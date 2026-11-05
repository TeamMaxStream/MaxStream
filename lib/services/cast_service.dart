import 'package:flutter/material.dart';
import 'package:flutter_chrome_cast/cast_context.dart';
import 'package:flutter_chrome_cast/media.dart';
import 'package:flutter_chrome_cast/session.dart';
import 'package:flutter_chrome_cast/discovery.dart';
import 'package:flutter_chrome_cast/entities.dart';
import 'package:flutter_chrome_cast/common.dart';

/// Google Cast service for streaming to Chromecast devices.
class CastService {
  static CastService? _instance;
  static CastService get instance => _instance ??= CastService._();
  CastService._();

  bool _initialized = false;

  /// Initialize the Google Cast context.
  Future<void> initialize() async {
    if (_initialized) return;

    try {
      await GoogleCastContext.instance.setSharedInstanceWithOptions(
        GoogleCastOptions(
          disableDiscoveryAutostart: false,
          startDiscoveryAfterFirstTapOnCastButton: true,
          stopCastingOnAppTerminated: true,
        ),
      );
      _initialized = true;
    } catch (e) {
      debugPrint('Failed to initialize Google Cast: $e');
    }
  }

  /// Check if Cast is available (device connected).
  bool get isCastAvailable =>
      GoogleCastSessionManager.instance.hasConnectedSession;

  /// Get the current session.
  GoogleCastSession? get currentSession =>
      GoogleCastSessionManager.instance.currentSession;

  /// Start discovery of Cast devices.
  Future<void> startDiscovery() async {
    await GoogleCastDiscoveryManager.instance.startDiscovery();
  }

  /// Stop discovery.
  Future<void> stopDiscovery() async {
    await GoogleCastDiscoveryManager.instance.stopDiscovery();
  }

  /// Get discovered devices.
  List<GoogleCastDevice> get discoveredDevices =>
      GoogleCastDiscoveryManager.instance.devices;

  /// Connect to a specific Cast device.
  Future<bool> connectToDevice(GoogleCastDevice device) async {
    try {
      return await GoogleCastSessionManager.instance.startSessionWithDevice(
        device,
      );
    } catch (e) {
      debugPrint('Failed to connect to Cast device: $e');
      return false;
    }
  }

  /// Cast media to the connected device.
  Future<void> castMedia({
    required String url,
    required String title,
    String? imageUrl,
    String? subtitle,
  }) async {
    if (!isCastAvailable) {
      debugPrint('No Cast device connected');
      return;
    }

    final mediaInfo = GoogleCastMediaInformation(
      contentId: url,
      contentType: 'application/x-mpegURL',
      streamType: CastMediaStreamType.buffered,
      metadata: GoogleCastGenericMediaMetadata(
        title: title,
        subtitle: subtitle,
        images: [
          if (imageUrl != null)
            GoogleCastImage(url: Uri.parse(imageUrl), width: 480, height: 1920),
        ],
      ),
    );

    final queueItem = GoogleCastQueueItem(mediaInformation: mediaInfo);

    await GoogleCastRemoteMediaClient.instance.queueLoadItems([queueItem]);
  }

  /// Play on Cast device.
  Future<void> play() async {
    await GoogleCastRemoteMediaClient.instance.play();
  }

  /// Pause on Cast device.
  Future<void> pause() async {
    await GoogleCastRemoteMediaClient.instance.pause();
  }

  /// Stop casting.
  Future<void> stop() async {
    await GoogleCastRemoteMediaClient.instance.stop();
  }

  /// Seek to position.
  Future<void> seek(Duration position) async {
    await GoogleCastRemoteMediaClient.instance.seek(
      GoogleCastMediaSeekOption(position: position),
    );
  }

  /// Disconnect from Cast device.
  Future<void> disconnect() async {
    await GoogleCastSessionManager.instance.endSession();
  }

  /// Listen to session changes.
  Stream<GoogleCastSession?> get sessionStream =>
      GoogleCastSessionManager.instance.currentSessionStream;

  /// Listen to discovery changes.
  Stream<List<GoogleCastDevice>> get devicesStream =>
      GoogleCastDiscoveryManager.instance.devicesStream;
}
