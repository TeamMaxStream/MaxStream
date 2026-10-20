package com.maxstream.app.download

import com.maxstream.app.core.AtomicFiles
import com.maxstream.app.data.model.PlayRequest
import org.json.JSONArray
import org.json.JSONObject
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths

enum class DownloadStatus { QUEUED, DOWNLOADING, PAUSED, COMPLETED, FAILED }

/**
 * One queued/offline title. Movies use S1/E1; episodes key by season/episode
 * so a series can hold many rows without colliding.
 */
data class DownloadItem(
    val id: String,
    val request: PlayRequest,
    val subtitleLabel: String?,
    val server: String,
    val qualityLabel: String,
    val url: String,
    val headers: Map<String, String>,
    val hls: Boolean?,
    val status: DownloadStatus,
    val bytesDownloaded: Long = 0L,
    val totalBytes: Long? = null,
    val fraction: Float = 0f,
    val localPath: String? = null,
    val error: String? = null,
    val profileId: String? = null,
    val createdAt: Long = System.currentTimeMillis(),
    val updatedAt: Long = System.currentTimeMillis(),
) {
    val isActive: Boolean
        get() = status == DownloadStatus.QUEUED || status == DownloadStatus.DOWNLOADING

    val isPlayable: Boolean
        get() = status == DownloadStatus.COMPLETED && localPath != null

    /** "1.24 GB / 2.10 GB" or "180 MB" when the server did not report a size. */
    fun sizeLabel(): String = when {
        totalBytes != null && totalBytes > 0L ->
            "${formatBytes(bytesDownloaded)} / ${formatBytes(totalBytes)}"
        bytesDownloaded > 0L -> formatBytes(bytesDownloaded)
        else -> "—"
    }

    fun progressLabel(): String = when (status) {
        DownloadStatus.QUEUED -> "Queued"
        DownloadStatus.DOWNLOADING -> if (totalBytes != null && totalBytes > 0L) {
            "${(fraction * 100).toInt().coerceIn(0, 100)}% · ${sizeLabel()}"
        } else {
            "${formatBytes(bytesDownloaded)} · preparing"
        }
        DownloadStatus.PAUSED -> "Paused · ${sizeLabel()}"
        DownloadStatus.COMPLETED -> "Downloaded · ${sizeLabel()}"
        DownloadStatus.FAILED -> error?.takeIf { it.isNotBlank() } ?: "Failed"
    }
}

/** A quality/server row shown by the download picker. */
data class DownloadChoice(
    val server: String,
    val label: String,
    val url: String,
    val height: Int,
    val headers: Map<String, String>,
    val hls: Boolean?,
)

private fun formatBytes(bytes: Long): String {
    if (bytes <= 0L) return "0 MB"
    val kb = bytes / 1024.0
    val mb = kb / 1024.0
    val gb = mb / 1024.0
    return when {
        gb >= 1.0 -> "%.2f GB".format(gb)
        mb >= 1.0 -> "%.0f MB".format(mb)
        else -> "%.0f KB".format(kb)
    }
}

/** On-disk layout for downloads and its crash-safe JSON index. */
object DownloadStore {

    @Volatile
    var baseDir: Path = Paths.get(System.getProperty("user.home"), ".maxstream", "downloads")

    fun indexFile(): Path = baseDir.resolve("index.json")
    fun directory(id: String): Path = baseDir.resolve(id)
    fun exists(item: DownloadItem): Boolean = item.localPath?.let { Files.exists(Path.of(it)) } == true

    /** Removes a download directory including every segment/partial file. */
    fun deleteDirectory(id: String) {
        val dir = directory(id)
        if (!Files.exists(dir)) return
        runCatching {
            Files.walk(dir).use { stream ->
                stream.sorted(Comparator.reverseOrder()).forEach { Files.deleteIfExists(it) }
            }
        }
    }

    fun writeIndex(items: List<DownloadItem>) {
        val arr = JSONArray()
        items.forEach { arr.put(it.toJson()) }
        AtomicFiles.write(indexFile(), JSONObject().put("items", arr).toString())
    }

    fun readIndex(): List<DownloadItem> {
        if (!Files.exists(indexFile())) return emptyList()
        return runCatching {
            val root = JSONObject(Files.readString(indexFile()))
            val arr = root.optJSONArray("items") ?: JSONArray()
            (0 until arr.length()).mapNotNull { i ->
                arr.optJSONObject(i)?.let(::fromJson)
            }
        }.getOrElse {
            System.err.println("DownloadStore: unreadable index, starting empty: $it")
            emptyList()
        }
    }

    private fun DownloadItem.toJson(): JSONObject = JSONObject()
        .put("id", id)
        .put("itemId", request.itemId)
        .put("mediaType", request.mediaType)
        .put("title", request.title)
        .put("season", request.season)
        .put("episode", request.episode)
        .put("posterPath", request.posterPath ?: "")
        .put("subtitleLabel", subtitleLabel ?: "")
        .put("server", server)
        .put("qualityLabel", qualityLabel)
        .put("url", url)
        .put("headers", JSONObject(headers as Map<*, *>))
        .put("hls", hls?.let { if (it) 1 else 0 } ?: -1)
        .put("status", status.name)
        .put("bytesDownloaded", bytesDownloaded)
        .put("totalBytes", totalBytes ?: -1L)
        .put("fraction", fraction.toDouble())
        .put("localPath", localPath ?: "")
        .put("error", error ?: "")
        .put("profileId", profileId ?: "")
        .put("createdAt", createdAt)
        .put("updatedAt", updatedAt)

    private fun fromJson(o: JSONObject): DownloadItem? {
        val itemId = o.optString("itemId").takeIf { it.isNotBlank() } ?: return null
        val mediaType = o.optString("mediaType", "movie")
        val headers = mutableMapOf<String, String>()
        o.optJSONObject("headers")?.let { h ->
            h.keys().forEach { key -> headers[key] = h.optString(key) }
        }
        val hlsFlag = o.optInt("hls", -1)
        return DownloadItem(
            id = o.optString("id").ifBlank { "$itemId-S${o.optInt("season", 1)}-E${o.optInt("episode", 1)}" },
            request = PlayRequest(
                itemId = itemId,
                mediaType = mediaType,
                title = o.optString("title", "Title"),
                season = o.optInt("season", 1),
                episode = o.optInt("episode", 1),
                posterPath = o.optString("posterPath").ifBlank { null },
            ),
            subtitleLabel = o.optString("subtitleLabel").ifBlank { null },
            server = o.optString("server", "Server"),
            qualityLabel = o.optString("qualityLabel", "Auto"),
            url = o.optString("url"),
            headers = headers,
            hls = when (hlsFlag) { 1 -> true; 0 -> false; else -> null },
            status = runCatching { DownloadStatus.valueOf(o.optString("status")) }
                .getOrDefault(DownloadStatus.PAUSED),
            bytesDownloaded = o.optLong("bytesDownloaded", 0L),
            totalBytes = o.optLong("totalBytes", -1L).takeIf { it > 0L },
            fraction = o.optDouble("fraction", 0.0).toFloat().coerceIn(0f, 1f),
            localPath = o.optString("localPath").ifBlank { null },
            error = o.optString("error").ifBlank { null },
            profileId = o.optString("profileId").ifBlank { null },
            createdAt = o.optLong("createdAt", System.currentTimeMillis()),
            updatedAt = o.optLong("updatedAt", System.currentTimeMillis()),
        )
    }
}
