import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'stream_security.dart';

/// Best-effort download size for one stream variant.
///
/// TMDB never exposes a file size, so this reports what can actually be known:
///
///  * **Progressive MP4/MKV** (non-HLS): exact. A one-byte ranged GET returns a
///    `Content-Range: bytes 0-0/<total>`, which is the real byte count the
///    server is willing to serve.
///  * **HLS**: the playlist itself does not carry file sizes, so the size is
///    derived from the variant's average bitrate and the runtime, or — when no
///    bitrate is published — by measuring a few segments and extrapolating from
///    their real byte counts. It is labelled with `~` in the UI so nobody reads
///    it as exact.
///
/// The segment path matters: extractors hand back **per-quality media
/// playlists** (`{label, url, height}` with no bitrate), and a media playlist
/// publishes no `BANDWIDTH` at all — measuring bitrate alone left every one of
/// those rows showing "—".
///
/// Results are cached per URL for the life of the process: the download sheet
/// opens repeatedly and each probe costs network round trips.
class StreamSizeProbe {
  StreamSizeProbe._();

  static final Map<String, ProbeResult> _cache = {};
  /// URLs that failed, with the time, so a transient network hiccup does not
  /// blank the row for the rest of the session — but a dead server is not
  /// re-probed on every keystroke either.
  static final Map<String, ProbeResult> _failed = {};
  static final Map<String, DateTime> _failedAt = {};
  static const Duration _failureCooldown = Duration(seconds: 60);
  static final Map<String, Future<ProbeResult>> _inFlight = {};
  static const Duration _timeout = Duration(seconds: 6);

  /// How many segments to measure when a playlist publishes no bitrate. Three
  /// (first / middle / last) catches the VOD hosts that ship an intro or an
  /// ad break at a different bitrate, without opening a request per segment.
  static const int _sampleCount = 3;

  /// Stream CDNs frequently reject requests without a browser User-Agent, which
  /// made a probe return nothing while the real download (which sets one)
  /// worked fine.
  static const String _defaultUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  /// Test seam: replaces the playlist fetch, so classification and estimation
  /// can be exercised without a socket. StreamSecurity (correctly) refuses
  /// loopback hosts, so a local test server cannot be used.
  @visibleForTesting
  static Future<String?> Function(String url, Map<String, String> headers)?
      debugFetchTextOverride;

  /// Test seam: replaces the progressive-file size probe. See above.
  @visibleForTesting
  static Future<int?> Function(String url, Map<String, String> headers)?
      debugContentLengthOverride;

  static Map<String, String> _withUserAgent(Map<String, String> headers) {
    final hasUa = headers.keys.any((k) => k.toLowerCase() == 'user-agent');
    return hasUa ? headers : {'User-Agent': _defaultUserAgent, ...headers};
  }

  static bool isHls(String url) {
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    return path.endsWith('.m3u8') || path.endsWith('.m3u');
  }

  /// Extensions that are unambiguously a whole media file.
  static const List<String> _mediaExtensions = [
    '.mp4',
    '.mkv',
    '.webm',
    '.mov',
    '.m4v',
    '.avi',
    '.flv',
    '.ts',
    '.mpeg',
    '.mpg',
  ];

  static bool _isDirectMediaPath(String url) {
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    return _mediaExtensions.any(path.endsWith);
  }

  /// Anything smaller than this, served from a URL with no media extension, is a
  /// manifest rather than a movie. Reporting a playlist's own 12 KB as the
  /// file size is worse than reporting nothing.
  static const int _manifestCeiling = 32 * 1024;

  /// Bytes to read when classifying a URL whose extension says nothing.
  static const int _peekBytes = 4096;

  /// Size in bytes, or null when it cannot be determined.
  ///
  /// [height] picks the matching variant when [url] is a master playlist, so a
  /// quality row asking about 1080p is measured at 1080p rather than at
  /// whatever variant happens to be listed first.
  static Future<int?> probe(
    String url, {
    Map<String, String> headers = const {},
    int? averageBitrate,
    int? runtimeSeconds,
    int? height,
  }) async =>
      (await probeSize(
        url,
        headers: headers,
        averageBitrate: averageBitrate,
        runtimeSeconds: runtimeSeconds,
        height: height,
      ))
          .bytes;

