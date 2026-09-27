package com.maxstream.app.ui.screens

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.maxstream.app.resources.Res
import com.maxstream.app.resources.maxstream_logo
import org.jetbrains.compose.resources.painterResource
import kotlinx.coroutines.delay

/**
 * Desktop splash — black canvas, wordmark fade-in and a red spinner, matching
 * the mobile (1500ms) and TV (1800ms) splash timing before auth/profile routing.
 */
@Composable
fun SplashScreen(onDone: () -> Unit) {
    var started by remember { mutableStateOf(false) }
    val logoAlpha by animateFloatAsState(
        targetValue = if (started) 1f else 0f,
        animationSpec = tween(700),
        label = "splashLogo",
    )

    LaunchedEffect(Unit) {
        started = true
        delay(1500)
        onDone()
    }

    Box(
        Modifier
            .fillMaxSize()
            .background(Color(0xFF0D0D0F)),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
            modifier = Modifier.alpha(logoAlpha),
        ) {
            Image(
                painter = painterResource(Res.drawable.maxstream_logo),
                contentDescription = "MaxStream",
                modifier = Modifier.height(72.dp),
            )
            Spacer(Modifier.height(28.dp))
            CircularProgressIndicator(
                modifier = Modifier.size(34.dp),
                color = MaterialTheme.colorScheme.primary,
                strokeWidth = 3.dp,
            )
            Spacer(Modifier.height(18.dp))
            Text(
                "MAXSTREAM",
                color = Color.White.copy(alpha = 0.45f),
                fontSize = 12.sp,
                letterSpacing = 4.sp,
                fontWeight = FontWeight.Medium,
            )
        }
    }
}
