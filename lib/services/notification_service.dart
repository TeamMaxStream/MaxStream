import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'notification_router.dart';

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  static late FlutterLocalNotificationsPlugin _notificationsPlugin;

  factory NotificationService() {
    return _instance;
  }

  NotificationService._internal();

  Future<void> initialize() async {
    _notificationsPlugin = FlutterLocalNotificationsPlugin();

    const AndroidInitializationSettings androidSettings =
        AndroidInitializationSettings('ic_notification');

    const DarwinInitializationSettings iosSettings =
        DarwinInitializationSettings(
          requestSoundPermission: true,
          requestBadgePermission: true,
          requestAlertPermission: true,
        );

    final InitializationSettings initSettings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _notificationsPlugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: NotificationRouter.handleTap,
    );
  }

  Future<void> showNotification({
    required int id,
    required String title,
    required String body,
    String? payload,
  }) async {
    const AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
          'maxstream_channel',
          'MaxStream Notifications',
          channelDescription: 'Notifications for content availability',
          importance: Importance.max,
          priority: Priority.high,
          showWhen: true,
          icon: 'ic_notification',
          largeIcon: DrawableResourceAndroidBitmap('ic_launcher'),
        );

    const DarwinNotificationDetails iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    const NotificationDetails details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    await _notificationsPlugin.show(id, title, body, details, payload: payload);
  }

  Future<void> showDownloadProgress({
    required int id,
    required String title,
    required String label,
    required int progress,
    String? size,
  }) async {
    final androidDetails = AndroidNotificationDetails(
      'maxstream_downloads',
      'Media downloads',
      channelDescription: 'Progress for offline movie and episode downloads',
      importance: Importance.low,
      priority: Priority.low,
      category: AndroidNotificationCategory.progress,
      ongoing: true,
      autoCancel: false,
      onlyAlertOnce: true,
      showProgress: true,
      maxProgress: 100,
      progress: progress.clamp(0, 100),
      icon: 'ic_notification',
      largeIcon: const DrawableResourceAndroidBitmap('ic_launcher'),
    );
    await _notificationsPlugin.show(
      id,
      title,
      '$label · $progress%${size == null ? '' : ' · $size'}',
      NotificationDetails(android: androidDetails),
      payload: 'downloads',
    );
  }

  /// Progress for a device-to-device share (sending on one phone, receiving
  /// on the other). [done]/[total] are bytes so the notification can show the
  /// real transferred size, not just a percentage.
  Future<void> showShareProgress({
    required int id,
    required String title,
    required String label,
    required int done,
    required int total,
    required bool sending,
  }) async {
    final percent = total <= 0 ? 0 : ((done / total) * 100).round().clamp(0, 100);
    final size = _humanBytes(done);
    final details = AndroidNotificationDetails(
      'maxstream_share',
      'Device-to-device sharing',
      channelDescription: 'Progress while sending or receiving a shared movie '
          'or series to another device',
      importance: Importance.low,
      priority: Priority.low,
      category: AndroidNotificationCategory.progress,
      ongoing: true,
      autoCancel: false,
      onlyAlertOnce: true,
      showProgress: true,
      maxProgress: 100,
      progress: percent,
      icon: 'ic_notification',
      largeIcon: const DrawableResourceAndroidBitmap('ic_launcher'),
    );
    await _notificationsPlugin.show(
      id,
      title,
      '$label · $percent% · $size'
      '${total <= 0 ? '' : ' of ${_humanBytes(total)}'}',
      NotificationDetails(android: details),
      payload: 'downloads',
    );
  }

  /// Terminal state of a share: finished, failed or stopped.
  Future<void> showShareFinished({
    required int id,
    required String label,
    required bool sending,
    String? error,
  }) async {
    const details = AndroidNotificationDetails(
      'maxstream_share',
      'Device-to-device sharing',
      channelDescription: 'Progress while sending or receiving a shared movie '
          'or series to another device',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
      autoCancel: true,
      onlyAlertOnce: true,
      icon: 'ic_notification',
      largeIcon: DrawableResourceAndroidBitmap('ic_launcher'),
    );
    final verb = sending ? 'Sent' : 'Received';
    await _notificationsPlugin.show(
      id,
      error == null ? '$verb to device' : 'Share failed',
      error == null ? label : '$label · $error',
      const NotificationDetails(android: details),
      payload: 'downloads',
    );
  }

  static String _humanBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  Future<void> showDownloadFinished({
    required int id,
    required String label,
    String? error,
  }) async {
    const androidDetails = AndroidNotificationDetails(
      'maxstream_downloads',
      'Media downloads',
      channelDescription: 'Progress for offline movie and episode downloads',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
      autoCancel: true,
      onlyAlertOnce: true,
      icon: 'ic_notification',
      largeIcon: DrawableResourceAndroidBitmap('ic_launcher'),
    );
    await _notificationsPlugin.show(
      id,
      error == null ? 'Download complete' : 'Download failed',
      error == null ? label : '$label · $error',
      const NotificationDetails(android: androidDetails),
      payload: 'downloads',
    );
  }

  Future<void> notifyNewContent({
    required String contentTitle,
    required String providerName,
    required String mediaType,
  }) async {
    await showNotification(
      id: DateTime.now().millisecond,
      title: 'New on $providerName!',
      body: '$contentTitle is now available on $providerName ($mediaType)',
      payload: 'new_content:$contentTitle:$providerName',
    );
  }

  Future<void> notifyMultipleProvidersAdded({
    required String contentTitle,
    required List<String> providerNames,
    required String mediaType,
  }) async {
    final providers = providerNames.join(', ');
    await showNotification(
      id: DateTime.now().millisecond,
      title: '$contentTitle is now on multiple platforms!',
      body: 'Available on: $providers',
      payload: 'content_expanded:$contentTitle',
    );
  }

  Future<void> notifyPreferredProviderUpdate({
    required String contentTitle,
    required String providerName,
  }) async {
    await showNotification(
      id: DateTime.now().millisecond,
      title: 'Your Favorite Provider Has It!',
      body: '$contentTitle just became available on $providerName',
      payload: 'preferred:$contentTitle:$providerName',
    );
  }

  Future<void> cancelNotification(int id) async {
    await _notificationsPlugin.cancel(id);
  }

  Future<void> cancelAllNotifications() async {
    await _notificationsPlugin.cancelAll();
  }
}
