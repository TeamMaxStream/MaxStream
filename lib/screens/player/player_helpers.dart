part of '../m3u8_video_player_screen.dart';

extension _PlayerHelpers on _M3U8VideoPlayerScreenState {
  String _sourceLabel(
    Map<String, dynamic>? stream, {
    String fallback = 'Server',
  }) {
    final source = stream?['source']?.toString() ?? fallback;
    final method = stream?['method']?.toString();
    return method != null ? '$source ($method)' : source;
  }

  List<_StreamQuality> _parseQualities(dynamic value) {
    if (value is! List) return const [];
    return value
        .whereType<Map>()
        .map((quality) {
          return _StreamQuality(
            label: quality['label']?.toString() ?? 'Auto',
            url: quality['url']?.toString() ?? '',
            height: int.tryParse(quality['height']?.toString() ?? '') ?? 0,
          );
        })
        .where((quality) => quality.url.isNotEmpty)
        .toList();
  }

  List<_SubtitleTrack> _parseSubtitleTracks(dynamic value) {
    if (value is! List) return const [];
    return value
        .whereType<Map>()
        .map(
          (subtitle) => _SubtitleTrack(
            label: subtitle['label']?.toString() ?? 'Subtitle',
            url: subtitle['url']?.toString() ?? '',
            isDefault: subtitle['default'] == true,
            source: subtitle['source']?.toString() ?? '',
          ),
        )
        .where((subtitle) => subtitle.url.isNotEmpty)
        .toList();
  }

  /// Unions the subtitle tracks of every discovered server so subtitles from
  /// other servers are available when the current one has none (e.g. RPM).
  /// Tracks are tagged with the owning server's display label (for grouping)
  /// and headers (for fetching).
  List<_SubtitleTrack> _unionSubtitleTracks() {
    final result = <_SubtitleTrack>[];
    final seen = <String>{};
    // The currently playing server's group goes first so its subtitles are
    // the easiest to reach; the rest follow in discovery order.
    final servers = [..._availableServers]
      ..sort((a, b) {
        final aSelected = _serverIdentity(a) == _selectedServerKey ? 0 : 1;
        final bSelected = _serverIdentity(b) == _selectedServerKey ? 0 : 1;
        return aSelected - bSelected;
      });
    for (final server in servers) {
      final source = server['source']?.toString() ?? 'Server';
      final route = server['server']?.toString() ?? source;
      final group = route == source ? source : '$source via $route';
      final headers = _parseStreamHeaders(server);
      for (final track in _parseSubtitleTracks(server['subtitles'])) {
        if (!seen.add(track.url)) continue;
        result.add(
          _SubtitleTrack(
            label: track.label,
            url: track.url,
            isDefault: track.isDefault,
            source: track.source,
            group: group,
            headers: headers,
          ),
        );
      }
    }
    // Online-search downloads survive server/quality re-unions.
    for (final track in _onlineSubtitleTracks) {
      if (!seen.add(track.url)) continue;
      result.add(track);
    }
    return result;
  }

  /// English subtitle of the server being switched to: "English",
  /// "English CC", "British English" or a bare `en`/`eng` code. Prefers the
  /// target server's own group, then a captioned (CC/SDH) track within it.
  _SubtitleTrack? _pickEnglishSubtitleTrack(String group) {
    bool english(String label) {
      final tokens = label
          .toLowerCase()
          .split(RegExp(r'[^a-z0-9]+'))
          .where((t) => t.isNotEmpty);
      return tokens.any((t) => t == 'english' || t == 'en' || t == 'eng');
    }

    bool captioned(String label) {
      final tokens = label.toLowerCase().split(RegExp(r'[^a-z0-9]+'));
      return tokens.any(
        (t) =>
            t == 'cc' ||
            t == 'sdh' ||
            t == 'caption' ||
            t == 'captions' ||
            t.startsWith('hearing'),
      );
    }

    final englishTracks = _subtitleTracks
        .where((t) => english(t.label))
        .toList();
    if (englishTracks.isEmpty) return null;
    final own = englishTracks.where((t) => t.group == group).toList();
    final pool = own.isNotEmpty ? own : englishTracks;
    final captionedTracks = pool.where((t) => captioned(t.label)).toList();
    return (captionedTracks.isNotEmpty ? captionedTracks : pool).first;
  }

  /// Display identity for a subtitle tile: owning server group + track label.
  /// Used both as the selection value and the subtitle button label, so the
  /// value stays unique across servers (e.g. "RPM via Vidflix · English").
  String _subtitleTileValue(_SubtitleTrack track) {
    final group = track.group.isNotEmpty
        ? track.group
        : (track.source.isEmpty ? 'Other' : track.source);
    return '$group · ${track.label}';
  }

  Map<String, String> _parseStreamHeaders(Map<String, dynamic> stream) {
    final headers = <String, String>{};
    if (stream['referer'] != null) {
      headers['Referer'] = stream['referer'].toString();
    }
    final rawHeaders = stream['headers'];
    if (rawHeaders is Map) {
      rawHeaders.forEach((key, value) {
        headers[key.toString()] = value.toString();
      });
    }
    return headers;
  }

  /// Stable identity for a server entry: the provider/server name from the
  /// extractor (e.g. "RPM video"), falling back to the source name or URL.
  String _serverIdentity(Map<String, dynamic> stream) {
    final server = stream['server']?.toString();
    if (server != null && server.isNotEmpty) return server;
    final source = stream['source']?.toString();
    if (source != null && source.isNotEmpty) return source;
    return stream['url']?.toString() ?? '';
  }
}
