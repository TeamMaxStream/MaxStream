import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/trailer_feed_item.dart';
import '../utils/kids_filter.dart';
import 'profile_scope.dart';
import 'recommendation_service.dart';
import 'tmdb_api_service.dart';
import 'user_scope.dart';
import 'watch_history_service.dart';

/// Builds the trailers feed: titles recommended from what the user watched,
/// each with its YouTube trailer resolved.
///
/// Recommendation *selection* is delegated to [RecommendationService] so the
/// feed and the Recommendations screen agree on taste; this service only adds
/// the trailer lookup, the "reason" labels, and snapshot persistence.
class TrailerFeedService {
  static const int maxTrailers = 24;

  /// Trimming after the lookup keeps a feed of usable pages without fanning
  /// out over every candidate.
  static const int _maxCandidates = 40;

  /// Trailer lookups per batch. TMDB has no bulk videos endpoint, so one
  /// request per title is unavoidable; batching bounds the burst.
  static const int _batchSize = 4;

  static const Duration _cacheTtl = Duration(minutes: 30);

  static List<TrailerFeedItem>? _cache;
  static DateTime? _cacheAt;
  static Future<List<TrailerFeedItem>>? _inFlight;

  /// Candidates already resolved to trailers are reused while the cache is
  /// fresh, so the banner, the rail, and the screen sharing one build do not
  /// repeat the per-title lookup.
  static final Map<String, TrailerFeedItem> _resolved = {};

  /// Picks the best YouTube trailer from a `/videos` payload.
  ///
  /// Order of preference: official trailer, any trailer, teaser. Newest
  /// `published_at` wins within a tier. Returns null when nothing is usable.
  static Map<String, dynamic>? selectTrailer(
    List<Map<String, dynamic>> videos,
  ) {
    final usable = videos
        .where((video) => video['site'] == 'YouTube')
        .where((video) => '${video['key'] ?? ''}'.trim().isNotEmpty)
        .where(
          (video) => video['type'] == 'Trailer' || video['type'] == 'Teaser',
        )
        .toList();
    if (usable.isEmpty) return null;

    int tier(Map<String, dynamic> video) {
      if (video['type'] == 'Trailer') {
        return video['official'] == true ? 0 : 1;
      }
      return 2;
    }

    usable.sort((a, b) {
      final byTier = tier(a).compareTo(tier(b));
      if (byTier != 0) return byTier;
      return '${b['published_at'] ?? ''}'.compareTo(
        '${a['published_at'] ?? ''}',
      );
    });
    return usable.first;
  }

  /// Convenience for callers that only need the video key.
  static String? selectTrailerKey(List<Map<String, dynamic>> videos) =>
      selectTrailer(videos)?['key']?.toString();

  /// YouTube exposes no reliable length to the embed, so the exact trailer
  /// duration is read from TMDb's playable session (`playback` /
  /// `session` blocks) instead.
  static Duration? selectTrailerDuration(Map<String, dynamic> video) {
    final boxes = [
      video['playback'],
      video['playback'] is Map ? (video['playback'] as Map)['playback'] : null,
      video['session'],
    ];
    for (final box in boxes) {
      if (box is! List) continue;
      for (final entry in box.whereType<Map>()) {
        final seconds = int.tryParse('${entry['duration'] ?? ''}') ?? 0;
        if (seconds > 0) return Duration(seconds: seconds);
      }
    }
    return null;
  }

  static final Map<String, Duration> _durations = {};

  /// Trailer lengths keyed by video id, fused into every page. This uses the
  /// same TMDb session lookup the details screens use for inline playback,
  /// which also keeps the trailer playable from the official channel.
  static Future<Map<String, Duration>> prefetchDurations(
    Iterable<TrailerFeedItem> items,
  ) async {
    final resolved = <String, Duration>{};
    final missing = <TrailerFeedItem>[];
    for (final item in items) {
      final known = item.trailerDuration ?? _durations[item.trailerKey];
      if (known != null) {
        resolved[item.trailerKey] = known;
      } else if (!missing.any((m) => m.trailerKey == item.trailerKey)) {
        missing.add(item);
      }
    }
    for (var offset = 0; offset < missing.length; offset += _batchSize) {
      final batch = missing.skip(offset).take(_batchSize);
      await Future.wait(
        batch.map((item) async {
          try {
            final videos = await TmdbApiService.getVideos(
              item.tmdbId,
              isMovie: item.isMovie,
            );
            final video = TrailerFeedService.selectTrailer(videos);
            final duration = video == null
                ? null
                : selectTrailerDuration(video);
            if (duration != null) {
              _durations[item.trailerKey] = duration;
              resolved[item.trailerKey] = duration;
            }
          } catch (_) {
            // A missing length only costs the exact scale on the scrubber.
          }
        }),
      );
    }
    return resolved;
  }

