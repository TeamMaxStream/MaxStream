import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../database/db_helper.dart';
import 'direct_m3u8_service.dart';
import 'download_service_bridge.dart';
import 'downloads_settings_service.dart';
import 'stream_size_probe.dart';
import 'media_download_service.dart';
import 'notification_service.dart';
import 'profile_scope.dart';
import 'stream_security.dart';

class ActiveMediaDownload {
  const ActiveMediaDownload({
    required this.downloadKey,
    required this.title,
    required this.label,
    required this.thumbnail,
    required this.progress,
    required this.downloadedBytes,
    required this.totalBytes,
    required this.isPaused,
    this.expectedTotalBytes,
    this.service,
    this.url,
    this.headers = const {},
    this.isHls = false,
    this.mediaId = '',
    this.isMovie = false,
    this.resolverTitle = '',
    this.seriesId,
    this.seasonNumber,
    this.episodeNumber,
    this.subtitles = const [],
  });

  final String downloadKey;
  final String title;
  final String label;
  final String thumbnail;
  final double progress;
  final int downloadedBytes;
  final int? totalBytes;

  /// Size measured before the download started, for streams whose length is not
  /// knowable up front (every HLS master). Without it the progress line could
  /// only ever say "10.0 MB downloaded" — the "10 MB / 170 MB" form needs a
  /// total, and HLS only reveals one after the fact.
  final int? expectedTotalBytes;
  final bool isPaused;
  final MediaDownloadService? service;
  final String? url;
  final Map<String, String> headers;
  final bool isHls;
  final String mediaId;
  final bool isMovie;
  final String resolverTitle;
  final String? seriesId;
  final int? seasonNumber;
  final int? episodeNumber;
  final List<Map<String, dynamic>> subtitles;

  ActiveMediaDownload copyWith({
    double? progress,
    int? downloadedBytes,
    int? totalBytes,
    int? expectedTotalBytes,
    MediaDownloadService? service,
    bool clearService = false,
    bool? isPaused,
    String? url,
    Map<String, String>? headers,
    bool? isHls,
    List<Map<String, dynamic>>? subtitles,
  }) => ActiveMediaDownload(
    downloadKey: downloadKey,
    title: title,
    label: label,
    thumbnail: thumbnail,
    progress: progress ?? this.progress,
    downloadedBytes: downloadedBytes ?? this.downloadedBytes,
    totalBytes: totalBytes ?? this.totalBytes,
    expectedTotalBytes: expectedTotalBytes ?? this.expectedTotalBytes,
    service: clearService ? null : service ?? this.service,
    isPaused: isPaused ?? this.isPaused,
    url: url ?? this.url,
    headers: headers ?? this.headers,
    isHls: isHls ?? this.isHls,
    mediaId: mediaId,
    isMovie: isMovie,
    resolverTitle: resolverTitle,
    seriesId: seriesId,
    seasonNumber: seasonNumber,
    episodeNumber: episodeNumber,
    subtitles: subtitles ?? this.subtitles,
  );

  /// "10.0 MB / 170.0 MB", falling back to the size measured before the
  /// download started when the server never reports a total.
  String get sizeLabel {
    final downloaded = _formatBytes(downloadedBytes);
    final total = totalBytes ?? expectedTotalBytes;
    return total == null
        ? '$downloaded downloaded'
        : '$downloaded / ${_formatBytes(total)}';
  }

