package com.maxstream.app.ui.screens

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Tab
import androidx.compose.material3.TabRow
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
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.maxstream.app.data.cloud.AppSession
import com.maxstream.app.resources.Res
import com.maxstream.app.resources.background
import com.maxstream.app.resources.maxstream_logo
import org.jetbrains.compose.resources.painterResource
import com.maxstream.app.ui.components.appFocusRing
import com.maxstream.app.ui.theme.AppColors
import kotlinx.coroutines.launch

/**
 * Desktop auth — Sign in / Sign Up over the mobile background image with a
 * frosted glass card and MaxStream red branding (same flow as the phone app).
 */
@Composable
fun AuthScreen(onSuccess: () -> Unit) {
    var mode by remember { mutableStateOf(0) } // 0 = sign in, 1 = sign up, 2 = forgot password
    var email by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var showPassword by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var notice by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()

    var entered by remember { mutableStateOf(false) }
    val cardAlpha by animateFloatAsState(if (entered) 1f else 0f, tween(600), label = "authCard")
    LaunchedEffect(Unit) { entered = true }

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        Image(
            painter = painterResource(Res.drawable.background),
            contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier = Modifier.fillMaxSize(),
        )
        Box(
            Modifier.fillMaxSize().background(
                Brush.verticalGradient(
                    listOf(Color.Black.copy(alpha = 0.35f), Color.Black.copy(alpha = 0.75f)),
                ),
            ),
        )

        // Responsive + scrollable: the card was a fixed 440dp with no scroll,
        // so short or narrow windows clipped the form.
        Column(
            Modifier.fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(32.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                modifier = Modifier
                    .fillMaxWidth()
                    .widthIn(max = 440.dp)
                    .alpha(cardAlpha)
                    .clip(RoundedCornerShape(24.dp))
                    .background(Color.White.copy(alpha = 0.10f))
                    .border(1.dp, Color.White.copy(alpha = 0.28f), RoundedCornerShape(24.dp))
                    .padding(28.dp),
            ) {
                Image(
                    painter = painterResource(Res.drawable.maxstream_logo),
                    contentDescription = "MaxStream",
                    modifier = Modifier.height(56.dp),
                )
                Spacer(Modifier.height(16.dp))
                Text(
                    when (mode) {
                        1 -> "Create Account"
                        2 -> "Reset Password"
                        else -> "Welcome Back!"
                    },
                    color = Color.White,
                    fontSize = 26.sp,
                    fontWeight = FontWeight.Bold,
                )
                Spacer(Modifier.height(16.dp))

                if (mode != 2) {
                    TabRow(
                        selectedTabIndex = mode,
                        containerColor = Color.Transparent,
                        contentColor = MaterialTheme.colorScheme.primary,
                        indicator = {},
                        divider = {},
                    ) {
                        Tab(selected = mode == 0, onClick = { mode = 0; error = null; notice = null }) {
                            Text(
                                "Sign In",
                                color = if (mode == 0) Color.White else Color.White.copy(alpha = 0.55f),
                                fontWeight = if (mode == 0) FontWeight.Bold else FontWeight.Normal,
                                modifier = Modifier.padding(vertical = 10.dp),
                            )
                        }
                        Tab(selected = mode == 1, onClick = { mode = 1; error = null; notice = null }) {
                            Text(
                                "Sign Up",
                                color = if (mode == 1) Color.White else Color.White.copy(alpha = 0.55f),
                                fontWeight = if (mode == 1) FontWeight.Bold else FontWeight.Normal,
                                modifier = Modifier.padding(vertical = 10.dp),
                            )
                        }
                    }
                    Spacer(Modifier.height(14.dp))
                } else {
                    Text(
                        "Enter your email and we'll send a reset link.",
                        color = Color.White.copy(alpha = 0.7f),
                        fontSize = 13.sp,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Spacer(Modifier.height(14.dp))
                }

                if (busy) {
                    CircularProgressIndicator(color = Color.White, modifier = Modifier.size(36.dp))
                    Spacer(Modifier.height(20.dp))
                } else {
                    OutlinedTextField(
                        value = email,
                        onValueChange = { email = it },
                        label = { Text("Email", color = Color.White) },
                        singleLine = true,
                        textStyle = MaterialTheme.typography.bodyMedium.copy(color = Color.White),
                        colors = authFieldColors(),
                        modifier = Modifier.fillMaxWidth(),
                    )
                    if (mode != 2) {
                        Spacer(Modifier.height(12.dp))
                        OutlinedTextField(
                            value = password,
                            onValueChange = { password = it },
                            label = { Text("Password", color = Color.White) },
                            singleLine = true,
                            visualTransformation = if (showPassword) VisualTransformation.None else PasswordVisualTransformation(),
                            trailingIcon = {
                                IconButton(onClick = { showPassword = !showPassword }) {
                                    Icon(
                                        if (showPassword) Icons.Default.VisibilityOff else Icons.Default.Visibility,
                                        contentDescription = "Toggle password",
                                        tint = Color.White,
                                    )
                                }
                            },
                            textStyle = MaterialTheme.typography.bodyMedium.copy(color = Color.White),
                            colors = authFieldColors(),
                            modifier = Modifier.fillMaxWidth(),
                        )
                        if (mode == 0) {
                            Spacer(Modifier.height(8.dp))
                            Row(
                                Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.End,
                            ) {
                                Text(
                                    "Forgot password?",
                                    color = MaterialTheme.colorScheme.primary,
                                    fontSize = 13.sp,
                                    fontWeight = FontWeight.SemiBold,
                                    modifier = Modifier
                                        .clickable {
                                            mode = 2
                                            error = null
                                            notice = null
                                        }
                                        .appFocusRing(cornerRadius = 4.dp)
                                        .padding(4.dp),
                                )
                            }
                        }
                    }
                    if (error != null) {
                        Spacer(Modifier.height(10.dp))
                        Text(
                            error.orEmpty(),
                            color = AppColors.errorBright,
                            fontSize = 13.sp,
                            textAlign = TextAlign.Center,
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                    if (notice != null) {
                        Spacer(Modifier.height(10.dp))
                        Text(
                            notice.orEmpty(),
                            color = AppColors.success,
                            fontSize = 13.sp,
                            textAlign = TextAlign.Center,
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                    Spacer(Modifier.height(16.dp))
                    Button(
                        enabled = !busy,
                        onClick = {
                            busy = true
                            error = null
                            notice = null
                            scope.launch {
                                if (mode == 2) {
                                    AppSession.sendPasswordReset(email)
                                        .onSuccess {
                                            notice = "Password reset email sent!"
                                        }
                                        .onFailure { e ->
                                            error = e.message ?: "Could not send reset email."
                                        }
                                    busy = false
                                } else {
                                    val result = try {
                                        if (mode == 0) {
                                            AppSession.signIn(email, password)
                                        } else {
                                            AppSession.signUp(email, password)
                                        }
                                    } catch (e: Exception) {
                                        Result.failure(e)
                                    }
                                    result.onFailure { e ->
                                        error = e.message
                                            ?.takeIf { !it.startsWith("A JSON") && !it.contains("character") }
                                            ?: "Could not reach MaxStream. Check your connection and try again."
                                    }
                                    busy = false
                                    if (result.isSuccess) onSuccess()
                                }
                            }
                        },
                        shape = RoundedCornerShape(10.dp),
                        colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.primary),
                        modifier = Modifier.fillMaxWidth().height(48.dp),
                    ) {
                        Text(
                            when (mode) {
                                1 -> "Create Account"
                                2 -> "Send Reset Link"
                                else -> "Sign In"
                            },
                            fontWeight = FontWeight.Bold,
                            fontSize = 15.sp,
                        )
                    }
                    Spacer(Modifier.height(12.dp))
                    OutlinedButton(
                        enabled = !busy,
                        onClick = {
                            error = null
                            notice = null
                            mode = if (mode == 2) 0 else if (mode == 0) 1 else 0
                        },
                        shape = RoundedCornerShape(10.dp),
                        modifier = Modifier.fillMaxWidth().height(46.dp),
                    ) {
                        Text(
                            when (mode) {
                                1 -> "Already have an account? Sign In"
                                2 -> "Back to Sign In"
                                else -> "New to MaxStream? Sign Up"
                            },
                            color = Color.White.copy(alpha = 0.85f),
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun authFieldColors() = OutlinedTextFieldDefaults.colors(
    focusedBorderColor = MaterialTheme.colorScheme.primary,
    unfocusedBorderColor = Color.White.copy(alpha = 0.45f),
    focusedLabelColor = Color.White,
    unfocusedLabelColor = Color.White.copy(alpha = 0.75f),
    cursorColor = Color.White,
    focusedContainerColor = Color.Transparent,
    unfocusedContainerColor = Color.Transparent,
)
