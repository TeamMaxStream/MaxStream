import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maxstream/config/api_config.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maxstream/models/trailer_feed_item.dart';
import 'package:maxstream/services/profile_scope.dart';
import 'package:maxstream/services/tmdb_api_service.dart';
import 'package:maxstream/services/trailer_feed_service.dart';
import 'package:maxstream/services/user_scope.dart';
import 'package:shared_preferences/shared_preferences.dart';

TrailerFeedItem buildItem({
  int id = 1,
  String mediaType = 'movie',
  String title = 'A Movie',
  String key = 'abc123',
  TrailerReason reason = TrailerReason.trending,
  String reasonTitle = '',
}) => TrailerFeedItem(
  tmdbId: id,
  mediaType: mediaType,
  title: title,
  trailerKey: key,
  posterPath: '/poster.jpg',
  backdropPath: '/backdrop.jpg',
  reason: reason,
  reasonTitle: reasonTitle,
);

http.Response jsonResponse(Map<String, dynamic> body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

Map<String, dynamic> video(
  String key, {
  String type = 'Trailer',
  String site = 'YouTube',
  bool? official,
  String publishedAt = '',
}) => {
  'key': key,
  'type': type,
  'site': site,
  'official': ?official,
  'published_at': publishedAt,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('selectTrailer', () {
    test('prefers an official trailer over a teaser and unofficial cuts', () {
      final picked = TrailerFeedService.selectTrailer([
        video('teaser', type: 'Teaser'),
        video('unofficial', official: false),
        video('official', official: true),
      ]);
      expect(picked?['key'], 'official');
    });

    test('falls back to any trailer before a teaser', () {
      expect(
        TrailerFeedService.selectTrailerKey([
          video('teaser', type: 'Teaser'),
          video('trailer'),
        ]),
        'trailer',
      );
    });

    test('ignores non-YouTube videos and other types', () {
      expect(
        TrailerFeedService.selectTrailerKey([
          video('vimeo', site: 'Vimeo'),
          video('clip', type: 'Clip'),
          {'key': 'empty-key-and-type', 'type': 'Trailer', 'site': 'YouTube'},
        ]),
        'empty-key-and-type',
      );
      expect(
        TrailerFeedService.selectTrailerKey([
          video('vimeo', site: 'Vimeo'),
          video('featurette', type: 'Featurette'),
        ]),
        isNull,
      );
    });

    test('newest published trailer wins within a tier', () {
      expect(
        TrailerFeedService.selectTrailerKey([
          video('older', publishedAt: '2019-01-01T00:00:00.000Z'),
          video('newer', publishedAt: '2024-05-01T00:00:00.000Z'),
        ]),
        'newer',
      );
    });
  });

  group('selectTrailerDuration', () {
    test('reads the length from a TMDb playable session', () {
      expect(
        TrailerFeedService.selectTrailerDuration({
          'id': 'V1',
          'playback': [
            {
              'type': 'youtube',
              'duration': 150,
              'url': 'https://www.youtube.com/watch?v=abc123',
            },
          ],
        }),
        const Duration(seconds: 150),
      );
    });

    test('handles nested payloads and ignores unusable entries', () {
      expect(
        TrailerFeedService.selectTrailerDuration({
          'playback': {
            'playback': [
              {'duration': 0},
              {'duration': '92'},
            ],
          },
        }),
        const Duration(seconds: 92),
      );
      expect(TrailerFeedService.selectTrailerDuration({'id': 'V2'}), isNull);
      expect(TrailerFeedService.selectTrailerDuration({}), isNull);
    });
  });

  group('TrailerFeedItem', () {
    test('round-trips through JSON', () {
      final item = buildItem(
        reason: TrailerReason.because,
        reasonTitle: 'Dune',
      );
      final decoded = TrailerFeedItem.fromJson(item.toJson());
      expect(decoded, isNotNull);
      expect(decoded!.key, item.key);
      expect(decoded.trailerKey, 'abc123');
      expect(decoded.reason, TrailerReason.because);
      expect(decoded.reasonLabel, 'Because you watched Dune');
      expect(decoded.railHeadline, 'Because you watched Dune');
      expect(decoded.backdropUrl, contains('/w780/backdrop.jpg'));
    });

    test('rejects entries without a usable trailer', () {
      expect(TrailerFeedItem.fromJson({'id': 5, 'title': 'X'}), isNull);
      expect(
        TrailerFeedItem.fromJson({'id': 0, 'title': 'X', 'trailerKey': 'k'}),
        isNull,
      );
    });

    test('keeps the trailer length through JSON', () {
      final item = buildItem().copyWith(
        trailerDuration: const Duration(seconds: 135),
      );
      expect(item.toJson()['trailer_duration'], 135);
      final decoded = TrailerFeedItem.fromJson(item.toJson());
      expect(decoded!.trailerDuration, const Duration(seconds: 135));
      expect(buildItem().toJson().containsKey('trailer_duration'), isFalse);
    });

    test('reason labels cover trending and similar', () {
      expect(buildItem().reasonLabel, 'Trending now');
      expect(
        buildItem(
          reason: TrailerReason.similar,
          reasonTitle: 'Breaking Bad',
        ).reasonLabel,
        'More like Breaking Bad',
      );
    });
  });

  group('TrailerFeedService snapshot', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      UserScope.ownerResolver = () => 'user-a';
      TrailerFeedService.clearCache();
    });

    tearDown(() {
      UserScope.ownerResolver = null;
    });

    test('saves and restores the feed for the active profile', () async {
      final items = [buildItem(id: 1), buildItem(id: 2, mediaType: 'tv')];
      await TrailerFeedService.saveSnapshot(items);

      final restored = await TrailerFeedService.loadSnapshot();
      expect(restored, isNotNull);
      expect(restored!.map((i) => i.key), ['movie:1', 'tv:2']);
    });

    test('ignores an expired snapshot', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'trailers_snapshot_user-a_${ProfileScope.currentProfileId}',
        jsonEncode({
          'savedAt': DateTime.now()
              .subtract(const Duration(hours: 25))
              .toIso8601String(),
          'items': [buildItem().toJson()],
        }),
      );
      expect(await TrailerFeedService.loadSnapshot(), isNull);
    });

    test('corrupt snapshots are dropped instead of throwing', () async {
      await TrailerFeedService.saveSnapshot([buildItem()]);
      final prefs = await SharedPreferences.getInstance();
      final key = 'trailers_snapshot_user-a_${ProfileScope.currentProfileId}';
      await prefs.setString(
        key,
        jsonEncode({
          'savedAt': DateTime.now().toIso8601String(),
          'items': [
            'garbage',
            {'id': 3, 'title': 'No key'},
          ],
        }),
      );
      expect(await TrailerFeedService.loadSnapshot(), isNull);
    });
  });

  group('TrailerFeedService feed', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      UserScope.ownerResolver = () => 'user-a';
      ApiConfig.debugOverrideKey = 'test-key';
      TrailerFeedService.clearCache();
    });

    tearDown(() {
      TmdbApiService.setHttpClient(http.Client());
      UserScope.ownerResolver = null;
      ApiConfig.debugOverrideKey = null;
    });

    test(
      'resolves trailers, tags reasons, and drops titles without videos',
      () async {
        final requestedPaths = <String>[];
        TmdbApiService.setHttpClient(
          MockClient((request) async {
            final path = request.url.path;
            requestedPaths.add(path);
            if (path.endsWith('/genres/movie') ||
                path.endsWith('/genres/tv') ||
                path.endsWith('/genres')) {
              return jsonResponse({'genres': []});
            }
            if (path == '/3/trending/movie/week') {
              return jsonResponse({
                'results': [
                  {
                    'id': 1,
                    'title': 'Has Trailer',
                    'poster_path': '/p1.jpg',
                    'release_date': '2024-01-01',
                  },
                  {
                    'id': 2,
                    'title': 'No Trailer',
                    'poster_path': '/p2.jpg',
                    'release_date': '2023-01-01',
                  },
                ],
              });
            }
            if (path == '/3/trending/tv/week') {
              return jsonResponse({'results': []});
            }
            if (path == '/3/movie/1/videos') {
              return jsonResponse({
                'results': [video('good-key', official: true)],
              });
            }
            return jsonResponse({'results': []});
          }),
        );

        // No watch history, so For You is itself the trending fallback.
        final feed = await TrailerFeedService.getFeed();

        expect(feed, hasLength(1));
        expect(feed.single.title, 'Has Trailer');
        expect(feed.single.trailerKey, 'good-key');
        expect(feed.single.reason, TrailerReason.trending);
        expect(feed.single.releaseYear, '2024');
        expect(requestedPaths, contains('/3/movie/2/videos'));
      },
    );

    test('stays empty rather than throwing when TMDB is unreachable', () async {
      TmdbApiService.setHttpClient(
        MockClient((request) async => http.Response('nope', 503)),
      );
      expect(await TrailerFeedService.getFeed(), isEmpty);
    });
  });
}
