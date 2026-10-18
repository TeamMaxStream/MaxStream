import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../database/db_helper.dart';
import '../download_storage_service.dart';
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
      openFile: (file, {int? start, int? end}) async {
        final path = file.path;
        if (path == null) {
          return const Stream<Uint8List>.empty();
        }
        // openRead takes positional range args, so a partial read of a multi-GB
        // file never loads the whole thing.
        return File(path)
            .openRead(start, end)
            .map((chunk) => Uint8List.fromList(chunk));
      },
    );
    return transport.publish(session);
  }

  Future<void> stopSending(String transportId) =>
      transportById(transportId).unpublish();

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

    for (final item in items) {
      onStage?.call(item.title);
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
