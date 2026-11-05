package com.maxstream.app.ui.screens.auth

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.scale
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.maxstream.app.R
import com.maxstream.app.data.repository.AuthRepository
import com.maxstream.app.ui.theme.Background
import kotlinx.coroutines.launch

/**
 * TV login screen mirroring the reference app: three tabs
 * (Device Code / Sign In / Sign Up) driven by the D-pad.
 *
 * Text entry uses real [OutlinedTextField]s, so focusing a field brings up the
 * Android TV on-screen keyboard (the platform IME) instead of a custom keypad.
 *
 * Focus model (single index):
 *   0 = tab row (LEFT/RIGHT switches the active tab)
 *   1 = field 1 (code on tab 0, email on tabs 1-2)
 *   2 = field 2 (password on tabs 1-2, submit on tab 0)
 *   3 = submit button (tabs 1-2)
 */
@Composable
fun LoginScreen(onLoginSuccess: () -> Unit) {
    val context = LocalContext.current
    val scope   = rememberCoroutineScope()

    var selectedTab by remember { mutableIntStateOf(0) }   // 0: Device Code, 1: Sign In, 2: Sign Up
    var focusedField by remember { mutableIntStateOf(0) }
    var isLoading   by remember { mutableStateOf(false) }
    var errorMsg    by remember { mutableStateOf<String?>(null) }
    var successMsg  by remember { mutableStateOf<String?>(null) }

    var code     by remember { mutableStateOf("") }
    var email    by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }

    val keyboardController = LocalSoftwareKeyboardController.current

    val tabsRequester   = remember { FocusRequester() }
    val field1Requester = remember { FocusRequester() }
    val field2Requester = remember { FocusRequester() }
    val submitRequester = remember { FocusRequester() }

    val maxField = if (selectedTab == 0) 2 else 3

    fun requestFocus(field: Int) {
        when (field) {
            0 -> runCatching { tabsRequester.requestFocus() }
            1 -> runCatching { field1Requester.requestFocus() }
            2 -> if (selectedTab == 0) runCatching { submitRequester.requestFocus() }
                else runCatching { field2Requester.requestFocus() }
            3 -> runCatching { submitRequester.requestFocus() }
        }
    }

    fun moveFocus(delta: Int) {
        focusedField = (focusedField + delta).coerceIn(0, maxField)
        requestFocus(focusedField)
    }

    fun resetForTabChange() {
        keyboardController?.hide()
        focusedField = 0
        errorMsg = null
        successMsg = null
        requestFocus(0)
    }

    fun submit() {
        when (selectedTab) {
            0 -> scope.launch {
                val c = code.trim()
                if (c.isEmpty()) { errorMsg = "Please enter your device code"; return@launch }
                isLoading = true; errorMsg = null
                val result = AuthRepository.authenticateWithDeviceCode(c)
                isLoading = false
                result.fold(
                    onSuccess = { session ->
                        AuthRepository.completeSignIn(context, session)
                        onLoginSuccess()
                    },
                    onFailure = { errorMsg = it.message ?: "Invalid code" },
                )
            }
            1 -> scope.launch {
                val e = email.trim()
                val p = password
                if (e.isEmpty() || p.isEmpty()) { errorMsg = "Please enter your email and password"; return@launch }
                keyboardController?.hide()
                isLoading = true; errorMsg = null
                val result = AuthRepository.signInWithEmail(e, p)
                isLoading = false
                result.fold(
                    onSuccess = { session ->
                        AuthRepository.completeSignIn(context, session)
                        onLoginSuccess()
                    },
                    onFailure = { errorMsg = it.message ?: "Login failed" },
                )
            }
            else -> scope.launch {
                val e = email.trim()
                val p = password
                if (e.isEmpty() || p.isEmpty()) { errorMsg = "Please enter your email and password"; return@launch }
                if (p.length < 6) { errorMsg = "Password must be at least 6 characters"; return@launch }
                keyboardController?.hide()
                isLoading = true; errorMsg = null
                val result = AuthRepository.signUpWithEmail(e, p)
                isLoading = false
                result.fold(
                    onSuccess = { session ->
                        AuthRepository.completeSignIn(context, session)
                        onLoginSuccess()
                    },
                    onFailure = { errorMsg = it.message ?: "Sign up failed" },
                )
            }
        }
    }

    val rootRequester = remember { FocusRequester() }

    // Keep a focusable root so D-pad navigation works even when no field/tab
    // is explicitly focused.
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Background)
            .focusRequester(rootRequester)
            .onPreviewKeyEvent { event ->
                if (event.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
                when (event.key) {
                    Key.DirectionUp -> { moveFocus(-1); true }
                    Key.DirectionDown -> { moveFocus(1); true }
                    Key.DirectionLeft -> {
                        if (focusedField == 0) {
                            selectedTab = if (selectedTab == 0) 2 else selectedTab - 1
                            resetForTabChange()
                            true
                        } else {
                            // Let text fields handle cursor movement.
                            false
                        }
                    }
                    Key.DirectionRight -> {
                        if (focusedField == 0) {
                            selectedTab = (selectedTab + 1) % 3
                            resetForTabChange()
                            true
                        } else {
                            false
                        }
                    }
                    Key.Enter -> {
                        when {
                            focusedField == 0 -> { focusedField = 1; requestFocus(1); true }
                            focusedField == maxField -> { submit(); true }
                            else -> { moveFocus(1); true }
                        }
                    }
                    else -> false
                }
            },
    ) {
        // ── Background ─────────────────────────────────────────────────────
        // Full-bleed background image with a horizontal black gradient overlay,
        // mirroring the Dart reference login screen.
        Box(modifier = Modifier.fillMaxSize()) {
            Image(
                painter = painterResource(R.drawable.background),
                contentDescription = null,
                modifier = Modifier
                    .fillMaxSize()
                    .scale(1.1f),
                contentScale = ContentScale.Crop,
            )
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(
                        Brush.horizontalGradient(
                            colors = listOf(
                                Color.Black.copy(alpha = 0.85f),
                                Color.Black.copy(alpha = 0.45f),
                                Color.Black.copy(alpha = 0.85f),
                            ),
                        ),
                    ),
            )
        }

        // Start on the tabs row.
        LaunchedEffect(Unit) {
            kotlinx.coroutines.delay(120)
            runCatching { tabsRequester.requestFocus() }
        }

        Column(
            modifier = Modifier
                .fillMaxSize()
                .imePadding()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 64.dp, vertical = 48.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            // ── Branding ──────────────────────────────────────────────────────
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    modifier = Modifier
                        .size(56.dp)
                        .background(Color(0xFFE50914), RoundedCornerShape(14.dp)),
                    contentAlignment = Alignment.Center,
                ) {
                    Text("M", color = Color.White, fontSize = 30.sp, fontWeight = FontWeight.Black)
                }
                Spacer(Modifier.width(16.dp))
                Column(horizontalAlignment = Alignment.Start) {
                    Text("MAXSTREAM", color = Color.White, fontSize = 24.sp, fontWeight = FontWeight.W900, letterSpacing = 3.sp)
                    Text(
                        when (selectedTab) {
                            0 -> "Sign in on your TV using a code from your phone"
                            1 -> "Welcome back, sign in to continue"
                            else -> "Create your account to get started"
                        },
                        color = Color.White.copy(alpha = 0.5f),
                        fontSize = 14.sp,
                    )
                }
            }

            Spacer(Modifier.height(40.dp))

            // ── Tabs ─────────────────────────────────────────────────────────
            Row(
                modifier = Modifier
                    .width(760.dp)
                    .height(64.dp)
                    .border(
                        width = if (focusedField == 0) 4.dp else 0.dp,
                        color = if (focusedField == 0) Color.White else Color.Transparent,
                        shape = RoundedCornerShape(12.dp),
                    )
                    .focusRequester(tabsRequester)
                    .padding(4.dp),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                val labels = listOf("Device Code", "Sign In", "Sign Up")
                labels.forEachIndexed { index, label ->
                    Box(
                        modifier = Modifier
                            .weight(1f)
                            .fillMaxHeight()
                            .background(
                                if (selectedTab == index) Color(0xFFE50914) else Color.White.copy(alpha = 0.08f),
                                RoundedCornerShape(10.dp),
                            ),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            label,
                            color = Color.White,
                            fontSize = 20.sp,
                            fontWeight = FontWeight.Bold,
                        )
                    }
                }
            }

            Spacer(Modifier.height(32.dp))

            // ── Fields ───────────────────────────────────────────────────────
            Column(modifier = Modifier.width(760.dp)) {
                AuthField(
                    value = if (selectedTab == 0) code else email,
                    onValueChange = { if (selectedTab == 0) code = it else email = it },
                    label = if (selectedTab == 0) "Device Code" else "Email",
                    isPassword = false,
                    keyboardType = if (selectedTab == 0) KeyboardType.Number else KeyboardType.Email,
                    isFocused = focusedField == 1,
                    focusRequester = field1Requester,
                    imeAction = if (selectedTab == 0) ImeAction.Done else ImeAction.Next,
                    onDone = { if (selectedTab == 0) submit() else moveFocus(1) },
                )
                if (selectedTab == 0) {
                    Spacer(Modifier.height(10.dp))
                    Text(
                        "On your phone, open MaxStream → TV Pairing and enter the 6-digit code shown there.",
                        color = Color.White.copy(alpha = 0.5f),
                        fontSize = 14.sp,
                    )
                }
                if (selectedTab != 0) {
                    Spacer(Modifier.height(16.dp))
                    AuthField(
                        value = password,
                        onValueChange = { password = it },
                        label = "Password",
                        isPassword = true,
                        keyboardType = KeyboardType.Password,
                        isFocused = focusedField == 2,
                        focusRequester = field2Requester,
                        imeAction = ImeAction.Done,
                        onDone = { submit() },
                    )
                }
            }

            Spacer(Modifier.height(24.dp))

            // ── Messages ─────────────────────────────────────────────────────
            if (successMsg != null) {
                Text(successMsg!!, color = Color(0xFF4CAF50), fontSize = 16.sp)
                Spacer(Modifier.height(12.dp))
            }
            if (errorMsg != null) {
                Text(errorMsg!!, color = Color(0xFFE50914), fontSize = 16.sp)
                Spacer(Modifier.height(12.dp))
            }

            // ── Submit ───────────────────────────────────────────────────────
            Button(
                onClick = { submit() },
                modifier = Modifier
                    .width(760.dp)
                    .height(64.dp)
                    .focusRequester(submitRequester)
                    .border(
                        width = if (focusedField == maxField) 4.dp else 0.dp,
                        color = if (focusedField == maxField) Color.White else Color.Transparent,
                        shape = RoundedCornerShape(12.dp),
                    ),
                colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFE50914)),
                enabled = !isLoading,
            ) {
                if (isLoading) {
                    CircularProgressIndicator(
                        color = Color.White,
                        modifier = Modifier.size(22.dp),
                        strokeWidth = 2.dp,
                    )
                } else {
                    Text(
                        when (selectedTab) {
                            0 -> "Sign In with Code"
                            1 -> "Sign In"
                            else -> "Create Account"
                        },
                        fontWeight = FontWeight.Bold,
                        fontSize = 18.sp,
                    )
                }
            }

            Spacer(Modifier.height(32.dp))

            // ── Navigation hints ─────────────────────────────────────────────
            Row(horizontalArrangement = Arrangement.spacedBy(24.dp)) {
                Hint("▲ ▼", "Move")
                Hint("◀ ▶", "Tabs")
                Hint("OK", "Select")
            }
        }
    }
}

