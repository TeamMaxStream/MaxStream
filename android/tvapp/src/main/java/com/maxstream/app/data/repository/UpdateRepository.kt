package com.maxstream.app.data.repository

import android.content.Context
import com.maxstream.app.core.Constants
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/**
 * Native mirror of the Dart [TvUpdateService]: checks the GitHub latest release
 * for `TeamMaxStream/MaxStream` and returns the TV APK asset when a newer version
 * exists.
 */
object UpdateRepository {
    private const val OWNER = "TeamMaxStream"
    private const val REPO = "MaxStream"
    private const val LATEST_URL = "https://api.github.com/repos/$OWNER/$REPO/releases/latest"
    private const val APK_HINT = "maxstream-tv"

    private val client = OkHttpClient.Builder()
        .connectTimeout(Constants.NETWORK_TIMEOUT_SECONDS, TimeUnit.SECONDS)
        .readTimeout(Constants.NETWORK_TIMEOUT_SECONDS, TimeUnit.SECONDS)
        .build()

    data class UpdateInfo(
        val version: String,
        val downloadUrl: String,
        val changelog: String,
    )

    fun currentVersion(context: Context): String =
        runCatching {
            val pkg = context.packageManager.getPackageInfo(context.packageName, 0)
            pkg.versionName ?: "0.0.0"
        }.getOrDefault("0.0.0")

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
                for (i in 0 until assets.length()) {
                    val asset = assets.optJSONObject(i)
                    val name = asset?.optString("name")?.lowercase().orEmpty()
                    if (name.endsWith(".apk") && name.contains(APK_HINT)) {
                        return@withContext UpdateInfo(
                            version = tag,
                            downloadUrl = asset.optString("browser_download_url"),
                            changelog = changelog,
                        )
                    }
                }
                null
            }
        } catch (_: Exception) {
            null
        }
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
