/// Where the "tablet" vs "phone" split falls.
///
/// The dashboard's four data windows are paged on a phone (one screen at a
/// time, swipe between them) and tiled on an iPad (all four in view at once,
/// each with its own maximise button). The line between the two is a
/// short-side threshold rather than an OS check: split-screen on iPad can
/// leave this app in a phone-shaped column, and that column earns nothing from
/// a 2×2 grid of postage stamps.
library;

import 'package:flutter/widgets.dart';

/// Minimum short-side, in logical pixels, for the tiled dashboard.
///
/// 600 dp is the same figure Material uses to distinguish `handset` from
/// `tablet` — narrow enough that even a mini iPad in portrait qualifies, wide
/// enough that a large phone in landscape does not.
const double tabletShortSideThreshold = 600;

bool isTabletLayout(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  return size.shortestSide >= tabletShortSideThreshold;
}
