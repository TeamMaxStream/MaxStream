package com.maxstream.app.stream

/** A playable variant offered by one server (from StreamExtractor's result maps). */
data class ResolvedStream(
    val url: String,
    val server: String,
    val headers: Map<String, String> = emptyMap(),
    val qualities: List<ResolvedQuality> = emptyList(),
    val subtitles: List<ResolvedSubtitle> = emptyList(),
    val audioTracks: List<ResolvedAudioTrack> = emptyList(),
    val separateAudio: Boolean = false,
    val type: String = "",
) {
    val referer: String? get() = headers["Referer"]
    val userAgent: String? get() = headers["User-Agent"]
    val origin: String? get() = headers["Origin"]

    fun qualityMatch(): List<ResolvedQuality> =
        qualities.sortedByDescending { it.height } // 0/unknown sorts last
}

data class ResolvedQuality(
    val label: String,
    val url: String,
    val height: Int,
)

data class ResolvedSubtitle(
    val label: String,
    val url: String,
    val isDefault: Boolean = false,
    val language: String = "",
) {
    /** "English" / "Spanish" style menu label; falls back to the provider label. */
    fun display(): String {
        val lang = subtitleLanguageName(language, label)
        val name = label.trim()
        // "en", "en-US", "eng", "English" all mean just "English".
        val bareCode = name.isBlank() || name.equals(lang, ignoreCase = true) ||
            languageCode(name).length.let { it == 2 || it == 3 }
        return when {
            lang.isBlank() -> name.ifBlank { "Subtitles" }
            bareCode -> lang
            else -> "$name ($lang)"
        }
    }

    fun matchesLanguage(tag: String): Boolean = sameLanguage(language, label, tag)
}

/** Extracts a two-letter language code from "en", "en-US", "English", "Español" … */
fun languageCode(raw: String): String {
    val value = raw.trim().lowercase()
    if (value.isBlank()) return ""
    val prefix = value.substringBefore('-').substringBefore('_')
    if (prefix.length == 2 && prefix.all { it in 'a'..'z' }) return prefix
    if (prefix.length == 3) ISO3[prefix]?.let { return it }
    // Full language names ("english", "spanish", …) → ISO code.
    return NAMES.entries.firstOrNull { (_, names) -> value in names }?.key.orEmpty()
}

// Subtitles routinely use ISO-639-2 codes ("eng", "spa") next to the 2-letter form.
private val ISO3: Map<String, String> = mapOf(
    "eng" to "en", "spa" to "es", "fre" to "fr", "fra" to "fr", "ger" to "de", "deu" to "de",
    "por" to "pt", "ita" to "it", "swa" to "sw", "ara" to "ar", "hin" to "hi", "rus" to "ru",
    "jpn" to "ja", "kor" to "ko", "zho" to "zh", "chi" to "zh", "tur" to "tr", "ind" to "id",
    "dut" to "nl", "nld" to "nl", "pol" to "pl", "tgl" to "tl", "fil" to "tl",
)

private val NAMES: Map<String, Set<String>> = mapOf(
    "en" to setOf("english", "eng"),
    "es" to setOf("spanish", "español", "espanol", "spa", "latino", "latinoamericano"),
    "fr" to setOf("french", "français", "francais", "fre", "fra"),
    "de" to setOf("german", "deutsch", "ger", "deu"),
    "pt" to setOf("portuguese", "português", "portugues", "por", "brasil", "brazilian"),
    "it" to setOf("italian", "italiano", "ita"),
    "sw" to setOf("swahili", "kiswahili", "swa"),
    "ar" to setOf("arabic", "العربية", "ara"),
    "hi" to setOf("hindi", "हिन्दी", "hin"),
    "ru" to setOf("russian", "русский", "rus"),
    "ja" to setOf("japanese", "日本語", "jpn"),
    "ko" to setOf("korean", "한국어", "kor"),
    "zh" to setOf("chinese", "中文", "zho", "chi", "mandarin"),
    "tr" to setOf("turkish", "türkçe", "tur"),
    "id" to setOf("indonesian", "ind"),
    "nl" to setOf("dutch", "nederlands", "dut", "nld"),
    "pl" to setOf("polish", "polski", "pol"),
    "tl" to setOf("tagalog", "filipino", "tgl", "fil"),
)

fun subtitleLanguageName(language: String, label: String): String {
    val code = languageCode(language).ifBlank { languageCode(label) }
    return if (code.isBlank()) "" else DISPLAY_NAMES[code] ?: code.uppercase()
}

private val DISPLAY_NAMES: Map<String, String> = mapOf(
    "en" to "English", "es" to "Spanish", "fr" to "French", "de" to "German",
    "pt" to "Portuguese", "it" to "Italian", "sw" to "Swahili", "ar" to "Arabic",
    "hi" to "Hindi", "ru" to "Russian", "ja" to "Japanese", "ko" to "Korean",
    "zh" to "Chinese", "tr" to "Turkish", "id" to "Indonesian", "nl" to "Dutch",
    "pl" to "Polish", "tl" to "Filipino",
)

