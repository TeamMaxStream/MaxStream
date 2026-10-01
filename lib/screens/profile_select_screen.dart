import 'dart:async';

import 'package:flutter/material.dart';

import '../models/profile.dart';
import '../services/profile_scope.dart';
import '../services/profile_service.dart';
import '../services/tmdb_api_service.dart';
import 'maxstream_main_screen.dart';
import 'profile_create_screen.dart';

const _heroCycleDuration = Duration(seconds: 5);
const _heroCrossfadeDuration = Duration(milliseconds: 800);

class _HeroItem {
  final String imageUrl;
  final String title;
  final String subtitle;
  final bool isSeries;

  const _HeroItem({
    required this.imageUrl,
    required this.title,
    required this.subtitle,
    required this.isSeries,
  });
}

class ProfileSelectScreen extends StatefulWidget {
  final bool isLaunchScreen;

  const ProfileSelectScreen({super.key, this.isLaunchScreen = true});

  @override
  State<ProfileSelectScreen> createState() => _ProfileSelectScreenState();
}

class _ProfileSelectScreenState extends State<ProfileSelectScreen> {
  List<Profile> _profiles = [];
  bool _isLoading = true;

  // Hero carousel state
  List<_HeroItem> _heroItems = [];
  int _heroIndex = 0;
  bool _heroVisible = true;
  Timer? _heroTimer;

  @override
  void initState() {
    super.initState();
    _loadProfiles();
    _loadHeroContent();
  }

