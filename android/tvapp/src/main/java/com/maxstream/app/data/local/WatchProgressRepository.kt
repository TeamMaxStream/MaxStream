package com.maxstream.app.data.local

import android.content.Context
import android.content.SharedPreferences
import com.maxstream.app.data.model.MediaItem
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.GlobalScope
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject

/**
 * Local watch-progress store (mirrors the Dart [WatchHistoryService] flow).
 * Persists per-title resume positions plus a timestamped "recently watched"
 * list so the native TV app can resume playback and populate the Home
 * "Continue Watching" row without the cloud-sync backend.
 */
object WatchProgressRepository {
    private const val PREFS = "maxstream_tv_watch_progress"
    private const val POSITION_SAVE_THRESHOLD_SECONDS = 30

    /** Profile-scoped key for the "recently watched" list. */
    private fun recentKey(context: Context): String {
        val profileId = ProfileScope.activeProfileId(context)
        return "recent:$profileId"
    }

    private fun prefs(context: Context): SharedPreferences =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun progressKey(context: Context, tmdbId: String, isMovie: Boolean, season: Int, episode: Int): String {
        val profileId = ProfileScope.activeProfileId(context)
        return "progress:${profileId}:$tmdbId:$isMovie:$season:$episode"
    }

    /** Resume position in seconds for the given title (0 when none). */
    fun loadPosition(context: Context, tmdbId: String, isMovie: Boolean, season: Int, episode: Int): Long {
        val key = progressKey(context, tmdbId, isMovie, season, episode)
        val raw = prefs(context).getString(key, null) ?: return 0L
        return runCatching { JSONObject(raw).optLong("position", 0L) }.getOrDefault(0L)
    }

    /**
     * Persists watch progress. Ignores positions below the save threshold so a
     * freshly opened title is never marked as "started".
     */
    fun saveProgress(
        context: Context,
        tmdbId: String,
        title: String,
        isMovie: Boolean,
        season: Int,
        episode: Int,
        positionSeconds: Long,
        durationSeconds: Long,
        posterPath: String = "",
        backdropPath: String = "",
        seriesTitle: String = "",
        episodeName: String = "",
    ) {
        if (positionSeconds <= POSITION_SAVE_THRESHOLD_SECONDS) return
        val watched = durationSeconds > 0 && positionSeconds.toFloat() / durationSeconds >= 0.9f
        val entry = JSONObject()
            .put("tmdbId", tmdbId)
            .put("title", title)
            .put("isMovie", isMovie)
            .put("season", season)
            .put("episode", episode)
            .put("position", positionSeconds)
            .put("duration", durationSeconds)
            .put("posterPath", posterPath)
            .put("backdropPath", backdropPath)
            .put("seriesTitle", seriesTitle)
            .put("episodeName", episodeName)
            .put("watchPercentage", if (durationSeconds > 0)
                positionSeconds * 100.0 / durationSeconds else 0.0)
            .put("isWatched", watched)
            .put("timestamp", System.currentTimeMillis())
        prefs(context).edit().putString(progressKey(context, tmdbId, isMovie, season, episode), entry.toString()).apply()
        upsertRecent(context, entry)
    }

    /**
     * Marks a title as fully watched (mirrors Dart
     * [WatchHistoryService.markAsWatched]). Finished items leave Continue
     * Watching regardless of the stored position/duration ratio.
     */
    fun markAsWatched(
        context: Context,
        tmdbId: String,
        title: String,
        isMovie: Boolean,
        season: Int,
        episode: Int,
        posterPath: String = "",
        seriesTitle: String = "",
        episodeName: String = "",
    ) {
        val key = progressKey(context, tmdbId, isMovie, season, episode)
        val existing = prefs(context).getString(key, null)
        val entry = (existing?.let { runCatching { JSONObject(it) }.getOrNull() } ?: JSONObject())
            .put("tmdbId", tmdbId)
            .put("title", title)
            .put("isMovie", isMovie)
            .put("season", season)
            .put("episode", episode)
            .put("isWatched", true)
            .put("watchPercentage", 100.0)
            .put("timestamp", System.currentTimeMillis())
        if (posterPath.isNotEmpty()) entry.put("posterPath", posterPath)
        if (seriesTitle.isNotEmpty()) entry.put("seriesTitle", seriesTitle)
        if (episodeName.isNotEmpty()) entry.put("episodeName", episodeName)
        prefs(context).edit().putString(key, entry.toString()).apply()
        upsertRecent(context, entry)
    }

