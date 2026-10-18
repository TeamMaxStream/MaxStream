import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../services/download_storage_service.dart';
import '../../services/share/share_models.dart';
import '../../services/share/share_service.dart';

/// Receives movies/series shared from another device.
///
/// Paste or scan the sender's code, preview what they are offering, pick what
/// to take, and the files land in the Downloads screen as normal downloads
/// (poster, offline playback, storage accounting and delete all work).
class ShareReceiveScreen extends StatefulWidget {
  const ShareReceiveScreen({super.key});

  @override
  State<ShareReceiveScreen> createState() => _ShareReceiveScreenState();
}

class _ShareReceiveScreenState extends State<ShareReceiveScreen> {
  final TextEditingController _codeController = TextEditingController();

  ShareDescriptor? _descriptor;
  ShareManifest? _manifest;
  bool _connecting = false;
  bool _receiving = false;
  String _stage = '';
  String? _error;
  final Set<String> _selected = {};
  StreamSubscription<Map<int, dynamic>>? _progressSub;

  @override
  void dispose() {
    _progressSub?.cancel();
    if (_descriptor != null) {
      unawaited(ShareService.instance.cancelReceive(_descriptor!.transportId));
    }
    _codeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text(
          'Receive',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
      ),
      body: _manifest == null ? _buildConnect() : _buildPreview(),
    );
  }

  Widget _buildConnect() {
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        16,
        16,
        16,
        16 + MediaQuery.viewPaddingOf(context).bottom,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Enter the code shown on the sending device',
            style: TextStyle(color: Colors.white70),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _codeController,
            autocorrect: false,
            enableSuggestions: false,
            style: const TextStyle(color: Colors.white, fontSize: 13),
            decoration: InputDecoration(
              hintText: 'maxstream:lan:192.168.1.5:41234:ab12cd34',
              hintStyle: const TextStyle(color: Colors.white24, fontSize: 12),
              filled: true,
              fillColor: const Color(0xFF1A1A1A),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _connecting ? null : () => _connect(_codeController.text),
                  icon: const Icon(Icons.link, size: 18),
                  label: Text(_connecting ? 'Connecting…' : 'Connect'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _connecting ? null : _scan,
                  icon: const Icon(Icons.qr_code_scanner, size: 18),
                  label: const Text('Scan'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(_error!, style: const TextStyle(color: Colors.redAccent)),
          ],
          const SizedBox(height: 24),
          const _HowItWorks(),
        ],
      ),
    );
  }

  Widget _buildPreview() {
    final manifest = _manifest!;
    final totalSelected = _manifest!.items
        .where((i) => _selected.contains(i.downloadKey))
        .fold<int>(0, (sum, item) => sum + item.totalBytes);

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                'From ${manifest.senderName}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${manifest.items.length} item${manifest.items.length == 1 ? '' : 's'} • '
                '${DownloadStorageService.formatBytes(manifest.totalBytes)}',
                style: const TextStyle(color: Colors.white54),
              ),
              const SizedBox(height: 16),
              ...manifest.items.map(_buildItem),
            ],
          ),
        ),
        if (_receiving) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.red,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _stage.isEmpty ? 'Receiving…' : 'Receiving $_stage',
                    style: const TextStyle(color: Colors.white70),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ] else
          Padding(
            padding: EdgeInsets.fromLTRB(
              16,
              8,
              16,
              16 + MediaQuery.viewPaddingOf(context).bottom,
            ),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _selected.isEmpty ? null : _receive,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: Text(
                  _selected.isEmpty
                      ? 'Select something to receive'
                      : 'Receive ${_selected.length} item${_selected.length == 1 ? '' : 's'} '
                          '(${DownloadStorageService.formatBytes(totalSelected)})',
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildItem(ShareItem item) {
    final selected = _selected.contains(item.downloadKey);
    return Card(
      color: const Color(0xFF1E1E1E),
      child: CheckboxListTile(
        value: selected,
        activeColor: Colors.red,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
        title: Text(
          item.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white),
        ),
        subtitle: Text(
          '${item.episodeLabel} • '
          '${DownloadStorageService.formatBytes(item.totalBytes)} • '
          '${item.files.length} file${item.files.length == 1 ? '' : 's'}',
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
        onChanged: (value) {
          setState(() {
            if (value == true) {
              _selected.add(item.downloadKey);
            } else {
              _selected.remove(item.downloadKey);
            }
          });
        },
      ),
    );
  }

  Future<void> _connect(String raw) async {
    final descriptor = ShareDescriptor.tryParse(raw);
    if (descriptor == null) {
      setState(() => _error = 'That does not look like a MaxStream share code.');
      return;
    }
    setState(() {
      _connecting = true;
      _error = null;
    });
    try {
      final manifest = await ShareService.instance.previewShare(descriptor);
      setState(() {
        _descriptor = descriptor;
        _manifest = manifest;
        _selected.addAll(manifest.items.map((i) => i.downloadKey));
      });
    } catch (error) {
      setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  Future<void> _scan() async {
    final code = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(builder: (_) => const _QrScannerScreen()),
    );
    if (code == null || !mounted) return;
    _codeController.text = code;
    await _connect(code);
  }

  Future<void> _receive() async {
    final descriptor = _descriptor;
    final manifest = _manifest;
    if (descriptor == null || manifest == null) return;
    final items = manifest.items
        .where((i) => _selected.contains(i.downloadKey))
        .toList();
    setState(() {
      _receiving = true;
      _stage = '';
    });
    _progressSub = ShareService.instance.progress(descriptor.transportId).listen((_) {
      if (mounted) setState(() {});
    });
    try {
      await ShareService.instance.receive(
        descriptor,
        manifest,
        items,
        onStage: (title) {
          if (mounted) setState(() => _stage = title);
        },
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Added ${items.length} item${items.length == 1 ? '' : 's'} to Downloads',
          ),
          backgroundColor: Colors.green,
        ),
      );
      Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = '$error';
          _receiving = false;
        });
      }
    } finally {
      await _progressSub?.cancel();
      _progressSub = null;
    }
  }
}

