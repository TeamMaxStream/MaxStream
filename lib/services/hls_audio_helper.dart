import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'stream_audio_helper.dart';
import 'stream_security.dart';

/// Rewrites an HLS master playlist so ExoPlayer defaults to the user's
/// preferred audio language without any native player changes.
///
/// The rewritten master keeps every video variant but drops the non-matching
/// `#EXT-X-MEDIA:TYPE=AUDIO` groups and marks the match `DEFAULT=YES`. It is
/// written to a temp file with all URIs absolutized, so relative masters keep
/// working. Stream headers (cookies, referer, UA) are still supplied to
/// ExoPlayer via `httpHeaders` and apply to the remote segments, which stay
/// remote — only the tiny master text is local.
class HlsAudioHelper {
  /// Returns a local `.m3u8` path pinning [language], or null when the master
  /// has no alternate audio to choose from (use the original URL then).
  static Future<String?> buildMasterWithPreferredAudio({
    required String masterUrl,
    required Map<String, String> headers,
    required String language,
  }) async {
    final uri = StreamSecurity.safeNetworkUri(masterUrl);
    if (uri == null || language.trim().isEmpty) return null;
    try {
      final response = await http
          .get(uri, headers: {...headers, 'Accept': '*/*'})
          .timeout(const Duration(seconds: 15));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }
      final text = utf8.decode(response.bodyBytes, allowMalformed: true);
      if (!text.startsWith('#EXTM3U') || !text.contains('#EXT-X-STREAM-INF')) {
        return null;
      }
      final rewritten = _rewriteMaster(uri, text, language);
      if (rewritten == null) return null;
      final dir = Directory(
        '${(await getTemporaryDirectory()).path}/audio_pref',
      );
      await dir.create(recursive: true);
      final file = File(
        '${dir.path}/master_${masterUrl.hashCode & 0x7fffffff}_${language.hashCode & 0xffff}.m3u8',
      );
      await file.writeAsString(rewritten, flush: true);
      return file.path;
    } catch (_) {
      return null;
    }
  }

  /// Returns the rewritten master text, or null when there is nothing to pin
  /// (0-1 audio groups, or no group matching [language]).
  static String? _rewriteMaster(Uri masterUri, String text, String language) {
    final lines = const LineSplitter().convert(text);
    var audioGroupCount = 0;
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.startsWith('#EXT-X-MEDIA:') &&
          trimmed.toUpperCase().contains('TYPE=AUDIO')) {
        audioGroupCount++;
      }
    }
    if (audioGroupCount <= 1) return null;

    var matched = 0;
    final out = <String>[];
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final trimmed = line.trim();
      if (trimmed.startsWith('#EXT-X-MEDIA:') &&
          trimmed.toUpperCase().contains('TYPE=AUDIO')) {
        final languageAttr = _attribute(trimmed, 'LANGUAGE');
        final nameAttr = _attribute(trimmed, 'NAME');
        final track = {'language': languageAttr ?? '', 'label': nameAttr ?? ''};
        if (!StreamAudioHelper.matches(track, language)) continue;
        matched++;
        var kept = trimmed.replaceAll(
          RegExp(r',?\s*DEFAULT\s*=\s*(YES|NO)', caseSensitive: false),
          '',
        );
        kept = kept.replaceAll(
          RegExp(r',?\s*AUTOSELECT\s*=\s*(YES|NO)', caseSensitive: false),
          '',
        );
        kept = kept.replaceFirst(
          RegExp(r'TYPE\s*=\s*AUDIO', caseSensitive: false),
          'TYPE=AUDIO,DEFAULT=YES,AUTOSELECT=YES',
        );
        out.add(_absolutizeUriAttr(kept, masterUri));
        continue;
      }
      if (trimmed.startsWith('#EXT-X-I-FRAME-STREAM-INF:')) {
        out.add(_absolutizeUriAttr(line, masterUri));
        continue;
      }
      if (trimmed.isNotEmpty &&
          !trimmed.startsWith('#') &&
          i > 0 &&
          lines[i - 1].trim().startsWith('#EXT-X-STREAM-INF:')) {
        // Variant playlist URI: absolutize so the local master resolves it.
        final resolved = masterUri.resolve(trimmed).toString();
        out.add(resolved);
        continue;
      }
      out.add(line);
    }
    if (matched == 0) return null;
    return '${out.join('\n')}\n';
  }

  static String? _attribute(String line, String name) {
    final match = RegExp(
      '(?:^|,)$name=(?:"([^"]*)"|([^,]*))',
      caseSensitive: false,
    ).firstMatch(line);
    if (match == null) return null;
    final value = match.group(1)!.isNotEmpty
        ? match.group(1)!
        : match.group(2)!;
    return value.isEmpty ? null : value;
  }

  static String _absolutizeUriAttr(String line, Uri base) {
    final match = RegExp(
      r'URI=("([^"]+)"|([^,]+))',
      caseSensitive: false,
    ).firstMatch(line);
    if (match == null) return line;
    final source = match.group(2) ?? match.group(3)!;
    if (source.isEmpty) return line;
    final resolved = base.resolve(source).toString();
    return line.replaceRange(match.start, match.end, 'URI="$resolved"');
  }
}
