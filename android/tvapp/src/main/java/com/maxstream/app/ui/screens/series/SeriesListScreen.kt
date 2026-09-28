package com.maxstream.app.ui.screens.series

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.OverscrollEffect
import androidx.compose.foundation.overscroll.modifier.overscrollEffect
import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.livedata.observeAsState
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavController
import coil.compose.AsyncImage
import com.maxstream.app.R
import com.maxstream.app.data.model.MediaItem
import com.maxstream.app.ui.components.ContentCard
import com.maxstream.app.ui.navigation.Screen
import com.maxstream.app.ui.theme.Background
import com.maxstream.app.ui.tv.RowDesc
import com.maxstream.app.ui.tv.RowNavState
import com.maxstream.app.ui.viewmodel.HomeViewModel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

// ─────────────────────────────────────────────────────────────────────────────
// SeriesListScreen  (Tab 3)
//
// Mirrors Dart TvSeriesListScreen exactly:
//  - Hero banner (backdrop, title, rating, year, genres, overview, Play + Details)
//  - Three horizontal content rows: Trending / Popular / Top Rated TV Shows
//  - D-pad: LEFT on hero → sidebar, DOWN on hero → first row,
//            UP on first row → hero play button, LEFT on first card → sidebar
// ─────────────────────────────────────────────────────────────────────────────

