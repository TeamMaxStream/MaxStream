import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../widgets/app_shimmer.dart';
import '../models/movie.dart';
import '../database/db_helper.dart';
import '../utils/kids_filter.dart';
import '../utils/kids_theme.dart';
import '../services/cloud_sync_service.dart';
import '../services/miniplayer_service.dart';
import '../services/profile_scope.dart';
import '../services/tmdb_api_service.dart';
import '../utils/tmdb_list_utils.dart';
import '../services/watch_history_service.dart';
import '../widgets/hero_banner.dart';
import '../widgets/app_network_image.dart';
import '../widgets/custom_loading_widget.dart';
import '../widgets/continue_watching_section.dart';
import '../widgets/profile_menu_button.dart';
import 'maxstream_details_screen.dart';
import 'maxstream_series_screen.dart';
import 'provider_content_screen.dart';

class MaxStreamHomeScreen extends StatefulWidget {
  final Function(int)? onTabChange;

  const MaxStreamHomeScreen({super.key, this.onTabChange});

  @override
  State<MaxStreamHomeScreen> createState() => _MaxStreamHomeScreenState();
}

class _MaxStreamHomeScreenState extends State<MaxStreamHomeScreen> {
  bool isLoading = true;
  List<Map<String, dynamic>> trendingMovies = [];
  List<Map<String, dynamic>> popularMovies = [];
  List<Map<String, dynamic>> topRatedMovies = [];
  List<Map<String, dynamic>> upcomingContent = [];
  List<Map<String, dynamic>> continueWatching = [];
  List<Map<String, dynamic>> nowPlaying = [];
  List<Map<String, dynamic>> genres = [];

  /// Monotonically increasing counter to discard stale load results.
  int _loadGeneration = 0;

  /// Profile ID captured at the start of a load to detect profile switches mid-load.
  String _loadProfileId = '';

  @override
  void initState() {
    super.initState();
    CloudSyncService.historyRevision.addListener(_onSyncedHistory);
    CloudSyncService.watchlistRevision.addListener(_onSyncedHistory);
    ProfileScope.activeProfile.addListener(_onProfileChanged);
    _loadContent();
  }

  void _onSyncedHistory() {
    if (!mounted) return;
    // Guard: only reload if the active profile hasn't changed since last load.
    if (_loadProfileId.isNotEmpty &&
        _loadProfileId != ProfileScope.currentProfileId) {
      return;
    }
    _loadContinueWatching();
  }

  void _onProfileChanged() {
    // Stop miniplayer on profile switch to prevent background playback across profiles.
    MiniplayerService.instance.close();
    if (mounted) _loadContent();
  }

  @override
  void dispose() {
    CloudSyncService.historyRevision.removeListener(_onSyncedHistory);
    CloudSyncService.watchlistRevision.removeListener(_onSyncedHistory);
    ProfileScope.activeProfile.removeListener(_onProfileChanged);
    super.dispose();
  }

  Future<List<Map<String, dynamic>>> _safeList(
    Future<List<Map<String, dynamic>>> Function() f,
  ) async {
    try {
      return await f();
    } catch (_) {
      return [];
    }
  }

