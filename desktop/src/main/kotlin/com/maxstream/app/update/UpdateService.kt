package com.maxstream.app.update

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.maxstream.app.core.AppConfig
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.TimeUnit

/** One downloadable desktop release from GitHub. */
data class UpdateInfo(
    val version: String,
    val tag: String,
    val notes: String,
    val assetName: String,
    val assetUrl: String,
    val assetSize: Long,
) {
    val isExecutable: Boolean get() = assetName.endsWith(".exe", ignoreCase = true)
}

/**
 * Self-update for the desktop client. GitHub Releases is the distribution
 * channel already used by the Android build, so no update server is needed:
 * releases are scanned for a desktop asset and compared numerically with
 * [AppConfig.APP_VERSION].
 *
 * Asset preference is `MaxStream-Dex.exe` (the desktop installer published
 * under that name), then any other MaxStream installer, then the MSI. Both
 * desktop assets are complete installers: the EXE is launched, the MSI is
 * handed to `msiexec`, and MaxStream exits so either can replace its files.
 * A raw jpackage launcher is not an update payload and is rejected.
 *
 * The public Compose state is written from an IO coroutine; Snapshot state is
 * thread-safe and recomposes whichever screen is observing it.
 */
object UpdateService {
    private const val RELEASES_URL =
        "https://api.github.com/repos/TeamMaxStream/MaxStream/releases?per_page=20"
    private const val USER_AGENT = "MaxStream-Desktop/${AppConfig.APP_VERSION}"
    private const val PREFERRED_EXE = "MaxStream-Dex.exe"

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val apiClient = OkHttpClient.Builder()
        .connectTimeout(12, TimeUnit.SECONDS)
        .readTimeout(20, TimeUnit.SECONDS)
        .build()
    private val downloadClient = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .build()

    var available by mutableStateOf<UpdateInfo?>(null)
        private set
    var checking by mutableStateOf(false)
        private set
    var checkError by mutableStateOf<String?>(null)
        private set
    var checkedOnce by mutableStateOf(false)
        private set

    var downloading by mutableStateOf(false)
        private set
    var downloadedBytes by mutableLongStateOf(0L)
        private set
    var downloadTotalBytes by mutableLongStateOf(0L)
        private set
    var downloadedFile by mutableStateOf<File?>(null)
        private set
    var downloadError by mutableStateOf<String?>(null)
        private set

    /** Banner dismissal is per launch; a manual check brings it back. */
    var bannerDismissed by mutableStateOf(false)
        private set

    fun dismissBanner() {
        bannerDismissed = true
    }

    fun checkInBackground() {
        if (checking) return
        checking = true
        checkError = null
        scope.launch {
            try {
                val found = fetchLatestDesktopRelease()
                available = found
                bannerDismissed = false
            } catch (e: Exception) {
                checkError = e.message ?: "Could not check for updates"
            } finally {
                checking = false
                checkedOnce = true
            }
        }
    }

    fun checkNow() = checkInBackground()

    /** Downloads the selected desktop installer, reporting progress for the UI. */
    fun download(info: UpdateInfo) {
        if (downloading) return
        downloading = true
        downloadError = null
        downloadedBytes = 0L
        downloadTotalBytes = info.assetSize.coerceAtLeast(0L)
        downloadedFile?.delete()
        downloadedFile = null
        scope.launch {
            var part: File? = null
            try {
                val dir = File(System.getProperty("user.home"), ".maxstream/updates")
                if (!dir.exists() && !dir.mkdirs()) error("Could not create ${dir.path}")
                val name = info.assetName.replace(Regex("[^A-Za-z0-9._-]"), "_")
                val target = File(dir, name)
                part = File(dir, "$name.part")
                if (part.exists()) part.delete()

                val request = Request.Builder()
                    .url(info.assetUrl)
                    .header("User-Agent", USER_AGENT)
                    .header("Accept", "application/octet-stream")
                    .build()
                downloadClient.newCall(request).execute().use { response ->
                    if (!response.isSuccessful) error("Download failed: HTTP ${response.code}")
                    val body = response.body ?: error("Download returned no data")
                    val total = body.contentLength().takeIf { it > 0L } ?: info.assetSize
                    if (total > 0) downloadTotalBytes = total
                    var lastPublish = 0L
                    part.outputStream().buffered().use { output ->
                        body.byteStream().use { input ->
                            val buffer = ByteArray(256 * 1024)
                            var written = 0L
                            while (true) {
                                val read = input.read(buffer)
                                if (read < 0) break
                                output.write(buffer, 0, read)
                                written += read
                                val now = System.currentTimeMillis()
                                if (now - lastPublish >= 120) {
                                    downloadedBytes = written
                                    lastPublish = now
                                }
                            }
                            downloadedBytes = written
                        }
                    }
                }
                if (!part.renameTo(target)) {
                    part.copyTo(target, overwrite = true)
                    part.delete()
                }
                part = null
                downloadedFile = target
            } catch (e: Exception) {
                part?.delete()
                downloadError = e.message ?: "Download failed"
            } finally {
                downloading = false
            }
        }
    }

