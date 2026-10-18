import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:nearby_connections/nearby_connections.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'share_models.dart';
import 'share_transport.dart';

/// Routerless transport built on Google's Nearby Connections (the same stack
/// behind Nearby Share), exposed through the same [ShareTransport] interface as
/// the LAN transport.
///
/// It needs no router, hotspot or shared network — the two devices pair over
/// Wi-Fi Direct / Wi-Fi Aware with Play services doing the work. The trade-off
/// versus LAN HTTP is that Nearby sends whole files (no byte ranges, so no
/// partial resume) and needs the Play services stack plus the nearby-device
/// permissions.
class NearbyTransport implements ShareTransport {
  NearbyTransport();

  /// Both sides must advertise/discover under the same service id.
  static const String serviceId = 'com.maxstream.app.share';

  static const String _nicknameKey = 'share_nearby_nickname';

  final Nearby _nearby = Nearby();

  ShareSession? _session;
  String? _token;
  String? _nickname;
  String? _connectedEndpoint;

  final _senderEvents = StreamController<ShareSenderEvent>.broadcast();
  final _progress =
      StreamController<Map<int, ShareFileProgress>>.broadcast();
  final Map<int, ShareFileProgress> _lastProgress = {};

  final Map<int, Completer<void>> _payloadWaiters = {};
  final Map<int, String> _incomingFiles = {};
  final Completer<String> _manifestReply = Completer<String>();
  final Completer<String> _peerHello = Completer<String>();

  @override
  String get id => 'nearby';

  @override
  String get label => 'Nearby (no Wi-Fi needed)';

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
    _session = session;
    final token = _randomToken();
    _token = token;
    final nickname = await _deviceNickname();

