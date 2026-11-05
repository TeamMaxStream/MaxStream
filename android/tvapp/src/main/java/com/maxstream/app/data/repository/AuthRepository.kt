package com.maxstream.app.data.repository

import android.content.Context
import android.util.Base64
import com.maxstream.app.data.local.SessionManager
import com.google.gson.Gson
import com.google.gson.JsonObject
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.util.concurrent.TimeUnit

/**
 * Authentication for the native TV build, backed by the same Firebase project
 * the phone app uses (project maxstream-8effc). The TV APK intentionally does
 * not bundle the Firebase SDK or google-services.json, so auth goes over the
 * public Firebase REST APIs using OkHttp/Gson.
 *
 * Flow:
 *  - Device Code: POST the phone-generated code to the MaxStream pairing
 *    Worker, which burns it server-side and returns a Firebase custom token.
 *    The TV signs in with that token via `signInWithCustomToken`, so no
 *    credentials ever travel through the (publicly readable) RTDB node or the
 *    TV. Works for Google-only accounts too.
 *  - Sign In / Sign Up: email + password against the Auth REST endpoints.
 *  - A successful auth persists a lightweight session via [SessionManager] so
 *    subsequent launches skip the login screen.
 */
object AuthRepository {
    private const val API_KEY = "AIzaSyAiNjTADd8kA3qi3Dgnvlyo1Vf347QnsYk"

    private const val AUTH_BASE = "https://identitytoolkit.googleapis.com/v1/accounts"
    private const val PAIRING_REDEEM_URL =
        "https://maxstream-pairing.maxstream123.workers.dev/pairing/redeem"

    private val JSON = "application/json".toMediaType()

    private val gson = Gson()

