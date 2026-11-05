import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';
import '../models/movie.dart';
import '../services/tmdb_api_service.dart';
import '../utils/kids_filter.dart';
import '../widgets/custom_loading_widget.dart';
import '../widgets/profile_menu_button.dart';
import 'maxstream_details_screen.dart';
import 'maxstream_series_screen.dart';
import 'actor_details_screen.dart';
import '../widgets/app_network_image.dart';

class MaxStreamSearchScreen extends StatefulWidget {
  const MaxStreamSearchScreen({super.key});

  @override
  State<MaxStreamSearchScreen> createState() => _MaxStreamSearchScreenState();
}

class _MaxStreamSearchScreenState extends State<MaxStreamSearchScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final TextEditingController _searchController = TextEditingController();

  bool isLoading = false;
  List<Map<String, dynamic>> searchResults = [];
  List<Map<String, dynamic>> actorResults = [];

  final List<String> _searchTabs = ['All', 'Movies', 'TV Shows', 'Actors'];
  int _currentTabIndex = 0;
  int _searchGeneration = 0;

  // Top Searched / Most Watched (idle state when no query)
  List<String> _searchHistory = [];
  List<Map<String, dynamic>> topSearched = [];
  List<Map<String, dynamic>> mostWatched = [];
  bool isLoadingRecommendations = true;

  // Voice search
  final SpeechToText _speechToText = SpeechToText();
  bool _speechEnabled = false;
  bool _isListening = false;
  Timer? _voiceDebounce;

  // Content filters
  int? _filterGenreId;
  String? _filterGenreName;
  int? _filterYearFrom;
  int? _filterYearTo;
  double? _filterRatingMin;
  bool _filtersActive = false;
  static const Map<int, String> _genreMap = {
    28: 'Action',
    12: 'Adventure',
    16: 'Animation',
    35: 'Comedy',
    80: 'Crime',
    99: 'Documentary',
    18: 'Drama',
    10751: 'Family',
    14: 'Fantasy',
    36: 'History',
    27: 'Horror',
    10402: 'Music',
    9648: 'Mystery',
    10749: 'Romance',
    878: 'Sci-Fi',
    10770: 'TV Movie',
    53: 'Thriller',
    10752: 'War',
    37: 'Western',
    10759: 'Action & Adventure',
    10762: 'Kids',
    10763: 'News',
    10764: 'Reality',
    10765: 'Sci-Fi & Fantasy',
    10766: 'Soap',
    10767: 'Talk',
    10768: 'War & Politics',
  };

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _searchTabs.length, vsync: this);
    _tabController.addListener(() {
      if (_tabController.indexIsChanging) {
        setState(() {
          _currentTabIndex = _tabController.index;
        });
        if (_searchController.text.isNotEmpty) {
          _performSearch(_searchController.text);
        }
      }
    });
    _loadSearchHistory();
    _loadSearchRecommendations();
    _initSpeech();
  }

  Future<void> _initSpeech() async {
    try {
      _speechEnabled = await _speechToText.initialize(
        onError: (e) => debugPrint('Speech init error: $e'),
        onStatus: (s) {
          if (s == 'done' || s == 'notListening') {
            if (mounted) setState(() => _isListening = false);
          }
        },
      );
    } catch (_) {
      _speechEnabled = false;
    }
  }

  Future<void> _toggleListening() async {
    if (_isListening) {
      await _speechToText.stop();
      if (mounted) setState(() => _isListening = false);
      return;
    }
    final status = await Permission.microphone.request();
    if (status.isDenied || status.isPermanentlyDenied) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Microphone permission needed for voice search'),
          ),
        );
      }
      return;
    }
    if (!_speechEnabled) {
      await _initSpeech();
      if (!_speechEnabled) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Voice search not available on this device'),
            ),
          );
        }
        return;
      }
    }
    if (mounted) setState(() => _isListening = true);
    // Keep listening longer so it doesn't cut off before you speak:
    // 30s total, 5s of silence allowed, system locale, partial results.
    await _speechToText.listen(
      onResult: _onSpeechResult,
      listenFor: const Duration(seconds: 30),
      pauseFor: const Duration(seconds: 5),
      listenOptions: SpeechListenOptions(
        cancelOnError: false,
        partialResults: true,
        listenMode: ListenMode.search,
      ),
    );
    // If listen() returns false (no speech service), reset UI.
    if (!_speechToText.isListening && mounted) {
      setState(() => _isListening = false);
    }
  }

  String _cleanVoiceQuery(String raw) {
    var q = raw.trim().toLowerCase();
    // Strip common fillers: "search for", "find", "show me", "play", "open"
    q = q.replaceFirst(
      RegExp(
        r'^(search\s+(for\s+)?|find\s+(for\s+)?|show me\s+|play\s+|open\s+)',
      ),
      '',
    );
    // Title-case for display but keep lower for search – search is case-insensitive
    final cleaned = q.trim();
    if (cleaned.isEmpty) return raw.trim();
    // Capitalize first letter for UI nicety
    return cleaned[0].toUpperCase() + cleaned.substring(1);
  }

  void _onSpeechResult(SpeechRecognitionResult result) {
    final raw = result.recognizedWords.trim();
    if (raw.isEmpty) return;
    final words = _cleanVoiceQuery(raw);
    _searchController.text = words;
    _searchController.selection = TextSelection.fromPosition(
      TextPosition(offset: words.length),
    );
    setState(() {});
    // Fire on partial after short debounce so results appear instantly while speaking;
    // finalResult always fires immediately for reliability.
    if (result.finalResult) {
      _voiceDebounce?.cancel();
      _performSearch(words);
      if (mounted) setState(() => _isListening = false);
    } else {
      _voiceDebounce?.cancel();
      _voiceDebounce = Timer(const Duration(milliseconds: 650), () {
        if (!mounted || words.length < 2) return;
        _performSearch(words);
      });
    }
  }

  Future<void> _loadSearchHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = prefs.getString('search_history');
    if (encoded != null) {
      final List<dynamic> decoded = jsonDecode(encoded);
      setState(() => _searchHistory = decoded.cast<String>());
    }
  }

  Future<void> _saveToHistory(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;
    setState(() {
      _searchHistory.remove(trimmed);
      _searchHistory.insert(0, trimmed);
      if (_searchHistory.length > 20) {
        _searchHistory = _searchHistory.sublist(0, 20);
      }
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('search_history', jsonEncode(_searchHistory));
  }

  Future<void> _removeFromHistory(String query) async {
    setState(() => _searchHistory.remove(query));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('search_history', jsonEncode(_searchHistory));
  }

  Future<void> _loadSearchRecommendations() async {
    setState(() => isLoadingRecommendations = true);
    try {
      final results = await Future.wait([
        TmdbApiService.fetchTrendingMovies().catchError(
          (_) => <Map<String, dynamic>>[],
        ),
        TmdbApiService.fetchTrendingSeries().catchError(
          (_) => <Map<String, dynamic>>[],
        ),
        TmdbApiService.fetchPopularMovies().catchError(
          (_) => <Map<String, dynamic>>[],
        ),
        TmdbApiService.fetchPopularSeries().catchError(
          (_) => <Map<String, dynamic>>[],
        ),
      ]);
      if (!mounted) return;
      final trending = filterForKids([...results[0], ...results[1]])..shuffle();
      final popular = filterForKids([...results[2], ...results[3]])..shuffle();
      setState(() {
        topSearched = trending.take(10).toList();
        mostWatched = popular.take(10).toList();
      });
    } catch (_) {
    } finally {
      if (mounted) setState(() => isLoadingRecommendations = false);
    }
  }

  @override
  void dispose() {
    _voiceDebounce?.cancel();
    _speechToText.stop();
    _speechToText.cancel();
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _performSearch(String query) async {
    final generation = ++_searchGeneration;
    final trimmedQuery = query.trim();
    if (trimmedQuery.isEmpty) {
      if (!mounted) return;
      setState(() {
        searchResults = [];
        actorResults = [];
      });
      return;
    }

    setState(() => isLoading = true);

    try {
      switch (_currentTabIndex) {
        case 0: // All
          final results = await TmdbApiService.searchAll(trimmedQuery);
          if (!mounted || generation != _searchGeneration) return;
          setState(() {
            searchResults = _applyFilters(results);
            actorResults = results
                .where((item) => item['media_type'] == 'person')
                .toList();
          });
          break;
        case 1: // Movies
          final results = await TmdbApiService.searchMovies(trimmedQuery);
          if (!mounted || generation != _searchGeneration) return;
          setState(() {
            searchResults = _applyFilters(results);
            actorResults = [];
          });
          break;
        case 2: // TV Shows
          final results = await TmdbApiService.searchSeries(trimmedQuery);
          if (!mounted || generation != _searchGeneration) return;
          setState(() {
            searchResults = _applyFilters(results);
            actorResults = [];
          });
          break;
        case 3: // Actors
          final results = await TmdbApiService.searchActors(trimmedQuery);
          if (!mounted || generation != _searchGeneration) return;
          setState(() {
            searchResults = [];
            actorResults = results;
          });
          break;
      }
    } catch (e) {
      // Error searching
    } finally {
      if (mounted && generation == _searchGeneration) {
        setState(() => isLoading = false);
      }
    }
  }

  List<Map<String, dynamic>> _applyFilters(List<Map<String, dynamic>> items) {
    return items.where((item) {
      if (item['media_type'] == 'person') return true;
      // Kids profile: only show kid-friendly content
      if (isKidsProfile && item['media_type'] != 'person') {
        final genreIds =
            (item['genre_ids'] as List<dynamic>?)?.cast<int>() ?? [];
        if (!genreIds.contains(16) && !genreIds.contains(10751)) return false;
      }
      if (_filterGenreId != null) {
        final genreIds =
            (item['genre_ids'] as List<dynamic>?)?.cast<int>() ?? [];
        if (!genreIds.contains(_filterGenreId)) return false;
      }
      if (_filterYearFrom != null || _filterYearTo != null) {
        final dateStr =
            (item['release_date'] ?? item['first_air_date'] ?? '') as String;
        if (dateStr.length >= 4) {
          final year = int.tryParse(dateStr.substring(0, 4));
          if (year != null) {
            if (_filterYearFrom != null && year < _filterYearFrom!) {
              return false;
            }
            if (_filterYearTo != null && year > _filterYearTo!) return false;
          }
        }
      }
      if (_filterRatingMin != null) {
        final rating = (item['vote_average'] ?? 0).toDouble();
        if (rating < _filterRatingMin!) return false;
      }
      return true;
    }).toList();
  }

  void _showFilterSheet() {
    final temp = {
      'genreId': _filterGenreId,
      'genreName': _filterGenreName,
      'yearFrom': _filterYearFrom,
      'yearTo': _filterYearTo,
      'rating': _filterRatingMin,
    };

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.grey[700],
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Filters',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      if (_filtersActive)
                        TextButton(
                          onPressed: () {
                            setSheetState(() {
                              temp['genreId'] = null;
                              temp['genreName'] = null;
                              temp['yearFrom'] = null;
                              temp['yearTo'] = null;
                              temp['rating'] = null;
                            });
                          },
                          child: const Text(
                            'Clear All',
                            style: TextStyle(color: Colors.red, fontSize: 13),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Genre',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 40,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        _buildGenreChip(setSheetState, temp, null, null),
                        ..._genreMap.entries.map(
                          (e) => _buildGenreChip(
                            setSheetState,
                            temp,
                            e.key,
                            e.value,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'Release Year',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: _buildYearField(
                          'From',
                          temp['yearFrom'] as int?,
                          (v) {
                            setSheetState(() => temp['yearFrom'] = v);
                          },
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 12),
                        child: Text(
                          '–',
                          style: TextStyle(color: Colors.grey, fontSize: 18),
                        ),
                      ),
                      Expanded(
                        child: _buildYearField('To', temp['yearTo'] as int?, (
                          v,
                        ) {
                          setSheetState(() => temp['yearTo'] = v);
                        }),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      const Text(
                        'Min Rating',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      if (temp['rating'] != null)
                        Text(
                          '${(temp['rating'] as double).toStringAsFixed(1)}+',
                          style: const TextStyle(
                            color: Colors.red,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  SliderTheme(
                    data: SliderThemeData(
                      activeTrackColor: Colors.red,
                      inactiveTrackColor: Colors.grey[800],
                      thumbColor: Colors.red,
                      overlayColor: Colors.red.withValues(alpha: 0.2),
                    ),
                    child: Slider(
                      value: (temp['rating'] as double?) ?? 0,
                      min: 0,
                      max: 10,
                      divisions: 20,
                      onChanged: (v) {
                        setSheetState(() => temp['rating'] = v == 0 ? null : v);
                      },
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: () {
                        Navigator.pop(ctx);
                        setState(() {
                          _filterGenreId = temp['genreId'] as int?;
                          _filterGenreName = temp['genreName'] as String?;
                          _filterYearFrom = temp['yearFrom'] as int?;
                          _filterYearTo = temp['yearTo'] as int?;
                          _filterRatingMin = temp['rating'] as double?;
                          _filtersActive =
                              _filterGenreId != null ||
                              _filterYearFrom != null ||
                              _filterYearTo != null ||
                              _filterRatingMin != null;
                        });
                        if (_searchController.text.trim().length >= 2) {
                          _performSearch(_searchController.text);
                        }
                      },
                      child: const Text(
                        'Apply Filters',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildGenreChip(
    StateSetter setSheetState,
    Map<String, dynamic> temp,
    int? genreId,
    String? genreName,
  ) {
    final selected = temp['genreId'] == genreId;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: () {
          setSheetState(() {
            if (genreId == null || temp['genreId'] == genreId) {
              temp['genreId'] = null;
              temp['genreName'] = null;
            } else {
              temp['genreId'] = genreId;
              temp['genreName'] = genreName;
            }
          });
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? Colors.red : const Color(0xFF2A2A2A),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected
                  ? Colors.red
                  : Colors.white.withValues(alpha: 0.1),
            ),
          ),
          child: Text(
            genreName ?? 'All',
            style: TextStyle(
              color: selected ? Colors.white : Colors.grey[400],
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildYearField(String hint, int? value, Function(int?) onChanged) {
    return TextFormField(
      keyboardType: TextInputType.number,
      style: const TextStyle(color: Colors.white, fontSize: 14),
      initialValue: value?.toString() ?? '',
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: Colors.grey[600], fontSize: 13),
        filled: true,
        fillColor: const Color(0xFF2A2A2A),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
        ),
      ),
      onChanged: (v) {
        onChanged(int.tryParse(v));
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F0F0F),
        elevation: 0,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(7),
              decoration: BoxDecoration(
                color: Colors.red,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(
                Icons.search_rounded,
                color: Colors.white,
                size: 18,
              ),
            ),
            const SizedBox(width: 10),
            const Text(
              'Search',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: 20,
                letterSpacing: -0.5,
              ),
            ),
          ],
        ),
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 12),
            child: ProfileMenuButton(),
          ),
        ],
      ),
      body: Column(
        children: [
          _buildSearchBar(),
          if (_searchController.text.trim().isNotEmpty) _buildModernTabs(),
          Expanded(
            child: _searchController.text.trim().isEmpty
                ? _buildSearchRecommendations()
                : RefreshIndicator(
                    onRefresh: () => _performSearch(_searchController.text),
                    child: TabBarView(
                      controller: _tabController,
                      children: [
                        _buildAllResults(),
                        _buildMovieResults(),
                        _buildTVResults(),
                        _buildActorResults(),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchRecommendations() {
    if (isLoadingRecommendations) return _buildRecommendationsShimmer();
    if (topSearched.isEmpty && mostWatched.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.search, size: 48, color: Colors.grey[700]),
              const SizedBox(height: 12),
              Text(
                'No recommendations yet',
                style: TextStyle(color: Colors.grey[500]),
              ),
              const SizedBox(height: 8),
              ElevatedButton(
                onPressed: _loadSearchRecommendations,
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
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
    return RefreshIndicator(
      onRefresh: _loadSearchRecommendations,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_searchHistory.isNotEmpty) ...[
              _buildSectionHeader('Recent Searches'),
              SizedBox(
                height: 42,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: _searchHistory.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (context, index) {
                    final item = _searchHistory[index];
                    return GestureDetector(
                      onTap: () {
                        _searchController.text = item;
                        _performSearch(item);
                        setState(() {});
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1E1E1E),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.08),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              item,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(width: 6),
                            GestureDetector(
                              onTap: () => _removeFromHistory(item),
                              child: Icon(
                                Icons.close_rounded,
                                color: Colors.grey[500],
                                size: 14,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
            if (topSearched.isNotEmpty) ...[
              _buildSectionHeader('Top Searched'),
              _buildRecommendationCarousel(topSearched),
            ],
            if (mostWatched.isNotEmpty) ...[
              _buildSectionHeader('Most Watched'),
              _buildRecommendationCarousel(mostWatched),
            ],
            const SizedBox(height: 100),
          ],
        ),
      ),
    );
  }

  Widget _buildRecommendationsShimmer() {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Container(width: 140, height: 18, color: Colors.grey[800]),
          ),
          SizedBox(
            height: 234,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: 5,
              itemBuilder: (_, _) => Container(
                width: 152,
                margin: const EdgeInsets.only(right: 10),
                decoration: BoxDecoration(
                  color: Colors.grey[800],
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Container(width: 140, height: 18, color: Colors.grey[800]),
          ),
          SizedBox(
            height: 234,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: 5,
              itemBuilder: (_, _) => Container(
                width: 152,
                margin: const EdgeInsets.only(right: 10),
                decoration: BoxDecoration(
                  color: Colors.grey[800],
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModernTabs() {
    return Container(
      height: 46,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _searchTabs.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final selected = _currentTabIndex == i;
          return GestureDetector(
            onTap: () {
              _tabController.animateTo(i);
              setState(() => _currentTabIndex = i);
              if (_searchController.text.isNotEmpty) {
                _performSearch(_searchController.text);
              }
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
              decoration: BoxDecoration(
                color: selected ? Colors.red : const Color(0xFF1E1E1E),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: selected
                      ? Colors.red
                      : Colors.white.withValues(alpha: 0.08),
                ),
              ),
              child: Center(
                child: Text(
                  _searchTabs[i],
                  style: TextStyle(
                    color: selected ? Colors.white : Colors.grey[400],
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [const Color(0xFF1E1E1E), const Color(0xFF232323)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: _isListening
                ? Colors.red.withValues(alpha: 0.4)
                : Colors.white.withValues(alpha: 0.09),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.35),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
            BoxShadow(
              color: Colors.red.withValues(alpha: _isListening ? 0.15 : 0.06),
              blurRadius: 20,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _searchController,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                ),
                decoration: InputDecoration(
                  hintText: _isListening
                      ? 'Listening… speak now'
                      : 'Search movies, TV shows, actors…',
                  hintStyle: TextStyle(
                    color: _isListening
                        ? Colors.red[300]
                        : const Color(0xFF6B7280),
                    fontSize: 14,
                    fontWeight: FontWeight.w400,
                  ),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(
                    vertical: 16,
                    horizontal: 16,
                  ),
                ),
                onChanged: (value) {
                  setState(() {});
                  if (value.length >= 2) {
                    _performSearch(value);
                  } else {
                    _searchGeneration++;
                    setState(() {
                      searchResults = [];
                      actorResults = [];
                    });
                  }
                },
                onSubmitted: (v) {
                  final trimmed = v.trim();
                  if (trimmed.length >= 2) {
                    _saveToHistory(trimmed);
                    _performSearch(v);
                  }
                },
              ),
            ),
            if (_searchController.text.isNotEmpty)
              IconButton(
                onPressed: () {
                  _searchGeneration++;
                  _searchController.clear();
                  setState(() {
                    searchResults = [];
                    actorResults = [];
                  });
                },
                icon: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.08),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.close_rounded,
                    color: Colors.grey,
                    size: 14,
                  ),
                ),
                splashRadius: 18,
              ),
            // Mic integrated as part of the same pill — no divider, no separate container
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              margin: const EdgeInsets.only(right: 6),
              decoration: BoxDecoration(
                color: _isListening
                    ? Colors.red
                    : Colors.white.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
              ),
              child: IconButton(
                onPressed: _toggleListening,
                icon: Icon(
                  _isListening ? Icons.mic_rounded : Icons.mic_none_rounded,
                  color: _isListening ? Colors.white : Colors.grey[300],
                  size: 18,
                ),
                splashRadius: 18,
                tooltip: _isListening ? 'Stop listening' : 'Voice search',
                padding: const EdgeInsets.all(8),
                constraints: const BoxConstraints(),
              ),
            ),
            // Filter button
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              margin: const EdgeInsets.only(right: 6),
              decoration: BoxDecoration(
                color: _filtersActive
                    ? Colors.red
                    : Colors.white.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
              ),
              child: IconButton(
                onPressed: _showFilterSheet,
                icon: Icon(
                  Icons.tune_rounded,
                  color: _filtersActive ? Colors.white : Colors.grey[300],
                  size: 18,
                ),
                splashRadius: 18,
                tooltip: 'Filters',
                padding: const EdgeInsets.all(8),
                constraints: const BoxConstraints(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAllResults() {
    if (isLoading) return _buildLoadingIndicator();
    if (searchResults.isEmpty &&
        actorResults.isEmpty &&
        _searchController.text.isNotEmpty) {
      return _buildNoResults();
    }

    final movies = searchResults
        .where((item) => item['media_type'] == 'movie')
        .toList();
    final tvShows = searchResults
        .where((item) => item['media_type'] == 'tv')
        .toList();
    final actors = searchResults
        .where((item) => item['media_type'] == 'person')
        .toList();

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (movies.isNotEmpty) _buildSectionHeader('Movies'),
          if (movies.isNotEmpty) _buildMovieGrid(movies),
          if (tvShows.isNotEmpty) _buildSectionHeader('TV Shows'),
          if (tvShows.isNotEmpty) _buildMovieGrid(tvShows),
          if (actors.isNotEmpty) _buildSectionHeader('Actors'),
          if (actors.isNotEmpty) _buildActorGrid(actors),
          const SizedBox(height: 100),
        ],
      ),
    );
  }

  Widget _buildMovieResults() {
    if (isLoading) return _buildLoadingIndicator();
    if (searchResults.isEmpty && _searchController.text.isNotEmpty) {
      return _buildNoResults();
    }
    return SingleChildScrollView(
      child: Column(
        children: [_buildMovieGrid(searchResults), const SizedBox(height: 100)],
      ),
    );
  }

  Widget _buildTVResults() {
    if (isLoading) return _buildLoadingIndicator();
    if (searchResults.isEmpty && _searchController.text.isNotEmpty) {
      return _buildNoResults();
    }
    return SingleChildScrollView(
      child: Column(
        children: [_buildMovieGrid(searchResults), const SizedBox(height: 100)],
      ),
    );
  }

  Widget _buildActorResults() {
    if (isLoading) return _buildLoadingIndicator();
    if (actorResults.isEmpty && _searchController.text.isNotEmpty) {
      return _buildNoResults();
    }
    return SingleChildScrollView(
      child: Column(
        children: [_buildActorGrid(actorResults), const SizedBox(height: 100)],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    final icon = title == 'Recent Searches'
        ? Icons.history_rounded
        : title == 'Top Searched'
        ? Icons.trending_up_rounded
        : title == 'Most Watched'
        ? Icons.local_fire_department_rounded
        : title == 'Movies'
        ? Icons.movie_rounded
        : title == 'TV Shows'
        ? Icons.tv_rounded
        : Icons.people_rounded;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 10),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 16,
            decoration: BoxDecoration(
              color: Colors.red,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Icon(icon, color: Colors.red, size: 16),
          const SizedBox(width: 6),
          Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 17,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMovieGrid(List<Map<String, dynamic>> items) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        childAspectRatio: 0.62,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        return _buildMovieCard(item, isRecommendation: false);
      },
    );
  }

  Widget _buildRecommendationCarousel(List<Map<String, dynamic>> items) {
    return SizedBox(
      height: 220,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: items.length,
        itemBuilder: (context, index) =>
            _buildRecommendationComingSoonCard(items[index]),
      ),
    );
  }

  Widget _buildRecommendationComingSoonCard(Map<String, dynamic> item) {
    final name = item['title'] ?? item['name'] ?? 'Unknown';
    final backdropPath = item['backdrop_path'];
    final posterPath = item['poster_path'];
    final rating = (item['vote_average'] as num?)?.toDouble();
    final date =
        (item['release_date'] ?? item['first_air_date'])?.toString() ?? '';
    final overview = item['overview']?.toString() ?? '';
    final isTv =
        item['media_type'] == 'tv' || item.containsKey('first_air_date');
    return GestureDetector(
      onTap: () {
        if (!mounted) return;
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => isTv
                ? MaxStreamSeriesScreen(seriesItem: Movie.fromJson(item))
                : MaxStreamDetailsScreen(
                    item: Movie.fromJson(item),
                    mediaType: isTv ? 'tv' : 'movie',
                  ),
          ),
        );
      },
      child: Container(
        width: 300,
        margin: const EdgeInsets.only(right: 12),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (backdropPath != null)
                AppNetworkImage(
                  url: TmdbApiService.getBackdropUrl(backdropPath),
                  fit: BoxFit.cover,
                  errorWidget: _posterFallback(posterPath),
                )
              else
                _posterFallback(posterPath),
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.black.withValues(alpha: 0.88),
                      ],
                      stops: const [0.3, 1.0],
                    ),
                  ),
                ),
              ),
              if (posterPath != null)
                Positioned(
                  left: 12,
                  bottom: 12,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: AppNetworkImage(
                      url: TmdbApiService.getPosterUrl(posterPath),
                      width: 56,
                      height: 82,
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
              Positioned(
                top: 10,
                left: 10,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: isTv ? Colors.teal : Colors.red,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    isTv ? 'TV' : 'MOVIE',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 9,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
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
                      color: Colors.black.withValues(alpha: 0.65),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.12),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.star_rounded,
                          color: Colors.amber,
                          size: 11,
                        ),
                        const SizedBox(width: 3),
                        Text(
                          rating.toStringAsFixed(1),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              Positioned(
                left: posterPath != null ? 80 : 12,
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
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (date.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          const Icon(
                            Icons.calendar_today_rounded,
                            color: Colors.white70,
                            size: 11,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            date.length >= 4 ? date.substring(0, 4) : date,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          if (rating != null && rating > 0) ...[
                            const Text(
                              '  ·  ',
                              style: TextStyle(
                                color: Colors.white38,
                                fontSize: 11,
                              ),
                            ),
                            Text(
                              rating.toStringAsFixed(1),
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 11,
                              ),
                            ),
                          ],
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
                          height: 1.3,
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
        errorWidget: _placeholderBox(),
      );
    }
    return _placeholderBox();
  }

  Widget _placeholderBox() {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.grey[850]!, Colors.grey[900]!],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: const Icon(Icons.movie_rounded, color: Colors.grey, size: 42),
    );
  }

  Widget _buildActorGrid(List<Map<String, dynamic>> actors) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 0.75,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: actors.length,
      itemBuilder: (context, index) {
        final actor = actors[index];
        return _buildActorCard(actor);
      },
    );
  }

  Widget _buildMovieCard(
    Map<String, dynamic> item, {
    bool isRecommendation = false,
  }) {
    final card = GestureDetector(
      onTap: () {
        if (!mounted) return;
        final mediaType =
            item['media_type'] ??
            (item['first_air_date'] != null ? 'tv' : 'movie');
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
                            curve: Curves.easeInOut,
                          ),
                        ),
                    child: child,
                  );
                },
            transitionDuration: const Duration(milliseconds: 300),
          ),
        );
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.25),
                    blurRadius: 8,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Stack(
                  children: [
                    item['poster_path'] != null
                        ? AppNetworkImage(
                            url: TmdbApiService.getPosterUrl(
                              item['poster_path'],
                            ),
                            width: double.infinity,
                            height: double.infinity,
                            fit: BoxFit.cover,
                          )
                        : Container(
                            width: double.infinity,
                            height: double.infinity,
                            color: Colors.grey[800],
                            child: const Icon(
                              Icons.movie,
                              color: Colors.grey,
                              size: 32,
                            ),
                          ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      height: 56,
                      child: Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.transparent,
                              Colors.black.withValues(alpha: 0.75),
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (item['vote_average'] != null &&
                        (item['vote_average'] as num) > 0)
                      Positioned(
                        top: 6,
                        right: 6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.75),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.15),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.star_rounded,
                                color: Colors.amber,
                                size: 11,
                              ),
                              const SizedBox(width: 3),
                              Text(
                                (item['vote_average'] as num).toStringAsFixed(
                                  1,
                                ),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            item['title'] ?? item['name'] ?? 'Unknown',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              height: 1.2,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
    if (isRecommendation) {
      return Container(
        width: 152,
        margin: const EdgeInsets.only(right: 10),
        child: card,
      );
    }
    return card;
  }

  Widget _buildActorCard(Map<String, dynamic> actor) {
    return GestureDetector(
      onTap: () {
        if (!mounted) return;
        Navigator.push(
          context,
          PageRouteBuilder(
            pageBuilder: (context, animation, secondaryAnimation) =>
                ActorDetailsScreen(actorId: actor['id']),
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
                            curve: Curves.easeInOut,
                          ),
                        ),
                    child: child,
                  );
                },
            transitionDuration: const Duration(milliseconds: 300),
          ),
        );
      },
      child: Column(
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: actor['profile_path'] != null
                  ? AppNetworkImage(
                      url: TmdbApiService.getProfileUrl(actor['profile_path']),
                      width: double.infinity,
                      height: double.infinity,
                      fit: BoxFit.cover,
                    )
                  : Container(
                      width: double.infinity,
                      height: double.infinity,
                      color: Colors.grey[800],
                      child: const Icon(
                        Icons.person,
                        color: Colors.grey,
                        size: 40,
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            actor['name'] ?? 'Unknown',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
          if (actor['known_for_department'] != null)
            Text(
              actor['known_for_department'],
              style: const TextStyle(color: Colors.grey, fontSize: 12),
              textAlign: TextAlign.center,
            ),
        ],
      ),
    );
  }

  Widget _buildLoadingIndicator() {
    return const Center(child: SearchLoadingWidget());
  }

  Widget _buildNoResults() {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.search_off, size: 64, color: Colors.grey),
          SizedBox(height: 16),
          Text(
            'No results found',
            style: TextStyle(
              color: Colors.grey,
              fontSize: 18,
              fontWeight: FontWeight.w500,
            ),
          ),
          SizedBox(height: 8),
          Text(
            'Try searching with different keywords',
            style: TextStyle(color: Colors.grey, fontSize: 14),
          ),
        ],
      ),
    );
  }
}
