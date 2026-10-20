package com.maxstream.app.download

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.maxstream.app.data.AppPrefs
import com.maxstream.app.data.cloud.ProfileStore
import com.maxstream.app.data.model.PlayRequest
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import java.nio.file.Files
import java.util.concurrent.ConcurrentHashMap

/**
 * Persistent download queue. Two transfers run at once so a slow movie does
 * not block a short episode; every state change survives a restart because it
 * is written to `index.json` (progress is throttled to once every 2 s).
 *
 * Downloads are per-profile and stored under ~/.maxstream/downloads. The file
 * layout inside each directory is the same one mpv reads:
 *   playlist.m3u8 + resource_*.ts/.m4s/.key  (HLS)
 *   video.mp4                                (direct)
 */
object DownloadManager {

    private const val MAX_CONCURRENT = 2

    var items by mutableStateOf<List<DownloadItem>>(emptyList())
        private set

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val queue = Channel<String>(Channel.UNLIMITED)
    private val controls = ConcurrentHashMap<String, DownloadControl>()
    private val lastPersist = ConcurrentHashMap<String, Long>()
    private val inFlight = ConcurrentHashMap.newKeySet<String>()
    private val lock = Any()
    private val persistLock = Any()

    @Volatile private var workersStarted = false
    @Volatile private var restored = false

    val storagePath: String get() = DownloadStore.baseDir.toString()

    fun freeSpaceBytes(): Long = runCatching { DownloadStore.baseDir.toFile().usableSpace }.getOrDefault(0L)

    fun restore() {
        val first = synchronized(lock) {
            if (restored) false else {
                restored = true
                true
            }
        }
        if (!first) return
        runCatching { Files.createDirectories(DownloadStore.baseDir) }
        val loaded = DownloadStore.readIndex().map { item ->
            when {
                item.status == DownloadStatus.COMPLETED && !DownloadStore.exists(item) ->
                    item.copy(status = DownloadStatus.FAILED, error = "File is missing", localPath = null)
                // A transfer interrupted by app exit resumes automatically;
                // a transfer the user explicitly paused stays paused.
                item.status == DownloadStatus.DOWNLOADING || item.status == DownloadStatus.QUEUED ->
                    item.copy(status = DownloadStatus.QUEUED, updatedAt = System.currentTimeMillis())
                else -> item
            }
        }
        items = loaded.sortedByDescending { it.createdAt }
        startWorkers()
        loaded.filter { it.status == DownloadStatus.QUEUED }.forEach { queue.trySend(it.id) }
    }

    fun itemsForActiveProfile(): List<DownloadItem> {
        val profileId = ProfileStore.activeProfileId
        return items.filter { item ->
            profileId == null || item.profileId == null || item.profileId == profileId
        }
    }

    /** Adds a new download (or updates a failed/paused one with a new source). */
    fun start(
        request: PlayRequest,
        subtitleLabel: String?,
        server: String,
        qualityLabel: String,
        url: String,
        headers: Map<String, String>,
        hls: Boolean?,
    ): DownloadItem {
        val id = keyFor(request)
        val cleanRequest = request.copy(localPath = null)
        val existing = items.firstOrNull { it.id == id }
        if (existing != null && existing.status == DownloadStatus.COMPLETED) return existing

        // Two clicks on Download while the first transfer is running must not
        // start a second writer on the same directory.
        if (existing != null && existing.isActive) return existing

        // A different source/quality cannot resume the old partial segment
        // files, so start that item from a clean directory.
        if (existing != null && existing.url != url) {
            DownloadStore.deleteDirectory(id)
        }

        val now = System.currentTimeMillis()
        val item = DownloadItem(
            id = id,
            request = cleanRequest,
            subtitleLabel = subtitleLabel,
            server = server,
            qualityLabel = qualityLabel,
            url = url,
            headers = headers,
            hls = hls,
            status = DownloadStatus.QUEUED,
            bytesDownloaded = if (existing?.url == url) existing.bytesDownloaded else 0L,
            totalBytes = existing?.totalBytes,
            fraction = if (existing?.url == url) existing.fraction else 0f,
            localPath = null,
            error = null,
            profileId = ProfileStore.activeProfileId,
            createdAt = existing?.createdAt ?: now,
            updatedAt = now,
        )
        synchronized(lock) {
            items = (items.filterNot { it.id == id } + item).sortedByDescending { it.createdAt }
            DownloadStore.writeIndex(items)
        }
        controls[id] = DownloadControl()
        startWorkers()
        queue.trySend(id)
        return item
    }

    fun pause(id: String) {
        controls[id]?.paused = true
        update(id) {
            if (it.status == DownloadStatus.DOWNLOADING || it.status == DownloadStatus.QUEUED) {
                it.copy(status = DownloadStatus.PAUSED, updatedAt = System.currentTimeMillis())
            } else it
        }
        persist()
    }

    fun resume(id: String) {
        val item = items.firstOrNull { it.id == id } ?: return
        if (item.status == DownloadStatus.COMPLETED) return
        controls[id] = DownloadControl()
        update(id) { it.copy(status = DownloadStatus.QUEUED, error = null, updatedAt = System.currentTimeMillis()) }
        persist()
        startWorkers()
        queue.trySend(id)
    }

