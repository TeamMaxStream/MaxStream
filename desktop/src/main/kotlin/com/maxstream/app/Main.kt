package com.maxstream.app

import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application
import androidx.compose.ui.window.rememberWindowState
import com.maxstream.app.data.AppPrefs
import com.maxstream.app.data.cloud.AppSession
import com.maxstream.app.data.cloud.ProfileStore
import com.maxstream.app.download.DownloadManager
import com.maxstream.app.player.MpvRuntime
import com.maxstream.app.player.PlaybackSession
import com.maxstream.app.ui.Shell
import com.maxstream.app.update.UpdateService

fun main() {
    // One-time bootstrap, strictly before the first composition. Running these
    // inside application { } would re-execute them on every recomposition
    // (re-reading AppSession could clobber an in-flight token refresh).
    runCatching { MpvRuntime.ensure() }
        .onFailure { e -> System.err.println("libmpv runtime init failed (playback will not start): $e") }
    runCatching { AppSession.restore() }
        .onFailure { e -> System.err.println("Session restore failed (signed out): $e") }
    runCatching { ProfileStore.restoreLocal() }
        .onFailure { e -> System.err.println("Profile restore failed: $e") }
    runCatching { AppPrefs.restore() }
        .onFailure { e -> System.err.println("Prefs restore failed (defaults used): $e") }
    runCatching { DownloadManager.restore() }
        .onFailure { e -> System.err.println("Download queue restore failed: $e") }
    // Non-blocking: the shell paints immediately, the banner appears if a
    // newer desktop build is published.
    UpdateService.checkInBackground()

    application {
        val windowState = rememberWindowState(width = 1320.dp, height = 840.dp)
        Window(
            onCloseRequest = {
                // Stop the event loop and unload the native library before the JVM
                // exits; otherwise libmpv's threads can keep the process alive.
                runCatching { PlaybackSession.stop() }
                runCatching { PlaybackSession.controller.release() }
                exitApplication()
            },
            state = windowState,
            title = "MaxStream",
        ) {
            Shell(windowState = windowState)
        }
    }
}
