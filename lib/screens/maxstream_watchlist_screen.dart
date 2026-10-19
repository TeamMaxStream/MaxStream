import 'package:flutter/material.dart';

import '../widgets/floating_nav_metrics.dart';
import '../database/db_helper.dart';
import '../models/movie.dart';
import '../services/cloud_sync_service.dart';
import '../widgets/app_shimmer.dart';
import 'maxstream_details_screen.dart';
import 'maxstream_series_screen.dart';
import '../widgets/app_network_image.dart';

class MaxStreamWatchlistScreen extends StatefulWidget {
  final bool embedded;
  const MaxStreamWatchlistScreen({super.key, this.embedded = false});

  @override
  State<MaxStreamWatchlistScreen> createState() =>
      _MaxStreamWatchlistScreenState();
}

class _MaxStreamWatchlistScreenState extends State<MaxStreamWatchlistScreen>
    with SingleTickerProviderStateMixin {
  List<Movie> watchlistItems = [];
  List<Movie> movies = [];
  List<Movie> series = [];
  bool isLoading = true;
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    CloudSyncService.watchlistRevision.addListener(_onSyncedWatchlist);
    _loadWatchlist();
  }

  void _onSyncedWatchlist() {
    if (mounted) _loadWatchlist(showLoading: false);
  }

  @override
  void dispose() {
    CloudSyncService.watchlistRevision.removeListener(_onSyncedWatchlist);
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadWatchlist({bool showLoading = true}) async {
    if (mounted && showLoading) setState(() => isLoading = true);
    try {
      await CloudSyncService.pullToDevice();
      final items = await DBHelper.getWatchlistItems();
      if (!mounted) return;
      setState(() {
        watchlistItems = items;
        movies = items.where((item) => item.mediaType != 'tv').toList();
        series = items.where((item) => item.mediaType == 'tv').toList();
      });
    } catch (e) {
      // Error loading watchlist
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  Future<void> _removeFromWatchlist(Movie item) async {
    try {
      await DBHelper.removeFromWatchlist(item.id, item.mediaType);
      await _loadWatchlist();
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
          ),
        );
      }
    } catch (e) {
      // Error removing from watchlist
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.error, color: Colors.white, size: 20),
                const SizedBox(width: 8),
                Text('Error removing from watchlist'),
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

  @override
  Widget build(BuildContext context) {
    final body = isLoading
        ? AppShimmer(
            baseColor: Colors.grey[800]!,
            highlightColor: Colors.grey[600]!,
            child: GridView.builder(
              padding: EdgeInsets.fromLTRB(
                16,
                16,
                16,
                16 + FloatingNavBar.clearance(context),
              ),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                childAspectRatio: 0.6,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
              ),
              itemCount: 9,
              itemBuilder: (_, __) => Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          )
        : TabBarView(
            controller: _tabController,
            children: [
              watchlistItems.isEmpty
                  ? _buildEmptyState()
                  : _buildWatchlistGrid(watchlistItems),
              movies.isEmpty
                  ? _buildEmptyState()
                  : _buildWatchlistGrid(movies),
              series.isEmpty
                  ? _buildEmptyState()
                  : _buildWatchlistGrid(series),
            ],
          );

    if (widget.embedded) {
      return Column(
        children: [
          TabBar(
            controller: _tabController,
            indicatorColor: Colors.red,
            labelColor: Colors.white,
            unselectedLabelColor: Colors.grey,
            tabs: [
              Tab(text: 'All (${watchlistItems.length})'),
              Tab(text: 'Movies (${movies.length})'),
              Tab(text: 'Series (${series.length})'),
            ],
          ),
          Expanded(child: body),
        ],
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text(
          'My Watchlist',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            onPressed: _loadWatchlist,
            icon: const Icon(Icons.refresh, color: Colors.white),
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Colors.red,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.grey,
          tabs: [
            Tab(text: 'All (${watchlistItems.length})'),
            Tab(text: 'Movies (${movies.length})'),
            Tab(text: 'Series (${series.length})'),
          ],
        ),
      ),
      body: body,
    );
  }

  Widget _buildEmptyState() {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.bookmark_border, size: 64, color: Colors.grey),
          SizedBox(height: 16),
          Text(
            'Your watchlist is empty',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          SizedBox(height: 8),
          Text(
            'Add movies and TV shows to keep track of what you want to watch',
            style: TextStyle(color: Colors.grey, fontSize: 14),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildWatchlistGrid(List<Movie> items) {
    return GridView.builder(
      padding: EdgeInsets.fromLTRB(
                16,
                16,
                16,
                16 + FloatingNavBar.clearance(context),
              ),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        childAspectRatio: 0.6,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        return _buildWatchlistItem(item);
      },
    );
  }

  Widget _buildWatchlistItem(Movie item) {
    return GestureDetector(
      onTap: () {
        if (!mounted) return;
        Navigator.push(
          context,
          PageRouteBuilder(
            pageBuilder: (context, animation, secondaryAnimation) =>
                item.mediaType == 'tv'
                ? MaxStreamSeriesScreen(seriesItem: item)
                : MaxStreamDetailsScreen(item: item, mediaType: item.mediaType),
            transitionsBuilder:
                (context, animation, secondaryAnimation, child) {
                  return SlideTransition(
                    position:
                        Tween<Offset>(
                          begin: const Offset(1.0, 0.0),
                          end: Offset.zero,
                        ).animate(
                          CurvedAnimation(
                            parent: animation,
                            curve: Curves.fastOutSlowIn,
                          ),
                        ),
                    child: child,
                  );
                },
            transitionDuration: const Duration(milliseconds: 250),
          ),
        );
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: item.thumbnail.isNotEmpty
                      ? AppNetworkImage(
                          url: item.thumbnail,
                          width: double.infinity,
                          height: double.infinity,
                          fit: BoxFit.cover,
                          errorWidget: Container(
                            color: Colors.grey[800],
                            child: const Icon(
                              Icons.movie,
                              color: Colors.grey,
                            ),
                          ),
                        )
                      : Container(
                          width: double.infinity,
                          height: double.infinity,
                          color: Colors.grey[800],
                          child: const Icon(Icons.movie, color: Colors.grey),
                        ),
                ),
                Positioned(
                  top: 4,
                  right: 4,
                  child: GestureDetector(
                    onTap: () => _removeFromWatchlist(item),
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.7),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(
                        Icons.close,
                        color: Colors.white,
                        size: 16,
                      ),
                    ),
                  ),
                ),
                if (item.rating > 0)
                  Positioned(
                    bottom: 4,
                    left: 4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.7),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.star, color: Colors.amber, size: 10),
                          const SizedBox(width: 2),
                          Text(
                            item.rating.toStringAsFixed(1),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 8,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Text(
            item.title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          if (item.year.isNotEmpty)
            Text(
              item.year,
              style: const TextStyle(color: Colors.grey, fontSize: 10),
            ),
        ],
      ),
    );
  }
}
