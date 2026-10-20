package com.maxstream.app.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Download
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.maxstream.app.update.UpdateService

/**
 * Slim startup banner when GitHub publishes a newer desktop MSI. It only
 * routes to Settings, where downloading/installing (and the release notes)
 * live; dismissing hides it for the rest of this launch.
 */
@Composable
fun UpdateBanner(
    onOpenSettings: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val info = UpdateService.available ?: return
    if (UpdateService.bannerDismissed) return

    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.primary.copy(alpha = 0.12f))
            .padding(horizontal = 14.dp, vertical = 6.dp),
    ) {
        Icon(
            Icons.Default.Download,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.primary,
            modifier = Modifier.size(18.dp),
        )
        Spacer(Modifier.width(10.dp))
        Text(
            "MaxStream ${info.version} is available",
            color = MaterialTheme.colorScheme.onSurface,
            fontWeight = FontWeight.SemiBold,
            style = MaterialTheme.typography.bodySmall,
        )
        Spacer(Modifier.weight(1f))
        TextButton(onClick = onOpenSettings) {
            Text("Update", color = MaterialTheme.colorScheme.primary, fontWeight = FontWeight.SemiBold)
        }
        IconButton(
            onClick = { UpdateService.dismissBanner() },
            modifier = Modifier.size(30.dp),
        ) {
            Icon(
                Icons.Default.Close,
                contentDescription = "Dismiss update",
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(16.dp),
            )
        }
    }
}