    final started = await _nearby.startAdvertising(
      nickname,
      Strategy.P2P_POINT_TO_POINT,
      serviceId: serviceId,
      onConnectionInitiated: (endpointId, info) async {
        // Only accept peers that present the share token; a random scanner
        // request must not be able to pull files.
        if (info.authenticationToken != token) {
          await _nearby.rejectConnection(endpointId);
          return;
        }
        await _nearby.acceptConnection(
          endpointId,
          onPayLoadRecieved: _onPayloadReceived,
          onPayloadTransferUpdate: _onTransferUpdate,
        );
      },
      onConnectionResult: (endpointId, status) {
        if (status == Status.CONNECTED) {
          _connectedEndpoint = endpointId;
          _emit('connected', 'Device connected');
          unawaited(_greet(endpointId));
        } else {
          _connectedEndpoint = null;
          _emit('disconnected', 'Device disconnected');
        }
      },
      onDisconnected: (endpointId) {
        if (_connectedEndpoint == endpointId) _connectedEndpoint = null;
        _emit('disconnected', 'Device disconnected');
      },
    );
    if (!started) {
      throw StateError(
        'Nearby sharing is unavailable. Turn on Bluetooth and Wi-Fi, and allow '
        'nearby devices.',
      );
    }
    _emit('waiting', 'Looking for the other device nearby…');
    return ShareDescriptor(
      transportId: id,
      code: 'maxstream:nearby:$token',
      label: '$nickname · nearby',
      data: {'token': token},
    );
  }

  /// The sender says hello first so the receiver can match its token even if
  /// the receiver is the one that discovered.
  Future<void> _greet(String endpointId) async {
    final token = _token;
    if (token == null) return;
    await _nearby.sendBytesPayload(
      endpointId,
      Uint8List.fromList(utf8.encode('{"hello":"$token"}')),
    );
  }

  @override
  Future<void> unpublish() async {
    try {
      await _nearby.stopAdvertising();
      await _nearby.stopAllEndpoints();
    } catch (_) {}
    _session = null;
    _token = null;
    _connectedEndpoint = null;
    _emit('disconnected', 'Stopped sharing');
  }

  void _emit(String kind, String? message) {
    if (_senderEvents.isClosed) return;
    _senderEvents.add(ShareSenderEvent(kind: kind, message: message));
  }

  // ── Receiver ──────────────────────────────────────────────────────────────

  @override
  Future<ShareManifest> fetchManifest(ShareDescriptor descriptor) async {
    final token = descriptor.data['token'] ?? '';
    final nickname = await _deviceNickname();
    String? endpointId;
    final started = await _nearby.startDiscovery(
      nickname,
      Strategy.P2P_POINT_TO_POINT,
      serviceId: serviceId,
      onEndpointFound: (id, name, service) {
        // The token arrives with the connection handshake; remember every
        // candidate and let acceptConnection filter by token.
        endpointId ??= id;
      },
      onEndpointLost: (_) {},
    );
    if (!started) {
      throw StateError(
        'Nearby sharing is unavailable. Turn on Bluetooth and Wi-Fi, and allow '
        'nearby devices.',
      );
    }

    final peer = await _findPeerWithToken(
      token,
      nickname,
      onConnectionInitiated: (id, info) async {
        if (info.authenticationToken == token) {
          await _nearby.acceptConnection(
            id,
            onPayLoadRecieved: _onPayloadReceived,
            onPayloadTransferUpdate: _onTransferUpdate,
          );
        } else {
          await _nearby.rejectConnection(id);
        }
      },
      onConnectionResult: (id, status) {
        if (status == Status.CONNECTED) _connectedEndpoint = id;
      },
      onDisconnected: (id) {
        if (_connectedEndpoint == id) _connectedEndpoint = null;
      },
    );
    if (peer == null) {
      await _nearby.stopDiscovery();
      throw StateError('No nearby device is sharing with that code.');
    }
    _connectedEndpoint = peer;
    await _nearby.stopDiscovery();

    // Ask for the manifest; the sender answers with a bytes payload.
    await _nearby.sendBytesPayload(
      peer,
      Uint8List.fromList(utf8.encode('{"manifest":"?"}')),
    );
    final raw = await _manifestReply.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () => throw StateError('The sender did not answer in time.'),
    );
    return ShareManifest.decode(raw);
  }

  /// Connects to whichever advertiser presents [token].
  Future<String?> _findPeerWithToken(
    String token,
    String nickname, {
    required OnConnectionInitiated onConnectionInitiated,
    required OnConnectionResult onConnectionResult,
    required OnDisconnected onDisconnected,
  }) async {
    final completer = Completer<String?>();
    final advertising = await _nearby.startAdvertising(
      nickname,
      Strategy.P2P_POINT_TO_POINT,
      serviceId: serviceId,
      onConnectionInitiated: onConnectionInitiated,
      onConnectionResult: (id, status) {
        onConnectionResult(id, status);
        if (status == Status.CONNECTED && !completer.isCompleted) {
          completer.complete(id);
        }
      },
      onDisconnected: onDisconnected,
    );
    if (!advertising) return null;

    // Discovery and advertising run together so whichever side hears the other
    // first can connect.
    await _nearby.startDiscovery(
      nickname,
      Strategy.P2P_POINT_TO_POINT,
      serviceId: serviceId,
      onEndpointFound: (id, name, service) async {
        if (completer.isCompleted) return;
        await _nearby.requestConnection(
          nickname,
          id,
          onConnectionInitiated: onConnectionInitiated,
          onConnectionResult: (endpointId, status) {
            onConnectionResult(endpointId, status);
            if (status == Status.CONNECTED && !completer.isCompleted) {
              completer.complete(endpointId);
            }
          },
          onDisconnected: onDisconnected,
        );
      },
      onEndpointLost: (_) {},
    );
    try {
      return await completer.future.timeout(const Duration(seconds: 45));
    } on TimeoutException {
      return null;
    }
  }

  @override
  Stream<Uint8List> fetchFile(
    ShareDescriptor descriptor,
    ShareFileEntry file, {
    int? start,
    int? end,
  }) async* {
    final endpointId = _connectedEndpoint;
    final path = file.path;
    if (endpointId == null || path == null) {
      throw StateError('Not connected to a sender');
    }
    // Nearby transfers whole files; range requests are intentionally ignored.
    final payloadId = await _nearby.sendFilePayload(endpointId, path);
    _incomingFiles[payloadId] = file.name;
    await _payloadWaiters[payloadId]?.future.timeout(
      const Duration(minutes: 60),
      onTimeout: () => throw StateError('Transfer timed out'),
    );
    // The file is on disk at this point; the importer reads it from there.
    yield Uint8List(0);
  }

  @override
  Future<void> closeReceiver() async {
    try {
      await _nearby.stopDiscovery();
      await _nearby.stopAllEndpoints();
    } catch (_) {}
    _connectedEndpoint = null;
  }

  // ── Payload plumbing ──────────────────────────────────────────────────────

  void _onPayloadReceived(String endpointId, Payload payload) {
    if (payload.type == PayloadType.BYTES && payload.bytes != null) {
      final text = utf8.decode(payload.bytes!);
      final Map<String, dynamic> decoded;
      try {
        decoded = jsonDecode(text) as Map<String, dynamic>;
      } catch (_) {
        return;
      }
      if (decoded.containsKey('manifest')) {
        if (!_manifestReply.isCompleted) _manifestReply.complete(text);
      } else if (decoded.containsKey('hello')) {
        if (!_peerHello.isCompleted) _peerHello.complete(text);
      }
      return;
    }
    final path = payload.uri ?? payload.filePath;
    if (path != null) {
      _incomingFiles[payload.id] = path;
    }
  }

  void _onTransferUpdate(String endpointId, PayloadTransferUpdate update) {
    final name = _incomingFiles[update.id];
    final index = name == null ? null : _fileIndexForName(name);
    if (index != null) {
      _lastProgress[index] = ShareFileProgress(
        received: update.bytesTransferred,
        total: update.totalBytes,
        done: update.status == PayloadStatus.SUCCESS,
      );
      if (!_progress.isClosed) _progress.add(Map.of(_lastProgress));
    }
    if (update.status == PayloadStatus.SUCCESS ||
        update.status == PayloadStatus.FAILURE) {
      final waiter = _payloadWaiters.remove(update.id);
      if (waiter != null && !waiter.isCompleted) waiter.complete();
    }
  }

  int? _fileIndexForName(String name) {
    final session = _session;
    if (session == null) return null;
    for (final item in session.manifest.items) {
      for (final file in item.files) {
        if (file.name == name) return file.index;
      }
    }
    return null;
  }

  Future<String> _deviceNickname() async {
    if (_nickname != null) return _nickname!;
    var nickname = 'MaxStream';
    try {
      final prefs = await SharedPreferences.getInstance();
      nickname = prefs.getString(_nicknameKey) ?? 'MaxStream';
    } catch (_) {}
    _nickname = nickname;
    return nickname;
  }

  static String _randomToken() {
    const alphabet = 'abcdefghijkmnpqrstuvwxyz23456789';
    final random = DateTime.now().microsecondsSinceEpoch;
    return List.generate(
      8,
      (i) => alphabet[(random ~/ (i + 1) + i * 7) % alphabet.length],
    ).join();
  }

  void dispose() {
    unawaited(unpublish());
    unawaited(closeReceiver());
    unawaited(_senderEvents.close());
    unawaited(_progress.close());
  }
}
