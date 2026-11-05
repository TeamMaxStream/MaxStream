import 'dart:async';

import 'package:flutter/material.dart';
import '../models/subtitle_settings.dart';
import '../services/cloud_sync_service.dart';

class SubtitleSettingsScreen extends StatefulWidget {
  const SubtitleSettingsScreen({super.key});

  @override
  State<SubtitleSettingsScreen> createState() => _SubtitleSettingsScreenState();
}

class _SubtitleSettingsScreenState extends State<SubtitleSettingsScreen> {
  SubtitleSettings _settings = SubtitleSettings();
  bool _loading = true;

  // Listen to subtitlePrefsRevision so the screen reloads whenever another
  // device (e.g. TV) pushes new subtitle settings to Firebase.
  late final VoidCallback _syncListener;

  @override
  void initState() {
    super.initState();
    _syncListener = () {
      // Only reload if the screen is still mounted and not already loading
      if (mounted && !_loading) _load(silent: true);
    };
    CloudSyncService.subtitlePrefsRevision.addListener(_syncListener);
    _load();
  }

  @override
  void dispose() {
    CloudSyncService.subtitlePrefsRevision.removeListener(_syncListener);
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent && mounted) setState(() => _loading = true);
    final s = await SubtitleSettings.load();
    if (mounted)
      setState(() {
        _settings = s;
        _loading = false;
      });
  }

  Future<void> _save() async {
    await _settings.save();
    unawaited(CloudSyncService.pushSubtitleSettings());
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Subtitle settings saved'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        backgroundColor: const Color(0xFF121212),
        appBar: AppBar(
          backgroundColor: const Color(0xFF1A1A1A),
          title: const Text(
            'Subtitle Settings',
            style: TextStyle(color: Colors.white),
          ),
        ),
        body: const Center(child: CircularProgressIndicator(color: Colors.red)),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text(
          'Subtitle Settings',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        actions: [
          TextButton(
            onPressed: () {
              setState(() => _settings = SubtitleSettings());
              _save();
            },
            child: const Text('Reset', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildPreview(),
            const SizedBox(height: 24),
            _buildSectionHeader('TEXT'),
            _buildColorTile('Text Color', _settings.textColorParsed, (c) {
              setState(
                () => _settings.textColor = SubtitleSettings.colorToHex(c),
              );
              _save();
            }),
            _buildSlider('Font Size', _settings.fontSize, 12, 32, (v) {
              setState(() => _settings.fontSize = v);
            }, onChangeEnd: (_) => _save()),
            const SizedBox(height: 16),
            _buildSectionHeader('BACKGROUND'),
            _buildColorTile(
              'Background Color',
              _settings.backgroundColorParsed,
              (c) {
                setState(
                  () => _settings.backgroundColor = SubtitleSettings.colorToHex(
                    c,
                  ),
                );
                _save();
              },
            ),
            _buildSlider('Opacity', _settings.backgroundOpacity, 0, 1, (v) {
              setState(() => _settings.backgroundOpacity = v);
            }, onChangeEnd: (_) => _save()),
            const SizedBox(height: 16),
            _buildSectionHeader('EDGE / SHADOW'),
            _buildEdgeTypeTile(),
            _buildColorTile('Edge Color', _settings.edgeColorParsed, (c) {
              setState(
                () => _settings.edgeColor = SubtitleSettings.colorToHex(c),
              );
              _save();
            }),
            _buildToggle('Text Shadow', _settings.textShadow, (v) {
              setState(() => _settings.textShadow = v);
              _save();
            }),
            if (_settings.textShadow)
              _buildColorTile('Shadow Color', _settings.textShadowColorParsed, (
                c,
              ) {
                setState(
                  () => _settings.textShadowColor = SubtitleSettings.colorToHex(
                    c,
                  ),
                );
                _save();
              }),
            const SizedBox(height: 16),
            _buildSectionHeader('POSITION'),
            _buildPositionTile(),
          ],
        ),
      ),
    );
  }

  Widget _buildPreview() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey[900],
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          const Text(
            'Preview',
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            height: 100,
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Stack(
              alignment: _settings.position == 'top'
                  ? Alignment.topCenter
                  : Alignment.bottomCenter,
              children: [
                Center(
                  child: Text(
                    'Sample Video',
                    style: TextStyle(color: Colors.grey[700], fontSize: 14),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: _settings.backgroundColorParsed.withValues(
                        alpha: _settings.backgroundOpacity,
                      ),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      'This is a sample subtitle',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: _settings.textColorParsed,
                        fontSize: _settings.fontSize.clamp(10, 24),
                        fontWeight: FontWeight.w600,
                        shadows: _settings.textShadow
                            ? [
                                Shadow(
                                  color: _settings.textShadowColorParsed,
                                  blurRadius: 3,
                                ),
                              ]
                            : null,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: TextStyle(
          color: Colors.grey[500],
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  Widget _buildColorTile(
    String label,
    Color currentColor,
    ValueChanged<Color> onColorChanged,
  ) {
    return ListTile(
      title: Text(label, style: const TextStyle(color: Colors.white)),
      trailing: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: currentColor,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.grey),
        ),
      ),
      onTap: () => _showColorPicker(currentColor, onColorChanged),
    );
  }

  void _showColorPicker(Color current, ValueChanged<Color> onChanged) {
    final colors = [
      Colors.white,
      Colors.yellow,
      Colors.lime,
      Colors.green,
      Colors.cyan,
      Colors.blue,
      Colors.purple,
      Colors.red,
      Colors.orange,
      Colors.grey,
      Colors.amber,
      Colors.teal,
      Colors.pink,
      Colors.indigo,
      Colors.brown,
    ];
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      builder: (ctx) => Container(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Choose Color',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: colors.map((c) {
                final selected = c.value == current.value;
                return GestureDetector(
                  onTap: () {
                    onChanged(c);
                    Navigator.pop(ctx);
                  },
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: c,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: selected ? Colors.red : Colors.grey,
                        width: selected ? 3 : 1,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildSlider(
    String label,
    double value,
    double min,
    double max,
    ValueChanged<double> onChanged, {
    ValueChanged<double>? onChangeEnd,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label, style: const TextStyle(color: Colors.white)),
              Text(
                value.toStringAsFixed(1),
                style: const TextStyle(color: Colors.grey),
              ),
            ],
          ),
        ),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          activeColor: Colors.red,
          inactiveColor: Colors.grey[800],
          onChanged: onChanged,
          onChangeEnd: onChangeEnd,
        ),
      ],
    );
  }

  Widget _buildToggle(String label, bool value, ValueChanged<bool> onChanged) {
    return SwitchListTile(
      title: Text(label, style: const TextStyle(color: Colors.white)),
      value: value,
      onChanged: onChanged,
      activeColor: Colors.green,
    );
  }

  Widget _buildEdgeTypeTile() {
    final types = ['none', 'outline', 'dropShadow'];
    final labels = {
      'none': 'None',
      'outline': 'Outline',
      'dropShadow': 'Drop Shadow',
    };
    return ListTile(
      title: const Text('Edge Type', style: TextStyle(color: Colors.white)),
      trailing: DropdownButton<String>(
        value: _settings.edgeType,
        dropdownColor: const Color(0xFF2A2A2A),
        style: const TextStyle(color: Colors.white),
        items: types
            .map((t) => DropdownMenuItem(value: t, child: Text(labels[t]!)))
            .toList(),
        onChanged: (v) {
          if (v != null) {
            setState(() => _settings.edgeType = v);
            _save();
          }
        },
      ),
    );
  }

  Widget _buildPositionTile() {
    return ListTile(
      title: const Text('Position', style: TextStyle(color: Colors.white)),
      trailing: DropdownButton<String>(
        value: _settings.position,
        dropdownColor: const Color(0xFF2A2A2A),
        style: const TextStyle(color: Colors.white),
        items: const [
          DropdownMenuItem(value: 'bottom', child: Text('Bottom')),
          DropdownMenuItem(value: 'top', child: Text('Top')),
        ],
        onChanged: (v) {
          if (v != null) {
            setState(() => _settings.position = v);
            _save();
          }
        },
      ),
    );
  }
}
