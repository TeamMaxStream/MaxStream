import 'dart:async';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../../database/db_helper.dart';
import '../../services/share/share_models.dart';
import '../../services/share/share_service.dart';
import 'share_receive_screen.dart';

/// Share sheet opened from a download row: pick what to send, choose a
/// transport, then show the QR / code the other device pairs with.
class ShareSendSheet extends StatefulWidget {
  const ShareSendSheet({
    super.key,
    required this.initialDownloads,
    this.title,
  });

  final List<Map<String, dynamic>> initialDownloads;
  final String? title;

  @override
  State<ShareSendSheet> createState() => _ShareSendSheetState();
}

class _ShareSendSheetState extends State<ShareSendSheet> {
  late List<Map<String, dynamic>> _items = List.of(widget.initialDownloads);
  List<Map<String, dynamic>> _available = const [];
  String _transportId = 'lan';
  ShareDescriptor? _descriptor;
  ShareManifest? _sentManifest;
  int _manifestItems = 0;
  int _manifestBytes = 0;
  String _status = '';
  bool _starting = false;
  bool _sharing = false;
  StreamSubscription<ShareSenderEvent>? _events;

  @override
  void initState() {
    super.initState();
    // Populated in the background so the picker can offer the rest of the
    // library without ever being empty on first frame.
    unawaited(_loadAvailable());
  }

  Future<void> _loadAvailable() async {
    final rows = await DBHelper.getMediaDownloads();
    if (!mounted) return;
    setState(() {
      _available = rows;
      if (_items.isEmpty) _items = rows;
    });
  }

