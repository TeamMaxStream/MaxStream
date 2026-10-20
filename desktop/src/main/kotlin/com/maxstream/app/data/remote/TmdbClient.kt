package com.maxstream.app.data.remote

import com.maxstream.app.core.AppConfig
import com.maxstream.app.data.model.CastMember
import com.maxstream.app.data.model.Episode
import com.maxstream.app.data.model.MediaDetails
import com.maxstream.app.data.model.MediaItem
import com.maxstream.app.data.model.Season
import com.maxstream.app.data.model.StreamingProvider
import com.maxstream.app.data.model.Trailer
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/**
 * Thin TMDB v3 client. Every call appends the shared ?api_key= and parses the
 * standard {results: [...]}/{...} envelopes into the desktop models. Same
 * endpoints as the mobile service (lib/services/tmdb_api_service.dart) and the
 * TV app (data/remote/TmdbApi.kt).
 */
class TmdbClient {

    private val http = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(15, TimeUnit.SECONDS)
        .followRedirects(true)
        .build()

    @Volatile
    private var genreCache: Map<String, Map<Int, String>> = emptyMap()

    suspend fun json(path: String, vararg query: Pair<String, String>): JSONObject = withContextIO {
        val url = AppConfig.TMDB_BASE_URL.toHttpUrl().newBuilder()
            .addPathSegments(path.trimStart('/'))
            .addQueryParameter("api_key", AppConfig.TMDB_API_KEY)
            .apply { query.forEach { addQueryParameter(it.first, it.second) } }
            .build()
        val request = Request.Builder()
            .url(url)
            .header("Accept", "application/json")
            .header("User-Agent", "MaxStreamDesktop/1.0")
            .build()
        val response = http.newCall(request).execute()
        response.use { res ->
            val body = res.body?.string().orEmpty()
            if (!res.isSuccessful) throw IllegalStateException("TMDB ${res.code} for $path: ${body.take(200)}")
            JSONObject(body)
        }
    }

    suspend fun array(path: String, vararg query: Pair<String, String>): List<JSONObject> {
        val results = json(path, *query).optJSONArray("results") ?: JSONArray()
        return buildList {
            for (i in 0 until results.length()) {
                val o = results.opt(i)
                if (o is JSONObject) add(o)
            }
        }
    }

    /**
     * Reads a top-level JSON array under [key] rather than the usual "results".
     * TMDB's /tv/{id}/season/{n} envelope uses "episodes", so [array] would
     * return an empty list there.
     */
    suspend fun arrayAt(path: String, key: String, vararg query: Pair<String, String>): List<JSONObject> {
        val arr = json(path, *query).optJSONArray(key) ?: JSONArray()
        return buildList {
            for (i in 0 until arr.length()) {
                val o = arr.opt(i)
                if (o is JSONObject) add(o)
            }
        }
    }

    /** {genreId to name} for a media type, cached after the first request. */
    suspend fun genres(type: String): Map<Int, String> {
        genreCache[type]?.let { return it }
        val list = array("/genre/$type/list")
        val map = buildMap {
            list.forEach { g -> put(g.optInt("id"), g.optString("name")) }
        }
        genreCache = genreCache + (type to map)
        return map
    }

    fun parseMedia(o: JSONObject): MediaItem {
        val type = when {
            o.optString("media_type") == "movie" || o.has("title") -> "movie"
            o.optString("media_type") == "tv" || o.has("name") -> "tv"
            else -> "movie"
        }
        val id = o.optString("id")
        val genreMap = genreCache.getValue(type)
        val genreIds = when {
            o.has("genres") -> o.optJSONArray("genres").let { arr -> ids(arr) }
            o.has("genre_ids") -> o.optJSONArray("genre_ids").let { arr -> ids(arr) }
            else -> emptyList()
        }
        val genres = when {
            o.has("genres") -> names(o.optJSONArray("genres"))
            o.has("genre_ids") -> o.optJSONArray("genre_ids").let { arr ->
                (0 until arr.length()).map { i -> genreMap[arr.optInt(i)] }.filterNotNull()
            }
            else -> emptyList()
        }
        return MediaItem(
            id = id,
            title = if (type == "movie") o.optString("title") else o.optString("name"),
            mediaType = type,
            overview = o.optString("overview"),
            year = yearOf(if (type == "movie") o.optString("release_date") else o.optString("first_air_date")),
            genres = genres,
            genreIds = genreIds,
            rating = o.optDouble("vote_average", 0.0),
            posterPath = o.optString("poster_path").ifBlank { null },
            backdropPath = o.optString("backdrop_path").ifBlank { null },
        )
    }

