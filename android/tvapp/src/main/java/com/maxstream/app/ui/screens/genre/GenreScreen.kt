package com.maxstream.app.ui.screens.genre

import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEvent
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.navigation.NavController
import coil.compose.AsyncImage
import com.maxstream.app.data.model.MediaItem
import com.maxstream.app.di.Modules
import com.maxstream.app.ui.components.ContentCard
import com.maxstream.app.ui.components.ContentCardRowHeight
import com.maxstream.app.ui.navigation.Screen
import com.maxstream.app.ui.theme.Primary
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

private const val COLUMNS = 5
private val TYPE_OPTIONS = listOf("movie" to "Movies", "tv" to "TV Shows")

private data class GenreEntry(val source: String, val id: Int, val name: String) {
    val key: String get() = "$source:$id"
}

/**
 * TV Browse-by-Genre screen. Mirrors the Dart TvGenreScreen:
 *  - Left pane: media type (Movies / TV Shows)
 *  - Genre rail below the header
 *  - 5-column content grid with infinite paging
 *  - 3-section focus model: 0 = type pane, 1 = genre rail, 2 = grid
 */
@Composable
fun GenreScreen(
    navController: NavController,
    onReturnToSidebar: () -> Unit = {},
    isVisible: Boolean = true,
    initialMediaType: String = "all",
    focusKey: Int = 0,
    restoreFocusKey: Int = 0,
) {
    val scope = rememberCoroutineScope()
    val gridState = rememberLazyGridState()
    val genreListState = rememberLazyListState()

    // ── State ────────────────────────────────────────────────────────────────
    var selectedType by remember { mutableStateOf(if (initialMediaType == "tv") "tv" else "movie") }
    var focusedType by remember { mutableStateOf(selectedType) }
    var genres by remember { mutableStateOf<List<GenreEntry>>(emptyList()) }
    var items by remember { mutableStateOf<List<MediaItem>>(emptyList()) }
    var focusedGenre by remember { mutableStateOf<GenreEntry?>(null) }
    var selectedGenre by remember { mutableStateOf<GenreEntry?>(null) }
    var focusedCard by remember { mutableIntStateOf(-1) }
    var loadingGenres by remember { mutableStateOf(false) }
    var loadingContent by remember { mutableStateOf(false) }
    var loadingMore by remember { mutableStateOf(false) }
    var hasMore by remember { mutableStateOf(true) }
    var genreError by remember { mutableStateOf<String?>(null) }
    var contentError by remember { mutableStateOf<String?>(null) }
    var pagingError by remember { mutableStateOf<String?>(null) }
    var page by remember { mutableIntStateOf(1) }
    var generation by remember { mutableIntStateOf(0) }
    var pendingEnterGrid by remember { mutableStateOf(false) }
    var sectionFocus by remember { mutableIntStateOf(0) }
    var navJob by remember { mutableStateOf<Job?>(null) }

    // ── Focus requesters ────────────────────────────────────────────────────
    val typeFocusRequesters = remember { mutableMapOf<String, FocusRequester>() }
    val genreFocusRequesters = remember { mutableMapOf<String, FocusRequester>() }
    val cardFocusRequesters = remember { mutableMapOf<String, FocusRequester>() }
    var genreDebounceJob by remember { mutableStateOf<Job?>(null) }

    fun cardKey(item: MediaItem) = "${item.mediaType}:${item.id}"

    // ── Data (declared before focus helpers — local funs must precede use) ──
    suspend fun fetch(genre: GenreEntry, page: Int): List<MediaItem> =
        if (genre.source == "movie")
            Modules.catalogRepository.catalogByGenre(genre.id, "movie", page)
        else
            Modules.catalogRepository.catalogByGenre(genre.id, "tv", page)

    fun loadMore() {
        val genre = selectedGenre ?: return
        if (loadingMore || !hasMore) return
        val request = generation
        val nextPage = page + 1
        loadingMore = true
        pagingError = null
        scope.launch {
            try {
                val rows = fetch(genre, nextPage)
                if (request != generation) return@launch
                // Dedupe: TMDB paging can return titles already on screen (and
                // the grid key is mediaType:id), which made LazyVerticalGrid
                // throw "key was already used" and crash on navigation.
                val seen = items.mapTo(mutableSetOf()) { cardKey(it) }
                val fresh = rows.filter { cardKey(it) !in seen }
                items = items + fresh
                page = nextPage
                hasMore = rows.isNotEmpty()
                loadingMore = false
            } catch (e: Exception) {
                if (request != generation) return@launch
                loadingMore = false
                pagingError = "More titles could not be loaded."
            }
        }
    }

    // ── Focus helpers ────────────────────────────────────────────────────────
    // Retries focus attempts. The requester is looked up fresh on every
    // attempt via [provider] so it picks up nodes that are only created once
    // a lazy item has been composed (e.g. a grid card after scrolling).
    // First attempt is immediate; later attempts back off 50/150/300/…ms.
    suspend fun focusWithRetry(provider: () -> FocusRequester?) {
        var attempt = 0
        while (attempt < 6) {
            if (attempt > 0) delay(50L * attempt)
            val r = provider()
            if (r != null) {
                val ok = runCatching { r.requestFocus(); true }.getOrDefault(false)
                if (ok) return
            }
            attempt++
        }
    }

    fun requestFocus(provider: () -> FocusRequester?) {
        navJob?.cancel()
        navJob = scope.launch { focusWithRetry(provider) }
    }

    fun focusType(source: String) {
        sectionFocus = 0
        focusedType = source
        requestFocus { typeFocusRequesters[source] }
    }

    fun focusGenreChip(index: Int) {
        if (genres.isEmpty()) return
        val target = index.coerceIn(0, genres.lastIndex)
        sectionFocus = 1
        navJob?.cancel()
        navJob = scope.launch {
            val requester = genres.getOrNull(target)?.key?.let { genreFocusRequesters[it] }
            // Most targets are already composed and visible — land focus on the
            // first attempt instead of suspending on a scroll first (the old
            // animated scroll blocked until it finished, so every rapid LEFT/
            // RIGHT press cancelled a half-finished scroll and the focus ring
            // lagged behind — the "tab dragging itself" feel).
            if (requester != null && runCatching { requester.requestFocus() }.isSuccess) return@launch
            runCatching { genreListState.scrollToItem(target) }
            focusWithRetry { genres.getOrNull(target)?.key?.let { genreFocusRequesters[it] } }
        }
    }

    fun focusGrid(index: Int) {
        if (items.isEmpty()) return
        val target = index.coerceIn(0, items.lastIndex)
        sectionFocus = 2
        focusedCard = target
        navJob?.cancel()
        navJob = scope.launch {
            val requester = items.getOrNull(target)?.let { cardFocusRequesters[cardKey(it)] }
            // Same immediate-focus-first approach: only scroll (instant, no
            // animation) when the card is not yet composed off-screen.
            if (requester != null && runCatching { requester.requestFocus() }.isSuccess) return@launch
            runCatching { gridState.scrollToItem(target) }
            focusWithRetry { items.getOrNull(target)?.let { cardFocusRequesters[cardKey(it)] } }
        }
        if (target >= items.size - COLUMNS * 2) loadMore()
    }

    fun enterGrid(genre: GenreEntry) {
        val genreIndex = genres.indexOfFirst { it.key == genre.key }
        val target = (if (genreIndex < 0) 0 else genreIndex % COLUMNS).coerceIn(0, items.lastIndex)
        focusGrid(target)
    }

    fun loadGenreContent(genre: GenreEntry, enterGrid: Boolean = false) {
        // Same genre already loaded with content: just enter its grid.
        if (selectedGenre?.key == genre.key && items.isNotEmpty()) {
            if (enterGrid) enterGrid(genre)
            return
        }
        genreDebounceJob?.cancel()
        val request = ++generation
        selectedGenre = genre
        focusedGenre = genre
        items = emptyList()
        focusedCard = -1
        page = 1
        hasMore = true
        loadingContent = true
        contentError = null
        pagingError = null
        pendingEnterGrid = enterGrid
        scope.launch {
            try {
                val rows = fetch(genre, 1)
                if (request != generation) return@launch
                items = rows.distinctBy { cardKey(it) }
                hasMore = rows.isNotEmpty()
                loadingContent = false
                if (pendingEnterGrid && items.isNotEmpty()) {
                    pendingEnterGrid = false
                    enterGrid(genre)
                }
            } catch (e: Exception) {
                if (request != generation) return@launch
                loadingContent = false
                contentError = "Content could not be loaded."
            }
        }
    }

    fun restoreFocus() {
        when (sectionFocus) {
            2 -> if (items.isNotEmpty()) focusGrid(focusedCard.coerceAtLeast(0))
                 else focusGenreChip(0)
            1 -> {
                val idx = genres.indexOfFirst { it.key == selectedGenre?.key }
                focusGenreChip(if (idx < 0) 0 else idx)
            }
            else -> focusType(selectedType)
        }
    }

    fun selectType(source: String, enterGenreBar: Boolean = false, initial: Boolean = false) {
        if (selectedType == source && genres.isNotEmpty()) {
            if (enterGenreBar) {
                val idx = genres.indexOfFirst { it.key == selectedGenre?.key }
                focusGenreChip(if (idx < 0) 0 else idx)
            }
            return
        }
        if (selectedType == source && loadingGenres) return
        val request = ++generation
        selectedType = source
        focusedType = source
        genres = emptyList()
        selectedGenre = null
        focusedGenre = null
        items = emptyList()
        focusedCard = -1
        page = 1
        hasMore = true
        loadingGenres = true
        loadingContent = true
        genreError = null
        contentError = null
        pagingError = null
        scope.launch {
            try {
                val genresMap = Modules.catalogRepository.genres(source)
                if (request != generation) return@launch
                val list = genresMap.entries.map { GenreEntry(source, it.key, it.value) }
                genres = list
                selectedGenre = list.firstOrNull()
                focusedGenre = list.firstOrNull()
                loadingGenres = false
                val first = list.firstOrNull()
                if (first != null) {
                    loadGenreContent(first)
                } else {
                    loadingContent = false
                }
                if (enterGenreBar) {
                    focusGenreChip(0)
                } else if (initial) {
                    restoreFocus()
                }
            } catch (e: Exception) {
                if (request != generation) return@launch
                loadingGenres = false
                loadingContent = false
                genreError = "Genres could not be loaded."
                requestFocus { typeFocusRequesters[source] }
            }
        }
    }

    fun open(index: Int) {
        if (index < 0 || index >= items.size) return
        val item = items[index]
        navController.navigate(Screen.Details.createRoute(item.id.toString(), item.mediaType))
    }

    // ── Key handlers ─────────────────────────────────────────────────────────
    fun onTypeKey(source: String, event: KeyEvent): Boolean {
        if (event.type != KeyEventType.KeyDown) return false
        val index = TYPE_OPTIONS.indexOfFirst { it.first == source }
        return when (event.key) {
            Key.DirectionUp, Key.DirectionDown -> {
                val delta = if (event.key == Key.DirectionUp) -1 else 1
                val next = (index + delta).coerceIn(0, TYPE_OPTIONS.lastIndex)
                focusedType = TYPE_OPTIONS[next].first
                requestFocus { typeFocusRequesters[TYPE_OPTIONS[next].first] }
                true
            }
            Key.DirectionRight, Key.DirectionCenter, Key.Enter -> {
                selectType(source, enterGenreBar = true)
                true
            }
            Key.DirectionLeft, Key.Back, Key.Escape -> { onReturnToSidebar(); true }
            else -> false
        }
    }

    fun onTypeFocus(source: String) {
        focusedType = source
        if (source != selectedType || genres.isEmpty()) {
            selectType(source)
        }
    }

    fun onGenreKey(genre: GenreEntry, index: Int, event: KeyEvent): Boolean {
        if (event.type != KeyEventType.KeyDown) return false
        return when (event.key) {
            Key.DirectionLeft -> {
                if (index == 0) focusType(selectedType) else focusGenreChip(index - 1)
                true
            }
            Key.DirectionRight -> {
                if (index + 1 < genres.size) focusGenreChip(index + 1)
                true
            }
            Key.DirectionDown, Key.DirectionCenter, Key.Enter -> {
                genreDebounceJob?.cancel()
                loadGenreContent(genre, enterGrid = true)
                true
            }
            Key.DirectionUp -> true
            Key.Back, Key.Escape -> { focusType(selectedType); true }
            else -> false
        }
    }

    fun onGenreFocus(genre: GenreEntry) {
        focusedGenre = genre
        if (genre.key == selectedGenre?.key && items.isNotEmpty()) return
        genreDebounceJob?.cancel()
        genreDebounceJob = scope.launch {
            delay(180)
            loadGenreContent(genre)
        }
    }

    fun onCardKey(index: Int, event: KeyEvent): Boolean {
        if (event.type != KeyEventType.KeyDown) return false
        return when (event.key) {
            Key.Back, Key.Escape -> {
                if (genres.isNotEmpty()) {
                    focusGenreChip((index % COLUMNS).coerceIn(0, genres.lastIndex))
                }
                true
            }
            Key.DirectionLeft -> {
                if (index % COLUMNS == 0) focusType(selectedType)
                else focusGrid(index - 1)
                true
            }
            Key.DirectionRight -> {
                if (index % COLUMNS < COLUMNS - 1 && index + 1 < items.size) focusGrid(index + 1)
                true
            }
            Key.DirectionUp -> {
                if (index < COLUMNS && genres.isNotEmpty()) {
                    focusGenreChip((index % COLUMNS).coerceIn(0, genres.lastIndex))
                } else {
                    focusGrid(index - COLUMNS)
                }
                true
            }
            Key.DirectionDown -> {
                val column = index % COLUMNS
                val nextRowStart = (index / COLUMNS + 1) * COLUMNS
                if (nextRowStart < items.size) {
                    focusGrid((nextRowStart + column).coerceIn(nextRowStart, items.lastIndex))
                }
                true
            }
            Key.Enter, Key.DirectionCenter -> { open(index); true }
            else -> false
        }
    }

    // ── Lifecycle ────────────────────────────────────────────────────────────
    LaunchedEffect(Unit) { selectType(selectedType, initial = true) }

    // Re-runs when the tab becomes visible OR focus returns from the sidebar
    // (focusKey bump). restoreFocus() keeps the last section (type / rail / grid).
    LaunchedEffect(isVisible, focusKey) {
        if (!isVisible) return@LaunchedEffect
        if (genres.isNotEmpty()) {
            delay(60)
            restoreFocus()
        } else if (!loadingGenres) {
            selectType(selectedType, initial = true)
        } else {
            while (loadingGenres) delay(50)
            delay(60)
            restoreFocus()
        }
    }

    // Deep-nav return: details/player overlay popped. Shell never left
    // composition, so restoreFocus() puts focus back on the last section.
    LaunchedEffect(isVisible, restoreFocusKey, sectionFocus) {
        if (!isVisible || restoreFocusKey <= 0) return@LaunchedEffect
        delay(60)
        restoreFocus()
    }

    // ── UI ───────────────────────────────────────────────────────────────────
    Row(
        modifier = Modifier
            .fillMaxSize()
            .padding(start = 28.dp, top = 26.dp, end = 34.dp, bottom = 24.dp),
    ) {
        // ── Media type pane ─────────────────────────────────────────────────
        Column(modifier = Modifier.width(168.dp), horizontalAlignment = Alignment.Start) {
            Text(
                text = "Browse",
                color = Color.White,
                fontSize = 31.sp,
                fontWeight = FontWeight.W700,
            )
            Spacer(Modifier.height(20.dp))
            TYPE_OPTIONS.forEach { (source, label) ->
                TypeButton(
                    source = source,
                    label = label,
                    selected = source == selectedType,
                    focused = source == focusedType,
                    focusRequester = typeFocusRequesters.getOrPut(source) { FocusRequester() },
                    onFocusChanged = { if (it) onTypeFocus(source) },
                    onKeyEvent = { onTypeKey(source, it) },
                    onClick = { selectType(source, enterGenreBar = true) },
                )
                Spacer(Modifier.height(10.dp))
            }
            if (loadingGenres) {
                Spacer(Modifier.height(24.dp))
                CircularProgressIndicator(color = Primary, modifier = Modifier.size(28.dp))
            }
            if (genreError != null) {
                Spacer(Modifier.height(20.dp))
                GenreMessage(
                    message = genreError!!,
                    action = "Retry",
                    onPressed = { selectType(selectedType, enterGenreBar = true) },
                    compact = true,
                )
            }
        }

        Spacer(Modifier.width(26.dp))

        // ── Genre rail + detail pane ────────────────────────────────────────
        Column(modifier = Modifier.weight(1f), horizontalAlignment = Alignment.Start) {
            if (genres.isEmpty()) {
                Spacer(Modifier.height(46.dp))
            } else {
                LazyRow(
                    state = genreListState,
                    modifier = Modifier.height(46.dp),
                    horizontalArrangement = Arrangement.spacedBy(9.dp),
                ) {
                    items(genres.size) { index ->
                        val genre = genres[index]
                        GenreChip(
                            genre = genre,
                            selected = selectedGenre?.key == genre.key,
                            focused = focusedGenre?.key == genre.key,
                            focusRequester = genreFocusRequesters.getOrPut(genre.key) { FocusRequester() },
                            onFocusChanged = { if (it) onGenreFocus(genre) },
                            onKeyEvent = { onGenreKey(genre, index, it) },
                            onClick = { loadGenreContent(genre, enterGrid = true) },
                        )
                    }
                }
            }

            Spacer(Modifier.height(14.dp))

            val typeLabel = TYPE_OPTIONS.first { it.first == selectedType }.second
            Text(
                text = if (selectedGenre == null) typeLabel else "$typeLabel  •  ${selectedGenre!!.name}",
                color = Color.White,
                fontSize = 27.sp,
                fontWeight = FontWeight.W700,
            )
            Spacer(Modifier.height(5.dp))

            val focusedItem = if (focusedCard in items.indices) items[focusedCard] else null
            val detailText = if (focusedItem == null) {
                "Select a title to see details"
            } else {
                val year = focusedItem.releaseDate.take(4).ifBlank { "—" }
                val rating = if (focusedItem.voteAverage > 0) "%.1f".format(focusedItem.voteAverage) else "—"
                val typeName = if (focusedItem.mediaType == "movie") "Movie" else "TV Series"
                "${focusedItem.title}  •  $year  •  $rating ★  •  $typeName"
            }
            Text(
                text = detailText,
                color = Color.White.copy(alpha = 0.7f),
                fontSize = 18.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )

            Spacer(Modifier.height(14.dp))

            // ── Content ────────────────────────────────────────────────────
            Box(modifier = Modifier.weight(1f)) {
                when {
                    loadingContent -> CircularProgressIndicator(
                        color = Primary,
                        modifier = Modifier.align(Alignment.Center).size(42.dp),
                    )
                    contentError != null -> GenreMessage(
                        message = contentError!!,
                        action = "Retry",
                        onPressed = {
                            val genre = selectedGenre
                            if (genre != null) loadGenreContent(genre, enterGrid = true)
                            else selectType(selectedType, enterGenreBar = true)
                        },
                        modifier = Modifier.align(Alignment.Center),
                    )
                    selectedGenre == null || items.isEmpty() -> GenreMessage(
                        message = "No titles found for this genre.",
                        modifier = Modifier.align(Alignment.Center),
                    )
                    else -> Column(modifier = Modifier.fillMaxSize()) {
                        LazyVerticalGrid(
                            state = gridState,
                            columns = GridCells.Fixed(COLUMNS),
                            modifier = Modifier.weight(1f),
                            contentPadding = PaddingValues(vertical = 4.dp),
                            verticalArrangement = Arrangement.spacedBy(14.dp),
                            horizontalArrangement = Arrangement.spacedBy(12.dp),
                        ) {
                            items(
                                count = items.size,
                                key = { index -> cardKey(items[index]) },
                            ) { index ->
                                val item = items[index]
                                // Fixed-height cell — see ContentCardRowHeight.
                                // Every cell is identical, so the grid no longer
                                // re-flows as focus moves between cards.
                                Box(Modifier.height(ContentCardRowHeight)) {
                                    ContentCard(
                                        posterUrl = item.posterUrl,
                                        title = item.title,
                                        rating = item.voteAverage.takeIf { it > 0 },
                                        year = item.releaseDate.take(4).toIntOrNull(),
                                        contentTypeLabel = if (item.mediaType == "tv") "TV Series" else "Movie",
                                        isFocused = focusedCard == index,
                                        focusRequester = cardFocusRequesters.getOrPut(cardKey(item)) { FocusRequester() },
                                        onFocusChanged = { focused ->
                                            if (focused) {
                                                focusedCard = index
                                                if (index >= items.size - COLUMNS * 2) loadMore()
                                            }
                                        },
                                        onKeyEvent = { onCardKey(index, it) },
                                        onClick = { open(index) },
                                    )
                                }
                            }
                        }
                        if (loadingMore) {
                            CircularProgressIndicator(
                                color = Primary,
                                modifier = Modifier
                                    .padding(8.dp)
                                    .size(25.dp),
                            )
                        }
                        if (pagingError != null) {
                            GenreMessage(
                                message = pagingError!!,
                                action = "Retry",
                                onPressed = { loadMore() },
                                compact = true,
                                modifier = Modifier.padding(12.dp),
                            )
                        }
                    }
                }
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Media type button (Movies / TV Shows)
// ─────────────────────────────────────────────────────────────────────────────

@Composable
private fun TypeButton(
    source: String,
    label: String,
    selected: Boolean,
    focused: Boolean,
    focusRequester: FocusRequester,
    onFocusChanged: (Boolean) -> Unit,
    onKeyEvent: (KeyEvent) -> Boolean,
    onClick: () -> Unit,
) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(8.dp))
            .background(
                when {
                    selected -> Color(0xFFE50914)
                    focused -> Color(0x1FFFFFFF)
                    else -> Color.Transparent
                }
            )
            .border(
                width = if (focused) 1.dp else 0.dp,
                color = if (focused) Color.White.copy(alpha = 0.7f) else Color.Transparent,
                shape = RoundedCornerShape(8.dp),
            )
            .focusRequester(focusRequester)
            .onFocusChanged { state -> onFocusChanged(state.hasFocus) }
            .onKeyEvent(onKeyEvent)
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 13.dp),
        contentAlignment = Alignment.Center,
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Box(
                modifier = Modifier
                    .size(22.dp)
                    .clip(RoundedCornerShape(4.dp))
                    .background(
                        if (selected || focused) Color.White
                        else Color.White.copy(alpha = 0.7f)
                    ),
            )
            Spacer(Modifier.height(6.dp))
            Text(
                text = label,
                color = if (selected || focused) Color.White else Color.White.copy(alpha = 0.7f),
                fontSize = 17.sp,
                fontWeight = FontWeight.W600,
            )
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Genre chip
// ─────────────────────────────────────────────────────────────────────────────

@Composable
private fun GenreChip(
    genre: GenreEntry,
    selected: Boolean,
    focused: Boolean,
    focusRequester: FocusRequester,
    onFocusChanged: (Boolean) -> Unit,
    onKeyEvent: (KeyEvent) -> Boolean,
    onClick: () -> Unit,
) {
    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(20.dp))
            .background(
                when {
                    selected -> Color(0xFFE50914)
                    focused -> Color(0x1FFFFFFF)
                    else -> Color(0x1AFFFFFF)
                }
            )
            .border(
                width = if (focused) 1.dp else 0.dp,
                color = if (focused) Color.White.copy(alpha = 0.7f) else Color.Transparent,
                shape = RoundedCornerShape(20.dp),
            )
            .focusRequester(focusRequester)
            .onFocusChanged { state -> onFocusChanged(state.hasFocus) }
            .onKeyEvent(onKeyEvent)
            .clickable(onClick = onClick)
            .padding(horizontal = 18.dp, vertical = 9.dp),
    ) {
        Text(
            text = genre.name,
            color = Color.White,
            fontSize = 16.sp,
            fontWeight = if (selected || focused) FontWeight.W700 else FontWeight.W500,
        )
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Message + optional retry action
// ─────────────────────────────────────────────────────────────────────────────

@Composable
private fun GenreMessage(
    message: String,
    action: String? = null,
    onPressed: (() -> Unit)? = null,
    compact: Boolean = false,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier,
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text(
            text = message,
            color = Color.White.copy(alpha = 0.7f),
            fontSize = if (compact) 16.sp else 19.sp,
        )
        if (action != null && onPressed != null) {
            Spacer(Modifier.height(12.dp))
            FilledTonalButton(
                onClick = onPressed,
                colors = ButtonDefaults.filledTonalButtonColors(
                    containerColor = Color(0xFFE50914),
                    contentColor = Color.White,
                ),
            ) { Text(action) }
        }
    }
}