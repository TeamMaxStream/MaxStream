import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';

import '../../database/db_helper.dart';
import '../download_storage_service.dart';
import '../notification_service.dart';
import '../profile_scope.dart';
import 'lan_http_transport.dart';
import 'nearby_transport.dart';
import 'share_models.dart';
import 'share_transport.dart';

/// Device-to-device sharing of downloaded movies and series, Xender-style.
///
/// The sender publishes a [ShareManifest] (metadata) plus every file of the
/// chosen downloads; the receiver fetches the files, writes them into the same
/// on-disk layout a normal download uses and registers a `media_downloads` row
/// — so a shared item lands in the Downloads screen with its poster, plays
/// offline, counts toward storage and can be deleted like any other download.
///
/// Transports are pluggable: [LanHttpTransport] (same network) and
/// [NearbyTransport] (no network at all) implement the same interface.
class ShareService {
  ShareService._();
  static final ShareService instance = ShareService._();

  static const int manifestVersion = 1;

  final LanHttpTransport _lan = LanHttpTransport();
  final NearbyTransport _nearby = NearbyTransport();

  /// Name shown as the sender in the receiver's preview.
  String get senderName => ProfileScope.currentProfileName.isEmpty
      ? 'MaxStream'
      : ProfileScope.currentProfileName;

  List<ShareTransport> get transports => [_lan, _nearby];

  ShareTransport transportById(String id) =>
      transports.firstWhere((t) => t.id == id, orElse: () => _lan);

  /// Runtime permissions a transport needs before it can run.
  ///
  /// Nearby Connections advertises over Bluetooth, which on API 31+ needs
  /// BLUETOOTH_ADVERTISE at runtime as well as location (for peer discovery).
  /// Missing ADVERTISE surfaces as Android error 8038
  /// (MISSING_PERMISSION_BLUETOOTH_ADVERTISE), which is what the app used to
  /// show verbatim when the user picked the Bluetooth option.
  /// Extra setup the user still has to do (e.g. precise location).
  static List<String> _pendingNearbyHints = const [];

  /// Human-readable list of what's still missing, empty when all good.
  static List<String> pendingNearbyHints() => _pendingNearbyHints;

  static Future<PermissionStatus> ensureTransportPermissions(
    String transportId,
  ) async {
    if (transportId != 'nearby') {
      _pendingNearbyHints = const [];
      return PermissionStatus.granted;
    }
    final location = await Permission.locationWhenInUse.request();
    if (location.isDenied) return PermissionStatus.denied;
    final missing = <String>[];
    if (location.isLimited) {
      // "Approximate location" is granted, but Nearby Connections needs
      // precise to discover peers — without this the user was told location was
      // denied even though they had allowed it.
      missing.add('precise location');
    }
    for (final entry in {
      Permission.bluetoothScan: 'Nearby devices',
      Permission.bluetoothConnect: 'Nearby devices',
      Permission.bluetoothAdvertise: 'Nearby devices',
    }.entries) {
      final status = await entry.key.request();
      if (!status.isGranted && !status.isLimited) missing.add(entry.value);
    }
    _pendingNearbyHints = missing;
    return PermissionStatus.granted;
  }

  /// Turns a native failure into something a user can act on.
  static String describeError(Object error, String transportId) {
    if (error is PlatformException) {
      final code = '${error.code} ${error.message ?? ''}';
      if (code.contains('8038') ||
          code.contains('MISSING_PERMISSION_BLUETOOTH_ADVERTISE')) {
        return 'Bluetooth permission for advertising was denied. Allow '
            '"Nearby devices" for MaxStream in Settings, then try again.';
      }
      if (code.contains('BLUETOOTH') || code.contains('8028')) {
        return 'Bluetooth permission denied. Allow "Nearby devices" for '
            'MaxStream in Settings, then try again.';
      }
      if (code.contains('8029') || code.contains('LOCATION')) {
        return 'Location permission denied. Nearby sharing needs precise '
            'location to discover the other device — allow it in Settings, or '
            'use the Wi-Fi option.';
      }
      if (code.contains('8037') || code.contains('BLUETOOTH_DISABLED')) {
        return 'Turn on Bluetooth and Wi-Fi to use nearby sharing.';
      }
      return error.message?.toString() ?? error.code;
    }
    return error.toString();
  }

  // ── Building a bundle ─────────────────────────────────────────────────────

