import 'dart:convert';
import 'dart:typed_data';

/// One file inside a shared item.
///
/// [path] is the absolute local path and is only populated on the SENDING
/// device — it is never serialised, so the receiver only ever sees [name].
class ShareFileEntry {
  const ShareFileEntry({
    required this.index,
    required this.name,
    required this.size,
    this.path,
  });

  final int index;

  /// File name relative to the item's download directory.
  final String name;
  final int size;
  final String? path;

  Map<String, dynamic> toJson() => {'i': index, 'n': name, 's': size};

  static ShareFileEntry fromJson(Map<String, dynamic> json) => ShareFileEntry(
        index: (json['i'] as num?)?.toInt() ?? 0,
        name: json['n']?.toString() ?? '',
        size: (json['s'] as num?)?.toInt() ?? 0,
      );
}

/// One downloaded movie/episode, described well enough that the receiving
/// device can register it as a real download: title, poster, TMDB id and
/// S/E so it shows up (and plays) identically to a self-downloaded item.
class ShareItem {
  const ShareItem({
    required this.downloadKey,
    required this.mediaId,
    required this.mediaType,
    required this.title,
    required this.thumbnail,
    required this.entryFile,
    required this.files,
    this.seriesId,
    this.seasonNumber,
    this.episodeNumber,
    this.subtitleNames = const [],
  });

  final String downloadKey;
  final String mediaId;

  /// 'movie' or 'episode' — matches the media_downloads.mediaType values.
  final String mediaType;
  final String title;
  final String thumbnail;
  final String? seriesId;
  final int? seasonNumber;
  final int? episodeNumber;

  /// File the player opens. For HLS downloads this is the local playlist, whose
  /// sibling segments travel with it, which is why the whole directory is
  /// shared rather than a single "video" file.
  final String entryFile;
  final List<String> subtitleNames;
  final List<ShareFileEntry> files;

  int get totalBytes => files.fold(0, (sum, f) => sum + f.size);

  /// Best-effort label: "Movie" or "S2E5".
  String get episodeLabel {
    if (mediaType != 'episode') return 'Movie';
    return 'S${seasonNumber ?? 1}E${episodeNumber ?? 1}';
  }

  Map<String, dynamic> toJson() => {
        'k': downloadKey,
        'm': mediaId,
        't': mediaType,
        'n': title,
        'p': thumbnail,
        if (seriesId != null) 'r': seriesId,
        if (seasonNumber != null) 'sn': seasonNumber,
        if (episodeNumber != null) 'en': episodeNumber,
        'e': entryFile,
        'sub': subtitleNames,
        'f': files.map((f) => f.toJson()).toList(),
      };

  static ShareItem fromJson(Map<String, dynamic> json) => ShareItem(
        downloadKey: json['k']?.toString() ?? '',
        mediaId: json['m']?.toString() ?? '',
        mediaType: json['t']?.toString() ?? 'movie',
        title: json['n']?.toString() ?? 'Shared video',
        thumbnail: json['p']?.toString() ?? '',
        entryFile: json['e']?.toString() ?? '',
        seriesId: json['r']?.toString(),
        seasonNumber: (json['sn'] as num?)?.toInt(),
        episodeNumber: (json['en'] as num?)?.toInt(),
        subtitleNames:
            (json['sub'] as List? ?? const []).map((e) => '$e').toList(),
        files: (json['f'] as List? ?? const [])
            .whereType<Map>()
            .map((e) => ShareFileEntry.fromJson(e.cast<String, dynamic>()))
            .toList(),
      );
}

/// The bundle header exchanged before any bytes move.
class ShareManifest {
  const ShareManifest({
    required this.senderName,
    required this.createdAt,
    required this.items,
    this.version = 1,
  });

  final int version;
  final String senderName;
  final DateTime createdAt;
  final List<ShareItem> items;

  int get totalBytes => items.fold(0, (sum, item) => sum + item.totalBytes);
  int get fileCount => items.fold(0, (sum, item) => sum + item.files.length);

  Map<String, dynamic> toJson() => {
        'v': version,
        'from': senderName,
        'at': createdAt.toIso8601String(),
        'items': items.map((i) => i.toJson()).toList(),
      };

  String encode() => jsonEncode(toJson());

  static ShareManifest decode(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) throw const FormatException('Bad share manifest');
    return ShareManifest(
      version: (decoded['v'] as num?)?.toInt() ?? 1,
      senderName: decoded['from']?.toString() ?? 'Unknown device',
      createdAt:
          DateTime.tryParse(decoded['at']?.toString() ?? '') ?? DateTime.now(),
      items: (decoded['items'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => ShareItem.fromJson(e.cast<String, dynamic>()))
          .toList(),
    );
  }
}

/// Everything a transport needs to serve a bundle.
///
/// The transport moves bytes and knows nothing about the app: the opener hands
/// it a stream for a file (optionally byte-ranged), which is what makes the LAN
/// and Nearby implementations interchangeable.
class ShareSession {
  const ShareSession({
    required this.manifest,
    required this.openFile,
  });

  final ShareManifest manifest;
  final Future<Stream<Uint8List>> Function(
    ShareFileEntry file, {
    int? start,
    int? end,
  }) openFile;
}

/// How a receiver reaches a sender. [code] is what gets rendered as a QR and
/// typed by hand; [data] carries whatever the transport needs to reconnect.
class ShareDescriptor {
  const ShareDescriptor({
    required this.transportId,
    required this.code,
    required this.label,
    this.data = const {},
  });

  final String transportId;

  /// Self-contained, e.g. `maxstream:lan:192.168.1.5:41234:ab12cd34` or
  /// `maxstream:nearby:ab12cd34`.
  final String code;

  /// Human readable, e.g. "192.168.1.5:41234" or "Pixel 7 · nearby".
  final String label;
  final Map<String, String> data;

  static final RegExp _pattern =
      RegExp(r'^maxstream:(lan|nearby):(.+)$', caseSensitive: false);

  /// Parses a scanned/typed code. Null when it isn't one of ours.
  static ShareDescriptor? tryParse(String raw) {
    final match = _pattern.firstMatch(raw.trim());
    if (match == null) return null;
    final transportId = match.group(1)!.toLowerCase();
    final rest = match.group(2)!;
    switch (transportId) {
      case 'lan':
        final parts = rest.split(':');
        if (parts.length < 3) return null;
        return ShareDescriptor(
          transportId: 'lan',
          code: raw.trim(),
          label: '${parts[0]}:${parts[1]}',
          data: {
            'host': parts[0],
            'port': parts.sublist(1, parts.length - 1).join(':'),
            'token': parts.last,
          },
        );
      case 'nearby':
        return ShareDescriptor(
          transportId: 'nearby',
          code: raw.trim(),
          label: 'Nearby device',
          data: {'token': rest},
        );
    }
    return null;
  }
}

/// Sender-side transport events, used to drive the send sheet's UI.
class ShareSenderEvent {
  const ShareSenderEvent({required this.kind, this.message});

  /// 'waiting' | 'connected' | 'disconnected' | 'progress' | 'error'
  final String kind;
  final String? message;
}
