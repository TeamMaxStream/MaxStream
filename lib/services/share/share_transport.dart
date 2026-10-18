import 'dart:typed_data';

import 'share_models.dart';

/// A way to move a [ShareSession] from one device to another.
///
/// Deliberately thin: it moves bytes and nothing else. The HTTP-over-LAN and
/// Nearby Connections implementations are interchangeable behind this
/// interface, so adding a routerless transport never touches the manifest
/// format, the transfer UI, or the import into the Downloads screen.
abstract class ShareTransport {
  /// Stable id, also used in the share code (`maxstream:<id>:...`).
  String get id;

  /// Name shown in the transport picker.
  String get label;

  /// False when the device can't run this transport (e.g. no Play services).
  bool get isSupported;

  /// Human-readable reason when [isSupported] is false.
  String? get unavailableReason;

  /// Receiver progress ticks for the current fetch, keyed by file index.
  Stream<Map<int, ShareFileProgress>> get progress;

  // ── Sender ────────────────────────────────────────────────────────────────

  /// Starts serving [session] and returns how receivers can reach it.
  Future<ShareDescriptor> publish(ShareSession session);

  /// Stops serving and releases sockets/endpoints.
  Future<void> unpublish();

  /// Connection lifecycle for the send UI.
  Stream<ShareSenderEvent> get senderEvents;

  // ── Receiver ──────────────────────────────────────────────────────────────

  /// Fetches the bundle header from a sender.
  Future<ShareManifest> fetchManifest(ShareDescriptor descriptor);

  /// Fetches one file. [start]/[end] request a byte range when the transport
  /// supports it (LAN does; Nearby sends whole files and ignores them).
  Stream<Uint8List> fetchFile(
    ShareDescriptor descriptor,
    ShareFileEntry file, {
    int? start,
    int? end,
  });

  /// Tears down receiver-side state (sockets / discovery / endpoints).
  Future<void> closeReceiver();
}

/// Per-file transfer progress.
class ShareFileProgress {
  const ShareFileProgress({
    required this.received,
    required this.total,
    required this.done,
  });

  final int received;
  final int total;
  final bool done;

  double get fraction => total <= 0 ? 0 : (received / total).clamp(0.0, 1.0);
}
