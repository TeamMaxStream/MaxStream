import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'native_stream_extractor.dart';
import 'stream_security.dart';
import 'web_stream_service.dart';

/// Stream extraction service.
/// On mobile: delegates to native Android Kotlin extractors via platform channel.
/// On web: uses web-compatible embed URLs and HTTP requests.
class DirectM3u8Service {
  static const String _tag = 'DirectM3u8Service';

  /// In-memory server-list cache so reopening a picker is instant.
  /// Key: "$tmdbId|$isMovie|$season|$episode". TTL 5 minutes.
  static const Duration _cacheTtl = Duration(minutes: 5);
  static final Map<String, _CachedStreams> _streamsCache = {};

  static String _cacheKey(
    String tmdbId,
    bool isMovie,
    int season,
    int episode,
  ) => '$tmdbId|$isMovie|$season|$episode';

  /// Returns cached server lists (including failed entries) or null.
  static List<Map<String, dynamic>>? cachedStreams({
    required String tmdbId,
    required bool isMovie,
    int season = 1,
    int episode = 1,
  }) {
    final entry = _streamsCache[_cacheKey(tmdbId, isMovie, season, episode)];
    if (entry == null) return null;
    if (DateTime.now().difference(entry.fetchedAt) > _cacheTtl) {
      _streamsCache.remove(_cacheKey(tmdbId, isMovie, season, episode));
      return null;
    }
    return entry.streams;
  }

  /// Fire-and-forget warm of the server list (call when a details screen
  /// loads so the download picker later opens instantly).
  static void prefetchAvailableStreams({
    required String title,
    required String tmdbId,
    required bool isMovie,
    int season = 1,
    int episode = 1,
  }) {
    if (cachedStreams(
          tmdbId: tmdbId,
          isMovie: isMovie,
          season: season,
          episode: episode,
        ) !=
        null) {
      return;
    }
    fetchAvailableStreams(
      title: title,
      tmdbId: tmdbId,
      isMovie: isMovie,
      season: season,
      episode: episode,
    ).then((_) {}, onError: (_) {});
  }

  static Future<Map<String, dynamic>?> fetchMovieStreamUrl(
    String title,
    int? year,
    String? tmdbId,
  ) async {
    final id = tmdbId?.trim();
    if (id == null || id.isEmpty) return null;
    debugPrint('$_tag: Resolving movie $title (TMDB: $id)');

    if (kIsWeb) {
      return WebStreamService.resolveStream(
        tmdbId: id,
        isMovie: true,
        title: title,
      );
    }

    final result = await NativeStreamExtractor.resolveStream(
      tmdbId: id,
      isMovie: true,
      title: title,
    );

    return StreamSecurity.sanitizeResolverResult(result);
  }

  static Future<Map<String, dynamic>?> fetchSeriesStreamUrl(
    String title,
    int season,
    int episode,
    String? tmdbId,
  ) async {
    final id = tmdbId?.trim();
    if (id == null || id.isEmpty) return null;
    debugPrint('$_tag: Resolving $title S${season}E$episode (TMDB: $id)');

    if (kIsWeb) {
      return WebStreamService.resolveStream(
        tmdbId: id,
        isMovie: false,
        season: season,
        episode: episode,
        title: title,
      );
    }

    final result = await NativeStreamExtractor.resolveStream(
      tmdbId: id,
      isMovie: false,
      season: season,
      episode: episode,
      title: title,
    );

    return StreamSecurity.sanitizeResolverResult(result);
  }

  static Future<List<Map<String, dynamic>>> fetchAvailableStreams({
    required String title,
    required String tmdbId,
    required bool isMovie,
    int season = 1,
    int episode = 1,
    bool fast = false,
    bool useCache = true,
  }) async {
    if (kIsWeb) {
      // On web, return embed sources as available servers
      final sources = WebStreamService.servers;
      return sources.map((source) {
        final url = isMovie
            ? source['movieUrl']!.replaceAll('{id}', tmdbId)
            : source['tvUrl']!
                  .replaceAll('{id}', tmdbId)
                  .replaceAll('{season}', season.toString())
                  .replaceAll('{episode}', episode.toString());
        return {
          'url': url,
          'source': source['name'],
          'type': 'embed',
          'isEmbed': true,
        };
      }).toList();
    }

    final streams = await NativeStreamExtractor.resolveStreams(
      tmdbId: tmdbId,
      isMovie: isMovie,
      season: season,
      episode: episode,
      title: title,
      fast: fast,
    );
    // Keep every entry, including servers whose extraction failed (empty
    // URL, available: false) so the picker can list them and offer re-fetch.
    final result = streams
        .map((stream) {
          final url = stream['url']?.toString() ?? '';
          if (url.isEmpty) {
            return {
              ...stream,
              'headers': StreamSecurity.sanitizeHeaders(
                stream['headers'] is Map ? stream['headers'] as Map : null,
              ),
            };
          }
          return StreamSecurity.sanitizeResolverResult(stream);
        })
        .whereType<Map<String, dynamic>>()
        .toList();
    if (useCache && !fast) {
      _streamsCache[_cacheKey(tmdbId, isMovie, season, episode)] =
          _CachedStreams(result, DateTime.now());
    }
    return result;
  }

