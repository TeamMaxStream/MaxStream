package com.maxstream.app.ui.components

import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.requiredHeight
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.key.KeyEvent
import androidx.compose.ui.input.key.onKeyEvent
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage

// Uniform poster card size, matching the Dart TvContentCard (width 130 / height 190).
// Exported: this is the SURFACE the focus ring wraps, so the trailing `>` See
// All cell can present the exact same focused surface.
val ContentCardWidth: Dp = 130.dp
val ContentCardPosterHeight: Dp = 190.dp
private val CardCornerRadius = 10.dp

// Horizontal breathing room between cards (matches the Dart TvContentCard).
private val CardHorizontalPadding = 7.dp
// Gap between the poster and the title block.
private val CardTitleTopPadding = 6.dp
// Fixed title block height so a 1- vs 2-line title never resizes the card.
private val CardTitleHeight = 42.dp

/**
 * Total laid-out height of a [ContentCard]: poster + title block.
 *
 * Exported so rows and grids can reserve an exact, focus-independent height.
 * A card sized to its content reflows its parent on every focus change, which
 * is what made rows jump when moving LEFT/RIGHT.
 */
val ContentCardTotalHeight: Dp = ContentCardPosterHeight + CardTitleTopPadding + CardTitleHeight

/**
 * Focus-pop headroom: a focused card is drawn 2% larger, so a container with a
 * fixed height needs a little slack or the growth gets clipped.
 */
val ContentCardFocusHeadroom: Dp = 8.dp

/**
 * Height a row/grid cell must reserve for a [ContentCard]: the fixed card
 * footprint plus focus-pop headroom.
 *
 * Rows and grids MUST give their container this height. A card that sizes
 * itself to its content reflows its whole parent the moment focus changes the
 * border width or the scale animation runs, which is what made rows visibly
 * jump on LEFT/RIGHT. ContentCard now pins its own size, so this constant is
 * only needed to stop a *fixed-height* container from clipping the focus pop.
 */
val ContentCardRowHeight: Dp = ContentCardTotalHeight + ContentCardFocusHeadroom

/**
 * The white rounded focus ring, drawn as a Modifier.
 *
 * Why this exists instead of `.border(width = if (isFocused) 2.dp else 0.dp)`:
 *
 *  - `border` width participates in LAYOUT. Flipping it between 0.dp and 2.dp
 *    resized the card on every focus change, re-flowing the whole row. This
 *    draws at a constant 2.dp.
 *  - `border` strokes CENTRED on the shape outline, so half its width lands
 *    outside the parent's clip and gets cut off — the ring looked chipped and,
 *    on cards already clipped, invisible. Insetting by half the stroke keeps
 *    the whole ring inside the clip.
 *  - As a Modifier it applies AFTER `.clip(...)` but does not consume the
 *    clip, so it renders on top of the poster, scrim, progress bar and badges.
 */
fun Modifier.focusRing(
    visible: Boolean,
    cornerRadius: Dp,
    width: Dp = 2.dp,
    color: Color = Color.White,
): Modifier = if (!visible) {
    this
} else {
    drawWithContent {
        drawContent()
        val stroke = width.toPx()
        val inset = stroke / 2f
        drawRoundRect(
            color = color,
            topLeft = androidx.compose.ui.geometry.Offset(inset, inset),
            size = androidx.compose.ui.geometry.Size(
                width = size.width - stroke,
                height = size.height - stroke,
            ),
            // x/y default to the same value, so a single radius keeps the
            // corners circular (CornerRadius requires BOTH components).
            cornerRadius = androidx.compose.ui.geometry.CornerRadius(
                x = (cornerRadius.toPx() - inset).coerceAtLeast(0f),
                y = (cornerRadius.toPx() - inset).coerceAtLeast(0f),
            ),
            style = androidx.compose.ui.graphics.drawscope.Stroke(width = stroke),
        )
    }
}

/**
 * TV content card (poster + title + optional overlays).
 *
 * Fixes applied:
 * - Single focus state path: `onFocusChanged` is the canonical source of truth;
 *   the external [isFocused] param drives scale animation only.
 * - No double LaunchedEffect(isFocused) calling onFocusChanged — that was
 *   causing duplicate callbacks on every recomposition.
 * - focusable() + clickable() in the right order so D-pad Enter triggers onClick.
 * - Focus feedback is drawn ONLY: the scale runs through `graphicsLayer` and
 *   the focus ring is drawn inside the existing bounds instead of by growing a
 *   border from 0.dp to 2.dp. Both used to change the card's measured size, so
 *   every focus move re-measured the row and shoved neighbouring cards around.
 *   `requiredHeight` pins the card's height so no parent can infer a different
 *   size from the focus state.
 */
