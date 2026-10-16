import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' show ClientException;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'download_storage_service.dart';
import 'stream_security.dart';

typedef DownloadProgress = void Function(double progress);
typedef DownloadBytesProgress =
    void Function(int downloadedBytes, int? totalBytes);

class MediaDownloadResult {
  const MediaDownloadResult({required this.localPath, required this.isHls});

  final String localPath;
  final bool isHls;
}

class _ContentRange {
  const _ContentRange(this.start, this.end, this.total);

  final int start;
  final int end;
  final int total;
}

/// Downloads resolved, non-DRM media into the application's private storage.
/// Supports retry with resume for both direct and HLS downloads.
class MediaDownloadService {
  MediaDownloadService({
    http.Client? client,
    this.maxDownloadBytes = defaultMaxDownloadBytes,
    this.maxHlsResources = defaultMaxHlsResources,
    this.maxHlsResourceBytes = defaultMaxHlsResourceBytes,
    this.maxPlaylistBytes = defaultMaxPlaylistBytes,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null;

  static const int defaultMaxDownloadBytes = 8 * 1024 * 1024 * 1024;
  static const int defaultMaxHlsResources = 20000;
  static const int defaultMaxHlsResourceBytes = 32 * 1024 * 1024;
  static const int defaultMaxPlaylistBytes = 2 * 1024 * 1024;

  final int maxDownloadBytes;
  final int maxHlsResources;
  final int maxHlsResourceBytes;
  final int maxPlaylistBytes;

  final http.Client _client;
  final bool _ownsClient;
  bool _cancelled = false;
  bool _paused = false;
  Completer<void>? _pauseCompleter;

  static const int _maxRetries = 10;
  static const Duration _initialRetryDelay = Duration(seconds: 2);
  static const Duration _maxRetryDelay = Duration(seconds: 60);

  void cancel() {
    _cancelled = true;
    _pauseCompleter?.complete();
    _pauseCompleter = null;
  }

  void pause() {
    _paused = true;
  }

  void resume() {
    _paused = false;
    _pauseCompleter?.complete();
    _pauseCompleter = null;
  }

  bool get isPaused => _paused;

  Future<void> _waitForResume() async {
    if (!_paused) return;
    _pauseCompleter = Completer<void>();
    await _pauseCompleter!.future;
  }

  Future<MediaDownloadResult> download({
    required String url,
    Map<String, String> headers = const {},
    String? downloadId,
    bool? hls,
    int? maxVariantHeightPixels,
    DownloadProgress? onProgress,
    DownloadBytesProgress? onBytesProgress,
  }) async {
    // Lives in app-specific external storage (see DownloadStorageService.root)
    // so the space we report matches Android's Settings → App storage, and
    // deleting the files frees it there the same moment it frees it here.
    final root = await DownloadStorageService.root();
    final id = _safeName(
      downloadId ?? DateTime.now().microsecondsSinceEpoch.toString(),
    );
    final partial = Directory(p.join(root.path, '.$id.partial'));
    final completed = Directory(p.join(root.path, id));

    // If a completed directory exists, return it immediately (resume after crash).
    if (await completed.exists()) {
      final existing = await _findExistingOutput(completed);
      if (existing != null) {
        onProgress?.call(1);
        return MediaDownloadResult(localPath: existing, isHls: hls ?? false);
      }
    }

    // Don't delete partial on start — we want to resume from it.
    if (!await partial.exists()) {
      await partial.create(recursive: true);
    }
    onProgress?.call(0);
    try {
      final uri = StreamSecurity.safeNetworkUri(url);
      if (uri == null) throw const FormatException('Unsafe media URL');
      headers = StreamSecurity.sanitizeHeaders(headers);
      final isHls =
          hls ??
          uri.path.toLowerCase().endsWith('.m3u8') ||
              uri.path.toLowerCase().endsWith('.m3u');
      late final String outputName;
      if (isHls) {
        outputName = await _downloadHls(
          uri,
          partial,
          headers,
          onProgress,
          onBytesProgress,
          maxVariantHeightPixels: maxVariantHeightPixels,
        );
      } else {
        outputName = await _downloadDirect(
          uri,
          partial,
          headers,
          onProgress,
          onBytesProgress,
        );
      }

      await File(
        p.join(partial.path, '.complete'),
      ).writeAsString('ok', flush: true);
      await _deleteIfPresent(completed);
      await partial.rename(completed.path);
      onProgress?.call(1);
      return MediaDownloadResult(
        localPath: p.join(completed.path, outputName),
        isHls: isHls,
      );
    } catch (_) {
      // Keep partial directory for resume — only delete if explicitly cancelled.
      if (_cancelled) {
        await _deleteIfPresent(partial);
      }
      rethrow;
    }
  }

  Future<String> _downloadDirect(
    Uri uri,
    Directory directory,
    Map<String, String> headers,
    DownloadProgress? onProgress,
    DownloadBytesProgress? onBytesProgress,
  ) async {
    final extension = p.extension(uri.path);
    final name = 'video${extension.isEmpty ? '.mp4' : extension}';
    final file = File(p.join(directory.path, name));
    var received = 0;

    // Check if we have partial data to resume from.
    if (await file.exists()) {
      received = await file.length();
    }
    _checkTotalBytes(received);

    await _retryWithResume(
      description: 'direct download ${uri.path}',
      onProgress: onProgress,
      totalGetter: () => _contentLength(uri, headers),
      execute: (total) async {
        if (total != null && total > 0 && received == total) return;
        if (total != null) _checkTotalBytes(total);
        if (total != null && total > 0 && received > total) {
          received = 0;
          await file.writeAsBytes(const []);
        }
        final requestHeaders = Map<String, String>.from(headers);
        if (received > 0) {
          requestHeaders['Range'] = 'bytes=$received-';
        }
        final request = http.Request('GET', uri)
          ..headers.addAll(requestHeaders);
        final response = await _sendSafely(request);
        final requestedOffset = received;
        int? expectedTotal;
        int? expectedResponseBytes;

        if (received > 0 && response.statusCode == 206) {
          final range = _parseContentRange(response.headers);
          if (range == null || range.start != requestedOffset) {
            throw ClientException(
              'Server returned the wrong byte range for resume',
            );
          }
          expectedTotal = range.total;
          expectedResponseBytes = range.end - range.start + 1;
          _checkTotalBytes(expectedTotal);
        } else if (received > 0 && response.statusCode == 200) {
          // Server doesn't support range — restart from beginning.
          received = 0;
          expectedTotal = response.contentLength;
          expectedResponseBytes = response.contentLength;
        } else {
          if (response.statusCode != 200) {
            throw HttpException(
              'HTTP ${response.statusCode} while downloading media',
            );
          }
          expectedTotal = response.contentLength ?? total;
          expectedResponseBytes = response.contentLength;
        }

        final sink = file.openWrite(
          mode: received > 0 ? FileMode.append : FileMode.write,
        );
        var responseBytes = 0;
        try {
          await for (final bytes in response.stream) {
            if (_cancelled) throw StateError('Download cancelled');
            await _waitForResume();
            sink.add(bytes);
            received += bytes.length;
            _checkTotalBytes(received);
            responseBytes += bytes.length;
            if (expectedTotal != null && expectedTotal > 0) {
              onProgress?.call((received / expectedTotal).clamp(0, 1));
            }
            onBytesProgress?.call(received, expectedTotal);
          }
          await sink.flush();
          if (expectedResponseBytes != null &&
              responseBytes != expectedResponseBytes) {
            throw ClientException(
              'Download response ended early '
              '($responseBytes of $expectedResponseBytes bytes)',
            );
          }
          if (expectedTotal != null &&
              expectedTotal > 0 &&
              received != expectedTotal) {
            throw ClientException(
              'Download ended early ($received of $expectedTotal bytes)',
            );
          }
        } finally {
          await sink.close();
        }
      },
      cleanup: () async {
        if (_cancelled) {
          await _deleteIfPresent(File(p.join(directory.path, name)).parent);
        }
      },
    );
    return name;
  }

  Future<String> _downloadHls(
    Uri initialUri,
    Directory directory,
    Map<String, String> headers,
    DownloadProgress? onProgress,
    DownloadBytesProgress? onBytesProgress, {
    int? maxVariantHeightPixels,
  }) async {
    var playlistUri = initialUri;
    var playlist = await _getText(playlistUri, headers);
    _validateEncryption(playlist);

    // Every referenced URI maps to a local filename. Playlist texts (the
    // selected video variant plus any EXT-X-MEDIA audio/subtitle playlists)
    // are rewritten and re-saved from their fetched text; every other resource
    // (segments, keys, maps) is downloaded as bytes.
    final names = <Uri, String>{};
    var resourceIndex = 0;
    final byteResources = <Uri>{};
    String localFileName(Uri uri) {
      _requireSafeUri(uri);
      return names.putIfAbsent(uri, () {
        final extension = p.extension(uri.path);
        return 'resource_${resourceIndex++}${extension.isEmpty ? '.bin' : extension}';
      });
    }

    final sourceFile = File(p.join(directory.path, '.playlist_source'));
    final source = playlistUri.replace(query: '', fragment: '').toString();
    if (await sourceFile.exists() &&
        await sourceFile.readAsString() != source) {
      await for (final entity in directory.list()) {
        if (entity is File &&
            (p.basename(entity.path).startsWith('resource_') ||
                p.basename(entity.path).startsWith('playlist'))) {
          await entity.delete();
        }
      }
    }
    await sourceFile.writeAsString(source, flush: true);

    // filename -> rewritten playlist text to write at the end.
    final rewrittenPlaylists = <String, String>{};

    if (_isMaster(playlist)) {
      final variants = _parseVariants(playlist, playlistUri);
      if (variants.isEmpty) {
        throw const FormatException('HLS master has no variants');
      }
      final chosen = _chooseVariant(
        variants,
        maxVariantHeightPixels: maxVariantHeightPixels,
      );
      // Audio + subtitle renditions declared via EXT-X-MEDIA. Without these a
      // downloaded video-only variant would play back with no sound, and the
      // subtitles would be missing entirely.
      final mediaGroups = _parseMediaGroups(playlist, playlistUri);
      final audioGroup = _audioGroupId(playlist);

      // Fetch + rewrite every media playlist (chosen variant, audio, subtitles).
      // chosen.uri is often relative (e.g. sd/80/index-s480p…m3u8) so resolve
      // against the master playlist base, otherwise _requireSafeUri sees a
      // host-less Uri and throws "Unsafe media resource URL: sd/…".
      final chosenUri = playlistUri.resolve(chosen.uri);
      final playlistUris = <Uri>[chosenUri, ...mediaGroups];
      final seenPlaylists = <Uri>{};
      for (final mediaUri in playlistUris) {
        if (!seenPlaylists.add(mediaUri)) continue;
        final mediaText = await _getText(mediaUri, headers);
        _validateEncryption(mediaText);
        if (_isMaster(mediaText)) {
          throw const FormatException(
            'Unexpected nested HLS master playlist',
          );
        }
        if (!mediaText.contains('#EXT-X-ENDLIST')) {
          throw const FormatException(
            'This HLS stream is not a complete video and cannot be downloaded yet',
          );
        }
        final hasMediaSegment = const LineSplitter()
            .convert(mediaText)
            .any(
              (line) =>
                  line.trim().isNotEmpty && !line.trim().startsWith('#'),
            );
        if (!hasMediaSegment) {
          throw const FormatException(
            'HLS playlist contains no media segments',
          );
        }
        final localName = localFileName(mediaUri);
        rewrittenPlaylists[localName] =
            _rewriteMediaPlaylist(mediaText, mediaUri, localFileName, byteResources);
      }

      // Build the local master: only the chosen video variant plus the
      // audio/subtitle renditions we downloaded, all pointing at local files.
      final masterLines = <String>[];
      for (final line in const LineSplitter().convert(playlist)) {
        final trimmed = line.trim();
        if (!trimmed.startsWith('#')) continue;
        if (trimmed.startsWith('#EXT-X-STREAM-INF:')) {
          continue; // re-emitted once, for the chosen variant
        }
        if (trimmed.startsWith('#EXT-X-MEDIA:')) {
          final uri = _attribute(trimmed, 'URI');
          if (uri == null || !seenPlaylists.contains(playlistUri.resolve(_unquote(uri)))) {
            continue;
          }
          masterLines.add(_rewriteAttributeUri(trimmed, playlistUri, localFileName));
          continue;
        }
        masterLines.add(line);
      }
      masterLines.add(
        '#EXT-X-STREAM-INF:BANDWIDTH=${chosen.bandwidth},'
        'RESOLUTION=${chosen.width}x${chosen.height}'
        '${audioGroup == null || audioGroup.isEmpty ? '' : ',AUDIO="$audioGroup"'}',
      );
      masterLines.add(
        localFileName(chosenUri),
      );
      rewrittenPlaylists['playlist.m3u8'] = '${masterLines.join('\n')}\n';
    } else {
      // Single media playlist (muxed audio, no master).
      if (!playlist.contains('#EXT-X-ENDLIST')) {
        throw const FormatException(
          'This HLS stream is not a complete video and cannot be downloaded yet',
        );
      }
      final hasMediaSegment = const LineSplitter()
          .convert(playlist)
          .any(
            (line) =>
                line.trim().isNotEmpty && !line.trim().startsWith('#'),
          );
      if (!hasMediaSegment) {
        throw const FormatException('HLS playlist contains no media segments');
      }
      rewrittenPlaylists['playlist.m3u8'] =
          _rewriteMediaPlaylist(playlist, playlistUri, localFileName, byteResources);
    }

    if (byteResources.length > maxHlsResources) {
      throw StateError('HLS resource limit exceeded');
    }

    var done = 0;
    var downloadedBytes = 0;
    final resourceCount = byteResources.length;
    for (final uri in byteResources) {
      if (_cancelled) throw StateError('Download cancelled');
      await _waitForResume();
      final file = File(p.join(directory.path, names[uri]));
      final marker = File('${file.path}.complete');

      // Skip already-downloaded segments.
      if (await file.exists() && await file.length() > 0) {
        final expectedLength = await _contentLength(uri, headers);
        final existingLength = await file.length();
        if (await marker.exists() ||
            (expectedLength != null && existingLength == expectedLength)) {
          downloadedBytes += existingLength;
          _checkTotalBytes(downloadedBytes);
          onBytesProgress?.call(downloadedBytes, null);
          done++;
          onProgress?.call(resourceCount == 0 ? 1 : done / resourceCount);
          continue;
        }
        await file.delete();
        if (await marker.exists()) await marker.delete();
      }

      var currentResourceBytes = 0;
      await _retryWithResume(
        description: 'HLS resource ${names[uri]}',
        onProgress: null,
        execute: (_) async {
          currentResourceBytes = 0;
          await _downloadResource(uri, file, headers, (bytes) {
            currentResourceBytes += bytes;
            _checkTotalBytes(downloadedBytes + currentResourceBytes);
            onBytesProgress?.call(downloadedBytes + currentResourceBytes, null);
          });
        },
      );
      await marker.writeAsString('ok', flush: true);
      downloadedBytes += currentResourceBytes;
      done++;
      onProgress?.call(resourceCount == 0 ? 1 : done / resourceCount);
    }

    // Write the rewritten playlists last so a resume always has complete files.
    for (final entry in rewrittenPlaylists.entries) {
      await File(
        p.join(directory.path, entry.key),
      ).writeAsString(entry.value, flush: true);
    }

    return 'playlist.m3u8';
  }

  /// Re-writes a media playlist so every segment, key and map URI points at a
  /// local file, registering anything downloadable as a byte resource.
  String _rewriteMediaPlaylist(
    String playlist,
    Uri base,
    String Function(Uri) localFileName,
    Set<Uri> byteResources,
  ) {
    final rewritten = <String>[];
    for (final line in const LineSplitter().convert(playlist)) {
      final trimmed = line.trim();
      if (trimmed.startsWith('#EXT-X-KEY:')) {
        final method = _attribute(trimmed, 'METHOD')?.toUpperCase();
        if (method != null && method != 'NONE' && method != 'AES-128') {
          throw UnsupportedError('Unsupported encrypted HLS method: $method');
        }
        if (trimmed.toUpperCase().contains('KEYFORMAT=') &&
            !trimmed.toUpperCase().contains('KEYFORMAT="IDENTITY"')) {
          throw UnsupportedError('DRM HLS key formats are not supported');
        }
        rewritten.add(_rewriteUriAttributeToLocal(trimmed, base, localFileName, byteResources));
      } else if (trimmed.startsWith('#EXT-X-MAP:')) {
        rewritten.add(_rewriteUriAttributeToLocal(trimmed, base, localFileName, byteResources));
      } else if (trimmed.isNotEmpty && !trimmed.startsWith('#')) {
        final uri = base.resolve(trimmed);
        rewritten.add(localFileName(uri));
        byteResources.add(uri);
      } else {
        rewritten.add(line);
      }
    }
    return '${rewritten.join('\n')}\n';
  }

  String _rewriteUriAttributeToLocal(
    String line,
    Uri base,
    String Function(Uri) localFileName,
    Set<Uri> byteResources,
  ) {
    final match = RegExp(
      r'URI=("([^"]+)"|([^,]+))',
      caseSensitive: false,
    ).firstMatch(line);
    if (match == null) return line;
    final source = match.group(2) ?? match.group(3)!;
    final uri = base.resolve(_unquote(source));
    byteResources.add(uri);
    final replacement = 'URI="${localFileName(uri)}"';
    return line.replaceRange(match.start, match.end, replacement);
  }

  List<({String uri, int width, int height, int bandwidth})> _parseVariants(
    String playlist,
    Uri base,
  ) {
    final variants = <({String uri, int width, int height, int bandwidth})>[];
    final lines = const LineSplitter().convert(playlist);
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index].trim();
      if (!line.startsWith('#EXT-X-STREAM-INF:')) continue;
      var next = index + 1;
      while (next < lines.length &&
          (lines[next].trim().isEmpty || lines[next].trim().startsWith('#'))) {
        next++;
      }
      if (next >= lines.length) continue;
      final resolution = _attribute(line, 'RESOLUTION')?.split('x');
      variants.add((
        uri: lines[next].trim(),
        width: resolution != null && resolution.length == 2
            ? int.tryParse(resolution[0]) ?? 0
            : 0,
        height: resolution != null && resolution.length == 2
            ? int.tryParse(resolution[1]) ?? 0
            : 0,
        bandwidth: int.tryParse(_attribute(line, 'BANDWIDTH') ?? '') ?? 0,
      ));
    }
    return variants;
  }