  /// Re-resolves a single named server on demand (used when the user taps a
  /// server that failed during discovery). Returns the sanitized stream map,
  /// or null if the server is still unavailable.
  static Future<Map<String, dynamic>?> resolveServer({
    required String serverName,
    required String title,
    required String tmdbId,
    required bool isMovie,
    int season = 1,
    int episode = 1,
  }) async {
    if (kIsWeb) return null;
    final result = await NativeStreamExtractor.resolveServer(
      serverName: serverName,
      tmdbId: tmdbId,
      isMovie: isMovie,
      season: season,
      episode: episode,
      title: title,
    );
    return StreamSecurity.sanitizeResolverResult(result);
  }

  /// Pre-flight check that a resolved stream URL will actually play before we
  /// hand it to ExoPlayer. Downloads only the head of the resource (the HLS
  /// manifest is small; a direct file is capped at 64KB) so it is fast, and
  /// rejects only URLs that are definitively dead (unreachable, non-2xx, or
  /// empty body). It deliberately errs on the side of passing: CDNs often
  /// behave differently for different clients, so a stream that merely looks
  /// odd is still handed to the player, which is the final arbiter. The caller
  /// uses this to prefer working servers, never to block every server.
  static Future<bool> validateStream(
    String url, {
    Map<String, String> headers = const {},
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (kIsWeb) return true;
    if (url.isEmpty) return false;
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return false;

    final client = http.Client();
    try {
      final request = http.Request('GET', uri)
        ..headers.addAll(headers)
        ..headers.putIfAbsent(
          'User-Agent',
          () =>
              'Mozilla/5.0 (Linux; Android 10) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36',
        );
      final response = await client.send(request).timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        debugPrint('$_tag: reject $url -> HTTP ${response.statusCode}');
        return false;
      }
      final bytes = <int>[];
      await for (final chunk in response.stream.timeout(timeout)) {
        bytes.addAll(chunk);
        if (bytes.length > 65536) break;
      }
      if (bytes.isEmpty) {
        debugPrint('$_tag: reject $url -> empty body');
        return false;
      }
      return true;
    } catch (e) {
      debugPrint('$_tag: reject $url -> $e');
      return false;
    } finally {
      client.close();
    }
  }

  /// Embed URLs for VidLinkExtractor fallback.
  static const List<Map<String, String>> _embedSources = [
    {
      'name': 'VidLink',
      'movieUrl': 'https://vidlink.pro/movie/{id}',
      'tvUrl': 'https://vidlink.pro/tv/{id}/{season}/{episode}',
    },
  ];

  static List<Map<String, String>> getEmbedSources() =>
      List.from(_embedSources);

  static String generateMovieEmbedUrl(String tmdbId, String sourceName) {
    final s = _embedSources.firstWhere(
      (s) => s['name'] == sourceName,
      orElse: () => _embedSources.first,
    );
    return s['movieUrl']!.replaceAll('{id}', tmdbId);
  }

  static String generateTvEmbedUrl(
    String tmdbId,
    int season,
    int episode,
    String sourceName,
  ) {
    final s = _embedSources.firstWhere(
      (s) => s['name'] == sourceName,
      orElse: () => _embedSources.first,
    );
    return s['tvUrl']!
        .replaceAll('{id}', tmdbId)
        .replaceAll('{season}', season.toString())
        .replaceAll('{episode}', episode.toString());
  }
}

/// One cached server-list entry for [DirectM3u8Service._streamsCache].
class _CachedStreams {
  const _CachedStreams(this.streams, this.fetchedAt);

  final List<Map<String, dynamic>> streams;
  final DateTime fetchedAt;
}