fun sameLanguage(a: String, b: String, tag: String): Boolean {
    val want = languageCode(tag)
    if (want.isBlank()) return false
    return languageCode(a) == want || languageCode(b) == want
}

/**
 * Default subtitle so playback is captioned out of the box: an explicit
 * default first, then the audio language (TV-style), then English, then the
 * first track the server offers. [audioLanguage] comes from the selected audio
 * rendition when the server exposes one.
 */
fun pickDefaultSubtitle(
    subtitles: List<ResolvedSubtitle>,
    audioLanguage: String = "",
): ResolvedSubtitle? {
    if (subtitles.isEmpty()) return null
    subtitles.firstOrNull { it.isDefault }?.let { return it }
    val wanted = listOfNotNull(audioLanguage.takeIf { it.isNotBlank() }, "en")
    for (tag in wanted) {
        subtitles.firstOrNull { it.matchesLanguage(tag) }?.let { return it }
    }
    return subtitles.first()
}

/** One multi-language audio rendition (`#EXT-X-MEDIA:TYPE=AUDIO`). */
data class ResolvedAudioTrack(
    val label: String,
    val language: String,
    val isDefault: Boolean = false,
) {
    /** "English (en)" style menu label. */
    fun display(): String = when {
        language.isBlank() || language == "und" -> label
        label.isBlank() || label.equals(language, ignoreCase = true) -> language
        else -> "$label ($language)"
    }
}

/** A server that failed discovery; shown in the picker with a retry action. */
data class FailedServer(
    val name: String,
    val error: String,
)

@Suppress("UNCHECKED_CAST")
fun parseStreams(raw: Any?): List<ResolvedStream> {
    val list = raw as? List<*> ?: return emptyList()
    return list.mapNotNull { item ->
        val m = item as? Map<*, *> ?: return@mapNotNull null
        // Failed rows carry an empty url + available=false — they are surfaced
        // through [parseFailedServers], never as playable streams.
        if (m["available"] == false) return@mapNotNull null
        val url = (m["url"] as? String)?.takeIf { it.isNotBlank() } ?: return@mapNotNull null
        val headers = (m["headers"] as? Map<*, *>)?.mapKeys { it.key.toString() } as? Map<String, String>
            ?: emptyMap()
        val qualities = (m["qualities"] as? List<*>)?.mapNotNull { q ->
            val qm = q as? Map<*, *> ?: return@mapNotNull null
            val qu = qm["url"] as? String ?: return@mapNotNull null
            ResolvedQuality(
                label = qm["label"] as? String ?: "",
                url = qu,
                height = (qm["height"] as? Number)?.toInt() ?: 0,
            )
        } ?: emptyList()
        val subtitles = (m["subtitles"] as? List<*>)?.mapNotNull { s ->
            val sm = s as? Map<*, *> ?: return@mapNotNull null
            val su = sm["url"] as? String ?: return@mapNotNull null
            ResolvedSubtitle(
                label = sm["label"] as? String ?: "Subtitles",
                url = su,
                isDefault = sm["default"] as? Boolean ?: false,
                language = sm["language"] as? String ?: "",
            )
        } ?: emptyList()
        val audioTracks = (m["audioTracks"] as? List<*>)?.mapNotNull { a ->
            val am = a as? Map<*, *> ?: return@mapNotNull null
            ResolvedAudioTrack(
                label = am["label"] as? String ?: "Audio",
                language = am["language"] as? String ?: "",
                isDefault = am["default"] as? Boolean ?: false,
            )
        } ?: emptyList()
        ResolvedStream(
            url = url,
            server = m["server"] as? String ?: m["source"] as? String ?: "Server",
            headers = headers,
            qualities = qualities,
            subtitles = subtitles,
            audioTracks = audioTracks,
            separateAudio = m["separateAudio"] as? Boolean ?: false,
            type = m["type"] as? String ?: "",
        )
    }
}

/** Extracts the `available == false` rows (name + failure reason). */
fun parseFailedServers(raw: Any?): List<FailedServer> {
    val list = raw as? List<*> ?: return emptyList()
    return list.mapNotNull { item ->
        val m = item as? Map<*, *> ?: return@mapNotNull null
        if (m["available"] != false) return@mapNotNull null
        val name = (m["server"] as? String)?.takeIf { it.isNotBlank() }
            ?: (m["source"] as? String)?.takeIf { it.isNotBlank() }
            ?: return@mapNotNull null
        FailedServer(name, m["error"] as? String ?: "Unavailable")
    }.distinctBy { it.name }
}
