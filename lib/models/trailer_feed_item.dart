import '../services/tmdb_api_service.dart';
import '../services/trailer_feed_service.dart';

enum TrailerReason {
  because,
  similar,
  trending;

  static TrailerReason parse(Object? raw) => switch (raw) {
    'because' => TrailerReason.because,
    'similar' => TrailerReason.similar,
    _ => TrailerReason.trending,
  };

  String get storageValue => name;
}

/// One page of the trailers feed: the title, its YouTube trailer, and why it
/// was picked. Kept as a value type so the feed can be snapshotted to disk and
/// rebuilt without another TMDB round-trip.
class TrailerFeedItem {
  const TrailerFeedItem({
    required this.tmdbId,
    required this.mediaType,
    required this.title,
    required this.trailerKey,
    this.overview = '',
    this.releaseYear = '',
    this.posterPath,
    this.backdropPath,
    this.trailerName = '',
    this.trailerPublishedAt = '',
    this.reason = TrailerReason.trending,
    this.reasonTitle = '',
    this.rating,
    this.genreIds = const [],
    this.trailerDuration,
  });

  final int tmdbId;
  final String mediaType;
  final String title;
  final String trailerKey;
  final String overview;
  final String releaseYear;
  final String? posterPath;
  final String? backdropPath;
  final String trailerName;
  final String trailerPublishedAt;
  final TrailerReason reason;
  final String reasonTitle;
  final double? rating;
  final List<int> genreIds;

  /// Exact trailer length, only known from a TMDb session lookup.
  final Duration? trailerDuration;

  bool get isMovie => mediaType == 'movie';

  String get key => '$mediaType:$tmdbId';

  String get typeLabel => isMovie ? 'MOVIE' : 'TV';

  String get reasonLabel => switch (reason) {
    TrailerReason.because =>
      reasonTitle.isEmpty
          ? 'Because you watched'
          : 'Because you watched $reasonTitle',
    TrailerReason.similar =>
      reasonTitle.isEmpty
          ? 'Similar to what you watch'
          : 'More like $reasonTitle',
    TrailerReason.trending => 'Trending now',
  };

  String get railHeadline => switch (reason) {
    TrailerReason.because =>
      reasonTitle.isEmpty
          ? 'Because you watched'
          : 'Because you watched $reasonTitle',
    TrailerReason.similar =>
      reasonTitle.isEmpty
          ? 'More like what you watch'
          : 'More like $reasonTitle',
    TrailerReason.trending => 'Trending trailers',
  };

  String get backdropUrl =>
      TmdbApiService.getImageUrl(backdropPath ?? posterPath, size: 'w780');

  String get posterUrl => TmdbApiService.getPosterUrl(posterPath);

  String get youtubeUrl =>
      Uri.https('www.youtube.com', '/watch', {'v': trailerKey}).toString();

  TrailerFeedItem copyWith({
    TrailerReason? reason,
    String? reasonTitle,
    Duration? trailerDuration,
  }) => TrailerFeedItem(
    tmdbId: tmdbId,
    mediaType: mediaType,
    title: title,
    trailerKey: trailerKey,
    overview: overview,
    releaseYear: releaseYear,
    posterPath: posterPath,
    backdropPath: backdropPath,
    trailerName: trailerName,
    trailerPublishedAt: trailerPublishedAt,
    reason: reason ?? this.reason,
    reasonTitle: reasonTitle ?? this.reasonTitle,
    rating: rating,
    genreIds: genreIds,
    trailerDuration: trailerDuration ?? this.trailerDuration,
  );

