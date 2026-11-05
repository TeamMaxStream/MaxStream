import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maxstream/config/api_config.dart';
import 'package:maxstream/screens/trailers_screen.dart';
import 'package:maxstream/services/tmdb_api_service.dart';
import 'package:maxstream/services/trailer_feed_service.dart';
import 'package:maxstream/services/user_scope.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    UserScope.ownerResolver = () => 'user-a';
    ApiConfig.debugOverrideKey = 'test-key';
    TrailerFeedService.clearCache();
    // Every TMDB call fails, so the feed resolves empty.
    TmdbApiService.setHttpClient(
      MockClient((request) async => http.Response('unavailable', 503)),
    );
  });

  tearDown(() {
    TmdbApiService.setHttpClient(http.Client());
    UserScope.ownerResolver = null;
    ApiConfig.debugOverrideKey = null;
    TrailerFeedService.clearCache();
  });

  testWidgets('empty feed shows the trending fallback action', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: TrailersScreen()));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('No trailers yet'), findsOneWidget);
    expect(find.text('Browse trending trailers'), findsOneWidget);
  });
}