    private val client: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(25, TimeUnit.SECONDS)
            .build()
    }

    private suspend fun postJson(url: String, body: JsonObject): JsonObject? =
        withContext(Dispatchers.IO) {
            val request = Request.Builder()
                .url(url)
                .post(body.toString().toRequestBody(JSON))
                .build()
            client.newCall(request).execute().use { response ->
                val text = response.body?.string() ?: return@use null
                runCatching { gson.fromJson(text, JsonObject::class.java) }.getOrNull()
            }
        }

    private data class HttpResult(val status: Int, val body: JsonObject?)

    /** POSTs JSON and keeps the HTTP status so callers can map API errors. */
    private suspend fun postJsonForStatus(url: String, body: JsonObject): HttpResult =
        withContext(Dispatchers.IO) {
            val request = Request.Builder()
                .url(url)
                .post(body.toString().toRequestBody(JSON))
                .build()
            client.newCall(request).execute().use { response ->
                val text = response.body?.string().orEmpty()
                val json = if (text.isBlank()) null else runCatching {
                    gson.fromJson(text, JsonObject::class.java)
                }.getOrNull()
                HttpResult(response.code, json)
            }
        }

    private fun authError(json: JsonObject?): String {
        val message = json
            ?.getAsJsonObject("error")
            ?.get("message")
            ?.asString
            ?: return "Authentication failed. Check your connection."
        return when {
            message.contains("EMAIL_NOT_FOUND") || message.contains("INVALID_LOGIN_CREDENTIALS") ||
                message.contains("INVALID_PASSWORD") -> "Incorrect email or password"
            message.contains("EMAIL_EXISTS") -> "An account already exists with this email"
            message.contains("WEAK_PASSWORD") -> "Password is too weak (min 6 characters)"
            message.contains("INVALID_EMAIL") -> "Invalid email format"
            message.contains("USER_DISABLED") -> "This account has been disabled"
            message.contains("TOO_MANY_ATTEMPTS_TRY_LATER") -> "Too many attempts. Try again later"
            else -> message
        }
    }

    /**
     * Extracts the Firebase Auth session fields (uid + idToken + refreshToken)
     * from an Auth REST response.
     */
    private fun sessionFrom(auth: JsonObject, email: String): Session {
        val uid = auth.get("localId")?.asString.orEmpty()
        val idToken = auth.get("idToken")?.asString.orEmpty()
        val refreshToken = auth.get("refreshToken")?.asString.orEmpty()
        return Session(email = email, uid = uid, idToken = idToken, refreshToken = refreshToken)
    }

    /**
     * Renews the Firebase ID token via the Auth REST securetoken endpoint.
     * ID tokens expire after ~1 hour. Returns the new token on success, null on failure.
     */
    suspend fun refreshIdToken(context: Context): String? {
        val refreshToken = SessionManager.refreshToken(context)
        if (refreshToken.isEmpty()) return null
        return try {
            val body = JsonObject().apply {
                addProperty("grant_type", "refresh_token")
                addProperty("refresh_token", refreshToken)
            }
            val response = postJson("https://securetoken.googleapis.com/v1/token?key=$API_KEY", body)
                ?: return null
            if (response.has("error")) return null
            val idToken = response.get("id_token")?.asString.orEmpty()
            val newRefreshToken = response.get("refresh_token")?.asString.orEmpty()
            if (idToken.isEmpty()) return null
            SessionManager.updateTokens(context, idToken, newRefreshToken)
            idToken
        } catch (e: Exception) {
            null
        }
    }

    /** Ensures a fresh idToken is stored, refreshing it if it has expired. */
    suspend fun ensureFreshIdToken(context: Context): String {
        val current = SessionManager.idToken(context)
        if (current.isNotEmpty() && !SessionManager.idTokenExpired(context)) return current
        return refreshIdToken(context) ?: current
    }

    /**
     * Redeems the 6-digit code shown on the phone. The pairing Worker validates
     * and burns the code server-side (the TV never reads RTDB), mints a custom
     * token for the code's uid, and the TV exchanges it for a Firebase session.
     */
    suspend fun authenticateWithDeviceCode(code: String): Result<Session> {
        val digits = code.trim()
        if (digits.isEmpty()) return Result.failure(IllegalArgumentException("Enter your code"))
        if (!digits.matches(Regex("\\d{6}"))) {
            return Result.failure(IllegalArgumentException("Code must be 6 digits"))
        }
        return try {
            val body = JsonObject().apply { addProperty("code", digits) }
            val response = postJsonForStatus(PAIRING_REDEEM_URL, body)
            val customToken = response.body?.get("customToken")?.asString.orEmpty()
            if (response.status in 200..299 && customToken.isNotEmpty()) {
                return signInWithCustomToken(customToken)
            }
            val message = when (response.status) {
                400 -> "Invalid pairing code. Check the code and try again."
                404 -> "Code not found, already used, or expired. Generate a new code on your phone."
                409 -> "This code was already used. Generate a new code on your phone."
                429 -> "Too many attempts. Wait a minute and try again."
                in 500..599 -> "MaxStream pairing is temporarily unavailable. Try again shortly."
                else -> "Could not pair this TV. Check your connection and try again."
            }
            Result.failure(Exception(message))
        } catch (e: Exception) {
            if (e is java.io.IOException) {
                Result.failure(Exception("Failed to connect. Check your connection."))
            } else {
                Result.failure(e)
            }
        }
    }

    private suspend fun signInWithCustomToken(customToken: String): Result<Session> {
        val body = JsonObject().apply {
            addProperty("token", customToken)
            addProperty("returnSecureToken", true)
        }
        val auth = postJson("$AUTH_BASE:signInWithCustomToken?key=$API_KEY", body)
            ?: return Result.failure(Exception("Failed to sign in. Check your connection."))
        if (auth.has("error")) return Result.failure(Exception(authError(auth)))

        val idToken = auth.get("idToken")?.asString.orEmpty()
        val email = decodeIdTokenClaims(idToken)?.get("email")?.asString.orEmpty()
        return Result.success(sessionFrom(auth, email))
    }

    /** Decodes the (unsigned) idToken payload to recover the account email. */
    private fun decodeIdTokenClaims(idToken: String): JsonObject? {
        val payload = idToken.split('.').getOrNull(1) ?: return null
        return runCatching {
            val bytes = Base64.decode(
                payload,
                Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING,
            )
            gson.fromJson(String(bytes, Charsets.UTF_8), JsonObject::class.java)
        }.getOrNull()
    }

    suspend fun signInWithEmail(email: String, password: String): Result<Session> {
        if (email.isBlank() || password.isBlank()) {
            return Result.failure(IllegalArgumentException("Enter your email and password"))
        }
        return try {
            val body = JsonObject().apply {
                addProperty("email", email.trim())
                addProperty("password", password)
                addProperty("returnSecureToken", true)
            }
            val auth = postJson("$AUTH_BASE:signInWithPassword?key=$API_KEY", body)
                ?: return Result.failure(Exception("Failed to sign in. Check your connection."))
            if (auth.has("error")) return Result.failure(Exception(authError(auth)))
            Result.success(sessionFrom(auth, email.trim()))
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun signUpWithEmail(email: String, password: String): Result<Session> {
        if (email.isBlank() || password.length < 6) {
            return Result.failure(IllegalArgumentException("Invalid email or password (min 6 characters)"))
        }
        return try {
            val body = JsonObject().apply {
                addProperty("email", email.trim())
                addProperty("password", password)
                addProperty("returnSecureToken", true)
            }
            val auth = postJson("$AUTH_BASE:signUp?key=$API_KEY", body)
                ?: return Result.failure(Exception("Failed to create account. Check your connection."))
            if (auth.has("error")) return Result.failure(Exception(authError(auth)))
            Result.success(sessionFrom(auth, email.trim()))
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    fun completeSignIn(context: Context, session: Session) {
        SessionManager.signIn(
            context,
            session.email,
            session.uid,
            session.idToken,
            session.refreshToken,
        )
    }

    fun signOut(context: Context) = SessionManager.signOut(context)

    data class Session(
        val email: String,
        val uid: String,
        val idToken: String,
        val refreshToken: String = "",
    )
}
