import 'dart:async';

import 'package:flutter/material.dart';

import '../../database/db_helper.dart';
import '../../services/download_storage_service.dart';
import 'share_send_sheet.dart';

/// Lets the user pick exactly what to send before the pairing sheet opens.
///
/// Granularity matches how downloads are organised: movies are single items,
/// a series can be taken whole, or drilled into season by season and episode by
/// episode. Every checkbox (series, season, episode) selects its own subtree, so
/// "send the whole series but only some seasons" is two taps.
Future<void> showSharePicker(
  BuildContext context, {
  List<Map<String, dynamic>>? downloads,
  String? title,
}) async {
  final rows = downloads ?? await DBHelper.getMediaDownloads();
  if (!context.mounted) return;
  if (rows.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('There is nothing to send yet.')),
    );
    return;
  }
  final selected = await showModalBottomSheet<List<Map<String, dynamic>>>(
    context: context,
    backgroundColor: const Color(0xFF1E1E1E),
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => _SharePickerSheet(rows: rows, title: title),
  );
  if (selected == null || selected.isEmpty || !context.mounted) return;
  await showShareSendSheet(context, downloads: selected);
}

class _SharePickerSheet extends StatefulWidget {
  const _SharePickerSheet({required this.rows, this.title});

  final List<Map<String, dynamic>> rows;
  final String? title;

  @override
  State<_SharePickerSheet> createState() => _SharePickerSheetState();
}

class _SharePickerSheetState extends State<_SharePickerSheet> {
  /// downloadKey -> true when the user picked it.
  final Set<String> _selected = {};
  final Map<String, int> _sizes = {};
  bool _sizing = true;

  /// seriesId -> its episode rows, in display order.
  late final Map<String, List<Map<String, dynamic>>> _series = _groupSeries();

