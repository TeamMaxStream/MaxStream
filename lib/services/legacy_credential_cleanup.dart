import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Removes credentials persisted by older builds for the password-based TV
/// pairing flow. Pairing no longer sends passwords, and users upgrading from
/// ≤1.8.0 may still have them encrypted on disk.
class LegacyCredentialCleanup {
  static const String _doneKey = 'legacy_tv_password_cleanup_v1';
  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  static Future<void> runOnce() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_doneKey) == true) return;
      await clearStoredPasswords();
      await prefs.setBool(_doneKey, true);
    } catch (_) {
      // Cleanup is best effort and must never block startup or sign-out.
    }
  }

  /// Deletes only the keys the old TV-pairing flow wrote, leaving any other
  /// secure-storage entries untouched.
  static Future<void> clearStoredPasswords() async {
    try {
      final entries = await _storage.readAll();
      for (final key in entries.keys) {
        if (key.startsWith('tv_login_password_') ||
            key.startsWith('tv_login_email_')) {
          await _storage.delete(key: key);
        }
      }
    } catch (_) {
      // Best effort.
    }
  }
}
