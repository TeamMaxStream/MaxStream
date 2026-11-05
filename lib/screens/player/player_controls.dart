part of '../m3u8_video_player_screen.dart';

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
