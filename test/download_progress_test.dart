import 'package:flutter_test/flutter_test.dart';
import 'package:maxstream/services/downloads_settings_service.dart';
import 'package:maxstream/services/media_download_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

ActiveMediaDownload _task({int? totalBytes, int? expectedTotalBytes}) =>
    ActiveMediaDownload(
      downloadKey: 'movie_1',
      title: 'Some Movie',
      label: 'Some Movie',
      thumbnail: '',
      progress: 0.1,
      downloadedBytes: 10 * 1024 * 1024,
      totalBytes: totalBytes,
      expectedTotalBytes: expectedTotalBytes,
      isPaused: false,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the quality setting applies without restarting the app', () async {
    SharedPreferences.setMockInitialValues({});

    await DownloadsSettingsService.refreshCache();
    expect(
      DownloadsSettingsService.maxVariantHeightPixels,
      isNull,
      reason: 'auto means no ceiling',
    );

    // Choosing a quality in Download Settings has to be visible immediately:
    // this is what "Auto" in the download sheet reads.
    await DownloadsSettingsService.setQuality('1080');
    expect(DownloadsSettingsService.maxVariantHeightPixels, 1080);

    await DownloadsSettingsService.setQuality('480');
    expect(DownloadsSettingsService.maxVariantHeightPixels, 480);

    await DownloadsSettingsService.setQuality('auto');
    expect(DownloadsSettingsService.maxVariantHeightPixels, isNull);
  });

  test('progress reads "downloaded / total" from the pre-measured size', () {
    // HLS never reports its own length, so without this the line could only
    // ever say "10.0 MB downloaded".
    expect(
      _task(expectedTotalBytes: 170 * 1024 * 1024).sizeLabel,
      '10.0 MB / 170.0 MB',
    );
  });

  test('a total the server reports itself wins over the measured one', () {
    expect(
      _task(totalBytes: 200 * 1024 * 1024, expectedTotalBytes: 170 * 1024 * 1024)
          .sizeLabel,
      '10.0 MB / 200.0 MB',
    );
  });

  test('with no total at all it still reports the bytes downloaded', () {
    expect(_task().sizeLabel, '10.0 MB downloaded');
  });
}
