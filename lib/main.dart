import 'dart:async';

import 'firebase_options.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'screens/splash_screen.dart';
import 'services/notification_service.dart';
import 'services/notification_router.dart';
import 'services/download_storage_service.dart';
import 'services/media_download_manager.dart';
import 'services/theme_service.dart';
import 'services/crashlytics_service.dart';
import 'services/memory_service.dart';
import 'widgets/cloud_sync_bootstrap.dart';
import 'widgets/crash_screen.dart';

final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  installGlobalCrashHandlers();
  installMemoryTrimHandler();
  // Surface the previous process's native crash / unexpected exit before the
  // first frame (see checkForNativeCrash in widgets/crash_screen.dart).
  await checkForNativeCrash();
  await checkUnexpectedExit();
  runZonedGuarded(
    () {
      runApp(const CrashReportGate(child: _StartupGate()));
    },
    (error, stack) {
      if (isBenignError(error)) return;
      recordCrash('UncaughtZone', error, stack);
      unawaited(reportCrashlytics('UncaughtZone', error, stack));
    },
  );
}

/// Shows the MaxStream splash immediately and finishes network-backed service
/// initialization in the background, so a slow first launch (e.g. Firebase on a
/// cold start) can never leave the app frozen on the native splash drawable.
class _StartupGate extends StatefulWidget {
  const _StartupGate();

  @override
  State<_StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends State<_StartupGate> {
  Object? _fatal;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      if (Firebase.apps.isEmpty) {
        try {
          await Firebase.initializeApp(
            options: DefaultFirebaseOptions.currentPlatform,
          );
        } on Exception catch (e) {
          // Another isolate/path already initialized Firebase between our
          // isEmpty check and initializeApp — treat this as success.
          if (!e.toString().contains('already exists')) rethrow;
        }
      }

      // Crashlytics captures native crashes (which Dart can never see) and
      // receives fatal Dart errors once initialized.
      await enableCrashlyticsReporting();
      attachCrashlyticsFatalHandlers();

      if (!kIsWeb) await NotificationService().initialize();
      if (!kIsWeb) {
        // Downloads now live in app-specific external storage so the space they
        // use matches what Android's Settings → App storage reports; move any
        // downloads made before that (best effort, never blocks start-up).
        await DownloadStorageService.migrateLegacyDownloads();
        await MediaDownloadManager.instance.initialize();
      }
      await ThemeService.instance.loadTheme();
    } catch (e, stack) {
      recordCrash('Bootstrap', e, stack);
      _fatal = e;
    }
    if (!mounted) return;
    setState(() => _ready = true);
    if (_fatal == null) {
      // Attach the navigator once the first frame is up so notification taps
      // (including cold-start taps) can be routed to the right screen.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        NotificationRouter.registerNavigator(appNavigatorKey);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_fatal != null) return ErrorApp(error: _fatal!);
    if (!_ready) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeService.darkTheme,
        home: const Scaffold(
          backgroundColor: Colors.black,
          body: Center(
            child: CircularProgressIndicator(
              valueColor: AlwaysStoppedAnimation<Color>(Colors.red),
            ),
          ),
        ),
      );
    }
    return const MaxStreamApp();
  }
}

class ErrorApp extends StatelessWidget {
  final Object error;

  const ErrorApp({super.key, required this.error});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Text(
              'Failed to initialize the app:\n$error',
              style: const TextStyle(color: Colors.white, fontSize: 16),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}

class MaxStreamApp extends StatelessWidget {
  const MaxStreamApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MaxStream',
      navigatorKey: appNavigatorKey,
      theme: ThemeService.darkTheme,
      themeMode: ThemeMode.dark,
      debugShowCheckedModeBanner: false,
      // Clamp system font scaling (e.g. Honor MagicOS / Android 16) to avoid
      // RenderFlex overflows on small viewports when users set 150-200% text
      // zoom. The 1.3 max is recommended by Gemini analysis for this crash.
      builder: (context, child) {
        final mq = MediaQuery.of(context);
        final clamped = mq.textScaler.clamp(
          minScaleFactor: 0.8,
          maxScaleFactor: 1.3,
        );
        if (clamped == mq.textScaler) return child!;
        return MediaQuery(
          data: mq.copyWith(textScaler: clamped),
          child: child!,
        );
      },
      home: const CloudSyncBootstrap(child: AuthGate()),
    );
  }
}

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    // The SplashScreen always plays first (logo + loading animation) and routes
    // to the right screen after the auth session settles, so the MaxStream logo
    // is visible on every launch whether or not the user is signed in.
    return const SplashScreen();
  }
}
