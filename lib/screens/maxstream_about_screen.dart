import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

class MaxStreamAboutScreen extends StatefulWidget {
  const MaxStreamAboutScreen({super.key});

  @override
  State<MaxStreamAboutScreen> createState() => _MaxStreamAboutScreenState();
}

class _MaxStreamAboutScreenState extends State<MaxStreamAboutScreen> {
  String _version = 'v1.6.0';
  String _variant = '...';

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      String variant = 'unknown';
      try {
        if (Platform.isAndroid) {
          variant = await const MethodChannel('com.maxstream.app/install')
              .invokeMethod<String>('getArch') ?? _getArchFromAbi();
        }
      } catch (_) {
        variant = _getArchFromAbi();
      }
      if (mounted) {
        setState(() {
          _version = 'v${info.version}';
          _variant = variant;
        });
      }
    } catch (_) {}
  }

  String _getArchFromAbi() {
    try {
      final abi = Platform.operatingSystemVersion;
      if (abi.contains('arm64') || abi.contains('aarch64')) return 'arm64-v8a';
      if (abi.contains('arm')) return 'armeabi-v7a';
      if (abi.contains('x86_64') || abi.contains('amd64')) return 'x86_64';
    } catch (_) {}
    return 'unknown';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            backgroundColor: const Color(0xFF0A0A0A),
            title: const Text(
              'About',
              style: TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildHeroSection(),
                  const SizedBox(height: 32),
                  _buildSectionTitle('About MaxStream'),
                  const SizedBox(height: 12),
                  _buildInfoCard(
                    icon: Icons.info_outline,
                    title: 'What is MaxStream?',
                    content:
                        'MaxStream is a modern movie and TV discovery app powered by '
                        'The Movie Database (TMDB). Discover, explore, and manage your '
                        'watchlist with ease.',
                  ),
                  const SizedBox(height: 8),
                  _buildInfoCard(
                    icon: Icons.code,
                    title: 'Version',
                    content: _version,
                  ),
                  const SizedBox(height: 8),
                  _buildInfoCard(
                    icon: Icons.architecture,
                    title: 'Variant',
                    content: _variant,
                  ),
                  const SizedBox(height: 32),
                  _buildSectionTitle('Get Help'),
                  const SizedBox(height: 12),
                  _buildActionCard(
                    icon: Icons.help_outline,
                    title: 'Help & Support',
                    subtitle: 'Get help with using MaxStream',
                    onTap: () => _showHelpDialog(context),
                  ),
                  const SizedBox(height: 32),
                  _buildSectionTitle('Community'),
                  const SizedBox(height: 12),
                  _buildActionCard(
                    icon: Icons.telegram,
                    title: 'Join Our Community',
                    subtitle: 'Connect with other MaxStream users',
                    onTap: () => _launchUrl('https://t.me/maxstream254'),
                  ),
                  const SizedBox(height: 32),
                  _buildSectionTitle('Website'),
                  const SizedBox(height: 12),
                  _buildActionCard(
                    icon: Icons.language,
                    title: 'Official Website',
                    subtitle: 'https://maxstreamweb.vercel.app',
                    onTap: () => _launchUrl('https://maxstreamweb.vercel.app/'),
                  ),
                  const SizedBox(height: 12),
                  _buildActionCard(
                    icon: Icons.code,
                    title: 'GitHub Repository',
                    subtitle: 'https://github.com/TeamMaxStream/MaxStream',
                    onTap: () => _launchUrl('https://github.com/TeamMaxStream/MaxStream'),
                  ),
                  const SizedBox(height: 32),
                  _buildSectionTitle('Legal'),
                  const SizedBox(height: 12),
                  _buildInfoCard(
                    icon: Icons.gavel,
                    title: 'TMDB Attribution',
                    content:
                        'This product uses the TMDB API but is not endorsed or '
                        'certified by TMDB. All movie and TV show data is provided '
                        'by The Movie Database.',
                  ),
                  const SizedBox(height: 100),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeroSection() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Colors.red.withValues(alpha: 0.2),
            Colors.red.withValues(alpha: 0.05),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Colors.red.withValues(alpha: 0.2),
        ),
      ),
      child: Column(
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: Colors.red,
              borderRadius: BorderRadius.circular(16),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Image.asset(
                'assets/images/app_icon.png',
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) => const Icon(
                  Icons.play_arrow,
                  color: Colors.white,
                  size: 40,
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'MaxStream',
            style: TextStyle(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _version,
            style: TextStyle(
              color: Colors.grey[500],
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Discover. Watch. Enjoy.',
            style: TextStyle(
              color: Colors.grey[400],
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Text(
      title,
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
    required String content,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
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
                const SizedBox(height: 4),
                Text(
                  content,
                  style: TextStyle(
                    color: Colors.grey[400],
                    fontSize: 13,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.08),
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: Colors.red, size: 22),
            ),
            const SizedBox(width: 14),
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
                    style: TextStyle(
                      color: Colors.grey[500],
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.arrow_forward_ios,
              color: Colors.grey[600],
              size: 14,
            ),
          ],
        ),
      ),
    );
  }

  void _showHelpDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Help & Support',
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          'For help and support, please join our community or contact us through the app.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  Future<void> _launchUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
}
