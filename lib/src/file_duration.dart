/// Working out how long each recording actually is.
///
/// The problem: the Brahma file listing returns only name, size and mtime — no
/// duration — and the folder metadata reports a single `duration_ms` for the
/// whole stream. Folders are not uniform. `repmus25`, for instance, holds 6400
/// recordings of 5 seconds alongside 8 of 5 minutes. Treating every file as the
/// folder duration puts the wrong time span in the header and, worse, maps
/// detection overlays against the wrong scale: a 3-second detection in a
/// 5-second file drawn against a 300-second axis is sub-pixel.
///
/// The fix: recordings in a folder share an encoding, so **size is proportional
/// to duration**. Anchoring on the folder's reported duration and the size that
/// dominates the folder gives every other file's duration by simple proportion:
///
///     duration(file) = folderDuration × size(file) / modalSize
///
/// Proportion rather than arithmetic from the sample rate deliberately: it needs
/// no assumption about bit depth or header size, and it stays correct for any
/// constant-bitrate encoding. Checked against `repmus25`, where the 5-minute
/// files come out at 300.4 s against a nominal 300.
///
/// This is an estimate. The real fix is for the Brahma service to report a
/// per-file duration in `/streams/folder_files`; when it does, prefer that and
/// delete this.
library;

import 'models.dart';

/// The size that most recordings in the folder share.
///
/// The mode rather than the mean or median: a folder is normally thousands of
/// uniform chunks plus a handful of oddities, and the mode picks the uniform
/// population no matter how extreme the oddities are. Returns null for an empty
/// list, or when no size is usable.
int? modalSizeBytes(List<StreamFile> files) {
  if (files.isEmpty) return null;

  final counts = <int, int>{};
  for (final f in files) {
    if (f.sizeBytes > 0) {
      counts[f.sizeBytes] = (counts[f.sizeBytes] ?? 0) + 1;
    }
  }
  if (counts.isEmpty) return null;

  var bestSize = 0;
  var bestCount = -1;
  counts.forEach((size, count) {
    // Ties break towards the larger size, so the choice is deterministic rather
    // than dependent on map iteration order.
    if (count > bestCount || (count == bestCount && size > bestSize)) {
      bestCount = count;
      bestSize = size;
    }
  });
  return bestSize;
}

/// How long [file] runs, in milliseconds, or null when it can't be worked out.
///
/// Falls back to [folderDurationMs] when the file's own size is unusable —
/// which is at least right for the files that match the folder's nominal
/// length, and no worse than what it replaces.
int? estimateDurationMs(
  StreamFile file, {
  required int? modalSize,
  required int? folderDurationMs,
}) {
  if (folderDurationMs == null || folderDurationMs <= 0) return null;
  if (modalSize == null || modalSize <= 0) return folderDurationMs;
  if (file.sizeBytes <= 0) return folderDurationMs;

  final scaled = folderDurationMs * (file.sizeBytes / modalSize);
  if (!scaled.isFinite || scaled <= 0) return folderDurationMs;

  return scaled.round();
}

/// Per-file durations for a whole folder, keyed by filename.
///
/// Computed in one pass so callers don't recompute the mode for every file —
/// the strip and the map both need this for lists of thousands.
Map<String, int> estimateDurations(
  List<StreamFile> files, {
  required int? folderDurationMs,
}) {
  final modal = modalSizeBytes(files);
  final out = <String, int>{};
  for (final f in files) {
    final ms = estimateDurationMs(
      f,
      modalSize: modal,
      folderDurationMs: folderDurationMs,
    );
    if (ms != null) out[f.name] = ms;
  }
  return out;
}

/// How far outside every recording an instant may fall and still resolve.
const recordingSearchTolerance = Duration(minutes: 5);

/// The recording covering [instant], or the nearest one within [tolerance].
///
/// Returns **null** when nothing is close enough, and that case is real rather
/// than defensive: the AIS map can show fixes from long before the oldest
/// recording still on disk, and the honest answer to "take me to this moment" is
/// then "there is no recording of it". Jumping to whatever file happens to be
/// nearest would silently show the operator the wrong audio.
///
/// A recording's span is its start plus its estimated duration ([durations],
/// keyed by filename); a file with no estimate is treated as an instant, so it
/// can still be reached by proximity but never falsely claims to cover an hour.
StreamFile? recordingAt(
  DateTime instant,
  List<StreamFile> files,
  Map<String, int> durations, {
  Duration tolerance = recordingSearchTolerance,
}) {
  final t = instant.millisecondsSinceEpoch;

  StreamFile? nearest;
  var nearestGap = double.infinity;

  for (final f in files) {
    final start = f.startTime.millisecondsSinceEpoch;
    final end = start + (durations[f.name] ?? 0);

    if (t >= start && t <= end) return f;

    final gap = (t < start ? start - t : t - end).toDouble();
    // Strictly less-than, so a tie keeps the first file in list order rather
    // than the last — same input, same answer, every call.
    if (gap < nearestGap) {
      nearestGap = gap;
      nearest = f;
    }
  }

  return nearestGap <= tolerance.inMilliseconds ? nearest : null;
}
