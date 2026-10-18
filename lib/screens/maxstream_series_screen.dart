import 'package:flutter/material.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';
import '../widgets/app_shimmer.dart';
import 'dart:async' show unawaited;
import '../models/movie.dart';
import '../models/series.dart';
import '../services/media_download_manager.dart';
import '../services/direct_m3u8_service.dart';
import '../services/miniplayer_service.dart';
import '../services/server_list_loader.dart';
import '../services/stream_audio_helper.dart';
import '../services/stream_size_probe.dart';
import '../services/tmdb_api_service.dart';
import '../services/watch_history_service.dart';
import '../database/db_helper.dart';
import '../services/cloud_sync_service.dart';
import '../widgets/app_network_image.dart';
import '../widgets/video_player_screen.dart';

class MaxStreamSeriesScreen extends StatefulWidget {
  final Movie seriesItem;

  const MaxStreamSeriesScreen({super.key, required this.seriesItem});

  @override
  State<MaxStreamSeriesScreen> createState() => _MaxStreamSeriesScreenState();
}

class _MaxStreamSeriesScreenState extends State<MaxStreamSeriesScreen> {
  YoutubePlayerController? _youtubeController;
  Map<String, dynamic>? seriesDetails;
  List<Season> seasons = [];
  int selectedSeasonIndex = 0;
  List<Episode> currentEpisodes = [];
  bool isLoading = true;
  bool isInWatchlist = false;
  bool isLoadingEpisodes = false;
  String? trailerUrl;
  List<Map<String, dynamic>> cast = [];
  List<Map<String, dynamic>> recommendations = [];
  final Set<String> _downloadingEpisodes = {};
  late final MediaDownloadManager _downloadManager;
  final Set<String> _downloadedEpisodeKeys = {};
  Map<String, dynamic>? _watchProgress;

  @override
  void initState() {
    super.initState();
    _downloadManager = MediaDownloadManager.instance;
    _downloadManager.addListener(_onDownloadChanged);
    CloudSyncService.watchlistRevision.addListener(_onSyncedWatchlist);
    CloudSyncService.historyRevision.addListener(_onHistoryChanged);
    _loadSeriesDetails();
    _checkWatchlistStatus();
    _loadWatchProgress();
  }

  void _onSyncedWatchlist() {
    if (mounted) _checkWatchlistStatus();
  }

  void _onHistoryChanged() {
    if (mounted) _loadWatchProgress();
  }

  @override
  void dispose() {
    CloudSyncService.watchlistRevision.removeListener(_onSyncedWatchlist);
    CloudSyncService.historyRevision.removeListener(_onHistoryChanged);
    _youtubeController?.dispose();
    _downloadManager.removeListener(_onDownloadChanged);
    super.dispose();
  }

  void _onDownloadChanged() {
    if (mounted) {
      _refreshDownloadedStatus();
      setState(() {});
    }
  }

  String _episodeDownloadKey(int season, int episode) =>
      'series_${widget.seriesItem.id}_s${season}_e$episode';

