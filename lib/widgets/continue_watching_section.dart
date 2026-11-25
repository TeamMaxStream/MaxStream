import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import '../screens/maxstream_details_screen.dart';
import '../screens/maxstream_series_screen.dart';
import '../models/movie.dart';
import '../services/watch_history_service.dart';
import 'video_player_screen.dart';

class ContinueWatchingSection extends StatefulWidget {
  final List<Map<String, dynamic>> continueWatching;
  final Future<void> Function()? onChanged;

  const ContinueWatchingSection({
    super.key,
    required this.continueWatching,
    this.onChanged,
  });

  @override
  State<ContinueWatchingSection> createState() =>
      _ContinueWatchingSectionState();
}

class _ContinueWatchingSectionState extends State<ContinueWatchingSection> {
  @override
  Widget build(BuildContext context) {
    if (widget.continueWatching.isEmpty) return const SizedBox();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            'Continue Watching',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        SizedBox(
          height: 280,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: widget.continueWatching.length,
            itemBuilder: (context, index) {
              final item = widget.continueWatching[index];
              return _buildContinueWatchingCard(context, item);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildContinueWatchingCard(
    BuildContext context,
    Map<String, dynamic> item,
  ) {
    final progress = (item['position'] ?? 0) / (item['duration'] ?? 1);
    final progressPercent = (progress * 100).round();
    final isMovie = item['isMovie'] == true;
    final typeLabel = isMovie ? 'MOVIE' : 'TV';
    final title = item['title'] ?? 'Unknown Title';

    return SizedBox(
      width: 150,
      child: GestureDetector(
        onTap: () => _playContent(context, item),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: 150,
                height: 225,
                child: Stack(
                  children: [
                    Container(
                      width: 150,
                      height: 225,
                      color: Colors.grey[850],
                      child:
                          item['posterUrl'] != null &&
                              item['posterUrl'].toString().isNotEmpty
                          ? Image.network(
                              item['posterUrl'].toString(),
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) =>
                                  _continueWatchingPosterFallback(),
                            )
                          : _continueWatchingPosterFallback(),
                    ),
                    Positioned(
                      top: 8,
                      left: 8,
                      child: _continueWatchingTypeBadge(typeLabel),
                    ),
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(
                              Icons.info_outline,
                              size: 18,
                              color: Colors.white,
                            ),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 32,
                              minHeight: 32,
                            ),
                            onPressed: () => _openDetails(context, item),
                          ),
                          PopupMenuButton<String>(
                            icon: const Icon(
                              Icons.more_vert,
                              size: 18,
                              color: Colors.white,
                            ),
                            iconSize: 18,
                            tooltip: 'More options',
                            onSelected: (value) {
                              unawaited(
                                _runContinueWatchingAction(
                                  context,
                                  value,
                                  item,
                                ),
                              );
                            },
                            itemBuilder: (context) => <PopupMenuEntry<String>>[
                              const PopupMenuItem(
                                value: 'mark',
                                child: Text('Mark as Watched'),
                              ),
                              const PopupMenuItem(
                                value: 'remove',
                                child: Text('Remove from Continue Watching'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    Positioned.fill(
                      child: Center(
                        child: Material(
                          color: Colors.black.withValues(alpha: 0.55),
                          shape: const CircleBorder(),
                          child: IconButton(
                            icon: const Icon(
                              Icons.play_arrow,
                              size: 26,
                              color: Colors.white,
                            ),
                            onPressed: () => _playContent(context, item),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 44,
                              minHeight: 44,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: progress,
                      backgroundColor: Colors.grey[800],
                      valueColor: const AlwaysStoppedAnimation<Color>(
                        Colors.red,
                      ),
                      minHeight: 3,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '$progressPercent%',
                  style: const TextStyle(
                    color: Colors.red,
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _continueWatchingPosterFallback() {
    return Container(
      color: Colors.grey[850],
      child: Icon(Icons.movie, color: Colors.grey, size: 40),
    );
  }

  Widget _continueWatchingTypeBadge(String typeLabel) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.red,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        typeLabel,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 9,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Future<void> _openDetails(
    BuildContext context,
    Map<String, dynamic> item,
  ) async {
    final isMovie = item['isMovie'] == true;
    final tmdbId = (item['tmdbId'] ?? item['id'] ?? '').toString();
    final movie = Movie(
      id: tmdbId,
      title: item['title']?.toString() ?? 'Unknown Title',
      description: item['description']?.toString() ?? '',
      thumbnail: item['posterUrl']?.toString() ?? '',
      videoUrl: '',
      trailerUrl: '',
      genres: const [],
      year: item['year']?.toString() ?? '',
      rating: (item['rating'] as num?)?.toDouble() ?? 0,
      mediaType: isMovie ? 'movie' : 'tv',
    );
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => isMovie
            ? MaxStreamDetailsScreen(item: movie, mediaType: 'movie')
            : MaxStreamSeriesScreen(seriesItem: movie),
      ),
    );
  }

  Future<void> _runContinueWatchingAction(
    BuildContext context,
    String action,
    Map<String, dynamic> item,
  ) async {
    final isMovie = item['isMovie'] == true;
    final tmdbId = (item['tmdbId'] ?? item['id'] ?? '').toString();
    final season = (item['season'] ?? 1) is int
        ? (item['season'] as int)
        : int.tryParse(item['season']?.toString() ?? '') ?? 1;
    final episode = (item['episode'] ?? 1) is int
        ? (item['episode'] as int)
        : int.tryParse(item['episode']?.toString() ?? '') ?? 1;

    if (action == 'mark') {
      await WatchHistoryService.markAsWatched(tmdbId, isMovie, season, episode);
    } else if (action == 'remove') {
      await WatchHistoryService.removeFromHistory(
        tmdbId,
        isMovie,
        season,
        episode,
      );
    }

    if (mounted) await widget.onChanged?.call();
  }

  Future<void> _playContent(
    BuildContext context,
    Map<String, dynamic> item,
  ) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => buildVideoPlayerScreen(
          title: item['title'],
          tmdbId: item['tmdbId'],
          isMovie: item['isMovie'],
          season: item['season'] ?? 1,
          episode: item['episode'] ?? 1,
        ),
      ),
    );
    await widget.onChanged?.call();
  }
}
