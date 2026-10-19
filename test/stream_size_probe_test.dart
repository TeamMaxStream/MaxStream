import 'package:flutter_test/flutter_test.dart';
import 'package:maxstream/services/stream_size_probe.dart';

/// Network checks for the quality-size probe.
///
/// These hit public sample streams so a parsing regression shows up here rather
/// than as a "—" on someone's download sheet.
void main() {
  // Master playlist that lists its variants as RELATIVE paths ("v5/prog_index.m3u8").
  const master =
      'https://devstreaming-cdn.apple.com/videos/streaming/examples/'
      'img_bipbop_adv_example_fmp4/master.m3u8';
  // The media playlist that master resolves to: no BANDWIDTH anywhere, which is
  // the shape extractors return and used to be unmeasurable.
  const media =
      'https://devstreaming-cdn.apple.com/videos/streaming/examples/'
      'img_bipbop_adv_example_fmp4/v5/prog_index.m3u8';
  // A progressive file that honours Range, so the 1-byte probe can read the
  // real total out of Content-Range.
  const progressive =
      'https://download.blender.org/durian/trailer/sintel_trailer-480p.mp4';
  const progressiveBytes = 4372373;

  test('master playlist resolves RELATIVE variants and yields a size', () async {
    final size = await StreamSizeProbe.probe(master);
    expect(size, isNotNull, reason: 'master must produce a size');
    expect(size!, greaterThan(1024 * 1024), reason: 'must be plausible bytes');
  });

  test('media playlist with no BANDWIDTH is measured from real segments', () async {
    // This is the shape every extractor returns: a per-quality media playlist
    // with no bitrate published. Reading bitrate alone left these rows at "—".
    final size = await StreamSizeProbe.probe(media);
    expect(size, isNotNull, reason: 'media playlist must produce a size');
    expect(size!, greaterThan(0));
  });

  test('a master and its lowest variant agree within 2x', () async {
    // The master path derives the first (lowest) variant; the media path
    // measures segments. They describe the same content, so a gross mismatch
    // means one of the two derivations drifted.
    final masterSize = await StreamSizeProbe.probe(master);
    final mediaSize = await StreamSizeProbe.probe(media);
    if (masterSize == null || mediaSize == null) return;
    final ratio = masterSize / mediaSize;
    expect(ratio, greaterThan(0.5));
    expect(ratio, lessThan(2.0));
  });

  test('progressive file yields its exact content length', () async {
    final size = await StreamSizeProbe.probe(progressive);
    expect(size, isNotNull);
    expect(size, progressiveBytes, reason: 'a progressive probe is exact');
    expect(StreamSizeProbe.isHls(progressive), isFalse);
  });

  test('formatting marks estimates and hides unknowns', () {
    expect(StreamSizeProbe.format(0, estimated: false), '');
    expect(StreamSizeProbe.format(null, estimated: false), '');
    expect(StreamSizeProbe.format(5 * 1024 * 1024, estimated: false), '5.0 MB');
    expect(
      StreamSizeProbe.format(5 * 1024 * 1024, estimated: true),
      '~5.0 MB',
      reason: 'HLS sizes are estimates and must be labelled as such',
    );
  });
}