  static String _formatBytes(int bytes) {
    const mb = 1024 * 1024;
    const gb = 1024 * mb;
    if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(2)} GB';
    return '${(bytes / mb).toStringAsFixed(1)} MB';
  }

  Map<String, dynamic> toJson() => {
    'downloadKey': downloadKey,
    'title': title,
    'label': label,
    'thumbnail': thumbnail,
    'progress': progress,
    'downloadedBytes': downloadedBytes,
    'totalBytes': totalBytes,
    'expectedTotalBytes': expectedTotalBytes,
    'url': url,
    'headers': headers,
    'isHls': isHls,
    'mediaId': mediaId,
    'isMovie': isMovie,
    'resolverTitle': resolverTitle,
    'seriesId': seriesId,
    'seasonNumber': seasonNumber,
    'episodeNumber': episodeNumber,
    'subtitles': subtitles,
  };

  factory ActiveMediaDownload.fromJson(Map<String, dynamic> json) {
    return ActiveMediaDownload(
      downloadKey: json['downloadKey']?.toString() ?? '',
      title: json['title']?.toString() ?? 'Download',
      label: json['label']?.toString() ?? 'Download',
      thumbnail: json['thumbnail']?.toString() ?? '',
      progress: (json['progress'] as num?)?.toDouble() ?? 0,
      downloadedBytes: (json['downloadedBytes'] as num?)?.toInt() ?? 0,
      totalBytes: (json['totalBytes'] as num?)?.toInt(),
      expectedTotalBytes: (json['expectedTotalBytes'] as num?)?.toInt(),
      isPaused: true,
      url: json['url']?.toString(),
      headers: StreamSecurity.sanitizeHeaders(json['headers'] as Map?),
      isHls: json['isHls'] == true,
      mediaId: json['mediaId']?.toString() ?? '',
      isMovie: json['isMovie'] == true,
      resolverTitle: json['resolverTitle']?.toString() ?? '',
      seriesId: json['seriesId']?.toString(),
      seasonNumber: (json['seasonNumber'] as num?)?.toInt(),
      episodeNumber: (json['episodeNumber'] as num?)?.toInt(),
      subtitles: (json['subtitles'] as List? ?? const [])
          .whereType<Map>()
          .map(
            (item) => item.map((key, value) => MapEntry(key.toString(), value)),
          )
          .toList(),
    );
  }
}

class MediaDownloadManager extends ChangeNotifier {
  MediaDownloadManager._();

  static final MediaDownloadManager instance = MediaDownloadManager._();
  static const _pendingDownloadsKeyPrefix = 'pending_media_downloads_';
  static const int maxSubtitleBytes = 5 * 1024 * 1024;

  static String get _pendingDownloadsKey =>
      '$_pendingDownloadsKeyPrefix${ProfileScope.currentProfileId}';

  final Map<String, ActiveMediaDownload> _active = {};
  int _completionVersion = 0;
  bool _initialized = false;

  List<ActiveMediaDownload> get activeDownloads =>
      List.unmodifiable(_active.values);
  int get completionVersion => _completionVersion;

