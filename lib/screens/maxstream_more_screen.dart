import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/user_service.dart';
import '../services/auth_service.dart';
import '../services/biometric_service.dart';
import '../services/profile_scope.dart';
import '../screens/sign_in_screen.dart';
import '../screens/profile_settings_screen.dart';
import '../screens/profile_select_screen.dart';
import '../screens/streaming_provider_settings_screen.dart';
import '../screens/tv_pairing_screen.dart';
import '../screens/maxstream_about_screen.dart';
import '../screens/provider_health_screen.dart';
import '../screens/updates_screen.dart';
import '../screens/subtitle_settings_screen.dart';
import '../screens/downloads_settings_screen.dart';

import '../widgets/profile_avatar.dart';

class MaxStreamMoreScreen extends StatefulWidget {
  const MaxStreamMoreScreen({super.key});

  @override
  State<MaxStreamMoreScreen> createState() => _MaxStreamMoreScreenState();
}

class _MaxStreamMoreScreenState extends State<MaxStreamMoreScreen> {
  String _userName = 'MaxStream User';
  String _userEmail = 'user@maxstream.app';
  final UserService _userService = UserService();
  bool _biometricEnabled = false;

  @override
  void initState() {
    super.initState();
    _loadUserInfo();
    _userService.loadAvatar();
    _userService.loadProfilePicture();
    _loadBiometricPreference();
  }

