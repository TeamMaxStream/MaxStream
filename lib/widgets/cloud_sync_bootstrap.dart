import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../services/cloud_sync_service.dart';
import '../services/profile_scope.dart';

/// Starts the cloud sync listener while the user is signed in and stops it
/// when they sign out, on any platform (phone or TV).
class CloudSyncBootstrap extends StatefulWidget {
  final Widget child;

  const CloudSyncBootstrap({super.key, required this.child});

  @override
  State<CloudSyncBootstrap> createState() => _CloudSyncBootstrapState();
}

class _CloudSyncBootstrapState extends State<CloudSyncBootstrap> {
  StreamSubscription<User?>? _authSub;

  @override
  void initState() {
    super.initState();
    // Resolve the active profile BEFORE the first cloud read/write. The RTDB
    // paths and every SharedPreferences key are scoped by
    // ProfileScope.currentProfileId, which returns the Firebase UID instead of
    // the profile ID until this resolves. Starting the listener first wrote the
    // cloud history back under the wrong scope on a cold start.
    unawaited(
      ProfileScope.ensureInitialized().then((_) {
        if (!mounted) return;
        _authSub = FirebaseAuth.instance.authStateChanges().listen((user) {
          if (user != null) {
            CloudSyncService.stopListening();
            CloudSyncService.startListening();
          } else {
            CloudSyncService.stopListening();
          }
        });
        // The cached user may already be set, in which case authStateChanges will
        // not emit again — start sync now rather than waiting for a sign-in event
        // that already happened before this listener was attached.
        if (FirebaseAuth.instance.currentUser != null) {
          CloudSyncService.stopListening();
          CloudSyncService.startListening();
        }
      }),
    );
  }

  @override
  void dispose() {
    _authSub?.cancel();
    CloudSyncService.stopListening();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
