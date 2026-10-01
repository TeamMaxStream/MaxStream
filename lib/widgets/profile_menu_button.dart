import 'dart:async';

import 'package:flutter/material.dart';
import '../models/profile.dart';
import '../services/profile_scope.dart';
import '../screens/profile_select_screen.dart';
import '../screens/maxstream_more_screen.dart';

class ProfileMenuButton extends StatefulWidget {
  const ProfileMenuButton({super.key});

  @override
  State<ProfileMenuButton> createState() => _ProfileMenuButtonState();
}

class _ProfileMenuButtonState extends State<ProfileMenuButton> {
  @override
  void initState() {
    super.initState();
    // ensureInitialized (not initialize): concurrent callers must share the one
    // in-flight future. A second initialize() call returned early while the
    // profile was still unresolved, leaving this scope half-initialized.
    unawaited(ProfileScope.ensureInitialized());
  }

  void _openSettings() {
    Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const MaxStreamMoreScreen(),
        transitionsBuilder: (_, animation, __, child) => SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(1.0, 0.0),
            end: Offset.zero,
          ).animate(CurvedAnimation(
            parent: animation,
            curve: Curves.fastOutSlowIn,
          )),
          child: child,
        ),
        transitionDuration: const Duration(milliseconds: 250),
      ),
    );
  }

  void _switchProfile() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const ProfileSelectScreen(isLaunchScreen: false),
      ),
    ).then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Profile?>(
      valueListenable: ProfileScope.activeProfile,
      builder: (context, activeProfile, _) {
        final avatar = activeProfile?.avatar ?? const ProfileAvatar();
        final avatarColor = avatar.color;
        final avatarIcon = avatar.icon;
        final profileName = activeProfile?.name ?? 'Profile';

        return GestureDetector(
          onTap: () => _showProfileMenu(context, activeProfile),
          child: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: avatarColor,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: avatarColor.withValues(alpha: 0.4),
                  blurRadius: 8,
                ),
              ],
            ),
            child: Icon(
              avatarIcon,
              color: Colors.white,
              size: 18,
            ),
          ),
        );
      },
    );
  }

  void _showProfileMenu(BuildContext context, Profile? activeProfile) {
    final profiles = ProfileScope.profiles.value;
    final activeId = activeProfile?.id;

    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        MediaQuery.of(context).size.width - 20,
        MediaQuery.of(context).padding.top + kToolbarHeight + 8,
        16,
        0,
      ),
      color: const Color(0xFF1E1E1E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      items: [
        // Current profile header
        PopupMenuItem<String>(
          enabled: false,
          child: _buildProfileHeader(activeProfile),
        ),
        const PopupMenuDivider(height: 1, color: Colors.grey),
        // Switch Profile option
        PopupMenuItem<String>(
          value: 'switch_profile',
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: const Row(
              children: [
                Icon(Icons.swap_horiz, color: Colors.white, size: 20),
                SizedBox(width: 12),
                Text(
                  'Switch Profile',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
        // All profiles list
        if (profiles.length > 1) ...[
          const PopupMenuDivider(height: 1, color: Colors.grey),
          ...profiles.map((profile) {
            final isActive = profile.id == activeId;
            final pColor = profile.avatar.color;
            final pIcon = profile.avatar.icon;
            return PopupMenuItem<String>(
              value: 'profile_${profile.id}',
              enabled: !isActive,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: pColor,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(pIcon, color: Colors.white, size: 14),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            profile.name,
                            style: TextStyle(
                              color: isActive ? Colors.white70 : Colors.white,
                              fontSize: 14,
                              fontWeight:
                                  isActive ? FontWeight.bold : FontWeight.w500,
                            ),
                          ),
                          if (profile.isKids)
                            const Text(
                              'KIDS',
                              style: TextStyle(
                                color: Colors.green,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (isActive)
                      const Icon(Icons.check, color: Colors.red, size: 18),
                  ],
                ),
              ),
            );
          }),
        ],
        const PopupMenuDivider(height: 1, color: Colors.grey),
        PopupMenuItem<String>(
          value: 'settings',
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: const Row(
              children: [
                Icon(Icons.settings, color: Colors.white, size: 20),
                SizedBox(width: 12),
                Text(
                  'Settings',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    ).then((value) {
      if (!mounted) return;
      if (value == 'settings') {
        _openSettings();
      } else if (value == 'switch_profile') {
        _switchProfile();
      } else if (value != null && value.startsWith('profile_')) {
        final profileId = value.replaceFirst('profile_', '');
        ProfileScope.selectProfile(profileId);
        setState(() {});
      }
    });
  }

  Widget _buildProfileHeader(Profile? profile) {
    if (profile == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text(
          'No profile selected',
          style: TextStyle(color: Colors.grey, fontSize: 14),
        ),
      );
    }

    final avatar = profile.avatar;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: avatar.color,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: avatar.color.withValues(alpha: 0.4),
                  blurRadius: 8,
                ),
              ],
            ),
            child: Icon(avatar.icon, color: Colors.white, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  profile.name,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const Text(
                  'Currently watching',
                  style: TextStyle(
                    color: Colors.grey,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
