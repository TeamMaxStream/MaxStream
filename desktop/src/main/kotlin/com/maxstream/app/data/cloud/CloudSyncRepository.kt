package com.maxstream.app.data.cloud

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.setValue
import com.maxstream.app.core.AppConfig
import com.maxstream.app.data.WatchStateStore
import com.maxstream.app.data.model.MediaItem
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/**
 * Firebase Realtime Database sync for the desktop client — watchlist + watch
 * history, stored under the same paths the TV app uses
 * (/users/{uid}/profiles/{profile}/...). All calls are signed-out safe: they
 * no-op and return empty results until a Firebase session exists.
 */
object CloudSync {

    private val jsonType = "application/json; charset=utf-8".toMediaType()

    private val http = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(15, TimeUnit.SECONDS)
        .build()

    val isSynced: Boolean get() = AppSession.isSignedIn

    /**
     * Bumped after every cloud pull so screens that render watchlist /
     * continue-watching re-read local state (same pattern as TV's
     * CloudSyncCoordinator and mobile's historyRevision).
     */
    var dataRevision by mutableIntStateOf(0)
        private set

    /** Cloud history keys from the previous pull, so deletions made on the
     * phone/TV are mirrored locally instead of only additions syncing. */
    private var previousCloudHistoryKeys: Set<String>? = null

    fun bump() {
        dataRevision++
    }

    // ── watchlist ────────────────────────────────────────────────────────────

    suspend fun watchlist(): List<MediaItem> = authed { token, base ->
        val root = get("$base/watchlist.json", token) ?: return@authed emptyList()
        val out = mutableListOf<MediaItem>()
        root.keys().forEach { key ->
            val o = root.optJSONObject(key) ?: return@forEach
            out += MediaItem(
                // Mobile + TV write `id`; older desktop builds wrote `mediaId`.
                id = o.optString("id").ifBlank { o.optString("mediaId") },
                title = o.optString("title"),
                mediaType = o.optString("mediaType", "movie"),
                overview = o.optString("overview").ifBlank { o.optString("description") },
                year = o.optInt("year", 0).takeIf { it > 0 },
                rating = o.optDouble("rating", 0.0),
                posterPath = o.optString("thumbnail")
                    .ifBlank { o.optString("posterUrl") }
                    .ifBlank { o.optString("posterPath") }
                    .ifBlank { null },
                backdropPath = o.optString("backdrop")
                    .ifBlank { o.optString("backdropUrl") }
                    .ifBlank { o.optString("backdropPath") }
                    .ifBlank { null },
            )
        }
        out
    } ?: emptyList()

    suspend fun isInWatchlist(id: String): Boolean = authed { token, base ->
        get("$base/watchlist.json", token)
            ?.let { root ->
                root.keys().asSequence().any { k ->
                    val entry = root.optJSONObject(k) ?: return@any false
                    val storedId = entry.optString("id").ifBlank { entry.optString("mediaId") }
                    storedId == id
                }
            }
            ?: false
    } ?: false

    suspend fun addToWatchlist(item: MediaItem) {
        authed { token, base ->
            val key = "${item.id}_${item.mediaType}"
            put(
                "$base/watchlist/$key.json",
                JSONObject()
                    // `id` is the mobile/TV schema; `mediaId` is kept so older
                    // desktop builds can still read entries written here.
                    .put("id", item.id)
                    .put("mediaId", item.id)
                    .put("mediaType", item.mediaType)
                    .put("title", item.title)
                    .put("description", item.overview)
                    .put("overview", item.overview)
                    .put("thumbnail", AppConfig.posterUrl(item.posterPath).orEmpty())
                    .put("posterUrl", AppConfig.posterUrl(item.posterPath).orEmpty())
                    .put("posterPath", item.posterPath ?: "")
                    .put("backdrop", AppConfig.backdropUrl(item.backdropPath).orEmpty())
                    .put("backdropUrl", AppConfig.backdropUrl(item.backdropPath).orEmpty())
                    .put("backdropPath", item.backdropPath ?: "")
                    .put("videoUrl", "")
                    .put("trailerUrl", "")
                    .put("year", item.year ?: 0)
                    .put("rating", item.rating)
                    .put("country", "")
                    .put("addedAt", System.currentTimeMillis()),
                token,
            )
        }
    }

    suspend fun removeFromWatchlist(item: MediaItem) {
        authed { token, base ->
            val key = "${item.id}_${item.mediaType}"
            delete("$base/watchlist/$key.json", token)
        }
    }

    // ── watch history / progress ─────────────────────────────────────────────

    /** RTDB child key for one watch-history entry (matches mobile/TV). */
    internal fun historyKey(s: WatchStateStore.WatchState): String =
        if (s.mediaType == "tv") "tv_${s.itemId}_${s.season}_${s.episode}" else "movie_${s.itemId}"

