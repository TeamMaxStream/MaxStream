import 'dart:async';
import 'dart:ui' show FontFeature, ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';

import '../models/movie.dart';
import '../models/trailer_feed_item.dart';
import '../services/trailer_feed_service.dart';
import '../services/watch_history_service.dart';
import '../utils/kids_theme.dart';
import '../widgets/app_network_image.dart';
import '../widgets/app_shimmer.dart';
import 'maxstream_details_screen.dart';
import 'maxstream_series_screen.dart';

/// Full-screen, vertically swiped trailer feed.
///
/// Only the settled page owns a YouTube player: swiping tears the old one down
/// before the next is built, so at most one WebView (and one audio source)
/// exists at a time.
class TrailersScreen extends StatefulWidget {
  const TrailersScreen({super.key, this.initialIndex = 0});

  final int initialIndex;

  @override
  State<TrailersScreen> createState() => _TrailersScreenState();
}

class _TrailersScreenState extends State<TrailersScreen>
    with WidgetsBindingObserver {
  late final PageController _pageController;
  final GlobalKey<_TrailerPageState> _pageKey = GlobalKey<_TrailerPageState>();
  int _index = 0;
  List<TrailerFeedItem> _items = const [];
  bool _loading = true;
  bool _refreshing = false;

  /// Trailers start with sound. A new page fires the user gesture of the
  /// swipe, which Android accepts as an autoplay-with-audio signal.
  bool _muted = false;
  int _generation = 0;
  Timer? _reloadDebounce;
  Timer? _durationsDebounce;

  /// Exact trailer lengths, loaded once per screen open when missing.
  Future<Map<String, Duration>>? _durationsFuture;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _pageController = PageController(initialPage: _index);
    WidgetsBinding.instance.addObserver(this);
    WatchHistoryService.localHistoryRevision.addListener(_onHistoryChanged);
    _restoreSnapshot();
    _load();
    _durationsDebounce = Timer(
      const Duration(seconds: 3),
      () => _ensureDurations(),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    WatchHistoryService.localHistoryRevision.removeListener(_onHistoryChanged);
    _reloadDebounce?.cancel();
    _durationsDebounce?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Kill the audio when the app goes away; sound resumes with the next
    // swipe so it never starts blaring on return.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _pageKey.currentState?.mute();
      if (!_muted) setState(() => _muted = true);
    }
  }

  void _onHistoryChanged() {
    _reloadDebounce?.cancel();
    _reloadDebounce = Timer(const Duration(milliseconds: 400), () {
      if (mounted) _load(refresh: true);
    });
  }

  Future<void> _restoreSnapshot() async {
    final snapshot = await TrailerFeedService.loadSnapshot();
    if (!mounted || snapshot == null || _items.isNotEmpty) return;
    setState(() {
      _items = snapshot;
      _loading = false;
      _index = _index.clamp(0, snapshot.length - 1);
    });
  }

  Future<void> _load({bool refresh = false}) async {
    final generation = ++_generation;
    if (_items.isEmpty) setState(() => _loading = true);
    if (refresh && _items.isNotEmpty) setState(() => _refreshing = true);
    try {
      final items = await TrailerFeedService.getFeed(refresh: refresh);
      if (!mounted || generation != _generation) return;
      setState(() {
        _items = items;
        _loading = false;
        _refreshing = false;
        if (items.isEmpty) {
          _index = 0;
        } else {
          _index = _index.clamp(0, items.length - 1);
        }
      });
      if (items.isNotEmpty) _precacheAround(_index);
      _ensureDurations();
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _refreshing = false;
      });
      if (_items.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Could not load trailers'),
            action: SnackBarAction(label: 'Retry', onPressed: _load),
          ),
        );
      }
    }
  }

  /// Fills in missing trailer lengths in the background, then rebuilds so the
  /// scrubber switches from its estimate to the real runtime.
  void _ensureDurations() {
    final pending = _items
        .where((item) => item.trailerDuration == null)
        .toList(growable: false);
    if (pending.isEmpty || _durationsFuture != null) return;
    _durationsFuture = TrailerFeedService.prefetchDurations(pending);
    unawaited(
      _durationsFuture!.then((durations) {
        if (!mounted || durations.isEmpty) return;
        setState(() {
          _items = [
            for (final item in _items)
              item.trailerDuration == null && durations[item.trailerKey] != null
                  ? item.copyWith(trailerDuration: durations[item.trailerKey])
                  : item,
          ];
        });
      }, onError: (_) {}),
    );
  }

  void _precacheAround(int index) {
    for (var i = index + 1; i <= index + 2 && i < _items.length; i++) {
      final url = _items[i].backdropUrl;
      if (url.isEmpty) continue;
      unawaited(precacheImage(NetworkImage(url), context).catchError((_) {}));
    }
  }

  /// Stops the current trailer as soon as the user starts dragging, so the
  /// old page is silent before the next one arrives; [_onPageChanged] then
  /// builds the next player.
  bool _onScroll(ScrollStartNotification notification) {
    _pageKey.currentState?.stop();
    return false;
  }

  void _onPageChanged(int index) {
    setState(() => _index = index);
    _precacheAround(index);
  }

  void _toggleMute() {
    final page = _pageKey.currentState;
    if (_muted) {
      page?.unmute();
    } else {
      page?.mute();
    }
    setState(() => _muted = !_muted);
  }

  Future<void> _openDetails(TrailerFeedItem item) async {
    _pageKey.currentState?.mute();
    final payload = <String, dynamic>{
      'id': item.tmdbId,
      'media_type': item.mediaType,
      'title': item.title,
      'name': item.title,
      'overview': item.overview,
      'poster_path': item.posterPath,
      'backdrop_path': item.backdropPath,
      if (item.releaseYear.isNotEmpty)
        item.isMovie ? 'release_date' : 'first_air_date': item.releaseYear,
      if (item.rating != null) 'vote_average': item.rating,
    };
    await Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (context, _, _) => item.isMovie
            ? MaxStreamDetailsScreen(
                item: Movie.fromJson(payload),
                mediaType: 'movie',
              )
            : MaxStreamSeriesScreen(seriesItem: Movie.fromJson(payload)),
        transitionsBuilder: (context, animation, _, child) => SlideTransition(
          position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
              .animate(
                CurvedAnimation(parent: animation, curve: Curves.fastOutSlowIn),
              ),
          child: child,
        ),
        transitionDuration: const Duration(milliseconds: 250),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: const Color(0xFF0A0A0A),
        body: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_items.isEmpty) {
      if (_loading) return const _TrailersShimmer();
      return _EmptyTrailers(
        onRetry: () => _load(refresh: true),
        onBack: () => Navigator.maybePop(context),
      );
    }

    return Stack(
      children: [
        NotificationListener<ScrollStartNotification>(
          onNotification: _onScroll,
          child: PageView.builder(
            controller: _pageController,
            scrollDirection: Axis.vertical,
            itemCount: _items.length,
            onPageChanged: _onPageChanged,

            itemBuilder: (context, i) {
              final item = _items[i];
              final active = i == _index;
              return _TrailerPage(
                // The settled page owns one stable key; others are keyed by item
                // so a refresh re-order never reuses the previous video.
                key: active ? _pageKey : ValueKey(item.key),
                item: item,
                active: active,
                muted: _muted,
                onStop: () => _pageKey.currentState?.stop(),
                onOpenDetails: () => _openDetails(item),
              );
            },
          ),
        ),
        _buildTopBar(),
        if (_refreshing)
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LinearProgressIndicator(
              minHeight: 2,
              color: Color(0xFFE50914),
              backgroundColor: Colors.transparent,
            ),
          ),
      ],
    );
  }

  Widget _buildTopBar() {
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Row(
          children: [
            _GlassButton(
              icon: Icons.arrow_back_ios_new,
              tooltip: 'Back',
              onPressed: () => Navigator.maybePop(context),
            ),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.38),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.play_circle_fill,
                    color: Color(0xFFE50914),
                    size: 14,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Trailers  ${_index + 1}/${_items.length}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            const Spacer(),
            _GlassButton(
              icon: _muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
              tooltip: _muted ? 'Unmute' : 'Mute',
              onPressed: _toggleMute,
            ),
            _GlassButton(
              icon: Icons.refresh_rounded,
              tooltip: 'Refresh trailers',
              onPressed: _refreshing ? null : () => _load(refresh: true),
            ),
          ],
        ),
      ),
    );
  }
}