  Future<void> _loadBiometricPreference() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted)
      setState(
        () => _biometricEnabled = prefs.getBool('biometric_lock') ?? false,
      );
  }

  void _loadUserInfo() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      setState(() {
        _userName = user.displayName ?? 'MaxStream User';
        _userEmail = user.email ?? 'user@maxstream.app';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text(
          'Settings',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            _buildUserSection(),
            const SizedBox(height: 20),
            _buildMenuItems(),
            const SizedBox(height: 100),
          ],
        ),
      ),
    );
  }

  Widget _buildUserSection() {
    return Container(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          ProfileAvatar(size: 80, userService: _userService),
          const SizedBox(height: 12),
          Text(
            _userName,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          if (_userEmail.isNotEmpty)
            Text(
              _userEmail,
              style: const TextStyle(color: Colors.grey, fontSize: 14),
            ),
          const SizedBox(height: 16),
          _buildProfileChip(),
        ],
      ),
    );
  }

  Widget _buildProfileChip() {
    final profile = ProfileScope.activeProfile.value;
    final isKids = ProfileScope.isKidsProfile;
    final profileName = ProfileScope.currentProfileName;

    return GestureDetector(
      onTap: () {
        if (!mounted) return;
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) =>
                const ProfileSelectScreen(isLaunchScreen: false),
          ),
        );
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: isKids
              ? const Color(0xFF132A42).withValues(alpha: 0.6)
              : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isKids
                ? const Color(0xFF10B981).withValues(alpha: 0.3)
                : Colors.white.withValues(alpha: 0.1),
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: isKids
                    ? const Color(0xFF10B981)
                    : (profile?.avatar.color ?? Colors.red),
                shape: BoxShape.circle,
              ),
              child: Icon(
                profile?.avatar.icon ?? Icons.person,
                color: Colors.white,
                size: 18,
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  profileName,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (isKids)
                  const Text(
                    'Kids Profile',
                    style: TextStyle(
                      color: Color(0xFF10B981),
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 8),
            Icon(Icons.chevron_right, color: Colors.grey[500], size: 18),
          ],
        ),
      ),
    );
  }

  Widget _buildMenuItems() {
    return Column(
      children: [
        _buildSectionHeader('SECURITY'),
        _buildBiometricToggle(),
        const SizedBox(height: 20),
        _buildSectionHeader('SETTINGS'),
        _buildMenuItem(
          icon: Icons.subtitles,
          title: 'Subtitle Settings',
          onTap: () {
            if (!mounted) return;
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => const SubtitleSettingsScreen(),
              ),
            );
          },
        ),
        _buildMenuItem(
          icon: Icons.download,
          title: 'Download Settings',
          onTap: () {
            if (!mounted) return;
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => const DownloadsSettingsScreen(),
              ),
            );
          },
        ),
        _buildMenuItem(
          icon: Icons.person,
          title: 'Profile Settings',
          onTap: () {
            if (!mounted) return;
            Navigator.push(
              context,
              PageRouteBuilder(
                pageBuilder: (context, animation, secondaryAnimation) =>
                    const ProfileSettingsScreen(),
                transitionsBuilder:
                    (context, animation, secondaryAnimation, child) {
                      return SlideTransition(
                        position:
                            Tween<Offset>(
                              begin: const Offset(1.0, 0.0),
                              end: Offset.zero,
                            ).animate(
                              CurvedAnimation(
                                parent: animation,
                                curve: Curves.fastOutSlowIn,
                              ),
                            ),
                        child: child,
                      );
                    },
                transitionDuration: const Duration(milliseconds: 250),
              ),
            );
          },
        ),
        _buildMenuItem(
          icon: Icons.tv,
          title: 'Streaming Services',
          onTap: () {
            if (!mounted) return;
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => const StreamingProviderSettingsScreen(),
              ),
            );
          },
        ),
        _buildMenuItem(
          icon: Icons.tv_outlined,
          title: 'TV Pairing',
          onTap: () {
            if (!mounted) return;
            Navigator.push(
              context,
              PageRouteBuilder(
                pageBuilder: (context, animation, secondaryAnimation) =>
                    const TVPairingScreen(),
                transitionsBuilder:
                    (context, animation, secondaryAnimation, child) {
                      return SlideTransition(
                        position:
                            Tween<Offset>(
                              begin: const Offset(1.0, 0.0),
                              end: Offset.zero,
                            ).animate(
                              CurvedAnimation(
                                parent: animation,
                                curve: Curves.fastOutSlowIn,
                              ),
                            ),
                        child: child,
                      );
                    },
                transitionDuration: const Duration(milliseconds: 250),
              ),
            );
          },
        ),
        _buildMenuItem(
          icon: Icons.health_and_safety,
          title: 'Provider Health',
          onTap: () {
            if (!mounted) return;
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => const ProviderHealthScreen(),
              ),
            );
          },
        ),
        _buildMenuItem(
          icon: Icons.system_update,
          title: 'Updates',
          onTap: () {
            if (!mounted) return;
            Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => const UpdatesScreen()),
            );
          },
        ),
        _buildMenuItem(
          icon: Icons.info_outline,
          title: 'About',
          onTap: () {
            if (!mounted) return;
            Navigator.push(
              context,
              PageRouteBuilder(
                pageBuilder: (context, animation, secondaryAnimation) =>
                    const MaxStreamAboutScreen(),
                transitionsBuilder:
                    (context, animation, secondaryAnimation, child) {
                      return SlideTransition(
                        position:
                            Tween<Offset>(
                              begin: const Offset(1.0, 0.0),
                              end: Offset.zero,
                            ).animate(
                              CurvedAnimation(
                                parent: animation,
                                curve: Curves.fastOutSlowIn,
                              ),
                            ),
                        child: child,
                      );
                    },
                transitionDuration: const Duration(milliseconds: 250),
              ),
            );
          },
        ),
        const SizedBox(height: 20),
        _buildMenuItem(
          icon: Icons.logout,
          title: 'Sign Out',
          onTap: () {
            _signOut();
          },
          isDestructive: true,
        ),
      ],
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          title,
          style: TextStyle(
            color: Colors.grey[500],
            fontSize: 12,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.2,
          ),
        ),
      ),
    );
  }

  Widget _buildBiometricToggle() {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      child: ListTile(
        leading: const Icon(Icons.fingerprint, color: Colors.white),
        title: const Text(
          'Biometric Lock',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w500),
        ),
        subtitle: Text(
          _biometricEnabled
              ? 'Tap to disable'
              : 'Tap to enable (requires authentication)',
          style: TextStyle(color: Colors.grey[500], fontSize: 12),
        ),
        trailing: Switch(
          value: _biometricEnabled,
          onChanged: (value) async {
            if (value) {
              // Check if biometric is available
              final available = await BiometricService.canUseBiometric();
              if (!available) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'Biometric authentication not available. Please set up a screen lock on your device first.',
                      ),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
                return;
              }

              // Prompt user to authenticate to verify they can use biometrics
              final biometrics =
                  await BiometricService.getAvailableBiometrics();
              String reason = 'Authenticate to enable biometric lock';
              if (biometrics.contains(BiometricType.face)) {
                reason = 'Scan your face to enable biometric lock';
              } else if (biometrics.contains(BiometricType.fingerprint)) {
                reason = 'Scan your fingerprint to enable biometric lock';
              }

              final result = await BiometricService.authenticateDetailed(
                reason: reason,
                biometricOnly: false, // Allow PIN/password fallback
              );

              if (!result.success) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        result.error ?? 'Authentication failed.',
                      ),
                      backgroundColor: Colors.orange,
                    ),
                  );
                }
                return;
              }
            }

            final prefs = await SharedPreferences.getInstance();
            if (mounted) {
              setState(() => _biometricEnabled = value);
              await prefs.setBool('biometric_lock', value);
              if (value) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Biometric lock enabled. You will be prompted on next app launch.',
                    ),
                    backgroundColor: Colors.green,
                  ),
                );
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Biometric lock disabled.'),
                    backgroundColor: Colors.grey,
                  ),
                );
              }
            }
          },
          activeColor: Colors.green,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        tileColor: Colors.transparent,
        hoverColor: Colors.white.withAlpha(12),
        splashColor: Colors.white.withAlpha(25),
      ),
    );
  }

  Widget _buildMenuItem({
    required IconData icon,
    required String title,
    required VoidCallback onTap,
    bool isDestructive = false,
  }) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      child: ListTile(
        leading: Icon(icon, color: isDestructive ? Colors.red : Colors.white),
        title: Text(
          title,
          style: TextStyle(
            color: isDestructive ? Colors.red : Colors.white,
            fontWeight: FontWeight.w500,
          ),
        ),
        trailing: const Icon(
          Icons.arrow_forward_ios,
          color: Colors.grey,
          size: 16,
        ),
        onTap: onTap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        tileColor: Colors.transparent,
        hoverColor: Colors.white.withAlpha(12),
        splashColor: Colors.white.withAlpha(25),
      ),
    );
  }

  void _signOut() async {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('Sign Out', style: TextStyle(color: Colors.white)),
        content: const Text(
          'Are you sure you want to sign out?',
          style: TextStyle(color: Colors.white),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              try {
                await ProfileScope.clear();
                await AuthService.signOut();
                if (mounted) {
                  Navigator.pushAndRemoveUntil(
                    context,
                    MaterialPageRoute(builder: (_) => const SignInScreen()),
                    (route) => false,
                  );
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Error signing out: $e'),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              }
            },
            child: const Text('Sign Out', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}