    /**
     * JSON body for one watch-history PUT. Uses the same schema as the phone
     * and TV (`tmdbId` / `isMovie` / `position` in seconds) so all three apps
     * can read each other's entries. Legacy desktop fields are still written
     * for older clients.
     */
    internal fun historyPayload(s: WatchStateStore.WatchState): JSONObject = JSONObject()
        .put("tmdbId", s.itemId)
        .put("isMovie", s.mediaType != "tv")
        .put("title", s.title)
        .put("seriesTitle", if (s.mediaType == "tv") s.title else "")
        .put("episodeName", "")
        .put("posterUrl", AppConfig.posterUrl(s.posterPath).orEmpty())
        .put("backdropUrl", AppConfig.backdropUrl(s.backdropPath).orEmpty())
        .put("position", s.positionMs / 1000L)
        .put("duration", s.lengthMs / 1000L)
        .put("watchPercentage", s.progress * 100.0)
        .put("isWatched", s.isWatched || s.progress >= 0.9f)
        .put("genreIds", JSONArray(s.genreIds))
        .put("timestamp", s.updatedAt)
        // Legacy desktop fields (previous releases read only these).
        .put("itemId", s.itemId)
        .put("mediaType", s.mediaType)
        .put("season", s.season)
        .put("episode", s.episode)
        .put("positionMs", s.positionMs)
        .put("lengthMs", s.lengthMs)
        .put("progress", s.progress)
        .put("posterPath", s.posterPath ?: "")
        .put("backdropPath", s.backdropPath ?: "")
        .put("year", s.year ?: 0)
        .put("rating", s.rating)
        .put("updatedAt", s.updatedAt)

    suspend fun pushWatchHistory(s: WatchStateStore.WatchState) {
        authed { token, base ->
            put("$base/watch_history/${historyKey(s)}.json", historyPayload(s), token)
        }
    }

    /** Pulls cloud watch history into the local store; returns # merged. */
    suspend fun syncWatchHistory(): Int = authed { token, base ->
        val pullStartedAt = System.currentTimeMillis()
        val fetched = getWithSuccess("$base/watch_history.json", token) ?: return@authed 0
        if (!fetched.first) return@authed 0
        val root = fetched.second
        val cloudKeys = mutableSetOf<String>()
        val states = mutableListOf<WatchStateStore.WatchState>()
        root?.keys()?.forEach { key ->
            val o = root.optJSONObject(key) ?: return@forEach
            val itemId = o.optString("tmdbId").ifBlank { o.optString("itemId") }
            if (itemId.isBlank()) return@forEach
            val isMovie = if (o.has("isMovie")) o.optBoolean("isMovie", true)
            else o.optString("mediaType", "movie") != "tv"
            val mediaType = if (isMovie) "movie" else "tv"
            val season = o.optInt("season", 1).takeIf { it > 0 } ?: 1
            val episode = o.optInt("episode", 1).takeIf { it > 0 } ?: 1
            cloudKeys += key
            val legacyPositionMs = o.optLong("positionMs", 0L)
            val legacyLengthMs = o.optLong("lengthMs", 0L)
            val legacyTimestamp = o.optLong("updatedAt", 0L)
            states += WatchStateStore.WatchState(
                itemId = itemId,
                mediaType = mediaType,
                season = season,
                episode = episode,
                positionMs = if (o.has("position")) o.optLong("position", 0L) * 1000L
                else legacyPositionMs,
                lengthMs = if (o.has("duration")) o.optLong("duration", 0L) * 1000L
                else legacyLengthMs,
                updatedAt = o.optLong("timestamp", 0L).takeIf { it > 0L }
                    ?: legacyTimestamp.takeIf { it > 0L }
                    ?: System.currentTimeMillis(),
                title = if (!isMovie) {
                    o.optString("seriesTitle").ifBlank { o.optString("title") }
                } else {
                    o.optString("title")
                },
                posterPath = o.optString("posterUrl")
                    .ifBlank { o.optString("thumbnail") }
                    .ifBlank { o.optString("posterPath") }
                    .ifBlank { null },
                backdropPath = o.optString("backdropUrl")
                    .ifBlank { o.optString("backdrop") }
                    .ifBlank { o.optString("backdropPath") }
                    .ifBlank { null },
                year = o.optInt("year", 0).takeIf { it > 0 },
                rating = o.optDouble("rating", 0.0),
                genreIds = o.optJSONArray("genreIds")?.let { arr ->
                    (0 until arr.length()).map { i -> arr.optInt(i) }
                } ?: emptyList(),
                isWatched = o.optBoolean("isWatched", false) ||
                    o.optDouble("watchPercentage", 0.0) >= 90.0,
            )
        }
        var changed = WatchStateStore.mergeIncoming(states)

        // Mirror deletions made on the phone/TV. Only entries seen in the
        // previous cloud snapshot are eligible, so locally-created history is
        // never removed just because a pull raced the first progress push.
        previousCloudHistoryKeys?.let { previous ->
            WatchStateStore.all().forEach { s ->
                val key = historyKey(s)
                if (key in previous && key !in cloudKeys && s.updatedAt <= pullStartedAt) {
                    WatchStateStore.clear(s.itemId, s.season, s.episode)
                    changed++
                }
            }
        }
        previousCloudHistoryKeys = cloudKeys
        if (changed > 0) bump()
        changed
    } ?: 0

