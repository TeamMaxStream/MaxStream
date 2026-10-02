import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';
import '../database/db_helper.dart';
import '../services/cast_service.dart';
import '../services/direct_m3u8_service.dart';
import '../services/hls_audio_helper.dart';
import '../services/media_download_manager.dart';
import '../services/media_session_handler.dart';
import '../services/native_stream_extractor.dart';
import '../services/stream_audio_helper.dart';
import '../services/tmdb_api_service.dart';
import '../models/subtitle_settings.dart';
import '../services/cloud_sync_service.dart';
import '../services/watch_history_service.dart';
import '../services/miniplayer_service.dart';
import '../services/open_subtitles_service.dart';
import '../widgets/app_network_image.dart';

class M3U8VideoPlayerScreen extends StatefulWidget {
  final String title;
  final String tmdbId;
  final bool isMovie;
  final int season;
  final int episode;
  final String? offlinePath;
  final List<Map<String, dynamic>> offlineSubtitles;
  final List<Map<String, dynamic>> offlineEpisodes;
  final List<int> genreIds;

  const M3U8VideoPlayerScreen({
    super.key,
    required this.title,
    required this.tmdbId,
    required this.isMovie,
    this.season = 1,
    this.episode = 1,
    this.offlinePath,
    this.offlineSubtitles = const [],
    this.offlineEpisodes = const [],
    this.genreIds = const [],
  });

  @override
  State<M3U8VideoPlayerScreen> createState() => _M3U8VideoPlayerScreenState();
}

class _StreamQuality {
  const _StreamQuality({
    required this.label,
    required this.url,
    required this.height,
  });

  final String label;
  final String url;
  final int height;
}

class _SubtitleTrack {
  const _SubtitleTrack({
    required this.label,
    required this.url,
    required this.isDefault,
    this.source = '',
    this.group = '',
    this.headers = const {},
  });

  final String label;
  final String url;
  final bool isDefault;
  final String source;

  /// Server display label the track belongs to (e.g. "VidLink via Worker"),
  /// used to group cross-server subtitle fallback options.
  final String group;

  /// HTTP headers of the server that provided this track, so a subtitle
  /// picked from another server is fetched with the right referer/cookies.
  final Map<String, String> headers;
}

class Subtitle {
  const Subtitle({
    required this.index,
    required this.start,
    required this.end,
    required this.text,
  });

  final int index;
  final Duration start;
  final Duration end;
  final String text;
}

class _StablePlayerControls extends StatefulWidget {
  const _StablePlayerControls({
    required this.controller,
    required this.onBack,
    required this.onMinimize,
    required this.onPlayIntent,
    required this.mediaTitle,
    required this.onQuality,
    required this.qualityLabel,
    required this.showQuality,
    required this.onServer,
    required this.serverLabel,
    required this.showServer,
    required this.serversLoading,
    required this.onSubtitles,
    required this.subtitleLabel,
    required this.showSubtitles,
    required this.onAudio,
    required this.audioLabel,
    required this.showAudio,
    required this.onAspectRatio,
    required this.aspectRatioLabel,
    required this.onDownload,
    required this.showDownload,
    required this.downloadProgress,
    required this.downloadCompleted,
  });

  final dynamic controller;
  final VoidCallback onBack;
  final VoidCallback onMinimize;
  final void Function(bool wantsPlayback) onPlayIntent;
  final String mediaTitle;
  final VoidCallback onQuality;
  final String qualityLabel;
  final bool showQuality;
  final VoidCallback onServer;
  final String serverLabel;
  final bool showServer;
  final bool serversLoading;
  final VoidCallback onSubtitles;
  final ValueNotifier<String> subtitleLabel;
  final bool showSubtitles;
  final VoidCallback onAudio;
  final String audioLabel;
  final bool showAudio;
  final VoidCallback onAspectRatio;
  final String aspectRatioLabel;
  final VoidCallback onDownload;
  final bool showDownload;
  final double? downloadProgress;
  final bool downloadCompleted;

  @override
  State<_StablePlayerControls> createState() => _StablePlayerControlsState();
}

class _StablePlayerControlsState extends State<_StablePlayerControls> {
  bool _visible = true;
  Timer? _hideTimer;
  bool _adjustingBrightness = false;
  double _gestureValue = 0.5;
  bool _showGestureValue = false;
  Duration _lastPosition = Duration.zero;
  Duration _lastDuration = Duration.zero;

