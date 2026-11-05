class Movie {
  final String id; // Changed to String to support various ID formats
  final String title;
  final String description;
  final String thumbnail;
  final String backdrop;
  final String videoUrl;
  final String trailerUrl;
  final List<String> genres;
  final String year; // Changed from releaseDate to year for simplicity
  final double rating;
  final String mediaType; // 'movie' or 'tv'
  final String country; // Optional: Country of production

  // Getters for backwards compatibility and OnStream screens
  String get releaseDate => year;
  String get overview => description;
  String get posterPath => thumbnail;
  String get backdropPath => backdrop;

  Movie({
    required this.id,
    required this.title,
    required this.description,
    required this.thumbnail,
    this.backdrop = '',
    required this.videoUrl,
    this.trailerUrl = '',
    required this.genres,
    required this.year,
    required this.rating,
    required this.mediaType,
    this.country = '',
  });

  factory Movie.fromJson(Map<String, dynamic> json) {
    // Determine media type robustly. Some endpoints omit `media_type`;
    // series results expose `name` and `first_air_date`, movies expose
    // `title` and `release_date`.
    final rawType = json['media_type']?.toString();
    final resolvedType =
        rawType ??
        ((json['first_air_date'] != null || json['name'] != null)
            ? 'tv'
            : 'movie');

    List<String> parsedGenres = [];
    if (json['genre_ids'] is List) {
      final ids = json['genre_ids'] as List;
      parsedGenres = ids.map((id) => _genreMap[id] ?? 'Unknown').toList();
    } else if (json['genres'] is List) {
      parsedGenres = json['genres']
          .map<String>(
            (genre) => (genre is Map && genre.containsKey('name'))
                ? genre['name']
                : genre.toString(),
          )
          .toList();
    }

    final List productionCountries = json['production_countries'] ?? [];
    final country =
        productionCountries.isNotEmpty && productionCountries[0] is Map
        ? (productionCountries[0]['name'] ?? '')
        : '';

    // Extract year from release date
    final releaseDate = json['release_date'] ?? json['first_air_date'] ?? '';
    final year = releaseDate.isNotEmpty ? releaseDate.split('-')[0] : '';

    return Movie(
      id: json['id']?.toString() ?? '0',
      title: json['title'] ?? json['name'] ?? 'Untitled',
      description: json['overview'] ?? 'No description available.',
      thumbnail: 'https://image.tmdb.org/t/p/w500${json['poster_path'] ?? ''}',
      backdrop:
          'https://image.tmdb.org/t/p/original${json['backdrop_path'] ?? ''}',
      videoUrl: '', // Will be populated by VideoService
      trailerUrl: json['trailerUrl'] ?? '',
      genres: parsedGenres,
      year: year,
      rating: (json['vote_average'] as num?)?.toDouble() ?? 0.0,
      mediaType: resolvedType,
      country: country,
    );
  }
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'description': description,
      'thumbnail': thumbnail,
      'backdrop': backdrop,
      'videoUrl': videoUrl,
      'trailerUrl': trailerUrl,
      'genres': genres.join(','), // store as comma-separated
      'year': year,
      'rating': rating,
      'mediaType': mediaType,
      'country': country,
    };
  }

  factory Movie.fromMap(Map<String, dynamic> map) {
    return Movie(
      id: map['id']?.toString() ?? '0',
      title: map['title'] ?? '',
      description: map['description'] ?? '',
      thumbnail: map['thumbnail'] ?? '',
      backdrop: map['backdrop'] ?? '',
      videoUrl: map['videoUrl'] ?? '',
      trailerUrl: map['trailerUrl'] ?? '',
      genres: map['genres']?.toString().split(',') ?? [],
      year: map['year']?.toString() ?? '',
      rating: (map['rating'] as num?)?.toDouble() ?? 0.0,
      mediaType: map['mediaType'] ?? 'movie',
      country: map['country'] ?? '',
    );
  }
}

const Map<int, String> _genreMap = {
  28: 'Action',
  12: 'Adventure',
  16: 'Animation',
  35: 'Comedy',
  80: 'Crime',
  99: 'Documentary',
  18: 'Drama',
  10751: 'Family',
  14: 'Fantasy',
  36: 'History',
  27: 'Horror',
  10402: 'Music',
  9648: 'Mystery',
  10749: 'Romance',
  878: 'Science Fiction',
  10770: 'TV Movie',
  53: 'Thriller',
  10752: 'War',
  37: 'Western',
};
