package com.maxstream.app.ui.screens.more

import android.content.Intent
import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.maxstream.app.data.repository.UpdateRepository
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

private data class UpdateAction(
    val label: String,
    val primary: Boolean = false,
    val onClick: () -> Unit,
)

/**
 * More → Updates.
 *
 * Shows current vs latest version, downloads the TV APK in-app and hands it to
 * the system installer (same flow as the phone app), renders the GitHub release
 * notes as organised markdown blocks, and offers an auto-check toggle.
 */
@Composable
fun UpdatesScreen(onBack: () -> Unit = {}) {
    BackHandler { onBack() }

    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val scrollState = rememberScrollState()
    val controller = rememberUpdateInstallController()

    val currentVersion = remember { UpdateRepository.currentVersion(context) }
    var updateInfo by remember { mutableStateOf<UpdateRepository.UpdateInfo?>(null) }
    var loading by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var checkedOnce by remember { mutableStateOf(false) }
    var autoCheck by remember {
        mutableStateOf(UpdateRepository.isAutoCheckEnabled(context))
    }

    val phase = controller.phase
    val busy = phase is UpdatePhase.Downloading ||
        phase is UpdatePhase.Installing ||
        phase is UpdatePhase.Launched

    val notes = remember(updateInfo?.changelog) {
        parseReleaseNotes(updateInfo?.changelog.orEmpty())
    }

    fun runCheck() {
        if (loading || busy) return
        loading = true
        error = null
        scope.launch {
            try {
                updateInfo = UpdateRepository.checkForUpdate(context)
                checkedOnce = true
            } catch (e: Exception) {
                error = e.message ?: "Failed to check for updates"
            } finally {
                loading = false
            }
        }
    }

    fun primaryAction() {
        when (phase) {
            UpdatePhase.NeedsPermission -> controller.allowPermission(context)
            UpdatePhase.Launched -> controller.retryInstall(context)
            is UpdatePhase.Downloading, is UpdatePhase.Installing -> Unit
            else -> updateInfo?.let { controller.start(context, it) }
        }
    }

    fun secondaryAction() {
        when (phase) {
            UpdatePhase.NeedsPermission -> controller.retryInstall(context)
            is UpdatePhase.Downloading -> controller.reset()
            else -> runCheck()
        }
    }

    LaunchedEffect(Unit) { runCheck() }

    // Seed D-pad focus on the primary action once the check settles; the notes
    // block below is reachable by pressing DOWN.
    val actionFocus = remember { List(3) { FocusRequester() } }
    LaunchedEffect(loading, checkedOnce, updateInfo) {
        if (loading) return@LaunchedEffect
        var attempt = 0
        while (attempt < 6) {
            if (attempt > 0) delay(60L * attempt)
            if (runCatching { actionFocus[0].requestFocus() }.isSuccess) return@LaunchedEffect
            attempt++
        }
    }

    val actions = listOf(
        UpdateAction(
            label = when (phase) {
                is UpdatePhase.Downloading -> "Downloading..."
                is UpdatePhase.Installing -> "Installing..."
                UpdatePhase.Launched -> "Open Installer"
                UpdatePhase.NeedsPermission -> "Allow Permission"
                else -> "Download & Install"
            },
            primary = true,
            onClick = ::primaryAction,
        ),
        UpdateAction(
            label = when (phase) {
                is UpdatePhase.Downloading -> "Cancel"
                UpdatePhase.NeedsPermission -> "Install Again"
                else -> "Check again"
            },
            onClick = ::secondaryAction,
        ),
        UpdateAction("Website") {
            runCatching {
                val url = updateInfo?.releaseUrl ?: UpdateRepository.releasesUrl
                context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
            }
        },
    )

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color(0xFF121212)),
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(horizontal = 48.dp, vertical = 40.dp)
                .verticalScroll(scrollState),
        ) {
            Text(
                text = "Updates",
                color = Color.White,
                fontSize = 28.sp,
                fontWeight = FontWeight.Bold,
            )
            Spacer(Modifier.height(8.dp))
            Text(
                text = "Current version: $currentVersion" +
                    (updateInfo?.let { "   •   Latest: ${it.version}" } ?: ""),
                color = Color.Gray,
                fontSize = 14.sp,
            )
            Spacer(Modifier.height(24.dp))

            when {
                loading -> Text(
                    text = "Checking for updates...",
                    color = Color.Gray,
                    fontSize = 16.sp,
                )

                error != null -> {
                    Text(
                        text = "Couldn't check for updates",
                        color = Color(0xFFE53935),
                        fontSize = 18.sp,
                        fontWeight = FontWeight.Bold,
                    )
                    Spacer(Modifier.height(6.dp))
                    Text(
                        text = error ?: "",
                        color = Color.White.copy(alpha = 0.7f),
                        fontSize = 14.sp,
                        lineHeight = 20.sp,
                    )
                    Spacer(Modifier.height(16.dp))
                    UpdateButton(
                        label = "Try Again",
                        primary = true,
                        focusRequester = actionFocus[0],
                        onClick = { error = null; runCheck() },
                    )
                }

                updateInfo != null -> {
                    val info = updateInfo!!
                    Text(
                        text = "Update Available",
                        color = Color(0xFF4CAF50),
                        fontSize = 20.sp,
                        fontWeight = FontWeight.Bold,
                    )
                    Spacer(Modifier.height(6.dp))
                    Text(
                        text = buildString {
                            append("Version ${info.version}")
                            if (info.sizeBytes > 0) {
                                append("   •   ")
                                append("${info.sizeBytes / (1024 * 1024)} MB")
                            }
                            if (info.publishedAt.isNotBlank()) {
                                append("   •   ")
                                append(info.publishedAt.take(10))
                            }
                        },
                        color = Color.White.copy(alpha = 0.75f),
                        fontSize = 14.sp,
                    )
                    Spacer(Modifier.height(16.dp))

                    if (phase !is UpdatePhase.Idle) {
                        UpdateProgressContent(phase)
                        Spacer(Modifier.height(16.dp))
                    }

                    Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                        actions.forEachIndexed { index, action ->
                            UpdateButton(
                                label = action.label,
                                primary = action.primary,
                                focusRequester = actionFocus[index],
                                onClick = action.onClick,
                            )
                        }
                    }

                    if (info.changelog.isNotBlank()) {
                        Spacer(Modifier.height(24.dp))
                        Text(
                            text = "What's New",
                            color = Color.White,
                            fontSize = 17.sp,
                            fontWeight = FontWeight.SemiBold,
                        )
                        Spacer(Modifier.height(8.dp))
                        DpadScrollableNotes(
                            scrollState = scrollState,
                            blocks = notes,
                            modifier = Modifier.fillMaxWidth(),
                            emptyText = info.changelog,
                        )
                    }
                }

                else -> {
                    Text(
                        text = "You're up to date!",
                        color = Color(0xFF4CAF50),
                        fontSize = 20.sp,
                        fontWeight = FontWeight.Bold,
                    )
                    Spacer(Modifier.height(8.dp))
                    Text(
                        text = "Version $currentVersion is the latest release.",
                        color = Color.Gray,
                        fontSize = 16.sp,
                    )
                    if (checkedOnce) {
                        Spacer(Modifier.height(4.dp))
                        Text(
                            text = "Last checked just now",
                            color = Color.White.copy(alpha = 0.45f),
                            fontSize = 13.sp,
                        )
                    }
                    Spacer(Modifier.height(16.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                        UpdateButton(
                            label = "Check again",
                            primary = true,
                            focusRequester = actionFocus[0],
                            onClick = ::runCheck,
                        )
                        UpdateButton(
                            label = "Website",
                            focusRequester = actionFocus[1],
                            onClick = {
                                runCatching {
                                    context.startActivity(
                                        Intent(
                                            Intent.ACTION_VIEW,
                                            Uri.parse(UpdateRepository.releasesUrl),
                                        ),
                                    )
                                }
                            },
                        )
                    }
                }
            }

            Spacer(Modifier.height(32.dp))
            AutoCheckRow(
                checked = autoCheck,
                onToggle = {
                    autoCheck = !autoCheck
                    UpdateRepository.setAutoCheckEnabled(context, autoCheck)
                },
            )
            Spacer(Modifier.height(24.dp))
        }
    }
}

