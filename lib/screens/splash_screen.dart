import 'package:flutter/material.dart';
import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'profile_select_screen.dart';
import 'sign_in_screen.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );
    _animation = CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeIn,
    );

    _animationController.forward();

    _navigateToNextScreen();
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  void _navigateToNextScreen() async {
    try {
      final auth = FirebaseAuth.instance;

      // Instant check — if Firebase already has a cached user, skip the stream.
      final cachedUser = auth.currentUser;

      // Minimum splash display time (short so the logo flashes briefly).
      final minimumDelay = Future<void>.delayed(
        const Duration(milliseconds: 1500),
      );

      User? user = cachedUser;

      if (user == null) {
        // No cached session — wait for Firebase to restore one (up to 5s).
        user = await auth.authStateChanges().first.timeout(
          const Duration(seconds: 5),
          onTimeout: () => null,
        );
      }

      // Ensure the minimum splash duration has elapsed.
      await minimumDelay;

      if (!mounted) return;

      debugPrint(
        "SplashScreen: User is ${user == null ? 'not signed in' : 'signed in'}",
      );

      if (user == null) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (context) => const SignInScreen()),
        );
      } else {
        // Signed in → profile selection (auto-skips if single profile)
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const ProfileSelectScreen()),
        );
      }
    } catch (e) {
      debugPrint("SplashScreen Error: $e");
      if (!mounted) return;

      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (context) => const SignInScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: FadeTransition(
          opacity: _animation,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Image.asset(
                'assets/images/maxstream_logo.png',
                width: 150,
                errorBuilder: (context, error, stackTrace) {
                  return const Icon(
                    Icons.play_circle_fill,
                    size: 150,
                    color: Colors.red,
                  );
                },
              ),
              const SizedBox(height: 20),
              const CircularProgressIndicator(
                valueColor: AlwaysStoppedAnimation<Color>(Colors.red),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