@Composable
fun SeriesListScreen(
    navController: NavController,
    onReturnToSidebar: () -> Unit = {},
    isVisible: Boolean = true,
    focusKey: Int = 0,
    restoreFocusKey: Int = 0,
) {
    val viewModel: HomeViewModel = viewModel()
    val trendingSeries   by viewModel.trendingSeries.observeAsState(emptyList())
    val popularSeries    by viewModel.popularSeries.observeAsState(emptyList())
    val topRatedSeries   by viewModel.topRatedSeries.observeAsState(emptyList())

    var heroItem        by remember { mutableStateOf<MediaItem?>(null) }
    var pendingHeroItem by remember { mutableStateOf<MediaItem?>(null) }
    var isEntryVisible  by remember { mutableStateOf(false) }

    val playFocusRequester    = remember { FocusRequester() }
    val detailsFocusRequester = remember { FocusRequester() }
    val coroutineScope = rememberCoroutineScope()

    // D-pad navigation across the content rows (shared with every SeriesContentRow).
    val outerListState = rememberLazyListState()
    val rowNav = remember { RowNavState() }

    // Ordered list of visible rows — must mirror the LazyColumn item order.
    val rows = remember(trendingSeries, popularSeries, topRatedSeries) {
        buildList {
            if (trendingSeries.isNotEmpty()) add(RowDesc("series:Trending", trendingSeries.size.coerceAtMost(15)))
            if (popularSeries.isNotEmpty()) add(RowDesc("series:Popular", popularSeries.size.coerceAtMost(15)))
            if (topRatedSeries.isNotEmpty()) add(RowDesc("series:Top Rated", topRatedSeries.size.coerceAtMost(15)))
        }
    }
    rowNav.setRows(rows)
    rowNav.clearMissingRows()

    // Seed hero from first trending series item
    LaunchedEffect(trendingSeries) {
        if (heroItem == null && trendingSeries.isNotEmpty()) {
            heroItem = trendingSeries.first()
        }
    }

    // Hero debounce — mirrors Dart's Timer(400ms) _queueHero pattern.
    // When a card is focused, we wait 400ms before updating the hero.
    // If another card is focused within that window, the timer resets.
    LaunchedEffect(pendingHeroItem) {
        val item = pendingHeroItem ?: return@LaunchedEffect
        delay(400)
        heroItem = item
    }

    // Focus seed on tab visible — first attempt is IMMEDIATE (no pre-delay);
    // then keeps retrying across frames so the hero Play button actually gets
    // focus. The tab enters via AnimatedVisibility (fade-in), so the Play
    // button may not be composed on the first frame even when heroItem is set —
    // a single requestFocus would be a silent no-op and the user would see no
    // focus when coming from the sidebar. Retrying mirrors Dart's
    // _restoreInitialFocus (double post-frame callback).
    // Also re-runs when focus returns from the sidebar (focusKey bump).
    LaunchedEffect(isVisible, focusKey) {
        if (!isVisible) return@LaunchedEffect
        isEntryVisible = true
        var attempt = 0
        while (attempt < 18) {
            if (attempt > 0) delay(50L * attempt)
            runCatching { playFocusRequester.requestFocus() }
            if (attempt >= 4 && heroItem != null) return@LaunchedEffect
            attempt++
        }
    }

    // Deep-nav return: details/player overlay popped. Row/card FocusRequesters
    // are still valid (the shell never left composition), so jump back to the
    // exact row the user left; fall back to the hero if no row was active.
    LaunchedEffect(isVisible, restoreFocusKey) {
        if (!isVisible || restoreFocusKey <= 0) return@LaunchedEffect
        val rowId = rowNav.activeRowId
        if (rowId != null && rowNav.count(rowId) > 0) {
            rowNav.moveTo(rowId, rowNav.focusedIndex(rowId), outerListState, coroutineScope)
        } else {
            runCatching { playFocusRequester.requestFocus() }
        }
    }

    fun heroDown() {
        rowNav.focusFirstRow(outerListState, coroutineScope)
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Background)
    ) {
        AnimatedVisibility(
            visible = isEntryVisible,
            enter = fadeIn(tween(330)) + scaleIn(tween(330), initialScale = 0.97f),
            exit  = fadeOut(tween(180)),
        ) {
            Box(modifier = Modifier.fillMaxSize()) {

                // ── Hero (top 55%) ─────────────────────────────────────────
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .fillMaxHeight(0.55f)
                        .align(Alignment.TopStart)
                ) {
                    SeriesHeroSection(
                        item = heroItem,
                        playFocusRequester    = playFocusRequester,
                        detailsFocusRequester = detailsFocusRequester,
                        onPlay = { item ->
                            item ?: return@SeriesHeroSection
                            navController.navigate(
                                Screen.Player.createRoute(item.id.toString(), "tv", 1, 1)
                            )
                        },
                        onDetails = { item ->
                            item ?: return@SeriesHeroSection
                            navController.navigate(Screen.Details.createRoute(item.id.toString(), item.mediaType))
                        },
                        onReturnToSidebar = onReturnToSidebar,
                        onArrowDown = { heroDown() },
                        modifier = Modifier.fillMaxSize(),
                    )
                }

                // ── Content rows (bottom 45%) ──────────────────────────────
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
                        if (trendingSeries.isNotEmpty()) {
                            item {
                                SeriesContentRow(
                                    title = "Trending TV Shows",
                                    items = trendingSeries.take(15),
                                    navController = navController,
                                    rowId = "series:Trending",
                                    rowNav = rowNav,
                                    rows = rows,
                                    outerListState = outerListState,
                                    onItemFocus = { pendingHeroItem = it },
                                    onUpToHero = { runCatching { playFocusRequester.requestFocus() } },
                                    onReturnToSidebar = onReturnToSidebar,
                                    modifier = Modifier.padding(top = 20.dp),
                                )
                            }
                        }
                        if (popularSeries.isNotEmpty()) {
                            item {
                                SeriesContentRow(
                                    title = "Popular TV Shows",
                                    items = popularSeries.take(15),
                                    navController = navController,
                                    rowId = "series:Popular",
                                    rowNav = rowNav,
                                    rows = rows,
                                    outerListState = outerListState,
                                    onItemFocus = { pendingHeroItem = it },
                                    onUpToHero = { runCatching { playFocusRequester.requestFocus() } },
                                    onReturnToSidebar = onReturnToSidebar,
                                    modifier = Modifier.padding(top = 20.dp),
                                )
                            }
                        }
                        if (topRatedSeries.isNotEmpty()) {
                            item {
                                SeriesContentRow(
                                    title = "Top Rated TV Shows",
                                    items = topRatedSeries.take(15),
                                    navController = navController,
                                    rowId = "series:Top Rated",
                                    rowNav = rowNav,
                                    rows = rows,
                                    outerListState = outerListState,
                                    onItemFocus = { pendingHeroItem = it },
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
// Hero section — series backdrop with title, metadata, Play + Details buttons
// ─────────────────────────────────────────────────────────────────────────────

private val GENRE_NAMES = mapOf(
    28 to "Action", 12 to "Adventure", 16 to "Animation", 35 to "Comedy",
    80 to "Crime", 99 to "Documentary", 18 to "Drama", 10751 to "Family",
    14 to "Fantasy", 36 to "History", 27 to "Horror", 10402 to "Music",
    9648 to "Mystery", 10749 to "Romance", 878 to "Sci-Fi", 53 to "Thriller",
    10752 to "War", 37 to "Western", 10759 to "Action & Adventure",
    10762 to "Kids", 10763 to "News", 10764 to "Reality",
    10765 to "Sci-Fi & Fantasy", 10766 to "Soap", 10767 to "Talk",
    10768 to "War & Politics",
)

@Composable
private fun SeriesHeroSection(
    item: MediaItem?,
    playFocusRequester: FocusRequester,
    detailsFocusRequester: FocusRequester,
    onPlay: (MediaItem?) -> Unit,
    onDetails: (MediaItem?) -> Unit,
    onReturnToSidebar: () -> Unit,
    onArrowDown: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val heroKey = item?.id?.toString() ?: "empty"

    AnimatedContent(
        targetState = heroKey,
        transitionSpec = {
            (fadeIn(tween(480)) + scaleIn(tween(480), initialScale = 1.025f)) togetherWith
                    (fadeOut(tween(180)) + scaleOut(tween(180)))
        },
        modifier = modifier,
        label = "seriesHeroTransition",
    ) { _ ->
        if (item == null) { Box(modifier = Modifier.fillMaxSize()); return@AnimatedContent }

        val backdropUrl = item.backdropUrl.ifEmpty { item.posterUrl }
        val year = item.releaseDate.take(4).toIntOrNull()
        val genres = item.genreIds.take(3).mapNotNull { GENRE_NAMES[it] }.joinToString("  •  ")
        val metadata = buildString {
            if (item.voteAverage > 0) append("★ ${String.format("%.1f", item.voteAverage)}")
            if (year != null) { if (isNotEmpty()) append("   "); append(year) }
            if (genres.isNotEmpty()) { if (isNotEmpty()) append("   "); append(genres) }
        }

        Box(modifier = Modifier.fillMaxSize()) {
            // Backdrop
            AsyncImage(
                model = backdropUrl,
                contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize(),
                placeholder = painterResource(R.drawable.ic_launcher_foreground),
                error = painterResource(R.drawable.ic_launcher_foreground),
            )
            // Left gradient
            Box(
                modifier = Modifier.fillMaxSize().background(
                    Brush.horizontalGradient(
                        0f to Color.Black,
                        0.35f to Color(0xD9000000),
                        0.78f to Color.Transparent,
                    )
                )
            )
            // Bottom gradient
            Box(
                modifier = Modifier.fillMaxSize().background(
                    Brush.verticalGradient(
                        0.42f to Color.Transparent,
                        1f to Color(0xFF080808),
                    )
                )
            )
            // Text + buttons
            Column(
                modifier = Modifier
                    .align(Alignment.BottomStart)
                    .fillMaxWidth(0.65f)
                    .padding(start = 48.dp, bottom = 32.dp, end = 24.dp),
                verticalArrangement = Arrangement.spacedBy(0.dp),
            ) {
                androidx.compose.material3.Text(
                    text = item.title,
                    color = Color.White,
                    fontSize = 38.sp,
                    fontWeight = FontWeight.ExtraBold,
                    lineHeight = 42.sp,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    letterSpacing = (-0.7).sp,
                )
                Spacer(Modifier.height(10.dp))
                if (metadata.isNotEmpty()) {
                    androidx.compose.material3.Text(
                        text = metadata,
                        color = Color.White.copy(alpha = 0.7f),
                        fontSize = 14.sp,
                        fontWeight = FontWeight.SemiBold,
                    )
                }
                if (item.overview.isNotBlank()) {
                    Spacer(Modifier.height(10.dp))
                    androidx.compose.material3.Text(
                        text = item.overview,
                        color = Color(0xFFD8D8D8),
                        fontSize = 14.sp,
                        lineHeight = 22.sp,
                        maxLines = 3,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                Spacer(Modifier.height(18.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    var playFocused by remember { mutableStateOf(false) }
                    var detailsFocused by remember { mutableStateOf(false) }
                    // Play button
                    androidx.compose.material3.Button(
                        onClick = { onPlay(item) },
                        modifier = Modifier
                            .focusRequester(playFocusRequester)
                            .onFocusChanged { playFocused = it.hasFocus }
                            .border(
                                width = if (playFocused) 2.dp else 0.dp,
                                color = if (playFocused) Color.White else Color.Transparent,
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
                            containerColor = Color(0xFFE50914)
                        ),
                    ) {
                        androidx.compose.material3.Icon(
                            painter = painterResource(R.drawable.ic_play),
                            contentDescription = null,
                            modifier = Modifier.size(18.dp),
                        )
                        Spacer(Modifier.width(8.dp))
                        androidx.compose.material3.Text(stringResource(R.string.play))
                    }
                    // Details button
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
                        Spacer(Modifier.width(8.dp))
                        androidx.compose.material3.Text(stringResource(R.string.details))
                    }
                }
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Content row — horizontal LazyRow of series cards
// ─────────────────────────────────────────────────────────────────────────────

@Composable
private fun SeriesContentRow(
    title: String,
    items: List<MediaItem>,
    navController: NavController,
    rowId: String,
    rowNav: RowNavState,
    rows: List<RowDesc>,
    outerListState: LazyListState,
    onItemFocus: (MediaItem) -> Unit = {},
    onUpToHero: () -> Unit = {},
    onReturnToSidebar: () -> Unit = {},
    modifier: Modifier = Modifier,
) {
    val coroutineScope = rememberCoroutineScope()
    val rowListState = rememberLazyListState()
    var focusedItemIndex by remember { mutableIntStateOf(-1) }

    // Register this row's horizontal scroll state with the shared navigator.
    LaunchedEffect(rowId, rowListState) {
        rowNav.registerRow(rowId, rowListState)
    }

    Column(modifier = modifier.padding(horizontal = 48.dp)) {
        androidx.compose.material3.Text(
            text = title,
            color = Color.White,
            fontSize = 20.sp,
            fontWeight = FontWeight.W700,
            modifier = Modifier.padding(bottom = 12.dp),
        )
        LazyRow(
            state = rowListState,
            contentPadding = PaddingValues(vertical = 4.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            modifier = Modifier.overscrollEffect(OverscrollEffect.None),
        ) {
            items(
                count = items.size,
                key   = { index -> "$rowId:$index" },
            ) { index ->
                val item = items[index]
                ContentCard(
                    posterUrl  = item.posterUrl,
                    title      = item.title,
                    rating     = item.voteAverage.takeIf { it > 0 },
                    year       = item.releaseDate.take(4).toIntOrNull(),
                    contentTypeLabel = "TV Series",
                    isFocused  = focusedItemIndex == index,
                    focusRequester = rowNav.requester(rowId, index),
                    onClick    = {
                        navController.navigate(Screen.Details.createRoute(item.id.toString(), item.mediaType))
                    },
                    onFocusChanged = { focused ->
                        if (focused) {
                            focusedItemIndex = index
                            onItemFocus(item)
                        } else if (focusedItemIndex == index) focusedItemIndex = -1
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
                        )
                    },
                )
            }
        }
    }
}
