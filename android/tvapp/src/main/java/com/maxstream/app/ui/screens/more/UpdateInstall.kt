package com.maxstream.app.ui.screens.more

import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.maxstream.app.data.repository.UpdateRepository
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

// ─────────────────────────────────────────────────────────────────────────────
// Download → install state machine, shared by the startup update dialog and
// the Updates screen (mirrors Dart's `UpdateService.downloadAndInstallUpdate`
// + `DownloadProgressDialog`).
// ─────────────────────────────────────────────────────────────────────────────

sealed class UpdatePhase {
    data object Idle : UpdatePhase()

    /** [progress] is 0f..1f, or -1f when the total size is unknown. */
    data class Downloading(val progress: Float) : UpdatePhase()
    data object Installing : UpdatePhase()
    data object NeedsPermission : UpdatePhase()
    data object Launched : UpdatePhase()
    data class Failed(val message: String) : UpdatePhase()
}

class UpdateInstallController {
    var phase: UpdatePhase by mutableStateOf(UpdatePhase.Idle)
        private set

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var job: Job? = null
    private var apkFile: java.io.File? = null

    val isBusy: Boolean
        get() = phase is UpdatePhase.Downloading ||
            phase is UpdatePhase.Installing ||
            phase is UpdatePhase.Launched

    /** Download [info]'s APK, then hand it straight to the system installer. */
    fun start(context: Context, info: UpdateRepository.UpdateInfo) {
        if (isBusy) return
        val appContext = context.applicationContext
        phase = UpdatePhase.Downloading(0f)
        job = scope.launch {
            try {
                val file = withContext(Dispatchers.IO) {
                    UpdateRepository.downloadUpdate(appContext, info.downloadUrl) { received, total ->
                        val fraction = if (total > 0L) received.toFloat() / total.toFloat() else -1f
                        scope.launch { phase = UpdatePhase.Downloading(fraction) }
                    }
                }
                apkFile = file
                runInstall(appContext)
            } catch (e: kotlinx.coroutines.CancellationException) {
                // User pressed Cancel — phase was already reset to Idle.
                throw e
            } catch (t: Throwable) {
                phase = UpdatePhase.Failed(t.message ?: "Could not download the update")
            }
        }
    }

    /** Retry the installer after the user granted unknown-source permission. */
    fun retryInstall(context: Context) {
        val file = apkFile
        if (file == null) {
            phase = UpdatePhase.Failed("Update file not found — download it again")
            return
        }
        job = scope.launch { runInstall(context.applicationContext) }
    }

    /** Android 8+: send the user to the install-unknown-apps screen. */
    fun allowPermission(context: Context) {
        UpdateRepository.openInstallPermissionSettings(context)
    }

    fun reset() {
        job?.cancel()
        phase = UpdatePhase.Idle
    }

    fun dispose() {
        job?.cancel()
        scope.cancel()
    }

    private suspend fun runInstall(context: Context) {
        val file = apkFile ?: return
        phase = UpdatePhase.Installing
        val result = withContext(Dispatchers.IO) { UpdateRepository.install(context, file) }
        phase = when (result) {
            is UpdateRepository.InstallResult.Launched -> UpdatePhase.Launched
            is UpdateRepository.InstallResult.NeedsPermission -> UpdatePhase.NeedsPermission
            is UpdateRepository.InstallResult.Failed -> UpdatePhase.Failed(result.message)
        }
    }
}

@Composable
fun rememberUpdateInstallController(): UpdateInstallController {
    val controller = remember { UpdateInstallController() }
    DisposableEffect(controller) {
        onDispose { controller.dispose() }
    }
    return controller
}

// ─────────────────────────────────────────────────────────────────────────────
// Progress / status block (identical in the dialog and the Updates screen)
// ─────────────────────────────────────────────────────────────────────────────

@Composable
fun UpdateProgressContent(
    phase: UpdatePhase,
    modifier: Modifier = Modifier,
) {
    when (phase) {
        is UpdatePhase.Idle -> Unit

        is UpdatePhase.Downloading -> {
            val percent = if (phase.progress >= 0f) {
                "${(phase.progress.coerceAtMost(1f) * 100f).toInt()}%"
            } else {
                ""
            }
            StatusBlock(modifier, title = "Downloading update...", trailing = percent) {
                UpdateProgressBar(phase.progress, label = "Transferring to this device")
            }
        }

        UpdatePhase.Installing -> StatusBlock(modifier, title = "Starting installer...") {
            UpdateProgressBar(-1f, label = "Handing over to Android")
        }

        UpdatePhase.NeedsPermission -> StatusBlock(
            modifier,
            title = "Permission required",
            body = "Allow MaxStream to install unknown apps, then press Install again.",
            accent = Color(0xFFFFB300),
        )

        UpdatePhase.Launched -> StatusBlock(
            modifier,
            title = "Ready to install",
            body = "Follow the system prompts to finish updating.",
            accent = Color(0xFF4CAF50),
        )

        is UpdatePhase.Failed -> StatusBlock(
            modifier,
            title = "Update failed",
            body = phase.message,
            accent = Color(0xFFE53935),
        )
    }
}

@Composable
private fun StatusBlock(
    modifier: Modifier = Modifier,
    title: String,
    trailing: String = "",
    body: String? = null,
    accent: Color = Color.White,
    content: (@Composable () -> Unit)? = null,
) {
    Column(modifier = modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = title,
                color = accent,
                fontSize = 15.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.weight(1f),
            )
            if (trailing.isNotEmpty()) {
                Text(
                    text = trailing,
                    color = Color.White,
                    fontSize = 15.sp,
                    fontWeight = FontWeight.Bold,
                )
            }
        }
        if (body != null) {
            Spacer(Modifier.height(6.dp))
            Text(
                text = body,
                color = Color.White.copy(alpha = 0.7f),
                fontSize = 13.sp,
                lineHeight = 18.sp,
            )
        }
        if (content != null) {
            Spacer(Modifier.height(10.dp))
            content()
        }
    }
}

@Composable
fun UpdateProgressBar(progress: Float, label: String = "") {
    val indeterminate = progress < 0f
    val fraction = progress.coerceIn(0f, 1f)
    Column(modifier = Modifier.fillMaxWidth()) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(6.dp)
                .clip(RoundedCornerShape(3.dp))
                .background(Color(0x30FFFFFF)),
        ) {
            Box(
                modifier = Modifier
                    .fillMaxWidth(if (indeterminate) 0.35f else fraction)
                    .height(6.dp)
                    .clip(RoundedCornerShape(3.dp))
                    .background(Color(0xFF4CAF50)),
            )
        }
        if (label.isNotEmpty()) {
            Spacer(Modifier.height(6.dp))
            Text(
                text = label,
                color = Color.White.copy(alpha = 0.55f),
                fontSize = 12.sp,
            )
        }
    }
}
