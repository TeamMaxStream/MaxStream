package com.maxstream.app.data

import com.maxstream.app.core.AtomicFiles
import org.json.JSONArray
import org.json.JSONObject
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths

/**
 * Local resume memory for the desktop player. Persists last-watched position
 * and enough metadata (title/poster) to render Continue Watching offline, and
 * is the merge target for cloud watch-history pulled from Firebase.
 *
 * The in-memory [map] is the single source of truth after the first load:
 * every mutation updates it and then persists, so a save can never rewrite
 * the file from a stale snapshot (the previous implementation froze the
 * startup contents and evicted everything saved later in the session).
 */
object WatchStateStore {

    data class WatchState(
        val itemId: String,
        val mediaType: String,
        val season: Int,
        val episode: Int,
        val positionMs: Long,
        val lengthMs: Long,
        val updatedAt: Long,
        val title: String = "",
        val posterPath: String? = null,
        val backdropPath: String? = null,
        val year: Int? = null,
        val rating: Double = 0.0,
        /** TMDB genre IDs, so kids profiles can filter history offline. */
        val genreIds: List<Int> = emptyList(),
    ) {
        val progress: Float
            get() = if (lengthMs > 0L) (positionMs.toFloat() / lengthMs).coerceIn(0f, 1f) else 0f
    }

    /** Overridable so tests can point at a temp directory. */
    @Volatile
    internal var baseDir: Path = Paths.get(System.getProperty("user.home"), ".maxstream")

    /** Resume position for a specific movie/episode, or null when fresh. */
    fun resumeFor(itemId: String, season: Int, episode: Int): WatchState? = synchronized(this) {
        ensureLoaded()
        map[key(itemId, season, episode)]
    }

    /** Overwrites the stored state for the given movie/episode. */
    fun save(state: WatchState) = synchronized(this) {
        ensureLoaded()
        map[key(state.itemId, state.season, state.episode)] = state
        persist()
    }

    /** Removes a finished/cleared movie/episode. */
    fun clear(itemId: String, season: Int, episode: Int) = synchronized(this) {
        ensureLoaded()
        map.remove(key(itemId, season, episode))
        persist()
    }

    /**
     * Wipes every locally stored entry. Used on sign-out so the next account
     * never sees the previous user's Continue Watching (the cloud path is
     * per-profile; this local file is process-global).
     */
    fun clearAll() = synchronized(this) {
        map.clear()
        loaded = true
        persist()
    }

    /** Everything, newest last-played first. */
    fun all(): List<WatchState> = synchronized(this) {
        ensureLoaded()
        map.values.sortedByDescending { it.updatedAt }
    }

    /** Merges cloud entries into the local store (newest per movie/episode wins). */
    fun mergeIncoming(states: List<WatchState>): Int = synchronized(this) {
        ensureLoaded()
        var merged = 0
        states.forEach { s ->
            val k = key(s.itemId, s.season, s.episode)
            val existing = map[k]
            if (existing == null || s.updatedAt > existing.updatedAt) {
                map[k] = s
                merged++
            }
        }
        if (merged > 0) persist()
        merged
    }

    /** Test hook: forget in-memory state so the next call reloads from [baseDir]. */
    internal fun resetForTesting() = synchronized(this) {
        map.clear()
        loaded = false
    }

    // ── persistence ──────────────────────────────────────────────────────────

    private val map = HashMap<String, WatchState>()
    private var loaded = false

    /** Caller must hold this object's monitor. */
    private fun ensureLoaded() {
        if (loaded) return
        loaded = true
        try {
            if (Files.exists(file())) {
                val root = JSONObject(Files.readString(file()))
                val arr = root.optJSONArray("items") ?: JSONArray()
                for (i in 0 until arr.length()) {
                    val o = arr.getJSONObject(i)
                    map[o.getString("key")] = WatchState(
                        itemId = o.optString("itemId", ""),
                        mediaType = o.optString("mediaType", "movie"),
                        season = o.optInt("season", 1),
                        episode = o.optInt("episode", 1),
                        positionMs = o.optLong("positionMs", 0L),
                        lengthMs = o.optLong("lengthMs", 0L),
                        updatedAt = o.optLong("updatedAt", 0L),
                        title = o.optString("title", ""),
                        posterPath = o.optString("posterPath").ifBlank { null },
                        backdropPath = o.optString("backdropPath").ifBlank { null },
                        year = o.optInt("year", 0).takeIf { it > 0 },
                        rating = o.optDouble("rating", 0.0),
                        genreIds = o.optJSONArray("genreIds")?.let { arr ->
                            (0 until arr.length()).map { i -> arr.optInt(i) }
                        } ?: emptyList(),
                    )
                }
            }
        } catch (e: Exception) {
            // Corrupt state file: keep it aside instead of silently destroying
            // the user's history on the next write.
            System.err.println("WatchStateStore: state file unreadable, starting fresh: $e")
            runCatching {
                Files.move(file(), file().resolveSibling("watchstate.json.corrupt"))
            }
            map.clear()
        }
    }

    /** Caller must hold this object's monitor and have called [ensureLoaded]. */
    private fun persist() {
        try {
            val arr = JSONArray()
            map.values.forEach {
                arr.put(
                    JSONObject()
                        .put("key", key(it.itemId, it.season, it.episode))
                        .put("itemId", it.itemId)
                        .put("mediaType", it.mediaType)
                        .put("season", it.season)
                        .put("episode", it.episode)
                        .put("positionMs", it.positionMs)
                        .put("lengthMs", it.lengthMs)
                        .put("updatedAt", it.updatedAt)
                        .put("title", it.title)
                        .put("posterPath", it.posterPath ?: "")
                        .put("backdropPath", it.backdropPath ?: "")
                        .put("year", it.year ?: 0)
                        .put("rating", it.rating)
                        .put("genreIds", JSONArray(it.genreIds)),
                )
            }
            AtomicFiles.write(file(), JSONObject().put("items", arr).toString())
        } catch (e: Exception) {
            System.err.println("WatchStateStore: failed to persist: $e")
        }
    }

    private fun file(): Path = baseDir.resolve("watchstate.json")

    private fun key(itemId: String, season: Int, episode: Int) = "$itemId|S$season|E$episode"
}
