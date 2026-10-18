package com.maxstream.app

import android.content.ComponentCallbacks2
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.core.content.FileProvider
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.*
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Plain AudioServiceActivity (a FlutterActivity) on purpose.
 *
 * Making this a FragmentActivity so local_auth could host its prompt broke the
 * audio_service engine lifecycle twice: the retained FlutterFragment fought
 * over the shared cached engine ("The internal FlutterEngine ... has been
 * attached to by another activity"), and taking the engine down with the host
 * left the AudioService touching a detached JNI ("FlutterJNI is not attached
 * to native").
 *
 * The biometric prompt therefore lives in its own engine-less activity —
 * [BiometricAuthActivity] — and this activity only relays its result.
 */
class MainActivity : AudioServiceActivity() {
    private val EXTRACTOR_CHANNEL = "com.maxstream.app/extractor"
    private val BIOMETRIC_CHANNEL = "com.maxstream.app/biometric"
    private val DOWNLOAD_SERVICE_CHANNEL = "com.maxstream.app/download_service"
    private val RESTART_CHANNEL = "com.maxstream.app/restart"
    private val CRASHLOG_CHANNEL = "com.maxstream.app/crashlog"
    private val MEMORY_CHANNEL = "com.maxstream.app/memory"
    private val INSTALL_CHANNEL = "com.maxstream.app/install"
    private val extractor by lazy { StreamExtractor(this) }
    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())
    private var memoryChannel: MethodChannel? = null

    private companion object {
        const val BIOMETRIC_REQUEST = 0x8D17
    }

    /** Result of an in-flight biometric prompt, completed in onActivityResult. */
    private var pendingBiometric: MethodChannel.Result? = null

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        installNativeCrashHandler()
        super.onCreate(savedInstanceState)
    }

    /**
     * Dart caches (decoded posters, subtitle buffers) can be released when the
     * system warns about memory pressure, which is the main thing we control to
     * keep the Low Memory Killer from killing the process while a video is
     * buffered 45s ahead. Forward the warning to Dart; JVM-level trim also gets
     * a GC hint because a chunk of the footprint lives in the video decoder.
     *
     * On Android 14 TV boxes (Vitron-class, 1 GB RAM) the LMK is the #1 cause
     * of mid-playback crashes: once the system crosses the critical threshold
     * it sends SIGKILL without any JVM callback, so we must act on the
     * *running-low* signal before it is too late.
     */
    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        try {
            memoryChannel?.invokeMethod("onTrimMemory", level)
        } catch (_: Throwable) {
            // Best-effort; never let memory handling crash the app.
        }
        if (level >= ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW) {
            // Hint the GC to reclaim unreachable bitmap / codec buffers before
            // the LMK picks our process as its next target.
            System.gc()
        }
        if (level >= ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL) {
            // At the critical threshold the process is seconds away from being
            // killed.  A second GC after a short delay lets finalizers run and
            // recover native codec memory that the first pass could not free.
            android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                try { System.gc() } catch (_: Throwable) {}
            }, 200)
        }
    }

    /**
     * Captures JVM-level crashes (uncaught exceptions thrown off the Flutter
     * thread, e.g. in ExoPlayer/MediaCodec callbacks or our extractors) into a
     * tombstone file. The crash screen has no chance to show for a hard process
     * death, so the report is persisted here and surfaced by Dart on next boot.
     *
     * Note: a Low Memory Killer SIGKILL or a pure native SIGSEGV never runs a
     * JVM handler, so those cannot be recorded this way - but the most common
     * Android crashes are still Java exceptions and will now produce a report.
     */
    private fun installNativeCrashHandler() {
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            try {
                val file = File(filesDir, "maxstream_native_crash.txt")
                file.parentFile?.mkdirs()
                val time = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US).format(Date())
                val entry = buildString {
                    append(time).append('\n')
                    append("[NativeCrash] ")
                    append(throwable.javaClass.name)
                    append(": ")
                    append(throwable.message ?: "")
                    append('\n')
                    append("Thread: ").append(thread.name).append('\n')
                    append("Stack:\n")
                    for (el in throwable.stackTrace) {
                        append("  at ").append(el.toString()).append('\n')
                    }
                    throwable.cause?.let { cause ->
                        append("Caused by: ").append(cause).append('\n')
                    }
                    append('\n')
                }
                file.appendText(entry)
            } catch (_: Throwable) {
                // Crash handling must never crash.
            }
            // Let the default handler do its job (abort the process, logcat).
            previous?.uncaughtException(thread, throwable)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Biometric relay: Dart asks, we launch the engine-less
        // BiometricAuthActivity and pass its verdict straight back.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, BIOMETRIC_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "authenticate" -> {
                        if (pendingBiometric != null) {
                            result.error(
                                "in_progress",
                                "A biometric prompt is already showing",
                                null,
                            )
                            return@setMethodCallHandler
                        }
                        val reason =
                            call.argument<String>("reason") ?: "Unlock MaxStream"
                        val biometricOnly = call.argument<Boolean>("biometricOnly") ?: false
                        pendingBiometric = result
                        runCatching {
                            startActivityForResult(
                                BiometricAuthActivity.intent(this, reason, biometricOnly),
                                BIOMETRIC_REQUEST,
                            )
                        }.onFailure {
                            pendingBiometric = null
                            result.error("prompt_failed", it.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        memoryChannel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, MEMORY_CHANNEL)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CRASHLOG_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getNativeCrashTombstone" -> {
                        // Return (and clear) the tombstone written by
                        // installNativeCrashHandler so Dart can show the crash
                        // screen once for a previous-process death. Deleting on
                        // read means a restart after "Restart app" won't re-show
                        // the same crash.
                        val file = File(filesDir, "maxstream_native_crash.txt")
                        if (file.exists() && file.isFile) {
                            val text = file.readText()
                            file.delete()
                            result.success(text)
                        } else {
                            result.success("")
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, EXTRACTOR_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getBrightness" -> {
                        try {
                            val windowBrightness = window.attributes.screenBrightness
                            val brightness = if (windowBrightness >= 0f) {
                                windowBrightness
                            } else {
                                Settings.System.getInt(
                                    contentResolver,
                                    Settings.System.SCREEN_BRIGHTNESS,
                                    128,
                                ) / 255f
                            }
                            result.success(brightness.toDouble())
                        } catch (e: Exception) {
                            result.success(0.5)
                        }
                    }
                    "setBrightness" -> {
                        try {
                            val brightness = (call.argument<Double>("value") ?: 0.5)
                                .coerceIn(0.01, 1.0)
                                .toFloat()
                            window.attributes = window.attributes.apply {
                                screenBrightness = brightness
                            }
                            result.success(null)
                        } catch (e: Exception) {
                            result.success(null)
                        }
                    }
                    "resolveStream" -> {
                        val tmdbId = call.argument<String>("tmdbId") ?: ""
                        val isMovie = call.argument<Boolean>("isMovie") ?: true
                        val season = call.argument<Int>("season") ?: 1
                        val episode = call.argument<Int>("episode") ?: 1
                        val title = call.argument<String>("title") ?: ""

                        scope.launch {
                            try {
                                val stream = withContext(Dispatchers.IO) {
                                    extractor.resolveStream(tmdbId, isMovie, season, episode, title)
                                }
                                try {
                                    if (stream != null) {
                                        result.success(stream)
                                    } else {
                                        result.error("NO_STREAM", "No stream found", null)
                                    }
                                } catch (_: IllegalStateException) { }
                            } catch (e: Exception) {
                                try { result.error("EXTRACT_ERROR", e.message, null) }
                                catch (_: IllegalStateException) { }
                            }
                        }
                    }
                    "resolveStreams" -> {
                        val tmdbId = call.argument<String>("tmdbId") ?: ""
                        val isMovie = call.argument<Boolean>("isMovie") ?: true
                        val season = call.argument<Int>("season") ?: 1
                        val episode = call.argument<Int>("episode") ?: 1
                        val title = call.argument<String>("title") ?: ""
                        val fast = call.argument<Boolean>("fast") ?: false

                        scope.launch {
                            try {
                                val streams = withContext(Dispatchers.IO) {
                                    extractor.resolveStreams(tmdbId, isMovie, season, episode, title, fast)
                                }
                                try { result.success(streams) }
                                catch (_: IllegalStateException) { }
                            } catch (e: Exception) {
                                try { result.error("EXTRACT_ERROR", e.message, null) }
                                catch (_: IllegalStateException) { }
                            }
                        }
                    }
                    "resolveServer" -> {
                        val serverName = call.argument<String>("serverName") ?: ""
                        val tmdbId = call.argument<String>("tmdbId") ?: ""
                        val isMovie = call.argument<Boolean>("isMovie") ?: true
                        val season = call.argument<Int>("season") ?: 1
                        val episode = call.argument<Int>("episode") ?: 1
                        val title = call.argument<String>("title") ?: ""

                        scope.launch {
                            try {
                                val stream = withContext(Dispatchers.IO) {
                                    extractor.resolveServer(
                                        serverName, tmdbId, isMovie, season, episode, title,
                                    )
                                }
                                try { result.success(stream) }
                                catch (_: IllegalStateException) { }
                            } catch (e: Exception) {
                                try { result.error("EXTRACT_ERROR", e.message, null) }
                                catch (_: IllegalStateException) { }
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, INSTALL_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getArch" -> {
                        // Pick the ABI this device can actually install, preferring
                        // the one our release APKs are split for. Reporting only
                        // SUPPORTED_ABIS.first() meant a 32-bit x86 device/emulator
                        // returned "x86", which matched no APK variant and silently
                        // fell back to arm64 — an APK that cannot install on it.
                        val supported = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.LOLLIPOP) {
                            android.os.Build.SUPPORTED_ABIS.toList()
                        } else {
                            @Suppress("DEPRECATION")
                            listOf(android.os.Build.CPU_ABI)
                        }
                        val variant = supported.firstNotNullOfOrNull { abi ->
                            when {
                                abi.startsWith("arm64") || abi.startsWith("aarch64") -> "arm64-v8a"
                                abi.startsWith("armeabi") || abi == "arm" -> "armeabi-v7a"
                                abi.startsWith("x86_64") || abi.startsWith("amd64") -> "x86_64"
                                abi.startsWith("x86") -> "x86"
                                else -> null
                            }
                        } ?: supported.firstOrNull() ?: "arm64-v8a"
                        result.success(variant)
                    }
                    "installApk" -> {
                        val filePath = call.argument<String>("filePath") ?: ""
                        try {
                            val file = File(filePath)
                            if (!file.exists()) {
                                result.error("FILE_NOT_FOUND", "APK file not found", null)
                                return@setMethodCallHandler
                            }

                            val uri = FileProvider.getUriForFile(
                                this,
                                "${packageName}.fileprovider",
                                file,
                            )

                            val intent = Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(uri, "application/vnd.android.package-archive")
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(intent)
                            result.success("ok")
                        } catch (e: Exception) {
                            result.error("INSTALL_FAILED", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, RESTART_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "restartApp" -> {
                        // Relaunch the activity as a cold start so the crash
                        // report restart button fully resets the app state.
                        val intent = packageManager.getLaunchIntentForPackage(packageName)
                        if (intent != null) {
                            intent.addFlags(
                                Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK,
                            )
                            startActivity(intent)
                            result.success(null)
                        } else {
                            result.error("NO_LAUNCH_INTENT", "No launch intent found", null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DOWNLOAD_SERVICE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startForegroundService" -> {
                        val downloadCount = call.argument<Int>("downloadCount") ?: 1
                        val title = call.argument<String>("title") ?: "Downloading media"
                        val intent = Intent(this, DownloadForegroundService::class.java).apply {
                            action = DownloadForegroundService.ACTION_START
                            putExtra("download_count", downloadCount)
                            putExtra("title", title)
                        }
                        startForegroundService(intent)
                        result.success(true)
                    }
                    "stopForegroundService" -> {
                        val intent = Intent(this, DownloadForegroundService::class.java).apply {
                            action = DownloadForegroundService.ACTION_STOP
                        }
                        startService(intent)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        scope.cancel()
        // Dart will never see this prompt's outcome if the activity goes away
        // first; fail it explicitly so the UI doesn't wait forever.
        pendingBiometric?.error("cancelled", "Activity destroyed", null)
        pendingBiometric = null
        super.onDestroy()
    }

    @Deprecated("Kept for the biometric relay; Flutter uses its own plumbing.")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != BIOMETRIC_REQUEST) return
        val pending = pendingBiometric ?: return
        pendingBiometric = null
        val errorCode = data?.getStringExtra(BiometricAuthActivity.EXTRA_ERROR_CODE) ?: "failed"
        // Same shape local_auth returns, so the Dart error mapping is unchanged.
        pending.success(
            mapOf(
                "authenticated" to (resultCode == BiometricAuthActivity.RESULT_AUTHENTICATED && errorCode.isEmpty()),
                "errorCode" to errorCode,
            ),
        )
    }
}
