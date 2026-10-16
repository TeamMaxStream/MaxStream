package com.maxstream.app.ui.tv

import androidx.compose.foundation.gestures.Orientation
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEvent
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.type
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * True when the lazy item at [index] is completely within the viewport along
 * the list's scroll axis.
 *
 * Only correct as a post-scroll confirmation. As a *gate* on whether to scroll
 * it is wrong: see [isItemPartiallyVisible].
 */
internal fun LazyListState.isItemFullyVisible(index: Int): Boolean {
    val info = layoutInfo
    val item = info.visibleItemsInfo.firstOrNull { it.index == index } ?: return false
    return when (info.orientation) {
        Orientation.Horizontal -> item.offset >= 0 && item.offset + item.size <= info.viewportSize.width
        else -> item.offset >= 0 && item.offset + item.size <= info.viewportSize.height
    }
}

/**
 * True when the item is at least PARTIALLY inside the viewport. This is the
 * check that must gate scrolling.
 *
 * [isItemFullyVisible] demands the whole card fit, which no card at a row's
 * trailing edge does — the last few are always clipped by a fraction of a pixel.
 * A strict full-visibility gate therefore reported "off-screen" on every press
 * near the end of a row and re-scrolled to the offset the row was already at.
 * Re-issuing a scroll to the position you are already in is the bounce.
 */
internal fun LazyListState.isItemPartiallyVisible(index: Int): Boolean {
    val info = layoutInfo
    val item = info.visibleItemsInfo.firstOrNull { it.index == index } ?: return false
    return when (info.orientation) {
        Orientation.Horizontal -> item.offset + item.size > 0 && item.offset < info.viewportSize.width
        else -> item.offset + item.size > 0 && item.offset < info.viewportSize.height
    }
}



/**
 * A single horizontal content row on a tab screen (matches Dart's stable row ids).
 *
 * @param id    stable identity used to remember focus across tab switches.
 * @param count number of cards in the row.
 */
data class RowDesc(val id: String, val count: Int)

/**
 * State holder for D-pad navigation across horizontal content rows.
 *
 * Mirrors the Dart `_focusCard` / `_revealCard` logic used by the Home and
 * Series-list screens: every card owns a [FocusRequester] and every row a
 * horizontal [LazyListState], so UP/DOWN/LEFT/RIGHT can move between rows and
 * scroll them into view even when the target row is not yet composed.
 *
 * Usage:
 * ```
 * val rowNav = remember { RowNavState() }
 * rowNav.setRows(visibleRows)
 * ```
 * Register each row's horizontal state via [registerRow], then call
 * [focusCard] (hero DOWN / programmatic moves) and [onCardKey] (from each
 * card's `onKeyEvent`).
 */
class RowNavState {

    private val cardRequesters = mutableMapOf<String, FocusRequester>()
    private val rowStates = mutableMapOf<String, LazyListState>()
    private val savedIndices = mutableMapOf<String, Int>()

    /**
     * Focus moves are serialised, NOT cancelled.
     *
     * A move is a coroutine: scroll the outer column, scroll the row, then
     * request focus. Cancelling one to start the next (the old behaviour) had
     * two failure modes on fast D-pad input:
     *  - cancel between the two scrolls left the row scrolled with focus still
     *    on the old card, and the *new* job's `index` was computed from that
     *    stale card, so focus landed one card further along than the single
     *    press warranted;
     *  - whichever job's `requestFocus()` happened to run last won, which is
     *    how a single press could move focus twice.
     *
     * Instead a new press replaces the *queued* target and the running job
     * picks it up when it finishes, so every move is applied in order and
     * exactly once.
     */
    private var focusJob: Job? = null
    private var queuedMove: Move? = null

    private data class Move(val rowId: String, val index: Int, val outer: LazyListState)

    /** Ordered list of currently visible rows. */
    var rows: List<RowDesc> = emptyList()
        private set

    /** Row that currently owns focus, or null when no row is focused (hero). */
    var activeRowId: String? = null
        private set

    fun setRows(rows: List<RowDesc>) {
        this.rows = rows
    }

    fun registerRow(rowId: String, state: LazyListState) {
        rowStates[rowId] = state
    }

    fun unregisterRow(rowId: String) {
        rowStates.remove(rowId)
        cardRequesters.keys.removeIf { it.substringBeforeLast(':') == rowId }
    }