@Composable
fun ContentCard(
    posterUrl: String,
    title: String,
    modifier: Modifier = Modifier,
    isFocused: Boolean = false,
    progress: Float? = null,
    rating: Double? = null,
    contentTypeLabel: String? = null,
    year: Int? = null,
    onClick: () -> Unit = {},
    onFocusChanged: (Boolean) -> Unit = {},
    onKeyEvent: (KeyEvent) -> Boolean = { false },
    focusRequester: FocusRequester? = null,
) {
    val cardHeightPx = with(LocalDensity.current) { ContentCardPosterHeight.toPx() }

    val scale by animateFloatAsState(
        targetValue = if (isFocused) 1.02f else 1f,
        animationSpec = tween(durationMillis = 180, easing = FastOutSlowInEasing),
        label = "cardScale",
    )

    Box(
        modifier = modifier
            .padding(horizontal = CardHorizontalPadding)
            // graphicsLayer (not Modifier.scale) so the focus pop is a draw-time
            // transform: the card keeps the exact same measured bounds focused
            // or not, so nothing beside it can move.
            .graphicsLayer {
                scaleX = scale
                scaleY = scale
            }
            // D-pad navigation: arrow keys handled here so parents can wire
            // cross-row / sidebar moves (mirrors Dart's card onKeyEvent).
            .onKeyEvent(onKeyEvent)
            // External programmatic focus (row navigator) must be registered
            // before the card is made focusable below.
            .then(if (focusRequester != null) Modifier.focusRequester(focusRequester) else Modifier)
            // Focus must be registered BEFORE clickable so the D-pad Enter key
            // fires the click callback correctly.
            .onFocusChanged { state -> onFocusChanged(state.hasFocus) }
            .focusable()
            .clickable(onClick = onClick)
            // Pin the height AFTER the clickable/focus modifiers so neither the
            // focus ring nor the scale can influence the measured size. Width
            // is deliberately NOT pinned: the search grid supplies its own
            // weight(1f) column width, and overriding it would break that
            // layout. The inner column's fixed 130.dp poster/title already
            // makes the width deterministic inside a LazyRow.
            .requiredHeight(ContentCardTotalHeight),
        contentAlignment = Alignment.TopCenter,
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            // ── Poster ──────────────────────────────────────────────────────
            Box(
                modifier = Modifier
                    .width(ContentCardWidth)
                    .height(ContentCardPosterHeight)
                    .clip(RoundedCornerShape(CardCornerRadius))
                    // Focus ring: drawn last (via drawWithContent) so it sits
                    // on top of the poster, scrim, progress bar and badges, and
                    // at a constant width so it never affects the layout.
                    .focusRing(visible = isFocused, cornerRadius = CardCornerRadius),
            ) {
                AsyncImage(
                    model = posterUrl,
                    contentDescription = title,
                    modifier = Modifier.fillMaxSize(),
                    contentScale = ContentScale.Crop,
                )

                // Bottom gradient scrim
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .background(
                            Brush.verticalGradient(
                                colors = listOf(
                                    Color.Transparent,
                                    Color.Transparent,
                                    Color.Black.copy(alpha = 0.55f),
                                ),
                                startY = 0f,
                                endY = cardHeightPx,
                            )
                        )
                )

                // Progress bar
                if (progress != null) {
                    Box(
                        modifier = Modifier
                            .align(Alignment.BottomCenter)
                            .fillMaxWidth()
                            .height(4.dp)
                            .padding(horizontal = 7.dp),
                    ) {
                        Box(
                            modifier = Modifier
                                .fillMaxSize()
                                .clip(RoundedCornerShape(2.dp))
                                .background(Color(0xFF333333))
                        )
                        Box(
                            modifier = Modifier
                                .fillMaxWidth(progress.coerceIn(0f, 1f))
                                .fillMaxSize()
                                .clip(RoundedCornerShape(2.dp))
                                .background(Color(0xFFE50914))
                        )
                    }
                }

                // Rating badge
                if (rating != null && rating > 0) {
                    Box(
                        modifier = Modifier
                            .align(Alignment.TopEnd)
                            .padding(top = 6.dp, end = 6.dp),
                    ) {
                        Text(
                            text = String.format("%.1f", rating),
                            color = Color.White,
                            fontSize = 12.sp,
                            fontWeight = FontWeight.Bold,
                            modifier = Modifier
                                .background(Color.Black.copy(alpha = 0.6f), RoundedCornerShape(4.dp))
                                .padding(horizontal = 4.dp, vertical = 2.dp),
                        )
                    }
                }
            }

            // ── Title ────────────────────────────────────────────────────────
            // Fixed width + height: a 1-line and a 2-line title must occupy the
            // same slot, otherwise gaining/losing focus on a long title resizes
            // the whole row.
            Column(
                modifier = Modifier
                    .width(ContentCardWidth)
                    .padding(top = CardTitleTopPadding)
                    .height(CardTitleHeight),
                verticalArrangement = Arrangement.Center,
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text(
                    text = title,
                    color = Color.White,
                    fontSize = 12.sp,
                    fontWeight = FontWeight.Medium,
                    textAlign = TextAlign.Center,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }
    }
}
