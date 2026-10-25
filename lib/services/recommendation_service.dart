import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import 'profile_scope.dart';
import 'tmdb_api_service.dart';
import 'user_scope.dart';
import 'watch_history_service.dart';

/// Last computed rows, kept on disk so a cold start can paint the screen
/// immediately and refresh behind it instead of showing a skeleton while a
/// dozen TMDB round-trips run.
class RecommendationSnapshot {
  const RecommendationSnapshot({
    required this.forYou,
    required this.becauseYouWatched,
    required this.byGenre,
    required this.genreIdByName,
    required this.savedAt,
  });

  final List<Map<String, dynamic>> forYou;
  final List<Map<String, dynamic>> becauseYouWatched;
  final Map<String, List<Map<String, dynamic>>> byGenre;
  final Map<int, String> genreIdByName;
  final DateTime savedAt;
}

class RecommendationService {
  // ── Row cache (in-memory, per key) ─────────────────────────────────────────
  // Was a single shared timestamp for every key, so one fresh entry marked
  // unrelated entries fresh and one stale entry marked all of them stale.
  static final Map<String, List<Map<String, dynamic>>> _cache = {};
  static final Map<String, DateTime> _cacheTimes = {};
  /// Top-genre ids are cached separately from the row cache (different type).
  static final Map<int, List<int>> _topGenresCache = {};
  static const Duration _cacheTtl = Duration(minutes: 30);

  // ── Genre cache (persisted) ────────────────────────────────────────────────
  // `tmdbId_isMovie` -> genre ids. Enriching the watch history used to be a
  // serial chain of full detail requests on EVERY load (twice per load, because
  // both the screen and getForYou asked for the top genres). Genre ids never
  // change for an item, so they are remembered across launches.
  static final Map<String, List<int>> _genreCache = {};
  static bool _genreCacheLoaded = false;
  static const int _maxGenreEntries = 400;

  /// Only the newest N items are profiled. The weighting is dominated by recent
  /// watches anyway, and this caps the fan-out on a long history.
  static const int _maxGenreLookups = 10;

  /// In-flight [getTopGenres] computation, so the screen and getForYou share one
  /// pass instead of running the same work twice.
  static Future<List<int>>? _topGenresInFlight;

  /// Analyze the user's watch history and return top genre IDs weighted by
  /// watch count and completion percentage.
  ///
  /// Enrichment now runs concurrently and is cached permanently per item, so a
  /// repeat visit costs zero requests.
  static Future<List<int>> getTopGenres({int limit = 5, bool refresh = false}) async {
    if (!refresh) {
      if (!_isStale('topGenres')) {
        // Any wider computed list can serve a narrower limit.
        final cached = _topGenresCache.entries
            .map((e) => e.value)
            .firstWhere(
              (value) => value.length >= limit,
              orElse: () => const <int>[],
            );
        if (cached.isNotEmpty) return cached.take(limit).toList();
      }
      final inFlight = _topGenresInFlight;
      if (inFlight != null) return (await inFlight).take(limit).toList();
    }

    final future = _computeTopGenres(limit);
    _topGenresInFlight = future;
    try {
      final result = await future;
      // Keep the widest computed set so a smaller limit can be served from it.
      final widest = _topGenresCache[limit];
      if (widest == null || result.length > widest.length) {
        _topGenresCache[limit] = result;
      }
      _cacheTimes['topGenres'] = DateTime.now();
      return result.take(limit).toList();
    } finally {
      if (identical(_topGenresInFlight, future)) _topGenresInFlight = null;
    }
  }

