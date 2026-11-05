import 'dart:async';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../services/logger_service.dart';

const MethodChannel _nativeCrashChannel = MethodChannel(
  'com.maxstream.app/crashlog',
);

/// Playback heartbeat file. Written while a video plays; cleared on a clean
/// player dispose and on app backgrounding. Its mere presence at a cold start
/// means the previous process died in the foreground without a chance to shut
/// down - the Low-Memory-Killer SIGKILL that no JVM/Dart handler can observe.
Future<File?> _heartbeatFile() async {
  try {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/maxstream_heartbeat.txt');
  } catch (_) {
    return null;
  }
}

Future<void> heartbeatTouch() async {
  try {
    final file = await _heartbeatFile();
    await file?.writeAsString('${DateTime.now().millisecondsSinceEpoch}');
  } catch (_) {
    // Never crash the player over the heartbeat.
  }
}

Future<void> heartbeatClear() async {
  try {
    await (await _heartbeatFile())?.delete();
  } catch (_) {}
}

/// Surfaces a playback session that was killed without a clean exit.
///
/// Called at every cold start after [checkForNativeCrash]. If the heartbeat is
/// still on disk, the last run's player was active when the process died
/// (Low Memory Killer, power cut to the TV while foregrounded, reboot). The
/// marker is consumed on read so it only reports once.
Future<void> checkUnexpectedExit() async {
  if (crashReport.value != null) return;
  try {
    final file = await _heartbeatFile();
    if (file == null || !await file.exists()) return;
    final stat = await file.stat();
    final age = DateTime.now().difference(stat.modified).inHours;
    if (age > 24) {
      // Leftover from an old session (e.g. after a version bump removed a
      // cleanup path) - not a fresh death, so don't bother the user with it.
      await file.delete();
      return;
    }
    final trace = playbackTraceNote;
    crashReport.value = CrashInfo(
      tag: 'UnexpectedExit',
      error:
          'Your TV closed MaxStream while you were watching (usually '
          'because it ran low on memory, or the device restarted).'
          '${trace.isEmpty ? '' : '\n\n$trace'}',
      stack: StackTrace.fromString(
        'The player was active when the previous process was terminated '
        'without a clean shutdown - this is typically the system\'s Low '
        'Memory Killer, which no crash handler can intercept.',
      ),
      time: DateTime.now(),
    );
    await file.delete();
  } catch (_) {}
}

void installGlobalCrashHandlers() {
  FlutterError.onError = (FlutterErrorDetails details) {
    recordCrash(
      'FlutterError',
      details.exception,
      details.stack ?? StackTrace.current,
    );
  };
  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    recordCrash('PlatformDispatcher', error, stack);
    return true;
  };
}

/// Surfaces a *native* (JVM) crash that happened in a previous process run.
///
/// Dart-level hooks ([FlutterError], [PlatformDispatcher], the zone) can never
/// see a hard process death, so MainActivity writes an uncaught-exception
/// tombstone before aborting. This reads (and clears) that tombstone; the run
/// then boots straight into the crash screen. Called before runApp so the gate
/// is already populated when the first frame renders.
Future<void> checkForNativeCrash() async {
  if (crashReport.value != null) return;
  try {
    final text = await _nativeCrashChannel.invokeMethod<String>(
      'getNativeCrashTombstone',
    );
    if (text == null || !text.contains('[NativeCrash]')) return;
    final lines = text.split('\n');
    final errorLine = lines.firstWhere(
      (line) => line.contains('[NativeCrash]'),
      orElse: () => 'Native crash',
    );
    final error = errorLine.replaceFirst('[NativeCrash]', '').trim();
    final stackLines = <String>[];
    var inStack = false;
    for (final line in lines) {
      if (line.startsWith('Stack:')) {
        inStack = true;
        continue;
      }
      if (inStack) stackLines.add(line);
    }
    crashReport.value = CrashInfo(
      tag: 'NativeCrash',
      error: error.isEmpty ? 'Native crash' : error,
      stack: StackTrace.fromString(
        stackLines.isEmpty ? text : stackLines.join('\n'),
      ),
      time: DateTime.now(),
    );
    // A native tombstone already explains the death - consume the playback
    // heartbeat too so the same boot can't also show 'UnexpectedExit'. (LMK
    // kills have no tombstone, so checkUnexpectedExit still owns that case.)
    await heartbeatClear();
  } catch (_) {
    // No native handler / channel unavailable: the run continues normally and
    // any Dart errors still report through the in-memory crash screen.
  }
}

