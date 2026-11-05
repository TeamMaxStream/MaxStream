part of '../m3u8_video_player_screen.dart';

extension _SubtitleParsers on _M3U8VideoPlayerScreenState {
  List<Subtitle> _parseSubtitleFile(String input) {
    final normalized = input
        .replaceFirst('\uFEFF', '')
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n');

    final upper = normalized.trimLeft().toUpperCase();

    // Detect format
    if (upper.startsWith('WEBVTT')) {
      return _parseVtt(normalized);
    } else if (upper.startsWith('{') || upper.startsWith('[')) {
      final jsonSubtitles = _parseJsonSubtitles(normalized);
      if (jsonSubtitles.isNotEmpty) return jsonSubtitles;
    } else if (upper.contains('[SCRIPT INFO]') || upper.contains('[V4')) {
      return _parseAss(normalized);
    } else if (upper.contains('<TT') ||
        upper.contains('<P ') ||
        upper.contains('<P>')) {
      return _parseTtml(normalized);
    } else {
      final srt = _parseSrt(normalized);
      if (srt.isNotEmpty) return srt;
      // Last resort: try TTML for any XML-like content
      if (normalized.contains('<') && normalized.contains('begin=')) {
        return _parseTtml(normalized);
      }
      return srt;
    }
    return const [];
  }

  List<Subtitle> _parseJsonSubtitles(String input) {
    try {
      final decoded = jsonDecode(input);
      final dynamic rawCues = decoded is List
          ? decoded
          : decoded is Map
          ? decoded['cues'] ?? decoded['subtitles'] ?? decoded['data']
          : null;
      if (rawCues is! List) return const [];

      final subtitles = <Subtitle>[];
      for (final rawCue in rawCues.whereType<Map>()) {
        final start = _parseJsonCueTime(
          rawCue['startTime'] ?? rawCue['start'] ?? rawCue['from'],
        );
        final end = _parseJsonCueTime(
          rawCue['endTime'] ?? rawCue['end'] ?? rawCue['to'],
        );
        final rawText =
            rawCue['text'] ?? rawCue['payload'] ?? rawCue['caption'];
        final text = rawText is List
            ? rawText.join('\n')
            : rawText?.toString() ?? '';
        final cleanedText = text
            .replaceAll(RegExp(r'<[^>]+>'), '')
            .replaceAll('&amp;', '&')
            .replaceAll('&lt;', '<')
            .replaceAll('&gt;', '>')
            .trim();
        if (start == null || end == null || cleanedText.isEmpty) continue;
        subtitles.add(
          Subtitle(
            index: subtitles.length,
            start: start,
            end: end,
            text: cleanedText,
          ),
        );
      }
      return subtitles;
    } catch (_) {
      return const [];
    }
  }

  Duration? _parseJsonCueTime(dynamic value) {
    if (value is num) {
      return Duration(milliseconds: (value.toDouble() * 1000).round());
    }
    if (value is! String) return null;
    final timestamp = _parseSubtitleTime(value);
    if (timestamp != null) return timestamp;
    final seconds = double.tryParse(value);
    return seconds == null
        ? null
        : Duration(milliseconds: (seconds * 1000).round());
  }

  List<Subtitle> _parseVtt(String input) {
    final lines = input.split('\n');
    final subtitles = <Subtitle>[];
    int i = 0;

    // Skip WEBVTT header
    if (lines.isNotEmpty &&
        lines[0].trim().toUpperCase().startsWith('WEBVTT')) {
      i = 1;
    }

    while (i < lines.length) {
      final line = lines[i].trim();

      // Skip empty lines and NOTE blocks
      if (line.isEmpty || line.toUpperCase().startsWith('NOTE')) {
        if (line.toUpperCase().startsWith('NOTE')) {
          while (i < lines.length && lines[i].trim().isNotEmpty) {
            i++;
          }
        }
        i++;
        continue;
      }

      // Skip cue identifiers (lines that don't contain -->)
      if (!line.contains('-->')) {
        i++;
        continue;
      }

      // Parse timing line
      final timing = line.split('-->');
      if (timing.length != 2) {
        i++;
        continue;
      }
      final start = _parseSubtitleTime(timing[0]);
      final endValue = timing[1].trim().split(RegExp(r'\s+')).first;
      final end = _parseSubtitleTime(endValue);
      if (start == null || end == null) {
        i++;
        continue;
      }

      // Collect text lines until next empty line or next cue timing
      i++;
      final textLines = <String>[];
      while (i < lines.length && lines[i].trim().isNotEmpty) {
        // Stop if we hit another timing line (handles VTT without blank lines between cues)
        if (lines[i].trim().contains('-->')) break;
        textLines.add(lines[i].trim());
        i++;
      }

      final text = textLines
          .join('\n')
          .replaceAll(RegExp(r'<[^>]+>'), '')
          .replaceAll('&amp;', '&')
          .replaceAll('&lt;', '<')
          .replaceAll('&gt;', '>')
          .replaceAll(RegExp(r'\{[^}]+\}'), '');
      if (text.isEmpty) continue;

      subtitles.add(
        Subtitle(index: subtitles.length, start: start, end: end, text: text),
      );
    }
    return subtitles;
  }

