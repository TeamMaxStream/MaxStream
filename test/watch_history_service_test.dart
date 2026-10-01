import 'package:flutter_test/flutter_test.dart';
import 'package:maxstream/services/profile_scope.dart';
import 'package:maxstream/services/user_scope.dart';
import 'package:maxstream/services/watch_history_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

// These tests inject the owner via UserScope.ownerResolver. FirebaseAuth is
// unavailable outside a real Firebase app, so ProfileScope falls back to its
// default profile suffix — the tests care about the storage keys, not a live
// Firebase project.

void profileScopeBaselineTests() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    UserScope.ownerResolver = () => 'user-a';
  });

  tearDown(() => UserScope.ownerResolver = null);

  test('history and item keys are scoped by owner', () async {
    await WatchHistoryService.saveWatchProgress(
      tmdbId: '42',
      title: 'Movie',
      isMovie: true,
      season: 0,
      episode: 0,
      position: const Duration(seconds: 60),
      duration: const Duration(seconds: 120),
    );
    expect(await WatchHistoryService.getWatchHistory(), hasLength(1));

    UserScope.ownerResolver = () => 'user-b';
    expect(await WatchHistoryService.getWatchHistory(), isEmpty);
    expect(
      await WatchHistoryService.loadWatchPosition('42', true, 0, 0),
      Duration.zero,
    );

    UserScope.ownerResolver = () => 'user-a';
    expect(
      await WatchHistoryService.loadWatchPosition('42', true, 0, 0),
      const Duration(seconds: 60),
    );
  });

  test('malformed JSON and wrong shapes return safe defaults', () async {
    SharedPreferences.setMockInitialValues({
      'watch_history_list_user-a': '{broken',
      'watch_history_user-a_movie_42': '[]',
    });

    expect(await WatchHistoryService.getWatchHistory(), isEmpty);
    expect(
      await WatchHistoryService.loadWatchPosition('42', true, 0, 0),
      Duration.zero,
    );
    expect(
      await WatchHistoryService.getWatchProgressPercentage('42', true, 0, 0),
      0,
    );
    expect(await WatchHistoryService.isWatched('42', true, 0, 0), isFalse);
  });

  test('empty injected owner uses stable anonymous owner', () {
    UserScope.ownerResolver = () => '  ';
    expect(UserScope.currentOwner, UserScope.anonymousOwner);
    expect(
      WatchHistoryService.getWatchHistoryKey('7', false, 1, 2),
      'watch_history___anonymous___tv_7_1_2',
    );
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Regression: watch history vanished from Continue Watching / Watch History on
// a cold start, while tapping into a title still resumed at the right position.
//
// Every storage key is scoped by ProfileScope.currentProfileId, which returns
// the Firebase UID until the active profile has been resolved from local
// storage. Any read in that window looks up a UID-scoped key and finds nothing.
// The two symptoms came from the same cause at different moments: the lists are
// read early by the grid screens, the per-title key is read late by the player.
// ─────────────────────────────────────────────────────────────────────────────
void profileScopeRegressionTests() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    UserScope.ownerResolver = () => 'user-a';
  });

  tearDown(() => UserScope.ownerResolver = null);

  test(
    'resume position survives a read that races profile resolution',
    () async {
      // The list key is scoped by owner AND profile. With no profile resolved
      // the profile part falls back, so derive the key from the service itself
      // rather than hard-coding the suffix.
      final listKey =
          'watch_history_list_user-a_${ProfileScope.currentProfileId}';
      final itemKey = WatchHistoryService.getWatchHistoryKey('42', true, 1, 1);

      // Seed history exactly as the app did before the profile was known.
      SharedPreferences.setMockInitialValues({
        listKey:
            '[{"tmdbId":"42","title":"Movie","isMovie":true,'
            '"season":1,"episode":1,"position":60,"duration":120,'
            '"isWatched":false,"timestamp":1}]',
        itemKey:
            '{"tmdbId":"42","isMovie":true,"season":1,"episode":1,'
            '"position":60,"duration":120,"timestamp":1}',
      });

      // The list comes back from the fallback-scoped key: the data was never
      // actually lost, which is why it reappeared once things settled.
      final history = await WatchHistoryService.getWatchHistory();
      expect(history, hasLength(1));
      expect(history.single['tmdbId'], '42');

      // And the per-title resume read agrees with it.
      expect(
        await WatchHistoryService.loadWatchPosition('42', true, 1, 1),
        const Duration(seconds: 60),
      );
      expect(
        await WatchHistoryService.getWatchProgressPercentage('42', true, 1, 1),
        0.5,
      );
    },
  );

  test('history written through the service is readable by the list', () async {
    await WatchHistoryService.saveWatchProgress(
      tmdbId: '42',
      title: 'Movie',
      isMovie: true,
      season: 1,
      episode: 1,
      position: const Duration(seconds: 60),
      duration: const Duration(seconds: 120),
    );

    expect(await WatchHistoryService.getWatchHistory(), hasLength(1));
    expect(
      await WatchHistoryService.getContinueWatching(),
      hasLength(1),
      reason: 'an unfinished item must appear in Continue Watching',
    );
    expect(
      await WatchHistoryService.getGroupedWatchHistory(),
      hasLength(1),
      reason: 'and in Watch History',
    );
  });
}

void main() {
  profileScopeBaselineTests();
  profileScopeRegressionTests();
}
