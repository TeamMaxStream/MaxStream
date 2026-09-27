package com.maxstream.app.ui.components

import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.input.pointer.onPointerEvent
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.clickable
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * Visible keyboard-focus ring. Custom `clickable(indication = null)` surfaces
 * (cards, chips, tiles) had no focus indication at all, which made the app
 * unusable with the keyboard alone. Draws a 2dp outline in the primary color
 * while the node has focus; optionally also while hovered for pointer parity.
 */
@OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class)
fun Modifier.appFocusRing(
    cornerRadius: Dp = 8.dp,
    onHover: Boolean = false,
    ringColor: Color? = null,
    strokeWidth: Dp = 2.dp,
): Modifier = composed {
    var focused by remember { mutableStateOf(false) }
    var hovered by remember { mutableStateOf(false) }
    val color = ringColor ?: MaterialTheme.colorScheme.primary
    this
        .onFocusChanged { focused = it.isFocused }
        .onPointerEvent(PointerEventType.Enter) { hovered = true }
        .onPointerEvent(PointerEventType.Exit) { hovered = false }
        .drawWithContent {
            drawContent()
            if (focused || (onHover && hovered)) {
                drawRoundRect(
                    color = color,
                    topLeft = Offset(strokeWidth.toPx() / 2, strokeWidth.toPx() / 2),
                    size = Size(size.width - strokeWidth.toPx(), size.height - strokeWidth.toPx()),
                    cornerRadius = CornerRadius(cornerRadius.toPx()),
                    style = Stroke(width = strokeWidth.toPx()),
                )
            }
        }
}

/**
 * Clickable with an explicit focus ring for custom Rows/Boxes used as
 * buttons/tabs. [androidx.compose.foundation.clickable] already handles
 * Enter/Space activation, so no extra key handling is needed here.
 */
fun Modifier.appClickable(
    enabled: Boolean = true,
    showRing: Boolean = true,
    cornerRadius: Dp = 8.dp,
    onClick: () -> Unit,
): Modifier {
    val base = clickable(
        enabled = enabled,
        interactionSource = MutableInteractionSource(),
        indication = null,
    ) { onClick() }
    return if (showRing) base.appFocusRing(cornerRadius = cornerRadius) else base
}

/** 0.55→1.0 alpha oscillation used by skeletons (fixes "static skeleton" docs). */
@Composable
fun pulseAlpha(): Float {
    val transition = rememberInfiniteTransition(label = "skeleton-pulse")
    return transition.animateFloat(
        initialValue = 0.55f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(900),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "skeleton-pulse-alpha",
    ).value
}