  static bool get _isStale =>
      _cacheAt == null || DateTime.now().difference(_cacheAt!) > _cacheTtl;

  /// The feed, ordered by relevance. Screens call this on open; the value is
  /// cached for [_cacheTtl] and shared with any concurrent caller.
  ///
  /// [refresh] re-runs candidate selection but reuses trailers already
  /// resolved in this session, so it costs two list calls, not one per title.
  static Future<List<TrailerFeedItem>> getFeed({bool refresh = false}) async {
    if (!refresh) {
      if (_cache != null && !_isStale) return _cache!;
      final running = _inFlight;
      if (running != null) return running;
    } else {
      _resolved.clear();
    }

    final future = _buildFeed().then((items) async {
      if (items.isEmpty) return items;
      final durations = await prefetchDurations(items);
      return [
        for (final item in items)
          durations[item.trailerKey] is Duration && item.trailerDuration == null
              ? item.copyWith(trailerDuration: durations[item.trailerKey])
              : item,
      ];
    });
    _inFlight = future;
    try {
      final items = await future;
      if (items.isNotEmpty) {
        _cache = items;
        _cacheAt = DateTime.now();
        await saveSnapshot(items);
      }
      return items;
    } finally {
      if (identical(_inFlight, future)) _inFlight = null;
    }
  }

  static Future<List<TrailerFeedItem>> _buildFeed() async {
    final candidates = await _candidates();
    if (candidates.isEmpty) return const [];

    final resolved = <TrailerFeedItem>[];
    for (var offset = 0; offset < candidates.length; offset += _batchSize) {
      final batch = candidates.skip(offset).take(_batchSize).toList();
      final results = await Future.wait(batch.map(_resolve));
      for (final item in results) {
        if (item != null) resolved.add(item);
      }
      if (resolved.length >= maxTrailers) break;
    }
    return resolved.take(maxTrailers).toList();
  }

  /// Ordered candidates with their reason. Alternates "because you watched X"
  /// with the personalised/trending pool so the feed does not become a wall
  /// of one source.
  static Future<List<_Candidate>> _candidates() async {
    List<Map<String, dynamic>> history;
    try {
      history = await WatchHistoryService.getWatchHistory();
    } catch (_) {
      // Profile resolution needs Firebase in tests/headless hosts; without
      // history the feed simply falls back to the trending pool.
      history = const [];
    }
    final watched = <String>{
      for (final entry in history)
        '${entry['isMovie'] == true ? 'movie' : 'tv'}:${entry['tmdbId']}',
    };
    final seen = <String>{};
    final ordered = <_Candidate>[];

    void add(
      List<Map<String, dynamic>> items,
      TrailerReason reason,
      String from,
    ) {
      for (final item in items) {
        final mediaType = item['media_type'] == 'tv' ? 'tv' : 'movie';
        final tmdbId = int.tryParse('${item['id']}') ?? 0;
        if (tmdbId <= 0) continue;
        final key = '$mediaType:$tmdbId';
        if (watched.contains(key) || !seen.add(key)) continue;
        ordered.add(
          _Candidate(
            item: item,
            mediaType: mediaType,
            reason: reason,
            reasonTitle: from,
          ),
        );
      }
    }

    var because = <Map<String, dynamic>>[];
    var forYou = <Map<String, dynamic>>[];
    try {
      because = filterForKids(
        await RecommendationService.getBecauseYouWatched(limit: 15),
      );
    } catch (_) {
      // One failed source must not empty the feed.
    }
    try {
      forYou = filterForKids(await RecommendationService.getForYou());
    } catch (_) {
      // Ditto: whatever resolved is still shown.
    }

    final fromRecentlyWatched =
        '${because.firstOrNull?['recommendedFrom'] ?? ''}';
    // No watch history means For You is itself the trending fallback.
    final forYouReason = history.isEmpty
        ? TrailerReason.trending
        : TrailerReason.similar;

    // Interleave: after every 2 "For You" titles, sprinkle in one "Because
    // you watched" pick, so the feed keeps both its personal hook and variety.
    var becauseIndex = 0;
    var forYouIndex = 0;
    var untilNextBecause = 2;
    while (becauseIndex < because.length || forYouIndex < forYou.length) {
      if (untilNextBecause == 0 && becauseIndex < because.length) {
        add(
          [because[becauseIndex++]],
          TrailerReason.because,
          fromRecentlyWatched,
        );
        untilNextBecause = 2;
      } else if (forYouIndex < forYou.length) {
        add([forYou[forYouIndex++]], forYouReason, fromRecentlyWatched);
        if (untilNextBecause > 0) untilNextBecause--;
      } else if (becauseIndex < because.length) {
        add(
          [because[becauseIndex++]],
          TrailerReason.because,
          fromRecentlyWatched,
        );
      }
      if (ordered.length >= _maxCandidates) break;
    }
    return ordered.take(_maxCandidates).toList();
  }

