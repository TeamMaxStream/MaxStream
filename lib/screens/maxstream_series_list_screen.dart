import 'dart:async';
import 'package:flutter/material.dart';
import '../widgets/app_shimmer.dart';
import '../models/movie.dart';
import '../services/tmdb_api_service.dart';
import '../utils/tmdb_list_utils.dart';
import '../utils/kids_filter.dart';
import '../widgets/series_hero_banner.dart';
import '../widgets/profile_menu_button.dart';
import 'maxstream_series_screen.dart';
import '../widgets/app_network_image.dart';

class MaxStreamSeriesListScreen extends StatefulWidget {
  const MaxStreamSeriesListScreen({super.key});

  @override
  State<MaxStreamSeriesListScreen> createState() =>
      _MaxStreamSeriesListScreenState();
}

class _MaxStreamSeriesListScreenState extends State<MaxStreamSeriesListScreen> {
  bool isLoading = true;
  List<Map<String, dynamic>> trendingSeries = [];
  List<Map<String, dynamic>> popularSeries = [];
  List<Map<String, dynamic>> topRatedSeries = [];
  List<Map<String, dynamic>> onTheAirSeries = [];
  List<Map<String, dynamic>> upcomingSeries = [];

  @override
  void initState() {
    super.initState();
    _loadContent();
  }

  Future<List<Map<String, dynamic>>> _safe(
    Future<List<Map<String, dynamic>>> Function() f,
  ) async {
    try {
      return await f();
    } catch (_) {
      return [];
    }
  }