  Future<void> _refreshDownloadedStatus() async {
    final downloads = await DBHelper.getMediaDownloads();
    final keys = <String>{};
    for (final d in downloads) {
      final key = d['downloadKey']?.toString() ?? '';
      if (key.isNotEmpty) keys.add(key);
    }
    // Also include active downloads
    for (final active in _downloadManager.activeDownloads) {
      keys.add(active.downloadKey);
    }
    if (mounted) {
      setState(() {
        _downloadedEpisodeKeys
          ..clear()
          ..addAll(keys);
      });
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

  Future<void> _loadSeriesDetails() async {
    setState(() => isLoading = true);

    try {
      final details = await TmdbApiService.getSeriesDetails(
        int.parse(widget.seriesItem.id),
      );
      if (details != null && mounted) {
        setState(() {
          seriesDetails = details;
          seasons = (details['seasons'] as List)
              .map((season) => Season.fromJson(season))
              .where((season) => season.seasonNumber > 0) // Filter out specials
              .toList();
          cast = List<Map<String, dynamic>>.from(
            details['credits']?['cast'] ?? [],
          );
          recommendations = List<Map<String, dynamic>>.from(
            details['recommendations']?['results'] ?? [],
          );
        });

        if (seasons.isNotEmpty) {
          _loadSeasonEpisodes(seasons[0].seasonNumber);
        }

        // Load trailer
        final trailerUrlFromApi = await TmdbApiService.getTrailerUrl(
          int.parse(widget.seriesItem.id),
          isMovie: false,
        );
        if (trailerUrlFromApi.isNotEmpty) {
          _initializeYouTubePlayer(trailerUrlFromApi);
        }
      }
      _refreshDownloadedStatus();
    } catch (e) {
      // Error loading series details
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  Future<void> _loadSeasonEpisodes(int seasonNumber) async {
    setState(() {
      isLoadingEpisodes = true;
    });

    try {
      final episodesData = await TmdbApiService.getSeasonEpisodes(
        int.parse(widget.seriesItem.id),
        seasonNumber,
      );

      final episodes = episodesData.map((ep) => Episode.fromJson(ep)).toList();

      if (mounted) {
        setState(() {
          currentEpisodes = episodes;
          isLoadingEpisodes = false;
        });
        _refreshDownloadedStatus();
        // Warm the server list for the first episode so its download picker
        // opens instantly.
        if (episodes.isNotEmpty) {
          DirectM3u8Service.prefetchAvailableStreams(
            title: widget.seriesItem.title,
            tmdbId: widget.seriesItem.id,
            isMovie: false,
            season: seasonNumber,
            episode: episodes.first.episodeNumber,
          );
        }
      }
    } catch (e) {
      // Error loading episodes
      if (mounted) {
        setState(() {
          isLoadingEpisodes = false;
        });
      }
    }
  }

  Future<void> _checkWatchlistStatus() async {
    await CloudSyncService.pullToDevice();
    final watchlist = await DBHelper.getWatchlistItems();
    if (mounted) {
      setState(() {
        isInWatchlist = watchlist.any(
          (item) =>
              item.id == widget.seriesItem.id &&
              item.mediaType == widget.seriesItem.mediaType,
        );
      });
    }
  }

  Future<void> _toggleWatchlist() async {
    try {
      final wasAdded = !isInWatchlist;

      if (isInWatchlist) {
        await DBHelper.removeFromWatchlist(
          widget.seriesItem.id,
          widget.seriesItem.mediaType,
        );
      } else {
        await DBHelper.addToWatchlist(widget.seriesItem);
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

  void _playEpisode(Episode episode) {
    final season = seasons[selectedSeasonIndex];
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => buildVideoPlayerScreen(
          title:
              '${widget.seriesItem.title} - S${season.seasonNumber}E${episode.episodeNumber}: ${episode.name}',
          tmdbId: widget.seriesItem.id.toString(),
          isMovie: false,
          season: season.seasonNumber,
          episode: episode.episodeNumber,
        ),
      ),
    ).then((_) => _loadWatchProgress());
  }

  void _showEpisodeQualitySheet(Episode episode) {
    final season = seasons[selectedSeasonIndex].seasonNumber;
    final episodeTitle =
        '${widget.seriesItem.title} - S${season}E${episode.episodeNumber}: ${episode.name}';

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return _EpisodeQualitySheet(
          title: episodeTitle,
          tmdbId: widget.seriesItem.id,
          season: season,
          episode: episode.episodeNumber,
          onDownload: (selectedStream) {
            _downloadEpisode(
              episode,
              seasonNumber: season,
              selectedStream: selectedStream,
            );
          },
        );
      },
    );
  }

  Future<bool> _downloadEpisode(
    Episode episode, {
    bool showResult = true,
    int? seasonNumber,
    String? resolverTitle,
    Map<String, dynamic>? selectedStream,
  }) async {
    final season = seasonNumber ?? seasons[selectedSeasonIndex].seasonNumber;
    final key = _episodeDownloadKey(season, episode.episodeNumber);
    if (_downloadingEpisodes.contains(key)) return true;
    // Stop any background playback before starting download.
    MiniplayerService.instance.close();
    if (mounted) setState(() => _downloadingEpisodes.add(key));
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
            downloadKey: key,
            url: url,
            headers: headers,
            isHls: isHls,
            mediaId: widget.seriesItem.id,
            isMovie: false,
            title:
                '${widget.seriesItem.title} - S${season}E${episode.episodeNumber}: ${episode.name}',
            resolverTitle: resolverTitle ?? widget.seriesItem.title,
            thumbnail: episode.stillPath.isNotEmpty
                ? 'https://image.tmdb.org/t/p/w500${episode.stillPath}'
                : widget.seriesItem.thumbnail,
            seriesId: widget.seriesItem.id,
            seasonNumber: season,
            episodeNumber: episode.episodeNumber,
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
          downloadKey: key,
          mediaId: widget.seriesItem.id,
          isMovie: false,
          resolverTitle: resolverTitle ?? widget.seriesItem.title,
          title:
              '${widget.seriesItem.title} - S${season}E${episode.episodeNumber}: ${episode.name}',
          thumbnail: episode.stillPath.isNotEmpty
              ? 'https://image.tmdb.org/t/p/w500${episode.stillPath}'
              : widget.seriesItem.thumbnail,
          seasonNumber: season,
          episodeNumber: episode.episodeNumber,
        );
      }
      if (showResult && mounted && !found) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'No downloadable stream found for episode ${episode.episodeNumber}',
            ),
          ),
        );
      }
      return found;
    } catch (error) {
      if (showResult && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Episode download failed: $error')),
        );
      }
      return false;
    } finally {
      if (mounted) {
        setState(() => _downloadingEpisodes.remove(key));
        _refreshDownloadedStatus();
      }
    }
  }

  Future<void> _downloadCurrentSeason() async {
    final releasedEpisodes = currentEpisodes
        .where((e) => e.isReleased)
        .toList();
    if (_downloadManager.seasonDownloading || releasedEpisodes.isEmpty) return;
    // Stop any background playback before starting download.
    MiniplayerService.instance.close();
    final season = seasons[selectedSeasonIndex].seasonNumber;
    final unreleasedCount = currentEpisodes.length - releasedEpisodes.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Download Season $season?'),
        content: Text(
          '${releasedEpisodes.length} released episodes will be downloaded one at a time.'
          '${unreleasedCount > 0 ? '\n\n$unreleasedCount unreleased episodes will be skipped.' : ''}'
          '\n\nQuality: the lowest available on the chosen server, and every episode continues using that same server.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final selection = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => _SeasonQualitySheet(
        title: widget.seriesItem.title,
        tmdbId: widget.seriesItem.id,
        season: season,
        episode: releasedEpisodes.first.episodeNumber,
        serverCountHint: releasedEpisodes.length,
      ),
    );
    if (selection == null || !mounted) return;
    final preferredServer = selection['server']?.toString();

    final episodes = releasedEpisodes
        .map(
          (episode) => {
            'episodeNumber': episode.episodeNumber,
            'name': episode.name,
            'stillPath': episode.stillPath,
          },
        )
        .toList();
    unawaited(
      _downloadManager.downloadSeason(
        seasonKey: 'season_${widget.seriesItem.id}_s$season',
        seriesId: widget.seriesItem.id,
        tmdbId: widget.seriesItem.id,
        title: widget.seriesItem.title,
        thumbnail: widget.seriesItem.thumbnail,
        seasonNumber: season,
        episodes: episodes,
        preferredServer: preferredServer,
        lowestQuality: true,
      ),
    );
  }

  Future<void> _loadWatchProgress() async {
    await CloudSyncService.pullToDevice();
    final continueWatching = await WatchHistoryService.getContinueWatching();
    if (!mounted) return;
    final match = continueWatching.firstWhere(
      (item) =>
          item['tmdbId']?.toString() == widget.seriesItem.id &&
          item['isMovie'] == false,
      orElse: () => {},
    );
    if (match.isNotEmpty) {
      setState(() => _watchProgress = match);
      return;
    }

    // No resumable episode found — clear the card.
    final allHistory = await WatchHistoryService.getWatchHistory();
    if (!mounted) return;

    final matches =
        allHistory
            .where(
              (item) =>
                  item['tmdbId']?.toString() == widget.seriesItem.id &&
                  item['isMovie'] == false &&
                  item['isWatched'] != true,
            )
            .toList()
          ..sort(
            (a, b) => (b['timestamp'] ?? 0).compareTo(a['timestamp'] ?? 0),
          );

    if (matches.isNotEmpty) {
      final first = matches.first;
      final position = (first['position'] as num?)?.toInt() ?? 0;
      final duration = (first['duration'] as num?)?.toInt() ?? 1;
      if (position > 30 && duration > 0) {
        setState(() => _watchProgress = first);
        return;
      }
    }
    // Nothing resumable — hide the continue watching card.
    if (mounted && _watchProgress != null) {
      setState(() => _watchProgress = null);
    }
  }

  Widget _buildContinueWatching() {
    final position = (_watchProgress!['position'] as num?)?.toInt() ?? 0;
    final duration = (_watchProgress!['duration'] as num?)?.toInt() ?? 1;
    final progress = duration > 0 ? (position / duration).clamp(0.0, 1.0) : 0.0;
    final percent = (progress * 100).round();
    final remaining = duration - position;
    final remainingMin = (remaining / 60).round();
    final season = _watchProgress!['season'] ?? 1;
    final episode = _watchProgress!['episode'] ?? 1;
    final epTitle = _watchProgress!['title'] ?? '';

    return GestureDetector(
      onTap: () async {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => buildVideoPlayerScreen(
              title: '${widget.seriesItem.title} - S${season}E$episode',
              tmdbId: widget.seriesItem.id.toString(),
              isMovie: false,
              season: season,
              episode: episode,
            ),
          ),
        ).then((_) => _loadWatchProgress());
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
            const SizedBox(height: 6),
            Text(
              'S$season E$episode${epTitle.isNotEmpty ? ' - $epTitle' : ''}',
              style: TextStyle(color: Colors.grey[400], fontSize: 13),
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

  String getYear() {
    final firstAirDate = seriesDetails?['first_air_date'];
    if (firstAirDate != null && firstAirDate.toString().length >= 4) {
      return firstAirDate.toString().substring(0, 4);
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

  String _formatAirDate(String date) {
    if (date.isEmpty) return '';
    try {
      final parsed = DateTime.parse(date);
      const months = [
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
    } catch (e) {
      return date;
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
            : CustomScrollView(
                slivers: [
                  buildSliverAppBar(),
                  SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        buildDetailsSection(),
                        if (_watchProgress != null) _buildContinueWatching(),
                        if (cast.isNotEmpty) buildCastSection(),
                        if (seasons.isNotEmpty) buildSeasonsSection(),
                        if (recommendations.isNotEmpty)
                          buildRecommendationsSection(),
                        const SizedBox(height: 20),
                      ],
                    ),
                  ),
                ],
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
            expandedHeight: 350,
            flexibleSpace: FlexibleSpaceBar(
              background: Container(color: Colors.grey[800]),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Poster and title skeleton
                  Row(
                    children: [
                      Container(
                        width: 100,
                        height: 150,
                        color: Colors.grey[800],
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              height: 24,
                              width: 150,
                              color: Colors.grey[800],
                            ),
                            const SizedBox(height: 8),
                            Container(
                              height: 16,
                              width: 100,
                              color: Colors.grey[800],
                            ),
                            const SizedBox(height: 8),
                            Container(
                              height: 16,
                              width: 80,
                              color: Colors.grey[800],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),

                  // Overview skeleton
                  Container(height: 24, width: 100, color: Colors.grey[800]),
                  const SizedBox(height: 12),
                  ...List.generate(
                    4,
                    (index) => Padding(
                      padding: const EdgeInsets.only(bottom: 8.0),
                      child: Container(height: 12, color: Colors.grey[800]),
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Cast section skeleton
                  Container(height: 24, width: 80, color: Colors.grey[800]),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Container(
                          height: 160,
                          color: Colors.grey[800],
                          margin: const EdgeInsets.only(right: 8),
                        ),
                      ),
                      Expanded(
                        child: Container(
                          height: 160,
                          color: Colors.grey[800],
                          margin: const EdgeInsets.only(right: 8),
                        ),
                      ),
                      Expanded(
                        child: Container(height: 160, color: Colors.grey[800]),
                      ),
                    ],
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
    final backdropPath =
        seriesDetails?['backdrop_path'] ?? widget.seriesItem.backdropPath;
    final posterPath =
        seriesDetails?['poster_path'] ?? widget.seriesItem.posterPath;

    return SliverAppBar(
      expandedHeight: 350,
      pinned: true,
      backgroundColor: const Color(0xFF1A1A1A),
      flexibleSpace: FlexibleSpaceBar(
        background: Stack(
          fit: StackFit.expand,
          children: [
            if (backdropPath != null && backdropPath.isNotEmpty)
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
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: posterPath != null && posterPath.isNotEmpty
                        ? AppNetworkImage(
                            url: TmdbApiService.getPosterUrl(posterPath),
                            width: 100,
                            height: 150,
                            fit: BoxFit.cover,
                          )
                        : Container(
                            width: 100,
                            height: 150,
                            color: Colors.grey[800],
                            child: const Icon(Icons.tv),
                          ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          seriesDetails?['name'] ?? widget.seriesItem.title,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          getYear(),
                          style: const TextStyle(
                            color: Colors.grey,
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Icon(Icons.star, color: Colors.amber, size: 20),
                            const SizedBox(width: 4),
                            Text(
                              '${seriesDetails?['vote_average']?.toStringAsFixed(1) ?? widget.seriesItem.rating.toStringAsFixed(1)}',
                              style: const TextStyle(color: Colors.white),
                            ),
                            const SizedBox(width: 16),
                            if (seriesDetails?['number_of_seasons'] != null)
                              Text(
                                '${seriesDetails!['number_of_seasons']} Seasons',
                                style: const TextStyle(color: Colors.grey),
                              ),
                            const SizedBox(width: 16),
                            IconButton(
                              onPressed: _toggleWatchlist,
                              icon: Icon(
                                isInWatchlist
                                    ? Icons.bookmark
                                    : Icons.bookmark_border,
                                color: isInWatchlist
                                    ? Colors.red
                                    : Colors.white,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: currentEpisodes.any((e) => e.isReleased)
                                ? () {
                                    final firstReleased = currentEpisodes
                                        .firstWhere((e) => e.isReleased);
                                    _playEpisode(firstReleased);
                                  }
                                : null,
                            icon: const Icon(
                              Icons.play_arrow,
                              color: Colors.white,
                            ),
                            label: const Text(
                              'Watch Now',
                              style: TextStyle(color: Colors.white),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.red,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                          ),
                        ),
                      ],
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
            seriesDetails?['overview'] ??
                widget.seriesItem.overview ??
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
    final firstAirDate = seriesDetails?['first_air_date'];
    final lastAirDate = seriesDetails?['last_air_date'];
    final genres = (seriesDetails?['genres'] as List<dynamic>?)
        ?.map((g) => g['name'].toString())
        .join(', ');

    return Column(
      children: [
        if (firstAirDate != null)
          buildInfoRow('First Air Date', formatDate(firstAirDate)),
        if (lastAirDate != null && lastAirDate != firstAirDate)
          buildInfoRow('Last Air Date', formatDate(lastAirDate)),
        if (genres != null) buildInfoRow('Genres', genres),
        buildInfoRow(
          'Language',
          seriesDetails?['original_language']?.toUpperCase() ?? 'N/A',
        ),
        buildInfoRow('Status', seriesDetails?['status'] ?? 'Unknown'),
        if (seriesDetails?['episode_run_time'] != null &&
            (seriesDetails!['episode_run_time'] as List).isNotEmpty)
          buildInfoRow(
            'Episode Runtime',
            '~${seriesDetails!['episode_run_time'][0]} minutes',
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
            width: 120,
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

  Widget buildSeasonsSection() {
    final seasonActive = _downloadManager.isSeasonDownloadActive(
      'season_${widget.seriesItem.id}'
      '_s${seasons[selectedSeasonIndex].seasonNumber}',
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'Seasons & Episodes',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed:
                    seasonActive || !currentEpisodes.any((e) => e.isReleased)
                    ? null
                    : _downloadCurrentSeason,
                icon: seasonActive
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.download_for_offline_outlined),
                label: Text(
                  seasonActive
                      ? '${_downloadManager.seasonDownloadCurrent}/${_downloadManager.seasonDownloadTotal}'
                      : 'Download Season',
                ),
                style: TextButton.styleFrom(foregroundColor: Colors.white),
              ),
            ],
          ),
        ),
        if (seasonActive && _downloadManager.seasonDownloadStatus.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.red,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _downloadManager.seasonDownloadStatus,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SizedBox(
            height: 40,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: seasons.length,
              itemBuilder: (context, index) {
                final season = seasons[index];
                final isSelected = index == selectedSeasonIndex;

                return Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: ChoiceChip(
                    label: Text(
                      season.isReleased
                          ? 'Season ${season.seasonNumber}'
                          : 'Season ${season.seasonNumber} · ${_formatAirDate(season.airDate)}',
                    ),
                    selected: isSelected,
                    onSelected: (selected) {
                      if (selected) {
                        setState(() {
                          selectedSeasonIndex = index;
                        });
                        _loadSeasonEpisodes(season.seasonNumber);
                      }
                    },
                    selectedColor: season.isReleased
                        ? Colors.red
                        : Colors.grey[700],
                    backgroundColor: const Color(0xFF2A2A2A),
                    labelStyle: TextStyle(
                      color: isSelected ? Colors.white : Colors.grey,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        const SizedBox(height: 20),
        if (isLoadingEpisodes)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(20),
              child: CircularProgressIndicator(color: Colors.red),
            ),
          )
        else if (currentEpisodes.isNotEmpty)
          ...currentEpisodes.map((episode) => _buildEpisodeTile(episode))
        else
          const Center(
            child: Padding(
              padding: EdgeInsets.all(20),
              child: Text(
                'No episodes available',
                style: TextStyle(color: Colors.grey),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildEpisodeTile(Episode episode) {
    final season = seasons[selectedSeasonIndex].seasonNumber;
    final key = _episodeDownloadKey(season, episode.episodeNumber);
    final isDownloading = _downloadingEpisodes.contains(key);
    final isDownloaded = _downloadedEpisodeKeys.contains(key);
    final activeTask = _downloadManager.taskFor(key);
    final isCurrentlyDownloading = activeTask != null;
    final isReleased = episode.isReleased;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: InkWell(
        onTap: isReleased ? () => _playEpisode(episode) : null,
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFF1E1E1E),
            borderRadius: BorderRadius.circular(8),
            border: isReleased
                ? null
                : Border.all(color: Colors.grey[700]!, width: 1),
          ),
          child: Row(
            children: [
              Container(
                width: 120,
                height: 80,
                decoration: BoxDecoration(
                  borderRadius: const BorderRadius.horizontal(
                    left: Radius.circular(8),
                  ),
                  color: const Color(0xFF2A2A2A),
                ),
                child: episode.stillPath.isNotEmpty
                    ? ClipRRect(
                        borderRadius: const BorderRadius.horizontal(
                          left: Radius.circular(8),
                        ),
                        child: AppNetworkImage(
                          url:
                              'https://image.tmdb.org/t/p/w300${episode.stillPath}',
                          fit: BoxFit.cover,
                        ),
                      )
                    : isReleased
                    ? const Icon(
                        Icons.play_circle_outline,
                        color: Colors.white54,
                        size: 40,
                      )
                    : Icon(Icons.schedule, color: Colors.grey[600], size: 40),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            '${episode.episodeNumber}. ',
                            style: const TextStyle(
                              color: Colors.red,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Expanded(
                            child: Text(
                              episode.name,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w500,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      if (!isReleased && episode.airDate.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.amber.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            'Releases ${episode.formattedAirDate}',
                            style: const TextStyle(
                              color: Colors.amber,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                      if (episode.overview.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          episode.overview,
                          style: const TextStyle(
                            color: Colors.grey,
                            fontSize: 12,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                      if (isCurrentlyDownloading) ...[
                        const SizedBox(height: 8),
                        _buildEpisodeDownloadProgress(activeTask),
                      ],
                    ],
                  ),
                ),
              ),
              if (isReleased)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: IconButton(
                    tooltip: isDownloaded
                        ? 'Downloaded'
                        : isCurrentlyDownloading
                        ? 'Downloading'
                        : 'Download episode',
                    onPressed: isDownloading || isCurrentlyDownloading
                        ? null
                        : isDownloaded
                        ? null
                        : () => _showEpisodeQualitySheet(episode),
                    icon: isDownloading || isCurrentlyDownloading
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : isDownloaded
                        ? const Icon(Icons.check_circle, color: Colors.green)
                        : const Icon(
                            Icons.download_for_offline_outlined,
                            color: Colors.red,
                          ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEpisodeDownloadProgress(ActiveMediaDownload task) {
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
                minHeight: 4,
                color: task.isPaused ? Colors.orange : Colors.red,
                backgroundColor: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '$percent%',
              style: const TextStyle(color: Colors.white70, fontSize: 11),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          task.isPaused ? 'Paused' : task.sizeLabel,
          style: TextStyle(
            color: task.isPaused ? Colors.orange : Colors.white54,
            fontSize: 10,
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
                          MaxStreamSeriesScreen(
                            seriesItem: Movie.fromJson(item),
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
                                child: const Icon(Icons.tv, color: Colors.grey),
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
}

/// Bottom sheet for server and quality selection before episode download.
class _EpisodeQualitySheet extends StatefulWidget {
  final String title;
  final String tmdbId;
  final int season;
  final int episode;
  final void Function(Map<String, dynamic>? selectedStream) onDownload;

  const _EpisodeQualitySheet({
    required this.title,
    required this.tmdbId,
    required this.season,
    required this.episode,
    required this.onDownload,
  });

  @override
  State<_EpisodeQualitySheet> createState() => _EpisodeQualitySheetState();
}

class _EpisodeQualitySheetState extends State<_EpisodeQualitySheet> {
  bool _loadingStreams = true;
  /// Exact (progressive) or estimated (HLS) size per quality URL, filled in
  /// when the server list arrives so every server row can show it.
  final Map<String, int?> _qualitySizes = {};
  bool _sizesLoading = false;
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
      isMovie: false,
      season: widget.season,
      episode: widget.episode,
      isCurrent: () => mounted && generation == _resolveGeneration,
      onUpdate: (available, loading, refreshing, error) {
        if (!mounted || generation != _resolveGeneration) return;
        setState(() {
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
        unawaited(_probeQualitySizes(available));
      },
    );
  }

  /// Asks each server's quality variants how big they are. Progressive files
  /// report an exact byte count; HLS variants are estimated from their bitrate
  /// and shown with a "~". Runs in the background so the sheet paints at once.
  Future<void> _probeQualitySizes(List<Map<String, dynamic>> streams) async {
    if (_sizesLoading) return;
    final pending = <String, Map<String, dynamic>>{};
    for (final stream in streams) {
      for (final raw in (stream['qualities'] as List? ?? const [])) {
        if (raw is! Map) continue;
        final q = raw.map((k, v) => MapEntry(k.toString(), v));
        final url = q['url']?.toString() ?? '';
        if (url.isEmpty || _qualitySizes.containsKey(url)) continue;
        pending[url] = q;
      }
      final auto = stream['url']?.toString() ?? '';
      if (auto.isNotEmpty && !_qualitySizes.containsKey(auto)) {
        pending.putIfAbsent(auto, () => <String, dynamic>{});
      }
    }
    if (pending.isEmpty) return;
    setState(() => _sizesLoading = true);
    for (final entry in pending.entries) {
      final headers = streams
              .firstWhere(
                (s) =>
                    s['url']?.toString() == entry.key ||
                    (s['qualities'] as List? ?? const []).any(
                      (q) => q is Map && q['url']?.toString() == entry.key,
                    ),
                orElse: () => const <String, dynamic>{},
              )['headers'] as Map<String, dynamic>? ??
          const {};
      final bitrate = int.tryParse('${entry.value['averageBitrate'] ?? ''}');
      final seconds =
          int.tryParse('${entry.value['runtime'] ?? entry.value['duration'] ?? ''}');
      final size = await StreamSizeProbe.probe(
        entry.key,
        headers: headers.map((k, v) => MapEntry('$k', '$v')),
        averageBitrate: bitrate,
        runtimeSeconds: seconds,
      );
      if (!mounted) return;
      setState(() => _qualitySizes[entry.key] = size);
    }
    if (mounted) setState(() => _sizesLoading = false);
  }

  String _sizeLabel(String url) {
    final size = _qualitySizes[url];
    if (size == null) return '';
    return StreamSizeProbe.format(
      size,
      estimated: StreamSizeProbe.isHls(url),
    );
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
                          ...List.generate(qualities.length, (qIdx) {
                            final raw = qualities[qIdx];
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
                            final sizeText = _sizeLabel(qualityUrl);
                            final subtitle = [
                              if (height > 0) '${height}p' else 'Adaptive bitrate',
                              if (sizeText.isNotEmpty) sizeText,
                            ].join(' • ');

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
                                        subtitle,
                                        style: TextStyle(
                                          color: isQSelected
                                              ? Colors.white60
                                              : Colors.grey,
                                          fontSize: 11,
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

/// Bottom sheet that picks the server used for a whole-season download. Every
/// episode downloads at the lowest quality from this server (Auto lets the app
/// pick the first working server).
class _SeasonQualitySheet extends StatefulWidget {
  final String title;
  final String tmdbId;
  final int season;
  final int episode;
  final int serverCountHint;

  const _SeasonQualitySheet({
    required this.title,
    required this.tmdbId,
    required this.season,
    required this.episode,
    required this.serverCountHint,
  });

  @override
  State<_SeasonQualitySheet> createState() => _SeasonQualitySheetState();
}

class _SeasonQualitySheetState extends State<_SeasonQualitySheet> {
  bool _loadingStreams = true;
  bool _refreshing = false;
  int _resolveGeneration = 0;
  List<Map<String, dynamic>> _availableStreams = [];
  String? _error;
  int? _selectedServerIndex;

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
      isMovie: false,
      season: widget.season,
      episode: widget.episode,
      isCurrent: () => mounted && generation == _resolveGeneration,
      onUpdate: (available, loading, refreshing, error) {
        if (!mounted || generation != _resolveGeneration) return;
        setState(() {
          if (available.isNotEmpty || _availableStreams.isEmpty) {
            _availableStreams = available;
            if (_selectedServerIndex != null &&
                _selectedServerIndex! >= available.length) {
              _selectedServerIndex = available.isEmpty ? null : 0;
            }
          }
          _loadingStreams = loading;
          _refreshing = refreshing;
          if (error != null && _availableStreams.isEmpty) {
            _error = error.toString();
          }
        });
      },
    );
  }

  void _start() {
    if (_selectedServerIndex != null &&
        _selectedServerIndex! < _availableStreams.length) {
      final source = _availableStreams[_selectedServerIndex!]['source']
          ?.toString();
      Navigator.pop(context, {'server': source});
    } else {
      Navigator.pop(context, null);
    }
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
            'Download Season',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${widget.title} · ${widget.serverCountHint} episodes at the lowest'
            ' quality from one server',
            style: const TextStyle(color: Colors.grey, fontSize: 13),
            maxLines: 2,
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
                child: Text(
                  'Could not fetch servers. Auto will still work.',
                  style: TextStyle(color: Colors.grey[400], fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              ),
            )
          else ...[
            GestureDetector(
              onTap: () => setState(() => _selectedServerIndex = null),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: _selectedServerIndex == null
                      ? Colors.red.withValues(alpha: 0.15)
                      : const Color(0xFF2A2A2A),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: _selectedServerIndex == null
                        ? Colors.red
                        : Colors.transparent,
                    width: 1.5,
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.auto_awesome, color: Colors.red, size: 24),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Auto',
                            style: TextStyle(
                              color: _selectedServerIndex == null
                                  ? Colors.white
                                  : Colors.white70,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _availableStreams.isNotEmpty
                                ? 'App picks the first working server'
                                : 'Let the app choose the best server',
                            style: TextStyle(
                              color: _selectedServerIndex == null
                                  ? Colors.white60
                                  : Colors.grey,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      _selectedServerIndex == null
                          ? Icons.radio_button_checked
                          : Icons.radio_button_off,
                      color: Colors.red,
                      size: 20,
                    ),
                  ],
                ),
              ),
            ),
            if (_availableStreams.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text(
                'Server',
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
                  itemBuilder: (context, index) {
                    final source =
                        _availableStreams[index]['source']?.toString() ??
                        'Server';
                    final isSelected = _selectedServerIndex == index;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: GestureDetector(
                        onTap: () =>
                            setState(() => _selectedServerIndex = index),
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? Colors.red.withValues(alpha: 0.15)
                                : const Color(0xFF2A2A2A),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: isSelected
                                  ? Colors.red
                                  : Colors.transparent,
                              width: 1.5,
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.dns,
                                color: isSelected ? Colors.red : Colors.grey,
                                size: 20,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  source,
                                  style: TextStyle(
                                    color: isSelected
                                        ? Colors.white
                                        : Colors.white70,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              Icon(
                                isSelected
                                    ? Icons.radio_button_checked
                                    : Icons.radio_button_off,
                                color: Colors.red,
                                size: 18,
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ],
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton(
              onPressed: _start,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text(
                'Start Season Download',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
