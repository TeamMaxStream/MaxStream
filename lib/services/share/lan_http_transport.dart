import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'share_models.dart';
import 'share_transport.dart';

/// Device-to-device sharing over the local network using plain HTTP.
///
/// Chosen as the default transport because `dart:io` does it natively: no
/// native module, no Wi-Fi Direct permissions, and `Range` support gives free
/// resume. Two devices simply need to share a network (the same Wi-Fi, or one
/// of them acting as a hotspot).
///
/// Wire format (paths shown here without angle brackets):
///   GET /s/TOKEN/manifest.json  -> the bundle header
///   GET /s/TOKEN/f/INDEX        -> raw file bytes (honours Range)
class LanHttpTransport implements ShareTransport {
  LanHttpTransport();

  HttpServer? _server;
  String? _token;
  String? _address;

  final _senderEvents = StreamController<ShareSenderEvent>.broadcast();
  final _progress =
      StreamController<Map<int, ShareFileProgress>>.broadcast();
  final Map<int, ShareFileProgress> _lastProgress = {};

  /// Concurrent chunk requests per file. More than one stream keeps both the
  /// Wi-Fi link and the storage pipeline busy; 4 is a good ceiling on phones.
  static const int _parallelChunks = 4;
  static const int _chunkSize = 4 * 1024 * 1024;
  static const Duration _connectTimeout = Duration(seconds: 8);
  static const Duration _idleTimeout = Duration(minutes: 30);

  @override
  String get id => 'lan';

  @override
  String get label => 'Wi-Fi (local network)';

  @override
  bool get isSupported => true;

  @override
  String? get unavailableReason => null;

  @override
  Stream<ShareSenderEvent> get senderEvents => _senderEvents.stream;

  @override
  Stream<Map<int, ShareFileProgress>> get progress => _progress.stream;

  // ── Sender ────────────────────────────────────────────────────────────────

  @override
  Future<ShareDescriptor> publish(ShareSession session) async {
    await unpublish();
    _token = _randomToken();
    // Port 0 lets the OS pick a free one; anything in the ephemeral range is
    // fine and avoids clashing with the download service.
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    server.idleTimeout = _idleTimeout;
    _server = server;
    unawaited(_serve(server, _token!, session));
    _emit('waiting', 'Waiting for the other device…');

    final host = await _localAddress() ?? '127.0.0.1';
    _address = '$host:${server.port}';
    final code = 'maxstream:lan:$host:${server.port}:$_token';
    return ShareDescriptor(
      transportId: id,
      code: code,
      label: _address!,
      data: {'host': host, 'port': '${server.port}', 'token': _token!},
    );
  }