  static Future<List<int>> _computeTopGenres(int limit) async {
    final history = await WatchHistoryService.getWatchHistory();
    if (history.isEmpty) return [];

    // Group unique items by tmdbId + isMovie to avoid duplicate API calls.
    // History is newest-first, so keep that order and cap the fan-out.
    final uniqueItems = <String, Map<String, dynamic>>{};
    for (final item in history) {
      final key = '${item['tmdbId']}_${item['isMovie']}';
      uniqueItems.putIfAbsent(key, () => item);
    }
    await _loadGenreCache();

    // Resolve the missing genre ids CONCURRENTLY. The old loop awaited each
    // detail request one at a time, so twenty watched items meant twenty
    // sequential round-trips before the screen could show anything.
    final needsLookup = <String, Map<String, dynamic>>{};
    final genreIds = <String, List<int>>{};
    for (final entry in uniqueItems.entries) {
      final stored = List<int>.from(
        entry.value['genreIds'] ?? entry.value['genre_ids'] ?? const [],
      );
      if (stored.isNotEmpty) {
        genreIds[entry.key] = stored;
      } else if (_genreCache.containsKey(entry.key)) {
        genreIds[entry.key] = _genreCache[entry.key]!;
      } else {
        needsLookup[entry.key] = entry.value;
      }
    }

    final lookupEntries = needsLookup.entries
        .take(_maxGenreLookups)
        .toList(growable: false);
    if (lookupEntries.isNotEmpty) {
      final resolved = await Future.wait(
        lookupEntries.map((entry) => _fetchGenreIds(entry.value)),
      );
      var added = false;
      for (var i = 0; i < lookupEntries.length; i++) {
        final ids = resolved[i];
        if (ids.isEmpty) continue;
        genreIds[lookupEntries[i].key] = ids;
        _genreCache[lookupEntries[i].key] = ids;
        added = true;
      }
      if (added) unawaited(_persistGenreCache());
    }

    final genreWeights = <int, double>{};
    for (final entry in uniqueItems.entries) {
      final ids = genreIds[entry.key];
      if (ids == null || ids.isEmpty) continue;

      final item = entry.value;
      final isWatched = item['isWatched'] == true;
      final watchPct = (item['watchPercentage'] as num?)?.toDouble() ?? 0.0;

      var weight = 1.0;
      if (isWatched) {
        weight = 2.0;
      } else if (watchPct > 0.5) {
        weight = 1.5;
      }

      for (final genreId in ids) {
        genreWeights[genreId] = (genreWeights[genreId] ?? 0) + weight;
      }
    }

    final sorted = genreWeights.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return sorted.take(limit).map((e) => e.key).toList();
  }

  /// Genre ids for one watched item. Uses the shared detail cache so this is a
  /// single request, and returns an empty list rather than throwing.
  static Future<List<int>> _fetchGenreIds(Map<String, dynamic> item) async {
    final tmdbId = int.tryParse(item['tmdbId']?.toString() ?? '') ?? 0;
    if (tmdbId <= 0) return const [];
    try {
      final isMovie = item['isMovie'] == true;
      final details = isMovie
          ? await TmdbApiService.getMovieDetails(tmdbId)
          : await TmdbApiService.getSeriesDetails(tmdbId);
      return ((details?['genres'] as List<dynamic>?) ?? const [])
          .map((g) => (g as Map)['id'])
          .whereType<int>()
          .toList();
    } catch (_) {
      // Genre enrichment is best-effort.
      return const [];
    }
  }

  static String _genreCacheKey() =>
      'rec_genres_${UserScope.currentOwner}_${ProfileScope.currentProfileId}';