  /// Collects the files of each download row (the whole directory: HLS
  /// downloads are a playlist plus segments, so sharing one file would produce
  /// an unplayable item).
  Future<ShareManifest> buildManifest(
    List<Map<String, dynamic>> downloads, {
    String? senderName,
  }) async {
    final items = <ShareItem>[];
    var index = 0;
    for (final download in downloads) {
      final localPath = download['localPath']?.toString() ?? '';
      if (localPath.isEmpty) continue;
      final directory = Directory(p.dirname(localPath));
      if (!await directory.exists()) continue;

      final files = <ShareFileEntry>[];
      try {
        final entries = await directory.list(followLinks: false).toList();
        for (final entity in entries) {
          if (entity is! File) continue;
          final name = p.basename(entity.path);
          if (name.startsWith('.')) continue; // .complete and partials
          int size;
          try {
            size = await entity.length();
          } catch (_) {
            continue;
          }
          files.add(
            ShareFileEntry(index: index++, name: name, size: size, path: entity.path),
          );
        }
      } catch (_) {
        continue;
      }
      if (files.isEmpty) continue;

      final subtitles = (download['subtitles'] as List? ?? const [])
          .whereType<Map>()
          .map((track) => p.basename(track['url']?.toString() ?? ''))
          .where((name) => name.isNotEmpty)
          .toList();

      items.add(
        ShareItem(
          downloadKey: download['downloadKey']?.toString() ?? '',
          mediaId: download['mediaId']?.toString() ?? '',
          mediaType: download['mediaType']?.toString() ?? 'movie',
          title: download['title']?.toString() ?? 'Shared video',
          thumbnail: download['thumbnail']?.toString() ?? '',
          seriesId: download['seriesId']?.toString(),
          seasonNumber: (download['seasonNumber'] as num?)?.toInt(),
          episodeNumber: (download['episodeNumber'] as num?)?.toInt(),
          entryFile: p.basename(localPath),
          subtitleNames: subtitles,
          files: files,
        ),
      );
    }
    return ShareManifest(
      version: manifestVersion,
      senderName: senderName ?? this.senderName,
      createdAt: DateTime.now(),
      items: items,
    );
  }

  // ── Sending ───────────────────────────────────────────────────────────────

  /// Starts sharing [manifest] over [transportId] and returns the descriptor to
  /// render as a QR / short code.
  Future<ShareDescriptor> startSending(
    ShareManifest manifest, {
    required String transportId,
  }) async {
    final transport = transportById(transportId);
    final session = ShareSession(
      manifest: manifest,
      // The LAN sender always streams from `start` to EOF, so only the start
      // offset matters; openRead takes it positionally and never loads the
      // whole file into memory.
      openFile: (file, {int? start, int? end}) async {
        final path = file.path;
        if (path == null) return const Stream<Uint8List>.empty();
        return File(path)
            .openRead(start)
            .map((chunk) => Uint8List.fromList(chunk));
      },
    );
    final descriptor = await transport.publish(session);
    _watchSendingProgress(transportId, manifest);
    return descriptor;
  }

  Future<void> stopSending(String transportId) =>
      transportById(transportId).unpublish();

  /// Watches a running share and mirrors it into a notification (bytes sent).
  void _watchSendingProgress(
    String transportId,
    ShareManifest manifest,
  ) {
    final transport = transportById(transportId);
    final notifications = NotificationService();
    const notificationId = 0x5A4E; // 'SN' — same slot as receiving
    final filesByIndex = <int, ShareItem>{};
    for (final item in manifest.items) {
      for (final file in item.files) {
        filesByIndex[file.index] = item;
      }
    }
    final total = manifest.totalBytes;
    final byItem = <String, int>{};
    var lastPercent = -1;
    final sub = transport.progress.listen((files) {
      byItem.clear();
      var sent = 0;
      files.forEach((index, entry) {
        sent += entry.received;
        final item = filesByIndex[index];
        if (item != null) {
          byItem[item.downloadKey] = (byItem[item.downloadKey] ?? 0) + entry.received;
        }
      });
      final percent = total <= 0 ? 0 : ((sent / total) * 100).round();
      if (percent == lastPercent) return;
      lastPercent = percent;
      final active = byItem.entries.isEmpty
          ? manifest.senderName
          : manifest.items
              .firstWhere(
                (i) => i.downloadKey == byItem.keys.first,
                orElse: () => manifest.items.first,
              )
              .title;
      unawaited(notifications.showShareProgress(
        id: notificationId,
        title: 'Sending ${manifest.items.length} item${manifest.items.length == 1 ? '' : 's'}',
        label: active,
        done: sent,
        total: total,
        sending: true,
      ));
    });
    _sendingSubscribers[transportId] = sub;
  }

  final Map<String, StreamSubscription<Map<int, ShareFileProgress>>>
      _sendingSubscribers = {};

  /// Ends the sending notification with a success/failure line.
  Future<void> finishSending(
    String transportId,
    ShareManifest manifest, {
    String? error,
  }) async {
    final sub = _sendingSubscribers.remove(transportId);
    await sub?.cancel();
    await NotificationService().showShareFinished(
      id: 0x5A4E,
      label: error == null
          ? '${manifest.items.length} item${manifest.items.length == 1 ? '' : 's'} '
              '· ${DownloadStorageService.formatBytes(manifest.totalBytes)}'
          : 'Send failed',
      sending: true,
      error: error,
    );
  }

