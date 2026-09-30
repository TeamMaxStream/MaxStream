package com.maxstream.app.ui.screens.search

import androidx.compose.foundation.OverscrollEffect
import androidx.compose.foundation.overscroll
import androidx.compose.foundation.background
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
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.navigation.NavController
import com.maxstream.app.R
import com.maxstream.app.data.model.MediaItem
import com.maxstream.app.di.Modules
import com.maxstream.app.util.isKidFriendly
import com.maxstream.app.util.isKidsProfile
import com.maxstream.app.ui.components.ContentCard
import com.maxstream.app.ui.components.TvKeyboard
import com.maxstream.app.ui.navigation.Screen
import com.maxstream.app.ui.tv.GridDesc
import com.maxstream.app.ui.tv.GridNavState
import com.maxstream.app.ui.tv.TvKeyboardFocusManager
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import androidx.compose.ui.platform.LocalContext

private const val COLUMNS = 5

// ─────────────────────────────────────────────────────────────────────────────
// SearchScreen
// Matches Dart TvSearchScreen:
//  - Left panel: keyboard
//  - Right panel: "Discover" grid when no query (trending + popular mix)
//                 "Movies" + "TV Series" sections when searching
//  - D-pad: RIGHT from keyboard's last key → first result card
//           LEFT on first column / UP on first row → back to keyboard
//           ESC/Back from a card → sidebar
// ─────────────────────────────────────────────────────────────────────────────