  Map<String, List<Map<String, dynamic>>> _groupSeries() {
    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final row in widget.rows) {
      if (row['mediaType'] != 'episode') continue;
      final key = row['seriesId']?.toString() ?? row['mediaId'].toString();
      grouped.putIfAbsent(key, () => []).add(row);
    }
    for (final episodes in grouped.values) {
      episodes.sort((a, b) {
        final season = ((a['seasonNumber'] as num?)?.toInt() ?? 0).compareTo(
          (b['seasonNumber'] as num?)?.toInt() ?? 0,
        );
        if (season != 0) return season;
        return ((a['episodeNumber'] as num?)?.toInt() ?? 0)
            .compareTo((b['episodeNumber'] as num?)?.toInt() ?? 0);
      });
    }
    return grouped;
  }

  List<Map<String, dynamic>> get _movies =>
      widget.rows.where((r) => r['mediaType'] == 'movie').toList();

  @override
  void initState() {
    super.initState();
    unawaited(_measure());
  }

  Future<void> _measure() async {
    for (final row in widget.rows) {
      final key = row['downloadKey']?.toString() ?? '';
      final path = row['localPath']?.toString() ?? '';
      if (key.isEmpty || path.isEmpty) continue;
      _sizes[key] = await DownloadStorageService.sizeOfDownload(path);
    }
    if (!mounted) return;
    setState(() => _sizing = false);
  }

  int _sizeOf(Map<String, dynamic> row) =>
      _sizes[row['downloadKey']?.toString() ?? ''] ?? 0;

  String _keyOf(Map<String, dynamic> row) => row['downloadKey']?.toString() ?? '';

  bool _isSelected(Map<String, dynamic> row) => _selected.contains(_keyOf(row));

  bool _allSelected(Iterable<Map<String, dynamic>> rows) {
    final keys = rows.map(_keyOf).toList();
    return keys.isNotEmpty && keys.every(_selected.contains);
  }

  bool _someSelected(Iterable<Map<String, dynamic>> rows) {
    final keys = rows.map(_keyOf).toList();
    return !_allSelected(rows) && keys.any(_selected.contains);
  }

  int _countSelected(Iterable<Map<String, dynamic>> rows) =>
      rows.where(_isSelected).length;

  int get _totalBytes =>
      _selected.fold<int>(0, (sum, key) => sum + (_sizes[key] ?? 0));

  void _setSubtree(List<Map<String, dynamic>> rows, bool value) {
    setState(() {
      for (final row in rows) {
        if (value) {
          _selected.add(_keyOf(row));
        } else {
          _selected.remove(_keyOf(row));
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + bottomInset),
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
            'Choose a whole series, a season, or individual episodes',
            style: const TextStyle(color: Colors.grey, fontSize: 12),
          ),
          const SizedBox(height: 12),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                if (_movies.isNotEmpty) ...[
                  const _SectionLabel('MOVIES'),
                  ..._movies.map(
                    (movie) => _EpisodeTile(
                      title: movie['title']?.toString() ?? 'Movie',
                      subtitle: 'Movie',
                      size: _sizeOf(movie),
                      selected: _isSelected(movie),
                      onChanged: (value) => _setSubtree([movie], value),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                for (final entry in _series.entries) ...[
                  _seriesBlock(entry.key, entry.value),
                ],
                if (_sizing)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.grey,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text(
                  _selected.isEmpty
                      ? 'Nothing selected'
                      : '${_selected.length} item${_selected.length == 1 ? '' : 's'} • '
                          '${DownloadStorageService.formatBytes(_totalBytes)}',
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ),
              TextButton(
                onPressed: _selected.isEmpty
                    ? null
                    : () => setState(_selected.clear),
                child: const Text('Clear', style: TextStyle(color: Colors.grey)),
              ),
            ],
          ),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _selected.isEmpty
                  ? null
                  : () => Navigator.of(context).pop(
                        widget.rows.where(_isSelected).toList(),
                      ),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: Text(
                _selected.isEmpty
                    ? 'Select something to send'
                    : 'Continue with ${_selected.length}',
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _seriesBlock(String seriesId, List<Map<String, dynamic>> episodes) {
    final seasons = <int, List<Map<String, dynamic>>>{};
    for (final episode in episodes) {
      final season = (episode['seasonNumber'] as num?)?.toInt() ?? 1;
      seasons.putIfAbsent(season, () => []).add(episode);
    }
    final title = episodes.isEmpty
        ? 'Series'
        : (episodes.first['title']?.toString().split(' - S').first ?? 'Series');
    final seriesBytes = episodes.fold<int>(0, (sum, e) => sum + _sizeOf(e));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionLabel('SERIES'),
        Container(
          decoration: BoxDecoration(
            color: const Color(0xFF242424),
            borderRadius: BorderRadius.circular(10),
          ),
          margin: const EdgeInsets.only(bottom: 6),
          child: Column(
            children: [
              Row(
                children: [
                  Checkbox(
                    // tristate with a null value renders the "some selected"
                    // dash; true/false render the whole-subtree states.
                    value: _allSelected(episodes)
                        ? true
                        : (_someSelected(episodes) ? null : false),
                    tristate: true,
                    activeColor: Colors.red,
                    onChanged: (value) => _setSubtree(episodes, value ?? false),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          '${seasons.length} season${seasons.length == 1 ? '' : 's'} • '
                          '${episodes.length} episode${episodes.length == 1 ? '' : 's'} • '
                          '${DownloadStorageService.formatBytes(seriesBytes)}',
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Whole series in one tap, then drill in.
                  TextButton(
                    onPressed: () => _setSubtree(episodes, !_allSelected(episodes)),
                    child: Text(
                      _allSelected(episodes) ? 'None' : 'Whole series',
                      style: const TextStyle(color: Colors.red, fontSize: 12),
                    ),
                  ),
                ],
              ),
              for (final season in seasons.entries) ...[
                const Divider(height: 1, color: Colors.white10),
                Row(
                  children: [
                    Checkbox(
                      value: _allSelected(season.value)
                          ? true
                          : (_someSelected(season.value) ? null : false),
                      tristate: true,
                      activeColor: Colors.red,
                      onChanged: (value) =>
                          _setSubtree(season.value, value ?? false),
                    ),
                    Expanded(
                      child: Text(
                        'Season ${season.key}',
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ),
                    Text(
                      '${_countSelected(season.value)}/${season.value.length} • '
                      '${DownloadStorageService.formatBytes(season.value.fold<int>(0, (sum, e) => sum + _sizeOf(e)))}',
                      style: const TextStyle(color: Colors.white38, fontSize: 11),
                    ),
                  ],
                ),
                for (final episode in season.value)
                  _EpisodeTile(
                    title: episode['episodeName']?.toString() ??
                        'S${episode['seasonNumber']}E${episode['episodeNumber']}',
                    subtitle: 'S${episode['seasonNumber']}E${episode['episodeNumber']}',
                    size: _sizeOf(episode),
                    selected: _isSelected(episode),
                    indent: true,
                    onChanged: (value) => _setSubtree([episode], value),
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 4),
        child: Text(
          text,
          style: const TextStyle(
            color: Colors.white38,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.2,
          ),
        ),
      );
}

class _EpisodeTile extends StatelessWidget {
  const _EpisodeTile({
    required this.title,
    required this.subtitle,
    required this.size,
    required this.selected,
    required this.onChanged,
    this.indent = false,
  });

  final String title;
  final String subtitle;
  final int size;
  final bool selected;
  final ValueChanged<bool> onChanged;
  final bool indent;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onChanged(!selected),
      child: Padding(
        padding: EdgeInsets.only(left: indent ? 40 : 8, right: 8, top: 2, bottom: 2),
        child: Row(
          children: [
            Checkbox(
              value: selected,
              activeColor: Colors.red,
              onChanged: (value) => onChanged(value ?? false),
            ),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: selected ? Colors.white : Colors.white70,
                  fontSize: 14,
                ),
              ),
            ),
            Text(
              '$subtitle • ${DownloadStorageService.formatBytes(size)}',
              style: const TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}
