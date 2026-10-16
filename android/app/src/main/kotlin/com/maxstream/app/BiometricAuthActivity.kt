package com.maxstream.app

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.util.Log
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_STRONG
import androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_WEAK
import androidx.biometric.BiometricManager.Authenticators.DEVICE_CREDENTIAL
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity

/**
 * Hosts the androidx [BiometricPrompt] and reports the outcome back to whoever
 * started it via `setResult`.
 *
 * This is a PLAIN FragmentActivity with no FlutterEngine of its own, which is
 * the whole point: `androidx.biometric` requires a FragmentActivity host, but
 * making the Flutter activity one does not work with audio_service's shared,
 * cached engine. Two crashes came out of that combination:
 *  - `The internal FlutterEngine created by ... has been attached to by another
 *    activity` — FlutterFragmentActivity's retained fragment fighting the
 *    engine that audio_service keeps alive across activities;
 *  - `Cannot execute operation because FlutterJNI is not attached to native`
 *    when the AudioService stopped after the host had taken the engine down.
 *
 * Keeping the prompt in its own activity leaves MainActivity an ordinary
 * FlutterActivity whose engine lifecycle is exactly as it always was, so
 * neither crash is possible.
 *
 * Returns RESULT_AUTHENTICATED with [EXTRA_ERROR_CODE] empty on success, or
 * with a local_auth-style code (NotAvailable / NotEnrolled / LockedOut /
 * PermanentlyLockedOut / canceled) on failure.
 */
class BiometricAuthActivity : FragmentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val reason = intent?.getStringExtra(EXTRA_REASON) ?: "Unlock MaxStream"
        // The app allows the device PIN/pattern as a fallback, so the prompt
        // never needs a negative button (BiometricPrompt rejects one when
        // DEVICE_CREDENTIAL is part of the allowed set).
        val biometricOnly = intent?.getBooleanExtra(EXTRA_BIOMETRIC_ONLY, false) ?: false
        val allowed: Int = if (biometricOnly) {
            BIOMETRIC_STRONG or BIOMETRIC_WEAK
        } else {
            BIOMETRIC_STRONG or BIOMETRIC_WEAK or DEVICE_CREDENTIAL
        }

        // Fail fast with a precise code instead of letting the prompt show a
        // system error dialog the app cannot interpret.
        val availability = BiometricManager.from(this).canAuthenticate(allowed)
        if (availability != BiometricManager.BIOMETRIC_SUCCESS) {
            Log.w(TAG, "Biometrics unavailable: $availability")
            finishWith(availability.availabilityToErrorCode())
            return
        }

        val prompt = BiometricPrompt(
            this,
            ContextCompat.getMainExecutor(this),
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                    finishWith("")
                }

                override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                    Log.w(TAG, "Authentication error $errorCode: $errString")
                    finishWith(errorCode.promptToErrorCode())
                }

                // onAuthenticationFailed is a soft rejection (wrong finger); the
                // prompt stays up, so there is nothing to do here.
            },
        )

        val info = BiometricPrompt.PromptInfo.Builder()
            .setTitle("MaxStream")
            .setSubtitle(reason)
            .setAllowedAuthenticators(allowed)
            .setConfirmationRequired(false)
            .build()

        runCatching { prompt.authenticate(info) }
            .onFailure {
                Log.e(TAG, "Could not show the biometric prompt: ${it.message}")
                finishWith("NotAvailable")
            }
    }

    private fun finishWith(errorCode: String) {
        setResult(RESULT_AUTHENTICATED, Intent().putExtra(EXTRA_ERROR_CODE, errorCode))
        finish()
    }

    companion object {
        private const val TAG = "BiometricAuth"

        /** Result code for both success and failure; [EXTRA_ERROR_CODE] says which. */
        const val RESULT_AUTHENTICATED = 0x4D41 // 'MA'
        const val EXTRA_ERROR_CODE = "com.maxstream.app.BIOMETRIC_ERROR"
        private const val EXTRA_REASON = "reason"
        private const val EXTRA_BIOMETRIC_ONLY = "biometricOnly"

        fun intent(
            context: Context,
            reason: String,
            biometricOnly: Boolean,
        ): Intent = Intent(context, BiometricAuthActivity::class.java)
            .putExtra(EXTRA_REASON, reason)
            .putExtra(EXTRA_BIOMETRIC_ONLY, biometricOnly)
    }
}

/** Maps a BiometricManager availability constant to a local_auth-style code. */
private fun Int.availabilityToErrorCode(): String = when (this) {
    BiometricManager.BIOMETRIC_ERROR_NONE_ENROLLED -> "NotEnrolled"
    else -> "NotAvailable"
}

/** Maps a BiometricPrompt error constant to a local_auth-style code. */
private fun Int.promptToErrorCode(): String = when (this) {
    BiometricPrompt.ERROR_NO_BIOMETRICS -> "NotEnrolled"
    BiometricPrompt.ERROR_HW_NOT_PRESENT,
    BiometricPrompt.ERROR_HW_UNAVAILABLE,
    BiometricPrompt.ERROR_NO_DEVICE_CREDENTIAL,
    -> "NotAvailable"
    BiometricPrompt.ERROR_LOCKOUT -> "LockedOut"
    BiometricPrompt.ERROR_LOCKOUT_PERMANENT -> "PermanentlyLockedOut"
    BiometricPrompt.ERROR_USER_CANCELED,
    BiometricPrompt.ERROR_CANCELED,
    BiometricPrompt.ERROR_NEGATIVE_BUTTON,
    -> "canceled"
    else -> "failed"
}