@Composable
fun SearchScreen(
    navController: NavController,
    onReturnToSidebar: () -> Unit = {},
    isVisible: Boolean = true,
    focusKey: Int = 0,
    restoreFocusKey: Int = 0,
) {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current

    // ── State ──────────────────────────────────────────────────────────────
    var query       by remember { mutableStateOf("") }
    var discoverItems by remember { mutableStateOf<List<MediaItem>>(emptyList()) }
    var movieResults  by remember { mutableStateOf<List<MediaItem>>(emptyList()) }
    var seriesResults by remember { mutableStateOf<List<MediaItem>>(emptyList()) }
    var isSearching   by remember { mutableStateOf(false) }
    var searchError   by remember { mutableStateOf<String?>(null) }
    var debounceJob   by remember { mutableStateOf<Job?>(null) }

    // ── Focus ──────────────────────────────────────────────────────────────
    val keyboardFocusManager  = remember { TvKeyboardFocusManager() }
    val keyboardFocusRequester = remember { FocusRequester() }
    val gridNav = remember { GridNavState(COLUMNS) }
    val resultsListState = rememberLazyListState()
    var focusedKey by remember { mutableStateOf<String?>(null) }

    val showingResults =
        query.trim().length >= 2 && !isSearching &&
        (movieResults.isNotEmpty() || seriesResults.isNotEmpty())

    // Right panel rendered as a single LazyColumn of rows (mirrors the Dart
    // CustomScrollView + slivers). Each section contributes a section header
    // item followed by one item per row of cards, so the whole panel scrolls
    // as one lazy list — like the watchlist grid — instead of a fully-composed
    // fixed-height nested grid (which let focus land on invisible off-screen
    // cards because requestFocus always succeeded).
    val (panel, grids) = remember(
        showingResults, isSearching, query.trim(),
        movieResults.size, seriesResults.size, discoverItems.size,
    ) {
        buildPanel(
            showingResults = showingResults,
            isSearching = isSearching,
            query = query.trim(),
            movieResults = movieResults,
            seriesResults = seriesResults,
            discoverItems = discoverItems,
        )
    }
    gridNav.setGrids(grids)
    gridNav.clearMissingGrids()

    // ── Load discover content on first entry (mix of trending + popular) ──
    // Each feed is fetched independently so one failing endpoint can no longer
    // drop the entire Discover panel (which made the keyboard's RIGHT / DONE
    // appear to do nothing because there was no grid to move into).
    LaunchedEffect(Unit) {
        val seen = mutableSetOf<String>()
        val items = mutableListOf<MediaItem>()
        fun add(list: List<MediaItem>) {
            items.addAll(list)
        }
        repeat(3) {
            runCatching { add(Modules.catalogRepository.trendingMovies().take(12)) }
            runCatching { add(Modules.catalogRepository.trendingSeries().take(12)) }
            runCatching { add(Modules.catalogRepository.popularMovies().take(12)) }
            runCatching { add(Modules.catalogRepository.popularSeries().take(12)) }
            runCatching { add(Modules.catalogRepository.topRatedMovies().take(12)) }
            runCatching { add(Modules.catalogRepository.topRatedSeries().take(12)) }
            if (items.isNotEmpty()) return@repeat
        }
        // Mix and deduplicate by id+type, same as Dart
        discoverItems = items.filter { item ->
            seen.add("${item.mediaType}:${item.id}")
        }
    }

    // ── Debounced search ───────────────────────────────────────────────────
    LaunchedEffect(query) {
        debounceJob?.cancel()
        if (query.trim().length < 2) {
            movieResults = emptyList(); seriesResults = emptyList()
            searchError = null; isSearching = false
            return@LaunchedEffect
        }
        debounceJob = scope.launch {
            delay(400)
            if (!isActive) return@launch
            isSearching = true; searchError = null
            try {
                val results = Modules.catalogRepository.search(query.trim())
                val filtered = if (isKidsProfile(context)) {
                    results.filter { isKidFriendly(it.genreIds) }
                } else results
                movieResults  = filtered.filter { it.mediaType == "movie" }
                seriesResults = filtered.filter { it.mediaType == "tv" }
            } catch (e: Exception) {
                searchError = e.message
                movieResults = emptyList(); seriesResults = emptyList()
            } finally {
                isSearching = false
            }
        }
    }

    // ── Focus seed on tab visible / focus returns from the sidebar ─────────
    // Re-seeds the keyboard so navigation never parks on the invisible box
    // when returning to the same tab. First attempt is immediate.
    LaunchedEffect(isVisible, focusKey) {
        if (!isVisible) return@LaunchedEffect
        var attempt = 0
        while (attempt < 6) {
            if (attempt > 0) delay(50L * attempt)
            // requestFocus() throws while the node is unattached, so retry on
            // exception until the keyboard node is composed (isSuccess == no throw).
            val ok = runCatching { keyboardFocusRequester.requestFocus() }.isSuccess
            if (ok) return@LaunchedEffect
            attempt++
        }
    }

    // Deep-nav return: details/player overlay popped. The shell (and keyboard /
    // grid focus manager) never left composition, so put focus back on whatever
    // the user was on — the grid cards if they were on results, else the keyboard.
    LaunchedEffect(isVisible, restoreFocusKey) {
        if (!isVisible || restoreFocusKey <= 0) return@LaunchedEffect
        if (!keyboardFocusManager.isKeyboardActive) {
            val first = gridNav.grids.firstOrNull { it.count > 0 }
            if (first != null) gridNav.focusFirstCard(first.id, resultsListState, scope)
        } else {
            runCatching { keyboardFocusRequester.requestFocus() }
        }
    }

    fun returnToKeyboard() {
        keyboardFocusManager.activateKeyboard()
        runCatching { keyboardFocusRequester.requestFocus() }
    }

    fun moveToResults() {
        keyboardFocusManager.focusOnContent()
        val first = gridNav.grids.firstOrNull { it.count > 0 }
        if (first != null) gridNav.focusFirstCard(first.id, resultsListState, scope)
    }

    fun cardKey(gridId: String, index: Int) = "$gridId:$index"

    // ── Layout ─────────────────────────────────────────────────────────────
    Row(
        modifier = Modifier
            .fillMaxSize()
            .background(
                Brush.linearGradient(
                    colors = listOf(Color(0xF20A0D13), Color(0xE6111620), Color(0xFF050608))
                )
            )
    ) {
        // ── Left panel: keyboard ───────────────────────────────────────────
        Column(
            modifier = Modifier
                .width(480.dp)
                .fillMaxHeight()
                .padding(horizontal = 24.dp, vertical = 16.dp),
        ) {
            Text(
                text = "Search",
                color = Color.White,
                fontSize = 34.sp,
                fontWeight = FontWeight.W800,
            )
            Spacer(Modifier.height(4.dp))
            Text(
                text = "Find movies and series",
                color = Color.White.copy(alpha = 0.55f),
                fontSize = 15.sp,
            )
            Spacer(Modifier.height(24.dp))

            TvKeyboard(
                onInput  = { text -> query = text },
                onSubmit = {
                    // Mirrors Dart _submitSearch: with an empty query DONE is a
                    // no-op; otherwise move focus into the results grid (the
                    // search itself is already live via the debounce).
                    if (query.trim().isNotEmpty()) moveToResults()
                },
                initialText = query,
                focusManager = keyboardFocusManager,
                focusRequester = keyboardFocusRequester,
                onMoveRight = { moveToResults() },
                onMoveLeft = onReturnToSidebar,
                modifier = Modifier.fillMaxWidth(),
            )
        }

        Spacer(Modifier.width(24.dp))

        // ── Right panel: results / discover ───────────────────────────────
        LazyColumn(
            state = resultsListState,
            modifier = Modifier
                .weight(1f)
                .fillMaxHeight()
                .padding(end = 34.dp, top = 24.dp, bottom = 24.dp)
                .overscroll(null),
            contentPadding = PaddingValues(bottom = 56.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            when {
                isSearching -> item {
                    Box(Modifier.fillMaxWidth().height(280.dp), contentAlignment = Alignment.Center) {
                        CircularProgressIndicator(color = Color(0xFFE50914), strokeWidth = 3.dp)
                    }
                }

                searchError != null -> item {
                    SearchMessage(
                        icon = R.drawable.ic_search,
                        text = "Search unavailable. Please try again."
                    )
                }

                query.trim().length >= 2 && movieResults.isEmpty() && seriesResults.isEmpty() ->
                    item {
                        SearchMessage(
                            icon = R.drawable.ic_search,
                            text = "No matches for \"${query.trim()}\""
                        )
                    }

                else -> {
                    items(
                        count = panel.size,
                        key = { i -> panel[i].key },
                    ) { i ->
                        when (val entry = panel[i]) {
                            is PanelTitle -> Text(
                                text = entry.text,
                                color = Color.White,
                                fontSize = 29.sp,
                                fontWeight = FontWeight.W800,
                                modifier = Modifier.padding(bottom = 8.dp),
                            )

                            is PanelSection -> SectionHeader(
                                title = entry.title,
                                modifier = Modifier.padding(top = 18.dp, bottom = 4.dp),
                            )

                            is PanelRow -> Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.spacedBy(12.dp),
                            ) {
                                entry.items.forEachIndexed { col, item ->
                                    val index = entry.startIndex + col
                                    ContentCard(
                                        modifier = Modifier.weight(1f),
                                        posterUrl = item.posterUrl,
                                        title = item.title,
                                        rating = item.voteAverage.takeIf { it > 0 },
                                        year = item.releaseDate.take(4).toIntOrNull(),
                                        contentTypeLabel = if (item.mediaType == "tv") "TV Series" else "Movie",
                                        isFocused = focusedKey == cardKey(entry.gridId, index),
                                        focusRequester = gridNav.requester(entry.gridId, index),
                                        onFocusChanged = { focused ->
                                            if (focused) focusedKey = cardKey(entry.gridId, index)
                                            else if (focusedKey == cardKey(entry.gridId, index)) focusedKey = null
                                        },
                                        onKeyEvent = { event ->
                                            gridNav.onCardKey(
                                                gridId = entry.gridId,
                                                index = index,
                                                event = event,
                                                outerListState = resultsListState,
                                                scope = scope,
                                                onReturnToKeyboard = { returnToKeyboard() },
                                                onReturnToSidebar = onReturnToSidebar,
                                            )
                                        },
                                        onClick = {
                                            navController.navigate(Screen.Details.createRoute(item.id.toString(), item.mediaType))
                                        },
                                    )
                                }
                            }
                        }
                    }
                    if (!showingResults && discoverItems.isEmpty() && query.trim().length < 2) {
                        item {
                            Box(
                                modifier = Modifier.fillMaxWidth().height(200.dp),
                                contentAlignment = Alignment.Center,
                            ) {
                                CircularProgressIndicator(
                                    color = Color(0xFFE50914),
                                    strokeWidth = 2.dp,
                                    modifier = Modifier.size(32.dp),
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
// Results panel model
// ─────────────────────────────────────────────────────────────────────────────

private sealed interface PanelItem {
    val key: String
}

private data class PanelTitle(val text: String) : PanelItem {
    override val key: String get() = "title:$text"
}

private data class PanelSection(val title: String) : PanelItem {
    override val key: String get() = "section:$title"
}

private data class PanelRow(val gridId: String, val startIndex: Int, val items: List<MediaItem>) : PanelItem {
    override val key: String get() = "row:$gridId:$startIndex"
}

// Builds the right panel as a flat list of LazyColumn items (title / section
// header / card rows) plus the matching GridDesc sections. Row-based like the
// Dart CustomScrollView: the panel scrolls as ONE lazy list, and GridNavState
// scrolls the parent to the exact row (sectionIndex + index / columns) so the
// focused card is always brought into view.
private fun buildPanel(
    showingResults: Boolean,
    isSearching: Boolean,
    query: String,
    movieResults: List<MediaItem>,
    seriesResults: List<MediaItem>,
    discoverItems: List<MediaItem>,
): Pair<List<PanelItem>, List<GridDesc>> {
    val panel = mutableListOf<PanelItem>()
    val grids = mutableListOf<GridDesc>()

    fun addSection(gridId: String, title: String, items: List<MediaItem>) {
        if (items.isEmpty()) return
        panel.add(PanelSection(title))
        grids.add(GridDesc(gridId, items.size, sectionIndex = panel.size))
        items.chunked(COLUMNS).forEachIndexed { row, chunk ->
            panel.add(PanelRow(gridId, row * COLUMNS, chunk))
        }
    }

    when {
        isSearching -> {}
        showingResults -> {
            panel.add(PanelTitle("Results for \"$query\""))
            addSection("search:movies", "Movies", movieResults)
            addSection("search:series", "TV Series", seriesResults)
        }
        else -> {
            panel.add(PanelTitle("Discover"))
            if (discoverItems.isNotEmpty()) {
                grids.add(GridDesc("search:discover", discoverItems.size, sectionIndex = panel.size))
                discoverItems.chunked(COLUMNS).forEachIndexed { row, chunk ->
                    panel.add(PanelRow("search:discover", row * COLUMNS, chunk))
                }
            }
        }
    }
    return panel to grids
}

@Composable
private fun SectionHeader(title: String, modifier: Modifier = Modifier) {
    Row(modifier = modifier, verticalAlignment = Alignment.CenterVertically) {
        Box(
            modifier = Modifier
                .size(width = 4.dp, height = 23.dp)
                .background(Color(0xFFE50914), RoundedCornerShape(4.dp))
        )
        Spacer(Modifier.width(10.dp))
        Text(
            text = title,
            color = Color.White,
            fontSize = 21.sp,
            fontWeight = FontWeight.W700,
        )
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Empty / error message
// ─────────────────────────────────────────────────────────────────────────────

@Composable
private fun SearchMessage(icon: Int, text: String) {
    Box(
        modifier = Modifier.fillMaxWidth().height(280.dp),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Icon(
                painter = painterResource(icon),
                contentDescription = null,
                tint = Color.White.copy(alpha = 0.38f),
                modifier = Modifier.size(58.dp),
            )
            Text(
                text = text,
                color = Color.White.copy(alpha = 0.7f),
                fontSize = 18.sp,
                fontWeight = FontWeight.Normal,
            )
        }
    }
}