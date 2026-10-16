import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

/// Outcome of a biometric attempt: success, or a message worth showing.
class BiometricAuthResult {
  final bool success;
  final String? error;
  const BiometricAuthResult.success()
      : success = true,
        error = null;
  const BiometricAuthResult.failure(this.error) : success = false;
}

/// Biometric Authentication Service
/// Supports fingerprint and face recognition
class BiometricService {
  static final LocalAuthentication _localAuth = LocalAuthentication();

  /// MainActivity's biometric relay. The prompt is hosted by
  /// BiometricAuthActivity (a FragmentActivity with no FlutterEngine) because
  /// androidx.biometric requires a FragmentActivity host and local_auth's
  /// plugin cannot use one without breaking audio_service's shared engine.
  static const MethodChannel _biometricChannel =
      MethodChannel('com.maxstream.app/biometric');

  /// Check if biometric is available on device
  static Future<bool> isBiometricAvailable() async {
    try {
      return await _localAuth.canCheckBiometrics;
    } catch (e) {
      debugPrint('Error checking biometric availability: $e');
      return false;
    }
  }

  /// Get list of available biometric types
  static Future<List<BiometricType>> getAvailableBiometrics() async {
    try {
      return await _localAuth.getAvailableBiometrics();
    } catch (e) {
      debugPrint('Error getting available biometrics: $e');
      return [];
    }
  }

  /// Check if device supports any form of biometric
  static Future<bool> canUseBiometric() async {
    try {
      final canCheck = await _localAuth.canCheckBiometrics;
      final isDeviceSupported = await _localAuth.isDeviceSupported();
      return canCheck || isDeviceSupported;
    } catch (e) {
      debugPrint('Error checking device biometric support: $e');
      return false;
    }
  }

  /// Authenticate using biometric
  /// Shows system biometric dialog (fingerprint, face, or PIN fallback)
  static Future<bool> authenticate({
    required String reason,
    bool stickyAuth = false,
    bool biometricOnly = true,
  }) async {
    return (await authenticateDetailed(
      reason: reason,
      stickyAuth: stickyAuth,
      biometricOnly: biometricOnly,
    ))
        .success;
  }

  /// Same as [authenticate], but reports WHY it failed.
  ///
  /// The prompt itself is shown by MainActivity's own engine-less
  /// BiometricAuthActivity rather than local_auth: androidx.biometric needs a
  /// FragmentActivity host, and making the Flutter activity one broke
  /// audio_service's cached engine twice (retained fragment attaching the
  /// shared engine to a second activity, then a detached FlutterJNI when the
  /// AudioService stopped). local_auth's plugin can't host the prompt from a
  /// plain FlutterActivity, so we own it natively and get the same
  /// error-code vocabulary back.
  static Future<BiometricAuthResult> authenticateDetailed({
    required String reason,
    bool stickyAuth = false,
    bool biometricOnly = true,
  }) async {
    try {
      final isAvailable = await canUseBiometric();
      if (!isAvailable) {
        return const BiometricAuthResult.failure(
            'No screen lock set up. Add a PIN, pattern or fingerprint in Android Settings first.');
      }

      final response = await _biometricChannel.invokeMapMethod<String, dynamic>(
        'authenticate',
        {'reason': reason, 'biometricOnly': biometricOnly},
      );
      if (response == null) {
        return const BiometricAuthResult.failure('Authentication failed.');
      }
      if (response['authenticated'] == true) {
        return const BiometricAuthResult.success();
      }
      final code = response['errorCode'] as String? ?? 'failed';
      // A user-cancelled prompt is not a failure to report loudly.
      if (code == 'canceled') {
        return const BiometricAuthResult.failure('Authentication cancelled.');
      }
      return BiometricAuthResult.failure(_messageForCode(code));
    } on PlatformException catch (e) {
      debugPrint('Biometric authentication error: ${e.code} ${e.message}');
      return BiometricAuthResult.failure(_messageForCode(e.code));
    } catch (e) {
      debugPrint('Biometric authentication error: $e');
      return const BiometricAuthResult.failure('Authentication failed.');
    }
  }

  /// Error codes reported by BiometricAuthActivity; mapping them here is the
  /// difference between an actionable message and a generic one.
  static String _messageForCode(String code) {
    switch (code) {
      case 'NotAvailable':
      case 'no_biometrics':
        return 'Biometrics are not available. Use your PIN instead.';
      case 'NotEnrolled':
        return 'No biometrics enrolled on this device. Use your PIN instead.';
      case 'LockedOut':
      case 'PermanentlyLockedOut':
        return 'Too many attempts. Unlock with your PIN first, then retry.';
      case 'no_fragment_activity':
        return 'Biometric unlock is unavailable in this build.';
      case 'temporary_lockout':
        return 'Too many attempts. Try again in a moment.';
      case 'in_progress':
        return 'A biometric prompt is already open.';
      default:
        return 'Authentication failed.';
    }
  }

  /// Authenticate with fingerprint
  static Future<bool> authenticateWithFingerdebugPrint() async {
    return authenticate(
      reason: 'Authenticate using your fingerprint',
      biometricOnly: true,
    );
  }

  /// Authenticate with face
  static Future<bool> authenticateWithFace() async {
    return authenticate(
      reason: 'Authenticate using your face',
      biometricOnly: true,
    );
  }

  /// Generic biometric authentication (fingerprint or face, whatever is available)
  static Future<bool> authenticateForDeviceCode() async {
    try {
      final biometrics = await getAvailableBiometrics();

      String reason = 'Verify your identity to complete TV login';

      // Customize message based on available biometrics
      if (biometrics.contains(BiometricType.face)) {
        reason = 'Scan your face to complete TV login';
      } else if (biometrics.contains(BiometricType.fingerprint)) {
        reason = 'Scan your fingerprint to complete TV login';
      }

      return await authenticate(
        reason: reason,
        biometricOnly: false, // Allow PIN fallback if biometric fails
      );
    } catch (e) {
      debugPrint('Device code biometric authentication error: $e');
      return false;
    }
  }

  /// Check if biometric enrollment exists
  static Future<bool> hasBiometricEnrolled() async {
    try {
      final biometrics = await getAvailableBiometrics();
      return biometrics.isNotEmpty;
    } catch (e) {
      debugPrint('Error checking biometric enrollment: $e');
      return false;
    }
  }

  /// Get biometric type string for display
  static Future<String> getBiometricTypeString() async {
    try {
      final biometrics = await getAvailableBiometrics();

      if (biometrics.contains(BiometricType.face)) {
        return 'Face Recognition';
      } else if (biometrics.contains(BiometricType.fingerprint)) {
        return 'Fingerprint';
      } else if (biometrics.contains(BiometricType.iris)) {
        return 'Iris Scan';
      }

      return 'Biometric';
    } catch (e) {
      debugPrint('Error getting biometric type: $e');
      return 'Biometric';
    }
  }
}
