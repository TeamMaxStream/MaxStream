import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../database/db_helper.dart';

/// Single source of truth for where downloads live on disk and how much space
/// they really take.
///
/// Two bugs lived here before:
///
///  * **Sizes were measured from `localPath` alone.** For an HLS download that
///    file is the rewritten *playlist* — a few KB of text — while the movie is
///    the hundreds of segments sitting next to it. Every screen therefore
///    reported "3 KB" for a full episode and the settings screen reported 0 B.
///    [sizeOfDownload] measures the whole per-download directory instead.
///  * **The numbers never refreshed.** They were computed once in `initState`,
///    so a finished download or a deletion only showed up after the screen was
///    reopened. [revision] is bumped whenever the set of downloads changes and
///    both screens listen to it.
class DownloadStorageService {
  DownloadStorageService._();

  static const String _folder = 'media_downloads';

  /// Marker the download service writes when a download completes. Its presence
  /// is what tells us a directory is a whole download (so we can sum it)
  /// rather than a shared parent that would double-count.
  static const String _completeMarker = '.complete';

  /// Bumped whenever the on-disk set of downloads changes.
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static void notifyChanged() {
    revision.value++;
  }

  /// Root of the download tree.
  ///
  /// App-specific EXTERNAL storage on purpose: this is the directory Android's
  /// Settings → App storage reports, so the figure the app shows and the figure
  /// the system shows are the same, and deleting files frees it there too.
  /// Falls back to the internal support directory if external storage is
  /// unavailable (unmounted / no external volume).
  static Future<Directory> root() async {
    final external = await getExternalStorageDirectory();
    final base = external ?? await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, _folder));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Where downloads used to live (internal app support dir).
  static Future<Directory> legacyRoot() async {
    final support = await getApplicationSupportDirectory();
    return Directory(p.join(support.path, _folder));
  }

  /// Real on-disk size of one download, in bytes.
  ///
  /// Measures the whole download directory (video/playlist + segments +
  /// subtitles). 0 when nothing is on disk for it.
  static Future<int> sizeOfDownload(String localPath) async {
    if (localPath.isEmpty) return 0;
    final file = File(localPath);
    final dir = Directory(p.dirname(localPath));
    try {
      if (await dir.exists() &&
          await File(p.join(dir.path, _completeMarker)).exists()) {
        return await _directorySize(dir);
      }
      if (await file.exists()) return await file.length();
    } catch (_) {
      // Unreadable path: fall through to 0 rather than break the screen.
    }
    return 0;
  }

  static Future<int> _directorySize(Directory dir) async {
    var total = 0;
    try {
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          try {
            total += await entity.length();
          } catch (_) {}
        }
      }
    } catch (_) {}
    return total;
  }

  /// Total bytes used by [downloads] (rows from `media_downloads`), counting
  /// each download directory once.
  static Future<int> totalSizeOf(
    Iterable<Map<String, dynamic>> downloads,
  ) async {
    final seen = <String>{};
    var total = 0;
    for (final download in downloads) {
      final path = download['localPath']?.toString() ?? '';
      if (path.isEmpty) continue;
      final dirKey = p.dirname(path);
      if (!seen.add(dirKey)) continue;
      total += await sizeOfDownload(path);
    }
    return total;
  }

  static String formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  /// Moves downloads made before the move to app-specific external storage.
  ///
  /// Android's Settings → App storage only reports the external app directory
  /// on many devices, which is why downloads live there now; without this the
  /// already-downloaded episodes would keep occupying space the app (and the
  /// system) can't account for. Safe to call repeatedly.
  static Future<void> migrateLegacyDownloads() async {
    try {
      final legacy = await legacyRoot();
      if (!await legacy.exists()) return;
      final target = await root();
      if (p.equals(legacy.path, target.path)) return;

      final downloads = await DBHelper.getAllMediaDownloads();
      for (final download in downloads) {
        final localPath = download['localPath']?.toString() ?? '';
        if (localPath.isEmpty) continue;
        final id = p.basename(p.dirname(localPath));
        if (id.isEmpty || id == '.') continue;
        final from = Directory(p.join(legacy.path, id));
        final to = Directory(p.join(target.path, id));
        if (!await from.exists()) continue;
        if (await to.exists()) {
          // Already migrated (interrupted run): drop the stale copy.
          await _delete(from);
          await _repoint(download, to.path, legacy.path, target.path);
          continue;
        }
        try {
          await from.rename(to.path);
        } catch (_) {
          // rename() fails across filesystems; fall back to copy + delete.
          try {
            await _copy(from, to);
            await _delete(from);
          } catch (_) {
            continue;
          }
        }
        await _repoint(download, to.path, legacy.path, target.path);
      }
      // Anything left under the legacy root (partials, orphans) is dead weight.
      if (await legacy.exists()) await _delete(legacy);
      notifyChanged();
    } catch (_) {
      // Migration is best-effort; never block app start.
    }
  }

  /// Rewrites a row's stored paths from the legacy root to the current one.
  static Future<void> _repoint(
    Map<String, dynamic> download,
    String newDir,
    String legacyRoot,
    String newRoot,
  ) async {
    final localPath = download['localPath']?.toString() ?? '';
    final suffix = p.join(p.basename(newDir), p.basename(localPath));
    await DBHelper.updateMediaDownloadPaths(
      downloadKey: download['downloadKey']?.toString() ?? '',
      localPath: p.join(newRoot, suffix),
      subtitles: (download['subtitles'] as List? ?? const [])
          .whereType<Map>()
          .map(
            (track) => track.map(
              (key, value) => MapEntry(
                key.toString(),
                key.toString() == 'url' && value is String
                    ? p.join(newRoot, p.basename(value))
                    : value,
              ),
            ),
          )
          .toList(),
      legacyRoot: legacyRoot,
    );
  }

  static Future<void> _delete(Directory dir) async {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }

  static Future<void> _copy(Directory from, Directory to) async {
    await to.create(recursive: true);
    await for (final entity in from.list(recursive: true, followLinks: false)) {
      final relative = p.relative(entity.path, from: from.path);
      if (entity is Directory) {
        await Directory(p.join(to.path, relative)).create(recursive: true);
      } else if (entity is File) {
        await entity.copy(p.join(to.path, relative));
      }
    }
  }
}