@Composable
private fun AuthField(
    value: String,
    onValueChange: (String) -> Unit,
    label: String,
    isPassword: Boolean,
    keyboardType: KeyboardType,
    isFocused: Boolean,
    focusRequester: FocusRequester,
    imeAction: ImeAction,
    onDone: () -> Unit,
) {
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        modifier = Modifier
            .fillMaxWidth()
            .focusRequester(focusRequester),
        label = { Text(label, color = if (isFocused) Color.White else Color.White.copy(alpha = 0.5f)) },
        singleLine = true,
        visualTransformation = if (isPassword) PasswordVisualTransformation() else androidx.compose.ui.text.input.VisualTransformation.None,
        keyboardOptions = KeyboardOptions(keyboardType = keyboardType, imeAction = imeAction),
        keyboardActions = KeyboardActions(onDone = { onDone() }),
        textStyle = androidx.compose.ui.text.TextStyle(color = Color.White, fontSize = 22.sp),
        shape = RoundedCornerShape(12.dp),
        colors = androidx.compose.material3.OutlinedTextFieldDefaults.colors(
            focusedBorderColor = Color.White,
            unfocusedBorderColor = Color.White.copy(alpha = 0.3f),
            cursorColor = Color(0xFFE50914),
        ),
    )
}

@Composable
private fun Hint(keys: String, action: String) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(keys, color = Color(0xFFE50914), fontSize = 16.sp, fontWeight = FontWeight.Bold)
        Spacer(Modifier.width(8.dp))
        Text(action, color = Color.White.copy(alpha = 0.6f), fontSize = 16.sp)
    }
}