  ({String uri, int width, int height, int bandwidth}) _chooseVariant(
    List<({String uri, int width, int height, int bandwidth})> variants, {
    int? maxVariantHeightPixels,
  }) {
    final withResolution =
        variants.where((v) => v.height > 0).toList();
    final pool = withResolution.isNotEmpty ? withResolution : variants;
    if (maxVariantHeightPixels != null) {
      final fitting = pool
          .where((v) => v.height > 0 && v.height <= maxVariantHeightPixels)
          .toList();
      if (fitting.isNotEmpty) {
        // Highest variant that still fits under the requested ceiling.
        return fitting.reduce(
          (a, b) => a.height >= b.height ? a : b,
        );
      }
      // Nothing fits: lowest available is the best match for a ceiling.
      return pool.reduce((a, b) => a.height <= b.height ? a : b);
    }
    return pool.reduce((a, b) => a.height >= b.height ? a : b);
  }

  /// Extracts the EXT-X-MEDIA audio/subtitle playlist URIs.
  List<Uri> _parseMediaGroups(String playlist, Uri base) {
    final uris = <Uri>[];
    for (final line in const LineSplitter().convert(playlist)) {
      final trimmed = line.trim();
      if (!trimmed.startsWith('#EXT-X-MEDIA:')) continue;
      final type = _attribute(trimmed, 'TYPE')?.toLowerCase();
      final raw = _attribute(trimmed, 'URI');
      if (type != null &&
          type != 'audio' &&
          type != 'subtitles') {
        continue;
      }
      if (raw != null && raw.isNotEmpty) {
        final uri = base.resolve(_unquote(raw));
        if (!uris.contains(uri)) uris.add(uri);
      }
    }
    return uris;
  }

