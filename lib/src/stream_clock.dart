/// The application clock — the instant a stream's windows are all showing.
///
/// Every data window in a stream answers a question about a moment: which
/// recording is on screen, which vessels were out there, which detections
/// fired. Before this they each held their own idea of that moment, which meant
/// swiping between them could show three different times and nothing said so.
/// The clock is the one answer they all read.
///
/// It has two states and no third:
///
///   * **live** — follow the newest data as it arrives. This is where a stream
///     opens, and it is the only state that moves on its own.
///   * **pinned** — a specific UTC instant the operator put the app at, by
///     choosing a recording, a detection, or a position on the AIS chart.
///
/// Pinning is always something the operator did. Nothing in the app pins the
/// clock on their behalf: a background refresh that quietly took the app off
/// live would strand them in history without a word, and the whole point of the
/// unhighlighted Live button is that off-live is visible.
library;

import 'package:flutter/foundation.dart' show immutable;

import 'models.dart';

/// What moved the clock. Carried so a window can say *why* it is where it is,
/// and so re-pinning to the same instant from a different window still counts
/// as a change.
enum ClockSource {
  /// Following the newest data.
  live,

  /// A recording chosen in the images window.
  recording,

  /// A detection chosen in the decisions window.
  decision,

  /// A vessel fix chosen on the AIS chart.
  ais,
}

@immutable
class StreamClock {
  /// Following the newest data — where every stream starts.
  const StreamClock.live()
      : at = null,
        source = ClockSource.live;

  const StreamClock.pinned(DateTime this.at, this.source);

  /// The instant the app is at, in UTC, or null while following live data.
  final DateTime? at;

  final ClockSource source;

  bool get isLive => at == null;

  @override
  bool operator ==(Object other) =>
      other is StreamClock && other.at == at && other.source == source;

  @override
  int get hashCode => Object.hash(at, source);

  @override
  String toString() => isLive ? 'StreamClock.live' : 'StreamClock($at, $source)';
}

/// Which recording in [files] the clock is pointing at.
///
/// [files] is ordered newest-first, and may be a *filtered* list — the strip
/// showing only detections or only favourites is still a list the clock has to
/// land somewhere in. That is why this always returns an index rather than a
/// file: unlike [recordingAt], which may honestly answer "nothing covers this
/// moment", the viewer has to be sitting on something.
///
/// The rule is the same one [recordingAt] uses, so the clock resolves to the
/// same recording wherever it is asked:
///
///   * a recording whose span contains the instant wins outright;
///   * otherwise the one whose span comes closest to it;
///   * ties keep the newer, so the same clock always lands in the same place.
///
/// A live clock is index 0 — the newest of whatever this list holds, which in
/// the decisions filter is the newest recording that fired rather than the
/// newest recording outright.
///
/// [durations] is keyed by filename; a file with no estimate is treated as an
/// instant rather than assumed to cover anything, so a missing duration can
/// never make a recording claim a moment it did not contain.
int clockFileIndex(
  List<StreamFile> files,
  StreamClock clock,
  Map<String, int> durations,
) {
  if (files.isEmpty) return 0;

  final at = clock.at;
  if (at == null) return 0;

  final t = at.millisecondsSinceEpoch;
  var best = 0;
  var bestGap = double.infinity;

  for (var i = 0; i < files.length; i++) {
    final start = files[i].startTime.millisecondsSinceEpoch;
    final end = start + (durations[files[i].name] ?? 0);

    if (t >= start && t <= end) return i;

    final gap = (t < start ? start - t : t - end).toDouble();
    // Strictly less-than, so a tie keeps the earlier entry — the newer
    // recording, in a newest-first list.
    if (gap < bestGap) {
      bestGap = gap;
      best = i;
    }
  }

  return best;
}
