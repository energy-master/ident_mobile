/// Moving between the dashboard's windows.
///
/// The windows are a ring built on an unbounded page index, so "go to the
/// images window" is a step, not a destination. Getting the step wrong does not
/// throw — it animates the long way round, through every other window, which
/// reads as the app taking a scenic route to the screen you asked for.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ident_mobile/src/ui/dashboard_screen.dart';

void main() {
  // Live images, AIS, Decisions, Notifications.
  const count = 4;
  const origin = 4000; // window 0

  group('nextPageForWindow', () {
    test('staying put is not a move', () {
      expect(nextPageForWindow(origin, 0, count), origin);
    });

    test('the next window along is one page forward', () {
      expect(nextPageForWindow(origin, 1, count), origin + 1);
    });

    test('the last window is one page BACK from the first', () {
      // The point of putting Notifications last: from Live images it is one
      // backward swipe, not three forward ones.
      expect(nextPageForWindow(origin, 3, count), origin - 1);
    });

    test('the first window is one page forward from the last', () {
      expect(nextPageForWindow(origin + 3, 0, count), origin + 4);
    });

    test('the far side of the ring goes forward, consistently', () {
      // Two apart in a ring of four is a tie; it always resolves the same way
      // so the same pair does not animate left one time and right the next.
      expect(nextPageForWindow(origin, 2, count), origin + 2);
      expect(nextPageForWindow(origin + 2, 0, count), origin + 4);
    });

    test('never travels more than half the ring', () {
      for (var current = origin; current < origin + count; current++) {
        for (var window = 0; window < count; window++) {
          final step = (nextPageForWindow(current, window, count) - current).abs();
          expect(step, lessThanOrEqualTo(count ~/ 2));
        }
      }
    });

    test('always lands on the window that was asked for', () {
      for (var current = origin - 3; current < origin + 7; current++) {
        for (var window = 0; window < count; window++) {
          expect(nextPageForWindow(current, window, count) % count, window);
        }
      }
    });
  });
}
