package com.maxstream.app.ui.screens.home

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.OverscrollEffect
import androidx.compose.foundation.overscroll
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Upcoming
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.livedata.observeAsState
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEvent
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavController
import coil.compose.AsyncImage
import com.maxstream.app.R
import com.maxstream.app.data.local.WatchEntryCompat
import com.maxstream.app.data.local.ProfileScope
import com.maxstream.app.data.model.MediaItem
import com.maxstream.app.ui.components.ContentCard
import com.maxstream.app.ui.components.SeeAllCell
import com.maxstream.app.ui.components.ContentCardPosterHeight
import com.maxstream.app.ui.components.ContentCardRowHeight
import com.maxstream.app.ui.components.ContentCardWidth
import com.maxstream.app.ui.components.ComingSoonCard
import com.maxstream.app.ui.components.ComingSoonCardWidth
import com.maxstream.app.ui.components.ComingSoonCardHeight
import com.maxstream.app.ui.components.ComingSoonCardRowHeight
import com.maxstream.app.ui.components.focusRing
import com.maxstream.app.ui.navigation.Screen
import com.maxstream.app.ui.screens.more.MoreContentKind
import com.maxstream.app.ui.screens.more.MoreContentSeed
import com.maxstream.app.ui.theme.Background
import com.maxstream.app.ui.tv.RowDesc
import com.maxstream.app.ui.tv.RowNavState
import com.maxstream.app.ui.viewmodel.HomeViewModel
import com.maxstream.app.util.KidsTheme
import androidx.compose.ui.platform.LocalContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.isActive

/** Continue Watching poster — the surface its focus ring wraps. */
private val CWPosterWidth: Dp = 220.dp
private val CWPosterHeight: Dp = 160.dp

// ─────────────────────────────────────────────────────────────────────────────
// HomeScreen
// ─────────────────────────────────────────────────────────────────────────────