class CrashInfo {
  const CrashInfo({
    required this.tag,
    required this.error,
    required this.stack,
    required this.time,
  });

  final String tag;
  final Object error;
  final StackTrace stack;
  final DateTime time;
}

final ValueNotifier<CrashInfo?> crashReport = ValueNotifier<CrashInfo?>(null);

/// Ring buffer of the last few playback steps, kept in memory and appended to
/// the crash log so that even a native process death (Low-Memory-Killer, GPU
/// driver crash) leaves a trail of where the player was when it died. The TV
/// player writes a step before/after every meaningful transition (resolving,
/// pre-flight, player create, server attempts, playback start).
final List<String> playbackTrace = <String>[];

/// Records a playback step for the on-device crash trail. Must never throw.
void recordPlaybackTrace(String line) {
  try {
    final stamped = '[$_traceClock] $line';
    playbackTrace.add(stamped);
    if (playbackTrace.length > 8) playbackTrace.removeAt(0);
    unawaited(_appendCrashLog('[PlaybackTrace] $stamped\n'));
  } catch (_) {
    // Diagnostics must never crash the player.
  }
}

String get _traceClock {
  final now = DateTime.now();
  final hh = now.hour.toString().padLeft(2, '0');
  final mm = now.minute.toString().padLeft(2, '0');
  final ss = now.second.toString().padLeft(2, '0');
  return '$hh:$mm:$ss';
}

/// The last playback steps formatted for inclusion in a crash report, or an
/// empty string when there is nothing to show.
String get playbackTraceNote {
  if (playbackTrace.isEmpty) return '';
  return 'Last player steps:\n${playbackTrace.join('\n')}';
}

/// True for the benign channel-error thrown by the video player's
/// buffered-position poll when it races player teardown.
///
/// When the native player is disposed, its per-player pigeon channel handler
/// is torn down, so an in-flight or late `getBufferedPosition` call fails with
/// a `channel-error` PlatformException. The vendored plugin (third_party/
/// video_player_android) now swallows this itself, but a release APK built
/// from an older checkout still throws it. Buffer polling is only a progress
/// nicety - the exception is never a real failure, so it must not show the
/// crash screen or spam Crashlytics.
bool isBenignVideoPlayerChannelError(Object error) {
  if (error is! PlatformException) return false;
  if (error.code != 'channel-error') return false;
  final message = error.message?.toString() ?? '';
  return message.contains('video_player_android') &&
      message.contains('getBufferedPosition');
}

/// True for transient image-network load failures, e.g. a TMDB poster/backdrop
/// dropped mid-download ("Connection closed while receiving data"). These are
/// never app bugs - the image widget already renders its fallback - so they
/// must not show the crash screen or be reported as a fatal Crashlytics event.
bool isBenignImageNetworkError(Object error) {
  if (error is SocketException) return true;
  if (error is HttpException) return true;
  final message = error.toString();
  return message.contains('Connection closed while receiving data') ||
      message.contains('image.tmdb.org') ||
      message.contains('Failed host lookup') ||
      message.contains('Connection timed out') ||
      message.contains('Connection reset') ||
      message.contains('Network is unreachable');
}

bool isRenderFlexOverflowError(Object error) {
  final msg = error.toString();
  return msg.contains('RenderFlex overflowed') || msg.contains('overflowed by');
}

bool isBenignFvpStreamError(Object error) {
  final msg = error.toString();
  // fvp / MdkVideoPlayer throws Bad state: Cannot add event after closing when
  // disposing a player while native events are still in flight (server switch).
  // This is a race in the plugin, not an app bug - safe to ignore and let the
  // new player take over. Otherwise it shows crash screen and leaves UI stuck
  // at "Switching to Auto".
  return msg.contains('Cannot add event after closing') &&
      (msg.contains('MdkVideoPlayer') ||
          msg.contains('fvp') ||
          msg.contains('StreamController'));
}

/// Single decision point for whether an error should be ignored by every
/// crash funnel (zone, FlutterError, PlatformDispatcher). A benign error never
/// shows the crash screen and is never recorded as fatal.
bool isBenignError(Object error) {
  return isBenignVideoPlayerChannelError(error) ||
      isBenignImageNetworkError(error) ||
      isRenderFlexOverflowError(error) ||
      isBenignFvpStreamError(error);
}

