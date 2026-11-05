import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

/// Bridges to the native Kotlin StreamExtractor via platform channel.
/// Uses OkHttp on Android for better Cloudflare/TLS handling.
class NativeStreamExtractor {
  static const _channel = MethodChannel('com.maxstream.app/extractor');

  static Future<double> getBrightness() async {
    return await _channel.invokeMethod<double>('getBrightness') ?? 0.5;
  }

  static Future<void> setBrightness(double value) async {
    await _channel.invokeMethod<void>('setBrightness', {
      'value': value.clamp(0.01, 1.0),
    });
  }

  static Map<String, dynamic> _normalizeStream(Map result) {
    final map = <String, dynamic>{};
    result.forEach((key, value) {
      if (key.toString() == 'headers' && value is Map) {
        map['headers'] = value.map(
          (header, headerValue) =>
              MapEntry(header.toString(), headerValue.toString()),
        );
      } else if (key.toString() == 'qualities' && value is List) {
        map['qualities'] = value.whereType<Map>().map((q) {
          final normalized = <String, dynamic>{};
          q.forEach((k, v) => normalized[k.toString()] = v);
          return normalized;
        }).toList();
      } else if (key.toString() == 'subtitles' && value is List) {
        map['subtitles'] = value.whereType<Map>().map((s) {
          final normalized = <String, dynamic>{};
          s.forEach((k, v) => normalized[k.toString()] = v);
          return normalized;
        }).toList();
      } else if (key.toString() == 'audioTracks' && value is List) {
        map['audioTracks'] = value.whereType<Map>().map((a) {
          final normalized = <String, dynamic>{};
          a.forEach((k, v) => normalized[k.toString()] = v);
          return normalized;
        }).toList();
      } else {
        map[key.toString()] = value;
      }
    });
    return map;
  }

  /// Resolve a TMDB ID to a playable stream URL using native Kotlin extractors.
  /// Returns stream metadata and request headers, or null on failure.
  static Future<Map<String, dynamic>?> resolveStream({
    required String tmdbId,
    required bool isMovie,
    int season = 1,
    int episode = 1,
    String title = '',
  }) async {
    try {
      debugPrint('NativeExtractor: Resolving TMDB $tmdbId (movie=$isMovie)');

      final result = await _channel.invokeMethod<Map>('resolveStream', {
        'tmdbId': tmdbId,
        'isMovie': isMovie,
        'season': season,
        'episode': episode,
        'title': title,
      });

      if (result == null) return null;

      final map = _normalizeStream(result);
      debugPrint('NativeExtractor: Successfully resolved ${map["source"]}');
      return map;
    } on PlatformException catch (e) {
      debugPrint('NativeExtractor: Platform error: ${e.message}');
      return null;
    } catch (e) {
      debugPrint('NativeExtractor: Error: $e');
      return null;
    }
  }

  /// Resolve every server, including ones that failed extraction/validation.
  /// Failed entries carry an empty `url` and `available: false` so the picker
  /// can still list them and offer a per-server re-fetch.
  /// When [fast] is true the native side uses shorter per-server budgets and
  /// master-only HLS validation so the picker paints in seconds; call again
  /// with fast=false afterwards to correct any false positives in the
  /// background.
  static Future<List<Map<String, dynamic>>> resolveStreams({
    required String tmdbId,
    required bool isMovie,
    int season = 1,
    int episode = 1,
    String title = '',
    bool fast = false,
  }) async {
    try {
      final result = await _channel.invokeMethod<List>('resolveStreams', {
        'tmdbId': tmdbId,
        'isMovie': isMovie,
        'season': season,
        'episode': episode,
        'title': title,
        'fast': fast,
      });
      return result?.whereType<Map>().map(_normalizeStream).toList() ??
          const [];
    } on PlatformException catch (e) {
      debugPrint('NativeExtractor: Server discovery failed: ${e.message}');
      return const [];
    } catch (e) {
      debugPrint('NativeExtractor: Server discovery error: $e');
      return const [];
    }
  }

  /// Re-resolve a single named server on demand. Returns its stream map when
  /// it now produces a playable URL, or null if it is still unavailable.
  static Future<Map<String, dynamic>?> resolveServer({
    required String serverName,
    required String tmdbId,
    required bool isMovie,
    int season = 1,
    int episode = 1,
    String title = '',
  }) async {
    try {
      debugPrint('NativeExtractor: Re-resolving server $serverName');
      final result = await _channel.invokeMethod<Map>('resolveServer', {
        'serverName': serverName,
        'tmdbId': tmdbId,
        'isMovie': isMovie,
        'season': season,
        'episode': episode,
        'title': title,
      });
      if (result == null) return null;
      return _normalizeStream(result);
    } on PlatformException catch (e) {
      debugPrint(
        'NativeExtractor: resolveServer $serverName failed: ${e.message}',
      );
      return null;
    } catch (e) {
      debugPrint('NativeExtractor: resolveServer error: $e');
      return null;
    }
  }
}
