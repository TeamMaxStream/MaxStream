import 'dart:async';
import 'dart:convert';

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

  static final Map<String, int> _cache = {};
  /// URLs that failed, with the time, so a transient network hiccup does not
  /// blank the row for the rest of the session — but a dead server is not
  /// re-probed on every keystroke either.
  static final Map<String, DateTime> _failed = {};
  static const Duration _failureCooldown = Duration(seconds: 60);
  static final Map<String, Future<int?>> _inFlight = {};
  static const Duration _timeout = Duration(seconds: 6);

  /// Stream CDNs frequently reject requests without a browser User-Agent, which
  /// made a probe return nothing while the real download (which sets one)
  /// worked fine.
  static const String _defaultUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  static Map<String, String> _withUserAgent(Map<String, String> headers) {
    final hasUa = headers.keys.any((k) => k.toLowerCase() == 'user-agent');
    return hasUa ? headers : {'User-Agent': _defaultUserAgent, ...headers};
  }

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
    final cached = _cache[key];
    if (cached != null) return Future.value(cached);
    final failedAt = _failed[key];
    if (failedAt != null &&
        DateTime.now().difference(failedAt) < _failureCooldown) {
      return Future.value(null);
    }
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
        ? await _estimateHls(url, headers, averageBitrate, runtimeSeconds)
        : await _exactContentLength(url, headers);
    if (value != null && value > 0) {
      _cache[keyFor(url, headers)] = value;
      _failed.remove(keyFor(url, headers));
    } else {
      _failed[keyFor(url, headers)] = DateTime.now();
    }
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
        ..headers.addAll(_withUserAgent(headers))
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

  /// Estimated size for an HLS variant.
  ///
  /// HLS playlists carry no byte counts, so this builds the estimate from the
  /// two things that ARE published: the variant's BANDWIDTH (from the master
  /// playlist, or from the resolver when it supplies one) and the real runtime
  /// (summed from the media playlist's EXTINF entries). Both requests are tiny
  /// text files and the results are cached per URL.
  static Future<int?> _estimateHls(
    String url,
    Map<String, String> headers,
    int? averageBitrate,
    int? runtimeSeconds,
  ) async {
    var bitrate = averageBitrate;
    var seconds = runtimeSeconds;

    if (bitrate == null || seconds == null) {
      final playlist = await _fetchText(url, headers);
      if (playlist != null) {
        final isMaster = _isMaster(playlist);
        // BANDWIDTH lives on the master; the runtime lives on the media
        // playlist, so a master URL costs one extra tiny request.
        bitrate ??= _bandwidthOf(playlist, isMaster: isMaster);
        final media =
            isMaster ? _firstVariantUrl(playlist, url) : playlist;
        if (media != null) {
          seconds ??= _durationOf(await _fetchText(media, headers) ?? media);
        }
      }
    }
    if (bitrate == null || bitrate <= 0 || seconds == null || seconds <= 0) {
      return null;
    }
    return (bitrate * 1000 * seconds) ~/ 8;
  }

  static bool _isMaster(String playlist) =>
      playlist.contains('#EXT-X-STREAM-INF:');

  static int? _bandwidthOf(String playlist, {required bool isMaster}) {
    if (!isMaster) return null;
    for (final line in const LineSplitter().convert(playlist)) {
      if (!line.startsWith('#EXT-X-STREAM-INF:')) continue;
      final match =
          RegExp(r'BANDWIDTH=(\d+)').firstMatch(line) ??
          RegExp(r'AVERAGE-BANDWIDTH=(\d+)').firstMatch(line);
      final value = int.tryParse(match?.group(1) ?? '');
      if (value != null && value > 0) return value;
    }
    return null;
  }

  /// Sum of EXTINF durations, in seconds.
  static int? _durationOf(String playlist) {
    var seconds = 0.0;
    var found = false;
    for (final line in const LineSplitter().convert(playlist)) {
      if (!line.startsWith('#EXTINF:')) continue;
      final value = line.split(':').last.split(',').first.trim();
      final parsed = double.tryParse(value);
      if (parsed == null || parsed <= 0) continue;
      seconds += parsed;
      found = true;
    }
    return found ? seconds.round() : null;
  }

  /// First variant URI of a master playlist, resolved against the playlist's own
  /// URL. Variant lines are almost always RELATIVE ("720p/index.m3u8"); only
  /// accepting absolute ones meant the runtime was never found and every HLS
  /// size came back empty.
  static String? _firstVariantUrl(String master, String playlistUrl) {
    final Uri? base = Uri.tryParse(playlistUrl);
    final lines = const LineSplitter().convert(master);
    var sawVariantTag = false;
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.startsWith('#EXT-X-STREAM-INF:')) {
        sawVariantTag = true;
        continue;
      }
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      if (!sawVariantTag) continue;
      final uri = Uri.tryParse(trimmed);
      if (uri == null) continue;
      if (uri.hasScheme) return trimmed;
      if (base == null) return null;
      return base.resolveUri(uri).toString();
    }
    return null;
  }

  static Future<String?> _fetchText(
    String url,
    Map<String, String> headers,
  ) async {
    if (url.isEmpty || !StreamSecurity.isSafeNetworkUrl(url)) return null;
    final client = http.Client();
    try {
      final response = await client
          .get(Uri.parse(url), headers: _withUserAgent(headers))
          .timeout(_timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) return null;
      return response.body;
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  static void clear() {
    _cache.clear();
    _failed.clear();
  }

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
