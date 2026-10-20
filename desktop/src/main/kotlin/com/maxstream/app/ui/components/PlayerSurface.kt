package com.maxstream.app.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.layout.onSizeChanged
import com.maxstream.app.player.PlaybackSession
import com.maxstream.app.player.VideoFrame
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import org.jetbrains.skia.Image
import org.jetbrains.skia.Rect

/**
 * Draws the latest libmpv frame inside the Compose scene.
 *
 * mpv renders into CPU-side RGB buffers; this composable only presents the most
 * recent one. Because the video is an ordinary Compose draw call, controls,
 * sheets and the mini-player can layer over it without heavyweight-window or
 * platform-specific interop tricks.
 */
@Composable
fun PlayerSurface(
    modifier: Modifier = Modifier,
    background: Color = Color.Black,
) {
    val controller = PlaybackSession.controller
    var frame by remember { mutableStateOf<VideoFrame?>(null) }

    LaunchedEffect(Unit) {
        var lastRevision = -1L
        while (isActive) {
            val next = controller.videoFrame
            if (next == null) {
                if (frame != null) frame = null
                lastRevision = -1L
            } else if (next.revision != lastRevision) {
                frame = next
                lastRevision = next.revision
            }
            // Frames arrive at video rate, not necessarily at the compositor's
            // rate; a short poll keeps the UI from holding a stale frame when a
            // paused/seeked stream produces a redraw.
            delay(8)
        }
    }

    Box(
        modifier
            .clipToBounds()
            .background(background)
            .onSizeChanged { size ->
                controller.setVideoViewport(size.width, size.height)
            }
            .drawBehind {
                val current = frame ?: return@drawBehind
                drawIntoCanvas { canvas ->
                    val image = Image.makeRaster(
                        current.info,
                        current.data,
                        current.rowBytes,
                    )
                    try {
                        canvas.nativeCanvas.drawImageRect(
                            image,
                            Rect.makeWH(current.width.toFloat(), current.height.toFloat()),
                            Rect.makeWH(size.width, size.height),
                        )
                    } finally {
                        image.close()
                    }
                }
            },
    )
}
