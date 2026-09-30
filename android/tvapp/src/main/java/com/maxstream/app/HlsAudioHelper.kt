package com.maxstream.app

import android.util.Log
import java.io.File
import java.net.URI
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request

/**
 * Rewrites an HLS master playlist so ExoPlayer defaults to the chosen audio
 * rendition without any native player changes (mirrors the Dart
 * HlsAudioHelper used by the phone build).
 *
 * The rewritten master keeps every video variant but drops the non-matching
 * `#EXT-X-MEDIA:TYPE=AUDIO` groups and marks the match `DEFAULT=YES`. It is
 * written to a temp file with all URIs absolutized, so relative masters keep
 * working. Stream headers (cookies, referer, UA) are still supplied to
 * ExoPlayer via OkHttpDataSource and apply to the remote segments, which stay
 * remote — only the tiny master text is local.
 */
object HlsAudioHelper {

    private val client by lazy {
        OkHttpClient.Builder()
            .connectTimeout(12, TimeUnit.SECONDS)
            .readTimeout(15, TimeUnit.SECONDS)
            .followRedirects(true)
            .followSslRedirects(true)
            .build()
    }

    /**
     * Returns the URL ExoPlayer should actually play: [masterUrl] itself when
     * no audio language is pinned, the pinned local master when a rewrite
     * succeeds, or [masterUrl] again when the rewrite has nothing to pin.
     * Every playback build funnels through this so server switches, quality
     * switches, subtitle changes, retries and the initial load all honour the
     * selection.
     */
    suspend fun resolvePlaybackUrl(
        masterUrl: String,
        headers: Map<String, String>,
        preferredLanguage: String?,
        cacheDir: File,
    ): String {
        if (preferredLanguage.isNullOrBlank()) return masterUrl
        return withContext(Dispatchers.IO) {
            buildMasterWithPreferredAudio(masterUrl, headers, preferredLanguage, cacheDir)
                ?: masterUrl
        }
    }

    /**
     * Returns a local `.m3u8` path pinning [language], or null when the master
     * has no alternate audio to choose from (callers then use the original URL).
     */
    fun buildMasterWithPreferredAudio(
        masterUrl: String,
        headers: Map<String, String>,
        language: String,
        cacheDir: File,
    ): String? {
        if (language.trim().isEmpty()) return null
        val uri = runCatching { URI(masterUrl) }.getOrNull() ?: return null
        if (uri.scheme != "http" && uri.scheme != "https") return null
        return try {
            val request = Request.Builder().url(masterUrl).apply {
                headers.forEach { (name, value) ->
                    if (name.isNotBlank() && value.isNotBlank()) header(name, value)
                }
                if (headers.keys.none { it.equals("Accept", ignoreCase = true) }) {
                    header("Accept", "*/*")
                }
            }.build()
            client.newCall(request).execute().use { response ->
                if (!response.isSuccessful) return null
                val text = response.body?.string().orEmpty()
                if (!text.startsWith("#EXTM3U") || !text.contains("#EXT-X-STREAM-INF")) return null
                val rewritten = rewriteMaster(uri, text, language) ?: return null
                val dir = File(cacheDir, "audio_pref").apply { mkdirs() }
                val name = "master_${masterUrl.hashCode() and 0x7fffffff}_${language.hashCode() and 0xffff}.m3u8"
                val file = File(dir, name)
                file.writeText(rewritten)
                file.absolutePath
            }
        } catch (error: Throwable) {
            Log.w("HlsAudioHelper", "Audio rewrite failed: ${error.message}")
            null
        }
    }

