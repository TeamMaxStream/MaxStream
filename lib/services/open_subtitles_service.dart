import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// One subtitle found through the OpenSubtitles legacy REST search.
class OpenSubtitleResult {
  const OpenSubtitleResult({
    required this.id,
    required this.label,
    required this.language,
    required this.downloadUrl,
    required this.encoding,
    required this.downloads,
  });

  final String id;
  final String label;
  final String language;
  final String downloadUrl;
  final String? encoding;
  final int downloads;
}

/// Client for the keyless legacy OpenSubtitles REST API
/// (`rest.opensubtitles.org`). Downloads arrive gzip-compressed in a legacy
/// codepage and are decoded to UTF-8 here so the player's normal subtitle
/// parser can consume them from a local file.
class OpenSubtitlesService {
  OpenSubtitlesService._();

  static const String _baseUrl = 'https://rest.opensubtitles.org/';
  // The legacy endpoint rejects custom user agents with a redirect; it only
  // answers this shared test agent.
  static const String _userAgent = 'TemporaryUserAgent';

  /// Searches by [query] (a title), optionally scoped to a TV episode.
  /// Results are sorted by popularity (downloads, descending).
  static Future<List<OpenSubtitleResult>> search({
    required String query,
    int? season,
    int? episode,
    int limit = 30,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const [];
    final params = <String, String>{'query': trimmed.toLowerCase()};
    if (season != null) params['season'] = '$season';
    if (episode != null) params['episode'] = '$episode';
    final path = params.entries
        .map((e) => '${e.key}-${Uri.encodeComponent(e.value)}')
        .join('/');
    final uri = Uri.parse('$_baseUrl/search/$path');
    final response = await http
        .get(uri, headers: {'User-Agent': _userAgent})
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw Exception('Subtitle search failed (HTTP ${response.statusCode})');
    }
    final decoded = jsonDecode(
      utf8.decode(response.bodyBytes, allowMalformed: true),
    );
    if (decoded is! List) return const [];

    final results = <OpenSubtitleResult>[];
    for (final entry in decoded) {
      if (entry is! Map) continue;
      final downloadUrl = entry['SubDownloadLink']?.toString() ?? '';
      if (downloadUrl.isEmpty) continue;
      final language = entry['LanguageName']?.toString() ?? '';
      final release = entry['MovieReleaseName']?.toString() ?? '';
      final downloads =
          int.tryParse(entry['SubDownloadsCnt']?.toString() ?? '') ?? 0;
      final labelParts = [
        if (language.isNotEmpty) language,
        if (release.isNotEmpty) release,
      ];
      results.add(
        OpenSubtitleResult(
          id: entry['IDSubtitleFile']?.toString() ?? downloadUrl,
          label: labelParts.isEmpty ? 'Subtitle' : labelParts.join(' · '),
          language: language,
          downloadUrl: downloadUrl,
          encoding: entry['SubEncoding']?.toString(),
          downloads: downloads,
        ),
      );
    }
    results.sort((a, b) => b.downloads.compareTo(a.downloads));
    // Same release often appears once per language track — keep one entry per
    // label so picker rows stay distinct.
    final seenLabels = <String>{};
    results.retainWhere((r) => seenLabels.add(r.label));
    return results.take(limit).toList();
  }

  /// Downloads [subtitle] and returns its caption text decoded to UTF-8.
  static Future<String> downloadAsText(OpenSubtitleResult subtitle) async {
    final response = await http
        .get(
          Uri.parse(subtitle.downloadUrl),
          headers: {'User-Agent': _userAgent},
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw Exception(
        'Subtitle download failed (HTTP ${response.statusCode})',
      );
    }
    List<int> raw;
    try {
      raw = gzip.decode(response.bodyBytes);
    } catch (_) {
      // Some mirrors serve the plain file without the gzip wrapper.
      raw = response.bodyBytes;
    }
    return _decodeBytes(raw, subtitle.encoding);
  }