@Composable
fun HomeScreen(
    navController: NavController,
    onReturnToSidebar: () -> Unit,
    isVisible: Boolean = true,
    focusKey: Int = 0,
    restoreFocusKey: Int = 0,
) {
    val viewModel: HomeViewModel = viewModel()
    val trendingMovies  by viewModel.trendingMovies.observeAsState(emptyList())
    val popularMovies   by viewModel.popularMovies.observeAsState(emptyList())
    val topRatedMovies  by viewModel.topRatedMovies.observeAsState(emptyList())
    val continueWatching by viewModel.continueWatching.observeAsState(emptyList())
    val forYou by viewModel.forYou.observeAsState(emptyList())
    val becauseYouWatched by viewModel.becauseYouWatched.observeAsState(null)
    val comingSoon by viewModel.comingSoon.observeAsState(emptyList())

    var heroItem   by remember { mutableStateOf<MediaItem?>(null) }
    var heroType   by remember { mutableStateOf("movie") }
    var heroResume by remember { mutableStateOf(false) }
    var pendingHeroItem by remember { mutableStateOf<MediaItem?>(null) }
    var pendingHeroResume by remember { mutableStateOf(false) }
    var isEntryVisible by remember { mutableStateOf(false) }

    // Focus requesters for the hero buttons
    val playFocusRequester    = remember { FocusRequester() }
    val detailsFocusRequester = remember { FocusRequester() }
    val coroutineScope = rememberCoroutineScope()
    val context = LocalContext.current

    // D-pad navigation across the content rows (shared with every ContentRow).
    val outerListState = rememberLazyListState()
    val rowNav = remember { RowNavState() }

    // Ordered list of visible rows — must mirror the LazyColumn item order.
    val rows = remember(continueWatching, trendingMovies, popularMovies, topRatedMovies, forYou, becauseYouWatched, comingSoon) {
        buildList {
            if (continueWatching.isNotEmpty()) add(RowDesc("home:Continue Watching", continueWatching.size))
            if (trendingMovies.isNotEmpty()) add(RowDesc("home:Trending Movies", trendingMovies.size.coerceAtMost(15)))
            if (forYou.isNotEmpty()) add(RowDesc("home:For You", forYou.size.coerceAtMost(15)))
            if (popularMovies.isNotEmpty()) add(RowDesc("home:Popular Movies", popularMovies.size.coerceAtMost(15)))
            if (topRatedMovies.isNotEmpty()) add(RowDesc("home:Top Rated", topRatedMovies.size.coerceAtMost(15)))
            val byw = becauseYouWatched
            if (byw != null) add(RowDesc("home:Because You Watched", byw.second.size.coerceAtMost(15)))
            if (comingSoon.isNotEmpty()) add(RowDesc("home:Coming Soon", comingSoon.size.coerceAtMost(15)))
        }
    }

    // Row titles resolved once at composable scope (stringResource is
    // @Composable, so it can't be called inside a click handler).
    val cwTitle = stringResource(R.string.continue_watching)
    val trendingTitle = stringResource(R.string.trending_movies)
    val forYouTitle = stringResource(R.string.for_you)
    val popularTitle = stringResource(R.string.popular_movies)
    val topRatedTitle = stringResource(R.string.top_rated)
    val bywTitle = stringResource(
        R.string.because_you_watched,
        becauseYouWatched?.first ?: "",
    )
    val comingSoonTitle = stringResource(R.string.coming_soon)

    // Trailing `>` cell -> seed the full list, then open it.
    val openMore: (MoreContentKind, String, List<MediaItem>) -> Unit = { kind, title, seed ->
        MoreContentSeed.set(title, seed)
        navController.navigate(Screen.MoreContent.createRoute(kind.name))
    }
    rowNav.setRows(rows)
    rowNav.clearMissingRows()

    // Seed hero item once data loads
    LaunchedEffect(trendingMovies) {
        if (heroItem == null && trendingMovies.isNotEmpty()) {
            heroItem = trendingMovies.first()
            heroType = "movie"
            heroResume = false
        }
    }

    // Hero debounce — mirrors Dart's Timer(400ms) _queueHero pattern.
    LaunchedEffect(pendingHeroItem, pendingHeroResume) {
        val item = pendingHeroItem ?: return@LaunchedEffect
        delay(400)
        heroItem = item
        heroResume = pendingHeroResume
        heroType = if (item.mediaType == "tv") "series" else "movie"
    }

    fun heroDown() {
        rowNav.focusFirstRow(outerListState, coroutineScope)
    }

    // Entry animation + initial focus seed.
    // Re-runs whenever this tab becomes visible OR focus returns from the
    // sidebar (focusKey bump), so focus is restored on tab return.
    // First attempt is IMMEDIATE (no pre-delay); retries until the hero Play
    // button actually takes focus. Because the tab enters via AnimatedVisibility
    // (a fade-in), the hero may not be composed on the very first frame even
    // when heroItem is already set — so a single requestFocus would be a silent
    // no-op and the user would see no focus on the Play button when coming from
    // the sidebar. We keep retrying across frames until the repeated requests
    // catch the Play button once it exists (mirrors Dart's _restoreInitialFocus,
    // which runs on double post-frame callbacks). The user pressed DOWN during
    // the window could still be handled, but requesting the hero repeatedly for
    // a short window is what makes OK-from-sidebar land on Play reliably.
    LaunchedEffect(isVisible, focusKey) {
        if (!isVisible) return@LaunchedEffect
        isEntryVisible = true
        var attempt = 0
        while (attempt < 18) {
            if (attempt > 0) delay(50L * attempt)
            runCatching { playFocusRequester.requestFocus() }
            // Keep at least a few attempts even when heroItem exists, so the
            // request survives the tab's fade-in frame where the button is not
            // yet composed; stop once we've had enough chances.
            if (attempt >= 4 && heroItem != null) return@LaunchedEffect
            attempt++
        }
    }

    // Deep-nav return: details/player overlay popped. The shell never leaves
    // composition now, so every row/card FocusRequester is still valid — put
    // focus back on the exact row the user left, not the hero. Falls back to
    // the hero when no row was active (e.g. cold start).
    LaunchedEffect(isVisible, restoreFocusKey) {
        if (!isVisible || restoreFocusKey <= 0) return@LaunchedEffect
        // Left via a row's trailing `>` See All cell — put focus back on that
        // cell, not on the card the navigator last remembered.
        rowNav.seeAllReturnRowId?.let { returnRow ->
            rowNav.seeAllReturnRowId = null
            runCatching { rowNav.seeAllRequester(returnRow).requestFocus() }
            return@LaunchedEffect
        }
        val rowId = rowNav.activeRowId
        if (rowId != null && rowNav.count(rowId) > 0) {
            rowNav.moveTo(rowId, rowNav.focusedIndex(rowId), outerListState, coroutineScope)
        } else {
            runCatching { playFocusRequester.requestFocus() }
        }
    }

    // Seed focus once the hero item loads (data arrives from API).
    // This covers the cold-start case where the initial retry window above
    // expires before the hero poster is composed. Deliberately runs ONCE:
    // re-running on every heroItem change (the 400ms pendingHeroItem debounce
    // fires whenever a content card is focused) stole focus back to the hero
    // from the card the user was navigating.
    var heroFocusSeeded by remember { mutableStateOf(false) }
    LaunchedEffect(heroItem, isVisible) {
        if (!isVisible || heroItem == null || heroFocusSeeded) return@LaunchedEffect
        var attempt = 0
        while (attempt < 8) {
            if (attempt > 0) delay(60L * attempt)
            // requestFocus() is a silent no-op while unattached; the hero Play
            // button exists once heroItem != null, so the call lands then.
            runCatching { playFocusRequester.requestFocus() }
            if (heroItem != null) {
                heroFocusSeeded = true
                return@LaunchedEffect
            }
            attempt++
        }
    }

    // While Home is visible, continuously mirror the phone's synced progress so
    // Continue Watching reflects what was watched on the phone. The 30s poll
    // keeps the row fresh even if a revision bump is missed; CloudSyncCoordinator
    // also bumps historyRevision on every inbound change (mirrors the phone's
    // real-time Firestore listener + historyRevision notifier).
    val historyRevision by com.maxstream.app.data.repository.CloudSyncCoordinator.historyRevision
        .collectAsState()
    LaunchedEffect(isVisible, historyRevision) {
        if (isVisible) viewModel.refreshSynced()
    }
    // Reload all content when the active profile changes (sidebar switch)
    val profileRevision by ProfileScope.profileRevision
    LaunchedEffect(isVisible, profileRevision) {
        if (isVisible && profileRevision > 0) viewModel.loadAll()
    }
    LaunchedEffect(isVisible) {
        while (isVisible && coroutineContext.isActive) {
            delay(30_000)
            viewModel.refreshSynced()
        }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(KidsTheme.background(context))
    ) {
        AnimatedVisibility(
            visible = isEntryVisible,
            enter = fadeIn(tween(330)) + scaleIn(tween(330), initialScale = 0.97f),
            exit  = fadeOut(tween(180)),
        ) {
            Box(modifier = Modifier.fillMaxSize()) {
                // ── Hero backdrop (top 55%) ────────────────────────────────
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .fillMaxHeight(0.55f)
                        .align(Alignment.TopStart)
                ) {
                    HeroSection(
                        item = heroItem,
                        mediaType = heroType,
                        isResume = heroResume,
                        playFocusRequester = playFocusRequester,
                        detailsFocusRequester = detailsFocusRequester,
                        onPlay = { mediaItem ->
                            if (mediaItem != null) {
                                val route = if (heroType == "series")
                                    Screen.Player.createRoute(
                                        mediaItem.id.toString(), "tv",
                                        season = mediaItem.season,
                                        episode = mediaItem.episode,
                                    )
                                else
                                    Screen.Player.createRoute(mediaItem.id.toString(), "movie")
                                navController.navigate(route)
                            }
                        },
                        onDetails = { mediaItem ->
                            if (mediaItem != null) {
                                navController.navigate(Screen.Details.createRoute(mediaItem.id.toString(), mediaItem.mediaType))
                            }
                        },
                        onReturnToSidebar = onReturnToSidebar,
                        onArrowDown = { heroDown() },
                        modifier = Modifier.fillMaxSize(),
                    )
                }

                // ── Content rows (bottom 45%) ─────────────────────────────
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .fillMaxHeight(0.45f)
                        .align(Alignment.BottomStart)
                ) {
                    LazyColumn(
                        modifier = Modifier.fillMaxSize(),
                        state = outerListState,
                        contentPadding = PaddingValues(bottom = 56.dp),
                        userScrollEnabled = false,
                    ) {
                        if (continueWatching.isNotEmpty()) {
                            item {
                                ContentRow(
                                    title = stringResource(R.string.continue_watching),
                                    items = continueWatching,
                                    navController = navController,
                                    rowId = "home:Continue Watching",
                                    onSeeAll = { openMore(MoreContentKind.CONTINUE_WATCHING, cwTitle, continueWatching) },
                                    rowNav = rowNav,
                                    rows = rows,
                                    outerListState = outerListState,
                                    showProgress = true,
                                    resumeOnSelect = true,
                                    onItemFocus = { mediaItem ->
                                        pendingHeroItem = mediaItem
                                        pendingHeroResume = true
                                    },
                                    onUpToHero = { runCatching { playFocusRequester.requestFocus() } },
                                    onReturnToSidebar = onReturnToSidebar,
                                    modifier = Modifier.padding(top = 20.dp),
                                )
                            }
                        }

                        if (trendingMovies.isNotEmpty()) {
                            item {
                                ContentRow(
                                    title = stringResource(R.string.trending_movies),
                                    items = trendingMovies.take(15),
                                    navController = navController,
                                    rowId = "home:Trending Movies",
                                    onSeeAll = { openMore(MoreContentKind.TRENDING_MOVIES, trendingTitle, trendingMovies.take(15)) },
                                    rowNav = rowNav,
                                    rows = rows,
                                    outerListState = outerListState,
                                    onItemFocus = { mediaItem ->
                                        pendingHeroItem = mediaItem
                                        pendingHeroResume = false
                                    },
                                    onUpToHero = { runCatching { playFocusRequester.requestFocus() } },
                                    onReturnToSidebar = onReturnToSidebar,
                                    modifier = Modifier.padding(top = 20.dp),
                                )
                            }
                        }

                        if (forYou.isNotEmpty()) {
                            item {
                                ContentRow(
                                    title = stringResource(R.string.for_you),
                                    items = forYou.take(15),
                                    navController = navController,
                                    rowId = "home:For You",
                                    onSeeAll = { openMore(MoreContentKind.FOR_YOU, forYouTitle, forYou.take(15)) },
                                    rowNav = rowNav,
                                    rows = rows,
                                    outerListState = outerListState,
                                    onItemFocus = { mediaItem ->
                                        pendingHeroItem = mediaItem
                                        pendingHeroResume = false
                                    },
                                    onUpToHero = { runCatching { playFocusRequester.requestFocus() } },
                                    onReturnToSidebar = onReturnToSidebar,
                                    modifier = Modifier.padding(top = 20.dp),
                                )
                            }
                        }

                        if (popularMovies.isNotEmpty()) {
                            item {
                                ContentRow(
                                    title = stringResource(R.string.popular_movies),
                                    items = popularMovies.take(15),
                                    navController = navController,
                                    rowId = "home:Popular Movies",
                                    onSeeAll = { openMore(MoreContentKind.POPULAR_MOVIES, popularTitle, popularMovies.take(15)) },
                                    rowNav = rowNav,
                                    rows = rows,
                                    outerListState = outerListState,
                                    onItemFocus = { mediaItem ->
                                        pendingHeroItem = mediaItem
                                        pendingHeroResume = false
                                    },
                                    onUpToHero = { runCatching { playFocusRequester.requestFocus() } },
                                    onReturnToSidebar = onReturnToSidebar,
                                    modifier = Modifier.padding(top = 20.dp),
                                )
                            }
                        }

                        if (topRatedMovies.isNotEmpty()) {
                            item {
                                ContentRow(
                                    title = stringResource(R.string.top_rated),
                                    items = topRatedMovies.take(15),
                                    navController = navController,
                                    rowId = "home:Top Rated",
                                    onSeeAll = { openMore(MoreContentKind.TOP_RATED_MOVIES, topRatedTitle, topRatedMovies.take(15)) },
                                    rowNav = rowNav,
                                    rows = rows,
                                    outerListState = outerListState,
                                    onItemFocus = { mediaItem ->
                                        pendingHeroItem = mediaItem
                                        pendingHeroResume = false
                                    },
                                    onUpToHero = { runCatching { playFocusRequester.requestFocus() } },
                                    onReturnToSidebar = onReturnToSidebar,
                                    modifier = Modifier.padding(top = 20.dp),
                                )
                            }
                        }

                        val byw = becauseYouWatched
                        if (byw != null) {
                            item {
                                ContentRow(
                                    title = stringResource(R.string.because_you_watched, byw.first),
                                    items = byw.second.take(15),
                                    navController = navController,
                                    rowId = "home:Because You Watched",
                                    onSeeAll = { openMore(MoreContentKind.BECAUSE_YOU_WATCHED, bywTitle, byw.second.take(15)) },
                                    rowNav = rowNav,
                                    rows = rows,
                                    outerListState = outerListState,
                                    onItemFocus = { mediaItem ->
                                        pendingHeroItem = mediaItem
                                        pendingHeroResume = false
                                    },
                                    onUpToHero = { runCatching { playFocusRequester.requestFocus() } },
                                    onReturnToSidebar = onReturnToSidebar,
                                    modifier = Modifier.padding(top = 20.dp),
                                )
                            }
                        }

                        if (comingSoon.isNotEmpty()) {
                            item {
                                ContentRow(
                                    title = stringResource(R.string.coming_soon),
                                    items = comingSoon.take(15),
                                    navController = navController,
                                    rowId = "home:Coming Soon",
                                    onSeeAll = { openMore(MoreContentKind.COMING_SOON, comingSoonTitle, comingSoon.take(15)) },
                                    rowNav = rowNav,
                                    rows = rows,
                                    outerListState = outerListState,
                                    comingSoon = true,
                                    onItemFocus = { mediaItem ->
                                        pendingHeroItem = mediaItem
                                        pendingHeroResume = false
                                    },
                                    onUpToHero = { runCatching { playFocusRequester.requestFocus() } },
                                    onReturnToSidebar = onReturnToSidebar,
                                    modifier = Modifier.padding(top = 20.dp),
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Hero section
// ─────────────────────────────────────────────────────────────────────────────

@Composable
private fun HeroSection(
    item: MediaItem?,
    mediaType: String,
    isResume: Boolean,
    playFocusRequester: FocusRequester,
    detailsFocusRequester: FocusRequester,
    onPlay: (MediaItem?) -> Unit,
    onDetails: (MediaItem?) -> Unit,
    onReturnToSidebar: () -> Unit,
    onArrowDown: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val heroKey = item?.let { "${it.id}:$mediaType" } ?: "empty"

    AnimatedContent(
        targetState = heroKey,
        transitionSpec = {
            (fadeIn(tween(480)) + scaleIn(tween(480), initialScale = 1.025f)) togetherWith
                    (fadeOut(tween(180)) + scaleOut(tween(180)))
        },
        modifier = modifier,
        label = "heroTransition",
    ) { currentKey ->
        if (currentKey == "empty" || item == null) {
            Box(modifier = Modifier.fillMaxSize())
            return@AnimatedContent
        }

        val backdropUrl = item.backdropUrl.ifEmpty { item.posterUrl }
        val displayTitle = item.title
        val year = item.releaseDate.take(4).toIntOrNull() ?: 0
        val rating = item.voteAverage
        val overview = item.overview

        val heroMetadata = buildString {
            if (isResume) append("Resume")
            if (rating > 0) { if (isNotEmpty()) append("   "); append(String.format("★ %.1f", rating)) }
            if (year > 0)   { if (isNotEmpty()) append("   "); append(year) }
            if (isNotEmpty()) append("   ")
            append(if (mediaType == "series") "TV Series" else "Movie")
        }

        Box(modifier = Modifier.fillMaxSize()) {
            AsyncImage(
                model = backdropUrl,
                contentDescription = displayTitle,
                modifier = Modifier.fillMaxSize(),
                contentScale = ContentScale.Crop,
            )

            // Horizontal gradient (left side dark)
            Box(
                modifier = Modifier.fillMaxSize().background(
                    Brush.horizontalGradient(
                        colors = listOf(Color.Black, Color(0xD9000000), Color.Transparent),
                        startX = 0f, endX = 1200f,
                    )
                )
            )
            // Bottom fade to background colour
            Box(
                modifier = Modifier.fillMaxSize().background(
                    Brush.verticalGradient(
                        colors = listOf(Color.Transparent, Color.Transparent, Color(0xFF0F0F0F)),
                        startY = 0f, endY = 400f,
                    )
                )
            )

            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(start = 48.dp, top = 32.dp, end = 48.dp, bottom = 56.dp),
                verticalArrangement = Arrangement.Bottom,
            ) {
                androidx.compose.material3.Text(
                    text = displayTitle,
                    color = Color.White,
                    fontSize = 38.sp,
                    fontWeight = FontWeight.ExtraBold,
                    lineHeight = 44.sp,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    letterSpacing = (-0.7).sp,
                    modifier = Modifier.fillMaxWidth(0.65f),
                )
                Spacer(modifier = Modifier.height(10.dp))
                androidx.compose.material3.Text(
                    text = heroMetadata,
                    color = Color.White.copy(alpha = 0.7f),
                    fontSize = 14.sp,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.fillMaxWidth(0.85f),
                )
                if (overview.isNotBlank()) {
                    Spacer(modifier = Modifier.height(10.dp))
                    androidx.compose.material3.Text(
                        text = overview,
                        color = Color(0xFFD8D8D8),
                        fontSize = 14.sp,
                        lineHeight = 22.sp,
                        maxLines = 3,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.fillMaxWidth(0.75f),
                    )
                }
                Spacer(modifier = Modifier.height(18.dp))

                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    // ── Play button ── Key handlers are on the BUTTON, not a container
                    var playFocused by remember { mutableStateOf(false) }
                    var detailsFocused by remember { mutableStateOf(false) }
                    androidx.compose.material3.Button(
                        onClick = { onPlay(item) },
                        modifier = Modifier
                            .focusRequester(playFocusRequester)
                            .onFocusChanged { playFocused = it.hasFocus }
                            .border(
                                width = if (playFocused) 2.dp else 0.dp,
                                color = if (playFocused) Color.White else Color.Transparent,
                                // Match the button's own shape so the focus ring
                                // traces the rounded corners instead of looking square.
                                shape = RoundedCornerShape(28.dp),
                            )
                            .onKeyEvent { event ->
                                if (event.type != KeyEventType.KeyDown) return@onKeyEvent false
                                when (event.key) {
                                    Key.DirectionLeft  -> { onReturnToSidebar(); true }
                                    Key.DirectionRight -> { runCatching { detailsFocusRequester.requestFocus() }; true }
                                    Key.DirectionUp    -> true
                                    Key.DirectionDown  -> { onArrowDown(); true }
                                    else -> false
                                }
                            },
                        shape = RoundedCornerShape(28.dp),
                        colors = androidx.compose.material3.ButtonDefaults.buttonColors(
                            containerColor = KidsTheme.primary(context)
                        ),
                    ) {
                        androidx.compose.material3.Icon(
                            painter = painterResource(R.drawable.ic_play),
                            contentDescription = null,
                            modifier = Modifier.size(18.dp),
                        )
                        Spacer(modifier = Modifier.width(8.dp))
                        androidx.compose.material3.Text(
                            text = if (isResume) stringResource(R.string.resume) else stringResource(R.string.play)
                        )
                    }

                    // ── Details button ──
                    androidx.compose.material3.OutlinedButton(
                        onClick = { onDetails(item) },
                        modifier = Modifier
                            .focusRequester(detailsFocusRequester)
                            .onFocusChanged { detailsFocused = it.hasFocus }
                            .border(
                                width = if (detailsFocused) 2.dp else 0.dp,
                                color = if (detailsFocused) Color.White else Color.Transparent,
                                shape = RoundedCornerShape(28.dp),
                            )
                            .onKeyEvent { event ->
                                if (event.type != KeyEventType.KeyDown) return@onKeyEvent false
                                when (event.key) {
                                    Key.DirectionLeft  -> { runCatching { playFocusRequester.requestFocus() }; true }
                                    Key.DirectionRight -> true
                                    Key.DirectionUp    -> true
                                    Key.DirectionDown  -> { onArrowDown(); true }
                                    else -> false
                                }
                            },
                        shape = RoundedCornerShape(28.dp),
                    ) {
                        androidx.compose.material3.Icon(
                            painter = painterResource(R.drawable.ic_info),
                            contentDescription = null,
                            modifier = Modifier.size(18.dp),
                        )
                        Spacer(modifier = Modifier.width(8.dp))
                        androidx.compose.material3.Text(text = stringResource(R.string.details))
                    }
                }
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Content row
// ─────────────────────────────────────────────────────────────────────────────

@Composable
private fun ContentRow(
    title: String,
    items: List<MediaItem>,
    navController: NavController,
    rowId: String,
    rowNav: RowNavState,
    rows: List<RowDesc>,
    outerListState: LazyListState,
    showProgress: Boolean = false,
    resumeOnSelect: Boolean = false,
    comingSoon: Boolean = false,
    onSeeAll: (() -> Unit)? = null,
    onItemFocus: (MediaItem) -> Unit = {},
    onUpToHero: () -> Unit = {},
    onReturnToSidebar: () -> Unit = {},
    modifier: Modifier = Modifier,
) {
    val coroutineScope = rememberCoroutineScope()
    val rowListState = rememberLazyListState()
    // Track which card is focused within THIS row
    var focusedItemIndex by remember { mutableIntStateOf(-1) }

    // Register the row's horizontal scroll state with the shared navigator so
    // cross-row moves can scroll this row into view before focusing a card.
    LaunchedEffect(rowId, rowListState) {
        rowNav.registerRow(rowId, rowListState)
    }

    // RIGHT past the last card lands on the trailing `>` See All cell.
    val seeAllFromRow: (() -> Unit)? =
        if (onSeeAll != null) {
            ({ runCatching { rowNav.seeAllRequester(rowId).requestFocus() } })
        } else {
            null
        }

    Column(modifier = modifier.padding(horizontal = 48.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(bottom = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (comingSoon) {
                // Purple icon badge, exactly like Dart's _buildUpcomingSection.
                Box(
                    modifier = Modifier
                        .background(Color(0xFF7B1FA2), RoundedCornerShape(6.dp))
                        .padding(horizontal = 8.dp, vertical = 3.dp),
                ) {
                    Icon(
                        imageVector = Icons.Filled.Upcoming,
                        contentDescription = null,
                        tint = Color.White,
                        modifier = Modifier.size(14.dp),
                    )
                }
                Spacer(Modifier.width(8.dp))
            }
            Text(
                text = title,
                color = Color.White,
                fontSize = 20.sp,
                fontWeight = FontWeight.W700,
                modifier = Modifier.weight(1f),
            )
        }

        LazyRow(
            state = rowListState,
            contentPadding = PaddingValues(vertical = 4.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            // Fixed height for EVERY card type. Previously only the
            // continue-watching row had one; the poster rows wrapped their
            // content, so any change to a card's measured height (the focus
            // scale, the 0->2.dp border, a 1- vs 2-line title) re-flowed the
            // row and made everything around it jump on LEFT/RIGHT.
            modifier = (when {
                showProgress -> Modifier.height(260.dp)
                comingSoon   -> Modifier.height(ComingSoonCardRowHeight)
                else         -> Modifier.height(ContentCardRowHeight)
            }).overscroll(null),
        ) {
            items(
                count = items.size + if (onSeeAll != null) 1 else 0,
                key = { index ->
                    if (index >= items.size) "$rowId:seeall" else "$rowId:$index"
                },
            ) { index ->
                // ── Trailing `>` cell: scroll right past the last card ──────
                if (index >= items.size) {
                    SeeAllCell(
                        focusRequester = rowNav.seeAllRequester(rowId),
                        cardWidth = when {
                            comingSoon -> ComingSoonCardWidth
                            showProgress -> CWPosterWidth
                            else -> ContentCardWidth
                        },
                        cardHeight = when {
                            comingSoon -> ComingSoonCardHeight
                            showProgress -> CWPosterHeight
                            else -> ContentCardPosterHeight
                        },
                        cornerRadius = when {
                            comingSoon -> 12.dp
                            showProgress -> 8.dp
                            else -> 10.dp
                        },
                        modifier = Modifier.padding(horizontal = 7.dp),
                        onClick = {
                            rowNav.seeAllReturnRowId = rowId
                            onSeeAll?.invoke()
                        },
                        onKeyEvent = { event ->
                            if (event.type == KeyEventType.KeyDown &&
                                event.key == Key.DirectionLeft
                            ) {
                                rowNav.moveTo(
                                    rowId,
                                    (items.size - 1).coerceAtLeast(0),
                                    outerListState,
                                    coroutineScope,
                                )
                                true
                            } else {
                                rowNav.onCardKey(
                                    rowId = rowId,
                                    index = rowNav.focusedIndex(rowId),
                                    event = event,
                                    outerListState = outerListState,
                                    scope = coroutineScope,
                                    onUpToHero = onUpToHero,
                                    onReturnToSidebar = onReturnToSidebar,
                                )
                            }
                        },
                    )
                    return@items
                }

                val item = items[index]
                val isSeries = item.mediaType == "tv"

                if (comingSoon) {
                    ComingSoonCard(
                        item = item,
                        isFocused = focusedItemIndex == index,
                        focusRequester = rowNav.requester(rowId, index),
                        onClick = {
                            navController.navigate(
                                Screen.Details.createRoute(item.id.toString(), item.mediaType),
                            )
                        },
                        onFocusChanged = { focused ->
                            if (focused) {
                                focusedItemIndex = index
                                onItemFocus(item)
                            } else {
                                if (focusedItemIndex == index) focusedItemIndex = -1
                            }
                        },
                        onKeyEvent = { event ->
                            rowNav.onCardKey(
                                rowId = rowId,
                                index = index,
                                event = event,
                                outerListState = outerListState,
                                scope = coroutineScope,
                                onUpToHero = onUpToHero,
                                onReturnToSidebar = onReturnToSidebar,
                                onRightAtEnd = seeAllFromRow,
                            )
                        },
                    )
                } else if (showProgress) {
                    ContinueWatchingCard(
                        item = item,
                        isSeries = isSeries,
                        isFocused = focusedItemIndex == index,
                        focusRequester = rowNav.requester(rowId, index),
                        progress = WatchEntryCompat.progressOf(
                            item.id, item.mediaType, item.season, item.episode
                        ).takeIf { it > 0f },
                        onClick = {
                            if (resumeOnSelect) {
                                navController.navigate(
                                    Screen.Player.createRoute(
                                        item.id.toString(), item.mediaType,
                                        season = item.season, episode = item.episode,
                                    )
                                )
                            } else {
                                navController.navigate(Screen.Details.createRoute(item.id.toString(), item.mediaType))
                            }
                        },
                        onFocusChanged = { focused ->
                            if (focused) {
                                focusedItemIndex = index
                                onItemFocus(item)
                            } else {
                                if (focusedItemIndex == index) focusedItemIndex = -1
                            }
                        },
                        onKeyEvent = { event ->
                            rowNav.onCardKey(
                                rowId = rowId,
                                index = index,
                                event = event,
                                outerListState = outerListState,
                                scope = coroutineScope,
                                onUpToHero = onUpToHero,
                                onReturnToSidebar = onReturnToSidebar,
                                onRightAtEnd = seeAllFromRow,
                            )
                        },
                    )
                } else {
                    ContentCard(
                        posterUrl = item.posterUrl,
                        title = item.title,
                        rating = item.voteAverage.takeIf { it > 0 },
                        year = item.releaseDate.take(4).toIntOrNull(),
                        contentTypeLabel = if (isSeries) "TV Series" else "Movie",
                        isFocused = focusedItemIndex == index,
                        focusRequester = rowNav.requester(rowId, index),
                        progress = null,
                        onClick = {
                            if (resumeOnSelect) {
                                navController.navigate(
                                    Screen.Player.createRoute(
                                        item.id.toString(), item.mediaType,
                                        season = item.season, episode = item.episode,
                                    )
                                )
                            } else {
                                navController.navigate(Screen.Details.createRoute(item.id.toString(), item.mediaType))
                            }
                        },
                        onFocusChanged = { focused ->
                            if (focused) {
                                focusedItemIndex = index
                                onItemFocus(item)
                            } else {
                                if (focusedItemIndex == index) focusedItemIndex = -1
                            }
                        },
                        onKeyEvent = { event ->
                            rowNav.onCardKey(
                                rowId = rowId,
                                index = index,
                                event = event,
                                outerListState = outerListState,
                                scope = coroutineScope,
                                onUpToHero = onUpToHero,
                                onReturnToSidebar = onReturnToSidebar,
                                onRightAtEnd = seeAllFromRow,
                            )
                        },
                    )
                }
            }
        }
    }
}


// ─────────────────────────────────────────────────────────────────────────────
// Continue Watching card (mirrors Dart's 220×160 resume card in tv_home_screen)
// ─────────────────────────────────────────────────────────────────────────────

@Composable
private fun ContinueWatchingCard(
    item: MediaItem,
    isSeries: Boolean,
    isFocused: Boolean,
    focusRequester: FocusRequester,
    progress: Float?,
    onClick: () -> Unit,
    onFocusChanged: (Boolean) -> Unit,
    onKeyEvent: (KeyEvent) -> Boolean,
) {
    val context = LocalContext.current
    val scale by androidx.compose.animation.core.animateFloatAsState(
        targetValue = if (isFocused) 1.02f else 1f,
        animationSpec = tween(180),
        label = "cwCardScale",
    )
    val episodeName = item.episodeName
    val overview = item.overview

    Box(
        modifier = Modifier
            .padding(horizontal = 7.dp)
            // graphicsLayer, not Modifier.scale: this row looked stable only
            // because it has a hard-coded height. A layout-affecting scale
            // still resized the card and shifted its neighbours, it just had
            // nowhere to shift to vertically.
            .graphicsLayer {
                scaleX = scale
                scaleY = scale
            }
            .onKeyEvent(onKeyEvent)
            .focusRequester(focusRequester)
            .onFocusChanged { state -> onFocusChanged(state.hasFocus) }
            .focusable()
            .clickable(onClick = onClick),
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            // ── Poster (220 × 160) ─────────────────────────────────────────
            Box(
                modifier = Modifier
                    .width(CWPosterWidth)
                    .height(CWPosterHeight)
                    .clip(RoundedCornerShape(8.dp))
                    // Constant-width ring drawn last, on top of the badges and
                    // progress bar. See Modifier.focusRing for why this is not a
                    // border whose width flips 0.dp -> 2.dp.
                    .focusRing(visible = isFocused, cornerRadius = 8.dp),
            ) {
                val posterUrl = item.posterUrl
                if (posterUrl.isNotEmpty()) {
                    AsyncImage(
                        model = posterUrl,
                        contentDescription = item.title,
                        modifier = Modifier.fillMaxSize(),
                        contentScale = ContentScale.Crop,
                    )
                } else {
                    Box(
                        modifier = Modifier
                            .fillMaxSize()
                            .background(Color(0xFF242424)),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(
                            painter = painterResource(R.drawable.ic_play),
                            contentDescription = null,
                            tint = Color.White.copy(alpha = 0.4f),
                            modifier = Modifier.size(48.dp),
                        )
                    }
                }

                // Series badge (S{season}E{episode})
                if (isSeries) {
                    Box(
                        modifier = Modifier
                            .align(Alignment.TopStart)
                            .padding(6.dp)
                            .background(Color.Black.copy(alpha = 0.7f), RoundedCornerShape(4.dp))
                            .padding(horizontal = 5.dp, vertical = 1.dp),
                    ) {
                        Text(
                            text = "S${item.season}E${item.episode}",
                            color = Color.White,
                            fontSize = 10.sp,
                            fontWeight = FontWeight.Bold,
                        )
                    }
                }

                // Progress bar at the bottom of the poster
                if (progress != null) {
                    Box(
                        modifier = Modifier
                            .align(Alignment.BottomCenter)
                            .fillMaxWidth()
                            .height(4.dp),
                    ) {
                        Box(
                            modifier = Modifier
                                .fillMaxSize()
                                .background(Color(0xFF333333))
                        )
                        Box(
                            modifier = Modifier
                                .fillMaxWidth(progress.coerceIn(0f, 1f))
                                .fillMaxSize()
                                .background(KidsTheme.primary(context))
                        )
                    }
                }
            }

            // ── Title (series title for series, movie title otherwise) ────
            Spacer(Modifier.height(6.dp))
            Text(
                text = item.title,
                color = Color.White,
                fontSize = 13.sp,
                fontWeight = FontWeight.W600,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.fillMaxWidth(),
            )
            // Series caption: Season • Episode • Episode name (always shown,
            // emphasized in red when the card is focused — mirrors Dart's
            // focused resume card which surfaces S/E + episode title).
            if (isSeries) {
                Spacer(Modifier.height(2.dp))
                Text(
                    text = buildString {
                        append("S${item.season}  E${item.episode}")
                        if (episodeName.isNotEmpty()) append("  ·  $episodeName")
                    },
                    color = if (isFocused) KidsTheme.primary(context) else Color.White.copy(alpha = 0.7f),
                    fontSize = if (isFocused) 12.sp else 11.sp,
                    fontWeight = if (isFocused) FontWeight.Bold else FontWeight.Normal,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            // Overview (2 lines)
            if (overview.isNotBlank() && overview != "No description available.") {
                Spacer(Modifier.height(4.dp))
                Text(
                    text = overview,
                    color = Color.White.copy(alpha = 0.6f),
                    fontSize = 10.sp,
                    lineHeight = 13.sp,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }
    }
}
