import 'package:flutter/material.dart';

/// Geometry of the floating bottom navigation bar.
///
/// `MaxStreamMainScreen` builds the bar as a `Positioned` overlay inside a
/// `Scaffold` with `extendBody: true`, so every tab's content runs *underneath*
/// it rather than being laid out above it. A list that pads only by the system
/// inset therefore ends with its last row — and its delete button — trapped
/// behind the bar and unreachable, even when scrolled to the end.
///
/// Anything scrollable inside a shell tab must reserve
/// [clearance] at the bottom.
class FloatingNavBar {
  FloatingNavBar._();

  /// Bar height, matching `_buildNavBar` in maxstream_main_screen.dart.
  static const double height = 52;

  /// Gap below the bar, matching the same method.
  static const double margin = 10;

  /// Space to leave free at the bottom of a scrollable inside a shell tab.
  ///
  /// Uses `viewPadding` rather than `padding`: the shell's `extendBody: true`
  /// consumes the bottom padding for its body, so `padding.bottom` reads as 0
  /// inside a tab and would under-reserve the space.
  static double clearance(BuildContext context) =>
      height + margin + MediaQuery.viewPaddingOf(context).bottom;
}
