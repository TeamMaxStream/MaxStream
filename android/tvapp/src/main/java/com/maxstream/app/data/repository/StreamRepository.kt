package com.maxstream.app.data.repository

import android.content.Context
import com.maxstream.app.data.model.AudioTrack
import com.maxstream.app.data.model.Quality
import com.maxstream.app.data.model.Source
import com.maxstream.app.data.model.Subtitle
import com.maxstream.app.StreamExtractor
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Resolves a playable [Source] for a TMDB title by delegating to the reused
 * [StreamExtractor] (ported verbatim from the legacy Flutter build). The
 * extractor returns a `Map<String, Any>`; this repository adapts it into the
 * typed [Source] model the player consumes.
 */
class StreamRepository(private val context: Context) {

    private val extractor by lazy { StreamExtractor(context.applicationContext) }

    /** Resolve the first playable server. */
    suspend fun resolve(
        tmdbId: String,
        isMovie: Boolean,
        season: Int = 1,
        episode: Int = 1,
        title: String = "",
    ): Source? = withContext(Dispatchers.IO) {
        val map = extractor.resolveStream(tmdbId, isMovie, season, episode, title) ?: return@withContext null
        runCatching { mapToSource(map) }.getOrNull()
    }

    /** Resolve every server in parallel (for a server-picker UI). */
    suspend fun resolveAll(
        tmdbId: String,
        isMovie: Boolean,
        season: Int = 1,
        episode: Int = 1,
        title: String = "",
    ): List<Source> = withContext(Dispatchers.IO) {
        runCatching {
            extractor.resolveStreams(tmdbId, isMovie, season, episode, title)
                .mapNotNull { runCatching { mapToSource(it) }.getOrNull() }
        }.getOrDefault(emptyList())
    }

    @Suppress("UNCHECKED_CAST")
    private fun mapToSource(map: Map<String, Any>): Source {
        val url = (map["url"] as? String).orEmpty()
        require(url.isNotBlank()) { "Resolved stream has no url" }

        val rawHeaders = map["headers"] as? Map<*, *>
        val headers = rawHeaders?.mapNotNull { (k, v) ->
            (k as? String)?.let { it to (v?.toString().orEmpty()) }
        }?.toMap().orEmpty()

        val qualities = (map["qualities"] as? List<*>)?.mapNotNull { item ->
            (item as? Map<*, *>)?.let {
                Quality(
                    label = it["label"]?.toString().orEmpty(),
                    url = it["url"]?.toString().orEmpty(),
                    height = (it["height"] as? Number)?.toInt() ?: 0,
                    codec = it["codec"]?.toString().orEmpty(),
                )
            }
        }.orEmpty()

        val subtitles = (map["subtitles"] as? List<*>)?.mapNotNull { item ->
            (item as? Map<*, *>)?.let {
                Subtitle(
                    label = it["label"]?.toString().orEmpty(),
                    url = it["url"]?.toString().orEmpty(),
                    isDefault = it["default"] as? Boolean ?: false,
                    source = it["source"]?.toString().orEmpty(),
                )
            }
        }.orEmpty()

        val audioTracks = (map["audioTracks"] as? List<*>)?.mapNotNull { item ->
            (item as? Map<*, *>)?.let {
                AudioTrack(
                    label = it["label"]?.toString().orEmpty(),
                    language = it["language"]?.toString().orEmpty(),
                    url = it["url"]?.toString().orEmpty(),
                    groupId = it["groupId"]?.toString().orEmpty(),
                    isDefault = it["default"] as? Boolean ?: false,
                    channels = it["channels"]?.toString().orEmpty(),
                    source = it["source"]?.toString() ?: "HLS",
                )
            }
        }.orEmpty()

        val server = (map["server"] as? String).orEmpty()
        val extractor = (map["source"] as? String).orEmpty()
        return Source(
            url = url,
            server = server.ifEmpty { extractor },
            type = (map["type"] as? String).orEmpty(),
            headers = headers,
            qualities = qualities,
            subtitles = subtitles,
            audioTracks = audioTracks,
            separateAudio = map["separateAudio"] as? Boolean ?: false,
            extractor = extractor,
            method = (map["method"] as? String).orEmpty(),
        )
    }
}