  List<Subtitle> _parseSrt(String input) {
    final blocks = input.split(RegExp(r'\n\s*\n'));
    final subtitles = <Subtitle>[];

    for (final block in blocks) {
      final lines = block.trim().split('\n');
      if (lines.length < 2) continue;

      // Find the timing line
      int timingIndex = -1;
      for (int j = 0; j < lines.length; j++) {
        if (lines[j].contains('-->')) {
          timingIndex = j;
          break;
        }
      }
      if (timingIndex < 0) continue;

      final timing = lines[timingIndex].split('-->');
      if (timing.length != 2) continue;

      final start = _parseSrtTime(timing[0]);
      final endValue = timing[1].trim().split(RegExp(r'\s+')).first;
      final end = _parseSrtTime(endValue);
      if (start == null || end == null) continue;

      // Text is everything after the timing line
      final textLines = lines.sublist(timingIndex + 1);
      final text = textLines
          .join('\n')
          .replaceAll(RegExp(r'<[^>]+>'), '')
          .replaceAll('&amp;', '&')
          .replaceAll('&lt;', '<')
          .replaceAll('&gt;', '>')
          .trim();
      if (text.isEmpty) continue;

      subtitles.add(
        Subtitle(index: subtitles.length, start: start, end: end, text: text),
      );
    }
    return subtitles;
  }

  Duration? _parseSrtTime(String value) {
    final cleaned = value.trim().replaceAll(',', '.');
    final parts = cleaned.split(':');
    if (parts.length < 2 || parts.length > 3) return null;
    final seconds = double.tryParse(parts.last);
    final minutes = int.tryParse(parts[parts.length - 2]);
    final hours = parts.length == 3 ? int.tryParse(parts.first) : 0;
    if (seconds == null || minutes == null || hours == null) return null;
    return Duration(
      hours: hours,
      minutes: minutes,
      milliseconds: (seconds * 1000).round(),
    );
  }

  Duration? _parseSubtitleTime(String value) {
    final parts = value.trim().replaceAll(',', '.').split(':');
    if (parts.length < 2 || parts.length > 3) return null;
    final seconds = double.tryParse(parts.last);
    final minutes = int.tryParse(parts[parts.length - 2]);
    final hours = parts.length == 3 ? int.tryParse(parts.first) : 0;
    if (seconds == null || minutes == null || hours == null) return null;
    return Duration(
      hours: hours,
      minutes: minutes,
      milliseconds: (seconds * 1000).round(),
    );
  }