  Future<void> _loadContent() async {
    setState(() => isLoading = true);

    try {
      final results = await Future.wait([
        _safe(() => TmdbApiService.fetchTrendingSeries()),
        _safe(() => TmdbApiService.fetchPopularSeries()),
        _safe(() => TmdbApiService.fetchTopRatedSeries()),
        _safe(() => TmdbApiService.fetchOnTheAirSeries()),
        _safe(() => TmdbApiService.fetchUpcomingSeries()),
      ]);

      if (!mounted) return;
      setState(() {
        trendingSeries = results[0];
        popularSeries = results[1];
        topRatedSeries = results[2];
        onTheAirSeries = results[3];
        upcomingSeries = results[4];
      });
    } catch (e) {
      debugPrint('Series list load error: $e');
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      body: RefreshIndicator(
        onRefresh: _loadContent,
        child: CustomScrollView(
          slivers: [
            _buildAppBar(),
            if (isLoading)
              SliverToBoxAdapter(child: _buildLoadingIndicator())
            else ...[
              if (trendingSeries.isNotEmpty) _buildHeroBannerSection(),
              _buildSection('Trending TV Shows', trendingSeries, 'tv'),
              _buildSection('Popular TV Shows', popularSeries, 'tv'),
              _buildSection('Top Rated TV Shows', topRatedSeries, 'tv'),
              if (onTheAirSeries.isNotEmpty) _buildOnTheAirSection(),
              if (upcomingSeries.isNotEmpty) _buildUpcomingSection(),
              const SliverToBoxAdapter(child: SizedBox(height: 100)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildAppBar() {
    return SliverAppBar(
      floating: true,
      backgroundColor: const Color(0xFF1A1A1A),
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.red,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.tv, color: Colors.white, size: 20),
          ),
          const SizedBox(width: 8),
          const Text(
            'TV Series',
            style: TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
      actions: const [
        Padding(padding: EdgeInsets.only(right: 8), child: ProfileMenuButton()),
      ],
    );
  }

  Widget _buildLoadingIndicator() {
    return AppShimmer(
      baseColor: Colors.grey[800]!,
      highlightColor: Colors.grey[600]!,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 200,
            margin: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.grey[800],
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          _buildShimmerSection(),
          _buildShimmerSection(),
          _buildShimmerSection(),
        ],
      ),
    );
  }

  Widget _buildShimmerSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          margin: const EdgeInsets.fromLTRB(16, 24, 16, 8),
          height: 24,
          width: 150,
          color: Colors.grey[800],
        ),
        SizedBox(
          height: 280,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: 5,
            itemBuilder: (context, index) {
              return Container(
                width: 135,
                margin: const EdgeInsets.only(right: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 135,
                      height: 200,
                      decoration: BoxDecoration(
                        color: Colors.grey[800],
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(height: 12, width: 100, color: Colors.grey[800]),
                    const SizedBox(height: 4),
                    Container(height: 10, width: 40, color: Colors.grey[800]),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildHeroBannerSection() {
    return const SliverToBoxAdapter(child: SeriesHeroBanner());
  }

  Widget _buildSection(
    String title,
    List<Map<String, dynamic>> items,
    String mediaType,
  ) {
    if (items.isEmpty) return const SliverToBoxAdapter(child: SizedBox());

    return SliverToBoxAdapter(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                TextButton(
                  onPressed: () {
                    _showFullList(title, mediaType);
                  },
                  child: const Text(
                    'See All',
                    style: TextStyle(color: Colors.red, fontSize: 14),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 280,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: items.length,
              itemBuilder: (context, index) {
                final item = items[index];
                return _buildSeriesCard(item, mediaType);
              },
            ),
          ),
        ],
      ),
    );
  }

  // On The Air: wide horizontal cards with backdrop images, air schedule badge
  Widget _buildOnTheAirSection() {
    return SliverToBoxAdapter(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.teal,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Icon(
                        Icons.live_tv,
                        color: Colors.white,
                        size: 14,
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      'On The Air',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                TextButton(
                  onPressed: () => _showFullList('On The Air', 'tv'),
                  child: const Text(
                    'See All',
                    style: TextStyle(color: Colors.red, fontSize: 14),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 170,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: onTheAirSeries.length,
              itemBuilder: (context, index) {
                final item = onTheAirSeries[index];
                return _buildOnTheAirCard(item);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOnTheAirCard(Map<String, dynamic> item) {
    final name = item['name'] ?? item['title'] ?? 'Unknown';
    final backdropPath = item['backdrop_path'];
    final rating = (item['vote_average'] as num?)?.toDouble();
    final firstAirDate = item['first_air_date']?.toString() ?? '';
    final overview = item['overview']?.toString() ?? '';
    final episodeCount = item['number_of_episodes'];
    final seasonNumber = item['number_of_seasons'];

    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) =>
                MaxStreamSeriesScreen(seriesItem: Movie.fromJson(item)),
          ),
        );
      },
      child: Container(
        width: 300,
        margin: const EdgeInsets.only(right: 12),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Stack(
            fit: StackFit.expand,
            children: [
              backdropPath != null
                  ? AppNetworkImage(
                      url: TmdbApiService.getBackdropUrl(backdropPath),
                      fit: BoxFit.cover,
                      errorWidget: Container(
                        color: Colors.grey[850],
                        child: const Icon(
                          Icons.tv,
                          color: Colors.grey,
                          size: 40,
                        ),
                      ),
                    )
                  : Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [Colors.grey[850]!, Colors.grey[900]!],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                      ),
                      child: const Icon(Icons.tv, color: Colors.grey, size: 40),
                    ),
              // Gradient overlay
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.1),
                        Colors.black.withValues(alpha: 0.85),
                      ],
                      stops: const [0.3, 1.0],
                    ),
                  ),
                ),
              ),
              // "AIRING" badge
              Positioned(
                top: 10,
                left: 10,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.teal,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Text(
                    'AIRING',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              // Rating
              if (rating != null && rating > 0)
                Positioned(
                  top: 10,
                  right: 10,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.7),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.star, color: Colors.amber, size: 12),
                        const SizedBox(width: 3),
                        Text(
                          rating.toStringAsFixed(1),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              // Bottom info
              Positioned(
                left: 12,
                right: 12,
                bottom: 12,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        if (firstAirDate.length >= 4)
                          Text(
                            firstAirDate.substring(0, 4),
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                            ),
                          ),
                        if (seasonNumber != null) ...[
                          const Text(
                            '  \u00B7  ',
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 12,
                            ),
                          ),
                          Text(
                            '$seasonNumber season${seasonNumber == 1 ? '' : 's'}',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                            ),
                          ),
                        ],
                        if (episodeCount != null) ...[
                          const Text(
                            '  \u00B7  ',
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 12,
                            ),
                          ),
                          Text(
                            '$episodeCount ep${episodeCount == 1 ? '' : 's'}',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (overview.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        overview,
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 11,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Upcoming: large backdrop auto-scrolling carousel
  Widget _buildUpcomingSection() {
    return SliverToBoxAdapter(
      child: _AutoScrollingCarousel(items: upcomingSeries),
    );
  }

  Widget _buildSeriesCard(Map<String, dynamic> item, String mediaType) {
    final name = item['title'] ?? item['name'] ?? 'Unknown';
    final posterPath = item['poster_path'];
    final rating = (item['vote_average'] as num?)?.toDouble();
    final year = _getYear(item);

    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) =>
                MaxStreamSeriesScreen(seriesItem: Movie.fromJson(item)),
          ),
        );
      },
      child: Container(
        width: 135,
        margin: const EdgeInsets.only(right: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Stack(
                children: [
                  posterPath != null
                      ? AppNetworkImage(
                          url: TmdbApiService.getPosterUrl(posterPath),
                          width: 135,
                          height: 200,
                          fit: BoxFit.cover,
                          errorWidget: Container(
                            width: 135,
                            height: 200,
                            color: Colors.grey[850],
                            child: const Icon(
                              Icons.tv,
                              color: Colors.grey,
                              size: 40,
                            ),
                          ),
                        )
                      : Container(
                          width: 135,
                          height: 200,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [Colors.grey[850]!, Colors.grey[900]!],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                          ),
                          child: const Icon(
                            Icons.tv,
                            color: Colors.grey,
                            size: 40,
                          ),
                        ),
                  Positioned(
                    top: 6,
                    left: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.red,
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
                  ),
                  if (rating != null && rating > 0)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.75),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.star,
                              color: Colors.amber,
                              size: 10,
                            ),
                            const SizedBox(width: 2),
                            Text(
                              rating.toStringAsFixed(1),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    height: 60,
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.transparent,
                            Colors.black.withValues(alpha: 0.8),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              name,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            if (year.isNotEmpty)
              Text(
                year,
                style: TextStyle(color: Colors.grey[500], fontSize: 11),
              ),
          ],
        ),
      ),
    );
  }

