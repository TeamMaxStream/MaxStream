import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../database/db_helper.dart';
import 'tmdb_api_service.dart';

/// Checks the user's preferred streaming providers for newly released movies
/// and series, then posts a phone-notification-panel alert for each one:
/// title + poster art + which season is available. Tapping a notification
/// opens the details screen (routed via NotificationRouter).
class ContentNotificationService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  /// Cap per check so enabling a provider never floods the notification panel.
  static const int _maxItemsPerCheck = 3;
  static const int _movieRecencyDays = 45;
  static const int _seriesRecencyDays = 90;

  /// No-op. The plugin is initialized once in NotificationService.initialize()
  /// (main.dart) and taps are dispatched through NotificationRouter. Calling
  /// initialize() again here would replace that tap handler.
  static Future<void> initialize() async {}

  static Future<void> checkAndNotifyNewContent({int? onlyProviderId}) async {
    try {
      var preferredProviders = await DBHelper.getPreferredProviders();
      if (onlyProviderId != null) {
        preferredProviders = preferredProviders
            .where((p) => p['providerId'] == onlyProviderId)
            .toList();
      }
      if (preferredProviders.isEmpty) {
        debugPrint('ContentNotificationService: No preferred providers');
        return;
      }

      final prefs = await SharedPreferences.getInstance();
      for (final provider in preferredProviders) {
        final providerId = provider['providerId'] as int;
        final providerName = provider['providerName'] as String? ?? 'Provider';
        try {
          await _checkProviderMovies(providerId, providerName, prefs);
          await _checkProviderShows(providerId, providerName, prefs);
        } catch (e) {
          debugPrint(
            'ContentNotificationService: Error checking $providerName: $e',
          );
        }
      }
    } catch (e) {
      debugPrint('ContentNotificationService Error: $e');
    }
  }

  static Future<void> _checkProviderMovies(
    int providerId,
    String providerName,
    SharedPreferences prefs,
  ) async {
    final movies = await TmdbApiService.getMoviesByProvider(
      providerId,
      page: 1,
    );
    if (movies.isEmpty) return;

    final key = 'notified_movies_$providerId';
    final notified = _getStoredIds(prefs, key);

    final newMovies = movies
        .where(
          (movie) =>
              !notified.contains(movie['id'] as int?) &&
              _isRecent(movie['release_date'] as String?, _movieRecencyDays),
        )
        .take(_maxItemsPerCheck)
        .toList();

    for (final movie in newMovies) {
      final id = movie['id'] as int;
      final title = movie['title'] as String? ?? 'New Movie';
      await _sendNotification(
        mediaType: 'movie',
        tmdbId: id,
        providerId: providerId,
        title: title,
        posterPath: movie['poster_path'] as String? ?? '',
        providerName: providerName,
        detailLine: 'Now streaming',
      );
      notified.add(id);
    }

    if (newMovies.isNotEmpty) {
      await prefs.setStringList(
        key,
        notified.map((id) => id.toString()).toList(),
      );
    }
  }

  static Future<void> _checkProviderShows(
    int providerId,
    String providerName,
    SharedPreferences prefs,
  ) async {
    final shows = await TmdbApiService.getSeriesByProvider(providerId, page: 1);
    if (shows.isEmpty) return;

    final key = 'notified_shows_$providerId';
    final notified = _getStoredIds(prefs, key);

    final newShows = shows
        .where(
          (show) =>
              !notified.contains(show['id'] as int?) &&
              _isRecent(show['first_air_date'] as String?, _seriesRecencyDays),
        )
        .take(_maxItemsPerCheck)
        .toList();

    for (final show in newShows) {
      final id = show['id'] as int;
      final title = show['name'] as String? ?? 'New Series';
      final seasonLabel = await _seasonLabel(id);
      await _sendNotification(
        mediaType: 'tv',
        tmdbId: id,
        providerId: providerId,
        title: title,
        posterPath: show['poster_path'] as String? ?? '',
        providerName: providerName,
        detailLine: seasonLabel,
      );
      notified.add(id);
    }

    if (newShows.isNotEmpty) {
      await prefs.setStringList(
        key,
        notified.map((id) => id.toString()).toList(),
      );
    }
  }

  /// Resolves which season is available for a series (e.g. "Season 2 is now
  /// available" or "3 seasons are now available").
  static Future<String> _seasonLabel(int seriesId) async {
    try {
      final details = await TmdbApiService.getSeriesDetails(seriesId);
      final seasons = details?['number_of_seasons'];
      if (seasons is num && seasons.toInt() > 0) {
        final n = seasons.toInt();
        return n == 1
            ? 'Season 1 is now available'
            : '$n seasons are now available';
      }
    } catch (_) {}
    return 'Now streaming';
  }

  static bool _isRecent(String? dateString, int days) {
    if (dateString == null || dateString.isEmpty) return false;
    final date = DateTime.tryParse(dateString);
    if (date == null) return false;
    return date.isAfter(DateTime.now().subtract(Duration(days: days)));
  }

  static Set<int> _getStoredIds(SharedPreferences prefs, String key) {
    final stored = prefs.getStringList(key) ?? [];
    return stored.map((id) => int.tryParse(id)).whereType<int>().toSet();
  }

  static int _notificationId(int tmdbId, int providerId) =>
      tmdbId * 1000 + providerId;

  static Future<void> _sendNotification({
    required String mediaType,
    required int tmdbId,
    required int providerId,
    required String title,
    required String posterPath,
    required String providerName,
    required String detailLine,
  }) async {
    try {
      final body = '$detailLine on $providerName';
      final posterFile = await _downloadPoster(tmdbId, posterPath);

      AndroidNotificationDetails androidDetails;
      if (posterFile != null) {
        androidDetails = AndroidNotificationDetails(
          'maxstream_content_channel',
          'New Content Notifications',
          channelDescription:
              'Notifications for new releases on your favorite providers',
          importance: Importance.max,
          priority: Priority.high,
          autoCancel: true,
          category: AndroidNotificationCategory.recommendation,
          icon: 'ic_notification',
          largeIcon: FilePathAndroidBitmap(posterFile),
          styleInformation: BigPictureStyleInformation(
            FilePathAndroidBitmap(posterFile),
            largeIcon: FilePathAndroidBitmap(posterFile),
            contentTitle: title,
            summaryText: body,
          ),
        );
      } else {
        androidDetails = const AndroidNotificationDetails(
          'maxstream_content_channel',
          'New Content Notifications',
          channelDescription:
              'Notifications for new releases on your favorite providers',
          importance: Importance.max,
          priority: Priority.high,
          autoCancel: true,
          category: AndroidNotificationCategory.recommendation,
          icon: 'ic_notification',
          largeIcon: DrawableResourceAndroidBitmap('ic_launcher'),
        );
      }

      const darwinDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      );

      await _plugin.show(
        _notificationId(tmdbId, providerId),
        title,
        body,
        NotificationDetails(android: androidDetails, iOS: darwinDetails),
        payload: 'content:$mediaType:$tmdbId',
      );

      debugPrint(
        'ContentNotificationService: Notified "$title" ($mediaType) on $providerName',
      );
    } catch (e) {
      debugPrint('ContentNotificationService: Error sending notification: $e');
    }
  }

  static Future<String?> _downloadPoster(int tmdbId, String posterPath) async {
    if (posterPath.isEmpty) return null;
    try {
      final dir = await getTemporaryDirectory();
      final file = '${dir.path}/maxstream_notify_$tmdbId.jpg';
      await Dio().download(
        'https://image.tmdb.org/t/p/original$posterPath',
        file,
      );
      if (File(file).existsSync()) return file;
      return null;
    } catch (_) {
      return null;
    }
  }
}
