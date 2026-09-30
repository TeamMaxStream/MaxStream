package com.maxstream.app.data.model

import android.os.Bundle

data class Source(
    val url: String,
    val server: String,
    val type: String,
    val headers: Map<String, String> = emptyMap(),
    val qualities: List<Quality> = emptyList(),
    val subtitles: List<Subtitle> = emptyList(),
    val audioTracks: List<AudioTrack> = emptyList(),
    val separateAudio: Boolean = false,
    /** Extractor name (e.g. "VidLink") - the host that produced this stream. */
    val extractor: String = "",
    /** Extraction route that produced this stream (e.g. "Worker", "HTTP", "WebView"). */
    val method: String = "",
) {
    val isHls: Boolean get() = type == "direct_m3u8" || url.contains(".m3u8", ignoreCase = true)

    /** Display label like "VidLink via Worker" or "VidLink via VidLink" */
    val displayName: String
        get() = when {
            extractor.isNotBlank() && method.isNotBlank() -> "$extractor ($method)"
            extractor.isNotBlank() && server.isNotBlank() && extractor != server -> "$extractor via $server"
            extractor.isNotBlank() -> extractor
            server.isNotBlank() -> server
            else -> "Unknown"
        }

    companion object {
        fun fromBundle(b: Bundle): Source {
            @Suppress("UNCHECKED_CAST")
            val headers = (b.getSerializable("headers") as? HashMap<String, String>) ?: HashMap()
            val qualities = b.getParcelableArrayList<Bundle>("qualities").orEmpty()
                .map { Quality.fromBundle(it) }
            val subtitles = b.getParcelableArrayList<Bundle>("subtitles").orEmpty()
                .map { Subtitle.fromBundle(it) }
            val audioTracks = b.getParcelableArrayList<Bundle>("audioTracks").orEmpty()
                .map { AudioTrack.fromBundle(it) }
            return Source(
                url = b.getString("url").orEmpty(),
                server = b.getString("server").orEmpty(),
                type = b.getString("type").orEmpty(),
                headers = headers,
                qualities = qualities,
                subtitles = subtitles,
                audioTracks = audioTracks,
                separateAudio = b.getBoolean("separateAudio", false),
                extractor = b.getString("extractor").orEmpty(),
                method = b.getString("method").orEmpty(),
            )
        }
    }
}

data class Quality(
    val label: String,
    val url: String,
    val height: Int,
    val codec: String = "",
) {
    fun toBundle() = Bundle().apply {
        putString("label", label)
        putString("url", url)
        putInt("height", height)
        putString("codec", codec)
    }

    companion object {
        fun fromBundle(b: Bundle) = Quality(
            label = b.getString("label").orEmpty(),
            url = b.getString("url").orEmpty(),
            height = b.getInt("height", 0),
            codec = b.getString("codec").orEmpty(),
        )
    }
}

data class Subtitle(
    val label: String,
    val url: String,
    val isDefault: Boolean = false,
    val source: String = "",
) {
    fun toBundle() = Bundle().apply {
        putString("label", label)
        putString("url", url)
        putBoolean("isDefault", isDefault)
        putString("source", source)
    }

    companion object {
        fun fromBundle(b: Bundle) = Subtitle(
            label = b.getString("label").orEmpty(),
            url = b.getString("url").orEmpty(),
            isDefault = b.getBoolean("isDefault", false),
            source = b.getString("source").orEmpty(),
        )
    }
}

data class AudioTrack(
    val label: String,
    val language: String,
    val url: String = "",
    val groupId: String = "",
    val isDefault: Boolean = false,
    val channels: String = "",
    val source: String = "HLS",
) {
    fun toBundle() = Bundle().apply {
        putString("label", label)
        putString("language", language)
        putString("url", url)
        putString("groupId", groupId)
        putBoolean("isDefault", isDefault)
        putString("channels", channels)
        putString("source", source)
    }

    companion object {
        fun fromBundle(b: Bundle) = AudioTrack(
            label = b.getString("label").orEmpty(),
            language = b.getString("language").orEmpty(),
            url = b.getString("url").orEmpty(),
            groupId = b.getString("groupId").orEmpty(),
            isDefault = b.getBoolean("isDefault", false),
            channels = b.getString("channels").orEmpty(),
            source = b.getString("source").orEmpty(),
        )
    }
}

fun Source.toBundle(): Bundle = Bundle().apply {
    putString("url", url)
    putString("server", server)
    putString("type", type)
    putSerializable("headers", HashMap(headers))
    putParcelableArrayList(
        "qualities",
        ArrayList(qualities.map { it.toBundle() }),
    )
    putParcelableArrayList(
        "subtitles",
        ArrayList(subtitles.map { it.toBundle() }),
    )
    putParcelableArrayList(
        "audioTracks",
        ArrayList(audioTracks.map { it.toBundle() }),
    )
    putBoolean("separateAudio", separateAudio)
    putString("extractor", extractor)
    putString("method", method)
}