Future<void> recordCrash(String tag, Object error, StackTrace stack) async {
  // Swallow benign errors (see isBenignError) before anything records them: no
  // crash screen, no Crashlytics non-fatal. Every handler (zone, FlutterError,
  // PlatformDispatcher) funnels through here, so a single check covers all.
  if (isBenignError(error)) {
    debugPrint('Ignoring benign error: $error');
    return;
  }
  final time = DateTime.now();
  final trace = playbackTraceNote;
  final reported = trace.isEmpty ? '$error' : '$error\n\n$trace';
  LoggerService.error('[$tag] $reported', error, stack);
  unawaited(_appendCrashLog('[$time] [$tag] $reported\n$stack\n'));
  // The user is about to see the report screen for this crash - don't also
  // flag the now-dead process as an "unexpected exit" on the next boot.
  unawaited(heartbeatClear());
  if (crashReport.value == null) {
    crashReport.value = CrashInfo(
      tag: tag,
      error: reported,
      stack: stack,
      time: time,
    );
  }
}

Future<File?> _crashLogFile() async {
  try {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/maxstream_crash.log');
  } catch (_) {
    return null;
  }
}

Future<void> _appendCrashLog(String line) async {
  try {
    final file = await _crashLogFile();
    await file?.writeAsString(line, mode: FileMode.append);
  } catch (_) {
    // Logging must never crash the app.
  }
}

Future<void> restartApp() async {
  const channel = MethodChannel('com.maxstream.app/restart');
  try {
    await channel.invokeMethod<void>('restartApp');
  } catch (_) {
    await SystemNavigator.pop();
  }
}

class CrashReportGate extends StatelessWidget {
  const CrashReportGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<CrashInfo?>(
      valueListenable: crashReport,
      builder: (context, report, _) {
        if (report == null) return child;
        return CrashScreen(report: report);
      },
    );
  }
}

class CrashScreen extends StatelessWidget {
  const CrashScreen({super.key, required this.report});

  final CrashInfo report;

  /// First app-owned frame in the stack, e.g.
  /// `lib/tv/screens/tv_search_screen.dart:74  TvSearchScreenState.dispose`.
  /// Null-able formatting in a tiny box so the report names the widget/screen
  /// that crashed instead of burying it in the long stack below.
  String? get _origin {
    final frames = report.stack.toString().split('\n');
    for (final frame in frames) {
      final app = RegExp(r'package:maxstream/([^\s]+)').firstMatch(frame);
      if (app == null) continue;
      final symbol = frame.trim().split(' (')[0];
      return '${app.group(1)}${symbol.isNotEmpty ? '  $symbol' : ''}';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final summary = '${report.tag}: ${report.error}';
    final shortSummary = summary.length > 180
        ? '${summary.substring(0, 177)}...'
        : summary;
    return MaterialApp(
      theme: ThemeData.dark(),
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(
                      Icons.error_outline,
                      size: 64,
                      color: Colors.redAccent,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Something went wrong',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${report.time}',
                      style: const TextStyle(color: Colors.grey, fontSize: 13),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1A1A1A),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        shortSummary,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 14,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                    if (_origin != null) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: const Color(0x33FF5252),
                          border: Border.all(color: const Color(0x66FF5252)),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          'Crashed in: $_origin',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontFamily: 'monospace',
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFF141414),
                        border: Border.all(color: const Color(0xFF2A2A2A)),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: SizedBox(
                        height: 240,
                        child: SingleChildScrollView(
                          child: Text(
                            report.stack.toString(),
                            style: const TextStyle(
                              color: Colors.grey,
                              fontSize: 12,
                              fontFamily: 'monospace',
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    SizedBox(
                      height: 56,
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () {
                          final fullReport =
                              'Tag: ${report.tag}\n'
                              'Time: ${report.time}\n'
                              'Error: ${report.error}\n\n'
                              'Stack Trace:\n${report.stack}';
                          Clipboard.setData(ClipboardData(text: fullReport));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Error copied to clipboard'),
                              duration: Duration(seconds: 2),
                            ),
                          );
                        },
                        icon: const Icon(Icons.copy),
                        label: const Text('Copy error details'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white70,
                          side: const BorderSide(color: Colors.white24),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: SizedBox(
                            height: 56,
                            child: OutlinedButton.icon(
                              onPressed: () => SystemNavigator.pop(),
                              icon: const Icon(Icons.close),
                              label: const Text('Exit'),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.white,
                                side: const BorderSide(color: Colors.white38),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: SizedBox(
                            height: 56,
                            child: FilledButton.icon(
                              autofocus: true,
                              onPressed: () => unawaited(restartApp()),
                              icon: const Icon(Icons.refresh),
                              label: const Text('Restart app'),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
