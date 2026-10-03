package com.maxstream.app.ui.shell

import android.os.Bundle
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import com.maxstream.app.data.local.WatchEntryCompat
import com.maxstream.app.data.local.ProfileScope
import com.maxstream.app.data.repository.UpdateRepository
import com.maxstream.app.ui.navigation.Screen
import com.maxstream.app.ui.screens.auth.LoginScreen
import com.maxstream.app.ui.screens.more.UpdateDialog
import com.maxstream.app.ui.screens.more.rememberUpdateInstallController
import com.maxstream.app.ui.screens.profile.ProfileSelectScreen
import com.maxstream.app.ui.screens.details.DetailsScreen
import com.maxstream.app.ui.screens.genre.GenreScreen
import com.maxstream.app.ui.screens.home.HomeScreen
import com.maxstream.app.ui.screens.more.MoreContentKind
import com.maxstream.app.ui.screens.more.MoreContentScreen
import com.maxstream.app.ui.screens.more.MoreScreen
import com.maxstream.app.ui.screens.player.PlayerScreen
import com.maxstream.app.ui.screens.search.SearchScreen
import com.maxstream.app.ui.screens.series.SeriesListScreen
import com.maxstream.app.ui.screens.splash.SplashScreen
import com.maxstream.app.ui.screens.watchlist.WatchlistScreen
import com.maxstream.app.ui.theme.MaxStreamTheme
import com.maxstream.app.ui.tv.TvFocusManager
import kotlinx.coroutines.delay

class MainActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        WatchEntryCompat.init(applicationContext)
        // Continuous cloud sync (watch progress + watchlist) while signed in —
        // mirrors the Dart phone app's CloudSyncService.startListening().
        com.maxstream.app.data.repository.CloudSyncCoordinator.start(applicationContext)

        try {
            setContent {
                MaxStreamTheme {
                    TvAppRoot()
                }
            }
        } catch (t: Throwable) {
            Log.e("MainActivity", "Compose startup failure", t)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Root composable
// ─────────────────────────────────────────────────────────────────────────────

@Composable
private fun TvAppRoot() {
    val appState = rememberTvAppState()

    // ── Focus architecture (mirrors Dart FocusScopeNode pattern) ─────────
    // sidebarFocusRequesters[i] is attached to each sidebar pill item.
    // contentFocusRequester is attached to the content Box. The Box itself is
    // NOT focusable: Compose 1.7 has no FocusScope/focusGroup to forward focus
    // into the active screen, so parking focus on the Box only fought the
    // screen's own reseed. Instead each screen re-seeds its content focus from
    // the contentFocusTick (focusKey) kept in MainActivity.
    val sidebarFocusRequesters = remember { List(6) { FocusRequester() } }
    val contentFocusRequester  = remember { FocusRequester() }

    // ── Two NavHosts (mirrors Dart: IndexedStack shell + Navigator overlays) ─
    // shellNavController holds Splash/Login/Shell. Once the Shell destination is
    // reached it STAYS composed — tab scroll/focus state (heroItem, RowNavState,
    // Genre section, …) survives every details/player excursion below.
    val shellNavController = rememberNavController()
    // deepNavController overlays the shell with Details/Player. DeepRoot is an
    // invisible placeholder at the bottom of its stack so popBackStack never
    // empties it; popping back to DeepRoot restores the shell's content focus.
    val deepNavController = rememberNavController()

    // Wire TvFocusManager singleton (used by individual screens)
    LaunchedEffect(Unit) {
        TvFocusManager.initialize(
            sidebarFocusRequesters = sidebarFocusRequesters,
            contentFocusRequester  = contentFocusRequester,
        )
    }

    var exitDialogVisible by remember { mutableStateOf(false) }

    // ── Startup update check (mirrors Dart MaxStreamMainScreen._initializeServices) ─
    // Populated once the Shell is reached; shown as a modal dialog until the
    // user picks Update Now (in-app download + install) or Later.
    var updateInfo by remember { mutableStateOf<UpdateRepository.UpdateInfo?>(null) }
    var updatePromptedVersion by remember { mutableStateOf<String?>(null) }
    val updateController = rememberUpdateInstallController()

    // Bumped on every sidebar → content hand-off so the active screen re-seeds
    // its own focus. Mirrors Dart's _focusContent(): focusing the content
    // FocusScope restores the last-focused descendant; Compose has no such
    // auto-forward on a plain focusable Box, so we nudge each screen to
    // restore focus via this tick (passed down as `focusKey`).
    var contentFocusTick by remember { mutableIntStateOf(0) }

    // Bumped when the deep-nav overlay (Details/Player) empties back to
    // DeepRoot. Unlike contentFocusTick (which re-seeds the hero), this makes
    // the active tab restore ITS last-focused element (the card/row/grid spot
    // the user launched the player/details from).
    var deepNavReturnTick by remember { mutableIntStateOf(0) }

    // When the overlay pops back to DeepRoot, nudge the active tab to restore
    // its last focus. Each screen re-seeds on (isVisible, restoreFocusKey), so
    // we only need to bump the tick here — the content Box is not focusable
    // (Compose 1.7 has no focus group to forward into the screen), so requesting
    // contentFocusRequester would just park focus on an invisible container.
    LaunchedEffect(Unit) {
        var prev: String? = Screen.DeepRoot.route
        deepNavController.currentBackStackEntryFlow.collect { entry ->
            val route = entry.destination.route
            if (route == Screen.DeepRoot.route && prev != Screen.DeepRoot.route) {
                deepNavReturnTick++
            }
            prev = route
        }
    }

    // ── Back state machine (Nuvio pattern) ──────────────────────────────
    // root=tab0, sidebar=expanded, content=collapsed.
    // - Back with the deep-nav overlay on top → pop the overlay (exit back to
    //   the shell; the entry-flow listener below hands focus back to content)
    // - Back on root + sidebar focused → exit app
    // - Back on root + content focused → open sidebar (expand it)
    // - Back on non-root tab → navigate to home + focus sidebar
    fun handleBack() {
        // 1. Deep-nav overlay on top (anything but the DeepRoot placeholder).
        if (deepNavController.currentBackStackEntry?.destination?.route != Screen.DeepRoot.route) {
            deepNavController.popBackStack()
            return
        }
        // 2. Home tab (root):
        if (appState.selectedTab == 0) {
            if (appState.focusOnSidebar) {
                // Home + sidebar → exit
                exitDialogVisible = true
            } else {
                // Home + content → open sidebar
                appState.updateFocusOnSidebar(true)
            }
            return
        }
        // 3. Non-home tab: always go to home + focus sidebar
        appState.selectTab(0)
        appState.updateFocusOnSidebar(true)
    }

    // ── Focus transfer effect ─────────────────────────────────────────────
    // The sidebar handles its own focus transfer: when active flips true,
    // Sidebar's self-terminating LaunchedEffect retries requestFocus() on
    // selectedIndex until a pill reports focus (focusedIndex >= 0).
    //
    // NOTE: there must be NO competing loop here. An unconditional retry loop
    // on selectedIndex (as we once had) keeps firing ~1s after focus lands,
    // so a user navigating within the sidebar during that window gets yanked
    // back to the selected item — the "focus goes down then comes back up"
    // flicker. The sidebar owns this transfer; the shell just flips the flag.
    //
    // When focusOnSidebar is false we deliberately do nothing: the active
    // screen seeds its own content focus via its isVisible effect, so we
    // must not fight it by re-requesting the content box.

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color(0xFF0F0F0F))
            .onKeyEvent { event ->
                if (event.type == KeyEventType.KeyDown &&
                    (event.key == Key.Back || event.key == Key.Escape)
                ) {
                    handleBack(); true
                } else false
            }
    ) {
        // ── Underlay NavHost: Splash / Login / Shell ──────────────────────
        // The Shell destination stays composed once reached; tabs keep their
        // scroll/focus state across details/player excursions on the overlay.
        NavHost(
            navController = shellNavController,
            startDestination = Screen.Splash.route,
            enterTransition  = { fadeIn(tween(300)) },
            exitTransition   = { fadeOut(tween(180)) },
            popEnterTransition = { fadeIn(tween(250)) },
            popExitTransition  = { fadeOut(tween(200)) },
        ) {
            composable(Screen.Splash.route) {
                val context = androidx.compose.ui.platform.LocalContext.current
                SplashScreen(onComplete = {
                    val loggedIn = com.maxstream.app.data.local.SessionManager.isLoggedIn(context)
                    val destination = if (loggedIn) Screen.ProfileSelect.route else Screen.Login.route
                    shellNavController.navigate(destination) {
                        popUpTo(Screen.Splash.route) { inclusive = true }
                    }
                })
            }
            composable(Screen.Login.route) {
                LoginScreen(onLoginSuccess = {
                    shellNavController.navigate(Screen.ProfileSelect.route) {
                        popUpTo(Screen.Login.route) { inclusive = true }
                    }
                })
            }
            composable(Screen.ProfileSelect.route) {
                ProfileSelectScreen(
                    onProfileSelected = {
                        shellNavController.navigate(Screen.Shell.route) {
                            popUpTo(Screen.ProfileSelect.route) { inclusive = true }
                        }
                    },
                )
            }
            composable(Screen.Shell.route) {
                val shellContext = androidx.compose.ui.platform.LocalContext.current
                // One update check per app start, a beat after the shell lands
                // so it never fights splash/profile focus.
                LaunchedEffect(Unit) {
                    delay(4_000)
                    if (updatePromptedVersion != null) return@LaunchedEffect
                    if (!UpdateRepository.isAutoCheckEnabled(shellContext)) return@LaunchedEffect
                    val info = runCatching { UpdateRepository.checkForUpdate(shellContext) }
                        .getOrNull()
                    if (info != null && info.version != updatePromptedVersion) {
                        updateInfo = info
                    }
                }
                TvShell(
                    appState                = appState,
                    sidebarFocusRequesters  = sidebarFocusRequesters,
                    contentFocusRequester   = contentFocusRequester,
                    shellNavController      = shellNavController,
                    deepNavController       = deepNavController,
                    contentFocusTick        = contentFocusTick,
                    deepNavReturnTick       = deepNavReturnTick,
                    requestContentFocus     = {
                        contentFocusTick++
                        // NOTE: deliberately do NOT request contentFocusRequester
                        // here. The content Box is a plain focusable (Compose 1.7
                        // has no FocusScope/focusGroup to forward focus into the
                        // screen), so requesting the Box parks focus on an
                        // invisible container and fights the screen's own
                        // reseed (which requests the hero). Bumping the tick is
                        // enough: each screen reseeds its content focus on
                        // (isVisible, focusKey), stealing focus off the sidebar
                    },
                    onContentFocusTick     = { contentFocusTick++ },
                )
            }
        }

        // ── Overlay NavHost: Details / Player, above the shell ─────────────
        // DeepRoot is an invisible transparent placeholder that never leaves the
        // bottom of the stack. Popping Details/Player back to it (see the entry
        // flow listener) restores the shell's content focus at the last spot.
        NavHost(
            navController = deepNavController,
            startDestination = Screen.DeepRoot.route,
            enterTransition  = { fadeIn(tween(250)) },
            exitTransition   = { fadeOut(tween(180)) },
            popEnterTransition = { fadeIn(tween(220)) },
            popExitTransition  = { fadeOut(tween(200)) },
        ) {
            composable(Screen.DeepRoot.route) {
                // Transparent placeholder: no background, no focusables, panel
                // laws keep the shell's own focusables reachable below it.
                Box(Modifier.fillMaxSize())
            }
            composable(Screen.Details.route) { backStackEntry ->
                // `active` is false the moment the Player (or another Details) is
                // pushed on top: the Hidden Details must stop receiving focus and
                // D-pad/OK so pressing OK while playing can never activate a tile
                // underneath (the "pressing OK selects another movie" bug).
                val isActive =
                    deepNavController.currentBackStackEntryAsState().value?.destination?.route ==
                        backStackEntry.destination.route
                val itemId = backStackEntry.arguments?.getString("itemId") ?: ""
                val mediaType = backStackEntry.arguments?.getString("mediaType") ?: "movie"
                DetailsScreen(
                    navController    = deepNavController,
                    itemId           = itemId,
                    mediaType        = mediaType,
                    active           = isActive,
                    onReturnToSidebar = {
                        deepNavController.popBackStack()
                        appState.updateFocusOnSidebar(true)
                    },
                )
            }
            composable(Screen.Player.route) { backStackEntry ->
                val itemId    = backStackEntry.arguments?.getString("itemId")    ?: ""
                val mediaType = backStackEntry.arguments?.getString("mediaType") ?: "movie"
                val season    = backStackEntry.arguments?.getString("season")?.toIntOrNull()  ?: 1
                val episode   = backStackEntry.arguments?.getString("episode")?.toIntOrNull() ?: 1
                PlayerScreen(deepNavController, itemId, mediaType, season, episode)
            }
            composable(Screen.MoreContent.route) { backStackEntry ->
                // Same `active` gate as Details: a Player pushed on top must not
                // let a hidden grid tile consume OK.
                val isActive =
                    deepNavController.currentBackStackEntryAsState().value?.destination?.route ==
                        backStackEntry.destination.route
                MoreContentScreen(
                    kind = MoreContentKind.from(
                        backStackEntry.arguments?.getString("kind")
                    ),
                    navController = deepNavController,
                    active = isActive,
                    // Popping back to the row re-seeds focus on the `>` cell
                    // the user launched from (see deepNavReturnTick).
                    onReturnToSidebar = { deepNavController.popBackStack() },
                    restoreFocusKey = deepNavReturnTick,
                )
            }
        }

        if (exitDialogVisible) {
            val activity = androidx.compose.ui.platform.LocalContext.current as? android.app.Activity
            ExitDialog(
                onDismiss = { exitDialogVisible = false },
                onConfirm = { exitDialogVisible = false; activity?.finish() },
            )
        }

        // ── Update available: same "Update to vX / Later / Update Now" flow ──
        updateInfo?.let { info ->
            UpdateDialog(
                info = info,
                controller = updateController,
                onDismiss = {
                    // Only prompt once per version per app start (Dart's
                    // UpdateService.reserveUpdateDialog equivalent).
                    updatePromptedVersion = info.version
                    updateInfo = null
                    // The dialog owns its own window; nudge the active tab to
                    // re-seed its own focus (same trick as requestContentFocus)
                    // so the D-pad still works after it closes.
                    if (shellNavController.currentBackStackEntry?.destination?.route ==
                        Screen.Shell.route
                    ) {
                        contentFocusTick++
                    }
                },
            )
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shell — sidebar + IndexedStack
// ─────────────────────────────────────────────────────────────────────────────

@Composable
private fun TvShell(
    appState: TvAppState,
    sidebarFocusRequesters: List<FocusRequester>,
    contentFocusRequester: FocusRequester,
    shellNavController: androidx.navigation.NavController,
    deepNavController: androidx.navigation.NavController,
    contentFocusTick: Int,
    deepNavReturnTick: Int,
    requestContentFocus: () -> Unit,
    onContentFocusTick: () -> Unit = {},
) {
    val context = androidx.compose.ui.platform.LocalContext.current

    Row(modifier = Modifier.fillMaxSize()) {

        // ── Sidebar ────────────────────────────────────────────────────────
        Sidebar(
            selectedIndex   = appState.selectedTab,
            focusRequesters = sidebarFocusRequesters,
            onItemSelected  = { index -> appState.selectTab(index) },
            onReturnToContent = {
                appState.updateFocusOnSidebar(false)
                requestContentFocus()
            },
            onFocusEntered  = { appState.updateFocusOnSidebar(true) },
            onSwitchProfile = {
                // Just reload content — don't navigate to ProfileSelect
                // (sidebar dropdown already sets the active profile)
                onContentFocusTick()
            },
            active          = appState.focusOnSidebar,
        )

        // ── Content area ───────────────────────────────────────────────────
        // NOTE: We intentionally do NOT use onKeyEvent here. Content screens
        // (Home, Search, etc.) handle LEFT→sidebar themselves via their own
        // onKeyEvent on the play button / first card. Adding a parent key
        // handler would intercept events before children see them.
        Box(
            modifier = Modifier
                .weight(1f)
                .fillMaxSize()
                .focusRequester(contentFocusRequester)
                .onFocusChanged { state ->
                    if (state.hasFocus) appState.updateFocusOnSidebar(false)
                }
        ) {
            TabScreen(visible = appState.selectedTab == 0) {
                HomeScreen(
                    navController      = deepNavController,
                    onReturnToSidebar  = { appState.updateFocusOnSidebar(true) },
                    isVisible          = appState.selectedTab == 0,
                    focusKey           = contentFocusTick,
                    restoreFocusKey    = deepNavReturnTick,
                )
            }
            TabScreen(visible = appState.selectedTab == 1) {
                SearchScreen(
                    navController      = deepNavController,
                    onReturnToSidebar  = { appState.updateFocusOnSidebar(true) },
                    isVisible          = appState.selectedTab == 1,
                    focusKey           = contentFocusTick,
                    restoreFocusKey    = deepNavReturnTick,
                )
            }
            TabScreen(visible = appState.selectedTab == 2) {
                GenreScreen(
                    navController      = deepNavController,
                    onReturnToSidebar  = { appState.updateFocusOnSidebar(true) },
                    isVisible          = appState.selectedTab == 2,
                    focusKey           = contentFocusTick,
                    restoreFocusKey    = deepNavReturnTick,
                )
            }
            TabScreen(visible = appState.selectedTab == 3) {
                SeriesListTab(
                    navController      = deepNavController,
                    onReturnToSidebar  = { appState.updateFocusOnSidebar(true) },
                    isVisible          = appState.selectedTab == 3,
                    focusKey           = contentFocusTick,
                    restoreFocusKey    = deepNavReturnTick,
                )
            }
            TabScreen(visible = appState.selectedTab == 4) {
                WatchlistScreen(
                    navController      = deepNavController,
                    onReturnToSidebar  = { appState.updateFocusOnSidebar(true) },
                    isVisible          = appState.selectedTab == 4,
                    focusKey           = contentFocusTick,
                    restoreFocusKey    = deepNavReturnTick,
                )
            }
            TabScreen(visible = appState.selectedTab == 5) {
                MoreScreen(
                    navController      = deepNavController,
                    onReturnToSidebar  = { appState.updateFocusOnSidebar(true) },
                    onSignOut = {
                        ProfileScope.clearAll(context)
                        shellNavController.navigate(Screen.Login.route) {
                            popUpTo(Screen.Shell.route) { inclusive = true }
                        }
                    },
                    isVisible       = appState.selectedTab == 5,
                    focusKey        = contentFocusTick,
                    restoreFocusKey = deepNavReturnTick,
                )
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// IndexedStack cell
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Keeps the composable alive (for scroll/state preservation) but collapses
 * it to 0×0 and blocks all focus traversal into it when not visible.
 * Mirrors Flutter's IndexedStack + Offstage behaviour.
 */
@Composable
private fun TabScreen(
    visible: Boolean,
    content: @Composable () -> Unit,
) {
    androidx.compose.animation.AnimatedVisibility(
        visible = visible,
        enter  = androidx.compose.animation.fadeIn(tween(220)),
        exit   = androidx.compose.animation.fadeOut(tween(160)),
    ) {
        Box(
            modifier = Modifier.fillMaxSize()
        ) {
            content()
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Series list tab wrapper
// ─────────────────────────────────────────────────────────────────────────────

@Composable
private fun SeriesListTab(
    navController: androidx.navigation.NavController,
    onReturnToSidebar: () -> Unit,
    isVisible: Boolean,
    focusKey: Int,
    restoreFocusKey: Int,
) {
    SeriesListScreen(
        navController      = navController,
        onReturnToSidebar  = onReturnToSidebar,
        isVisible          = isVisible,
        focusKey           = focusKey,
        restoreFocusKey    = restoreFocusKey,
    )
}

// ─────────────────────────────────────────────────────────────────────────────
// Exit dialog
// ─────────────────────────────────────────────────────────────────────────────

@Composable
private fun ExitDialog(onDismiss: () -> Unit, onConfirm: () -> Unit) {
    val cancelFocus = androidx.compose.ui.focus.FocusRequester()
    val confirmFocus = androidx.compose.ui.focus.FocusRequester()
    var cancelFocused by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf(false) }
    var confirmFocused by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf(false) }
    androidx.compose.runtime.LaunchedEffect(Unit) { cancelFocus.requestFocus() }
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor   = Color(0xFF1E1E1E),
        title = {
            Text("Exit MaxStream?", color = Color.White,
                fontSize = 24.sp, fontWeight = FontWeight.Bold)
        },
        text = {
            Text("Do you want to exit the app?",
                color = Color.White.copy(alpha = 0.7f), fontSize = 18.sp)
        },
        dismissButton = {
            TextButton(
                modifier = Modifier
                    .focusRequester(cancelFocus)
                    .onFocusChanged { cancelFocused = it.isFocused }
                    .background(
                        if (cancelFocused) Color.White else Color.Transparent,
                        RoundedCornerShape(20.dp)
                    )
                    .border(
                        width = if (cancelFocused) 2.dp else 1.dp,
                        color = if (cancelFocused) Color.White else Color(0x40FFFFFF),
                        shape = RoundedCornerShape(20.dp)
                    ),
                onClick = onDismiss,
                colors = ButtonDefaults.textButtonColors(
                    contentColor = if (cancelFocused) Color.Black else Color.White
                ),
            ) {
                Text("Cancel", fontSize = 18.sp, fontWeight = if (cancelFocused) FontWeight.Bold else FontWeight.Normal)
            }
        },
        confirmButton = {
            TextButton(
                modifier = Modifier
                    .focusRequester(confirmFocus)
                    .onFocusChanged { confirmFocused = it.isFocused }
                    .background(
                        if (confirmFocused) Color.White else Color(0xFFE50914),
                        RoundedCornerShape(20.dp)
                    )
                    .border(
                        width = if (confirmFocused) 2.dp else 0.dp,
                        color = if (confirmFocused) Color.White else Color.Transparent,
                        shape = RoundedCornerShape(20.dp)
                    ),
                onClick = onConfirm,
                colors = ButtonDefaults.textButtonColors(
                    contentColor = if (confirmFocused) Color.Black else Color.White
                ),
            ) {
                Text("Exit", fontSize = 18.sp, fontWeight = if (confirmFocused) FontWeight.Bold else FontWeight.Normal)
            }
        },
    )
}
