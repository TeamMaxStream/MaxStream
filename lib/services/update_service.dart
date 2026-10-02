import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'notification_service.dart';

/// APK variant names matching GitHub release assets.
const Map<String, String> kApkVariants = {
  'arm64-v8a': 'maxstream-arm64-v8a.apk',
  'armeabi-v7a': 'maxstream-armeabi-v7a.apk',
  'x86_64': 'maxstream-x86_64.apk',
};

/// Get the device's primary ABI (arm64-v8a, armeabi-v7a, x86_64).
Future<String> getDeviceArch() async {
  try {
    if (Platform.isAndroid) {
      final arch = await const MethodChannel('com.maxstream.app/install')
          .invokeMethod<String>('getArch');
      if (arch != null && kApkVariants.containsKey(arch)) return arch;
    }
  } catch (_) {}
  // Fallback from Dart
  try {
    final abi = Platform.operatingSystemVersion;
    if (abi.contains('arm64') || abi.contains('aarch64')) return 'arm64-v8a';
    if (abi.contains('arm')) return 'armeabi-v7a';
    if (abi.contains('x86_64') || abi.contains('amd64')) return 'x86_64';
  } catch (_) {}
  return 'arm64-v8a'; // default to most common
}

class UpdateInfo {
  final String downloadUrl;
  final String version;
  final String changelog;

  const UpdateInfo({
    required this.downloadUrl,
    required this.version,
    this.changelog = '',
  });
}

class DownloadProgressDialog extends StatefulWidget {
  const DownloadProgressDialog({super.key});

  @override
  State<DownloadProgressDialog> createState() => _DownloadProgressDialogState();
}

class _DownloadProgressDialogState extends State<DownloadProgressDialog> {
  double _progress = 0.0;

  @override
  void initState() {
    super.initState();
    UpdateService._progressDialogState = this;
  }

  void updateProgress(double progress) {
    if (mounted) {
      setState(() {
        _progress = progress;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDone = _progress >= 0.999;
    return AlertDialog(
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(isDone ? 'Download complete' : 'Downloading update...'),
          const SizedBox(height: 16),
          LinearProgressIndicator(value: _progress >= 0 ? _progress : null),
          const SizedBox(height: 8),
          Text('${(_progress * 100).clamp(0, 100).toStringAsFixed(0)}%'),
          if (isDone) ...[
            const SizedBox(height: 12),
            const Text(
              'If the installer doesn’t open, download directly from our website.',
              style: TextStyle(fontSize: 12, color: Colors.white70),
              textAlign: TextAlign.center,
            ),
            TextButton(
              onPressed: () async {
                final uri = Uri.parse('https://maxstreamweb.vercel.app/');
                if (await canLaunchUrl(uri)) {
                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                }
              },
              child: const Text('Open Website'),
            ),
          ],
        ],
      ),
    );
  }
}

class DownloadCompleteDialog extends StatelessWidget {
  final String filePath;
  final String packageName;

  const DownloadCompleteDialog({
    super.key,
    required this.filePath,
    required this.packageName,
  });

  Future<void> _launchWebsite() async {
    final uri = Uri.parse('https://maxstreamweb.vercel.app/');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _tryInstall(BuildContext context) async {
    try {
      final result = await const MethodChannel('com.maxstream.app/install')
          .invokeMethod<String>('installApk', {
        'filePath': filePath,
        'packageName': packageName,
      });
      if (result != 'ok' && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Failed to launch installer. Try downloading from website.'),
            action: SnackBarAction(label: 'Website', onPressed: _launchWebsite),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Install failed: $e'),
            action: SnackBarAction(label: 'Website', onPressed: _launchWebsite),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Download Complete'),
      content: const Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('The update has been downloaded.'),
          SizedBox(height: 8),
          Text(
            'Tap Install to launch the system installer. If nothing happens, use the website fallback.',
            style: TextStyle(fontSize: 12, color: Colors.white70),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Later'),
        ),
        TextButton(
          onPressed: _launchWebsite,
          child: const Text('Website'),
        ),
        FilledButton(
          onPressed: () => _tryInstall(context),
          child: const Text('Install'),
        ),
      ],
    );
  }
}

class UpdateService {
  static const String githubOwner = 'TeamMaxStream';
  static const String githubRepo = 'MaxStream';
  static const String latestReleaseUrl =
      'https://api.github.com/repos/$githubOwner/$githubRepo/releases/latest';

  static _DownloadProgressDialogState? _progressDialogState;
  static String? _notifiedVersion;
  static Future<UpdateInfo?>? _inFlightCheck;
  static final Set<String> _shownDialogVersions = {};

  /// Check GitHub for a newer release. Returns UpdateInfo if an update exists.
  static Future<UpdateInfo?> checkForUpdate() async {
    final existing = _inFlightCheck;
    if (existing != null) return existing;
    final check = _performUpdateCheck();
    _inFlightCheck = check;
    try {
      return await check;
    } finally {
      if (identical(_inFlightCheck, check)) _inFlightCheck = null;
    }
  }

  static Future<UpdateInfo?> _performUpdateCheck() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;

      final response = await Dio().get(
        latestReleaseUrl,
        options: Options(headers: {'Accept': 'application/vnd.github+json'}),
      );

      final tagName = response.data['tag_name'] as String? ?? '';
      final latestVersion = tagName.replaceFirst('v', '');
      final changelog = response.data['body'] as String? ?? '';

      if (latestVersion.isEmpty) return null;
      if (!_isVersionNewer(currentVersion, latestVersion)) return null;

      // Auto-detect device variant and find matching APK asset.
      final deviceArch = await getDeviceArch();
      final expectedFilename = kApkVariants[deviceArch] ?? 'maxstream-arm64-v8a.apk';

