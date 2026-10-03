package com.maxstream.app.ui.components

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ChevronRight
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.KeyEvent
import androidx.compose.ui.input.key.onKeyEvent
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

// ─────────────────────────────────────────────────────────────────────────────
// Trailing "See All" cell — the `>` you scroll right to at the end of a row.
//
// It sits in the LazyRow after the last card: RIGHT past the final card lands
// on it, ENTER opens the full list for that row, LEFT returns to the last card.
// It matches the row's card footprint so it never changes the row height.
// ─────────────────────────────────────────────────────────────────────────────

@Composable
fun SeeAllCell(
    focusRequester: FocusRequester,
    cardHeight: Dp,
    cardWidth: Dp = 130.dp,
    label: String = "See All",
    onClick: () -> Unit,
    onFocusChanged: (Boolean) -> Unit = {},
    onKeyEvent: (KeyEvent) -> Boolean = { false },
    modifier: Modifier = Modifier,
) {
    var focused by remember { mutableStateOf(false) }

    // Same focus pop as ContentCard: 1.02 scale drawn through graphicsLayer so
    // the cell's measured bounds never change.
    val scale by animateFloatAsState(
        targetValue = if (focused) 1.02f else 1f,
        animationSpec = tween(180),
        label = "seeAllCellScale",
    )

    Box(
        modifier = modifier
            .graphicsLayer {
                scaleX = scale
                scaleY = scale
            }
            .onKeyEvent(onKeyEvent)
            .focusRequester(focusRequester)
            .onFocusChanged {
                focused = it.hasFocus
                onFocusChanged(it.hasFocus)
            }
            // Focus must be registered BEFORE clickable so D-pad Enter fires.
            .focusable()
            .clickable(onClick = onClick)
            .width(cardWidth)
            .height(cardHeight)
            .clip(RoundedCornerShape(10.dp))
            .background(Color(0x14FFFFFF))
            // Identical to ContentCard: a constant 2.dp white ring drawn on top.
            .focusRing(visible = focused, cornerRadius = 10.dp),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier.padding(8.dp),
        ) {
            Icon(
                imageVector = Icons.Outlined.ChevronRight,
                contentDescription = label,
                tint = Color.White,
                modifier = Modifier.size(46.dp),
            )
            Spacer(Modifier.height(4.dp))
            Text(
                text = label,
                color = Color.White.copy(alpha = 0.8f),
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                textAlign = TextAlign.Center,
            )
        }
    }
}
