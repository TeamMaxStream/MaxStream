import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maxstream/services/share/nearby_transport.dart';
import 'package:maxstream/services/share/share_models.dart';
import 'package:nearby_connections/nearby_connections.dart';

/// Drives a [NearbyTransport] against a fake plugin.
///
/// This exists because the real defect was invisible: the transport compared
/// `ConnectionInfo.authenticationToken` against the share code, but the plugin
/// calls Google's legacy `requestConnection(name, id, callback)` overload, which
/// carries no token — so the value was always `'-1'` and *every* connection was
/// rejected on both sides, whatever permissions were granted.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodChannel = MethodChannel('nearby_connections');
  const eventChannelName = 'nearby_connections/events';
  const codec = StandardMethodCodec();

  late List<MethodCall> calls;
  late List<Map<String, dynamic>> disconnected;
  const endpoint = 'endpoint-1';

  setUp(() {
    calls = [];
    disconnected = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, (call) async {
          calls.add(call);
          switch (call.method) {
            case 'sendPayload':
            case 'startAdvertising':
            case 'startDiscovery':
            case 'requestConnection':
            case 'acceptConnection':
            case 'rejectConnection':
              return true;
            case 'disconnectFromEndpoint':
              disconnected.add(
                Map<String, dynamic>.from(call.arguments as Map),
              );
              return true;
            default:
              return null;
          }
        });
    // The plugin subscribes to events on this channel; accept the listen call.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel(eventChannelName),
      (_) async => null,
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(eventChannelName), null);
  });

  /// Delivers a plugin event the way the native side does: a success envelope
  /// on the event channel carrying `{method, ...args}`.
  Future<void> emit(String method, Map<String, dynamic> args) async {
    await TestDefaultBinaryMessengerBinding
        .instance
        .defaultBinaryMessenger
        .handlePlatformMessage(
          eventChannelName,
          codec.encodeSuccessEnvelope(<String, dynamic>{'method': method, ...args}),
          (_) {},
        );
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }

  /// The plugin expects the payload fields flattened into the event args (it
  /// reads `args['type']`, `args['bytes']` directly, not a nested map).
  Future<void> emitBytes(String body) async {
    await emit('onPayloadReceived', {
      'endpointId': endpoint,
      'payloadId': 1,
      'type': PayloadType.BYTES.index,
      'bytes': utf8.encode(body),
    });
  }

  // The plugin exposes sendBytesPayload() but invokes "sendPayload" on the
  // wire, so assertions have to match the wire name.
  List<String> sentBodies() => calls
      .where((c) => c.method == 'sendPayload')
      .map((c) => utf8.decode((c.arguments as Map)['bytes'] as List<int>))
      .toList();

  /// The code this session is running, read back off the sender's own greeting.
  String advertisedCode() {
    final greeting = sentBodies().firstWhere((b) => b.contains('hello'));
    return (jsonDecode(greeting) as Map)['hello'].toString();
  }

  ShareSession sessionFor() => ShareSession(
        manifest: ShareManifest(
          senderName: 'Pixel',
          createdAt: DateTime.fromMillisecondsSinceEpoch(0),
          items: const [],
        ),
        openFile: (_, {int? start, int? end}) async =>
            Stream<Uint8List>.value(Uint8List(0)),
      );

  /// Brings the transport to the "peer connected" state.
  ///
  /// Both steps matter: `onConnectionInitiated` is where the transport calls
  /// acceptConnection, which is what registers the payload callback. Skipping
  /// it leaves the transport deaf even though it looks connected.
  Future<void> connectPeer(NearbyTransport transport) async {
    await transport.publish(sessionFor());
    await emit('ad.onConnectionInitiated', {
      'endpointId': endpoint,
      'endpointName': 'Other phone',
      'authenticationToken': '-1',
      'isIncomingConnection': true,
    });
    await emit('ad.onConnectionResult', {
      'endpointId': endpoint,
      'statusCode': Status.CONNECTED.index,
    });
  }

  test('the sender presents its code the moment the peer connects', () async {
    final transport = NearbyTransport();
    await connectPeer(transport);

    final greetings = sentBodies().where((b) => b.contains('hello')).toList();
    expect(
      greetings.any((b) => b.contains('"hello"')),
      isTrue,
      reason: 'the sender must prove which code it is running',
    );
  });

  test('a peer that does not know the code is never served the manifest',
      () async {
    final transport = NearbyTransport();
    await connectPeer(transport);

    // Asks for the manifest without proving anything.
    await emitBytes('{"manifest":"?"}');

    expect(
      sentBodies().where((b) => b.contains('items')),
      isEmpty,
      reason: 'an unauthenticated peer got the manifest',
    );
    expect(
      disconnected.any((a) => a['endpointId'] == endpoint),
      isTrue,
      reason: 'the peer should have been disconnected',
    );
  });

  test('a peer that presents the code is served the manifest', () async {
    final transport = NearbyTransport();
    await connectPeer(transport);

    // The receiver proves it and asks in the same payload.
    await emitBytes('{"manifest":"?","hello":"${advertisedCode()}"}');

    expect(
      sentBodies().where((b) => b.contains('items')),
      isNotEmpty,
      reason: 'an authenticated peer got nothing',
    );
    expect(
      disconnected.where((a) => a['endpointId'] == endpoint),
      isEmpty,
      reason: 'an authenticated peer was dropped',
    );
  });

  test('a peer presenting the wrong code is dropped', () async {
    final transport = NearbyTransport();
    await connectPeer(transport);

    await emitBytes('{"manifest":"?","hello":"not-the-code"}');

    expect(
      sentBodies().where((b) => b.contains('items')),
      isEmpty,
      reason: 'a wrong code was accepted',
    );
    expect(
      disconnected.any((a) => a['endpointId'] == endpoint),
      isTrue,
    );
  });

  test('the manifest echoes the code so the receiver can authenticate it', () {
    final manifest = ShareManifest(
      senderName: 'Pixel',
      createdAt: DateTime.fromMillisecondsSinceEpoch(0),
      items: const [],
    );
    expect(manifest.encode(token: 'zz99xx'), contains('"hello":"zz99xx"'));
    expect(
      manifest.encode(),
      isNot(contains('hello')),
      reason: 'the LAN transport must not gain a hello field',
    );
    expect(ShareManifest.decode(manifest.encode(token: 'zz99xx')).senderName,
        'Pixel');
  });
}
