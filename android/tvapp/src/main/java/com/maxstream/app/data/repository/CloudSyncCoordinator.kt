package com.maxstream.app.data.repository

import android.content.Context
import com.maxstream.app.data.local.ProfileScope
import com.maxstream.app.data.local.SessionManager
import com.maxstream.app.data.local.SubtitleSettingsRepository
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * Continuous cloud-sync coordinator for the TV, mirroring the Dart phone app's
 * `CloudSyncService.startListening()` real-time listener.
 *
 * While the user is signed in, a background loop re-pulls the phone's watch
 * progress + watchlist + profiles from Realtime Database every [SYNC_INTERVAL_MS].
 * Any change bumps the matching revision [StateFlow] — the Home/Details/Library
 * screens collect these and refresh, so a title watched (or un-watched) on the phone
 * appears on the TV within a few seconds, just like the Dart listener did.
 *
 * Profiles are synced every [PROFILE_SYNC_INTERVAL_MS] so phone-created profiles
 * appear on TV and vice versa.
 */
object CloudSyncCoordinator {
    private const val SYNC_INTERVAL_MS = 10_000L
    private const val PROFILE_SYNC_INTERVAL_MS = 30_000L

    private val _historyRevision = MutableStateFlow(0)
    private val _watchlistRevision = MutableStateFlow(0)

    /** Bumped whenever synced watch history changed (Dart historyRevision). */
    val historyRevision: StateFlow<Int> = _historyRevision.asStateFlow()

    /** Bumped whenever synced watchlist changed (Dart watchlistRevision). */
    val watchlistRevision: StateFlow<Int> = _watchlistRevision.asStateFlow()

    @Volatile
    private var started = false
    private var job: Job? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /** Starts the background sync loop (no-op if already running). */
    fun start(context: Context) {
        if (started) return
        started = true
        job = scope.launch {
            var lastProfileSync = 0L
            while (isActive) {
                if (SessionManager.isLoggedIn(context)) {
                    // The stored Firebase idToken expires after ~1h; refresh it
                    // first so Realtime Database REST calls don't silently 401/403.
                    try { AuthRepository.ensureFreshIdToken(context) } catch (_: Exception) {}
                    val fbChange = try {
                        CloudSyncRepository.pullToDevice(context)
                    } catch (_: Exception) {
                        CloudSyncRepository.SyncChange(false, false)
                    }
                    if (fbChange.historyChanged) _historyRevision.value++
                    if (fbChange.watchlistChanged) _watchlistRevision.value++
                    try { SubtitleSettingsRepository.pullFromCloud(context) } catch (_: Exception) {}

                    // Sync profiles periodically so phone-created profiles appear on TV
                    val now = System.currentTimeMillis()
                    if (now - lastProfileSync >= PROFILE_SYNC_INTERVAL_MS) {
                        lastProfileSync = now
                        try { ProfileRepository.pullProfiles(context) } catch (_: Exception) {}
                    }
                }
                delay(SYNC_INTERVAL_MS)
            }
        }
    }

    /** Stops the background sync loop. */
    fun stop() {
        started = false
        job?.cancel()
        job = null
    }
}