  String? _audioGroupId(String playlist) {
    for (final line in const LineSplitter().convert(playlist)) {
      final trimmed = line.trim();
      if (!trimmed.startsWith('#EXT-X-STREAM-INF:')) continue;
      final audio = _attribute(trimmed, 'AUDIO');
      if (audio != null && audio.isNotEmpty) return audio;
    }
    return null;
  }

  String _unquote(String value) {
    if (value.length >= 2 &&
        value.startsWith('"') &&
        value.endsWith('"')) {
      return value.substring(1, value.length - 1);
    }
    return value;
  }

  Future<void> _downloadResource(
    Uri uri,
    File file,
    Map<String, String> headers,
    void Function(int bytes)? onBytes,
  ) async {
    _requireSafeUri(uri);
    final request = http.Request('GET', uri)..headers.addAll(headers);
    final response = await _sendSafely(request);
    if (response.statusCode != 200) {
      throw HttpException(
        'HTTP ${response.statusCode} while downloading HLS resource',
      );
    }
    if (response.contentLength != null &&
        response.contentLength! > maxHlsResourceBytes) {
      throw StateError('HLS resource size limit exceeded');
    }
    final partial = File('${file.path}.part');
    if (await partial.exists()) await partial.delete();
    final sink = partial.openWrite();
    var received = 0;
    try {
      await for (final bytes in response.stream) {
        if (_cancelled) throw StateError('Download cancelled');
        sink.add(bytes);
        received += bytes.length;
        if (received > maxHlsResourceBytes) {
          throw StateError('HLS resource size limit exceeded');
        }
        onBytes?.call(bytes.length);
      }
      await sink.flush();
      if (received == 0) {
        throw ClientException('HLS resource was empty');
      }
      final expected = response.contentLength;
      if (expected != null && expected > 0 && received != expected) {
        throw ClientException(
          'HLS segment ended early ($received of $expected bytes)',
        );
      }
    } finally {
      await sink.close();
    }
    if (await file.exists()) await file.delete();
    await partial.rename(file.path);
  }

