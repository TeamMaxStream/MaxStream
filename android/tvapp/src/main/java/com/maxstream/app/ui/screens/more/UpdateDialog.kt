package com.maxstream.app.ui.screens.more

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
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

// ─────────────────────────────────────────────────────────────────────────────
// Startup update dialog — TV mirror of Dart's `_showUpdateDialog`
// (maxstream_main_screen.dart): "Update to vX", What's New with scrollable
// release notes, Later / Update Now. Update Now downloads the APK in-app and
// hands it straight to the system installer.
// ─────────────────────────────────────────────────────────────────────────────

@Composable
fun UpdateDialog(
    info: UpdateRepository.UpdateInfo,
    controller: UpdateInstallController,
    onDismiss: () -> Unit,
) {
    val context = LocalContext.current
    val phase = controller.phase
    val busy = phase is UpdatePhase.Downloading || phase is UpdatePhase.Installing
    val noteScrollState = rememberScrollState()
    val notes = remember(info.changelog) { parseReleaseNotes(info.changelog) }

    val confirmFocus = remember { FocusRequester() }
    val dismissFocus = remember { FocusRequester() }

    // D-pad starts on the affirmative action for the current step, re-seeding
    // whenever the button set changes.
    LaunchedEffect(phase) {
        val target = when (phase) {
            UpdatePhase.Installing -> null
            UpdatePhase.NeedsPermission, UpdatePhase.Launched -> dismissFocus
            else -> confirmFocus
        } ?: return@LaunchedEffect
        var attempt = 0
        while (attempt < 6) {
            if (attempt > 0) delay(60L * attempt)
            if (runCatching { target.requestFocus() }.isSuccess) break
            attempt++
        }
    }

    AlertDialog(
        onDismissRequest = { if (!busy) onDismiss() },
        containerColor = Color(0xFF1E1E1E),
        title = {
            Text(
                text = "Update to v${info.version}",
                color = Color.White,
                fontSize = 22.sp,
                fontWeight = FontWeight.Bold,
            )
        },
        text = {
            Column(modifier = Modifier.fillMaxWidth()) {
                when (phase) {
                    UpdatePhase.Idle -> {
                        Text(
                            text = "A new version is available. Would you like to download it?",
                            color = Color.White.copy(alpha = 0.85f),
                            fontSize = 15.sp,
                            lineHeight = 21.sp,
                        )
                        if (info.changelog.isNotBlank()) {
                            Spacer(Modifier.height(14.dp))
                            Text(
                                text = "What's New:",
                                color = Color.White,
                                fontSize = 15.sp,
                                fontWeight = FontWeight.Bold,
                            )
                            Spacer(Modifier.height(8.dp))
                            DpadScrollableNotes(
                                scrollState = noteScrollState,
                                blocks = notes,
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .heightIn(max = 260.dp)
                                    .verticalScroll(noteScrollState),
                                emptyText = info.changelog,
                            )
                        }
                    }

                    is UpdatePhase.Failed -> {
                        Text(
                            text = "Something went wrong while updating.",
                            color = Color(0xFFE53935),
                            fontSize = 15.sp,
                        )
                        Spacer(Modifier.height(6.dp))
                        Text(
                            text = phase.message,
                            color = Color.White.copy(alpha = 0.75f),
                            fontSize = 13.sp,
                            lineHeight = 18.sp,
                        )
                    }

                    UpdatePhase.NeedsPermission -> {
                        Text(
                            text = "Allow MaxStream to install unknown apps, then press " +
                                "Install again to finish updating.",
                            color = Color.White.copy(alpha = 0.85f),
                            fontSize = 15.sp,
                            lineHeight = 21.sp,
                        )
                    }

                    UpdatePhase.Launched -> {
                        Text(
                            text = "Follow the system prompts to finish updating.",
                            color = Color(0xFF4CAF50),
                            fontSize = 15.sp,
                            lineHeight = 21.sp,
                        )
                    }

                    UpdatePhase.Installing -> {
                        Text(
                            text = "Handing the update over to Android...",
                            color = Color.White.copy(alpha = 0.85f),
                            fontSize = 15.sp,
                            lineHeight = 21.sp,
                        )
                    }

                    else -> Unit
                }

                if (phase is UpdatePhase.Downloading || phase is UpdatePhase.Installing) {
                    Spacer(Modifier.height(16.dp))
                    UpdateProgressContent(phase)
                }
            }
        },
        confirmButton = {
            when (phase) {
                UpdatePhase.Idle -> DialogButton(
                    label = "Update Now",
                    primary = true,
                    focusRequester = confirmFocus,
                    onClick = { controller.start(context, info) },
                )

                is UpdatePhase.Downloading -> DialogButton(
                    label = "Cancel",
                    focusRequester = confirmFocus,
                    onClick = { controller.reset() },
                )

                UpdatePhase.NeedsPermission -> DialogButton(
                    label = "Install Again",
                    primary = true,
                    focusRequester = confirmFocus,
                    onClick = { controller.retryInstall(context) },
                )

                is UpdatePhase.Failed -> DialogButton(
                    label = "Try Again",
                    primary = true,
                    focusRequester = confirmFocus,
                    onClick = { controller.start(context, info) },
                )

                else -> Unit
            }
        },
        dismissButton = {
            when (phase) {
                UpdatePhase.Idle -> DialogButton(
                    label = "Later",
                    focusRequester = dismissFocus,
                    onClick = onDismiss,
                )

                UpdatePhase.NeedsPermission -> DialogButton(
                    label = "Allow Permission",
                    focusRequester = dismissFocus,
                    onClick = { controller.allowPermission(context) },
                )

                UpdatePhase.Launched, is UpdatePhase.Failed -> DialogButton(
                    label = "Close",
                    focusRequester = dismissFocus,
                    onClick = onDismiss,
                )

                else -> Unit
            }
        },
    )
}

@Composable
private fun DialogButton(
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
    TextButton(
        onClick = onClick,
        modifier = Modifier
            .focusRequester(focusRequester)
            .onFocusChanged { focused = it.isFocused }
            // Focus must be registered BEFORE the button so D-pad Enter fires.
            .focusable()
            .clip(RoundedCornerShape(18.dp))
            .background(background)
            .border(
                width = if (focused) 2.dp else 0.dp,
                color = if (focused) Color.White else Color.Transparent,
                shape = RoundedCornerShape(18.dp),
            ),
    ) {
        Text(
            text = label,
            color = if (focused) Color.Black else Color.White,
            fontSize = 15.sp,
            fontWeight = if (focused || primary) FontWeight.Bold else FontWeight.Normal,
        )
    }
}
