import 'package:flutter/material.dart';

import '../widgets/floating_nav_metrics.dart';
import '../services/watch_history_service.dart';
import '../services/cloud_sync_service.dart';

import 'package:maxstream/widgets/video_player_screen.dart';
import '../widgets/app_network_image.dart';

class WatchHistoryScreen extends StatefulWidget {
  final bool embedded;
  const WatchHistoryScreen({super.key, this.embedded = false});

  @override
  State<WatchHistoryScreen> createState() => _WatchHistoryScreenState();
}

class _WatchHistoryScreenState extends State<WatchHistoryScreen> {
  List<Map<String, dynamic>> _watchHistory = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    WatchHistoryService.localHistoryRevision.addListener(_onHistoryChanged);
    CloudSyncService.historyRevision.addListener(_onHistoryChanged);
    _loadWatchHistory();
  }

  @override
  void dispose() {
    WatchHistoryService.localHistoryRevision.removeListener(_onHistoryChanged);
    CloudSyncService.historyRevision.removeListener(_onHistoryChanged);
    super.dispose();
  }

  void _onHistoryChanged() {
    if (mounted) _loadWatchHistory();
  }

  Future<void> _loadWatchHistory() async {
    final historyList = await WatchHistoryService.getGroupedWatchHistory();

    if (!mounted) return;
    setState(() {
      _watchHistory = historyList;
      _isLoading = false;
    });
  }

  Future<void> _clearHistory() async {
    await WatchHistoryService.clearAllHistory();
    setState(() {
      _watchHistory = [];
    });
  }

  Future<void> _removeItem(int index) async {
    final item = _watchHistory[index];

    // Show loading state
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Removing from history...'),
        backgroundColor: Colors.grey,
        duration: Duration(seconds: 1),
      ),
    );

    try {
      if (item['isMovie'] == true) {
        await WatchHistoryService.removeFromHistory(
          item['tmdbId'],
          true,
          item['season'] ?? 1,
          item['episode'] ?? 1,
        );
      } else {
        await WatchHistoryService.removeSeriesFromHistory(item['tmdbId']);
      }

      setState(() {
        _watchHistory.removeAt(index);
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Removed from history'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error removing item: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  void _continueWatching(Map<String, dynamic> item) {
    Navigator.push(
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
  }

  @override
  Widget build(BuildContext context) {
    final body = RefreshIndicator(
      onRefresh: _loadWatchHistory,
      color: Colors.red,
      child: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Colors.red))
          : _watchHistory.isEmpty
          ? _buildEmptyState()
          : _buildHistoryList(),
    );

    if (widget.embedded) {
      return body;
    }

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text(
          'Watch History',
          style: TextStyle(color: Colors.white),
        ),
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          if (_watchHistory.isNotEmpty)
            IconButton(
              onPressed: () => _showClearDialog(),
              icon: const Icon(Icons.clear_all),
              tooltip: 'Clear History',
            ),
        ],
      ),
      body: body,
    );
  }

  Widget _buildEmptyState() {
    return ListView(
      children: [
        SizedBox(height: MediaQuery.of(context).size.height * 0.3),
        const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.history, size: 80, color: Colors.grey),
              SizedBox(height: 16),
              Text(
                'No Watch History',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              SizedBox(height: 8),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  'Start watching movies and shows to see your history here',
                  style: TextStyle(color: Colors.grey, fontSize: 14),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildHistoryList() {
    return ListView.builder(
      padding: EdgeInsets.fromLTRB(
        16,
        16,
        16,
        16 + FloatingNavBar.clearance(context),
      ),
      itemCount: _watchHistory.length,
      itemBuilder: (context, index) {
        final item = _watchHistory[index];
        return _buildHistoryItem(item, index);
      },
    );
  }

  Widget _buildHistoryItem(Map<String, dynamic> item, int index) {
    final watched = item['isWatched'] == true;
    final progress = watched
        ? 1.0
        : ((item['position'] ?? 0) / (item['duration'] ?? 1)).toDouble();
    final progressPercent = (progress * 100).round();

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Colors.grey[900],
        borderRadius: BorderRadius.circular(12),
      ),
      child: InkWell(
        onTap: () => _continueWatching(item),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: AppNetworkImage(
                  url: item['posterUrl']?.toString() ?? '',
                  width: 80,
                  height: 120,
                  fit: BoxFit.cover,
                  errorWidget: Container(
                    width: 80,
                    height: 120,
                    color: Colors.grey[800],
                    child: const Icon(
                      Icons.movie,
                      color: Colors.grey,
                      size: 40,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              // Content info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item['title'] ?? 'Unknown Title',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    if (!item['isMovie'])
                      Text(
                        'Latest: S${item['season']}E${item['episode']}'
                        '${(item['groupedEpisodeCount'] as num?)?.toInt() == 1 ? '' : ' · ${item['groupedEpisodeCount']} episodes'}',
                        style: const TextStyle(
                          color: Colors.grey,
                          fontSize: 14,
                        ),
                      ),
                    const SizedBox(height: 8),
                    // Progress bar
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          watched ? 'Watched' : '$progressPercent% watched',
                          style: const TextStyle(
                            color: Colors.grey,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 4),
                        LinearProgressIndicator(
                          value: progress,
                          backgroundColor: Colors.grey[700],
                          valueColor: const AlwaysStoppedAnimation<Color>(
                            Colors.red,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _formatTimestamp(item['timestamp']),
                      style: const TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                  ],
                ),
              ),
              // Actions
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert, color: Colors.white),
                color: Colors.grey[800],
                onSelected: (value) {
                  if (value == 'remove') {
                    _removeItem(index);
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: 'remove',
                    child: Row(
                      children: [
                        Icon(Icons.delete, color: Colors.red),
                        SizedBox(width: 8),
                        Text('Remove', style: TextStyle(color: Colors.white)),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatTimestamp(int? timestamp) {
    if (timestamp == null) return 'Unknown';

    final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final now = DateTime.now();
    final difference = now.difference(date);

    if (difference.inDays > 0) {
      return '${difference.inDays} day${difference.inDays == 1 ? '' : 's'} ago';
    } else if (difference.inHours > 0) {
      return '${difference.inHours} hour${difference.inHours == 1 ? '' : 's'} ago';
    } else if (difference.inMinutes > 0) {
      return '${difference.inMinutes} minute${difference.inMinutes == 1 ? '' : 's'} ago';
    } else {
      return 'Just now';
    }
  }

  void _showClearDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text(
          'Clear Watch History',
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          'Are you sure you want to clear all watch history? This action cannot be undone.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _clearHistory();
            },
            child: const Text('Clear', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}