  /// Retries an operation with exponential backoff.
  Future<void> _retryWithResume({
    required String description,
    required Future<void> Function(int? total) execute,
    DownloadProgress? onProgress,
    Future<int?> Function()? totalGetter,
    Future<void> Function()? cleanup,
  }) async {
    var delay = _initialRetryDelay;
    for (var attempt = 0; attempt < _maxRetries; attempt++) {
      if (_cancelled) {
        await cleanup?.call();
        throw StateError('Download cancelled');
      }
      await _waitForResume();
      try {
        final total = totalGetter != null ? await totalGetter() : null;
        await execute(total);
        return;
      } catch (e) {
        final isRetryable =
            e is SocketException ||
            e is HttpException ||
            e is TimeoutException ||
            e is ClientException ||
            e.toString().contains('Software caused connection abort') ||
            e.toString().contains('Connection reset') ||
            e.toString().contains('Connection refused') ||
            e.toString().contains('Connection closed');

        if (!isRetryable) {
          await cleanup?.call();
          rethrow;
        }

        if (attempt == _maxRetries - 1) {
          await cleanup?.call();
          rethrow;
        }

        // Exponential backoff with jitter.
        final jitter = Duration(
          milliseconds:
              (delay.inMilliseconds *
                      0.5 *
                      (DateTime.now().millisecond % 100) /
                      100)
                  .round(),
        );
        final waitTime = delay + jitter;
        await Future.delayed(waitTime);
        delay = Duration(
          milliseconds: (delay.inMilliseconds * 2).clamp(
            0,
            _maxRetryDelay.inMilliseconds,
          ),
        );
      }
    }
    throw StateError(
      'Download failed after $_maxRetries retries: $description',
    );
  }

