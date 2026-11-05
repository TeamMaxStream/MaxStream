import 'dart:async';
import 'package:flutter/material.dart';
import '../models/movie.dart';
import '../screens/maxstream_series_screen.dart';
import '../services/tmdb_api_service.dart';
import '../database/db_helper.dart';
import '../utils/responsive_utils.dart';
import 'video_player_screen.dart';

class SeriesHeroBanner extends StatefulWidget {
  const SeriesHeroBanner({super.key});

  @override
  State<SeriesHeroBanner> createState() => _SeriesHeroBannerState();
}

class _SeriesHeroBannerState extends State<SeriesHeroBanner> {
  List<Movie> featuredSeries = [];
  final PageController _pageController = PageController();
  Timer? _timer;
  int _currentPage = 0;
  final Set<int> _watchlistIds = {};
  bool _isPlayingVideo = false;

  @override
  void initState() {
    super.initState();
    _loadFeaturedSeries();
    _loadWatchlistIds();
  }

  Future<void> _loadFeaturedSeries() async {
    try {
      final series = await TmdbApiService.fetchTrendingSeries();
      if (series.isEmpty) return;

      if (mounted) {
        setState(() {
          featuredSeries = series
              .take(5)
              .map((item) => Movie.fromJson(item))
              .toList();
        });
        _startTimer();
      }
    } catch (e) {
      // Error loading featured series
    }
  }

  Future<void> _loadWatchlistIds() async {
    final watchlist = await DBHelper.getWatchlist();
    setState(() {
      _watchlistIds.addAll(
        watchlist
            .where((item) => item.mediaType == 'tv')
            .map((item) => int.parse(item.id)),
      );
    });
  }

  void _startTimer() {
    _timer = Timer.periodic(const Duration(seconds: 6), (timer) {
      if (_currentPage < featuredSeries.length - 1) {
        _currentPage++;
      } else {
        _currentPage = 0;
      }
      if (_pageController.hasClients) {
        _pageController.animateToPage(
          _currentPage,
          duration: const Duration(milliseconds: 600),
          curve: Curves.easeInOutCubic,
        );
      }
    });
  }

