import 'dart:io';

import 'package:flutter/material.dart';

import '../database/db_helper.dart';
import '../services/download_storage_service.dart';
import '../services/media_download_manager.dart';
import '../services/profile_scope.dart';
import '../screens/downloads_settings_screen.dart';
import '../screens/share/share_send_sheet.dart';
import '../widgets/app_network_image.dart';
import '../widgets/app_shimmer.dart';
import '../widgets/video_player_screen.dart';

class DownloadsScreen extends StatefulWidget {
  final bool embedded;
  const DownloadsScreen({super.key, this.embedded = false});

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  List<Map<String, dynamic>> _downloads = const [];
  /// Real on-disk bytes per download, measured when the list loads. The rows
  /// carry no size column and `localPath` is a few-KB playlist for HLS
  /// downloads, so nothing could be derived from the row itself.
  Map<String, int> _sizes = const {};
  bool _loading = true;
  final MediaDownloadManager _downloadManager = MediaDownloadManager.instance;
  late int _completionVersion;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _completionVersion = _downloadManager.completionVersion;
    _downloadManager.addListener(_handleDownloadManagerChanged);
    ProfileScope.activeProfile.addListener(_handleProfileChanged);
    // Sizes are measured from disk, so re-measure whenever a download finishes
    // or one is deleted — otherwise the numbers only changed after reopening
    // the screen.
    DownloadStorageService.revision.addListener(_handleDownloadsChanged);
    _loadDownloads();
  }

  @override
  void dispose() {
    _downloadManager.removeListener(_handleDownloadManagerChanged);
    ProfileScope.activeProfile.removeListener(_handleProfileChanged);
    DownloadStorageService.revision.removeListener(_handleDownloadsChanged);
    super.dispose();
  }

  void _handleProfileChanged() {
    _downloadManager.onProfileChanged();
    _loadDownloads();
  }

  void _handleDownloadsChanged() => _loadDownloads();

  void _handleDownloadManagerChanged() {
    if (_completionVersion != _downloadManager.completionVersion) {
      _completionVersion = _downloadManager.completionVersion;
      _loadDownloads();
    } else if (mounted) {
      setState(() {});
    }
  }

  Future<void> _loadDownloads() async {
    final generation = ++_loadGeneration;
    if (mounted) setState(() => _loading = true);
    final downloads = await DBHelper.getMediaDownloads();
    final existing = <Map<String, dynamic>>[];
    for (final download in downloads) {
      final path = download['localPath']?.toString() ?? '';
      // Check file exists, but also include downloads that are still active
      // (being downloaded) so they don't disappear from the list
      if (path.isNotEmpty &&
          (await File(path).exists() || _isStillDownloading(download))) {
        existing.add(download);
      }
    }
    final sizes = <String, int>{};
    for (final download in existing) {
      final key = download['downloadKey']?.toString() ?? '';
      final path = download['localPath']?.toString() ?? '';
      if (key.isEmpty || path.isEmpty) continue;
      sizes[key] = await DownloadStorageService.sizeOfDownload(path);
    }
    if (mounted && generation == _loadGeneration) {
      setState(() {
        _downloads = existing;
        _sizes = sizes;
        _loading = false;
      });
    }
  }

  /// On-disk bytes for one download row.
  int _sizeOf(Map<String, dynamic> download) =>
      _sizes[download['downloadKey']?.toString() ?? ''] ?? 0;

  bool _isStillDownloading(Map<String, dynamic> download) {
    final key = download['downloadKey']?.toString() ?? '';
    return _downloadManager.taskFor(key) != null;
  }

  Future<void> _play(Map<String, dynamic> download) async {
    final isMovie = download['mediaType'] == 'movie';
    final seriesId = download['seriesId']?.toString();
    final offlineEpisodes = isMovie
        ? const <Map<String, dynamic>>[]
        : _downloads
              .where(
                (item) =>
                    item['mediaType'] == 'episode' &&
                    item['seriesId']?.toString() == seriesId,
              )
              .map((item) => Map<String, dynamic>.from(item))
              .toList();
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => buildVideoPlayerScreen(
          title: download['title']?.toString() ?? 'Downloaded video',
          tmdbId: download['mediaId']?.toString() ?? '',
          isMovie: isMovie,
          season: (download['seasonNumber'] as num?)?.toInt() ?? 1,
          episode: (download['episodeNumber'] as num?)?.toInt() ?? 1,
          offlinePath: download['localPath']?.toString(),
          offlineSubtitles: (download['subtitles'] as List? ?? const [])
              .whereType<Map>()
              .map(
                (track) =>
                    track.map((key, value) => MapEntry(key.toString(), value)),
              )
              .toList(),
          offlineEpisodes: offlineEpisodes,
        ),
      ),
    );
  }

  Future<void> _delete(Map<String, dynamic> download) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete download?'),
        content: Text(
          '${download['title'] ?? 'This video'} will be removed from this device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    // DBHelper.deleteMediaDownload removes the download directory as well, so
    // the bytes (and the app's storage figure) actually go away.
    await DBHelper.deleteMediaDownload(download['downloadKey'].toString());
    await _loadDownloads();
  }

  void _pauseDownload(String downloadKey) {
    _downloadManager.pauseDownload(downloadKey);
  }

  void _resumeDownload(String downloadKey) {
    _downloadManager.resumeDownload(downloadKey);
  }

  Future<void> _cancelDownload(ActiveMediaDownload download) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel download?'),
        content: Text(
          '${download.label} and its partial files will be removed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Cancel download'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _downloadManager.cancelDownload(download.downloadKey);
    }
  }

  @override
  Widget build(BuildContext context) {
    final movies = _downloads
        .where((download) => download['mediaType'] == 'movie')
        .toList();
    final episodes = _downloads
        .where((download) => download['mediaType'] == 'episode')
        .toList();
    final series = <String, List<Map<String, dynamic>>>{};
    for (final episode in episodes) {
      final key =
          episode['seriesId']?.toString() ?? episode['mediaId'].toString();
      series.putIfAbsent(key, () => []).add(episode);
    }

    String totalSizeLabel(Iterable<int?> bytes) {
      final total = bytes.whereType<int>().fold<int>(0, (a, b) => a + b);
      if (total == 0) return '';
      return DownloadStorageService.formatBytes(total);
    }

    final activeTotal = totalSizeLabel(
      _downloadManager.activeDownloads.map((d) => d.totalBytes),
    );
    // Measured from disk, not from a column the table never had.
    final downloadedSize = totalSizeLabel(_downloads.map(_sizeOf));
    final downloadedMoviesSize = totalSizeLabel(movies.map(_sizeOf));
    final downloadedSeriesSize = totalSizeLabel(
      series.values.expand((episodes) => episodes).map(_sizeOf),
    );
    // The last download tile's delete button was rendering behind the system
    // nav bar and could not be tapped; pad the list by the raw inset so it can
    // always be scrolled clear of it.
    final listPadding = EdgeInsets.fromLTRB(
      16,
      16,
      16,
      16 + MediaQuery.viewPaddingOf(context).bottom,
    );

    final body = _loading && _downloadManager.activeDownloads.isEmpty
        ? AppShimmer(
            baseColor: Colors.grey[800]!,
            highlightColor: Colors.grey[600]!,
            child: ListView.builder(
              padding: listPadding,
              itemCount: 3,
              itemBuilder: (_, __) => Container(
                height: 88,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          )
        : _downloads.isEmpty && _downloadManager.activeDownloads.isEmpty
        ? const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.download_done, size: 64, color: Colors.white38),
                SizedBox(height: 16),
                Text(
                  'No downloads yet',
                  style: TextStyle(color: Colors.white, fontSize: 20),
                ),
                SizedBox(height: 6),
                Text(
                  'Tap the download button on a movie or series details page.',
                  style: TextStyle(color: Colors.white54),
                ),
              ],
            ),
          )
        : RefreshIndicator(
            onRefresh: _loadDownloads,
            child: ListView(
              padding: listPadding,
              children: [
                _buildProfileIndicator(),
                if (_downloadManager.activeDownloads.isNotEmpty) ...[
                  _sectionTitle(
                    'Downloading${activeTotal.isNotEmpty ? ' • $activeTotal' : ''}',
                    _downloadManager.activeDownloads.length,
                  ),
                  ..._downloadManager.activeDownloads.map(_activeDownloadTile),
                  const SizedBox(height: 20),
                ],
                if (_downloads.isNotEmpty)
                  _sectionTitle(
                    'Downloaded${downloadedSize.isNotEmpty ? ' • $downloadedSize' : ''}',
                    _downloads.length,
                  ),
                if (movies.isNotEmpty) ...[
                  _subsectionTitle(
                    'Movies${downloadedMoviesSize.isNotEmpty ? ' • $downloadedMoviesSize' : ''}',
                  ),
                  ...movies.map(_downloadTile),
                  const SizedBox(height: 20),
                ],
                if (series.isNotEmpty) ...[
                  _subsectionTitle(
                    'Series${downloadedSeriesSize.isNotEmpty ? ' • $downloadedSeriesSize' : ''}',
                  ),
                  ...series.values.map(_seriesGroup),
                ],
              ],
            ),
          );

    if (widget.embedded) {
      return RefreshIndicator(onRefresh: _loadDownloads, child: body);
    }

    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('Downloads'),
        actions: [
          IconButton(
            tooltip: 'Download Settings',
            onPressed: () {
              if (!mounted) return;
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const DownloadsSettingsScreen(),
                ),
              );
            },
            icon: const Icon(Icons.settings),
          ),
          IconButton(
            tooltip: 'Receive from another device',
            onPressed: () => openShareReceiver(context),
            icon: const Icon(Icons.download_outlined),
          ),
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loadDownloads,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: body,
    );
  }

  Widget _sectionTitle(String title, int count) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(
        '$title ($count)',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 20,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _subsectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 8),
      child: Text(
        title,
        style: const TextStyle(
          color: Colors.white70,
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _activeDownloadTile(ActiveMediaDownload download) {
    final percent = (download.progress * 100).round().clamp(0, 100);
    final isPaused = download.isPaused;
    return Card(
      color: const Color(0xFF1E1E1E),
      child: ListTile(
        leading: _thumbnail(download.thumbnail),
        title: Text(
          download.label,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: LinearProgressIndicator(
                      value: download.progress,
                      minHeight: 5,
                      color: isPaused ? Colors.orange : Colors.red,
                      backgroundColor: Colors.white24,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '$percent%',
                    style: const TextStyle(color: Colors.white70),
                  ),
                ],
              ),
              const SizedBox(height: 5),
              Text(
                isPaused
                    ? 'Paused — ${download.sizeLabel}'
                    : download.sizeLabel,
                style: TextStyle(
                  color: isPaused ? Colors.orange : Colors.white54,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isPaused)
              IconButton(
                tooltip: 'Resume download',
                onPressed: () => _resumeDownload(download.downloadKey),
                icon: const Icon(Icons.play_arrow_rounded, color: Colors.green),
              )
            else
              IconButton(
                tooltip: 'Pause download',
                onPressed: () => _pauseDownload(download.downloadKey),
                icon: const Icon(Icons.pause_rounded, color: Colors.orange),
              ),
            IconButton(
              tooltip: 'Cancel download',
              onPressed: () => _cancelDownload(download),
              icon: const Icon(Icons.close_rounded, color: Colors.redAccent),
            ),
          ],
        ),
      ),
    );
  }

  Widget _seriesGroup(List<Map<String, dynamic>> episodes) {
    episodes.sort((a, b) {
      final season = ((a['seasonNumber'] as num?)?.toInt() ?? 0).compareTo(
        (b['seasonNumber'] as num?)?.toInt() ?? 0,
      );
      return season != 0
          ? season
          : ((a['episodeNumber'] as num?)?.toInt() ?? 0).compareTo(
              (b['episodeNumber'] as num?)?.toInt() ?? 0,
            );
    });
    final first = episodes.first;
    final title = first['title']?.toString().split(' - S').first ?? 'Series';
    // Total size for this series (sum of local files + active downloads for its episodes)
    String seriesTotal() {
      // Measured from disk (see _sizeOf): an HLS episode's localPath is the
      // playlist, so summing those files reported ~3 KB per season.
      var total = 0;
      for (final ep in episodes) {
        total += _sizeOf(ep);
      }
      // Add active downloads for this series if any
      final sid = first['seriesId']?.toString() ?? first['mediaId'].toString();
      for (final d in _downloadManager.activeDownloads) {
        if (d.seriesId?.toString() == sid && d.totalBytes != null)
          total += d.totalBytes!;
      }
      if (total == 0) return '';
      return ' • ${DownloadStorageService.formatBytes(total)}';
    }

    final seasons = <int, List<Map<String, dynamic>>>{};
    for (final episode in episodes) {
      final season = (episode['seasonNumber'] as num?)?.toInt() ?? 1;
      seasons.putIfAbsent(season, () => []).add(episode);
    }
    return Card(
      color: const Color(0xFF1E1E1E),
      child: ExpansionTile(
        leading: _thumbnail(first['thumbnail']?.toString() ?? ''),
        title: Text(title, style: const TextStyle(color: Colors.white)),
        subtitle: Text(
          '${episodes.length} downloaded episode${episodes.length == 1 ? '' : 's'}${seriesTotal()}',
          style: const TextStyle(color: Colors.white54),
        ),
        iconColor: Colors.white,
        collapsedIconColor: Colors.white70,
        trailing: IconButton(
          tooltip: 'Send series to another device',
          onPressed: () => _share(List.of(episodes), title),
          icon: const Icon(Icons.send_outlined, color: Colors.white70),
        ),
        children: seasons.entries.map((entry) {
          return ExpansionTile(
            title: Text(
              'Season ${entry.key}',
              style: const TextStyle(color: Colors.white70),
            ),
            iconColor: Colors.white,
            collapsedIconColor: Colors.white70,
            children: entry.value.map(_downloadTile).toList(),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildProfileIndicator() {
    final profile = ProfileScope.activeProfile.value;
    final isKids = ProfileScope.isKidsProfile;
    final profileName = ProfileScope.currentProfileName;

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: isKids
            ? const Color(0xFF132A42).withValues(alpha: 0.6)
            : Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isKids
              ? const Color(0xFF10B981).withValues(alpha: 0.3)
              : Colors.white.withValues(alpha: 0.1),
          width: 1,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: isKids
                  ? const Color(0xFF10B981)
                  : (profile?.avatar.color ?? Colors.red),
              shape: BoxShape.circle,
            ),
            child: Icon(
              profile?.avatar.icon ?? Icons.person,
              color: Colors.white,
              size: 18,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  profileName,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (isKids)
                  const Text(
                    'Kids Profile',
                    style: TextStyle(
                      color: Color(0xFF10B981),
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
              ],
            ),
          ),
          Text(
            '${_downloads.length} downloads',
            style: TextStyle(color: Colors.grey[500], fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _downloadTile(Map<String, dynamic> download) {
    final isEpisode = download['mediaType'] == 'episode';
    final episodeLabel = isEpisode
        ? 'S${download['seasonNumber']}E${download['episodeNumber']}'
        : 'Movie';
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      leading: _thumbnail(download['thumbnail']?.toString() ?? ''),
      title: Text(
        download['title']?.toString() ?? 'Downloaded video',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.white),
      ),
      subtitle: Builder(
        builder: (context) {
          final size = _sizeOf(download);
          return Text(
            size > 0
                ? '$episodeLabel • ${DownloadStorageService.formatBytes(size)}'
                : episodeLabel,
            style: const TextStyle(color: Colors.white54),
          );
        },
      ),
      onTap: () => _play(download),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Send to another device',
            onPressed: () => _share([download], download['title']?.toString()),
            icon: const Icon(Icons.send_outlined, color: Colors.white70),
          ),
          IconButton(
            tooltip: 'Delete download',
            onPressed: () => _delete(download),
            icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
          ),
        ],
      ),
    );
  }

  /// Opens the device-to-device send sheet for [downloads].
  void _share(List<Map<String, dynamic>> downloads, String? title) {
    showShareSendSheet(context, downloads: downloads, title: title);
  }

  Widget _thumbnail(String url) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: 54,
        height: 70,
        child: url.isEmpty
            ? const ColoredBox(
                color: Colors.black38,
                child: Icon(Icons.movie, color: Colors.white38),
              )
            : AppNetworkImage(
                url: url,
                fit: BoxFit.cover,
                errorWidget: const ColoredBox(
                  color: Colors.black38,
                  child: Icon(Icons.movie, color: Colors.white38),
                ),
              ),
      ),
    );
  }
}
