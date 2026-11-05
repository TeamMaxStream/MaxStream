import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:maxstream/services/device_code_service.dart';

/// Returns a fixed value from [nextInt] so the boundary of the code range can
/// be asserted without relying on a random draw.
class _FixedRandom implements Random {
  _FixedRandom(this.value);

  final int value;

  @override
  int nextInt(int max) => value.clamp(0, max - 1);

  @override
  bool nextBool() => false;

  @override
  double nextDouble() => 0;
}

void main() {
  group('DeviceCodeService.generateSixDigitCode', () {
    test('stays within the six-digit range at the lower bound', () {
      expect(DeviceCodeService.generateSixDigitCode(_FixedRandom(0)), '100000');
    });

    test('stays within the six-digit range at the upper bound', () {
      expect(
        DeviceCodeService.generateSixDigitCode(_FixedRandom(899999)),
        '999999',
      );
    });

    test('always produces exactly six digits without a leading zero', () {
      final random = Random(42);
      for (var i = 0; i < 1000; i++) {
        final code = DeviceCodeService.generateSixDigitCode(random);
        expect(code, matches(RegExp(r'^\d{6}$')));
        expect(code.codeUnitAt(0), isNot(0x30)); // '0'
        expect(int.parse(code), inInclusiveRange(100000, 999999));
      }
    });

    test('codes expire after 15 minutes', () {
      expect(DeviceCodeService.codeLifetime, const Duration(minutes: 15));
    });
  });
}