  static Future<TrailerFeedItem?> _resolve(_Candidate candidate) async {
    final tmdbId = int.tryParse('${candidate.item['id']}') ?? 0;
    final cacheKey = '${candidate.mediaType}:$tmdbId';
    final cached = _resolved[cacheKey];
    if (cached != null) {
      return cached.copyWith(
        reason: candidate.reason,
        reasonTitle: candidate.reasonTitle,
      );
    }
    try {
      final videos = await TmdbApiService.getVideos(
        tmdbId,
        isMovie: candidate.mediaType == 'movie',
      );
      final trailer = selectTrailer(videos);
      if (trailer == null) return null;
      final item = TrailerFeedItem.fromTmdb(
        candidate.item,
        candidate.mediaType,
        video: trailer,
        reason: candidate.reason,
        reasonTitle: candidate.reasonTitle,
      );
      if (item.tmdbId <= 0 || item.title.isEmpty) return null;
      _resolved[cacheKey] = item;
      return item;
    } catch (_) {
      return null;
    }
  }

  // ── Snapshot ───────────────────────────────────────────────────────────────
  static String _snapshotKey() =>
      'trailers_snapshot_${UserScope.currentOwner}_${ProfileScope.currentProfileId}';

  static const Duration _snapshotTtl = Duration(hours: 24);

  /// Last saved feed, or null when missing/expired/corrupt.
  static Future<List<TrailerFeedItem>?> loadSnapshot() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_snapshotKey());
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final savedAt = DateTime.tryParse('${decoded['savedAt']}');
      if (savedAt == null ||
          DateTime.now().difference(savedAt) > _snapshotTtl) {
        return null;
      }
      final items = (decoded['items'] as List? ?? const [])
          .map(TrailerFeedItem.fromJson)
          .whereType<TrailerFeedItem>()
          .toList();
      return items.isEmpty ? null : items;
    } catch (_) {
      return null;
    }
  }

  static Future<void> saveSnapshot(List<TrailerFeedItem> items) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _snapshotKey(),
        jsonEncode({
          'savedAt': DateTime.now().toIso8601String(),
          'items': items.map((item) => item.toJson()).toList(),
        }),
      );
    } catch (_) {
      // Snapshots are an optimisation; never fail the screen for them.
    }
  }

  /// Drops the session cache (resolved trailers, feed, snapshots are left).
  static void clearCache() {
    _cache = null;
    _cacheAt = null;
    _inFlight = null;
    _resolved.clear();
  }
}

class _Candidate {
  const _Candidate({
    required this.item,
    required this.mediaType,
    required this.reason,
    required this.reasonTitle,
  });

  final Map<String, dynamic> item;
  final String mediaType;
  final TrailerReason reason;
  final String reasonTitle;
}
