import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';

class MediaSessionHandler {
  static MediaSessionHandler? _instance;
  static MediaSessionHandler get instance =>
      _instance ??= MediaSessionHandler._();
  MediaSessionHandler._();

  MaxStreamAudioHandler? _handler;
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    try {
      _handler =
          await AudioService.init(
                builder: () => MaxStreamAudioHandler(),
                config: const AudioServiceConfig(
                  androidNotificationChannelId: 'com.maxstream.app.playback',
                  androidNotificationChannelName: 'MaxStream Playback',
                  androidNotificationOngoing: true,
                  androidStopForegroundOnPause: true,
                ),
              )
              as MaxStreamAudioHandler;
      _initialized = true;
    } catch (e) {
      debugPrint('MediaSession init error: $e');
    }
  }

  MaxStreamAudioHandler? get handler => _handler;

  void updateMetadata({
    required String title,
    required String artist,
    Duration? duration,
    String? artUri,
  }) {
    _handler?.mediaItem.add(
      MediaItem(
        id: 'maxstream_current',
        title: title,
        artist: artist,
        artUri: artUri != null ? Uri.parse(artUri) : null,
        duration: duration,
      ),
    );
  }

  void updatePlaybackState({
    required bool isPlaying,
    required Duration position,
    required Duration duration,
  }) {
    _handler?.playbackState.add(
      PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          if (isPlaying) MediaControl.pause else MediaControl.play,
          MediaControl.skipToNext,
          MediaControl.stop,
        ],
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        androidCompactActionIndices: const [0, 1, 2],
        processingState: AudioProcessingState.ready,
        playing: isPlaying,
        updatePosition: position,
        bufferedPosition: position,
        speed: 1.0,
      ),
    );
  }

  void updateProgress({
    required bool isPlaying,
    required Duration position,
    required Duration duration,
  }) {
    _handler?.playbackState.add(
      PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          // Must mirror the real state: publishing `playing: true` with a Pause
          // control while the video is paused made the notification lie, and
          // tapping its Play button re-entered playback the user had ended.
          if (isPlaying) MediaControl.pause else MediaControl.play,
          MediaControl.skipToNext,
          MediaControl.stop,
        ],
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        androidCompactActionIndices: const [0, 1, 2],
        processingState: AudioProcessingState.ready,
        playing: isPlaying,
        updatePosition: position,
        bufferedPosition: position,
        speed: 1.0,
      ),
    );
  }

  void notifyStopped() {
    _handler?.playbackState.add(
      PlaybackState(processingState: AudioProcessingState.idle, playing: false),
    );
  }
}

class MaxStreamAudioHandler extends BaseAudioHandler with SeekHandler {
  VoidCallback? onPlay;
  VoidCallback? onPause;
  VoidCallback? onSkipPrevious;
  VoidCallback? onSkipNext;
  void Function(Duration)? onSeek;
  VoidCallback? onStop;

  @override
  Future<void> play() async => onPlay?.call();

  @override
  Future<void> pause() async => onPause?.call();

  @override
  Future<void> skipToPrevious() async => onSkipPrevious?.call();

  @override
  Future<void> skipToNext() async => onSkipNext?.call();

  @override
  Future<void> seek(Duration position) async => onSeek?.call(position);

  @override
  Future<void> stop() async => onStop?.call();
}
