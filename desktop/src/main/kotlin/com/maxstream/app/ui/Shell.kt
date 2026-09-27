package com.maxstream.app.ui

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowLeft
import androidx.compose.material.icons.filled.Bookmark
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.DarkMode
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.LightMode
import androidx.compose.material.icons.filled.LiveTv
import androidx.compose.material.icons.filled.Movie
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.input.pointer.onPointerEvent
import org.jetbrains.compose.resources.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.WindowPlacement
import androidx.compose.ui.window.WindowState
import androidx.compose.ui.window.rememberWindowState
import com.maxstream.app.data.AppPrefs
import com.maxstream.app.data.WatchStateStore
import com.maxstream.app.data.cloud.AppSession
import com.maxstream.app.data.cloud.CloudSync
import com.maxstream.app.data.cloud.ProfileStore
import com.maxstream.app.data.model.PlayRequest
import com.maxstream.app.data.repository.TmdbRepository
import com.maxstream.app.resources.Res
import com.maxstream.app.resources.app_icon
import com.maxstream.app.ui.components.LocalSearchActive
import com.maxstream.app.ui.components.appClickable
import com.maxstream.app.ui.navigation.AppRoute
import com.maxstream.app.ui.screens.AuthScreen
import com.maxstream.app.ui.screens.DetailsScreen
import com.maxstream.app.ui.screens.HomeScreen
import com.maxstream.app.ui.screens.MoviesScreen
import com.maxstream.app.ui.screens.PlayerScreen
import com.maxstream.app.ui.screens.ProfileSelectScreen
import com.maxstream.app.ui.screens.SeriesScreen
import com.maxstream.app.ui.screens.SettingsScreen
import com.maxstream.app.ui.screens.SplashScreen
import com.maxstream.app.ui.screens.WatchlistScreen
import com.maxstream.app.ui.theme.DesktopTheme

private val repository = TmdbRepository

private val topLevels = listOf<AppRoute>(
    AppRoute.Home,
    AppRoute.Movies(),
    AppRoute.Series(),
    AppRoute.Watchlist,
    AppRoute.Settings,
)

private sealed interface AppPhase {
    data object Splash : AppPhase
    data object Auth : AppPhase
    data object Profile : AppPhase
    data object Main : AppPhase
}

/** Coarse depth for push vs pop slide direction (Details/Player deeper). */
private fun AppRoute.depth(): Int = when (this) {
    AppRoute.Home, is AppRoute.Movies, is AppRoute.Series, AppRoute.Watchlist, AppRoute.Settings -> 0
    is AppRoute.Detail -> 1
    is AppRoute.Player -> 2
}