    /** Returns the rewritten master text, or null when there is nothing to pin
     * (0-1 audio groups, or no group matching [language]). */
    private fun rewriteMaster(masterUri: URI, text: String, language: String): String? {
        val lines = text.split('\n').map { it.removeSuffix("\r") }
        var audioGroupCount = 0
        for (line in lines) {
            val trimmed = line.trim()
            if (trimmed.startsWith("#EXT-X-MEDIA:", true) &&
                trimmed.uppercase().contains("TYPE=AUDIO")
            ) {
                audioGroupCount++
            }
        }
        if (audioGroupCount <= 1) return null

        var matched = 0
        val out = ArrayList<String>(lines.size)
        for (i in lines.indices) {
            val line = lines[i]
            val trimmed = line.trim()
            if (trimmed.startsWith("#EXT-X-MEDIA:", true) &&
                trimmed.uppercase().contains("TYPE=AUDIO")
            ) {
                val languageAttr = attribute(trimmed, "LANGUAGE")
                val nameAttr = attribute(trimmed, "NAME")
                if (!matches(languageAttr.orEmpty(), nameAttr.orEmpty(), language)) continue
                matched++
                var kept = trimmed.replace(
                    Regex(""",?\s*DEFAULT\s*=\s*(YES|NO)""", RegexOption.IGNORE_CASE),
                    "",
                )
                kept = kept.replace(
                    Regex(""",?\s*AUTOSELECT\s*=\s*(YES|NO)""", RegexOption.IGNORE_CASE),
                    "",
                )
                kept = kept.replaceFirst(
                    Regex("""TYPE\s*=\s*AUDIO""", RegexOption.IGNORE_CASE),
                    "TYPE=AUDIO,DEFAULT=YES,AUTOSELECT=YES",
                )
                out.add(absolutizeUriAttr(kept, masterUri))
                continue
            }
            if (trimmed.startsWith("#EXT-X-I-FRAME-STREAM-INF:", true)) {
                out.add(absolutizeUriAttr(line, masterUri))
                continue
            }
            if (trimmed.isNotEmpty() && !trimmed.startsWith("#") && i > 0 &&
                lines[i - 1].trim().startsWith("#EXT-X-STREAM-INF:", true)
            ) {
                // Variant playlist URI: absolutize so the local master resolves it.
                out.add(runCatching { masterUri.resolve(trimmed).toString() }.getOrNull() ?: trimmed)
                continue
            }
            out.add(line)
        }
        if (matched == 0) return null
        return out.joinToString(separator = "\n", postfix = "\n")
    }

    /** Dart StreamAudioHelper.matches, minus the language-name dictionary
     * (our queries are the exact LANGUAGE/NAME attrs we parsed ourselves). */
    private fun matches(trackLanguage: String, trackLabel: String, query: String): Boolean {
        val q = query.trim().lowercase()
        if (q.isEmpty()) return false
        val language = trackLanguage.trim().lowercase()
        val label = trackLabel.trim().lowercase()
        if (language.isNotEmpty() && language == q) return true
        if (label.isNotEmpty() && label == q) return true
        if (language.isNotEmpty() && language.contains(q)) return true
        if (language.isNotEmpty() && q.contains(language) && language != "und") return true
        if (label.isNotEmpty() && (label.contains(q) || q.contains(label))) return true
        return false
    }

    private fun attribute(line: String, name: String): String? {
        val match = Regex(
            """(?:^|,)$name=(?:"([^"]*)"|([^,]*))""",
            RegexOption.IGNORE_CASE,
        ).find(line) ?: return null
        val value = match.groupValues[1].ifEmpty { match.groupValues[2] }
        return value.ifEmpty { null }
    }

    private fun absolutizeUriAttr(line: String, base: URI): String {
        val match = Regex(
            """URI=("([^"]+)"|([^,]+))""",
            RegexOption.IGNORE_CASE,
        ).find(line) ?: return line
        val source = match.groupValues[2].ifEmpty { match.groupValues[3] }
        if (source.isEmpty()) return line
        val resolved = runCatching { base.resolve(source).toString() }.getOrNull() ?: return line
        return line.replaceRange(match.range.first, match.range.last + 1, "URI=\"$resolved\"")
    }
}