  void _showFullList(String title, String mediaType) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) =>
            _FullListScreen(title: title, mediaType: mediaType),
      ),
    );
  }

  String _getYear(Map<String, dynamic> item) {
    final date = item['first_air_date'];
    if (date != null && date.length >= 4) {
      return date.substring(0, 4);
    }
    return '';
  }
}

class _AutoScrollingCarousel extends StatefulWidget {
  final List<Map<String, dynamic>> items;

  const _AutoScrollingCarousel({required this.items});

  @override
  State<_AutoScrollingCarousel> createState() => _AutoScrollingCarouselState();
}

class _AutoScrollingCarouselState extends State<_AutoScrollingCarousel> {
  late final PageController _pageController;
  late final Timer _timer;
  int _currentPage = 0;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(viewportFraction: 0.88);
    _timer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (!mounted || widget.items.isEmpty) return;
      final nextPage = (_currentPage + 1) % widget.items.length;
      _pageController.animateToPage(
        nextPage,
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeInOut,
      );
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) return const SizedBox();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.amber.shade700,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Icon(
                      Icons.schedule,
                      color: Colors.white,
                      size: 14,
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    'Coming Soon',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              TextButton(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => _FullListScreen(
                        title: 'Coming Soon',
                        mediaType: 'tv',
                      ),
                    ),
                  );
                },
                child: const Text(
                  'See All',
                  style: TextStyle(color: Colors.red, fontSize: 14),
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 220,
          child: PageView.builder(
            controller: _pageController,
            itemCount: widget.items.length,
            onPageChanged: (index) => setState(() => _currentPage = index),
            itemBuilder: (context, index) {
              final item = widget.items[index];
              return _buildUpcomingCard(item);
            },
          ),
        ),
        const SizedBox(height: 8),
        // Dot indicators
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(
            widget.items.length.clamp(0, 8),
            (index) => AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              margin: const EdgeInsets.symmetric(horizontal: 3),
              width: _currentPage == index ? 20 : 6,
              height: 6,
              decoration: BoxDecoration(
                color: _currentPage == index
                    ? Colors.amber
                    : Colors.grey.shade700,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildUpcomingCard(Map<String, dynamic> item) {
    final name = item['name'] ?? item['title'] ?? 'Unknown';
    final backdropPath = item['backdrop_path'];
    final posterPath = item['poster_path'];
    final rating = (item['vote_average'] as num?)?.toDouble();
    final firstAirDate = item['first_air_date']?.toString() ?? '';
    final overview = item['overview']?.toString() ?? '';
    final seasonCount = item['number_of_seasons'];
    final episodeCount = item['number_of_episodes'];

    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) =>
                MaxStreamSeriesScreen(seriesItem: Movie.fromJson(item)),
          ),
        );
      },
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 4),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Backdrop image or poster fallback
              if (backdropPath != null)
                AppNetworkImage(
                  url: TmdbApiService.getBackdropUrl(backdropPath),
                  fit: BoxFit.cover,
                  errorWidget: _buildPosterFallback(posterPath, name),
                )
              else
                _buildPosterFallback(posterPath, name),
              // Dark gradient
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.black.withValues(alpha: 0.9),
                      ],
                      stops: const [0.25, 1.0],
                    ),
                  ),
                ),
              ),
              // Left poster thumbnail
              if (posterPath != null)
                Positioned(
                  left: 12,
                  bottom: 12,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: AppNetworkImage(
                      url: TmdbApiService.getPosterUrl(posterPath),
                      width: 55,
                      height: 80,
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
              // "UPCOMING" badge
              Positioned(
                top: 12,
                left: 12,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.amber.shade700,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    'UPCOMING',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ),
              // Rating
              if (rating != null && rating > 0)
                Positioned(
                  top: 12,
                  right: 12,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.7),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.star, color: Colors.amber, size: 14),
                        const SizedBox(width: 4),
                        Text(
                          rating.toStringAsFixed(1),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              // Text info at bottom
              Positioned(
                left: posterPath != null ? 78 : 12,
                right: 12,
                bottom: 12,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      name,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    // Date + seasons/episodes info
                    Row(
                      children: [
                        if (firstAirDate.isNotEmpty) ...[
                          const Icon(
                            Icons.calendar_today,
                            color: Colors.amber,
                            size: 12,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            _formatReleaseDate(firstAirDate),
                            style: const TextStyle(
                              color: Colors.amber,
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (seasonCount != null || episodeCount != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Row(
                          children: [
                            if (seasonCount != null)
                              Text(
                                '$seasonCount season${seasonCount == 1 ? '' : 's'}',
                                style: const TextStyle(
                                  color: Colors.white60,
                                  fontSize: 11,
                                ),
                              ),
                            if (seasonCount != null && episodeCount != null)
                              const Text(
                                '  \u00B7  ',
                                style: TextStyle(
                                  color: Colors.white38,
                                  fontSize: 11,
                                ),
                              ),
                            if (episodeCount != null)
                              Text(
                                '$episodeCount episode${episodeCount == 1 ? '' : 's'}',
                                style: const TextStyle(
                                  color: Colors.white60,
                                  fontSize: 11,
                                ),
                              ),
                          ],
                        ),
                      ),
                    if (overview.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        overview,
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 11,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPosterFallback(String? posterPath, String name) {
    if (posterPath != null) {
      return AppNetworkImage(
        url: TmdbApiService.getPosterUrl(posterPath),
        fit: BoxFit.cover,
        errorWidget: _buildPlaceholder(),
      );
    }
    return _buildPlaceholder();
  }

  Widget _buildPlaceholder() {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.grey[850]!, Colors.grey[900]!],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: const Icon(Icons.tv, color: Colors.grey, size: 50),
    );
  }

  String _formatReleaseDate(String date) {
    if (date.isEmpty) return '';
    try {
      final parsed = DateTime.parse(date);
      final months = [
        'Jan',
        'Feb',
        'Mar',
        'Apr',
        'May',
        'Jun',
        'Jul',
        'Aug',
        'Sep',
        'Oct',
        'Nov',
        'Dec',
      ];
      return '${months[parsed.month - 1]} ${parsed.day}, ${parsed.year}';
    } catch (_) {
      return date;
    }
  }
}

class _FullListScreen extends StatefulWidget {
  final String title;
  final String mediaType;

  const _FullListScreen({required this.title, required this.mediaType});

  @override
  _FullListScreenState createState() => _FullListScreenState();
}

class _FullListScreenState extends State<_FullListScreen> {
  List<Map<String, dynamic>> _allItems = [];
  bool _isLoading = false;
  int _currentPage = 1;
  bool _hasMore = true;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_scrollListener);
    _loadInitialItems();
  }

  Future<void> _loadInitialItems() async {
    setState(() {
      _isLoading = true;
    });

    try {
      List<Map<String, dynamic>> initialItems = [];

      if (widget.title.contains('Trending') && widget.mediaType == 'tv') {
        initialItems = await TmdbApiService.fetchTrendingSeries(page: 1);
      } else if (widget.title.contains('Popular') && widget.mediaType == 'tv') {
        initialItems = await TmdbApiService.fetchPopularSeries(page: 1);
      } else if (widget.title.contains('Top Rated') &&
          widget.mediaType == 'tv') {
        initialItems = await TmdbApiService.fetchTopRatedSeries(page: 1);
      } else if (widget.title.contains('On The Air') &&
          widget.mediaType == 'tv') {
        initialItems = await TmdbApiService.fetchOnTheAirSeries(page: 1);
      } else if (widget.title.contains('Coming Soon') &&
          widget.mediaType == 'tv') {
        initialItems = await TmdbApiService.fetchUpcomingSeries(page: 1);
      }

      setState(() {
        _allItems = filterForKids(initialItems);
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollListener() {
    if (_scrollController.position.pixels ==
            _scrollController.position.maxScrollExtent &&
        !_isLoading &&
        _hasMore) {
      _loadMoreItems();
    }
  }

  Future<void> _loadMoreItems() async {
    if (_isLoading || !_hasMore) return;

    setState(() {
      _isLoading = true;
    });

    try {
      final nextPage = _currentPage + 1;
      List<Map<String, dynamic>> newItems = [];

      if (widget.title.contains('Trending') && widget.mediaType == 'tv') {
        newItems = await TmdbApiService.fetchTrendingSeries(page: nextPage);
      } else if (widget.title.contains('Popular') && widget.mediaType == 'tv') {
        newItems = await TmdbApiService.fetchPopularSeries(page: nextPage);
      } else if (widget.title.contains('Top Rated') &&
          widget.mediaType == 'tv') {
        newItems = await TmdbApiService.fetchTopRatedSeries(page: nextPage);
      } else if (widget.title.contains('On The Air') &&
          widget.mediaType == 'tv') {
        newItems = await TmdbApiService.fetchOnTheAirSeries(page: nextPage);
      } else if (widget.title.contains('Coming Soon') &&
          widget.mediaType == 'tv') {
        newItems = await TmdbApiService.fetchUpcomingSeries(page: nextPage);
      }

      if (!mounted) return;
      final merged = uniqueTmdbItems(
        _allItems,
        filterForKids(newItems),
        widget.mediaType,
      );
      setState(() {
        _hasMore = merged.length > _allItems.length;
        _allItems = merged;
        if (_hasMore) _currentPage = nextPage;
      });
    } catch (e) {
      // Error loading more items
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Widget _buildShimmerGrid() {
    return AppShimmer(
      baseColor: Colors.grey[800]!,
      highlightColor: Colors.grey[600]!,
      child: GridView.builder(
        padding: const EdgeInsets.all(16),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          childAspectRatio: 0.6,
        ),
        itemCount: 12,
        itemBuilder: (context, index) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: Colors.grey[800],
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Container(
                height: 12,
                width: double.infinity,
                color: Colors.grey[800],
              ),
              const SizedBox(height: 4),
              Container(height: 10, width: 40, color: Colors.grey[800]),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1A1A),
        title: Text(widget.title, style: const TextStyle(color: Colors.white)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: _isLoading && _allItems.isEmpty
          ? _buildShimmerGrid()
          : GridView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(16),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
                childAspectRatio: 0.6,
              ),
              itemCount: _allItems.length + (_isLoading ? 1 : 0),
              itemBuilder: (context, index) {
                if (index < _allItems.length) {
                  final item = _allItems[index];
                  return GestureDetector(
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => MaxStreamSeriesScreen(
                            seriesItem: Movie.fromJson(item),
                          ),
                        ),
                      );
                    },
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: item['poster_path'] != null
                                ? AppNetworkImage(
                                    url: TmdbApiService.getPosterUrl(
                                      item['poster_path'],
                                    ),
                                    width: double.infinity,
                                    fit: BoxFit.cover,
                                  )
                                : Container(
                                    width: double.infinity,
                                    color: Colors.grey[800],
                                    child: const Icon(
                                      Icons.tv,
                                      color: Colors.grey,
                                      size: 40,
                                    ),
                                  ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          item['name'] ?? 'Unknown',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          _getYear(item),
                          style: const TextStyle(
                            color: Colors.grey,
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                  );
                } else {
                  return const Center(
                    child: CircularProgressIndicator(
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  );
                }
              },
            ),
    );
  }

  String _getYear(Map<String, dynamic> item) {
    final date = item['first_air_date'];
    if (date != null && date.length >= 4) {
      return date.substring(0, 4);
    }
    return '';
  }
}