class _GlassButton extends StatelessWidget {
  const _GlassButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      style: IconButton.styleFrom(
        backgroundColor: Colors.black.withValues(alpha: 0.38),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
        minimumSize: const Size(38, 38),
      ),
      icon: Icon(icon, color: Colors.white, size: 18),
    );
  }
}

/// A single feed page: backdrop first, muted autoplaying trailer on top.
/// A single feed page: a full-bleed trailer over the title art.
///
/// The inline player is only grown past its intrinsic 16:9 box once the WebView
/// has actually streamed a frame, so a black box never covers the backdrop art
/// while the embed boots.
class _TrailerPage extends StatefulWidget {
  const _TrailerPage({
    super.key,
    required this.item,
    required this.active,
    required this.muted,
    required this.onStop,
    required this.onOpenDetails,
  });

  final TrailerFeedItem item;
  final bool active;
  final bool muted;
  final VoidCallback onStop;
  final VoidCallback onOpenDetails;

  @override
  State<_TrailerPage> createState() => _TrailerPageState();
}

class _TrailerPageState extends State<_TrailerPage> {
  YoutubePlayerController? _controller;
  bool _playFailed = false;
  bool _ready = false;

  /// Watchdog for embeds that load but never stream a frame (offline, blocked
  /// script), which otherwise leave a silent black page.
  Duration _positionAtCheck = Duration.zero;
  Duration _lastPosition = Duration.zero;
  Timer? _stallCheck;
  bool _scrubbing = false;
  Duration _scrubTarget = Duration.zero;