    /** Reads numeric ids from either [16, 10751] or [{"id": 16}, …]. */
    private fun ids(arr: JSONArray?): List<Int> {
        if (arr == null) return emptyList()
        val out = mutableListOf<Int>()
        for (i in 0 until arr.length()) {
            val value = when (val o = arr.opt(i)) {
                is JSONObject -> o.optInt("id", 0)
                is Number -> o.toInt()
                else -> o.toString().toIntOrNull() ?: 0
            }
            if (value > 0) out += value
        }
        return out
    }

    private fun names(arr: JSONArray?): List<String> {
        if (arr == null) return emptyList()
        val out = mutableListOf<String>()
        for (i in 0 until arr.length()) {
            val o = arr.opt(i)
            val name = when (o) {
                is JSONObject -> o.optString("name").ifBlank { o.optString("title") }
                else -> o.toString()
            }
            if (name.isNotBlank()) out += name
        }
        return out
    }

    /** Details assembled from a /movie|/tv/{id} JSON document. */
    fun parseDetails(item: MediaItem, root: JSONObject): MediaDetails {
        val credits = root.optJSONObject("credits")
        val cast = credits?.optJSONArray("cast")
            ?.let { arr ->
                (0 until arr.length())
                    .take(14)
                    .map { i ->
                        val c = arr.getJSONObject(i)
                        CastMember(
                            name = c.optString("name"),
                            character = c.optString("character"),
                            profilePath = c.optString("profile_path").ifBlank { null },
                        )
                    }
                    .filter { it.name.isNotBlank() }
            }
            ?: emptyList()

        val videos = root.optJSONObject("videos")?.optJSONArray("results")
        val trailers = videos?.let { arr ->
            (0 until arr.length())
                .map { i -> arr.getJSONObject(i) }
                .filter { it.optString("site").equals("YouTube", true) && it.optString("type") in setOf("Trailer", "Teaser") }
                .take(2)
                .map { Trailer(it.optString("name"), it.optString("site"), it.optString("key")) }
        } ?: emptyList()

        val seasons = if (item.mediaType == "tv") {
            root.optJSONArray("seasons")?.let { arr ->
                (0 until arr.length())
                    .map { i ->
                        val s = arr.getJSONObject(i)
                        val num = s.optInt("season_number", 0)
                        if (num == 0) null else Season(
                            seasonNumber = num,
                            name = s.optString("name").ifBlank { "Season $num" },
                            episodeCount = s.optInt("episode_count", 0),
                            overview = s.optString("overview"),
                        )
                    }
                    .filterNotNull()
            } ?: emptyList()
        } else emptyList()

        val providers = root.optJSONObject("watch/providers")
            ?.optJSONObject("results")?.optJSONObject("US")?.optJSONArray("flatrate")
            ?.let { arr ->
                (0 until arr.length()).map { i ->
                    val p = arr.getJSONObject(i)
                    StreamingProvider(
                        name = p.optString("provider_name"),
                        providerId = p.optInt("provider_id", 0),
                        logoPath = p.optString("logo_path").ifBlank { null },
                    )
                }
            }
            ?: emptyList()

        return MediaDetails(
            item = item,
            cast = cast,
            trailers = trailers,
            seasons = seasons,
            providers = providers,
        )
    }

    fun parseEpisode(o: JSONObject, seriesId: String, season: Int): Episode {
        val num = o.optInt("episode_number", 0)
        val runtime = o.optInt("runtime", 0).takeIf { it > 0 }
        return Episode(
            id = "$seriesId-$season-$num",
            season = season,
            number = num,
            title = o.optString("name").ifBlank { "Episode $num" },
            overview = o.optString("overview"),
            stillPath = o.optString("still_path").ifBlank { null },
            runtimeMinutes = runtime,
            airDate = o.optString("air_date").ifBlank { null },
        )
    }

    private fun yearOf(date: String): Int? =
        date.take(4).toIntOrNull()

    private suspend fun <T> withContextIO(block: () -> T): T =
        kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { block() }
}