  Map<String, dynamic> toJson() => {
    'id': tmdbId,
    'media_type': mediaType,
    'title': title,
    'trailerKey': trailerKey,
    if (overview.isNotEmpty) 'overview': overview,
    if (releaseYear.isNotEmpty) 'year': releaseYear,
    if (posterPath != null) 'poster_path': posterPath,
    if (backdropPath != null) 'backdrop_path': backdropPath,
    if (trailerName.isNotEmpty) 'trailerName': trailerName,
    if (trailerPublishedAt.isNotEmpty) 'trailerPublishedAt': trailerPublishedAt,
    'reason': reason.storageValue,
    if (reasonTitle.isNotEmpty) 'reasonTitle': reasonTitle,
    if (rating != null) 'vote_average': rating,
    if (genreIds.isNotEmpty) 'genre_ids': genreIds,
    if (trailerDuration != null) 'trailer_duration': trailerDuration!.inSeconds,
  };

  /// Tolerant parse: a snapshot written by an older build, or a partially
  /// corrupt entry, must not break the whole feed.
  static TrailerFeedItem? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final tmdbId = int.tryParse('${raw['id'] ?? raw['tmdbId']}') ?? 0;
    final trailerKey = '${raw['trailerKey'] ?? ''}'.trim();
    final title = '${raw['title'] ?? raw['name'] ?? ''}'.trim();
    if (tmdbId <= 0 || trailerKey.isEmpty || title.isEmpty) return null;
    final mediaType = raw['media_type'] == 'tv' || raw['mediaType'] == 'tv'
        ? 'tv'
        : 'movie';
    return TrailerFeedItem(
      tmdbId: tmdbId,
      mediaType: mediaType,
      title: title,
      trailerKey: trailerKey,
      overview: '${raw['overview'] ?? ''}',
      releaseYear: '${raw['year'] ?? ''}',
      posterPath: _stringOrNull(raw['poster_path']),
      backdropPath: _stringOrNull(raw['backdrop_path']),
      trailerName: '${raw['trailerName'] ?? ''}',
      trailerPublishedAt: '${raw['trailerPublishedAt'] ?? ''}',
      reason: TrailerReason.parse(raw['reason']),
      reasonTitle: '${raw['reasonTitle'] ?? ''}',
      rating: (raw['vote_average'] as num?)?.toDouble(),
      genreIds: (raw['genre_ids'] as List? ?? const [])
          .map((id) => int.tryParse('$id'))
          .whereType<int>()
          .toList(),
      trailerDuration: _durationOrNull(raw['trailer_duration']),
    );
  }

  /// Builds an item from a TMDB list payload plus a resolved trailer.
  static TrailerFeedItem fromTmdb(
    Map<String, dynamic> item,
    String mediaType, {
    required Map<String, dynamic> video,
    TrailerReason reason = TrailerReason.trending,
    String reasonTitle = '',
  }) {
    final title = '${item['title'] ?? item['name'] ?? ''}'.trim();
    final date = '${item['release_date'] ?? item['first_air_date'] ?? ''}';
    return TrailerFeedItem(
      tmdbId: int.tryParse('${item['id']}') ?? 0,
      mediaType: mediaType,
      title: title,
      trailerKey: '${video['key']}',
      overview: '${item['overview'] ?? ''}'.trim(),
      releaseYear: date.length >= 4 ? date.substring(0, 4) : '',
      posterPath: _stringOrNull(item['poster_path']),
      backdropPath: _stringOrNull(item['backdrop_path']),
      trailerName: '${video['name'] ?? ''}',
      trailerPublishedAt: '${video['published_at'] ?? ''}',
      reason: reason,
      reasonTitle: reasonTitle,
      rating: (item['vote_average'] as num?)?.toDouble(),
      genreIds: (item['genre_ids'] as List? ?? const [])
          .map((id) => int.tryParse('$id'))
          .whereType<int>()
          .toList(),
      trailerDuration: TrailerFeedService.selectTrailerDuration(video),
    );
  }

  static Duration? _durationOrNull(Object? value) {
    final data = value is Map ? value['duration'] ?? value['seconds'] : value;
    final seconds = (data as num?)?.toInt() ?? int.tryParse('${data ?? ''}');
    return seconds == null || seconds <= 0 ? null : Duration(seconds: seconds);
  }

  static String? _stringOrNull(Object? value) {
    final text = '${value ?? ''}'.trim();
    return text.isEmpty ? null : text;
  }
}
