/// The AIS window's header, and the view state behind it.
///
/// The header is the only thing telling the operator what range they are
/// actually looking at. Once the window can be widened past the recording, a
/// header that still quotes the recording's own span is not a cosmetic bug — it
/// asserts that traffic from an hour either side was present during a five
/// second clip.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ident_mobile/src/ais_map_geometry.dart';
import 'package:ident_mobile/src/models.dart';
import 'package:ident_mobile/src/providers.dart';
import 'package:ident_mobile/src/ui/ais_page.dart';

TrackPoint at(DateTime t) =>
    TrackPoint(lat: 48, lng: -123, t: t.millisecondsSinceEpoch);

Vessel vessel(int mmsi, List<TrackPoint> track) =>
    Vessel(mmsi: mmsi, track: track);

void main() {
  final start = DateTime.utc(2026, 7, 30, 14);
  final end = DateTime.utc(2026, 7, 30, 14, 0, 5);

  group('aisSpanLabel', () {
    test('falls back to the recording when nothing came back', () {
      expect(aisSpanLabel(null, start, end), contains('14:00:00'));
      expect(aisSpanLabel(const [], start, end), contains('14:00:00'));
    });

    test('always carries the date, including the year', () {
      // These screens are used on archive material as often as on today's, so a
      // bare time invites the reader to assume it means now.
      expect(aisSpanLabel(null, start, end), contains('30 Jul 2026'));
      expect(
        aisSpanLabel([vessel(1, [at(start)])], start, end),
        contains('30 Jul 2026'),
      );
    });

    test('a span crossing midnight dates both ends', () {
      final label = aisSpanLabel(
        [
          vessel(1, [at(DateTime.utc(2026, 7, 30, 23, 50))]),
          vessel(2, [at(DateTime.utc(2026, 7, 31, 0, 10))]),
        ],
        start,
        end,
      );
      expect(label, contains('30 Jul 2026 23:50'));
      expect(label, contains('31 Jul 2026 00:10'));
    });

    test('quotes the span of the fixes actually plotted', () {
      // The widened range loaded traffic from either side; saying "14:00:00 –
      // 14:00:05" here would be a straight lie about what is on screen.
      final label = aisSpanLabel(
        [
          vessel(1, [at(DateTime.utc(2026, 7, 30, 13, 12))]),
          vessel(2, [at(DateTime.utc(2026, 7, 30, 14, 48))]),
        ],
        start,
        end,
      );
      expect(label, contains('13:12:00'));
      expect(label, contains('14:48:00'));
    });

    test('adds the date once the range is too wide for a time alone', () {
      final label = aisSpanLabel(
        [
          vessel(1, [at(DateTime.utc(2026, 7, 28, 9))]),
          vessel(2, [at(DateTime.utc(2026, 7, 30, 9))]),
        ],
        start,
        end,
      );
      expect(label, contains('28 Jul'));
      expect(label, contains('30 Jul'));
    });
  });

  group('aisCountLabel', () {
    test('distinguishes loading from empty', () {
      expect(aisCountLabel(null, AisHistory.recording), contains('Loading'));
      expect(
        aisCountLabel(const [], AisHistory.recording),
        'No vessels logged in this range',
      );
    });

    test('an empty answer says which question it is answering', () {
      expect(
        aisCountLabel(const [], AisHistory.all),
        'No AIS logged for this sensor',
      );
      expect(
        aisCountLabel(const [], AisHistory.live),
        'Nothing reporting in the last hour',
      );
    });

    test('counts vessels and how many of them moved', () {
      final label = aisCountLabel(
        [
          vessel(1, [at(start), at(end)]),
          vessel(2, [at(start)]),
        ],
        AisHistory.recording,
      );
      expect(label, '2 vessels · 1 moving');
    });

    test('says so when it is drawing only some of them', () {
      // Silence here would read as "this is everything".
      final many = [
        for (var i = 0; i < maxDrawnVessels + 5; i++) vessel(i, [at(start)]),
      ];
      expect(
        aisCountLabel(many, AisHistory.recording),
        contains('drawing the $maxDrawnVessels nearest'),
      );
    });
  });

  group('AisView', () {
    test('hiding and isolating are different answers', () {
      const view = AisView(hiddenMmsi: {1});
      expect(view.visible(1), isFalse);
      expect(view.visible(2), isTrue);

      const isolated = AisView(isolatedMmsi: 5, hiddenMmsi: {1});
      expect(isolated.visible(5), isTrue);
      expect(isolated.visible(1), isFalse);
      expect(isolated.visible(2), isFalse);
    });

    test('pruning drops vessels the new range no longer contains', () {
      // Without this, widening the range leaves an invisible highlight and a
      // vessel list row pointing at nothing.
      const view = AisView(
        selectedMmsi: 1,
        isolatedMmsi: 2,
        hiddenMmsi: {3, 4},
      );
      final pruned = view.prunedTo({4});
      expect(pruned.selectedMmsi, isNull);
      expect(pruned.isolatedMmsi, isNull);
      expect(pruned.hiddenMmsi, {4});
    });

    test('pruning keeps the history range, which is not about vessels', () {
      const view = AisView(history: AisHistory.all, historyChosen: true);
      final pruned = view.prunedTo(const {});
      expect(pruned.history, AisHistory.all);
      expect(pruned.historyChosen, isTrue);
    });
  });

  group('AisViewNotifier', () {
    test('selecting null deselects — a tap on open water', () {
      final n = AisViewNotifier()..select(9);
      expect(n.state.selectedMmsi, 9);
      n.select(null);
      expect(n.state.selectedMmsi, isNull);
    });

    test('toggling visibility is its own inverse', () {
      final n = AisViewNotifier()..toggleVisible(3);
      expect(n.state.visible(3), isFalse);
      n.toggleVisible(3);
      expect(n.state.visible(3), isTrue);
    });

    test('isolating clears the hidden set, so the two cannot conflict', () {
      final n = AisViewNotifier()
        ..toggleVisible(1)
        ..isolate(2);
      expect(n.state.hiddenMmsi, isEmpty);
      expect(n.state.visible(2), isTrue);
      expect(n.state.visible(1), isFalse);

      n.isolate(null);
      expect(n.state.visible(1), isTrue);
    });

    test('showAll undoes both hiding and isolation', () {
      final n = AisViewNotifier()
        ..toggleVisible(1)
        ..isolate(2)
        ..showAll();
      expect(n.state.visible(1), isTrue);
      expect(n.state.isolatedMmsi, isNull);
    });

    test('auto-widening does not count as the operator choosing', () {
      // If it did, the map would stop widening for the next short recording
      // even though nobody ever picked a range.
      final n = AisViewNotifier()
        ..setHistory(AisHistory.aroundRecording, byUser: false);
      expect(n.state.history, AisHistory.aroundRecording);
      expect(n.state.historyChosen, isFalse);

      n.setHistory(AisHistory.all);
      expect(n.state.historyChosen, isTrue);
    });
  });
}
