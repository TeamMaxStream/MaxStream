import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

class AppNetworkImage extends StatelessWidget {
  final String url;
  final double? width;
  final double? height;
  final BoxFit fit;
  final Widget? errorWidget;

  const AppNetworkImage({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.errorWidget,
  });

  @override
  Widget build(BuildContext context) {
    if (url.isEmpty) {
      return errorWidget ?? _defaultError();
    }

    final dpr = MediaQuery.devicePixelRatioOf(context);

    return CachedNetworkImage(
      imageUrl: url,
      width: width,
      height: height,
      fit: fit,
      memCacheWidth: _safeCacheSize(width, dpr),
      memCacheHeight: _safeCacheSize(height, dpr),
      fadeInDuration: const Duration(milliseconds: 200),
      // Consume load failures (e.g. a TMDB poster/backdrop dropped mid-stream)
      // here so they never reach FlutterError / Crashlytics as a fatal crash.
      // The errorWidget below still renders the fallback UI.
      errorListener: (Object error) {},
      placeholder: (context, _) =>
          Container(width: width, height: height, color: Colors.grey[850]),
      errorWidget: (context, url, error) => errorWidget ?? _defaultError(),
    );
  }

  /// Safely derives the in-memory cache size (pixels) for CachedNetworkImage.
  /// Returns null (no caching) when the size or device pixel ratio is null or
  /// non-finite (e.g. a parent passing double.infinity to "fill" width), since
  /// Infinity/NaN.toInt() throws "Unsupported operation".
  int? _safeCacheSize(double? value, double dpr) {
    if (value == null || !value.isFinite || !dpr.isFinite) return null;
    final scaled = value * dpr;
    if (!scaled.isFinite) return null;
    return scaled.toInt();
  }

  Widget _defaultError() {
    return Container(
      width: width,
      height: height,
      color: Colors.grey[850],
      child: const Icon(Icons.movie, color: Colors.grey, size: 40),
    );
  }
}
