import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/movie.dart';
import '../models/series.dart';
import '../config/api_config.dart';

class ApiService {
  static String get _apiKey => ApiConfig.requireTmdbApiKey();
  static const String _baseUrl = ApiConfig.tmdbBaseUrl;
  static const Duration _timeout = Duration(seconds: 10);

  // Movie APIs
  static Future<List> fetchTrendingMovies({int page = 1}) async {
    final response = await http
        .get(
          Uri.parse(
            '$_baseUrl/trending/movie/week?api_key=$_apiKey&page=$page',
          ),
        )
        .timeout(_timeout);
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      return data['results'];
    } else {
      throw Exception('Failed to load trending movies');
    }
  }

  static Future<List> fetchPopularMovies({int page = 1}) async {
    final response = await http.get(
      Uri.parse('$_baseUrl/movie/popular?api_key=$_apiKey&page=$page'),
    );
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      return data['results'];
    } else {
      throw Exception('Failed to load popular movies');
    }
  }

  static Future<List> fetchTopRatedMovies({int page = 1}) async {
    final response = await http.get(
      Uri.parse('$_baseUrl/movie/top_rated?api_key=$_apiKey&page=$page'),
    );
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      return data['results'];
    } else {
      throw Exception('Failed to load top-rated movies');
    }
  }

  static Future<List> fetchUpcomingMovies({int page = 1}) async {
    final response = await http.get(
      Uri.parse('$_baseUrl/movie/upcoming?api_key=$_apiKey&page=$page'),
    );
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      return data['results'];
    } else {
      throw Exception('Failed to load upcoming movies');
    }
  }

  static Future<List> searchMovies(String query, {int page = 1}) async {
    final response = await http.get(
      Uri.parse(
        '$_baseUrl/search/movie?api_key=$_apiKey&query=$query&page=$page',
      ),
    );
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      return data['results'];
    } else {
      throw Exception('Failed to search movies');
    }
  }

  // Series APIs
  static Future<List> searchSeries(String query, {int page = 1}) async {
    final response = await http.get(
      Uri.parse('$_baseUrl/search/tv?api_key=$_apiKey&query=$query&page=$page'),
    );
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      return data['results'];
    } else {
      throw Exception('Failed to search series');
    }
  }

  static Future<List> searchAll(String query, {int page = 1}) async {
    final movieResults = await searchMovies(query, page: page);
    final seriesResults = await searchSeries(query, page: page);
    return [...movieResults, ...seriesResults];
  }

  static Future<List<Movie>> fetchPopularSeries({int page = 1}) async {
    final response = await http.get(
      Uri.parse('$_baseUrl/tv/popular?api_key=$_apiKey&page=$page'),
    );
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      return (data['results'] as List)
          .map((item) => Movie.fromJson(item))
          .toList();
    } else {
      throw Exception('Failed to load popular series');
    }
  }

  static Future<List<Movie>> fetchTrendingSeries({int page = 1}) async {
    final response = await http.get(
      Uri.parse('$_baseUrl/trending/tv/week?api_key=$_apiKey&page=$page'),
    );
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      return (data['results'] as List)
          .map((item) => Movie.fromJson(item))
          .toList();
    } else {
      throw Exception('Failed to load trending series');
    }
  }

  static Future<List<Movie>> fetchTopRatedSeries({int page = 1}) async {
    final response = await http.get(
      Uri.parse('$_baseUrl/tv/top_rated?api_key=$_apiKey&page=$page'),
    );
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      return (data['results'] as List)
          .map((item) => Movie.fromJson(item))
          .toList();
    } else {
      throw Exception('Failed to load top-rated series');
    }
  }

  // GENRES
  static Future<Map<int, String>> fetchGenres(String type) async {
    final response = await http.get(
      Uri.parse('$_baseUrl/genre/$type/list?api_key=$_apiKey'),
    );
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      return {
        for (var genre in data['genres'])
          genre['id'] as int: genre['name'] as String,
      };
    } else {
      throw Exception('Failed to fetch genres');
    }
  }

  // TRAILER URL
  static Future<String> fetchTrailerUrl(int id, {bool isMovie = true}) async {
    final type = isMovie ? 'movie' : 'tv';
    final url = '$_baseUrl/$type/$id/videos?api_key=$_apiKey';

    final response = await http.get(Uri.parse(url));
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      final videos = data['results'] as List;
      final trailer = videos.firstWhere(
        (video) => video['type'] == 'Trailer' && video['site'] == 'YouTube',
        orElse: () => {},
      );
      if (trailer.containsKey('key')) {
        return 'https://www.youtube.com/watch?v=${trailer['key']}';
      }
    }
    return '';
  }

  // ENRICH ITEM WITH TRAILER + GENRES
  static Future<Map<String, dynamic>> enrichItem(
    Map<String, dynamic> item,
    String mediaType,
  ) async {
    final id = item['id'];
    final isMovie = mediaType == 'movie';
    final genresMap = await fetchGenres(mediaType);
    final genreIds = List<int>.from(item['genre_ids'] ?? []);
    final genreNames = genreIds
        .map((id) => genresMap[id] ?? '')
        .where((name) => name.isNotEmpty)
        .toList();
    final trailerUrl = await fetchTrailerUrl(id, isMovie: isMovie);

    item['trailerUrl'] = trailerUrl;
    item['genres'] = genreNames;
    return item;
  }

  static Future<Series> fetchSeriesDetails(int seriesId) async {
    final response = await http.get(
      Uri.parse(
        '$_baseUrl/tv/$seriesId?api_key=$_apiKey&append_to_response=season_details',
      ),
    );
    if (response.statusCode == 200) {
      return Series.fromJson(json.decode(response.body));
    } else {
      throw Exception('Failed to load series details');
    }
  }

  static Future<List<Episode>> fetchSeasonEpisodes(
    int seriesId,
    int seasonNumber,
  ) async {
    final response = await http.get(
      Uri.parse('$_baseUrl/tv/$seriesId/season/$seasonNumber?api_key=$_apiKey'),
    );
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      return (data['episodes'] as List)
          .map((episode) => Episode.fromJson(episode))
          .toList();
    } else {
      throw Exception('Failed to load season episodes');
    }
  }

  /// Get series seasons
  static Future<List<Map<String, dynamic>>> getSeriesSeasons(
    int seriesId,
  ) async {
    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/tv/$seriesId?api_key=$_apiKey'),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final seasons = data['seasons'] as List<dynamic>? ?? [];
        return seasons.cast<Map<String, dynamic>>();
      }
    } catch (e) {
      print('Error fetching series seasons: $e');
    }
    return [];
  }

  /// Get series trailers
  static Future<List<Map<String, dynamic>>> getSeriesTrailers(
    int seriesId,
  ) async {
    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/tv/$seriesId/videos?api_key=$_apiKey'),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final videos = data['results'] as List<dynamic>? ?? [];
        // Filter for trailers only
        return videos
            .cast<Map<String, dynamic>>()
            .where((video) => video['type'] == 'Trailer')
            .toList();
      }
    } catch (e) {
      print('Error fetching series trailers: $e');
    }
    return [];
  }

  /// Get latest series
  static Future<List> fetchLatestSeries({int page = 1}) async {
    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/tv/on_the_air?api_key=$_apiKey&page=$page'),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return data['results'] ?? [];
      }
    } catch (e) {
      print('Error fetching latest series: $e');
    }
    return [];
  }

  /// Get upcoming series
  static Future<List> fetchUpcomingSeries({int page = 1}) async {
    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/tv/airing_today?api_key=$_apiKey&page=$page'),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return data['results'] ?? [];
      }
    } catch (e) {
      print('Error fetching upcoming series: $e');
    }
    return [];
  }

  /// Get series by genre
  static Future<List> fetchSeriesByGenre(int genreId, {int page = 1}) async {
    try {
      final response = await http.get(
        Uri.parse(
          '$_baseUrl/discover/tv?api_key=$_apiKey&with_genres=$genreId&page=$page',
        ),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return data['results'] ?? [];
      }
    } catch (e) {
      print('Error fetching series by genre: $e');
    }
    return [];
  }

  // Actor search methods for OnStream-like functionality
  static Future<List<Map<String, dynamic>>> searchActors(
    String query, {
    int page = 1,
  }) async {
    final response = await http.get(
      Uri.parse(
        '$_baseUrl/search/person?api_key=$_apiKey&query=$query&page=$page',
      ),
    );
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      return List<Map<String, dynamic>>.from(data['results']);
    } else {
      throw Exception('Failed to search actors');
    }
  }

  // Get actor details
  static Future<Map<String, dynamic>> getActorDetails(int actorId) async {
    final response = await http.get(
      Uri.parse('$_baseUrl/person/$actorId?api_key=$_apiKey'),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('Failed to load actor details');
    }
  }

  // Get actor movie credits
  static Future<List<Map<String, dynamic>>> getActorMovieCredits(
    int actorId,
  ) async {
    final response = await http.get(
      Uri.parse('$_baseUrl/person/$actorId/movie_credits?api_key=$_apiKey'),
    );
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      return List<Map<String, dynamic>>.from(data['cast']);
    } else {
      throw Exception('Failed to load actor movie credits');
    }
  }

  // Get actor TV credits
  static Future<List<Map<String, dynamic>>> getActorTvCredits(
    int actorId,
  ) async {
    final response = await http.get(
      Uri.parse('$_baseUrl/person/$actorId/tv_credits?api_key=$_apiKey'),
    );
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      return List<Map<String, dynamic>>.from(data['cast']);
    } else {
      throw Exception('Failed to load actor TV credits');
    }
  }
}
