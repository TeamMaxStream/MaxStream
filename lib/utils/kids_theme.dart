import 'package:flutter/material.dart';
import '../services/profile_scope.dart';

/// Kids profile UI theme — brighter, more playful colors.
class KidsTheme {
  KidsTheme._();

  static bool get isKids => ProfileScope.activeProfile.value?.isKids ?? false;

  // ── Accent Colors ──────────────────────────────────────────────────
  static Color get primary =>
      isKids ? const Color(0xFF10B981) : const Color(0xFFE50914);
  static Color get secondary =>
      isKids ? const Color(0xFF06B6D4) : const Color(0xFFE50914);
  static Color get accent =>
      isKids ? const Color(0xFFF59E0B) : const Color(0xFFE50914);

  // ── Background ─────────────────────────────────────────────────────
  static Color get background =>
      isKids ? const Color(0xFF0A1628) : const Color(0xFF121212);
  static Color get surface =>
      isKids ? const Color(0xFF0F2035) : const Color(0xFF1A1A1A);
  static Color get cardBg =>
      isKids ? const Color(0xFF132A42) : const Color(0xFF1E1E1E);

  // ── Text ───────────────────────────────────────────────────────────
  static Color get textPrimary => isKids ? Colors.white : Colors.white;
  static Color get textSecondary =>
      isKids ? const Color(0xFF94D2BD) : const Color(0xFFAAAAAA);
  static Color get textMuted =>
      isKids ? const Color(0xFF6B9080) : const Color(0xFF666666);

  // ── Buttons ────────────────────────────────────────────────────────
  static Color get buttonPrimary =>
      isKids ? const Color(0xFF10B981) : const Color(0xFFE50914);
  static Color get buttonSecondary =>
      isKids ? const Color(0xFF06B6D4) : Colors.white;

  // ── Navigation ─────────────────────────────────────────────────────
  static Color get navSelected =>
      isKids ? const Color(0xFF10B981) : const Color(0xFFE50914);
  static Color get navUnselected =>
      isKids ? const Color(0xFF4A7C6F) : const Color(0xFF888888);

  // ── Gradients ──────────────────────────────────────────────────────
  static LinearGradient get heroGradient => isKids
      ? const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF0A1628), Color(0xFF132A42), Color(0xFF0A1628)],
        )
      : const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF121212), Color(0xFF1A1A1A), Color(0xFF121212)],
        );

  // ── Profile Colors ─────────────────────────────────────────────────
  static List<Color> get profileColors => isKids
      ? const [
          Color(0xFF10B981), // Emerald
          Color(0xFF06B6D4), // Cyan
          Color(0xFFF59E0B), // Amber
          Color(0xFFEC4899), // Pink
          Color(0xFF8B5CF6), // Violet
          Color(0xFF3B82F6), // Blue
        ]
      : const [
          Color(0xFFE50914), // Red
          Color(0xFF6366F1), // Indigo
          Color(0xFF8B5CF6), // Violet
          Color(0xFFEC4899), // Pink
          Color(0xFFF59E0B), // Amber
          Color(0xFF10B981), // Emerald
        ];
}
