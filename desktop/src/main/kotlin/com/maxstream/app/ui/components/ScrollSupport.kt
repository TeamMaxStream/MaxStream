package com.maxstream.app.ui.components

import androidx.compose.foundation.VerticalScrollbar
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.grid.LazyGridState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.v2.ScrollbarAdapter
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEvent
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.foundation.ScrollState
import androidx.compose.ui.unit.dp
import androidx.compose.runtime.staticCompositionLocalOf
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import kotlin.math.ceil

/**
 * True while the TitleBar search field has focus. Scroll containers and the
 * shell must not steal focus then — the old autoFocus unconditionally grabbed
 * focus on every mount, so typing (which remounts grids / re-navigates) lost
 * keystrokes after the first character.
 */
val LocalSearchActive = staticCompositionLocalOf { false }

/**
 * Vertical-scrolling column with a right-edge scrollbar and keyboard support
 * (arrow up/down, PageUp/PageDown, Home/End). The container takes focus on
 * entry so the keys work immediately; if an inner control (text field) has
 * focus it consumes the keys first.
 */
@Composable
fun ScrollableColumn(
    modifier: Modifier = Modifier,
    contentPadding: PaddingValues = PaddingValues(0.dp),
    autoFocus: Boolean = true,
    content: @Composable ColumnScope.() -> Unit,
) {
    val scope = rememberCoroutineScope()
    val requester = remember { FocusRequester() }
    val scrollState = rememberScrollState()
    val searchActive = LocalSearchActive.current
    Box(
        modifier
            .fillMaxSize()
            .focusRequester(requester)
            .focusable()
            .onKeyEvent { scrollKeys(scrollState, scope, it) },
    ) {
        Column(
            Modifier.fillMaxSize().verticalScroll(scrollState).padding(contentPadding),
            content = content,
        )
        VerticalScrollbar(
            adapter = ScrollStateAdapter(scrollState),
            modifier = Modifier.align(Alignment.CenterEnd).fillMaxHeight(),
        )
    }
    LaunchedEffect(requester, searchActive) {
        if (autoFocus && !searchActive) runCatching { requester.requestFocus() }
    }
}

/**
 * Wrapper for a lazy grid: draws the right-edge scrollbar and handles keyboard
 * scrolling. The grid itself is supplied by [content] and must use [state].
 */
@Composable
fun ScrollableGrid(
    state: LazyGridState,
    modifier: Modifier = Modifier,
    autoFocus: Boolean = true,
    content: @Composable () -> Unit,
) {
    val scope = rememberCoroutineScope()
    val requester = remember { FocusRequester() }
    val searchActive = LocalSearchActive.current
    Box(
        modifier
            .fillMaxSize()
            .focusRequester(requester)
            .focusable()
            .onKeyEvent { gridKeys(state, scope, it) },
    ) {
        content()
        VerticalScrollbar(
            adapter = remember(state) { GridScrollbarAdapter(state) },
            modifier = Modifier.align(Alignment.CenterEnd).fillMaxHeight(),
        )
    }
    LaunchedEffect(requester, searchActive) {
        if (autoFocus && !searchActive) runCatching { requester.requestFocus() }
    }
}

private fun scrollKeys(state: ScrollState, scope: CoroutineScope, event: KeyEvent): Boolean {
    if (event.type != KeyEventType.KeyDown) return false
    val page = state.viewportSize * 0.9f
    val delta = when (event.key) {
        Key.DirectionDown -> 120f
        Key.DirectionUp -> -120f
        Key.PageDown -> page
        Key.PageUp -> -page
        Key.Home, Key.MoveHome -> -1_000_000f
        Key.MoveEnd -> 1_000_000f
        else -> return false
    }
    scope.launch { state.dispatchRawDelta(delta) }
    return true
}

private fun gridKeys(state: LazyGridState, scope: CoroutineScope, event: KeyEvent): Boolean {
    if (event.type != KeyEventType.KeyDown) return false
    val page = state.layoutInfo.viewportSize.height * 0.9f
    when (event.key) {
        Key.Home, Key.MoveHome -> {
            scope.launch { state.scrollToItem(0) }
            return true
        }
        Key.MoveEnd -> {
            scope.launch {
                val last = state.layoutInfo.totalItemsCount - 1
                state.scrollToItem(last.coerceAtLeast(0))
            }
            return true
        }
        else -> Unit
    }
    val delta = when (event.key) {
        Key.DirectionDown -> 120f
        Key.DirectionUp -> -120f
        Key.PageDown -> page
        Key.PageUp -> -page
        else -> return false
    }
    scope.launch { state.scroll { scrollBy(delta) } }
    return true
}

/** Exact scrollbar adapter for a [ScrollState] (column-based screens). */
private class ScrollStateAdapter(private val state: ScrollState) : ScrollbarAdapter {
    override val scrollOffset: Double get() = state.value.toDouble()
    override val contentSize: Double get() = (state.viewportSize + state.maxValue).toDouble()
    override val viewportSize: Double get() = state.viewportSize.toDouble()

    override suspend fun scrollTo(scrollOffset: Double) {
        state.dispatchRawDelta((scrollOffset - state.value).toFloat())
    }
}

/**
 * Approximate scrollbar adapter for a [LazyGridState]. Lazy grids don't expose
 * a total content height, so this derives it from the visible item sizes and
 * the estimated column count — good enough to drive a thumb indicator.
 */
private class GridScrollbarAdapter(private val state: LazyGridState) : ScrollbarAdapter {

    private val cols: Int
        get() {
            val visible = state.layoutInfo.visibleItemsInfo
            if (visible.isEmpty()) return 1
            val itemWidth = visible.first().size.width
            if (itemWidth <= 0) return 1
            return (state.layoutInfo.viewportSize.width / itemWidth).coerceAtLeast(1)
        }

    private val avgItemHeight: Double
        get() {
            val visible = state.layoutInfo.visibleItemsInfo
            if (visible.isEmpty()) return 1.0
            return visible.map { it.size.height }.average().coerceAtLeast(1.0)
        }

    override val viewportSize: Double get() = state.layoutInfo.viewportSize.height.toDouble()

    override val contentSize: Double get() {
        val info = state.layoutInfo
        if (info.totalItemsCount == 0) return viewportSize
        val rows = ceil(info.totalItemsCount / cols.toDouble())
        return rows * avgItemHeight
    }

    override val scrollOffset: Double get() {
        if (state.layoutInfo.visibleItemsInfo.isEmpty()) return 0.0
        val row = state.firstVisibleItemIndex / cols
        return row * avgItemHeight + state.firstVisibleItemScrollOffset
    }

    override suspend fun scrollTo(scrollOffset: Double) {
        if (state.layoutInfo.totalItemsCount == 0) return
        val row = (scrollOffset / avgItemHeight).toInt()
        val index = (row * cols).coerceIn(0, (state.layoutInfo.totalItemsCount - 1).coerceAtLeast(0))
        state.scrollToItem(index)
    }
}