  Future<String?> _findExistingOutput(Directory dir) async {
    if (!await File(p.join(dir.path, '.complete')).exists()) return null;
    if (await dir.exists()) {
      await for (final entity in dir.list()) {
        if (entity is File) {
          final name = p.basename(entity.path);
          if (name == 'playlist.m3u8' || name.startsWith('video')) {
            return entity.path;
          }
        }
      }
    }
    return null;
  }

  Future<String> _getText(Uri uri, Map<String, String> headers) async {
    _requireSafeUri(uri);
    final request = http.Request('GET', uri)..headers.addAll(headers);
    final response = await _sendSafely(request);
    if (response.statusCode != 200) {
      throw HttpException(
        'HTTP ${response.statusCode} while downloading HLS playlist',
      );
    }
    if (response.contentLength != null &&
        response.contentLength! > maxPlaylistBytes) {
      throw StateError('HLS playlist size limit exceeded');
    }
    final bytes = <int>[];
    await for (final chunk in response.stream) {
      bytes.addAll(chunk);
      if (bytes.length > maxPlaylistBytes) {
        throw StateError('HLS playlist size limit exceeded');
      }
    }
    final body = utf8.decode(bytes);
    if (!body.trimLeft().startsWith('#EXTM3U')) {
      throw const FormatException('HLS endpoint returned an invalid playlist');
    }
    return body;
  }

