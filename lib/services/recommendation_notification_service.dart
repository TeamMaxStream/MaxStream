import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'recommendation_service.dart';

/// Periodically checks for new content matching the user's genre preferences
/// and sends a recommendation notification. Uses the same notification channel
/// as ContentNotificationService so both share a single user-facing channel.
class RecommendationNotificationService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static const int _maxItemsPerCheck = 3;
  static const String _notifiedKey = 'notified_recommendations';

  static Future<void> checkAndNotify() async {
    try {
      final items = await RecommendationService.getNewReleasesForNotifications(
        limit: 10,
      );
      if (items.isEmpty) return;

      final prefs = await SharedPreferences.getInstance();
      final notified = _getStoredIds(prefs);

      final newItems = items
          .where((item) => !notified.contains(item['id'] as int?))
          .take(_maxItemsPerCheck)
          .toList();

      for (final item in newItems) {
        final id = item['id'] as int;
        final title =
            item['title'] as String? ?? item['name'] as String? ?? 'New';
        final mediaType = item['mediaType'] ?? 'movie';
        final posterPath = item['poster_path'] as String? ?? '';

        await _sendNotification(
          tmdbId: id,
          mediaType: mediaType,
          title: title,
          posterPath: posterPath,
        );
        notified.add(id);
      }

      if (newItems.isNotEmpty) {
        await prefs.setStringList(
          _notifiedKey,
          notified.map((id) => id.toString()).toList(),
        );
      }
    } catch (e) {
      debugPrint('RecommendationNotificationService: Error: $e');
    }
  }

  static Future<void> _sendNotification({
    required int tmdbId,
    required String mediaType,
    required String title,
    required String posterPath,
  }) async {
    try {
      final body = mediaType == 'tv'
          ? 'A series you might like'
          : 'A movie you might like';

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

      final id = tmdbId * 100 + 99;
      await _plugin.show(
        id,
        title,
        body,
        NotificationDetails(android: androidDetails, iOS: darwinDetails),
        payload: 'content:$mediaType:$tmdbId',
      );

      debugPrint('RecommendationNotificationService: Notified "$title"');
    } catch (e) {
      debugPrint('RecommendationNotificationService: Send error: $e');
    }
  }

  static Future<String?> _downloadPoster(int tmdbId, String posterPath) async {
    if (posterPath.isEmpty) return null;
    try {
      final dir = await getTemporaryDirectory();
      final file = '${dir.path}/maxstream_rec_$tmdbId.jpg';
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

  static Set<int> _getStoredIds(SharedPreferences prefs) {
    final stored = prefs.getStringList(_notifiedKey) ?? [];
    return stored.map((id) => int.tryParse(id)).whereType<int>().toSet();
  }
}