@Composable
fun Shell(windowState: WindowState = rememberWindowState()) {
    // Launch phases: splash → auth (if needed) → profile pick → main shell.
    var phase by remember { mutableStateOf<AppPhase>(AppPhase.Splash) }
    // Navigation history: last entry is the current route. Top-level sidebar
    // selections reset the stack; detail/player push so Back returns.
    var backStack by remember { mutableStateOf(listOf<AppRoute>(AppRoute.Home)) }
    val route = backStack.last()
    var query by remember { mutableStateOf("") }
    // True while the title-bar search field holds keyboard focus; guards the
    // route-change focus grab (typing jumps routes and must not steal focus).
    var searchFocused by remember { mutableStateOf(false) }
    // Dark is the MaxStream default; Settings/sidebar can force light (persisted).
    var darkOverride by remember { mutableStateOf(AppPrefs.darkTheme) }
    // Bumped when cloud watch history / profile changes so Home reloads CW.
    var syncRevision by remember { mutableIntStateOf(CloudSync.dataRevision) }
    val contentFocus = remember { FocusRequester() }
    val priorPlacement = remember { mutableStateOf(windowState.placement) }

    val useDark = darkOverride

    fun push(next: AppRoute) {
        if (next != route) backStack = backStack + next
    }

    fun replaceRoot(next: AppRoute) {
        backStack = listOf(next)
    }

    fun back() {
        if (backStack.size > 1) backStack = backStack.dropLast(1)
    }

    // Pull cloud watch history whenever the signed-in state changes.
    LaunchedEffect(AppSession.isSignedIn) {
        if (AppSession.isSignedIn) {
            CloudSync.syncWatchHistory()
            syncRevision = CloudSync.dataRevision
        }
    }

    // After profile pick / phase change into Main, pull that profile's data
    // before (or as) Home loads so Continue Watching isn't empty.
    LaunchedEffect(phase) {
        if (phase == AppPhase.Main && AppSession.isSignedIn) {
            CloudSync.syncWatchHistory()
            syncRevision = CloudSync.dataRevision
        }
    }

    // Observe revision bumps without reading snapshot state in this
    // composition — a keyed read here recomposed the whole Shell (window
    // placement, phases, theme) on every watch-history push.
    LaunchedEffect(Unit) {
        snapshotFlow { CloudSync.dataRevision }.collect { syncRevision = it }
    }

    // Maximize while the player is open; restore prior placement on exit.
    LaunchedEffect(route) {
        if (route is AppRoute.Player) {
            if (windowState.placement != WindowPlacement.Fullscreen) {
                priorPlacement.value = windowState.placement
            }
            if (windowState.placement == WindowPlacement.Floating) {
                windowState.placement = WindowPlacement.Maximized
            }
        } else if (windowState.placement == WindowPlacement.Maximized &&
            priorPlacement.value == WindowPlacement.Floating
        ) {
            windowState.placement = priorPlacement.value
        }
    }

    // Returning from the player restores keyboard focus to the shell content,
    // but never while the user is typing in search (route changes under them).
    // The field unmounts on Player/Detail without dispatching a focus-lost
    // callback, so clear any stale flag there or focus would never restore.
    LaunchedEffect(route, searchFocused) {
        if (searchFocused && (route is AppRoute.Player || route is AppRoute.Detail)) {
            searchFocused = false
            return@LaunchedEffect
        }
        if (route !is AppRoute.Player && phase == AppPhase.Main && !searchFocused) {
            runCatching { contentFocus.requestFocus() }
        }
    }

    DesktopTheme(useDarkTheme = useDark) {
        when (phase) {
            AppPhase.Splash -> SplashScreen(
                onDone = {
                    phase = if (AppSession.isSignedIn) AppPhase.Profile else AppPhase.Auth
                },
            )
            AppPhase.Auth -> AuthScreen(
                onSuccess = { phase = AppPhase.Profile },
            )
            AppPhase.Profile -> ProfileSelectScreen(
                onSelected = { phase = AppPhase.Main },
            )
            AppPhase.Main -> CompositionLocalProvider(LocalSearchActive provides searchFocused) {
                MainShell(
                    route = route,
                    backStack = backStack,
                    query = query,
                    darkOverride = darkOverride,
                    syncRevision = syncRevision,
                    searchFocused = searchFocused,
                    onSearchFocusChange = { searchFocused = it },
                    contentFocus = contentFocus,
                    windowState = windowState,
                    onPush = ::push,
                    onReplaceRoot = ::replaceRoot,
                    onBack = ::back,
                    onQueryChange = { query = it },
                    onThemeChange = {
                        darkOverride = it
                        AppPrefs.setDarkTheme(it)
                    },
                    onSignOut = {
                        // Back to the auth gate; clear local CW/watch states so the
                        // next signed-in user doesn't inherit the previous profile's
                        // progress (cloud pull only replaces our data when signed in).
                        WatchStateStore.clearAll()
                        phase = AppPhase.Auth
                        replaceRoot(AppRoute.Home)
                        query = ""
                        syncRevision = CloudSync.dataRevision
                    },
                    onManageProfiles = {
                        phase = AppPhase.Profile
                        priorPlacement.value = WindowPlacement.Floating
                        if (windowState.placement != WindowPlacement.Fullscreen) {
                            windowState.placement = WindowPlacement.Floating
                        }
                    },
                    onSwitchProfile = {
                        phase = AppPhase.Profile
                        priorPlacement.value = WindowPlacement.Floating
                        if (windowState.placement != WindowPlacement.Fullscreen) {
                            windowState.placement = WindowPlacement.Floating
                        }
                    },
                )
            }
        }
    }
}

