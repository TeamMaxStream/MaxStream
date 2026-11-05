import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../models/movie.dart';
import '../screens/maxstream_details_screen.dart';
import '../screens/maxstream_series_screen.dart';
import 'tmdb_api_service.dart';
import 'update_service.dart';

/// Central handler for notification taps. Dispatches by payload prefix and
/// navigates using a global navigator key, so it works from the phone's
/// notification panel regardless of which screen is currently visible.
class NotificationRouter {
  static GlobalKey<NavigatorState>? navigatorKey;
  static String? _pendingPayload;

  /// Called once the root navigator is attached (after the first frame).
  static void registerNavigator(GlobalKey<NavigatorState> key) {
    navigatorKey = key;
    final pending = _pendingPayload;
    _pendingPayload = null;
    if (pending != null) _openPayload(pending);
  }

  /// Entry point wired into flutter_local_notifications.
  static void handleTap(NotificationResponse response) {
    final payload = response.payload;
    if (payload == null || payload.isEmpty) return;
    if (navigatorKey?.currentContext == null) {
      _pendingPayload = payload;
      return;
    }
    _openPayload(payload);
  }

  static Future<void> _openPayload(String payload) async {
    if (payload.startsWith('update:')) {
      final context = navigatorKey?.currentContext;
      if (context == null || !context.mounted) return;
      // New payloads are `update:<apkUrl>|<checksumUrl>`. Notifications
      // posted by older app versions carry only the APK URL.
      final parts = payload.substring('update:'.length).split('|');
      final url = parts.first;
      final checksumUrl = parts.length > 1 && parts[1].isNotEmpty
          ? parts[1]
          : null;
      UpdateService.downloadAndInstallUpdate(
        context,
        url,
        checksumUrl: checksumUrl,
      );
      return;
    }

    if (payload.startsWith('content:')) {
      // Only open details screens once the user is signed in.
      if (FirebaseAuth.instance.currentUser == null) return;
      final context = navigatorKey?.currentContext;
      if (context == null || !context.mounted) return;
      final parts = payload.split(':');
      if (parts.length < 3) return;
      final mediaType = parts[1];
      final id = parts[2];
      final isMovie = mediaType == 'movie';

      // Fetch real metadata (title, poster, overview) so the details screen
      // and anything added to the watchlist from it carries proper cover art.
      final numericId = int.tryParse(id) ?? 0;
      var details = <String, dynamic>{};
      if (numericId > 0) {
        try {
          details = isMovie
              ? (await TmdbApiService.getMovieDetails(numericId)) ?? {}
              : (await TmdbApiService.getSeriesDetails(numericId)) ?? {};
        } catch (_) {
          // Fall back to the id-only item below.
        }
      }
      final item = Movie.fromJson({
        'id': id,
        'media_type': mediaType,
        'title': isMovie ? (details['title'] ?? ' ') : (details['name'] ?? ' '),
        'name': details['name'] ?? details['title'] ?? ' ',
        'overview': details['overview'] ?? '',
        'poster_path': details['poster_path'] ?? '',
        'backdrop_path': details['backdrop_path'] ?? '',
        'vote_average': details['vote_average'] ?? 0,
        'release_date': details['release_date'] ?? '',
        'first_air_date': details['first_air_date'] ?? '',
        'genre_ids':
            (details['genres'] as List?)
                ?.whereType<Map>()
                .map((g) => g['id'])
                .toList() ??
            <dynamic>[],
      });
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => isMovie
              ? MaxStreamDetailsScreen(item: item, mediaType: 'movie')
              : MaxStreamSeriesScreen(seriesItem: item),
        ),
      );
    }
  }
}