class _HowItWorks extends StatelessWidget {
  const _HowItWorks();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: const [
        Text(
          'HOW IT WORKS',
          style: TextStyle(
            color: Colors.white54,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.2,
          ),
        ),
        SizedBox(height: 8),
        Text(
          '• On the other device open Downloads → Send on a movie or series.\n'
          '• Put both phones on the same Wi-Fi (or join its hotspot), or pick '
          'the nearby option to pair with no network at all.\n'
          '• Scan or paste the code shown there.',
          style: TextStyle(color: Colors.white38, fontSize: 12, height: 1.5),
        ),
      ],
    );
  }
}

class _QrScannerScreen extends StatefulWidget {
  const _QrScannerScreen();

  @override
  State<_QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends State<_QrScannerScreen> {
  final MobileScannerController _controller = MobileScannerController();
  bool _handled = false;
  bool _cameraDenied = false;

  @override
  void initState() {
    super.initState();
    unawaited(_requestCamera());
  }

  /// mobile_scanner declares CAMERA but can't ask for it; without this the
  /// preview is black and every scan silently fails.
  Future<void> _requestCamera() async {
    final status = await Permission.camera.request();
    if (status.isGranted || status.isLimited) return;
    if (!mounted) return;
    setState(() => _cameraDenied = true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_cameraDenied) {
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          title: const Text('Scan share code'),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Camera permission is needed to scan, or type the code instead.',
                  style: TextStyle(color: Colors.white70),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: () async {
                    await openAppSettings();
                  },
                  child: const Text('Open settings'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Scan share code'),
      ),
      body: MobileScanner(
        controller: _controller,
        onDetect: (capture) {
          if (_handled) return;
          for (final barcode in capture.barcodes) {
            final value = barcode.rawValue;
            if (value == null) continue;
            if (ShareDescriptor.tryParse(value) == null) continue;
            _handled = true;
            Navigator.of(context).pop(value);
            return;
          }
        },
        errorBuilder: (context, error) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'Camera unavailable — type the code instead.\n($error)',
              style: const TextStyle(color: Colors.white70),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}
