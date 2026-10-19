import 'package:shared_preferences/shared_preferences.dart';

import 'profile_scope.dart';

/// Centralized, persistent download settings per profile.
class DownloadsSettingsService {
  DownloadsSettingsService._();

  static String _key(String suffix) =>
      'download_${suffix}_${ProfileScope.currentProfileId}';

  // ── Quality ────────────────────────────────────────────────────────

  /// Returns the preferred download quality: 'auto', '360', '480', '720', '1080'.
  static Future<String> getQuality() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_key('quality')) ?? 'auto';
  }

  static Future<void> setQuality(String quality) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key('quality'), quality);
    // Update the cache the quality ceiling is read from. Without this the
    // preference was written but `maxVariantHeightPixels` kept returning the
    // value from app start, so "Auto" in the download sheet ignored the
    // Quality setting until the app was restarted.
    _cachedQuality = quality;
  }

  /// Returns the max variant height in pixels for the selected quality,
  /// or null for 'auto'.
  static int? get maxVariantHeightPixels {
    final q = _cachedQuality;
    switch (q) {
      case '360':
        return 360;
      case '480':
        return 480;
      case '720':
        return 720;
      case '1080':
        return 1080;
      default:
        return null; // auto
    }
  }

  static String _cachedQuality = 'auto';

  static Future<void> refreshCache() async {
    _cachedQuality = await getQuality();
    _cachedWifiOnly = await getWifiOnly();
    _cachedStorageLimitGb = await getStorageLimitGb();
  }

  // ── WiFi Only ──────────────────────────────────────────────────────

  static bool _cachedWifiOnly = true;

  static Future<bool> getWifiOnly() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_key('wifi_only')) ?? true;
  }

  static Future<void> setWifiOnly(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key('wifi_only'), value);
    _cachedWifiOnly = value;
  }

  static bool get wifiOnly => _cachedWifiOnly;

  // ── Auto-Download Favorites ────────────────────────────────────────

  static Future<bool> getAutoDownloadFavorites() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_key('auto_favorites')) ?? false;
  }

  static Future<void> setAutoDownloadFavorites(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key('auto_favorites'), value);
  }

  // ── Notifications ──────────────────────────────────────────────────

  static Future<bool> getNotifications() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_key('notifications')) ?? true;
  }

  static Future<void> setNotifications(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key('notifications'), value);
  }

  // ── Auto-Delete After Watch ────────────────────────────────────────

  static Future<bool> getAutoDeleteAfterWatch() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_key('auto_delete')) ?? false;
  }

  static Future<void> setAutoDeleteAfterWatch(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key('auto_delete'), value);
  }

  // ── Storage Limit ──────────────────────────────────────────────────

  /// Returns the storage limit in GB. 0 = unlimited.
  static double _cachedStorageLimitGb = 0;

  static Future<double> getStorageLimitGb() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_key('storage_limit_gb')) ?? 0;
  }

  static Future<void> setStorageLimitGb(double gb) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_key('storage_limit_gb'), gb);
    _cachedStorageLimitGb = gb;
  }

  static double get storageLimitGb => _cachedStorageLimitGb;

  /// Returns true if the given bytes would exceed the storage limit.
  /// Returns false if unlimited (0).
  static bool wouldExceedLimit(int currentUsageBytes, int additionalBytes) {
    if (_cachedStorageLimitGb <= 0) return false; // unlimited
    final limitBytes = (_cachedStorageLimitGb * 1024 * 1024 * 1024).toInt();
    return (currentUsageBytes + additionalBytes) > limitBytes;
  }
}