    /**
     * Imports an entry pulled from the cloud into local storage, preserving the
     * cloud's timestamp so Continue Watching keeps the same ordering as the
     * phone. Mirrors the Dart [WatchHistoryService.importWatchProgress] flow.
     *
     * @return true when the stored entry changed (new or different) — lets the
     *         caller decide whether to bump a refresh revision.
     */
    fun importCloudEntry(
        context: Context,
        tmdbId: String,
        title: String,
        isMovie: Boolean,
        season: Int,
        episode: Int,
        positionSeconds: Long,
        durationSeconds: Long,
        posterPath: String,
        backdropPath: String,
        timestamp: Long,
        seriesTitle: String = "",
        episodeName: String = "",
        isWatched: Boolean = false,
    ): Boolean {
        // Completed entries are real history too: the phone keeps a 100%
        // entry so Watch History can show it, even when its resume position is
        // zero. Only drop barely-started, unfinished entries.
        if (positionSeconds <= POSITION_SAVE_THRESHOLD_SECONDS && !isWatched) return false
        val entry = JSONObject()
            .put("tmdbId", tmdbId)
            .put("title", title)
            .put("isMovie", isMovie)
            .put("season", season)
            .put("episode", episode)
            .put("position", positionSeconds)
            .put("duration", durationSeconds)
            .put("posterPath", posterPath)
            .put("backdropPath", backdropPath)
            .put("seriesTitle", seriesTitle)
            .put("episodeName", episodeName)
            .put("watchPercentage", when {
                isWatched -> 100.0
                durationSeconds > 0 -> positionSeconds * 100.0 / durationSeconds
                else -> 0.0
            })
            .put("isWatched", isWatched)
            .put("timestamp", if (timestamp > 0L) timestamp else System.currentTimeMillis())
        val key = progressKey(context, tmdbId, isMovie, season, episode)
        val before = prefs(context).getString(key, null)
        if (before != null) {
            val existingTs = runCatching { JSONObject(before).optLong("timestamp", 0L) }.getOrDefault(0L)
            val existingWatched = runCatching { JSONObject(before).optBoolean("isWatched", false) }.getOrDefault(false)
            val incomingTs = if (timestamp > 0L) timestamp else System.currentTimeMillis()
            // Don't downgrade from watched to unwatched
            if (existingWatched && !isWatched) return false
            // Never overwrite with older data
            if (incomingTs <= existingTs) return false
        }
        val changed = before != entry.toString()
        prefs(context).edit().putString(key, entry.toString()).apply()
        upsertRecent(context, entry)
        return changed
    }

    /** Clears the resume position (used when the user watches to the end). */
    fun clearPosition(context: Context, tmdbId: String, isMovie: Boolean, season: Int, episode: Int) {
        prefs(context).edit().remove(progressKey(context, tmdbId, isMovie, season, episode)).apply()
    }

    /**
     * Removes an entry entirely (progress key + recent list). Used by cloud
     * reconciliation so a title deleted on the phone disappears from the TV.
     */
    fun removeEntry(context: Context, tmdbId: String, isMovie: Boolean, season: Int, episode: Int) {
        prefs(context).edit().remove(progressKey(context, tmdbId, isMovie, season, episode)).apply()
        val current = runCatching {
            JSONArray(prefs(context).getString(recentKey(context), "[]"))
        }.getOrDefault(JSONArray())
        val key = if (isMovie) "$tmdbId:movie" else "$tmdbId:tv:$season:$episode"
        val filtered = JSONArray()
        for (i in 0 until current.length()) {
            val item = current.optJSONObject(i) ?: continue
            val itemKey = if (item.optBoolean("isMovie")) {
                "${item.optString("tmdbId")}:movie"
            } else {
                "${item.optString("tmdbId")}:tv:${item.optInt("season", 1)}:${item.optInt("episode", 1)}"
            }
            if (itemKey != key) filtered.put(item)
        }
        prefs(context).edit().putString(recentKey(context), filtered.toString()).apply()
    }

    /** Recently-watched entries, newest first, for the Home Continue Watching row. */
    fun recent(context: Context, limit: Int = 20): List<WatchEntry> {
        val raw = prefs(context).getString(recentKey(context), null) ?: return emptyList()
        return runCatching {
            val arr = JSONArray(raw)
            (0 until arr.length()).mapNotNull { i ->
                runCatching { WatchEntry.fromJson(arr.getJSONObject(i)) }.getOrNull()
            }
        }.getOrDefault(emptyList())
            // Newest first — matches Dart WatchHistoryService.getContinueWatching(),
            // which sorts by timestamp descending.
            .sortedByDescending { it.timestamp }
            .take(limit)
    }

