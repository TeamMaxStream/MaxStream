import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
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
  /// Every failure used to collapse into `false`, so the UI always said
  /// "Authentication failed. Biometric lock not enabled." — even when the
  /// prompt never appeared because the host activity was not a FragmentActivity.
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

      final isAuthenticated = await _localAuth.authenticate(
        localizedReason: reason,
        options: AuthenticationOptions(
          stickyAuth: stickyAuth,
          biometricOnly: biometricOnly,
          useErrorDialogs: true,
        ),
      );

      if (isAuthenticated) return const BiometricAuthResult.success();
      return const BiometricAuthResult.failure('Authentication failed.');
    } on PlatformException catch (e) {
      debugPrint('Biometric authentication error: ${e.code} ${e.message}');
      return BiometricAuthResult.failure(_messageForCode(e.code));
    } catch (e) {
      debugPrint('Biometric authentication error: $e');
      return const BiometricAuthResult.failure('Authentication failed.');
    }
  }

  /// local_auth throws a PlatformException per native failure reason; mapping
  /// them here is the difference between an actionable message and a generic one.
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
