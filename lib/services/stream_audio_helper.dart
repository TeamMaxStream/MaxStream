/// Helpers for multi-language HLS audio tracks (`EXT-X-MEDIA:TYPE=AUDIO`).
///
/// Upstream hosts (VidLink with `?multiLang=1`, VixSrc, Frembed, ...) provide
/// the alternate renditions; [server providers][1] request them and the native
/// extractors parse + forward them as `audioTracks` on each resolved stream.
///
/// [1]: android/app/.../StreamExtractor.kt (`parseHlsAudio`)
class StreamAudioHelper {
  static const Map<String, String> _languageNames = {
    'en': 'English',
    'eng': 'English',
    'hi': 'Hindi',
    'hin': 'Hindi',
    'es': 'Spanish',
    'spa': 'Spanish',
    'fr': 'French',
    'fra': 'French',
    'fre': 'French',
    'de': 'German',
    'deu': 'German',
    'ger': 'German',
    'it': 'Italian',
    'ita': 'Italian',
    'pt': 'Portuguese',
    'por': 'Portuguese',
    'ru': 'Russian',
    'rus': 'Russian',
    'ar': 'Arabic',
    'ara': 'Arabic',
    'ta': 'Tamil',
    'tam': 'Tamil',
    'te': 'Telugu',
    'tel': 'Telugu',
    'ml': 'Malayalam',
    'mal': 'Malayalam',
    'bn': 'Bengali',
    'ben': 'Bengali',
    'mr': 'Marathi',
    'mar': 'Marathi',
    'kn': 'Kannada',
    'kan': 'Kannada',
    'pa': 'Punjabi',
    'pan': 'Punjabi',
    'ur': 'Urdu',
    'urd': 'Urdu',
    'ja': 'Japanese',
    'jpn': 'Japanese',
    'ko': 'Korean',
    'kor': 'Korean',
    'zh': 'Chinese',
    'zho': 'Chinese',
    'chi': 'Chinese',
    'tr': 'Turkish',
    'tur': 'Turkish',
    'nl': 'Dutch',
    'nld': 'Dutch',
    'dut': 'Dutch',
    'pl': 'Polish',
    'pol': 'Polish',
    'id': 'Indonesian',
    'ind': 'Indonesian',
    'ms': 'Malay',
    'msa': 'Malay',
    'may': 'Malay',
    'th': 'Thai',
    'tha': 'Thai',
    'vi': 'Vietnamese',
    'vie': 'Vietnamese',
    'fil': 'Filipino',
    'tl': 'Filipino',
    'uk': 'Ukrainian',
    'ukr': 'Ukrainian',
    'und': 'Default',
  };

  /// Normalized audio track maps from a resolved stream map.
  static List<Map<String, dynamic>> tracksOf(Map stream) {
    final raw = stream['audioTracks'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((t) => t.map((k, v) => MapEntry(k.toString(), v)))
        .toList();
  }

  static String languageOf(Map track) =>
      (track['language']?.toString() ?? '').trim();

  static String labelOf(Map track) => (track['label']?.toString() ?? '').trim();

  /// Human-readable name: "English", "Hindi · 6ch", ...
  static String displayName(Map track) {
    final language = languageOf(track).toLowerCase();
    final label = labelOf(track);
    final known = _languageNames[language];
    var name = known ?? (label.isEmpty ? language : label);
    if (name.isEmpty) name = 'Audio';
    // Avoid "English (English)" style duplication.
    if (known != null &&
        label.isNotEmpty &&
        !label.toLowerCase().contains(known.toLowerCase()) &&
        !label.toLowerCase().contains(language)) {
      name = '$known ($label)';
    }
    final channels = track['channels']?.toString() ?? '';
    if (channels.isNotEmpty && !name.contains(channels)) {
      name = '$name · $channels';
    }
    return name;
  }

  /// Short badge for server rows: "EN", "EN+2", "".
  static String badgeFor(Map stream) {
    final tracks = tracksOf(stream);
    if (tracks.isEmpty) return '';
    if (tracks.length == 1) {
      final lang = languageOf(tracks.first);
      if (lang.isEmpty || lang == 'und') return '';
      return lang.length <= 3
          ? lang.toUpperCase()
          : lang.toUpperCase().substring(0, 3);
    }
    final first = languageOf(tracks.first);
    final short = first.length <= 3
        ? first.toUpperCase()
        : first.toUpperCase().substring(0, 3);
    final prefix = first.isEmpty || first == 'und' ? '' : short;
    return '$prefix+${tracks.length - 1}';
  }

  /// Case-insensitive match against LANGUAGE, label, or known name.
  static bool matches(Map track, String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return false;
    final language = languageOf(track).toLowerCase();
    final label = labelOf(track).toLowerCase();
    if (language == q || label == q) return true;
    if (language.contains(q) || q.contains(language) && language != 'und') {
      return true;
    }
    if (label.contains(q) || q.contains(label)) return true;
    final known = _languageNames[language];
    if (known != null &&
        (known.toLowerCase() == q ||
            known.toLowerCase().contains(q) ||
            q.contains(known.toLowerCase()))) {
      return true;
    }
    return false;
  }
}
