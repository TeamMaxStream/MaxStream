/// Security policy shared by stream playback and download code.
class StreamSecurity {
  static const Set<String> _forwardedHeaders = {
    'user-agent',
    'referer',
    'origin',
    'cookie',
    'accept',
    'accept-language',
    'range',
    'if-range',
    'x-requested-with',
  };

  static Uri? safeNetworkUri(Object? value, {Uri? base}) {
    final text = value?.toString().trim() ?? '';
    if (text.isEmpty) return null;
    final parsed = Uri.tryParse(text);
    if (parsed == null) return null;
    final uri = base == null ? parsed : base.resolveUri(parsed);
    if ((uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        _isUnsafeHost(uri.host)) {
      return null;
    }
    return uri;
  }

  static bool isSafeNetworkUrl(Object? value, {Uri? base}) =>
      safeNetworkUri(value, base: base) != null;

  static Map<String, String> sanitizeHeaders(Map? input) {
    final output = <String, String>{};
    input?.forEach((key, value) {
      final name = key.toString().trim();
      if (!_forwardedHeaders.contains(name.toLowerCase())) return;
      final headerValue = value.toString();
      if (headerValue.contains('\r') || headerValue.contains('\n')) return;
      output[name] = headerValue;
    });
    return output;
  }

  static Map<String, dynamic>? sanitizeResolverResult(Map? result) {
    if (result == null) return null;
    final uri = safeNetworkUri(result['url']);
    if (uri == null) return null;
    final output = result.map((key, value) => MapEntry(key.toString(), value));
    final headers = sanitizeHeaders(
      result['headers'] is Map ? result['headers'] : null,
    );
    if (result['referer'] != null) {
      headers.addAll(sanitizeHeaders({'Referer': result['referer']}));
    }
    output['url'] = uri.toString();
    output['headers'] = headers;
    output.remove('referer');
    if (result['subtitles'] is List) {
      output['subtitles'] = (result['subtitles'] as List)
          .whereType<Map>()
          .where((track) => isSafeNetworkUrl(track['url']))
          .map(
            (track) =>
                track.map((key, value) => MapEntry(key.toString(), value)),
          )
          .toList();
    }
    if (result['qualities'] is List) {
      output['qualities'] = (result['qualities'] as List)
          .whereType<Map>()
          .map((q) => q.map((key, value) => MapEntry(key.toString(), value)))
          .toList();
    }
    if (result['audioTracks'] is List) {
      // Audio rendition URIs may legitimately be empty (muxed/default track
      // without a separate URI), so keep every entry and only normalize keys.
      output['audioTracks'] = (result['audioTracks'] as List)
          .whereType<Map>()
          .map((a) => a.map((key, value) => MapEntry(key.toString(), value)))
          .toList();
    }
    return output;
  }

  static bool _isUnsafeHost(String rawHost) {
    final host = rawHost.toLowerCase().replaceAll(RegExp(r'^\[|\]$'), '');
    // Videasy and related HLS hosts must never be blocked — they are the
    // actual CDN for episode downloads (m3u8.videasy.to, etc.).
    if (host.contains('videasy') || host.contains('speedracelight.com'))
      return false;
    if (host == 'localhost' || host.endsWith('.localhost')) return true;
    final parts = host.split('.');
    if (parts.length == 4) {
      final octets = parts.map(int.tryParse).toList();
      if (octets.every(
        (value) => value != null && value >= 0 && value <= 255,
      )) {
        final a = octets[0]!;
        final b = octets[1]!;
        return a == 0 ||
            a == 10 ||
            a == 127 ||
            (a == 169 && b == 254) ||
            (a == 172 && b >= 16 && b <= 31) ||
            (a == 192 && b == 168);
      }
    }
    if (host.contains(':')) {
      return host == '::' ||
          host == '::1' ||
          host.startsWith('fc') ||
          host.startsWith('fd') ||
          RegExp(r'^fe[89ab]').hasMatch(host) ||
          host.startsWith('::ffff:127.') ||
          host.startsWith('::ffff:10.') ||
          host.startsWith('::ffff:192.168.') ||
          RegExp(r'^::ffff:172\.(1[6-9]|2\d|3[01])\.').hasMatch(host);
    }
    return false;
  }
}
