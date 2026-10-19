import 'package:flutter_test/flutter_test.dart';
import 'package:maxstream/services/stream_size_probe.dart';

/// The VixSrc shape: a playlist served from a URL that gives nothing away —
/// "/playlist/<id>?token=…&expires=…&lang=en", no `.m3u8` anywhere, and the
/// extractor reports no `qualities` at all.
///
/// Deciding by file extension sent that URL down the progressive path, where a
/// 1-byte ranged GET returned the *playlist's* own length — a few KB shown as
/// the size of the whole film.
///
/// Network access is stubbed rather than served locally: StreamSecurity
/// correctly refuses loopback hosts, and weakening that to make a test pass
/// would be the wrong trade.
void main() {
  // 800 kbit/s for 30s is ~3 MB — unmistakably not a playlist's byte count.
  const master =
      '#EXTM3U\n'
      '#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=1280x720\n'
      '720/index.m3u8\n';
  const media =
      '#EXTM3U\n#EXT-X-TARGETDURATION:10\n'
      '#EXTINF:10.0,\nseg0.ts\n#EXTINF:10.0,\nseg1.ts\n#EXTINF:10.0,\nseg2.ts\n';
  const dash =
      '<MPD mediaPresentationDuration="PT1H30M0S">'
      '<Representation height="720" bandwidth="2500000"/>'
      '</MPD>';

  setUp(() {
    StreamSizeProbe.clear();
    StreamSizeProbe.debugFetchTextOverride = (url, _) async {
      if (url.contains('720/index') || url.endsWith('/media')) return media;
      if (url.contains('/playlist/')) return master;
      // The first bytes of an MP4, decoded the way the classifier decodes them.
      if (url.contains('/v/')) return '\x00\x00\x00\x18ftypisom';
      return null;
    };
    StreamSizeProbe.debugContentLengthOverride = (url, _) async =>
        url.contains('playlist') ? 812 : 4 * 1024 * 1024;
  });

  tearDown(() {
    StreamSizeProbe.debugFetchTextOverride = null;
    StreamSizeProbe.debugContentLengthOverride = null;
  });

  test('an extension-less playlist is measured as a video, not as its own KB',
      () async {
    const url = 'https://vixsrc.to/playlist/abc123?token=t&expires=1&lang=en';
    expect(
      StreamSizeProbe.isHls(url),
      isFalse,
      reason: 'this is the whole problem: the URL gives nothing away',
    );
    expect(classifyStreamBody(master), StreamSizeKind.hls);

    final result = await StreamSizeProbe.probeSize(url);

    expect(result.bytes, isNotNull);
    expect(result.bytes, greaterThan(1024 * 1024));
    expect(
      result.bytes,
      isNot(812),
      reason: '812 is the playlist length — never the size of the film',
    );
    expect(result.estimated, isTrue, reason: 'a playlist size is an estimate');
  });

  test('a DASH manifest is measured from its duration and bandwidth', () async {
    StreamSizeProbe.debugFetchTextOverride = (url, _) async => dash;
    final result = await StreamSizeProbe.probeSize(
      'https://example.tv/stream/manifest',
    );
    expect(classifyStreamBody(dash), StreamSizeKind.dash);
    // 2.5 Mbit/s × 5400s ÷ 8
    expect(result.bytes, (2500000 * 5400) ~/ 8);
    expect(result.estimated, isFalse);
  });

  test('an extension-less MP4 still reports its exact size', () async {
    final result = await StreamSizeProbe.probeSize('https://example.tv/v/1');
    expect(result.bytes, 4 * 1024 * 1024);
    expect(result.estimated, isFalse);
  });

  test('an HTML error page reports no size rather than a bogus one', () async {
    StreamSizeProbe.debugFetchTextOverride = (url, _) async =>
        '<!DOCTYPE html><html><body>403 Forbidden</body></html>';
    final result = await StreamSizeProbe.probeSize('https://example.tv/v/2');
    expect(result.bytes, isNull);
    expect(
      result.bytes,
      isNot(812),
      reason: 'a manifest must never be reported as the video',
    );
  });

  test('classification reads the body, not the URL', () {
    expect(classifyStreamBody('#EXTM3U\n#EXT-X-VERSION:3'), StreamSizeKind.hls);
    expect(classifyStreamBody('  \n#EXTM3U'), StreamSizeKind.hls);
    expect(classifyStreamBody('<MPD/>'), StreamSizeKind.dash);
    expect(
      classifyStreamBody('\u0000\u0000\u0000\u0018ftypisom'),
      StreamSizeKind.media,
    );
    expect(classifyStreamBody('<html>'), StreamSizeKind.unknown);
    expect(classifyStreamBody(''), StreamSizeKind.unknown);
  });
}
