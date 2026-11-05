import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dio/dio.dart';
import 'dart:io';

import 'tmdb_api_service.dart';

/// Manages "Remind Me" preferences for TV shows and checks for new episodes.
class WatchReminderService {
  static const String _remindersKey = 'watch_reminders';
  static const int _checkIntervalHours = 12;

  /// Get all show IDs the user has set reminders for.
  static Future<Set<int>> getRemindedShowIds() async {
    final prefs = await _prefs();
    final stored = prefs.getStringList(_remindersKey) ?? [];
    return stored.map((id) => int.tryParse(id)).whereType<int>().toSet();
  }

  /// Check if a specific show has a reminder set.
  static Future<bool> isReminded(int showId) async {
    final ids = await getRemindedShowIds();
    return ids.contains(showId);
  }

  /// Toggle reminder for a show. Returns the new state (true = reminded).
  static Future<bool> toggleReminder({
    required int showId,
    required String title,
    required String posterPath,
    required int lastKnownSeason,
    required int lastKnownEpisode,
  }) async {
    final prefs = await _prefs();
    final stored = prefs.getStringList(_remindersKey) ?? [];
    final ids = stored.map((id) => int.tryParse(id)).whereType<int>().toSet();

    if (ids.contains(showId)) {
      ids.remove(showId);
      await prefs.setStringList(
        _remindersKey,
        ids.map((id) => id.toString()).toList(),
      );
      // Remove episode tracking
      await prefs.remove('reminder_${showId}_season');
      await prefs.remove('reminder_${showId}_episode');
      await prefs.remove('reminder_${showId}_title');
      await prefs.remove('reminder_${showId}_poster');
      debugPrint('WatchReminderService: Removed reminder for "$title"');
      return false;
    } else {
      ids.add(showId);
      await prefs.setStringList(
        _remindersKey,
        ids.map((id) => id.toString()).toList(),
      );
      // Store episode tracking info
      await prefs.setInt('reminder_${showId}_season', lastKnownSeason);
      await prefs.setInt('reminder_${showId}_episode', lastKnownEpisode);
      await prefs.setString('reminder_${showId}_title', title);
      await prefs.setString('reminder_${showId}_poster', posterPath);
      debugPrint(
        'WatchReminderService: Added reminder for "$title" (S${lastKnownSeason}E$lastKnownEpisode)',
      );
      return true;
    }
  }

  /// Check all reminded shows for new episodes and send notifications.
  static Future<void> checkForNewEpisodes() async {
    final prefs = await _prefs();
    final ids = await getRemindedShowIds();
    if (ids.isEmpty) return;

    final lastCheck = prefs.getInt('reminder_last_check') ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    final hoursSince = (now - lastCheck) / (1000 * 60 * 60);
    if (hoursSince < _checkIntervalHours && lastCheck > 0) return;

    await prefs.setInt('reminder_last_check', now);

    for (final showId in ids) {
      try {
        await _checkSingleShow(prefs, showId);
      } catch (e) {
        debugPrint('WatchReminderService: Error checking show $showId: $e');
      }
    }
  }

  static Future<void> _checkSingleShow(dynamic prefs, int showId) async {
    final details = await TmdbApiService.getSeriesDetails(showId);
    if (details == null) return;

    final currentSeason = details['number_of_seasons'] as int? ?? 0;
    final lastKnownSeason = prefs.getInt('reminder_${showId}_season') ?? 0;
    final lastKnownEpisode = prefs.getInt('reminder_${showId}_episode') ?? 0;
    final title = prefs.getString('reminder_${showId}_title') ?? 'Unknown';
    final posterPath = prefs.getString('reminder_${showId}_poster') ?? '';

    // Check if there's a new season
    if (currentSeason > lastKnownSeason) {
      await _sendNotification(
        showId: showId,
        title: title,
        posterPath: posterPath,
        message:
            'New season available! Season $currentSeason is now streaming.',
      );
      await prefs.setInt('reminder_${showId}_season', currentSeason);
      await prefs.setInt('reminder_${showId}_episode', 0);
      return;
    }

    // Check for new episodes in current season
    if (currentSeason > 0) {
      final episodes = await TmdbApiService.getSeasonEpisodes(
        showId,
        currentSeason,
      );
      final currentEpisodeCount = episodes.length;
      if (currentEpisodeCount > lastKnownEpisode && lastKnownEpisode > 0) {
        await _sendNotification(
          showId: showId,
          title: title,
          posterPath: posterPath,
          message:
              'New episode available! Season $currentSeason now has $currentEpisodeCount episodes.',
        );
        await prefs.setInt('reminder_${showId}_episode', currentEpisodeCount);
      }
    }
  }

  static Future<void> _sendNotification({
    required int showId,
    required String title,
    required String posterPath,
    required String message,
  }) async {
    try {
      final plugin = FlutterLocalNotificationsPlugin();

      AndroidNotificationDetails androidDetails;
      if (posterPath.isNotEmpty) {
        final posterFile = await _downloadPoster(showId, posterPath);
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
              summaryText: message,
            ),
          );
        } else {
          androidDetails = _defaultDetails();
        }
      } else {
        androidDetails = _defaultDetails();
      }

      const darwinDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      );

      final notifId = showId * 10 + 7; // Unique ID per show
      await plugin.show(
        notifId,
        title,
        message,
        NotificationDetails(android: androidDetails, iOS: darwinDetails),
        payload: 'content:tv:$showId',
      );

      debugPrint('WatchReminderService: Notified "$title" - $message');
    } catch (e) {
      debugPrint('WatchReminderService: Send error: $e');
    }
  }

  static AndroidNotificationDetails _defaultDetails() {
    return const AndroidNotificationDetails(
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

  static Future<String?> _downloadPoster(int showId, String posterPath) async {
    if (posterPath.isEmpty) return null;
    try {
      final dir = await getTemporaryDirectory();
      final file = '${dir.path}/maxstream_reminder_$showId.jpg';
      if (File(file).existsSync()) return file;
      await Dio().download('https://image.tmdb.org/t/p/w500$posterPath', file);
      if (File(file).existsSync()) return file;
      return null;
    } catch (_) {
      return null;
    }
  }

  static Future<SharedPreferences> _prefs() async {
    return await SharedPreferences.getInstance();
  }
}
