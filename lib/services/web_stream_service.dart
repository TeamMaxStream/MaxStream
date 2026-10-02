import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'stream_security.dart';

/// Web stream resolution service.
/// Calls Cloudflare Worker API to extract actual .m3u8 URLs server-side.
class WebStreamService {
  static const String _tag = 'WebStreamService';
  static const String _workerUrl =
      'https://maxstream-api.maxstream123.workers.dev';

  /// All available servers. Ids are passed straight through as the API's
  /// `server=` parameter, so they must match a provider the API exposes.
  static const List<Map<String, String>> servers = [
    {
      'name': 'NetMirror',
      'id': 'netmirror',
      'movieUrl': 'https://net79.cc/watch-tmdb/{id}',
      'tvUrl': 'https://net79.cc/watch-tmdb/{id}',
    },
    {
      'name': 'VixSrc',
      'id': 'vixsrc',
      'movieUrl': 'https://vixsrc.to/api/movie/{id}?lang=en',
      'tvUrl': 'https://vixsrc.to/api/tv/{id}/{season}/{episode}?lang=en',
    },
    {
      'name': 'VidLink',
      'id': 'vidlink',
      'movieUrl': 'https://vidlink.pro/movie/{id}',
      'tvUrl': 'https://vidlink.pro/tv/{id}/{season}/{episode}',
    },
    {
      'name': 'Videasy',
      'id': 'videasy',
      'movieUrl': 'https://player.videasy.to/movie/{id}',
      'tvUrl': 'https://player.videasy.to/tv/{id}/{season}/{episode}',
    },
  ];

  /// Resolve a stream URL from a specific server.
  static Future<Map<String, dynamic>?> resolveFromServer({
    required String serverId,
    required String tmdbId,
    required bool isMovie,
    int season = 1,
    int episode = 1,
  }) async {
    debugPrint('$_tag: Resolving from $serverId for TMDB $tmdbId');

    try {
      final url =
          '$_workerUrl/v1/stream'
          '?tmdb=$tmdbId'
          '&type=${isMovie ? 'movie' : 'tv'}'
          '&season=$season'
          '&episode=$episode'
          '&server=$serverId';

      final response = await http
          .get(Uri.parse(url), headers: const {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 25));
      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        final streamUrl = data['url']?.toString() ?? '';
        if (data['ok'] != true || streamUrl.isEmpty) {
          debugPrint(
            '$_tag: API found no stream for $serverId: '
            '${data['error'] ?? 'empty url'}',
          );
          return null;
        }

        final headers = <String, String>{};
        (data['headers'] as Map?)?.forEach((key, value) {
          headers[key.toString()] = value.toString();
        });

        return StreamSecurity.sanitizeResolverResult({
          'url': streamUrl,
          'source': (data['label'] ?? data['provider'] ?? serverId).toString(),
          'type': _playerType(data['type']?.toString(), streamUrl),
          'headers': headers,
          'qualities': data['qualities'] is List ? data['qualities'] : null,
          'subtitles': data['subtitles'] is List ? data['subtitles'] : null,
        });
      }
      debugPrint('$_tag: API returned HTTP ${response.statusCode} for $serverId');
    } catch (e) {
      debugPrint('$_tag: API call failed: $e');
    }

    return null;
  }

  /// The API answers `hls`/`direct`/`dash`; the web player only knows
  /// `hls` (hls.js) and anything else (native <video src>).
  static String _playerType(String? raw, String url) {
    final type = (raw ?? '').toLowerCase();
    if (type == 'hls' || url.toLowerCase().contains('.m3u8')) return 'hls';
    if (type == 'dash') return 'dash';
    return 'direct';
  }

  /// Resolve a stream URL trying all servers in order.
  static Future<Map<String, dynamic>?> resolveStream({
    required String tmdbId,
    required bool isMovie,
    int season = 1,
    int episode = 1,
    String title = '',
  }) async {
    // Try each server in order
    for (final server in servers) {
      final result = await resolveFromServer(
        serverId: server['id']!,
        tmdbId: tmdbId,
        isMovie: isMovie,
        season: season,
        episode: episode,
      );
      if (result != null) {
        debugPrint('$_tag: Success with ${server['name']}');
        return result;
      }
    }

    debugPrint('$_tag: No direct streaming source was found');
    return null;
  }

  /// Get server list for UI picker.
  static List<Map<String, String>> getServerList() {
    return servers.map((s) => {'name': s['name']!, 'id': s['id']!}).toList();
  }
}
