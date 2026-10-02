package com.maxstream.app.ui.screens.more

import androidx.compose.foundation.background
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.ScrollState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch

// ─────────────────────────────────────────────────────────────────────────────
// Release notes renderer
//
// GitHub release bodies are markdown; on TV they used to render as raw text
// (`## Fixes`, `**bold**`, `- bullets`, `[links](url)`). These helpers turn
// that into organised blocks: headings, bullets, dividers and inline-styled
// paragraphs — and keep D-pad scrolling working inside scrollable parents.
// ─────────────────────────────────────────────────────────────────────────────

sealed class ReleaseNoteBlock {
    data class Heading(val text: String, val level: Int) : ReleaseNoteBlock()
    data class Bullet(val text: String, val marker: String) : ReleaseNoteBlock()
    data class Paragraph(val text: String) : ReleaseNoteBlock()
    data object Divider : ReleaseNoteBlock()
}

private val HEADING_REGEX = Regex("^#{1,6}\\s*(.+)$")
private val BULLET_REGEX = Regex("^\\s*([-*+•])\\s+(.+)$")
private val NUMBERED_REGEX = Regex("^\\s*(\\d{1,2})[.)]\\s+(.+)$")
private val DIVIDER_REGEX = Regex("^\\s*(?:-{3,}|\\*{3,}|_{3,})\\s*$")
private val HTML_COMMENT_REGEX = Regex("(?s)<!--.*?-->")
private val BLOCK_TAG_REGEX = Regex("</?(?:p|li|ul|ol|div|tr|h[1-6])[^>]*>", RegexOption.IGNORE_CASE)
private val BR_TAG_REGEX = Regex("<br\\s*/?>", RegexOption.IGNORE_CASE)
private val ANY_TAG_REGEX = Regex("<[^>]+>")

/** Converts a markdown/HTML release body into renderable blocks. */
fun parseReleaseNotes(raw: String): List<ReleaseNoteBlock> {
    if (raw.isBlank()) return emptyList()
    val text = raw
        .replace("\r\n", "\n")
        .replace(HTML_COMMENT_REGEX, "")
        .replace(BR_TAG_REGEX, "\n")
        .replace(BLOCK_TAG_REGEX, "\n")
        .replace(ANY_TAG_REGEX, "")
        .replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&#39;", "'")
        .replace("&quot;", "\"")

    val blocks = mutableListOf<ReleaseNoteBlock>()
    val paragraph = StringBuilder()

    fun flushParagraph() {
        if (paragraph.isNotBlank()) {
            blocks += ReleaseNoteBlock.Paragraph(paragraph.toString().trim())
        }
        paragraph.setLength(0)
    }

    for (rawLine in text.split('\n')) {
        val line = rawLine.trim()
        when {
            line.isBlank() -> flushParagraph()

            DIVIDER_REGEX.matches(line) -> {
                flushParagraph()
                blocks += ReleaseNoteBlock.Divider
            }

            HEADING_REGEX.matches(line) -> {
                flushParagraph()
                val match = HEADING_REGEX.matchEntire(line) ?: continue
                val body = match.groupValues[1].trim()
                if (body.isNotEmpty()) {
                    blocks += ReleaseNoteBlock.Heading(body, line.takeWhile { it == '#' }.length)
                }
            }

            BULLET_REGEX.matches(line) -> {
                flushParagraph()
                val match = BULLET_REGEX.matchEntire(line) ?: continue
                blocks += ReleaseNoteBlock.Bullet(match.groupValues[2].trim(), "•")
            }

            NUMBERED_REGEX.matches(line) -> {
                flushParagraph()
                val match = NUMBERED_REGEX.matchEntire(line) ?: continue
                blocks += ReleaseNoteBlock.Bullet(
                    match.groupValues[2].trim(),
                    "${match.groupValues[1]}.",
                )
            }

            else -> {
                if (paragraph.isNotEmpty()) paragraph.append(' ')
                paragraph.append(line)
            }
        }
    }
    flushParagraph()
    return blocks
}

