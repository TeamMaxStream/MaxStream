package com.maxstream.app.download

import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.FileOutputStream
import java.io.IOException
import java.net.URI
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.util.concurrent.TimeUnit

/** Thrown to unwind a transfer while keeping its partial directory. */
class DownloadPausedException : Exception("Paused")

/** Thrown when the user cancels; the caller deletes the directory. */
class DownloadCancelledException : Exception("Cancelled")

/** Per-transfer pause/cancel flags read from another thread. */
class DownloadControl {
    @Volatile var paused: Boolean = false
    @Volatile var cancelled: Boolean = false

    fun check() {
        if (cancelled) throw DownloadCancelledException()
        if (paused) throw DownloadPausedException()
    }
}

data class DownloadResult(
    val path: String,
    val isHls: Boolean,
    val bytes: Long,
)

/**
 * Downloads HLS playlists and direct files without any extra dependency.
 *
 * HLS is handled the same way the mobile downloader does it: every segment,
 * key and init map is fetched once and the playlist is rewritten to relative
 * local filenames. mpv then plays the local `playlist.m3u8` — including
 * AES-128 encrypted titles — with no network access. No remuxing is needed.
 */
object MediaDownloader {

    private const val MAX_PLAYLIST_BYTES = 8L * 1024 * 1024
    private const val MAX_HLS_RESOURCES = 6_000
    private const val MAX_RESOURCE_BYTES = 2L * 1024 * 1024 * 1024

