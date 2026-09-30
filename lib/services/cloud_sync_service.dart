import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

import '../database/db_helper.dart';
import '../models/movie.dart';
import '../models/subtitle_settings.dart';
import 'media_download_manager.dart';
import 'miniplayer_service.dart';
import 'profile_scope.dart';
import 'profile_service.dart';
import 'watch_history_service.dart';

/// Syncs a user's watch history and watchlist between devices through
/// Firebase Realtime Database. Writes on any device push the activity to the
/// user's node, and a real-time listener (see [startListening]) mirrors every
/// cloud change back into local storage so all signed-in devices stay in sync.
class CloudSyncService {
  static final FirebaseDatabase _rtdb = FirebaseDatabase.instance;

  static bool _pullInProgress = false;
  static bool _listening = false;
  static Set<String>? _lastCloudKeys;
  static StreamSubscription<DatabaseEvent>? _historySub;
  static StreamSubscription<DatabaseEvent>? _watchlistSub;
  static StreamSubscription<DatabaseEvent>? _prefsSub;
  static StreamSubscription<DatabaseEvent>? _subtitlePrefsSub;
  static StreamSubscription<DatabaseEvent>? _profilesSub;

  /// Bumped whenever synced watch history changes; screens listen to refresh.
  static final ValueNotifier<int> historyRevision = ValueNotifier<int>(0);

  /// Bumped whenever synced watchlist changes; screens listen to refresh.
  static final ValueNotifier<int> watchlistRevision = ValueNotifier<int>(0);

  /// Bumped whenever provider prefs change.
  static final ValueNotifier<int> prefsRevision = ValueNotifier<int>(0);

  /// Bumped whenever subtitle settings change.
  static final ValueNotifier<int> subtitlePrefsRevision = ValueNotifier<int>(0);

  /// Bumped whenever profiles change (cross-device sync).
  static final ValueNotifier<int> profilesRevision = ValueNotifier<int>(0);

  static String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  static DatabaseReference _watchHistoryRef(String uid, String profileId) =>
      _rtdb.ref('users/$uid/profiles/$profileId/watch_history');

  static DatabaseReference _watchlistRef(String uid, String profileId) =>
      _rtdb.ref('users/$uid/profiles/$profileId/watchlist');

  static DatabaseReference _prefsRef(String uid) =>
      _rtdb.ref('users/$uid/provider_preferences');

  static DatabaseReference _subtitlePrefsRef(String uid) =>
      _rtdb.ref('users/$uid/user_preferences/subtitle_settings');

  static DatabaseReference _profilesRef(String uid) =>
      _rtdb.ref('users/$uid/profiles');

  /// Deterministic doc id for a watch-history item. Keep in sync with
  /// WatchHistoryService.getWatchHistoryKey.
  static String watchHistoryKey(
    String tmdbId,
    bool isMovie,
    int season,
    int episode,
  ) {
    return isMovie ? 'movie_$tmdbId' : 'tv_${tmdbId}_${season}_$episode';
  }

  static String watchlistKey(String id, String mediaType) => '${id}_$mediaType';

  // ---------------------------------------------------------------------
  // Real-time listener
  // ---------------------------------------------------------------------

  /// Subscribes to the signed-in user's cloud nodes and mirrors
  /// changes into local storage. No-op if already listening or signed out.
  /// Uploads the device's entire local watchlist to the cloud. This backfills
  /// items that were added before cloud sync existed (or while the other device
  /// was offline) so they appear on every signed-in device, not just items
  /// added after the sync feature was enabled. Idempotent (upsert by key).
  static Future<void> pushEntireWatchlist() async {
    final uid = _uid;
    if (uid == null) return;
    try {
      final items = await DBHelper.getWatchlist();
      for (final movie in items) {
        await pushWatchlist(movie);
      }
    } catch (e) {
      debugPrint('CloudSync: backfill watchlist failed: $e');
    }
  }

