package com.maxstream.app.data.repository

import android.content.Context
import com.maxstream.app.core.Constants
import com.maxstream.app.data.local.SessionManager
import com.maxstream.app.data.local.ProfileScope
import com.maxstream.app.data.local.WatchProgressRepository
import com.maxstream.app.data.local.WatchlistRepository
import com.maxstream.app.data.model.MediaItem
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.io.IOException
import java.util.concurrent.TimeUnit

/**
 * Cloud sync for the native TV build using Firebase Realtime Database REST API.
 * Watchlist + watch-progress data lives in RTDB under
 * `users/{uid}/watchlist` and `users/{uid}/watch_history`, so the TV and phone
 * stay in sync when signed in with the same account.
 *
 * All calls authenticate as the signed-in user via the idToken passed as a
 * query parameter — no Firebase SDK needed on the TV.
 */
object CloudSyncRepository {
    private const val PROJECT_ID = "maxstream-8effc"
    private const val RTDB_BASE =
        "https://$PROJECT_ID-default-rtdb.firebaseio.com"

    private val JSON = "application/json".toMediaType()

    private val client: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(25, TimeUnit.SECONDS)
            .build()
    }

    /** Cloud watchlist keys seen during the previous poll, so we can detect
     * items that were deleted on the phone and mirror those deletions locally
     * instead of only ever adding remote items. */
    @Volatile
    private var previousCloudKeys: Set<String> = emptySet()

    /** Cloud watch-history keys from the previous poll. Used to mirror
     * deletions made on the phone/desktop into the TV's local history. */
    @Volatile
    private var previousCloudHistoryKeys: Set<String>? = null

    private fun auth(context: Context): String {
        val token = SessionManager.idToken(context)
        return if (token.isNotEmpty()) token else ""
    }

    private suspend fun ensureFreshToken(context: Context) {
        if (SessionManager.idToken(context).isEmpty()) return
        AuthRepository.ensureFreshIdToken(context)
    }

    private fun rtdbUrl(path: String, context: Context): String {
        val token = auth(context)
        val base = "$RTDB_BASE$path.json"
        return if (token.isNotEmpty()) "$base?auth=$token" else base
    }

    // ─────────────────────────────────────────────────────────────────────────
    // HTTP helpers
    // ─────────────────────────────────────────────────────────────────────────

    private suspend fun getJson(path: String, context: Context): JSONObject? =
        withContext(Dispatchers.IO) {
            repeat(2) { attempt ->
                if (attempt == 0) {
                    ensureFreshToken(context)
                } else {
                    AuthRepository.refreshIdToken(context)
                }
                val request = Request.Builder().url(rtdbUrl(path, context)).get().build()
                client.newCall(request).execute().use { response ->
                    if (response.isSuccessful) {
                        val text = response.body?.string()
                        if (text.isNullOrBlank() || text == "null") return@withContext null
                        return@withContext JSONObject(text)
                    }
                    if (response.code != 401 && response.code != 403) {
                        throw IOException("Realtime Database read failed: HTTP ${response.code}")
                    }
                }
            }
            throw IOException("Realtime Database authentication failed after token refresh")
        }

    private suspend fun putJson(path: String, body: JSONObject, context: Context) {
        withContext(Dispatchers.IO) {
            ensureFreshToken(context)
            val url = rtdbUrl(path, context)
            val request = Request.Builder().url(url)
                .put(body.toString().toRequestBody(JSON))
                .build()
            client.newCall(request).execute().use { response ->
                if (!response.isSuccessful) {
                    android.util.Log.w("CloudSyncRepo", "PUT $path failed: ${response.code} ${response.body?.string()}")
                }
            }
        }
    }

    private suspend fun deleteJson(path: String, context: Context) {
        withContext(Dispatchers.IO) {
            ensureFreshToken(context)
            val url = rtdbUrl(path, context)
            val request = Request.Builder().url(url).delete().build()
            client.newCall(request).execute().use { response ->
                if (!response.isSuccessful) {
                    android.util.Log.w("CloudSyncRepo", "DELETE $path failed: ${response.code} ${response.body?.string()}")
                }
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Watchlist
    // ─────────────────────────────────────────────────────────────────────────

    private fun watchlistKey(id: String, mediaType: String): String =
        "${id}_$mediaType"

    private fun fullUrl(path: String?): String {
        if (path.isNullOrEmpty()) return ""
        if (path.startsWith("http://") || path.startsWith("https://")) return path
        return "${Constants.TMDB_IMAGE_BASE}/w500$path"
    }

    /** Pushes a watchlist entry to RTDB (upsert). */
    suspend fun pushWatchlist(context: Context, item: MediaItem) {
        val uid = SessionManager.uid(context)
        val profileId = ProfileScope.activeProfileId(context)
        if (uid.isEmpty() || item.id == 0) return
        val key = watchlistKey(item.id.toString(), item.mediaType)
        val body = JSONObject().apply {
            put("id", item.id.toString())
            put("title", item.title)
            put("description", item.overview)
            put("thumbnail", fullUrl(item.posterPath))
            put("backdrop", fullUrl(item.backdropPath))
            put("videoUrl", "")
            put("trailerUrl", "")
            put("year", item.releaseDate.take(4))
            put("rating", item.voteAverage)
            put("mediaType", item.mediaType)
            put("country", "")
        }
        putJson("/users/$uid/profiles/$profileId/watchlist/$key", body, context)
    }

    /** Deletes a watchlist entry from RTDB. */
    suspend fun deleteWatchlist(context: Context, id: String, mediaType: String) {
        val uid = SessionManager.uid(context)
        val profileId = ProfileScope.activeProfileId(context)
        if (uid.isEmpty() || id.isEmpty()) return
        deleteJson("/users/$uid/profiles/$profileId/watchlist/${watchlistKey(id, mediaType)}", context)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Watch progress
    // ─────────────────────────────────────────────────────────────────────────

    private fun watchHistoryKey(tmdbId: String, isMovie: Boolean, season: Int, episode: Int): String =
        if (isMovie) "movie_$tmdbId" else "tv_${tmdbId}_${season}_$episode"

    private data class ParsedHistoryKey(
        val tmdbId: String,
        val isMovie: Boolean,
        val season: Int,
        val episode: Int,
    )

    /** Inverse of [watchHistoryKey] for reconciling cloud deletions. */
    private fun parseHistoryKey(key: String): ParsedHistoryKey? {
        if (key.startsWith("movie_")) {
            val id = key.removePrefix("movie_")
            return id.takeIf { it.isNotEmpty() }?.let { ParsedHistoryKey(it, true, 1, 1) }
        }
        if (key.startsWith("tv_")) {
            val parts = key.split("_")
            if (parts.size >= 4) {
                val id = parts[1]
                val season = parts[2].toIntOrNull() ?: 1
                val episode = parts[3].toIntOrNull() ?: 1
                if (id.isNotEmpty()) return ParsedHistoryKey(id, false, season, episode)
            }
        }
        return null
    }

    /** Pushes watch progress to RTDB (upsert). */
    suspend fun pushWatchProgress(
        context: Context,
        tmdbId: String,
        title: String,
        isMovie: Boolean,
        season: Int,
        episode: Int,
        positionSeconds: Long,
        durationSeconds: Long,
        posterPath: String,
        seriesTitle: String = "",
        episodeName: String = "",
        forceWatched: Boolean = false,
    ) {
        val uid = SessionManager.uid(context)
        val profileId = ProfileScope.activeProfileId(context)
        if (uid.isEmpty() || tmdbId.isEmpty()) return
        val percentage = if (durationSeconds > 0)
            (positionSeconds.toDouble() / durationSeconds * 100).coerceIn(0.0, 100.0)
        else 0.0
        val body = JSONObject().apply {
            put("tmdbId", tmdbId)
            put("title", title)
            put("isMovie", isMovie)
            put("season", season)
            put("episode", episode)
            put("posterUrl", fullUrl(posterPath))
            put("seriesTitle", seriesTitle)
            put("episodeName", episodeName)
            put("position", positionSeconds)
            put("duration", durationSeconds)
            put("watchPercentage", percentage)
            put("isWatched", forceWatched || percentage >= 90.0)
            put("timestamp", System.currentTimeMillis())
        }
        val key = watchHistoryKey(tmdbId, isMovie, season, episode)
        android.util.Log.d("CloudSyncRepo", "pushWatchProgress: $key pos=${positionSeconds}s dur=${durationSeconds}s pct=$percentage%")
        putJson("/users/$uid/profiles/$profileId/watch_history/$key", body, context)
    }

    /** Deletes watch progress from RTDB. */
    suspend fun deleteWatchProgress(
        context: Context,
        tmdbId: String,
        isMovie: Boolean,
        season: Int,
        episode: Int,
    ) {
        val uid = SessionManager.uid(context)
        val profileId = ProfileScope.activeProfileId(context)
        if (uid.isEmpty() || tmdbId.isEmpty()) return
        val key = watchHistoryKey(tmdbId, isMovie, season, episode)
        deleteJson("/users/$uid/profiles/$profileId/watch_history/$key", context)
    }

    /** Removes every episode of a series from RTDB so the phone/desktop
     * history screens drop it too. */
    suspend fun deleteSeriesWatchProgress(context: Context, tmdbId: String) {
        val uid = SessionManager.uid(context)
        val profileId = ProfileScope.activeProfileId(context)
        if (uid.isEmpty() || tmdbId.isEmpty()) return
        val path = "/users/$uid/profiles/$profileId/watch_history"
        runCatching {
            val history = getJson(path, context) ?: return
            val prefix = "tv_${tmdbId}_"
            val keys = history.keys()
            while (keys.hasNext()) {
                val key = keys.next()
                if (key.startsWith(prefix)) deleteJson("$path/$key", context)
            }
        }
    }

    /** Deletes the whole per-profile history node. Used by Clear History so
     * the removal propagates to phone and desktop in one write. */
    suspend fun deleteAllWatchProgress(context: Context) {
        val uid = SessionManager.uid(context)
        val profileId = ProfileScope.activeProfileId(context)
        if (uid.isEmpty()) return
        deleteJson("/users/$uid/profiles/$profileId/watch_history", context)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Pull (cloud → local)
    // ─────────────────────────────────────────────────────────────────────────

    /** Pulls the signed-in user's cloud data into local storage. Safe to call
     * repeatedly; missing auth or network failure is silently ignored.
     *
     * Returns which collections changed so screens can refresh. */
    suspend fun pullToDevice(context: Context): SyncChange {
        val uid = SessionManager.uid(context)
        val profileId = ProfileScope.activeProfileId(context)
        if (uid.isEmpty() || auth(context).isEmpty()) return SyncChange(false, false)

        var historyChanged = false
        var watchlistChanged = false

        runCatching {
            val pullStartedAt = System.currentTimeMillis()
            val cloudHistoryKeys = mutableSetOf<String>()
            val historyJson = getJson("/users/$uid/profiles/$profileId/watch_history", context)
            if (historyJson != null) {
                val keys = historyJson.keys()
                while (keys.hasNext()) {
                    val key = keys.next()
                    val entry = historyJson.optJSONObject(key) ?: continue
                    val tmdbId = entry.optString("tmdbId", "")
                        .ifBlank { entry.optString("itemId", "") }
                    if (tmdbId.isEmpty()) continue
                    cloudHistoryKeys += key
                    val isMovie = if (entry.has("isMovie")) {
                        entry.optBoolean("isMovie", true)
                    } else {
                        entry.optString("mediaType", "movie") != "tv"
                    }
                    val season = entry.optInt("season", 1).takeIf { it > 0 } ?: 1
                    val episode = entry.optInt("episode", 1).takeIf { it > 0 } ?: 1
                    val position = if (entry.has("position")) {
                        entry.optLong("position", 0)
                    } else {
                        entry.optLong("positionMs", 0) / 1000L
                    }
                    val duration = if (entry.has("duration")) {
                        entry.optLong("duration", 0)
                    } else {
                        entry.optLong("lengthMs", 0) / 1000L
                    }
                    val watchPercentage = entry.optDouble("watchPercentage", 0.0)
                    val isWatched = entry.optBoolean("isWatched", false) ||
                        watchPercentage >= 90.0
                    if (position <= 0L && !isWatched) continue
                    val rawTitle = entry.optString("title", tmdbId)
                    val title = if (!isMovie) {
                        entry.optString("seriesTitle").ifBlank { rawTitle }
                    } else {
                        rawTitle
                    }
                    val timestamp = entry.optLong("timestamp", 0L).takeIf { it > 0L }
                        ?: entry.optLong("updatedAt", 0L)
                    historyChanged = WatchProgressRepository.importCloudEntry(
                        context,
                        tmdbId = tmdbId,
                        title = title,
                        isMovie = isMovie,
                        season = season,
                        episode = episode,
                        positionSeconds = position,
                        durationSeconds = duration,
                        posterPath = entry.optString("posterUrl")
                            .ifBlank { entry.optString("thumbnail") }
                            .ifBlank { entry.optString("posterPath") },
                        backdropPath = entry.optString("backdropUrl")
                            .ifBlank { entry.optString("backdrop") }
                            .ifBlank { entry.optString("backdropPath") },
                        timestamp = timestamp,
                        seriesTitle = entry.optString("seriesTitle", ""),
                        episodeName = entry.optString("episodeName", ""),
                        isWatched = isWatched,
                    ) || historyChanged
                }
            }

            // Mirror deletions: anything present in the previous cloud snapshot
            // but gone now was removed on the phone or desktop. Do not delete a
            // fresh local save that raced this pull.
            // Guard: only reconcile when both the previous AND current cloud
            // snapshots are non-empty. An empty current snapshot most likely
            // means a failed or incomplete fetch — treating it as "everything
            // was deleted" would wipe the user's entire local history.
            if (cloudHistoryKeys.isNotEmpty()) {
                previousCloudHistoryKeys?.let { previous ->
                    if (previous.isNotEmpty()) {
                        for (staleKey in previous - cloudHistoryKeys) {
                            val parsed = parseHistoryKey(staleKey) ?: continue
                            val local = WatchProgressRepository.find(
                                context,
                                parsed.tmdbId,
                                parsed.isMovie,
                                parsed.season,
                                parsed.episode,
                            ) ?: continue
                            if (local.timestamp > pullStartedAt) continue
                            WatchProgressRepository.removeEntry(
                                context,
                                parsed.tmdbId,
                                parsed.isMovie,
                                parsed.season,
                                parsed.episode,
                            )
                            historyChanged = true
                        }
                    }
                }
            }
            previousCloudHistoryKeys = cloudHistoryKeys
        }

        runCatching {
            val watchlistJson = getJson("/users/$uid/profiles/$profileId/watchlist", context)
            val cloudKeys = mutableSetOf<String>()
            if (watchlistJson != null) {
                val keys = watchlistJson.keys()
                while (keys.hasNext()) {
                    val key = keys.next()
                    val entry = watchlistJson.optJSONObject(key) ?: continue
                    val id = entry.optString("id", "")
                    if (id.isEmpty()) continue
                    val mediaType = entry.optString("mediaType", "movie")
                    val item = MediaItem(
                        id = id.toIntOrNull() ?: continue,
                        mediaType = mediaType,
                        title = entry.optString("title", id),
                        overview = entry.optString("description", ""),
                        posterPath = entry.optString("thumbnail", "").ifBlank { null },
                        backdropPath = entry.optString("backdrop", "").ifBlank { null },
                        releaseDate = entry.optString("year", ""),
                        voteAverage = entry.optDouble("rating", 0.0),
                        genreIds = emptyList(),
                    )
                    if (!WatchlistRepository.isIn(context, item)) watchlistChanged = true
                    cloudKeys += key
                    WatchlistRepository.add(context, item)
                }
                // Reconcile deletions: items that were in the cloud during the
                // previous poll but are absent now were removed on another device.
                // Only delete keys that we actually saw in a prior cloud snapshot so
                // that offline-only local additions (never pushed) are preserved.
                if (previousCloudKeys.isNotEmpty()) {
                    val deletedKeys = previousCloudKeys - cloudKeys
                    for (delKey in deletedKeys) {
                        val parts = delKey.split("_")
                        if (parts.size == 2) {
                            val delId = parts[0]
                            val delType = parts[1]
                            WatchlistRepository.removeByKey(context, delId, delType)
                            watchlistChanged = true
                        }
                    }
                }
                previousCloudKeys = cloudKeys.toSet()
            } else if (previousCloudKeys.isNotEmpty()) {
                // Cloud watchlist is now empty — remove all previously-synced items.
                for (delKey in previousCloudKeys) {
                    val parts = delKey.split("_")
                    if (parts.size == 2) {
                        WatchlistRepository.removeByKey(context, parts[0], parts[1])
                        watchlistChanged = true
                    }
                }
                previousCloudKeys = emptySet()
            }
        }

        // Provider preferences (full sync) - mirrors phone's CloudSyncService
        runCatching {
            val prefsJson = getJson("/users/$uid/provider_preferences", context)
            if (prefsJson != null) {
                val prefs = context.getSharedPreferences("provider_prefs", Context.MODE_PRIVATE)
                val keys = prefsJson.keys()
                while (keys.hasNext()) {
                    val key = keys.next()
                    val entry = prefsJson.optJSONObject(key) ?: continue
                    val pid = entry.optInt("providerId", -1)
                    if (pid == -1) continue
                    val isPref = entry.optBoolean("isPreferred", false)
                    prefs.edit().putBoolean("provider_$pid", isPref).apply()
                }
            }
        }

        return SyncChange(historyChanged, watchlistChanged)
    }

    /** Result of a cloud pull: which collections actually changed. */
    data class SyncChange(
        val historyChanged: Boolean,
        val watchlistChanged: Boolean,
    )
}