  @override
  void initState() {
    super.initState();
    _restartHideTimer();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  void _restartHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      final value = widget.controller.value;
      if (mounted && value.isPlaying && !value.isBuffering && !value.hasError) {
        setState(() => _visible = false);
      }
    });
  }

  void _toggleControls() {
    setState(() => _visible = !_visible);
    if (_visible) _restartHideTimer();
  }

  void _togglePlayback() {
    // Report intent first: the screen uses it to decide whether the rebuilt
    // controller after a quality/server/audio switch should autoplay.
    final nextWantsPlayback = !widget.controller.value.isPlaying;
    widget.onPlayIntent(nextWantsPlayback);
    setState(() => _visible = true);
    _restartHideTimer();
  }

  void _showCastDialog(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Container(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Row(
              children: [
                Icon(Icons.cast, color: Colors.white, size: 24),
                SizedBox(width: 12),
                Text(
                  'Cast to Device',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Row(
                children: [
                  Icon(Icons.info_outline, color: Colors.grey, size: 20),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Make sure your Chromecast is on the same Wi-Fi network, then tap the Cast icon in your browser or use the Google Home app.',
                      style: TextStyle(color: Colors.grey, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => Navigator.pop(ctx),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: const Text(
                  'Done',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _seekBy(Duration offset) {
    final value = widget.controller.value;
    var target = value.position + offset;
    if (target < Duration.zero) target = Duration.zero;
    if (value.duration > Duration.zero && target > value.duration) {
      target = value.duration;
    }
    widget.controller.seekTo(target);
    _restartHideTimer();
  }

  void _startVerticalDrag(DragStartDetails details) {
    final width = MediaQuery.sizeOf(context).width;
    _adjustingBrightness = details.localPosition.dx < width / 2;
    _gestureValue = _adjustingBrightness ? 0.5 : widget.controller.value.volume;
    if (_adjustingBrightness) {
      NativeStreamExtractor.getBrightness().then((value) {
        if (mounted && _adjustingBrightness) _gestureValue = value;
      });
    }
    setState(() => _showGestureValue = true);
    _hideTimer?.cancel();
  }

  void _updateVerticalDrag(DragUpdateDetails details) {
    final delta = -(details.primaryDelta ?? 0) / 220;
    _gestureValue = (_gestureValue + delta).clamp(0.01, 1.0);
    if (_adjustingBrightness) {
      NativeStreamExtractor.setBrightness(_gestureValue);
    } else {
      widget.controller.setVolume(_gestureValue);
    }
    setState(() => _showGestureValue = true);
  }

  void _endVerticalDrag(DragEndDetails details) {
    setState(() => _showGestureValue = false);
    _restartHideTimer();
  }

  String _format(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: widget.controller,
      builder: (context, value, _) {
        if (value.duration > Duration.zero) _lastDuration = value.duration;
        if (value.position > Duration.zero) _lastPosition = value.position;
        final displayedDuration = value.duration > Duration.zero
            ? value.duration
            : _lastDuration;
        final displayedPosition = value.position > Duration.zero
            ? value.position
            : _lastPosition;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _toggleControls,
          onVerticalDragStart: _startVerticalDrag,
          onVerticalDragUpdate: _updateVerticalDrag,
          onVerticalDragEnd: _endVerticalDrag,
          child: Stack(
            children: [
              if (_visible)
                const Positioned.fill(child: ColoredBox(color: Colors.black26)),
              if (_visible)
                Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Back 10 seconds',
                        iconSize: 42,
                        onPressed: () => _seekBy(const Duration(seconds: -10)),
                        icon: const Icon(Icons.replay_10, color: Colors.white),
                      ),
                      const SizedBox(width: 24),
                      IconButton(
                        iconSize: 58,
                        onPressed: _togglePlayback,
                        icon: Icon(
                          value.isPlaying
                              ? Icons.pause_circle_filled
                              : Icons.play_circle_fill,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(width: 24),
                      IconButton(
                        tooltip: 'Forward 10 seconds',
                        iconSize: 42,
                        onPressed: () => _seekBy(const Duration(seconds: 10)),
                        icon: const Icon(Icons.forward_10, color: Colors.white),
                      ),
                    ],
                  ),
                ),
              if (_visible)
                SafeArea(
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Back',
                            onPressed: widget.onBack,
                            icon: const Icon(
                              Icons.arrow_back,
                              color: Colors.white,
                            ),
                          ),
                          IconButton(
                            tooltip: 'Minimize',
                            onPressed: widget.onMinimize,
                            icon: const Icon(
                              Icons.picture_in_picture_alt,
                              color: Colors.white,
                            ),
                          ),
                          // Cast button
                          ValueListenableBuilder<bool>(
                            valueListenable: ValueNotifier(
                              CastService.instance.isCastAvailable,
                            ),
                            builder: (context, isAvailable, _) {
                              if (!isAvailable) return const SizedBox.shrink();
                              return IconButton(
                                tooltip: 'Cast to TV',
                                onPressed: () => _showCastDialog(context),
                                icon: const Icon(
                                  Icons.cast,
                                  color: Colors.white,
                                ),
                              );
                            },
                          ),
                          if (widget.mediaTitle.isNotEmpty)
                            Flexible(
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 6,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.black54,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  widget.mediaTitle,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              if (_visible)
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 12,
                  child: SafeArea(
                    top: false,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (value.isInitialized &&
                            value.duration > Duration.zero)
                          VideoProgressIndicator(
                            widget.controller,
                            allowScrubbing: true,
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            colors: const VideoProgressColors(
                              playedColor: Colors.red,
                              bufferedColor: Colors.white54,
                              backgroundColor: Colors.white24,
                            ),
                          )
                        else if (value.isInitialized &&
                            displayedDuration > Duration.zero)
                          SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: 4,
                              activeTrackColor: Colors.red,
                              inactiveTrackColor: Colors.white24,
                              thumbColor: Colors.red,
                              overlayColor: Colors.red.withOpacity(0.2),
                            ),
                            child: Slider(
                              value: displayedPosition.inMilliseconds
                                  .clamp(0, displayedDuration.inMilliseconds)
                                  .toDouble(),
                              max: displayedDuration.inMilliseconds.toDouble(),
                              onChanged: (milliseconds) {
                                widget.controller.seekTo(
                                  Duration(milliseconds: milliseconds.round()),
                                );
                                _restartHideTimer();
                              },
                            ),
                          )
                        else
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 10),
                            child: SizedBox(
                              height: 4,
                              child: ColoredBox(color: Colors.white24),
                            ),
                          ),
                        Row(
                          children: [
                            Text(
                              '${_format(displayedPosition)} / ${_format(displayedDuration)}',
                              style: const TextStyle(color: Colors.white),
                            ),
                            IconButton(
                              tooltip: value.volume == 0 ? 'Unmute' : 'Mute',
                              onPressed: () => widget.controller.setVolume(
                                value.volume == 0 ? 1 : 0,
                              ),
                              icon: Icon(
                                value.volume == 0
                                    ? Icons.volume_off
                                    : Icons.volume_up,
                                color: Colors.white,
                              ),
                            ),
                            const Spacer(),
                            if (widget.showDownload)
                              IconButton(
                                tooltip: widget.downloadCompleted
                                    ? 'Downloaded'
                                    : widget.downloadProgress == null
                                    ? 'Download for offline viewing'
                                    : 'Downloading',
                                onPressed:
                                    !widget.downloadCompleted &&
                                        widget.downloadProgress == null
                                    ? widget.onDownload
                                    : null,
                                icon: widget.downloadCompleted
                                    ? const Icon(
                                        Icons.check_circle,
                                        color: Colors.green,
                                      )
                                    : widget.downloadProgress == null
                                    ? const Icon(
                                        Icons.download_for_offline_outlined,
                                        color: Colors.white,
                                      )
                                    : SizedBox(
                                        width: 22,
                                        height: 22,
                                        child: CircularProgressIndicator(
                                          value: widget.downloadProgress,
                                          strokeWidth: 2.5,
                                          color: Colors.red,
                                          backgroundColor: Colors.white24,
                                        ),
                                      ),
                              ),
                            if (widget.showServer)
                              TextButton.icon(
                                onPressed: widget.onServer,
                                icon: widget.serversLoading
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: Colors.white,
                                        ),
                                      )
                                    : const Icon(
                                        Icons.dns_outlined,
                                        color: Colors.white,
                                      ),
                                label: Text(
                                  widget.serverLabel,
                                  style: const TextStyle(color: Colors.white),
                                ),
                              ),
                            if (widget.showSubtitles)
                              ValueListenableBuilder<String>(
                                valueListenable: widget.subtitleLabel,
                                builder: (context, label, _) => TextButton.icon(
                                  onPressed: widget.onSubtitles,
                                  icon: const Icon(
                                    Icons.subtitles,
                                    color: Colors.white,
                                  ),
                                  label: Text(
                                    label,
                                    style: const TextStyle(color: Colors.white),
                                  ),
                                ),
                              ),
                            if (widget.showAudio)
                              TextButton.icon(
                                onPressed: widget.onAudio,
                                icon: const Icon(
                                  Icons.audiotrack,
                                  color: Colors.white,
                                ),
                                label: Text(
                                  widget.audioLabel,
                                  style: const TextStyle(color: Colors.white),
                                ),
                              ),
                            if (widget.showQuality)
                              TextButton.icon(
                                onPressed: widget.onQuality,
                                icon: const Icon(Icons.hd, color: Colors.white),
                                label: Text(
                                  widget.qualityLabel,
                                  style: const TextStyle(color: Colors.white),
                                ),
                              ),
                            TextButton.icon(
                              onPressed: widget.onAspectRatio,
                              icon: const Icon(
                                Icons.aspect_ratio,
                                color: Colors.white,
                              ),
                              label: Text(
                                widget.aspectRatioLabel,
                                style: const TextStyle(color: Colors.white),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              if (_showGestureValue)
                Positioned(
                  top: 0,
                  bottom: 0,
                  left: _adjustingBrightness ? 36 : null,
                  right: _adjustingBrightness ? null : 36,
                  child: Center(
                    child: Container(
                      width: 64,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 14,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _adjustingBrightness
                                ? Icons.brightness_6
                                : Icons.volume_up,
                            color: Colors.white,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '${(_gestureValue * 100).round()}%',
                            style: const TextStyle(color: Colors.white),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

enum _AspectRatioMode { fit, stretch, zoom }

class _M3U8VideoPlayerScreenState extends State<M3U8VideoPlayerScreen> {
  VideoPlayerController? _videoPlayerController;
  bool _useNativePlayer = false;
  bool _isBuffering = false;
  bool _isSwitchingQuality = false;
  bool _isSwitchingServer = false;
  bool _isRetryingServer = false;
  String? _error;
  String? _currentSource;
  String _selectedQuality = 'Auto';
  Map<String, String> _streamHeaders = const {};
  List<_StreamQuality> _qualities = const [];
  bool _separateAudio = false;
  List<_SubtitleTrack> _subtitleTracks = const [];
  // Subtitles downloaded from online search this session. Kept separate from
  // _subtitleTracks because that list is rebuilt from server metadata on every
  // server/quality switch; _unionSubtitleTracks re-appends these.
  final List<_SubtitleTrack> _onlineSubtitleTracks = [];
  List<OpenSubtitleResult> _onlineSearchResults = const [];
  bool _onlineSearchLoading = false;
  String? _onlineSearchError;
  final ValueNotifier<List<Subtitle>> _activeSubtitles =
      ValueNotifier<List<Subtitle>>(const []);
  final ValueNotifier<String> _selectedSubtitle = ValueNotifier<String>('Off');
  // Multi-language HLS audio (EXT-X-MEDIA:TYPE=AUDIO). Parsed from the current
  // server's master playlist; empty when the host serves a single track.
  List<Map<String, dynamic>> _audioTracks = const [];
  // Remote master URL backing audio switching (null when playing a pinned
  // variant or a non-HLS file, where no alternate renditions exist).
  String? _masterStreamUrl;
  String? _preferredAudioLanguage;
  bool _isSwitchingAudio = false;
  // Whole alternate dub streams (NetMirror): every language is its own MP4, so
  // the default stream URL differs from a selected dub's URL and switching
  // audio means swapping URLs instead of rewriting an HLS master.
  String? _baseStreamUrl;
  bool _hasAlternateAudio = false;
  // Stall watchdog. Progressive MP4 has no adaptive ladder, so a link that
  // drops below the rendition's bitrate freezes the video while the already
  // buffered audio keeps playing — which no error callback ever reports.
  Timer? _stallWatchdog;
  int _stallTicks = 0;
  int _stallGraceSeconds = 0;
  int _stallRecoveries = 0;
  Duration _stallLastPosition = Duration.zero;

  /// URL of the currently selected subtitle track, used as a stable key
  /// to re-sync the display value when group names change after re-discovery.
  String? _selectedSubtitleUrl;
  double _subtitleOffsetMs = 0; // Subtitle timing offset in milliseconds
  SubtitleSettings _subtitleSettings = SubtitleSettings();
  String _statusMessage = 'Initializing...';
  Timer? _progressTimer;
  bool _isLeaving = false;
  bool _isMinimizing = false;
  late int _currentSeason;
  late int _currentEpisode;
  late String _currentTitle;
  late String _resolverTitle;
  String _posterUrl = '';
  Map<String, dynamic>? _nextEpisode;
  bool _nextEpisodeCancelled = false;
  bool _loadingNextEpisode = false;
  bool _showNextEpisode = false;
  int _nextEpisodeCountdown = 30;
  _AspectRatioMode _aspectRatioMode = _AspectRatioMode.fit;
  bool _videoInitialized = false;
  String? _currentStreamUrl;
  bool _currentStreamIsHls = true;
  Duration _lastStablePosition = Duration.zero;
  bool _recoveringPlayback = false;

  /// Whether the user currently wants audio/video to be playing.
  ///
  /// Playback intent cannot be derived from `controller.value.isPlaying`: that
  /// flag lags a tick behind `pause()` and is also true while a paused player
  /// is stalled buffering. Every source swap (quality / server / audio track /
  /// error recovery / next episode) tears the controller down and rebuilds it,
  /// so reading it there made a paused video resume on its own. This flag is
  /// only mutated by explicit user intent (play/pause button, media session,
  /// auto-advance) and is the sole input to `shouldPlay`.
  bool _userWantsPlayback = true;

  /// Records the user's play/pause intent and mirrors it onto the live
  /// controller. Always route play/pause through here so intent and the
  /// controller cannot drift apart.
  void _setPlayIntent(bool wantsPlayback) {
    _userWantsPlayback = wantsPlayback;
    final controller = _videoPlayerController;
    if (controller == null || !controller.value.isInitialized) return;
    if (wantsPlayback) {
      controller.play();
    } else {
      controller.pause();
    }
  }

  Duration get _currentPosition =>
      _videoPlayerController?.value.position ?? Duration.zero;
  Duration get _currentDuration =>
      _videoPlayerController?.value.duration ?? Duration.zero;
  bool get _isPlayingNow => _videoPlayerController?.value.isPlaying ?? false;
  int _playbackRetryCount = 0;
  // Failure tracking is identity-based: re-discovery hands every server a new
  // signed URL, so URL-keyed entries would never match the fresh list and a
  // dead server would keep getting retried (or the current one never skipped).
  final Set<String> _failedServerKeys = {};
  // Identity of the server currently playing, so the sheet can keep the
  // highlight on it even after its URL is re-extracted fresh.
  String? _selectedServerKey;
  double? _downloadProgress;
  bool _downloadCompleted = false;
  late int _downloadCompletionVersion;
  String? _offlinePath;
  List<Map<String, dynamic>> _offlineSubtitles = const [];
  List<Map<String, dynamic>> _availableServers = const [];
  bool _serversLoading = false;
  int _serverDiscoveryGeneration = 0;

  /// Monotonic token for player rebuilds. Every `_replacePlayer` bumps it and
  /// a build that is no longer the newest tears its controller down instead of
  /// installing it. Without this, overlapping loads (server menu refresh,
  /// playback recovery, next-episode auto-advance, a user tapping a server
  /// while the first one is still initializing) each created their own
  /// controller, the last one won the `_videoPlayerController` assignment and
  /// the losers were never disposed — audibly playing in the background.
  int _playerBuildGeneration = 0;

  /// Controller of the build that is still initializing (not yet installed).
  VideoPlayerController? _pendingController;

  @override
  void initState() {
    super.initState();
    _currentSeason = widget.season;
    _currentEpisode = widget.episode;
    _currentTitle = widget.title;
    _resolverTitle = widget.title;
    _offlinePath = widget.offlinePath;
    _offlineSubtitles = widget.offlineSubtitles;
    _downloadCompletionVersion =
        MediaDownloadManager.instance.completionVersion;
    MediaDownloadManager.instance.addListener(_handleDownloadChanged);
    unawaited(_refreshDownloadStatus());
    SubtitleSettings.load().then((s) {
      if (mounted) setState(() => _subtitleSettings = s);
    });
    // Re-load subtitle settings when cloud sync delivers changes from another device
    CloudSyncService.subtitlePrefsRevision.addListener(_onSubtitlePrefsChanged);
    // Initialize Chromecast
    CastService.instance.initialize();

    // Check if we're restoring from miniplayer
    final miniplayer = MiniplayerService.instance;
    if (miniplayer.isActive &&
        miniplayer.tmdbId == widget.tmdbId &&
        miniplayer.season == widget.season &&
        miniplayer.episode == widget.episode) {
      final restoredController = miniplayer.restore();
      if (restoredController != null) {
        _videoPlayerController = restoredController;
        _videoPlayerController!.addListener(_handlePlaybackChanged);
        // The handed-over controller keeps its own play state; adopt it so a
        // switch right after restore doesn't autoplay a paused video.
        _userWantsPlayback = restoredController.value.isPlaying;
        _useNativePlayer = true;
        _videoInitialized = true;
        // Restore controls state so buttons show immediately
        _availableServers = miniplayer.availableServers;
        _selectedQuality = miniplayer.selectedQuality;
        _selectedServerKey = miniplayer.selectedServerKey.isNotEmpty
            ? miniplayer.selectedServerKey
            : null;
        _currentSource = miniplayer.currentSource.isNotEmpty
            ? miniplayer.currentSource
            : null;
        _streamHeaders = miniplayer.streamHeaders;
        _selectedSubtitle.value = miniplayer.selectedSubtitleValue;
        _selectedSubtitleUrl = miniplayer.selectedSubtitleUrl.isNotEmpty
            ? miniplayer.selectedSubtitleUrl
            : null;
        _activeSubtitles.value = miniplayer.activeSubtitleCues
            .map(
              (c) =>
                  Subtitle(index: 0, start: c.start, end: c.end, text: c.text),
            )
            .toList();
        _subtitleTracks = _unionSubtitleTracks();
        _qualities = _parseQualities(miniplayer.qualitiesRaw);
        SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
        // Re-discover servers in background for fresh URLs
        _loadMediaMetadata();
        _discoverAvailableServers(++_serverDiscoveryGeneration);
        _registerMediaSessionCallbacks();
        return;
      }
    }

    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _loadStream();
    _registerMediaSessionCallbacks();
  }

  /// Binds the notification / lock-screen transport controls to this screen.
  ///
  /// Play and pause go through [_setPlayIntent] so the intent flag stays in
  /// sync; a notification "play" must not be undone by the next source switch.
  /// [_isLeaving] is checked because `init()` is async and can resolve after
  /// the user already backed out, which would otherwise leave live callbacks
  /// on the singleton handler (they only get cleared in `dispose`).
  void _registerMediaSessionCallbacks() {
    MediaSessionHandler.instance.init().then((_) {
      final handler = MediaSessionHandler.instance.handler;
      if (handler == null || !mounted || _isLeaving) return;
      handler.onPlay = () => _setPlayIntent(true);
      handler.onPause = () => _setPlayIntent(false);
      handler.onSeek = (pos) => _videoPlayerController?.seekTo(pos);
      handler.onStop = () {
        if (mounted) _exitPlayer();
      };
    });
  }

  String _sourceLabel(
    Map<String, dynamic>? stream, {
    String fallback = 'Server',
  }) {
    final source = stream?['source']?.toString() ?? fallback;
    final method = stream?['method']?.toString();
    return method != null ? '$source ($method)' : source;
  }

  void _showStatus(String message) {
    debugPrint('M3U8Player: $message');
    if (mounted) {
      setState(() => _statusMessage = message);
      try {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            duration: const Duration(seconds: 2),
            backgroundColor: Colors.blue.shade800,
            behavior: SnackBarBehavior.floating,
          ),
        );
      } catch (_) {}
    }
  }

  Future<void> _loadStream({bool resume = true}) async {
    if (!mounted || _isLeaving) return;
    final offlinePath = _offlinePath;
    if (offlinePath != null && offlinePath.isNotEmpty) {
      await _loadOfflineStream(offlinePath, resume: resume);
      return;
    }
    final discoveryGeneration = ++_serverDiscoveryGeneration;

    setState(() {
      _error = null;
      _statusMessage = 'Fetching servers...';
      _availableServers = const [];
      _serversLoading = false;
      _selectedServerKey = null;
    });

    try {
      _showStatus('Fetching available servers...');
      await _loadMediaMetadata();
      Map<String, dynamic>? result;

      if (widget.isMovie) {
        result = await DirectM3u8Service.fetchMovieStreamUrl(
          _resolverTitle,
          null,
          widget.tmdbId,
        );
      } else {
        result = await DirectM3u8Service.fetchSeriesStreamUrl(
          _resolverTitle,
          _currentSeason,
          _currentEpisode,
          widget.tmdbId,
        );
      }

      if (!mounted || _isLeaving) return;

      if (result != null && result['url'] != null) {
        final url = result['url'] as String;
        final source = result['source'] as String? ?? 'Unknown';
        final method = result['method'] as String?;
        final headers = <String, String>{};
        if (result['referer'] != null) {
          headers['Referer'] = result['referer'].toString();
        }
        if (result['headers'] != null && result['headers'] is Map) {
          (result['headers'] as Map).forEach((k, v) {
            headers[k.toString()] = v.toString();
          });
        }
        final qualities = _parseQualities(result['qualities']);
        final subtitleTracks = _parseSubtitleTracks(result['subtitles']);
        _separateAudio = result['separateAudio'] == true;
        _syncAudioFromStream(result);
        _currentSource = source;
        _playbackRetryCount = 0;
        _failedServerKeys.clear();
        _availableServers = [result];
        _serversLoading = true;
        _selectedServerKey = _serverIdentity(result);
        result['available'] = true;

        // Auto-select subtitle: English CC > English > default > first available.
        _SubtitleTrack? initialSubtitle;
        _SubtitleTrack? defaultTrack;
        _SubtitleTrack? englishTrack;
        _SubtitleTrack? englishCcTrack;
        for (final track in subtitleTracks) {
          final lower = track.label.toLowerCase();
          if (lower.contains('english') && lower.contains('cc')) {
            englishCcTrack ??= track;
          } else if (lower.contains('english')) {
            englishTrack ??= track;
          }
          if (track.isDefault) {
            defaultTrack ??= track;
          }
        }
        initialSubtitle = englishCcTrack ?? englishTrack ?? defaultTrack;
        var initialSubtitles = const <Subtitle>[];
        if (initialSubtitle != null) {
          try {
            initialSubtitles = await _fetchSubtitles(initialSubtitle, headers);
          } catch (error) {
            debugPrint('M3U8Player: Default subtitle failed: $error');
            initialSubtitle = null;
          }
        }
        var selectedQuality = 'Auto';
        for (final quality in qualities) {
          if (quality.url == url) {
            selectedQuality = quality.label;
            break;
          }
        }
        final resumePosition = resume
            ? await WatchHistoryService.loadWatchPosition(
                widget.tmdbId,
                widget.isMovie,
                _currentSeason,
                _currentEpisode,
              )
            : Duration.zero;
        if (!mounted || _isLeaving) return;
        _subtitleTracks = _unionSubtitleTracks();
        _activeSubtitles.value = initialSubtitles;
        _selectedSubtitle.value = initialSubtitle != null
            ? _subtitleTileValue(initialSubtitle)
            : 'Off';
        _selectedSubtitleUrl = initialSubtitle?.url;

        final methodLabel = method != null ? ' ($method)' : '';
        _showStatus(
          'Stream found from $source$methodLabel! Initializing player...',
        );
        var discoveredServers = false;
        // The native extractor already validated this exact stream with
        // OkHttp. Hand it straight to ExoPlayer instead of letting the
        // dart:io pre-flight veto it (dart:io can reject a URL that OkHttp
        // and ExoPlayer happily play). The pre-flight only orders the
        // fallback candidates below.
        var initialized = await _initializePlayer(
          url,
          headers: headers,
          source: source,
          qualities: qualities,
          selectedQuality: selectedQuality,
          position: resumePosition,
          isHls:
              result['type'] == 'direct_m3u8' ||
              url.toLowerCase().contains('.m3u8'),
        );
        if (!initialized) {
          _showStatus('Trying next server...');
          discoveredServers = true;
          await _discoverAvailableServers(discoveryGeneration);
          final candidates = _availableServers
              .where(
                (s) =>
                    (s['url']?.toString() ?? '').isNotEmpty &&
                    s['url']?.toString() != url,
              )
              .toList();
          for (final server in candidates) {
            _showStatus('Trying ${_sourceLabel(server)}...');
            initialized = await _tryPlayServer(
              server,
              position: resumePosition,
              primaryUrl: url,
            );
            if (initialized) break;
          }
        }
        if (!initialized) {
          if (mounted) {
            setState(() {
              _error =
                  'None of the available servers could start playback. '
                  'Please try again later.';
            });
          }
          return;
        }
        // Now that the new player is ready, allow the next-episode countdown
        // to function again. The cancel flag was held true during the episode
        // transition to prevent the old controller's listener from showing
        // the overlay with stale data.
        if (mounted) {
          setState(() {
            _nextEpisodeCancelled = false;
          });
        }
        if (!discoveredServers) {
          unawaited(_discoverAvailableServers(discoveryGeneration));
        }
        return;
      }

      _showStatus('No stream found');
      if (mounted) {
        setState(() {
          _error =
              'No working streaming sources found.\n\n'
              '• Check your internet connection\n'
              '• Try again later\n'
              '• Content might be unavailable';
        });
      }
    } catch (e) {
      debugPrint('M3U8VideoPlayer: Error loading stream: $e');
      _showStatus('Error: $e');
      if (mounted) {
        setState(() {
          _error = 'Failed to load stream: $e';
        });
      }
    }
  }

  /// Tries to start playback for a candidate server, returning true on success
  /// so the caller can stop falling through the server list.
  Future<bool> _tryPlayServer(
    Map<String, dynamic> server, {
    required Duration position,
    required String primaryUrl,
    bool? shouldPlay,
  }) async {
    final fallbackUrl = server['url']?.toString() ?? '';
    if (fallbackUrl.isEmpty || fallbackUrl == primaryUrl) return false;
    if (_isLeaving) return false;
    final fallbackSource = server['source']?.toString() ?? 'Server';
    final fallbackQualities = _parseQualities(server['qualities']);
    _subtitleTracks = _unionSubtitleTracks();
    _syncAudioFromStream(server);
    _selectedSubtitle.value = 'Off';
    _activeSubtitles.value = const [];
    final ok = await _initializePlayer(
      fallbackUrl,
      headers: _parseStreamHeaders(server),
      source: fallbackSource,
      qualities: fallbackQualities,
      selectedQuality: 'Auto',
      position: position,
      isHls:
          server['type'] == 'direct_m3u8' ||
          fallbackUrl.toLowerCase().contains('.m3u8'),
      // Falling through the server list is a recovery, not a user request to
      // start watching: keep whatever the user had before.
      shouldPlay: shouldPlay ?? _userWantsPlayback,
    );
    if (ok) {
      _selectedServerKey = _serverIdentity(server);
    }
    return ok;
  }

  Future<void> _loadOfflineStream(String path, {required bool resume}) async {
    if (_isLeaving) return;
    // Same supersede rules as _replacePlayer: bump the generation, cancel a
    // build that is still initializing, and free the current player BEFORE the
    // new one starts so two controllers can never be audible at once.
    final generation = ++_playerBuildGeneration;
    final pending = _pendingController;
    if (pending != null) {
      _pendingController = null;
      try {
        await pending.dispose().timeout(const Duration(seconds: 3));
      } catch (_) {}
    }
    final previousVideo = _videoPlayerController;
    _videoPlayerController = null;
    if (previousVideo != null) {
      try {
        previousVideo.removeListener(_handlePlaybackChanged);
      } catch (_) {}
      try {
        await previousVideo.dispose().timeout(const Duration(seconds: 3));
      } catch (_) {}
    }
    setState(() {
      _error = null;
      _statusMessage = 'Opening download...';
      _availableServers = const [];
      _serversLoading = false;
    });
    final file = File(path);
    final exists = await file.exists();
    if (!mounted || _isLeaving) return;
    if (!exists) {
      setState(() => _error = 'This downloaded video file no longer exists.');
      return;
    }
    final controller = VideoPlayerController.file(
      file,
      videoPlayerOptions: VideoPlayerOptions(
        backBufferDurationMs: 60000,
        allowBackgroundPlayback: true,
      ),
    );
    _pendingController = controller;
    try {
      final subtitleTracks = _parseSubtitleTracks(_offlineSubtitles);
      await controller.initialize();
      if (!_isBuildCurrent(generation)) {
        await _discardPendingController(controller);
        return;
      }
      final position = resume
          ? await WatchHistoryService.loadWatchPosition(
              widget.tmdbId,
              widget.isMovie,
              _currentSeason,
              _currentEpisode,
            )
          : Duration.zero;
      if (position > Duration.zero && position < controller.value.duration) {
        await controller.seekTo(position);
      }
      // Autoplay only when the user still wants to be watching. _loadStream
      // also runs for auto-advance and for the error-view retry, which must
      // not resurrect a video the user paused or backed out of.
      if (_userWantsPlayback) await controller.play();
      if (!_isBuildCurrent(generation)) {
        await _discardPendingController(controller);
        return;
      }
      controller.addListener(_handlePlaybackChanged);
      _prepareNextOfflineEpisode();
      setState(() {
        _videoPlayerController = controller;
        _useNativePlayer = true;
        _videoInitialized = true;
        _currentSource = 'Downloaded';
        _currentStreamUrl = null;
        _currentStreamIsHls = path.toLowerCase().endsWith('.m3u8');
        _streamHeaders = const {};
        _qualities = const [];
        _subtitleTracks = subtitleTracks;
        _selectedSubtitle.value = 'Off';
        _activeSubtitles.value = const [];
        _audioTracks = const [];
        _masterStreamUrl = null;
        _baseStreamUrl = null;
        _hasAlternateAudio = false;
        _preferredAudioLanguage = null;
        _nextEpisodeCancelled = false;
        _selectedServerKey = null;
      });
      if (identical(_pendingController, controller)) {
        _pendingController = null;
      }
      _startProgressSaving();
    } catch (error) {
      await controller.dispose();
      debugPrint('M3U8Player: Download playback failed: $error');
      if (mounted) {
        setState(() {
          _error =
              'This downloaded video is incomplete or damaged and cannot play. '
              'Delete it and download it again.';
        });
      }
    }
  }

  void _prepareNextOfflineEpisode() {
    if (widget.isMovie || widget.offlineEpisodes.isEmpty) {
      _nextEpisode = null;
      return;
    }
    final episodes = List<Map<String, dynamic>>.from(widget.offlineEpisodes)
      ..sort((a, b) {
        final season = ((a['seasonNumber'] as num?)?.toInt() ?? 0).compareTo(
          (b['seasonNumber'] as num?)?.toInt() ?? 0,
        );
        return season != 0
            ? season
            : ((a['episodeNumber'] as num?)?.toInt() ?? 0).compareTo(
                (b['episodeNumber'] as num?)?.toInt() ?? 0,
              );
      });
    Map<String, dynamic>? next;
    for (final episode in episodes) {
      final season = (episode['seasonNumber'] as num?)?.toInt() ?? 0;
      final number = (episode['episodeNumber'] as num?)?.toInt() ?? 0;
      if (season > _currentSeason ||
          (season == _currentSeason && number > _currentEpisode)) {
        next = episode;
        break;
      }
    }
    if (next == null) {
      _nextEpisode = null;
      return;
    }
    final title = next['title']?.toString() ?? 'Next episode';
    _nextEpisode = {
      'season': next['seasonNumber'],
      'episode': next['episodeNumber'],
      'name': title.contains(': ')
          ? title.split(': ').skip(1).join(': ')
          : title,
      'seriesTitle': title.contains(' - S')
          ? title.split(' - S').first
          : _resolverTitle,
      'stillUrl': next['thumbnail']?.toString() ?? '',
      'offlinePath': next['localPath']?.toString() ?? '',
      'subtitles': next['subtitles'] ?? const <Map<String, dynamic>>[],
    };
  }

  Future<void> _downloadCurrentStream() async {
    final url = _currentStreamUrl;
    if (url == null || _downloadProgress != null) return;
    try {
      await MediaDownloadManager.instance.start(
        downloadKey: _currentDownloadKey,
        url: url,
        headers: _streamHeaders,
        mediaId: widget.tmdbId,
        isMovie: widget.isMovie,
        isHls: _currentStreamIsHls,
        seriesId: widget.isMovie ? null : widget.tmdbId,
        seasonNumber: widget.isMovie ? null : _currentSeason,
        episodeNumber: widget.isMovie ? null : _currentEpisode,
        title: _currentTitle,
        resolverTitle: _resolverTitle,
        thumbnail: _posterUrl,
      );
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Download completed')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Download failed: $error')));
      }
    }
  }

  String get _currentDownloadKey => widget.isMovie
      ? 'movie_${widget.tmdbId}'
      : 'series_${widget.tmdbId}_s${_currentSeason}_e$_currentEpisode';

  Future<void> _refreshDownloadStatus() async {
    final key = _currentDownloadKey;
    final downloads = await DBHelper.getMediaDownloads();
    final downloaded = downloads.any(
      (item) => item['downloadKey']?.toString() == key,
    );
    if (mounted &&
        key == _currentDownloadKey &&
        downloaded != _downloadCompleted) {
      setState(() => _downloadCompleted = downloaded);
    }
  }

  void _handleDownloadChanged() {
    if (!mounted) return;
    final manager = MediaDownloadManager.instance;
    final progress = manager.taskFor(_currentDownloadKey)?.progress;
    if (progress != _downloadProgress) {
      setState(() => _downloadProgress = progress);
    }
    if (_downloadCompletionVersion != manager.completionVersion) {
      _downloadCompletionVersion = manager.completionVersion;
      unawaited(_refreshDownloadStatus());
    }
  }

  void _onSubtitlePrefsChanged() {
    if (!mounted) return;
    SubtitleSettings.load().then((s) {
      if (mounted) setState(() => _subtitleSettings = s);
    });
  }

  Future<void> _loadMediaMetadata() async {
    final id = int.tryParse(widget.tmdbId);
    if (id == null) return;
    final details = widget.isMovie
        ? await TmdbApiService.getMovieDetails(id)
        : await TmdbApiService.getSeriesDetails(id);
    if (details == null) return;

    _posterUrl = TmdbApiService.getPosterUrl(
      details['poster_path']?.toString(),
    );
    if (widget.isMovie) {
      _currentTitle = details['title']?.toString() ?? widget.title;
      _resolverTitle = _currentTitle;
      _nextEpisode = null;
      return;
    }

    final seriesTitle = details['name']?.toString() ?? widget.title;
    _resolverTitle = seriesTitle;
    final episodes = await TmdbApiService.getSeasonEpisodes(id, _currentSeason);
    final currentEpisodeData = episodes
        .where(
          (e) =>
              ((e['episode_number'] as num?)?.toInt() ?? 0) == _currentEpisode,
        )
        .firstOrNull;
    final episodeName = currentEpisodeData?['name']?.toString() ?? '';
    _currentTitle = episodeName.isNotEmpty
        ? '$seriesTitle - S${_currentSeason}E$_currentEpisode: $episodeName'
        : '$seriesTitle - S${_currentSeason}E$_currentEpisode';
    final laterEpisodes =
        episodes
            .where(
              (episode) =>
                  ((episode['episode_number'] as num?)?.toInt() ?? 0) >
                  _currentEpisode,
            )
            .toList()
          ..sort(
            (a, b) => ((a['episode_number'] as num?)?.toInt() ?? 0).compareTo(
              (b['episode_number'] as num?)?.toInt() ?? 0,
            ),
          );

    Map<String, dynamic>? next;
    var nextSeason = _currentSeason;
    if (laterEpisodes.isNotEmpty) {
      next = laterEpisodes.first;
    } else {
      final seasons =
          (details['seasons'] as List? ?? const [])
              .whereType<Map>()
              .where(
                (season) =>
                    ((season['season_number'] as num?)?.toInt() ?? 0) >
                        _currentSeason &&
                    ((season['episode_count'] as num?)?.toInt() ?? 0) > 0,
              )
              .toList()
            ..sort(
              (a, b) => ((a['season_number'] as num?)?.toInt() ?? 0).compareTo(
                (b['season_number'] as num?)?.toInt() ?? 0,
              ),
            );
      if (seasons.isNotEmpty) {
        nextSeason = (seasons.first['season_number'] as num).toInt();
        final nextSeasonEpisodes = await TmdbApiService.getSeasonEpisodes(
          id,
          nextSeason,
        );
        if (nextSeasonEpisodes.isNotEmpty) next = nextSeasonEpisodes.first;
      }
    }

    _nextEpisode = next == null
        ? null
        : {
            'season': nextSeason,
            'episode': (next['episode_number'] as num).toInt(),
            'name': next['name']?.toString() ?? 'Next episode',
            'stillUrl': TmdbApiService.getBackdropUrl(
              next['still_path']?.toString(),
            ),
            'seriesTitle': seriesTitle,
          };
    _showNextEpisode = false;
    _nextEpisodeCountdown = 30;
    // _nextEpisodeCancelled stays true during loading to prevent the old
    // controller's listener from showing the popup with stale data.
    // It gets reset in _loadStream after the new player is initialized.
  }

  Future<bool> _initializePlayer(
    String m3u8Url, {
    Map<String, String> headers = const {},
    String source = 'Unknown',
    List<_StreamQuality> qualities = const [],
    String selectedQuality = 'Auto',
    Duration position = Duration.zero,
    bool isHls = true,
    bool shouldPlay = true,
  }) async {
    if (_isLeaving) return false;
    try {
      _showStatus('Initializing video player...');
      final resolved = await _resolveAudioUrl(m3u8Url, headers, isHls);
      if (!mounted || _isLeaving) return false;
      final installed = await _replacePlayer(
        resolved.url,
        headers: headers,
        source: source,
        qualities: qualities,
        selectedQuality: resolved.isLocalFile ? 'Auto' : selectedQuality,
        isHls: isHls,
        position: position,
        shouldPlay: shouldPlay,
        isLocalFile: resolved.isLocalFile,
        remoteUrl: m3u8Url,
      );
      // Superseded by a newer rebuild: it owns the player now, so this load
      // must not claim success (nor report a failure the user caused nothing
      // about).
      if (!installed) return false;
      _showStatus('Playing from $source');
      return true;
    } catch (e) {
      debugPrint('M3U8VideoPlayer: Error initializing player: $e');
      _showStatus('Server failed: $e');
      return false;
    }
  }

  /// Syncs multi-language audio state from a freshly resolved server map.
  /// [_masterStreamUrl] is only set when the play URL is the HLS master (so
  /// alternate renditions actually exist); pinned variants carry no audio
  /// groups and hide the audio button.
  void _syncAudioFromStream(Map<String, dynamic> stream) {
    final tracks = StreamAudioHelper.tracksOf(stream);
    final url = stream['url']?.toString() ?? '';
    final separate = stream['separateAudio'] == true;
    var isMaster = separate;
    if (!isMaster) {
      final autoUrl = _parseQualities(
        stream['qualities'],
      ).where((q) => q.height == 0).firstOrNull?.url;
      isMaster = autoUrl != null && autoUrl.isNotEmpty && autoUrl == url;
    }
    _audioTracks = tracks;
    _baseStreamUrl = url;
    _hasAlternateAudio = tracks.any((track) {
      final trackUrl = track['url']?.toString() ?? '';
      return trackUrl.isNotEmpty && trackUrl != url;
    });
    _masterStreamUrl = tracks.length > 1 && isMaster ? url : null;
  }

  /// Refreshes audio state from the currently selected server after a
  /// background re-discovery hands it a fresh signed URL.
  void _resyncAudioFromDiscovery() {
    final key = _selectedServerKey;
    if (key == null) return;
    final current = _availableServers
        .where((s) => _serverIdentity(s) == key)
        .firstOrNull;
    if (current != null) _syncAudioFromStream(current);
  }

  /// Effective play URL honoring the preferred audio language. Returns the
  /// original URL unless a rewritten local master could be built.
  Future<({String url, bool isLocalFile})> _resolveAudioUrl(
    String url,
    Map<String, String> headers,
    bool isHls,
  ) async {
    final preferred = _preferredAudioLanguage;
    final master = _masterStreamUrl;
    if (preferred == null ||
        preferred.isEmpty ||
        !isHls ||
        _audioTracks.length <= 1 ||
        master == null ||
        master.isEmpty) {
      return (url: url, isLocalFile: false);
    }
    final local = await HlsAudioHelper.buildMasterWithPreferredAudio(
      masterUrl: master,
      headers: headers,
      language: preferred,
    );
    if (local == null) return (url: url, isLocalFile: false);
    return (url: local, isLocalFile: true);
  }

  String get _audioLabel {
    final preferred = _preferredAudioLanguage;
    if (preferred == null || preferred.isEmpty) return 'Audio';
    for (final track in _audioTracks) {
      if (StreamAudioHelper.matches(track, preferred)) {
        return StreamAudioHelper.displayName(track);
      }
    }
    return preferred;
  }

  List<_StreamQuality> _parseQualities(dynamic value) {
    if (value is! List) return const [];
    return value
        .whereType<Map>()
        .map((quality) {
          return _StreamQuality(
            label: quality['label']?.toString() ?? 'Auto',
            url: quality['url']?.toString() ?? '',
            height: int.tryParse(quality['height']?.toString() ?? '') ?? 0,
          );
        })
        .where((quality) => quality.url.isNotEmpty)
        .toList();
  }

  List<_SubtitleTrack> _parseSubtitleTracks(dynamic value) {
    if (value is! List) return const [];
    return value
        .whereType<Map>()
        .map(
          (subtitle) => _SubtitleTrack(
            label: subtitle['label']?.toString() ?? 'Subtitle',
            url: subtitle['url']?.toString() ?? '',
            isDefault: subtitle['default'] == true,
            source: subtitle['source']?.toString() ?? '',
          ),
        )
        .where((subtitle) => subtitle.url.isNotEmpty)
        .toList();
  }

  /// Unions the subtitle tracks of every discovered server so subtitles from
  /// other servers are available when the current one has none (e.g. RPM).
  /// Tracks are tagged with the owning server's display label (for grouping)
  /// and headers (for fetching).
  List<_SubtitleTrack> _unionSubtitleTracks() {
    final result = <_SubtitleTrack>[];
    final seen = <String>{};
    // The currently playing server's group goes first so its subtitles are
    // the easiest to reach; the rest follow in discovery order.
    final servers = [..._availableServers]
      ..sort((a, b) {
        final aSelected = _serverIdentity(a) == _selectedServerKey ? 0 : 1;
        final bSelected = _serverIdentity(b) == _selectedServerKey ? 0 : 1;
        return aSelected - bSelected;
      });
    for (final server in servers) {
      final source = server['source']?.toString() ?? 'Server';
      final route = server['server']?.toString() ?? source;
      final group = route == source ? source : '$source via $route';
      final headers = _parseStreamHeaders(server);
      for (final track in _parseSubtitleTracks(server['subtitles'])) {
        if (!seen.add(track.url)) continue;
        result.add(
          _SubtitleTrack(
            label: track.label,
            url: track.url,
            isDefault: track.isDefault,
            source: track.source,
            group: group,
            headers: headers,
          ),
        );
      }
    }
    // Online-search downloads survive server/quality re-unions.
    for (final track in _onlineSubtitleTracks) {
      if (!seen.add(track.url)) continue;
      result.add(track);
    }
    return result;
  }

  /// Display identity for a subtitle tile: owning server group + track label.
  /// Used both as the selection value and the subtitle button label, so the
  /// value stays unique across servers (e.g. "RPM via Vidflix · English").
  String _subtitleTileValue(_SubtitleTrack track) {
    final group = track.group.isNotEmpty
        ? track.group
        : (track.source.isEmpty ? 'Other' : track.source);
    return '$group · ${track.label}';
  }

  /// Re-sync the subtitle button label / radio group value after
  /// `_subtitleTracks` is rebuilt.  Group names change when servers are
  /// re-discovered, so the old tile value no longer matches any track.
  /// Match by the stable URL to find the correct new value.
  void _resyncSubtitleSelection() {
    final current = _selectedSubtitle.value;
    if (current == 'Off') return;
    // Already valid?  Nothing to do.
    if (_subtitleTracks.any((t) => _subtitleTileValue(t) == current)) return;
    final url = _selectedSubtitleUrl;
    if (url == null || url.isEmpty) {
      _selectedSubtitle.value = 'Off';
      return;
    }
    final match = _subtitleTracks.where((t) => t.url == url).firstOrNull;
    if (match != null) {
      _selectedSubtitle.value = _subtitleTileValue(match);
    } else {
      // Track no longer available (different server set).
      _selectedSubtitle.value = 'Off';
      _selectedSubtitleUrl = null;
      _activeSubtitles.value = const [];
    }
  }

  Map<String, String> _parseStreamHeaders(Map<String, dynamic> stream) {
    final headers = <String, String>{};
    if (stream['referer'] != null) {
      headers['Referer'] = stream['referer'].toString();
    }
    final rawHeaders = stream['headers'];
    if (rawHeaders is Map) {
      rawHeaders.forEach((key, value) {
        headers[key.toString()] = value.toString();
      });
    }
    return headers;
  }

  Future<void> _discoverAvailableServers(int generation) async {
    final streams = await DirectM3u8Service.fetchAvailableStreams(
      title: _resolverTitle,
      tmdbId: widget.tmdbId,
      isMovie: widget.isMovie,
      season: _currentSeason,
      episode: _currentEpisode,
    );
    if (!mounted || generation != _serverDiscoveryGeneration) return;
    // Replace stale entries with freshly extracted URLs: stream URLs (esp.
    // VixSrc tokens) expire quickly, so reusing them when switching servers
    // or recovering playback causes a "Source error". Servers are keyed by
    // identity (their provider/server name) rather than URL, because the same
    // server gets a brand-new signed URL on every extraction: matching by URL
    // would drop the currently playing server from the sheet or duplicate it,
    // and the selection highlight would never land.
    final seen = <String>{};
    // Keep entries with empty urls too: they represent servers that failed
    // extraction/validation but must still be listed so the user can select
    // and re-fetch them. Dedupe by identity rather than URL so a failed
    // server doesn't collapse into one row.
    final fresh = streams.where((s) {
      final key = _serverIdentity(s);
      if (key.isEmpty) return false;
      return seen.add(key);
    }).toList();
    setState(() {
      final byIdentity = <String, Map<String, dynamic>>{};
      // Prefer the server row that has a playable URL; a failed row for the
      // same identity must not shadow a working one.
      for (final stream in fresh) {
        final key = _serverIdentity(stream);
        final existing = byIdentity[key];
        final incomingHasUrl = (stream['url']?.toString() ?? '').isNotEmpty;
        final existingHasUrl =
            (existing?['url']?.toString() ?? '').isNotEmpty || existing == null;
        if (existing == null || (incomingHasUrl && !existingHasUrl)) {
          byIdentity[key] = stream;
        }
      }
      // Keep the currently playing server in the sheet so it is always shown
      // and highlighted, even when this round of extraction dropped it. Match
      // by identity, not URL: the playing URL may already be a fresh one from
      // an earlier discovery round, so URL matching would drop it again.
      final playingKey = _selectedServerKey;
      final playing = playingKey == null
          ? null
          : _availableServers
                .where((s) => _serverIdentity(s) == playingKey)
                .firstOrNull;
      if (playing != null) {
        final key = _serverIdentity(playing);
        final existing = byIdentity[key];
        final playingHasUrl = (playing['url']?.toString() ?? '').isNotEmpty;
        final existingHasUrl = (existing?['url']?.toString() ?? '').isNotEmpty;
        if (existing == null || (playingHasUrl && !existingHasUrl)) {
          byIdentity[key] = playing;
        }
      }
      // Available (playable) servers first, failed (re-fetchable) ones last.
      // Viduki servers are prioritized at the top since they consistently return streams.
      final servers = byIdentity.values.toList()
        ..sort((a, b) {
          final aOk = (a['url']?.toString() ?? '').isNotEmpty ? 0 : 1;
          final bOk = (b['url']?.toString() ?? '').isNotEmpty ? 0 : 1;
          if (aOk != bOk) return aOk - bOk;
          // Among available servers, Viduki first
          final aName =
              (a['server']?.toString() ?? a['source']?.toString() ?? '')
                  .toLowerCase();
          final bName =
              (b['server']?.toString() ?? b['source']?.toString() ?? '')
                  .toLowerCase();
          final aIsViduki = aName.contains('viduki') ? 0 : 1;
          final bIsViduki = bName.contains('viduki') ? 0 : 1;
          return aIsViduki - bIsViduki;
        });
      _availableServers = servers;
      _serversLoading = false;
      // Rebuild the subtitle menu from every server's tracks so fallback
      // subtitles from other servers stay available after re-discovery.
      _subtitleTracks = _unionSubtitleTracks();
      _resyncSubtitleSelection();
      _resyncAudioFromDiscovery();
    });
  }

  /// Stable identity for a server entry: the provider/server name from the
  /// extractor (e.g. "RPM video"), falling back to the source name or URL.
  String _serverIdentity(Map<String, dynamic> stream) {
    final server = stream['server']?.toString();
    if (server != null && server.isNotEmpty) return server;
    final source = stream['source']?.toString();
    if (source != null && source.isNotEmpty) return source;
    return stream['url']?.toString() ?? '';
  }

  Future<bool> _replacePlayer(
    String url, {
    required Map<String, String> headers,
    required String source,
    required List<_StreamQuality> qualities,
    required String selectedQuality,
    required bool isHls,
    required Duration position,
    required bool shouldPlay,
    bool isLocalFile = false,
    String? remoteUrl,
  }) async {
    // Never build a player for a screen the user already left. Any in-flight
    // load/switch runs for up to 30s, and `mounted` stays true until dispose()
    // fires after the pop transition — so without this the switch would finish,
    // call play() and hand a live controller to a screen with no UI attached,
    // leaving audio playing in the background from position 0.
    if (_isLeaving) return false;

    // Newest build wins. Bumping first means any older rebuild still awaiting
    // initialize()/seek() notices it was superseded and dies here instead of
    // installing a second, unmanaged player.
    final generation = ++_playerBuildGeneration;

    // A build that is still initializing is not reachable through
    // _videoPlayerController, so it has to be torn down explicitly.
    final pending = _pendingController;
    if (pending != null) {
      _pendingController = null;
      try {
        await pending.dispose().timeout(const Duration(seconds: 3));
      } catch (_) {
        // Same benign teardown race as below.
      }
    }

    // Dispose old player before creating new one to free decoder/surface.
    // Await with short timeout and swallow fvp Bad state race where native
    // still sends events after StreamController closed during rapid switches.
    final previousVideo = _videoPlayerController;
    _videoPlayerController = null;
    if (previousVideo != null) {
      try {
        previousVideo.removeListener(_handlePlaybackChanged);
      } catch (_) {}
      try {
        await previousVideo.dispose().timeout(const Duration(seconds: 3));
      } catch (_) {
        // Ignore Bad state: Cannot add event after closing and timeout
      }
    }
    if (!mounted || _isLeaving) return false;

    // A preferred audio language plays through a rewritten local master that
    // pins the language as DEFAULT. Segments stay remote and keep the stream
    // headers (cookies/referer), which ExoPlayer applies at its HTTP layer.
    final controller = VideoPlayerController.networkUrl(
      isLocalFile ? Uri.file(url) : Uri.parse(url),
      httpHeaders: headers,
      formatHint: isHls ? VideoFormat.hls : VideoFormat.other,
      videoPlayerOptions: VideoPlayerOptions(
        backBufferDurationMs: 60000,
        allowBackgroundPlayback: true,
      ),
    );
    _pendingController = controller;

    try {
      _showStatus(
        position == Duration.zero
            ? 'Loading video...'
            : 'Switching to $selectedQuality...',
      );
      // Timeout after 30s - HLS playlists on slow/CDN can take >15s, and
      // 15s was causing working servers to be marked as failed with
      // TimeoutException after 0:00:15.000000
      await controller.initialize().timeout(const Duration(seconds: 30));
      // Re-check before touching playback: the user may have hit back or
      // picked another server while initialize() ran, in which case this
      // controller must die here rather than start playing on its own.
      if (!_isBuildCurrent(generation)) {
        await _discardPendingController(controller);
        return false;
      }
      if (position > Duration.zero) await controller.seekTo(position);
      if (!_isBuildCurrent(generation)) {
        await _discardPendingController(controller);
        return false;
      }
      // Re-check the INTENT flag at the moment of play(): shouldPlay was
      // captured when this rebuild started, and the user may have paused
      // (e.g. while the server menu was still loading) since then.
      if (shouldPlay && _userWantsPlayback) await controller.play();
      if (!_isBuildCurrent(generation)) {
        await _discardPendingController(controller);
        return false;
      }

      controller.addListener(_handlePlaybackChanged);
      setState(() {
        _videoPlayerController = controller;
        _useNativePlayer = true;
        _currentSource = source;
        _streamHeaders = headers;
        _qualities = qualities;
        _selectedQuality = selectedQuality;
        _isBuffering = controller.value.isBuffering;
        _isSwitchingQuality = false;
        _videoInitialized = true;
        _currentStreamUrl = remoteUrl ?? url;
        _currentStreamIsHls = isHls;
      });

      _startProgressSaving();
      _startStallWatchdog();
      return true;
    } catch (e) {
      // A superseded build is a normal race, not a playback failure: never
      // rethrow into the caller or it will report an error the user caused
      // nothing about (and the newer build is already taking over).
      if (!_isBuildCurrent(generation)) {
        await _discardPendingController(controller);
        return false;
      }
      debugPrint('M3U8VideoPlayer: init failed ($url): $e');
      try {
        await controller.dispose();
      } catch (_) {}
      rethrow;
    } finally {
      if (identical(_pendingController, controller)) {
        _pendingController = null;
      }
    }
  }

  /// True while [generation] is still the newest rebuild and the screen lives.
  bool _isBuildCurrent(int generation) =>
      mounted && !_isLeaving && generation == _playerBuildGeneration;

  /// Tears down the controller of a build that lost the race or was superseded.
  Future<void> _discardPendingController(VideoPlayerController controller) async {
    if (identical(_pendingController, controller)) _pendingController = null;
    try {
      await controller.dispose().timeout(const Duration(seconds: 3));
    } catch (_) {
      // Already disposed by the build that superseded this one.
    }
  }

  /// Convenience for teardown paths: discards whatever build is in flight.
  Future<void> _discardPendingControllerOf(VideoPlayerController? controller) async {
    if (controller == null) return;
    await _discardPendingController(controller);
  }

  void _handlePlaybackChanged() {
    final controller = _videoPlayerController;
    if (!mounted || controller == null) return;
    final value = controller.value;
    if (value.position > Duration.zero) _lastStablePosition = value.position;
    if (value.hasError && _offlinePath != null && _error == null) {
      controller.pause();
      setState(() {
        _error =
            'This downloaded video is incomplete or damaged and cannot continue. '
            'Delete it and download it again.';
      });
      return;
    }
    if (value.hasError && !_recoveringPlayback) {
      // Keep trying other servers so a single dead source (e.g. an expired
      // RPM HLS URL that ExoPlayer rejects) never blocks playback. Recovery
      // re-resolves streams fresh, so allow a few rounds without a known next.
      final hasNext = _nextServerAfter(_currentStreamUrl ?? '') != null;
      if (_playbackRetryCount < 1 || hasNext) {
        unawaited(_recoverPlayback());
      }
    }
    final isBuffering = value.isBuffering;
    var shouldRebuild = isBuffering != _isBuffering;
    _isBuffering = isBuffering;

    if (!widget.isMovie &&
        _nextEpisode != null &&
        !_nextEpisodeCancelled &&
        value.duration > Duration.zero) {
      final remaining = value.duration - value.position;
      final countdown = remaining.inSeconds.clamp(0, 30);
      final showNext = remaining <= const Duration(seconds: 30);
      if (showNext != _showNextEpisode || countdown != _nextEpisodeCountdown) {
        _showNextEpisode = showNext;
        _nextEpisodeCountdown = countdown;
        shouldRebuild = true;
      }
      if (remaining <= const Duration(milliseconds: 500) &&
          value.isPlaying &&
          !_loadingNextEpisode) {
        unawaited(_playNextEpisode());
      }
    }
    if (shouldRebuild) setState(() {});
    MediaSessionHandler.instance.updateMetadata(
      title: _currentTitle,
      artist: widget.isMovie
          ? 'Movie'
          : 'S${_currentSeason.toString().padLeft(2, '0')}E${_currentEpisode.toString().padLeft(2, '0')}',
      duration: value.duration,
      artUri: _posterUrl.isNotEmpty ? _posterUrl : null,
    );
    MediaSessionHandler.instance.updatePlaybackState(
      isPlaying: value.isPlaying,
      position: value.position,
      duration: value.duration,
    );
  }

  Map<String, dynamic>? _nextServerAfter(String currentUrl) {
    if (_availableServers.length <= 1 || currentUrl.isEmpty) return null;
    final currentKey = _selectedServerKey;
    final currentIndex = _availableServers.indexWhere(
      (s) => _serverIdentity(s) == currentKey,
    );
    final start =
        (currentIndex < 0 ? 0 : currentIndex + 1) % _availableServers.length;
    for (var i = 0; i < _availableServers.length; i++) {
      final server = _availableServers[(start + i) % _availableServers.length];
      final serverKey = _serverIdentity(server);
      if (serverKey.isEmpty ||
          serverKey == currentKey ||
          _failedServerKeys.contains(serverKey)) {
        continue;
      }
      return server;
    }
    return null;
  }

  Future<void> _recoverPlayback() async {
    final url = _currentStreamUrl;
    if (url == null || _recoveringPlayback || _isLeaving) return;
    _recoveringPlayback = true;
    _playbackRetryCount++;
    if (mounted) {
      setState(() {
        _isBuffering = true;
        _statusMessage = 'Stream interrupted. Trying next server...';
      });
    }
    await Future<void>.delayed(Duration(seconds: 2));
    try {
      // Re-resolve streams fresh before switching: discovered URLs (esp.
      // VixSrc tokens) expire quickly, so prefer freshly extracted servers
      // over stale entries that ExoPlayer rejects with a source error.
      await _discoverAvailableServers(_serverDiscoveryGeneration);
      if (!mounted || _isLeaving) return;
      // After the first failure, switch to another server immediately
      // instead of retrying a dead stream.
      final shouldSwitch = _playbackRetryCount >= 1;
      if (shouldSwitch) {
        final currentKey = _selectedServerKey;
        if (currentKey != null) _failedServerKeys.add(currentKey);
        final candidates = _availableServers
            .where(
              (s) =>
                  (s['url']?.toString() ?? '').isNotEmpty &&
                  _serverIdentity(s) != currentKey,
            )
            .toList();
        // Try next servers immediately without sequential HEAD validation - was
        // causing stuck at "Switching to Auto" (6x 15s validates).
        var switched = false;
        for (final server in candidates) {
          _showStatus(
            'Loading a working stream from ${_sourceLabel(server)}...',
          );
          switched = await _tryPlayServer(
            server,
            position: _lastStablePosition,
            primaryUrl: url,
            // Recovering from a stall is not a request to start playing: if the
            // user paused (or the screen is going away) the replacement must
            // come up paused, otherwise it looks like the app un-paused itself.
            shouldPlay: _userWantsPlayback,
          );
          if (switched) break;
          if (_isLeaving) return;
        }
        if (!switched) {
          _showStatus(
            'All streams are unavailable right now. Please try again later.',
          );
        }
      } else {
        await _replacePlayer(
          url,
          headers: _streamHeaders,
          source: _currentSource ?? 'Unknown',
          qualities: _qualities,
          selectedQuality: _selectedQuality,
          isHls: _currentStreamIsHls,
          position: _lastStablePosition,
          shouldPlay: _userWantsPlayback,
        );
      }
      _playbackRetryCount = 0;
    } catch (error) {
      debugPrint('M3U8Player: Playback recovery failed: $error');
      if (mounted && !_isLeaving && _playbackRetryCount >= 1) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'The current server stopped responding. Please try again.',
            ),
          ),
        );
      }
    } finally {
      _recoveringPlayback = false;
    }
  }

  Future<void> _playNextEpisode() async {
    final next = _nextEpisode;
    if (next == null || _loadingNextEpisode || _isLeaving) return;
    _loadingNextEpisode = true;
    // Clear next-episode state immediately so the old controller's
    // _handlePlaybackChanged doesn't re-show the popup for the next-next episode.
    if (mounted) {
      setState(() {
        _nextEpisode = null;
        _nextEpisodeCancelled = true;
        _showNextEpisode = false;
        _isSwitchingQuality = true;
        _statusMessage = 'Loading next episode...';
      });
    }
    await _saveProgress();
    if (_isLeaving) return;
    _currentSeason = (next['season'] as num).toInt();
    _currentEpisode = (next['episode'] as num).toInt();
    _currentTitle =
        '${next['seriesTitle']} - S${_currentSeason}E$_currentEpisode: ${next['name']}';
    _downloadCompleted = false;
    unawaited(_refreshDownloadStatus());
    if (_offlinePath != null) {
      _offlinePath = next['offlinePath']?.toString();
      _offlineSubtitles = (next['subtitles'] as List? ?? const [])
          .whereType<Map>()
          .map(
            (track) =>
                track.map((key, value) => MapEntry(key.toString(), value)),
          )
          .toList();
    }
    try {
      await _loadStream(resume: false);
    } finally {
      _loadingNextEpisode = false;
      if (mounted) setState(() => _isSwitchingQuality = false);
    }
  }

  void _cancelNextEpisode() {
    setState(() {
      _nextEpisodeCancelled = true;
      _showNextEpisode = false;
    });
  }

  void _startProgressSaving() {
    _progressTimer?.cancel();
    _progressTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (_isLeaving) return;
      _saveProgress();
      final c = _videoPlayerController;
      if (c != null && c.value.isInitialized) {
        MediaSessionHandler.instance.updateProgress(
          isPlaying: c.value.isPlaying,
          position: c.value.position,
          duration: c.value.duration,
        );
      }
    });
  }

  Future<void> _saveProgress() async {
    final c = _videoPlayerController;
    if (c == null || !c.value.isInitialized) return;
    await _writeProgress(c.value.position, c.value.duration);
  }

  Future<void> _writeProgress(Duration position, Duration duration) async {
    if (position <= Duration.zero || duration <= Duration.zero) return;
    await WatchHistoryService.saveWatchProgress(
      tmdbId: widget.tmdbId,
      title: _currentTitle,
      seriesTitle: widget.isMovie ? null : _resolverTitle,
      isMovie: widget.isMovie,
      season: _currentSeason,
      episode: _currentEpisode,
      posterUrl: _posterUrl,
      position: position,
      duration: duration,
      genreIds: widget.genreIds,
    );
  }

  Future<void> _exitPlayer() async {
    if (_isLeaving) return;
    _isLeaving = true;
    // A build still initializing is not visible through _videoPlayerController
    // but WILL start playing if it completes — kill it before persisting.
    await _discardPendingControllerOf(_pendingController);
    // Silence and free the decoder FIRST, then persist. _saveProgress is a
    // Firestore write that can take seconds; awaiting it before pausing left
    // audio running after the user pressed back. Snapshot the values while the
    // controller is still alive so the write still has them.
    final controller = _videoPlayerController;
    _videoPlayerController = null;
    final position = controller?.value.position ?? Duration.zero;
    final duration = controller?.value.duration ?? Duration.zero;
    if (controller != null) {
      controller.removeListener(_handlePlaybackChanged);
      controller.pause();
      await controller.dispose();
    }
    await _writeProgress(position, duration);
    if (mounted) Navigator.of(context).pop(true);
  }

  void _minimizePlayer() async {
    if (_isLeaving) return;
    _isLeaving = true;
    unawaited(_discardPendingControllerOf(_pendingController));
    final controller = _videoPlayerController;
    // Snapshot before the handoff, then persist after the pop: the Firestore
    // write takes seconds and must not delay the PiP bar appearing.
    final position = controller?.value.position ?? Duration.zero;
    final duration = controller?.value.duration ?? Duration.zero;
    if (controller != null && controller.value.isInitialized) {
      _isMinimizing = true;
      // Find the current server to get its qualities data
      final currentServer = _selectedServerKey != null
          ? _availableServers.firstWhere(
              (s) => _serverIdentity(s) == _selectedServerKey,
              orElse: () => {},
            )
          : null;
      MiniplayerService.instance.minimize(
        controller: controller,
        title: _currentTitle,
        tmdbId: widget.tmdbId,
        isMovie: widget.isMovie,
        season: _currentSeason,
        episode: _currentEpisode,
        genreIds: widget.genreIds,
        availableServers: _availableServers,
        selectedQuality: _selectedQuality,
        selectedServerKey: _selectedServerKey ?? '',
        currentSource: _currentSource ?? '',
        streamHeaders: _streamHeaders,
        selectedSubtitleValue: _selectedSubtitle.value,
        selectedSubtitleUrl: _selectedSubtitleUrl ?? '',
        activeSubtitleCues: _activeSubtitles.value
            .map(
              (s) => MiniSubtitleCue(start: s.start, end: s.end, text: s.text),
            )
            .toList(),
        qualitiesRaw: currentServer != null && currentServer.isNotEmpty
            ? (currentServer['qualities'] as List<dynamic>? ?? const [])
                  .whereType<Map<String, dynamic>>()
                  .toList()
            : const [],
      );
    }
    if (mounted) Navigator.of(context).pop(true);
    await _writeProgress(position, duration);
  }

  void _cycleAspectRatio() {
    setState(() {
      _aspectRatioMode = switch (_aspectRatioMode) {
        _AspectRatioMode.fit => _AspectRatioMode.stretch,
        _AspectRatioMode.stretch => _AspectRatioMode.zoom,
        _AspectRatioMode.zoom => _AspectRatioMode.fit,
      };
    });
  }

  String get _aspectRatioLabel => switch (_aspectRatioMode) {
    _AspectRatioMode.fit => 'Fit',
    _AspectRatioMode.stretch => 'Stretch',
    _AspectRatioMode.zoom => 'Zoom',
  };

  Future<void> _showServerPicker() async {
    if (!mounted || _availableServers.isEmpty) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xff202124),
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              leading: const Icon(Icons.dns_outlined, color: Colors.white),
              title: const Text(
                'Select server',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
              subtitle: Text(
                _serversLoading
                    ? 'Checking other servers...'
                    : '${_availableServers.length} server${_availableServers.length == 1 ? '' : 's'}',
                style: const TextStyle(color: Colors.white60),
              ),
              trailing: _serversLoading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.red,
                      ),
                    )
                  : null,
            ),
            ..._availableServers.asMap().entries.map((entry) {
              final stream = entry.value;
              final source = stream['source']?.toString() ?? 'Server';
              final server = stream['server']?.toString() ?? source;
              final method = stream['method']?.toString();
              final selected = _serverIdentity(stream) == _selectedServerKey;
              final url = stream['url']?.toString() ?? '';
              final available = url.isNotEmpty;
              final audioBadge = StreamAudioHelper.badgeFor(stream);
              final serverSuffix = server == source
                  ? 'Server ${entry.key + 1}'
                  : 'Via $server · Server ${entry.key + 1}';
              final subtitleText = !available
                  ? 'Unavailable · Tap to retry'
                  : [
                      if (method != null) method,
                      serverSuffix,
                      if (audioBadge.isNotEmpty) '🔊 $audioBadge',
                    ].join(' · ');
              return ListTile(
                leading: Icon(
                  selected
                      ? Icons.check_circle
                      : available
                      ? Icons.play_circle_outline
                      : Icons.refresh,
                  color: selected
                      ? Colors.red
                      : available
                      ? Colors.white70
                      : Colors.orangeAccent,
                ),
                title: Text(
                  source,
                  style: const TextStyle(color: Colors.white),
                ),
                subtitle: Text(
                  subtitleText,
                  style: TextStyle(
                    color: available ? Colors.white54 : Colors.orangeAccent,
                  ),
                ),
                enabled: !selected && !_isSwitchingServer && !_isRetryingServer,
                onTap: selected
                    ? null
                    : () {
                        Navigator.of(sheetContext).pop();
                        if (available) {
                          _switchServer(stream);
                        } else {
                          _retryServer(stream);
                        }
                      },
              );
            }),
          ],
        ),
      ),
    );
  }

  Future<void> _switchServer(Map<String, dynamic> stream) async {
    if (_isSwitchingServer) return;
    final url = stream['url']?.toString() ?? '';
    if (url.isEmpty || _serverIdentity(stream) == _selectedServerKey) return;
    final current = _videoPlayerController;
    // Allow switching even when no player exists (initial load failed) - initialize directly
    if (current == null) {
      final headers = _parseStreamHeaders(stream);
      final qualities = _parseQualities(stream['qualities']);
      _separateAudio = stream['separateAudio'] == true;
      _syncAudioFromStream(stream);
      var selectedQuality = 'Auto';
      for (final q in qualities) if (q.url == url) selectedQuality = q.label;
      final position = _lastStablePosition;
      setState(() {
        _isSwitchingServer = true;
        _error = null;
        _subtitleTracks = _unionSubtitleTracks();
        _selectedSubtitle.value = 'Off';
        _activeSubtitles.value = const [];
      });
      try {
        final ok = await _initializePlayer(
          url,
          headers: headers,
          source: stream['source']?.toString() ?? 'Server',
          qualities: qualities,
          selectedQuality: selectedQuality,
          isHls:
              stream['type'] == 'direct_m3u8' ||
              url.toLowerCase().contains('.m3u8'),
          position: position,
          shouldPlay: _userWantsPlayback,
        );
        if (ok && mounted)
          setState(() => _selectedServerKey = _serverIdentity(stream));
      } finally {
        if (mounted) setState(() => _isSwitchingServer = false);
      }
      return;
    }

    final oldTracks = _subtitleTracks;
    final oldSelectedSubtitle = _selectedSubtitle.value;
    final oldSubtitles = _activeSubtitles.value;
    final headers = _parseStreamHeaders(stream);
    final qualities = _parseQualities(stream['qualities']);
    _separateAudio = stream['separateAudio'] == true;
    _syncAudioFromStream(stream);
    var selectedQuality = 'Auto';
    for (final quality in qualities) {
      if (quality.url == url) selectedQuality = quality.label;
    }
    final position = current.value.position > Duration.zero
        ? current.value.position
        : _lastStablePosition;
    // Deliberately the intent flag, not `current.value.isPlaying`: the live
    // flag is still true for a tick or two after pause() and is true while a
    // paused player stalls buffering, either of which used to restart playback.
    final shouldPlay = _userWantsPlayback;
    setState(() {
      _isSwitchingServer = true;
      _subtitleTracks = _unionSubtitleTracks();
      _selectedSubtitle.value = 'Off';
      _activeSubtitles.value = const [];
    });
    try {
      final isHls =
          stream['type'] == 'direct_m3u8' ||
          url.toLowerCase().contains('.m3u8');
      final resolved = await _resolveAudioUrl(url, headers, isHls);
      if (!mounted || _isLeaving) return;
      await _replacePlayer(
        resolved.url,
        headers: headers,
        source: stream['source']?.toString() ?? 'Server',
        qualities: qualities,
        selectedQuality: resolved.isLocalFile ? 'Auto' : selectedQuality,
        isHls: isHls,
        position: position,
        shouldPlay: shouldPlay,
        isLocalFile: resolved.isLocalFile,
        remoteUrl: url,
      );
      if (mounted) {
        setState(() => _selectedServerKey = _serverIdentity(stream));
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _subtitleTracks = oldTracks;
        _selectedSubtitle.value = oldSelectedSubtitle;
        _activeSubtitles.value = oldSubtitles;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not switch server: $error')),
      );
    } finally {
      _isSwitchingServer = false;
      if (mounted) setState(() {});
    }
  }

  /// Re-fetches a server that previously failed to extract/validate and, if
  /// it now yields a playable URL, switches to it.
  Future<void> _retryServer(Map<String, dynamic> stream) async {
    if (_isSwitchingServer || _isRetryingServer) return;
    final identity = _serverIdentity(stream);
    if (identity.isEmpty) return;
    setState(() => _isRetryingServer = true);
    _showStatus('Fetching ${_sourceLabel(stream, fallback: identity)}...');
    try {
      final resolved = await DirectM3u8Service.resolveServer(
        serverName: identity,
        title: _resolverTitle,
        tmdbId: widget.tmdbId,
        isMovie: widget.isMovie,
        season: _currentSeason,
        episode: _currentEpisode,
      );
      if (!mounted) return;
      if (resolved == null || (resolved['url']?.toString() ?? '').isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$identity is still unavailable')),
        );
        return;
      }
      resolved['available'] = true;
      setState(() {
        final idx = _availableServers.indexWhere(
          (s) => _serverIdentity(s) == identity,
        );
        if (idx >= 0) {
          _availableServers = [..._availableServers]..[idx] = resolved;
        }
        _subtitleTracks = _unionSubtitleTracks();
      });
      if (_videoPlayerController == null) {
        // Error-view state: no live player to switch, initialize from scratch.
        final resolvedUrl = resolved['url']!.toString();
        final headers = _parseStreamHeaders(resolved);
        final qualities = _parseQualities(resolved['qualities']);
        _separateAudio = resolved['separateAudio'] == true;
        _syncAudioFromStream(resolved);
        var selectedQuality = 'Auto';
        for (final quality in qualities) {
          if (quality.url == resolvedUrl) {
            selectedQuality = quality.label;
            break;
          }
        }
        await _initializePlayer(
          resolvedUrl,
          headers: headers,
          source: resolved['source']?.toString() ?? identity,
          qualities: qualities,
          selectedQuality: selectedQuality,
          isHls:
              resolved['type'] == 'direct_m3u8' ||
              resolvedUrl.toLowerCase().contains('.m3u8'),
          shouldPlay: _userWantsPlayback,
        );
        if (mounted) {
          setState(() => _selectedServerKey = _serverIdentity(resolved));
        }
      } else {
        await _switchServer(resolved);
      }
    } finally {
      if (mounted) setState(() => _isRetryingServer = false);
    }
  }

  Future<void> _showQualityPicker() async {
    if (!mounted || _qualities.length < 2) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xff202124),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              leading: Icon(Icons.hd, color: Colors.white),
              title: Text(
                'Video quality',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            ..._qualities.map(
              (quality) => RadioListTile<String>(
                value: quality.label,
                groupValue: _selectedQuality,
                activeColor: Colors.red,
                title: Text(
                  quality.label,
                  style: const TextStyle(color: Colors.white),
                ),
                onChanged: (_) {
                  Navigator.of(sheetContext).pop();
                  _switchQuality(quality);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showAudioPicker() async {
    if (!mounted ||
        _audioTracks.length <= 1 ||
        (_masterStreamUrl == null && !_hasAlternateAudio)) {
      return;
    }
    final currentLabel = _audioLabel;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xff202124),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              leading: Icon(Icons.audiotrack, color: Colors.white),
              title: Text(
                'Audio language',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  RadioListTile<String>(
                    value: 'Default',
                    groupValue: _preferredAudioLanguage == null
                        ? 'Default'
                        : currentLabel,
                    activeColor: Colors.red,
                    title: const Text(
                      'Default',
                      style: TextStyle(color: Colors.white),
                    ),
                    subtitle: const Text(
                      'Original audio track',
                      style: TextStyle(color: Colors.white60, fontSize: 12),
                    ),
                    onChanged: (_) {
                      Navigator.of(sheetContext).pop();
                      _applyAudioLanguage(null);
                    },
                  ),
                  ..._audioTracks.map(
                    (track) => RadioListTile<String>(
                      value: StreamAudioHelper.displayName(track),
                      groupValue: _preferredAudioLanguage == null
                          ? 'Default'
                          : currentLabel,
                      activeColor: Colors.red,
                      title: Text(
                        StreamAudioHelper.displayName(track),
                        style: const TextStyle(color: Colors.white),
                      ),
                      subtitle: (track['language']?.toString() ?? '').isNotEmpty
                          ? Text(
                              track['language'].toString(),
                              style: const TextStyle(
                                color: Colors.white60,
                                fontSize: 12,
                              ),
                            )
                          : null,
                      onChanged: (_) {
                        Navigator.of(sheetContext).pop();
                        final language =
                            StreamAudioHelper.languageOf(track).isNotEmpty
                            ? StreamAudioHelper.languageOf(track)
                            : StreamAudioHelper.labelOf(track);
                        _applyAudioLanguage(language);
                      },
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Switches the audio language by reloading the (rewritten) master at the
  /// current position. Video quality becomes adaptive while a preference is
  /// active, since pinned variants carry no alternate renditions.
  Future<void> _applyAudioLanguage(String? language) async {
    if (_isSwitchingAudio || language == _preferredAudioLanguage) return;
    final controller = _videoPlayerController;
    if (controller != null) {
      // Whole alternate dub streams (NetMirror): the language is a separate
      // MP4, so play that URL instead of rewriting an HLS master.
      final alternate =
          language == null ? null : _alternateAudioTrack(language);
      final base = _baseStreamUrl;
      String? target;
      if (alternate != null) {
        target = alternate['url']?.toString();
      } else if (language == null && base != null && base != _currentStreamUrl) {
        target = base;
      }
      if (target != null && target.isNotEmpty) {
        await _switchToAlternateAudio(target, language);
        return;
      }
    }
    if (controller == null || _masterStreamUrl == null) {
      setState(() => _preferredAudioLanguage = language);
      return;
    }
    _isSwitchingAudio = true;
    final position = controller.value.position;
    // See _switchServer: intent flag, not the lagging live isPlaying.
    final shouldPlay = _userWantsPlayback;
    final master = _masterStreamUrl!;
    setState(() => _preferredAudioLanguage = language);
    try {
      _showStatus(
        language == null ? 'Restoring default audio...' : 'Switching audio...',
      );
      final resolved = await _resolveAudioUrl(
        master,
        _streamHeaders,
        _currentStreamIsHls,
      );
      if (!mounted || _isLeaving) return;
      await _replacePlayer(
        resolved.url,
        headers: _streamHeaders,
        source: _currentSource ?? 'Unknown',
        qualities: _qualities,
        selectedQuality: resolved.isLocalFile ? 'Auto' : _selectedQuality,
        isHls: _currentStreamIsHls,
        position: position,
        shouldPlay: shouldPlay,
        isLocalFile: resolved.isLocalFile,
        remoteUrl: master,
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not switch audio: $error')));
    } finally {
      _isSwitchingAudio = false;
      if (mounted) setState(() {});
    }
  }

  /// The audio track whose URL differs from the stream we started on — i.e. a
  /// whole alternate rendition rather than an HLS #EXT-X-MEDIA group entry.
  Map<String, dynamic>? _alternateAudioTrack(String language) {
    final base = _baseStreamUrl;
    if (base == null) return null;
    for (final track in _audioTracks) {
      if (!StreamAudioHelper.matches(track, language)) continue;
      final url = track['url']?.toString() ?? '';
      if (url.isNotEmpty && url != base) return track;
    }
    return null;
  }

  /// Reloads the player on [targetUrl] (a dub's own MP4, or back on the
  /// default stream URL) while keeping position and play intent.
  Future<void> _switchToAlternateAudio(String targetUrl, String? language) async {
    final controller = _videoPlayerController;
    if (controller == null || _isSwitchingAudio) return;
    _isSwitchingAudio = true;
    final position = controller.value.position;
    final shouldPlay = _userWantsPlayback;
    setState(() => _preferredAudioLanguage = language);
    try {
      _showStatus(
        language == null ? 'Restoring default audio...' : 'Switching audio...',
      );
      if (!mounted || _isLeaving) return;
      await _replacePlayer(
        targetUrl,
        headers: _streamHeaders,
        source: _currentSource ?? 'Unknown',
        qualities: _qualities,
        selectedQuality: _selectedQuality,
        isHls: targetUrl.toLowerCase().contains('.m3u8'),
        position: position,
        shouldPlay: shouldPlay,
        remoteUrl: targetUrl,
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not switch audio: $error')));
    } finally {
      _isSwitchingAudio = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _showSubtitlePicker() async {
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xff202124),
      builder: (sheetContext) => SafeArea(
        child: StatefulBuilder(
          builder: (context, setSheetState) => ListView(
            shrinkWrap: true,
            children: [
              const ListTile(
                leading: Icon(Icons.subtitles, color: Colors.white),
                title: Text(
                  'Subtitles',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              RadioListTile<String>(
                value: 'Off',
                groupValue: _selectedSubtitle.value,
                activeColor: Colors.red,
                title: const Text('Off', style: TextStyle(color: Colors.white)),
                onChanged: (_) {
                  Navigator.of(sheetContext).pop();
                  setState(() {
                    _selectedSubtitle.value = 'Off';
                    _selectedSubtitleUrl = null;
                    _activeSubtitles.value = const [];
                  });
                },
              ),
              // Subtitle offset adjustment
              if (_selectedSubtitle.value != 'Off') ...[
                const Divider(color: Colors.white24),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'Subtitle Offset',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            '${_subtitleSettings.subtitleOffsetMs.round()}ms',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Adjust if subtitles are out of sync with video',
                        style: TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                      SliderTheme(
                        data: SliderThemeData(
                          activeTrackColor: Colors.red,
                          inactiveTrackColor: Colors.white24,
                          thumbColor: Colors.red,
                          overlayColor: Colors.red.withOpacity(0.2),
                        ),
                        child: Slider(
                          value: _subtitleSettings.subtitleOffsetMs.clamp(
                            -5000,
                            5000,
                          ),
                          min: -5000,
                          max: 5000,
                          divisions: 100,
                          onChanged: (value) {
                            setSheetState(() {
                              _subtitleSettings.subtitleOffsetMs = value;
                            });
                            setState(() {});
                          },
                          onChangeEnd: (_) => _subtitleSettings.save(),
                        ),
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          TextButton(
                            onPressed: () {
                              setSheetState(() {
                                _subtitleSettings.subtitleOffsetMs = 0;
                              });
                              _subtitleSettings.save();
                              setState(() {});
                            },
                            child: const Text(
                              'Reset',
                              style: TextStyle(color: Colors.red),
                            ),
                          ),
                          Text(
                            _subtitleSettings.subtitleOffsetMs > 0
                                ? 'Subtitles later'
                                : _subtitleSettings.subtitleOffsetMs < 0
                                ? 'Subtitles earlier'
                                : 'Synced',
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
              const Divider(color: Colors.white24),
              // Online subtitle search (fetched on demand, cached for the
              // session in _onlineSubtitleTracks).
              ListTile(
                leading: _onlineSearchLoading
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.red,
                        ),
                      )
                    : const Icon(Icons.cloud_download, color: Colors.white),
                title: Text(
                  _onlineSearchLoading
                      ? 'Searching…'
                      : 'Search online subtitles',
                  style: const TextStyle(color: Colors.white),
                ),
                subtitle: _onlineSearchError != null
                    ? Text(
                        _onlineSearchError!,
                        style: const TextStyle(
                          color: Colors.redAccent,
                          fontSize: 12,
                        ),
                      )
                    : null,
                onTap: _onlineSearchLoading
                    ? null
                    : () {
                        final sheetCtx = context;
                        unawaited(
                          _runOnlineSubtitleSearch(() {
                            if (sheetCtx.mounted) setSheetState(() {});
                          }),
                        );
                      },
              ),
              ..._onlineSearchResults
                  .where(
                    (r) =>
                        !_onlineSubtitleTracks.any((t) => t.label == r.label),
                  )
                  .map(
                    (result) => ListTile(
                      leading: const Icon(
                        Icons.download_for_offline_outlined,
                        color: Colors.white70,
                      ),
                      title: Text(
                        result.label,
                        style: const TextStyle(color: Colors.white),
                      ),
                      subtitle: result.downloads > 0
                          ? Text(
                              '${result.downloads} downloads',
                              style: const TextStyle(
                                color: Colors.white54,
                                fontSize: 11,
                              ),
                            )
                          : null,
                      onTap: () {
                        Navigator.of(sheetContext).pop();
                        unawaited(_applyOnlineSubtitle(result));
                      },
                    ),
                  ),
              if (_onlineSearchResults.isNotEmpty ||
                  _onlineSearchLoading ||
                  _onlineSearchError != null)
                const Divider(color: Colors.white24),
              ..._buildGroupedSubtitleTiles(),
            ],
          ),
        ),
      ),
    );
  }

  /// Runs an online subtitle search for the current title and refreshes the
  /// open picker sheet through [refreshSheet].
  Future<void> _runOnlineSubtitleSearch(VoidCallback refreshSheet) async {
    if (_onlineSearchLoading) return;
    setState(() {
      _onlineSearchLoading = true;
      _onlineSearchError = null;
    });
    refreshSheet();
    try {
      final results = await OpenSubtitlesService.search(
        query: _resolverTitle,
        season: widget.isMovie ? null : _currentSeason,
        episode: widget.isMovie ? null : _currentEpisode,
      );
      if (!mounted) return;
      setState(() {
        _onlineSearchResults = results;
        _onlineSearchLoading = false;
        if (results.isEmpty) {
          _onlineSearchError = 'No online subtitles found';
        }
      });
      refreshSheet();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _onlineSearchLoading = false;
        _onlineSearchError = 'Search failed';
        _onlineSearchResults = const [];
      });
      refreshSheet();
    }
  }

  /// Downloads an online subtitle to a temp file, registers it as a track and
  /// selects it through the normal local-file subtitle path.
  Future<void> _applyOnlineSubtitle(OpenSubtitleResult result) async {
    try {
      final text = await OpenSubtitlesService.downloadAsText(result);
      final dir = await getTemporaryDirectory();
      final file = File(p.join(dir.path, 'online_sub_${result.id}.srt'));
      await file.writeAsString(text, flush: true);
      if (!mounted) return;
      final track = _SubtitleTrack(
        label: result.label,
        url: file.path,
        isDefault: false,
        source: 'OpenSubtitles',
        group: 'OpenSubtitles',
        headers: const {},
      );
      setState(() {
        _onlineSubtitleTracks.removeWhere((t) => t.label == track.label);
        _onlineSubtitleTracks.add(track);
        _subtitleTracks = _unionSubtitleTracks();
      });
      await _selectSubtitle(track);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not download subtitle: $error'),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  List<Widget> _buildGroupedSubtitleTiles() {
    final grouped = <String, List<_SubtitleTrack>>{};
    for (final track in _subtitleTracks) {
      final source = track.group.isNotEmpty
          ? track.group
          : (track.source.isEmpty ? 'Other' : track.source);
      grouped.putIfAbsent(source, () => []).add(track);
    }
    final widgets = <Widget>[];
    for (final entry in grouped.entries) {
      widgets.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            entry.key,
            style: TextStyle(
              color: Colors.white.withOpacity(0.6),
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 1,
            ),
          ),
        ),
      );
      for (final track in entry.value) {
        widgets.add(
          RadioListTile<String>(
            value: _subtitleTileValue(track),
            groupValue: _selectedSubtitle.value,
            activeColor: Colors.red,
            title: Text(
              track.label,
              style: const TextStyle(color: Colors.white),
            ),
            onChanged: (_) {
              Navigator.of(context).pop();
              _selectSubtitle(track);
            },
          ),
        );
      }
    }
    return widgets;
  }

  Future<void> _selectSubtitle(_SubtitleTrack track) async {
    try {
      final subtitles = await _fetchSubtitles(
        track,
        track.headers.isNotEmpty ? track.headers : _streamHeaders,
      );
      if (!mounted) return;
      if (subtitles.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Subtitle file was empty or could not be parsed'),
          ),
        );
        return;
      }
      setState(() {
        _selectedSubtitle.value = _subtitleTileValue(track);
        _selectedSubtitleUrl = track.url;
        _activeSubtitles.value = subtitles;
      });
    } catch (error) {
      if (!mounted) return;
      final msg = error.toString().contains('404')
          ? 'Subtitle not found on server (404). Try another subtitle track.'
          : error.toString().contains('401')
          ? 'Subtitle requires authentication. Try another track.'
          : 'Could not load subtitles: $error';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
      );
    }
  }

  Future<List<Subtitle>> _fetchSubtitles(
    _SubtitleTrack track,
    Map<String, String> headers,
  ) async {
    final localFile = File(track.url);
    if (await localFile.exists()) {
      final input = await localFile.readAsString();
      // Legacy local subtitle downloads may have saved an HLS subtitle playlist
      // (M3U8) instead of cues. Best effort: merge any segments that exist
      // locally next to the file so the file still plays.
      if (input.trimLeft().startsWith('#EXTM3U')) {
        final merged = await _mergeLocalSubtitleHls(input, localFile);
        if (merged.isNotEmpty) return merged;
      }
      final subtitles = _parseSubtitleFile(input);
      if (subtitles.isEmpty) {
        throw const FormatException(
          'The downloaded subtitle contained no valid timed cues',
        );
      }
      return subtitles;
    }
    final uri = Uri.parse(track.url);
    if (uri.host.isEmpty) {
      throw Exception('Invalid subtitle URL: ${track.url}');
    }

    // Try the direct URL first
    final urlsToTry = <String>[track.url];

    // For RPM-style subtitles, try alternative URL patterns
    if (track.url.contains('.vtt') && !track.url.startsWith('http')) {
      // Already handled by URL construction
    } else if (track.url.contains('.vtt') || track.url.contains('.srt')) {
      // Try without fragment
      final urlNoFragment = track.url.split('#')[0];
      if (urlNoFragment != track.url) urlsToTry.add(urlNoFragment);
    }

    // For opensubtitles URLs, try with different headers
    if (track.url.contains('opensubtitles')) {
      urlsToTry.add(track.url);
    }

    Exception? lastError;
    for (final url in urlsToTry) {
      try {
        final parsedUri = Uri.parse(url);
        final inheritedHeaders = track.source == 'Vidflix'
            ? const <String, String>{}
            : headers;
        final response = await http
            .get(
              parsedUri,
              headers: {
                ...inheritedHeaders,
                'User-Agent':
                    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
                'Accept': 'text/vtt, application/x-subrip, text/plain, */*',
              },
            )
            .timeout(const Duration(seconds: 10));
        if (response.statusCode >= 200 && response.statusCode < 300) {
          final body = utf8.decode(response.bodyBytes, allowMalformed: true);
          if (body.trim().isNotEmpty) {
            // HLS subtitle playlists (source == 'HLS') return an M3U8 that
            // references individual .vtt segment files.  Fetch each segment
            // and concatenate into a single WEBVTT document.
            if (track.source == 'HLS' ||
                body.trimLeft().toUpperCase().startsWith('#EXTM3U')) {
              try {
                final vtt = await _resolveHlsSubtitlePlaylist(
                  body,
                  url,
                  headers,
                );
                final subtitles = _parseSubtitleFile(vtt);
                if (subtitles.isNotEmpty) return subtitles;
              } catch (_) {
                // Fall through to normal parsing below.
              }
            }
            final subtitles = _parseSubtitleFile(body);
            if (subtitles.isNotEmpty) return subtitles;
            lastError = const FormatException(
              'The subtitle file contained no valid timed cues',
            );
            continue;
          }
        }
        lastError = Exception('HTTP ${response.statusCode}');
      } catch (e) {
        lastError = e is Exception ? e : Exception(e.toString());
      }
    }
    throw lastError ?? Exception('Failed to load subtitles');
  }

  /// Best-effort merge of a locally saved HLS subtitle playlist (M3U8) where
  /// the referenced segment files were downloaded alongside it. Returns '' if
  /// the segments aren't present so the caller can fall back to normal
  /// parsing (and surface the missing-cues error).
  Future<List<Subtitle>> _mergeLocalSubtitleHls(
    String input,
    File playlistFile,
  ) async {
    final directory = playlistFile.parent.existsSync()
        ? playlistFile.parent
        : Directory.current;
    final parts = <String>[];
    for (final line in const LineSplitter().convert(input)) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      final segment = File(p.join(directory.path, p.basename(trimmed)));
      if (!await segment.exists()) continue;
      final text = await segment.readAsString();
      final cueText = text.trim();
      if (cueText.isEmpty) continue;
      parts.add(
        cueText.startsWith('WEBVTT')
            ? cueText.replaceFirst(RegExp('^WEBVTT.*\$', multiLine: true), '')
            : cueText,
      );
    }
    if (parts.isEmpty) return const [];
    return _parseSubtitleFile('WEBVTT\n\n${parts.join('\n\n')}\n');
  }

  /// Resolves an HLS subtitle playlist (M3U8) into a single WEBVTT string.
  ///
  /// HLS subtitle tracks declare `#EXT-X-MEDIA:TYPE=SUBTITLES` in the master
  /// with a URI pointing to an M3U8 segment playlist.  That playlist
  /// references individual `.vtt` files.  This method fetches each VTT segment
  /// and concatenates them into one WEBVTT document that our VTT parser can
  /// handle.
  Future<String> _resolveHlsSubtitlePlaylist(
    String m3u8Body,
    String playlistUrl,
    Map<String, String> headers,
  ) async {
    final baseUri = Uri.parse(playlistUrl);
    final segmentUrls = <String>[];
    for (final raw in m3u8Body.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      // Non-comment, non-empty line = segment reference
      final resolved = baseUri.resolve(line);
      segmentUrls.add(resolved.toString());
    }
    if (segmentUrls.isEmpty) {
      throw const FormatException(
        'HLS subtitle playlist contained no segments',
      );
    }

    final parts = <String>[];
    for (final segUrl in segmentUrls) {
      try {
        final resp = await http
            .get(
              Uri.parse(segUrl),
              headers: {
                ...headers,
                'User-Agent':
                    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
              },
            )
            .timeout(const Duration(seconds: 5));
        if (resp.statusCode >= 200 && resp.statusCode < 300) {
          parts.add(utf8.decode(resp.bodyBytes, allowMalformed: true));
        }
      } catch (_) {
        // Skip failed segments; partial subtitles are better than none.
      }
    }
    if (parts.isEmpty) {
      throw const FormatException('No HLS subtitle segments could be fetched');
    }
    // Concatenate into a single WEBVTT document.  Strip per-segment WEBVTT
    // headers/footers since _parseVtt expects one document.
    final buffer = StringBuffer('WEBVTT\n\n');
    for (final part in parts) {
      final cleaned = part
          .replaceAll(RegExp(r'WEBVTT[\s\S]*?\n\n'), '')
          .replaceAll(RegExp(r'^NOTE.*$', multiLine: true), '')
          .trim();
      if (cleaned.isNotEmpty) {
        buffer
          ..write(cleaned)
          ..write('\n\n');
      }
    }
    return buffer.toString();
  }

  List<Subtitle> _parseSubtitleFile(String input) {
    final normalized = input
        .replaceFirst('\uFEFF', '')
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n');

    final upper = normalized.trimLeft().toUpperCase();

    // Detect format
    if (upper.startsWith('WEBVTT')) {
      return _parseVtt(normalized);
    } else if (upper.startsWith('{') || upper.startsWith('[')) {
      final jsonSubtitles = _parseJsonSubtitles(normalized);
      if (jsonSubtitles.isNotEmpty) return jsonSubtitles;
    } else if (upper.contains('[SCRIPT INFO]') || upper.contains('[V4')) {
      return _parseAss(normalized);
    } else if (upper.contains('<TT') ||
        upper.contains('<P ') ||
        upper.contains('<P>')) {
      return _parseTtml(normalized);
    } else {
      final srt = _parseSrt(normalized);
      if (srt.isNotEmpty) return srt;
      // Last resort: try TTML for any XML-like content
      if (normalized.contains('<') && normalized.contains('begin=')) {
        return _parseTtml(normalized);
      }
      return srt;
    }
    return const [];
  }

  List<Subtitle> _parseJsonSubtitles(String input) {
    try {
      final decoded = jsonDecode(input);
      final dynamic rawCues = decoded is List
          ? decoded
          : decoded is Map
          ? decoded['cues'] ?? decoded['subtitles'] ?? decoded['data']
          : null;
      if (rawCues is! List) return const [];

      final subtitles = <Subtitle>[];
      for (final rawCue in rawCues.whereType<Map>()) {
        final start = _parseJsonCueTime(
          rawCue['startTime'] ?? rawCue['start'] ?? rawCue['from'],
        );
        final end = _parseJsonCueTime(
          rawCue['endTime'] ?? rawCue['end'] ?? rawCue['to'],
        );
        final rawText =
            rawCue['text'] ?? rawCue['payload'] ?? rawCue['caption'];
        final text = rawText is List
            ? rawText.join('\n')
            : rawText?.toString() ?? '';
        final cleanedText = text
            .replaceAll(RegExp(r'<[^>]+>'), '')
            .replaceAll('&amp;', '&')
            .replaceAll('&lt;', '<')
            .replaceAll('&gt;', '>')
            .trim();
        if (start == null || end == null || cleanedText.isEmpty) continue;
        subtitles.add(
          Subtitle(
            index: subtitles.length,
            start: start,
            end: end,
            text: cleanedText,
          ),
        );
      }
      return subtitles;
    } catch (_) {
      return const [];
    }
  }

  Duration? _parseJsonCueTime(dynamic value) {
    if (value is num) {
      return Duration(milliseconds: (value.toDouble() * 1000).round());
    }
    if (value is! String) return null;
    final timestamp = _parseSubtitleTime(value);
    if (timestamp != null) return timestamp;
    final seconds = double.tryParse(value);
    return seconds == null
        ? null
        : Duration(milliseconds: (seconds * 1000).round());
  }

  List<Subtitle> _parseVtt(String input) {
    final lines = input.split('\n');
    final subtitles = <Subtitle>[];
    int i = 0;

    // Skip WEBVTT header
    if (lines.isNotEmpty &&
        lines[0].trim().toUpperCase().startsWith('WEBVTT')) {
      i = 1;
    }

    while (i < lines.length) {
      final line = lines[i].trim();

      // Skip empty lines and NOTE blocks
      if (line.isEmpty || line.toUpperCase().startsWith('NOTE')) {
        if (line.toUpperCase().startsWith('NOTE')) {
          while (i < lines.length && lines[i].trim().isNotEmpty) {
            i++;
          }
        }
        i++;
        continue;
      }

      // Skip cue identifiers (lines that don't contain -->)
      if (!line.contains('-->')) {
        i++;
        continue;
      }

      // Parse timing line
      final timing = line.split('-->');
      if (timing.length != 2) {
        i++;
        continue;
      }
      final start = _parseSubtitleTime(timing[0]);
      final endValue = timing[1].trim().split(RegExp(r'\s+')).first;
      final end = _parseSubtitleTime(endValue);
      if (start == null || end == null) {
        i++;
        continue;
      }

      // Collect text lines until next empty line or next cue timing
      i++;
      final textLines = <String>[];
      while (i < lines.length && lines[i].trim().isNotEmpty) {
        // Stop if we hit another timing line (handles VTT without blank lines between cues)
        if (lines[i].trim().contains('-->')) break;
        textLines.add(lines[i].trim());
        i++;
      }

      final text = textLines
          .join('\n')
          .replaceAll(RegExp(r'<[^>]+>'), '')
          .replaceAll('&amp;', '&')
          .replaceAll('&lt;', '<')
          .replaceAll('&gt;', '>')
          .replaceAll(RegExp(r'\{[^}]+\}'), '');
      if (text.isEmpty) continue;

      subtitles.add(
        Subtitle(index: subtitles.length, start: start, end: end, text: text),
      );
    }
    return subtitles;
  }

  List<Subtitle> _parseSrt(String input) {
    final blocks = input.split(RegExp(r'\n\s*\n'));
    final subtitles = <Subtitle>[];

    for (final block in blocks) {
      final lines = block.trim().split('\n');
      if (lines.length < 2) continue;

      // Find the timing line
      int timingIndex = -1;
      for (int j = 0; j < lines.length; j++) {
        if (lines[j].contains('-->')) {
          timingIndex = j;
          break;
        }
      }
      if (timingIndex < 0) continue;

      final timing = lines[timingIndex].split('-->');
      if (timing.length != 2) continue;

      final start = _parseSrtTime(timing[0]);
      final endValue = timing[1].trim().split(RegExp(r'\s+')).first;
      final end = _parseSrtTime(endValue);
      if (start == null || end == null) continue;

      // Text is everything after the timing line
      final textLines = lines.sublist(timingIndex + 1);
      final text = textLines
          .join('\n')
          .replaceAll(RegExp(r'<[^>]+>'), '')
          .replaceAll('&amp;', '&')
          .replaceAll('&lt;', '<')
          .replaceAll('&gt;', '>')
          .trim();
      if (text.isEmpty) continue;

      subtitles.add(
        Subtitle(index: subtitles.length, start: start, end: end, text: text),
      );
    }
    return subtitles;
  }

  Duration? _parseSrtTime(String value) {
    final cleaned = value.trim().replaceAll(',', '.');
    final parts = cleaned.split(':');
    if (parts.length < 2 || parts.length > 3) return null;
    final seconds = double.tryParse(parts.last);
    final minutes = int.tryParse(parts[parts.length - 2]);
    final hours = parts.length == 3 ? int.tryParse(parts.first) : 0;
    if (seconds == null || minutes == null || hours == null) return null;
    return Duration(
      hours: hours,
      minutes: minutes,
      milliseconds: (seconds * 1000).round(),
    );
  }

  Duration? _parseSubtitleTime(String value) {
    final parts = value.trim().replaceAll(',', '.').split(':');
    if (parts.length < 2 || parts.length > 3) return null;
    final seconds = double.tryParse(parts.last);
    final minutes = int.tryParse(parts[parts.length - 2]);
    final hours = parts.length == 3 ? int.tryParse(parts.first) : 0;
    if (seconds == null || minutes == null || hours == null) return null;
    return Duration(
      hours: hours,
      minutes: minutes,
      milliseconds: (seconds * 1000).round(),
    );
  }

  List<Subtitle> _parseAss(String input) {
    final subtitles = <Subtitle>[];
    final lines = input.split('\n');
    bool inEvents = false;
    bool foundFormat = false;
    int textIndex = -1;
    int startIdx = -1;
    int endIdx = -1;

    for (final rawLine in lines) {
      final line = rawLine.trim();

      if (line.toUpperCase() == '[EVENTS]') {
        inEvents = true;
        continue;
      }
      if (line.startsWith('[') && inEvents) break;

      if (inEvents) {
        if (line.toUpperCase().startsWith('FORMAT:')) {
          foundFormat = true;
          final fields = line
              .substring(7)
              .split(',')
              .map((f) => f.trim().toLowerCase())
              .toList();
          startIdx = fields.indexOf('start');
          endIdx = fields.indexOf('end');
          textIndex = fields.indexOf('text');
          continue;
        }

        if (!foundFormat || textIndex < 0) continue;
        if (!line.toUpperCase().startsWith('DIALOGUE:') &&
            !line.toUpperCase().startsWith('COMMENT:')) {
          continue;
        }
        if (line.toUpperCase().startsWith('COMMENT:')) continue;

        final afterColon = line.substring(line.indexOf(':') + 1);
        final parts = afterColon.split(',');
        if (parts.length <= textIndex) continue;

        final start = _parseAssTime(
          startIdx >= 0 && startIdx < parts.length ? parts[startIdx] : '',
        );
        final end = _parseAssTime(
          endIdx >= 0 && endIdx < parts.length ? parts[endIdx] : '',
        );
        if (start == null || end == null) continue;

        final text = parts
            .sublist(textIndex)
            .join(',')
            .replaceAll(RegExp(r'\{[^}]*\}'), '')
            .replaceAll('\\N', '\n')
            .replaceAll('\\n', '\n')
            .replaceAll(RegExp(r'<[^>]+>'), '')
            .trim();
        if (text.isEmpty) continue;

        subtitles.add(
          Subtitle(index: subtitles.length, start: start, end: end, text: text),
        );
      }
    }
    return subtitles;
  }

  Duration? _parseAssTime(String value) {
    final cleaned = value.trim();
    final match = RegExp(r'(\d+):(\d+):(\d+)\.(\d+)').firstMatch(cleaned);
    if (match == null) return null;
    final hours = int.tryParse(match.group(1) ?? '') ?? 0;
    final minutes = int.tryParse(match.group(2) ?? '') ?? 0;
    final seconds = int.tryParse(match.group(3) ?? '') ?? 0;
    final cs = int.tryParse(match.group(4) ?? '') ?? 0;
    return Duration(
      hours: hours,
      minutes: minutes,
      seconds: seconds,
      milliseconds: cs * 10,
    );
  }

  List<Subtitle> _parseTtml(String input) {
    final subtitles = <Subtitle>[];
    // Match <p> or <div><p> elements with begin/end attributes
    final cuePattern = RegExp(
      r'<(?:p|P)\s[^>]*?begin="([^"]+)"[^>]*?end="([^"]+)"[^>]*?>([\s\S]*?)</(?:p|P)>',
      caseSensitive: false,
    );
    for (final match in cuePattern.allMatches(input)) {
      final start = _parseTtmlTime(match.group(1) ?? '');
      final end = _parseTtmlTime(match.group(2) ?? '');
      if (start == null || end == null) continue;
      final text = match
          .group(3)!
          .replaceAll(RegExp(r'<[^>]+>'), '')
          .replaceAll('&amp;', '&')
          .replaceAll('&lt;', '<')
          .replaceAll('&gt;', '>')
          .replaceAll('&#xA;', '\n')
          .replaceAll('\n', ' ')
          .trim();
      if (text.isEmpty) continue;
      subtitles.add(
        Subtitle(index: subtitles.length, start: start, end: end, text: text),
      );
    }
    return subtitles;
  }

  Duration? _parseTtmlTime(String value) {
    final cleaned = value.trim();
    // TTML formats: HH:MM:SS.mmm, HH:MM:SS:mm (frames), HH:MM:SS, or decimal seconds
    final hmsMatch = RegExp(
      r'(\d+):(\d+):(\d+)(?:\.(\d+))?',
    ).firstMatch(cleaned);
    if (hmsMatch != null) {
      final hours = int.tryParse(hmsMatch.group(1) ?? '') ?? 0;
      final minutes = int.tryParse(hmsMatch.group(2) ?? '') ?? 0;
      final seconds = int.tryParse(hmsMatch.group(3) ?? '') ?? 0;
      final frac = hmsMatch.group(4) ?? '0';
      // Normalize fractional part to milliseconds
      int ms = 0;
      if (frac.isNotEmpty) {
        final padded = frac.padRight(3, '0').substring(0, 3);
        ms = int.tryParse(padded) ?? 0;
      }
      return Duration(
        hours: hours,
        minutes: minutes,
        seconds: seconds,
        milliseconds: ms,
      );
    }
    // Plain seconds: "123.456"
    final secMatch = RegExp(r'^(\d+(?:\.\d+)?)s?$').firstMatch(cleaned);
    if (secMatch != null) {
      final seconds = double.tryParse(secMatch.group(1) ?? '') ?? 0;
      return Duration(milliseconds: (seconds * 1000).round());
    }
    return null;
  }

  Future<void> _switchQuality(_StreamQuality quality) async {
    final current = _videoPlayerController;
    if (current == null ||
        quality.label == _selectedQuality ||
        _isSwitchingQuality) {
      return;
    }

    // When the stream uses separate audio renditions (e.g. VixSrc), variant
    // media-playlist URLs have no audio groups.  ExoPlayer throws Source
    // error if given one directly.  Always reload the master URL so
    // ExoPlayer can mux audio + video itself.
    final playUrl = _separateAudio
        ? (_currentStreamUrl ?? quality.url)
        : quality.url;

    final position = _videoPlayerController?.value.position ?? Duration.zero;
    final shouldPlay = _userWantsPlayback;
    setState(() {
      _isSwitchingQuality = true;
      _videoInitialized = false;
    });
    try {
      // A preferred audio language forces the (rewritten) master so the
      // chosen rendition survives; quality then stays adaptive.
      final resolved = await _resolveAudioUrl(
        playUrl,
        _streamHeaders,
        _currentStreamIsHls,
      );
      if (!mounted || _isLeaving) return;
      await _replacePlayer(
        resolved.url,
        headers: _streamHeaders,
        source: _currentSource ?? 'Unknown',
        qualities: _qualities,
        selectedQuality: resolved.isLocalFile ? 'Auto' : quality.label,
        isHls: _currentStreamIsHls,
        position: position,
        shouldPlay: shouldPlay,
        isLocalFile: resolved.isLocalFile,
        remoteUrl: playUrl,
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _isSwitchingQuality = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not switch quality: $error')),
      );
    }
  }

  /// Starts (or restarts) the stall watchdog for a freshly installed player.
  void _startStallWatchdog() {
    _stallWatchdog?.cancel();
    _stallTicks = 0;
    _stallRecoveries = 0;
    _stallLastPosition = Duration.zero;
    _stallGraceSeconds = 8;
    _stallWatchdog = Timer.periodic(const Duration(seconds: 1), (_) {
      _checkPlaybackStall();
    });
  }

  /// Counts consecutive seconds in which the playhead should have moved but
  /// did not (or the player stayed buffering) while the user wants playback.
  void _checkPlaybackStall() {
    final controller = _videoPlayerController;
    if (!mounted || controller == null || _isLeaving) {
      _stallWatchdog?.cancel();
      _stallWatchdog = null;
      return;
    }
    final value = controller.value;
    if (_stallGraceSeconds > 0) {
      _stallGraceSeconds--;
      _stallLastPosition = value.position;
      return;
    }
    if (!_userWantsPlayback ||
        value.hasError ||
        value.isCompleted ||
        _offlinePath != null ||
        _recoveringPlayback ||
        _isSwitchingQuality ||
        _isSwitchingServer ||
        _isSwitchingAudio ||
        _isRetryingServer) {
      _stallTicks = 0;
      _stallLastPosition = value.position;
      return;
    }
    final stalled = value.isBuffering || value.position <= _stallLastPosition;
    _stallLastPosition = value.position;
    if (!stalled) {
      _stallTicks = 0;
      return;
    }
    _stallTicks++;
    if (_stallTicks < 6) return;
    _stallTicks = 0;
    unawaited(_recoverFromStall());
  }

  /// Progressive MP4 can't adapt down on its own, so a stall has to be turned
  /// into an action: step down a rendition first (halves the required bitrate
  /// and keeps position), then fall through to server failover.
  Future<void> _recoverFromStall() async {
    if (!mounted ||
        _isLeaving ||
        _recoveringPlayback ||
        _isSwitchingQuality ||
        _isSwitchingServer) {
      return;
    }
    _stallRecoveries++;
    final lower = _nextLowerQuality();
    if (lower != null) {
      _showStatus('Connection too slow, lowering quality...');
      await _switchQuality(lower);
      return;
    }
    if (_stallRecoveries <= 3) await _recoverPlayback();
  }

  _StreamQuality? _nextLowerQuality() {
    final playable = _qualities.where((q) => q.height > 0).toList()
      ..sort((a, b) => b.height.compareTo(a.height));
    if (playable.isEmpty) return null;
    final index = playable.indexWhere((q) => q.label == _selectedQuality);
    if (index < 0 || index + 1 >= playable.length) return null;
    return playable[index + 1];
  }

  @override
  void dispose() {
    // Set first: any load/switch still in flight awaits between statements and
    // must see the screen as gone before it can reach play().
    _isLeaving = true;
    _userWantsPlayback = false;
    // A rebuild that is still initializing is invisible to the controller
    // field below; without this it would finish, play, and leave audio
    // running with no UI attached.
    unawaited(_discardPendingControllerOf(_pendingController));
    MediaDownloadManager.instance.removeListener(_handleDownloadChanged);
    CloudSyncService.subtitlePrefsRevision.removeListener(
      _onSubtitlePrefsChanged,
    );
    _selectedSubtitle.dispose();
    _activeSubtitles.dispose();
    _progressTimer?.cancel();
    _stallWatchdog?.cancel();
    _stallWatchdog = null;
    unawaited(_saveProgress());
    final controller = _videoPlayerController;
    _videoPlayerController = null;
    if (controller != null) {
      controller.removeListener(_handlePlaybackChanged);
      // Only skip teardown when the miniplayer actually took THIS controller
      // over. If minimize() never ran (uninitialized controller) or the
      // service swapped in a different one, the controller is ours and must be
      // stopped here — otherwise it keeps playing with no UI attached.
      final handedOff =
          _isMinimizing &&
          identical(MiniplayerService.instance.controller, controller);
      if (!handedOff) {
        controller.pause();
        controller.dispose();
      }
    }
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values,
    );
    MediaSessionHandler.instance.notifyStopped();
    // Clear MediaSession callbacks to prevent stale references from triggering playback.
    final handler = MediaSessionHandler.instance.handler;
    if (handler != null) {
      handler.onPlay = null;
      handler.onPause = null;
      handler.onSkipPrevious = null;
      handler.onSkipNext = null;
      handler.onSeek = null;
      handler.onStop = null;
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) {
        if (!didPop) _exitPlayer();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: _error != null
            ? _buildError()
            : _useNativePlayer && _videoPlayerController != null
            ? _buildPlayer()
            : _buildLoading(),
      ),
    );
  }

  Widget _buildPlayer() {
    final controller = _videoPlayerController;
    Size size = const Size(1920, 1080);
    double aspect = 16 / 9;
    if (controller != null) {
      size = controller.value.size;
      aspect = controller.value.aspectRatio > 0
          ? controller.value.aspectRatio
          : 16 / 9;
    }
    final videoWidth = size.width > 0 ? size.width : 1920.0;
    final videoHeight = size.height > 0 ? size.height : 1080.0;
    final playerHeight = MediaQuery.sizeOf(context).height;
    final compactPlayer = playerHeight < 430;
    final subtitleBottom = compactPlayer
        ? (playerHeight * 0.06).clamp(18.0, 32.0)
        : 92.0;
    Widget innerPlayer;
    if (controller != null) {
      innerPlayer = VideoPlayer(controller);
    } else {
      innerPlayer = const SizedBox();
    }
    final videoWidget = switch (_aspectRatioMode) {
      _AspectRatioMode.fit => Center(
        child: AspectRatio(aspectRatio: aspect, child: innerPlayer),
      ),
      _AspectRatioMode.stretch => SizedBox.expand(child: innerPlayer),
      _AspectRatioMode.zoom => ClipRect(
        child: SizedBox.expand(
          child: FittedBox(
            fit: BoxFit.cover,
            clipBehavior: Clip.hardEdge,
            child: SizedBox(
              width: videoWidth,
              height: videoHeight,
              child: innerPlayer,
            ),
          ),
        ),
      ),
    };

    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: Colors.black, child: videoWidget),
        if (!_videoInitialized)
          Positioned.fill(
            child: ColoredBox(
              color: Colors.black,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox(
                    width: 72,
                    height: 72,
                    child: CircularProgressIndicator(
                      color: Colors.red,
                      strokeWidth: 3,
                    ),
                  ),
                  Transform.translate(
                    offset: Offset(0, 58),
                    child: Text(
                      'Preparing video...',
                      style: TextStyle(color: Colors.white70, fontSize: 14),
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (_videoInitialized &&
            _isBuffering &&
            !_isSwitchingQuality &&
            !_isSwitchingServer)
          Positioned.fill(
            child: IgnorePointer(
              child: ColoredBox(
                color: Colors.black26,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    SizedBox(
                      width: 72,
                      height: 72,
                      child: CircularProgressIndicator(
                        color: Colors.red,
                        strokeWidth: 3,
                      ),
                    ),
                    Transform.translate(
                      offset: Offset(0, 58),
                      child: Text(
                        'Loading video...',
                        style: TextStyle(color: Colors.white70, fontSize: 14),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        Positioned.fill(
          child: _StablePlayerControls(
            controller: controller,
            onBack: _exitPlayer,
            onMinimize: _minimizePlayer,
            onPlayIntent: _setPlayIntent,
            mediaTitle: _currentTitle,
            onQuality: _showQualityPicker,
            qualityLabel: _selectedQuality,
            showQuality: _qualities.length > 1,
            onServer: _showServerPicker,
            serverLabel: _currentSource ?? 'Server',
            showServer: _availableServers.isNotEmpty,
            serversLoading: _serversLoading,
            onSubtitles: _showSubtitlePicker,
            subtitleLabel: _selectedSubtitle,
            showSubtitles: _subtitleTracks.isNotEmpty,
            onAudio: _showAudioPicker,
            audioLabel: _audioLabel,
            showAudio:
                _audioTracks.length > 1 &&
                (_masterStreamUrl != null || _hasAlternateAudio),
            onAspectRatio: _cycleAspectRatio,
            aspectRatioLabel: _aspectRatioLabel,
            onDownload: _downloadCurrentStream,
            showDownload: widget.offlinePath == null || _downloadCompleted,
            downloadProgress: _downloadProgress,
            downloadCompleted: _downloadCompleted,
          ),
        ),
        if (_videoPlayerController != null)
          Positioned(
            left: compactPlayer ? 16 : 24,
            right: compactPlayer ? 16 : 24,
            bottom: subtitleBottom,
            child: IgnorePointer(
              child: ValueListenableBuilder<List<Subtitle>>(
                valueListenable: _activeSubtitles,
                builder: (context, subtitles, _) {
                  if (subtitles.isEmpty || _videoPlayerController == null)
                    return const SizedBox.shrink();
                  return ValueListenableBuilder<VideoPlayerValue>(
                    valueListenable: _videoPlayerController!,
                    builder: (context, value, _) {
                      final adjustedPosition = Duration(
                        milliseconds:
                            value.position.inMilliseconds +
                            _subtitleSettings.subtitleOffsetMs.round(),
                      );
                      final cues = subtitles.where(
                        (cue) =>
                            adjustedPosition >= cue.start &&
                            adjustedPosition <= cue.end,
                      );
                      if (cues.isEmpty) return const SizedBox.shrink();
                      final ss = _subtitleSettings;
                      final bgOpacity = ss.backgroundOpacity;
                      final shadows = <Shadow>[];
                      if (ss.textShadow) {
                        shadows.add(
                          Shadow(
                            color: ss.textShadowColorParsed,
                            blurRadius: 3,
                          ),
                        );
                      }
                      if (ss.edgeType == 'outline') {
                        shadows.add(
                          Shadow(color: ss.edgeColorParsed, blurRadius: 2),
                        );
                      } else if (ss.edgeType == 'dropShadow') {
                        shadows.add(
                          Shadow(
                            color: ss.edgeColorParsed,
                            blurRadius: 4,
                            offset: const Offset(1, 1),
                          ),
                        );
                      }
                      return Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: ss.backgroundColorParsed.withValues(
                              alpha: bgOpacity,
                            ),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            cues.map((cue) => cue.text.toString()).join('\n'),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: ss.textColorParsed,
                              fontSize:
                                  (compactPlayer
                                          ? ss.fontSize - 2
                                          : ss.fontSize)
                                      .clamp(10, 32),
                              fontWeight: FontWeight.w600,
                              fontFamily: ss.fontFamily.isNotEmpty
                                  ? ss.fontFamily
                                  : null,
                              shadows: shadows.isNotEmpty ? shadows : null,
                            ),
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ),
        if (_isSwitchingQuality)
          const Positioned.fill(
            child: ColoredBox(
              color: Colors.black38,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: Colors.red),
                    SizedBox(height: 12),
                    Text(
                      'Changing video quality...',
                      style: TextStyle(color: Colors.white),
                    ),
                  ],
                ),
              ),
            ),
          ),
        if (_showNextEpisode && _nextEpisode != null)
          Positioned(
            right: 20,
            bottom: 100,
            child: Container(
              width: 340,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xff202124),
                borderRadius: BorderRadius.circular(10),
                boxShadow: const [
                  BoxShadow(color: Colors.black54, blurRadius: 12),
                ],
              ),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: AppNetworkImage(
                      url: _nextEpisode!['stillUrl']?.toString() ?? '',
                      width: 110,
                      height: 66,
                      fit: BoxFit.cover,
                      errorWidget: const ColoredBox(
                        color: Colors.black45,
                        child: SizedBox(
                          width: 110,
                          height: 66,
                          child: Icon(Icons.tv, color: Colors.white54),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Next episode in $_nextEpisodeCountdown seconds',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          'S${_nextEpisode!['season']}E${_nextEpisode!['episode']} · ${_nextEpisode!['name']}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Row(
                          children: [
                            TextButton(
                              onPressed: _playNextEpisode,
                              child: const Text('Play now'),
                            ),
                            TextButton(
                              onPressed: _cancelNextEpisode,
                              child: const Text(
                                'Cancel',
                                style: TextStyle(color: Colors.white70),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (_currentSource != null)
          Positioned(
            top: 16,
            right: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.6),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                _currentSource!,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildLoading() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(color: Colors.red),
          const SizedBox(height: 16),
          Text(
            'Loading ${widget.title}...',
            style: const TextStyle(color: Colors.white, fontSize: 16),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              _statusMessage,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 64, color: Colors.red[400]),
            const SizedBox(height: 16),
            const Text(
              'Unable to Load Video',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _error ?? 'Unknown error',
              style: const TextStyle(color: Colors.grey, fontSize: 13),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            // Show detailed error log for debugging
            if (_error != null && _error!.isNotEmpty)
              GestureDetector(
                onTap: () {
                  Clipboard.setData(
                    ClipboardData(
                      text: 'Error: $_error\nStatus: $_statusMessage',
                    ),
                  );
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Error copied to clipboard'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                },
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.05),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.white24),
                  ),
                  child: Text(
                    '$_error\nStatus: $_statusMessage',
                    style: TextStyle(
                      color: Colors.grey[400],
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                    textAlign: TextAlign.left,
                  ),
                ),
              ),
            if (_availableServers.isNotEmpty) ...[
              const SizedBox(height: 20),
              const Text(
                'Try another server:',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 10),
              ..._availableServers.take(6).map((stream) {
                final source =
                    stream['source']?.toString() ??
                    stream['server']?.toString() ??
                    'Server';
                final selected = _serverIdentity(stream) == _selectedServerKey;
                final url = stream['url']?.toString() ?? '';
                final available = url.isNotEmpty;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed:
                          selected || _isSwitchingServer || _isRetryingServer
                          ? null
                          : available
                          ? () => _switchServer(stream)
                          : () => _retryServer(stream),
                      icon: Icon(
                        selected
                            ? Icons.check_circle
                            : available
                            ? Icons.play_circle_outline
                            : Icons.refresh,
                        size: 18,
                        color: selected
                            ? Colors.red
                            : available
                            ? Colors.white70
                            : Colors.orangeAccent,
                      ),
                      label: Text(
                        available ? source : '$source · retry',
                        style: TextStyle(
                          color: selected ? Colors.red : Colors.white,
                          fontSize: 13,
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        backgroundColor: Colors.white.withOpacity(0.05),
                        side: BorderSide(
                          color: selected ? Colors.red : Colors.white24,
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        alignment: Alignment.centerLeft,
                      ),
                    ),
                  ),
                );
              }),
            ],
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ElevatedButton(
                  onPressed: () => _loadStream(),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 28,
                      vertical: 12,
                    ),
                  ),
                  child: const Text(
                    'Retry',
                    style: TextStyle(color: Colors.white, fontSize: 15),
                  ),
                ),
                const SizedBox(width: 16),
                ElevatedButton(
                  onPressed: _exitPlayer,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.grey[700],
                    padding: const EdgeInsets.symmetric(
                      horizontal: 28,
                      vertical: 12,
                    ),
                  ),
                  child: const Text(
                    'Go Back',
                    style: TextStyle(color: Colors.white, fontSize: 15),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