  static void startListening() {
    final uid = _uid;
    if (uid == null || _listening) return;
    _listening = true;
    // Register profile-change callback to restart listeners
    ProfileScope.onProfileChanged = () {
      restartListeners();
      MediaDownloadManager.instance.onProfileChanged();
      // Stop and dispose any minimized playback: it belongs to the profile
      // that was active before the switch.
      MiniplayerService.instance.close();
    };
    // Backfill any pre-existing local watchlist entries to the cloud as soon
    // as we're signed in, so other devices can pull them.
    unawaited(pushEntireWatchlist());
    final profileId = ProfileScope.currentProfileId;
    _historySub = _watchHistoryRef(uid, profileId).onValue.listen(
      _onHistoryEvent,
      onError: (Object e) =>
          debugPrint('CloudSync: history listener error: $e'),
    );
    _watchlistSub = _watchlistRef(uid, profileId).onValue.listen(
      _onWatchlistEvent,
      onError: (Object e) =>
          debugPrint('CloudSync: watchlist listener error: $e'),
    );
    _prefsSub = _prefsRef(uid).onValue.listen(
      _onPrefsEvent,
      onError: (Object e) => debugPrint('CloudSync: prefs listener error: $e'),
    );
    _subtitlePrefsSub = _subtitlePrefsRef(uid).onValue.listen(
      _onSubtitlePrefsEvent,
      onError: (Object e) =>
          debugPrint('CloudSync: subtitle prefs listener error: $e'),
    );
    _profilesSub = _profilesRef(uid).onValue.listen(
      _onProfilesEvent,
      onError: (Object e) =>
          debugPrint('CloudSync: profiles listener error: $e'),
    );
  }

  /// Cancels the real-time subscriptions.
  static void stopListening() {
    _historySub?.cancel();
    _watchlistSub?.cancel();
    _prefsSub?.cancel();
    _subtitlePrefsSub?.cancel();
    _profilesSub?.cancel();
    _historySub = null;
    _watchlistSub = null;
    _prefsSub = null;
    _subtitlePrefsSub = null;
    _profilesSub = null;
    _listening = false;
    ProfileScope.onProfileChanged = null;
  }

  /// Restarts listeners for the current profile (call after profile switch).
  static void restartListeners() {
    stopListening();
    startListening();
  }

  static void _onHistoryEvent(DatabaseEvent event) {
    final snapshot = event.snapshot;
    if (snapshot.value == null) return;
    // Guard: capture the profile ID at the time this event was received.
    // If it differs from the current profile (profile switched mid-listener),
    // discard the event to prevent cross-profile data contamination.
    final profileId = ProfileScope.currentProfileId;
    final data = Map<String, dynamic>.from(snapshot.value as Map);

    for (final entry in data.entries) {
      final value = Map<String, dynamic>.from(entry.value as Map);
      final tmdbId = (value['tmdbId'] ?? '').toString();
      if (tmdbId.isEmpty) continue;
      unawaited(WatchHistoryService.importWatchProgress(value));
    }
    // Only bump revision if profile hasn't changed during import.
    if (ProfileScope.currentProfileId == profileId) {
      historyRevision.value++;
    }
  }

  static void _onWatchlistEvent(DatabaseEvent event) {
    final snapshot = event.snapshot;
    final data = snapshot.value != null
        ? Map<String, dynamic>.from(snapshot.value as Map)
        : <String, dynamic>{};

    final cloudKeys = <String>{};
    for (final entry in data.entries) {
      final value = Map<String, dynamic>.from(entry.value as Map);
      final id = (value['id'] ?? '').toString();
      if (id.isEmpty) continue;
      final mediaType = value['mediaType']?.toString() ?? 'movie';
      cloudKeys.add(watchlistKey(id, mediaType));
      unawaited(DBHelper.importWatchlist(_movieFromData(value)));
    }

    // Reconcile deletions: an item present in the previous cloud snapshot
    // but absent now was removed on another device — delete it locally.
    final previousKeys = _lastCloudKeys;
    if (previousKeys != null) {
      unawaited(_removeStaleWatchlistItems(cloudKeys, previousKeys));
    }
    _lastCloudKeys = cloudKeys;
    watchlistRevision.value++;
  }

  static Future<void> _removeStaleWatchlistItems(
    Set<String> cloudKeys,
    Set<String> previousKeys,
  ) async {
    final localItems = await DBHelper.getWatchlist();
    for (final movie in localItems) {
      final key = watchlistKey(movie.id, movie.mediaType);
      if (previousKeys.contains(key) && !cloudKeys.contains(key)) {
        await DBHelper.removeMovieLocal(movie.id, movie.mediaType);
      }
    }
  }

  static void _onPrefsEvent(DatabaseEvent event) {
    final snapshot = event.snapshot;
    if (snapshot.value == null) return;
    final data = Map<String, dynamic>.from(snapshot.value as Map);
    for (final entry in data.entries) {
      final value = Map<String, dynamic>.from(entry.value as Map);
      final pid = (value['providerId'] as num?)?.toInt();
      if (pid == null) continue;
      final isPref = value['isPreferred'] == true || value['isPreferred'] == 1;
      unawaited(
        DBHelper.setProviderPreference(pid, isPref, pushToCloud: false),
      );
    }
    prefsRevision.value++;
  }

