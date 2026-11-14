import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maxstream/widgets/crash_screen.dart';

void main() {
  test('late WebView JavaScript calls are treated as teardown noise', () {
    final error = MissingPluginException(
      'No implementation found for method evaluateJavascript on channel '
      'com.pichillilorenzo/flutter_inappwebview_0',
    );

    expect(isBenignWebViewTeardownError(error), isTrue);
    expect(isBenignError(error), isTrue);
  });

  test('other missing platform methods are still reported', () {
    final error = MissingPluginException(
      'No implementation found for method installApk on channel '
      'com.maxstream.app/install',
    );

    expect(isBenignWebViewTeardownError(error), isFalse);
    expect(isBenignError(error), isFalse);
  });
}
