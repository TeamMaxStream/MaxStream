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
    // Honour only the START of the Range header: the response always runs to
    // EOF. Taking a bounded [start, end] window made the sender advertise a
    // content-length that could disagree with what openRead actually produced,
    // and the transfer died mid-file ("starts then stops").
    final start = _parseRangeStart(
      request.headers.value(HttpHeaders.rangeHeader),
      file.size,
    );
    final end = file.size - 1;
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
      final stream = await session.openFile(file, start: start);
      // Backpressure: `add()` only queues into the socket's buffer, so a fast
      // disk outran the network and a whole multi-GB file piled up in memory —
      // the transfer then died partway. Flushing every chunk paces the writer to
      // the receiver, which is what makes big files survive the trip.
      await for (final chunk in stream) {
        request.response.add(chunk);
        await request.response.flush();
      }
      await request.response.flush();
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
    if (file.size > 0 && from >= file.size) return;

    // One request per file, written in order. Splitting a file into parallel
    // ranged requests and writing the results in *completion* order silently
    // interleaved the pieces, so the file arrived corrupt and the transfer
    // stalled. Parallelism now happens across files instead (see
    // ShareService.receive), which keeps the link busy without reordering.
    final client = HttpClient()..connectionTimeout = _connectTimeout;
    var received = 0;
    try {
      final uri = Uri.parse('http://$host:$port/s/$token/f/${file.index}');
      final request = await client.getUrl(uri).timeout(_connectTimeout);
      if (from > 0) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$from-');
      }
      final response = await request.close().timeout(const Duration(minutes: 5));
      if (response.statusCode != HttpStatus.partialContent &&
          response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'Transfer failed (${response.statusCode})',
          uri: uri,
        );
      }
      final expected = response.contentLength;
      await for (final chunk in response) {
        received += chunk.length;
        yield Uint8List.fromList(chunk);
        _updateProgress(file, received, done: false);
      }
      if (received != expected) {
        throw HttpException(
          'Transfer ended early ($received of $expected bytes)',
          uri: uri,
        );
      }
      _updateProgress(file, received, done: true);
    } finally {
      client.close(force: true);
    }
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

  /// Start offset of a `bytes=START-` / `bytes=START-END` header, or 0.
  static int _parseRangeStart(String? header, int size) {
    if (header == null || size == 0 || !header.startsWith('bytes=')) return 0;
    final first = header.substring(6).split('-').first.trim();
    final start = int.tryParse(first);
    if (start == null || start < 0 || start >= size) return 0;
    return start;
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
