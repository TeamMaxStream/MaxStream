package com.maxstream.app.ui.screens.more

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEvent
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onKeyEvent
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.navigation.NavController
import com.maxstream.app.data.model.MediaItem
import com.maxstream.app.di.Modules
import com.maxstream.app.ui.components.ContentCard
import com.maxstream.app.ui.components.ContentCardRowHeight
import com.maxstream.app.ui.components.ComingSoonCard
import com.maxstream.app.ui.components.ComingSoonCardRowHeight
import com.maxstream.app.ui.components.focusRing
import com.maxstream.app.ui.navigation.Screen
import com.maxstream.app.ui.theme.Background
import com.maxstream.app.ui.theme.Primary
import com.maxstream.app.ui.tv.GridDesc
import com.maxstream.app.ui.tv.GridNavState
import kotlinx.coroutines.delay

private const val GRID_ID = "more:grid"
private const val COLUMNS_POSTER = 5
private const val COLUMNS_WIDE = 6

// ─────────────────────────────────────────────────────────────────────────────
// MoreContentScreen — the full list behind a row's trailing `>` "See All" cell.
//
// Exactly like Dart's `_ComingSoonFullListScreen`: a poster grid of everything
// in that row, fetching page after page as the user scrolls DOWN, and Back
// returning to the row (with focus landing back on the `>` cell they left from).
// ─────────────────────────────────────────────────────────────────────────────

enum class MoreContentKind(val title: String, val isSeeded: Boolean) {
    // Hand-picked rows: the row already holds the whole list, so the screen
    // shows the seed as-is instead of hitting the API again.
    CONTINUE_WATCHING("Continue Watching", true),
    FOR_YOU("For You", true),
    BECAUSE_YOU_WATCHED("Because You Watched", true),

    // Paged TMDB rows: page 1..n straight from the catalog.
    TRENDING_MOVIES("Trending Movies", false),
    POPULAR_MOVIES("Popular Movies", false),
    TOP_RATED_MOVIES("Top Rated Movies", false),
    COMING_SOON("Coming Soon", false),
    TRENDING_SERIES("Trending TV Shows", false),
    POPULAR_SERIES("Popular TV Shows", false),
    TOP_RATED_SERIES("Top Rated TV Shows", false);

    companion object {
        fun from(raw: String?): MoreContentKind =
            entries.firstOrNull { it.name == raw } ?: TRENDING_MOVIES
    }
}

/** Seed data handed over by the row when it opens this screen. */
object MoreContentSeed {
    @Volatile var title: String = ""
    @Volatile var items: List<MediaItem> = emptyList()

    fun set(title: String, items: List<MediaItem>) {
        this.title = title
        this.items = items
    }
}

private suspend fun fetchPage(kind: MoreContentKind, page: Int): List<MediaItem> {
    val repo = Modules.catalogRepository
    return when (kind) {
        MoreContentKind.TRENDING_MOVIES -> repo.trendingMovies(page)
        MoreContentKind.POPULAR_MOVIES -> repo.popularMovies(page)
        MoreContentKind.TOP_RATED_MOVIES -> repo.topRatedMovies(page)
        MoreContentKind.TRENDING_SERIES -> repo.trendingSeries(page)
        MoreContentKind.POPULAR_SERIES -> repo.popularSeries(page)
        MoreContentKind.TOP_RATED_SERIES -> repo.topRatedSeries(page)
        MoreContentKind.COMING_SOON ->
            (repo.upcomingMovies(page) + repo.onTheAirSeries(page))
                .sortedBy { it.releaseDate.ifBlank { "9999-99-99" } }
        else -> emptyList()
    }
}

private fun dedupe(list: List<MediaItem>): List<MediaItem> {
    val seen = HashSet<String>()
    return list.filter { seen.add("${it.mediaType}:${it.id}") }
}