  List<Subtitle> _parseAss(String input) {
    final subtitles = <Subtitle>[];
    final lines = input.split('\n');
    bool inEvents = false;
    bool foundFormat = false;
    int textIndex = -1;
    int startIdx = -1;
    int endIdx = -1;

    for (final rawLine in lines) {
      final line = rawLine.trim();

      if (line.toUpperCase() == '[EVENTS]') {
        inEvents = true;
        continue;
      }
      if (line.startsWith('[') && inEvents) break;

      if (inEvents) {
        if (line.toUpperCase().startsWith('FORMAT:')) {
          foundFormat = true;
          final fields = line
              .substring(7)
              .split(',')
              .map((f) => f.trim().toLowerCase())
              .toList();
          startIdx = fields.indexOf('start');
          endIdx = fields.indexOf('end');
          textIndex = fields.indexOf('text');
          continue;
        }

        if (!foundFormat || textIndex < 0) continue;
        if (!line.toUpperCase().startsWith('DIALOGUE:') &&
            !line.toUpperCase().startsWith('COMMENT:')) {
          continue;
        }
        if (line.toUpperCase().startsWith('COMMENT:')) continue;

        final afterColon = line.substring(line.indexOf(':') + 1);
        final parts = afterColon.split(',');
        if (parts.length <= textIndex) continue;

        final start = _parseAssTime(
          startIdx >= 0 && startIdx < parts.length ? parts[startIdx] : '',
        );
        final end = _parseAssTime(
          endIdx >= 0 && endIdx < parts.length ? parts[endIdx] : '',
        );
        if (start == null || end == null) continue;

        final text = parts
            .sublist(textIndex)
            .join(',')
            .replaceAll(RegExp(r'\{[^}]*\}'), '')
            .replaceAll('\\N', '\n')
            .replaceAll('\\n', '\n')
            .replaceAll(RegExp(r'<[^>]+>'), '')
            .trim();
        if (text.isEmpty) continue;

        subtitles.add(
          Subtitle(index: subtitles.length, start: start, end: end, text: text),
        );
      }
    }
    return subtitles;
  }

  Duration? _parseAssTime(String value) {
    final cleaned = value.trim();
    final match = RegExp(r'(\d+):(\d+):(\d+)\.(\d+)').firstMatch(cleaned);
    if (match == null) return null;
    final hours = int.tryParse(match.group(1) ?? '') ?? 0;
    final minutes = int.tryParse(match.group(2) ?? '') ?? 0;
    final seconds = int.tryParse(match.group(3) ?? '') ?? 0;
    final cs = int.tryParse(match.group(4) ?? '') ?? 0;
    return Duration(
      hours: hours,
      minutes: minutes,
      seconds: seconds,
      milliseconds: cs * 10,
    );
  }

  List<Subtitle> _parseTtml(String input) {
    final subtitles = <Subtitle>[];
    // Match <p> or <div><p> elements with begin/end attributes
    final cuePattern = RegExp(
      r'<(?:p|P)\s[^>]*?begin="([^"]+)"[^>]*?end="([^"]+)"[^>]*?>([\s\S]*?)</(?:p|P)>',
      caseSensitive: false,
    );
    for (final match in cuePattern.allMatches(input)) {
      final start = _parseTtmlTime(match.group(1) ?? '');
      final end = _parseTtmlTime(match.group(2) ?? '');
      if (start == null || end == null) continue;
      final text = match
          .group(3)!
          .replaceAll(RegExp(r'<[^>]+>'), '')
          .replaceAll('&amp;', '&')
          .replaceAll('&lt;', '<')
          .replaceAll('&gt;', '>')
          .replaceAll('&#xA;', '\n')
          .replaceAll('\n', ' ')
          .trim();
      if (text.isEmpty) continue;
      subtitles.add(
        Subtitle(index: subtitles.length, start: start, end: end, text: text),
      );
    }
    return subtitles;
  }

  Duration? _parseTtmlTime(String value) {
    final cleaned = value.trim();
    // TTML formats: HH:MM:SS.mmm, HH:MM:SS:mm (frames), HH:MM:SS, or decimal seconds
    final hmsMatch = RegExp(
      r'(\d+):(\d+):(\d+)(?:\.(\d+))?',
    ).firstMatch(cleaned);
    if (hmsMatch != null) {
      final hours = int.tryParse(hmsMatch.group(1) ?? '') ?? 0;
      final minutes = int.tryParse(hmsMatch.group(2) ?? '') ?? 0;
      final seconds = int.tryParse(hmsMatch.group(3) ?? '') ?? 0;
      final frac = hmsMatch.group(4) ?? '0';
      // Normalize fractional part to milliseconds
      int ms = 0;
      if (frac.isNotEmpty) {
        final padded = frac.padRight(3, '0').substring(0, 3);
        ms = int.tryParse(padded) ?? 0;
      }
      return Duration(
        hours: hours,
        minutes: minutes,
        seconds: seconds,
        milliseconds: ms,
      );
    }
    // Plain seconds: "123.456"
    final secMatch = RegExp(r'^(\d+(?:\.\d+)?)s?$').firstMatch(cleaned);
    if (secMatch != null) {
      final seconds = double.tryParse(secMatch.group(1) ?? '') ?? 0;
      return Duration(milliseconds: (seconds * 1000).round());
    }
    return null;
  }
}
