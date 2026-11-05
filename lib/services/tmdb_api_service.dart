import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/api_config.dart';

/// Error information for the most recently failed TMDB request.
class TmdbApiException implements Exception {
  const TmdbApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => 'TmdbApiException($statusCode): $message';
}

class TmdbApiService {
  static String get _apiKey => ApiConfig.requireTmdbApiKey();
  static const Duration _timeout = Duration(seconds: 10);
  static http.Client _client = http.Client();

  /// Allows tests and application hosts to supply their own HTTP client.
  static void setHttpClient(http.Client client) => _client = client;

  /// Builds a correctly encoded TMDB URI. Kept public for focused tests.
  static Uri buildUri(
    String path, [
    Map<String, Object?> parameters = const {},
  ]) {
    final base = Uri.parse(ApiConfig.tmdbBaseUrl);
    return Uri.https(base.authority, '${base.path}$path', {
      'api_key': _apiKey,
      for (final entry in parameters.entries)
        if (entry.value != null) entry.key: entry.value.toString(),
    });
  }

  static Future<Map<String, dynamic>> _getJson(
    String path, [
    Map<String, Object?> parameters = const {},
  ]) async {
    final uri = buildUri(path, parameters);
    try {
      final response = await _client.get(uri).timeout(_timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw TmdbApiException(
          'TMDB returned HTTP ${response.statusCode}',
          statusCode: response.statusCode,
        );
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const TmdbApiException('TMDB returned invalid JSON');
      }
      return decoded;
    } on TmdbApiException {
      rethrow;
    } catch (error) {
      throw TmdbApiException(error.toString());
    }
  }

  /// Filter a TMDB results list to only include items whose release/air date
  /// is strictly in the future (i.e. not yet released).
  static List<Map<String, dynamic>> filterUnreleased(
    List<Map<String, dynamic>> items, {
    String dateField = 'release_date',
  }) {
    final today = DateTime.now();
    return items.where((item) {
      final dateStr = item[dateField]?.toString();
      if (dateStr == null || dateStr.length < 10) return false;
      try {
        final releaseDate = DateTime.parse(dateStr);
        return releaseDate.isAfter(today);
      } catch (_) {
        return false;
      }
    }).toList();
  }

  static Future<List<Map<String, dynamic>>> results(
    String path, [
    Map<String, Object?> parameters = const {},
  ]) async {
    final data = await _getJson(path, parameters);
    return List<Map<String, dynamic>>.from(data['results'] ?? const []);
  }

  static Future<List<Map<String, dynamic>>> fetchTrendingMovies({
    int page = 1,
  }) => results('/trending/movie/week', {'page': page});
  static Future<List<Map<String, dynamic>>> fetchPopularMovies({
    int page = 1,
  }) => results('/movie/popular', {'page': page});
  static Future<List<Map<String, dynamic>>> fetchTopRatedMovies({
    int page = 1,
  }) => results('/movie/top_rated', {'page': page});
  static Future<List<Map<String, dynamic>>> fetchUpcomingMovies({
    int page = 1,
  }) => results('/movie/upcoming', {'page': page});
  static Future<List<Map<String, dynamic>>> fetchNowPlayingMovies({
    int page = 1,
  }) => results('/movie/now_playing', {'page': page});

  static Future<List<Map<String, dynamic>>> fetchTrendingSeries({
    int page = 1,
  }) => results('/trending/tv/week', {'page': page});
  static Future<List<Map<String, dynamic>>> fetchPopularSeries({
    int page = 1,
  }) => results('/tv/popular', {'page': page});
  static Future<List<Map<String, dynamic>>> fetchTopRatedSeries({
    int page = 1,
  }) => results('/tv/top_rated', {'page': page});
  static Future<List<Map<String, dynamic>>> fetchOnTheAirSeries({
    int page = 1,
  }) => results('/tv/on_the_air', {'page': page});
  static Future<List<Map<String, dynamic>>> fetchAiringTodaySeries({
    int page = 1,
  }) => results('/tv/airing_today', {'page': page});
  static Future<List<Map<String, dynamic>>> fetchUpcomingSeries({
    int page = 1,
  }) {
    final now = DateTime.now().toIso8601String().split('T').first;
    return results('/discover/tv', {
      'page': page,
      'sort_by': 'first_air_date.asc',
      'first_air_date.gte': now,
      'vote_count.gte': 10,
    });
  }

  static Future<List<Map<String, dynamic>>> searchMovies(
    String query, {
    int page = 1,
  }) => results('/search/movie', {'query': query, 'page': page});
  static Future<List<Map<String, dynamic>>> searchSeries(
    String query, {
    int page = 1,
  }) => results('/search/tv', {'query': query, 'page': page});
  static Future<List<Map<String, dynamic>>> searchActors(
    String query, {
    int page = 1,
  }) => results('/search/person', {'query': query, 'page': page});
  static Future<List<Map<String, dynamic>>> searchAll(
    String query, {
    int page = 1,
  }) => results('/search/multi', {'query': query, 'page': page});