  @override
  void initState() {
    super.initState();
    if (widget.active) _startPlayer();
  }

  @override
  void didUpdateWidget(covariant _TrailerPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Becoming inactive (the user swiped): drop the WebView entirely.
    if (!widget.active && _controller != null) {
      _disposePlayer();
    } else if (widget.active && _controller == null && !_playFailed) {
      _startPlayer();
    }
    if (widget.active && widget.muted != oldWidget.muted) {
      _applyMute();
    }
  }

  @override
  void dispose() {
    _disposePlayer();
    super.dispose();
  }

  void _startPlayer() {
    _ready = false;
    _positionAtCheck = Duration.zero;
    _lastPosition = Duration.zero;
    _controller = YoutubePlayerController(
      initialVideoId: widget.item.trailerKey,
      flags: YoutubePlayerFlags(
        autoPlay: true,
        // Muting at init matters: an unmuted embed on Android blocks autoplay.
        mute: widget.muted,
        enableCaption: false,
        hideControls: true,
        hideThumbnail: true,
        disableDragSeek: true,
        useHybridComposition: true,
      ),
    )..addListener(_onValueChanged);
    _stallCheck = Timer(const Duration(seconds: 12), _checkStalled);
  }

  void _applyMute() {
    final controller = _controller;
    if (controller == null) return;
    final ready = controller.value.isReady;
    if (widget.muted) {
      controller.setVolume(0);
      if (ready) controller.mute();
    } else if (ready) {
      controller.setVolume(100);
      controller.unMute();
    }
  }

  void _onValueChanged() {
    final controller = _controller;
    if (controller == null || !mounted) return;
    final value = controller.value;
    // Embedding is disabled for some videos (101/150); surface the fallback
    // instead of leaving a black page.
    if (value.errorCode != 0) {
      if (!_playFailed) setState(() => _playFailed = true);
      return;
    }
    if (value.isReady) {
      _applyMute();
      _resumeIfParkedSilently();
    }
    if (!_ready && (value.hasPlayed || value.position > Duration.zero)) {
      _stallCheck?.cancel();
      setState(() => _ready = true);
    } else if (!_ready && value.position > _lastPosition) {
      // Some builds report a position without toggling hasPlayed.
      _stallCheck?.cancel();
      setState(() => _ready = true);
    }
    _lastPosition = value.position;
    if (_ready && !_scrubbing) setState(() {});
  }