  Stream<ShareSenderEvent> senderEvents(String transportId) =>
      transportById(transportId).senderEvents;

  // ── Receiving ─────────────────────────────────────────────────────────────

  Future<ShareManifest> previewShare(ShareDescriptor descriptor) =>
      transportById(descriptor.transportId).fetchManifest(descriptor);

  Stream<Map<int, ShareFileProgress>> progress(String transportId) =>
      transportById(transportId).progress;

  /// Fetches [items] into the Downloads library.
  ///
  /// Each item becomes `<download root>/<downloadKey>/` with the `.complete`
  /// marker the rest of the app uses to recognise a finished download, plus a
  /// `media_downloads` row — identical to what a normal download produces.
  Future<void> receive(
    ShareDescriptor descriptor,
    ShareManifest manifest,
    List<ShareItem> items, {
    void Function(String stage)? onStage,
  }) async {
    final transport = transportById(descriptor.transportId);
    final root = await DownloadStorageService.root();
    final notifications = NotificationService();
    const notificationId = 0x5A4E; // 'SN'
    // Per-file progress from the transport, mapped back to the item it belongs
    // to so the notification can show "3 of 8 episodes • 1.2 GB of 3.4 GB".
    var currentLabel = '';
    var progressSub = transport.progress.listen((files) {
      if (items.isEmpty) return;
      var received = 0;
      for (final item in items) {
        for (final file in item.files) {
          final entry = files[file.index];
          if (entry != null) received += entry.received;
        }
      }
      final total = items.fold<int>(0, (sum, item) => sum + item.totalBytes);
      unawaited(notifications.showShareProgress(
        id: notificationId,
        title: 'Receiving ${items.length} item${items.length == 1 ? '' : 's'}',
        label: currentLabel,
        done: received,
        total: total,
        sending: false,
      ));
    });

    try {
      for (final item in items) {
      onStage?.call(item.title);
      currentLabel = item.title;
      final key = item.downloadKey.isEmpty
          ? 'shared_${item.mediaId}_${DateTime.now().microsecondsSinceEpoch}'
          : item.downloadKey;
      final directory = Directory(p.join(root.path, key));
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
      await directory.create(recursive: true);

      // Manifest first: if the transfer dies halfway the partial directory has
      // no `.complete` marker, so the app never lists a broken item.
      final manifestFile = File(p.join(directory.path, 'share_manifest.json'));
      await manifestFile.writeAsString(
        '{"item":${item.toJson()}}',
        flush: true,
      );

      for (final file in item.files) {
        final target = File(p.join(directory.path, file.name));
        await _writeFile(transport, descriptor, file, target);
      }

      final subtitles = <Map<String, dynamic>>[];
      for (var i = 0; i < item.subtitleNames.length; i++) {
        subtitles.add({
          'label': 'Subtitle ${i + 1}',
          'url': p.join(directory.path, item.subtitleNames[i]),
          'default': i == 0,
          'source': 'Shared',
        });
      }

      await File(p.join(directory.path, '.complete')).writeAsString(
        'ok',
        flush: true,
      );

      await DBHelper.insertMediaDownload(
        downloadKey: key,
        mediaId: item.mediaId,
        mediaType: item.mediaType,
        title: item.title,
        thumbnail: item.thumbnail,
        localPath: p.join(directory.path, item.entryFile),
        subtitles: subtitles,
        seriesId: item.seriesId,
        seasonNumber: item.seasonNumber,
        episodeNumber: item.episodeNumber,
      );
      }
      DBHelper.notifyDownloadsChanged();
      await notifications.showShareFinished(
        id: notificationId,
        label: '${items.length} item${items.length == 1 ? '' : 's'} '
            '· ${DownloadStorageService.formatBytes(items.fold<int>(0, (sum, i) => sum + i.totalBytes))}',
        sending: false,
      );
    } catch (error) {
      await notifications.showShareFinished(
        id: notificationId,
        label: 'Receive failed',
        sending: false,
        error: error.toString(),
      );
      rethrow;
    } finally {
      await progressSub.cancel();
    }
  }

  Future<void> _writeFile(
    ShareTransport transport,
    ShareDescriptor descriptor,
    ShareFileEntry file,
    File target,
  ) async {
    final handle = await target.open(mode: FileMode.write);
    try {
      var written = 0;
      await for (final chunk in transport.fetchFile(descriptor, file)) {
        if (chunk.isEmpty) continue; // Nearby writes the file itself
        await handle.writeFrom(chunk);
        written += chunk.length;
      }
      await handle.flush();
      if (written == 0 && !await target.exists()) {
        throw StateError('Received an empty file (${file.name})');
      }
    } finally {
      await handle.close();
    }
  }

  Future<void> cancelReceive(String transportId) =>
      transportById(transportId).closeReceiver();

  void dispose() {
    _lan.dispose();
    _nearby.dispose();
  }
}
