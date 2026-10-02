package com.maxstream.app.data.repository

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import com.maxstream.app.core.Constants
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.util.concurrent.TimeUnit

/**
 * Native mirror of the Dart [TvUpdateService]: checks the GitHub latest release
 * for `TeamMaxStream/MaxStream` and returns the TV APK asset when a newer version
 * exists. Also owns the download → install hand-off so the app can update itself
 * (same flow as the phone app's `UpdateService.downloadAndInstallUpdate`).
 */
object UpdateRepository {
    private const val OWNER = "TeamMaxStream"
    private const val REPO = "MaxStream"
    private const val LATEST_URL = "https://api.github.com/repos/$OWNER/$REPO/releases/latest"
    private const val APK_HINT = "maxstream-tv"
    private const val RELEASES_URL = "https://github.com/$OWNER/$REPO/releases"
    private const val DOWNLOAD_FILE_NAME = "MaxStream-tv.apk"
    private const val PREFS = "maxstream_tv_settings"
    private const val KEY_AUTO_CHECK = "auto_check_updates"
    private const val MIN_APK_BYTES = 1000L

    val releasesUrl: String get() = RELEASES_URL

    private val client = OkHttpClient.Builder()
        .connectTimeout(Constants.NETWORK_TIMEOUT_SECONDS, TimeUnit.SECONDS)
        .readTimeout(Constants.NETWORK_TIMEOUT_SECONDS, TimeUnit.SECONDS)
        .build()

    data class UpdateInfo(
        val version: String,
        val downloadUrl: String,
        val changelog: String,
        val releaseName: String = "",
        val sizeBytes: Long = -1L,
        val publishedAt: String = "",
        val releaseUrl: String = RELEASES_URL,
    )

    sealed class InstallResult {
        data object Launched : InstallResult()
        data object NeedsPermission : InstallResult()
        data class Failed(val message: String) : InstallResult()
    }

    fun currentVersion(context: Context): String =
        runCatching {
            val pkg = context.packageManager.getPackageInfo(context.packageName, 0)
            pkg.versionName ?: "0.0.0"
        }.getOrDefault("0.0.0")

    // ── Auto-check preference (parity with Dart `UpdateService.isAutoCheckEnabled`) ──
    fun isAutoCheckEnabled(context: Context): Boolean =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getBoolean(KEY_AUTO_CHECK, true)

    fun setAutoCheckEnabled(context: Context, enabled: Boolean) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_AUTO_CHECK, enabled)
            .apply()
    }

    suspend fun checkForUpdate(context: Context): UpdateInfo? = withContext(Dispatchers.IO) {
        try {
            val request = Request.Builder().url(LATEST_URL)
                .header("Accept", "application/vnd.github+json")
                .build()
            client.newCall(request).execute().use { response ->
                if (!response.isSuccessful) return@withContext null
                val json = JSONObject(response.body?.string().orEmpty())
                val tag = json.optString("tag_name").replaceFirst("v", "")
                val changelog = json.optString("body", "")
                if (tag.isEmpty()) return@withContext null
                if (!isVersionNewer(currentVersion(context), tag)) return@withContext null
                val assets = json.optJSONArray("assets") ?: JSONArray()
                var size = -1L
                for (i in 0 until assets.length()) {
                    val asset = assets.optJSONObject(i)
                    val name = asset?.optString("name")?.lowercase().orEmpty()
                    if (name.endsWith(".apk") && name.contains(APK_HINT)) {
                        size = asset.optLong("size", -1L)
                        return@withContext UpdateInfo(
                            version = tag,
                            downloadUrl = asset.optString("browser_download_url"),
                            changelog = changelog,
                            releaseName = json.optString("name", ""),
                            sizeBytes = size,
                            publishedAt = json.optString("published_at", ""),
                            releaseUrl = json.optString("html_url", RELEASES_URL)
                                .ifBlank { RELEASES_URL },
                        )
                    }
                }
                null
            }
        } catch (_: Exception) {
            null
        }
    }

    /**
     * Streams the release APK into the app cache. [onProgress] receives
     * (receivedBytes, totalBytes); totalBytes is -1 when unknown.
     */
    suspend fun downloadUpdate(
        context: Context,
        url: String,
        onProgress: (Long, Long) -> Unit,
    ): File = withContext(Dispatchers.IO) {
        val target = File(context.cacheDir, DOWNLOAD_FILE_NAME)
        runCatching { if (target.exists()) target.delete() }
        val request = Request.Builder().url(url).build()
        client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) throw IOException("Server returned HTTP ${response.code}")
            val body = response.body ?: throw IOException("Empty download response")
            val total = body.contentLength()
            var received = 0L
            var lastEmit = 0L
            body.byteStream().use { input ->
                target.outputStream().use { out ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        val read = input.read(buffer)
                        if (read < 0) break
                        out.write(buffer, 0, read)
                        received += read
                        if (received - lastEmit >= 128 * 1024) {
                            lastEmit = received
                            onProgress(received, total)
                        }
                    }
                }
            }
            onProgress(received, if (total > 0) total else received)
        }
        if (target.length() < MIN_APK_BYTES) {
            target.delete()
            throw IOException("Downloaded file is too small — likely an error page")
        }
        target
    }

    /** Hands a downloaded APK to the system installer (FileProvider content URI). */
    fun install(context: Context, file: File): InstallResult {
        if (!file.exists() || file.length() < MIN_APK_BYTES) {
            return InstallResult.Failed("Downloaded file is missing or incomplete")
        }
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                !context.packageManager.canRequestPackageInstalls()
            ) {
                InstallResult.NeedsPermission
            } else {
                launchInstaller(context, file)
                InstallResult.Launched
            }
        } catch (t: Throwable) {
            InstallResult.Failed(t.message ?: "Could not start the installer")
        }
    }

    /** Best-effort: is this device allowed to install unknown-source APKs yet? */
    fun canInstallPackages(context: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
            context.packageManager.canRequestPackageInstalls()

    /** Opens the system "install unknown apps" screen for this package. */
    fun openInstallPermissionSettings(context: Context) {
        runCatching {
            val intent = Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:${context.packageName}"),
            )
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
        }
    }

    private fun launchInstaller(context: Context, file: File) {
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        context.startActivity(intent)
    }

    private fun isVersionNewer(current: String, latest: String): Boolean {
        val c = current.split('.').mapNotNull { it.toIntOrNull() }
        val l = latest.split('.').mapNotNull { it.toIntOrNull() }
        val n = maxOf(c.size, l.size)
        for (i in 0 until n) {
            val a = c.getOrElse(i) { 0 }
            val b = l.getOrElse(i) { 0 }
            if (b > a) return true
            if (b < a) return false
        }
        return false
    }
}