  /// Android blocks unmuted autoplay when the embed was created while the
  /// screen was still animating in. Once it is loaded but parked, play it
  /// again with the audio state we actually want; the user's setup tap on the
  /// feed counts as the gesture browsers want for sound.
  void _resumeIfParkedSilently() {
    final controller = _controller;
    if (controller == null || !widget.active) return;
    final value = controller.value;
    if (!value.isReady || widget.muted) return;
    final parked =
        value.playerState == PlayerState.paused ||
        value.playerState == PlayerState.cued ||
        value.playerState == PlayerState.unStarted;
    if (!value.hasPlayed && parked) {
      _applyMute();
      controller.play();
    }
  }

  void _checkStalled() {
    if (!mounted || _ready) return;
    final controller = _controller;
    if (controller == null) return;
    if (controller.value.isReady &&
        controller.value.position == _positionAtCheck &&
        !controller.value.hasPlayed) {
      // The embed never produced a frame (offline, blocked script, etc.).
      setState(() => _playFailed = true);
    } else {
      _positionAtCheck = controller.value.position;
      _stallCheck = Timer(const Duration(seconds: 12), _checkStalled);
    }
  }

  void _disposePlayer() {
    _stallCheck?.cancel();
    _stallCheck = null;
    final controller = _controller;
    _controller = null;
    _ready = false;
    if (controller != null) {
      controller.removeListener(_onValueChanged);
      try {
        controller.mute();
        controller.pause();
      } catch (_) {}
      controller.dispose();
    }
  }

  void unmute() {
    _applyMute();
  }

  /// Hand-off on swipe: silence the page now and park it at the start so the
  /// same title does not resume mid-way when the user swipes back to it.
  void stop() {
    final controller = _controller;
    if (controller == null) return;
    if (controller.value.isReady) {
      try {
        controller.mute();
        controller.pause();
      } catch (_) {}
    }
    controller.setVolume(0);
  }

  void mute() {
    final controller = _controller;
    if (controller == null) return;
    if (controller.value.isReady) controller.mute();
    controller.setVolume(0);
  }

  void _beginScrub() {
    _scrubbing = true;
    _scrubTarget = _controller?.value.position ?? Duration.zero;
  }

  void _updateScrub(Duration position) {
    setState(() => _scrubTarget = position);
  }

  void _endScrub(Duration position) {
    _scrubbing = false;
    final controller = _controller;
    if (controller == null || !controller.value.isReady) return;
    if (widget.muted) controller.mute();
    controller.seekTo(position);
  }

