import 'dart:async';

import 'package:flutter/material.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';
import '../widgets/app_shimmer.dart';
import '../database/db_helper.dart';
import '../models/movie.dart';
import '../services/cloud_sync_service.dart';
import '../services/direct_m3u8_service.dart';
import '../services/media_download_manager.dart';
import '../services/miniplayer_service.dart';
import '../services/server_list_loader.dart';
import '../services/stream_audio_helper.dart';
import '../services/stream_size_probe.dart';
import '../services/tmdb_api_service.dart';
import '../services/watch_history_service.dart';
import '../services/watch_reminder_service.dart';
import '../widgets/app_network_image.dart';
import '../widgets/video_player_screen.dart';

class MaxStreamDetailsScreen extends StatefulWidget {
  final Movie item;
  final String mediaType;

  const MaxStreamDetailsScreen({
    super.key,
    required this.item,
    required this.mediaType,
  });

  @override
  State<MaxStreamDetailsScreen> createState() => _MaxStreamDetailsScreenState();
}

class _MaxStreamDetailsScreenState extends State<MaxStreamDetailsScreen> {
  YoutubePlayerController? _youtubeController;
  bool isSaved = false;
  bool isLoading = true;
  String? trailerUrl;
  Map<String, dynamic>? details;
  List<Map<String, dynamic>> cast = [];
  List<Map<String, dynamic>> recommendations = [];
  bool _downloadingMovie = false;
  bool _isMovieDownloaded = false;
  late ScrollController _scrollController;
  late final MediaDownloadManager _downloadManager;
  Map<String, dynamic>? _watchProgress;
  bool _isReminded = false;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _downloadManager = MediaDownloadManager.instance;
    _downloadManager.addListener(_onDownloadChanged);
    CloudSyncService.watchlistRevision.addListener(_onSyncedWatchlist);
    _loadDetails();
    _checkDownloadStatus();
    _loadWatchProgress();
    _checkReminderStatus();
  }

  void _onSyncedWatchlist() {
    if (mounted) _checkWatchlistStatus();
  }

  @override
  void dispose() {
    CloudSyncService.watchlistRevision.removeListener(_onSyncedWatchlist);
    _youtubeController?.dispose();
    _scrollController.dispose();
    _downloadManager.removeListener(_onDownloadChanged);
    super.dispose();
  }

  void _onDownloadChanged() {
    if (mounted) {
      _checkDownloadStatus();
      setState(() {});
    }
  }

  String get _downloadKey => 'movie_${widget.item.id}';

  Future<void> _checkDownloadStatus() async {
    final downloads = await DBHelper.getMediaDownloads();
    final isDownloaded = downloads.any(
      (d) => d['downloadKey']?.toString() == _downloadKey,
    );
    final activeTask = _downloadManager.taskFor(_downloadKey);
    if (mounted) {
      setState(() {
        _isMovieDownloaded = isDownloaded && activeTask == null;
      });
    }
  }

  Future<void> _checkReminderStatus() async {
    if (widget.mediaType != 'tv') return;
    final reminded = await WatchReminderService.isReminded(
      int.parse(widget.item.id),
    );
    if (mounted) setState(() => _isReminded = reminded);
  }

  Future<void> _toggleReminder() async {
    final showId = int.parse(widget.item.id);
    final title = widget.item.title;
    final posterPath = widget.item.thumbnail ?? '';

    // Get current season/episode count from details
    int lastSeason = details?['number_of_seasons'] as int? ?? 1;
    int lastEpisode = 0;
    if (lastSeason > 0 && details?['seasons'] != null) {
      final seasons = details!['seasons'] as List<dynamic>;
      final currentSeason = seasons.lastWhere(
        (s) => (s['season_number'] as int? ?? 0) > 0,
        orElse: () => seasons.isNotEmpty ? seasons.last : null,
      );
      if (currentSeason != null) {
        lastSeason = currentSeason['season_number'] as int? ?? lastSeason;
        lastEpisode = currentSeason['episode_count'] as int? ?? 0;
      }
    }

    final newState = await WatchReminderService.toggleReminder(
      showId: showId,
      title: title,
      posterPath: posterPath,
      lastKnownSeason: lastSeason,
      lastKnownEpisode: lastEpisode,
    );

    if (mounted) {
      setState(() => _isReminded = newState);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            newState ? 'Reminder set for new episodes' : 'Reminder removed',
          ),
          backgroundColor: newState ? Colors.green : Colors.grey[800],
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _loadWatchProgress() async {
    await CloudSyncService.pullToDevice();
    final continueWatching = await WatchHistoryService.getContinueWatching();
    if (!mounted) return;

    // Search in continue watching first (partially watched)
    final match = continueWatching.firstWhere(
      (item) =>
          item['tmdbId']?.toString() == widget.item.id &&
          item['isMovie'] == true,
      orElse: () => {},
    );
    if (match.isNotEmpty) {
      setState(() => _watchProgress = match);
      return;
    }

    // Also check full watch history for recently watched movies
    final allHistory = await WatchHistoryService.getWatchHistory();
    if (!mounted) return;
    final historyMatch = allHistory.firstWhere(
      (item) =>
          item['tmdbId']?.toString() == widget.item.id &&
          item['isMovie'] == true,
      orElse: () => {},
    );
    if (historyMatch.isNotEmpty) {
      final position = (historyMatch['position'] as num?)?.toInt() ?? 0;
      final duration = (historyMatch['duration'] as num?)?.toInt() ?? 1;
      if (position > 30 && duration > 0) {
        setState(() => _watchProgress = historyMatch);
      }
    }
  }

  void _initializeYouTubePlayer(String url) {
    final videoId = YoutubePlayer.convertUrlToId(url);
    if (videoId != null) {
      setState(() {
        trailerUrl = url;
        _youtubeController = YoutubePlayerController(
          initialVideoId: videoId,
          flags: const YoutubePlayerFlags(
            autoPlay: false,
            mute: false,
            enableCaption: true,
          ),
        );
      });
    }
  }

  Future<void> _loadDetails() async {
    setState(() => isLoading = true);

    try {
      final id = int.parse(widget.item.id);
      final detailsData = widget.mediaType == 'movie'
          ? await TmdbApiService.getMovieDetails(id)
          : await TmdbApiService.getSeriesDetails(id);

      if (detailsData != null) {
        setState(() {
          details = detailsData;
          cast = List<Map<String, dynamic>>.from(
            detailsData['credits']?['cast'] ?? [],
          );
          recommendations = List<Map<String, dynamic>>.from(
            detailsData['recommendations']?['results'] ?? [],
          );
        });

        // Load trailer
        final trailerUrlFromApi = await TmdbApiService.getTrailerUrl(
          id,
          isMovie: widget.mediaType == 'movie',
        );
        if (trailerUrlFromApi.isNotEmpty) {
          _initializeYouTubePlayer(trailerUrlFromApi);
        }
        // Warm the server list in the background so the download picker and
        // playback open instantly.
        if (widget.mediaType == 'movie') {
          DirectM3u8Service.prefetchAvailableStreams(
            title: widget.item.title,
            tmdbId: widget.item.id,
            isMovie: true,
          );
        }
      }
      _checkWatchlistStatus();
    } catch (e) {
      // Error loading details
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  Future<void> _checkWatchlistStatus() async {
    await CloudSyncService.pullToDevice();
    final watchlist = await DBHelper.getWatchlistItems();
    if (mounted) {
      setState(() {
        isSaved = watchlist.any(
          (item) =>
              item.id == widget.item.id &&
              item.mediaType == widget.item.mediaType,
        );
      });
    }
  }

  Future<void> _toggleWatchlist() async {
    try {
      final wasAdded = !isSaved; // Store the action before state changes

      if (isSaved) {
        await DBHelper.removeFromWatchlist(
          widget.item.id,
          widget.item.mediaType,
        );
      } else {
        await DBHelper.addToWatchlist(widget.item);
      }
      await _checkWatchlistStatus();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                Icon(
                  wasAdded ? Icons.favorite : Icons.favorite_border,
                  color: Colors.white,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text(
                  wasAdded ? 'Added to Watchlist' : 'Removed from Watchlist',
                ),
              ],
            ),
            backgroundColor: wasAdded
                ? Colors.green.shade600
                : Colors.red.shade600,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      // Error toggling watchlist
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

  void _showQualitySelectionSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return _QualitySelectionSheet(
          title: widget.item.title,
          tmdbId: widget.item.id,
          onDownload: (selectedStream) {
            _startDownload(selectedStream: selectedStream);
          },
        );
      },
    );
  }

  Future<void> _startDownload({Map<String, dynamic>? selectedStream}) async {
    if (_downloadingMovie) return;
    // Stop any background playback before starting download.
    MiniplayerService.instance.close();
    setState(() => _downloadingMovie = true);
    try {
      bool found;
      if (selectedStream != null) {
        final url = selectedStream['url']?.toString() ?? '';
        if (url.isEmpty) {
          found = false;
        } else {
          final headers = <String, String>{};
          if (selectedStream['referer'] != null) {
            headers['Referer'] = selectedStream['referer'].toString();
          }
          if (selectedStream['headers'] is Map) {
            (selectedStream['headers'] as Map).forEach((k, v) {
              headers[k.toString()] = v.toString();
            });
          }
          final isHls =
              selectedStream['type'] == 'direct_m3u8' ||
              url.toLowerCase().contains('.m3u8');
          await MediaDownloadManager.instance.start(
            downloadKey: _downloadKey,
            url: url,
            headers: headers,
            isHls: isHls,
            mediaId: widget.item.id,
            isMovie: true,
            title: widget.item.title,
            resolverTitle: widget.item.title,
            thumbnail: widget.item.thumbnail,
            maxVariantHeightPixels: int.tryParse(
              selectedStream['maxVariantHeight']?.toString() ?? '',
            ),
            subtitles: (selectedStream['subtitles'] as List? ?? const [])
                .whereType<Map>()
                .map(
                  (track) => track.map(
                    (key, value) => MapEntry(key.toString(), value),
                  ),
                )
                .toList(),
          );
          found = true;
        }
      } else {
        found = await MediaDownloadManager.instance.resolveAndStart(
          downloadKey: _downloadKey,
          mediaId: widget.item.id,
          isMovie: true,
          title: widget.item.title,
          thumbnail: widget.item.thumbnail,
        );
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            found
                ? '${widget.item.title} download started'
                : 'No downloadable stream was found',
          ),
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Download failed: $error')));
      }
    } finally {
      if (mounted) setState(() => _downloadingMovie = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      onPopInvoked: (didPop) {
        if (didPop) {
          _youtubeController?.pause();
        }
      },
      child: Scaffold(
        body: isLoading
            ? buildLoadingShimmer()
            : RefreshIndicator(
                onRefresh: _loadDetails,
                color: Colors.red,
                child: CustomScrollView(
                  controller: _scrollController,
                  physics: const BouncingScrollPhysics(),
                  slivers: [
                    buildSliverAppBar(),
                    SliverToBoxAdapter(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          buildDetailsSection(),
                          if (_watchProgress != null) _buildContinueWatching(),
                          if (cast.isNotEmpty) buildCastSection(),
                          if (recommendations.isNotEmpty)
                            buildRecommendationsSection(),
                          const SizedBox(height: 20),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  Widget buildLoadingShimmer() {
    return AppShimmer(
      baseColor: Colors.grey[800]!,
      highlightColor: Colors.grey[600]!,
      child: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 300,
            flexibleSpace: Container(color: Colors.grey[800]),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(height: 24, width: 200, color: Colors.grey[800]),
                  const SizedBox(height: 8),
                  Container(height: 16, width: 150, color: Colors.grey[800]),
                  const SizedBox(height: 16),
                  ...List.generate(
                    5,
                    (index) => Padding(
                      padding: const EdgeInsets.only(bottom: 8.0),
                      child: Container(height: 16, color: Colors.grey[800]),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget buildSliverAppBar() {
    final backdropPath = details?['backdrop_path'] ?? widget.item.backdropPath;
    final posterPath = details?['poster_path'] ?? widget.item.posterPath;

    // Check active download for progress
    final activeTask = _downloadManager.taskFor(_downloadKey);
    final isCurrentlyDownloading = activeTask != null;

    return SliverAppBar(
      expandedHeight: 350,
      pinned: true,
      backgroundColor: const Color(0xFF1A1A1A),
      scrolledUnderElevation: 0,
      flexibleSpace: FlexibleSpaceBar(
        background: Stack(
          fit: StackFit.expand,
          children: [
            if (backdropPath != null)
              AppNetworkImage(
                url: TmdbApiService.getBackdropUrl(backdropPath),
                fit: BoxFit.cover,
                errorWidget: Container(
                  color: Colors.grey[900],
                  child: const Icon(
                    Icons.broken_image,
                    size: 50,
                    color: Colors.grey,
                  ),
                ),
              )
            else
              Container(color: Colors.grey[900]),

            Container(
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

            Positioned(
              bottom: 16,
              left: 16,
              right: 16,
              child: SingleChildScrollView(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        color: Colors.grey[800],
                        child: posterPath != null
                            ? AppNetworkImage(
                                url: TmdbApiService.getPosterUrl(posterPath),
                                width: 110,
                                height: 165,
                                fit: BoxFit.cover,
                                errorWidget: Container(
                                  width: 110,
                                  height: 165,
                                  color: Colors.grey[800],
                                  child: const Icon(Icons.movie, size: 40),
                                ),
                              )
                            : Container(
                                width: 110,
                                height: 165,
                                color: Colors.grey[800],
                                child: const Icon(Icons.movie, size: 40),
                              ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            details?['title'] ??
                                details?['name'] ??
                                widget.item.title,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 4),
                          if (details?['release_date'] != null ||
                              details?['first_air_date'] != null)
                            Text(
                              getYear(),
                              style: const TextStyle(
                                color: Colors.grey,
                                fontSize: 14,
                              ),
                            ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Icon(Icons.star, color: Colors.amber, size: 20),
                              const SizedBox(width: 4),
                              Text(
                                '${details?['vote_average']?.toStringAsFixed(1) ?? 'N/A'}/10',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                ),
                              ),
                              const SizedBox(width: 12),
                              SizedBox(
                                width: 32,
                                height: 32,
                                child: IconButton(
                                  padding: EdgeInsets.zero,
                                  onPressed: _toggleWatchlist,
                                  icon: Icon(
                                    isSaved
                                        ? Icons.bookmark_rounded
                                        : Icons.bookmark_border_rounded,
                                    color: isSaved ? Colors.red : Colors.white,
                                    size: 20,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          // Watch Now button
                          SizedBox(
                            width: double.infinity,
                            height: 40,
                            child: ElevatedButton.icon(
                              onPressed: () => playContent(),
                              icon: const Icon(
                                Icons.play_arrow,
                                color: Colors.white,
                                size: 18,
                              ),
                              label: const Text(
                                'Play',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                ),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.red,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 8,
                                ),
                              ),
                            ),
                          ),
                          if (widget.mediaType == 'tv') ...[
                            const SizedBox(height: 8),
                            SizedBox(
                              width: double.infinity,
                              height: 40,
                              child: OutlinedButton.icon(
                                onPressed: _toggleReminder,
                                icon: Icon(
                                  _isReminded
                                      ? Icons.notifications_active
                                      : Icons.notifications_none,
                                  color: _isReminded
                                      ? Colors.red
                                      : Colors.white70,
                                  size: 18,
                                ),
                                label: Text(
                                  _isReminded ? 'Reminded' : 'Remind Me',
                                  style: TextStyle(
                                    color: _isReminded
                                        ? Colors.red
                                        : Colors.white70,
                                    fontSize: 14,
                                  ),
                                ),
                                style: OutlinedButton.styleFrom(
                                  side: BorderSide(
                                    color: _isReminded
                                        ? Colors.red
                                        : Colors.white24,
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 8,
                                  ),
                                ),
                              ),
                            ),
                          ],
                          if (widget.mediaType == 'movie') ...[
                            const SizedBox(height: 8),
                            if (isCurrentlyDownloading)
                              _buildDownloadProgressWidget(activeTask)
                            else if (_isMovieDownloaded)
                              SizedBox(
                                width: double.infinity,
                                height: 40,
                                child: OutlinedButton.icon(
                                  onPressed: null,
                                  icon: const Icon(
                                    Icons.check_circle,
                                    color: Colors.green,
                                  ),
                                  label: const Text(
                                    'Downloaded',
                                    style: TextStyle(color: Colors.green),
                                  ),
                                  style: OutlinedButton.styleFrom(
                                    side: const BorderSide(color: Colors.green),
                                  ),
                                ),
                              )
                            else
                              SizedBox(
                                width: double.infinity,
                                height: 40,
                                child: OutlinedButton.icon(
                                  onPressed: _showQualitySelectionSheet,
                                  icon: const Icon(
                                    Icons.download_for_offline_outlined,
                                  ),
                                  label: const Text('Download'),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: Colors.white,
                                    side: const BorderSide(
                                      color: Colors.white54,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDownloadProgressWidget(ActiveMediaDownload task) {
    final percent = (task.progress * 100).round().clamp(0, 100);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: LinearProgressIndicator(
                value: task.progress,
                minHeight: 6,
                color: task.isPaused ? Colors.orange : Colors.red,
                backgroundColor: Colors.white24,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '$percent%',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          task.isPaused
              ? 'Paused — ${task.sizeLabel}'
              : 'Downloading — ${task.sizeLabel}',
          style: TextStyle(
            color: task.isPaused ? Colors.orange : Colors.white70,
            fontSize: 11,
          ),
        ),
      ],
    );
  }

  Widget _buildContinueWatching() {
    final position = (_watchProgress!['position'] as num?)?.toInt() ?? 0;
    final duration = (_watchProgress!['duration'] as num?)?.toInt() ?? 1;
    final progress = duration > 0 ? (position / duration).clamp(0.0, 1.0) : 0.0;
    final percent = (progress * 100).round();
    final remaining = duration - position;
    final remainingMin = (remaining / 60).round();

    return GestureDetector(
      onTap: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => buildVideoPlayerScreen(
              title: widget.item.title,
              tmdbId: widget.item.id.toString(),
              isMovie: true,
            ),
          ),
        );
        _loadWatchProgress();
      },
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.grey[900],
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.play_circle_fill, color: Colors.red, size: 20),
                const SizedBox(width: 8),
                const Text(
                  'Continue Watching',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                Text(
                  '$percent%',
                  style: const TextStyle(color: Colors.grey, fontSize: 13),
                ),
              ],
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress,
                backgroundColor: Colors.grey[800],
                valueColor: const AlwaysStoppedAnimation<Color>(Colors.red),
                minHeight: 4,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '$remainingMin min remaining',
              style: const TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget buildDetailsSection() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_youtubeController != null) ...[
            const Text(
              'Trailer',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: IgnorePointer(
                ignoring: false,
                child: YoutubePlayer(
                  controller: _youtubeController!,
                  showVideoProgressIndicator: true,
                  progressIndicatorColor: Colors.red,
                  progressColors: const ProgressBarColors(
                    playedColor: Colors.red,
                    handleColor: Colors.redAccent,
                  ),
                  onReady: () {
                    _youtubeController?.pause();
                  },
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],

          const Text(
            'Overview',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            details?['overview'] ??
                widget.item.overview ??
                widget.item.description ??
                'No overview available.',
            style: const TextStyle(
              color: Colors.grey,
              fontSize: 16,
              height: 1.5,
            ),
          ),

          const SizedBox(height: 16),
          buildInfoGrid(),
        ],
      ),
    );
  }

  Widget buildInfoGrid() {
    final releaseDate = details?['release_date'] ?? details?['first_air_date'];
    final runtime = details?['runtime']?.toString();
    final genres = (details?['genres'] as List<dynamic>?)
        ?.map((g) => g['name'].toString())
        .join(', ');
    final productionCompanies =
        (details?['production_companies'] as List<dynamic>?)
            ?.map((c) => c['name'].toString())
            .join(', ');
    final productionCountries =
        (details?['production_countries'] as List<dynamic>?)
            ?.map((c) => c['name'].toString())
            .join(', ');

    return Column(
      children: [
        if (releaseDate != null)
          buildInfoRow('Release Date', formatDate(releaseDate)),
        if (runtime != null) buildInfoRow('Runtime', '$runtime minutes'),
        if (genres != null) buildInfoRow('Genres', genres),
        buildInfoRow(
          'Language',
          details?['original_language']?.toUpperCase() ?? 'N/A',
        ),
        if (productionCompanies != null && productionCompanies.isNotEmpty)
          buildInfoRow('Production', productionCompanies),
        if (productionCountries != null && productionCountries.isNotEmpty)
          buildInfoRow('Country', productionCountries),
        buildInfoRow('Status', details?['status'] ?? 'Unknown'),
        const SizedBox(height: 24),
        buildWatchProvidersSection(),
      ],
    );
  }

  Widget buildWatchProvidersSection() {
    final watchProviders =
        details?['watch/providers']?['results']?['US']?['flatrate'] as List?;

    if (watchProviders == null || watchProviders.isEmpty) {
      return const SizedBox.shrink();
    }

    final Map<int, Map<String, dynamic>> providerMap = {
      8: {'name': 'Netflix', 'color': const Color(0xFFE50914)},
      9: {'name': 'Prime Video', 'color': const Color(0xFF00A8E1)},
      337: {'name': 'Disney+', 'color': const Color(0xFF113CCF)},
      15: {'name': 'Hulu', 'color': const Color(0xFF1CE783)},
      179: {'name': 'Apple TV', 'color': const Color(0xFF555555)},
    };

    final availableProviders = <Map<String, dynamic>>[];
    for (var provider in watchProviders) {
      final providerId = provider['provider_id'] as int;
      if (providerMap.containsKey(providerId)) {
        availableProviders.add({
          'id': providerId,
          'name': providerMap[providerId]!['name'],
          'color': providerMap[providerId]!['color'],
          'logo': provider['logo_path'] ?? '',
        });
      }
    }

    if (availableProviders.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Where to Watch',
          style: TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: availableProviders.map((provider) {
            return Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    (provider['color'] as Color).withValues(alpha: 0.3),
                    (provider['color'] as Color).withValues(alpha: 0.1),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: (provider['color'] as Color).withValues(alpha: 0.5),
                  width: 1,
                ),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if ((provider['logo'] as String).isNotEmpty)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: AppNetworkImage(
                        url:
                            'https://image.tmdb.org/t/p/original${provider['logo']}',
                        width: 24,
                        height: 24,
                        fit: BoxFit.cover,
                        errorWidget: Icon(
                          Icons.play_circle,
                          color: provider['color'] as Color,
                          size: 20,
                        ),
                      ),
                    )
                  else
                    Icon(
                      Icons.play_circle,
                      color: provider['color'] as Color,
                      size: 20,
                    ),
                  const SizedBox(width: 8),
                  Text(
                    provider['name'] as String,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            );
          }).toList(),
        ),
      ],
    );
  }

  Widget buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.grey,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }

  Widget buildCastSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.all(16.0),
          child: Text(
            'Cast',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        SizedBox(
          height: 200,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: cast.take(10).length,
            itemBuilder: (context, index) {
              final actor = cast[index];
              return Container(
                width: 120,
                margin: const EdgeInsets.only(right: 12),
                child: Column(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: actor['profile_path'] != null
                          ? AppNetworkImage(
                              url: TmdbApiService.getProfileUrl(
                                actor['profile_path'],
                              ),
                              width: 120,
                              height: 120,
                              fit: BoxFit.cover,
                            )
                          : Container(
                              width: 120,
                              height: 120,
                              color: Colors.grey[800],
                              child: const Icon(
                                Icons.person,
                                color: Colors.grey,
                              ),
                            ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      actor['name'] ?? 'Unknown',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      actor['character'] ?? '',
                      style: const TextStyle(color: Colors.grey, fontSize: 10),
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget buildRecommendationsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.all(16.0),
          child: Text(
            'More Like This',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        SizedBox(
          height: 200,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: recommendations.take(10).length,
            itemBuilder: (context, index) {
              final item = recommendations[index];
              return GestureDetector(
                onTap: () {
                  Navigator.push(
                    context,
                    PageRouteBuilder(
                      pageBuilder: (context, animation, secondaryAnimation) =>
                          MaxStreamDetailsScreen(
                            item: Movie.fromJson(item),
                            mediaType: item['media_type'] ?? widget.mediaType,
                          ),
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
                child: Container(
                  width: 120,
                  margin: const EdgeInsets.only(right: 12),
                  child: Column(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: item['poster_path'] != null
                            ? AppNetworkImage(
                                url: TmdbApiService.getPosterUrl(
                                  item['poster_path'],
                                ),
                                width: 120,
                                height: 160,
                                fit: BoxFit.cover,
                              )
                            : Container(
                                width: 120,
                                height: 160,
                                color: Colors.grey[800],
                                child: const Icon(
                                  Icons.movie,
                                  color: Colors.grey,
                                ),
                              ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        item['title'] ?? item['name'] ?? 'Unknown',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  String getYear() {
    final date = details?['release_date'] ?? details?['first_air_date'];
    if (date != null && date.length >= 4) {
      return date.substring(0, 4);
    }
    return 'N/A';
  }

  String formatDate(String date) {
    try {
      final parsedDate = DateTime.parse(date);
      return '${parsedDate.day}/${parsedDate.month}/${parsedDate.year}';
    } catch (e) {
      return date;
    }
  }

  void playContent() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => buildVideoPlayerScreen(
          title: widget.item.title,
          tmdbId: widget.item.id.toString(),
          isMovie: widget.mediaType == 'movie',
        ),
      ),
    );
  }
}

/// Bottom sheet for server and quality selection before download.
class _QualitySelectionSheet extends StatefulWidget {
  final String title;
  final String tmdbId;
  final void Function(Map<String, dynamic>? selectedStream) onDownload;

  const _QualitySelectionSheet({
    required this.title,
    required this.tmdbId,
    required this.onDownload,
  });

  @override
  State<_QualitySelectionSheet> createState() => _QualitySelectionSheetState();
}

class _QualitySelectionSheetState extends State<_QualitySelectionSheet> {
  bool _loadingStreams = true;
  bool _refreshing = false;
  int _resolveGeneration = 0;
  List<Map<String, dynamic>> _availableStreams = [];
  String? _error;
  int? _selectedServerIndex;
  int? _selectedQualityIndex;
  int? _selectedAudioIndex;

  @override
  void initState() {
    super.initState();
    _fetchAvailableStreams();
  }

  Future<void> _fetchAvailableStreams() async {
    final generation = ++_resolveGeneration;
    await ServerListLoader.load(
      title: widget.title,
      tmdbId: widget.tmdbId,
      isMovie: true,
      isCurrent: () => mounted && generation == _resolveGeneration,
      onUpdate: (available, loading, refreshing, error) {
        if (!mounted || generation != _resolveGeneration) return;
        setState(() {
          // A background refresh that yields nothing keeps the painted list.
          if (available.isNotEmpty || _availableStreams.isEmpty) {
            _availableStreams = available;
            if (available.isNotEmpty && _selectedServerIndex == null) {
              _selectedServerIndex ??= 0;
            }
            _clampSelection();
          }
          _loadingStreams = loading;
          _refreshing = refreshing;
          if (error != null && _availableStreams.isEmpty) {
            _error = error.toString();
          }
        });
        unawaited(_probeVisibleQualities(available));
      },
    );
  }

  /// Sizes probed per quality URL. A null value means "probed, unknown".
  final Map<String, int?> _qualitySizes = {};
  /// URLs currently being probed, so a slow probe shows "sizing…" rather than
  /// an empty cell — and a stalled one can't pin the sheet in that state
  /// forever (see _probeQualitySizes' per-URL deadline).
  final Set<String> _sizingUrls = {};
  bool _sizesLoading = false;

  /// Probes the qualities of the servers that are actually on screen.
  ///
  /// Probing every server's every variant up front meant dozens of playlist
  /// fetches for rows nobody had opened — which is why the sizes took minutes
  /// to appear (and used to sit on "sizing…" indefinitely). Now only the first
  /// server and the currently selected one are measured when the list arrives,
  /// and any other server is measured the moment it is tapped. Requests inside
  /// a server still run concurrently through a bounded pool, and each has a
  /// deadline so one slow host cannot hold the row hostage.
  Future<void> _probeVisibleQualities(
    List<Map<String, dynamic>> streams, {
    int? alsoIndex,
  }) async {
    final indexes = <int>{0};
    for (final candidate in [alsoIndex, _selectedServerIndex]) {
      if (candidate != null && candidate >= 0 && candidate < streams.length) {
        indexes.add(candidate);
      }
    }
    for (final index in indexes) {
      await _probeServerQualities(streams, index);
    }
  }

  /// Measures one server's qualities concurrently (pool of 6, per-URL deadline).
  Future<void> _probeServerQualities(
    List<Map<String, dynamic>> streams,
    int index,
  ) async {
    if (index < 0 || index >= streams.length) return;
    final stream = streams[index];
    final pending = <String, Map<String, dynamic>>{};
    for (final raw in (stream['qualities'] as List? ?? const [])) {
      if (raw is! Map) continue;
      final q = raw.map((k, v) => MapEntry(k.toString(), v));
      final url = q['url']?.toString() ?? '';
      if (url.isEmpty || _qualitySizes.containsKey(url)) continue;
      if (_sizingUrls.contains(url)) continue;
      pending[url] = q;
    }
    final auto = stream['url']?.toString() ?? '';
    if (auto.isNotEmpty &&
        !_qualitySizes.containsKey(auto) &&
        !_sizingUrls.contains(auto)) {
      pending.putIfAbsent(auto, () => <String, dynamic>{});
    }
    if (pending.isEmpty) return;

    if (mounted) setState(() => _sizesLoading = true);
    final urls = pending.keys.toList();
    final slots = <_ProbeSlot>[];
    for (final url in urls) {
      if (mounted) setState(() => _sizingUrls.add(url));
      slots.add(_ProbeSlot(url, pending[url]!));
    }

    // Bounded pool: all variants are requested at once (not one at a time,
    // which is why sizes never arrived), but capped so a sheet with 30
    // variants doesn't open 30 simultaneous playlist fetches and get throttled.
    const poolSize = 6;
    for (var offset = 0; offset < slots.length; offset += poolSize) {
      if (!mounted) return;
      final batch = slots.skip(offset).take(poolSize).toList();
      await _probeBatch(batch, streams);
    }
    if (mounted) setState(() => _sizesLoading = false);
  }

  Future<void> _probeBatch(
    List<_ProbeSlot> batch,
    List<Map<String, dynamic>> streams,
  ) async {
    await Future.wait(
      batch.map((slot) async {
        final headers = _headersFor(stream0: streams, url: slot.url);
        final bitrate = int.tryParse('${slot.quality['averageBitrate'] ?? ''}');
        final seconds = int.tryParse(
          '${slot.quality['runtime'] ?? slot.quality['duration'] ?? ''}',
        );
        int? size;
        try {
          // Deadline per URL: a server that never answers must not leave its
          // row saying "sizing…" for the rest of the session.
          size = await StreamSizeProbe.probe(
            slot.url,
            headers: headers,
            averageBitrate: bitrate,
            runtimeSeconds: seconds,
          ).timeout(const Duration(seconds: 12));
        } catch (_) {
          size = null;
        }
        if (!mounted) return;
        setState(() {
          _sizingUrls.remove(slot.url);
          _qualitySizes[slot.url] = size;
        });
      }),
    );
  }

  Map<String, String> _headersFor({
    required List<Map<String, dynamic>> stream0,
    required String url,
  }) {
    for (final stream in stream0) {
      final matches = stream['url']?.toString() == url ||
          (stream['qualities'] as List? ?? const []).any(
            (q) => q is Map && q['url']?.toString() == url,
          );
      if (!matches) continue;
      final headers = stream['headers'];
      if (headers is Map) {
        return headers.map((k, v) => MapEntry('$k', '$v'));
      }
    }
    return const {};
  }

  String _sizeLabel(String url) {
    final size = _qualitySizes[url];
    if (size == null || size <= 0) return '';
    return StreamSizeProbe.format(
      size,
      estimated: StreamSizeProbe.isHls(url),
    );
  }

  /// Text shown on the right of a quality row: the size once known, "sizing…"
  /// while it is being measured, and an explicit dash when the host would not
  /// answer (so the row never looks half-broken).
  String _sizeCell(String url) {
    if (_qualitySizes.containsKey(url)) {
      final size = _sizeLabel(url);
      return size.isEmpty ? '—' : size;
    }
    if (_sizingUrls.contains(url)) return 'sizing…';
    return '';
  }

  void _clampSelection() {
    if (_selectedServerIndex != null &&
        _selectedServerIndex! >= _availableStreams.length) {
      _selectedServerIndex = _availableStreams.isEmpty ? null : 0;
      _selectedQualityIndex = null;
      _selectedAudioIndex = null;
    }
  }

  List<Map<String, dynamic>> get _selectedAudioTracks {
    if (_selectedServerIndex == null ||
        _selectedServerIndex! >= _availableStreams.length) {
      return const [];
    }
    return StreamAudioHelper.tracksOf(
      _availableStreams[_selectedServerIndex!],
    );
  }

  Map<String, dynamic>? get _selectedAudio =>
      _selectedAudioIndex == null ||
              _selectedAudioIndex! >= _selectedAudioTracks.length
          ? null
          : _selectedAudioTracks[_selectedAudioIndex!];

  Map<String, dynamic>? get _selectedStream {
    if (_selectedServerIndex == null) return null;
    if (_selectedServerIndex! >= _availableStreams.length) return null;
    final server = _availableStreams[_selectedServerIndex!];
    final serverUrl = server['url']?.toString() ?? '';
    final isM3u8 =
        server['type'] == 'direct_m3u8' ||
        serverUrl.toLowerCase().contains('.m3u8');
    final audio = _selectedAudio;
    final qualities = server['qualities'];
    Map<String, dynamic> base({
      required String url,
      required String label,
      int? maxVariantHeight,
    }) =>
        {
          'url': url,
          'source': server['source']?.toString() ?? 'Server',
          'headers': server['headers'],
          'referer': server['referer']?.toString(),
          'type': server['type']?.toString() ?? '',
          'subtitles': server['subtitles'],
          'audioTracks': server['audioTracks'],
          'label': label,
          if (maxVariantHeight != null) 'maxVariantHeight': maxVariantHeight,
          // Preferred dub language. Downloads keep every audio rendition;
          // playback rewrites the master to default to this language.
          if (audio != null) ...{
            'preferredAudioLanguage':
                StreamAudioHelper.languageOf(audio).isNotEmpty
                ? StreamAudioHelper.languageOf(audio)
                : StreamAudioHelper.labelOf(audio),
            'preferredAudioLabel': StreamAudioHelper.displayName(audio),
          },
        };
    if (qualities is List && qualities.isNotEmpty) {
      final idx = _selectedQualityIndex ?? 0;
      if (idx < qualities.length) {
        final raw = qualities[idx];
        final q = raw is Map
            ? raw.map((k, v) => MapEntry(k.toString(), v))
            : <String, dynamic>{};
        final qUrl = q['url']?.toString() ?? '';
        final height = int.tryParse(q['height']?.toString() ?? '') ?? 0;
        // Download from the server master with a height ceiling so the audio
        // and subtitle renditions (EXT-X-MEDIA) are included in the file.
        if (isM3u8 && height > 0) {
          return base(
            url: serverUrl,
            label: q['label']?.toString() ?? 'Auto',
            maxVariantHeight: height,
          );
        }
        return base(
          url: qUrl.isNotEmpty ? qUrl : serverUrl,
          label: q['label']?.toString() ?? 'Auto',
        );
      }
    }
    return base(url: serverUrl, label: 'Auto');
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.7,
      ),
      // The sheet's last row of servers and the Start Download button sat
      // behind the system nav bar: a modal bottom sheet is laid out to the
      // screen edge, so pad past the nav bar inset.
      padding: EdgeInsets.fromLTRB(
        20,
        20,
        20,
        20 + MediaQuery.viewPaddingOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[600],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Download',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            widget.title,
            style: const TextStyle(color: Colors.grey, fontSize: 13),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (_refreshing && !_loadingStreams) ...[
            const SizedBox(height: 8),
            const Row(
              children: [
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.grey,
                  ),
                ),
                SizedBox(width: 8),
                Text(
                  'Checking for more servers…',
                  style: TextStyle(color: Colors.grey, fontSize: 11),
                ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          if (_loadingStreams)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(20),
                child: CircularProgressIndicator(color: Colors.red),
              ),
            )
          else if (_error != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    const Icon(
                      Icons.error_outline,
                      color: Colors.orange,
                      size: 32,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Could not fetch servers',
                      style: TextStyle(color: Colors.grey),
                    ),
                    const SizedBox(height: 16),
                    _buildAutoOption(),
                  ],
                ),
              ),
            )
          else if (_availableStreams.isEmpty)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    const Icon(Icons.cloud_off, color: Colors.grey, size: 32),
                    const SizedBox(height: 8),
                    const Text(
                      'No servers available',
                      style: TextStyle(color: Colors.grey),
                    ),
                    const SizedBox(height: 16),
                    _buildAutoOption(),
                  ],
                ),
              ),
            )
          else ...[
            _buildAutoOption(),
            const SizedBox(height: 12),
            const Text(
              'Servers',
              style: TextStyle(
                color: Colors.grey,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _availableStreams.length,
                itemBuilder: (context, serverIdx) {
                  final server = _availableStreams[serverIdx];
                  final source = server['source']?.toString() ?? 'Server';
                  final qualities = server['qualities'];
                  final hasQualities =
                      qualities is List && qualities.isNotEmpty;
                  final audioBadge = StreamAudioHelper.badgeFor(server);
                  final isServerSelected = _selectedServerIndex == serverIdx;

                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        GestureDetector(
                          onTap: () {
                            setState(() {
                              _selectedServerIndex = serverIdx;
                              _selectedQualityIndex = null;
                              _selectedAudioIndex = null;
                            });
                            // Measure this server's variants now that its
                            // quality list is what the user is looking at.
                            unawaited(
                              _probeServerQualities(_availableStreams, serverIdx),
                            );
                          },
                          child: Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: isServerSelected
                                  ? Colors.red.withValues(alpha: 0.15)
                                  : const Color(0xFF2A2A2A),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: isServerSelected
                                    ? Colors.red
                                    : Colors.transparent,
                                width: 1.5,
                              ),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.dns,
                                  color: isServerSelected
                                      ? Colors.red
                                      : Colors.grey,
                                  size: 20,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        source,
                                        style: TextStyle(
                                          color: isServerSelected
                                              ? Colors.white
                                              : Colors.white70,
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      if (hasQualities) ...[
                                        const SizedBox(height: 2),
                                        Text(
                                          '${qualities.length} quality option(s)'
                                          '${audioBadge.isEmpty ? '' : ' · 🔊 $audioBadge audio'}',
                                          style: TextStyle(
                                            color: isServerSelected
                                                ? Colors.white60
                                                : Colors.grey,
                                            fontSize: 11,
                                          ),
                                        ),
                                      ] else if (audioBadge.isNotEmpty) ...[
                                        const SizedBox(height: 2),
                                        Text(
                                          '🔊 $audioBadge audio',
                                          style: TextStyle(
                                            color: isServerSelected
                                                ? Colors.white60
                                                : Colors.grey,
                                            fontSize: 11,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                                if (isServerSelected)
                                  const Icon(
                                    Icons.radio_button_checked,
                                    color: Colors.red,
                                    size: 18,
                                  )
                                else
                                  const Icon(
                                    Icons.radio_button_off,
                                    color: Colors.grey,
                                    size: 18,
                                  ),
                              ],
                            ),
                          ),
                        ),
                        if (isServerSelected && hasQualities) ...[
                          const SizedBox(height: 6),
                          ...List.generate(qualities.length, (qIdx) {                            final raw = qualities[qIdx];
                            final q = raw is Map
                                ? raw.map((k, v) => MapEntry(k.toString(), v))
                                : <String, dynamic>{};
                            final label = q['label']?.toString() ?? 'Auto';
                            final height =
                                int.tryParse(q['height']?.toString() ?? '') ??
                                0;
                            final isQSelected =
                                (_selectedQualityIndex ?? 0) == qIdx;
                            final qualityUrl = q['url']?.toString() ?? '';
                            // The right-hand side carries the size for this
                            // quality (exact for progressive, "~" estimate for
                            // HLS) — the quality name is already on the left,
                            // so it is not repeated here.
                            final sizeText = _sizeCell(qualityUrl);

                            return Padding(
                              padding: const EdgeInsets.only(
                                left: 12,
                                bottom: 4,
                              ),
                              child: GestureDetector(
                                onTap: () {
                                  setState(() {
                                    _selectedQualityIndex = qIdx;
                                  });
                                },
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 8,
                                  ),
                                  decoration: BoxDecoration(
                                    color: isQSelected
                                        ? Colors.red.withValues(alpha: 0.1)
                                        : const Color(0xFF252525),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: isQSelected
                                          ? Colors.red.withValues(alpha: 0.5)
                                          : Colors.transparent,
                                      width: 1,
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        height >= 720
                                            ? Icons.high_quality
                                            : Icons.hd,
                                        color: isQSelected
                                            ? Colors.red
                                            : Colors.grey,
                                        size: 16,
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        label,
                                        style: TextStyle(
                                          color: isQSelected
                                              ? Colors.white
                                              : Colors.white70,
                                          fontSize: 13,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                      const Spacer(),
                                      Text(
                                        sizeText,
                                        style: TextStyle(
                                          color: isQSelected
                                              ? Colors.white
                                              : Colors.grey,
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          }),
                        ],
                        if (isServerSelected &&
                            _selectedAudioTracks.length > 1) ...[
                          const SizedBox(height: 8),
                          const Padding(
                            padding: EdgeInsets.only(left: 12),
                            child: Text(
                              'Audio language',
                              style: TextStyle(
                                color: Colors.grey,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Padding(
                            padding: const EdgeInsets.only(left: 12),
                            child: Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: [
                                ChoiceChip(
                                  label: const Text(
                                    'Default',
                                    style: TextStyle(fontSize: 12),
                                  ),
                                  selected: _selectedAudioIndex == null,
                                  selectedColor: Colors.red.withValues(
                                    alpha: 0.25,
                                  ),
                                  backgroundColor: const Color(0xFF252525),
                                  labelStyle: TextStyle(
                                    color: _selectedAudioIndex == null
                                        ? Colors.white
                                        : Colors.white70,
                                  ),
                                  onSelected: (_) => setState(
                                    () => _selectedAudioIndex = null,
                                  ),
                                ),
                                ...List.generate(
                                  _selectedAudioTracks.length,
                                  (aIdx) {
                                    final track =
                                        _selectedAudioTracks[aIdx];
                                    final isSelected =
                                        _selectedAudioIndex == aIdx;
                                    return ChoiceChip(
                                      label: Text(
                                        StreamAudioHelper.displayName(
                                          track,
                                        ),
                                        style: const TextStyle(fontSize: 12),
                                      ),
                                      selected: isSelected,
                                      selectedColor: Colors.red.withValues(
                                        alpha: 0.25,
                                      ),
                                      backgroundColor: const Color(
                                        0xFF252525,
                                      ),
                                      labelStyle: TextStyle(
                                        color: isSelected
                                            ? Colors.white
                                            : Colors.white70,
                                      ),
                                      onSelected: (_) => setState(
                                        () => _selectedAudioIndex = aIdx,
                                      ),
                                    );
                                  },
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton(
              // Gated on the server list: while it is still resolving there is no
              // selection, and a null stream means "auto-resolve" — which raced
              // every server natively and started downloading something the user
              // never picked. Wait for the list instead.
              onPressed: _loadingStreams
                  ? null
                  : () {
                      Navigator.pop(context);
                      widget.onDownload(_selectedStream);
                    },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
                disabledBackgroundColor: Colors.red.withValues(alpha: 0.35),
                disabledForegroundColor: Colors.white70,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: Text(
                _loadingStreams ? 'Loading servers…' : 'Start Download',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildAutoOption() {
    final isSelected = _selectedServerIndex == null;
    return GestureDetector(
      onTap: () => setState(() {
        _selectedServerIndex = null;
        _selectedQualityIndex = null;
        _selectedAudioIndex = null;
      }),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isSelected
              ? Colors.red.withValues(alpha: 0.15)
              : const Color(0xFF2A2A2A),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? Colors.red : Colors.transparent,
            width: 1.5,
          ),
        ),
        child: Row(
          children: [
            Icon(
              Icons.auto_awesome,
              color: isSelected ? Colors.red : Colors.grey,
              size: 24,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Auto',
                    style: TextStyle(
                      color: isSelected ? Colors.white : Colors.white70,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _availableStreams.isNotEmpty
                        ? 'Best available from ${_availableStreams.length} server(s)'
                        : 'Let the app choose the best server',
                    style: TextStyle(
                      color: isSelected ? Colors.white60 : Colors.grey,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            if (isSelected)
              const Icon(
                Icons.radio_button_checked,
                color: Colors.red,
                size: 20,
              )
            else
              const Icon(Icons.radio_button_off, color: Colors.grey, size: 20),
          ],
        ),
      ),
    );
  }
}

/// One in-flight size probe.
class _ProbeSlot {
  const _ProbeSlot(this.url, this.quality);
  final String url;
  final Map<String, dynamic> quality;
}
