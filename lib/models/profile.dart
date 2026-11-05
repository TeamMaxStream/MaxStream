import 'dart:convert';
import 'package:flutter/material.dart';

/// All supported profile icons as const entries — used by the tree-shake
/// icon build pass which requires every IconData to be a const expression.
const Map<int, IconData> kProfileIcons = {
  0xe4ff: Icons.person,
  0xe038: Icons.movie,
  0xe30f: Icons.sports_esports,
  0xe301: Icons.music_note,
  0xe838: Icons.star,
  0xe558: Icons.rocket_launch,
  0xe06d: Icons.auto_awesome,
  0xe91a: Icons.pets,
  0xe3a8: Icons.brush,
  0xe0e3: Icons.psychology,
  0xe0ca: Icons.public,
  0xe537: Icons.bolt,
};

/// Material 3 profile avatar: a color from a preset palette + a Material icon.
class ProfileAvatar {
  final int colorIndex;
  final int iconCodePoint;

  const ProfileAvatar({
    this.colorIndex = 0,
    this.iconCodePoint = 0xe4ff, // Icons.person code point
  });

  /// The preset color palette — vibrant, modern, distinguishable.
  static const List<Color> palette = [
    Color(0xFFE50914), // Red (MaxStream brand)
    Color(0xFF6366F1), // Indigo
    Color(0xFF8B5CF6), // Violet
    Color(0xFFEC4899), // Pink
    Color(0xFFF59E0B), // Amber
    Color(0xFF10B981), // Emerald
    Color(0xFF06B6D4), // Cyan
    Color(0xFF3B82F6), // Blue
    Color(0xFFEF4444), // Rose
    Color(0xFF14B8A6), // Teal
    Color(0xFFF97316), // Orange
    Color(0xFFA855F7), // Purple
  ];

  /// Available icons for profiles.
  static const List<IconData> icons = [
    Icons.person,
    Icons.movie,
    Icons.sports_esports,
    Icons.music_note,
    Icons.star,
    Icons.rocket_launch,
    Icons.auto_awesome,
    Icons.pets,
    Icons.brush,
    Icons.psychology,
    Icons.public,
    Icons.bolt,
  ];

  Color get color => palette[colorIndex % palette.length];
  IconData get icon => icons.firstWhere(
    (i) => i.codePoint == iconCodePoint,
    orElse: () => Icons.person,
  );

  Map<String, dynamic> toJson() => {
    'colorIndex': colorIndex,
    'iconCodePoint': iconCodePoint,
  };

  factory ProfileAvatar.fromJson(Map<String, dynamic> json) {
    return ProfileAvatar(
      colorIndex: json['colorIndex'] as int? ?? 0,
      iconCodePoint: json['iconCodePoint'] as int? ?? 0xe4ff,
    );
  }

  String encode() => jsonEncode(toJson());
  factory ProfileAvatar.decode(String source) =>
      ProfileAvatar.fromJson(jsonDecode(source) as Map<String, dynamic>);
}

class Profile {
  final String id;
  final String name;
  final ProfileAvatar avatar;
  final bool isKids;
  final String? pinHash;
  final DateTime createdAt;

  const Profile({
    required this.id,
    required this.name,
    this.avatar = const ProfileAvatar(),
    this.isKids = false,
    this.pinHash,
    required this.createdAt,
  });

  Profile copyWith({
    String? name,
    ProfileAvatar? avatar,
    bool? isKids,
    String? pinHash,
    bool clearPin = false,
  }) {
    return Profile(
      id: id,
      name: name ?? this.name,
      avatar: avatar ?? this.avatar,
      isKids: isKids ?? this.isKids,
      pinHash: clearPin ? null : (pinHash ?? this.pinHash),
      createdAt: createdAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'avatar': avatar.toJson(),
    'isKids': isKids,
    'pinHash': pinHash,
    'createdAt': createdAt.toIso8601String(),
  };

  factory Profile.fromJson(Map<String, dynamic> json) {
    return Profile(
      id: json['id'] as String,
      name: json['name'] as String? ?? 'Profile',
      avatar: json['avatar'] != null
          ? ProfileAvatar.fromJson(
              Map<String, dynamic>.from(json['avatar'] as Map),
            )
          : const ProfileAvatar(),
      isKids: json['isKids'] as bool? ?? false,
      pinHash: json['pinHash'] as String?,
      createdAt: json['createdAt'] != null
          ? DateTime.parse(json['createdAt'] as String)
          : DateTime.now(),
    );
  }

  String encode() => jsonEncode(toJson());

  factory Profile.decode(String source) =>
      Profile.fromJson(jsonDecode(source) as Map<String, dynamic>);

  static String generateId() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final random = (now % 100000).toString().padLeft(5, '0');
    return 'p_${now}_$random';
  }
}
