import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';

/// Loading shimmer with a fast, snappy sweep and a narrow bright "mirror glint"
/// band (like light catching a mirror) instead of the soft default gradient.
///
/// Drop-in replacement for `Shimmer.fromColors` — pass the same `baseColor`,
/// `highlightColor` and `child`. The period is short so the placeholder never
/// feels sluggish, and the thin highlight stop makes the shine read as a glint.
class AppShimmer extends StatelessWidget {
  final Widget child;
  final Duration period;
  final Color baseColor;
  final Color highlightColor;

  const AppShimmer({
    super.key,
    required this.child,
    this.period = const Duration(milliseconds: 800),
    this.baseColor = const Color(0xFF2A2A2A),
    this.highlightColor = const Color(0xFF6E6E6E),
  });

  @override
  Widget build(BuildContext context) {
    // Brighten the highlight a touch toward white so the glint actually pops
    // like a mirror catching light, regardless of the caller's grey choice.
    final glint =
        Color.lerp(highlightColor, Colors.white, 0.45) ?? highlightColor;
    return Shimmer(
      period: period,
      gradient: LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        stops: const [0.0, 0.42, 0.5, 0.58, 1.0],
        colors: [baseColor, baseColor, glint, baseColor, baseColor],
        tileMode: TileMode.clamp,
      ),
      child: child,
    );
  }
}