    /** Number of cards in [rowId] (0 when the row is not visible). */
    fun count(rowId: String): Int = rows.firstOrNull { it.id == rowId }?.count ?: 0

    /** Position of [rowId] within [rows], or -1 when not visible. */
    fun indexOf(rowId: String): Int = rows.indexOfFirst { it.id == rowId }

    /** Last focused card index for [rowId] (used to restore hero DOWN). */
    fun focusedIndex(rowId: String): Int = savedIndices[rowId] ?: 0

    /**
     * Records where focus actually landed. Called from each card's
     * `onFocusChanged(true)`.
     *
     * This used to be written optimistically at the START of a focus move, so
     * the remembered index ran one card ahead whenever a move was interrupted
     * (a rapid second press cancelling the in-flight scroll). hero DOWN then
     * restored to that phantom index and focus visibly jumped over cards.
     */
    fun commitFocus(rowId: String, index: Int) {
        savedIndices[rowId] = index
        activeRowId = rowId
        focusStamp++
    }

    /** Bumped by every real focus landing; focusCard polls it to know its
     *  requestFocus() actually took effect. */
    private var focusStamp = 0
        private set

    /** Stable per-card [FocusRequester], kept alive across recompositions. */
    fun requester(rowId: String, index: Int): FocusRequester =
        cardRequesters.getOrPut("$rowId:$index") { FocusRequester() }

    // ── Trailing "See All" cell (the > at the end of a row) ──────────────────
    private val seeAllRequesters = mutableMapOf<String, FocusRequester>()

    /** Stable requester for [rowId]'s trailing See All cell. */
    fun seeAllRequester(rowId: String): FocusRequester =
        seeAllRequesters.getOrPut(rowId) { FocusRequester() }

    /**
     * Row whose See All cell launched the full list. Set on click so that when
     * the user backs out of that screen, focus returns to the cell they left
     * from instead of the last card in the row.
     */
    var seeAllReturnRowId: String? = null

    /**
     * Moves focus to card [requestedIndex] of [rowId]. Reveals the outer
     * column and the row ONLY when the target is entirely off-screen, then
     * requests focus — the card only becomes focusable after it is composed.
     *
     * Two things stop the "bounce" on LEFT/RIGHT:
     *  - The visibility test is PARTIAL, not full. Cards clipped by a pixel at
     *    the trailing edge still count as visible, so a press that does not
     *    require scrolling performs no scrolling at all.
     *  - When a scroll IS needed it is instant (scrollToItem), never
     *    animated. An animation in flight while focus keeps moving reads as
     *    the row bouncing under the cursor.
     *
     * Dart's _revealCard follows the same only-reveal-when-needed rule.
     */
    suspend fun focusCard(rowId: String, requestedIndex: Int, outerListState: LazyListState) {
        val length = count(rowId)
        if (length == 0) return
        val index = requestedIndex.coerceIn(0, length - 1)
        val rowIndex = indexOf(rowId)
        if (rowIndex < 0) return

        // NOT savedIndices[rowId] — that is committed by the card's own
        // onFocusChanged, so the remembered position always matches where focus
        // really is. See commitFocus.
        val requester = requester(rowId, index)
        val rowState = rowStates[rowId]

        // Only scroll when the target is genuinely off-screen. The test is
        // PARTIAL visibility, not full visibility: at a row's trailing edge the
        // last card is clipped by a hair, a strict full-visibility check said
        // "not visible", and we re-scrolled to the same offset on every single
        // press — the bounce the user reported. Only when the card is entirely
        // out of the viewport do we actually move, and then we use instant
        // scrollToItem so the row never animates while focus is moving.
        if (!outerListState.isItemPartiallyVisible(rowIndex)) {
            runCatching { outerListState.scrollToItem(rowIndex) }
        }
        if (rowState != null && !rowState.isItemPartiallyVisible(index)) {
            runCatching { rowState.scrollToItem(index) }
        }

        // requestFocus() is a silent no-op (returns Unit) while the node is not
        // attached — there is no success value to test (it never throws in
        // Compose 1.7). The item is composed once scrollToItem has awaited
        // layout, so this call lands. Brief retries only guard the rare case
        // where the scroll silently failed; the visible-items check breaks as
        // soon as the card exists in the layout so hot paths never wait.
        var attempt = 0
        while (attempt < 4) {
            if (attempt > 0) delay(30L * attempt)
            val stamp = focusStamp
            runCatching { requester.requestFocus() }
            // Only stop once focus ACTUALLY landed. The old check was "is the item
            // composed?", which is true the moment the scroll lands — a frame
            // before the focus request takes effect. The loop then gave up while
            // focus was still on the old card, and the next D-pad press was
            // computed from that stale index: one press, two cards of movement.
            // commitFocus() bumps focusStamp from the card's onFocusChanged.
            if (focusStamp != stamp) break
            attempt++
        }
    }

