import 'dart:async';

import 'package:http/http.dart' as http;

import 'stream_security.dart';

/// Best-effort download size for one stream variant.
///
/// TMDB never exposes a file size, so this reports what can actually be known:
///
///  * **Progressive MP4/MKV** (non-HLS): exact. A one-byte ranged GET returns a
///    `Content-Range: bytes 0-0/<total>`, which is the real byte count the
///    server is willing to serve.
///  * **HLS**: the playlist itself does not carry file sizes, so the estimate
///    comes from the variant's average bitrate and the runtime. It is labelled
///    with `~` in the UI so nobody reads it as exact.
///
/// Results are cached per URL for the life of the process: the download sheet
/// opens repeatedly and each probe costs a network round trip.
class StreamSizeProbe {
  StreamSizeProbe._();

  static final Map<String, int?> _cache = {};
  static final Map<String, Future<int?>> _inFlight = {};
  static const Duration _timeout = Duration(seconds: 6);

  static bool isHls(String url) {
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    return path.endsWith('.m3u8') || path.endsWith('.m3u');
  }

  /// Size in bytes, or null when it cannot be determined.
  static Future<int?> probe(
    String url, {
    Map<String, String> headers = const {},
    int? averageBitrate,
    int? runtimeSeconds,
  }) {
    final key = keyFor(url, headers);
    if (_cache.containsKey(key)) return Future.value(_cache[key]);
    return _inFlight[key] ??= _probe(url, headers, averageBitrate, runtimeSeconds)
        .whenComplete(() => _inFlight.remove(key));
  }

  static Future<int?> _probe(
    String url,
    Map<String, String> headers,
    int? averageBitrate,
    int? runtimeSeconds,
  ) async {
    if (url.isEmpty || !StreamSecurity.isSafeNetworkUrl(url)) return null;
    final int? value = isHls(url)
        ? await _estimateHls(averageBitrate, runtimeSeconds)
        : await _exactContentLength(url, headers);
    _cache[keyFor(url, headers)] = value;
    return value;
  }

  static String keyFor(String url, Map<String, String> headers) =>
      '$url|${headers.length}';

  /// Exact size for a progressive file, via a 1-byte ranged request.
  static Future<int?> _exactContentLength(
    String url,
    Map<String, String> headers,
  ) async {
    final client = http.Client();
    try {
      final request = http.Request('GET', Uri.parse(url))
        ..headers.addAll(headers)
        ..followRedirects = true
        ..headers['Range'] = 'bytes=0-0';
      final response = await client.send(request).timeout(_timeout);
      await response.stream.drain<void>().timeout(
            _timeout,
            onTimeout: () => null,
          );
      final range = response.headers['content-range'];
      if (range != null) {
        final total = int.tryParse(range.split('/').last.trim());
        if (total != null && total > 0) return total;
      }
      final length = response.contentLength;
      return (length != null && length > 1) ? length : null;
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  /// Bitrate × runtime for an HLS variant.
  static Future<int?> _estimateHls(
    int? averageBitrate,
    int? runtimeSeconds,
  ) async {
    final bitrate = averageBitrate;
    if (bitrate != null && bitrate > 0) {
      if (runtimeSeconds != null && runtimeSeconds > 0) {
        return (bitrate * 1000 * runtimeSeconds) ~/ 8;
      }
      // Fall back to the master playlist's EXT-X-STREAM-INF BANDWIDTH, or a
      // typical movie length when even that is missing.
      final seconds = runtimeSeconds ?? 2 * 60 * 60;
      return (bitrate * 1000 * seconds) ~/ 8;
    }
    return null;
  }

  static void clear() => _cache.clear();

  /// Human-readable, with `~` marking an estimate.
  static String format(int? bytes, {required bool estimated}) {
    if (bytes == null || bytes <= 0) return '';
    final prefix = estimated ? '~' : '';
    if (bytes < 1024 * 1024) return '$prefix${(bytes / 1024).toStringAsFixed(0)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '$prefix${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '$prefix${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}
