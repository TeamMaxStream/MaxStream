import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'share_models.dart';
import 'share_transport.dart';

/// Raised when Android granted only *approximate* location.
///
/// play-services-nearby needs precise location for peer discovery, and that
/// cannot be requested from inside the app — only the system permission screen
/// can grant it. The share UI catches this to offer "Open settings" or a switch
/// to the Wi-Fi transport instead of showing a dead end.
class NearbyNeedsPreciseLocation implements Exception {
  const NearbyNeedsPreciseLocation();

  @override
  String toString() =>
      'Nearby sharing needs precise location (Android: Approximate location)';
}

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

  /// Token the receiver expects the sender to present. Set while resolving.
  String? _expectedToken;

  /// True once the connected peer proved it knows the share code.
  bool _peerAuthenticated = false;

  Completer<String> _manifestReply = Completer<String>();
  Completer<void> _peerHello = Completer<void>();

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

  /// Google's nearby status codes for "already in that state".
  ///
  /// `stopAdvertising()` is not synchronous with the platform: stopping and
  /// restarting straight away can lose the race and come back 8001. What matters
  /// here is the resulting state, not the transition — and the plugin installs
  /// the new callbacks *before* calling the platform, so an advertiser left
  /// running by a previous share keeps driving this session correctly.
  static const Map<String, int> _alreadyBusyCodes = {
    'STATUS_ALREADY_ADVERTISING': 8001,
    'STATUS_ALREADY_DISCOVERING': 8002,
  };

  static bool _isAlreadyBusy(PlatformException error) {
    final text = '${error.code} ${error.message ?? ''}';
    for (final entry in _alreadyBusyCodes.entries) {
      if (text.contains(entry.key) || text.contains('${entry.value}:')) {
        return true;
      }
    }
    return false;
  }

  Future<bool> _startAdvertising({
    required String nickname,
    required OnConnectionInitiated onConnectionInitiated,
    required OnConnectionResult onConnectionResult,
    required OnDisconnected onDisconnected,
  }) async {
    try {
      return await _nearby.startAdvertising(
        nickname,
        Strategy.P2P_POINT_TO_POINT,
        serviceId: serviceId,
        onConnectionInitiated: onConnectionInitiated,
        onConnectionResult: onConnectionResult,
        onDisconnected: onDisconnected,
      );
    } on PlatformException catch (e) {
      if (!_isAlreadyBusy(e)) rethrow;
      debugPrint('Nearby: already advertising — reusing the running one');
      return true;
    }
  }

  Future<bool> _startDiscovery({
    required String nickname,
    required OnEndpointFound onEndpointFound,
    required OnEndpointLost onEndpointLost,
  }) async {
    try {
      return await _nearby.startDiscovery(
        nickname,
        Strategy.P2P_POINT_TO_POINT,
        serviceId: serviceId,
        onEndpointFound: onEndpointFound,
        onEndpointLost: onEndpointLost,
      );
    } on PlatformException catch (e) {
      if (!_isAlreadyBusy(e)) rethrow;
      debugPrint('Nearby: already discovering — reusing the running one');
      return true;
    }
  }

  // ── Sender ────────────────────────────────────────────────────────────────

  @override
  Future<ShareDescriptor> publish(ShareSession session) async {
    await unpublish();
    _session = session;
    final token = _randomToken();
    _token = token;
    final nickname = await _deviceNickname();

    // Preconditions, checked before the plugin so the failure names the real
    // cause instead of surfacing as a generic platform error.
    final blocked = await _blockingReason();
    if (blocked != null) throw StateError(blocked);

    final started = await _startAdvertising(
      nickname: nickname,
      // A random scanner must not be able to pull files, but the share token
      // CANNOT be checked here: this plugin calls Google's legacy
      // requestConnection(name, id, callback) overload, which carries no
      // authentication token, so `info.authenticationToken` is always '-1'.
      // Gating on it rejected every connection on both sides, so Nearby could
      // never connect at all. The token is enforced one layer up instead, in
      // the hello handshake below, before any file is served.
      onConnectionInitiated: (endpointId, info) async {
        await _nearby.acceptConnection(
          endpointId,
          onPayLoadRecieved: _onPayloadReceived,
          onPayloadTransferUpdate: _onTransferUpdate,
        );
      },
      onConnectionResult: (endpointId, status) {
        if (status == Status.CONNECTED) {
          _connectedEndpoint = endpointId;
          _peerAuthenticated = false;
          _emit('connected', 'Device connected');
          unawaited(_sendHello(endpointId));
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

  /// Nearby's own prerequisites: Bluetooth on, Wi-Fi on, location services on,
  /// Play services available. Returns a user-facing reason, or null when fine.
  Future<String?> _blockingReason() async {
    try {
      final bluetooth = await Permission.bluetoothScan.status;
      if (bluetooth.isPermanentlyDenied || bluetooth.isRestricted) {
        return 'Nearby sharing needs Bluetooth permission. Allow "Nearby '
            'devices" for MaxStream in Settings, or use the Wi-Fi option.';
      }
      // Ask rather than just read: if the user switched the Android toggle to
      // Precise while the sheet was closed, this picks it up immediately.
      var location = await Permission.locationWhenInUse.status;
      if (location.isDenied || location.isPermanentlyDenied) {
        location = await Permission.locationWhenInUse.request();
      }
      if (location.isDenied || location.isPermanentlyDenied) {
        return 'Nearby sharing needs location permission to discover the other '
            'device. Allow it in Settings, or use the Wi-Fi option.';
      }
      if (location.isLimited) {
        // Android's "Approximate location" cannot be promoted from here: only
        // the system permission screen can, so this is reported as a
        // prerequisite the UI can act on (open settings / switch to Wi-Fi).
        throw const NearbyNeedsPreciseLocation();
      }
    } on NearbyNeedsPreciseLocation {
      rethrow;
    } catch (_) {
      // permission_handler can throw on odd OEM builds; let the plugin try.
    }
    return null;
  }

  /// Both sides greet with their token once connected, so each can decide
  /// whether the other actually knows the code.
  Future<void> _sendHello(String endpointId) async {
    final token = _token ?? _expectedToken;
    if (token == null || token.isEmpty) return;
    try {
      await _nearby.sendBytesPayload(
        endpointId,
        Uint8List.fromList(utf8.encode('{"hello":"$token"}')),
      );
    } catch (e) {
      // A greeting that fails to send is not worth tearing the session down;
      // the peer will simply fail to authenticate and disconnect itself.
      debugPrint('Nearby: hello not delivered: $e');
    }
  }

  /// Drops a peer that did not present the share code. Nothing has been served
  /// to it at this point, so disconnecting is enough.
  Future<void> _rejectPeer(String endpointId, String reason) async {
    _peerAuthenticated = false;
    if (_connectedEndpoint == endpointId) _connectedEndpoint = null;
    try {
      await _nearby.disconnectFromEndpoint(endpointId);
    } catch (_) {}
    // Only the receiving side awaits this completer; failing it anywhere else
    // would surface as an unhandled async error.
    if (_expectedToken != null && !_peerHello.isCompleted) {
      _peerHello.completeError(StateError(reason));
    }
    _emit('error', reason);
  }

  @override
  Future<void> unpublish() async {
    // Each stop runs on its own: sharing a try block meant a throw from
    // stopAdvertising skipped stopAllEndpoints and left the peer attached.
    try {
      await _nearby.stopAdvertising();
    } catch (_) {}
    try {
      await _nearby.stopAllEndpoints();
    } catch (_) {}
    _session = null;
    _token = null;
    _connectedEndpoint = null;
    _peerAuthenticated = false;
    _emit('disconnected', 'Stopped sharing');
  }

  void _emit(String kind, String? message) {
    if (_senderEvents.isClosed) return;
    _senderEvents.add(ShareSenderEvent(kind: kind, message: message));
  }

  // ── Receiver ──────────────────────────────────────────────────────────────

  @override
  Future<ShareManifest> fetchManifest(ShareDescriptor descriptor) async {
    final blocked = await _blockingReason();
    if (blocked != null) throw StateError(blocked);

    final token = descriptor.data['token']?.toString() ?? '';
    if (token.isEmpty) throw StateError('That share code is not a nearby code.');
    final nickname = await _deviceNickname();

    // Per-session state: the transport is long-lived, so the completers from a
    // previous share would otherwise still be holding that share's result.
    _expectedToken = token;
    _peerAuthenticated = false;
    _manifestReply = Completer<String>();
    _peerHello = Completer<void>();

    Future<bool> accept(String id, ConnectionInfo info) async {
      // No token check is possible here (see the sender side); the hello
      // handshake below is what decides whether this peer is the right one.
      await _nearby.acceptConnection(
        id,
        onPayLoadRecieved: _onPayloadReceived,
        onPayloadTransferUpdate: _onTransferUpdate,
      );
      return true;
    }

    void onResult(String id, Status status) {
      if (status == Status.CONNECTED) {
        _connectedEndpoint = id;
        _peerAuthenticated = false;
        unawaited(_sendHello(id));
      }
    }

    final peer = await _connectToPeer(
      nickname,
      onConnectionInitiated: (id, info) => accept(id, info),
      onConnectionResult: onResult,
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

    // Prove the sender knows the code before asking it for anything.
    try {
      await _peerHello.future.timeout(
        const Duration(seconds: 20),
        onTimeout: () => throw StateError(
          'That device did not confirm the share code.',
        ),
      );
    } catch (_) {
      await _nearby.disconnectFromEndpoint(peer).catchError((_) {});
      rethrow;
    }
    _peerAuthenticated = true;

    // Ask for the manifest; the sender answers with a bytes payload that
    // echoes this code back.
    await _nearby.sendBytesPayload(
      peer,
      Uint8List.fromList(utf8.encode('{"manifest":"?","hello":"$token"}')),
    );
    final raw = await _manifestReply.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () => throw StateError('The sender did not answer in time.'),
    );
    return ShareManifest.decode(raw);
  }

  /// Connects to the first advertiser we hear.
  ///
  /// Advertising and discovery run together so whichever side hears the other
  /// first can connect; the share code is then confirmed by the hello payload,
  /// which is the only place it can actually be checked.
  Future<String?> _connectToPeer(
    String nickname, {
    required OnConnectionInitiated onConnectionInitiated,
    required OnConnectionResult onConnectionResult,
    required OnDisconnected onDisconnected,
  }) async {
    final completer = Completer<String?>();
    final advertising = await _startAdvertising(
      nickname: nickname,
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
    await _startDiscovery(
      nickname: nickname,
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

  /// Serialises the manifest and sends it with the share code, so the receiver
  /// can verify it before trusting the file list.
  Future<void> _sendManifest(String endpointId) async {
    final session = _session;
    if (session == null) return;
    final raw = session.manifest.encode(token: _token);
    await _nearby.sendBytesPayload(
      endpointId,
      Uint8List.fromList(utf8.encode(raw)),
    );
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
    } catch (_) {}
    try {
      await _nearby.stopAllEndpoints();
    } catch (_) {}
    _connectedEndpoint = null;
    _expectedToken = null;
    _peerAuthenticated = false;
    if (!_manifestReply.isCompleted) {
      _manifestReply.completeError(StateError('Receive cancelled'));
    }
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
      // Hello is checked FIRST: the receiver sends
      // {"manifest":"?","hello":token} in a single payload, so testing
      // `manifest` first would reject a peer whose hello was right there.
      if (decoded.containsKey('hello')) {
        final expected = _token ?? _expectedToken;
        if (expected == null || decoded['hello']?.toString() != expected) {
          unawaited(
            _rejectPeer(endpointId, 'That device does not have this code.'),
          );
          return;
        }
        _peerAuthenticated = true;
        if (!_peerHello.isCompleted) _peerHello.complete();
      }
      if (decoded.containsKey('manifest')) {
        // Only a peer that proved it knows the code gets the file list.
        if (!_peerAuthenticated) {
          unawaited(
            _rejectPeer(endpointId, 'That device did not present the code.'),
          );
          return;
        }
        // A non-null token means this side is the sender, so answer the
        // request. (It previously just stashed the request itself and tried to
        // decode '{"manifest":"?"}' as a manifest.)
        if (_token != null) {
          unawaited(_sendManifest(endpointId));
        } else if (!_manifestReply.isCompleted) {
          _manifestReply.complete(text);
        }
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

  /// Share code. Previously eight characters picked from a clock value, which
  /// is guessable; this one is a real random draw and is the only thing
  /// standing between a stranger and someone's downloads.
  static String _randomToken() {
    const alphabet = 'abcdefghijkmnpqrstuvwxyz23456789';
    final random = Random.secure();
    return List.generate(
      10,
      (_) => alphabet[random.nextInt(alphabet.length)],
    ).join();
  }

  void dispose() {
    unawaited(unpublish());
    unawaited(closeReceiver());
    unawaited(_senderEvents.close());
    unawaited(_progress.close());
  }
}
