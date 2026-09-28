import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../database/db_helper.dart';
import '../services/downloads_settings_service.dart';
import '../services/profile_scope.dart';

class DownloadsSettingsScreen extends StatefulWidget {
  const DownloadsSettingsScreen({super.key});

  @override
  State<DownloadsSettingsScreen> createState() =>
      _DownloadsSettingsScreenState();
}

class _DownloadsSettingsScreenState extends State<DownloadsSettingsScreen> {
  bool _wifiOnly = true;
  bool _autoDownloadFavorites = false;
  bool _notifications = true;
  bool _autoDeleteAfterWatch = false;
  String _downloadQuality = 'auto';
  double _storageLimitGb = 0; // 0 = unlimited
  int _storageUsage = 0;
  int _downloadCount = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _loadStorageInfo();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _loadStorageInfo();
  }

  Future<void> _loadSettings() async {
    final quality = await DownloadsSettingsService.getQuality();
    final wifiOnly = await DownloadsSettingsService.getWifiOnly();
    final autoFav = await DownloadsSettingsService.getAutoDownloadFavorites();
    final notifs = await DownloadsSettingsService.getNotifications();
    final autoDel = await DownloadsSettingsService.getAutoDeleteAfterWatch();
    final limit = await DownloadsSettingsService.getStorageLimitGb();
    await DownloadsSettingsService.refreshCache();
    if (mounted) {
      setState(() {
        _downloadQuality = quality;
        _wifiOnly = wifiOnly;
        _autoDownloadFavorites = autoFav;
        _notifications = notifs;
        _autoDeleteAfterWatch = autoDel;
        _storageLimitGb = limit;
        _loading = false;
      });
    }
  }

  Future<void> _loadStorageInfo() async {
    final profileId = ProfileScope.currentProfileId;
    final downloads = await DBHelper.getMediaDownloads(profileId: profileId);
    final totalBytes = await DBHelper.getDownloadStorageUsage(
      profileId: profileId,
    );
    if (mounted) {
      setState(() {
        _storageUsage = totalBytes;
        _downloadCount = downloads.length;
      });
    }
  }

  String _formatBytes(int bytes) {
    if (bytes == 0) return '0 B';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  String _limitLabel(double gb) {
    if (gb <= 0) return 'Unlimited';
    if (gb == 1) return '1 GB';
    return '${gb.toInt()} GB';
  }

  Future<void> _clearAllDownloads() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text(
          'Clear All Downloads?',
          style: TextStyle(color: Colors.white),
        ),
        content: Text(
          'This will delete all $_downloadCount downloads '
          '(${_formatBytes(_storageUsage)}) for '
          '${ProfileScope.currentProfileName}. This cannot be undone.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text(
              'Delete All',
              style: TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await DBHelper.clearAllDownloads();
      await _loadStorageInfo();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('All downloads cleared'),
            backgroundColor: Colors.green,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text(
          'Download Settings',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Colors.red))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildProfileIndicator(),
                  const SizedBox(height: 20),
                  _buildStorageCard(),
                  const SizedBox(height: 12),
                  _buildStorageLimitSlider(),
                  const SizedBox(height: 24),
                  _buildSectionHeader('QUALITY'),
                  _buildQualitySelector(),
                  const SizedBox(height: 24),
                  _buildSectionHeader('PREFERENCES'),
                  _buildToggleSetting(
                    icon: Icons.wifi,
                    title: 'WiFi Only',
                    subtitle: 'Prevent downloads on cellular data',
                    value: _wifiOnly,
                    onChanged: (value) {
                      setState(() => _wifiOnly = value);
                      DownloadsSettingsService.setWifiOnly(value);
                    },
                  ),
                  _buildToggleSetting(
                    icon: Icons.favorite,
                    title: 'Auto-Download Favorites',
                    subtitle:
                        'Automatically download when you add to watchlist',
                    value: _autoDownloadFavorites,
                    onChanged: (value) {
                      setState(() => _autoDownloadFavorites = value);
                      DownloadsSettingsService.setAutoDownloadFavorites(value);
                    },
                  ),
                  _buildToggleSetting(
                    icon: Icons.notifications,
                    title: 'Notifications',
                    subtitle: 'Show download completion/error notifications',
                    value: _notifications,
                    onChanged: (value) {
                      setState(() => _notifications = value);
                      DownloadsSettingsService.setNotifications(value);
                    },
                  ),
                  _buildToggleSetting(
                    icon: Icons.delete_sweep,
                    title: 'Auto-Delete After Watch',
                    subtitle: 'Remove download after playback completes',
                    value: _autoDeleteAfterWatch,
                    onChanged: (value) {
                      setState(() => _autoDeleteAfterWatch = value);
                      DownloadsSettingsService.setAutoDeleteAfterWatch(value);
                    },
                  ),
                  const SizedBox(height: 24),
                  _buildSectionHeader('MANAGEMENT'),
                  _buildStorageLocationCard(),
                  const SizedBox(height: 12),
                  _buildClearAllButton(),
                  const SizedBox(height: 40),
                ],
              ),
            ),
    );
  }

  // ── Profile Indicator ─────────────────────────────────────────────

  Widget _buildProfileIndicator() {
    final profile = ProfileScope.activeProfile.value;
    final isKids = ProfileScope.isKidsProfile;
    final profileName = ProfileScope.currentProfileName;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: isKids
            ? const Color(0xFF132A42).withValues(alpha: 0.6)
            : Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isKids
              ? const Color(0xFF10B981).withValues(alpha: 0.3)
              : Colors.white.withValues(alpha: 0.1),
          width: 1,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: isKids
                  ? const Color(0xFF10B981)
                  : (profile?.avatar.color ?? Colors.red),
              shape: BoxShape.circle,
            ),
            child: Icon(
              profile?.avatar.icon ?? Icons.person,
              color: Colors.white,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  profileName,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (isKids)
                  const Text(
                    'Kids Profile',
                    style: TextStyle(
                      color: Color(0xFF10B981),
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Storage Usage Card ────────────────────────────────────────────

  Widget _buildStorageCard() {
    final limitGb = _storageLimitGb;
    final usageFraction = limitGb > 0
        ? (_storageUsage / (limitGb * 1024 * 1024 * 1024)).clamp(0.0, 1.0)
        : 0.0;
    final isNearLimit = limitGb > 0 && usageFraction > 0.85;
    final barColor = isNearLimit
        ? Colors.orange
        : limitGb > 0 && usageFraction > 0.6
        ? Colors.amber
        : Colors.red;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF1A1A1A), Color(0xFF252525)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.storage, color: Colors.red, size: 24),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Storage Usage',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      '$_downloadCount downloads \u2022 ${_formatBytes(_storageUsage)}',
                      style: TextStyle(color: Colors.grey[400], fontSize: 13),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: limitGb > 0 ? usageFraction : 0,
              backgroundColor: Colors.white.withValues(alpha: 0.1),
              valueColor: AlwaysStoppedAnimation<Color>(barColor),
              minHeight: 6,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            limitGb > 0
                ? '${_formatBytes(_storageUsage)} of ${_limitLabel(limitGb)} used'
                : '${_formatBytes(_storageUsage)} \u2022 No limit set',
            style: TextStyle(color: Colors.grey[500], fontSize: 11),
          ),
        ],
      ),
    );
  }

  // ── Storage Limit Slider ──────────────────────────────────────────

  Widget _buildStorageLimitSlider() {
    // Slider steps: 0=Unlimited, 1=1GB, 4=4GB, 8=8GB, 16=16GB
    const steps = [0.0, 1.0, 4.0, 8.0, 16.0];
    final currentIndex = steps.indexWhere((v) => v == _storageLimitGb);
    final sliderValue = currentIndex >= 0 ? currentIndex.toDouble() : 0.0;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.data_usage,
                color: _storageLimitGb > 0 ? Colors.red : Colors.grey,
                size: 20,
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Storage Limit',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: _storageLimitGb > 0
                      ? Colors.red.withValues(alpha: 0.15)
                      : Colors.green.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _limitLabel(_storageLimitGb),
                  style: TextStyle(
                    color: _storageLimitGb > 0 ? Colors.red : Colors.green,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: Colors.red,
              inactiveTrackColor: Colors.white.withValues(alpha: 0.1),
              thumbColor: Colors.red,
              overlayColor: Colors.red.withValues(alpha: 0.2),
              trackHeight: 4,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
            ),
            child: Slider(
              value: sliderValue,
              min: 0,
              max: (steps.length - 1).toDouble(),
              divisions: steps.length - 1,
              onChanged: (value) {
                HapticFeedback.lightImpact();
                final newLimit = steps[value.round()];
                setState(() => _storageLimitGb = newLimit);
                DownloadsSettingsService.setStorageLimitGb(newLimit);
              },
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: steps.map((gb) {
              final isActive = _storageLimitGb == gb;
              return Text(
                gb <= 0 ? 'Max' : '${gb.toInt()}',
                style: TextStyle(
                  color: isActive ? Colors.red : Colors.grey[600],
                  fontSize: 10,
                  fontWeight: isActive ? FontWeight.w700 : FontWeight.w400,
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  // ── Section Header ────────────────────────────────────────────────

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        title,
        style: TextStyle(
          color: Colors.grey[500],
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  // ── Quality Selector ──────────────────────────────────────────────

  Widget _buildQualitySelector() {
    final qualities = [
      {'value': 'auto', 'label': 'Auto', 'subtitle': 'Best available'},
      {'value': '1080', 'label': '1080p', 'subtitle': 'Full HD'},
      {'value': '720', 'label': '720p', 'subtitle': 'HD'},
      {'value': '480', 'label': '480p', 'subtitle': 'SD'},
      {'value': '360', 'label': '360p', 'subtitle': 'Low \u2022 Smallest file'},
    ];

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
      ),
      child: Column(
        children: qualities.map((quality) {
          final isSelected = _downloadQuality == quality['value'];
          return InkWell(
            onTap: () {
              HapticFeedback.lightImpact();
              setState(() => _downloadQuality = quality['value']!);
              DownloadsSettingsService.setQuality(quality['value']!);
            },
            borderRadius: BorderRadius.circular(12),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: isSelected
                    ? Colors.red.withValues(alpha: 0.15)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(
                    isSelected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    color: isSelected ? Colors.red : Colors.grey,
                    size: 20,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          quality['label']!,
                          style: TextStyle(
                            color: isSelected ? Colors.white : Colors.grey[300],
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        Text(
                          quality['subtitle']!,
                          style: TextStyle(
                            color: Colors.grey[500],
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  // ── Toggle Setting ────────────────────────────────────────────────

  Widget _buildToggleSetting({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: ListTile(
        leading: Icon(icon, color: value ? Colors.red : Colors.grey, size: 22),
        title: Text(
          title,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w500,
          ),
        ),
        subtitle: Text(
          subtitle,
          style: TextStyle(color: Colors.grey[500], fontSize: 12),
        ),
        trailing: Switch(
          value: value,
          onChanged: onChanged,
          activeColor: Colors.red,
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      ),
    );
  }

  // ── Storage Location Card ─────────────────────────────────────────

  Widget _buildStorageLocationCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Row(
        children: [
          Icon(Icons.storage, color: Colors.grey[400], size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Storage Location',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                Text(
                  'SQLite (sqflite) \u2022 Internal Storage',
                  style: TextStyle(color: Colors.grey[500], fontSize: 12),
                ),
                const SizedBox(height: 2),
                Text(
                  'Downloads are stored locally on this device.',
                  style: TextStyle(color: Colors.grey[600], fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Clear All Button ──────────────────────────────────────────────

  Widget _buildClearAllButton() {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: _downloadCount > 0 ? _clearAllDownloads : null,
        icon: const Icon(Icons.delete_sweep, color: Colors.red),
        label: const Text(
          'Clear All Downloads',
          style: TextStyle(color: Colors.red, fontWeight: FontWeight.w600),
        ),
        style: OutlinedButton.styleFrom(
          side: const BorderSide(color: Colors.red),
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
    );
  }
}
