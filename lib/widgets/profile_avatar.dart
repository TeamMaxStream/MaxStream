import 'package:flutter/material.dart';
import 'dart:io';
import '../services/user_service.dart';

class ProfileAvatar extends StatelessWidget {
  final double size;
  final UserService userService;
  final VoidCallback? onTap;

  const ProfileAvatar({
    super.key,
    this.size = 80,
    required this.userService,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String?>(
      valueListenable: userService.profilePictureUrl,
      builder: (context, profilePictureUrl, child) {
        return ValueListenableBuilder<String>(
          valueListenable: userService.avatar,
          builder: (context, selectedAvatar, child) {
            final hasProfilePicture =
                profilePictureUrl != null &&
                File(profilePictureUrl).existsSync();

            final container = Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                color: Colors.red,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 3),
              ),
              child: hasProfilePicture
                  ? ClipOval(
                      child: Image.file(
                        File(profilePictureUrl),
                        fit: BoxFit.cover,
                      ),
                    )
                  : Center(
                      child: Text(
                        selectedAvatar.isNotEmpty ? selectedAvatar : '🐰',
                        style: TextStyle(fontSize: size * 0.65),
                      ),
                    ),
            );

            if (onTap != null) {
              return GestureDetector(onTap: onTap, child: container);
            }

            return container;
          },
        );
      },
    );
  }
}
