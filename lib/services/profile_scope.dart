import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../models/profile.dart';
import 'profile_service.dart';

/// Manages the currently active profile across the app.
/// Provides the active profile ID for per-profile data isolation
/// (watch progress, Continue Watching, preferences).
class ProfileScope {
  static const String _defaultProfileSuffix = '__default__';

  static Profile? _activeProfile;
  static List<Profile> _profiles = [];
  static bool _initialized = false;

  /// Shared in-flight initialization, so concurrent callers all await the SAME
  /// future instead of the first one returning early while later ones see a
  /// half-initialized scope. The previous `if (_initialized) return;` guard did
  /// exactly that: a second caller got `null` for [_activeProfile] and silently
  /// built storage keys from the fallback profile ID.
  static Future<void>? _initFuture;

  /// True once [_activeProfile] has been resolved from LOCAL storage, which is
  /// all [currentProfileId] needs to be correct.
  ///
  /// Not the same as "the cloud profile list has arrived" — see [initialize].
  static bool get isReady => _initialized;

  /// Called when the active profile changes (for cloud sync listener restart).
  static void Function()? onProfileChanged;

  /// ValueNotifier that screens can listen to for profile changes.
  static final ValueNotifier<Profile?> activeProfile = ValueNotifier<Profile?>(
    null,
  );

  static final ValueNotifier<List<Profile>> profiles =
      ValueNotifier<List<Profile>>([]);

  /// The active profile ID used as key in SharedPreferences and RTDB.
  /// Falls back to the Firebase UID if no profile is selected (legacy mode).
  ///
  /// WARNING: only meaningful once [isReady] is true (await [ensureInitialized]
  /// first). Before that this can return the Firebase UID instead of the real
  /// profile ID, and every per-profile storage key built from it
  /// (watch history, watchlist, ...) points at the wrong place.
  static String get currentProfileId {
    return _activeProfile?.id ?? _firebaseUid ?? _defaultProfileSuffix;
  }

  /// Whether the current profile is a kids profile.
  static bool get isKidsProfile => _activeProfile?.isKids ?? false;

  /// The active profile name for display.
  static String get currentProfileName =>
      _activeProfile?.name ?? 'Default Profile';

  static String? get _firebaseUid {
    try {
      return FirebaseAuth.instance.currentUser?.uid;
    } catch (_) {
      return null;
    }
  }

  // ── Initialization ─────────────────────────────────────────────────

  /// Resolves the active profile so [currentProfileId] is safe to use, then
  /// kicks off the (slow, networked) cloud reconciliation in the background.
  ///
  /// Safe to call any number of times and from anywhere: every caller awaits
  /// the same future. Prefer this over [initialize] for new call sites.
  static Future<void> ensureInitialized() => _initFuture ??= initialize();

  /// Call once at app start to restore the last-active profile.
  ///
  /// Ordered deliberately in two phases. The local resolve is what makes
  /// [currentProfileId] correct, and it must complete FAST — it is awaited by
  /// the watch-history / watchlist readers. The cloud pull is a network call
  /// that used to run FIRST, so on a cold start with a slow connection every
  /// per-profile key stayed wrong for seconds and the lists came up empty even
  /// though the data was on disk. Cloud data is merged afterwards; if it adds a
  /// profile that changes the selection, [onProfileChanged] fires and listeners
  /// re-read under the correct key.
  static Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    try {
      // ── Phase 1: local only, must stay fast ──────────────────────────
      _profiles = await ProfileService.getProfiles();
      profiles.value = _profiles;

      final savedId = await ProfileService.getActiveProfileId();
      if (savedId != null) {
        _activeProfile = _profiles.where((p) => p.id == savedId).firstOrNull;
      }

      // Auto-select if only one profile
      if (_activeProfile == null && _profiles.length == 1) {
        _activeProfile = _profiles.first;
        await ProfileService.setActiveProfileId(_activeProfile!.id);
      }

      activeProfile.value = _activeProfile;

      // ── Phase 2: network, must not block phase 1 ─────────────────────
      unawaited(_syncFromCloud());
    } catch (e, stack) {
      debugPrint('ProfileScope: initialize failed: $e\n$stack');
      // isReady stays true: a local failure must not leave callers hanging on
      // a future that never completes. currentProfileId degrades to the
      // fallback, which is the same behaviour as before this change.
    }
  }

  /// Pulls profiles from cloud and reconciles the local selection. Runs after
  /// [initialize] has already made [currentProfileId] usable, so a slow or
  /// offline network can no longer blank out the history lists.
  static Future<void> _syncFromCloud() async {
    try {
      final previousId = _activeProfile?.id;
      await ProfileService.pullFromCloud();
      _profiles = await ProfileService.getProfiles();
      profiles.value = _profiles;

      final savedId = await ProfileService.getActiveProfileId();
      final resolved = savedId == null
          ? null
          : _profiles.where((p) => p.id == savedId).firstOrNull;

      // Only adopt the cloud selection when we had none locally. A profile the
      // user deliberately switched to must not be overridden by a stale cloud
      // value.
      if (_activeProfile == null && resolved != null) {
        _activeProfile = resolved;
        activeProfile.value = resolved;
        onProfileChanged?.call();
      } else if (previousId != null && resolved == null) {
        // The local profile vanished from the cloud list (deleted elsewhere).
        // Fall back to the single remaining profile, else the fallback key.
        _activeProfile = _profiles.length == 1 ? _profiles.first : null;
        activeProfile.value = _activeProfile;
        onProfileChanged?.call();
      }
    } catch (e) {
      debugPrint('ProfileScope: cloud profile sync failed: $e');
    }
  }

  // ── Profile Selection ──────────────────────────────────────────────

  static Future<void> selectProfile(String profileId) async {
    final match = _profiles.where((p) => p.id == profileId);
    if (match.isEmpty) return;

    _activeProfile = match.first;
    await ProfileService.setActiveProfileId(profileId);
    activeProfile.value = _activeProfile;
    onProfileChanged?.call();
  }

  /// Refresh profiles from storage (after create/edit/delete).
  static Future<void> refresh() async {
    _profiles = await ProfileService.getProfiles();
    profiles.value = _profiles;

    final savedId = await ProfileService.getActiveProfileId();
    if (savedId != null) {
      _activeProfile = _profiles.where((p) => p.id == savedId).firstOrNull;
      activeProfile.value = _activeProfile;
    }
  }

  /// Clear active profile (on sign out).
  static Future<void> clear() async {
    _activeProfile = null;
    _profiles = [];
    _initialized = false;
    // Drop the memoized future so the next sign-in re-runs initialization
    // instead of awaiting the previous session's completed future.
    _initFuture = null;
    await ProfileService.clearAllProfileData();
    activeProfile.value = null;
    profiles.value = [];
  }

  /// Whether the user needs to select a profile (multiple profiles, none selected).
  static bool get needsProfileSelection {
    return _profiles.length > 1 && _activeProfile == null;
  }

  /// Whether the user has only the default single profile (can skip selection).
  static bool get hasSingleProfile => _profiles.length <= 1;
}