  /// Size in bytes plus whether it is an estimate, so the UI can label it.
  ///
  /// Use this rather than [probe] wherever the result is displayed: a row that
  /// shows "~155 MB" for a playlist estimate must not drop the "~" just because
  /// the stream URL happened to have no .m3u8 on it.
  static Future<ProbeResult> probeSize(
    String url, {
    Map<String, String> headers = const {},
    int? averageBitrate,
    int? runtimeSeconds,
    int? height,
  }) {
    final key = keyFor(url, headers);
    final cached = _cache[key];
    if (cached != null) return Future.value(cached);
    final failed = _failed[key];
    if (failed != null &&
        DateTime.now().difference(_failedAt[key] ?? DateTime(0)) <
            _failureCooldown) {
      return Future.value(failed);
    }
    return _inFlight[key] ??= _probeSize(
      url,
      headers,
      averageBitrate,
      runtimeSeconds,
      height,
    ).whenComplete(() {
      // Must be a void body: `() => _inFlight.remove(key)` returns the in-flight
      // future itself, and whenComplete awaits futures its callback returns —
      // so every probe waited on itself forever and no size ever appeared.
      _inFlight.remove(key);
    });
  }

  static Future<ProbeResult> _probeSize(
    String url,
    Map<String, String> headers,
    int? averageBitrate,
    int? runtimeSeconds,
    int? height,
  ) async {
    if (url.isEmpty || !StreamSecurity.isSafeNetworkUrl(url)) {
      return (bytes: null, estimated: false);
    }

    int? bytes;
    var estimated = true;

    if (isHls(url)) {
      bytes = await _estimateHls(
        url,
        headers,
        averageBitrate,
        runtimeSeconds,
        height: height,
      );
    } else if (_isDirectMediaPath(url)) {
      estimated = false;
      bytes = await _exactContentLength(url, headers);
    } else {
      // The extension says nothing. VixSrc serves its master playlist at
      // "/playlist/<id>?token=…&expires=…" with no .m3u8 anywhere, so deciding
      // by extension sent it down the progressive path and reported the
      // playlist's own few kilobytes as the size of the movie.
      final kind = await _classify(url, headers);
      switch (kind) {
        case _Kind.hls:
          final playlist = await _fetchText(url, headers);
          bytes = await _estimateHls(
            url,
            headers,
            averageBitrate,
            runtimeSeconds,
            height: height,
            playlistOverride: playlist,
          );
        case _Kind.dash:
          estimated = false;
          final manifest = await _fetchText(url, headers);
          bytes = manifest == null ? null : _estimateDash(manifest, height);
        case _Kind.media:
          estimated = false;
          bytes = await _exactContentLength(url, headers);
          if (bytes != null && bytes < _manifestCeiling) bytes = null;
        case _Kind.unknown:
          // Never guess: a manifest's own byte count must not be presented as
          // the size of the video.
          bytes = null;
      }
    }

    final result = (bytes: (bytes != null && bytes > 0) ? bytes : null, estimated: estimated);
    if (result.bytes != null) {
      _cache[keyFor(url, headers)] = result;
      _failed.remove(keyFor(url, headers));
    } else {
      _failed[keyFor(url, headers)] = result;
      _failedAt[keyFor(url, headers)] = DateTime.now();
    }
    return result;
  }