  Future<int?> _contentLength(Uri uri, Map<String, String> headers) async {
    try {
      _requireSafeUri(uri);
      final request = http.Request('HEAD', uri)..headers.addAll(headers);
      final response = await _sendSafely(request);
      if (response.statusCode < 200 || response.statusCode >= 300) return null;
      final length = response.contentLength;
      return length != null && length > 0 ? length : null;
    } catch (_) {
      return null;
    }
  }

  void _checkTotalBytes(int bytes) {
    if (bytes > maxDownloadBytes) {
      throw StateError('Media download size limit exceeded');
    }
  }

  void _requireSafeUri(Uri uri) {
    if (!StreamSecurity.isSafeNetworkUrl(uri)) {
      // Log the actual URL so the Videasy episode can be diagnosed without laptop
      // ignore: avoid_print
      print('Blocked unsafe URL: $uri  host=${uri.host} scheme=${uri.scheme}');
      throw FormatException('Unsafe media resource URL: $uri');
    }
  }

  Future<http.StreamedResponse> _sendSafely(
    http.Request request, [
    int redirects = 0,
  ]) async {
    _requireSafeUri(request.url);
    request.followRedirects = false;
    final response = await _client.send(request);
    if (response.isRedirect) {
      if (redirects >= 5) throw StateError('Too many media redirects');
      final location = response.headers['location'];
      final redirected = StreamSecurity.safeNetworkUri(
        location,
        base: request.url,
      );
      if (redirected == null) {
        throw const FormatException('Unsafe media redirect');
      }
      await response.stream.drain<void>();
      final next = http.Request(request.method, redirected)
        ..headers.addAll(request.headers);
      return _sendSafely(next, redirects + 1);
    }
    return response;
  }