@Composable
private fun UpdateButton(
    label: String,
    primary: Boolean = false,
    focusRequester: FocusRequester,
    onClick: () -> Unit,
) {
    var focused by remember { mutableStateOf(false) }
    val background = when {
        focused && primary -> Color.White
        focused -> Color(0xFF2A2A2A)
        primary -> Color(0xFF4CAF50)
        else -> Color(0x18FFFFFF)
    }
    val textColor = when {
        focused -> Color.Black
        else -> Color.White
    }
    Text(
        text = label,
        color = textColor,
        fontSize = 15.sp,
        fontWeight = if (focused || primary) FontWeight.Bold else FontWeight.Normal,
        modifier = Modifier
            .focusRequester(focusRequester)
            .onFocusChanged { focused = it.isFocused }
            // Focus must be registered BEFORE clickable so D-pad Enter fires.
            .focusable()
            .clickable(onClick = onClick)
            .clip(RoundedCornerShape(20.dp))
            .background(background)
            .border(
                width = if (focused) 2.dp else 1.dp,
                color = if (focused) Color.White else Color(0x40FFFFFF),
                shape = RoundedCornerShape(20.dp),
            )
            .padding(horizontal = 22.dp, vertical = 11.dp),
    )
}

@Composable
private fun AutoCheckRow(checked: Boolean, onToggle: () -> Unit) {
    var focused by remember { mutableStateOf(false) }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(if (focused) Color(0xFF1E1E1E) else Color.Transparent)
            .onFocusChanged { focused = it.isFocused }
            // Focus must be registered BEFORE clickable so D-pad Enter fires.
            .focusable()
            .clickable(onClick = onToggle)
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = "Auto-check for updates",
                color = Color.White,
                fontSize = 15.sp,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                text = "Check for a new version when the app starts",
                color = Color.Gray,
                fontSize = 13.sp,
            )
        }
        Box(
            modifier = Modifier
                .width(46.dp)
                .height(26.dp)
                .clip(RoundedCornerShape(13.dp))
                .background(if (checked) Color(0xFF4CAF50) else Color(0x40FFFFFF)),
        ) {
            Box(
                modifier = Modifier
                    .align(if (checked) Alignment.CenterEnd else Alignment.CenterStart)
                    .padding(horizontal = 2.dp)
                    .size(22.dp)
                    .clip(RoundedCornerShape(11.dp))
                    .background(Color.White),
            )
        }
    }
}