  @override
  void dispose() {
    _events?.cancel();
    if (_sharing) {
      unawaited(ShareService.instance.stopSending(_transportId));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 16,
        // The sheet is laid out to the screen edge, so the actions at the
        // bottom need to clear the system nav bar.
        bottom: 20 + MediaQuery.viewPaddingOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[600],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            widget.title == null ? 'Send to device' : 'Send ${widget.title}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          Text(
            _descriptor == null
                ? '${_items.length} item${_items.length == 1 ? '' : 's'} selected'
                : '$_manifestItems item${_manifestItems == 1 ? '' : 's'} • '
                    '${_formatBytes(_manifestBytes)}',
            style: const TextStyle(color: Colors.grey, fontSize: 13),
          ),
          const SizedBox(height: 16),
          if (_descriptor == null) ...[
            if (_items.length > 1)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 220),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    ..._available.map(
                      (download) => CheckboxListTile(
                        dense: true,
                        value: _items.any(
                          (i) => i['downloadKey'] == download['downloadKey'],
                        ),
                        title: Text(
                          '${download['title'] ?? 'Video'}'
                          '${download['mediaType'] == 'episode' ? ' (S${download['seasonNumber']}E${download['episodeNumber']})' : ''}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                          ),
                        ),
                        onChanged: (checked) {
                          setState(() {
                            if (checked == true) {
                              _items = [..._items, download];
                            } else {
                              _items = _items
                                  .where(
                                    (i) => i['downloadKey'] != download['downloadKey'],
                                  )
                                  .toList();
                            }
                          });
                        },
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 12),
            _buildTransportPicker(),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _items.isEmpty || _starting ? null : _start,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(
                  _starting ? 'Preparing…' : 'Show pairing code',
                ),
              ),
            ),
          ] else
            _buildPairing(),
        ],
      ),
    );
  }

  Widget _buildTransportPicker() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'HOW TO CONNECT',
          style: TextStyle(
            color: Colors.white54,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 8),
        ...ShareService.instance.transports.map(
          (transport) => RadioListTile<String>(
            dense: true,
            value: transport.id,
            groupValue: _transportId,
            activeColor: Colors.red,
            contentPadding: EdgeInsets.zero,
            title: Text(
              transport.label,
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
            subtitle: Text(
              _transportHint(transport.id),
              style: const TextStyle(color: Colors.white38, fontSize: 11),
            ),
            onChanged: transport.isSupported
                ? (value) => setState(() => _transportId = value ?? 'lan')
                : null,
          ),
        ),
      ],
    );
  }

  static String _transportHint(String id) => id == 'nearby'
      ? 'Works with no Wi-Fi or router — devices pair directly'
      : 'Both devices on the same Wi-Fi, or join this phone\'s hotspot';

  Widget _buildPairing() {
    final descriptor = _descriptor!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Center(
            child: QrImageView(
              data: descriptor.code,
              version: QrVersions.auto,
              size: 190,
              backgroundColor: Colors.white,
            ),
          ),
        ),
        const SizedBox(height: 12),
        SelectableText(
          descriptor.code,
          style: const TextStyle(color: Colors.white, fontSize: 12),
          textAlign: TextAlign.center,
        ),
        if (_status.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            _status,
            style: const TextStyle(color: Colors.greenAccent, fontSize: 13),
            textAlign: TextAlign.center,
          ),
        ],
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () async {
                  await SharePlus.instance.share(
                    ShareParams(
                      text: 'Send "${widget.title ?? 'a download'}" to my MaxStream device:\n${descriptor.code}',
                    ),
                  );
                },
                icon: const Icon(Icons.ios_share, size: 18, color: Colors.white70),
                label: const Text('Share code', style: TextStyle(color: Colors.white70)),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: ElevatedButton(
                onPressed: _stop,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                ),
                child: const Text('Stop'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  static String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  Future<void> _start() async {
    setState(() => _starting = true);
    try {
      // Nearby advertises over Bluetooth: location + scan/connect/advertise are
      // all needed, and ADVERTISE is the one that fails with Android's 8038.
      final status =
          await ShareService.ensureTransportPermissions(_transportId);
      if (status != PermissionStatus.granted) {
        _toast(ShareService.describeError(
          PlatformException(code: 'permission', message: 'Nearby permissions were not granted'),
          _transportId,
        ));
        return;
      }
      final hints = ShareService.pendingNearbyHints();
      if (hints.isNotEmpty) {
        // Usually "approximate location" — Nearby Connections needs precise to
        // discover peers, and telling the user to "allow location" when they
        // already did is exactly the dead end we hit.
        _permissionHint(
          'Nearby needs ${hints.join(' and ')}. Open settings to finish setup, '
          'or use the Wi-Fi option.',
        );
      }
      final manifest = await ShareService.instance.buildManifest(_items);
      if (manifest.items.isEmpty) {
        _toast('Nothing to send — the files are missing on this device.');
        return;
      }
      final descriptor = await ShareService.instance.startSending(
        manifest,
        transportId: _transportId,
      );
      _events = ShareService.instance.senderEvents(_transportId).listen((event) {
        if (!mounted) return;
        setState(() => _status = event.message ?? '');
      });
      setState(() {
        _descriptor = descriptor;
        _sentManifest = manifest;
        _sharing = true;
        _manifestItems = manifest.items.length;
        _manifestBytes = manifest.totalBytes;
        _status = 'Waiting for the other device…';
      });
    } catch (error) {
      _toast(ShareService.describeError(error, _transportId));
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _stop() async {
    final manifest = _sentManifest;
    if (manifest != null) {
      await ShareService.instance.finishSending(_transportId, manifest);
    }
    await ShareService.instance.stopSending(_transportId);
    if (!mounted) return;
    setState(() {
      _descriptor = null;
      _sharing = false;
      _status = '';
    });
  }

  /// Message with a shortcut into the app's settings page.
  void _permissionHint(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.orange,
        duration: const Duration(seconds: 8),
        action: SnackBarAction(
          label: 'Settings',
          onPressed: openAppSettings,
        ),
      ),
    );
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }
}

/// Opens the send sheet for [downloads].
Future<void> showShareSendSheet(
  BuildContext context, {
  required List<Map<String, dynamic>> downloads,
  String? title,
}) {
  return showModalBottomSheet(
    context: context,
    backgroundColor: const Color(0xFF1E1E1E),
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => ShareSendSheet(initialDownloads: downloads, title: title),
  );
}

/// Convenience used by the Downloads screen.
void openShareReceiver(BuildContext context) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => const ShareReceiveScreen()),
  );
}
