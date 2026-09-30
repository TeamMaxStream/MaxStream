package com.maxstream.app

import android.annotation.SuppressLint
import android.app.ActivityManager
import android.content.Context
import android.text.Html
import android.util.Base64
import android.util.Log
import android.webkit.CookieManager
import android.webkit.JavascriptInterface
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.withPermit
import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Dns
import org.json.JSONArray
import org.json.JSONObject
import java.net.InetAddress
import java.net.URI
import java.net.URLDecoder
import java.net.URLEncoder
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.util.Locale
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.TimeUnit
import java.util.regex.Pattern
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlin.experimental.xor

/** Resolves TMDB metadata through server providers and host-specific extractors. */
class StreamExtractor(private val context: Context) {
    private val tag = "StreamExtractor"

    companion object {
        private const val HTTP_SERVER_TIMEOUT_MS = 18_000L
        private const val WEBVIEW_SERVER_TIMEOUT_MS = 12_000L
        private const val ALL_SERVERS_TOTAL_TIMEOUT_MS = 75_000L
    }

    /** True on 1GB-class devices (most cheap TV boxes). */
    private fun isLowRamDevice(): Boolean {
        val am =
            context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager ?: return false
        val memoryInfo = ActivityManager.MemoryInfo()
        am.getMemoryInfo(memoryInfo)
        return am.isLowRamDevice || memoryInfo.totalMem <= 2L * 1024 * 1024 * 1024
    }

    private val userAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
            "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

    data class MediaRequest(
        val tmdbId: String,
        val isMovie: Boolean,
        val season: Int,
        val episode: Int,
        val title: String,
    )

    data class StreamServer(
        val name: String,
        val url: String,
        val headers: Map<String, String> = emptyMap(),
        val subtitles: List<SubtitleOption> = emptyList(),
    )

    data class StreamResult(
        val url: String,
        val source: String,
        val type: String,
        val headers: Map<String, String> = emptyMap(),
        val qualities: List<QualityOption> = emptyList(),
        val subtitles: List<SubtitleOption> = emptyList(),
        val audioTracks: List<AudioOption> = emptyList(),
        val server: String = source,
        val separateAudio: Boolean = false,
        val method: String = "",
    ) {
        fun toMap(): Map<String, Any> = mapOf(
            "url" to url,
            "source" to source,
            "server" to server,
            "type" to type,
            "headers" to headers,
            "referer" to (headers["Referer"] ?: ""),
            "qualities" to qualities.map(QualityOption::toMap),
            "subtitles" to subtitles.map(SubtitleOption::toMap),
            "audioTracks" to audioTracks.map(AudioOption::toMap),
            "separateAudio" to separateAudio,
            "method" to method,
        )
    }

    data class SubtitleOption(
        val label: String,
        val url: String,
        val isDefault: Boolean = false,
        val source: String = "",
    ) {
        fun toMap(): Map<String, Any> = mapOf(
            "label" to label,
            "url" to url,
            "default" to isDefault,
            "source" to source,
        )
    }

    /** One `#EXT-X-MEDIA:TYPE=AUDIO` rendition from an HLS master playlist. */
    data class AudioOption(
        val label: String,
        val language: String,
        val url: String,
        val groupId: String = "",
        val isDefault: Boolean = false,
        val channels: String = "",
        val source: String = "HLS",
    ) {
        fun toMap(): Map<String, Any> = mapOf(
            "label" to label,
            "language" to language,
            "url" to url,
            "groupId" to groupId,
            "default" to isDefault,
            "channels" to channels,
            "source" to source,
        )
    }

    data class QualityOption(
        val label: String,
        val url: String,
        val height: Int,
        val codec: String = "",
    ) {
        fun toMap(): Map<String, Any> = mapOf(
            "label" to label,
            "url" to url,
            "height" to height,
            "codec" to codec,
        )
    }

    private sealed interface ExtractionResult {
        data class Final(val stream: StreamResult) : ExtractionResult
        data class Redirect(val server: StreamServer) : ExtractionResult
    }

    private interface ServerProvider {
        val name: String
        suspend fun getServers(request: MediaRequest): List<StreamServer>
    }

    private interface HostExtractor {
        val name: String
        /** True when extraction needs a WebView. WebViews are heavy and crash
         *  1GB-class boxes when several run at once, so they are skipped there. */
        val usesWebView: Boolean
            get() = false
        fun supports(server: StreamServer): Boolean
        suspend fun extract(server: StreamServer): ExtractionResult
    }

    private class MemoryCookieJar : CookieJar {
        private val cookies = ConcurrentHashMap<String, List<Cookie>>()

        override fun saveFromResponse(url: HttpUrl, cookies: List<Cookie>) {
            this.cookies[url.host] = cookies
        }

        override fun loadForRequest(url: HttpUrl): List<Cookie> {
            return cookies[url.host].orEmpty().filter { it.matches(url) }
        }
    }

    private val bootstrapClient = OkHttpClient.Builder()
        .connectTimeout(8, TimeUnit.SECONDS)
        .readTimeout(8, TimeUnit.SECONDS)
        .build()

    private val dns: Dns by lazy {
        Dns.SYSTEM
    }

    private val client = OkHttpClient.Builder()
        .connectTimeout(12, TimeUnit.SECONDS)
        .readTimeout(15, TimeUnit.SECONDS)
        .followRedirects(true)
        .followSslRedirects(true)
        .cookieJar(MemoryCookieJar())
        .dns(dns)
        .addInterceptor { chain ->
            requireSafeOutboundUrl(chain.request().url.toString())
            chain.proceed(chain.request())
        }
        // Network interceptors run again for each automatic redirect.
        .addNetworkInterceptor { chain ->
            requireSafeOutboundUrl(chain.request().url.toString())
            chain.proceed(chain.request())
        }
        .build()

    private val noRedirectClient = client.newBuilder()
        .followRedirects(false)
        .followSslRedirects(false)
        .build()

    private val serverProviders: List<ServerProvider> by lazy {
        listOf(
            StaticTmdbProvider(),
            VidrockServerProvider(),
            PrimeSrcServerProvider(),
            VidukiServerProvider(),
        )
    }

    private val extractorRegistry: List<HostExtractor> by lazy {
        listOf(
            VidLinkExtractor(),
            VidukiExtractor(),
            Mov2DayExtractor(),
            VixSrcExtractor(),
            VidsrcNetExtractor(),
            VidsrcRuExtractor(),
            PrimeSrcExtractor(),
            MultiEmbedExtractor(),
            VidFastExtractor(),
            VideasyExtractor(),
            VoeExtractor(),
            StreamtapeExtractor(),
            TwoEmbedExtractor(),
            VidemExtractor(),
            FilemoonExtractor(),
            StreamWishExtractor(),
            VidLoveExtractor(),
            DoodLaExtractor(),
            VidMoLyExtractor(),
            LuluVdoExtractor(),
            MixDropExtractor(),
            SupervideoExtractor(),
            RabbitstreamExtractor(),
            MegacloudExtractor(),
            GxPlayerExtractor(),
            VeevExtractor(),
            VidplayExtractor(),
            VidflixExtractor(),
            VixcloudExtractor(),
            StreamrubyExtractor(),
            StreamUpExtractor(),
            VidaraExtractor(),
            VidHideExtractor(),
            NekostreamExtractor(),
            VidoraExtractor(),
            VidsonicExtractor(),
            VtubeExtractor(),
            OkruExtractor(),
            DailymotionExtractor(),
            GenericIframeExtractor(),
            WorkerExtractor(),
            GenericMediaExtractor(),
        )
    }

    /** Serialises WebView-based extractors so only one WebView is alive at a time. */
    private val webViewMutex = Mutex()

    suspend fun resolveStream(
        tmdbId: String,
        isMovie: Boolean,
        season: Int = 1,
        episode: Int = 1,
        title: String = "",
    ): Map<String, Any>? = withContext(Dispatchers.IO) {
        require(tmdbId.isNotBlank()) { "TMDB ID is required" }

        val media = MediaRequest(tmdbId, isMovie, season, episode, title)
        Log.i(tag, "Resolving TMDB $tmdbId (movie=$isMovie, S$season E$episode)")

        val servers = buildServerList(media)
        if (servers.isEmpty()) {
            Log.w(tag, "No servers found for TMDB $tmdbId")
            return@withContext null
        }
        Log.i(tag, "Built ${servers.size} servers: ${servers.joinToString { it.name }}")

        // Race every server in parallel and take the FIRST playable one instead
        // of walking them one at a time (a single dead server used to stall the
        // whole chain on its 12-45s timeouts). WebView extractors are skipped on
        // 1GB-class boxes so several never render at once and OOM the device.
        // HTTP and WebView extractors use separate semaphores so slow WebViews
        // never block fast HTTP extractors from producing the first result.
        val httpSlots = Semaphore(4)
        val webViewSlots = Semaphore(1)
        val channel = Channel<StreamResult>(Channel.CONFLATED)
        val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
        val jobs = servers.map { server ->
            scope.launch {
                val slots = if (isWebViewServer(server)) webViewSlots else httpSlots
                slots.withPermit {
                    try {
                        extractServer(server)
                            ?.takeIf { it.url.isNotBlank() }
                            ?.let { channel.trySend(it) }
                    } catch (error: Throwable) {
                        if (error is CancellationException) throw error
                        Log.e(tag, "Server ${server.name} failed", error)
                    }
                }
            }
        }
        val first = withTimeoutOrNull(45_000) { channel.receive() }
        jobs.forEach { it.cancel() }
        scope.cancel()
        if (first != null) {
            Log.i(tag, "Resolved ${first.server} to ${first.source}")
            first.toMap()
        } else {
            Log.w(tag, "No playable stream found for TMDB $tmdbId")
            null
        }
    }

    suspend fun resolveStreams(
        tmdbId: String,
        isMovie: Boolean,
        season: Int = 1,
        episode: Int = 1,
        title: String = "",
    ): List<Map<String, Any>> = withContext(Dispatchers.IO) {
        require(tmdbId.isNotBlank()) { "TMDB ID is required" }
        val media = MediaRequest(tmdbId, isMovie, season, episode, title)
        val servers = buildServerList(media)
        val httpSlots = Semaphore(4)
        val webViewSlots = Semaphore(1)
        val collected = CopyOnWriteArrayList<StreamResult>()
        val jobs = servers.map { server ->
            async(Dispatchers.IO) {
                val webView = isWebViewServer(server)
                val slots = if (webView) webViewSlots else httpSlots
                slots.withPermit {
                    val timeout = if (webView) WEBVIEW_SERVER_TIMEOUT_MS else HTTP_SERVER_TIMEOUT_MS
                    withTimeoutOrNull(timeout) {
                        try {
                            // Enrich fills HLS audio renditions for extractors
                            // that early-return without validateHls (list path
                            // only — the playback race never pays for it).
                            extractServer(server)
                                ?.let { enrichHlsAudioTracks(it) }
                                ?.let(collected::add)
                        } catch (error: Throwable) {
                            if (error is CancellationException) throw error
                            Log.w(tag, "Alternative server ${server.name} failed: ${error.message}")
                        }
                    }
                }
            }
        }
        withTimeoutOrNull(ALL_SERVERS_TOTAL_TIMEOUT_MS) {
            jobs.forEach { it.join() }
        }
        jobs.forEach { it.cancel() }
        collected.distinctBy { it.url }.map(StreamResult::toMap)
    }

    private var cachedServerListKey: String? = null
    private var cachedServerList: List<StreamServer>? = null

    /** Server discovery runs once per media request; the secondary call from
     *  [resolveStreams] (server picker) reuses the list instead of re-hitting
     *  every provider. */
    private suspend fun buildServerList(media: MediaRequest): List<StreamServer> {
        val key = "${media.tmdbId}|${media.isMovie}|${media.season}|${media.episode}"
        cachedServerListKey?.let { if (it == key) return cachedServerList.orEmpty() }
        val servers = buildServerListUncached(media)
        cachedServerListKey = key
        cachedServerList = servers
        return servers
    }

    private suspend fun buildServerListUncached(media: MediaRequest): List<StreamServer> = coroutineScope {
        serverProviders.map { provider ->
            async(Dispatchers.IO) {
                try {
                    provider.getServers(media).also {
                        Log.d(tag, "${provider.name} supplied ${it.size} servers")
                    }
                } catch (error: Throwable) {
                    if (error is CancellationException) throw error
                    Log.e(tag, "Server provider ${provider.name} failed", error)
                    emptyList()
                }
            }
        }.awaitAll().flatten().distinctBy { it.url }
    }

    private suspend fun extractGoodstream(server: StreamServer): StreamResult? {
        return withContext(Dispatchers.IO) {
            try {
                requireSafeOutboundUrl(server.url)
                val request = Request.Builder()
                    .url(server.url)
                    .header("User-Agent", userAgent)
                    .header("Referer", "https://goodstream.one")
                    .build()

                val response = client.newCall(request).execute()
                if (!response.isSuccessful) {
                    Log.e(tag, "Goodstream HTTP ${response.code}")
                    return@withContext null
                }

                val html = response.body?.string() ?: return@withContext null
                val extractor = GoodstreamExtractor()
                val result = extractor.extract(html, server.url)

                if (result != null) {
                    val url = result["url"] as String
                    val headers = result["headers"] as? Map<String, String> ?: emptyMap()
                    validateStream(
                        StreamResult(
                            url = url,
                            source = "Goodstream",
                            type = result["type"] as String? ?: "direct",
                            headers = headers
                        )
                    )
                } else {
                    null
                }
            } catch (e: Exception) {
                if (e is CancellationException) throw e
                Log.e(tag, "Goodstream extraction failed: ${e.message}")
                null
            }
        }
    }

    /** Quick check whether a server will route to a WebView-based extractor. */
    private fun isWebViewServer(server: StreamServer): Boolean =
        extractorRegistry.firstOrNull { it.supports(server) }?.usesWebView == true

    private suspend fun extractServer(initialServer: StreamServer): StreamResult? {
        var server = initialServer
        val visited = mutableSetOf<String>()

        repeat(5) {
            if (!visited.add(server.url)) {
                Log.w(tag, "Extractor redirect loop for ${server.name}")
                return null
            }

            // Handle Goodstream specially
            if (server.name == "Goodstream") {
                return extractGoodstream(server)
            }

            val extractor = extractorRegistry.firstOrNull { it.supports(server) }
            if (extractor == null) {
                Log.w(tag, "No extractor for ${server.name}")
                return null
            }
            if (isLowRamDevice() && extractor.usesWebView && extractor.name != "VidLink") {
                Log.w(tag, "Skipping WebView extractor ${extractor.name} on low-RAM device")
                return null
            }
            Log.d(tag, "Dispatching ${server.name} to ${extractor.name}")

            val result = if (extractor.usesWebView) {
                webViewMutex.withLock {
                    try {
                        extractor.extract(server)
                    } catch (error: Throwable) {
                        if (error is CancellationException) throw error
                        Log.e(tag, "Extractor ${extractor.name} failed: ${error.message}")
                        return null
                    }
                }
            } else {
                try {
                    extractor.extract(server)
                } catch (error: Throwable) {
                    if (error is CancellationException) throw error
                    Log.e(tag, "Extractor ${extractor.name} failed: ${error.message}")
                    return null
                }
            }

            when (result) {
                is ExtractionResult.Final -> {
                    val stream = result.stream.copy(server = initialServer.name)
                    if (stream.source == "VidLink" || stream.source == "2Embed") {
                        return stream
                    }
                    return try {
                        validateStream(stream)
                    } catch (error: Throwable) {
                        if (error is CancellationException) throw error
                        Log.w(tag, "Validation failed for ${extractor.name}: ${error.message}")
                        null
                    }
                }
                is ExtractionResult.Redirect -> server = result.server
            }
        }

        Log.w(tag, "Too many extractor redirects for ${initialServer.name}")
        return null
    }

    private inner class StaticTmdbProvider : ServerProvider {
        override val name = "TMDB"

        override suspend fun getServers(request: MediaRequest): List<StreamServer> {
            val id = request.tmdbId
            val servers = mutableListOf<StreamServer>()

            servers += StreamServer(
                "VixSrc",
                if (request.isMovie) {
                    "https://vixsrc.to/api/movie/$id?lang=en"
                } else {
                    "https://vixsrc.to/api/tv/$id/${request.season}/${request.episode}?lang=en"
                },
            )

            servers += StreamServer(
                "VidLink",
                if (request.isMovie) {
                    "https://vidlink.pro/movie/$id"
                } else {
                    "https://vidlink.pro/tv/$id/${request.season}/${request.episode}"
                },
            )

            servers += StreamServer(
                "2Embed",
                if (request.isMovie) {
                    "https://www.2embed.cc/embed/$id"
                } else {
                    "https://www.2embed.cc/embedtv/$id&s=${request.season}&e=${request.episode}"
                },
            )

            servers += StreamServer(
                "VidsrcRu",
                if (request.isMovie) {
                    "https://vidsrc.ru/movie/$id"
                } else {
                    "https://vidsrc.ru/tv/$id/${request.season}/${request.episode}"
                },
            )

            servers += StreamServer(
                "MultiEmbed",
                if (request.isMovie) {
                    "https://multiembed.mov/?video_id=$id&tmdb=1"
                } else {
                    "https://multiembed.mov/?video_id=$id&tmdb=1&s=${request.season}&e=${request.episode}"
                },
            )

            servers += StreamServer(
                "VidFast",
                if (request.isMovie) {
                    "https://vidfast.io/movie/$id"
                } else {
                    "https://vidfast.io/tv/$id/${request.season}/${request.episode}"
                },
            )

            servers += StreamServer(
                "Videasy",
                if (request.isMovie) {
                    "https://player.videasy.to/movie/$id"
                } else {
                    "https://player.videasy.to/tv/$id/${request.season}/${request.episode}"
                },
            )

            servers += StreamServer(
                "Vidflix",
                if (request.isMovie) {
                    "https://vidflix.club/api/movie/$id"
                } else {
                    "https://vidflix.club/api/tv/$id/${request.season}/${request.episode}"
                },
            )

            servers += StreamServer(
                "VidLove",
                if (request.isMovie) {
                    "https://player.vidlove.cc/embed/movie/$id"
                } else {
                    "https://player.vidlove.cc/embed/tv/$id/${request.season}/${request.episode}"
                },
            )

            return servers
        }
    }

    private inner class MoflixProvider : ServerProvider {
        override val name = "Moflix"
        private val origin = "https://moflix-stream.xyz"

        override suspend fun getServers(request: MediaRequest): List<StreamServer> {
            val kind = if (request.isMovie) "movie" else "series"
            val externalId = Base64.encodeToString(
                "tmdb|$kind|${request.tmdbId}".toByteArray(),
                Base64.NO_WRAP,
            )
            val headers = refererHeaders(origin) + mapOf("Accept" to "application/json")
            val response = if (request.isMovie) {
                getJson("$origin/api/v1/titles/${encode(externalId)}?loader=titlePage", headers)
            } else {
                val titleResponse = getJson(
                    "$origin/api/v1/titles/${encode(externalId)}?loader=titlePage",
                    headers,
                )
                val titleId = titleResponse.optJSONObject("title")?.optString("id")
                    .orEmpty().ifBlank { externalId }
                getJson(
                    "$origin/api/v1/titles/${encode(titleId)}/seasons/${request.season}/episodes/${request.episode}?loader=episodePage",
                    headers,
                )
            }

            val videos = response.optJSONArray("videos")
                ?: response.optJSONObject("title")?.optJSONArray("videos")
                ?: response.optJSONObject("episode")?.optJSONArray("videos")
                ?: return emptyList()
            return (0 until videos.length()).mapNotNull { index ->
                val video = videos.optJSONObject(index) ?: return@mapNotNull null
                if (video.optBoolean("premium_locked")) return@mapNotNull null
                val source = video.optString("src")
                val playback = video.optString("playback_resolve_url")
                val url = when {
                    playback.isNotBlank() -> resolveUrl("$origin/api/v1/", playback)
                    source.isNotBlank() -> source
                    else -> return@mapNotNull null
                }
                val label = video.optString("name", "Mirror").ifBlank { "Mirror" }
                StreamServer("Moflix - $label", url, headers)
            }
        }
    }

    private inner class CommunityServerProvider : ServerProvider {
        override val name = "Community"
        private val baseUrl = "https://streamingunity.dog"

        override suspend fun getServers(request: MediaRequest): List<StreamServer> {
            if (request.title.isBlank()) return emptyList()
            val headers = communityHeaders("$baseUrl/")
            val searchUrl = "$baseUrl/en/search?q=${encode(request.title)}&page=1&lang=en"
            val results = getJson(searchUrl, headers).optJSONArray("data") ?: return emptyList()
            val wantedType = if (request.isMovie) "movie" else "tv"
            val title = (0 until results.length()).mapNotNull { results.optJSONObject(it) }
                .firstOrNull {
                    it.optString("type").equals(wantedType, true) &&
                        normalizeTitle(it.optString("name")) == normalizeTitle(request.title)
                } ?: return emptyList()

            val titleId = title.optString("id")
            if (titleId.isBlank()) return emptyList()
            var iframeUrl = "$baseUrl/en/iframe/$titleId?language=en"
            if (!request.isMovie) {
                val slug = title.optString("slug")
                val seasonPage = httpGet(
                    "$baseUrl/en/titles/$titleId-$slug/season-${request.season}",
                    headers,
                )
                val encodedPage = Regex("""data-page=["'](.*?)["']""", RegexOption.DOT_MATCHES_ALL)
                    .find(seasonPage)?.groupValues?.get(1)
                    ?: throw IllegalStateException("Community season metadata was not found")
                val page = JSONObject(
                    Html.fromHtml(encodedPage, Html.FROM_HTML_MODE_LEGACY).toString(),
                )
                val episodes = page.optJSONObject("props")
                    ?.optJSONObject("loadedSeason")
                    ?.optJSONArray("episodes")
                    ?: return emptyList()
                val episode = (0 until episodes.length()).mapNotNull { episodes.optJSONObject(it) }
                    .firstOrNull { it.optInt("number") == request.episode }
                    ?: return emptyList()
                iframeUrl += "&episode_id=${encode(episode.optString("id"))}&next_episode=1"
            }
            return listOf(StreamServer(name, iframeUrl, headers))
        }
    }

    private inner class VidrockServerProvider : ServerProvider {
        override val name = "Vidrock"
        private val passphrase = "x7k9mPqT2rWvY8zA5bC3nF6hJ2lK4mN9"

        override suspend fun getServers(request: MediaRequest): List<StreamServer> {
            val plain = if (request.isMovie) request.tmdbId
                else "${request.tmdbId}_${request.season}_${request.episode}"
            val encoded = aesCbcEncrypt(plain, passphrase)
            val apiUrl = "https://vidrock.net/api/${if (request.isMovie) "movie" else "tv"}/$encoded"
            val json = getJson(apiUrl, refererHeaders("https://vidrock.net/"))

            return json.keys().asSequence().mapNotNull { serverName ->
                val value = json.optJSONObject(serverName) ?: return@mapNotNull null
                if (value.optString("url").isBlank()) return@mapNotNull null
                StreamServer("$serverName (Vidrock)", "$apiUrl#$serverName")
            }.toList()
        }
    }

    private inner class VidzeeServerProvider : ServerProvider {
        override val name = "Vidzee"

        override suspend fun getServers(request: MediaRequest): List<StreamServer> {
            val names = listOf(
                "Nflix", "Duke", "Glory", "Nazy", "Atlas", "Drag", "Achilles",
                "Viet", "Velocita", "Hindi", "Bengali", "Tamil", "Telugu", "Malayalam",
            )
            return names.mapIndexed { index, serverName ->
                val url = if (request.isMovie) {
                    "https://player.vidzee.wtf/api/server?id=${request.tmdbId}&sr=$index"
                } else {
                    "https://player.vidzee.wtf/api/server?id=${request.tmdbId}&ss=${request.season}&ep=${request.episode}&sr=$index"
                }
                StreamServer("$serverName (Vidzee)", url)
            }
        }
    }

    private inner class PrimeSrcServerProvider : ServerProvider {
        override val name = "PrimeSrc"

        override suspend fun getServers(request: MediaRequest): List<StreamServer> {
            val url = if (request.isMovie) {
                "https://primesrc.me/api/v1/s?tmdb=${request.tmdbId}&type=movie"
            } else {
                "https://primesrc.me/api/v1/s?tmdb=${request.tmdbId}&season=${request.season}&episode=${request.episode}&type=tv"
            }
            val json = getJson(url, refererHeaders("https://primesrc.me/"))
            val servers = json.optJSONArray("servers") ?: return emptyList()

            return (0 until servers.length()).mapNotNull { index ->
                val item = servers.optJSONObject(index) ?: return@mapNotNull null
                val key = item.optString("key")
                if (key.isBlank()) return@mapNotNull null
                val serverName = item.optString("name", "PrimeSrc")
                StreamServer(
                    "$serverName (PrimeSrc)",
                    "https://primesrc.me/api/v1/l?key=$key",
                    refererHeaders("https://primesrc.me/"),
                )
            }
        }
    }