  static void _onSubtitlePrefsEvent(DatabaseEvent event) {
    final snapshot = event.snapshot;
    if (snapshot.value == null) return;
    final data = Map<String, dynamic>.from(snapshot.value as Map);
    unawaited(SubtitleSettings.saveFromJson(data));
    subtitlePrefsRevision.value++;
  }

  static void _onProfilesEvent(DatabaseEvent event) {
    // When profiles change on another device, pull them locally.
    // ProfileScope.refresh() is called so the UI picks up changes.
    profilesRevision.value++;
    unawaited(
      ProfileService.pullFromCloud().then((_) => ProfileScope.refresh()),
    );
  }

  // ---------------------------------------------------------------------
  // Push (called from phone/TV write paths)
  // ---------------------------------------------------------------------

  static Future<void> pushWatchProgress(Map<String, dynamic> item) async {
    final uid = _uid;
    final tmdbId = (item['tmdbId'] ?? '').toString();
    if (uid == null || tmdbId.isEmpty || tmdbId == '0') return;
    final profileId = ProfileScope.currentProfileId;
    final key = watchHistoryKey(
      tmdbId,
      item['isMovie'] == true,
      (item['season'] as num?)?.toInt() ?? 0,
      (item['episode'] as num?)?.toInt() ?? 0,
    );
    try {
      // Always write the entry — even when isWatched=true.
      // The receiving platform imports it and the isWatched flag causes
      // getContinueWatching() to filter it out (no stale entries left behind).
      await _watchHistoryRef(
        uid,
        profileId,
      ).child(key).set({...item, 'updatedAt': ServerValue.timestamp});
    } catch (e) {
      debugPrint('CloudSync: watch progress push failed: $e');
    }
  }

  static Future<void> deleteWatchProgress(
    String tmdbId,
    bool isMovie,
    int season,
    int episode,
  ) async {
    final uid = _uid;
    if (uid == null || tmdbId.isEmpty) return;
    final profileId = ProfileScope.currentProfileId;
    try {
      await _watchHistoryRef(
        uid,
        profileId,
      ).child(watchHistoryKey(tmdbId, isMovie, season, episode)).remove();
    } catch (e) {
      debugPrint('CloudSync: watch progress delete failed: $e');
    }
  }

  static Future<void> pushWatchlist(Movie movie) async {
    final uid = _uid;
    if (uid == null || movie.id.isEmpty || movie.id == '0') return;
    final profileId = ProfileScope.currentProfileId;
    try {
      await _watchlistRef(
        uid,
        profileId,
      ).child(watchlistKey(movie.id, movie.mediaType)).set({
        'id': movie.id,
        'title': movie.title,
        'description': movie.description,
        'thumbnail': movie.thumbnail,
        'backdrop': movie.backdrop,
        'videoUrl': movie.videoUrl,
        'trailerUrl': movie.trailerUrl,
        'genres': movie.genres,
        'year': movie.year,
        'rating': movie.rating,
        'mediaType': movie.mediaType,
        'country': movie.country,
        'updatedAt': ServerValue.timestamp,
      });
    } catch (e) {
      debugPrint('CloudSync: watchlist push failed: $e');
    }
  }

  static Future<void> deleteWatchlist(String id, String mediaType) async {
    final uid = _uid;
    if (uid == null || id.isEmpty) return;
    final profileId = ProfileScope.currentProfileId;
    try {
      await _watchlistRef(
        uid,
        profileId,
      ).child(watchlistKey(id, mediaType)).remove();
    } catch (e) {
      debugPrint('CloudSync: watchlist delete failed: $e');
    }
  }

  static Future<void> pushProviderPreference(
    int providerId,
    String providerName,
    bool isPreferred,
  ) async {
    final uid = _uid;
    if (uid == null) return;
    try {
      await _prefsRef(uid).child(providerId.toString()).set({
        'providerId': providerId,
        'providerName': providerName,
        'isPreferred': isPreferred,
        'updatedAt': ServerValue.timestamp,
      });
    } catch (e) {
      debugPrint('CloudSync: prefs push failed: $e');
    }
  }

  static Future<void> pushAllProviderPrefs() async {
    final uid = _uid;
    if (uid == null) return;
    try {
      final prefs = await DBHelper.getProviderPreferences();
      for (final row in prefs) {
        final pid = row['providerId'] as int;
        final name = row['providerName']?.toString() ?? '';
        final isPref = (row['isPreferred'] as int) == 1;
        await _prefsRef(uid).child(pid.toString()).set({
          'providerId': pid,
          'providerName': name,
          'isPreferred': isPref,
          'updatedAt': ServerValue.timestamp,
        });
      }
    } catch (e) {
      debugPrint('CloudSync: pushAllPrefs failed: $e');
    }
  }