    /** Complete local history for the Watch History screen (newest first). */
    fun history(context: Context): List<WatchEntry> = recent(context, limit = Int.MAX_VALUE)

    /** Looks up one stored entry by its deterministic movie/episode key. */
    fun find(
        context: Context,
        tmdbId: String,
        isMovie: Boolean,
        season: Int,
        episode: Int,
    ): WatchEntry? = history(context).firstOrNull {
        it.tmdbId == tmdbId &&
            it.isMovie == isMovie &&
            (isMovie || (it.season == season && it.episode == episode))
    }

    /** Removes every episode of a series, leaving other titles untouched. */
    fun removeSeries(context: Context, tmdbId: String) {
        val profileId = ProfileScope.activeProfileId(context)
        val editor = prefs(context).edit()
        val progressPrefix = "progress:$profileId:$tmdbId:"
        prefs(context).all.keys
            .filter { it.startsWith(progressPrefix) }
            .forEach { editor.remove(it) }
        editor.apply()

        val current = runCatching {
            JSONArray(prefs(context).getString(recentKey(context), "[]"))
        }.getOrDefault(JSONArray())
        val filtered = JSONArray()
        for (i in 0 until current.length()) {
            val item = current.optJSONObject(i) ?: continue
            if (item.optString("tmdbId") != tmdbId || item.optBoolean("isMovie")) {
                filtered.put(item)
            }
        }
        prefs(context).edit().putString(recentKey(context), filtered.toString()).apply()
    }

    /** Wipes the active profile's local history (resume keys + recent list). */
    fun clearAll(context: Context) {
        val profileId = ProfileScope.activeProfileId(context)
        val editor = prefs(context).edit()
        val progressPrefix = "progress:$profileId:"
        prefs(context).all.keys
            .filter { it.startsWith(progressPrefix) || it == recentKey(context) }
            .forEach { editor.remove(it) }
        editor.apply()
    }

    private fun upsertRecent(context: Context, entry: JSONObject) {
        val current = runCatching {
            JSONArray(prefs(context).getString(recentKey(context), "[]"))
        }.getOrDefault(JSONArray())
        // Same key as Dart's global history dedup: movies match on tmdbId only,
        // series on tmdbId+season+episode, so different episodes of a series
        // each stay in Continue Watching with their own cover art.
        val key = if (entry.optBoolean("isMovie")) {
            "${entry.optString("tmdbId")}:movie"
        } else {
            "${entry.optString("tmdbId")}:tv:${entry.optInt("season", 1)}:${entry.optInt("episode", 1)}"
        }
        val filtered = JSONArray()
        for (i in 0 until current.length()) {
            val item = current.optJSONObject(i) ?: continue
            val itemKey = if (item.optBoolean("isMovie")) {
                "${item.optString("tmdbId")}:movie"
            } else {
                "${item.optString("tmdbId")}:tv:${item.optInt("season", 1)}:${item.optInt("episode", 1)}"
            }
            if (itemKey != key) filtered.put(item)
        }
        filtered.put(entry)
        // Match Dart's _maxHistoryItems cap so a long-running profile never
        // grows SharedPreferences without bound. Entries are appended oldest →
        // newest, so keep the tail (the newest) when trimming.
        val capped = JSONArray()
        val start = maxOf(0, filtered.length() - 50)
        for (i in start until filtered.length()) capped.put(filtered.getJSONObject(i))
        prefs(context).edit().putString(recentKey(context), capped.toString()).apply()
    }
}

/**
 * Holds the application [Context] (set from MainActivity) so the pure
 * [MediaItem] model can expose a watch-progress fraction for Continue
 * Watching cards without threading a Context through the data layer.
 */
object WatchEntryCompat {
    @Volatile
    private var appContext: Context? = null

    fun init(context: Context) {
        appContext = context.applicationContext
    }

    fun progressOf(tmdbId: Int, mediaType: String, season: Int, episode: Int): Float {
        val context = appContext ?: return 0f
        val profileId = ProfileScope.activeProfileId(context)
        val prefs = context.getSharedPreferences("maxstream_tv_watch_progress", Context.MODE_PRIVATE)
        val key = "progress:$profileId:$tmdbId:${mediaType == "movie"}:$season:$episode"
        val raw = prefs.getString(key, null) ?: return 0f
        return runCatching {
            val obj = JSONObject(raw)
            val position = obj.optLong("position", 0L)
            val duration = obj.optLong("duration", 0L)
            if (duration > 0) {
                (position.toFloat() / duration.toFloat()).coerceIn(0f, 1f)
            } else 0f
        }.getOrDefault(0f)
    }

