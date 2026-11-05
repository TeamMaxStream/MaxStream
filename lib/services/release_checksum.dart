import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// Parses a `SHA256SUMS` sidecar (`<64 hex>  <filename>` per line, the format
/// produced by `sha256sum`) and returns the checksum for [fileName], or null
/// when the file is absent.
String? findSha256ForFile(String sums, String fileName) {
  for (final rawLine in const LineSplitter().convert(sums)) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final match = RegExp(r'^([0-9a-fA-F]{64})\s+\*?(.+)$').firstMatch(line);
    if (match == null) continue;
    final name = match.group(2)!.trim();
    if (name == fileName || name.endsWith('/$fileName')) {
      return match.group(1)!.toLowerCase();
    }
  }
  return null;
}

/// Streams [file] through SHA-256 so a 60–80 MB APK never has to be buffered
/// in memory as a single byte array.
Future<String> sha256OfFile(File file) async {
  final sink = _DigestSink();
  final input = sha256.startChunkedConversion(sink);
  await for (final chunk in file.openRead()) {
    input.add(chunk);
  }
  input.close();
  final digest = sink.value;
  if (digest == null) {
    throw StateError('SHA-256 hashing produced no digest');
  }
  return digest.toString();
}

class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) {
    value = data;
  }

  @override
  void close() {}
}