    fun retry(id: String) = resume(id)

    fun cancel(id: String) {
        controls.remove(id)?.cancelled = true
        synchronized(lock) {
            items = items.filterNot { it.id == id }
            DownloadStore.writeIndex(items)
        }
        DownloadStore.deleteDirectory(id)
    }

    fun remove(id: String) = cancel(id)

    fun clearCompleted() {
        val completed = items.filter { it.status == DownloadStatus.COMPLETED }
        synchronized(lock) {
            items = items.filterNot { it.status == DownloadStatus.COMPLETED }
            DownloadStore.writeIndex(items)
        }
        completed.forEach { DownloadStore.deleteDirectory(it.id) }
    }

    fun playablePath(item: DownloadItem): String? =
        item.localPath?.takeIf { Files.exists(java.nio.file.Path.of(it)) }

    // ── queue ────────────────────────────────────────────────────────────────

    private fun startWorkers() {
        if (workersStarted) return
        synchronized(lock) {
            if (workersStarted) return
            workersStarted = true
        }
        repeat(MAX_CONCURRENT) {
            scope.launch {
                for (id in queue) {
                    runCatching { runJob(id) }
                }
            }
        }
    }

    private fun runJob(id: String) {
        if (!inFlight.add(id)) return
        try {
            runJobInner(id)
        } finally {
            inFlight.remove(id)
        }
    }

    private fun runJobInner(id: String) {
        val item = readItem(id) ?: return
        if (item.status == DownloadStatus.COMPLETED) return
        update(id) { it.copy(status = DownloadStatus.DOWNLOADING, error = null, updatedAt = System.currentTimeMillis()) }
        persist()

        val control = controls.getOrPut(id) { DownloadControl() }
        control.paused = false
        control.cancelled = false
        val directory = DownloadStore.directory(id)
        try {
            val result = MediaDownloader.download(
                directory = directory,
                url = item.url,
                headers = item.headers,
                hlsHint = item.hls,
                maxVariantHeight = AppPrefs.defaultQualityHeight(),
                control = control,
            ) { downloaded, total, fraction ->
                if (control.paused || control.cancelled) return@download
                updateProgress(id, downloaded, total, fraction)
            }
            update(id) {
                it.copy(
                    status = DownloadStatus.COMPLETED,
                    localPath = result.path,
                    bytesDownloaded = result.bytes,
                    totalBytes = result.bytes,
                    fraction = 1f,
                    error = null,
                    updatedAt = System.currentTimeMillis(),
                )
            }
            persist()
        } catch (_: DownloadPausedException) {
            update(id) {
                if (it.status == DownloadStatus.DOWNLOADING) {
                    it.copy(status = DownloadStatus.PAUSED, updatedAt = System.currentTimeMillis())
                } else it
            }
            persist()
        } catch (_: DownloadCancelledException) {
            // cancel() already removed the row and directory.
        } catch (c: CancellationException) {
            throw c
        } catch (t: Throwable) {
            if (controls[id]?.cancelled == true) return
            update(id) {
                it.copy(
                    status = DownloadStatus.FAILED,
                    error = t.message?.takeIf { m -> m.isNotBlank() } ?: t.javaClass.simpleName,
                    updatedAt = System.currentTimeMillis(),
                )
            }
            persist()
        }
    }

    private fun updateProgress(id: String, downloaded: Long, total: Long?, fraction: Float) {
        val now = System.currentTimeMillis()
        synchronized(lock) {
            items = items.map { item ->
                if (item.id != id) item
                else item.copy(
                    bytesDownloaded = downloaded,
                    totalBytes = total ?: item.totalBytes,
                    fraction = fraction.coerceIn(0f, 1f),
                    status = DownloadStatus.DOWNLOADING,
                )
            }
        }
        val last = lastPersist[id] ?: 0L
        if (now - last >= 2_000L) {
            lastPersist[id] = now
            persist()
        }
    }

    private fun update(id: String, transform: (DownloadItem) -> DownloadItem) {
        synchronized(lock) {
            items = items.map { if (it.id == id) transform(it) else it }
        }
    }

    private fun readItem(id: String): DownloadItem? = synchronized(lock) {
        items.firstOrNull { it.id == id }
    }

    private fun persist() {
        val snapshot = synchronized(lock) { items }
        synchronized(persistLock) {
            runCatching { DownloadStore.writeIndex(snapshot) }
                .onFailure { System.err.println("DownloadManager: index write failed: $it") }
        }
    }

    private fun keyFor(request: PlayRequest): String {
        val safeId = request.itemId.filter { it.isLetterOrDigit() || it == '-' || it == '_' }
            .ifBlank { "title" }
        // Downloads are per profile: two profiles can keep the same title at
        // different qualities without sharing files or one hiding the other.
        val profile = (ProfileStore.activeProfileId ?: "guest")
            .filter { it.isLetterOrDigit() || it == '-' || it == '_' }
            .ifBlank { "guest" }
        val prefix = "$profile-$safeId"
        return if (request.mediaType == "tv") {
            "$prefix-S${request.season}-E${request.episode}"
        } else {
            "$prefix-movie"
        }
    }
}
