/// TMDb metadata configuration.
///
/// The API key is a build-time secret. Supply it with
/// `--dart-define=TMDB_API_KEY=<key>` (CI/Vercel) or
/// `--dart-define-from-file=config/secrets.json` locally. The key is public
/// once shipped inside the binary; never commit it to the repository.
class ApiConfig {
  static const String tmdbApiKey = String.fromEnvironment('TMDB_API_KEY');
  static const String tmdbBaseUrl = 'https://api.themoviedb.org/3';

  static bool get isTmdbConfigured => tmdbApiKey.isNotEmpty;

  /// Returns the TMDb key or throws a message that tells the developer how to
  /// supply it. Services call this instead of reading [tmdbApiKey] directly.
  static String requireTmdbApiKey() {
    if (tmdbApiKey.isEmpty) {
      throw StateError(
        'TMDB_API_KEY is not configured. Rebuild with '
        '--dart-define=TMDB_API_KEY=<key> or '
        '--dart-define-from-file=config/secrets.json.',
      );
    }
    return tmdbApiKey;
  }
}