  ActiveMediaDownload? taskFor(String downloadKey) => _active[downloadKey];

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    await _loadPendingDownloads();
  }

  Future<void> _loadPendingDownloads() async {
    final preferences = await SharedPreferences.getInstance();
    final encoded = preferences.getString(_pendingDownloadsKey);
    if (encoded == null || encoded.isEmpty) {
      _active.clear();
      notifyListeners();
      return;
    }
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! List) throw const FormatException('Invalid downloads');
      final pending = decoded;
      _active.clear();
      for (final value in pending.whereType<Map>()) {
        final task = ActiveMediaDownload.fromJson(
          value.map((key, value) => MapEntry(key.toString(), value)),
        );
        if (task.downloadKey.isNotEmpty &&
            StreamSecurity.isSafeNetworkUrl(task.url)) {
          _active[task.downloadKey] = task;
        }
      }
      notifyListeners();
    } on FormatException {
      await preferences.remove(_pendingDownloadsKey);
    }
  }

  Future<void> onProfileChanged() async {
    _initialized = false;
    _active.clear();
    _initialized = true;
    await DownloadsSettingsService.refreshCache();
    await _loadPendingDownloads();
    _completionVersion++;
    notifyListeners();
  }

  Future<void> _persistActiveDownloads() async {
    final preferences = await SharedPreferences.getInstance();
    if (_active.isEmpty) {
      await preferences.remove(_pendingDownloadsKey);
      return;
    }
    await preferences.setString(
      _pendingDownloadsKey,
      jsonEncode(_active.values.map((task) => task.toJson()).toList()),
    );
  }

  void pauseDownload(String downloadKey) {
    final task = _active[downloadKey];
    if (task == null) return;
    task.service?.pause();
    _active[downloadKey] = task.copyWith(isPaused: true);
    notifyListeners();
    unawaited(_persistActiveDownloads());
    unawaited(_updateOrStopForegroundService());
  }

  void resumeDownload(String downloadKey) {
    unawaited(_resumeDownload(downloadKey));
  }

  Future<void> _resumeDownload(String downloadKey) async {
    final task = _active[downloadKey];
    if (task == null || task.url == null) return;

    _active[downloadKey] = task.copyWith(isPaused: false);
    notifyListeners();
    unawaited(_persistActiveDownloads());

    final service = task.service;
    if (service != null) {
      service.resume();
      await _ensureForegroundService();
    } else {
      try {
        final refreshed = await _refreshStream(task);
        if (!_active.containsKey(downloadKey)) return;
        _active[downloadKey] = refreshed;
        notifyListeners();
        await _persistActiveDownloads();
        await _restartDownload(refreshed);
      } catch (error) {
        final current = _active[downloadKey];
        if (current == null) return;
        _active[downloadKey] = current.copyWith(isPaused: true);
        notifyListeners();
        await _persistActiveDownloads();
        await _updateOrStopForegroundService();
        await NotificationService().showDownloadFinished(
          id: downloadKey.hashCode & 0x7fffffff,
          label: task.label,
          error: 'Could not refresh stream — $error',
        );
      }
    }
  }

  Future<ActiveMediaDownload> _refreshStream(ActiveMediaDownload task) async {
    final stream = task.isMovie
        ? await DirectM3u8Service.fetchMovieStreamUrl(
            task.resolverTitle.isEmpty ? task.title : task.resolverTitle,
            null,
            task.mediaId,
          )
        : await DirectM3u8Service.fetchSeriesStreamUrl(
            task.resolverTitle.isEmpty ? task.title : task.resolverTitle,
            task.seasonNumber ?? 1,
            task.episodeNumber ?? 1,
            task.mediaId,
          );
    final url = stream?['url']?.toString() ?? '';
    if (stream == null || url.isEmpty) {
      throw StateError('No fresh downloadable stream was found');
    }
    final headers = <String, String>{};
    if (stream['referer'] != null) {
      headers['Referer'] = stream['referer'].toString();
    }
    if (stream['headers'] is Map) {
      (stream['headers'] as Map).forEach((key, value) {
        headers[key.toString()] = value.toString();
      });
    }
    return task.copyWith(
      clearService: true,
      isPaused: false,
      url: url,
      headers: headers,
      isHls:
          stream['type'] == 'direct_m3u8' ||
          url.toLowerCase().contains('.m3u8'),
      subtitles: (stream['subtitles'] as List? ?? const [])
          .whereType<Map>()
          .map(
            (track) =>
                track.map((key, value) => MapEntry(key.toString(), value)),
          )
          .toList(),
    );
  }

  Future<void> cancelDownload(String downloadKey) async {
    final task = _active.remove(downloadKey);
    if (task == null) return;
    task.service?.cancel();
    notifyListeners();
    await _persistActiveDownloads();
    await _updateOrStopForegroundService();
    final cleanup = MediaDownloadService();
    try {
      await cleanup.discard(downloadKey);
    } on FileSystemException {
      // The running transfer also removes its partial directory on cancellation.
    } finally {
      cleanup.dispose();
    }
    DBHelper.notifyDownloadsChanged();
  }

  Future<void> _restartDownload(ActiveMediaDownload task) async {
    final service = MediaDownloadService();
    _active[task.downloadKey] = _active[task.downloadKey]!.copyWith(
      service: service,
    );
    notifyListeners();

    await _ensureForegroundService();

    final notificationId = task.downloadKey.hashCode & 0x7fffffff;
    var lastNotificationProgress = -1;

    try {
      final result = await service.download(
        url: task.url!,
        headers: task.headers,
        downloadId: task.downloadKey,
        hls: task.isHls,
        onProgress: (progress) {
          _active[task.downloadKey] = _active[task.downloadKey]!.copyWith(
            progress: progress,
          );
          notifyListeners();
          final percent = (progress * 100).round().clamp(0, 100);
          if (percent != lastNotificationProgress) {
            lastNotificationProgress = percent;
            unawaited(_persistActiveDownloads());
            unawaited(
              NotificationService().showDownloadProgress(
                id: notificationId,
                title: task.isMovie
                    ? 'Downloading movie'
                    : 'Downloading episode',
                label: task.label,
                progress: percent,
                size: _active[task.downloadKey]!.sizeLabel,
              ),
            );
          }
        },
        onBytesProgress: (downloadedBytes, totalBytes) {
          _active[task.downloadKey] = _active[task.downloadKey]!.copyWith(
            downloadedBytes: downloadedBytes,
            totalBytes: totalBytes,
          );
          notifyListeners();
        },
      );
      final localSubtitles = await _downloadSubtitles(
        task.subtitles,
        File(result.localPath).parent,
        task.headers,
      );
      await DBHelper.insertMediaDownload(
        downloadKey: task.downloadKey,
        mediaId: task.mediaId,
        mediaType: task.isMovie ? 'movie' : 'episode',
        seriesId: task.seriesId,
        seasonNumber: task.seasonNumber,
        episodeNumber: task.episodeNumber,
        title: task.title,
        thumbnail: task.thumbnail,
        localPath: result.localPath,
        subtitles: localSubtitles,
      );
      // Storage figures are computed on demand from disk, so the Downloads and
      // Download Settings screens need to be told to re-measure.
      DBHelper.notifyDownloadsChanged();
      _completionVersion++;
      notifyListeners();
      await NotificationService().showDownloadFinished(
        id: notificationId,
        label: task.label,
      );
    } catch (error) {
      if (_active.containsKey(task.downloadKey)) {
        service.pause();
        service.dispose();
        _active[task.downloadKey] = _active[task.downloadKey]!.copyWith(
          isPaused: true,
          clearService: true,
        );
        notifyListeners();
        await _persistActiveDownloads();
        await _updateOrStopForegroundService();
        await NotificationService().showDownloadFinished(
          id: notificationId,
          label: task.label,
          error: 'Paused — ${error.toString()}',
        );
        return;
      }
    } finally {
      final current = _active[task.downloadKey];
      if (current != null && current.isPaused) {
        notifyListeners();
      } else {
        service.dispose();
        _active.remove(task.downloadKey);
        notifyListeners();
        await _persistActiveDownloads();
        await _updateOrStopForegroundService();
      }
    }
  }

  Future<bool> resolveAndStart({
    required String downloadKey,
    required String mediaId,
    required bool isMovie,
    required String title,
    required String thumbnail,
    String? resolverTitle,
    int seasonNumber = 1,
    int episodeNumber = 1,
    int? maxVariantHeightPixels,
  }) async {
    // Use quality setting from DownloadsSettingsService as default
    final effectiveMaxHeight =
        maxVariantHeightPixels ??
        DownloadsSettingsService.maxVariantHeightPixels;
    final lookupTitle = resolverTitle ?? title;
    final stream = isMovie
        ? await DirectM3u8Service.fetchMovieStreamUrl(
            lookupTitle,
            null,
            mediaId,
          )
        : await DirectM3u8Service.fetchSeriesStreamUrl(
            lookupTitle,
            seasonNumber,
            episodeNumber,
            mediaId,
          );
    final url = stream?['url']?.toString() ?? '';
    if (stream == null || url.isEmpty) return false;
    final headers = <String, String>{};
    if (stream['referer'] != null) {
      headers['Referer'] = stream['referer'].toString();
    }
    if (stream['headers'] is Map) {
      (stream['headers'] as Map).forEach((key, value) {
        headers[key.toString()] = value.toString();
      });
    }
    final isHlsUrl =
        stream['type'] == 'direct_m3u8' || url.toLowerCase().contains('.m3u8');
    final expectedTotal = await _measureExpectedTotal(
      url,
      headers,
      height: effectiveMaxHeight,
    );
    await start(
      downloadKey: downloadKey,
      url: url,
      headers: headers,
      isHls: isHlsUrl,
      mediaId: mediaId,
      isMovie: isMovie,
      title: title,
      resolverTitle: lookupTitle,
      thumbnail: thumbnail,
      seriesId: isMovie ? null : mediaId,
      seasonNumber: isMovie ? null : seasonNumber,
      episodeNumber: isMovie ? null : episodeNumber,
      maxVariantHeightPixels: effectiveMaxHeight,
      expectedTotalBytes: expectedTotal,
      subtitles: (stream['subtitles'] as List? ?? const [])
          .whereType<Map>()
          .map(
            (track) =>
                track.map((key, value) => MapEntry(key.toString(), value)),
          )
          .toList(),
    );
    return true;
  }

  // --- Season batch download ---
  bool _seasonDownloading = false;
  String? _seasonDownloadKey;
  int _seasonTotal = 0;
  int _seasonCurrent = 0;
  int _seasonCompleted = 0;
  String _seasonStatus = '';

  bool get seasonDownloading => _seasonDownloading;
  String? get seasonDownloadKey => _seasonDownloadKey;
  int get seasonDownloadTotal => _seasonTotal;
  int get seasonDownloadCurrent => _seasonCurrent;
  int get seasonDownloadCompleted => _seasonCompleted;
  String get seasonDownloadStatus => _seasonStatus;

  bool isSeasonDownloadActive(String seasonKey) =>
      _seasonDownloading && _seasonDownloadKey == seasonKey;

  /// Downloads a whole season one episode at a time. Lives on the manager
  /// (not a screen) so it keeps going while the UI navigates away and the
  /// progress bar can be rendered from any screen.
  Future<void> downloadSeason({
    required String seasonKey,
    required String seriesId,
    required String tmdbId,
    required String title,
    required String thumbnail,
    required int seasonNumber,
    required List<Map<String, dynamic>> episodes,
    String? preferredServer,
    bool lowestQuality = true,
  }) async {
    if (_seasonDownloading) return;
    final alreadyDownloaded = <String>{};
    try {
      for (final download in await DBHelper.getMediaDownloads()) {
        final key = download['downloadKey']?.toString() ?? '';
        if (key.isNotEmpty) alreadyDownloaded.add(key);
      }
    } catch (_) {}

    _seasonDownloading = true;
    _seasonDownloadKey = seasonKey;
    _seasonTotal = episodes.length;
    _seasonCurrent = 0;
    _seasonCompleted = 0;
    _seasonStatus = 'Preparing...';
    notifyListeners();

    var completed = 0;
    try {
      for (final episode in episodes) {
        if (!_seasonDownloading) break;
        final episodeNumber =
            (episode['episodeNumber'] as num?)?.toInt() ??
            (episode['number'] as num?)?.toInt() ??
            1;
        final episodeName = episode['name']?.toString() ?? '';
        final stillPath = episode['stillPath']?.toString() ?? '';
        final downloadKey =
            'series_${seriesId}_s${seasonNumber}_e$episodeNumber';
        _seasonCurrent++;
        if (alreadyDownloaded.contains(downloadKey) ||
            _active.containsKey(downloadKey)) {
          completed++;
          _seasonCompleted = completed;
          _seasonStatus = 'S${seasonNumber}E$episodeNumber already downloaded';
          notifyListeners();
          continue;
        }
        final label =
            '$title - S${seasonNumber}E$episodeNumber'
            '${episodeName.isEmpty ? '' : ': $episodeName'}';
        _seasonStatus =
            'Resolving S${seasonNumber}E$episodeNumber'
            '${episodeName.isEmpty ? '' : ': $episodeName'}';
        notifyListeners();
        final ok = await _downloadSeasonEpisode(
          downloadKey: downloadKey,
          seriesId: seriesId,
          tmdbId: tmdbId,
          title: title,
          label: label,
          thumbnail: stillPath.isNotEmpty
              ? 'https://image.tmdb.org/t/p/w500$stillPath'
              : thumbnail,
          seasonNumber: seasonNumber,
          episodeNumber: episodeNumber,
          preferredServer: preferredServer,
          lowestQuality: lowestQuality,
        );
        if (!_seasonDownloading) break;
        if (ok) completed++;
        _seasonCompleted = completed;
        _seasonStatus = ok
            ? 'S${seasonNumber}E$episodeNumber complete'
            : 'S${seasonNumber}E$episodeNumber failed, continuing...';
        notifyListeners();
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    } finally {
      _seasonDownloading = false;
      _seasonDownloadKey = null;
      _seasonTotal = 0;
      _seasonCurrent = 0;
      _seasonCompleted = 0;
      _seasonStatus = '';
      notifyListeners();
    }
  }

  Future<bool> _downloadSeasonEpisode({
    required String downloadKey,
    required String seriesId,
    required String tmdbId,
    required String title,
    required String label,
    required String thumbnail,
    required int seasonNumber,
    required int episodeNumber,
    String? preferredServer,
    bool lowestQuality = true,
  }) async {
    try {
      final streams = await DirectM3u8Service.fetchAvailableStreams(
        title: title,
        tmdbId: tmdbId,
        isMovie: false,
        season: seasonNumber,
        episode: episodeNumber,
      );
      final selected = _selectSeasonServer(
        streams,
        preferredServer: preferredServer,
      );
      final masterUrl = selected?['url']?.toString() ?? '';
      if (masterUrl.isNotEmpty) {
        final headers = <String, String>{};
        if (selected!['referer'] != null) {
          headers['Referer'] = selected['referer'].toString();
        }
        if (selected['headers'] is Map) {
          (selected['headers'] as Map).forEach((key, value) {
            headers[key.toString()] = value.toString();
          });
        }
        final maxHeight = lowestQuality
            ? _lowestVariantHeight(selected['qualities'])
            : null;
        final expectedTotal = await _measureExpectedTotal(
          masterUrl,
          headers,
        );
        await start(
          downloadKey: downloadKey,
          url: masterUrl,
          headers: headers,
          isHls:
              selected['type'] == 'direct_m3u8' ||
              masterUrl.toLowerCase().contains('.m3u8'),
          mediaId: tmdbId,
          isMovie: false,
          title: label,
          resolverTitle: title,
          thumbnail: thumbnail,
          seriesId: seriesId,
          seasonNumber: seasonNumber,
          episodeNumber: episodeNumber,
          maxVariantHeightPixels: maxHeight,
          expectedTotalBytes: expectedTotal,
          subtitles: (selected['subtitles'] as List? ?? const [])
              .whereType<Map>()
              .map(
                (track) =>
                    track.map((key, value) => MapEntry(key.toString(), value)),
              )
              .toList(),
        );
        return true;
      }
      return await resolveAndStart(
        downloadKey: downloadKey,
        mediaId: tmdbId,
        isMovie: false,
        resolverTitle: title,
        title: label,
        thumbnail: thumbnail,
        seasonNumber: seasonNumber,
        episodeNumber: episodeNumber,
      );
    } catch (_) {
      return false;
    }
  }

  /// Picks the server for a whole-season batch: the requested one if it is
  /// available, otherwise the first working server (never a failed one).
  Map<String, dynamic>? _selectSeasonServer(
    List<Map<String, dynamic>> streams, {
    String? preferredServer,
  }) {
    final available = streams
        .where((stream) => (stream['url']?.toString() ?? '').isNotEmpty)
        .toList();
    if (available.isEmpty) return null;
    if (preferredServer != null && preferredServer.isNotEmpty) {
      for (final stream in available) {
        final identity =
            stream['server']?.toString() ?? stream['source']?.toString() ?? '';
        if (identity == preferredServer) return stream;
      }
    }
    return available.first;
  }

  /// Measures the chosen stream up front so the progress line can read
  /// "10.0 MB / 170.0 MB" from the first tick instead of only ever reporting
  /// bytes downloaded. Best-effort: a host that will not answer just leaves the
  /// total unknown.
  Future<int?> _measureExpectedTotal(
    String url,
    Map<String, String> headers, {
    int? height,
  }) async {
    try {
      return await StreamSizeProbe.probe(url, headers: headers, height: height);
    } catch (_) {
      return null;
    }
  }

  int? _lowestVariantHeight(dynamic qualities) {
    if (qualities is! List) return null;
    int? lowest;
    for (final raw in qualities) {
      if (raw is! Map) continue;
      final height = int.tryParse(raw['height']?.toString() ?? '') ?? 0;
      if (height > 0 && (lowest == null || height < lowest)) {
        lowest = height;
      }
    }
    return lowest;
  }

  Future<void> _ensureForegroundService() async {
    final running = _active.values.where((task) => !task.isPaused).toList();
    if (running.isEmpty) return;
    await WakelockPlus.enable();
    await DownloadServiceBridge.startForegroundService(
      downloadCount: running.length,
      title: running.first.title,
    );
  }

  Future<void> _updateOrStopForegroundService() async {
    final running = _active.values.where((task) => !task.isPaused).toList();
    if (running.isEmpty) {
      await DownloadServiceBridge.stopForegroundService();
      await WakelockPlus.disable();
    } else {
      await DownloadServiceBridge.startForegroundService(
        downloadCount: running.length,
        title: running.first.title,
      );
    }
  }

  Future<void> start({
    required String downloadKey,
    required String url,
    required Map<String, String> headers,
    required bool isHls,
    required String mediaId,
    required bool isMovie,
    required String title,
    String? resolverTitle,
    required String thumbnail,
    String? seriesId,
    int? seasonNumber,
    int? episodeNumber,
    List<Map<String, dynamic>> subtitles = const [],
    int? maxVariantHeightPixels,
    int? expectedTotalBytes,
  }) async {
    if (_active.containsKey(downloadKey)) return;
    if (!StreamSecurity.isSafeNetworkUrl(url)) {
      throw const FormatException('Unsafe media URL');
    }
    // Check storage limit
    final currentUsage = await DBHelper.getDownloadStorageUsage();
    if (DownloadsSettingsService.wouldExceedLimit(currentUsage, 0)) {
      throw StateError(
        'Storage limit reached (${DownloadsSettingsService.storageLimitGb.toInt()} GB). '
        'Go to Download Settings to adjust the limit or clear old downloads.',
      );
    }
    headers = StreamSecurity.sanitizeHeaders(headers);
    subtitles = subtitles
        .where((track) => StreamSecurity.isSafeNetworkUrl(track['url']))
        .toList();
    // "Auto" in the download sheet means "the Quality chosen in Download
    // Settings", not "the highest variant available" — resolveAndStart already
    // applied this, but the sheet starts downloads through start() directly.
    final effectiveMaxHeight =
        maxVariantHeightPixels ?? DownloadsSettingsService.maxVariantHeightPixels;
    final label = title;
    final notificationId = downloadKey.hashCode & 0x7fffffff;
    var lastNotificationProgress = -1;
    final service = MediaDownloadService();
    _active[downloadKey] = ActiveMediaDownload(
      downloadKey: downloadKey,
      title: title,
      label: label,
      thumbnail: thumbnail,
      progress: 0,
      downloadedBytes: 0,
      totalBytes: null,
      expectedTotalBytes: expectedTotalBytes,
      service: service,
      isPaused: false,
      url: url,
      headers: headers,
      isHls: isHls,
      mediaId: mediaId,
      isMovie: isMovie,
      resolverTitle: resolverTitle ?? title,
      seriesId: seriesId,
      seasonNumber: seasonNumber,
      episodeNumber: episodeNumber,
      subtitles: subtitles,
    );
    notifyListeners();
    await _persistActiveDownloads();

    // Start foreground service and wakelock when first download begins.
    await _ensureForegroundService();

    try {
      await NotificationService().showDownloadProgress(
        id: notificationId,
        title: isMovie ? 'Downloading movie' : 'Downloading episode',
        label: label,
        progress: 0,
      );
      final result = await service.download(
        url: url,
        headers: headers,
        downloadId: downloadKey,
        hls: isHls,
        maxVariantHeightPixels: effectiveMaxHeight,
        onProgress: (progress) {
          _active[downloadKey] = _active[downloadKey]!.copyWith(
            progress: progress,
          );
          notifyListeners();
          final percent = (progress * 100).round().clamp(0, 100);
          if (percent != lastNotificationProgress) {
            lastNotificationProgress = percent;
            unawaited(_persistActiveDownloads());
            unawaited(
              NotificationService().showDownloadProgress(
                id: notificationId,
                title: isMovie ? 'Downloading movie' : 'Downloading episode',
                label: label,
                progress: percent,
                size: _active[downloadKey]!.sizeLabel,
              ),
            );
          }
        },
        onBytesProgress: (downloadedBytes, totalBytes) {
          _active[downloadKey] = _active[downloadKey]!.copyWith(
            downloadedBytes: downloadedBytes,
            totalBytes: totalBytes,
          );
          notifyListeners();
        },
      );
      final localSubtitles = await _downloadSubtitles(
        subtitles,
        File(result.localPath).parent,
        headers,
      );
      await DBHelper.insertMediaDownload(
        downloadKey: downloadKey,
        mediaId: mediaId,
        mediaType: isMovie ? 'movie' : 'episode',
        seriesId: seriesId,
        seasonNumber: seasonNumber,
        episodeNumber: episodeNumber,
        title: title,
        thumbnail: thumbnail,
        localPath: result.localPath,
        subtitles: localSubtitles,
      );
      // Storage figures are computed on demand from disk, so the Downloads and
      // Download Settings screens need to be told to re-measure.
      DBHelper.notifyDownloadsChanged();
      _completionVersion++;
      notifyListeners();
      await NotificationService().showDownloadFinished(
        id: notificationId,
        label: label,
      );
    } catch (error) {
      if (_active.containsKey(downloadKey)) {
        service.pause();
        service.dispose();
        _active[downloadKey] = _active[downloadKey]!.copyWith(
          isPaused: true,
          clearService: true,
        );
        notifyListeners();
        await _persistActiveDownloads();
        await _updateOrStopForegroundService();
        await NotificationService().showDownloadFinished(
          id: notificationId,
          label: label,
          error: 'Paused — ${error.toString()}',
        );
        rethrow;
      }
    } finally {
      final task = _active[downloadKey];
      if (task != null && task.isPaused) {
        // Keep paused downloads in _active - don't dispose or remove
        notifyListeners();
      } else {
        service.dispose();
        _active.remove(downloadKey);
        notifyListeners();
        await _persistActiveDownloads();
        await _updateOrStopForegroundService();
      }
    }
  }

  Future<List<Map<String, dynamic>>> _downloadSubtitles(
    List<Map<String, dynamic>> tracks,
    Directory directory,
    Map<String, String> streamHeaders,
  ) async {
    final downloaded = <Map<String, dynamic>>[];
    for (var index = 0; index < tracks.length; index++) {
      final track = tracks[index];
      final rawUrl = track['url']?.toString() ?? '';
      final uri = Uri.tryParse(rawUrl);
      if (uri == null || !uri.hasScheme || uri.host.isEmpty) continue;
      try {
        final headers = <String, String>{
          if (track['source']?.toString() != 'Vidflix') ...streamHeaders,
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/124.0.0.0 Safari/537.36',
          'Accept': 'text/vtt, application/x-subrip, text/plain, */*',
        };
        final response = await http
            .get(uri, headers: headers)
            .timeout(const Duration(seconds: 15));
        if (response.statusCode < 200 ||
            response.statusCode >= 300 ||
            response.bodyBytes.isEmpty ||
            response.bodyBytes.length > maxSubtitleBytes ||
            (response.contentLength != null &&
                response.contentLength! > maxSubtitleBytes)) {
          continue;
        }

        final text = utf8.decode(response.bodyBytes, allowMalformed: true);
        var extension = p.extension(uri.path).toLowerCase();
        List<int> bytes = response.bodyBytes;

        if (text.trimLeft().startsWith('#EXTM3U')) {
          // HLS subtitle playlist (e.g. VixSrc vixsrc.to/playlist/...type=subtitle).
          // Resolve every referenced segment and merge them into a single
          // valid WEBVTT file, otherwise the local file would be an .m3u8 and
          // fail to parse with "no valid timed cues".
          final merged = await _mergeHlsSubtitlePlaylist(uri, headers);
          if (merged.isEmpty) continue;
          extension = '.vtt';
          bytes = utf8.encode(merged);
        } else if (!{
          '.vtt',
          '.srt',
          '.ass',
          '.ssa',
          '.ttml',
          '.xml',
          '.json',
        }.contains(extension)) {
          extension = _sniffSubtitleExtension(text);
        }
        final file = File(p.join(directory.path, 'subtitle_$index$extension'));
        await file.writeAsBytes(bytes, flush: true);
        downloaded.add({
          'label': track['label']?.toString() ?? 'Subtitle ${index + 1}',
          'url': file.path,
          'default': track['default'] == true,
          'source': 'Downloaded',
        });
      } catch (_) {
        // A broken subtitle must not fail the video download.
      }
    }
    return downloaded;
  }

  /// Downloads every segment referenced in an HLS subtitle playlist and
  /// merges them into one WEBVTT document. Returns '' if nothing usable.
  Future<String> _mergeHlsSubtitlePlaylist(
    Uri playlistUri,
    Map<String, String> requestHeaders,
  ) async {
    final headers = <String, String>{
      ...requestHeaders,
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/124.0.0.0 Safari/537.36',
      'Accept': '*/*',
    };
    final playlistResponse = await http
        .get(playlistUri, headers: headers)
        .timeout(const Duration(seconds: 15));
    if (playlistResponse.statusCode < 200 ||
        playlistResponse.statusCode >= 300) {
      return '';
    }
    final parts = <String>[];
    for (final line in const LineSplitter().convert(
      utf8.decode(playlistResponse.bodyBytes, allowMalformed: true),
    )) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      final segmentUri = playlistUri.resolve(trimmed);
      final segmentResponse = await http
          .get(segmentUri, headers: headers)
          .timeout(const Duration(seconds: 30));
      if (segmentResponse.statusCode < 200 ||
          segmentResponse.statusCode >= 300) {
        continue;
      }
      final cueText = utf8
          .decode(segmentResponse.bodyBytes, allowMalformed: true)
          .trim();
      if (cueText.isEmpty) continue;
      if (cueText.startsWith('WEBVTT')) {
        parts.add(
          cueText.replaceFirst(RegExp('^WEBVTT.*\$', multiLine: true), ''),
        );
      } else {
        parts.add(cueText);
      }
    }
    if (parts.isEmpty) return '';
    return 'WEBVTT\n\n${parts.join('\n\n')}\n';
  }

  String _sniffSubtitleExtension(String text) {
    final trimmed = text.trimLeft();
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) return '.json';
    if (trimmed.contains('[Script Info]') || trimmed.contains('[V4')) {
      return '.ass';
    }
    if (trimmed.startsWith('<')) return '.ttml';
    return '.vtt';
  }
}