/** Inline markdown: **bold**, __bold__, *italic*, `code`, [text](url), ~~strike~~. */
fun releaseNotesAnnotated(text: String): AnnotatedString = buildAnnotatedString {
    var i = 0
    val n = text.length
    while (i < n) {
        val two = text.substring(i, minOf(i + 2, n))
        val ch = text[i]
        when {
            two == "**" || two == "__" -> {
                val end = text.indexOf(two, i + 2)
                if (end > i + 2) {
                    withStyle(SpanStyle(fontWeight = FontWeight.Bold)) {
                        append(text.substring(i + 2, end))
                    }
                    i = end + 2
                } else { append(ch); i++ }
            }
            two == "~~" -> {
                val end = text.indexOf("~~", i + 2)
                if (end > i + 2) {
                    withStyle(SpanStyle(textDecoration = TextDecoration.LineThrough)) {
                        append(text.substring(i + 2, end))
                    }
                    i = end + 2
                } else { append(ch); i++ }
            }
            two == "[]" || ch == '[' -> {
                val close = text.indexOf(']', i + 1)
                val openParen = if (close >= 0 && close + 1 < n && text[close + 1] == '(') {
                    text.indexOf(')', close + 2)
                } else -1
                if (close > i && openParen > close) {
                    withStyle(SpanStyle(color = Color(0xFF64B5F6), textDecoration = TextDecoration.Underline)) {
                        append(text.substring(i + 1, close))
                    }
                    i = openParen + 1
                } else { append(ch); i++ }
            }
            ch == '`' -> {
                val end = text.indexOf('`', i + 1)
                if (end > i) {
                    withStyle(
                        SpanStyle(color = Color(0xFFB9F6CA), background = Color(0x22FFFFFF))
                    ) { append(text.substring(i + 1, end)) }
                    i = end + 1
                } else { append(ch); i++ }
            }
            (ch == '*' || ch == '_') &&
                (i + 1 < n && !text[i + 1].isWhitespace()) -> {
                val close = text.indexOf(ch, i + 1)
                if (close > i) {
                    withStyle(SpanStyle(fontStyle = FontStyle.Italic)) {
                        append(text.substring(i + 1, close))
                    }
                    i = close + 1
                } else { append(ch); i++ }
            }
            else -> { append(ch); i++ }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Rendering
// ─────────────────────────────────────────────────────────────────────────────

@Composable
fun ReleaseNotesColumn(
    blocks: List<ReleaseNoteBlock>,
    modifier: Modifier = Modifier,
    headingColor: Color = Color.White,
) {
    Column(modifier = modifier.fillMaxWidth()) {
        blocks.forEach { block ->
            when (block) {
                is ReleaseNoteBlock.Heading -> {
                    Spacer(Modifier.height(10.dp))
                    Text(
                        text = block.text,
                        color = headingColor,
                        fontSize = if (block.level <= 2) 16.sp else 15.sp,
                        fontWeight = FontWeight.Bold,
                        lineHeight = 22.sp,
                    )
                    Spacer(Modifier.height(4.dp))
                }

                is ReleaseNoteBlock.Bullet -> {
                    Spacer(Modifier.height(4.dp))
                    Row(modifier = Modifier.fillMaxWidth()) {
                        Text(
                            text = block.marker,
                            color = Color(0xFF4CAF50),
                            fontSize = 14.sp,
                            fontWeight = FontWeight.Bold,
                            modifier = Modifier.padding(end = 8.dp),
                        )
                        Text(
                            text = releaseNotesAnnotated(block.text),
                            color = Color.White.copy(alpha = 0.88f),
                            fontSize = 14.sp,
                            lineHeight = 20.sp,
                            modifier = Modifier.weight(1f),
                        )
                    }
                }

                is ReleaseNoteBlock.Paragraph -> {
                    Spacer(Modifier.height(6.dp))
                    Text(
                        text = releaseNotesAnnotated(block.text),
                        color = Color.White.copy(alpha = 0.8f),
                        fontSize = 14.sp,
                        lineHeight = 20.sp,
                    )
                }

                ReleaseNoteBlock.Divider -> {
                    Spacer(Modifier.height(8.dp))
                    androidx.compose.foundation.layout.Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(1.dp)
                            .background(Color(0x28FFFFFF)),
                    )
                    Spacer(Modifier.height(8.dp))
                }
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// D-pad scrolling for focusable blocks inside a verticalScroll parent
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Makes [this] focusable and lets D-pad UP/DOWN/PAGE_UP/PAGE_DOWN scroll
 * [scrollState] by a fixed step. Compose only auto-scrolls when focus MOVES
 * between children, so a tall non-interactive block (release notes) needs this
 * to be scrollable in both directions with the remote.
 *
 * At the top/bottom edge the key is left unconsumed so focus continues to the
 * previous/next focusable (buttons above, auto-check row below).
 */
@Composable
fun Modifier.dpadScroll(
    scrollState: ScrollState,
    stepDp: Int = 300,
    onFocusGained: (() -> Unit)? = null,
): Modifier {
    val scope = rememberCoroutineScope()
    val stepPx = with(LocalDensity.current) { stepDp.dp.toPx() }
    return this
        .focusable()
        .onFocusChanged { if (it.isFocused) onFocusGained?.invoke() }
        .onKeyEvent { event ->
            if (event.type != KeyEventType.KeyDown) return@onKeyEvent false
            val delta = when (event.key) {
                Key.DirectionDown, Key.PageDown -> stepPx
                Key.DirectionUp, Key.PageUp -> -stepPx
                else -> 0f
            }
            if (delta == 0f) return@onKeyEvent false
            val atLimit = if (delta > 0f) {
                scrollState.value >= scrollState.maxValue
            } else {
                scrollState.value <= 0
            }
            if (atLimit) return@onKeyEvent false
            scope.launch { scrollState.scroll { scrollBy(delta) } }
            true
        }
}

/** Convenience wrapper: a focusable, D-pad scrollable notes column. */
@Composable
fun DpadScrollableNotes(
    scrollState: ScrollState,
    blocks: List<ReleaseNoteBlock>,
    modifier: Modifier = Modifier,
    emptyText: String = "",
) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .dpadScroll(scrollState),
    ) {
        if (blocks.isEmpty() && emptyText.isNotEmpty()) {
            Text(
                text = emptyText,
                color = Color.White.copy(alpha = 0.6f),
                fontSize = 14.sp,
                lineHeight = 20.sp,
                modifier = Modifier.padding(vertical = 4.dp),
            )
        } else {
            ReleaseNotesColumn(blocks)
        }
    }
}
