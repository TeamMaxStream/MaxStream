import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/update_service.dart';

class UpdatesScreen extends StatefulWidget {
  const UpdatesScreen({super.key});

  @override
  State<UpdatesScreen> createState() => _UpdatesScreenState();
}

class _UpdatesScreenState extends State<UpdatesScreen> {
  String _currentVersion = '...';
  String _currentBuild = '...';
  String _installedVariant = '...';
  bool _autoCheckEnabled = true;
  bool _checking = false;
  UpdateInfo? _availableUpdate;
  String _deviceArch = '...';

  // APK variant names matching GitHub release assets
  static const Map<String, String> variantNames = {
    'arm64-v8a': 'maxstream-arm64-v8a.apk',
    'armeabi-v7a': 'maxstream-armeabi-v7a.apk',
    'x86_64': 'maxstream-x86_64.apk',
  };

  static const Map<String, String> variantLabels = {
    'arm64-v8a': 'ARM 64-bit (arm64-v8a)',
    'armeabi-v7a': 'ARM 32-bit (armeabi-v7a)',
    'x86_64': 'x86_64 (Intel/AMD)',
  };

  @override
  void initState() {
    super.initState();
    _loadInfo();
  }

  Future<void> _loadInfo() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final prefs = await SharedPreferences.getInstance();
      final autoCheck = prefs.getBool('auto_check_updates') ?? true;

      // Detect device architecture
      String arch = 'unknown';
      try {
        if (Platform.isAndroid) {
          arch = await const MethodChannel('com.maxstream.app/install')
              .invokeMethod<String>('getArch') ?? _getArchFromAbi();
        }
      } catch (_) {
        arch = _getArchFromAbi();
      }

      if (mounted) {
        setState(() {
          _currentVersion = info.version;
          _currentBuild = info.buildNumber;
          _installedVariant = arch;
          _deviceArch = arch;
          _autoCheckEnabled = autoCheck;
        });
      }
    } catch (_) {}
  }

  String _getArchFromAbi() {
    // Fallback: detect from Dart's Platform
    final abi = Platform.operatingSystemVersion;
    if (abi.contains('arm64') || abi.contains('aarch64')) return 'arm64-v8a';
    if (abi.contains('arm')) return 'armeabi-v7a';
    if (abi.contains('x86_64') || abi.contains('amd64')) return 'x86_64';
    return 'unknown';
  }

  Future<void> _toggleAutoCheck(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('auto_check_updates', value);
    if (mounted) setState(() => _autoCheckEnabled = value);
  }

  Future<void> _checkForUpdate() async {
    if (_checking) return;
    setState(() {
      _checking = true;
      _availableUpdate = null;
    });

    try {
      final update = await UpdateService.checkForUpdate();
      if (mounted) {
        setState(() {
          _availableUpdate = update;
          _checking = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final matchedVariant = variantNames.entries.firstWhere(
      (e) => _installedVariant.contains(e.key),
      orElse: () => const MapEntry('unknown', ''),
    );

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text(
          'Updates',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Current version card
            _buildSectionTitle('Current Installation'),
            const SizedBox(height: 12),
            _buildInfoCard(
              icon: Icons.phone_android,
              title: 'Version $_currentVersion',
              subtitle: 'Build $_currentBuild',
            ),
            const SizedBox(height: 8),
            _buildInfoCard(
              icon: Icons.architecture,
              title: 'Installed Variant',
              subtitle: variantLabels[_installedVariant] ?? _installedVariant,
            ),
            const SizedBox(height: 24),

            // Auto-check toggle
            _buildSectionTitle('Update Settings'),
            const SizedBox(height: 12),
            _buildToggleCard(
              icon: Icons.autorenew,
              title: 'Auto-check for updates',
              subtitle: 'Check for new versions on app startup',
              value: _autoCheckEnabled,
              onChanged: _toggleAutoCheck,
            ),
            const SizedBox(height: 24),

            // Check for updates
            _buildSectionTitle('Check for Updates'),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _checking ? null : _checkForUpdate,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: _checking
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text(
                        'Check for Updates',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                      ),
              ),
            ),
            const SizedBox(height: 16),

            // Update available
            if (_availableUpdate != null) ...[
              _buildUpdateAvailableCard(_availableUpdate!),
              const SizedBox(height: 16),
            ] else if (!_checking && _availableUpdate == null) ...[
              _buildInfoCard(
                icon: Icons.check_circle,
                title: 'Up to Date',
                subtitle: 'You are running the latest version.',
              ),
              const SizedBox(height: 16),
            ],

            // All available variants
            _buildSectionTitle('Available Variants'),
            const SizedBox(height: 12),
            ...variantNames.entries.map((entry) {
              final isInstalled = _installedVariant.contains(entry.key);
              return _buildVariantCard(
                label: variantLabels[entry.key] ?? entry.key,
                filename: entry.value,
                isInstalled: isInstalled,
                downloadUrl: _availableUpdate != null
                    ? _getVariantDownloadUrl(_availableUpdate!.downloadUrl, entry.value)
                    : null,
              );
            }),
            const SizedBox(height: 100),
          ],
        ),
      ),
    );
  }

  String _getVariantDownloadUrl(String baseDownloadUrl, String variantFilename) {
    // GitHub release URL pattern:
    // https://github.com/TeamMaxStream/MaxStream/releases/download/v1.6.0/maxstream-arm64-v8a.apk
    // The base URL points to the release tag; we construct the variant URL from the tag
    final tag = baseDownloadUrl.split('/releases/download/').last.split('/').first;
    return 'https://github.com/TeamMaxStream/MaxStream/releases/download/$tag/$variantFilename';
  }

  Widget _buildSectionTitle(String title) {
    return Text(
      title.toUpperCase(),
      style: TextStyle(
        color: Colors.grey[500],
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: 1.2,
      ),
    );
  }

  Widget _buildInfoCard({
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, color: Colors.red, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(color: Colors.grey[500], fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToggleCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, color: Colors.red, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(color: Colors.grey[500], fontSize: 12),
                ),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeColor: Colors.red,
          ),
        ],
      ),
    );
  }

  Widget _buildUpdateAvailableCard(UpdateInfo update) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.red.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.system_update, color: Colors.red, size: 22),
              const SizedBox(width: 10),
              Text(
                'Update Available: v${update.version}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          if (update.changelog.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              update.changelog,
              style: TextStyle(color: Colors.grey[400], fontSize: 13, height: 1.4),
              maxLines: 5,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () {
                UpdateService.downloadAndInstallUpdate(context, update.downloadUrl);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: Text(
                'Download ${variantLabels[_deviceArch] ?? _deviceArch}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVariantCard({
    required String label,
    required String filename,
    required bool isInstalled,
    String? downloadUrl,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(
            isInstalled ? Icons.check_circle : Icons.phone_android,
            color: isInstalled ? Colors.green : Colors.grey,
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: isInstalled ? Colors.green : Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  filename,
                  style: TextStyle(color: Colors.grey[500], fontSize: 11),
                ),
              ],
            ),
          ),
          if (isInstalled)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.green.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Text(
                'Installed',
                style: TextStyle(color: Colors.green, fontSize: 11, fontWeight: FontWeight.w600),
              ),
            )
          else if (downloadUrl != null)
            IconButton(
              icon: const Icon(Icons.download, color: Colors.red, size: 20),
              onPressed: () {
                UpdateService.downloadAndInstallUpdate(context, downloadUrl);
              },
            ),
        ],
      ),
    );
  }
}
