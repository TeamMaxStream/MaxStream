import 'dart:async';
import 'dart:math';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

/// Creates the one-time code shown by the phone during TV pairing.
///
/// The code is the only credential the TV sends to the pairing Worker. It is
/// never accompanied by a password; the Worker validates and burns the code and
/// returns a Firebase custom token.
class DeviceCodeService {
  static final FirebaseDatabase _rtdb = FirebaseDatabase.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  static const Duration codeLifetime = Duration(minutes: 15);
  static const int _maxAttempts = 5;

  /// Six digits, never with a leading zero: 100000–999999. Exposed for tests so
  /// the code format cannot drift from the TV's `\d{6}` validation.
  @visibleForTesting
  static String generateSixDigitCode(Random random) =>
      (100000 + random.nextInt(900000)).toString();

  static Future<String> generateDeviceCode() async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('You need to be signed in to generate a pairing code.');
    }

    final expiresAt = DateTime.now().add(codeLifetime).millisecondsSinceEpoch;
    final random = Random.secure();
    Object? lastError;

    for (var attempt = 0; attempt < _maxAttempts; attempt++) {
      final code = generateSixDigitCode(random);
      try {
        await _rtdb
            .ref('device_codes/$code')
            .set({
              'code': code,
              'userId': user.uid,
              'createdAt': ServerValue.timestamp,
              'expiresAt': expiresAt,
              'isUsed': false,
            })
            .timeout(const Duration(seconds: 15));

        return code;
      } catch (e) {
        lastError = e;
        final message = e.toString().toLowerCase();
        if (message.contains('permission_denied') ||
            message.contains('permission denied')) {
          throw Exception(
            'Could not create a pairing code. Make sure you are signed in '
            'and try again.',
          );
        }
        // A collision (the same six digits already exist) or a transient
        // network error: pick another code and retry.
        await Future<void>.delayed(Duration(milliseconds: 200 * (attempt + 1)));
      }
    }

    throw Exception(
      'Could not create a pairing code after $_maxAttempts attempts. '
      'Check your connection and try again.${lastError == null ? '' : ' ($lastError)'}',
    );
  }
}