  /// What a URL without a telling extension actually serves.
  static Future<_Kind> _classify(
    String url,
    Map<String, String> headers,
  ) async {
    final override = debugFetchTextOverride;
    if (override != null) {
      return _classifyText((await override(url, headers)) ?? '');
    }
    if (!StreamSecurity.isSafeNetworkUrl(url)) return _Kind.unknown;
    final client = http.Client();
    try {
      final request = http.Request('GET', Uri.parse(url))
        ..headers.addAll(_withUserAgent(headers))
        ..followRedirects = true
        ..headers['Range'] = 'bytes=0-${_peekBytes - 1}';
      final response = await client.send(request).timeout(_timeout);
      final bytes = <int>[];
      final done = Completer<void>();
      late final StreamSubscription<List<int>> subscription;
      subscription = response.stream.listen(
        (chunk) {
          bytes.addAll(chunk);
          if (bytes.length >= _peekBytes && !done.isCompleted) {
            subscription.cancel();
            done.complete();
          }
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
        onError: (_) {
          if (!done.isCompleted) done.complete();
        },
        cancelOnError: true,
      );
      await done.future.timeout(_timeout, onTimeout: () {});

      final text =
          utf8.decode(bytes.take(_peekBytes).toList(), allowMalformed: true)
              .trimLeft();
      return _classifyText(text);
    } catch (_) {
      return _Kind.unknown;
    } finally {
      client.close();
    }
  }

  static String keyFor(String url, Map<String, String> headers) =>
      '$url|${headers.length}';

  /// Exact size for a progressive file, via a 1-byte ranged request.
  static Future<int?> _exactContentLength(
    String url,
    Map<String, String> headers,
  ) async {
    final override = debugContentLengthOverride;
    if (override != null) return override(url, headers);
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
  /// HLS playlists carry no byte counts, so this uses the two things that ARE
  /// published — the variant's average bitrate and the runtime (the sum of the
  /// media playlist's EXTINF entries) — and falls back to measuring actual
  /// segment byte counts when no bitrate is published.
  static Future<int?> _estimateHls(
    String url,
    Map<String, String> headers,
    int? averageBitrate,
    int? runtimeSeconds, {
    int? height,
    String? playlistOverride,
  }) async {
    var bitrate = averageBitrate;
    var seconds = runtimeSeconds;
    var mediaUrl = url;

    if (bitrate == null || seconds == null) {
      final playlist = playlistOverride ?? await _fetchText(url, headers);
      if (playlist != null) {
        if (_isMaster(playlist)) {
          final variant = _variantForHeight(playlist, url, height);
          if (variant != null) {
            bitrate ??= variant.bandwidth;
            mediaUrl = variant.uri;
          }
        }
        if (seconds == null) {
          final mediaText = mediaUrl == url
              ? playlist
              : await _fetchText(mediaUrl, headers);
          if (mediaText != null) seconds = _durationOf(mediaText);
        }
      }
    }

    if (seconds == null || seconds <= 0) return null;
    // BANDWIDTH/AVERAGE-BANDWIDTH are bits per SECOND (RFC 8216), so this is
    // bits/s × seconds ÷ 8 — no thousand, or every size reads 1000× too big.
    if (bitrate != null && bitrate > 0) return (bitrate * seconds) ~/ 8;

    // No published bitrate — the normal case for the per-quality media
    // playlists extractors return. Measure real segments instead of giving up,
    // which is what left every one of those rows showing "—".
    return _estimateFromSegments(mediaUrl, headers, seconds);
  }

  /// Measures a few segments and scales their real byte counts to the runtime.
  static Future<int?> _estimateFromSegments(
    String mediaUrl,
    Map<String, String> headers,
    int seconds,
  ) async {
    final text = await _fetchText(mediaUrl, headers);
    if (text == null) return null;
    // Group by what a single request would actually fetch. fMP4 playlists can
    // list the same file for every segment, and byte-range playlists share one
    // file across slices — counting those as separate samples would multiply
    // the same bytes by the number of times they appear.
    final byKey = <String, ({String uri, double seconds, int? start, int? end})>{};
    for (final segment in _segmentsOf(text, mediaUrl)) {
      final key = segment.start == null
          ? segment.uri
          : '${segment.uri}#${segment.start}-${segment.end}';
      final existing = byKey[key];
      byKey[key] = (
        uri: segment.uri,
        seconds: (existing?.seconds ?? 0) + segment.seconds,
        start: segment.start,
        end: segment.end,
      );
    }
    final segments = byKey.values.toList();
    if (segments.isEmpty) return null;

    var sampledBytes = 0;
    var sampledSeconds = 0.0;
    for (final index in _sampleIndexes(segments.length)) {
      final segment = segments[index];
      final length = await _contentLength(
        segment.uri,
        headers,
        start: segment.start,
        end: segment.end,
      );
      if (length == null || length <= 0) continue;
      sampledBytes += length;
      sampledSeconds += segment.seconds;
    }
    if (sampledBytes <= 0 || sampledSeconds <= 0) return null;
    return ((sampledBytes / sampledSeconds) * seconds).round();
  }

  /// First, middle and last segment (fewer when the playlist is short).
  static List<int> _sampleIndexes(int count) {
    if (count <= _sampleCount) {
      return List<int>.generate(count, (i) => i);
    }
    return {0, count ~/ 2, count - 1}.toList()..sort();
  }

  /// Size from a DASH manifest: runtime × the representation's bandwidth.
  ///
  /// The extractor answers "dash" for `.mpd` sources, and those used to be
  /// measured like progressive files — which returned the manifest's own few
  /// kilobytes.
  static int? _estimateDash(String manifest, int? height) {
    final duration = RegExp(
      r'mediaPresentationDuration="PT(?:(\d+)H)?(?:(\d+)M)?(?:([\d.]+)S)?"',
    ).firstMatch(manifest);
    if (duration == null) return null;
    final hours = int.tryParse(duration.group(1) ?? '') ?? 0;
    final minutes = int.tryParse(duration.group(2) ?? '') ?? 0;
    final seconds = double.tryParse(duration.group(3) ?? '') ?? 0;
    final total = hours * 3600 + minutes * 60 + seconds.round();
    if (total <= 0) return null;

    final representations = RegExp(
      r'<Representation\b[^>]*>',
    ).allMatches(manifest).map((m) => m.group(0)!).toList();
    if (representations.isEmpty) return null;

    ({int bandwidth, int height})? best;
    for (final tag in representations) {
      final bandwidth =
          int.tryParse(
            RegExp(r'bandwidth="(\d+)"').firstMatch(tag)?.group(1) ?? '',
          ) ??
          0;
      if (bandwidth <= 0) continue;
      final resolution =
          RegExp(r'(?:^|\s)height="(\d+)"').firstMatch(tag)?.group(1);
      final entry = (bandwidth: bandwidth, height: int.tryParse(resolution ?? '') ?? 0);
      if (best == null || entry.bandwidth > best.bandwidth) best = entry;
    }
    // Prefer the ceiling the caller asked for when the manifest lists it.
    if (height != null && height > 0) {
      for (final tag in representations) {
        final entryHeight =
            int.tryParse(RegExp(r'(?:^|\s)height="(\d+)"').firstMatch(tag)?.group(1) ?? '') ?? 0;
        if (entryHeight != height) continue;
        final bandwidth =
            int.tryParse(RegExp(r'bandwidth="(\d+)"').firstMatch(tag)?.group(1) ?? '') ?? 0;
        if (bandwidth > 0) return (bandwidth * total) ~/ 8;
      }
    }
    final chosen = best;
    if (chosen == null) return null;
    return (chosen.bandwidth * total) ~/ 8;
  }

  static bool _isMaster(String playlist) =>
      playlist.contains('#EXT-X-STREAM-INF:');

  /// Byte count of one segment, for a whole file or a byte-range slice.
  ///
  /// A byte-range segment is requested with exactly its own range, so the
  /// response's `Content-Length` is that segment's size rather than the size of
  /// the file they all share.
  static Future<int?> _contentLength(
    String url,
    Map<String, String> headers, {
    int? start,
    int? end,
  }) async {
    final override = debugContentLengthOverride;
    if (override != null) return override(url, headers);
    if (url.isEmpty || !StreamSecurity.isSafeNetworkUrl(url)) return null;
    final client = http.Client();
    try {
      final request = http.Request('GET', Uri.parse(url))
        ..headers.addAll(_withUserAgent(headers))
        ..followRedirects = true
        ..headers['Range'] = start != null && end != null
            ? 'bytes=$start-$end'
            : 'bytes=0-0';
      final response = await client.send(request).timeout(_timeout);
      await response.stream.drain<void>().timeout(
        _timeout,
        onTimeout: () => null,
      );
      final range = response.headers['content-range'];
      if (start == null && range != null) {
        final total = int.tryParse(range.split('/').last.trim());
        if (total != null && total > 0) return total;
      }
      final length = response.contentLength;
      return (length != null && length > 0) ? length : null;
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  /// One master-playlist variant.
  static ({String uri, int bandwidth, int height})? _variantForHeight(
    String master,
    String playlistUrl,
    int? height,
  ) {
    final variants = _variantsOf(master, playlistUrl);
    if (variants.isEmpty) return null;
    if (height != null && height > 0) {
      final exact = variants.where((v) => v.height == height).toList();
      if (exact.isNotEmpty) return exact.first;
      final under = variants
          .where((v) => v.height > 0 && v.height <= height)
          .toList();
      if (under.isNotEmpty) {
        under.sort((a, b) => a.height.compareTo(b.height));
        return under.last;
      }
    }
    return variants.first;
  }

  /// Every `#EXT-X-STREAM-INF` variant, with URIs resolved against the master.
  ///
  /// Variant lines are almost always RELATIVE (`720p/index.m3u8`); accepting
  /// absolute ones only meant the runtime was never found and HLS sizes came
  /// back empty.
  static List<({String uri, int bandwidth, int height})> _variantsOf(
    String master,
    String playlistUrl,
  ) {
    final Uri? base = Uri.tryParse(playlistUrl);
    final variants =
        <({String uri, int bandwidth, int height})>[];
    String? pendingUri;
    var pendingBandwidth = 0;
    var pendingHeight = 0;

    void flush() {
      final raw = pendingUri;
      if (raw == null) return;
      final uri = Uri.tryParse(raw);
      if (uri == null) return;
      final resolved = uri.hasScheme
          ? raw
          : (base == null ? null : base.resolveUri(uri).toString());
      if (resolved == null) return;
      variants.add((
        uri: resolved,
        bandwidth: pendingBandwidth,
        height: pendingHeight,
      ));
    }

    for (final line in const LineSplitter().convert(master)) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      if (trimmed.startsWith('#EXT-X-STREAM-INF:')) {
        flush();
        pendingUri = null;
        // AVERAGE-BANDWIDTH is the honest figure for a size estimate;
        // BANDWIDTH is a peak and would overstate the file.
        pendingBandwidth =
            int.tryParse(_attribute(trimmed, 'AVERAGE-BANDWIDTH') ?? '') ??
                int.tryParse(_attribute(trimmed, 'BANDWIDTH') ?? '') ??
                0;
        pendingHeight = _heightOf(trimmed);
        continue;
      }
      if (trimmed.startsWith('#')) continue;
      pendingUri = trimmed;
      flush();
      pendingUri = null;
    }
    flush();
    return variants;
  }

  static String? _attribute(String line, String name) {
    final match = RegExp('$name=(\\d+)').firstMatch(line);
    return match?.group(1);
  }

  static int _heightOf(String line) {
    final match = RegExp(r'RESOLUTION=(\d+)x(\d+)').firstMatch(line);
    return int.tryParse(match?.group(2) ?? '') ?? 0;
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

  /// One media-playlist segment with its duration and resolved URI.
  static List<({String uri, double seconds, int? start, int? end})> _segmentsOf(
    String playlist,
    String playlistUrl,
  ) {
    final Uri? base = Uri.tryParse(playlistUrl);
    final segments =
        <({String uri, double seconds, int? start, int? end})>[];
    var pendingSeconds = 0.0;
    var pendingLength = 0;
    var nextOffset = 0;
    var sawByteRange = false;

    for (final raw in const LineSplitter().convert(playlist)) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#EXTINF:')) {
        final value = line.split(':').last.split(',').first.trim();
        pendingSeconds = double.tryParse(value) ?? 0;
        continue;
      }
      if (line.startsWith('#EXT-X-BYTERANGE:')) {
        sawByteRange = true;
        final parts = line.substring('#EXT-X-BYTERANGE:'.length).split('@');
        final length = int.tryParse(parts.first.trim());
        if (length == null) continue;
        pendingLength = length;
        if (parts.length > 1) {
          nextOffset = int.tryParse(parts[1].trim()) ?? nextOffset;
        }
        continue;
      }
      if (line.startsWith('#')) continue;

      final uri = Uri.tryParse(line);
      if (uri != null) {
        final resolved = uri.hasScheme
            ? line
            : (base == null ? null : base.resolveUri(uri).toString());
        if (resolved != null && pendingSeconds > 0) {
          segments.add((
            uri: resolved,
            seconds: pendingSeconds,
            // Only meaningful when the segments genuinely share one file.
            start: sawByteRange ? nextOffset : null,
            end: sawByteRange ? nextOffset + pendingLength - 1 : null,
          ));
        }
      }
      if (pendingLength > 0) nextOffset += pendingLength;
      pendingSeconds = 0;
      pendingLength = 0;
    }
    return segments;
  }

  static Future<String?> _fetchText(
    String url,
    Map<String, String> headers,
  ) async {
    final override = debugFetchTextOverride;
    if (override != null) return override(url, headers);
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
    _failedAt.clear();
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

/// Size of a stream, and whether that size is an estimate.
typedef ProbeResult = ({int? bytes, bool estimated});

/// What a URL with no telling extension actually serves.
enum _Kind { hls, dash, media, unknown }

_Kind _classifyText(String text) {
  if (text.startsWith('#EXTM3U')) return _Kind.hls;
  if (text.contains('<MPD')) return _Kind.dash;
  // A whole media file announces itself with an ISO-BMFF box ("ftyp") or a
  // Matroska / WebM EBML header.
  if (text.contains('ftyp') || text.contains('matroska')) return _Kind.media;
  return _Kind.unknown;
}

/// Decides what a fetched body actually is, from its first bytes.
///
/// This is the decision that stops a playlist's own byte count from being
/// presented as the size of the video — the bug that made VixSrc, whose playlist
/// URL carries no extension at all, report "12 KB" for a whole film.
@visibleForTesting
StreamSizeKind classifyStreamBody(String text) =>
    switch (_classifyText(text.trimLeft())) {
      _Kind.hls => StreamSizeKind.hls,
      _Kind.dash => StreamSizeKind.dash,
      _Kind.media => StreamSizeKind.media,
      _Kind.unknown => StreamSizeKind.unknown,
    };

/// What a stream URL turned out to serve.
enum StreamSizeKind { hls, dash, media, unknown }