    /**
     * Installs the downloaded update and exits so it can replace the app.
     * Both desktop artifacts are full installers: the MSI goes to `msiexec`,
     * the EXE is launched directly. The launcher exe alone is not an update
     * payload (the code lives in the adjacent `app/` jars), so suspiciously
     * small exe downloads are rejected instead of corrupting the install.
     */
    fun installAndExit(file: File): Boolean {
        return try {
            val isWindows = System.getProperty("os.name").startsWith("Windows", ignoreCase = true)
            require(isWindows) { "Desktop updates are installed with the Windows build" }
            when {
                file.name.endsWith(".exe", ignoreCase = true) -> {
                    if (file.length() < 5L * 1024 * 1024) {
                        downloadError =
                            "This release only contains the MaxStream launcher, not the app. " +
                                "Upload the desktop installer (EXE/MSI) instead."
                        return false
                    }
                    ProcessBuilder(file.absolutePath).start()
                }
                file.name.endsWith(".msi", ignoreCase = true) -> {
                    ProcessBuilder(
                        "msiexec.exe",
                        "/i", file.absolutePath,
                        "/passive",
                        "/norestart",
                    ).start()
                }
                else -> error("Unsupported update file: ${file.name}")
            }
            scheduleExit()
            true
        } catch (e: Exception) {
            downloadError = e.message ?: "Could not start the installer"
            false
        }
    }

    private fun scheduleExit() {
        Thread {
            Thread.sleep(1_200)
            Runtime.getRuntime().halt(0)
        }.apply { isDaemon = true }.start()
    }

    fun clearDownload() {
        downloadedFile?.delete()
        downloadedFile = null
        downloadedBytes = 0L
        downloadTotalBytes = 0L
        downloadError = null
    }

    private fun fetchLatestDesktopRelease(): UpdateInfo? {
        val request = Request.Builder()
            .url(RELEASES_URL)
            .header("User-Agent", USER_AGENT)
            .header("Accept", "application/vnd.github+json")
            .build()
        apiClient.newCall(request).execute().use { response ->
            if (!response.isSuccessful) error("GitHub returned HTTP ${response.code}")
            val body = response.body?.string() ?: error("Empty release response")
            val releases = JSONArray(body)
            var best: UpdateInfo? = null
            for (i in 0 until releases.length()) {
                val release = releases.optJSONObject(i) ?: continue
                if (release.optBoolean("draft") || release.optBoolean("prerelease")) continue
                val tag = release.optString("tag_name").trim()
                val version = versionFromTag(tag) ?: continue
                if (compareVersions(version, AppConfig.APP_VERSION) <= 0) continue
                val asset = pickAsset(release.optJSONArray("assets") ?: continue) ?: continue
                if (best == null || compareVersions(version, best.version) > 0) {
                    best = UpdateInfo(
                        version = version,
                        tag = tag,
                        notes = release.optString("body").trim()
                            .takeIf { it.isNotBlank() } ?: "Bug fixes and improvements.",
                        assetName = asset.optString("name"),
                        assetUrl = asset.optString("browser_download_url"),
                        assetSize = asset.optLong("size", 0L),
                    )
                }
            }
            return best
        }
    }

    /**
     * Picks the best desktop asset. `MaxStream-Dex.exe` is the name the
     * desktop build is published under, so it wins even when the release also
     * carries an MSI. A MaxStream-named exe beats any MSI for the same reason;
     * the MSI remains a fallback for CI-produced releases.
     */
    private fun pickAsset(assets: JSONArray?): JSONObject? {
        if (assets == null) return null
        var preferredExe: JSONObject? = null
        var namedExe: JSONObject? = null
        var anyExe: JSONObject? = null
        var namedMsi: JSONObject? = null
        var anyMsi: JSONObject? = null
        for (i in 0 until assets.length()) {
            val asset = assets.optJSONObject(i) ?: continue
            val name = asset.optString("name")
            when {
                name.equals(PREFERRED_EXE, ignoreCase = true) -> preferredExe = asset
                name.endsWith(".exe", ignoreCase = true) && name.contains("maxstream", ignoreCase = true) ->
                    if (namedExe == null) namedExe = asset
                name.endsWith(".exe", ignoreCase = true) ->
                    if (anyExe == null) anyExe = asset
                name.endsWith(".msi", ignoreCase = true) && name.contains("maxstream", ignoreCase = true) ->
                    if (namedMsi == null) namedMsi = asset
                name.endsWith(".msi", ignoreCase = true) ->
                    if (anyMsi == null) anyMsi = asset
            }
        }
        return preferredExe ?: namedExe ?: anyExe ?: namedMsi ?: anyMsi
    }

    private fun versionFromTag(tag: String): String? {
        return Regex("""(\d+(?:\.\d+)*)""").find(tag)?.groupValues?.get(1)
    }
}

/** Numeric comparison: 1.0.10 is newer than 1.0.9 (string compare is not). */
internal fun compareVersions(a: String, b: String): Int {
    val left = a.split('.').map { it.toIntOrNull() ?: 0 }
    val right = b.split('.').map { it.toIntOrNull() ?: 0 }
    val size = maxOf(left.size, right.size)
    for (i in 0 until size) {
        val diff = (left.getOrElse(i) { 0 }) - (right.getOrElse(i) { 0 })
        if (diff != 0) return diff
    }
    return 0
}
