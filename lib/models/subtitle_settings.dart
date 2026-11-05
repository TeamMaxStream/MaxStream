import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SubtitleSettings {
  String textColor;
  String backgroundColor;
  double backgroundOpacity;
  double fontSize;
  String fontFamily;
  bool textShadow;
  String textShadowColor;
  String edgeType; // 'none', 'outline', 'dropShadow'
  String edgeColor;
  String position; // 'bottom', 'top'
  double subtitleOffsetMs;

  SubtitleSettings({
    this.textColor = '#FFFFFF',
    this.backgroundColor = '#000000',
    this.backgroundOpacity = 0.55,
    this.fontSize = 18,
    this.fontFamily = '',
    this.textShadow = true,
    this.textShadowColor = '#000000',
    this.edgeType = 'outline',
    this.edgeColor = '#000000',
    this.position = 'bottom',
    this.subtitleOffsetMs = 0,
  });

  static const String _prefsKey = 'subtitle_settings';

  Color get textColorParsed => _parseColor(textColor);
  Color get backgroundColorParsed => _parseColor(backgroundColor);
  Color get textShadowColorParsed => _parseColor(textShadowColor);
  Color get edgeColorParsed => _parseColor(edgeColor);

  static Color _parseColor(String hex) {
    hex = hex.replaceFirst('#', '');
    if (hex.length == 6) hex = 'FF$hex';
    return Color(int.parse(hex, radix: 16));
  }

  static String colorToHex(Color c) {
    return '#${c.value.toRadixString(16).substring(2).toUpperCase()}';
  }

  Map<String, dynamic> toJson() => {
    'textColor': textColor,
    'backgroundColor': backgroundColor,
    'backgroundOpacity': backgroundOpacity,
    'fontSize': fontSize,
    'fontFamily': fontFamily,
    'textShadow': textShadow,
    'textShadowColor': textShadowColor,
    'edgeType': edgeType,
    'edgeColor': edgeColor,
    'position': position,
    'subtitleOffsetMs': subtitleOffsetMs,
  };

  factory SubtitleSettings.fromJson(Map<String, dynamic> json) =>
      SubtitleSettings(
        textColor: json['textColor']?.toString() ?? '#FFFFFF',
        backgroundColor: json['backgroundColor']?.toString() ?? '#000000',
        backgroundOpacity:
            (json['backgroundOpacity'] as num?)?.toDouble() ?? 0.55,
        fontSize: (json['fontSize'] as num?)?.toDouble() ?? 18,
        fontFamily: json['fontFamily']?.toString() ?? '',
        textShadow: json['textShadow'] == true,
        textShadowColor: json['textShadowColor']?.toString() ?? '#000000',
        edgeType: json['edgeType']?.toString() ?? 'outline',
        edgeColor: json['edgeColor']?.toString() ?? '#000000',
        position: json['position']?.toString() ?? 'bottom',
        subtitleOffsetMs: (json['subtitleOffsetMs'] as num?)?.toDouble() ?? 0,
      );

  SubtitleSettings copy() => SubtitleSettings.fromJson(toJson());

  static Future<SubtitleSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null) return SubtitleSettings();
    try {
      return SubtitleSettings.fromJson(jsonDecode(raw));
    } catch (_) {
      return SubtitleSettings();
    }
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(toJson()));
  }

  static Future<void> saveFromJson(Map<String, dynamic> json) async {
    final settings = SubtitleSettings.fromJson(json);
    await settings.save();
  }
}