  _ContentRange? _parseContentRange(Map<String, String> headers) {
    final value = headers['content-range'];
    if (value == null) return null;
    final match = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$').firstMatch(value);
    if (match == null) return null;
    final start = int.tryParse(match.group(1)!);
    final end = int.tryParse(match.group(2)!);
    final total = int.tryParse(match.group(3)!);
    if (start == null || end == null || total == null || end < start) {
      return null;
    }
    return _ContentRange(start, end, total);
  }

  Future<void> discard(String downloadId) async {
    // Both roots: the partial may predate the move to external storage.
    final roots = <Directory>{
      await DownloadStorageService.root(),
      await DownloadStorageService.legacyRoot(),
    };
    for (final root in roots) {
      await _deleteIfPresent(
        Directory(p.join(root.path, '.${_safeName(downloadId)}.partial')),
      );
    }
  }

  bool _isMaster(String playlist) => playlist.contains('#EXT-X-STREAM-INF:');

  void _validateEncryption(String playlist) {
    for (final line in const LineSplitter().convert(playlist)) {
      final trimmed = line.trim();
      if (!trimmed.startsWith('#EXT-X-KEY:') &&
          !trimmed.startsWith('#EXT-X-SESSION-KEY:')) {
        continue;
      }
      final method = _attribute(trimmed, 'METHOD')?.toUpperCase();
      if (method != null && method != 'NONE' && method != 'AES-128') {
        throw UnsupportedError('Unsupported encrypted HLS method: $method');
      }
      final keyFormat = _attribute(trimmed, 'KEYFORMAT');
      if (keyFormat != null && keyFormat.toUpperCase() != 'IDENTITY') {
        throw UnsupportedError('DRM HLS key formats are not supported');
      }
    }
  }

  String _rewriteAttributeUri(
    String line,
    Uri base,
    String Function(Uri) localName,
  ) {
    final match = RegExp(
      r'URI=("([^"]+)"|([^,]+))',
      caseSensitive: false,
    ).firstMatch(line);
    if (match == null) return line;
    final source = match.group(2) ?? match.group(3)!;
    final replacement = 'URI="${localName(base.resolve(source))}"';
    return line.replaceRange(match.start, match.end, replacement);
  }

  String? _attribute(String line, String name) {
    final match = RegExp(
      '(?:^|,)$name=("([^"]*)"|[^,]*)',
      caseSensitive: false,
    ).firstMatch(line.substring(line.indexOf(':') + 1));
    final value = match?.group(1);
    return value?.startsWith('"') == true ? match?.group(2) : value;
  }

  String _safeName(String value) {
    final safe = value.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return safe.isEmpty ? 'download' : safe;
  }

  Future<void> _deleteIfPresent(FileSystemEntity entity) async {
    if (await entity.exists()) await entity.delete(recursive: true);
  }

  void dispose() {
    _cancelled = true;
    _pauseCompleter?.complete();
    _pauseCompleter = null;
    if (_ownsClient) _client.close();
  }
}