  Future<void> _openOnYouTube() async {
    final uri = Uri.parse(widget.item.youtubeUrl);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication) &&
        mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Could not open YouTube')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final controller = _controller;
    final playing = controller != null && _ready && !_playFailed;
    return Stack(
      fit: StackFit.expand,
      children: [
        AppNetworkImage(url: item.backdropUrl, fit: BoxFit.cover),
        if (controller != null && !_playFailed)
          Positioned.fill(child: _buildPlayer(controller, visible: playing)),
        if (_playFailed)
          _PlaybackFallback(
            onOpenYouTube: _openOnYouTube,
            onOpenDetails: widget.onOpenDetails,
          ),
        // Cinematic scrim: readable text at the bottom, art at the top.
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              stops: [0, 0.35, 0.62, 1],
              colors: [
                Color(0x55000000),
                Color(0x00000000),
                Color(0xCC0A0A0A),
                Color(0xFF0A0A0A),
              ],
            ),
          ),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 22),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _ReasonChip(label: item.reasonLabel),
                  const SizedBox(height: 12),
                  Text(
                    item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 30,
                      height: 1.08,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.4,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _MetaChip(label: item.typeLabel),
                      if (item.releaseYear.isNotEmpty)
                        _MetaChip(label: item.releaseYear),
                      if ((item.rating ?? 0) > 0)
                        _MetaChip(
                          label: item.rating!.toStringAsFixed(1),
                          icon: Icons.star_rounded,
                          iconColor: Colors.amber,
                        ),
                      if (item.trailerName.isNotEmpty)
                        _MetaChip(label: item.trailerName),
                    ],
                  ),
                  if (item.overview.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(
                      item.overview,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.72),
                        fontSize: 13.5,
                        height: 1.45,
                      ),
                    ),
                  ],
                  if (controller != null && _ready && !_playFailed) ...[
                    const SizedBox(height: 16),
                    _ScrubBar(
                      controller: controller,
                      duration: widget.item.trailerDuration,
                      scrubbing: _scrubbing,
                      scrubTarget: _scrubTarget,
                      onScrubStart: _beginScrub,
                      onScrubUpdate: _updateScrub,
                      onScrubEnd: _endScrub,
                    ),
                  ],
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: widget.onOpenDetails,
                          style: FilledButton.styleFrom(
                            backgroundColor: KidsTheme.primary,
                            foregroundColor: Colors.white,
                            minimumSize: const Size(0, 48),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          icon: const Icon(Icons.play_arrow_rounded, size: 22),
                          label: Text(
                            item.isMovie ? 'Watch movie' : 'Watch series',
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      _GlassButton(
                        icon: Icons.info_outline_rounded,
                        tooltip: 'Details',
                        onPressed: widget.onOpenDetails,
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Center(
                    child: Icon(
                      Icons.keyboard_arrow_up_rounded,
                      color: Colors.white.withValues(alpha: 0.45),
                      size: 22,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Full-bleed cover for the 16:9 embed. The iframe keeps its own aspect box
  /// (scaling a WebView through [FittedBox] leaves it blank on Android) and is
  /// pinned to the top so the bottom copy stays on top of black.
  Widget _buildPlayer(
    YoutubePlayerController controller, {
    required bool visible,
  }) {
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final videoHeight = constraints.maxWidth * 9 / 16;
            return ClipRect(
              child: OverflowBox(
                alignment: Alignment.topCenter,
                maxHeight: videoHeight,
                child: SizedBox(
                  width: constraints.maxWidth,
                  height: videoHeight,
                  child: OverflowBox(
                    maxHeight: double.infinity,
                    maxWidth: double.infinity,
                    child: YoutubePlayer(
                      controller: controller,
                      aspectRatio: 16 / 9,
                      showVideoProgressIndicator: false,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Thin, scrubbable timeline with elapsed and total time.
class _ScrubBar extends StatefulWidget {
  const _ScrubBar({
    required this.controller,
    required this.duration,
    required this.scrubbing,
    required this.scrubTarget,
    required this.onScrubStart,
    required this.onScrubUpdate,
    required this.onScrubEnd,
  });

  final YoutubePlayerController controller;

  /// Exact length from TMDb; null until [TrailerFeedService.prefetchDurations]
  /// lands, in which case the scrubber runs on an estimate.
  final Duration? duration;
  final bool scrubbing;
  final Duration scrubTarget;
  final VoidCallback onScrubStart;
  final ValueChanged<Duration> onScrubUpdate;
  final ValueChanged<Duration> onScrubEnd;

  @override
  State<_ScrubBar> createState() => _ScrubBarState();
}

class _ScrubBarState extends State<_ScrubBar> {
  // Until the TMDb length arrives, trailer previews (~2 minutes) are assumed.
  static const Duration _estimate = Duration(minutes: 2);
  double? _dragFraction;

  Duration get _duration {
    final exact = widget.duration;
    if (exact != null && exact > Duration.zero) return exact;
    final reported = widget.controller.value.metaData.duration;
    return reported > Duration.zero ? reported : _estimate;
  }

  Duration get _position => _dragFraction == null
      ? widget.controller.value.position
      : widget.scrubTarget;

  void _seekToFraction(double fraction) {
    final target = Duration(
      milliseconds: (_duration.inMilliseconds * fraction.clamp(0.0, 1.0))
          .round(),
    );
    widget.onScrubEnd(target);
    setState(() => _dragFraction = null);
  }

  @override
  Widget build(BuildContext context) {
    final total = _duration;
    final position = _position;
    final fraction = total.inMilliseconds == 0
        ? 0.0
        : (position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
            activeTrackColor: KidsTheme.primary,
            inactiveTrackColor: Colors.white.withValues(alpha: 0.22),
            thumbColor: KidsTheme.primary,
            overlayShape: SliderComponentShape.noOverlay,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
          ),
          child: Slider(
            value: fraction.toDouble(),
            onChangeStart: (value) {
              widget.onScrubStart();
              setState(() => _dragFraction = value);
            },
            onChanged: (value) {
              widget.onScrubUpdate(
                Duration(milliseconds: (total.inMilliseconds * value).round()),
              );
              setState(() => _dragFraction = value);
            },
            onChangeEnd: (value) {
              final target = Duration(
                milliseconds: (total.inMilliseconds * value).round(),
              );
              widget.onScrubUpdate(target);
              _seekToFraction(value);
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(
            children: [
              Text(
                _formatTime(position),
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.8),
                  fontSize: 11.5,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const Spacer(),
              Text(
                _formatTime(total),
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.55),
                  fontSize: 11.5,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  static String _formatTime(Duration d) {
    final totalSeconds = d.inSeconds.clamp(0, 359999);
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}

class _ReasonChip extends StatelessWidget {
  const _ReasonChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
          decoration: BoxDecoration(
            color: KidsTheme.primary.withValues(alpha: 0.22),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: KidsTheme.primary.withValues(alpha: 0.55),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: KidsTheme.primary,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 7),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.label, this.icon, this.iconColor});

  final String label;
  final IconData? icon;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, color: iconColor ?? Colors.white, size: 13),
            const SizedBox(width: 4),
          ],
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 160),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlaybackFallback extends StatelessWidget {
  const _PlaybackFallback({
    required this.onOpenYouTube,
    required this.onOpenDetails,
  });

  final VoidCallback onOpenYouTube;
  final VoidCallback onOpenDetails;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.smart_display_outlined,
            color: Colors.white.withValues(alpha: 0.7),
            size: 44,
          ),
          const SizedBox(height: 10),
          Text(
            'This trailer cannot play in the app',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.8),
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: onOpenYouTube,
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              side: BorderSide(color: Colors.white.withValues(alpha: 0.4)),
            ),
            icon: const Icon(Icons.open_in_new_rounded, size: 16),
            label: const Text('Watch on YouTube'),
          ),
        ],
      ),
    );
  }
}

class _EmptyTrailers extends StatelessWidget {
  const _EmptyTrailers({required this.onRetry, required this.onBack});

  final VoidCallback onRetry;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: _GlassButton(
              icon: Icons.arrow_back_ios_new,
              tooltip: 'Back',
              onPressed: onBack,
            ),
          ),
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 76,
                      height: 76,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            KidsTheme.primary.withValues(alpha: 0.9),
                            KidsTheme.primary.withValues(alpha: 0.35),
                          ],
                        ),
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: const Icon(
                        Icons.smart_display_rounded,
                        color: Colors.white,
                        size: 38,
                      ),
                    ),
                    const SizedBox(height: 20),
                    const Text(
                      'No trailers yet',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Watch something and trailers picked for you will '
                      'appear here. In the meantime, browse what is trending.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.grey[400],
                        fontSize: 13.5,
                        height: 1.45,
                      ),
                    ),
                    const SizedBox(height: 22),
                    FilledButton.icon(
                      onPressed: onRetry,
                      style: FilledButton.styleFrom(
                        backgroundColor: KidsTheme.primary,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 12,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      icon: const Icon(Icons.trending_up_rounded, size: 18),
                      label: const Text('Browse trending trailers'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TrailersShimmer extends StatelessWidget {
  const _TrailersShimmer();

  @override
  Widget build(BuildContext context) {
    return AppShimmer(
      baseColor: Colors.grey[900]!,
      highlightColor: Colors.grey[800]!,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Spacer(flex: 3),
            Container(
              width: 150,
              height: 26,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              height: 30,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            const SizedBox(height: 10),
            Container(
              width: 180,
              height: 14,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(6),
              ),
            ),
            const SizedBox(height: 18),
            Container(
              width: double.infinity,
              height: 48,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            const SizedBox(height: 60),
          ],
        ),
      ),
    );
  }
}
