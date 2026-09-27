package com.maxstream.app.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Logout
import androidx.compose.material.icons.filled.CloudDone
import androidx.compose.material.icons.filled.DarkMode
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.LightMode
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.maxstream.app.data.AppPrefs
import com.maxstream.app.data.cloud.AppSession
import com.maxstream.app.data.cloud.ProfileStore
import com.maxstream.app.core.AppConfig
import com.maxstream.app.ui.components.ScrollableColumn
import com.maxstream.app.ui.components.appFocusRing
import com.maxstream.app.ui.theme.AppSpacing
import kotlinx.coroutines.launch

/**
 * Desktop settings: account (incl. sign-out), appearance, streaming quality,
 * profiles, and About. Mirrors the phone app's More hub sections that make
 * sense without mobile-only features (downloads, biometrics, updates).
 */
@Composable
fun SettingsScreen(
    useDarkTheme: Boolean,
    onThemeChange: (Boolean) -> Unit,
    onSignOut: () -> Unit,
    onManageProfiles: () -> Unit,
) {
    var quality by remember { mutableStateOf(AppPrefs.defaultQuality) }
    var menuOpen by remember { mutableStateOf(false) }
    var confirmSignOut by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    ScrollableColumn(contentPadding = PaddingValues(AppSpacing.xl)) {
        Text(
            "Settings",
            style = MaterialTheme.typography.headlineSmall,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurface,
        )
        Spacer(Modifier.height(AppSpacing.gutter))

        SettingRow("Account") {
            AccountSection(onSignOut = { confirmSignOut = true })
        }

        Spacer(Modifier.height(16.dp))

        SettingRow("Appearance") {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    if (useDarkTheme) Icons.Default.DarkMode else Icons.Default.LightMode,
                    null,
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.width(20.dp),
                )
                Spacer(Modifier.width(10.dp))
                Text(
                    "Dark theme",
                    color = MaterialTheme.colorScheme.onSurface,
                    modifier = Modifier.width(200.dp),
                )
                Switch(checked = useDarkTheme, onCheckedChange = onThemeChange)
            }
        }

        Spacer(Modifier.height(16.dp))

        SettingRow("Streaming") {
            Column {
                Text(
                    "Default quality",
                    color = MaterialTheme.colorScheme.onSurface,
                    modifier = Modifier.width(200.dp),
                )
                Spacer(Modifier.height(6.dp))
                OutlinedButton(onClick = { menuOpen = true }, modifier = Modifier.appFocusRing(cornerRadius = 8.dp)) {
                    Text(quality, color = MaterialTheme.colorScheme.onSurface)
                }
                DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                    listOf("Auto", "480p", "720p", "1080p", "4K").forEach { option ->
                        DropdownMenuItem(
                            text = { Text(option, color = MaterialTheme.colorScheme.onSurface) },
                            onClick = {
                                quality = option
                                AppPrefs.setDefaultQuality(option)
                                menuOpen = false
                            },
                        )
                    }
                }
                Spacer(Modifier.height(4.dp))
                Text(
                    "Used when a server offers multiple renditions.",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    fontSize = 12.sp,
                )
            }
        }

        Spacer(Modifier.height(16.dp))

        SettingRow("Profiles") {
            Column {
                Text(
                    ProfileStore.activeProfile?.name ?: "No profile selected",
                    color = MaterialTheme.colorScheme.onSurface,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 14.sp,
                )
                Spacer(Modifier.height(2.dp))
                Text(
                    "${ProfileStore.profiles.size} of ${ProfileStore.MAX_PROFILES} profiles",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    fontSize = 12.sp,
                )
                Spacer(Modifier.height(10.dp))
                OutlinedButton(onClick = onManageProfiles, modifier = Modifier.appFocusRing(cornerRadius = 8.dp)) {
                    Text("Manage profiles", color = MaterialTheme.colorScheme.onSurface)
                }
            }
        }

        Spacer(Modifier.height(16.dp))

        SettingRow("About") {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    Icons.Default.Info,
                    null,
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.width(20.dp),
                )
                Spacer(Modifier.width(10.dp))
                Column {
                    Text(
                        "MaxStream Desktop",
                        color = MaterialTheme.colorScheme.onSurface,
                        fontWeight = FontWeight.SemiBold,
                        fontSize = 14.sp,
                    )
                    Text(
                        "Version ${AppConfig.APP_VERSION}  •  Stream movies & series free",
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        fontSize = 12.sp,
                    )
                    Text(
                        "Catalog by TMDB  •  Sync via Firebase",
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        fontSize = 12.sp,
                    )
                }
            }
        }
    }

    if (confirmSignOut) {
        AlertDialog(
            onDismissRequest = { confirmSignOut = false },
            containerColor = MaterialTheme.colorScheme.surface,
            title = { Text("Sign Out", color = MaterialTheme.colorScheme.onSurface) },
            text = {
                Text(
                    "Are you sure you want to sign out? Your watchlist stays in the cloud.",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        confirmSignOut = false
                        scope.launch {
                            runCatching { AppSession.signOut() }
                            runCatching { ProfileStore.clear() }
                            onSignOut()
                        }
                    },
                ) {
                    Text("Sign Out", color = MaterialTheme.colorScheme.primary)
                }
            },
            dismissButton = {
                TextButton(onClick = { confirmSignOut = false }) {
                    Text("Cancel", color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            },
        )
    }
}

/** Signed-in identity + destructive sign-out (mobile More hub parity). */
@Composable
private fun AccountSection(onSignOut: () -> Unit) {
    val user = AppSession.user
    val profile = ProfileStore.activeProfile

    if (user != null) {
        Column {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    Icons.Default.CloudDone,
                    null,
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.width(20.dp),
                )
                Spacer(Modifier.width(10.dp))
                Column {
                    Text(
                        profile?.name ?: user.email,
                        color = MaterialTheme.colorScheme.onSurface,
                        fontWeight = FontWeight.SemiBold,
                        fontSize = 14.sp,
                    )
                    Text(
                        if (profile != null && profile.name != user.email) user.email
                        else "Watchlist & progress sync to Firebase",
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        fontSize = 12.sp,
                    )
                }
            }
            Spacer(Modifier.height(12.dp))
            OutlinedButton(onClick = onSignOut, modifier = Modifier.appFocusRing(cornerRadius = 8.dp)) {
                Icon(
                    Icons.AutoMirrored.Filled.Logout,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.width(18.dp),
                )
                Spacer(Modifier.width(8.dp))
                Text("Sign out", color = MaterialTheme.colorScheme.primary)
            }
        }
        return
    }

    Text(
        "Sign in from the launch screen to sync your watchlist and progress across devices.",
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        fontSize = 13.sp,
    )
}

@Composable
private fun SettingRow(
    title: String,
    content: @Composable () -> Unit,
) {
    Column(
        Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surfaceVariant, RoundedCornerShape(10.dp))
            .padding(16.dp),
    ) {
        Text(
            title,
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurface,
        )
        Spacer(Modifier.height(12.dp))
        content()
    }
}