  /// Decodes [bytes] from the legacy codepage declared by the API into a
  /// UTF-16 string. UTF-8/ISO-8859-1 pass through standard decoders; the
  /// Windows codepages use embedded 0x80-0xFF lookup tables.
  static String _decodeBytes(List<int> bytes, String? encoding) {
    final enc = (encoding ?? '').trim().toUpperCase();
    if (enc.isEmpty || enc == 'UTF-8' || enc == 'UTF8') {
      try {
        return utf8.decode(bytes);
      } on FormatException {
        return latin1.decode(bytes);
      }
    }
    if (enc == 'ISO-8859-1' || enc == 'LATIN1' || enc == 'ISO-8859-15') {
      return latin1.decode(bytes);
    }

    String? table;
    if (enc == 'CP1251' || enc == 'WINDOWS-1251') {
      table = _kCp1251;
    } else if (enc == 'CP1253' || enc == 'WINDOWS-1253') {
      table = _kCp1253;
    } else if (enc == 'CP1254' || enc == 'WINDOWS-1254') {
      table = _kCp1254;
    } else if (enc == 'CP1256' || enc == 'WINDOWS-1256') {
      table = _kCp1256;
    }
    final isCp1252 = enc == 'CP1252' || enc == 'WINDOWS-1252';
    if (table == null && !isCp1252) {
      // Unknown legacy label: best effort as latin1 (never throws).
      return latin1.decode(bytes);
    }

    final buffer = StringBuffer();
    for (final byte in bytes) {
      if (byte < 0x80) {
        buffer.writeCharCode(byte);
      } else if (byte < 0xA0 && isCp1252) {
        buffer.write(_kCp1252High.codeUnitAt(byte - 0x80));
      } else if (isCp1252 || table == null) {
        // 0xA0-0xFF of CP1252 and ISO-8859-1 match Unicode codepoints.
        buffer.writeCharCode(byte);
      } else {
        buffer.write(table.codeUnitAt(byte - 0x80));
      }
    }
    return buffer.toString();
  }

  // 0x80-0xFF lookup tables for the legacy Windows codepages that appear in
  // subtitle metadata (Cyrillic/Greek/Turkish/Arabic/Western).
  static const String _kCp1251 =
      'ЂЃ‚ѓ„…†‡€‰Љ‹ЊЌЋЏђ‘’“”•–—\u{98}™љ›њќћџ ЎўЈ¤Ґ¦§Ё©Є«¬\u{ad}®Ї°±Ііґµ¶·ё№є»јЅѕїАБВГДЕЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯабвгдежзийклмнопрстуфхцчшщъыьэюя';
  static const String _kCp1253 =
      '€\u{81}‚ƒ„…†‡\u{88}‰\u{8a}‹\u{8c}\u{8d}\u{8e}\u{8f}\u{90}‘’“”•–—\u{98}™\u{9a}›\u{9c}\u{9d}\u{9e}\u{9f} ΅Ά£¤¥¦§¨©ª«¬\u{ad}®―°±²³΄µ¶·ΈΉΊ»Ό½ΎΏΐΑΒΓΔΕΖΗΘΙΚΛΜΝΞΟΠΡÒΣΤΥΦΧΨΩΪΫάέήίΰαβγδεζηθικλμνξοπρςστυφχψωϊϋόύώÿ';
  static const String _kCp1254 =
      '€\u{81}‚ƒ„…†‡ˆ‰Š‹Œ\u{8d}\u{8e}\u{8f}\u{90}‘’“”•–—˜™š›œ\u{9d}\u{9e}Ÿ ¡¢£¤¥¦§¨©ª«¬\u{ad}®¯°±²³´µ¶·¸¹º»¼½¾¿ÀÁÂÃÄÅÆÇÈÉÊËÌÍÎÏĞÑÒÓÔÕÖ×ØÙÚÛÜİŞßàáâãäåæçèéêëìíîïğñòóôõö÷øùúûüışÿ';
  static const String _kCp1256 =
      '€پ‚ƒ„…†‡ˆ‰ٹ‹Œچژڈگ‘’“”•–—ک™ڑ›œ\u{200c}\u{200d}ں ،¢£¤¥¦§¨©ھ«¬\u{ad}®¯°±²³´µ¶·¸¹؛»¼½¾؟ہءآأؤإئابةتثجحخدذرزسشصض×طظعغـفقكàلâمنهوçèéêëىيîïًٌٍَôُِ÷ّùْûü\u{200e}\u{200f}ے';
  static const String _kCp1252High =
      '€\u{81}‚ƒ„…†‡ˆ‰Š‹Œ\u{8d}Ž\u{8f}\u{90}‘’“”•–—˜™š›œ\u{9d}žŸ';
}
