part of '../m3u8_video_player_screen.dart';

class _StreamQuality {
  const _StreamQuality({
    required this.label,
    required this.url,
    required this.height,
  });

  final String label;
  final String url;
  final int height;
}

class _SubtitleTrack {
  const _SubtitleTrack({
    required this.label,
    required this.url,
    required this.isDefault,
    this.source = '',
    this.group = '',
    this.headers = const {},
  });

  final String label;
  final String url;
  final bool isDefault;
  final String source;

  /// Server display label the track belongs to (e.g. "VidLink via Worker"),
  /// used to group cross-server subtitle fallback options.
  final String group;

  /// HTTP headers of the server that provided this track, so a subtitle
  /// picked from another server is fetched with the right referer/cookies.
  final Map<String, String> headers;
}

class Subtitle {
  const Subtitle({
    required this.index,
    required this.start,
    required this.end,
    required this.text,
  });

  final int index;
  final Duration start;
  final Duration end;
  final String text;
}

enum _AspectRatioMode { fit, stretch, zoom }
