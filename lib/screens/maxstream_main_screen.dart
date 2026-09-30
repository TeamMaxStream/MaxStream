import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/kids_theme.dart';
import 'maxstream_home_screen.dart';
import 'maxstream_search_screen.dart';
import 'maxstream_series_list_screen.dart';
import 'maxstream_library_screen.dart';
import 'maxstream_recommendations_screen.dart';
import '../services/update_service.dart';
import '../services/notification_permission_service.dart';
import '../services/content_notification_service.dart';
import '../services/recommendation_notification_service.dart';
import '../services/miniplayer_service.dart';
import '../services/biometric_service.dart';
import '../widgets/miniplayer_bar.dart';
import '../widgets/video_player_screen.dart';

class MaxStreamMainScreen extends StatefulWidget {
  const MaxStreamMainScreen({super.key});

  @override
  State<MaxStreamMainScreen> createState() => _MaxStreamMainScreenState();
}

class _MaxStreamMainScreenState extends State<MaxStreamMainScreen>
    with WidgetsBindingObserver {
  int _currentIndex = 0;
  Timer? _updateTimer;
  Timer? _contentCheckTimer;
  Timer? _recommendationTimer;
  bool _checkingForUpdate = false;
  bool _miniplayerActive = false;

  void _onTabChange(int index) {
    setState(() {
      _currentIndex = index;
    });
  }

  void _miniplayerListener() {
    final wasActive = _miniplayerActive;
    final isNowActive = MiniplayerService.instance.isActive;
    if (wasActive != isNowActive && mounted) {
      setState(() => _miniplayerActive = isNowActive);
    }
  }

  @override
  void initState() {
    super.initState();
    _miniplayerActive = MiniplayerService.instance.isActive;
    MiniplayerService.instance.addListener(_miniplayerListener);
    WidgetsBinding.instance.addObserver(this);
    if (!kIsWeb) {
      _initializeServices();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Never let the miniplayer keep audio playing while the app is unseen —
    // the bar is only visible in-foreground, so background playback reads as
    // a phantom "audio with no UI". Full-screen playback is unaffected.
    if (state == AppLifecycleState.paused) {
      MiniplayerService.instance.pauseIfPlaying();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    MiniplayerService.instance.removeListener(_miniplayerListener);
    _updateTimer?.cancel();
    _contentCheckTimer?.cancel();
    _recommendationTimer?.cancel();
    super.dispose();
  }

  Future<void> _initializeServices() async {
    await _checkBiometricLock();
    final autoCheck = await UpdateService.isAutoCheckEnabled();
    if (autoCheck) {
      unawaited(_checkForUpdates());
      _updateTimer = Timer.periodic(
        const Duration(hours: 1),
        (_) => unawaited(_checkForUpdates()),
      );
    }
    _checkNotificationPermission();
    _contentCheckTimer = Timer.periodic(
      const Duration(hours: 6),
      (_) => unawaited(ContentNotificationService.checkAndNotifyNewContent()),
    );
    unawaited(ContentNotificationService.checkAndNotifyNewContent());
    _recommendationTimer = Timer.periodic(
      const Duration(hours: 8),
      (_) => unawaited(RecommendationNotificationService.checkAndNotify()),
    );
    unawaited(RecommendationNotificationService.checkAndNotify());
  }

  Future<void> _checkForUpdates() async {
    if (_checkingForUpdate) return;
    _checkingForUpdate = true;
    try {
      final info = await UpdateService.checkForUpdate();
      if (info == null) return;
      try {
        await UpdateService.checkAndNotify(info: info);
      } catch (error) {
        debugPrint('Could not show update notification: $error');
      }
      if (mounted && UpdateService.reserveUpdateDialog(info.version)) {
        _showUpdateDialog(info);
      }
    } catch (error) {
      debugPrint('Could not check for updates: $error');
    } finally {
      _checkingForUpdate = false;
    }
  }

  Future<void> _checkBiometricLock() async {
    final prefs = await SharedPreferences.getInstance();
    final biometricEnabled = prefs.getBool('biometric_lock') ?? false;
    if (!biometricEnabled || !mounted) return;
    final isAvailable = await BiometricService.canUseBiometric();
    if (!isAvailable || !mounted) {
      // Biometrics no longer available, disable the setting
      await prefs.setBool('biometric_lock', false);
      return;
    }

    // Prompt with a proper dialog instead of just authenticating silently
    final biometrics = await BiometricService.getAvailableBiometrics();
    String reason = 'Unlock MaxStream';
    if (biometrics.contains(BiometricType.face)) {
      reason = 'Scan your face to unlock MaxStream';
    } else if (biometrics.contains(BiometricType.fingerprint)) {
      reason = 'Scan your fingerprint to unlock MaxStream';
    }

    final authenticated = await BiometricService.authenticate(
      reason: reason,
      biometricOnly: false, // Allow PIN fallback
    );

    if (!authenticated && mounted) {
      // Show dialog before closing
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF1A1A1A),
          title: const Text('Authentication Required', style: TextStyle(color: Colors.white)),
          content: const Text(
            'You must authenticate to use MaxStream. Would you like to try again or exit?',
            style: TextStyle(color: Colors.grey),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                SystemNavigator.pop();
              },
              child: const Text('Exit', style: TextStyle(color: Colors.red)),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                _checkBiometricLock(); // Retry
              },
              child: const Text('Retry', style: TextStyle(color: Colors.green)),
            ),
          ],
        ),
      );
    }
  }

  Future<void> _checkNotificationPermission() async {
    final hasRequested =
        await NotificationPermissionService.hasRequestedNotificationPermission();
    final isGranted =
        await NotificationPermissionService.isNotificationPermissionGranted();

    if (!hasRequested && !isGranted && mounted) {
      await Future.delayed(const Duration(milliseconds: 500));
      if (mounted) {
        NotificationPermissionService.showNotificationPermissionDialog(
          context,
          onAllow: () {
            debugPrint('User allowed notifications');
          },
        );
      }
    }
  }

  void _showUpdateDialog(UpdateInfo info) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text('Update to v${info.version}'),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'A new version is available. Would you like to download it?',
                style: TextStyle(fontSize: 14),
              ),
              if (info.changelog.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text(
                  'What\'s New:',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                ),
                const SizedBox(height: 6),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 200),
                  child: SingleChildScrollView(
                    child: Text(
                      info.changelog,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Later'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(context).pop();
              UpdateService.downloadAndInstallUpdate(context, info.downloadUrl);
            },
            child: const Text('Update Now'),
          ),
        ],
      ),
    );
  }

  List<Widget> get _screens => [
    MaxStreamHomeScreen(onTabChange: _onTabChange),
    const MaxStreamRecommendationsScreen(),
    const MaxStreamSearchScreen(),
    const MaxStreamSeriesListScreen(),
    const MaxStreamLibraryScreen(),
  ];

  Widget _buildNavBar() {
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    final icons = [
      Icons.home,
      Icons.explore,
      Icons.search,
      Icons.tv,
      Icons.library_books,
    ];

    return Positioned(
      left: MediaQuery.of(context).size.width * 0.15,
      right: MediaQuery.of(context).size.width * 0.15,
      bottom: bottomPadding + 10,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            height: 52,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.2),
                width: 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: List.generate(icons.length, (i) {
                final isSelected = _currentIndex == i;
                return GestureDetector(
                  onTap: () => setState(() => _currentIndex = i),
                  behavior: HitTestBehavior.opaque,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeInOut,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? KidsTheme.navSelected.withValues(alpha: 0.2)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      icons[i],
                      size: 22,
                      color: isSelected ? KidsTheme.navSelected : KidsTheme.navUnselected,
                    ),
                  ),
                );
              }),
            ),
          ),
        ),
      ),
    );
  }

  void _restoreMiniplayer() {
    final service = MiniplayerService.instance;
    final controller = service.controller;
    if (controller == null) return;

    final title = service.title;
    final tmdbId = service.tmdbId;
    final isMovie = service.isMovie;
    final season = service.season;
    final episode = service.episode;
    final genreIds = service.genreIds;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => buildVideoPlayerScreen(
          title: title,
          tmdbId: tmdbId,
          isMovie: isMovie,
          season: season,
          episode: episode,
          genreIds: genreIds,
        ),
      ),
    );
  }

  void _closeMiniplayer() {
    MiniplayerService.instance.close();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _currentIndex == 0,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _currentIndex != 0) {
          setState(() {
            _currentIndex = 0;
          });
        }
      },
      child: Scaffold(
        extendBody: true,
        body: Stack(
          children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              transitionBuilder: (child, animation) {
                return FadeTransition(opacity: animation, child: child);
              },
              child: _screens[_currentIndex],
            ),
            if (_miniplayerActive)
              Positioned(
                right: 16,
                bottom: MediaQuery.of(context).padding.bottom + 70,
                child: MiniplayerBar(
                  onTap: _restoreMiniplayer,
                  onClose: _closeMiniplayer,
                ),
              ),
            _buildNavBar(),
          ],
        ),
      ),
    );
  }
}
