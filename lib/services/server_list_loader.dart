import 'direct_m3u8_service.dart';

/// Shared two-phase server-list loading for the download/playback pickers.
///
/// Phase 0 paints the in-memory cache instantly (after a prefetch on the
/// details screen this means zero spinner). Phase 1 runs a fast native
/// resolve (short budgets, master-only HLS validation) so servers appear in
/// seconds. Phase 2 re-resolves fully in the background and silently corrects
/// any false positives/negatives from the fast pass.
class ServerListLoader {
  /// Streams with an empty URL are failed entries (listed for re-fetch, never
  /// for download/playback).
  static List<Map<String, dynamic>> availableOnly(
    List<Map<String, dynamic>> streams,
  ) => streams
      .where((stream) => (stream['url']?.toString() ?? '').isNotEmpty)
      .toList();

  /// Runs the three phases, invoking [onUpdate] with
  /// `(available, loading, refreshing, error)`. [isCurrent] must return false
  /// once the caller no longer wants updates (sheet disposed / new resolve
  /// started) so stale async results never overwrite fresh ones.
  static Future<void> load({
    required String title,
    required String tmdbId,
    required bool isMovie,
    int season = 1,
    int episode = 1,
    required bool Function() isCurrent,
    required void Function(
      List<Map<String, dynamic>> available,
      bool loading,
      bool refreshing,
      Object? error,
    )
    onUpdate,
  }) async {
    var painted = false;

    // Phase 0: cache.
    final cached = DirectM3u8Service.cachedStreams(
      tmdbId: tmdbId,
      isMovie: isMovie,
      season: season,
      episode: episode,
    );
    if (cached != null) {
      final available = availableOnly(cached);
      if (available.isNotEmpty && isCurrent()) {
        painted = true;
        onUpdate(available, false, true, null);
      }
    }

    // Phase 1: fast resolve.
    try {
      final streams = await DirectM3u8Service.fetchAvailableStreams(
        title: title,
        tmdbId: tmdbId,
        isMovie: isMovie,
        season: season,
        episode: episode,
        fast: true,
        useCache: false,
      );
      if (!isCurrent()) return;
      final available = availableOnly(streams);
      painted = true;
      onUpdate(available, false, true, null);
    } catch (error) {
      if (!isCurrent()) return;
      if (!painted) {
        onUpdate(const [], false, false, error);
        return;
      }
      // Cache/fast failed but something is already painted: keep it and let
      // the full pass below decide.
    }

    // Phase 2: full resolve (also refreshes the cache).
    try {
      final streams = await DirectM3u8Service.fetchAvailableStreams(
        title: title,
        tmdbId: tmdbId,
        isMovie: isMovie,
        season: season,
        episode: episode,
      );
      if (!isCurrent()) return;
      onUpdate(availableOnly(streams), false, false, null);
    } catch (_) {
      if (!isCurrent()) return;
      // Fast pass already painted: just stop the spinner, keep the list.
      if (painted) {
        onUpdate(const [], false, false, null);
      }
    }
  }
}
