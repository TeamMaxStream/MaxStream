part of '../m3u8_video_player_screen.dart';

extension _SubtitleLoader on _M3U8VideoPlayerScreenState {
  Future<List<Subtitle>> _fetchSubtitles(
    _SubtitleTrack track,
    Map<String, String> headers,
  ) async {
    final localFile = File(track.url);
    if (await localFile.exists()) {
      final input = await localFile.readAsString();
      // Legacy local subtitle downloads may have saved an HLS subtitle playlist
      // (M3U8) instead of cues. Best effort: merge any segments that exist
      // locally next to the file so the file still plays.
      if (input.trimLeft().startsWith('#EXTM3U')) {
        final merged = await _mergeLocalSubtitleHls(input, localFile);
        if (merged.isNotEmpty) return merged;
      }
      final subtitles = _parseSubtitleFile(input);
      if (subtitles.isEmpty) {
        throw const FormatException(
          'The downloaded subtitle contained no valid timed cues',
        );
      }
      return subtitles;
    }
    final uri = Uri.parse(track.url);
    if (uri.host.isEmpty) {
      throw Exception('Invalid subtitle URL: ${track.url}');
    }

    // Try the direct URL first
    final urlsToTry = <String>[track.url];

    // For RPM-style subtitles, try alternative URL patterns
    if (track.url.contains('.vtt') && !track.url.startsWith('http')) {
      // Already handled by URL construction
    } else if (track.url.contains('.vtt') || track.url.contains('.srt')) {
      // Try without fragment
      final urlNoFragment = track.url.split('#')[0];
      if (urlNoFragment != track.url) urlsToTry.add(urlNoFragment);
    }

    // For opensubtitles URLs, try with different headers
    if (track.url.contains('opensubtitles')) {
      urlsToTry.add(track.url);
    }

    Exception? lastError;
    for (final url in urlsToTry) {
      try {
        final parsedUri = Uri.parse(url);
        final inheritedHeaders = track.source == 'Vidflix'
            ? const <String, String>{}
            : headers;
        final response = await http
            .get(
              parsedUri,
              headers: {
                ...inheritedHeaders,
                'User-Agent':
                    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
                'Accept': 'text/vtt, application/x-subrip, text/plain, */*',
              },
            )
            .timeout(const Duration(seconds: 10));
        if (response.statusCode >= 200 && response.statusCode < 300) {
          final body = utf8.decode(response.bodyBytes, allowMalformed: true);
          if (body.trim().isNotEmpty) {
            // HLS subtitle playlists (source == 'HLS') return an M3U8 that
            // references individual .vtt segment files.  Fetch each segment
            // and concatenate into a single WEBVTT document.
            if (track.source == 'HLS' ||
                body.trimLeft().toUpperCase().startsWith('#EXTM3U')) {
              try {
                final vtt = await _resolveHlsSubtitlePlaylist(
                  body,
                  url,
                  headers,
                );
                final subtitles = _parseSubtitleFile(vtt);
                if (subtitles.isNotEmpty) return subtitles;
              } catch (_) {
                // Fall through to normal parsing below.
              }
            }
            final subtitles = _parseSubtitleFile(body);
            if (subtitles.isNotEmpty) return subtitles;
            lastError = const FormatException(
              'The subtitle file contained no valid timed cues',
            );
            continue;
          }
        }
        lastError = Exception('HTTP ${response.statusCode}');
      } catch (e) {
        lastError = e is Exception ? e : Exception(e.toString());
      }
    }
    throw lastError ?? Exception('Failed to load subtitles');
  }

  /// Best-effort merge of a locally saved HLS subtitle playlist (M3U8) where
  /// the referenced segment files were downloaded alongside it. Returns '' if
  /// the segments aren't present so the caller can fall back to normal
  /// parsing (and surface the missing-cues error).
  Future<List<Subtitle>> _mergeLocalSubtitleHls(
    String input,
    File playlistFile,
  ) async {
    final directory = playlistFile.parent.existsSync()
        ? playlistFile.parent
        : Directory.current;
    final parts = <String>[];
    for (final line in const LineSplitter().convert(input)) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      final segment = File(p.join(directory.path, p.basename(trimmed)));
      if (!await segment.exists()) continue;
      final text = await segment.readAsString();
      final cueText = text.trim();
      if (cueText.isEmpty) continue;
      parts.add(
        cueText.startsWith('WEBVTT')
            ? cueText.replaceFirst(RegExp('^WEBVTT.*\$', multiLine: true), '')
            : cueText,
      );
    }
    if (parts.isEmpty) return const [];
    return _parseSubtitleFile('WEBVTT\n\n${parts.join('\n\n')}\n');
  }

  /// Resolves an HLS subtitle playlist (M3U8) into a single WEBVTT string.
  ///
  /// HLS subtitle tracks declare `#EXT-X-MEDIA:TYPE=SUBTITLES` in the master
  /// with a URI pointing to an M3U8 segment playlist.  That playlist
  /// references individual `.vtt` files.  This method fetches each VTT segment
  /// and concatenates them into one WEBVTT document that our VTT parser can
  /// handle.
  Future<String> _resolveHlsSubtitlePlaylist(
    String m3u8Body,
    String playlistUrl,
    Map<String, String> headers,
  ) async {
    final baseUri = Uri.parse(playlistUrl);
    final segmentUrls = <String>[];
    for (final raw in m3u8Body.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      // Non-comment, non-empty line = segment reference
      final resolved = baseUri.resolve(line);
      segmentUrls.add(resolved.toString());
    }
    if (segmentUrls.isEmpty) {
      throw const FormatException(
        'HLS subtitle playlist contained no segments',
      );
    }

    final parts = <String>[];
    for (final segUrl in segmentUrls) {
      try {
        final resp = await http
            .get(
              Uri.parse(segUrl),
              headers: {
                ...headers,
                'User-Agent':
                    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
              },
            )
            .timeout(const Duration(seconds: 5));
        if (resp.statusCode >= 200 && resp.statusCode < 300) {
          parts.add(utf8.decode(resp.bodyBytes, allowMalformed: true));
        }
      } catch (_) {
        // Skip failed segments; partial subtitles are better than none.
      }
    }
    if (parts.isEmpty) {
      throw const FormatException('No HLS subtitle segments could be fetched');
    }
    // Concatenate into a single WEBVTT document.  Strip per-segment WEBVTT
    // headers/footers since _parseVtt expects one document.
    final buffer = StringBuffer('WEBVTT\n\n');
    for (final part in parts) {
      final cleaned = part
          .replaceAll(RegExp(r'WEBVTT[\s\S]*?\n\n'), '')
          .replaceAll(RegExp(r'^NOTE.*$', multiLine: true), '')
          .trim();
      if (cleaned.isNotEmpty) {
        buffer
          ..write(cleaned)
          ..write('\n\n');
      }
    }
    return buffer.toString();
  }
}