  Future<void> _serve(HttpServer server, String token, ShareSession session) async {
    await for (final request in server) {
      final segments = request.uri.pathSegments;
      // /s/<token>/manifest.json | /s/<token>/f/<index>
      if (segments.length < 3 || segments[0] != 's' || segments[1] != token) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        continue;
      }
      try {
        if (segments[2] == 'manifest.json') {
          final body = session.manifest.encode();
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.json
            ..headers.set('X-MaxStream-Sender', session.manifest.senderName);
          request.response.add(utf8.encode(body));
          await request.response.close();
          _emit('progress', 'Manifest requested');
          continue;
        }
        if (segments[2] == 'f' && segments.length >= 4) {
          await _serveFile(request, session, int.tryParse(segments[3]));
          continue;
        }
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      } catch (error) {
        _emit('error', '$error');
        try {
          request.response.statusCode = HttpStatus.internalServerError;
          await request.response.close();
        } catch (_) {}
      }
    }
  }

  Future<void> _serveFile(
    HttpRequest request,
    ShareSession session,
    int? index,
  ) async {
    final files = session.manifest.items.expand((i) => i.files).toList();
    if (index == null || index < 0 || index >= files.length) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    final file = files[index];
    final range = _parseRange(request.headers.value(HttpHeaders.rangeHeader), file.size);
    final start = range?.$1 ?? 0;
    final end = range?.$2 ?? (file.size - 1);
    final length = file.size == 0 ? 0 : end - start + 1;

    request.response
      ..statusCode = length > 0 ? HttpStatus.partialContent : HttpStatus.ok
      ..headers.contentType = ContentType('application', 'octet-stream')
      ..headers.contentLength = length;
    if (length > 0) {
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/${file.size}',
      );
    }

    _emit('progress', 'Sending ${file.name}');
    try {
      final stream = await session.openFile(file, start: start, end: end);
      // A receiver that walks away mid-file makes the next write throw; the
      // catch below turns that into a transport event instead of a crash.
      await for (final chunk in stream) {
        request.response.add(chunk);
      }
    } on Object catch (error) {
      _emit('error', 'Failed to send ${file.name}: $error');
    }
    await request.response.close();
    _updateProgress(file, file.size, done: true);
    _emit('progress', 'Sent ${file.name}');
  }

  @override
  Future<void> unpublish() async {
    final server = _server;
    _server = null;
    _token = null;
    _address = null;
    if (server != null) {
      try {
        await server.close(force: true);
      } catch (_) {}
    }
    _emit('disconnected', 'Stopped sharing');
  }

  void _emit(String kind, String? message) {
    if (_senderEvents.isClosed) return;
    _senderEvents.add(ShareSenderEvent(kind: kind, message: message));
  }

  // ── Receiver ──────────────────────────────────────────────────────────────

  @override
  Future<ShareManifest> fetchManifest(ShareDescriptor descriptor) async {
    final host = descriptor.data['host'];
    final port = descriptor.data['port'];
    final token = descriptor.data['token'];
    if (host == null || port == null || token == null) {
      throw const FormatException('Incomplete share code');
    }
    final client = HttpClient()..connectionTimeout = _connectTimeout;
    try {
      final request = await client
          .getUrl(Uri.parse('http://$host:$port/s/$token/manifest.json'))
          .timeout(const Duration(seconds: 15));
      final response = await request.close().timeout(const Duration(seconds: 20));
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'Sender returned ${response.statusCode}',
          uri: request.uri,
        );
      }
      final body = await response.transform(utf8.decoder).join();
      return ShareManifest.decode(body);
    } finally {
      client.close(force: true);
    }
  }

  @override
  Stream<Uint8List> fetchFile(
    ShareDescriptor descriptor,
    ShareFileEntry file, {
    int? start,
    int? end,
  }) async* {
    final host = descriptor.data['host'];
    final port = descriptor.data['port'];
    final token = descriptor.data['token'];
    if (host == null || port == null || token == null) {
      throw const FormatException('Incomplete share code');
    }

    final from = start ?? 0;
    final to = end ?? (file.size == 0 ? 0 : file.size - 1);
    final total = file.size == 0 ? 0 : to - from + 1;
    if (total <= 0) return;

    final client = HttpClient()..connectionTimeout = _connectTimeout;
    var received = 0;
    try {
      final chunks = <(int, int)>[];
      for (var offset = from; offset <= to; offset += _chunkSize) {
        final chunkEnd = min(offset + _chunkSize - 1, to);
        chunks.add((offset, chunkEnd));
      }
      // Up to _parallelChunks requests in flight; results are emitted in
      // completion order, which is fine because the caller writes at offsets.
      final pending = chunks.toList();
      while (pending.isNotEmpty) {
        final batch = pending.take(_parallelChunks).toList();
        pending.removeRange(0, batch.length);
        final results = await Future.wait(batch.map((range) async {
          return _fetchChunk(client, host, port, token, file.index, range);
        }));
        for (final result in results) {
          yield result;
          received += result.length;
          _updateProgress(file, received, done: false);
        }
      }
      _updateProgress(file, received, done: true);
    } finally {
      client.close(force: true);
    }
  }

  Future<Uint8List> _fetchChunk(
    HttpClient client,
    String host,
    String port,
    String token,
    int index,
    (int, int) range,
  ) async {
    final uri = Uri.parse('http://$host:$port/s/$token/f/$index');
    final request = await client.getUrl(uri).timeout(_connectTimeout);
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=${range.$1}-${range.$2}');
    final response = await request.close().timeout(const Duration(minutes: 5));
    if (response.statusCode != HttpStatus.partialContent &&
        response.statusCode != HttpStatus.ok) {
      throw HttpException(
        'Transfer failed (${response.statusCode})',
        uri: uri,
      );
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  @override
  Future<void> closeReceiver() async {}

  void _updateProgress(ShareFileEntry file, int received, {required bool done}) {
    _lastProgress[file.index] = ShareFileProgress(
      received: received,
      total: file.size,
      done: done,
    );
    if (!_progress.isClosed) _progress.add(Map.of(_lastProgress));
  }

  void dispose() {
    unawaited(unpublish());
    unawaited(_senderEvents.close());
    unawaited(_progress.close());
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  static (int, int)? _parseRange(String? header, int size) {
    if (header == null || size == 0) return null;
    if (!header.startsWith('bytes=')) return null;
    final parts = header.substring(6).split('-');
    if (parts.length != 2) return null;
    final start = int.tryParse(parts[0].trim());
    var end = int.tryParse(parts[1].trim());
    if (start == null || start < 0 || start >= size) return null;
    end ??= size - 1;
    if (end >= size) end = size - 1;
    if (end < start) return null;
    return (start, end);
  }

  /// Picks the address other devices can actually reach: the first non-loopback
  /// IPv4 address, preferring Wi-Fi interfaces.
  static Future<String?> _localAddress() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      String? fallback;
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (address.isLoopback) continue;
          fallback ??= address.address;
          final name = interface.name.toLowerCase();
          if (name.startsWith('wlan') || name.startsWith('wifi')) {
            return address.address;
          }
          if (name.startsWith('ap') || name.contains('softap')) {
            return address.address;
          }
        }
      }
      return fallback;
    } catch (_) {
      return null;
    }
  }

  static String _randomToken() {
    const alphabet = 'abcdefghijkmnpqrstuvwxyz23456789';
    final random = Random.secure();
    return List.generate(8, (_) => alphabet[random.nextInt(alphabet.length)])
        .join();
  }
}