    /**
     * Moves focus to [index] in [rowId], serialised against any move already in
     * flight. A press that arrives mid-move replaces the queued target instead
     * of cancelling the running one, so focus can never be applied twice for one
     * press (which read as "some cards get skipped") and can never be left
     * un-applied (which read as the row scrolling past a card with focus stuck).
     */
    fun moveTo(rowId: String, index: Int, outerListState: LazyListState, scope: CoroutineScope) {
        val clamped = index.coerceIn(0, (count(rowId) - 1).coerceAtLeast(0))
        queuedMove = Move(rowId, clamped, outerListState)
        if (focusJob?.isActive == true) return
        focusJob = scope.launch {
            while (true) {
                val next = queuedMove ?: break
                queuedMove = null
                focusCard(next.rowId, next.index, next.outer)
            }
        }
    }

    /**
     * Shared D-pad handler for a card inside [rowId].
     *
     *  - LEFT  on first card  → [onReturnToSidebar], otherwise previous card
     *  - RIGHT                → next card, or [onRightAtEnd] past the last one
     *  - UP    on first row   → [onUpToHero], otherwise same column of row above
     *  - DOWN                 → same column of row below (consumed at bottom)
     *
     * @return true when the event was consumed.
     */
    fun onCardKey(
        rowId: String,
        index: Int,
        event: KeyEvent,
        outerListState: LazyListState,
        scope: CoroutineScope,
        onUpToHero: () -> Unit,
        onReturnToSidebar: () -> Unit,
        onRightAtEnd: (() -> Unit)? = null,
    ): Boolean {
        if (event.type != KeyEventType.KeyDown) return false
        val rowIndex = indexOf(rowId)
        when (event.key) {
            Key.DirectionLeft -> {
                if (index > 0) {
                    moveTo(rowId, index - 1, outerListState, scope)
                } else {
                    onReturnToSidebar()
                }
                return true
            }

            Key.DirectionRight -> {
                if (index + 1 < count(rowId)) {
                    moveTo(rowId, index + 1, outerListState, scope)
                } else {
                    // Trailing edge: rows with a header action (Coming Soon's
                    // "See All") hand focus there instead of dead-ending.
                    onRightAtEnd?.invoke()
                }
                return true
            }

            Key.DirectionUp -> {
                if (rowIndex > 0) {
                    val target = rows[rowIndex - 1]
                    moveTo(
                        target.id,
                        index.coerceAtMost((target.count - 1).coerceAtLeast(0)),
                        outerListState,
                        scope,
                    )
                } else {
                    onUpToHero()
                }
                return true
            }

            Key.DirectionDown -> {
                if (rowIndex in 0 until rows.lastIndex) {
                    val target = rows[rowIndex + 1]
                    moveTo(
                        target.id,
                        index.coerceAtMost((target.count - 1).coerceAtLeast(0)),
                        outerListState,
                        scope,
                    )
                }
                return true
            }

            else -> return false
        }
    }

    /**
     * Moves focus to the first visible row, keeping the previously focused
     * column if there is one (used by hero "DOWN").
     */
    fun focusFirstRow(outerListState: LazyListState, scope: CoroutineScope) {
        val first = rows.firstOrNull() ?: return
        moveTo(first.id, focusedIndex(first.id), outerListState, scope)
    }

    /** Drops requesters for rows that no longer exist (e.g. watchlist emptied). */
    fun clearMissingRows() {
        val visible = rows.mapTo(mutableSetOf()) { it.id }
        cardRequesters.keys.removeIf { it.substringBeforeLast(':') !in visible }
        seeAllRequesters.keys.retainAll(visible)
        activeRowId?.takeIf { it !in visible }?.let { activeRowId = null }
        seeAllReturnRowId?.takeIf { it !in visible }?.let { seeAllReturnRowId = null }
    }
}
