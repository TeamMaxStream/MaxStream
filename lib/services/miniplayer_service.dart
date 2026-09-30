import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// Active subtitle cue for rendering in the miniplayer.
class MiniSubtitleCue {
  const MiniSubtitleCue({
    required this.start,
    required this.end,
    required this.text,
  });

  final Duration start;
  final Duration end;
  final String text;
}

class MiniplayerService extends ChangeNotifier {
  static final MiniplayerService instance = MiniplayerService._();
  MiniplayerService._();

  VideoPlayerController? _controller;
  String _title = '';
  String _tmdbId = '';
  bool _isMovie = false;
  int _season = 1;
  int _episode = 1;
  List<int> _genreIds = const [];
  bool _minimizing = false;

  // Restored controls state
  List<Map<String, dynamic>> _availableServers = const [];
  List<Map<String, dynamic>> _subtitleTracksRaw = const [];
  List<Map<String, dynamic>> _qualitiesRaw = const [];
  String _selectedQuality = 'Auto';
  String _selectedServerKey = '';
  String _currentSource = '';
  Map<String, String> _streamHeaders = const {};
  String _selectedSubtitleValue = 'Off';
  String _selectedSubtitleUrl = '';
  List<MiniSubtitleCue> _activeSubtitleCues = const [];

  VideoPlayerController? get controller => _controller;
  String get title => _title;
  String get tmdbId => _tmdbId;
  bool get isMovie => _isMovie;
  int get season => _season;
  int get episode => _episode;
  List<int> get genreIds => _genreIds;
  bool get isActive => _controller != null;
  bool get isMinimizing => _minimizing;

  List<Map<String, dynamic>> get availableServers => _availableServers;
  List<Map<String, dynamic>> get subtitleTracksRaw => _subtitleTracksRaw;
  List<Map<String, dynamic>> get qualitiesRaw => _qualitiesRaw;
  String get selectedQuality => _selectedQuality;
  String get selectedServerKey => _selectedServerKey;
  String get currentSource => _currentSource;
  Map<String, String> get streamHeaders => _streamHeaders;
  String get selectedSubtitleValue => _selectedSubtitleValue;
  String get selectedSubtitleUrl => _selectedSubtitleUrl;
  List<MiniSubtitleCue> get activeSubtitleCues => _activeSubtitleCues;

  void minimize({
    required VideoPlayerController controller,
    required String title,
    required String tmdbId,
    required bool isMovie,
    required int season,
    required int episode,
    required List<int> genreIds,
    required List<Map<String, dynamic>> availableServers,
    required String selectedQuality,
    required String selectedServerKey,
    required String currentSource,
    required Map<String, String> streamHeaders,
    required String selectedSubtitleValue,
    required String selectedSubtitleUrl,
    required List<MiniSubtitleCue> activeSubtitleCues,
    required List<Map<String, dynamic>> qualitiesRaw,
  }) {
    // A previous miniplayer session must never outlive its replacement:
    // overwriting the field without disposing the old controller leaves it
    // playing with no UI anywhere — the "audio only, no bar" zombie.
    final previous = _controller;
    _controller = controller;
    _title = title;
    _tmdbId = tmdbId;
    _isMovie = isMovie;
    _season = season;
    _episode = episode;
    _genreIds = genreIds;
    _availableServers = availableServers;
    _selectedQuality = selectedQuality;
    _selectedServerKey = selectedServerKey;
    _currentSource = currentSource;
    _streamHeaders = streamHeaders;
    _selectedSubtitleValue = selectedSubtitleValue;
    _selectedSubtitleUrl = selectedSubtitleUrl;
    _activeSubtitleCues = activeSubtitleCues;
    _qualitiesRaw = qualitiesRaw;
    _minimizing = true;
    notifyListeners();
    _minimizing = false;
    if (previous != null && !identical(previous, controller)) {
      // Pause immediately so audio stops, but dispose only after the current
      // frame: the miniplayer bar is still showing `previous` until this
      // notifyListeners rebuild lands, and a controller disposed mid-frame
      // throws in the widget that renders it.
      previous.pause();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        previous.dispose();
      });
    }
  }

  VideoPlayerController? restore() {
    final c = _controller;
    _controller = null;
    _title = '';
    _tmdbId = '';
    _isMovie = false;
    _season = 1;
    _episode = 1;
    _genreIds = const [];
    _availableServers = const [];
    _subtitleTracksRaw = const [];
    _qualitiesRaw = const [];
    _selectedQuality = 'Auto';
    _selectedServerKey = '';
    _currentSource = '';
    _streamHeaders = const {};
    _selectedSubtitleValue = 'Off';
    _activeSubtitleCues = const [];
    notifyListeners();
    return c;
  }

  void close() {
    _controller?.dispose();
    _controller = null;
    _title = '';
    _tmdbId = '';
    _isMovie = false;
    _season = 1;
    _episode = 1;
    _genreIds = const [];
    _availableServers = const [];
    _subtitleTracksRaw = const [];
    _qualitiesRaw = const [];
    _selectedQuality = 'Auto';
    _selectedServerKey = '';
    _currentSource = '';
    _streamHeaders = const {};
    _selectedSubtitleValue = 'Off';
    _selectedSubtitleUrl = '';
    _activeSubtitleCues = const [];
    notifyListeners();
  }

  /// Pauses the miniplayer when the app goes to the background. Keeps the
  /// controller (and its position) alive so playback can resume on return,
  /// but stops audio from playing unseen. No-op when nothing is minimized.
  void pauseIfPlaying() {
    final controller = _controller;
    if (controller != null && controller.value.isPlaying) {
      controller.pause();
    }
  }
}