  static Future<Map<String, dynamic>?> getMovieDetails(int movieId) =>
      _getJson('/movie/$movieId', {
        'append_to_response':
            'credits,videos,similar,recommendations,watch/providers',
      });
  static Future<Map<String, dynamic>?> getSeriesDetails(int seriesId) =>
      _getJson('/tv/$seriesId', {
        'append_to_response':
            'credits,videos,similar,recommendations,watch/providers',
      });
  static Future<Map<String, dynamic>?> getActorDetails(int actorId) => _getJson(
    '/person/$actorId',
    {'append_to_response': 'movie_credits,tv_credits,external_ids'},
  );

  static Future<List<Map<String, dynamic>>> getSeasonEpisodes(
    int seriesId,
    int seasonNumber,
  ) async {
    final data = await _getJson('/tv/$seriesId/season/$seasonNumber');
    return List<Map<String, dynamic>>.from(data['episodes'] ?? const []);
  }

  static Future<Map<int, String>> fetchGenres(String type) async {
    final data = await _getJson('/genre/$type/list');
    return {
      for (final genre in data['genres'] ?? const [])
        genre['id'] as int: genre['name'] as String,
    };
  }

  static Future<List<Map<String, dynamic>>> fetchGenreList() =>
      results('/genre/movie/list', {'language': 'en-US'});

  static Future<List<Map<String, dynamic>>> getMoviesByGenre(
    int genreId, {
    int page = 1,
  }) => results('/discover/movie', {'with_genres': genreId, 'page': page});
  static Future<List<Map<String, dynamic>>> getSeriesByGenre(
    int genreId, {
    int page = 1,
  }) => results('/discover/tv', {'with_genres': genreId, 'page': page});

  static Future<List<Map<String, dynamic>>> getVideos(
    int id, {
    bool isMovie = true,
  }) => results('/${isMovie ? 'movie' : 'tv'}/$id/videos');

  static Future<String> getTrailerUrl(int id, {bool isMovie = true}) async {
    final videos = await getVideos(id, isMovie: isMovie);
    final trailer = videos.firstWhere(
      (video) => video['type'] == 'Trailer' && video['site'] == 'YouTube',
      orElse: () => const {},
    );
    return trailer['key'] == null
        ? ''
        : Uri.https('www.youtube.com', '/watch', {
            'v': trailer['key'].toString(),
          }).toString();
  }

  static String getImageUrl(String? imagePath, {String size = 'w500'}) {
    if (imagePath == null || imagePath.isEmpty) return '';
    // Some callers pass a fully-formed URL (e.g. a watchlist thumbnail stored
    // as `https://image.tmdb.org/t/p/w500/...`). Return it untouched instead of
    // double-prefixing the base URL, which produces a broken image.
    if (imagePath.startsWith('http://') || imagePath.startsWith('https://')) {
      return imagePath;
    }
    return Uri.https('image.tmdb.org', '/t/p/$size$imagePath').toString();
  }

  static String getFullImageUrl(String? imagePath) =>
      getImageUrl(imagePath, size: 'original');
  static String getPosterUrl(String? posterPath) => getImageUrl(posterPath);
  static String getBackdropUrl(String? backdropPath) =>
      getImageUrl(backdropPath, size: 'w1280');
  static String getProfileUrl(String? profilePath) =>
      getImageUrl(profilePath, size: 'w185');

  static Future<List<Map<String, dynamic>>> getMoviesByProvider(
    int providerId, {
    int page = 1,
  }) => results('/discover/movie', {
    'with_watch_providers': providerId,
    'watch_region': 'US',
    'page': page,
  });

  static Future<List<Map<String, dynamic>>> getSeriesByProvider(
    int providerId, {
    int page = 1,
  }) => results('/discover/tv', {
    'with_watch_providers': providerId,
    'watch_region': 'US',
    'page': page,
  });

  static Future<Map<String, dynamic>> enrichItem(
    Map<String, dynamic> item,
    String mediaType,
  ) async {
    try {
      final genresMap = await fetchGenres(mediaType);
      final genreIds = List<int>.from(item['genre_ids'] ?? const []);
      item['genres'] = genreIds
          .map((id) => genresMap[id] ?? '')
          .where((name) => name.isNotEmpty)
          .toList();
      item['trailerUrl'] = await getTrailerUrl(
        item['id'] as int,
        isMovie: mediaType == 'movie',
      );
      item['poster_url'] = getPosterUrl(item['poster_path']);
      item['backdrop_url'] = getBackdropUrl(item['backdrop_path']);
    } catch (_) {
      // Enrichment is optional; preserve the original item on failure.
    }
    return item;
  }
}
