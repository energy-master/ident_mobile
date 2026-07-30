/// The live feed re-reads its folder every minute, so `nextIndexAfterRefresh`
/// runs constantly. Its failure mode is quiet: an off-by-one does not throw, it
/// just drifts the feed one recording per refresh until the user is reading
/// something they never chose.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ident_mobile/src/ui/file_viewer.dart';

void main() {
  // Newest first, as the API returns them.
  const before = ['14:00.wav', '13:30.wav', '13:00.wav'];
  const after = ['14:30.wav', '14:00.wav', '13:30.wav', '13:00.wav'];

  int next(List<String> old, List<String> now, int i, {bool pin = false}) =>
      nextIndexAfterRefresh(
        oldNames: old,
        newNames: now,
        index: i,
        pinToNewest: pin,
      );

  group('nextIndexAfterRefresh', () {
    test('a pinned viewer on the newest follows the new arrival', () {
      expect(next(before, after, 0, pin: true), 0);
    });

    test('a pinned viewer that has scrubbed back keeps its recording', () {
      // The exact thing pinning must not do: the user is reading 13:30, which
      // has shifted from index 1 to index 2. Following the arrival here would
      // yank them forward mid-read.
      expect(next(before, after, 1, pin: true), 2);
      expect(after[next(before, after, 1, pin: true)], '13:30.wav');
    });

    test('an unpinned viewer on the newest still holds its recording', () {
      // All / Favourites: a background refresh must never move the user, even
      // when they happen to be sitting on the newest file.
      expect(next(before, after, 0), 1);
      expect(after[next(before, after, 0)], '14:00.wav');
    });

    test('position survives files being appended to the old end', () {
      const older = [...before, '12:30.wav'];
      expect(next(before, older, 2), 2);
      expect(older[next(before, older, 2)], '13:00.wav');
    });

    test('a recording that has left the list falls back to the same slot', () {
      // A filter changed underneath: 13:30 is gone. There is nothing to hold, so
      // the nearest position is the honest answer.
      const filtered = ['14:00.wav', '13:00.wav'];
      expect(next(before, filtered, 1), 1);
    });

    test('a shorter list clamps rather than running off the end', () {
      const filtered = ['14:00.wav'];
      expect(next(before, filtered, 2), 0);
    });

    test('an empty new list is index 0, not a range error', () {
      expect(next(before, const [], 2), 0);
      expect(next(before, const [], 2, pin: true), 0);
    });

    test('an empty old list clamps the incoming index', () {
      expect(next(const [], after, 0), 0);
      expect(next(const [], after, 99), 3);
    });

    test('an unchanged list leaves the user exactly where they were', () {
      for (var i = 0; i < before.length; i++) {
        expect(next(before, before, i), i);
        expect(next(before, before, i, pin: true), i);
      }
    });
  });
}