  Future<void> _toggleWatchlist(Movie series) async {
    final wasInWatchlist = _watchlistIds.contains(int.parse(series.id));

    if (wasInWatchlist) {
      await DBHelper.removeMovie(series.id, series.mediaType);
      setState(() => _watchlistIds.remove(int.parse(series.id)));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(
                  Icons.favorite_border,
                  color: Colors.white,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text('${series.title} removed from watchlist'),
              ],
            ),
            backgroundColor: Colors.red.shade600,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } else {
      await DBHelper.addToWatchlist(series);
      setState(() => _watchlistIds.add(int.parse(series.id)));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.favorite, color: Colors.white, size: 20),
                const SizedBox(width: 8),
                Text('${series.title} added to watchlist'),
              ],
            ),
            backgroundColor: Colors.green.shade600,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  Future<void> _playVideo(Movie series) async {
    try {
      if (!mounted) return;

      setState(() => _isPlayingVideo = true);

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => buildVideoPlayerScreen(
            title: series.title,
            tmdbId: series.id,
            isMovie: false,
            season: 1,
            episode: 1,
          ),
        ),
      ).then((_) {
        if (mounted) {
          setState(() => _isPlayingVideo = false);
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() => _isPlayingVideo = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to load video: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bannerHeight = ResponsiveUtils.getHeroBannerHeight(context);

    if (featuredSeries.isEmpty) {
      return Container(
        height: bannerHeight,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.grey.shade900, Colors.black],
          ),
        ),
        child: const Center(
          child: CircularProgressIndicator(color: Color(0xFFE50914)),
        ),
      );
    }

    return SizedBox(
      height: bannerHeight,
      child: PageView.builder(
        controller: _pageController,
        itemCount: featuredSeries.length,
        onPageChanged: (index) => setState(() => _currentPage = index),
        itemBuilder: (context, index) {
          final series = featuredSeries[index];
          final isInWatchlist = _watchlistIds.contains(int.parse(series.id));

          return _AnimatedSeriesPage(
            key: ValueKey(index),
            isActive: index == _currentPage,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Background Image
                Container(
                  decoration: BoxDecoration(
                    image: series.backdrop.isNotEmpty
                        ? DecorationImage(
                            image: NetworkImage(
                              TmdbApiService.getBackdropUrl(series.backdrop),
                            ),
                            fit: BoxFit.cover,
                          )
                        : null,
                    color: series.backdrop.isEmpty
                        ? Colors.grey.shade800
                        : null,
                  ),
                  child: series.backdrop.isEmpty
                      ? const Center(
                          child: Icon(
                            Icons.tv,
                            size: 100,
                            color: Colors.white54,
                          ),
                        )
                      : null,
                ),

                // Horizontal gradient (left side)
                Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: [
                        Colors.black.withOpacity(0.6),
                        Colors.transparent,
                      ],
                      stops: const [0.0, 0.5],
                    ),
                  ),
                ),

                // Vertical gradient (bottom)
                Positioned.fill(
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: Container(
                      height: bannerHeight * 0.65,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.transparent,
                            Colors.black.withOpacity(0.95),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),

                // Content
                Positioned(
                  bottom: ResponsiveUtils.getSpacing(context, mobile: 60),
                  left: ResponsiveUtils.getHorizontalPadding(context),
                  right: ResponsiveUtils.getHorizontalPadding(context),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Title
                      Text(
                        series.title,
                        style: TextStyle(
                          fontSize: ResponsiveUtils.getFontSize(
                            context,
                            mobile: 26,
                          ),
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                          height: 1.1,
                          shadows: const [
                            Shadow(
                              color: Colors.black,
                              blurRadius: 8,
                              offset: Offset(0, 2),
                            ),
                          ],
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 8),

                      // Metadata row
                      Row(
                        children: [
                          const Icon(Icons.star, color: Colors.amber, size: 16),
                          const SizedBox(width: 4),
                          Text(
                            series.rating.toStringAsFixed(1),
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                            ),
                          ),
                          const SizedBox(width: 12),
                          if (series.releaseDate.isNotEmpty)
                            Text(
                              series.releaseDate.split('-')[0],
                              style: const TextStyle(
                                color: Colors.white70,
                                fontWeight: FontWeight.w500,
                                fontSize: 13,
                              ),
                            ),
                          const SizedBox(width: 12),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFE50914),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text(
                              'TV',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 9,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),

                      // Overview
                      if (series.overview.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          series.overview,
                          style: const TextStyle(
                            color: Colors.white60,
                            fontSize: 12,
                            height: 1.3,
                          ),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                      const SizedBox(height: 14),

                      // Action Buttons
                      Row(
                        children: [
                          // Play Button (red like TV)
                          Expanded(
                            flex: 2,
                            child: ElevatedButton.icon(
                              onPressed: _isPlayingVideo
                                  ? null
                                  : () => _playVideo(series),
                              icon: _isPlayingVideo
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        valueColor:
                                            AlwaysStoppedAnimation<Color>(
                                              Colors.white,
                                            ),
                                      ),
                                    )
                                  : const Icon(
                                      Icons.play_arrow_rounded,
                                      color: Colors.white,
                                      size: 22,
                                    ),
                              label: Text(
                                _isPlayingVideo ? 'Loading...' : 'Play S1:E1',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                ),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFFE50914),
                                padding: const EdgeInsets.symmetric(
                                  vertical: 11,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                elevation: 4,
                                shadowColor: Colors.red.shade900,
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),

                          // Watchlist Button
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 300),
                            curve: Curves.easeInOut,
                            decoration: BoxDecoration(
                              color: isInWatchlist
                                  ? Colors.red.shade600.withValues(alpha: 0.8)
                                  : Colors.black.withValues(alpha: 0.5),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: isInWatchlist
                                    ? Colors.red.shade400
                                    : Colors.white38,
                                width: 1,
                              ),
                            ),
                            child: IconButton(
                              onPressed: () => _toggleWatchlist(series),
                              icon: AnimatedSwitcher(
                                duration: const Duration(milliseconds: 300),
                                transitionBuilder: (child, animation) {
                                  return ScaleTransition(
                                    scale: animation,
                                    child: child,
                                  );
                                },
                                child: Icon(
                                  isInWatchlist
                                      ? Icons.favorite
                                      : Icons.favorite_border,
                                  key: ValueKey(isInWatchlist),
                                  color: Colors.white,
                                  size: 20,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),

                          // More Info Button
                          Container(
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.5),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: Colors.white38,
                                width: 1,
                              ),
                            ),
                            child: IconButton(
                              onPressed: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => MaxStreamSeriesScreen(
                                      seriesItem: series,
                                    ),
                                  ),
                                );
                              },
                              icon: const Icon(
                                Icons.info_outline,
                                color: Colors.white,
                                size: 20,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                // Animated Page Indicators
                Positioned(
                  bottom: 18,
                  left: 0,
                  right: 0,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(
                      featuredSeries.length,
                      (index) => AnimatedContainer(
                        duration: const Duration(milliseconds: 400),
                        curve: Curves.easeInOut,
                        width: index == _currentPage ? 24 : 7,
                        height: 7,
                        margin: const EdgeInsets.symmetric(horizontal: 3),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(4),
                          color: index == _currentPage
                              ? const Color(0xFFE50914)
                              : Colors.white.withAlpha((255 * 0.35).round()),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Wraps each series hero page with staggered fade+slide animation when it
/// becomes the active page, matching the TV hero's AnimatedContent transition.
class _AnimatedSeriesPage extends StatefulWidget {
  final Widget child;
  final bool isActive;

  const _AnimatedSeriesPage({
    required super.key,
    required this.child,
    required this.isActive,
  });

  @override
  State<_AnimatedSeriesPage> createState() => _AnimatedSeriesPageState();
}

class _AnimatedSeriesPageState extends State<_AnimatedSeriesPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fadeAnimation;
  late final Animation<Offset> _slideAnimation;
  late final Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut,
    );
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0.0, 0.06),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
    _scaleAnimation = Tween<double>(
      begin: 1.05,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));

    if (widget.isActive) {
      _controller.forward();
    }
  }

  @override
  void didUpdateWidget(covariant _AnimatedSeriesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive) {
      _controller.forward(from: 0.0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Opacity(
          opacity: _fadeAnimation.value,
          child: Transform.translate(
            offset: _slideAnimation.value,
            child: Transform.scale(scale: _scaleAnimation.value, child: child),
          ),
        );
      },
      child: widget.child,
    );
  }
}