  static Future<void> pushSubtitleSettings() async {
    final uid = _uid;
    if (uid == null) return;
    try {
      final settings = await SubtitleSettings.load();
      await _subtitlePrefsRef(
        uid,
      ).set({...settings.toJson(), 'updatedAt': ServerValue.timestamp});
    } catch (e) {
      debugPrint('CloudSync: subtitle prefs push failed: $e');
    }
  }

  // ---------------------------------------------------------------------
  // Pull (called on TV sign-in / home + watchlist loads)
  // ---------------------------------------------------------------------

  /// Pulls the signed-in user's cloud data into local storage. Safe to call
  /// repeatedly; concurrent pulls are collapsed into one.
  static Future<void> pullToDevice() async {
    final uid = _uid;
    if (uid == null || _pullInProgress) return;
    _pullInProgress = true;
    try {
      final profileId = ProfileScope.currentProfileId;
      final historySnap = await _watchHistoryRef(uid, profileId).get();
      // Guard: if profile changed during the async fetch, abort.
      if (ProfileScope.currentProfileId != profileId) return;
      if (historySnap.value != null) {
        final data = Map<String, dynamic>.from(historySnap.value as Map);
        for (final entry in data.entries) {
          final value = Map<String, dynamic>.from(entry.value as Map);
          await WatchHistoryService.importWatchProgress(value);
        }
      }

      final watchlistSnap = await _watchlistRef(uid, profileId).get();
      // Guard: if profile changed during the async fetch, abort.
      if (ProfileScope.currentProfileId != profileId) return;
      if (watchlistSnap.value != null) {
        final data = Map<String, dynamic>.from(watchlistSnap.value as Map);
        final cloudKeys = <String>{};
        for (final entry in data.entries) {
          final value = Map<String, dynamic>.from(entry.value as Map);
          final id = (value['id'] ?? '').toString();
          if (id.isEmpty) continue;
          final mediaType = value['mediaType']?.toString() ?? 'movie';
          cloudKeys.add(watchlistKey(id, mediaType));
          await DBHelper.importWatchlist(_movieFromData(value));
        }
        // Reconcile deletions: remove local items that were in the cloud
        // during the previous pull but are absent now.
        final previousKeys = _lastCloudKeys;
        if (previousKeys != null) {
          await _removeStaleWatchlistItems(cloudKeys, previousKeys);
        }
        _lastCloudKeys = cloudKeys;
      } else if (_lastCloudKeys != null) {
        // Cloud watchlist is now empty — clear all previously-synced items.
        await _removeStaleWatchlistItems(<String>{}, _lastCloudKeys!);
        _lastCloudKeys = <String>{};
      }

      final prefsSnap = await _prefsRef(uid).get();
      if (prefsSnap.value != null) {
        final data = Map<String, dynamic>.from(prefsSnap.value as Map);
        for (final entry in data.entries) {
          final value = Map<String, dynamic>.from(entry.value as Map);
          final pid = (value['providerId'] as num?)?.toInt();
          if (pid == null) continue;
          final isPref =
              value['isPreferred'] == true || value['isPreferred'] == 1;
          await DBHelper.setProviderPreference(pid, isPref, pushToCloud: false);
        }
      }

      final subtitlePrefsSnap = await _subtitlePrefsRef(uid).get();
      if (subtitlePrefsSnap.value != null) {
        final data = Map<String, dynamic>.from(subtitlePrefsSnap.value as Map);
        await SubtitleSettings.saveFromJson(data);
      }
    } catch (e) {
      debugPrint('CloudSync: pull failed: $e');
    } finally {
      _pullInProgress = false;
    }
  }

  static Movie _movieFromData(Map<String, dynamic> data) {
    final rawGenres = data['genres'];
    final genres = rawGenres is List
        ? rawGenres.map((g) => g.toString()).toList()
        : (rawGenres?.toString() ?? '')
              .split(',')
              .where((g) => g.isNotEmpty)
              .toList();
    return Movie(
      id: (data['id'] ?? '').toString(),
      title: data['title']?.toString() ?? '',
      description: data['description']?.toString() ?? '',
      thumbnail: data['thumbnail']?.toString() ?? '',
      backdrop: data['backdrop']?.toString() ?? '',
      videoUrl: data['videoUrl']?.toString() ?? '',
      trailerUrl: data['trailerUrl']?.toString() ?? '',
      genres: genres,
      year: data['year']?.toString() ?? '',
      rating: (data['rating'] as num?)?.toDouble() ?? 0.0,
      mediaType: data['mediaType']?.toString() ?? 'movie',
      country: data['country']?.toString() ?? '',
    );
  }
}
