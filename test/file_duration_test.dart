/// Per-file duration estimation.
///
/// Folders are not uniform. repmus25 holds 6400 recordings of 5 s alongside 8
/// of 5 min, and neither the file listing nor the folder metadata reports a
/// per-file duration. Getting this wrong doesn't just mislabel the header — it
/// maps detection overlays against the wrong time axis, so a detection in a
/// short file becomes sub-pixel. The real numbers from that folder are used
/// below.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ident_mobile/src/file_duration.dart';
import 'package:ident_mobile/src/models.dart';

StreamFile f(String name, int size) =>
    StreamFile(name: name, sizeBytes: size, modified: 0);

// Observed in repmus25: 96 kHz mono 16-bit.
const shortSize = 960102; // 5 s
const longSize = 57688422; // ~5 min

void main() {
  group('modalSizeBytes', () {
    test('picks the size the folder is dominated by, not the extremes', () {
      final files = [
        for (var i = 0; i < 20; i++) f('short$i.wav', shortSize),
        f('long0.wav', longSize),
        f('long1.wav', longSize),
      ];
      expect(modalSizeBytes(files), shortSize);
    });

    test('ignores zero-size entries', () {
      expect(modalSizeBytes([f('a.wav', 0), f('b.wav', 0), f('c.wav', 500)]), 500);
    });

    test('returns null when there is nothing usable', () {
      expect(modalSizeBytes([]), isNull);
      expect(modalSizeBytes([f('a.wav', 0)]), isNull);
    });

    test('breaks ties deterministically rather than by map order', () {
      final a = modalSizeBytes([f('a', 100), f('b', 200)]);
      final b = modalSizeBytes([f('b', 200), f('a', 100)]);
      expect(a, b);
    });
  });

  group('estimateDurationMs', () {
    test('scales a long recording up from the modal short one', () {
      // The exact repmus25 case: folder reports 5 s, this file is 5 min.
      final ms = estimateDurationMs(
        f('long.wav', longSize),
        modalSize: shortSize,
        folderDurationMs: 5000,
      )!;
      // ~300 s. Proportion carries the WAV header along, hence the slight
      // overshoot — irrelevant at this scale, and far better than 5 s.
      expect(ms / 1000, closeTo(300.4, 0.5));
    });

    test('leaves a modal-sized recording at the folder duration', () {
      final ms = estimateDurationMs(
        f('short.wav', shortSize),
        modalSize: shortSize,
        folderDurationMs: 5000,
      );
      expect(ms, 5000);
    });

    test('works the other way too — a folder whose nominal file is the long one', () {
      final ms = estimateDurationMs(
        f('short.wav', shortSize),
        modalSize: longSize,
        folderDurationMs: 300000,
      )!;
      expect(ms / 1000, closeTo(4.99, 0.1));
    });

    test('falls back to the folder duration when size is unusable', () {
      expect(
        estimateDurationMs(f('a.wav', 0), modalSize: shortSize, folderDurationMs: 5000),
        5000,
      );
      expect(
        estimateDurationMs(f('a.wav', 100), modalSize: 0, folderDurationMs: 5000),
        5000,
      );
    });

    test('gives up rather than guessing when the folder duration is unknown', () {
      expect(
        estimateDurationMs(f('a.wav', 100), modalSize: 100, folderDurationMs: null),
        isNull,
      );
      expect(
        estimateDurationMs(f('a.wav', 100), modalSize: 100, folderDurationMs: 0),
        isNull,
      );
    });
  });

  group('estimateDurations', () {
    test('maps a mixed folder to per-file durations', () {
      final files = [
        for (var i = 0; i < 10; i++) f('short$i.wav', shortSize),
        f('long.wav', longSize),
      ];
      final durations = estimateDurations(files, folderDurationMs: 5000);

      expect(durations['short0.wav'], 5000);
      expect(durations['long.wav']! / 1000, closeTo(300.4, 0.5));
      // Every file is covered, so the viewer never falls back mid-scroll.
      expect(durations.length, files.length);
    });

    test('returns empty rather than nulls when the folder duration is unknown', () {
      final durations = estimateDurations(
        [f('a.wav', shortSize)],
        folderDurationMs: null,
      );
      expect(durations, isEmpty);
    });
  });
}