    /**
     * Returns Continue Watching entries for a specific title — used by
     * DetailsScreen to show the resume row (mirrors Dart's _continueWatching
     * filter in TvCinematicDetails._load()). Finished (isWatched / >= 90%)
     * and barely-started (<= 30s) items are dropped, exactly like Dart's
     * WatchHistoryService.getContinueWatching().
     */
    fun getEntriesFor(tmdbId: Int, isTv: Boolean): List<Entry> {
        val context = appContext ?: return emptyList()
        return WatchProgressRepository.recent(context)
            .filter { it.tmdbId == tmdbId.toString() && it.isMovie == !isTv }
            .filter { it.isVisibleInContinueWatching() }
            .take(6)
            .map { entry ->
                Entry(
                    tmdbId = entry.tmdbId,
                    title = entry.title,
                    seriesTitle = entry.seriesTitle,
                    episodeName = entry.episodeName,
                    season = entry.season,
                    episode = entry.episode,
                    position = entry.positionSeconds,
                    duration = entry.durationSeconds,
                    posterUrl = entry.coverUrl,
                    isWatched = entry.isWatched,
                )
            }
    }

    /** Simplified entry for UI consumption (DetailsScreen continue-watching row). */
    data class Entry(
        val tmdbId: String,
        val title: String,
        val seriesTitle: String,
        val episodeName: String,
        val season: Int,
        val episode: Int,
        val position: Long,
        val duration: Long,
        val posterUrl: String,
        val isWatched: Boolean = false,
    ) {
        val progress: Float
            get() = if (duration > 0) {
                (position.toFloat() / duration.toFloat()).coerceIn(0f, 1f)
            } else 0f
    }
}

/** A single "Continue Watching" entry reconstructed from stored JSON. */
data class WatchEntry(
    val tmdbId: String,
    val title: String,
    val isMovie: Boolean,
    val season: Int,
    val episode: Int,
    val positionSeconds: Long,
    val durationSeconds: Long,
    val posterPath: String,
    val backdropPath: String,
    val seriesTitle: String = "",
    val episodeName: String = "",
    val timestamp: Long = 0L,
    val isWatched: Boolean = false,
) {
    val progress: Float
        get() = if (durationSeconds > 0) {
            (positionSeconds.toFloat() / durationSeconds.toFloat()).coerceIn(0f, 1f)
        } else 0f

    /**
     * Whether this entry belongs on a Continue Watching row. Mirrors Dart's
     * WatchHistoryService.getContinueWatching() filter: drop barely-started
     * (<= 30s), finished (isWatched), and >= 90% watched items.
     */
    fun isVisibleInContinueWatching(): Boolean =
        positionSeconds > 30L &&
            durationSeconds > 0L &&
            positionSeconds.toFloat() / durationSeconds < 0.9f &&
            !isWatched

    /** The display title — for series use the series title, not the episode name. */
    val displayTitle: String
        get() = seriesTitle.ifBlank { title }

    /** Poster path that may already be a full still URL (episode cover art). */
    val coverUrl: String
        get() = if (posterPath.startsWith("http://") || posterPath.startsWith("https://")) {
            posterPath
        } else {
            "https://image.tmdb.org/t/p/w500$posterPath"
        }

    fun toMediaItem(): MediaItem = MediaItem(
        id = tmdbId.toIntOrNull() ?: 0,
        mediaType = if (isMovie) "movie" else "tv",
        title = displayTitle,
        overview = "",
        posterPath = posterPath.ifEmpty { null },
        backdropPath = backdropPath.ifEmpty { null },
        releaseDate = "",
        voteAverage = 0.0,
        genreIds = emptyList(),
        season = season,
        episode = episode,
        seriesTitle = seriesTitle,
        episodeName = episodeName,
    )

    companion object {
        fun fromJson(json: JSONObject): WatchEntry = WatchEntry(
            tmdbId = json.optString("tmdbId"),
            title = json.optString("title"),
            isMovie = json.optBoolean("isMovie"),
            season = json.optInt("season", 1),
            episode = json.optInt("episode", 1),
            positionSeconds = json.optLong("position", 0L),
            durationSeconds = json.optLong("duration", 0L),
            posterPath = json.optString("posterPath"),
            backdropPath = json.optString("backdropPath"),
            seriesTitle = json.optString("seriesTitle"),
            episodeName = json.optString("episodeName"),
            timestamp = json.optLong("timestamp", 0L),
            isWatched = json.optBoolean("isWatched", false),
        )
    }
}