    private inner class FrembedServerProvider : ServerProvider {
        override val name = "Frembed"
        private val baseUrl = "https://frembed.click"

        override suspend fun getServers(request: MediaRequest): List<StreamServer> {
            val url = if (request.isMovie) {
                "$baseUrl/api/films?id=${request.tmdbId}&idType=tmdb"
            } else {
                "$baseUrl/api/series?id=${request.tmdbId}&sa=${request.season}&epi=${request.episode}&idType=tmdb"
            }
            return try {
                val json = getJson(url, refererHeaders("$baseUrl/"))
                val linkFields = listOf(
                    "link1", "link2", "link3", "link4", "link5", "link6", "link7",
                    "link1vostfr", "link2vostfr", "link3vostfr", "link4vostfr",
                    "link5vostfr", "link6vostfr", "link7vostfr",
                )
                linkFields.mapNotNull { field ->
                    val path = json.optString(field).ifBlank { return@mapNotNull null }
                    val fullUrl = if (path.startsWith("/")) "$baseUrl$path" else path
                    val lang = when {
                        field.contains("vostfr") -> "VOSTFR"
                        else -> "Default"
                    }
                    StreamServer(
                        "Frembed $lang",
                        fullUrl,
                        refererHeaders("$baseUrl/"),
                    )
                }
            } catch (e: Exception) {
                if (e is CancellationException) throw e
                Log.w(tag, "Frembed provider failed: ${e.message}")
                emptyList()
            }
        }
    }

    private inner class VidukiServerProvider : ServerProvider {
        override val name = "Viduki"

        override suspend fun getServers(request: MediaRequest): List<StreamServer> {
            val id = request.tmdbId
            val servers = mutableListOf<StreamServer>()

            servers += StreamServer(
                "Viduki-1",
                if (request.isMovie) {
                    "https://www.viduki.net/1/movie/$id"
                } else {
                    "https://www.viduki.net/1/tv/$id/${request.season}/${request.episode}"
                },
            )

            servers += StreamServer(
                "Viduki-2",
                if (request.isMovie) {
                    "https://www.viduki.net/2/movie/$id"
                } else {
                    "https://www.viduki.net/2/tv/$id/${request.season}/${request.episode}"
                },
            )

            servers += StreamServer(
                "Viduki-3",
                if (request.isMovie) {
                    "https://www.viduki.net/3/movie/$id"
                } else {
                    "https://www.viduki.net/3/tv/$id/${request.season}/${request.episode}"
                },
            )

            servers += StreamServer(
                "Viduki-4",
                if (request.isMovie) {
                    "https://www.viduki.net/4/movie/$id"
                } else {
                    "https://www.viduki.net/4/tv/$id/${request.season}/${request.episode}"
                },
            )

            return servers
        }
    }

    private inner class MoflixExtractor : HostExtractor {
        override val name = "Moflix"
        private val origin = "https://moflix-stream.xyz"

        override fun supports(server: StreamServer) = host(server.url).endsWith("moflix-stream.xyz")

        override suspend fun extract(server: StreamServer): ExtractionResult {
            if (!server.url.contains("/playback", true)) {
                return GenericMediaExtractor().extract(server)
            }
            val videoId = server.url.substringAfter("videos/", "").substringBefore('/')
            val headers = server.headers + refererHeaders("$origin/watch/$videoId")
            val source = getJson(server.url, headers).optString("src")
            require(source.isNotBlank()) { "Moflix returned no playback source" }
            return ExtractionResult.Final(StreamResult(source, name, mediaType(source), headers))
        }
    }

    private inner class VidflixExtractor : HostExtractor {
        override val name = "Vidflix"
        override fun supports(server: StreamServer) = host(server.url).endsWith("vidflix.club")

        private val playerKey = "3a67e8866ae1d2bb9e81fe7f73315a56eb3bdf5e3e755c7554c8be6910aa6b13"
        private val servers = listOf("scrapify", "oreon", "vaplayer")

        override suspend fun extract(server: StreamServer): ExtractionResult {
            val path = URI(server.url).path.orEmpty()
            val segments = path.split('/').filter { it.isNotBlank() }
            val isMovie = segments.contains("movie")
            val typeIndex = segments.indexOfFirst { it == "movie" || it == "tv" }
            val tmdbId = if (typeIndex >= 0 && typeIndex + 1 < segments.size) {
                segments[typeIndex + 1]
            } else {
                segments.lastOrNull { it.all(Char::isDigit) && it.length >= 2 }
                    ?: throw IllegalStateException("Vidflix: cannot parse TMDB ID from ${server.url}")
            }
            val season = if (!isMovie && typeIndex >= 0 && typeIndex + 2 < segments.size) {
                segments[typeIndex + 2]
            } else null
            val episode = if (!isMovie && typeIndex >= 0 && typeIndex + 3 < segments.size) {
                segments[typeIndex + 3]
            } else null

            for (srv in servers) {
                val apiPath = if (isMovie) {
                    "/api/vidora/v1/movie/$tmdbId?source=$srv"
                } else {
                    "/api/vidora/v1/tv/$tmdbId/${season ?: "1"}/${episode ?: "1"}?source=$srv"
                }
                val apiUrl = "https://player.vidflix.club$apiPath"
                val headers = mapOf(
                    "x-player-key" to playerKey,
                    "Referer" to "https://player.vidflix.club/",
                )
                try {
                    val json = getJson(apiUrl, headers)
                    if (!json.optBoolean("result", false)) continue
                    val source = json.optJSONArray("sources")?.optJSONObject(0) ?: continue
                    val streamUrl = source.optString("url").orEmpty()
                    if (streamUrl.isBlank()) continue
                    val tracks = source.optJSONArray("tracks")?.let { items ->
                        (0 until items.length()).mapNotNull { i ->
                            val item = items.optJSONObject(i) ?: return@mapNotNull null
                            val file = item.optString("file").orEmpty()
                            if (file.isBlank()) return@mapNotNull null
                            SubtitleOption(
                                item.optString("label", "Subtitle"),
                                file,
                                source = "Vidflix",
                            )
                        }
                    }.orEmpty()
                    Log.i(tag, "Vidflix resolved via $srv: $streamUrl")
                    return ExtractionResult.Final(
                        validateStream(
                            StreamResult(streamUrl, name, mediaType(streamUrl), headers, subtitles = tracks),
                        ),
                    )
                } catch (e: Exception) {
                    if (e is CancellationException) throw e
                    Log.w(tag, "Vidflix $srv failed: ${e.message}")
                }
            }
            throw IllegalStateException("Vidflix: all servers failed for $tmdbId")
        }
    }