  Future<void> _loadContent() async {
    final generation = ++_loadGeneration;
    _loadProfileId = ProfileScope.currentProfileId;
    if (mounted) setState(() => isLoading = true);

    try {
      final syncFuture = CloudSyncService.pullToDevice().catchError((_) {});
      final results = await Future.wait([
        _safeList(() => TmdbApiService.fetchTrendingMovies()),
        _safeList(() => TmdbApiService.fetchPopularMovies()),
        _safeList(() => TmdbApiService.fetchTopRatedMovies()),
        _safeList(() => TmdbApiService.fetchUpcomingMovies()),
        _safeList(() => TmdbApiService.fetchUpcomingSeries()),
        syncFuture
            .then((_) => WatchHistoryService.getContinueWatching())
            .catchError((_) => <Map<String, dynamic>>[]),
        _safeList(() => _loadWatchlistUpcoming()),
        _safeList(() => TmdbApiService.fetchNowPlayingMovies()),
        _safeList(() => TmdbApiService.fetchGenreList()),
      ]);

      // Discard stale results if profile changed or a newer load started.
      if (!mounted || generation != _loadGeneration) return;
      final upcomingMv = TmdbApiService.filterUnreleased(results[3]);
      final upcomingTv = TmdbApiService.filterUnreleased(
        results[4],
        dateField: 'first_air_date',
      );
      // Merge and shuffle movies + series into one "Coming Soon" section
      for (final item in upcomingTv) {
        item['media_type'] = 'tv';
      }
      for (final item in upcomingMv) {
        item['media_type'] = 'movie';
      }
      // Watchlist upcoming episodes (already formatted)
      final watchlistUpcoming = results[6];
      final mergedUpcoming = [
        ...upcomingMv,
        ...upcomingTv,
        ...watchlistUpcoming,
      ]..shuffle();

      // Kids profile: filter to only kid-friendly content
      final filter = isKidsProfile
          ? filterForKids
          : (List<Map<String, dynamic>> l) => l;

      setState(() {
        trendingMovies = filter(results[0]);
        popularMovies = filter(results[1]);
        topRatedMovies = filter(results[2]);
        upcomingContent = filter(mergedUpcoming);
        continueWatching = results[5].take(10).toList();
        nowPlaying = filter(results[7]);
        genres = results[8];
      });
    } catch (e) {
      debugPrint('Home load error: $e');
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  /// Fetches upcoming seasons/episodes for TV series in the user's watchlist.
  Future<List<Map<String, dynamic>>> _loadWatchlistUpcoming() async {
    try {
      final watchlist = await DBHelper.getWatchlist();
      final tvItems = watchlist.where((m) => m.mediaType == 'tv').toList();
      if (tvItems.isEmpty) return const [];

      final upcoming = <Map<String, dynamic>>[];
      // Limit to 8 series to avoid too many API calls
      for (final item in tvItems.take(8)) {
        try {
          final details = await TmdbApiService.getSeriesDetails(
            int.parse(item.id),
          );
          if (details == null) continue;
          final nextAir = details['next_episode_to_air'];
          if (nextAir == null || nextAir is! Map) continue;

          final seasonNum = nextAir['season_number'] ?? 0;
          final episodeNum = nextAir['episode_number'] ?? 0;
          final airDate = nextAir['air_date']?.toString() ?? '';
          if (seasonNum == 0 && episodeNum == 0) continue;

          upcoming.add({
            'id': item.id,
            'title': item.title,
            'name': item.title,
            'poster_path': item.thumbnail.replaceFirst(
              RegExp(r'^https?://image\.tmdb\.org/t/p/w\d+'),
              '',
            ),
            'backdrop_path': item.backdrop.isNotEmpty
                ? item.backdrop.replaceFirst(
                    RegExp(r'^https?://image\.tmdb\.org/t/p/w\d+'),
                    '',
                  )
                : item.thumbnail.replaceFirst(
                    RegExp(r'^https?://image\.tmdb\.org/t/p/w\d+'),
                    '',
                  ),
            'vote_average': item.rating,
            'overview': item.description,
            'media_type': 'tv',
            'release_date': airDate,
            'first_air_date': airDate,
            '_nextSeason': seasonNum,
            '_nextEpisode': episodeNum,
            '_nextAirDate': airDate,
            '_isWatchlistUpcoming': true,
          });
        } catch (_) {
          // Skip individual failures
        }
      }
      return upcoming;
    } catch (_) {
      return const [];
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: KidsTheme.background,
      body: RefreshIndicator(
        onRefresh: _loadContent,
        child: isLoading
            ? _buildLoadingShimmer()
            : CustomScrollView(
                physics: const ClampingScrollPhysics(),
                slivers: [
                  _buildAppBar(),
                  SliverToBoxAdapter(
                    child: HeroBanner(onPlayerReturn: _loadContinueWatching),
                  ),
                  SliverToBoxAdapter(
                    child: ContinueWatchingSection(
                      continueWatching: continueWatching,
                      onChanged: _loadContinueWatching,
                    ),
                  ),
                  SliverToBoxAdapter(child: _buildProvidersSection()),
                  if (genres.isNotEmpty)
                    SliverToBoxAdapter(child: _buildGenresSection()),
                  _buildSection('Trending Movies', trendingMovies, 'movie'),
                  _buildSection('Popular Movies', popularMovies, 'movie'),
                  _buildSection('Top Rated Movies', topRatedMovies, 'movie'),
                  if (upcomingContent.isNotEmpty) _buildUpcomingSection(),
                  const SliverToBoxAdapter(child: SizedBox(height: 100)),
                ],
              ),
      ),
    );
  }

  Future<void> _loadContinueWatching() async {
    final profileId = ProfileScope.currentProfileId;
    // Pull TV watches first so Haven S4E9 mid-watch appears immediately
    try {
      await CloudSyncService.pullToDevice();
    } catch (_) {}
    // Guard: if profile changed during pull, abort.
    if (!mounted || profileId != ProfileScope.currentProfileId) return;
    final history = await WatchHistoryService.getContinueWatching();
    if (!mounted) return;
    setState(() => continueWatching = history.take(10).toList());
  }

  Widget _buildLoadingShimmer() {
    return AppShimmer(
      baseColor: Colors.grey[800]!,
      highlightColor: Colors.grey[600]!,
      child: CustomScrollView(
        slivers: [
          SliverAppBar(
            floating: true,
            backgroundColor: KidsTheme.surface,
            title: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.grey[800],
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    Icons.play_arrow,
                    color: Colors.grey[800],
                    size: 20,
                  ),
                ),
                const SizedBox(width: 8),
                Container(width: 100, height: 24, color: Colors.grey[800]),
              ],
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Hero banner skeleton
                  Container(
                    height: 200,
                    decoration: BoxDecoration(
                      color: Colors.grey[800],
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Continue watching skeleton
                  Container(height: 24, width: 150, color: Colors.grey[800]),
                  const SizedBox(height: 12),
                  Container(height: 150, color: Colors.grey[800]),
                  const SizedBox(height: 24),

                  // Section 1 skeleton
                  Container(height: 24, width: 150, color: Colors.grey[800]),
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
                  const SizedBox(height: 24),

                  // Section 2 skeleton
                  Container(height: 24, width: 150, color: Colors.grey[800]),
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
                  const SizedBox(height: 24),

                  // Section 3 skeleton
                  Container(height: 24, width: 150, color: Colors.grey[800]),
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

  Widget _buildAppBar() {
    return SliverAppBar(
      floating: true,
      backgroundColor: KidsTheme.surface,
      title: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(8),
            ),
            clipBehavior: Clip.antiAlias,
            child: Image.asset('assets/images/app_icon.png', fit: BoxFit.cover),
          ),
          const SizedBox(width: 10),
          const Text(
            'MaxStream',
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

  Widget _buildProvidersSection() {
    final providers = [
      _ProviderInfo(
        id: 8,
        name: 'Netflix',
        color: const Color(0xFFE50914),
        logoPath: '/pbpMk2JmcoNnQwx5JGpXngfoWtp.jpg',
      ),
      _ProviderInfo(
        id: 9,
        name: 'Prime Video',
        color: const Color(0xFF00A8E1),
        logoPath: '/pvske1MyAoymrs5bguRfVqYiM9a.jpg',
      ),
      _ProviderInfo(
        id: 337,
        name: 'Disney+',
        color: const Color(0xFF113CCF),
        logoPath: '/97yvRBw1GzX7fXprcF80er19ot.jpg',
      ),
      _ProviderInfo(
        id: 15,
        name: 'Hulu',
        color: const Color(0xFF1CE783),
        logoPath: '/bxBlRPEPpMVDc4jMhSrTf2339DW.jpg',
      ),
      _ProviderInfo(
        id: 350,
        name: 'Apple TV',
        color: const Color(0xFF1F1F1F),
        logoPath: '/mcbz1LgtErU9p4UdbZ0rG6RTWHX.jpg',
      ),
      _ProviderInfo(
        id: 1899,
        name: 'HBO Max',
        color: const Color(0xFF542DBF),
        logoPath: '/jbe4gVSfRlbPTdESXhEKpornsfu.jpg',
      ),
      _ProviderInfo(
        id: 386,
        name: 'Peacock',
        color: const Color(0xFF1B365D),
        logoPath: '/2aGrp1xw3qhwCYvNGAJZPdjfeeX.jpg',
      ),
      _ProviderInfo(
        id: 582,
        name: 'Paramount+',
        color: const Color(0xFF0064FF),
        logoPath: '/5qda0qKT6I1tm5EUOlw3YqQ5w.jpg',
      ),
      _ProviderInfo(
        id: 526,
        name: 'AMC+',
        color: const Color(0xFF1A1A1A),
        logoPath: '/ovmu6uot1XVvsemM2dDySXLiX57.jpg',
      ),
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Streaming Providers',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: List.generate(providers.length, (index) {
                final provider = providers[index];
                return Padding(
                  padding: EdgeInsets.only(
                    right: index == providers.length - 1 ? 0 : 12,
                  ),
                  child: GestureDetector(
                    onTap: () {
                      HapticFeedback.lightImpact();
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => ProviderContentScreen(
                            providerId: provider.id,
                            providerName: provider.name,
                            providerColor: provider.color,
                          ),
                        ),
                      );
                    },
                    child: SizedBox(
                      width: 94,
                      height: 112,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeInOut,
                        decoration: BoxDecoration(
                          color: provider.color,
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: [
                            BoxShadow(
                              color: provider.color.withValues(alpha: 0.5),
                              blurRadius: 8,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 12,
                        ),
                        child: Column(
                          children: [
                            Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: provider.logoPath != null
                                  ? AppNetworkImage(
                                      url:
                                          'https://image.tmdb.org/t/p/w92${provider.logoPath}',
                                      fit: BoxFit.contain,
                                      errorWidget: Center(
                                        child: Text(
                                          provider.name.substring(0, 1),
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.bold,
                                            fontSize: 20,
                                          ),
                                        ),
                                      ),
                                    )
                                  : Center(
                                      child: Text(
                                        provider.name.substring(0, 1),
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 20,
                                        ),
                                      ),
                                    ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              provider.name,
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGenresSection() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Browse by Genre',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: List.generate(genres.length, (index) {
                final genre = genres[index];
                final name = genre['name']?.toString() ?? '';
                final id = genre['id'] as int?;
                if (name.isEmpty || id == null) return const SizedBox();
                return Padding(
                  padding: EdgeInsets.only(
                    right: index == genres.length - 1 ? 0 : 10,
                  ),
                  child: GestureDetector(
                    onTap: () {
                      HapticFeedback.lightImpact();
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) =>
                              _GenreMoviesScreen(genreId: id, genreName: name),
                        ),
                      );
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E1E1E),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.12),
                        ),
                      ),
                      child: Text(
                        name,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),
        ],
      ),
    );
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
                  child: Text(
                    'See All',
                    style: TextStyle(color: KidsTheme.primary, fontSize: 14),
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
                return _buildMovieCard(item, mediaType);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUpcomingSection() {
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
                        color: Colors.purple.shade700,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Icon(
                        Icons.upcoming,
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
                        builder: (context) => const _ComingSoonFullListScreen(),
                      ),
                    );
                  },
                  child: Text(
                    'See All',
                    style: TextStyle(color: KidsTheme.primary, fontSize: 14),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 300,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: upcomingContent.length,
              itemBuilder: (context, index) {
                final item = upcomingContent[index];
                return _buildUpcomingCard(item);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUpcomingCard(Map<String, dynamic> item) {
    final name = item['title'] ?? item['name'] ?? 'Unknown';
    final posterPath = item['poster_path'];
    final backdropPath = item['backdrop_path'];
    final rating = (item['vote_average'] as num?)?.toDouble();
    final releaseDate =
        (item['release_date'] ?? item['first_air_date'])?.toString() ?? '';
    final overview = item['overview']?.toString() ?? '';
    final isTv = item['media_type'] == 'tv';
    final typeLabel = isTv ? 'TV' : 'MOVIE';
    final isWatchlistUpcoming = item['_isWatchlistUpcoming'] == true;
    final nextSeason = item['_nextSeason'];
    final nextEpisode = item['_nextEpisode'];

    return GestureDetector(
      onTap: () {
        if (!mounted) return;
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => isTv
                ? MaxStreamSeriesScreen(seriesItem: Movie.fromJson(item))
                : MaxStreamDetailsScreen(
                    item: Movie.fromJson(item),
                    mediaType: 'movie',
                  ),
          ),
        );
      },
      child: Container(
        width: 280,
        margin: const EdgeInsets.only(right: 14),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Backdrop image with poster fallback
              backdropPath != null
                  ? AppNetworkImage(
                      url: TmdbApiService.getBackdropUrl(backdropPath),
                      fit: BoxFit.cover,
                      errorWidget: _posterFallback(posterPath),
                    )
                  : _posterFallback(posterPath),
              // Gradient overlay
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
                      stops: const [0.3, 1.0],
                    ),
                  ),
                ),
              ),
              // Poster thumbnail bottom-left
              if (posterPath != null)
                Positioned(
                  left: 10,
                  bottom: 10,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: AppNetworkImage(
                      url: TmdbApiService.getPosterUrl(posterPath),
                      width: 50,
                      height: 72,
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
              // Badge row: type + UPCOMING
              Positioned(
                top: 10,
                left: 10,
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: isTv ? Colors.teal : KidsTheme.primary,
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
                    ),
                    const SizedBox(width: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: isWatchlistUpcoming
                            ? Colors.amber.shade700
                            : Colors.purple.shade700,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        isWatchlistUpcoming ? 'IN YOUR WATCHLIST' : 'UPCOMING',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                  ],
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
              // Text info
              Positioned(
                left: posterPath != null ? 72 : 10,
                right: 10,
                bottom: 10,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      name,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (isWatchlistUpcoming && nextSeason != null) ...[
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          const Icon(
                            Icons.tv,
                            color: Colors.amberAccent,
                            size: 11,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            'Season $nextSeason · Episode $nextEpisode',
                            style: const TextStyle(
                              color: Colors.amberAccent,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ],
                    if (releaseDate.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(
                            isWatchlistUpcoming
                                ? Icons.access_time
                                : Icons.calendar_today,
                            color: isWatchlistUpcoming
                                ? Colors.amberAccent
                                : Colors.purpleAccent,
                            size: 11,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            _formatReleaseDate(releaseDate),
                            style: TextStyle(
                              color: isWatchlistUpcoming
                                  ? Colors.amberAccent
                                  : Colors.purpleAccent,
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ],
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

  Widget _posterFallback(String? posterPath) {
    if (posterPath != null) {
      return AppNetworkImage(
        url: TmdbApiService.getPosterUrl(posterPath),
        fit: BoxFit.cover,
        errorWidget: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [Colors.grey[850]!, Colors.grey[900]!],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: const Icon(Icons.movie, color: Colors.grey, size: 50),
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.grey[850]!, Colors.grey[900]!],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: const Icon(Icons.movie, color: Colors.grey, size: 50),
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

  Widget _buildMovieCard(Map<String, dynamic> item, String mediaType) {
    final name = item['title'] ?? item['name'] ?? 'Unknown';
    final posterPath = item['poster_path'];
    final rating = (item['vote_average'] as num?)?.toDouble();
    final year = _getYear(item);
    final typeLabel = mediaType == 'tv' ? 'TV' : 'MOVIE';

    return GestureDetector(
      onTap: () {
        if (!mounted) return;
        Navigator.push(
          context,
          PageRouteBuilder(
            pageBuilder: (context, animation, secondaryAnimation) =>
                mediaType == 'tv'
                ? MaxStreamSeriesScreen(seriesItem: Movie.fromJson(item))
                : MaxStreamDetailsScreen(
                    item: Movie.fromJson(item),
                    mediaType: mediaType,
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
                            Icons.movie,
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
                        color: KidsTheme.primary,
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
    final date = item['release_date'] ?? item['first_air_date'];
    if (date != null && date.length >= 4) {
      return date.substring(0, 4);
    }
    return '';
  }
}

class _ProviderInfo {
  final int id;
  final String name;
  final Color color;
  final String? logoPath;

  _ProviderInfo({
    required this.id,
    required this.name,
    required this.color,
    this.logoPath,
  });
}

class _GenreMoviesScreen extends StatefulWidget {
  final int genreId;
  final String genreName;

  const _GenreMoviesScreen({required this.genreId, required this.genreName});

  @override
  State<_GenreMoviesScreen> createState() => _GenreMoviesScreenState();
}

class _GenreMoviesScreenState extends State<_GenreMoviesScreen> {
  List<Map<String, dynamic>> _movies = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadMovies();
  }

  Future<void> _loadMovies() async {
    setState(() => _isLoading = true);
    try {
      final results = await TmdbApiService.getMoviesByGenre(widget.genreId);
      if (mounted) setState(() => _movies = results);
    } catch (_) {
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: KidsTheme.background,
      appBar: AppBar(
        backgroundColor: KidsTheme.surface,
        title: Text(
          widget.genreName,
          style: const TextStyle(color: Colors.white),
        ),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: KidsTheme.primary))
          : _movies.isEmpty
          ? const Center(
              child: Text(
                'No movies found',
                style: TextStyle(color: Colors.grey, fontSize: 16),
              ),
            )
          : GridView.builder(
              physics: const ClampingScrollPhysics(),
              padding: const EdgeInsets.all(12),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
                childAspectRatio: 0.6,
              ),
              itemCount: _movies.length,
              itemBuilder: (context, index) {
                final item = _movies[index];
                return GestureDetector(
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => MaxStreamDetailsScreen(
                          item: Movie.fromJson(item),
                          mediaType: 'movie',
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
                                    Icons.movie,
                                    color: Colors.grey,
                                    size: 40,
                                  ),
                                ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        item['title'] ?? item['name'] ?? 'Unknown',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                );
              },
            ),
    );
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

      if (widget.title.contains('Trending') && widget.mediaType == 'movie') {
        initialItems = await TmdbApiService.fetchTrendingMovies(page: 1);
      } else if (widget.title.contains('Popular') &&
          widget.mediaType == 'movie') {
        initialItems = await TmdbApiService.fetchPopularMovies(page: 1);
      } else if (widget.title.contains('Top Rated') &&
          widget.mediaType == 'movie') {
        initialItems = await TmdbApiService.fetchTopRatedMovies(page: 1);
      } else if (widget.title.contains('Now Playing') &&
          widget.mediaType == 'movie') {
        initialItems = await TmdbApiService.fetchNowPlayingMovies(page: 1);
      } else if (widget.title.contains('Upcoming') &&
          widget.mediaType == 'movie') {
        initialItems = TmdbApiService.filterUnreleased(
          await TmdbApiService.fetchUpcomingMovies(page: 1),
        );
      } else if (widget.title.contains('Trending') &&
          widget.mediaType == 'tv') {
        initialItems = await TmdbApiService.fetchTrendingSeries(page: 1);
      } else if (widget.title.contains('Popular') && widget.mediaType == 'tv') {
        initialItems = await TmdbApiService.fetchPopularSeries(page: 1);
      } else if (widget.title.contains('Top Rated') &&
          widget.mediaType == 'tv') {
        initialItems = await TmdbApiService.fetchTopRatedSeries(page: 1);
      }

      if (!mounted) return;
      setState(() {
        _allItems = filterForKids(initialItems);
        _isLoading = false;
      });
    } catch (e) {
      // Error loading initial items
      if (!mounted) return;
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
    if (!_scrollController.hasClients) return;
    if (_scrollController.position.pixels ==
            _scrollController.position.maxScrollExtent &&
        !_isLoading &&
        _hasMore) {
      _loadMoreItems();
    }
  }

  Future<void> _loadMoreItems() async {
    if (_isLoading || !_hasMore) return;

    if (!mounted) return;
    setState(() {
      _isLoading = true;
    });

    try {
      final nextPage = _currentPage + 1;
      List<Map<String, dynamic>> newItems = [];

      if (widget.title.contains('Trending') && widget.mediaType == 'movie') {
        newItems = await TmdbApiService.fetchTrendingMovies(page: nextPage);
      } else if (widget.title.contains('Popular') &&
          widget.mediaType == 'movie') {
        newItems = await TmdbApiService.fetchPopularMovies(page: nextPage);
      } else if (widget.title.contains('Top Rated') &&
          widget.mediaType == 'movie') {
        newItems = await TmdbApiService.fetchTopRatedMovies(page: nextPage);
      } else if (widget.title.contains('Now Playing') &&
          widget.mediaType == 'movie') {
        newItems = await TmdbApiService.fetchNowPlayingMovies(page: nextPage);
      } else if (widget.title.contains('Upcoming') &&
          widget.mediaType == 'movie') {
        newItems = TmdbApiService.filterUnreleased(
          await TmdbApiService.fetchUpcomingMovies(page: nextPage),
        );
      } else if (widget.title.contains('Trending') &&
          widget.mediaType == 'tv') {
        newItems = await TmdbApiService.fetchTrendingSeries(page: nextPage);
      } else if (widget.title.contains('Popular') && widget.mediaType == 'tv') {
        newItems = await TmdbApiService.fetchPopularSeries(page: nextPage);
      } else if (widget.title.contains('Top Rated') &&
          widget.mediaType == 'tv') {
        newItems = await TmdbApiService.fetchTopRatedSeries(page: nextPage);
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: KidsTheme.background,
      appBar: AppBar(
        backgroundColor: KidsTheme.surface,
        title: Text(widget.title, style: const TextStyle(color: Colors.white)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Column(
        children: [
          Expanded(
            child: GridView.builder(
              controller: _scrollController,
              physics: const ClampingScrollPhysics(),
              padding: const EdgeInsets.all(16),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
                childAspectRatio: 0.6,
              ),
              itemCount: _allItems.length,
              itemBuilder: (context, index) {
                final item = _allItems[index];
                return GestureDetector(
                  key: ValueKey(tmdbItemKey(item, widget.mediaType)),
                  onTap: () {
                    Navigator.push(
                      context,
                      PageRouteBuilder(
                        pageBuilder: (context, animation, secondaryAnimation) =>
                            widget.mediaType == 'tv'
                            ? MaxStreamSeriesScreen(
                                seriesItem: Movie.fromJson(item),
                              )
                            : MaxStreamDetailsScreen(
                                item: Movie.fromJson(item),
                                mediaType: widget.mediaType,
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
                                  child: Icon(
                                    widget.mediaType == 'tv'
                                        ? Icons.tv
                                        : Icons.movie,
                                    color: Colors.grey,
                                    size: 40,
                                  ),
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
              },
            ),
          ),
          if (_isLoading)
            const Padding(
              padding: EdgeInsets.all(16.0),
              child: CustomLoadingWidget(
                size: 30,
                color: Color(0xFFE50914),
                style: LoadingStyle.dots,
              ),
            ),
        ],
      ),
    );
  }

  String _getYear(Map<String, dynamic> item) {
    final date = item['release_date'] ?? item['first_air_date'];
    if (date != null && date.length >= 4) {
      return date.substring(0, 4);
    }
    return '';
  }
}

class _ComingSoonFullListScreen extends StatefulWidget {
  const _ComingSoonFullListScreen();

  @override
  State<_ComingSoonFullListScreen> createState() =>
      _ComingSoonFullListScreenState();
}

class _ComingSoonFullListScreenState extends State<_ComingSoonFullListScreen> {
  List<Map<String, dynamic>> _items = [];
  bool _isLoading = true;
  bool _isLoadingMore = false;
  bool _hasMore = true;
  int _moviePage = 1;
  int _seriesPage = 1;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_scrollListener);
    _loadInitial();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollListener() {
    if (_scrollController.position.pixels >=
            _scrollController.position.maxScrollExtent - 200 &&
        !_isLoadingMore &&
        !_isLoading &&
        _hasMore) {
      _loadMore();
    }
  }

  String _getReleaseDate(Map<String, dynamic> item) {
    return (item['_nextAirDate'] ??
                item['release_date'] ??
                item['first_air_date'])
            ?.toString() ??
        '';
  }

  int _dateSort(Map<String, dynamic> a, Map<String, dynamic> b) {
    final da = _getReleaseDate(a);
    final db = _getReleaseDate(b);
    if (da.isEmpty && db.isEmpty) return 0;
    if (da.isEmpty) return 1;
    if (db.isEmpty) return -1;
    try {
      final pa = DateTime.parse(da);
      final pb = DateTime.parse(db);
      return pa.compareTo(pb);
    } catch (_) {
      return da.compareTo(db);
    }
  }

  Future<List<Map<String, dynamic>>> _loadWatchlistUpcoming() async {
    try {
      final watchlist = await DBHelper.getWatchlist();
      final tvItems = watchlist.where((m) => m.mediaType == 'tv').toList();
      if (tvItems.isEmpty) return const [];
      final futures = tvItems.take(12).map((item) async {
        try {
          final details = await TmdbApiService.getSeriesDetails(
            int.parse(item.id),
          );
          if (details == null) return null;
          final nextAir = details['next_episode_to_air'];
          if (nextAir == null || nextAir is! Map) return null;
          final seasonNum = nextAir['season_number'] ?? 0;
          final episodeNum = nextAir['episode_number'] ?? 0;
          final airDate = nextAir['air_date']?.toString() ?? '';
          if (seasonNum == 0 && episodeNum == 0) return null;
          return {
            'id': item.id,
            'title': item.title,
            'name': item.title,
            'poster_path': item.thumbnail.replaceFirst(
              RegExp(r'^https?://image\.tmdb\.org/t/p/w\d+'),
              '',
            ),
            'backdrop_path': item.backdrop.isNotEmpty
                ? item.backdrop.replaceFirst(
                    RegExp(r'^https?://image\.tmdb\.org/t/p/w\d+'),
                    '',
                  )
                : item.thumbnail.replaceFirst(
                    RegExp(r'^https?://image\.tmdb\.org/t/p/w\d+'),
                    '',
                  ),
            'vote_average': item.rating,
            'overview': item.description,
            'media_type': 'tv',
            'release_date': airDate,
            'first_air_date': airDate,
            '_nextSeason': seasonNum,
            '_nextEpisode': episodeNum,
            '_nextAirDate': airDate,
            '_isWatchlistUpcoming': true,
          };
        } catch (_) {
          return null;
        }
      }).toList();
      final results = await Future.wait(futures);
      return results.whereType<Map<String, dynamic>>().toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> _loadInitial() async {
    setState(() => _isLoading = true);
    try {
      final results = await Future.wait([
        _loadWatchlistUpcoming(),
        TmdbApiService.fetchUpcomingMovies(page: 1),
        TmdbApiService.fetchUpcomingSeries(page: 1),
      ]);
      final watchlistUpcoming = results[0];
      final moviesRaw = results[1];
      final seriesRaw = results[2];
      final movies = TmdbApiService.filterUnreleased(moviesRaw);
      for (final m in movies) {
        m['media_type'] = 'movie';
      }
      final series = TmdbApiService.filterUnreleased(
        seriesRaw,
        dateField: 'first_air_date',
      );
      for (final s in series) {
        s['media_type'] = 'tv';
      }
      final merged = [...watchlistUpcoming, ...movies, ...series];
      merged.sort(_dateSort);
      final deduped = <String, Map<String, dynamic>>{};
      for (final item in merged) {
        deduped.putIfAbsent(
          tmdbItemKey(item, item['media_type'] ?? 'movie'),
          () => item,
        );
      }
      if (!mounted) return;
      setState(() {
        _items = deduped.values.toList();
        _isLoading = false;
        _moviePage = 1;
        _seriesPage = 1;
        _hasMore = moviesRaw.length >= 20 || seriesRaw.length >= 20;
      });
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _loadMore() async {
    if (_isLoadingMore || !_hasMore) return;
    setState(() => _isLoadingMore = true);
    try {
      final nextMoviePage = _moviePage + 1;
      final nextSeriesPage = _seriesPage + 1;
      final results = await Future.wait([
        TmdbApiService.fetchUpcomingMovies(page: nextMoviePage),
        TmdbApiService.fetchUpcomingSeries(page: nextSeriesPage),
      ]);
      final moviesRaw = results[0];
      final seriesRaw = results[1];
      final movies = TmdbApiService.filterUnreleased(moviesRaw);
      for (final m in movies) {
        m['media_type'] = 'movie';
      }
      final series = TmdbApiService.filterUnreleased(
        seriesRaw,
        dateField: 'first_air_date',
      );
      for (final s in series) {
        s['media_type'] = 'tv';
      }
      final newItems = [...movies, ...series];
      if (newItems.isEmpty) {
        if (mounted) setState(() => _hasMore = false);
        return;
      }
      newItems.sort(_dateSort);
      if (!mounted) return;
      // Keep existing order to avoid glitch where already-shown movies jump
      // positions when merged is re-sorted by date (new items with earlier dates
      // would insert in middle, making it look like duplicates).
      final merged = uniqueTmdbItems(_items, newItems, 'movie');
      setState(() {
        _hasMore = movies.isNotEmpty || series.isNotEmpty;
        _items = merged;
        _moviePage = nextMoviePage;
        _seriesPage = nextSeriesPage;
      });
    } catch (_) {
      // keep hasMore so user can retry via scroll
    } finally {
      if (mounted) setState(() => _isLoadingMore = false);
    }
  }

  Widget _posterFallback(String? posterPath) {
    if (posterPath != null) {
      return AppNetworkImage(
        url: TmdbApiService.getPosterUrl(posterPath),
        fit: BoxFit.cover,
        errorWidget: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [Colors.grey[850]!, Colors.grey[900]!],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: const Icon(Icons.movie, color: Colors.grey, size: 50),
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.grey[850]!, Colors.grey[900]!],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: const Icon(Icons.movie, color: Colors.grey, size: 50),
    );
  }

  String _formatReleaseDate(String date) {
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
    } catch (_) {
      return date;
    }
  }

  Widget _buildComingSoonGridCard(Map<String, dynamic> item) {
    final name = item['title'] ?? item['name'] ?? 'Unknown';
    final posterPath = item['poster_path'];
    final backdropPath = item['backdrop_path'];
    final rating = (item['vote_average'] as num?)?.toDouble();
    final releaseDate =
        (item['release_date'] ?? item['first_air_date'])?.toString() ?? '';
    final overview = item['overview']?.toString() ?? '';
    final isTv = item['media_type'] == 'tv';
    final typeLabel = isTv ? 'TV' : 'MOVIE';
    final isWatchlistUpcoming = item['_isWatchlistUpcoming'] == true;
    final nextSeason = item['_nextSeason'];
    final nextEpisode = item['_nextEpisode'];

    return GestureDetector(
      onTap: () {
        if (!mounted) return;
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => isTv
                ? MaxStreamSeriesScreen(seriesItem: Movie.fromJson(item))
                : MaxStreamDetailsScreen(
                    item: Movie.fromJson(item),
                    mediaType: 'movie',
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
              child: Stack(
                fit: StackFit.expand,
                children: [
                  backdropPath != null
                      ? AppNetworkImage(
                          url: TmdbApiService.getBackdropUrl(backdropPath),
                          fit: BoxFit.cover,
                          errorWidget: _posterFallback(posterPath),
                        )
                      : (posterPath != null
                            ? AppNetworkImage(
                                url: TmdbApiService.getPosterUrl(posterPath),
                                fit: BoxFit.cover,
                              )
                            : _posterFallback(posterPath)),
                  Positioned.fill(
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.transparent,
                            Colors.black.withValues(alpha: 0.85),
                          ],
                          stops: const [0.5, 1.0],
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 6,
                    left: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: isTv ? Colors.teal : KidsTheme.primary,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        typeLabel,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 8,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 6,
                    right: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: isWatchlistUpcoming
                            ? Colors.amber.shade700
                            : Colors.purple.shade700,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        isWatchlistUpcoming ? 'WATCHLIST' : 'UPCOMING',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 7,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                  if (rating != null && rating > 0)
                    Positioned(
                      bottom: 6,
                      right: 6,
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
                            const Icon(
                              Icons.star,
                              color: Colors.amber,
                              size: 9,
                            ),
                            const SizedBox(width: 2),
                            Text(
                              rating.toStringAsFixed(1),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 9,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (posterPath != null)
                    Positioned(
                      left: 6,
                      bottom: 6,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: AppNetworkImage(
                          url: TmdbApiService.getPosterUrl(posterPath),
                          width: 28,
                          height: 38,
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            name,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          if (isWatchlistUpcoming && nextSeason != null)
            Text(
              'S$nextSeason · E$nextEpisode',
              style: const TextStyle(
                color: Colors.amberAccent,
                fontSize: 9,
                fontWeight: FontWeight.w600,
              ),
            ),
          if (releaseDate.isNotEmpty)
            Text(
              _formatReleaseDate(releaseDate),
              style: TextStyle(
                color: isWatchlistUpcoming
                    ? Colors.amberAccent
                    : Colors.purpleAccent,
                fontSize: 9,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          if (overview.isNotEmpty)
            Text(
              overview,
              style: const TextStyle(color: Colors.white54, fontSize: 9),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: KidsTheme.background,
      appBar: AppBar(
        backgroundColor: KidsTheme.surface,
        title: const Text('Coming Soon', style: TextStyle(color: Colors.white)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Column(
        children: [
          Expanded(
            child: GridView.builder(
              controller: _scrollController,
              physics: const ClampingScrollPhysics(),
              padding: const EdgeInsets.all(16),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
                childAspectRatio: 0.52,
              ),
              itemCount: _items.length,
              itemBuilder: (context, index) {
                final item = _items[index];
                return _buildComingSoonGridCard(item);
              },
            ),
          ),
          if (_isLoading || _isLoadingMore)
            const Padding(
              padding: EdgeInsets.all(16.0),
              child: CustomLoadingWidget(
                size: 30,
                color: Color(0xFFE50914),
                style: LoadingStyle.dots,
              ),
            ),
        ],
      ),
    );
  }
}