@Composable
fun MoreContentScreen(
    kind: MoreContentKind,
    navController: NavController,
    active: Boolean = true,
    onReturnToSidebar: () -> Unit = {},
    restoreFocusKey: Int = 0,
) {
    val wide = kind == MoreContentKind.COMING_SOON
    val columns = if (wide) COLUMNS_WIDE else COLUMNS_POSTER
    val cellHeight = if (wide) ComingSoonCardRowHeight else ContentCardRowHeight

    val scope = rememberCoroutineScope()
    val gridNav = remember(columns) { GridNavState(columns) }
    val gridState = rememberLazyGridState()

    var items by remember { mutableStateOf(emptyList<MediaItem>()) }
    var loading by remember { mutableStateOf(true) }
    var loadingMore by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var page by remember { mutableIntStateOf(1) }
    var hasMore by remember { mutableStateOf(false) }
    var seeded by remember { mutableStateOf(false) }
    var reloadTick by remember { mutableIntStateOf(0) }

    // Seed rows show what the row handed over; paged rows fetch page 1.
    LaunchedEffect(kind, reloadTick) {
        try {
            loading = true
            error = null
            if (kind.isSeeded) {
                items = dedupe(MoreContentSeed.items)
                hasMore = false
            } else {
                val first = fetchPage(kind, 1)
                items = dedupe(first)
                page = 1
                hasMore = first.isNotEmpty()
            }
        } catch (e: Exception) {
            error = e.message ?: "Failed to load"
        } finally {
            loading = false
        }
    }

    // Scroll near the bottom → fetch the next page (infinite scroll).
    LaunchedEffect(kind) {
        if (kind.isSeeded) return@LaunchedEffect
        snapshotFlow { gridState.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: -1 }
            .collect { lastIndex ->
                if (!loading && !loadingMore && hasMore && items.isNotEmpty() &&
                    lastIndex >= items.size - columns * 2
                ) {
                    loadingMore = true
                    try {
                        val next = fetchPage(kind, page + 1)
                        if (next.isEmpty()) {
                            hasMore = false
                        } else {
                            page++
                            items = dedupe(items + next)
                        }
                    } catch (_: Exception) {
                        hasMore = false
                    } finally {
                        loadingMore = false
                    }
                }
            }
    }

    // Keep the navigator in sync with the visible grid.
    val grids = remember(items.size) {
        if (items.isNotEmpty()) listOf(GridDesc(GRID_ID, items.size)) else emptyList()
    }
    gridNav.setGrids(grids)
    gridNav.clearMissingGrids()
    LaunchedEffect(items.size) {
        if (items.isNotEmpty()) gridNav.registerGrid(GRID_ID, gridState)
    }
    DisposableEffect(Unit) { onDispose { gridNav.unregisterGrid(GRID_ID) } }

    // Seed focus the first time content lands.
    LaunchedEffect(active, loading, items.size) {
        if (!active || loading || seeded || items.isEmpty()) return@LaunchedEffect
        seeded = true
        gridNav.focusCard(GRID_ID, gridNav.focusedIndex(GRID_ID), null)
    }

    // Deep-nav return (details/player popped while this screen is on top):
    // put focus back on the card the user left from.
    LaunchedEffect(active, restoreFocusKey, items.size) {
        if (!active || restoreFocusKey <= 0 || items.isEmpty()) return@LaunchedEffect
        gridNav.focusCard(GRID_ID, gridNav.focusedIndex(GRID_ID), null)
    }

    val displayTitle = MoreContentSeed.title.ifBlank { kind.title }

    fun onCardKey(index: Int, event: KeyEvent): Boolean = gridNav.onCardKey(
        gridId = GRID_ID,
        index = index,
        event = event,
        outerListState = null,
        scope = scope,
        onReturnToKeyboard = { onReturnToSidebar() },
        onReturnToSidebar = onReturnToSidebar,
    )

    fun onCardClick(item: MediaItem) {
        navController.navigate(Screen.Details.createRoute(item.id.toString(), item.mediaType))
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Background)
            // Not the top destination (player/details above) → non-focusable
            // so no hidden tile can ever be activated by an OK press.
            .then(
                if (active) Modifier
                else Modifier
                    .focusProperties { canFocus = false }
                    .onPreviewKeyEvent { true }
            )
    ) {
        Column(modifier = Modifier.fillMaxSize()) {
            Text(
                text = displayTitle,
                color = Color.White,
                fontSize = 28.sp,
                fontWeight = FontWeight.ExtraBold,
                modifier = Modifier
                    .padding(top = 48.dp)
                    .padding(horizontal = 48.dp),
            )
            Spacer(Modifier.height(16.dp))

            when {
                loading -> Box(
                    Modifier.fillMaxWidth().weight(1f),
                    contentAlignment = Alignment.Center,
                ) {
                    CircularProgressIndicator(color = Primary)
                }

                error != null -> Box(
                    Modifier.fillMaxWidth().weight(1f),
                    contentAlignment = Alignment.Center,
                ) {
                    RetryBlock(
                        message = "Error: $error",
                        onRetry = { reloadTick++ },
                    )
                }

                items.isEmpty() -> Box(
                    Modifier.fillMaxWidth().weight(1f),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        text = "Nothing here yet",
                        color = Color.White.copy(alpha = 0.6f),
                        fontSize = 16.sp,
                    )
                }

                else -> {
                    var focusedIndex by remember { mutableIntStateOf(-1) }

                    LazyVerticalGrid(
                        state = gridState,
                        columns = GridCells.Fixed(columns),
                        modifier = Modifier.fillMaxSize(),
                        contentPadding = PaddingValues(start = 48.dp, end = 48.dp, bottom = 56.dp),
                        verticalArrangement = Arrangement.spacedBy(14.dp),
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        items(
                            count = items.size + if (loadingMore) 1 else 0,
                            key = { index ->
                                if (index >= items.size) "more:loading"
                                else "${items[index].mediaType}:${items[index].id}"
                            },
                        ) { index ->
                            // Footer: the next page is on the way.
                            if (index >= items.size) {
                                Box(
                                    Modifier.height(cellHeight).fillMaxWidth(),
                                    contentAlignment = Alignment.Center,
                                ) {
                                    CircularProgressIndicator(color = Primary)
                                }
                                return@items
                            }

                            val item = items[index]
                            // Fixed-height cell: identical cells, no re-flow
                            // when focus moves between cards.
                            Box(Modifier.height(cellHeight)) {
                                if (wide) {
                                    ComingSoonCard(
                                        item = item,
                                        isFocused = focusedIndex == index,
                                        focusRequester = gridNav.requester(GRID_ID, index),
                                        onClick = { onCardClick(item) },
                                        onFocusChanged = { focused ->
                                            if (focused) focusedIndex = index
                                            else if (focusedIndex == index) focusedIndex = -1
                                        },
                                        onKeyEvent = { onCardKey(index, it) },
                                    )
                                } else {
                                    ContentCard(
                                        posterUrl = item.posterUrl,
                                        title = item.title,
                                        rating = item.voteAverage.takeIf { it > 0 },
                                        year = item.releaseDate.take(4).toIntOrNull(),
                                        contentTypeLabel = if (item.mediaType == "tv") "TV Series" else "Movie",
                                        isFocused = focusedIndex == index,
                                        focusRequester = gridNav.requester(GRID_ID, index),
                                        onClick = { onCardClick(item) },
                                        onFocusChanged = { focused ->
                                            if (focused) focusedIndex = index
                                            else if (focusedIndex == index) focusedIndex = -1
                                        },
                                        onKeyEvent = { onCardKey(index, it) },
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Retry block — shown when the first page fails to load. Focusable so the
// D-pad still has somewhere to land (Back never depends on it).
// ─────────────────────────────────────────────────────────────────────────────

@Composable
private fun RetryBlock(message: String, onRetry: () -> Unit) {
    var focused by remember { mutableStateOf(false) }

    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(
            text = message,
            color = Color(0xFFCF6679),
            fontSize = 16.sp,
        )
        Spacer(Modifier.height(16.dp))
        Box(
            modifier = Modifier
                .onFocusChanged { focused = it.hasFocus }
                .onKeyEvent { event ->
                    if (event.type == KeyEventType.KeyDown &&
                        (event.key == Key.Enter || event.key == Key.DirectionCenter)
                    ) {
                        onRetry(); true
                    } else false
                }
                .focusable()
                .clickable(onClick = onRetry)
                .clip(RoundedCornerShape(10.dp))
                .background(if (focused) Color.White else Color(0x1AFFFFFF))
                .focusRing(visible = focused, cornerRadius = 10.dp)
                .padding(horizontal = 26.dp, vertical = 12.dp),
        ) {
            Text(
                text = "Try again",
                color = if (focused) Color.Black else Color.White,
                fontWeight = FontWeight.Bold,
                fontSize = 15.sp,
            )
        }
    }
}