    @SuppressLint("SetJavaScriptEnabled")
    private inner class VidLinkExtractor : HostExtractor {
        override val name = "VidLink"
        override val usesWebView = true
        override fun supports(server: StreamServer) = host(server.url).endsWith("vidlink.pro")

        private val vidLinkKey = hexToBytes(
            "c75136c5668bbfe65a7ecad431a745db68b5f381555b38d8f6c699449cf11fcd"
        )

        override suspend fun extract(server: StreamServer): ExtractionResult {
            // Prefer Worker (website path) first – Worker-signed HLS plays without 428s on low-RAM
            runCatching { extractViaWorker(server) }
                .getOrNull()
                ?.let { return it }
            runCatching { extractViaHttp(server) }
                .getOrNull()
                ?.let { return it }
            Log.i(tag, "VidLink Worker/HTTP failed; falling back to hardened WebView hook")
            return runCatching { extractViaWebView(server) }
                .getOrElse { e ->
                    if (e is CancellationException) throw e
                    throw IllegalStateException("VidLink WebView failed: ${e.message}", e)
                }
        }

        private suspend fun extractViaWorker(server: StreamServer): ExtractionResult = withContext(Dispatchers.IO) {
            // Worker fallback – mirrors website web_stream_service.dart:42.
            // Only accept Worker-signed HLS (/api/media?token&sig); embed URLs are not playable natively.
            val path = URI(server.url).path.orEmpty()
            val segments = path.split('/').filter { it.isNotBlank() }
            val isMovie = segments.firstOrNull().equals("movie", true)
            val mediaId = segments.getOrNull(1) ?: throw IllegalStateException("VidLink URL missing media id")
            val season = if (segments.firstOrNull().equals("tv", true)) segments.getOrNull(2) ?: "1" else "1"
            val episode = if (segments.firstOrNull().equals("tv", true)) segments.getOrNull(3) ?: "1" else "1"
            val workerUrl = "https://maxstream-worker.maxstream123.workers.dev/api/extract?tmdb_id=$mediaId&is_movie=$isMovie&season=$season&episode=$episode&server=vidlink"
            requireSafeOutboundUrl(workerUrl)
            val request = Request.Builder().url(workerUrl).header("Accept", "application/json").build()
            client.newCall(request).execute().use { response ->
                require(response.isSuccessful) { "Worker HTTP ${response.code}" }
                val body = response.body?.string() ?: throw IllegalStateException("Worker empty")
                val json = JSONObject(body)
                val type = json.optString("type")
                val streamUrl = json.optString("url").ifBlank { throw IllegalStateException("Worker no url") }
                // Worker returns type:hls + /api/media?token&sig for playable streams.
                // type:embed (vidlink.pro/tv/… or 2embed.cc/embed…) is not directly playable in ExoPlayer.
                if (type != "hls" && !streamUrl.contains("/api/media")) {
                    throw IllegalStateException("Worker returned embed, not HLS")
                }
                return@withContext ExtractionResult.Final(StreamResult(streamUrl, name, "direct_m3u8", emptyMap(), method = "Worker"))
            }
        }

        /** Native VidLink bypass: XSalsa20 token -> /api/b/ -> plaintext JSON MP4 playlist. */
        private suspend fun extractViaHttp(server: StreamServer): ExtractionResult {
            return withContext(Dispatchers.IO) {
                val path = URI(server.url).path.orEmpty()
                val segments = path.split('/').filter { it.isNotBlank() }
                val isMovie = segments.firstOrNull().equals("movie", true)
                val isTv = segments.firstOrNull().equals("tv", true)
                require(isMovie || isTv) { "Unsupported VidLink URL: $path" }
                require(segments.size >= 2) { "VidLink URL missing media id" }
                val mediaId = segments[1]

                val timestamp = System.currentTimeMillis() / 1000 + 480
                val message = mediaId.toByteArray(Charsets.UTF_8) + byteArrayOf(
                    ((timestamp ushr 56) and 0xff).toByte(),
                    ((timestamp ushr 48) and 0xff).toByte(),
                    ((timestamp ushr 40) and 0xff).toByte(),
                    ((timestamp ushr 32) and 0xff).toByte(),
                    ((timestamp ushr 24) and 0xff).toByte(),
                    ((timestamp ushr 16) and 0xff).toByte(),
                    ((timestamp ushr 8) and 0xff).toByte(),
                    (timestamp and 0xff).toByte(),
                )
                val nonce = ByteArray(24)
                val token = Base64.encodeToString(
                    nonce + SalsaSecretBox.secretboxDetached(message, vidLinkKey, nonce),
                    Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING,
                )

                val apiUrl = if (isMovie) {
                    "https://vidlink.pro/api/b/movie/$token?multiLang=1"
                } else {
                    require(segments.size >= 4) { "VidLink TV URL missing season/episode" }
                    "https://vidlink.pro/api/b/tv/$token/${segments[2]}/${segments[3]}?multiLang=1"
                }

                requireSafeOutboundUrl(apiUrl)
                val request = Request.Builder()
                    .url(apiUrl)
                    .header("User-Agent", userAgent)
                    .header("Origin", "https://vidlink.pro")
                    .header("Referer", "https://vidlink.pro/")
                    .header("X-Playback-Environment", "standard")
                    .build()
                val response = client.newCall(request).execute()
                require(response.isSuccessful) { "VidLink /api/b/ HTTP ${response.code}" }
                val body = response.body?.string() ?: throw IllegalStateException("VidLink empty response")
                if (body.startsWith("<") || body.startsWith("<!")) {
                    throw IllegalStateException("VidLink API returned HTML (content not in API database)")
                }
                val json = JSONObject(body)
                val stream = json.optJSONObject("stream")
                    ?: throw IllegalStateException("VidLink response has no stream")

                val qualities = stream.optJSONObject("qualities")
                require(qualities != null && qualities.length() > 0) {
                    "VidLink stream has no playable qualities"
                }

                var bestH264Url: String? = null
                var bestH264Height = -1
                var bestH264Headers: Map<String, String> = refererHeaders("https://vidlink.pro/")
                var fallbackH264Url: String? = null
                var fallbackH264Height = -1
                var fallbackH264Headers: Map<String, String> = bestH264Headers
                val qualityOptions = mutableListOf<QualityOption>()
                var hasOriginalHls = false
                val iterator = qualities.keys()
                while (iterator.hasNext()) {
                    val label = iterator.next()
                    val entry = qualities.optJSONObject(label) ?: continue
                    val rawUrl = entry.optString("url").ifBlank { continue }
                    if (rawUrl.contains(".m3u8", true)) hasOriginalHls = true
                    val height = label.toIntOrNull() ?: 0
                    val entryHeaders = entry.optJSONObject("headers")?.let { h ->
                        buildMap {
                            h.keys().forEach { key ->
                                val value = h.optString(key)
                                if (value.isNotBlank()) put(key, value)
                            }
                        }
                    } ?: emptyMap()
                    val requiresProxy = entry.optBoolean("requiresProxy", false)
                    // hakunaymatata.com CDN rejects ANY request with headers (Referer,
                    // Origin, User-Agent) — only bare requests with ExoPlayer's UA work.
                    // The noon.mooncase.online proxy also fails (Cloudflare 403).
                    // Bypass the proxy entirely and play direct CDN URLs with no headers.
                    val isHakuna = rawUrl.contains("hakunaymatata.com")
                    val url = if (requiresProxy && isHakuna) {
                        rawUrl
                    } else if (requiresProxy) {
                        vidLinkProxyUrl(rawUrl, entryHeaders)
                    } else {
                        rawUrl
                    }
                    val mediaHeaders: Map<String, String> = if (isHakuna) {
                        emptyMap()
                    } else {
                        val streamReferer = if (rawUrl.contains("hakunaymatata.com")) {
                            "https://filmboom.top/"
                        } else {
                            "https://vidlink.pro/"
                        }
                        if (requiresProxy) {
                            refererHeaders(streamReferer)
                        } else {
                            refererHeaders(streamReferer) + entryHeaders
                        }
                    }
                    // Skip H.265/HEVC — most Android TV boxes lack stable HW decoders.
                    // CDNs use many path patterns, so check for the common ones.
                    val isH265 = rawUrl.contains("/h265/", true) ||
                        rawUrl.contains("/h.265/", true) ||
                        rawUrl.contains("/hevc/", true) ||
                        rawUrl.contains("_h265_", true) ||
                        rawUrl.contains("_hevc_", true) ||
                        rawUrl.contains("-h265-", true) ||
                        rawUrl.contains("-hevc-", true)
                    if (isH265) continue
                    qualityOptions += QualityOption("${label}p", url, height)
                    if (height > fallbackH264Height) {
                        fallbackH264Height = height
                        fallbackH264Url = url
                        fallbackH264Headers = mediaHeaders
                    }
                    if (height <= 720 && height > bestH264Height) {
                        bestH264Height = height
                        bestH264Url = url
                        bestH264Headers = mediaHeaders
                    }
                }

                val captions = stream.optJSONArray("captions")?.let { items ->
                    (0 until items.length()).mapNotNull { index ->
                        val item = items.optJSONObject(index) ?: return@mapNotNull null
                        val rawUrl = item.optString("url").ifBlank { item.optString("id") }
                        if (rawUrl.isBlank()) return@mapNotNull null
                        val captionUrl = if (rawUrl.startsWith("http")) rawUrl
                            else resolveUrl(server.url, rawUrl)
                        SubtitleOption(
                            item.optString("language", "Subtitle"),
                            captionUrl,
                            source = "VidLink",
                        )
                    }
                }.orEmpty()

                val (url, bestHeaders) = when {
                    bestH264Url != null -> bestH264Url to bestH264Headers
                    fallbackH264Url != null -> fallbackH264Url to fallbackH264Headers
                    else -> throw IllegalStateException("VidLink no quality URL")
                }
                val sortedQualities = qualityOptions.sortedByDescending { it.height }
                // Use raw CDN extension for MIME, not the proxy's /mp/ path
                val finalMediaType = if (url.contains("noon.mooncase.online")) {
                    if (hasOriginalHls) "direct_m3u8" else "mp4"
                } else mediaType(url)
                ExtractionResult.Final(
                    StreamResult(
                        url,
                        name,
                        finalMediaType,
                        bestHeaders,
                        qualities = sortedQualities,
                        subtitles = captions,
                        method = "HTTP",
                    )
                )
            }
        }

        private fun vidLinkProxyUrl(url: String, headers: Map<String, String>): String {
            val uri = URI(url)
            val allowed = setOf("auth", "expires", "hash", "key", "sign", "t", "token")
            val query = uri.rawQuery.orEmpty().split('&').filter { part ->
                part.isNotBlank() && runCatching {
                    URLDecoder.decode(part.substringBefore('='), Charsets.UTF_8.name()).lowercase() in allowed
                }.getOrDefault(false)
            }.toMutableList()
            query += "headers=${encode(JSONObject(headers.toSortedMap()).toString())}"
            query += "host=${encode("${uri.scheme}://${uri.rawAuthority}")}"
            return "https://noon.mooncase.online/mp${uri.rawPath}?${query.joinToString("&")}"
        }

        private fun isH265(url: String): Boolean =
            url.contains("/h265/", true) ||
                url.contains("/h.265/", true) ||
                url.contains("/hevc/", true) ||
                url.contains("_h265_", true) ||
                url.contains("_hevc_", true) ||
                url.contains("-h265-", true) ||
                url.contains("-hevc-", true)

        private suspend fun extractViaWebView(server: StreamServer): ExtractionResult {
            return withContext(Dispatchers.Main) {
                withTimeout(45_000) {
                    suspendCancellableCoroutine { continuation ->
                        val webView = WebView(context)
                        webView.settings.javaScriptEnabled = true
                        webView.settings.loadsImagesAutomatically = false
                        webView.settings.blockNetworkImage = true
                        webView.settings.cacheMode = android.webkit.WebSettings.LOAD_NO_CACHE
                        webView.settings.domStorageEnabled = true
                        webView.settings.mediaPlaybackRequiresUserGesture = false

                        fun finish(result: Result<StreamResult>) {
                            if (!continuation.isActive) return
                            result.fold(
                                onSuccess = { continuation.resume(ExtractionResult.Final(it)) },
                                onFailure = { continuation.resumeWithException(it) },
                            )
                            webView.post { webView.destroy() }
                        }

                        webView.addJavascriptInterface(object {
                            @JavascriptInterface
                            fun onStreamFound(payload: String) {
                                val parsed: Result<StreamResult?> = runCatching {
                                    val json = JSONObject(payload)
                                    val stream = json.optJSONObject("stream") ?: json
                                    val playlist = listOf(
                                        stream.optString("playlist"),
                                        stream.optString("url"),
                                        stream.optString("src"),
                                        stream.optString("file"),
                                    ).firstOrNull { it.isNotBlank() }
                                    require(!playlist.isNullOrBlank()) {
                                        "VidLink stream has no playlist URL"
                                    }
                                    if (isH265(playlist)) return@runCatching null
                                    val captions = stream.optJSONArray("captions")?.let { items ->
                                        (0 until items.length()).mapNotNull { index ->
                                            val item = items.optJSONObject(index) ?: return@mapNotNull null
                                            val rawUrl = item.optString("id").ifBlank {
                                                item.optString("url")
                                            }
                                            if (rawUrl.isBlank()) return@mapNotNull null
                                            val captionUrl = if (rawUrl.startsWith("http")) rawUrl
                                                else resolveUrl(server.url, rawUrl)
                                            SubtitleOption(
                                                item.optString("language", "Subtitle"),
                                                captionUrl,
                                                source = "VidLink",
                                            )
                                        }
                                    }.orEmpty()
                                    val referer = if (host(playlist).endsWith("hakunaymatata.com")) {
                                        // hakunaymatata.com CDN rejects Referer — use empty headers.
                                        ""
                                    } else {
                                        "https://vidlink.pro/"
                                    }
                                    StreamResult(
                                        playlist,
                                        name,
                                        mediaType(playlist),
                                        if (referer.isNotEmpty()) refererHeaders(referer) else emptyMap(),
                                        subtitles = captions,
                                        method = "WebView",
                                    )
                                }
                                val nonNull = parsed.getOrNull()
                                if (nonNull != null) {
                                    finish(Result.success(nonNull))
                                }
                            }
                        }, "NativeBridge")

                        webView.webViewClient = object : WebViewClient() {
                            override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
                                val reqUrl = request.url.toString()
                                // Real JS injection capture: intercept HLS/mp4 directly – mirrors vidlink-extension
                                if ((reqUrl.contains(".m3u8") || reqUrl.contains(".mp4")) && !reqUrl.contains("noir.suubmon.store")) {
                                    if (isH265(reqUrl)) return super.shouldInterceptRequest(view, request)
                                    val isHls = reqUrl.contains(".m3u8")
                                    val result = runCatching {
                                        // hakunaymatata.com CDN rejects Referer — send empty headers.
                                        val hdrs = if (reqUrl.contains("hakunaymatata.com")) emptyMap() else refererHeaders("https://vidlink.pro/")
                                        StreamResult(reqUrl, name, if (isHls) "hls" else "mp4", hdrs)
                                    }
                                    if (result.isSuccess) {
                                        view.post { finish(result) }
                                    }
                                }
                                val blocked = listOf("googletagmanager", "google-analytics", "yandex", "clarity", "bing", "adscore", "pemsrv", "usrpubtrk", "adexchangerapid", "intellipopup", "cloudflareinsights")
                                if (blocked.any { reqUrl.contains(it, true) }) {
                                    return WebResourceResponse("text/plain", "utf-8", java.io.ByteArrayInputStream(ByteArray(0)))
                                }
                                return super.shouldInterceptRequest(view, request)
                            }
                            override fun onPageFinished(view: WebView, url: String) {
                                val script = """
                                    (() => {
                                      if (window.__nativeStreamHook) return;
                                      window.__nativeStreamHook = true;
                                      const send = data => window.NativeBridge.onStreamFound(JSON.stringify(data));
                                      const isPlayable = s => typeof s === 'string' &&
                                        !s.includes('noir.suubmon.store') &&
                                        /\.(m3u8|mp4)([?#]|$)/i.test(s);
                                      const pickBest = qualities => {
                                        if (!qualities || typeof qualities !== 'object') return null;
                                        let best = null;
                                        let bestH = -1;
                                        for (const [label, q] of Object.entries(qualities)) {
                                          if (!q || typeof q !== 'object') continue;
                                          if (q.type && q.type !== 'mp4') continue;
                                          const h = parseInt(label, 10) || 0;
                                          const u = q.url;
                                          if (!u) continue;
                                          if (h > bestH) { best = { url: u, captions: qualities.__captions }; bestH = h; }
                                        }
                                        return best;
                                      };
                                      const extractPlaylist = obj => {
                                        if (!obj || typeof obj !== 'object') return null;
                                        if (isPlayable(obj.playlist)) return obj;
                                        const s = obj.stream;
                                        if (s && typeof s === 'object') {
                                          if (s.qualities && typeof s.qualities === 'object') {
                                            const picked = pickBest(s.qualities);
                                            if (picked && picked.url) return { stream: { playlist: picked.url, captions: s.captions } };
                                          }
                                          const p = s.playlist || s.url || s.src || s.file;
                                          if (isPlayable(p)) return { stream: { playlist: p, captions: s.captions } };
                                        }
                                        const p = obj.url || obj.src || obj.file || obj.hls;
                                        if (isPlayable(p)) return { stream: { playlist: p } };
                                        return null;
                                      };
                                      const originalFetch = window.fetch.bind(window);
                                      window.fetch = async (...args) => {
                                        const response = await originalFetch(...args);
                                        try {
                                          const u = response.url || '';
                                          if (u.includes('/api/b/')) {
                                            response.clone().text().then(text => {
                                              try {
                                                const payload = extractPlaylist(JSON.parse(text));
                                                if (payload) send(payload);
                                              } catch (e) {}
                                            }).catch(() => {});
                                          }
                                          if (isPlayable(u)) send({ stream: { playlist: u } });
                                        } catch (e) {}
                                        return response;
                                      };
                                      const origOpen = XMLHttpRequest.prototype.open;
                                      XMLHttpRequest.prototype.open = function(method, url, ...rest) {
                                        this.addEventListener('load', function() {
                                          try {
                                            if (isPlayable(url)) send({ stream: { playlist: url } });
                                            if ((url || '').includes('/api/b/')) {
                                              const payload = extractPlaylist(JSON.parse(this.responseText));
                                              if (payload) send(payload);
                                            }
                                          } catch (e) {}
                                        });
                                        return origOpen.apply(this, [method, url, ...rest]);
                                      };
                                      setInterval(() => {
                                        try {
                                          const v = document.querySelector('video');
                                          if (!v) return;
                                          const src = v.currentSrc || v.src || '';
                                          if (isPlayable(src) && !src.startsWith('blob:')) {
                                            send({ stream: { playlist: src } });
                                          }
                                        } catch (e) {}
                                      }, 1500);
                                    })();
                                """.trimIndent()
                                view.evaluateJavascript(script, null)
                            }
                        }
                        webView.loadUrl(server.url)
                        continuation.invokeOnCancellation {
                            webView.post {
                                webView.stopLoading()
                                webView.destroy()
                            }
                        }
                    }
                }
            }
        }
    }

    @SuppressLint("SetJavaScriptEnabled")
    private inner class VidukiExtractor : HostExtractor {
        override val name = "Viduki"
        override val usesWebView = true
        override fun supports(server: StreamServer) = host(server.url).endsWith("viduki.net")

        override suspend fun extract(server: StreamServer): ExtractionResult {
            return withContext(Dispatchers.Main) {
                withTimeout(30_000) {
                    suspendCancellableCoroutine { continuation ->
                        val webView = WebView(context)
                        webView.settings.javaScriptEnabled = true
                        webView.settings.loadsImagesAutomatically = false
                        webView.settings.blockNetworkImage = true
                        webView.settings.cacheMode = android.webkit.WebSettings.LOAD_NO_CACHE
                        webView.settings.domStorageEnabled = true
                        webView.settings.mediaPlaybackRequiresUserGesture = false

                        fun finish(result: Result<StreamResult>) {
                            if (!continuation.isActive) return
                            result.fold(
                                onSuccess = { continuation.resume(ExtractionResult.Final(it)) },
                                onFailure = { continuation.resumeWithException(it) },
                            )
                            webView.post { webView.destroy() }
                        }

                        webView.addJavascriptInterface(object {
                            @JavascriptInterface
                            fun onStreamFound(url: String) {
                                if (url.isNotBlank() && continuation.isActive) {
                                    val headers = refererHeaders("https://www.viduki.net/")
                                    finish(Result.success(StreamResult(url, name, mediaType(url), headers, method = "WebView")))
                                }
                            }
                        }, "NativeBridge")

                        webView.webViewClient = object : WebViewClient() {
                            override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
                                val reqUrl = request.url.toString()
                                if ((reqUrl.contains(".m3u8") || reqUrl.contains(".mp4")) &&
                                    !reqUrl.contains("google") && !reqUrl.contains("cloudflare")
                                ) {
                                    if (continuation.isActive) {
                                        val headers = refererHeaders("https://www.viduki.net/")
                                        finish(Result.success(StreamResult(reqUrl, name, mediaType(reqUrl), headers)))
                                    }
                                }
                                val blocked = listOf("googletagmanager", "google-analytics", "clarity", "adscore", "cloudflareinsights")
                                if (blocked.any { reqUrl.contains(it, true) }) {
                                    return WebResourceResponse("text/plain", "utf-8", java.io.ByteArrayInputStream(ByteArray(0)))
                                }
                                return super.shouldInterceptRequest(view, request)
                            }

                            override fun onPageFinished(view: WebView, url: String) {
                                val script = """
                                    (() => {
                                      if (window.__vidukiHook) return;
                                      window.__vidukiHook = true;
                                      const send = u => window.NativeBridge.onStreamFound(u);
                                      const isPlayable = s => typeof s === 'string' && /\.(m3u8|mp4)([?#]|$)/i.test(s);

                                      const originalFetch = window.fetch.bind(window);
                                      window.fetch = async (...args) => {
                                        const response = await originalFetch(...args);
                                        try {
                                          const u = response.url || '';
                                          if (isPlayable(u)) send(u);
                                          response.clone().text().then(text => {
                                            try {
                                              const json = JSON.parse(text);
                                              const src = json.url || json.src || json.file || json.playlist || (json.stream && json.stream.playlist);
                                              if (isPlayable(src)) send(src);
                                            } catch (e) {}
                                          }).catch(() => {});
                                        } catch (e) {}
                                        return response;
                                      };
                                      const origOpen = XMLHttpRequest.prototype.open;
                                      XMLHttpRequest.prototype.open = function(method, url, ...rest) {
                                        this.addEventListener('load', function() {
                                          try {
                                            if (isPlayable(url)) send(url);
                                            const resp = this.responseText;
                                            const json = JSON.parse(resp);
                                            const src = json.url || json.src || json.file || json.playlist || (json.stream && json.stream.playlist);
                                            if (isPlayable(src)) send(src);
                                          } catch (e) {}
                                        });
                                        return origOpen.apply(this, [method, url, ...rest]);
                                      };
                                      setInterval(() => {
                                        try {
                                          const v = document.querySelector('video');
                                          if (v) {
                                            const src = v.currentSrc || v.src || '';
                                            if (isPlayable(src) && !src.startsWith('blob:')) send(src);
                                          }
                                          const iframes = document.querySelectorAll('iframe');
                                          iframes.forEach(f => {
                                            try {
                                              const s = f.contentDocument && f.contentDocument.querySelector('video');
                                              if (s) {
                                                const src = s.currentSrc || s.src || '';
                                                if (isPlayable(src) && !src.startsWith('blob:')) send(src);
                                              }
                                            } catch (e) {}
                                          });
                                        } catch (e) {}
                                      }, 1500);
                                    })();
                                """.trimIndent()
                                view.evaluateJavascript(script, null)
                            }
                        }

                        webView.loadUrl(server.url)
                        continuation.invokeOnCancellation {
                            webView.post {
                                webView.stopLoading()
                                webView.destroy()
                            }
                        }
                    }
                }
            }
        }
    }

    private inner class WorkerExtractor : HostExtractor {
        override val name = "Worker"

        override fun supports(server: StreamServer): Boolean =
            host(server.url).endsWith("maxstream123.workers.dev")

        override suspend fun extract(server: StreamServer): ExtractionResult {
            val json = runCatching {
                JSONObject(httpGet(server.url))
            }.getOrNull() ?: throw IllegalStateException("Worker returned invalid JSON")

            val url = json.optString("url").ifBlank {
                val error = json.optString("error").ifBlank { "Worker returned no URL" }
                throw IllegalStateException(error)
            }
            val type = json.optString("type").ifBlank { mediaType(url) }

            if (type == "embed") {
                val source = json.optString("source").ifBlank { "Worker (VidLink)" }
                return ExtractionResult.Redirect(
                    StreamServer(source, url, refererHeaders("https://maxstream-worker.maxstream123.workers.dev")),
                )
            }

            val source = json.optString("source").ifBlank { "Worker (VidLink)" }
            val workerHeaders = runCatching {
                val h = json.optJSONObject("headers")
                if (h != null) {
                    val map = mutableMapOf<String, String>()
                    for (key in h.keys()) {
                        h.optString(key).ifBlank { null }?.let { map[key] = it }
                    }
                    map.toMap()
                } else emptyMap()
            }.getOrDefault(emptyMap()).ifEmpty { refererHeaders("https://maxstream-worker.maxstream123.workers.dev") }

            val subtitles = runCatching {
                val subs = json.optJSONArray("subtitles")
                if (subs != null) {
                    (0 until subs.length()).mapNotNull { i ->
                        val sub = subs.getJSONObject(i)
                        val subUrl = sub.optString("url").ifBlank { return@mapNotNull null }
                        SubtitleOption(
                            sub.optString("language", "Subtitle"),
                            subUrl,
                            source = source,
                        )
                    }
                } else emptyList()
            }.getOrDefault(emptyList())

            return ExtractionResult.Final(
                validateStream(
                    StreamResult(url, source, type, workerHeaders, subtitles = subtitles),
                ),
            )
        }
    }

    @SuppressLint("SetJavaScriptEnabled")
    private inner class MaxstreamVideoExtractor : HostExtractor {
        override val name = "MaxstreamVideo"
        override val usesWebView = true
        override fun supports(server: StreamServer) = host(server.url).endsWith("maxstream.video")

        override suspend fun extract(server: StreamServer): ExtractionResult {
            return withContext(Dispatchers.Main) {
                withTimeout(30_000) {
                    suspendCancellableCoroutine { continuation ->
                        val webView = WebView(context)
                        webView.settings.javaScriptEnabled = true
                        webView.settings.loadsImagesAutomatically = false
                        webView.settings.blockNetworkImage = true
                        webView.settings.cacheMode = android.webkit.WebSettings.LOAD_NO_CACHE
                        webView.settings.domStorageEnabled = true
                        webView.settings.mediaPlaybackRequiresUserGesture = false

                        fun finish(result: Result<StreamResult>) {
                            if (!continuation.isActive) return
                            result.fold(
                                onSuccess = { continuation.resume(ExtractionResult.Final(it)) },
                                onFailure = { continuation.resumeWithException(it) },
                            )
                            webView.post { webView.destroy() }
                        }

                        webView.addJavascriptInterface(object {
                            @JavascriptInterface
                            fun onStreamFound(payload: String) {
                                runCatching {
                                    val json = JSONObject(payload)
                                    val streamUrl = json.optString("url").ifBlank {
                                        json.optString("src")
                                    }
                                    require(streamUrl.isNotBlank()) { "No stream URL found" }
                                    val headers = refererHeaders("https://maxstream.video/")
                                    StreamResult(streamUrl, name, mediaType(streamUrl), headers)
                                }.let(::finish)
                            }

                            @JavascriptInterface
                            fun onSourceFound(url: String) {
                                if (url.isNotBlank()) {
                                    val headers = refererHeaders("https://maxstream.video/")
                                    finish(Result.success(StreamResult(url, name, mediaType(url), headers)))
                                }
                            }
                        }, "NativeBridge")

                        webView.webViewClient = object : WebViewClient() {
                            override fun onPageFinished(view: WebView, url: String) {
                                val script = """
                                    (() => {
                                      if (window.__maxstreamHook) return;
                                      window.__maxstreamHook = true;
                                      const send = data => window.NativeBridge.onStreamFound(JSON.stringify(data));
                                      const sendUrl = url => window.NativeBridge.onSourceFound(url);

                                      // Intercept fetch
                                      const originalFetch = window.fetch.bind(window);
                                      window.fetch = async (...args) => {
                                        const response = await originalFetch(...args);
                                        const u = response.url;
                                        if (u.includes('.m3u8') || u.includes('.mp4') || u.includes('/stream/') || u.includes('/play/')) {
                                          sendUrl(u);
                                        }
                                        return response;
                                      };

                                      // Intercept XMLHttpRequest
                                      const origOpen = XMLHttpRequest.prototype.open;
                                      XMLHttpRequest.prototype.open = function(method, url, ...rest) {
                                        this.addEventListener('load', function() {
                                          if (url.includes('.m3u8') || url.includes('.mp4') || url.includes('/stream/') || url.includes('/play/')) {
                                            sendUrl(url);
                                          }
                                        });
                                        return origOpen.apply(this, [method, url, ...rest]);
                                      };

                                      // Check for sources in window/player
                                      const checkSources = () => {
                                        if (window.player && window.player.sources) {
                                          send({ url: window.player.sources });
                                        }
                                        if (window.video && window.video.src) {
                                          sendUrl(window.video.src);
                                        }
                                        // Look for sources in scripts
                                        document.querySelectorAll('script').forEach(s => {
                                          const text = s.textContent || '';
                                          const match = text.match(/sources\s*:\s*\[\s*\{\s*[sS]rc\s*:\s*['"]([^'"]+)/);
                                          if (match) sendUrl(match[1]);
                                          const match2 = text.match(/file\s*:\s*['"]([^'"]+\.m3u8[^'"]*)/);
                                          if (match2) sendUrl(match2[1]);
                                        });
                                      };
                                      setTimeout(checkSources, 2000);
                                      setTimeout(checkSources, 5000);
                                    })();
                                """.trimIndent()
                                view.evaluateJavascript(script, null)
                            }

                            override fun shouldInterceptRequest(
                                view: WebView?,
                                request: WebResourceRequest?,
                            ): WebResourceResponse? {
                                val url = request?.url?.toString() ?: ""
                                if (url.contains(".m3u8") || url.contains(".mp4")) {
                                    if (continuation.isActive) {
                                        continuation.resume(
                                            ExtractionResult.Final(
                                                StreamResult(url, name, mediaType(url), refererHeaders("https://maxstream.video/")),
                                            ),
                                        )
                                    }
                                }
                                return super.shouldInterceptRequest(view, request)
                            }
                        }

                        webView.loadUrl(server.url)
                        continuation.invokeOnCancellation {
                            webView.post {
                                webView.stopLoading()
                                webView.destroy()
                            }
                        }
                    }
                }
            }
        }
    }

    @SuppressLint("SetJavaScriptEnabled")
    private inner class Mov2DayExtractor : HostExtractor {
        override val name = "Mov2Day"
        override val usesWebView = true

        override fun supports(server: StreamServer): Boolean {
            return host(server.url).endsWith("mov2day.xyz")
        }

        override suspend fun extract(server: StreamServer): ExtractionResult {
            return try {
                extractHttp(server)
            } catch (error: Throwable) {
                if (error is CancellationException) throw error
                Log.w(tag, "Mov2Day HTTP route failed (${error.message}); retrying through WebView")
                extractViaWebView(server)
            }
        }

        private suspend fun extractHttp(server: StreamServer): ExtractionResult {
            val landingHtml = httpGet(server.url, refererHeaders("https://vidflix.club/"))
            val embedBase = Regex(
                """const\s+EMBED_BASE\s*=\s*["']([^"']+)["']""",
                RegexOption.IGNORE_CASE,
            ).find(landingHtml)?.groupValues?.get(1)
                ?: throw IllegalStateException("Alternate Vidflix embed base was not found")

            val mediaPath = URI(server.url).rawPath.orEmpty()
            require(mediaPath.isNotBlank()) { "Alternate Vidflix media path was not found" }
            val embedUrl = "${embedBase.trimEnd('/')}/${mediaPath.trimStart('/')}"
            val embedHtml = httpGet(embedUrl, refererHeaders(server.url))
            val framePath = Regex(
                """<iframe[^>]+src\s*=\s*["']([^"']+)["']""",
                setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL),
            ).find(embedHtml)?.groupValues?.get(1)
                ?: throw IllegalStateException("Alternate Vidflix player frame was not found")
            val frameUrl = resolveUrl(embedUrl, framePath.replace("&amp;", "&"))

            val playerHtml = httpGet(frameUrl, refererHeaders(embedUrl))
            val configPayload = extractJsObject(playerHtml, "CONFIG")
                ?: throw IllegalStateException("Alternate Vidflix player configuration was not found")
            val config = JSONObject(configPayload)
            val apiBase = config.optString("streamDataApiUrl")
            val mediaId = config.optString("mediaId")
            val mediaKind = config.optString("mediaType")
            require(apiBase.isNotBlank() && mediaId.isNotBlank() && mediaKind.isNotBlank()) {
                "Alternate Vidflix player configuration was incomplete"
            }

            val apiUrl = apiBase.toHttpUrl().newBuilder().apply {
                addQueryParameter(if (config.optString("idType") == "imdb") "imdb" else "tmdb", mediaId)
                addQueryParameter("type", mediaKind)
                if (mediaKind.equals("tv", true)) {
                    addQueryParameter("season", config.optInt("season", 1).toString())
                    addQueryParameter("episode", config.optInt("episode", 1).toString())
                }
            }.build().toString()
            val response = getJson(apiUrl, refererHeaders(frameUrl))
            val data = response.optJSONObject("data") ?: response.optJSONObject("result")
            val streams = data?.optJSONArray("stream_urls")
                ?: data?.optJSONArray("streams")
                ?: response.optJSONArray("stream_urls")
                ?: throw IllegalStateException("Alternate Vidflix source returned no stream list")
            val frameOrigin = URI(frameUrl).let { "${it.scheme}://${it.host}" }
            val headers = refererHeaders(frameUrl) + mapOf("Origin" to frameOrigin)

            for (index in 0 until streams.length()) {
                val raw = streams.opt(index)
                val streamUrl = when (raw) {
                    is String -> raw
                    is JSONObject -> {
                        raw.optString("url").ifBlank { raw.optString("src") }
                    }
                    else -> ""
                }
                if (streamUrl.isBlank()) continue
                val candidate = StreamResult(
                    streamUrl,
                    name,
                    mediaType(streamUrl),
                    headers,
                    subtitles = server.subtitles.distinctBy { it.url },
                )
                try {
                    return ExtractionResult.Final(validateStream(candidate))
                } catch (error: Throwable) {
                    if (error is CancellationException) throw error
                    Log.w(tag, "Alternate Vidflix route failed: ${error.message}")
                }
            }
            throw IllegalStateException("Alternate Vidflix source returned no playable route")
        }

        private suspend fun extractViaWebView(server: StreamServer): ExtractionResult {
            return withContext(Dispatchers.Main) {
                withTimeout(45_000) {
                    suspendCancellableCoroutine { continuation ->
                        val webView = WebView(context)
                        webView.settings.javaScriptEnabled = true
                        webView.settings.loadsImagesAutomatically = false
                        webView.settings.blockNetworkImage = true
                        webView.settings.cacheMode = android.webkit.WebSettings.LOAD_NO_CACHE
                        webView.settings.domStorageEnabled = true
                        webView.settings.mediaPlaybackRequiresUserGesture = false

                        fun finish(result: Result<StreamResult>) {
                            if (!continuation.isActive) return
                            result.fold(
                                onSuccess = { continuation.resume(ExtractionResult.Final(it)) },
                                onFailure = { continuation.resumeWithException(it) },
                            )
                            webView.post { webView.destroy() }
                        }

                        val mediaPath = URI(server.url).rawPath.orEmpty()
                        webView.addJavascriptInterface(object {
                            @JavascriptInterface
                            fun onEmbedBase(base: String) {
                                if (!continuation.isActive) return
                                if (base.isBlank() || mediaPath.isBlank()) {
                                    finish(
                                        Result.failure(
                                            IllegalStateException("Mov2Day embed base was not found"),
                                        ),
                                    )
                                    return
                                }
                                val embedUrl = "${base.trimEnd('/')}$mediaPath"
                                webView.post {
                                    if (continuation.isActive) webView.loadUrl(embedUrl)
                                }
                            }
                        }, "NativeBridge")

                        webView.webViewClient = object : WebViewClient() {
                            override fun onPageFinished(view: WebView, url: String) {
                                if (host(url).endsWith("mov2day.xyz") && !url.contains("/embed", true)) {
                                    val script = """
                                        (() => {
                                          const text = [...document.querySelectorAll('script')]
                                            .map(s => s.textContent || '').join('\n');
                                          const m = text.match(/EMBED_BASE\s*=\s*['"]([^'"]+)['"]/);
                                          window.NativeBridge.onEmbedBase(m ? m[1] : '');
                                        })();
                                    """.trimIndent()
                                    view.evaluateJavascript(script, null)
                                }
                            }

                            override fun shouldInterceptRequest(
                                view: WebView?,
                                request: WebResourceRequest?,
                            ): WebResourceResponse? {
                                val url = request?.url?.toString() ?: ""
                                val isMediaRequest = url.contains(".m3u8", true) ||
                                    url.contains(".mp4", true) ||
                                    url.contains(".ts?", true) ||
                                    url.contains("/playlist", true) ||
                                    url.contains("/master.", true) ||
                                    url.contains("videoplayback", true)
                                if (isMediaRequest && continuation.isActive) {
                                    val origin = URI(url).let { "${it.scheme}://${it.host}" }
                                    val cookies = CookieManager.getInstance()
                                        .getCookie(url).orEmpty()
                                    val headers = buildMap {
                                        putAll(refererHeaders(origin))
                                        put("Origin", origin)
                                        if (cookies.isNotBlank()) put("Cookie", cookies)
                                    }
                                    finish(
                                        Result.success(
                                            StreamResult(
                                                url,
                                                name,
                                                mediaType(url),
                                                headers,
                                                subtitles = server.subtitles.distinctBy { it.url },
                                            ),
                                        ),
                                    )
                                }
                                return super.shouldInterceptRequest(view, request)
                            }
                        }

                        webView.loadUrl(server.url)
                        continuation.invokeOnCancellation {
                            webView.post {
                                webView.stopLoading()
                                webView.destroy()
                            }
                        }
                    }
                }
            }
        }
    }

    private inner class VixSrcExtractor : HostExtractor {
        override val name = "VixSrc"
        override fun supports(server: StreamServer) = host(server.url).endsWith("vixsrc.to")

        override suspend fun extract(server: StreamServer): ExtractionResult {
            val headers = refererHeaders("https://vixsrc.to") + mapOf("X-Requested-With" to "XMLHttpRequest")
            var api = getJson(server.url, headers)
            var embedPath = api.optString("src").trimStart('/')
            require(embedPath.isNotBlank()) { "VixSrc returned no embed path" }
            var embedUrl = "https://vixsrc.to/$embedPath"

            var html = try {
                httpGet(embedUrl, refererHeaders("https://vixsrc.to"))
            } catch (e: Exception) {
                if (e is CancellationException) throw e
                val isGone = e.message?.contains("410") == true || e.message?.contains("Gone") == true
                if (isGone) {
                    Log.d(tag, "VixSrc embed returned 410, retrying API for fresh path")
                    api = getJson(server.url, headers)
                    embedPath = api.optString("src").trimStart('/')
                    require(embedPath.isNotBlank()) { "VixSrc retry returned no embed path" }
                    embedUrl = "https://vixsrc.to/$embedPath"
                    httpGet(embedUrl, refererHeaders("https://vixsrc.to"))
                } else throw e
            }

            val videoSection = html.substringAfter("window.video = {", "")
            val playlistSection = html.substringAfter("window.masterPlaylist", "")
            val videoId = between(videoSection, "id: '", "'")
            val token = between(playlistSection, "'token': '", "'")
            val expires = between(playlistSection, "'expires': '", "'")
            require(videoId != null && token != null && expires != null) {
                "VixSrc player parameters were not found"
            }

            // The page's masterPlaylist.url is the authoritative playlist base:
            // it already carries the per-title flags the player needs ("?b=1" is
            // baked in for some TV titles and absent for movies and others).
            // Rebuilding the URL from scratch and adding "b=1" from a page-wide
            // substring match was wrong: the "?ub=1"/"?ab=1" stream entries also
            // contain "b=1", so movies and b=1-less TV titles got a bogus "b=1"
            // and vixsrc.to answered 403 - series intermittently failed to
            // fetch. Append only token/expires/lang (+h=1 when the page
            // advertises FHD) onto the page's own URL.
            val masterUrl =
                between(playlistSection, "url: '", "'") ?: "https://vixsrc.to/playlist/$videoId"
            val query =
                mutableListOf(
                    "token=${encode(token)}",
                    "expires=${encode(expires)}",
                    "lang=en",
                )
            if (html.contains("window.canPlayFHD = true")) query += "h=1"
            val separator = if (masterUrl.contains("?")) "&" else "?"
            val streamUrl = "$masterUrl$separator${query.joinToString("&")}"
            // ExoPlayer uses a different HTTP stack than OkHttp and won't have the cookies
            // that were set during API/embed page fetching. Forward them explicitly.
            val vixCookies = client.cookieJar.loadForRequest("https://vixsrc.to".toHttpUrl())
            val cookieHeader = vixCookies.joinToString("; ") { "${it.name}=${it.value}" }
            val responseHeaders = refererHeaders("https://vixsrc.to") +
                mapOf("Origin" to "https://vixsrc.to") +
                (if (cookieHeader.isNotBlank()) mapOf("Cookie" to cookieHeader) else emptyMap())
            validateFirstHlsSegment(streamUrl, responseHeaders)
            return ExtractionResult.Final(
                StreamResult(streamUrl, name, "direct_m3u8", responseHeaders),
            )
        }
    }

    private inner class CommunityExtractor : HostExtractor {
        override val name = "Community"

        override fun supports(server: StreamServer) = host(server.url).endsWith("streamingunity.dog")

        override suspend fun extract(server: StreamServer): ExtractionResult {
            val html = httpGet(server.url, communityHeaders("https://streamingunity.dog/"))
            val iframe = Regex(
                """<iframe[^>]+src=["']([^"']+)["']""",
                RegexOption.IGNORE_CASE,
            ).find(html)?.groupValues?.get(1)?.replace("&amp;", "&")
                ?: throw IllegalStateException("Community player iframe was not found")
            return ExtractionResult.Redirect(
                StreamServer(name, resolveUrl(server.url, iframe), mapOf("Referer" to server.url)),
            )
        }
    }

    private inner class VixcloudExtractor : HostExtractor {
        override val name = "Vixcloud"

        override fun supports(server: StreamServer) = host(server.url).endsWith("vixcloud.co")

        override suspend fun extract(server: StreamServer): ExtractionResult {
            val pageUrl = server.url.replace("&amp;", "&")
            val page = httpGet(pageUrl, refererHeaders(server.headers["Referer"] ?: "https://vixcloud.co/"))
            val videoId = Regex("""window\.video\s*=\s*\{.*?id:\s*['"]?([^,'"\s}]+)""", RegexOption.DOT_MATCHES_ALL)
                .find(page)?.groupValues?.get(1)
                ?: throw IllegalStateException("Vixcloud video ID was not found")
            val playlistSection = page.substringAfter("window.masterPlaylist", "")
            val token = Regex("""['"]?token['"]?\s*:\s*['"]([^'"]+)""")
                .find(playlistSection)?.groupValues?.get(1)
                ?: throw IllegalStateException("Vixcloud token was not found")
            val expires = Regex("""['"]?expires['"]?\s*:\s*['"]([^'"]+)""")
                .find(playlistSection)?.groupValues?.get(1)
                ?: throw IllegalStateException("Vixcloud expiry was not found")
            val origin = URI(pageUrl).let { "${it.scheme}://${it.host}" }
            val parameters = mutableListOf(
                "token=${encode(token)}",
                "expires=${encode(expires)}",
                "language=en",
            )
            if (page.contains("window.canPlayFHD = true")) parameters += "h=1"
            val streamUrl = "$origin/playlist/$videoId?${parameters.joinToString("&")}"
            return ExtractionResult.Final(
                StreamResult(streamUrl, name, "direct_m3u8", refererHeaders("$origin/")),
            )
        }
    }

    private inner class VidsrcNetExtractor : HostExtractor {
        override val name = "Vidsrc"
        override fun supports(server: StreamServer): Boolean {
            val domain = host(server.url)
            return domain.endsWith("vidsrc-embed.ru") || domain.endsWith("vsembed.ru") ||
                domain.endsWith("cloudorchestranova.com")
        }

        override suspend fun extract(server: StreamServer): ExtractionResult {
            val embedPage = httpGet(server.url)

            // Try data-api attribute first (newer format), then src
            val iframePath = Regex(
                """<iframe[^>]+id=["']player_iframe["'][^>]+data-api=["']([^"']+)["']""",
                RegexOption.IGNORE_CASE,
            ).find(embedPage)?.groupValues?.get(1)
                ?: Regex(
                    """<iframe[^>]+data-api=["']([^"']+)["'][^>]+id=["']player_iframe["']""",
                    RegexOption.IGNORE_CASE,
                ).find(embedPage)?.groupValues?.get(1)
                ?: Regex(
                    """<iframe[^>]+id=["']player_iframe["'][^>]+src=["']([^"']+)["']""",
                    RegexOption.IGNORE_CASE,
                ).find(embedPage)?.groupValues?.get(1)
                ?: Regex(
                    """<iframe[^>]+src=["']([^"']+)["'][^>]+id=["']player_iframe["']""",
                    RegexOption.IGNORE_CASE,
                ).find(embedPage)?.groupValues?.get(1)
                ?: throw IllegalStateException("Vidsrc player iframe not found")

            // data-api can be a JSON endpoint (returns {"src":"..."}) or a direct iframe path
            var iframeUrl = when {
                iframePath.startsWith("//") -> "https:$iframePath"
                iframePath.startsWith("http") -> iframePath
                else -> resolveUrl(server.url, iframePath)
            }

            // If the path looks like an API endpoint (e.g. /vs_src.php), fetch the JSON response
            if (iframeUrl.contains("vs_src.php") || iframeUrl.contains("data-api")) {
                val apiResp = httpGet(iframeUrl, refererHeaders(server.url))
                val srcJson = Regex(""""src"\s*:\s*"([^"]+)"""").find(apiResp)?.groupValues?.get(1)
                if (srcJson != null) {
                    iframeUrl = if (srcJson.startsWith("http")) srcJson else resolveUrl(iframeUrl, srcJson)
                }
            }

            val iframePage = httpGet(iframeUrl, refererHeaders(server.url))
            val playerPath = Regex("""src:\s*['"](/prorcp/[^'"]+)['"]""")
                .find(iframePage)?.groupValues?.get(1)
                ?: throw IllegalStateException("Vidsrc player source not found")
            val playerUrl = iframeUrl.substringBefore("/rcp") + playerPath
            val playerPage = httpGet(playerUrl, refererHeaders(iframeUrl))

            val playerId = Regex("""Playerjs.*?file:\s*([a-zA-Z0-9]+?)\s*,""", RegexOption.DOT_MATCHES_ALL)
                .find(playerPage)?.groupValues?.get(1).orEmpty()
            val decrypted = if (playerId.isNotBlank()) {
                val encrypted = Regex(
                    """<div id=["']$playerId["'][^>]*>\s*(.*?)\s*</div>""",
                    setOf(RegexOption.DOT_MATCHES_ALL, RegexOption.IGNORE_CASE),
                ).find(playerPage)?.groupValues?.get(1)
                    ?: throw IllegalStateException("Vidsrc encrypted source not found")
                decryptVidsrc(playerId, encrypted)
            } else {
                Regex(
                    """Playerjs.*?file:\s*["']([^"']+)["']\s*,""",
                    RegexOption.DOT_MATCHES_ALL,
                ).find(playerPage)?.groupValues?.get(1)
            }

            val streamUrl = decrypted?.substringBefore(" or ")
                ?.replace(Regex("""\{[a-z]\d+\}"""), "quibblezoomfable.com")
                ?.replace("&amp;", "&")
                ?.takeIf { it.isNotBlank() }
                ?: throw IllegalStateException("Vidsrc returned no stream")

            val subtitleRegex = Regex(
                """default_subtitles\s*=\s*["']([^"']+)["']""",
                RegexOption.DOT_MATCHES_ALL,
            )
            val subtitlesRaw = subtitleRegex.find(playerPage)?.groupValues?.get(1).orEmpty()
            val subtitleBase = URI(iframeUrl)
            val subtitleOrigin = "${subtitleBase.scheme}://${subtitleBase.host}"
            val subtitles = if (subtitlesRaw.isNotBlank()) {
                subtitlesRaw.split(",").mapNotNull { item ->
                    val language = item.substringAfter("[").substringBefore("]")
                    val subPath = item.substringAfter("]")
                    if (!subPath.startsWith("/")) return@mapNotNull null
                    SubtitleOption(language, "$subtitleOrigin$subPath", source = "Vidsrc")
                }
            } else emptyList()

            return ExtractionResult.Final(
                StreamResult(streamUrl, name, mediaType(streamUrl), refererHeaders(iframeUrl), subtitles = subtitles),
            )
        }

        private fun decryptVidsrc(id: String, encrypted: String): String = when (id) {
            "NdonQLf1Tzyx7bMG" -> encrypted.chunked(3).reversed().joinToString("")
            "sXnL9MQIry" -> {
                val key = "pWB9V)[*4I`nJpp?ozyB~dbr9yt!_n4u"
                val decoded = encrypted.chunked(2).joinToString("") { it.toInt(16).toChar().toString() }
                val shifted = decoded.mapIndexed { index, character ->
                    ((character.code xor key[index % key.length].code) - 3).toChar()
                }.joinToString("")
                String(Base64.decode(shifted, Base64.DEFAULT), Charsets.UTF_8)
            }
            "IhWrImMIGL" -> {
                val rotated = rot13(encrypted.reversed()).reversed()
                String(Base64.decode(rotated, Base64.DEFAULT), Charsets.UTF_8)
            }
            "xTyBxQyGTA" -> String(
                Base64.decode(encrypted.reversed().filterIndexed { index, _ -> index % 2 == 0 }, Base64.DEFAULT),
                Charsets.UTF_8,
            )
            "ux8qjPHC66" -> {
                val key = "X9a(O;FMV2-7VO5x;Ao\u0005:dN1NoFs?j,"
                encrypted.reversed().chunked(2).mapIndexed { index, value ->
                    (value.toInt(16) xor key[index % key.length].code).toChar()
                }.joinToString("")
            }
            "eSfH1IRMyL" -> encrypted.reversed()
                .map { (it.code - 1).toChar() }
                .joinToString("")
                .chunked(2)
                .joinToString("") { it.toInt(16).toChar().toString() }
            "KJHidj7det" -> {
                val trimmed = encrypted.substring(10, encrypted.length - 16)
                val key = "3SAY~#%Y(V%>5d/Yg\"\$G[Lh1rK4a;7ok"
                val decoded = String(Base64.decode(trimmed, Base64.DEFAULT), Charsets.UTF_8)
                decoded.mapIndexed { index, character ->
                    (character.code xor key[index % key.length].code).toChar()
                }.joinToString("")
            }
            "o2VSUnjnZl" -> encrypted.map { character ->
                when (character) {
                    in 'a'..'z' -> if (character - 3 < 'a') character + 23 else character - 3
                    in 'A'..'Z' -> if (character - 3 < 'A') character + 23 else character - 3
                    else -> character
                }
            }.joinToString("")
            "Oi3v1dAlaM", "TsA2KGDGux", "JoAHUMCLXV" -> {
                val shift = when (id) {
                    "Oi3v1dAlaM" -> 5
                    "TsA2KGDGux" -> 7
                    else -> 3
                }
                val normalized = encrypted.reversed().replace('-', '+').replace('_', '/')
                String(Base64.decode(normalized, Base64.DEFAULT), Charsets.UTF_8)
                    .map { (it.code - shift).toChar() }.joinToString("")
            }
            else -> throw IllegalStateException("Unsupported Vidsrc encryption: $id")
        }
    }

    private inner class VidrockExtractor : HostExtractor {
        override val name = "Vidrock"
        override fun supports(server: StreamServer) = host(server.url).endsWith("vidrock.net")

        override suspend fun extract(server: StreamServer): ExtractionResult {
            val apiUrl = server.url.substringBefore('#')
            val selectedName = server.url.substringAfter('#', "")
            val json = getJson(apiUrl, refererHeaders("https://vidrock.net/"))
            val headers = refererHeaders("https://vidrock.net/") + mapOf("Origin" to "https://vidrock.net")

            val candidates = if (selectedName.isNotBlank()) {
                val item = json.optJSONObject(selectedName)
                if (item != null) listOf(item) else emptyList()
            } else {
                json.keys().asSequence()
                    .mapNotNull { name -> json.optJSONObject(name)?.let { name to it } }
                    .filter { it.second.optString("url").isNotBlank() }
                    .map { it.second }
                    .toList()
            }

            for (item in candidates) {
                var url = item.optString("url")
                if (url.isBlank()) continue

                val serverName = item.toString().substringBefore("://").ifBlank { server.name }
                if (selectedName.isBlank()) {
                    for (key in json.keys()) {
                        if (json.optJSONObject(key) === item) {
                            val candidateName = "$name $key"
                            try {
                                val stream = resolveVidrockUrl(url, candidateName, headers)
                                if (stream != null) return ExtractionResult.Final(stream)
                            } catch (e: Exception) {
                                if (e is CancellationException) throw e
                            }
                            break
                        }
                    }
                } else {
                    try {
                        val stream = resolveVidrockUrl(url, "$name $selectedName", headers)
                        if (stream != null) return ExtractionResult.Final(stream)
                    } catch (e: Exception) {
                        if (e is CancellationException) throw e
                    }
                }
            }

            throw IllegalStateException("Vidrock returned no playable source")
        }

        private suspend fun resolveVidrockUrl(url: String, label: String, headers: Map<String, String>): StreamResult? {
            var resolvedUrl = url
            if (label.contains("Atlas", ignoreCase = true)) {
                val qualities = getJsonArray(resolvedUrl, headers)
                val highest = (0 until qualities.length())
                    .mapNotNull { qualities.optJSONObject(it) }
                    .maxByOrNull { it.optInt("resolution") }
                if (highest != null) resolvedUrl = highest.optString("url", resolvedUrl)
            }
            if (resolvedUrl.isBlank()) return null
            return StreamResult(resolvedUrl, label, mediaType(resolvedUrl), headers)
        }
    }

    private inner class VidzeeExtractor : HostExtractor {
        override val name = "Vidzee"
        private val player = "https://player.vidzee.wtf"
        private val staticPass = "4f2a9c7d1e8b3a6f0d5c2e9a7b1f4d8c"

        override fun supports(server: StreamServer) = host(server.url).endsWith("vidzee.wtf")

        override suspend fun extract(server: StreamServer): ExtractionResult {
            val masterKey = getVidzeeMasterKey()
            val response = getJson(
                server.url,
                refererHeaders("$player/") + mapOf("Origin" to player),
            )
            val headers = refererHeaders(player) + mapOf("Origin" to player)
            val links = response.optJSONArray("url") ?: throw IllegalStateException("Vidzee returned no links")
            for (index in 0 until links.length()) {
                val encrypted = links.optJSONObject(index)?.optString("link").orEmpty()
                if (encrypted.isBlank()) continue
                try {
                    val url = decryptVidzeeLink(encrypted, masterKey)
                    val stream = StreamResult(url, server.name, mediaType(url), headers)
                    return ExtractionResult.Final(validateStream(stream))
                } catch (error: Throwable) {
                    if (error is CancellationException) throw error
                    Log.w(tag, "Vidzee route $index failed: ${error.message}")
                }
            }
            throw IllegalStateException("Vidzee returned no playable link")
        }

        private fun getVidzeeMasterKey(): String {
            val encoded = httpGet("https://core.vidzee.wtf/api-key", refererHeaders("$player/"))
            val data = Base64.decode(encoded.trim(), Base64.DEFAULT)
            require(data.size > 28) { "Invalid Vidzee key payload" }
            val iv = data.copyOfRange(0, 12)
            val authTag = data.copyOfRange(12, 28)
            val ciphertext = data.copyOfRange(28, data.size)
            val key = MessageDigest.getInstance("SHA-256").digest(staticPass.toByteArray())
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, iv))
            return String(cipher.doFinal(ciphertext + authTag), Charsets.UTF_8)
        }

        private fun decryptVidzeeLink(encoded: String, masterKey: String): String {
            val decoded = String(Base64.decode(encoded, Base64.DEFAULT), Charsets.UTF_8)
            val parts = decoded.split(':', limit = 2)
            require(parts.size == 2) { "Invalid Vidzee link payload" }
            val iv = Base64.decode(parts[0], Base64.DEFAULT)
            val ciphertext = Base64.decode(parts[1], Base64.DEFAULT)
            val sourceKey = masterKey.toByteArray()
            val key = ByteArray(32) { index -> sourceKey.getOrElse(index) { 0 } }
            val cipher = Cipher.getInstance("AES/CBC/PKCS5Padding")
            cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), IvParameterSpec(iv))
            return String(cipher.doFinal(ciphertext), Charsets.UTF_8)
        }
    }

    private inner class VideasyExtractor : HostExtractor {
        override val name = "Videasy"
        override fun supports(server: StreamServer): Boolean {
            val domain = host(server.url)
            return domain.endsWith("videasy.to") || domain.endsWith("videasy.net") || domain.endsWith("videasy.io")
        }

        override suspend fun extract(server: StreamServer): ExtractionResult {
            val segments = URI(server.url).path.split('/').filter(String::isNotBlank)
            val mediaType = segments.firstOrNull().orEmpty()
            val mediaId = segments.getOrNull(1).orEmpty()
            require(mediaType == "movie" || mediaType == "tv") { "Unsupported Videasy URL" }
            require(mediaId.isNotBlank()) { "Videasy media ID not found" }
            val seed = getJson(
                "https://api.speedracelight.com/seed?mediaId=${encode(mediaId)}",
                videasyHeaders(),
            ).optString("seed").ifBlank { throw IllegalStateException("Videasy seed not found") }
            val parameters = buildString {
                append("mediaType=").append(mediaType)
                append("&tmdbId=").append(encode(mediaId))
                if (mediaType == "tv") {
                    append("&seasonId=").append(segments.getOrNull(2) ?: "1")
                    append("&episodeId=").append(segments.getOrNull(3) ?: "1")
                }
                append("&enc=2&seed=").append(encode(seed))
            }
            var lastError: Throwable? = null
            for (path in listOf("cdn", "m4uhd", "lamovie")) {
                try {
                    val encrypted = httpGet(
                        "https://api.speedracelight.com/$path/sources-with-title?$parameters",
                        videasyHeaders(),
                    )
                    val data = JSONObject(decryptVideasyPayload(encrypted, seed, mediaId))
                    val sources = data.optJSONArray("sources")
                    require(sources != null && sources.length() > 0) { "Videasy returned no sources" }
                    val qualities = (0 until sources.length()).mapNotNull { index ->
                        val item = sources.optJSONObject(index) ?: return@mapNotNull null
                        val url = item.optString("url").ifBlank { return@mapNotNull null }
                        val label = item.optString("quality", "Auto")
                        val height = Regex("""\d{3,4}""").find(label)?.value?.toIntOrNull() ?: 0
                        QualityOption(label, url, height)
                    }.sortedByDescending(QualityOption::height)
                    require(qualities.isNotEmpty()) { "Videasy returned no playable sources" }
                    val playlist = data.optString("playlist").ifBlank { qualities.first().url }
                    val subtitles = data.optJSONArray("subtitles")?.let { items ->
                        (0 until items.length()).mapNotNull { index ->
                            val item = items.optJSONObject(index) ?: return@mapNotNull null
                            val url = item.optString("url").ifBlank { return@mapNotNull null }
                            SubtitleOption(
                                item.optString("language").ifBlank { item.optString("lang", "Subtitle") },
                                url,
                                source = name,
                            )
                        }
                    }.orEmpty()
                    return ExtractionResult.Final(
                        StreamResult(
                            playlist,
                            name,
                            if (playlist.contains(".mpd", true)) "dash" else "direct_m3u8",
                            videasyHeaders(),
                            qualities = qualities,
                            subtitles = subtitles,
                        ),
                    )
                } catch (error: Throwable) {
                    if (error is CancellationException) throw error
                    lastError = error
                    Log.w(tag, "Videasy $path failed: ${error.message}")
                }
            }
            throw lastError ?: IllegalStateException("Videasy returned no playable source")
        }

        private fun videasyHeaders() = refererHeaders("https://player.videasy.to/") +
            mapOf("Accept" to "application/json")

        private fun decryptVideasyPayload(encoded: String, seed: String, mediaId: String): String {
            val bytes = Base64.decode(encoded.trim(), Base64.URL_SAFE or Base64.NO_WRAP)
            val key = videasyKeyStream(seed, mediaId.toLong().toInt(), bytes.size)
            bytes.indices.forEach { index -> bytes[index] = bytes[index] xor key[index] }
            require(bytes.size >= 4 && bytes.copyOfRange(0, 4).contentEquals("mvm1".toByteArray())) {
                "Videasy response could not be decrypted"
            }
            return String(bytes, 4, bytes.size - 4, Charsets.UTF_8)
        }

        private fun videasyKeyStream(seed: String, mediaId: Int, length: Int): ByteArray {
            val table = arrayOfNulls<Int>(61)
            val golden = -1640531527
            var state = videasyMix(videasyFnv(seed) xor videasyMix(mediaId xor golden))
            repeat(8) { round ->
                val index = (state.toUInt() % 61u).toInt()
                state = Integer.rotateLeft(state + golden, 7 + (7 and round))
                table[index] = state xor videasyMix(state)
                state = videasyMix(state + index)
            }
            var accumulator = videasyMix(-1515870811 xor state)
            val output = ByteArray(length)
            var position = 0
            var counter = 0
            while (position < length) {
                val index = (accumulator.toUInt() % 61u).toInt()
                val mask = if (table[index] != null) -1 else 0
                val value = table[index] ?: 0
                val mixed = value xor (golden * (counter + 1))
                var next = (accumulator xor mixed) or (accumulator and mixed and mask)
                next = Integer.rotateLeft(next + accumulator, index and 31) xor
                    Integer.rotateLeft(accumulator, (index * 7) and 31)
                accumulator = videasyMix(next + golden)
                table[index] = accumulator
                for (shift in 0..24 step 8) {
                    if (position < length) output[position++] = (accumulator ushr shift).toByte()
                }
                counter++
            }
            return output
        }

        private fun videasyFnv(value: String): Int {
            var hash = -2128831035
            value.forEach { hash = (hash xor it.code) * 16777619 }
            return videasyMix(hash)
        }

        private fun videasyMix(input: Int): Int {
            var value = input
            value = value xor (value ushr 16)
            value *= -2048144789
            value = value xor (value ushr 13)
            value *= -1028477387
            return value xor (value ushr 16)
        }
    }

    private inner class PrimeSrcExtractor : HostExtractor {
        override val name = "PrimeSrc"
        override fun supports(server: StreamServer) = host(server.url).endsWith("primesrc.me")

        override suspend fun extract(server: StreamServer): ExtractionResult {
            val headers = server.headers + mapOf(
                "Accept" to "application/json, text/plain, */*",
                "Origin" to "https://primesrc.me",
                "X-Requested-With" to "XMLHttpRequest",
            )
            val link = getJson(server.url, headers).optString("link")
            require(link.isNotBlank()) { "PrimeSrc returned no host link" }
            return ExtractionResult.Redirect(StreamServer(server.name.substringBefore(" ("), link))
        }
    }

    private inner class FrembedExtractor : HostExtractor {
        override val name = "Frembed"
        override fun supports(server: StreamServer) = host(server.url).endsWith("frembed.click")

        override suspend fun extract(server: StreamServer): ExtractionResult {
            requireSafeOutboundUrl(server.url)
            val response = noRedirectClient.newCall(
                Request.Builder().url(server.url)
                    .header("User-Agent", userAgent)
                    .header("Referer", "https://frembed.click/")
                    .build()
            ).execute()

            val location = response.header("Location").orEmpty()
            response.close()

            if (location.isNotBlank()) {
                val resolved = resolveUrl(server.url, location)
                requireSafeOutboundUrl(resolved)
                Log.d(tag, "Frembed supplied an outbound redirect")
                return ExtractionResult.Redirect(
                    StreamServer(server.name, resolved, refererHeaders("https://frembed.click/")),
                )
            }

            val pageHtml = httpGet(server.url, refererHeaders("https://frembed.click/"))
            val mediaUrl = Regex(
                """https?://[^\s"'<>]+\.(?:m3u8|mp4)(?:[^\s"'<>]*)?""",
                RegexOption.IGNORE_CASE,
            ).find(pageHtml)?.value
                ?.replace("\\/", "/")?.replace("&amp;", "&")
                ?: throw IllegalStateException("Frembed returned no media URL")

            return ExtractionResult.Final(
                StreamResult(mediaUrl, name, mediaType(mediaUrl), refererHeaders("https://frembed.click/")),
            )
        }
    }

    private inner class VidsrcRuExtractor : HostExtractor {
        override val name = "VidsrcRu"
        override val usesWebView = true
        override fun supports(server: StreamServer) = host(server.url).endsWith("vidsrc.ru")

        override suspend fun extract(server: StreamServer): ExtractionResult {
            return withContext(Dispatchers.Main) {
                withTimeout(30_000) {
                    suspendCancellableCoroutine { continuation ->
                        val webView = WebView(context)
                        webView.settings.javaScriptEnabled = true
                        webView.settings.loadsImagesAutomatically = false
                        webView.settings.blockNetworkImage = true
                        webView.settings.cacheMode = android.webkit.WebSettings.LOAD_NO_CACHE
                        webView.settings.domStorageEnabled = true
                        webView.settings.userAgentString =
                            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

                        webView.webViewClient = object : WebViewClient() {
                            override fun shouldInterceptRequest(
                                view: WebView?,
                                request: WebResourceRequest?,
                            ): WebResourceResponse? {
                                val url = request?.url?.toString() ?: ""
                                if (url.contains(".m3u8") && !url.contains("analytics") && !url.contains("cloudflare")) {
                                    if (continuation.isActive) {
                                        webView.post {
                                            webView.stopLoading()
                                            webView.destroy()
                                        }
                                        continuation.resume(
                                            ExtractionResult.Final(
                                                StreamResult(url, name, "direct_m3u8", refererHeaders(server.url)),
                                            ),
                                        )
                                    }
                                }
                                return super.shouldInterceptRequest(view, request)
                            }
                        }
                        webView.loadUrl(server.url)
                        continuation.invokeOnCancellation {
                            webView.post {
                                webView.stopLoading()
                                webView.destroy()
                            }
                        }
                    }
                }
            }
        }
    }

    private inner class VidsrcToExtractor : HostExtractor {
        override val name = "VidsrcTo"
        override fun supports(server: StreamServer) = host(server.url).endsWith("vidsrc.to")

        override suspend fun extract(server: StreamServer): ExtractionResult {
            val html = httpGet(server.url)
            val mediaId = Regex("""data-id=["']([^"']+)["']""")
                .find(html)?.groupValues?.get(1)
                ?: throw IllegalStateException("VidsrcTo media ID not found")

            val keysUrl = "https://raw.githubusercontent.com/Ciarands/vidsrc-keys/main/keys.json"
            val keysJson = getJson(keysUrl)
            val decryptKey = keysJson.getJSONArray("decrypt").getString(0)

            val sourcesUrl = "https://vidsrc.to/ajax/embed/episode/$mediaId/sources"
            val sourcesJson = getJson(sourcesUrl)
            val sources = sourcesJson.optJSONArray("result")
                ?: throw IllegalStateException("VidsrcTo no sources")

            for (i in 0 until sources.length()) {
                val source = sources.optJSONObject(i) ?: continue
                val sourceId = source.optString("id")
                if (sourceId.isBlank()) continue

                val embedUrl = "https://vidsrc.to/ajax/embed/source/$sourceId"
                val embedJson = getJson(embedUrl)
                val encUrl = embedJson.optJSONObject("result")?.optString("url").orEmpty()
                if (encUrl.isBlank()) continue

                val decryptedUrl = decryptRc4(decryptKey, encUrl)
                if (decryptedUrl.isNotBlank() && decryptedUrl != encUrl) {
                    return ExtractionResult.Redirect(
                        StreamServer(name, decryptedUrl, server.headers),
                    )
                }
            }
            throw IllegalStateException("VidsrcTo returned no playable source")
        }

        private fun decryptRc4(key: String, encUrl: String): String {
            val keyBytes = key.toByteArray(Charsets.UTF_8)
            val s = IntArray(256) { it }
            var j = 0
            for (i in 0 until 256) {
                j = (j + s[i] + keyBytes[i % keyBytes.size].toInt()) and 0xff
                s[i] = s[j].also { s[j] = s[i] }
            }
            var data = Base64.decode(encUrl, Base64.URL_SAFE)
            val result = ByteArray(data.size)
            var ci = 0; var ck = 0
            for (index in data.indices) {
                ci = (ci + 1) and 0xff
                ck = (ck + s[ci]) and 0xff
                s[ci] = s[ck].also { s[ck] = s[ci] }
                val t = (s[ci] + s[ck]) and 0xff
                result[index] = (data[index].toInt() xor s[t]).toByte()
            }
            return java.net.URLDecoder.decode(String(result, Charsets.UTF_8), "utf-8")
        }
    }

    private inner class VoeExtractor : HostExtractor {
        override val name = "VOE"
        private val aliases = setOf(
            "voe.sx", "jilliandescribecompany.com", "mikaylaarealike.com",
            "christopheruntilpoint.com", "walterprettytheir.com", "crystaltreatmenteast.com",
            "lauradaydo.com", "lancewhosedifficult.com", "dianaavoidthey.com",
            "jefferycontrolmodel.com", "charlestoughrace.com", "richardquestionbuilding.com",
            "jessicayeahcatch.com", "juliewomanwish.com",
        )

        override fun supports(server: StreamServer) = host(server.url) in aliases || server.name.contains("voe", true)

        override suspend fun extract(server: StreamServer): ExtractionResult {
            val html = httpGet(server.url, refererHeaders(server.url))
            val encoded = Pattern.compile(
                """<script\s+type=["']application/json["']>(.*?)</script>""",
                Pattern.DOTALL or Pattern.CASE_INSENSITIVE,
            ).matcher(html).let { if (it.find()) it.group(1)?.trim() else null }
                ?: throw IllegalStateException("VOE payload not found")
            val json = decryptVoe(encoded)
            val url = json.optString("source")
            require(url.isNotBlank()) { "VOE returned no source" }
            return ExtractionResult.Final(StreamResult(url, name, mediaType(url), refererHeaders(server.url)))
        }
    }

    private inner class StreamtapeExtractor : HostExtractor {
        override val name = "Streamtape"
        override fun supports(server: StreamServer): Boolean {
            val domain = host(server.url)
            return domain.endsWith("streamtape.com") || domain.endsWith("streamta.site") ||
                server.name.contains("streamtape", true)
        }

        override suspend fun extract(server: StreamServer): ExtractionResult {
            val html = httpGet(server.url)
            val matcher = Pattern.compile(
                """document\.getElementById\('botlink'\)\.innerHTML\s*=\s*'([^']+)'\s*\+\s*\('([^']+)'\)\.substring\((\d+)\)""",
            ).matcher(html)
            require(matcher.find()) { "Streamtape botlink not found" }
            val prefix = matcher.group(1).orEmpty()
            val value = matcher.group(2).orEmpty()
            val start = matcher.group(3).orEmpty().toInt()
            val videoUrl = if (prefix.startsWith("http")) prefix + value.substring(start)
                else "https://streamtape.com${prefix + value.substring(start)}"
            val finalUrl = followRedirect(videoUrl)
            return ExtractionResult.Final(
                StreamResult(finalUrl, name, "direct_video", refererHeaders("https://streamtape.com/")),
            )
        }
    }

    private inner class TwoEmbedExtractor : HostExtractor {
        override val name = "2Embed"
        override fun supports(server: StreamServer) = host(server.url).contains("2embed")

        override suspend fun extract(server: StreamServer): ExtractionResult {
            val html = httpGet(server.url)
            // Prefer data-src (lazy-loaded actual embed) over plain src (self-referencing)
            val iframeSrc = Regex("""<iframe[^>]+data-src=["']([^"']+)["']""", RegexOption.IGNORE_CASE)
                .find(html)?.groupValues?.get(1)
                ?: Regex("""<iframe[^>]+src=["']([^"']+)["']""", RegexOption.IGNORE_CASE)
                    .find(html)?.groupValues?.get(1)
                ?: throw IllegalStateException("2Embed iframe not found")
            val iframeUrl = resolveUrl(server.url, iframeSrc)

            // streamsrcs.2embed.cc pages embed 2vcdn.skin via swish.js or vnest.js
            if (iframeUrl.contains("streamsrcs.2embed.cc")) {
                val swishHtml = httpGet(iframeUrl, refererHeaders(server.url))
                // The swish/vnest page has <iframe id="framesrc" src="{videoId}">
                // swish.js rewrites this to https://2vcdn.skin/e/{videoId}
                // vnest.js rewrites this to https://cineby.hair/movie/{tmdbId} (dead)
                val framesrcId = Regex(
                    """<iframe[^>]*id=["']framesrc["'][^>]*src=["']([^"']+)["']""",
                    RegexOption.IGNORE_CASE,
                ).find(swishHtml)?.groupValues?.get(1)?.trim()
                    ?: Regex(
                        """<iframe[^>]*src=["']([^"']+)["'][^>]*id=["']framesrc["']""",
                        RegexOption.IGNORE_CASE,
                    ).find(swishHtml)?.groupValues?.get(1)?.trim()
                    ?: throw IllegalStateException("2Embed framesrc iframe not found")

                // If framesrc looks like a numeric/alphanumeric video ID (not a URL), use 2vcdn
                if (framesrcId.matches(Regex("^[a-zA-Z0-9_-]+$"))) {
                    val v2cdnUrl = "https://2vcdn.skin/e/$framesrcId"
                    val v2cdnHtml = httpGet(v2cdnUrl, mapOf("Referer" to "https://streamsrcs.2embed.cc/"))
                    val decoded = unpackObfuscatedJs(v2cdnHtml)
                        ?: throw IllegalStateException("2Embed failed to decode packed JS")
                    val m3u8 = Regex("""(?:https?://[^\s"'<>]+|/[^\s"'<>]+)\.m3u8[^\s"'<>]*""")
                        .find(decoded)?.value?.replace("\\/", "/")?.replace("&amp;", "&")
                        ?: throw IllegalStateException("2Embed no m3u8 URL in decoded JS")
                    val absolute = if (m3u8.startsWith("http")) m3u8 else "https://2vcdn.skin$m3u8"
                    return ExtractionResult.Final(
                        StreamResult(absolute, server.name, "application/vnd.apple.mpegurl", refererHeaders("https://2vcdn.skin/"))
                    )
                }

                // framesrc is a URL (movie path via cineby/vidnest) - try as redirect
                return ExtractionResult.Redirect(StreamServer("2Embed host", framesrcId, refererHeaders(iframeUrl)))
            }

            return ExtractionResult.Redirect(StreamServer("2Embed host", iframeUrl, refererHeaders(server.url)))
        }
    }

    private inner class VidemExtractor : HostExtractor {
        override val name = "Videm"
        override fun supports(server: StreamServer) = host(server.url).endsWith("videm.xyz")

        override suspend fun extract(server: StreamServer): ExtractionResult {
            val html = httpGet(server.url, server.headers)
            val configText = Regex(
                """var\s+Q\s*=\s*(\{[\s\S]*?});""",
            ).find(html)?.groupValues?.get(1)
                ?: throw IllegalStateException("Videm player configuration not found")
            val config = JSONObject(configText)
            val token = config.optString("t").ifBlank {
                throw IllegalStateException("Videm player token not found")
            }
            val sourceUrl = "https://videm.xyz/api.php?a=sources" +
                "&type=${encode(config.optString("type"))}" +
                "&id=${encode(config.optString("id"))}" +
                "&s=${config.optInt("s")}&e=${config.optInt("e")}" +
                "&t=${encode(token)}"
            val headers = refererHeaders(server.url)
            val sources = getJson(sourceUrl, headers).optJSONArray("servers")
            require(sources != null && sources.length() > 0) { "Videm returned no servers" }
            val reference = sources.optJSONObject(0)?.optString("ref").orEmpty()
            require(reference.isNotBlank()) { "Videm server reference not found" }
            val stream = getJson(
                "https://videm.xyz/api.php?a=play&ref=${encode(reference)}&t=${encode(token)}",
                headers,
            )
            val streamUrl = stream.optString("url").ifBlank {
                throw IllegalStateException("Videm returned no stream URL")
            }
            val absolute = resolveUrl("https://videm.xyz/", streamUrl)
            return ExtractionResult.Final(
                StreamResult(absolute, "2Embed", "direct_m3u8", headers),
            )
        }
    }

    private inner class SeapiLinkExtractor : HostExtractor {
        override val name = "SeapiLink"
        override fun supports(server: StreamServer) = host(server.url).contains("seapi.link")

        override suspend fun extract(server: StreamServer): ExtractionResult {
            val json = getJson(server.url, refererHeaders("https://multiembed.mov"))
            val results = json.optJSONArray("result") ?: json.optJSONArray("results")
            require(results != null && results.length() > 0) { "SeapiLink returned no results" }
            val first = results.getJSONObject(0)
            val streamUrl = first.optString("url").ifBlank {
                first.optString("stream").ifBlank {
                    first.optString("link").ifBlank {
                        first.optString("video_url")
                    }
                }
            }
            require(streamUrl.isNotBlank()) { "SeapiLink result has no URL" }
            return ExtractionResult.Final(
                StreamResult(streamUrl, name, mediaType(streamUrl), refererHeaders("https://multiembed.mov")),
            )
        }
    }

    private inner class VidNestExtractor : HostExtractor {
        override val name = "VidNest"
        override fun supports(server: StreamServer) = host(server.url).contains("vidnest.fun")

        override suspend fun extract(server: StreamServer): ExtractionResult {
            val pathParts = server.url.removeSuffix("/").split("/")
            val tmdbId = pathParts.getOrNull(pathParts.size - 3) ?: ""
            val season = pathParts.getOrNull(pathParts.size - 2) ?: ""
            val episode = pathParts.getOrNull(pathParts.size - 1) ?: ""
            if (tmdbId.isBlank() || season.isBlank() || episode.isBlank()) {
                throw IllegalStateException("VidNest: cannot parse tmdbId/season/episode from ${server.url}")
            }

            val isMovie = server.url.contains("/movie/")
            val servers = listOf("alfa", "zeta", "filxer", "catflix", "lamda", "gama", "beta", "sigma")
            val pathType = if (isMovie) "movie" else "tv"

            for (s in servers) {
                try {
                    val apiUrl = "https://new.vidnest.fun/$s/$pathType/$tmdbId/$season/$episode"
                    val resp = getJson(apiUrl)
                    if (!resp.optBoolean("encrypted", false)) continue
                    val encData = resp.optString("data", "")
                    if (encData.isBlank()) continue

                    val decrypted = decryptVidNestResponse(encData)
                    val json = JSONObject(decrypted)
                    val url = json.optString("url", "")
                    if (url.isBlank()) continue

                    val headers = mutableMapOf("Referer" to server.url)
                    json.optJSONObject("headers")?.let { h ->
                        val keys = h.keys()
                        while (keys.hasNext()) {
                            val key = keys.next()
                            headers[key] = h.optString(key, "")
                        }
                    }

                    val streams = mutableListOf(StreamResult(url, server.name, "application/vnd.apple.mpegurl", headers))
                    if (json.has("all_urls")) {
                        val allUrls = json.getJSONArray("all_urls")
                        for (i in 0 until allUrls.length()) {
                            val u = allUrls.optString(i, "")
                            if (u.isNotBlank() && u != url) {
                                streams.add(StreamResult(u, "${server.name} ${i + 1}", "application/vnd.apple.mpegurl", headers))
                            }
                        }
                    }

                    return ExtractionResult.Final(streams.first())
                } catch (e: Exception) {
                    if (e is CancellationException) throw e
                }
            }
            throw IllegalStateException("VidNest: all servers failed for $tmdbId")
        }
    }

    private inner class VidLoveExtractor : HostExtractor {
        override val name = "VidLove"
        override val usesWebView = true
        override fun supports(server: StreamServer) = host(server.url).contains("vidlove.cc")

        override suspend fun extract(server: StreamServer): ExtractionResult {
            return withContext(Dispatchers.Main) {
                withTimeout(30_000) {
                    suspendCancellableCoroutine { continuation ->
                        val webView = WebView(context)
                        webView.settings.javaScriptEnabled = true
                        webView.settings.loadsImagesAutomatically = false
                        webView.settings.blockNetworkImage = true
                        webView.settings.cacheMode = android.webkit.WebSettings.LOAD_NO_CACHE
                        webView.settings.domStorageEnabled = true

                        webView.webViewClient = object : WebViewClient() {
                            override fun shouldInterceptRequest(
                                view: WebView?,
                                request: WebResourceRequest?,
                            ): WebResourceResponse? {
                                val url = request?.url?.toString() ?: ""
                                if (url.endsWith(".m3u8") && !url.contains("master")) {
                                    if (continuation.isActive) {
                                        continuation.resume(
                                            ExtractionResult.Final(
                                                StreamResult(url, name, "direct_m3u8", refererHeaders(server.url)),
                                            ),
                                        )
                                    }
                                }
                                return super.shouldInterceptRequest(view, request)
                            }
                        }
                        webView.loadUrl(server.url)
                        continuation.invokeOnCancellation {
                            webView.post {
                                webView.stopLoading()
                                webView.destroy()
                            }
                        }
                    }
                }
            }
        }
    }

    private inner class AutoEmbedExtractor : HostExtractor {
        override val name = "AutoEmbed"
        override fun supports(server: StreamServer) = host(server.url).contains("autoembed")

        override suspend fun extract(server: StreamServer): ExtractionResult {
            val html = httpGet(server.url)
            val iframe = Regex("""<iframe[^>]+src=["']([^"']+)["']""", RegexOption.IGNORE_CASE)
                .find(html)?.groupValues?.get(1)
                ?: throw IllegalStateException("AutoEmbed iframe not found")
            val absolute = resolveUrl(server.url, iframe)
            return ExtractionResult.Redirect(StreamServer("AutoEmbed host", absolute, refererHeaders(server.url)))
        }
    }

    private inner class MultiEmbedExtractor : HostExtractor {
        override val name = "MultiEmbed"
        override fun supports(server: StreamServer) = host(server.url).contains("multiembed.mov")

        override suspend fun extract(server: StreamServer): ExtractionResult {
            val html = httpGet(server.url)
            val iframe = Regex("""<iframe[^>]+src=["']([^"']+)["']""", RegexOption.IGNORE_CASE)
                .find(html)?.groupValues?.get(1)
                ?: throw IllegalStateException("MultiEmbed iframe not found")
            val absolute = resolveUrl(server.url, iframe)
            return ExtractionResult.Redirect(StreamServer("MultiEmbed host", absolute, refererHeaders(server.url)))
        }
    }

    private inner class EmbedSuExtractor : HostExtractor {
        override val name = "EmbedSu"
        override fun supports(server: StreamServer) = host(server.url).contains("embed.su")

        override suspend fun extract(server: StreamServer): ExtractionResult {
            val html = httpGet(server.url)
            val iframe = Regex("""<iframe[^>]+src=["']([^"']+)["']""", RegexOption.IGNORE_CASE)
                .find(html)?.groupValues?.get(1)
                ?: throw IllegalStateException("Embed.su iframe not found")
            val absolute = resolveUrl(server.url, iframe)
            return ExtractionResult.Redirect(StreamServer("EmbedSu host", absolute, refererHeaders(server.url)))
        }
    }

    private inner class VidFastExtractor : HostExtractor {
        override val name = "VidFast"
        override fun supports(server: StreamServer): Boolean {
            val domain = host(server.url)
            return domain.endsWith("vidfast.vc") || domain.endsWith("vidfast.pro") ||
                domain.endsWith("vidfast.io") || domain.endsWith("vidfast.xyz")
        }

        override suspend fun extract(server: StreamServer): ExtractionResult {
            val html = httpGet(server.url)
            val pageToken = Regex("""\\"(?:en|token)\\":\\"([^"\\]+)\\"""")
                .find(html)?.groupValues?.get(1)
                ?: Regex(""""(?:en|token)":"([^"\\]{20,})"""")
                    .find(html)?.groupValues?.get(1)
                ?: throw IllegalStateException("VidFast page token not found")
            val handshake = getJson(
                "https://enc-dec.app/api/enc-vidfast?text=${encode(pageToken)}",
            )
            require(handshake.optInt("status") == 200) { "VidFast handshake failed" }
            val boot = handshake.optJSONObject("result")
                ?: throw IllegalStateException("VidFast handshake was incomplete")
            val serversUrl = boot.optString("servers")
            val streamBase = boot.optString("stream")
            require(serversUrl.isNotBlank() && streamBase.isNotBlank()) {
                "VidFast endpoints not found"
            }
            val headers = refererHeaders("https://vidfast.io/")
            val requestHeaders = boot.optString("token").takeIf(String::isNotBlank)?.let {
                headers + mapOf("X-CSRF-Token" to it)
            } ?: headers
            val encryptedServers = postBody(
                serversUrl,
                ByteArray(0).toRequestBody(null),
                requestHeaders,
            )
            val servers = JSONArray(decryptVidFast(encryptedServers).toString())
            var lastError: Throwable? = null
            for (index in 0 until servers.length()) {
                val item = servers.optJSONObject(index) ?: continue
                val data = item.optString("data").ifBlank { continue }
                try {
                    val encrypted = postBody(
                        "$streamBase/$data",
                        ByteArray(0).toRequestBody(null),
                        requestHeaders,
                    )
                    val source = JSONObject(decryptVidFast(encrypted).toString())
                    val url = source.optString("url").ifBlank { continue }
                    val subtitles = source.optJSONArray("tracks")?.let { tracks ->
                        (0 until tracks.length()).mapNotNull { trackIndex ->
                            val track = tracks.optJSONObject(trackIndex) ?: return@mapNotNull null
                            val trackUrl = track.optString("file").ifBlank {
                                track.optString("url")
                            }
                            if (trackUrl.isBlank()) return@mapNotNull null
                            SubtitleOption(
                                track.optString("label", "Subtitle"),
                                trackUrl,
                                source = name,
                            )
                        }
                    }.orEmpty()
                    return ExtractionResult.Final(
                        StreamResult(
                            url,
                            name,
                            if (url.contains(".mpd", true)) "dash" else "direct_m3u8",
                            headers,
                            subtitles = subtitles,
                        ),
                    )
                } catch (error: Throwable) {
                    if (error is CancellationException) throw error
                    lastError = error
                    Log.w(tag, "VidFast server $index failed: ${error.message}")
                }
            }
            throw lastError ?: IllegalStateException("VidFast returned no playable stream")
        }

        private fun decryptVidFast(encrypted: String): Any {
            val response = JSONObject(
                postJson(
                    "https://enc-dec.app/api/dec-vidfast",
                    JSONObject().put("text", encrypted).toString(),
                ),
            )
            require(response.optInt("status") == 200) { "VidFast decryption failed" }
            val result = response.opt("result")
                ?: throw IllegalStateException("VidFast decrypted an empty response")
            if (result !is String) return result
            return runCatching<Any> { JSONObject(result) }
                .recoverCatching { JSONArray(result) }
                .getOrElse { result }
        }
    }

    private inner class GenericIframeExtractor : HostExtractor {
        override val name = "GenericIframe"
        override fun supports(server: StreamServer) = server.name.contains("Iframe", true)

        override suspend fun extract(server: StreamServer): ExtractionResult {
            val html = httpGet(server.url)
            val iframe = Regex("""<iframe[^>]+src=["']([^"']+)["']""", RegexOption.IGNORE_CASE)
                .find(html)?.groupValues?.get(1)
                ?: throw IllegalStateException("Iframe not found in ${server.name}")
            val absolute = resolveUrl(server.url, iframe)
            return ExtractionResult.Redirect(StreamServer("${server.name} host", absolute, refererHeaders(server.url)))
        }
    }

    private inner class FilemoonExtractor : HostExtractor {
        override val name = "Filemoon"
        private val aliases = setOf(
            "bf0skv.org", "bysejikuar.com", "moflix-stream.link", "bysezoxexe.com",
            "bysebuho.com", "filemoon.sx", "bysekoze.com", "bysesayeveum.com",
        )

        override fun supports(server: StreamServer): Boolean {
            val domain = host(server.url)
            return domain.contains("filemoon") || domain in aliases
        }

        override suspend fun extract(server: StreamServer): ExtractionResult {
            val matcher = Regex("""/(e|d)/([a-zA-Z0-9]+)""").find(server.url)
                ?: throw IllegalStateException("Filemoon link has no video ID")
            val linkType = matcher.groupValues[1]
            val videoId = matcher.groupValues[2]
            val currentDomain = Regex("""(https?://[^/]+)""").find(server.url)?.groupValues?.get(1)
                ?: throw IllegalStateException("Filemoon link has no base URL")

            val details = getJson(
                "$currentDomain/api/videos/$videoId/embed/details",
                refererHeaders(server.url),
            )
            val embedFrameUrl = details.optString("embed_frame_url")
            require(embedFrameUrl.isNotBlank()) { "Filemoon embed frame URL was not found" }
            val playbackDomain = Regex("""(https?://[^/]+)""").find(embedFrameUrl)
                ?.groupValues?.get(1)
                ?: throw IllegalStateException("Filemoon playback domain was not found")

            val accessHeaders = refererHeaders(embedFrameUrl) + mapOf("Origin" to playbackDomain)
            val challenge = JSONObject(
                postJson(
                    "$playbackDomain/api/videos/access/challenge",
                    "{}",
                    accessHeaders,
                ),
            )
            val challengeId = challenge.optString("challenge_id")
            val nonce = challenge.optString("nonce")
            require(challengeId.isNotBlank() && nonce.isNotBlank()) {
                "Filemoon challenge was incomplete"
            }

            val viewerId = UUID.randomUUID().toString().replace("-", "")
            val deviceId = UUID.randomUUID().toString().replace("-", "")
            val attestation = filemoonAttestation(nonce)
            val attestPayload = JSONObject().apply {
                put("viewer_id", viewerId)
                put("device_id", deviceId)
                put("challenge_id", challengeId)
                put("nonce", nonce)
                put("signature", attestation.first)
                put("public_key", attestation.second)
                put(
                    "client",
                    JSONObject().apply {
                        put("user_agent", userAgent)
                        put("architecture", "x86")
                        put("bitness", "64")
                        put("platform", "Windows")
                        put("platform_version", "10.0.0")
                        put("pixel_ratio", 1.0)
                        put("screen_width", 1920)
                        put("screen_height", 1080)
                        put("languages", JSONArray(listOf("en-US")))
                    },
                )
                put(
                    "storage",
                    JSONObject().apply {
                        put("cookie", viewerId)
                        put("local_storage", viewerId)
                        put("indexed_db", "$viewerId:$deviceId")
                        put("cache_storage", "$viewerId:$deviceId")
                    },
                )
                put("attributes", JSONObject().put("entropy", "high"))
            }.toString()

            val attestResponse = JSONObject(
                postJson(
                    "$playbackDomain/api/videos/access/attest",
                    attestPayload,
                    accessHeaders,
                ),
            )
            val token = attestResponse.optString("token")
            val confidence = attestResponse.optDouble("confidence", 0.0)
            require(token.isNotBlank()) { "Filemoon attestation returned no token" }

            val playbackPayload = JSONObject().apply {
                put(
                    "fingerprint",
                    JSONObject().apply {
                        put("token", token)
                        put("viewer_id", attestResponse.optString("viewer_id", viewerId))
                        put("device_id", attestResponse.optString("device_id", deviceId))
                        put("confidence", confidence)
                    },
                )
            }.toString()
            val playbackHeaders = buildMap {
                putAll(accessHeaders)
                if (linkType == "e") put("X-Embed-Parent", server.url)
            }
            val playbackData = JSONObject(
                postJson(
                    "$playbackDomain/api/videos/$videoId/embed/playback",
                    playbackPayload,
                    playbackHeaders,
                ),
            ).optJSONObject("playback") ?: throw IllegalStateException("Filemoon playback data was not found")

            val iv = Base64.decode(playbackData.optString("iv"), Base64.URL_SAFE)
            val payload = Base64.decode(playbackData.optString("payload"), Base64.URL_SAFE)
            val keyParts = playbackData.optJSONArray("key_parts")
            require(keyParts != null && keyParts.length() >= 2) { "Filemoon playback payload was incomplete" }
            val p1 = Base64.decode(keyParts.getString(0), Base64.URL_SAFE)
            val p2 = Base64.decode(keyParts.getString(1), Base64.URL_SAFE)
            val key = ByteArray(p1.size + p2.size)
            System.arraycopy(p1, 0, key, 0, p1.size)
            System.arraycopy(p2, 0, key, p1.size, p2.size)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(
                Cipher.DECRYPT_MODE,
                SecretKeySpec(key, "AES"),
                GCMParameterSpec(128, iv),
            )
            val decrypted = String(cipher.doFinal(payload), Charsets.UTF_8)
            val sources = JSONObject(decrypted).optJSONArray("sources")
                ?: throw IllegalStateException("Filemoon returned no sources")
            require(sources.length() > 0) { "Filemoon returned an empty source list" }
            val streamUrl = sources.optJSONObject(0).optString("url")
            require(streamUrl.isNotBlank()) { "Filemoon returned no source URL" }

            return ExtractionResult.Final(
                StreamResult(streamUrl, name, mediaType(streamUrl), accessHeaders),
            )
        }

        private fun filemoonAttestation(nonce: String): Pair<String, JSONObject> {
            val keyPairGenerator = KeyPairGenerator.getInstance("EC")
            keyPairGenerator.initialize(ECGenParameterSpec("secp256r1"))
            val keyPair = keyPairGenerator.generateKeyPair()
            val publicKey = keyPair.public as ECPublicKey
            val x = Base64.encodeToString(
                publicKey.w.affineX.toByteArray().stripLeadingZero(),
                Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING,
            )
            val y = Base64.encodeToString(
                publicKey.w.affineY.toByteArray().stripLeadingZero(),
                Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING,
            )
            val signature = Signature.getInstance("SHA256withECDSA")
            signature.initSign(keyPair.private)
            signature.update(nonce.toByteArray())
            val raw = derToRawSignature(signature.sign())
            val encodedSignature = Base64.encodeToString(
                raw,
                Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING,
            )
            val jwk = JSONObject().apply {
                put("crv", "P-256")
                put("ext", true)
                put("key_ops", JSONArray(listOf("verify")))
                put("kty", "EC")
                put("x", x)
                put("y", y)
            }
            return encodedSignature to jwk
        }

        private fun derToRawSignature(der: ByteArray): ByteArray {
            var offset = 2
            val rLen = der[offset + 1].toInt()
            val r = der.copyOfRange(offset + 2, offset + 2 + rLen).stripLeadingZero()
            offset += 2 + rLen
            val sLen = der[offset + 1].toInt()
            val s = der.copyOfRange(offset + 2, offset + 2 + sLen).stripLeadingZero()
            val raw = ByteArray(64)
            System.arraycopy(r, 0, raw, 32 - r.size, r.size)
            System.arraycopy(s, 0, raw, 64 - s.size, s.size)
            return raw
        }

        private fun ByteArray.stripLeadingZero(): ByteArray =
            if (isNotEmpty() && this[0] == 0.toByte()) copyOfRange(1, size) else this
    }

    @SuppressLint("SetJavaScriptEnabled")
    private inner class StreamWishExtractor : HostExtractor {
        override val name = "StreamWish"
        override val usesWebView = true
        private val aliases = setOf(
            "streamwish.to", "streamwish.com", "streamwish.site", "streamwish.club",
            "streamwish.cc", "streamwish.biz", "streamwish.info", "streamwish.net",
            "streamwish.org", "streamwish.live", "streamwish.me", "streamwish.fun",
            "ajmidyad.sbs", "khadhnayad.sbs", "yadmalik.sbs", "hayaatieadhab.sbs",
            "kharabnahs.sbs", "atabkhha.sbs", "atabknha.sbs", "atabknhk.sbs",
            "atabknhs.sbs", "abkrzkr.sbs", "abkrzkz.sbs", "ankrzkz.sbs",
            "ankrznm.sbs", "eghjrutf.sbs", "eghzrutw.sbs", "egsyxurh.sbs",
            "egtpgrvh.sbs", "trgsfjll.sbs", "fsdcmo.sbs", "anime4low.sbs",
            "gsfqzmqu.sbs", "4yftwvrdz7.sbs", "eb8gfmjn71.sbs", "edbrdl7pab.sbs",
            "wishembed.pro", "mwish.pro", "strmwis.xyz", "awish.pro", "dwish.pro",
            "embedwish.com", "vidmoviesb.xyz", "cilootv.store", "uqloads.xyz",
            "tuktukcinema.store", "doodporn.xyz", "volvovideo.top", "wishfast.top",
            "sfastwish.com", "playembed.online", "flaswish.com", "obeywish.com",
            "cdnwish.com", "javsw.me", "cinemathek.online", "mohahhda.site",
            "ma2d.store", "dancima.shop", "swhoi.com", "jodwish.com", "swdyu.com",
            "strwish.com", "asnwish.com", "wishonly.site", "playerwish.com",
            "katomen.store", "swishsrv.com", "iplayerhls.com", "hlsflast.com",
            "ghbrisk.com", "cybervynx.com", "stbhg.click", "dhcplay.com",
            "gradehgplus.com", "ultpreplayer.com", "hglink.to", "haxloppd.com",
            "swish.site", "wishon.site", "vidwish.site", "awish.top", "dwish.top",
            "mwish.top",
        )

        override fun supports(server: StreamServer): Boolean {
            val domain = host(server.url)
            return domain in aliases || domain.contains("streamwish") ||
                domain.contains("swish") || domain.contains("wishfast")
        }

        override suspend fun extract(server: StreamServer): ExtractionResult {
            val uri = URI(server.url)
            val referer = "${uri.scheme}://${uri.host}/"
            val resolved = resolveStreamWishRedirect(server.url, uri.host ?: "")
            val html = httpGet(resolved, refererHeaders(referer))
            val script = unpackPackedScript(html, requiresM3u8 = true)
                ?: throw IllegalStateException("StreamWish player script was not found")
            val source = Regex(
                """(?:["']?hls(\d*)["']?|["']?file["']?)\s*[:=]\s*["']((?:https?://|/)[^"']+\.m3u8[^"']*)["']""",
            ).findAll(script)
                .map { (it.groupValues[1].toIntOrNull() ?: 0) to it.groupValues[2] }
                .sortedByDescending { it.first }
                .map { it.second }
                .firstOrNull()
                ?: throw IllegalStateException("StreamWish returned no m3u8 source")
            val finalSource = if (source.startsWith("/")) {
                val resolvedUri = URI(resolved)
                "${resolvedUri.scheme}://${resolvedUri.host}$source"
            } else {
                source
            }
            val tracksBlock = Regex("""tracks:\s*\[(.*?)]""", RegexOption.DOT_MATCHES_ALL)
                .find(script)?.groupValues?.get(1).orEmpty()
            val subtitles = Regex(
                """file:\s*"(.*?)"(?:,label:\s*"(.*?)")?,kind:\s*"(.*?)"""",
                RegexOption.DOT_MATCHES_ALL,
            ).findAll(tracksBlock)
                .filter { it.groupValues[3] == "captions" }
                .mapNotNull {
                    val url = it.groupValues[1]
                    if (url.isBlank()) return@mapNotNull null
                    SubtitleOption(
                        it.groupValues[2].ifBlank { "Subtitle" },
                        resolveUrl(resolved, url),
                        source = name,
                    )
                }
                .toList()
            val resolvedOrigin = URI(resolved).let { "${it.scheme}://${it.host}" }
            val headers = refererHeaders(referer) + mapOf("Origin" to resolvedOrigin)
            return ExtractionResult.Final(
                StreamResult(finalSource, name, "direct_m3u8", headers, subtitles = subtitles),
            )
        }

        @SuppressLint("SetJavaScriptEnabled")
        private suspend fun resolveStreamWishRedirect(url: String, hostName: String): String {
            return withContext(Dispatchers.Main) {
                withTimeoutOrNull(30_000) {
                    suspendCancellableCoroutine { continuation ->
                        val webView = WebView(context)
                        webView.settings.javaScriptEnabled = true
                        webView.settings.loadsImagesAutomatically = false
                        webView.settings.blockNetworkImage = true
                        webView.settings.cacheMode = android.webkit.WebSettings.LOAD_NO_CACHE
                        webView.settings.domStorageEnabled = true
                        webView.webViewClient = object : WebViewClient() {
                            override fun shouldOverrideUrlLoading(
                                view: WebView?,
                                request: WebResourceRequest?,
                            ): Boolean {
                                val newUrl = request?.url.toString()
                                if (newUrl.contains(hostName) || newUrl.contains("/e/")) {
                                    if (continuation.isActive) continuation.resume(newUrl)
                                    webView.post { webView.destroy() }
                                    return true
                                }
                                return false
                            }

                            override fun onPageFinished(view: WebView?, url: String?) {
                                if (url != null &&
                                    (url.contains(hostName) || url.contains("/e/") || !url.contains("about:blank"))
                                ) {
                                    if (continuation.isActive) continuation.resume(url)
                                    webView.post { webView.destroy() }
                                }
                            }
                        }
                        webView.loadUrl(url)
                        continuation.invokeOnCancellation {
                            webView.post {
                                webView.stopLoading()
                                webView.destroy()
                            }
                        }
                    }
                } ?: url
            }
        }
    }

    private inner class DoodLaExtractor : HostExtractor {
        override val name = "Dood"
        private val alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"

        override fun supports(server: StreamServer): Boolean {
            val domain = host(server.url)
            return domain.contains("dood") || domain.contains("d000d") || domain == "vide0.net"
        }

        override suspend fun extract(server: StreamServer): ExtractionResult {
            val embedUrl = server.url.replace("/d/", "/e/")
            val (finalUrl, html) = httpGetFinalUrl(embedUrl, refererHeaders(server.url))
            val md5Path = Regex("""/pass_md5/[^']*""").find(html)?.value
                ?: throw IllegalStateException("Dood pass_md5 path was not found")
            val finalBaseUrl = URI(finalUrl).let { "${it.scheme}://${it.host}" }
            val videoPrefix = httpGet(
                finalBaseUrl + md5Path,
                refererHeaders(finalUrl),
            )
            val url = videoPrefix +
                buildString { repeat(10) { append(alphabet[(Math.random() * alphabet.length).toInt()]) } } +
                "?token=${md5Path.substringAfterLast("/")}"
            return ExtractionResult.Final(
                StreamResult(url, name, mediaType(url), refererHeaders(finalBaseUrl)),
            )
        }
    }

    private inner class VidMoLyExtractor : HostExtractor {
        override val name = "VidMoLy"
        private val redirectUrl = "https://vidmoly.to/"

        override fun supports(server: StreamServer): Boolean = host(server.url).contains("vidmoly")

        override suspend fun extract(server: StreamServer): ExtractionResult {
            val html = httpGet(server.url.replace(".me/", ".to/"), refererHeaders(redirectUrl))
            val hlsUrl = Regex("""sources:\s*\[\{file:\s*"([^"]+)"\}\]""")
                .find(html)?.groupValues?.get(1)
                ?: throw IllegalStateException("VidMoLy HLS source was not found")
            return ExtractionResult.Final(
                StreamResult(hlsUrl, name, "direct_m3u8", refererHeaders(redirectUrl)),
            )
        }
    }

    private inner class LuluVdoExtractor : HostExtractor {
        override val name = "LuluVdo"

        override fun supports(server: StreamServer): Boolean {
            val domain = host(server.url)
            return domain.contains("luluv") || domain in setOf("luluvdo.com", "luluvdoo.com", "luluvid.com")
        }

        override suspend fun extract(server: StreamServer): ExtractionResult {
            val html = httpGet(server.url)
            val source = Regex("""sources: \[\{file:"(.*?)"\}""")
                .find(html)?.groupValues?.get(1)
                ?: throw IllegalStateException("LuluVdo source was not found")
            val tracksBlock = Regex("""tracks: \[(.*?)]""", RegexOption.DOT_MATCHES_ALL)
                .find(html)?.groupValues?.get(1).orEmpty()
            val subtitles = Regex("""file: "(.*?)", label: "(.*?)"""")
                .findAll(tracksBlock)
                .mapNotNull {
                    val url = it.groupValues[1]
                    val label = it.groupValues[2]
                    if (url.isBlank() || label == "Upload captions") return@mapNotNull null
                    SubtitleOption(label, resolveUrl(server.url, url), source = name)
                }
                .toList()
            return ExtractionResult.Final(
                StreamResult(
                    source,
                    name,
                    mediaType(source),
                    refererHeaders(server.url),
                    subtitles = subtitles,
                ),
            )
        }
    }

    private inner class MixDropExtractor : HostExtractor {
        override val name = "MixDrop"

        override fun supports(server: StreamServer): Boolean {
            val domain = host(server.url)
            return domain.contains("mixdrop") || domain.contains("mxdrop") ||
                Regex("""^md[3bfyz][a-z0-9]*\.[a-z0-9]+""", RegexOption.IGNORE_CASE).containsMatchIn(domain)
        }

        override suspend fun extract(server: StreamServer): ExtractionResult {
            val embedUrl = server.url
                .replace("/f/", "/e/")
                .replace(".club/", ".ag/")
                .replace(Regex("""^(https?://[^/]+/e/[^/?#]+).*$""", RegexOption.IGNORE_CASE), "$1")
            val html = httpGet(
                embedUrl,
                refererHeaders("https://mixdrop.co") +
                    mapOf(
                        "Accept" to "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                        "X-Requested-With" to "XMLHttpRequest",
                    ),
            )
            val script = unpackPackedScript(html) ?: html
            val sourceUrl = Regex("""wurl.*?=.*?"(.*?)";""")
                .find(script)?.groupValues?.get(1)
                ?: throw IllegalStateException("MixDrop source was not found")
            val finalUrl = when {
                sourceUrl.startsWith("//") -> "https:$sourceUrl"
                sourceUrl.startsWith("http") -> sourceUrl
                else -> "https://$sourceUrl"
            }
            return ExtractionResult.Final(
                StreamResult(
                    finalUrl,
                    name,
                    mediaType(finalUrl),
                    refererHeaders("https://mixdrop.co"),
                ),
            )
        }
    }

    private inner class SupervideoExtractor : HostExtractor {
        override val name = "Supervideo"
        private val mainUrl = "https://supervideo.cc"

        override fun supports(server: StreamServer): Boolean = host(server.url).contains("supervideo")

        override suspend fun extract(server: StreamServer): ExtractionResult {
            val pageHtml = try {
                httpGet(server.url)
            } catch (e: Exception) {
                if (e is CancellationException) throw e
                httpGet(if (server.url.startsWith("http")) server.url else "https:${server.url}")
            }
            val scriptData = pageHtml
                .substringAfter("eval(function(p,a,c,k,e,d)")
                .substringBefore("</script>")
                .let { "eval(function(p,a,c,k,e,d)$it" }
            if (!scriptData.startsWith("eval")) {
                throw IllegalStateException("Supervideo packed script was not found")
            }
            val unpacked = JsUnpacker(scriptData).unpack()
                ?: throw IllegalStateException("Supervideo script unpack failed")
            val streamUrl = Regex("""file\s*:\s*["']([^"']+)["']""")
                .find(unpacked)?.groupValues?.get(1)
                ?: throw IllegalStateException("Supervideo stream URL was not found")
            val tracksBlock = Regex("""tracks\s*:\s*\[(.*?)\]""", RegexOption.DOT_MATCHES_ALL)
                .find(unpacked)?.groupValues?.get(1).orEmpty()
            val subtitles = Regex(
                """file\s*:\s*"(.*?)"\s*,\s*label\s*:\s*"(.*?)"\s*,\s*kind\s*:\s*"captions"""",
            ).findAll(tracksBlock)
                .mapNotNull {
                    val url = it.groupValues[1]
                    if (url.isBlank()) return@mapNotNull null
                    SubtitleOption(it.groupValues[2], resolveUrl(server.url, url), source = name)
                }
                .toList()
            return ExtractionResult.Final(
                StreamResult(
                    streamUrl,
                    name,
                    mediaType(streamUrl),
                    refererHeaders(mainUrl),
                    subtitles = subtitles,
                ),
            )
        }
    }

    private inner class RabbitstreamExtractor : HostExtractor {
        override val name = "Rabbitstream"
        private val sourceApi = "https://rabbitstream.net/ajax/v2/embed-4/"

        override fun supports(server: StreamServer): Boolean {
            val domain = host(server.url)
            return domain.contains("rabbitstream") || domain.contains("dokicloud") ||
                domain.contains("premiumembeding")
        }

        override suspend fun extract(server: StreamServer): ExtractionResult {
            val sourceId = server.url.substringAfterLast("/").substringBefore("?")
            val headers = refererHeaders(server.url) + mapOf(
                "Accept" to "*/*",
                "X-Requested-With" to "XMLHttpRequest",
            )
            val response = getJson(sourceApi + sourceId, headers)
            val (streamUrl, subtitles) = parseRabbitSourcesResponse(response, server.url, name)
            return ExtractionResult.Final(
                StreamResult(streamUrl, name, mediaType(streamUrl), headers, subtitles = subtitles),
            )
        }
    }

    private inner class MegacloudExtractor : HostExtractor {
        override val name = "Megacloud"

        override fun supports(server: StreamServer): Boolean {
            val domain = host(server.url)
            return domain.contains("megacloud") || domain.contains("videostr")
        }

        override suspend fun extract(server: StreamServer): ExtractionResult {
            val httpUrl = server.url.toHttpUrl()
            val hostUrl = "${httpUrl.scheme}://${httpUrl.host}/"
            val embedPath = httpUrl.pathSegments.dropLast(1).joinToString("/")
            val embedHtml = httpGet(server.url, refererHeaders(hostUrl))
            val token = megacloudToken(embedHtml)
                ?: throw IllegalStateException("Megacloud embed token was not found")
            val sourcesUrl = "$hostUrl$embedPath/getSources?id=${httpUrl.pathSegments.last()}&_k=$token"
            val headers = refererHeaders(server.url) + mapOf(
                "Accept" to "*/*",
                "X-Requested-With" to "XMLHttpRequest",
            )
            val response = getJson(sourcesUrl, headers)
            val sourcesValue = response.opt("sources")
            val (streamUrl, subtitles) = if (sourcesValue is String) {
                val (key, sources) = megacloudExtractRealKey(
                    sourcesValue,
                    megacloudKeys(httpUrl.scheme, httpUrl.host),
                )
                parseRabbitSourcesJson(sources, key, response.optJSONArray("tracks"), server.url, name)
            } else {
                parseRabbitSourcesJson(
                    sourcesValue?.toString() ?: "[]",
                    "",
                    response.optJSONArray("tracks"),
                    server.url,
                    name,
                )
            }
            return ExtractionResult.Final(
                StreamResult(
                    streamUrl,
                    name,
                    mediaType(streamUrl),
                    headers + mapOf("Referer" to hostUrl),
                    subtitles = subtitles,
                ),
            )
        }
    }

    private inner class GxPlayerExtractor : HostExtractor {
        override val name = "GxPlayer"

        override fun supports(server: StreamServer): Boolean = host(server.url).contains("gxplayer")

        override suspend fun extract(server: StreamServer): ExtractionResult {
            val base = URI(server.url).let { "${it.scheme}://${it.host}" }
            val html = httpGet(server.url, refererHeaders(base))
            val script = Regex(
                """<script[^>]*>.*?var video =.*?</script>""",
                setOf(RegexOption.DOT_MATCHES_ALL, RegexOption.IGNORE_CASE),
            ).find(html)?.value
                ?: throw IllegalStateException("GxPlayer video script was not found")
            val id = Regex("\"id\":\"([^\"]+)\"").find(script)?.groupValues?.get(1).orEmpty()
            val uid = Regex("\"uid\":\"([^\"]+)\"").find(script)?.groupValues?.get(1).orEmpty()
            val md5 = Regex("\"md5\":\"([^\"]+)\"").find(script)?.groupValues?.get(1).orEmpty()
            val status = Regex("\"status\":\"([^\"]+)\"").find(script)?.groupValues?.get(1).orEmpty()
            require(uid.isNotBlank() && md5.isNotBlank() && id.isNotBlank()) {
                "GxPlayer video parameters were not found"
            }
            val streamUrl = "$base/m3u8/$uid/$md5/master.txt?s=1&id=$id&cache=$status"
            return ExtractionResult.Final(
                StreamResult(streamUrl, name, "direct_m3u8", refererHeaders(base)),
            )
        }
    }

    private inner class VeevExtractor : HostExtractor {
        override val name = "Veev"
        private val pattern = Regex(
            """(?://|\.)((?:veev|kinoger|poophq|doods)\.(?:to|pw|com))/(?:e|d)/([0-9a-zA-Z]+)""",
        )

        override fun supports(server: StreamServer): Boolean {
            return pattern.containsMatchIn(server.url) || host(server.url).contains("veev")
        }

        override suspend fun extract(server: StreamServer): ExtractionResult {
            val match = pattern.find(server.url) ?: throw IllegalStateException("Invalid Veev URL")
            val embedHost = match.groupValues[1]
            var mediaId = match.groupValues[2]
            val referer = server.url
            val headers = refererHeaders(referer) + mapOf("Origin" to referer)
            val (finalUrl, responseBody) = httpGetFinalUrl("https://$embedHost/e/$mediaId", headers)
            pattern.find(finalUrl)?.let {
                val newId = it.groupValues[2]
                if (newId != mediaId) mediaId = newId
            }

            val items = Regex(
                """[\.\s'](?:fc|_vvto\[[^\]]*)(?:['\]]*)?\s*[:=]\s*['"]([^'"]+)""",
            ).findAll(responseBody).map { it.groupValues[1] }.toList()
            if (items.isEmpty()) throw IllegalStateException("Veev video was removed")

            val mainLink = URI(server.url).let { "${it.scheme}://${it.host}" }
            for (f in items.asReversed()) {
                val ch = try {
                    veevDecode(f)
                } catch (e: Exception) {
                    if (e is CancellationException) throw e
                    f
                }
                if (ch == f) continue
                val params = listOf(
                    "op" to "player_api",
                    "cmd" to "gi",
                    "file_code" to mediaId,
                    "r" to encode(referer),
                    "ch" to ch,
                    "ie" to "1",
                )
                val downloadUrl = "$mainLink/dl?" + params.joinToString("&") { "${it.first}=${it.second}" }
                val fileJson = JSONObject(httpGet(downloadUrl, headers)).optJSONObject("file")
                    ?: throw IllegalStateException("Veev video was removed")
                if (fileJson.optString("file_status") == "OK") {
                    val dv = fileJson.optJSONArray("dv")?.optJSONObject(0)?.optString("s")
                        ?: throw IllegalStateException("Veev source data was not found")
                    val sourceUrl = veevDecodeUrl(veevDecode(dv), veevBuildArray(ch)[0])
                    return ExtractionResult.Final(
                        StreamResult(sourceUrl, name, mediaType(sourceUrl), headers),
                    )
                }
                throw IllegalStateException("Veev video was removed")
            }
            throw IllegalStateException("Veev returned no playable source")
        }

        private fun veevDecode(etext: String): String {
            val result = StringBuilder()
            val lut = mutableMapOf<Int, String>()
            var n = 256
            var c = etext[0].toString()
            result.append(c)
            for (char in etext.drop(1)) {
                val code = char.code
                val nc = if (code < 256) char.toString() else lut[code] ?: (c + c[0])
                result.append(nc)
                lut[n] = c + nc[0]
                n += 1
                c = nc
            }
            return result.toString()
        }

        private fun veevBuildArray(encodedString: String): List<List<Int>> {
            val d = mutableListOf<List<Int>>()
            val c = encodedString.toMutableList()
            var count = if (c.isNotEmpty() && c[0].isDigit()) c.removeAt(0).digitToInt() else 0
            while (count != 0) {
                val currentArray = mutableListOf<Int>()
                repeat(count) {
                    currentArray.add(0, if (c.isNotEmpty() && c[0].isDigit()) c.removeAt(0).digitToInt() else 0)
                }
                d.add(currentArray)
                count = if (c.isNotEmpty() && c[0].isDigit()) c.removeAt(0).digitToInt() else 0
            }
            return d
        }

        private fun veevDecodeUrl(etext: String, tarray: List<Int>): String {
            var ds = etext
            for (t in tarray) {
                if (t == 1) ds = ds.reversed()
                val bytes = ds.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
                ds = String(bytes, Charsets.UTF_8)
                ds = ds.replace("dXRmOA==", "")
            }
            return ds
        }
    }

    private inner class VidplayExtractor : HostExtractor {
        override val name = "Vidplay"
        private val keysUrl = "https://raw.githubusercontent.com/Ciarands/vidsrc-keys/main/keys.json"

        override fun supports(server: StreamServer): Boolean {
            val domain = host(server.url)
            return domain.contains("vidplay") || domain in setOf("mcloud.bz", "vidplay.online")
        }

        override suspend fun extract(server: StreamServer): ExtractionResult {
            val mainUrl = URI(server.url).let { "${it.scheme}://${it.host}" }
            val id = server.url.substringBefore("?").substringAfterLast("/")
            val keys = getJson(keysUrl)
            val encrypt = keys.optJSONArray("encrypt")
            val decrypt = keys.optJSONArray("decrypt")
            require(encrypt != null && decrypt != null && encrypt.length() >= 3 && decrypt.length() >= 2) {
                "Vidplay keys were incomplete"
            }
            val encId = rc4EncodeBase64(encrypt.getString(1), id)
            val h = rc4EncodeBase64(encrypt.getString(2), id)
            val query = server.url.substringAfter("?", "")
            val mediaUrl = "$mainUrl/mediainfo/$encId?$query&autostart=true&ads=0&h=$h"
            val headers = refererHeaders(server.url) + mapOf("X-Requested-With" to "XMLHttpRequest")
            val response = getJson(mediaUrl, headers)

            val (sources, tracks) = if (response.optJSONObject("result") != null) {
                val result = response.optJSONObject("result")
                (result?.optJSONArray("sources") ?: JSONArray()) to result?.optJSONArray("tracks")
            } else {
                val encrypted = response.optString("result")
                require(encrypted.isNotBlank()) { "Vidplay returned no result" }
                val result = JSONObject(decryptVidplay(decrypt.getString(1), encrypted))
                (result.optJSONArray("sources") ?: JSONArray()) to result.optJSONArray("tracks")
            }
            require(sources.length() > 0) { "Vidplay returned no sources" }
            val streamUrl = sources.optJSONObject(0).optString("file")
            require(streamUrl.isNotBlank()) { "Vidplay returned no source URL" }
            val subtitles = if (tracks == null) {
                emptyList()
            } else {
                (0 until tracks.length()).mapNotNull { index ->
                    val track = tracks.optJSONObject(index) ?: return@mapNotNull null
                    if (track.optString("kind") != "captions") return@mapNotNull null
                    val url = track.optString("file")
                    if (url.isBlank()) return@mapNotNull null
                    SubtitleOption(track.optString("label", "Subtitle"), resolveUrl(mainUrl, url), source = name)
                }
            }
            return ExtractionResult.Final(
                StreamResult(streamUrl, name, mediaType(streamUrl), headers, subtitles = subtitles),
            )
        }
    }

    private inner class StreamrubyExtractor : HostExtractor {
        override val name = "Streamruby"

        override fun supports(server: StreamServer): Boolean {
            val domain = host(server.url)
            return domain.contains("streamruby") || domain.contains("stmruby") ||
                domain.contains("rubystm") || domain.contains("rubyvid") ||
                domain.contains("moflix-stream.fans")
        }

        override suspend fun extract(server: StreamServer): ExtractionResult {
            val baseUrl = URI(server.url).let { "${it.scheme}://${it.host}" }
            val html = httpGet(server.url, refererHeaders(baseUrl))
            val packedJS = Regex("(eval\\(function\\(p,a,c,k,e,d\\)(.|\\n)*?)</script>")
                .find(html)?.groupValues?.get(1)
                ?: throw IllegalStateException("Streamruby packed script was not found")
            val unpacked = JsUnpacker(packedJS).unpack()
                ?: throw IllegalStateException("Streamruby script unpack failed")
            val streamUrl = Regex("""file\s*:\s*["']([^"']+)["']""")
                .find(unpacked)?.groupValues?.get(1)
                ?: throw IllegalStateException("Streamruby returned no source")
            return ExtractionResult.Final(
                StreamResult(streamUrl, name, mediaType(streamUrl), refererHeaders(baseUrl)),
            )
        }
    }

    private inner class StreamUpExtractor : HostExtractor {
        override val name = "StreamUp"

        override fun supports(server: StreamServer): Boolean {
            val domain = host(server.url)
            return domain.endsWith("strmup.to") || domain.endsWith("upstream.to")
        }

        override suspend fun extract(server: StreamServer): ExtractionResult {
            val fileCode = URI(server.url).path.split("/").lastOrNull { it.isNotEmpty() }
                ?: throw IllegalStateException("StreamUp file code not found in URL")
            val baseUrl = URI(server.url).let { "${it.scheme}://${it.host}" }
            val apiUrl = "$baseUrl/ajax/stream"
            val referer = "$baseUrl/v/$fileCode"
            val headers = refererHeaders(referer)
            val request = okhttp3.FormBody.Builder()
                .add("filecode", fileCode)
                .build()
            val body = postBody(apiUrl, request, headers)
            val json = JSONObject(body)
            val streamUrl = json.optString("streaming_url").ifBlank {
                throw IllegalStateException("StreamUp returned no streaming_url")
            }
            val subtitles = json.optJSONArray("subtitles")?.let { arr ->
                (0 until arr.length()).mapNotNull { i ->
                    val sub = arr.optJSONObject(i) ?: return@mapNotNull null
                    val label = sub.optString("language").ifBlank { return@mapNotNull null }
                    val file = sub.optString("file_path").ifBlank { return@mapNotNull null }
                    SubtitleOption(label, file, source = name)
                }
            }.orEmpty()
            return ExtractionResult.Final(
                StreamResult(streamUrl, name, mediaType(streamUrl), refererHeaders(baseUrl), subtitles = subtitles),
            )
        }
    }

    private inner class VidaraExtractor : HostExtractor {
        override val name = "Vidara"

        override fun supports(server: StreamServer): Boolean {
            val domain = host(server.url)
            return domain.endsWith("vidara.to") || domain.endsWith("vidara.so")
        }

        override suspend fun extract(server: StreamServer): ExtractionResult {
            val fileCode = URI(server.url).path.split("/").lastOrNull { it.isNotEmpty() }
                ?: throw IllegalStateException("Vidara file code not found")
            val baseUrl = URI(server.url).let { "${it.scheme}://${it.host}" }
            val payload = JSONObject().put("filecode", fileCode).put("device", "web").toString()
            val body = postJson("$baseUrl/api/stream", payload)
            val json = JSONObject(body)
            val streamUrl = json.optString("streaming_url").ifBlank {
                throw IllegalStateException("Vidara returned no streaming_url")
            }
            val subtitles = json.optJSONArray("subtitles")?.let { arr ->
                (0 until arr.length()).mapNotNull { i ->
                    val sub = arr.optJSONObject(i) ?: return@mapNotNull null
                    val label = sub.optString("language").ifBlank { return@mapNotNull null }
                    val file = sub.optString("file_path").ifBlank { return@mapNotNull null }
                    SubtitleOption(label, file, source = name)
                }
            }.orEmpty()
            return ExtractionResult.Final(
                StreamResult(streamUrl, name, mediaType(streamUrl), refererHeaders(baseUrl), subtitles = subtitles),
            )
        }
    }

    private inner class VidHideExtractor : HostExtractor {
        override val name = "VidHide"

        override fun supports(server: StreamServer): Boolean {
            val domain = host(server.url)
            return domain.endsWith("dhtpre.com") || domain.endsWith("peytonepre.com") ||
                domain.endsWith("vidhideplus.com") || domain.endsWith("filelions.to") ||
                domain.endsWith("moflix-stream.click")
        }

        override suspend fun extract(server: StreamServer): ExtractionResult {
            val base = URI(server.url).let { "${it.scheme}://${it.host}" }
            val html = httpGet(server.url, refererHeaders(base))
            val packedJS = Regex("(eval\\(function\\(p,a,c,k,e,d\\)(.|\\n)*?)</script>")
                .find(html)?.groupValues?.get(1)
                ?: throw IllegalStateException("VidHide packed script not found")
            val unpacked = JsUnpacker(packedJS).unpack()
                ?: throw IllegalStateException("VidHide script unpack failed")
            val streamUrl = Regex("""(?:hls\d+|file)\s*[:=]\s*["']([^"']+\.m3u8[^"']*)["']""")
                .find(unpacked)?.groupValues?.get(1)
                ?.let { if (it.startsWith("/")) "$base$it" else it }
                ?: throw IllegalStateException("VidHide returned no m3u8 source")
            return ExtractionResult.Final(
                StreamResult(streamUrl, name, mediaType(streamUrl), refererHeaders(base)),
            )
        }
    }

    private inner class NekostreamExtractor : HostExtractor {
        override val name = "Nekostream"

        override fun supports(server: StreamServer): Boolean {
            val domain = host(server.url)
            return domain.endsWith("vidtube.site") || domain.endsWith("megaplay.buzz") ||
                domain.endsWith("vidwish.live")
        }

        override suspend fun extract(server: StreamServer): ExtractionResult {
            val pageBody = httpGet(server.url, refererHeaders("https://anikototv.to/"))
            val origin = URI(server.url).let { "${it.scheme}://${it.host}" }
            val fileId = Regex("""id=["']megaplay-player["'][^>]*data-id=["']([^"']+)""")
                .find(pageBody)?.groupValues?.get(1)
                ?: Regex("""data-id=["']([^"']+)["'][^>]*id=["']megaplay-player["']""")
                    .find(pageBody)?.groupValues?.get(1)
                ?: throw IllegalStateException("Nekostream player file id not found")
            val streamType = Regex("""type:\s*['"]([^'"]+)""")
                .find(pageBody)?.groupValues?.get(1)
            val sourcesUrl = if (pageBody.contains("getSourcesNew")) {
                "$origin/stream/getSourcesNew?id=$fileId" + (streamType?.let { "&type=$it" } ?: "")
            } else {
                "$origin/stream/getSources?id=$fileId"
            }
            val sourcesHeaders = refererHeaders(server.url) + mapOf(
                "Origin" to origin,
                "X-Requested-With" to "XMLHttpRequest",
            )
            val sourcesJson = getJson(sourcesUrl, sourcesHeaders)
            val streamUrl = sourcesJson.optJSONObject("sources")?.optString("file")
                ?: sourcesJson.optString("file").ifBlank { null }
                ?: throw IllegalStateException("Nekostream source not found")
            val subtitles = sourcesJson.optJSONArray("tracks")?.let { arr ->
                (0 until arr.length()).mapNotNull { i ->
                    val track = arr.optJSONObject(i) ?: return@mapNotNull null
                    val kind = track.optString("kind")
                    if (kind.isNotBlank() && kind != "captions") return@mapNotNull null
                    val label = track.optString("label").ifBlank { "Subtitle" }
                    val file = track.optString("file").ifBlank { return@mapNotNull null }
                    val isDefault = track.optBoolean("default", false)
                    SubtitleOption(label, file, isDefault, source = name)
                }
            }.orEmpty()
            return ExtractionResult.Final(
                StreamResult(streamUrl, name, mediaType(streamUrl), refererHeaders(origin), subtitles = subtitles),
            )
        }
    }

    private inner class VidoraExtractor : HostExtractor {
        override val name = "Vidora"

        override fun supports(server: StreamServer): Boolean = host(server.url).endsWith("vidora.stream")

        override suspend fun extract(server: StreamServer): ExtractionResult {
            val html = httpGet(server.url, refererHeaders("https://vidora.stream"))
            val packedJS = Regex("(eval\\(function\\(p,a,c,k,e,d\\)(.|\\n)*?)</script>")
                .find(html)?.groupValues?.get(1)
                ?: throw IllegalStateException("Vidora packed script not found")
            val unpacked = JsUnpacker(packedJS).unpack()
                ?: throw IllegalStateException("Vidora script unpack failed")
            val streamUrl = Regex("""file\s*:\s*["']([^"']+)["']""")
                .find(unpacked)?.groupValues?.get(1)
                ?: throw IllegalStateException("Vidora returned no source")
            return ExtractionResult.Final(
                StreamResult(streamUrl, name, mediaType(streamUrl), refererHeaders("https://vidora.stream")),
            )
        }
    }

    private inner class VidsonicExtractor : HostExtractor {
        override val name = "Vidsonic"

        override fun supports(server: StreamServer): Boolean = host(server.url).endsWith("vidsonic.net")

        override suspend fun extract(server: StreamServer): ExtractionResult {
            val html = httpGet(server.url)
            val encodedRegex = Regex("""const\s+\w+\s*=\s*'([a-fA-F0-9|]{50,})';""")
            val encodedStr = encodedRegex.find(html)?.groupValues?.get(1)
                ?: throw IllegalStateException("Vidsonic encoded string not found")
            val cleaned = encodedStr.replace("|", "")
            val asciiBuilder = StringBuilder()
            for (i in cleaned.indices step 2) {
                val hexPair = cleaned.substring(i, i + 2)
                asciiBuilder.append(hexPair.toInt(16).toChar())
            }
            val streamUrl = asciiBuilder.toString().reversed()
            return ExtractionResult.Final(
                StreamResult(streamUrl, name, mediaType(streamUrl), refererHeaders("https://vidsonic.net")),
            )
        }
    }

    private inner class VtubeExtractor : HostExtractor {
        override val name = "Vtube"

        override fun supports(server: StreamServer): Boolean {
            val domain = host(server.url)
            return domain.endsWith("vtbe.to") || domain.endsWith("vtube.to")
        }

        override suspend fun extract(server: StreamServer): ExtractionResult {
            val html = httpGet(server.url)
            val streamUrl = Regex("""sources:\s*\[\s*\{file:"([^"]+\.m3u8[^"]*)"""")
                .find(html)?.groupValues?.get(1)
                ?: Regex("""file:"([^"]+\.m3u8[^"]*)"""")
                    .find(html)?.groupValues?.get(1)
                ?: throw IllegalStateException("Vtube source not found")
            val origin = URI(server.url).let { "${it.scheme}://${it.host}" }
            return ExtractionResult.Final(
                StreamResult(streamUrl, name, mediaType(streamUrl), refererHeaders("$origin/")),
            )
        }
    }

    private inner class OkruExtractor : HostExtractor {
        override val name = "Okru"

        override fun supports(server: StreamServer): Boolean = host(server.url).endsWith("ok.ru")

        override suspend fun extract(server: StreamServer): ExtractionResult {
            val html = httpGet(server.url)
            val dataOptions = Regex("""div[^>]+data-options=["']([^"']+)["']""")
                .find(html)?.groupValues?.get(1)
                ?: throw IllegalStateException("Okru data-options not found")
            val videoUrls = Regex("""url\\*?\\*?:\\*?\\*?"(https://[^"]+)""")
                .findAll(dataOptions).map { it.groupValues[1].replace("\\u0026", "&") }.toList()
            if (videoUrls.isEmpty()) throw IllegalStateException("Okru found no video URLs")
            val streamUrl = videoUrls.first()
            return ExtractionResult.Final(
                StreamResult(streamUrl, name, mediaType(streamUrl), refererHeaders("https://ok.ru")),
            )
        }
    }

    private inner class DailymotionExtractor : HostExtractor {
        override val name = "Dailymotion"

        override fun supports(server: StreamServer): Boolean {
            val domain = host(server.url)
            return domain.endsWith("dailymotion.com") || domain.endsWith("dai.ly")
        }

        override suspend fun extract(server: StreamServer): ExtractionResult {
            val videoId = server.url.substringAfterLast("/").substringAfter("video=")
            val ts = (System.currentTimeMillis() / 1000).toString()
            val viewId = List(19) { (('a'..'z') + ('0'..'9')).random() }.joinToString("")
            val apiUrl = "https://geo.dailymotion.com/video/$videoId.json" +
                "?legacy=true&player-id=xtv3w&is_native_app=0&app=com.dailymotion.neon" +
                "&client_type=website&section_type=player&component_style=_&parallelCalls=1" +
                "&locale=en&dmV1st=${UUID.randomUUID()}&dmTs=$ts&dmViewId=$viewId"
            val headers = refererHeaders("https://geo.dailymotion.com/")
            val json = getJson(apiUrl, headers)
            val streamUrl = json.optJSONObject("qualities")
                ?.optJSONArray("auto")
                ?.optJSONObject(0)
                ?.optString("url")
                ?: throw IllegalStateException("Dailymotion manifest URL not found")
            return ExtractionResult.Final(
                StreamResult(streamUrl, name, mediaType(streamUrl), refererHeaders("https://www.dailymotion.com")),
            )
        }
    }

    private inner class GenericMediaExtractor : HostExtractor {
        override val name = "Generic media"
        override fun supports(server: StreamServer) = true

        override suspend fun extract(server: StreamServer): ExtractionResult {
            if (isMediaUrl(server.url)) {
                return ExtractionResult.Final(
                    StreamResult(server.url, server.name, mediaType(server.url), server.headers),
                )
            }

            val html = httpGet(server.url, server.headers + refererHeaders(server.url))
            val match = Regex(
                """https?://[^\s"'<>]+\.(?:m3u8|mp4)(?:[^\s"'<>]*)?""",
                RegexOption.IGNORE_CASE,
            ).find(html)?.value ?: throw IllegalStateException("No media URL found in page")
            val url = match.replace("\\/", "/").replace("&amp;", "&")
            return ExtractionResult.Final(
                StreamResult(url, server.name, mediaType(url), server.headers + refererHeaders(server.url)),
            )
        }
    }

    private fun unpackObfuscatedJs(html: String): String? {
        val marker = "eval(function(p,a,c,k,e,d){"
        val start = html.indexOf(marker)
        if (start < 0) return null

        // Find closing } of function body
        // Marker already consumed the opening {, so start braceCount at 1
        var braceCount = 1
        var i = start + marker.length
        while (i < html.length) {
            when (html[i]) {
                '{' -> braceCount++
                '}' -> {
                    braceCount--
                    if (braceCount == 0) break
                }
            }
            i++
        }
        // i is now at closing }, skip to (
        i++
        while (i < html.length && html[i] != '(') i++
        i++ // skip (

        // Parse the four arguments: 'CODE',BASE,COUNT,'DICT'.split('|')
        // Arg 1: quoted string (CODE)
        if (i >= html.length || html[i] != '\'') return null
        i++ // skip opening '
        val codeStart = i
        while (i < html.length && html[i] != '\'') i++
        val code = html.substring(codeStart, i)
        i++ // skip closing '

        // Skip comma
        while (i < html.length && html[i] != ',') i++
        i++ // skip ,

        // Arg 2: BASE number
        val baseStart = i
        while (i < html.length && html[i].isDigit()) i++
        val base = html.substring(baseStart, i).toIntOrNull() ?: return null

        // Skip comma
        while (i < html.length && html[i] != ',') i++
        i++ // skip ,

        // Arg 3: COUNT number
        val countStart = i
        while (i < html.length && html[i].isDigit()) i++
        val count = html.substring(countStart, i).toIntOrNull() ?: return null

        // Skip comma
        while (i < html.length && html[i] != ',') i++
        i++ // skip ,

        // Arg 4: 'DICT'.split('|')
        if (i >= html.length || html[i] != '\'') return null
        i++ // skip opening '
        val dictStart = i
        while (i < html.length && html[i] != '\'') i++
        val dictStr = html.substring(dictStart, i)
        val dict = dictStr.split('|')

        // Unpack
        var result = code
        for (idx in count - 1 downTo 0) {
            if (idx < dict.size && dict[idx].isNotEmpty()) {
                val word = if (base <= 36) {
                    if (idx == 0) "0" else buildString {
                        var n = idx
                        val digits = "0123456789abcdefghijklmnopqrstuvwxyz".take(base)
                        while (n > 0) {
                            append(digits[n % base])
                            n /= base
                        }
                        reverse()
                    }
                } else idx.toString()
                result = result.replace(Regex("\\b${java.util.regex.Pattern.quote(word)}\\b"), dict[idx])
            }
        }
        return result
    }

    private fun decryptVidNestResponse(data: String): String {
        val alphabet = "RB0fpH8ZEyVLkv7c2i6MAJ5u3IKFDxlS1NTsnGaqmXYdUrtzjwObCgQP94hoeW+/="
        val std = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/="
        val translated = StringBuilder()
        for (c in data) {
            val idx = alphabet.indexOf(c)
            translated.append(if (idx >= 0) std[idx] else c)
        }
        return String(Base64.decode(translated.toString(), Base64.DEFAULT))
    }

    private fun httpGet(url: String, headers: Map<String, String> = emptyMap()): String {
        requireSafeOutboundUrl(url)
        val request = Request.Builder().url(url).apply {
            header("User-Agent", userAgent)
            header("Accept", "*/*")
            safeHeaders(headers).forEach { (name, value) -> header(name, value) }
        }.build()

        client.newCall(request).execute().use { response ->
            val body = response.body?.string().orEmpty()
            if (!response.isSuccessful) {
                throw IllegalStateException("HTTP ${response.code} from ${host(url)}")
            }
            return body
        }
    }

    private fun postJson(url: String, json: String, headers: Map<String, String> = emptyMap()): String {
        requireSafeOutboundUrl(url)
        val request = Request.Builder()
            .url(url)
            .header("User-Agent", userAgent)
            .header("Accept", "*/*")
            .apply { safeHeaders(headers).forEach { (name, value) -> header(name, value) } }
            .post(json.toRequestBody("application/json".toMediaType()))
            .build()
        client.newCall(request).execute().use { response ->
            val body = response.body?.string().orEmpty()
            if (!response.isSuccessful) throw IllegalStateException("HTTP ${response.code} from ${host(url)}")
            return body
        }
    }

    private fun postBody(url: String, body: okhttp3.RequestBody, headers: Map<String, String> = emptyMap()): String {
        requireSafeOutboundUrl(url)
        val request = Request.Builder()
            .url(url)
            .header("User-Agent", userAgent)
            .header("Accept", "*/*")
            .apply { safeHeaders(headers).forEach { (name, value) -> header(name, value) } }
            .post(body)
            .build()
        client.newCall(request).execute().use { response ->
            val responseBody = response.body?.string().orEmpty()
            if (!response.isSuccessful) throw IllegalStateException("HTTP ${response.code} from ${host(url)}")
            return responseBody
        }
    }

    private fun getJson(url: String, headers: Map<String, String> = emptyMap()) =
        JSONObject(httpGet(url, headers))

    private fun getJsonArray(url: String, headers: Map<String, String> = emptyMap()) =
        org.json.JSONArray(httpGet(url, headers))

    private fun httpGetFinalUrl(url: String, headers: Map<String, String> = emptyMap()): Pair<String, String> {
        requireSafeOutboundUrl(url)
        val request = Request.Builder().url(url).apply {
            header("User-Agent", userAgent)
            header("Accept", "*/*")
            safeHeaders(headers).forEach { (name, value) -> header(name, value) }
        }.build()
        client.newCall(request).execute().use { response ->
            val body = response.body?.string().orEmpty()
            if (!response.isSuccessful) throw IllegalStateException("HTTP ${response.code} from ${host(url)}")
            return response.request.url.toString() to body
        }
    }

    private fun unpackPackedScript(html: String, requiresM3u8: Boolean = false): String? {
        return Regex(
            """<script[^>]*>\s*(eval\(function\(p,a,c,k,e,[rd]\)[\s\S]*?)</script>""",
            setOf(RegexOption.DOT_MATCHES_ALL, RegexOption.IGNORE_CASE),
        ).findAll(html)
            .mapNotNull { JsUnpacker(it.groupValues[1]).unpack() }
            .firstOrNull { !requiresM3u8 || it.contains("m3u8", true) }
    }

    private fun parseRabbitSourcesResponse(
        response: JSONObject,
        referer: String,
        sourceName: String,
    ): Pair<String, List<SubtitleOption>> {
        val sourcesValue = response.opt("sources")
        return if (sourcesValue is String) {
            val key = getJson("https://keys4.fun")
                .optJSONObject("rabbitstream")
                ?.optJSONObject("keys")
                ?.optString("key")
                ?: throw IllegalStateException("Rabbitstream decryption key was not found")
            parseRabbitSourcesJson(sourcesValue, key, response.optJSONArray("tracks"), referer, sourceName)
        } else {
            parseRabbitSourcesJson(
                sourcesValue?.toString() ?: "[]",
                "",
                response.optJSONArray("tracks"),
                referer,
                sourceName,
            )
        }
    }

    private fun parseRabbitSourcesJson(
        sourcesValue: String,
        secret: String,
        tracks: JSONArray?,
        referer: String,
        sourceName: String,
    ): Pair<String, List<SubtitleOption>> {
        val sources = try {
            JSONArray(sourcesValue)
        } catch (e: Exception) {
            if (e is CancellationException) throw e
            JSONArray(decryptRabbitSources(sourcesValue, secret))
        }
        require(sources.length() > 0) { "Rabbitstream returned no sources" }
        val streamUrl = sources.optJSONObject(0).optString("file")
        require(streamUrl.isNotBlank()) { "Rabbitstream returned no source URL" }
        val subtitles = if (tracks == null) {
            emptyList()
        } else {
            (0 until tracks.length()).mapNotNull { index ->
                val track = tracks.optJSONObject(index) ?: return@mapNotNull null
                if (track.optString("kind") != "captions") return@mapNotNull null
                val url = track.optString("file")
                if (url.isBlank()) return@mapNotNull null
                SubtitleOption(track.optString("label", "Subtitle"), resolveUrl(referer, url), source = sourceName)
            }
        }
        return streamUrl to subtitles
    }

    private fun decryptRabbitSources(sources: String, secret: String): String {
        val cipherData = Base64.decode(sources, Base64.DEFAULT)
        require(cipherData.size > 16) { "Rabbitstream encrypted payload was incomplete" }
        val salt = cipherData.copyOfRange(8, 16)
        val derivedKey = rabbitKeyDerivation(salt, secret.toByteArray(Charsets.UTF_8))
        val cipher = Cipher.getInstance("AES/CBC/PKCS5Padding")
        cipher.init(
            Cipher.DECRYPT_MODE,
            SecretKeySpec(derivedKey.copyOfRange(0, 32), "AES"),
            IvParameterSpec(derivedKey.copyOfRange(32, derivedKey.size)),
        )
        return String(cipher.doFinal(cipherData.copyOfRange(16, cipherData.size)), Charsets.UTF_8)
    }

    private fun rabbitKeyDerivation(salt: ByteArray, secret: ByteArray): ByteArray {
        fun md5(input: ByteArray) = MessageDigest.getInstance("MD5").digest(input)
        var output = md5(secret + salt)
        var currentKey = output
        while (currentKey.size < 48) {
            output = md5(output + secret + salt)
            currentKey += output
        }
        return currentKey
    }

    private fun megacloudToken(html: String): String? {
        Regex("""\w+\s*=\s*\{[^}]*?(\w+):\s*"([^"]+)",\s*(\w+):\s*"([^"]+)"(?:,\s*(\w+):\s*"([^"]+)")?""")
            .find(html)?.let { match ->
                val val1 = match.groupValues[2]
                val val2 = match.groupValues[4]
                val val3 = match.groupValues.getOrNull(6)
                return val1 + val2 + (val3 ?: "")
            }

        Regex(""""([A-Za-z0-9+/=]{10,})",\s*"([A-Za-z0-9+/=]{10,})"(?:,\s*"([A-Za-z0-9+/=]{10,})")?""")
            .find(html)?.let { match ->
                val val1 = match.groupValues[1]
                val val2 = match.groupValues[2]
                val val3 = match.groupValues.getOrNull(3)
                return val1 + val2 + (val3 ?: "")
            }

        return Regex("""[A-Za-z0-9+/=]{30,}""").findAll(html)
            .map { it.value }
            .maxByOrNull { it.length }
    }

    private fun megacloudKeys(scheme: String, host: String): List<List<Int>> {
        val scriptUrl = "$scheme://$host/js/player/a/prod/e1-player.min.js?v=${System.currentTimeMillis() / 1000}"
        val script = httpGet(scriptUrl, refererHeaders("$scheme://$host/"))

        fun matchingKey(value: String): String {
            return Regex(",$value=((?:0x)?([0-9a-fA-F]+))").find(script)?.groupValues?.get(1)
                ?.removePrefix("0x")
                ?: throw IllegalStateException("Failed to match the Megacloud key")
        }

        return Regex("case\\s*0x[0-9a-f]+:(?![^;]*=partKey)\\s*\\w+\\s*=\\s*(\\w+)\\s*,\\s*\\w+\\s*=\\s*(\\w+);")
            .findAll(script).toList().map { match ->
                val matchKey1 = matchingKey(match.groupValues[1])
                val matchKey2 = matchingKey(match.groupValues[2])
                try {
                    listOf(matchKey1.toInt(16), matchKey2.toInt(16))
                } catch (_: NumberFormatException) {
                    emptyList()
                }
            }.filter { it.isNotEmpty() }
    }

    private fun megacloudExtractRealKey(sources: String, rawKeys: List<List<Int>>): Pair<String, String> {
        val sourcesArray = sources.toCharArray()
        var extractedKey = ""
        var currentIndex = 0
        for (index in rawKeys) {
            val start = index[0] + currentIndex
            val end = start + index[1]
            for (i in start until end) {
                extractedKey += sourcesArray[i].toString()
                sourcesArray[i] = ' '
            }
            currentIndex += index[1]
        }
        return extractedKey to sourcesArray.joinToString("").replace(" ", "")
    }

    private fun rc4DecodeData(key: String, data: ByteArray): ByteArray {
        val keyBytes = key.toByteArray(Charsets.UTF_8)
        val s = ByteArray(256) { it.toByte() }
        var j = 0
        for (i in 0 until 256) {
            j = (j + s[i].toInt() + keyBytes[i % keyBytes.size].toInt()) and 0xff
            s[i] = s[j].also { s[j] = s[i] }
        }
        val decoded = ByteArray(data.size)
        var i = 0
        var k = 0
        for (index in decoded.indices) {
            i = (i + 1) and 0xff
            k = (k + s[i].toInt()) and 0xff
            s[i] = s[k].also { s[k] = s[i] }
            val t = (s[i].toInt() + s[k].toInt()) and 0xff
            decoded[index] = (data[index] xor s[t])
        }
        return decoded
    }

    private fun rc4EncodeBase64(key: String, value: String): String {
        val decodedId = rc4DecodeData(key, value.toByteArray(Charsets.UTF_8))
        return Base64.encodeToString(decodedId, Base64.NO_WRAP)
            .replace("/", "_")
            .replace("+", "-")
    }

    private fun decryptVidplay(key: String, encrypted: String): String {
        val standardized = encrypted.replace('_', '/').replace('-', '+')
        val encoded = Base64.decode(standardized, Base64.NO_WRAP)
        val decoded = rc4DecodeData(key, encoded)
        return URLDecoder.decode(decoded.toString(Charsets.UTF_8), Charsets.UTF_8.name())
    }

    private fun followRedirect(url: String): String {
        requireSafeOutboundUrl(url)
        val request = Request.Builder().url(url).header("User-Agent", userAgent).build()
        noRedirectClient.newCall(request).execute().use { response ->
            return response.header("Location")?.let { resolveUrl(url, it).also(::requireSafeOutboundUrl) }
                ?: response.request.url.toString()
        }
    }

    private suspend fun validateStream(stream: StreamResult): StreamResult {
        requireSafeOutboundUrl(stream.url)
        val sanitizedStream = stream.copy(headers = safeHeaders(stream.headers))
        if (stream.type != "direct_m3u8" && !stream.url.contains(".m3u8", true)) {
            validateMediaRequest(sanitizedStream.url, sanitizedStream.headers)
            return sanitizedStream
        }

        val validation = validateHls(sanitizedStream.url, sanitizedStream.headers)
        return sanitizedStream.copy(
            url = validation.playbackUrl,
            qualities = validation.qualities,
            subtitles = (sanitizedStream.subtitles + validation.subtitles).distinctBy { it.url },
            audioTracks = (sanitizedStream.audioTracks + validation.audioTracks)
                .distinctBy { it.url.ifBlank { it.label } },
            separateAudio = validation.separateAudio,
        )
    }

    private data class HlsValidation(
        val playbackUrl: String,
        val qualities: List<QualityOption>,
        val subtitles: List<SubtitleOption>,
        val audioTracks: List<AudioOption> = emptyList(),
        val separateAudio: Boolean = false,
    )

    private data class HlsVariant(val url: String, val height: Int, val codec: String = "")

    private suspend fun validateHls(url: String, headers: Map<String, String>): HlsValidation {
        val master = getValidationResponse(url, headers)
        require(master.body.startsWith("#EXTM3U")) {
            "HLS endpoint did not return a playlist (${master.contentType})"
        }

        val variants = parseHlsVariants(master.url, master.body)
        val subtitles = parseHlsSubtitles(master.url, master.body)
        val audioTracks = parseHlsAudio(master.url, master.body)
        if (variants.isEmpty()) {
            validateMediaPlaylist(master.url, master.body, headers)
            return HlsValidation(master.url, emptyList(), subtitles, audioTracks)
        }

        // A playlist can remain reachable after its signed media segments expire.
        // Validate one segment from every variant so dead RPM/CDN routes never
        // reach ExoPlayer as an apparently working server.
        // Limit to 2 concurrent variant checks to prevent OOM on low-memory devices
        val variantSlots = Semaphore(2)
        val playableVariants = coroutineScope {
            variants.map { variant ->
                async(Dispatchers.IO) {
                    variantSlots.withPermit {
                        try {
                            val playlist = getValidationResponse(variant.url, headers)
                            require(playlist.body.startsWith("#EXTM3U")) {
                                "Variant ${variant.height}p is not a valid playlist"
                            }
                            validateMediaPlaylist(playlist.url, playlist.body, headers)
                            variant.copy(url = playlist.url)
                        } catch (error: Throwable) {
                            if (error is CancellationException) throw error
                            Log.w(tag, "Discarding ${variant.height}p HLS variant: ${error.message}")
                            null
                        }
                    }
                }
            }.awaitAll().filterNotNull()
        }.distinctBy { it.height }.sortedByDescending { it.height }

        require(playableVariants.isNotEmpty()) { "No playable HLS quality variants" }
        val qualities = buildList {
            add(QualityOption("Auto", master.url, 0))
            addAll(
                playableVariants.map {
                    QualityOption("${it.height}p", it.url, it.height, it.codec)
                },
            )
        }
        // Restore original behaviour: return the master URL when every
        // variant is reachable so ExoPlayer can do adaptive bitrate
        // selection.  Only pin to a single variant when some are dead
        // (forcing a known-good route) or when the master has separate
        // audio renditions that would be lost by pinning.
        val allPlayable = playableVariants.size == variants.distinctBy { it.height }.size
        val separateAudio = hasSeparateAudioGroups(master.body)
        val pinnedUrl = when {
            separateAudio -> master.url
            allPlayable -> master.url
            else -> playableVariants.minByOrNull { it.height }?.url ?: master.url
        }
        return HlsValidation(
            pinnedUrl,
            qualities,
            subtitles,
            audioTracks,
            separateAudio = separateAudio,
        )
    }

    private fun validateMediaPlaylist(
        playlistUrl: String,
        body: String,
        headers: Map<String, String>,
    ) {
        require(body.startsWith("#EXTM3U")) { "HLS quality did not return a playlist" }
        val mediaUri = body.lineSequence()
            .map(String::trim)
            .firstOrNull { it.isNotEmpty() && !it.startsWith('#') }
            ?: throw IllegalStateException("HLS quality contains no media URI")
        validateMediaRequest(resolveUrl(playlistUrl, mediaUri), headers)
    }

    private fun validateFirstHlsSegment(url: String, headers: Map<String, String>) {
        val master = getValidationResponse(url, headers)
        require(master.body.startsWith("#EXTM3U")) { "HLS endpoint did not return a playlist" }
        val firstVariant = parseHlsVariants(master.url, master.body).firstOrNull()
        if (firstVariant == null) {
            validateMediaPlaylist(master.url, master.body, headers)
            return
        }
        val media = getValidationResponse(firstVariant.url, headers)
        validateMediaPlaylist(media.url, media.body, headers)
    }

    private fun parseHlsVariants(masterUrl: String, body: String): List<HlsVariant> {
        val lines = body.lineSequence().map(String::trim).toList()
        return lines.mapIndexedNotNull { index, line ->
            if (!line.startsWith("#EXT-X-STREAM-INF", true)) return@mapIndexedNotNull null
            val height = Regex("""RESOLUTION=\d+x(\d+)""", RegexOption.IGNORE_CASE)
                .find(line)?.groupValues?.getOrNull(1)?.toIntOrNull() ?: return@mapIndexedNotNull null
            val uri = lines.drop(index + 1).firstOrNull { it.isNotEmpty() && !it.startsWith('#') }
                ?: return@mapIndexedNotNull null
            HlsVariant(resolveUrl(masterUrl, uri), height, hlsCodec(line))
        }
    }

    /**
     * Reduces the variant's CODECS attribute (e.g. "avc1.640028,mp4a.40.2") to
     * a family token so the TV player can prefer a codec the box's hardware is
     * known to decode stably (H.264/AVC) instead of blindly pinning the tallest
     * HEVC/AV1 variant, whose firmware decoders are a common native-crash source.
     */
    private fun hlsCodec(streamInfLine: String): String {
        val codecs = Regex("""CODECS="([^"]*)"""", RegexOption.IGNORE_CASE)
            .find(streamInfLine)?.groupValues?.getOrNull(1)?.lowercase(Locale.US) ?: return ""
        return when {
            codecs.contains("avc") -> "h264"
            codecs.contains("hev1") || codecs.contains("hvc1") -> "hevc"
            codecs.contains("av01") -> "av1"
            codecs.contains("vp9") -> "vp9"
            else -> ""
        }
    }

    private fun parseHlsSubtitles(masterUrl: String, body: String): List<SubtitleOption> {
        fun attribute(line: String, name: String): String? {
            val match = Regex("""(?:^|,)$name=(?:"([^"]*)"|([^,]*))""", RegexOption.IGNORE_CASE)
                .find(line) ?: return null
            return match.groupValues[1].ifBlank { match.groupValues[2] }.ifBlank { null }
        }

        return body.lineSequence().mapNotNull { line ->
            if (!line.startsWith("#EXT-X-MEDIA", true) ||
                !line.contains("TYPE=SUBTITLES", true)) return@mapNotNull null
            val uri = attribute(line, "URI") ?: return@mapNotNull null
            val label = attribute(line, "NAME") ?: attribute(line, "LANGUAGE") ?: "Subtitle"
            SubtitleOption(
                label,
                resolveUrl(masterUrl, uri),
                attribute(line, "DEFAULT").equals("YES", true),
                source = "HLS",
            )
        }.distinctBy { it.url }.toList()
    }

    /** Fills HLS audio renditions for streams whose extractor skipped validateHls. */
    private suspend fun enrichHlsAudioTracks(stream: StreamResult): StreamResult {
        if (stream.audioTracks.isNotEmpty()) return stream
        if (stream.type != "direct_m3u8" && !stream.url.contains(".m3u8", true)) {
            return stream
        }
        return try {
            val master = getValidationResponse(stream.url, safeHeaders(stream.headers))
            if (!master.body.startsWith("#EXTM3U")) return stream
            stream.copy(
                audioTracks = parseHlsAudio(master.url, master.body),
                subtitles = if (stream.subtitles.isEmpty()) {
                    parseHlsSubtitles(master.url, master.body)
                } else {
                    stream.subtitles
                },
            )
        } catch (error: Throwable) {
            if (error is CancellationException) throw error
            stream
        }
    }

    /**
     * Parses `#EXT-X-MEDIA:TYPE=AUDIO` renditions (multi-language audio) from
     * an HLS master playlist. Dialects vary: some hosts set LANGUAGE only,
     * some NAME only, some neither (single default track).
     */
    private fun parseHlsAudio(masterUrl: String, body: String): List<AudioOption> {
        fun attribute(line: String, name: String): String? {
            val match = Regex("""(?:^|,)$name=(?:"([^"]*)"|([^,]*))""", RegexOption.IGNORE_CASE)
                .find(line) ?: return null
            return match.groupValues[1].ifBlank { match.groupValues[2] }.ifBlank { null }
        }

        return body.lineSequence().mapNotNull { line ->
            if (!line.startsWith("#EXT-X-MEDIA", true) ||
                !line.contains("TYPE=AUDIO", true)) return@mapNotNull null
            val language = attribute(line, "LANGUAGE")
                ?: attribute(line, "NAME")
                ?: "und"
            val label = attribute(line, "NAME")
                ?: attribute(line, "LANGUAGE")
                ?: "Audio"
            val uri = attribute(line, "URI")
            AudioOption(
                label,
                language,
                uri?.let { resolveUrl(masterUrl, it) } ?: "",
                attribute(line, "GROUP-ID") ?: "",
                attribute(line, "DEFAULT").equals("YES", true),
                attribute(line, "CHANNELS") ?: "",
                source = "HLS",
            )
        }.distinctBy { it.url.ifBlank { it.label + it.language } }.toList()
    }

    /**
     * Returns `true` when the HLS master playlist declares at least one
     * `#EXT-X-MEDIA:TYPE=AUDIO` entry with a URI, meaning audio is served
     * on a separate rendition.  In this case pinning to a single video
     * variant strips audio from playback because ExoPlayer never sees the
     * audio groups defined in the master.
     */
    private fun hasSeparateAudioGroups(body: String): Boolean =
        body.lineSequence().any { line ->
            line.startsWith("#EXT-X-MEDIA", true) &&
                line.contains("TYPE=AUDIO", true) &&
                Regex("""URI="[^"]+"""", RegexOption.IGNORE_CASE).containsMatchIn(line)
        }

    private data class ValidationResponse(
        val url: String,
        val body: String,
        val contentType: String,
    )

    private fun getValidationResponse(url: String, headers: Map<String, String>): ValidationResponse {
        requireSafeOutboundUrl(url)
        val request = Request.Builder().url(url).apply {
            header("User-Agent", userAgent)
            safeHeaders(headers).forEach { (name, value) -> header(name, value) }
        }.build()
        client.newCall(request).execute().use { response ->
            val body = response.body?.string().orEmpty()
            require(response.isSuccessful) { "HTTP ${response.code} while validating stream" }
            return ValidationResponse(
                response.request.url.toString(),
                body,
                response.header("Content-Type").orEmpty(),
            )
        }
    }

    private fun validateMediaRequest(url: String, headers: Map<String, String>) {
        requireSafeOutboundUrl(url)
        val request = Request.Builder().url(url).apply {
            header("User-Agent", userAgent)
            header("Range", "bytes=0-1023")
            safeHeaders(headers).forEach { (name, value) -> header(name, value) }
        }.build()
        client.newCall(request).execute().use { response ->
            require(response.isSuccessful) { "HTTP ${response.code} while validating media data" }
            require((response.body?.contentLength() ?: 0L) != 0L) { "Media response was empty" }
        }
    }

    private fun refererHeaders(referer: String) = mapOf(
        "Referer" to referer,
        "User-Agent" to userAgent,
    )

    private fun communityHeaders(referer: String) = refererHeaders(referer) + mapOf(
        "Accept-Language" to "en-US,en;q=0.9",
        "Cookie" to "language=en",
        "X-Requested-With" to "XMLHttpRequest",
    )

    private fun safeHeaders(headers: Map<String, String>): Map<String, String> {
        val allowed = setOf(
            "user-agent", "referer", "origin", "cookie", "accept", "accept-language",
            "range", "if-range", "x-requested-with",
        )
        return headers.filter { (name, value) ->
            require(!name.contains('\r') && !name.contains('\n') &&
                !value.contains('\r') && !value.contains('\n')) { "Invalid outbound header" }
            name.lowercase() in allowed
        }
    }

    private fun requireSafeOutboundUrl(url: String) {
        val uri = try {
            URI(url.substringBefore('#'))
        } catch (_: Exception) {
            throw IllegalArgumentException("Invalid outbound URL")
        }
        require(uri.scheme.equals("http", true) || uri.scheme.equals("https", true)) {
            "Only HTTP(S) outbound URLs are allowed"
        }
        require(uri.rawUserInfo == null) { "Outbound URL credentials are not allowed" }
        val hostname = uri.host?.lowercase().orEmpty()
        require(hostname.isNotBlank()) { "Outbound URL hostname is required" }
        require(hostname != "localhost" && !hostname.endsWith(".localhost")) {
            "Localhost outbound URLs are not allowed"
        }

        val isIpv4Literal = hostname.matches(Regex("""\d{1,3}(?:\.\d{1,3}){3}"""))
        val isIpv6Literal = hostname.contains(':')
        if (isIpv4Literal || isIpv6Literal) {
            val address = runCatching { InetAddress.getByName(hostname) }
                .getOrElse { throw IllegalArgumentException("Invalid IP literal") }
            val bytes = address.address
            val uniqueLocalV6 = bytes.size == 16 && (bytes[0].toInt() and 0xfe) == 0xfc
            require(!address.isAnyLocalAddress && !address.isLoopbackAddress &&
                !address.isLinkLocalAddress && !address.isSiteLocalAddress && !uniqueLocalV6) {
                "Non-public IP literals are not allowed"
            }
        }
    }

    private fun normalizeTitle(value: String) = value.lowercase().filter(Char::isLetterOrDigit)

    private fun host(url: String): String = try {
        URI(url.substringBefore('#')).host?.lowercase().orEmpty()
    } catch (_: Exception) {
        ""
    }

    private fun resolveUrl(base: String, value: String): String = URI(base).resolve(value).toString()

    private fun encode(value: String) = URLEncoder.encode(value, Charsets.UTF_8.name())
    private fun isMediaUrl(url: String) = url.contains(".m3u8", true) || url.contains(".mp4", true)
    private fun mediaType(url: String) = if (url.contains(".m3u8", true)) "direct_m3u8" else "direct_video"

    private fun hexToBytes(hex: String): ByteArray {
        val normalized = hex.removePrefix("0x").trim()
        require(normalized.length % 2 == 0) { "Invalid hex string" }
        return ByteArray(normalized.length / 2) { index ->
            normalized.substring(index * 2, index * 2 + 2).toInt(16).toByte()
        }
    }

    private fun aesCbcEncrypt(value: String, passphrase: String): String {
        val key = passphrase.toByteArray()
        val cipher = Cipher.getInstance("AES/CBC/PKCS5Padding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), IvParameterSpec(key.copyOfRange(0, 16)))
        return Base64.encodeToString(
            cipher.doFinal(value.toByteArray()),
            Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING,
        )
    }

    private fun between(value: String, before: String, after: String): String? {
        val start = value.indexOf(before)
        if (start < 0) return null
        val contentStart = start + before.length
        val end = value.indexOf(after, contentStart)
        return if (end < 0) null else value.substring(contentStart, end).trim()
    }

    /// Extracts the balanced JSON object assigned to `const <name> = {...};`
    /// from embedded JavaScript. A naive non-greedy regex truncates the object
    /// at the first `};`, which breaks pages whose CONFIG contains nested
    /// objects (e.g. Mov2Day player configs).
    private fun extractJsObject(html: String, name: String): String? {
        val match = Regex(
            """const\s+$name\s*=\s*\{""",
            setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL),
        ).find(html) ?: return null
        var depth = 0
        var inString = false
        var escaped = false
        for (index in match.range.last + 1 until html.length) {
            val char = html[index]
            if (inString) {
                when {
                    escaped -> escaped = false
                    char == '\\' -> escaped = true
                    char == '"' -> inString = false
                }
                continue
            }
            when (char) {
                '"' -> inString = true
                '{' -> depth++
                '}' -> {
                    depth--
                    if (depth == 0) return html.substring(match.range.last, index + 1)
                }
            }
        }
        return null
    }

    private fun decryptVoe(value: String): JSONObject {
        var data = rot13(value)
        listOf("@$", "^^", "~@", "%?", "*~", "!!", "#&").forEach { data = data.replace(it, "_") }
        data = String(Base64.decode(data.replace("_", ""), Base64.NO_WRAP), Charsets.UTF_8)
        data = data.map { (it.code + 3).toChar() }.joinToString("").reversed()
        data = String(Base64.decode(data, Base64.NO_WRAP), Charsets.UTF_8)
        return JSONObject(data)
    }

    private fun rot13(value: String) = value.map { character ->
        when (character) {
            in 'A'..'Z' -> ((character - 'A' + 13) % 26 + 'A'.code).toChar()
            in 'a'..'z' -> ((character - 'a' + 13) % 26 + 'a'.code).toChar()
            else -> character
        }
    }.joinToString("")

    private inner class JsUnpacker(private val packedJS: String?) {
        fun unpack(): String? {
            val js = packedJS ?: return null
            try {
                val pattern = Regex(
                    """\}\s*\('(.*)',\s*(.*?),\s*(\d+),\s*'(.*?)'\.split\('\|'\)""",
                    RegexOption.DOT_MATCHES_ALL,
                )
                val match = pattern.find(js) ?: return null
                if (match.groupValues.size < 5) return null
                val payload = match.groupValues[1].replace("\\'", "'")
                val radix = match.groupValues[2].toIntOrNull() ?: 36
                val count = match.groupValues[3].toIntOrNull() ?: 0
                val symtab = match.groupValues[4].split("|")
                if (symtab.size != count) return null
                val unbase = Unbase(radix)
                val wordPattern = Regex("""\b\w+\b""")
                val decoded = StringBuilder(payload)
                var replaceOffset = 0
                for (wordMatch in wordPattern.findAll(payload)) {
                    val word = wordMatch.value
                    val x = try {
                        unbase.unbase(word)
                    } catch (_: Exception) {
                        break
                    }
                    val value = if (x in symtab.indices) symtab[x] else null
                    if (value != null && value.isNotEmpty()) {
                        decoded.replace(
                            wordMatch.range.first + replaceOffset,
                            wordMatch.range.last + 1 + replaceOffset,
                            value,
                        )
                        replaceOffset += value.length - word.length
                    }
                }
                return decoded.toString()
            } catch (_: Exception) {
                return null
            }
        }

        private inner class Unbase(private val radix: Int) {
            private val alphabet62 = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
            private val alphabet95 =
                " !\"#$%&\\'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\\\]^_`abcdefghijklmnopqrstuvwxyz{|}~"
            private val alphabet: String? = when {
                radix > 36 && radix < 62 -> alphabet62.substring(0, radix)
                radix > 36 && radix in 63..94 -> alphabet95.substring(0, radix)
                radix == 62 -> alphabet62
                radix == 95 -> alphabet95
                else -> null
            }
            private val dictionary: HashMap<String, Int>? = alphabet?.let { alpha ->
                HashMap<String, Int>(alpha.length).apply {
                    for (i in alpha.indices) this[alpha.substring(i, i + 1)] = i
                }
            }

            fun unbase(str: String): Int {
                if (alphabet == null) return str.toInt(radix)
                val tmp = StringBuilder(str).reverse().toString()
                var ret = 0
                for (i in tmp.indices) {
                    ret += (Math.pow(radix.toDouble(), i.toDouble()) *
                        (dictionary!![tmp.substring(i, i + 1)] ?: 0)).toInt()
                }
                return ret
            }
        }
    }
}