  @override
  void dispose() {
    _heroTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadProfiles() async {
    // ensureInitialized (not initialize): this screen and CloudSyncBootstrap
    // both need the profile resolved, and concurrent callers must await the
    // same in-flight future rather than a second initialize() call returning
    // early on a half-resolved scope.
    await ProfileScope.ensureInitialized();
    final profiles = ProfileScope.profiles.value;
    if (!mounted) return;

    setState(() {
      _profiles = profiles;
      _isLoading = false;
    });
  }

  Future<void> _loadHeroContent() async {
    try {
      final results = await Future.wait([
        TmdbApiService.fetchTrendingMovies(),
        TmdbApiService.fetchTrendingSeries(),
      ]);
      final movies = results[0];
      final series = results[1];

      final items = <_HeroItem>[];

      for (final m in movies) {
        final backdrop = m['backdrop_path'];
        if (backdrop == null) continue;
        items.add(_HeroItem(
          imageUrl: 'https://image.tmdb.org/t/p/w1280$backdrop',
          title: m['title']?.toString() ?? '',
          subtitle: _movieSubtitle(m),
          isSeries: false,
        ));
      }

      for (final s in series) {
        final backdrop = s['backdrop_path'];
        if (backdrop == null) continue;
        items.add(_HeroItem(
          imageUrl: 'https://image.tmdb.org/t/p/w1280$backdrop',
          title: s['name']?.toString() ?? '',
          subtitle: _seriesSubtitle(s),
          isSeries: true,
        ));
      }

      items.shuffle();
      if (!mounted) return;
      setState(() => _heroItems = items.take(12).toList());
      _startHeroCycle();
    } catch (_) {}
  }

  String _movieSubtitle(Map<String, dynamic> m) {
    final year = (m['release_date'] ?? '').toString().substring(0, 4);
    if (year.length >= 4) return 'Movie · $year';
    return 'Movie';
  }

  String _seriesSubtitle(Map<String, dynamic> s) {
    final seasons = s['number_of_seasons'];
    if (seasons != null && seasons is int && seasons > 0) {
      return 'Series · Season $seasons';
    }
    return 'Series';
  }

  void _startHeroCycle() {
    _heroTimer?.cancel();
    if (_heroItems.length < 2) return;
    _heroTimer = Timer.periodic(_heroCycleDuration, (_) {
      if (!mounted) return;
      setState(() => _heroVisible = false);
      Future.delayed(_heroCrossfadeDuration, () {
        if (!mounted) return;
        setState(() {
          _heroIndex = (_heroIndex + 1) % _heroItems.length;
          _heroVisible = true;
        });
      });
    });
  }

  void _goToMain() {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const MaxStreamMainScreen()),
    );
  }

  void _selectProfile(Profile profile) async {
    await ProfileScope.selectProfile(profile.id);
    if (widget.isLaunchScreen) {
      _goToMain();
    } else {
      if (mounted) Navigator.pop(context);
    }
  }

  void _editProfile(Profile profile) async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ProfileCreateScreen(editProfile: profile),
      ),
    );
    if (result == true) {
      await ProfileScope.refresh();
      setState(() => _profiles = ProfileScope.profiles.value);
    }
  }

  void _addProfile() async {
    if (_profiles.length >= ProfileService.maxProfiles) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Maximum ${ProfileService.maxProfiles} profiles allowed.'),
          backgroundColor: Colors.red.shade700,
        ),
      );
      return;
    }

    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const ProfileCreateScreen()),
    );
    if (result == true) {
      await ProfileScope.refresh();
      setState(() => _profiles = ProfileScope.profiles.value);
    }
  }

  void _deleteProfile(Profile profile) async {
    if (_profiles.length <= 1) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1C1C1E),
        title: Text(
          'Delete ${profile.name}?',
          style: const TextStyle(color: Colors.white),
        ),
        content: Text(
          'This will remove the profile and its watch progress.',
          style: TextStyle(color: Colors.white.withValues(alpha: 0.7)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await ProfileService.deleteProfile(profile.id);
      await ProfileScope.refresh();
      setState(() => _profiles = ProfileScope.profiles.value);
    }
  }

  @override
  Widget build(BuildContext context) {
    final heroItem = _heroItems.isNotEmpty
        ? _heroItems[_heroIndex % _heroItems.length]
        : null;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Hero background — use w780 for crisp display on tablets
          if (heroItem != null)
            AnimatedOpacity(
              opacity: _heroVisible ? 1.0 : 0.0,
              duration: _heroCrossfadeDuration,
              child: Image.network(
                heroItem.imageUrl,
                fit: BoxFit.cover,
                width: double.infinity,
                height: double.infinity,
                errorBuilder: (_, __, ___) => const SizedBox(),
              ),
            ),

          // Dark gradient overlay
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.2),
                  Colors.black.withValues(alpha: 0.5),
                  Colors.black.withValues(alpha: 0.85),
                  Colors.black,
                ],
                stops: const [0.0, 0.3, 0.7, 1.0],
              ),
            ),
          ),

          // Content
          SafeArea(
            child: Column(
              children: [
                const SizedBox(height: 40),

                // Hero info overlay — title, subtitle, branding
                if (heroItem != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // MaxStream branding
                        Text(
                          'MaxStream',
                          style: TextStyle(
                            color: Colors.red.shade600,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1.5,
                          ),
                        ),
                        const SizedBox(height: 8),
                        // Title
                        Text(
                          heroItem.title,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        // Subtype + season info
                        Text(
                          heroItem.subtitle,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.7),
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ),

                const Spacer(),

                // Logo
                Image.asset(
                  'assets/images/maxstream_logo.png',
                  width: 70,
                  errorBuilder: (_, __, ___) => const Icon(
                    Icons.play_circle_fill,
                    size: 70,
                    color: Colors.red,
                  ),
                ),
                const SizedBox(height: 16),

                const Text(
                  "Who's watching?",
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 24),

                // Profile grid
                Expanded(
                  child: _isLoading
                      ? const Center(
                          child: CircularProgressIndicator(color: Colors.red),
                        )
                      : _buildProfileGrid(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProfileGrid() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        children: [
          Expanded(
            child: GridView.builder(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 24,
                crossAxisSpacing: 24,
                childAspectRatio: 0.85,
              ),
              itemCount: _profiles.length + 1,
              itemBuilder: (context, index) {
                if (index < _profiles.length) {
                  return _buildProfileCard(_profiles[index]);
                }
                return _buildAddProfileCard();
              },
            ),
          ),
          if (_profiles.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 40),
              child: Text(
                'Tap a profile to start watching',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.5),
                  fontSize: 14,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildProfileCard(Profile profile) {
    final avatarColor = profile.avatar.color;
    final avatarIcon = profile.avatar.icon;

    return GestureDetector(
      onTap: () => _selectProfile(profile),
      onLongPress: () => _showProfileOptions(profile),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 100,
            height: 100,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: avatarColor,
              boxShadow: [
                BoxShadow(
                  color: avatarColor.withValues(alpha: 0.4),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Icon(
              avatarIcon,
              color: Colors.white,
              size: 44,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            profile.name,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (profile.isKids)
            Container(
              margin: const EdgeInsets.only(top: 4),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.green.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text(
                'KIDS',
                style: TextStyle(
                  color: Colors.green,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildAddProfileCard() {
    return GestureDetector(
      onTap: _addProfile,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 100,
            height: 100,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: Colors.white24,
                width: 2,
              ),
              color: Colors.white.withValues(alpha: 0.05),
            ),
            child: Icon(
              Icons.add,
              color: Colors.white.withValues(alpha: 0.5),
              size: 40,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Add Profile',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.5),
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }

  void _showProfileOptions(Profile profile) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit, color: Colors.white),
              title: const Text('Edit Profile',
                  style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(ctx);
                _editProfile(profile);
              },
            ),
            if (_profiles.length > 1)
              ListTile(
                leading: const Icon(Icons.delete, color: Colors.red),
                title: const Text('Delete Profile',
                    style: TextStyle(color: Colors.red)),
                onTap: () {
                  Navigator.pop(ctx);
                  _deleteProfile(profile);
                },
              ),
            ListTile(
              leading: const Icon(Icons.close, color: Colors.white54),
              title: const Text('Cancel',
                  style: TextStyle(color: Colors.white54)),
              onTap: () => Navigator.pop(ctx),
            ),
          ],
        ),
      ),
    );
  }
}
