package com.maxstream.app

import java.io.ByteArrayInputStream
import java.net.URLEncoder
import java.nio.charset.Charset
import java.util.concurrent.TimeUnit
import java.util.zip.GZIPInputStream
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONArray

/** One subtitle found through the OpenSubtitles legacy REST search. */
data class OpenSubtitleResult(
    val id: String,
    val label: String,
    val language: String,
    val downloadUrl: String,
    val encoding: String,
    val downloads: Int,
)

/**
 * Client for the keyless legacy OpenSubtitles REST API
 * (`rest.opensubtitles.org`). Downloads arrive gzip-compressed in a legacy
 * codepage and are decoded to UTF-8 here so the player's own cue parser can
 * consume the text directly (the player renders subtitles itself, not via
 * media3).
 */
object OpenSubtitlesClient {

    private const val BASE_URL = "https://rest.opensubtitles.org/"
    // The legacy endpoint rejects custom user agents with a redirect; it only
    // answers this shared test agent.
    private const val USER_AGENT = "TemporaryUserAgent"

    private val client by lazy {
        OkHttpClient.Builder()
            .connectTimeout(12, TimeUnit.SECONDS)
            .readTimeout(20, TimeUnit.SECONDS)
            .followRedirects(true)
            .followSslRedirects(true)
            .build()
    }

    /**
     * Searches by [query] (a title), optionally scoped to a TV episode.
     * Results are sorted by popularity (downloads, descending).
     */
    suspend fun search(
        query: String,
        season: Int? = null,
        episode: Int? = null,
        limit: Int = 30,
    ): List<OpenSubtitleResult> = withContext(Dispatchers.IO) {
        val trimmed = query.trim()
        if (trimmed.isEmpty()) return@withContext emptyList()
        val params = mutableListOf("query-${encode(trimmed.lowercase())}")
        if (season != null) params.add("season-$season")
        if (episode != null) params.add("episode-$episode")
        val request = Request.Builder()
            .url("$BASE_URL/search/${params.joinToString("/")}")
            .header("User-Agent", USER_AGENT)
            .header("Accept", "application/json")
            .build()
        val body = client.newCall(request).execute().use { response ->
            require(response.isSuccessful) {
                "Subtitle search failed (HTTP ${response.code})"
            }
            response.body?.string().orEmpty()
        }
        val array = JSONArray(body)
        val results = ArrayList<OpenSubtitleResult>(array.length())
        for (i in 0 until array.length()) {
            val entry = array.optJSONObject(i) ?: continue
            val downloadUrl = entry.optString("SubDownloadLink").orEmpty()
            if (downloadUrl.isBlank()) continue
            val language = entry.optString("LanguageName").orEmpty()
            val release = entry.optString("MovieReleaseName").orEmpty()
            val label = listOf(language, release)
                .filter { it.isNotBlank() }
                .joinToString(" · ")
                .ifBlank { "Subtitle" }
            results.add(
                OpenSubtitleResult(
                    id = entry.optString("IDSubtitleFile").ifBlank { downloadUrl },
                    label = label,
                    language = language,
                    downloadUrl = downloadUrl,
                    encoding = entry.optString("SubEncoding"),
                    downloads = entry.optString("SubDownloadsCnt").toIntOrNull() ?: 0,
                ),
            )
        }
        results.sortByDescending { it.downloads }
        // Same release often appears once per language track — keep one entry
        // per label so picker rows stay distinct.
        val seenLabels = HashSet<String>()
        results.retainAll { seenLabels.add(it.label) }
        results.take(limit)
    }

    /** Downloads [subtitle] and returns its caption text decoded to UTF-8. */
    suspend fun downloadAsText(subtitle: OpenSubtitleResult): String =
        downloadAsText(subtitle.downloadUrl, subtitle.encoding)

    /** Downloads a subtitle file by URL with an optional source charset. */
    suspend fun downloadAsText(downloadUrl: String, encoding: String = ""): String =
        withContext(Dispatchers.IO) {
            val request = Request.Builder()
                .url(downloadUrl)
                .header("User-Agent", USER_AGENT)
                .build()
            val bytes = client.newCall(request).execute().use { response ->
                require(response.isSuccessful) {
                    "Subtitle download failed (HTTP ${response.code})"
                }
                response.body?.bytes() ?: ByteArray(0)
            }
            require(bytes.isNotEmpty()) { "Subtitle download was empty" }
            val raw = try {
                GZIPInputStream(ByteArrayInputStream(bytes))
                    .use { it.readBytes() }
            } catch (_: Exception) {
                // Some mirrors serve the plain file without the gzip wrapper.
                bytes
            }
            String(raw, charsetFromEncoding(encoding))
        }

    /** Path-segment encoding: spaces must be %20, not '+'. */
    private fun encode(value: String): String =
        URLEncoder.encode(value, "UTF-8").replace("+", "%20")

    /** Maps the API's SubEncoding label to a JVM charset (mirrors the Dart
     * decoder's tables; the JVM ships the Windows codepages). */
    private fun charsetFromEncoding(encoding: String?): Charset {
        if (encoding.isNullOrBlank()) return Charsets.UTF_8
        return try {
            when (encoding.uppercase()) {
                "CP1256", "WINDOWS-1256" -> Charset.forName("Windows-1256")
                "CP1251", "WINDOWS-1251" -> Charset.forName("Windows-1251")
                "CP1252", "WINDOWS-1252", "ISO-8859-1" ->
                    Charset.forName("Windows-1252")
                "CP1254", "WINDOWS-1254" -> Charset.forName("Windows-1254")
                "CP1253", "WINDOWS-1253" -> Charset.forName("Windows-1253")
                "UTF-8" -> Charsets.UTF_8
                else -> Charset.forName(encoding)
            }
        } catch (_: Exception) {
            Charsets.UTF_8
        }
    }
}