  static Future<void> _loadGenreCache() async {
    if (_genreCacheLoaded) return;
    _genreCacheLoaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_genreCacheKey());
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      decoded.forEach((key, value) {
        if (value is List) {
          _genreCache['$key'] = value.whereType<int>().toList();
        }
      });
    } catch (_) {
      // Corrupt cache: start over rather than fail the screen.
    }
  }

  static Future<void> _persistGenreCache() async {
    try {
      if (_genreCache.length > _maxGenreEntries) {
        // Oldest insertion order first; keep the most recent lookups.
        final keep = _genreCache.keys.toList()
          ..sort((a, b) => _genreCache[a]!.length.compareTo(_genreCache[b]!.length));
        while (_genreCache.length > _maxGenreEntries) {
          _genreCache.remove(keep.removeAt(0));
        }
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_genreCacheKey(), jsonEncode(_genreCache));
    } catch (_) {}
  }

  static bool _isStale(String key) {
    final at = _cacheTimes[key];
    return at == null || DateTime.now().difference(at) > _cacheTtl;
  }

  static Future<List<Map<String, dynamic>>> _fetchAndCache(
    String key,
    Future<List<Map<String, dynamic>>> Function() fetcher,
  ) async {
    if (!_isStale(key) && _cache.containsKey(key)) return _cache[key]!;
    final results = await fetcher();
    _cache[key] = results;
    _cacheTimes[key] = DateTime.now();
    return results;
  }

  /// "For You" — content filtered by the user's top genres, with a fallback to
  /// global trending when there is no watch history.
  ///
  /// Pass [topGenres] when the caller already computed them: recomputing here
  /// used to repeat the whole genre-profiling pass a second time per load.
  static Future<List<Map<String, dynamic>>> getForYou({
    int page = 1,
    List<int>? topGenres,
  }) async {
    final genres = topGenres ?? await getTopGenres(limit: 3);
    if (genres.isEmpty) {
      return _fetchAndCache('forYou_global', () async {
        final movies = await TmdbApiService.fetchTrendingMovies(page: page);
        final series = await TmdbApiService.fetchTrendingSeries(page: page);
        return _mergeAndShuffle(movies, series, 'movie', 'tv');
      });
    }

    final genreParam = genres.join(',');
    return _fetchAndCache('forYou_$genreParam', () async {
      final movies = await TmdbApiService.getMoviesByGenre(
        genres.first,
        page: page,
      );
      final series = await TmdbApiService.getSeriesByGenre(
        genres.first,
        page: page,
      );
      return _mergeAndShuffle(movies, series, 'movie', 'tv');
    });
  }

  /// "Because You Watched {title}" — uses TMDB recommendations for the most
  /// recently-watched item (movie or episode). Previously this preferred any
  /// old `isWatched==true` entry, so a series watched last week could stay
  /// pinned even after bingeing new content. Now it always reflects the
  /// latest history entry so the row updates after every watch (movie,
  /// single episode, whole season or series).
  static Future<List<Map<String, dynamic>>> getBecauseYouWatched({
    int limit = 20,
  }) async {
    final history = await WatchHistoryService.getWatchHistory();
    if (history.isEmpty) return [];

    // Most recent entry (WatchHistoryService returns history newest-first).
    // This guarantees the row follows the latest watch.
    final recent = history.first;
    final tmdbId = int.tryParse(recent['tmdbId']?.toString() ?? '') ?? 0;
    if (tmdbId == 0) return [];
    final isMovie = recent['isMovie'] == true;
    final from = recent['title'] ?? recent['seriesTitle'] ?? '';

    return _fetchAndCache('byw_${tmdbId}_$isMovie', () async {
      final details = isMovie
          ? await TmdbApiService.getMovieDetails(tmdbId)
          : await TmdbApiService.getSeriesDetails(tmdbId);
      final recs = List<Map<String, dynamic>>.from(
        details?['recommendations']?['results'] ?? const [],
      );
      return recs.take(limit).map((item) {
        item['recommendedFrom'] = from;
        item['recommendedMediaType'] = isMovie ? 'movie' : 'tv';
        return item;
      }).toList();
    });
  }

  /// Genre rows — fetch content for each of the user's top genres.
  static Future<List<Map<String, dynamic>>> getByGenre(
    int genreId, {
    int page = 1,
  }) async {
    if (page > 1) {
      final movies = await TmdbApiService.getMoviesByGenre(genreId, page: page);
      final series = await TmdbApiService.getSeriesByGenre(genreId, page: page);
      return _mergeAndShuffle(movies, series, 'movie', 'tv');
    }
    return _fetchAndCache('genre_$genreId', () async {
      final movies = await TmdbApiService.getMoviesByGenre(genreId, page: page);
      final series = await TmdbApiService.getSeriesByGenre(genreId, page: page);
      return _mergeAndShuffle(movies, series, 'movie', 'tv');
    });
  }

  /// Get new/trending content for the user's top genres (used by notifications).
  static Future<List<Map<String, dynamic>>> getNewReleasesForNotifications({
    int limit = 5,
  }) async {
    final topGenres = await getTopGenres(limit: 3);
    if (topGenres.isEmpty) return [];

    final results = <Map<String, dynamic>>[];
    for (final genreId in topGenres.take(2)) {
      final movies = await TmdbApiService.results('/discover/movie', {
        'with_genres': genreId,
        'sort_by': 'popularity.desc',
        'vote_count.gte': 200,
      });
      final series = await TmdbApiService.results('/discover/tv', {
        'with_genres': genreId,
        'sort_by': 'popularity.desc',
        'vote_count.gte': 200,
      });
      for (final item in [...movies, ...series]) {
        item['mediaType'] = item['media_type'] ??
            (item.containsKey('first_air_date') ? 'tv' : 'movie');
        results.add(item);
      }
    }

    results.shuffle(Random());
    return results.take(limit).toList();
  }

  // ── Disk snapshot ─────────────────────────────────────────────────────────
  static String _snapshotKey() =>
      'recs_snapshot_${UserScope.currentOwner}_${ProfileScope.currentProfileId}';

  /// Snapshots older than this are ignored (the screen just shows its
  /// skeleton instead).
  static const Duration _snapshotTtl = Duration(hours: 24);

  /// Last saved rows, or null when there is nothing usable. Read on screen
  /// entry so content paints before any network call completes.
  static Future<RecommendationSnapshot?> loadSnapshot() async {
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
      return RecommendationSnapshot(
        forYou: _decodeItems(decoded['forYou']),
        becauseYouWatched: _decodeItems(decoded['becauseYouWatched']),
        byGenre: (decoded['byGenre'] as Map? ?? const {}).map(
          (key, value) => MapEntry('$key', _decodeItems(value)),
        ),
        genreIdByName: (decoded['genreIdByName'] as Map? ?? const {}).map(
          (key, value) => MapEntry(int.tryParse('$key') ?? -1, '$value'),
        ),
        savedAt: savedAt,
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> saveSnapshot({
    required List<Map<String, dynamic>> forYou,
    required List<Map<String, dynamic>> becauseYouWatched,
    required Map<String, List<Map<String, dynamic>>> byGenre,
    required Map<int, String> genreIdByName,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _snapshotKey(),
        jsonEncode({
          'savedAt': DateTime.now().toIso8601String(),
          'forYou': forYou.map(_encodeItem).toList(),
          'becauseYouWatched': becauseYouWatched.map(_encodeItem).toList(),
          'byGenre': byGenre.map(
            (key, value) => MapEntry(key, value.map(_encodeItem).toList()),
          ),
          'genreIdByName': genreIdByName.map(
            (key, value) => MapEntry('$key', value),
          ),
        }),
      );
    } catch (_) {}
  }

  /// Keeps only the fields the screen renders, so the snapshot stays small
  /// (a full TMDB payload would be megabytes of credits and videos).
  static Map<String, dynamic> _encodeItem(Map<String, dynamic> item) => {
        'id': item['id'],
        'media_type': item['mediaType'] ?? item['media_type'],
        if ((item['title'] ?? item['name']) != null)
          'title': item['title'] ?? item['name'],
        if (item['poster_path'] != null) 'poster_path': item['poster_path'],
        if (item['vote_average'] != null) 'vote_average': item['vote_average'],
        if ((item['release_date'] ?? item['first_air_date']) != null)
          'release_date': item['release_date'] ?? item['first_air_date'],
        if (item['recommendedFrom'] != null)
          'recommendedFrom': item['recommendedFrom'],
        if (item['recommendedMediaType'] != null)
          'recommendedMediaType': item['recommendedMediaType'],
      };

  static List<Map<String, dynamic>> _decodeItems(Object? value) {
    if (value is! List) return const [];
    final items = <Map<String, dynamic>>[];
    for (final entry in value) {
      if (entry is! Map) continue;
      final map = entry.map((k, v) => MapEntry('$k', v));
      // The screens read `mediaType`; TMDB sends `media_type`.
      if (map['mediaType'] == null && map['media_type'] != null) {
        map['mediaType'] = map['media_type'];
      }
      items.add(map);
    }
    return items;
  }

  static List<Map<String, dynamic>> _mergeAndShuffle(
    List<Map<String, dynamic>> a,
    List<Map<String, dynamic>> b,
    String typeA,
    String typeB,
  ) {
    for (final item in a) {
      item['mediaType'] = typeA;
    }
    for (final item in b) {
      item['mediaType'] = typeB;
    }
    final merged = [...a, ...b];
    merged.shuffle(Random());
    return merged;
  }

  /// Drops the cached ROWS (so the next load re-queries TMDB).
  ///
  /// Deliberately keeps the persisted genre ids: those never change, and
  /// clearing them is what made every watch/resume re-run the whole genre
  /// profiling chain.
  static void clearCache() {
    _cache.clear();
    _cacheTimes.clear();
    _topGenresCache.clear();
    _topGenresInFlight = null;
  }
}