@Composable
private fun MainShell(
    route: AppRoute,
    backStack: List<AppRoute>,
    query: String,
    darkOverride: Boolean,
    syncRevision: Int,
    searchFocused: Boolean,
    onSearchFocusChange: (Boolean) -> Unit,
    contentFocus: FocusRequester,
    windowState: WindowState,
    onPush: (AppRoute) -> Unit,
    onReplaceRoot: (AppRoute) -> Unit,
    onBack: () -> Unit,
    onQueryChange: (String) -> Unit,
    onThemeChange: (Boolean) -> Unit,
    onSignOut: () -> Unit,
    onManageProfiles: () -> Unit,
    onSwitchProfile: () -> Unit,
) {
    fun push(next: AppRoute) {
        if (next != route) onPush(next)
    }

    fun replaceRoot(next: AppRoute) {
        onReplaceRoot(next)
    }

    fun back() {
        if (backStack.size > 1) onBack()
    }

    // Escape / browser-style Back anywhere except the root screen.
    // Player handles Escape itself (exit fullscreen first) while focused.
    // `.focusable()` matters: without it the focusRequester below targets a
    // non-focusable node, requestFocus() silently failed (runCatching), and
    // key events only arrived when some child already had focus.
    Box(
        Modifier
            .fillMaxSize()
            .focusRequester(contentFocus)
            .focusable()
            .onKeyEvent { event ->
                if (event.type != KeyEventType.KeyDown) return@onKeyEvent false
                if (route is AppRoute.Player) return@onKeyEvent false
                when (event.key) {
                    Key.Escape -> {
                        when {
                            // Esc clears an active search first; a second Esc
                            // then performs the usual back navigation.
                            searchFocused && query.isNotBlank() -> {
                                onQueryChange("")
                                true
                            }
                            backStack.size > 1 -> {
                                back()
                                true
                            }
                            else -> false
                        }
                    }
                    else -> false
                }
            },
    ) {
        if (route is AppRoute.Player) {
            val player = route as AppRoute.Player
            PlayerScreen(
                request = player.request,
                repository = repository,
                onBack = { back() },
                windowState = windowState,
            )
            return@Box
        }
        Row(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.surface)) {
            NavRail(
                current = route,
                onSelectRoot = {
                    replaceRoot(it)
                    // A rail tap is an explicit nav; drop stale search text.
                    onQueryChange("")
                },
                useDarkTheme = darkOverride,
                onToggleTheme = onThemeChange,
                onSwitchProfile = onSwitchProfile,
            )
            Column(Modifier.weight(1f).fillMaxHeight()) {
                TitleBar(
                    route = route,
                    canGoBack = backStack.size > 1,
                    onBack = { back() },
                    query = query,
                    onFocusChange = onSearchFocusChange,
                onQueryChange = {
                    onQueryChange(it)
                    // Typing from another top-level route jumps to Home results.
                    if (it.isNotBlank() && route != AppRoute.Home && route !is AppRoute.Detail && route !is AppRoute.Player) {
                        replaceRoot(AppRoute.Home)
                    }
                },
                )
                Spacer(Modifier.height(1.dp).fillMaxWidth().background(MaterialTheme.colorScheme.outlineVariant))
                AnimatedContent(
                    targetState = route,
                    transitionSpec = {
                        // Push (deeper route) enters from right; pop enters from left.
                        // Key off initialState/targetState — a captured route from
                        // the composition scope is stale by the time this runs, so
                        // the direction check never fired (transition was dead).
                        val forward = targetState.depth() > initialState.depth()
                        if (forward) {
                            slideInHorizontally(tween(240, easing = FastOutSlowInEasing)) { it / 4 } + fadeIn(tween(200)) togetherWith
                                slideOutHorizontally(tween(240, easing = FastOutSlowInEasing)) { -it / 6 } + fadeOut(tween(160))
                        } else if (targetState.depth() < initialState.depth()) {
                            slideInHorizontally(tween(240, easing = FastOutSlowInEasing)) { -it / 6 } + fadeIn(tween(200)) togetherWith
                                slideOutHorizontally(tween(240, easing = FastOutSlowInEasing)) { it / 4 } + fadeOut(tween(160))
                        } else {
                            fadeIn(tween(180)) togetherWith fadeOut(tween(140))
                        }
                    },
                    label = "routeContent",
                    modifier = Modifier.weight(1f).fillMaxWidth(),
                ) { target ->
                    when (target) {
                        is AppRoute.Home -> HomeScreen(
                            repository = repository,
                            query = query,
                            syncRevision = syncRevision,
                            onOpen = { push(AppRoute.Detail(it.id, it.mediaType, it.id)) },
                            onPlay = { m ->
                                push(AppRoute.Player(PlayRequest(m.id, m.mediaType, m.title)))
                            },
                            onSeeAllMovies = { section -> push(AppRoute.Movies(section)) },
                            onSeeAllSeries = { section -> push(AppRoute.Series(section)) },
                        )
                        is AppRoute.Movies -> MoviesScreen(
                            repository = repository,
                            initialSection = target.initialSection,
                            onOpen = { push(AppRoute.Detail(it.id, it.mediaType, it.id)) },
                        )
                        is AppRoute.Series -> SeriesScreen(
                            repository = repository,
                            initialSection = target.initialSection,
                            onOpen = { push(AppRoute.Detail(it.id, it.mediaType, it.id)) },
                        )
                        is AppRoute.Watchlist -> WatchlistScreen(
                            repository = repository,
                            isSignedIn = AppSession.isSignedIn,
                            syncRevision = syncRevision,
                            onOpen = { push(AppRoute.Detail(it.id, it.mediaType, it.id)) },
                        )
                        is AppRoute.Settings -> SettingsScreen(
                            useDarkTheme = darkOverride,
                            onThemeChange = onThemeChange,
                            onSignOut = onSignOut,
                            onManageProfiles = onManageProfiles,
                        )
                        is AppRoute.Detail -> DetailsScreen(
                            itemId = target.itemId,
                            mediaType = target.mediaType,
                            repository = repository,
                            onPlay = { req: PlayRequest ->
                                push(AppRoute.Player(req))
                            },
                            onOpen = { m ->
                                // Push (not replace) so Back steps through a chain
                                // of similar titles instead of losing history.
                                push(AppRoute.Detail(m.id, m.mediaType, m.id))
                            },
                        )
                        is AppRoute.Player -> Unit
                    }
                }
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Left navigation rail — collapsible (icon-only ↔ expanded), click-driven
// ─────────────────────────────────────────────────────────────────────────────

private data class RailItem(
    val label: String,
    val icon: ImageVector,
    val route: AppRoute,
)

@OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class)
@Composable
private fun NavRail(
    current: AppRoute,
    onSelectRoot: (AppRoute) -> Unit,
    useDarkTheme: Boolean,
    onToggleTheme: (Boolean) -> Unit,
    onSwitchProfile: () -> Unit,
) {
    val items = listOf(
        RailItem("Home", Icons.Default.Home, AppRoute.Home),
        RailItem("Movies", Icons.Default.Movie, AppRoute.Movies()),
        RailItem("Series", Icons.Default.LiveTv, AppRoute.Series()),
        RailItem("Watchlist", Icons.Default.Bookmark, AppRoute.Watchlist),
        RailItem("Settings", Icons.Default.Settings, AppRoute.Settings),
    )
    // Hover expands labels; chevron can pin the expanded state open.
    var pinnedExpanded by remember { mutableStateOf(false) }
    var railHovered by remember { mutableStateOf(false) }
    val expanded = pinnedExpanded || railHovered

    val railWidth by animateDpAsState(
        targetValue = if (expanded) 232.dp else 76.dp,
        animationSpec = tween(durationMillis = 180, easing = FastOutSlowInEasing),
        label = "railWidth",
    )

    val selectedRoute = when (current) {
        is AppRoute.Detail -> AppRoute.Home
        else -> current
    }
    val profile = ProfileStore.activeProfile
    val user = AppSession.user

    Column(
        Modifier
            .width(railWidth)
            .fillMaxHeight()
            .onPointerEvent(PointerEventType.Enter) { railHovered = true }
            .onPointerEvent(PointerEventType.Exit) { railHovered = false }
            .background(MaterialTheme.colorScheme.surfaceVariant)
            .padding(vertical = 12.dp),
    ) {
        // Header: centered mark when collapsed; logo + title + pin when open.
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = if (expanded) Arrangement.Start else Arrangement.Center,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = if (expanded) 12.dp else 0.dp, vertical = 8.dp),
        ) {
            // app_icon = installed-app mark (M only); maxstream_logo = wordmark splash.
            Image(
                painter = painterResource(Res.drawable.app_icon),
                contentDescription = "MaxStream",
                modifier = Modifier
                    .size(40.dp)
                    .appClickable { pinnedExpanded = !pinnedExpanded },
            )
            if (expanded) {
                Spacer(Modifier.width(10.dp))
                Text(
                    "MaxStream",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.onSurface,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                IconButton(
                    onClick = { pinnedExpanded = false },
                    modifier = Modifier.size(32.dp),
                ) {
                    Icon(
                        Icons.AutoMirrored.Filled.KeyboardArrowLeft,
                        contentDescription = "Collapse sidebar",
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }

        Spacer(Modifier.height(8.dp))

        items.forEach { item ->
            val selected = selectedRoute == item.route
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = if (expanded) Arrangement.Start else Arrangement.Center,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 10.dp)
                    .background(
                        if (selected) MaterialTheme.colorScheme.primary.copy(alpha = 0.16f)
                        else Color.Transparent,
                        RoundedCornerShape(8.dp),
                    )
                    .appClickable { onSelectRoot(item.route) }
                    .then(
                        if (expanded) Modifier.padding(horizontal = 12.dp, vertical = 10.dp)
                        else Modifier.padding(vertical = 12.dp),
                    ),
            ) {
                if (selected) {
                    // Red accent bar on the left of the selected rail item.
                    Box(
                        Modifier
                            .width(3.dp)
                            .height(18.dp)
                            .background(MaterialTheme.colorScheme.primary, RoundedCornerShape(2.dp)),
                    )
                    Spacer(Modifier.width(8.dp))
                }
                Icon(
                    item.icon,
                    contentDescription = item.label,
                    tint = if (selected) MaterialTheme.colorScheme.primary
                           else MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(22.dp),
                )
                if (expanded) {
                    Spacer(Modifier.width(12.dp))
                    Text(
                        item.label,
                        color = if (selected) MaterialTheme.colorScheme.primary
                                else MaterialTheme.colorScheme.onSurface,
                        fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
                        fontSize = 14.sp,
                        maxLines = 1,
                    )
                }
            }
        }

        Spacer(Modifier.weight(1f))

        // Theme toggle is always visible (collapsed: icon-only row).
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = if (expanded) Arrangement.Start else Arrangement.Center,
            modifier = Modifier
                .fillMaxWidth()
                .appClickable { onToggleTheme(!useDarkTheme) }
                .padding(horizontal = if (expanded) 22.dp else 0.dp, vertical = 10.dp),
        ) {
            Icon(
                if (useDarkTheme) Icons.Default.LightMode else Icons.Default.DarkMode,
                contentDescription = "Toggle theme",
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(20.dp),
            )
            if (expanded) {
                Spacer(Modifier.width(12.dp))
                Text(
                    if (useDarkTheme) "Light mode" else "Dark mode",
                    fontSize = 13.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }

        // Footer: profile chip (click → switch profile) with palette avatar.
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = if (expanded) Arrangement.Start else Arrangement.Center,
            modifier = Modifier
                .fillMaxWidth()
                .appClickable { onSwitchProfile() }
                .padding(horizontal = if (expanded) 12.dp else 0.dp, vertical = 8.dp),
        ) {
            val avatarColor = profileColor(profile?.colorIndex ?: 0)
            Box(
                Modifier
                    .size(30.dp)
                    .background(avatarColor, CircleShape),
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.Default.Person, null, tint = Color.White, modifier = Modifier.size(18.dp))
            }
            if (expanded) {
                Spacer(Modifier.width(10.dp))
                Column(Modifier.weight(1f)) {
                    Text(
                        profile?.name ?: if (user != null) "You" else "Guest",
                        fontSize = 13.sp,
                        color = MaterialTheme.colorScheme.onSurface,
                        fontWeight = FontWeight.Medium,
                        maxLines = 1,
                    )
                    Text(
                        if (user != null) user.email else "Switch profile",
                        fontSize = 11.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }
    }
}

/** Same avatar palette order as ProfileSelectScreen / mobile ProfileAvatar. */
private fun profileColor(index: Int): Color {
    val palette = listOf(
        0xFFE50914, 0xFF6366F1, 0xFF8B5CF6, 0xFFEC4899,
        0xFFF59E0B, 0xFF10B981, 0xFF06B6D4, 0xFF3B82F6,
        0xFFEF4444, 0xFF14B8A6, 0xFFF97316, 0xFFA855F7,
    )
    return Color(palette[index.mod(palette.size)])
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun TitleBar(
    route: AppRoute,
    canGoBack: Boolean,
    onBack: () -> Unit,
    query: String,
    onFocusChange: (Boolean) -> Unit,
    onQueryChange: (String) -> Unit,
) {
    val title = when (route) {
        is AppRoute.Home -> "Home"
        is AppRoute.Movies -> "Movies"
        is AppRoute.Series -> "Series"
        is AppRoute.Watchlist -> "Watchlist"
        is AppRoute.Settings -> "Settings"
        is AppRoute.Detail -> "Details"
        is AppRoute.Player -> "Player"
    }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().height(52.dp).background(MaterialTheme.colorScheme.surface)
            .padding(horizontal = 8.dp),
    ) {
        if (canGoBack) {
            IconButton(onClick = onBack) {
                Icon(
                    Icons.AutoMirrored.Filled.ArrowBack,
                    contentDescription = "Back",
                    tint = MaterialTheme.colorScheme.onSurface,
                )
            }
        }
        Text(
            title,
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurface,
            modifier = Modifier.padding(start = if (canGoBack) 0.dp else 8.dp),
        )
        Spacer(Modifier.weight(1f))
        // Search is available on every content route (Details keeps its title).
        if (route !is AppRoute.Detail && route !is AppRoute.Player) {
            OutlinedTextField(
                value = query,
                onValueChange = { onQueryChange(it) },
                placeholder = { Text("Search titles, genres…", color = MaterialTheme.colorScheme.outline) },
                leadingIcon = { Icon(Icons.Default.Search, null) },
                trailingIcon = {
                    if (query.isNotEmpty()) {
                        IconButton(onClick = { onQueryChange("") }) {
                            Icon(
                                Icons.Default.Close,
                                contentDescription = "Clear search",
                                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                },
                singleLine = true,
                shape = RoundedCornerShape(8.dp),
                textStyle = MaterialTheme.typography.bodyMedium,
                colors = OutlinedTextFieldDefaults.colors(
                    focusedContainerColor = MaterialTheme.colorScheme.surface,
                    unfocusedContainerColor = MaterialTheme.colorScheme.surface,
                ),
                modifier = Modifier
                    .width(300.dp)
                    .height(38.dp)
                    .onFocusChanged { onFocusChange(it.isFocused) },
            )
        }
    }
}