      final assets = response.data['assets'] as List<dynamic>? ?? [];

      // First, try to find the exact variant match.
      for (final asset in assets) {
        final name = (asset['name'] as String? ?? '');
        if (name == expectedFilename) {
          return UpdateInfo(
            downloadUrl: asset['browser_download_url'] as String,
            version: latestVersion,
            changelog: changelog,
          );
        }
      }

      // Fallback: find any arm64 APK (most common).
      for (final asset in assets) {
        final name = (asset['name'] as String? ?? '').toLowerCase();
        if (name.endsWith('.apk') && name.contains('maxstream-arm64')) {
          return UpdateInfo(
            downloadUrl: asset['browser_download_url'] as String,
            version: latestVersion,
            changelog: changelog,
          );
        }
      }

      // Last fallback: any maxstream APK (not TV).
      for (final asset in assets) {
        final name = (asset['name'] as String? ?? '').toLowerCase();
        if (name.endsWith('.apk') &&
            name.contains('maxstream') &&
            !name.contains('-tv')) {
          return UpdateInfo(
            downloadUrl: asset['browser_download_url'] as String,
            version: latestVersion,
            changelog: changelog,
          );
        }
      }

      return null;
    } catch (e) {
      print('Error checking for update: $e');
      return null;
    }
  }

  /// Check for updates and show a local notification if one is found.
  static Future<void> checkAndNotify({UpdateInfo? info}) async {
    final availableUpdate = info ?? await checkForUpdate();
    if (availableUpdate == null) return;
    if (_notifiedVersion == availableUpdate.version) return;
    _notifiedVersion = availableUpdate.version;

    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;

      final notificationService = NotificationService();
      await notificationService.showNotification(
        id: 9999,
        title: 'Update Available',
        body:
            'MaxStream ${availableUpdate.version} is available (current: $currentVersion). Tap to download.',
        payload: 'update:${availableUpdate.downloadUrl}',
      );
    } catch (_) {
      if (_notifiedVersion == availableUpdate.version) _notifiedVersion = null;
      rethrow;
    }
  }

  static bool reserveUpdateDialog(String version) =>
      _shownDialogVersions.add(version);

  /// Check if auto-check for updates is enabled in settings.
  static Future<bool> isAutoCheckEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool('auto_check_updates') ?? true;
    } catch (_) {
      return true;
    }
  }

  /// Download and install the APK from the given GitHub URL.
  /// At 100% the progress dialog now shows a website fallback, and after
  /// download a completion dialog with Install + Website is shown so a stalled
  /// installer never leaves the user stuck.
  static Future<void> downloadAndInstallUpdate(
    BuildContext context,
    String downloadUrl,
  ) async {
    String? filePath;
    bool progressShown = false;
    try {
      final directory = await getTemporaryDirectory();
      filePath = '${directory.path}/MaxStream.apk';

      if (context.mounted) {
        progressShown = true;
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (_) => const DownloadProgressDialog(),
        );
      }

      final file = File(filePath);
      if (await file.exists()) await file.delete();

      await Dio().download(
        downloadUrl,
        filePath,
        onReceiveProgress: (received, total) {
          final progress = total > 0 ? received / total : -1.0;
          _progressDialogState?.updateProgress(progress > 0 ? progress : 0);
        },
      );
      // Ensure the bar visibly hits 100% even when total was unknown.
      _progressDialogState?.updateProgress(1.0);
      await Future<void>.delayed(const Duration(milliseconds: 250));

      final downloadedFile = File(filePath);
      final fileSize = await downloadedFile.length();
      if (fileSize < 1000) {
        throw StateError('Downloaded file is too small — likely an error page');
      }

      if (context.mounted && progressShown) {
        Navigator.of(context).pop();
        progressShown = false;
      }

      if (context.mounted) {
        final packageInfo = await PackageInfo.fromPlatform();
        // Auto-launch the system installer — no extra tap needed.
        // Fall back to the DownloadCompleteDialog if the installer can't launch.
        try {
          final result = await const MethodChannel('com.maxstream.app/install')
              .invokeMethod<String>('installApk', {
            'filePath': filePath!,
            'packageName': packageInfo.packageName,
          });
          if (result != 'ok' && context.mounted) {
            // Installer didn't launch — show fallback dialog
            await showDialog(
              context: context,
              barrierDismissible: false,
              builder: (dialogContext) => DownloadCompleteDialog(
                filePath: filePath!,
                packageName: packageInfo.packageName,
              ),
            );
          }
        } catch (e) {
          if (context.mounted) {
            await showDialog(
              context: context,
              barrierDismissible: false,
              builder: (dialogContext) => DownloadCompleteDialog(
                filePath: filePath!,
                packageName: packageInfo.packageName,
              ),
            );
          }
        }
      }
    } catch (e) {
      if (context.mounted && progressShown) {
        Navigator.of(context).pop();
      }
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error downloading update: $e'),
            action: SnackBarAction(
              label: 'Website',
              onPressed: () async {
                final uri = Uri.parse('https://maxstreamweb.vercel.app/');
                if (await canLaunchUrl(uri)) {
                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                }
              },
            ),
          ),
        );
      }
    }
  }

  static bool _isVersionNewer(String current, String latest) {
    try {
      final currentParts = current.split('.').map(int.parse).toList();
      final latestParts = latest.split('.').map(int.parse).toList();

      for (int i = 0; i < currentParts.length && i < latestParts.length; i++) {
        if (latestParts[i] > currentParts[i]) return true;
        if (latestParts[i] < currentParts[i]) return false;
      }

      return latestParts.length > currentParts.length;
    } catch (e) {
      return false;
    }
  }
}
