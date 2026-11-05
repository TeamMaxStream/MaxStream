import 'dart:async';
import 'package:flutter/material.dart';
import '../models/movie.dart';
import '../screens/maxstream_details_screen.dart';
import '../screens/maxstream_series_screen.dart';
import '../services/tmdb_api_service.dart';
import '../database/db_helper.dart';
import '../utils/responsive_utils.dart';
import 'video_player_screen.dart';

class HeroBanner extends StatefulWidget {
  final VoidCallback? onPlayerReturn;
  const HeroBanner({super.key, this.onPlayerReturn});

  @override
  State<HeroBanner> createState() => _HeroBannerState();
}

class _HeroBannerState extends State<HeroBanner> {
  List<Movie> featuredItems = [];
  final PageController _pageController = PageController();
  Timer? _timer;
  int _currentPage = 0;
  final Set<int> _watchlistIds = {};
  bool _isLoading = true;
  bool _hasError = false;
  bool _isPlayingVideo = false;

  @override
  void initState() {
    super.initState();
    _loadFeaturedItems();
    _loadWatchlistIds();
  }

  Future<void> _loadFeaturedItems() async {
    try {
      setState(() {
        _isLoading = true;
        _hasError = false;
      });

      final movies = await TmdbApiService.fetchTrendingMovies();
      final series = await TmdbApiService.fetchTrendingSeries();
      final combined = [...movies, ...series];

      if (mounted) {
        setState(() {
          _isLoading = false;
          if (combined.isNotEmpty) {
            featuredItems = combined
                .map((item) => Movie.fromJson(item))
                .take(5)
                .toList();
            _startTimer();
          } else {
            _hasError = true;
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _hasError = true;
        });
      }
    }
  }

  Future<void> _loadWatchlistIds() async {
    final watchlist = await DBHelper.getWatchlist();
    setState(() {
      _watchlistIds.addAll(
        watchlist
            .where((item) => item.mediaType == 'movie')
            .map((item) => int.parse(item.id)),
      );
    });
  }

  void _startTimer() {
    _timer = Timer.periodic(const Duration(seconds: 6), (timer) {
      if (_currentPage < featuredItems.length - 1) {
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

  Future<void> _toggleWatchlist(Movie item) async {
    try {
      final wasInWatchlist = _watchlistIds.contains(int.parse(item.id));

      if (wasInWatchlist) {
        await DBHelper.removeMovie(item.id, item.mediaType);
        setState(() => _watchlistIds.remove(int.parse(item.id)));
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
                  Text('${item.title} removed from watchlist'),
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
        await DBHelper.addToWatchlist(item);
        setState(() => _watchlistIds.add(int.parse(item.id)));
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  const Icon(Icons.favorite, color: Colors.white, size: 20),
                  const SizedBox(width: 8),
                  Text('${item.title} added to watchlist'),
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
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.error, color: Colors.white, size: 20),
                const SizedBox(width: 8),
                Text('Error updating watchlist: $e'),
              ],
            ),
            backgroundColor: Colors.red.shade600,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        );
      }
    }
  }

  Future<void> _playVideo(Movie item) async {
    try {
      if (!mounted) return;

      setState(() => _isPlayingVideo = true);

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => buildVideoPlayerScreen(
            title: item.title,
            tmdbId: item.id,
            isMovie: item.mediaType == 'movie',
            season: 1,
            episode: 1,
          ),
        ),
      ).then((_) {
        if (mounted) {
          setState(() => _isPlayingVideo = false);
          widget.onPlayerReturn?.call();
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
    if (_isLoading) {
      return Container(
        height: 420,
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

    if (_hasError || featuredItems.isEmpty) {
      return Container(
        height: 420,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.grey.shade900, Colors.black],
          ),
        ),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, color: Colors.white54, size: 48),
              const SizedBox(height: 16),
              const Text(
                'Unable to load featured content',
                style: TextStyle(color: Colors.white54, fontSize: 16),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _loadFeaturedItems,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFE50914),
                ),
                child: const Text(
                  'Retry',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final bannerHeight = ResponsiveUtils.getHeroBannerHeight(context);

    return SizedBox(
      height: bannerHeight,
      child: PageView.builder(
        controller: _pageController,
        itemCount: featuredItems.length,
        onPageChanged: (index) => setState(() => _currentPage = index),
        itemBuilder: (context, index) {
          final item = featuredItems[index];
          final isInWatchlist = _watchlistIds.contains(int.parse(item.id));

          return _AnimatedHeroPage(
            key: ValueKey(index),
            isActive: index == _currentPage,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Background Image
                Container(
                  decoration: BoxDecoration(
                    image: item.backdrop.isNotEmpty
                        ? DecorationImage(
                            image: NetworkImage(
                              TmdbApiService.getBackdropUrl(item.backdrop),
                            ),
                            fit: BoxFit.cover,
                          )
                        : null,
                    color: item.backdrop.isEmpty ? Colors.grey.shade800 : null,
                  ),
                  child: item.backdrop.isEmpty
                      ? Center(
                          child: Icon(
                            item.mediaType == 'tv' ? Icons.tv : Icons.movie,
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
                        item.title,
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
                            item.rating.toStringAsFixed(1),
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                            ),
                          ),
                          const SizedBox(width: 12),
                          if (item.releaseDate.isNotEmpty)
                            Text(
                              item.releaseDate.split('-')[0],
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
                              color: item.mediaType == 'tv'
                                  ? const Color(0xFFE50914)
                                  : Colors.blue.shade700,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              item.mediaType == 'tv' ? 'TV' : 'MOVIE',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 9,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),

                      // Overview
                      if (item.overview.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          item.overview,
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
                                  : () => _playVideo(item),
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
                                _isPlayingVideo
                                    ? 'Loading...'
                                    : (item.mediaType == 'tv'
                                          ? 'Play S1:E1'
                                          : 'Play'),
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
                              onPressed: () => _toggleWatchlist(item),
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
                                if (!mounted) return;
                                Navigator.push(
                                  context,
                                  PageRouteBuilder(
                                    pageBuilder:
                                        (
                                          context,
                                          animation,
                                          secondaryAnimation,
                                        ) => item.mediaType == 'tv'
                                        ? MaxStreamSeriesScreen(
                                            seriesItem: item,
                                          )
                                        : MaxStreamDetailsScreen(
                                            item: item,
                                            mediaType: item.mediaType,
                                          ),
                                    transitionsBuilder:
                                        (
                                          context,
                                          animation,
                                          secondaryAnimation,
                                          child,
                                        ) {
                                          return SlideTransition(
                                            position:
                                                Tween<Offset>(
                                                  begin: const Offset(1.0, 0.0),
                                                  end: Offset.zero,
                                                ).animate(
                                                  CurvedAnimation(
                                                    parent: animation,
                                                    curve:
                                                        Curves.easeInOutCubic,
                                                  ),
                                                ),
                                            child: child,
                                          );
                                        },
                                    transitionDuration: const Duration(
                                      milliseconds: 350,
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
                      featuredItems.length,
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

/// Wraps each hero page with staggered fade+slide animation when it becomes
/// the active page, matching the TV hero's AnimatedContent transition.
class _AnimatedHeroPage extends StatefulWidget {
  final Widget child;
  final bool isActive;

  const _AnimatedHeroPage({
    required super.key,
    required this.child,
    required this.isActive,
  });

  @override
  State<_AnimatedHeroPage> createState() => _AnimatedHeroPageState();
}

class _AnimatedHeroPageState extends State<_AnimatedHeroPage>
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
  void didUpdateWidget(covariant _AnimatedHeroPage oldWidget) {
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