    private val http = OkHttpClient.Builder()
        .connectTimeout(20, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .writeTimeout(60, TimeUnit.SECONDS)
        .followRedirects(true)
        .followSslRedirects(true)
        .build()

    fun download(
        directory: Path,
        url: String,
        headers: Map<String, String>,
        hlsHint: Boolean?,
        maxVariantHeight: Int,
        control: DownloadControl,
        onProgress: (downloaded: Long, total: Long?, fraction: Float) -> Unit,
    ): DownloadResult {
        Files.createDirectories(directory)
        val uri = URI(url.trim())
        requireRemote(uri)
        val isHls = hlsHint ?: sniffHls(uri, headers, control)
        return if (isHls) {
            val path = downloadHls(directory, uri, headers, maxVariantHeight, control, onProgress)
            DownloadResult(path.toString(), true, directorySize(directory))
        } else {
            val path = downloadDirect(directory, uri, headers, control, onProgress)
            DownloadResult(path.toString(), false, Files.size(path))
        }
    }

    // ── direct MP4/WebM/extension-less files ─────────────────────────────────

    private fun downloadDirect(
        directory: Path,
        uri: URI,
        headers: Map<String, String>,
        control: DownloadControl,
        onProgress: (Long, Long?, Float) -> Unit,
    ): Path {
        val extension = extensionOf(uri).takeIf { it.isNotBlank() } ?: ".mp4"
        val output = directory.resolve("video$extension")
        val part = directory.resolve("video$extension.part")
        val done = directory.resolve("video$extension.done")
        if (Files.exists(output) && Files.exists(done)) return output

        var existing = if (Files.exists(part)) Files.size(part) else 0L
        val request = baseRequest(uri, headers)
            .apply { if (existing > 0L) header("Range", "bytes=$existing-") }
            .build()

        http.newCall(request).execute().use { response ->
            if (!response.isSuccessful) throw IOException("HTTP ${response.code} while downloading video")
            val body = response.body ?: throw IOException("Empty response body")
            val append = response.code == 206 && existing > 0L
            if (!append) {
                existing = 0L
                Files.deleteIfExists(part)
            }
            val contentLength = body.contentLength().takeIf { it > 0L }
            val total = contentLength?.let { it + existing }
            var received = existing
            onProgress(received, total, if (total != null && total > 0) received.toFloat() / total else 0f)

            body.byteStream().use { input ->
                FileOutputStream(part.toFile(), append).use { outputStream ->
                    val buffer = ByteArray(128 * 1024)
                    while (true) {
                        control.check()
                        val read = input.read(buffer)
                        if (read < 0) break
                        outputStream.write(buffer, 0, read)
                        received += read
                        onProgress(
                            received,
                            total,
                            if (total != null && total > 0) (received.toFloat() / total).coerceIn(0f, 1f) else 0f,
                        )
                    }
                    outputStream.flush()
                }
            }
        }
        Files.move(part, output, StandardCopyOption.REPLACE_EXISTING)
        Files.writeString(done, "ok")
        return output
    }

    /** Reads the first 2 KB to tell a playlist from a video (VixSrc has no extension). */
    private fun sniffHls(uri: URI, headers: Map<String, String>, control: DownloadControl): Boolean {
        control.check()
        val request = baseRequest(uri, headers)
            .header("Range", "bytes=0-2047")
            .build()
        http.newCall(request).execute().use { response ->
            if (!response.isSuccessful) throw IOException("HTTP ${response.code} while inspecting stream")
            val bytes = response.body?.source()?.let { source ->
                val buffer = ByteArray(2048)
                val count = source.read(buffer)
                if (count <= 0) ByteArray(0) else buffer.copyOf(count)
            } ?: ByteArray(0)
            val text = String(bytes, Charsets.UTF_8)
            if (text.startsWith("#EXTM3U")) return true
            if (text.contains("<MPD") || text.contains("<mpd")) {
                throw UnsupportedOperationException("DASH downloads are not supported yet — pick an HLS or direct source")
            }
            return false
        }
    }

    // ── HLS ──────────────────────────────────────────────────────────────────

    private fun downloadHls(
        directory: Path,
        initialUri: URI,
        headers: Map<String, String>,
        maxHeight: Int,
        control: DownloadControl,
        onProgress: (Long, Long?, Float) -> Unit,
    ): Path {
        val playlistMarker = directory.resolve("playlist.done")
        val playlistFile = directory.resolve("playlist.m3u8")
        if (Files.exists(playlistFile) && Files.exists(playlistMarker)) return playlistFile

        var playlistUri = initialUri
        var playlist = getText(playlistUri, headers, control)
        validateEncryption(playlist)

        val names = LinkedHashMap<URI, String>()
        var resourceIndex = 0
        val byteResources = LinkedHashSet<URI>()

        fun localName(uri: URI): String {
            requireRemote(uri)
            return names.getOrPut(uri) {
                val extension = extensionOf(uri).takeIf { it.isNotBlank() } ?: ".bin"
                "resource_${resourceIndex++}$extension"
            }
        }

        val sourceFile = directory.resolve("source.txt")
        val source = playlistUri.toString().substringBefore('?').substringBefore('#')
        if (Files.exists(sourceFile) && Files.readString(sourceFile) != source) {
            // The provider handed us a different playlist for the same episode —
            // keep thumbnails/user files out of it and start the media over.
            Files.list(directory).use { stream ->
                stream.filter {
                    val n = it.fileName.toString()
                    n.startsWith("resource_") || n.startsWith("playlist")
                }.forEach { Files.deleteIfExists(it) }
            }
        }
        Files.createDirectories(directory)
        Files.writeString(sourceFile, source)

        val rewrittenPlaylists = LinkedHashMap<String, String>()

        if (playlist.contains("#EXT-X-STREAM-INF")) {
            val variants = parseVariants(playlist)
            if (variants.isEmpty()) throw IOException("HLS master has no variants")
            val chosen = chooseVariant(variants, maxHeight)
            val mediaGroups = parseMediaGroups(playlist, playlistUri)
            val audioGroup = attribute(playlist.lines().firstOrNull { it.startsWith("#EXT-X-STREAM-INF") }.orEmpty(), "AUDIO")

            val chosenUri = playlistUri.resolve(chosen.uri)
            val playlistUris = listOf(chosenUri) + mediaGroups
            val seenPlaylists = LinkedHashSet<URI>()
            for (mediaUri in playlistUris) {
                control.check()
                if (!seenPlaylists.add(mediaUri)) continue
                val mediaText = getText(mediaUri, headers, control)
                validateEncryption(mediaText)
                if (mediaText.contains("#EXT-X-STREAM-INF")) {
                    throw IOException("Unexpected nested HLS master playlist")
                }
                if (!mediaText.contains("#EXT-X-ENDLIST")) {
                    throw IOException("This HLS stream is still live and cannot be downloaded yet")
                }
                if (!hasMediaSegment(mediaText)) throw IOException("HLS playlist contains no media segments")
                val local = localName(mediaUri)
                rewrittenPlaylists[local] = rewriteMediaPlaylist(mediaText, mediaUri, ::localName, byteResources)
            }

            // Build a local master that references only the selected video
            // variant plus the audio/subtitle renditions we actually fetched.
            val master = StringBuilder()
            playlist.lines().forEach { line ->
                val trimmed = line.trim()
                if (!trimmed.startsWith("#")) return@forEach
                if (trimmed.startsWith("#EXT-X-STREAM-INF") ||
                    trimmed.startsWith("#EXT-X-I-FRAME-STREAM-INF")
                ) return@forEach
                if (trimmed.startsWith("#EXT-X-MEDIA")) {
                    val raw = attribute(trimmed, "URI")
                    val resolved = raw?.let { runCatching { playlistUri.resolve(it) }.getOrNull() }
                    if (resolved == null || !seenPlaylists.contains(resolved)) return@forEach
                    master.append(rewriteUriAttribute(trimmed, playlistUri, ::localName)).append('\n')
                    return@forEach
                }
                master.append(line).append('\n')
            }
            master.append("#EXT-X-STREAM-INF:BANDWIDTH=${chosen.bandwidth},RESOLUTION=${chosen.width}x${chosen.height}")
            if (!audioGroup.isNullOrBlank()) master.append(",AUDIO=\"").append(audioGroup).append('"')
            master.append('\n')
            master.append(localName(chosenUri)).append('\n')
            rewrittenPlaylists["playlist.m3u8"] = master.toString()
        } else {
            if (!playlist.contains("#EXT-X-ENDLIST")) {
                throw IOException("This HLS stream is still live and cannot be downloaded yet")
            }
            if (!hasMediaSegment(playlist)) throw IOException("HLS playlist contains no media segments")
            rewrittenPlaylists["playlist.m3u8"] =
                rewriteMediaPlaylist(playlist, playlistUri, ::localName, byteResources)
        }

        if (byteResources.size > MAX_HLS_RESOURCES) {
            throw IOException("HLS playlist references too many files (${byteResources.size})")
        }

        var done = 0
        var downloaded = 0L
        val resources = byteResources.toList()
        for (uri in resources) {
            control.check()
            val fileName = names[uri] ?: localName(uri)
            val target = directory.resolve(fileName)
            val marker = directory.resolve("$fileName.done")
            if (Files.exists(target) && Files.exists(marker) && Files.size(target) > 0L) {
                downloaded += Files.size(target)
                done++
                onProgress(downloaded, null, if (resources.isEmpty()) 1f else done.toFloat() / resources.size)
                continue
            }
            val partial = directory.resolve("$fileName.part")
            Files.deleteIfExists(partial)
            downloadResource(uri, partial, headers, control)
            Files.move(partial, target, StandardCopyOption.REPLACE_EXISTING)
            Files.writeString(marker, "ok")
            downloaded += Files.size(target)
            done++
            onProgress(downloaded, null, if (resources.isEmpty()) 1f else done.toFloat() / resources.size)
        }

        // Write playlists only after every referenced file exists: a crash
        // midway therefore resumes instead of exposing a half-empty playlist.
        rewrittenPlaylists.forEach { (name, text) ->
            Files.writeString(directory.resolve(name), text)
        }
        Files.writeString(playlistMarker, "ok")
        return playlistFile
    }

    private fun downloadResource(
        uri: URI,
        target: Path,
        headers: Map<String, String>,
        control: DownloadControl,
    ) {
        control.check()
        http.newCall(baseRequest(uri, headers).build()).execute().use { response ->
            if (!response.isSuccessful) throw IOException("HTTP ${response.code} while downloading HLS resource")
            val body = response.body ?: throw IOException("Empty HLS resource")
            if (body.contentLength() > MAX_RESOURCE_BYTES) throw IOException("HLS resource too large")
            var received = 0L
            body.byteStream().use { input ->
                FileOutputStream(target.toFile()).use { output ->
                    val buffer = ByteArray(128 * 1024)
                    while (true) {
                        control.check()
                        val read = input.read(buffer)
                        if (read < 0) break
                        output.write(buffer, 0, read)
                        received += read
                        if (received > MAX_RESOURCE_BYTES) throw IOException("HLS resource too large")
                    }
                    output.flush()
                }
            }
            if (received <= 0L) throw IOException("HLS resource was empty")
        }
    }

    private fun rewriteMediaPlaylist(
        playlist: String,
        base: URI,
        localName: (URI) -> String,
        resources: MutableSet<URI>,
    ): String {
        val out = StringBuilder()
        playlist.lineSequence().forEach { line ->
            val trimmed = line.trim()
            when {
                trimmed.startsWith("#EXT-X-KEY") || trimmed.startsWith("#EXT-X-SESSION-KEY") -> {
                    val method = attribute(trimmed, "METHOD")?.uppercase()
                    if (method != null && method != "NONE" && method != "AES-128") {
                        throw UnsupportedOperationException("Unsupported encrypted HLS method: $method")
                    }
                    val keyFormat = attribute(trimmed, "KEYFORMAT")
                    if (!keyFormat.isNullOrBlank() && !keyFormat.equals("identity", ignoreCase = true)) {
                        throw UnsupportedOperationException("DRM HLS key formats are not supported")
                    }
                    out.append(rewriteUriAttribute(trimmed, base, localName, resources)).append('\n')
                }
                trimmed.startsWith("#EXT-X-MAP") ->
                    out.append(rewriteUriAttribute(trimmed, base, localName, resources)).append('\n')
                trimmed.isNotEmpty() && !trimmed.startsWith("#") -> {
                    val uri = base.resolve(trimmed.replace(" ", "%20"))
                    resources.add(uri)
                    out.append(localName(uri)).append('\n')
                }
                else -> out.append(line).append('\n')
            }
        }
        return out.toString()
    }

    private fun rewriteUriAttribute(
        line: String,
        base: URI,
        localName: (URI) -> String,
        resources: MutableSet<URI>? = null,
    ): String {
        val raw = attribute(line, "URI") ?: return line
        val uri = runCatching { base.resolve(raw.replace(" ", "%20")) }.getOrNull() ?: return line
        resources?.add(uri)
        val replacement = "URI=\"${localName(uri)}\""
        val regex = Regex("(?i)URI\\s*=\\s*(\"([^\"]*)\"|([^,]+))")
        return regex.replaceFirst(line, replacement)
    }

    private fun validateEncryption(playlist: String) {
        playlist.lineSequence().forEach { line ->
            val trimmed = line.trim()
            if (!trimmed.startsWith("#EXT-X-KEY") && !trimmed.startsWith("#EXT-X-SESSION-KEY")) return@forEach
            val method = attribute(trimmed, "METHOD")?.uppercase()
            if (method != null && method != "NONE" && method != "AES-128") {
                throw UnsupportedOperationException("Unsupported encrypted HLS method: $method")
            }
            val keyFormat = attribute(trimmed, "KEYFORMAT")
            if (!keyFormat.isNullOrBlank() && !keyFormat.equals("identity", ignoreCase = true)) {
                throw UnsupportedOperationException("DRM HLS key formats are not supported")
            }
        }
    }

    private data class Variant(val uri: String, val width: Int, val height: Int, val bandwidth: Int)

    private fun parseVariants(playlist: String): List<Variant> {
        val lines = playlist.lines()
        val out = mutableListOf<Variant>()
        for (index in lines.indices) {
            val line = lines[index].trim()
            if (!line.startsWith("#EXT-X-STREAM-INF")) continue
            var next = index + 1
            while (next < lines.size && (lines[next].trim().isEmpty() || lines[next].trim().startsWith("#"))) next++
            if (next >= lines.size) continue
            val resolution = attribute(line, "RESOLUTION")?.split('x')
            out += Variant(
                uri = lines[next].trim(),
                width = resolution?.getOrNull(0)?.toIntOrNull() ?: 0,
                height = resolution?.getOrNull(1)?.toIntOrNull() ?: 0,
                bandwidth = attribute(line, "BANDWIDTH")?.toIntOrNull() ?: 0,
            )
        }
        return out
    }

    private fun chooseVariant(variants: List<Variant>, maxHeight: Int): Variant {
        val sized = variants.filter { it.height > 0 }
        val pool = sized.ifEmpty { variants }
        if (maxHeight > 0) {
            val fitting = pool.filter { it.height in 1..maxHeight }
            if (fitting.isNotEmpty()) return fitting.maxBy { it.height }
            return pool.minBy { if (it.height > 0) it.height else Int.MAX_VALUE }
        }
        return pool.maxBy { it.height * 10_000L + it.bandwidth }
    }

    private fun parseMediaGroups(playlist: String, base: URI): List<URI> {
        val out = LinkedHashSet<URI>()
        playlist.lineSequence().forEach { line ->
            val trimmed = line.trim()
            if (!trimmed.startsWith("#EXT-X-MEDIA")) return@forEach
            val type = attribute(trimmed, "TYPE")?.lowercase()
            if (type != null && type != "audio" && type != "subtitles") return@forEach
            val raw = attribute(trimmed, "URI") ?: return@forEach
            runCatching { base.resolve(raw.replace(" ", "%20")) }.getOrNull()?.let(out::add)
        }
        return out.toList()
    }

    private fun hasMediaSegment(playlist: String): Boolean =
        playlist.lineSequence().any { it.trim().isNotEmpty() && !it.trim().startsWith("#") }

    // ── HTTP helpers ─────────────────────────────────────────────────────────

    private fun getText(uri: URI, headers: Map<String, String>, control: DownloadControl): String {
        control.check()
        http.newCall(baseRequest(uri, headers).build()).execute().use { response ->
            if (!response.isSuccessful) throw IOException("HTTP ${response.code} while fetching HLS playlist")
            val body = response.body ?: throw IOException("Empty HLS playlist")
            if (body.contentLength() > MAX_PLAYLIST_BYTES) throw IOException("HLS playlist too large")
            val text = body.string()
            if (text.length > MAX_PLAYLIST_BYTES) throw IOException("HLS playlist too large")
            return text
        }
    }

    private fun baseRequest(uri: URI, headers: Map<String, String>): Request.Builder {
        requireRemote(uri)
        val builder = Request.Builder().url(uri.toURL())
        // Identity encoding keeps Content-Length and encrypted segment bytes
        // exactly what the server intended.
        builder.header("Accept-Encoding", "identity")
        headers.forEach { (key, value) ->
            if (key.equals("Range", true) || key.equals("Host", true) || key.equals("Content-Length", true)) return@forEach
            if (value.isNotBlank()) builder.header(key, value)
        }
        if (headers.keys.none { it.equals("User-Agent", true) }) {
            builder.header(
                "User-Agent",
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
                    "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
            )
        }
        return builder
    }

    private fun requireRemote(uri: URI) {
        if (uri.scheme != "http" && uri.scheme != "https") {
            throw IOException("Unsafe media URL: $uri")
        }
    }

    private fun extensionOf(uri: URI): String {
        val path = uri.path.orEmpty()
        val raw = path.substringAfterLast('.', "")
        if (raw.isEmpty() || raw.length > 5) return ""
        val safe = raw.filter { it.isLetterOrDigit() }.take(5)
        return if (safe.length == raw.length && safe.isNotEmpty()) ".$safe" else ""
    }

    private fun directorySize(dir: Path): Long = runCatching {
        Files.walk(dir).use { stream ->
            stream.filter { Files.isRegularFile(it) }.mapToLong { Files.size(it) }.sum()
        }
    }.getOrDefault(0L)

    private val attributeRegex = Regex(
        "(?i)(?:^|[,:])\\s*([A-Z0-9-]+)\\s*=\\s*(\"([^\"]*)\"|([^,]*))",
    )

    /** Case-insensitive `NAME=value` / `NAME="value"` attribute lookup. */
    private fun attribute(line: String, name: String): String? {
        attributeRegex.findAll(line).forEach { match ->
            if (match.groupValues[1].equals(name, ignoreCase = true)) {
                val quoted = match.groupValues[3]
                val bare = match.groupValues[4].trim()
                return if (quoted.isNotEmpty()) quoted else bare
            }
        }
        return null
    }
}