    suspend fun clearWatchHistory(s: WatchStateStore.WatchState) {
        authed { token, base ->
            val key = if (s.mediaType == "tv") "tv_${s.itemId}_${s.season}_${s.episode}" else "movie_${s.itemId}"
            delete("$base/watch_history/$key.json", token)
        }
    }

    /** Deletes the whole per-profile history node, propagating Clear History
     * to the phone and TV in one write. */
    suspend fun clearAllWatchHistory() {
        authed { token, base ->
            delete("$base/watch_history.json", token)
        }
    }

    // ── RTDB helpers ─────────────────────────────────────────────────────────

    /**
     * Runs [block] with the RTDB base + auth token when signed in; returns
     * null otherwise so every cloud call is signed-out safe. Any network or
     * parse failure inside [block] is logged and treated as "no data" instead
     * of propagating — previously an IOException escaped into the callers'
     * unguarded coroutines and permanently killed the 10s progress-save loop,
     * the sync pull, and watchlist toggles after a single connection blip.
     */
    private suspend fun <T> authed(block: (token: String, base: String) -> T): T? {
        val token = AppSession.freshToken() ?: return null
        val user = AppSession.user ?: return null
        return try {
            withContext(Dispatchers.IO) {
                block(token, rtdbBase(user.localId))
            }
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            System.err.println("CloudSync: request failed: $e")
            null
        }
    }

    private fun rtdbBase(uid: String): String {
        // Match mobile ProfileScope.currentProfileId: active profile, else UID
        // (mobile never writes under literal "default").
        val profile = ProfileStore.activeProfileId ?: uid
        return "${AppConfig.FIREBASE_RTDB_URL}/users/$uid/profiles/$profile"
    }

    /**
     * GET that distinguishes an empty/deleted node (successful request with a
     * `null` body) from a network failure. History deletion reconciliation
     * must never wipe local state just because the request failed.
     */
    private fun getWithSuccess(url: String, token: String): Pair<Boolean, JSONObject?>? = try {
        val request = Request.Builder()
            .url("$url?auth=$token")
            .header("Accept", "application/json")
            .build()
        http.newCall(request).execute().use { res ->
            if (!res.isSuccessful) {
                System.err.println("CloudSync: GET $url -> HTTP ${res.code}")
                false to null
            } else {
                val body = res.body?.string().orEmpty()
                val json = runCatching { JSONObject(body) }
                    .onFailure { System.err.println("CloudSync: GET $url parse error: $it") }
                    .getOrNull()
                true to json
            }
        }
    } catch (e: Exception) {
        System.err.println("CloudSync: GET $url failed: $e")
        null
    }

    private fun get(url: String, token: String): JSONObject? = try {
        val request = Request.Builder()
            .url("$url?auth=$token")
            .header("Accept", "application/json")
            .build()
        http.newCall(request).execute().use { res ->
            when {
                res.code == 404 -> null
                !res.isSuccessful -> {
                    System.err.println("CloudSync: GET $url -> HTTP ${res.code}")
                    null
                }
                else -> runCatching { JSONObject(res.body?.string().orEmpty()) }
                    .onFailure { System.err.println("CloudSync: GET $url parse error: $it") }
                    .getOrNull()
            }
        }
    } catch (e: Exception) {
        System.err.println("CloudSync: GET $url failed: $e")
        null
    }

    private fun put(url: String, body: JSONObject, token: String) = try {
        val request = Request.Builder()
            .url("$url?auth=$token")
            .put(body.toString().toRequestBody(jsonType))
            .build()
        http.newCall(request).execute().use { res ->
            // Surface denials (e.g. RTDB rule rejections) instead of the old
            // execute().close() that swallowed every status code.
            if (!res.isSuccessful) {
                System.err.println(
                    "CloudSync: PUT $url -> HTTP ${res.code} ${res.body?.string()?.take(300).orEmpty()}",
                )
            }
        }
    } catch (e: Exception) {
        System.err.println("CloudSync: PUT $url failed: $e")
    }

    private fun delete(url: String, token: String) = try {
        val request = Request.Builder()
            .url("$url?auth=$token")
            .delete()
            .build()
        http.newCall(request).execute().use { res ->
            if (!res.isSuccessful && res.code != 404) {
                System.err.println("CloudSync: DELETE $url -> HTTP ${res.code}")
            }
        }
    } catch (e: Exception) {
        System.err.println("CloudSync: DELETE $url failed: $e")
    }
}