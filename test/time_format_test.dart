/// Filename timestamp parsing.
///
/// The time axis for the images page comes from recording filenames, so getting
/// this wrong silently mislabels every lane. The strict case must stay byte-for-
/// byte compatible with FILENAME_RE in the web app's js/decisions.js.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ident_mobile/src/time_format.dart';

void main() {
  group('parseFileStartTime', () {
    test('parses the strict _YYYYMMDD_HHMMSS_frac convention', () {
      final t = parseFileStartTime('_20260728_132408_500.wav');
      expect(t, isNotNull);
      expect(t!.isUtc, isTrue);
      expect(t.year, 2026);
      expect(t.month, 7);
      expect(t.day, 28);
      expect(t.hour, 13);
      expect(t.minute, 24);
      expect(t.second, 8);
      // "500" is three digits, so it means .500 s — not 500 ms read literally
      // off a different scale.
      expect(t.millisecond, 500);
    });

    test('scales fractional seconds by digit count', () {
      expect(parseFileStartTime('_20260728_132408_5.wav')!.millisecond, 500);
      expect(parseFileStartTime('_20260728_132408_05.wav')!.millisecond, 50);
      expect(parseFileStartTime('_20260728_132408_005.wav')!.millisecond, 5);
    });

    test('falls back to a timestamp embedded after a device prefix', () {
      final t = parseFileStartTime('ICLISTENHF1561_20260728_132408.wav');
      expect(t, isNotNull);
      expect(t!.hour, 13);
      expect(t.minute, 24);
    });

    test('strips a directory path before matching', () {
      final t = parseFileStartTime('/data/site-a/_20260728_132408_000.wav');
      expect(t, isNotNull);
      expect(t!.day, 28);
    });

    test('returns null when there is no timestamp', () {
      expect(parseFileStartTime('track_001.wav'), isNull);
      expect(parseFileStartTime(''), isNull);
    });

    test('rejects impossible components instead of rolling them over', () {
      // Month 19 would otherwise silently become mid-2027.
      expect(parseFileStartTime('_20261928_132408_000.wav'), isNull);
      expect(parseFileStartTime('_20260728_992408_000.wav'), isNull);
    });
  });

  group('recordingTime', () {
    test('prefers the filename over the mtime', () {
      // mtime is an hour later than the encoded start — the filename wins,
      // because mtime is when the writer finished, not when recording began.
      final t = recordingTime('_20260728_132408_000.wav', 1785419048);
      expect(t.hour, 13);
      expect(t.minute, 24);
    });

    test('falls back to the mtime when the name has no timestamp', () {
      final t = recordingTime('track_001.wav', 1785419048);
      expect(t.isUtc, isTrue);
      expect(t.millisecondsSinceEpoch, 1785419048 * 1000);
    });
  });

  group('formatAge', () {
    test('describes each magnitude in its own unit', () {
      expect(formatAge(const Duration(seconds: 20)), 'just now');
      expect(formatAge(const Duration(minutes: 5)), '5 min ago');
      expect(formatAge(const Duration(hours: 3)), '3 h ago');
      expect(formatAge(const Duration(days: 2)), '2 d ago');
    });

    test('treats a clock-skewed future timestamp as now', () {
      expect(formatAge(const Duration(minutes: -5)), 'just now');
    });
  });
}
