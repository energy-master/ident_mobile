/// Where the application clock lands in a list of recordings.
///
/// Every window in a stream resolves the same clock against the same file list
/// and has to agree about the answer. The failure mode is silent: landing one
/// recording out does not throw, it shows the operator a spectrogram from a
/// different quarter of an hour than the AIS chart beside it is plotting, and
/// both look entirely plausible.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ident_mobile/src/models.dart';
import 'package:ident_mobile/src/stream_clock.dart';

/// A recording starting at [t]. The filename carries the time, which is what
/// `StreamFile.startTime` parses.
StreamFile file(DateTime t) {
  final s = '${t.year.toString().padLeft(4, '0')}'
      '${t.month.toString().padLeft(2, '0')}'
      '${t.day.toString().padLeft(2, '0')}';
  final hms = '${t.hour.toString().padLeft(2, '0')}'
      '${t.minute.toString().padLeft(2, '0')}'
      '${t.second.toString().padLeft(2, '0')}';
  return StreamFile(name: '_${s}_${hms}_000.wav', sizeBytes: 1000, modified: 0);
}

void main() {
  // Newest first, as the API returns them: 15-minute recordings on the hour.
  final t14 = DateTime.utc(2026, 7, 30, 14);
  final t1345 = DateTime.utc(2026, 7, 30, 13, 45);
  final t1330 = DateTime.utc(2026, 7, 30, 13, 30);

  final files = [file(t14), file(t1345), file(t1330)];
  final durations = {
    for (final f in files) f.name: const Duration(minutes: 15).inMilliseconds,
  };

  int indexAt(DateTime at) =>
      clockFileIndex(files, StreamClock.pinned(at, ClockSource.ais), durations);

  group('StreamClock', () {
    test('a stream starts live, and live is not a moment', () {
      expect(const StreamClock.live().isLive, isTrue);
      expect(const StreamClock.live().at, isNull);
    });

    test('pinned is a moment, and never equal to live', () {
      final c = StreamClock.pinned(t14, ClockSource.recording);
      expect(c.isLive, isFalse);
      expect(c.at, t14);
      expect(c == const StreamClock.live(), isFalse);
    });

    test('the same moment from a different window is a different clock', () {
      // The source is part of identity so that re-choosing the same instant
      // from another window still registers as a change — otherwise a decision
      // and the AIS fix inside it would be indistinguishable, and the second
      // one would move nothing.
      expect(
        StreamClock.pinned(t14, ClockSource.decision) ==
            StreamClock.pinned(t14, ClockSource.ais),
        isFalse,
      );
      expect(
        StreamClock.pinned(t14, ClockSource.ais) ==
            StreamClock.pinned(t14, ClockSource.ais),
        isTrue,
      );
    });
  });

  group('clockFileIndex', () {
    test('a live clock is the newest of whatever list it is given', () {
      expect(clockFileIndex(files, const StreamClock.live(), durations), 0);
    });

    test('an empty list has nowhere to land, and does not throw', () {
      expect(clockFileIndex([], const StreamClock.live(), durations), 0);
      expect(
        clockFileIndex([], StreamClock.pinned(t14, ClockSource.ais), durations),
        0,
      );
    });

    test('a moment inside a recording lands on that recording', () {
      expect(indexAt(t14), 0);
      expect(indexAt(t1345.add(const Duration(minutes: 7))), 1);
      expect(indexAt(t1330.add(const Duration(minutes: 14, seconds: 59))), 2);
    });

    test('late in a recording stays there rather than jumping to the next', () {
      // The case that makes containment worth testing separately from
      // proximity: 14 minutes into 13:45 is only 1 minute from 14:00's start,
      // so a nearest-start rule lands on the recording that had not begun yet.
      expect(indexAt(t1345.add(const Duration(minutes: 14))), 1);
    });

    test('a moment in a gap takes the recording whose span is closest', () {
      final gapFiles = [file(t14), file(t1330)];
      final gapDurations = {
        for (final f in gapFiles)
          f.name: const Duration(minutes: 5).inMilliseconds,
      };
      int at(DateTime t) => clockFileIndex(
            gapFiles,
            StreamClock.pinned(t, ClockSource.ais),
            gapDurations,
          );

      // 13:35 ends the older one; 14:00 starts the newer. 13:50 is nearer 14:00.
      expect(at(DateTime.utc(2026, 7, 30, 13, 50)), 0);
      expect(at(DateTime.utc(2026, 7, 30, 13, 40)), 1);
    });

    test('a moment after everything holds the newest recording', () {
      expect(indexAt(DateTime.utc(2026, 7, 30, 23)), 0);
    });

    test('a moment before everything holds the oldest recording', () {
      // An AIS fix can easily predate the oldest file still on disk. The strip
      // has to sit somewhere, and the oldest is the only honest end to sit at.
      expect(indexAt(DateTime.utc(2026, 7, 29)), files.length - 1);
    });

    test('a file with no duration estimate covers only its own instant', () {
      // Never let a missing estimate make a recording claim a moment it did not
      // contain — that would put the wrong audio under a detection.
      expect(clockFileIndex(files, StreamClock.pinned(t14, ClockSource.ais), const {}), 0);
      expect(
        clockFileIndex(
          files,
          StreamClock.pinned(t1345.add(const Duration(minutes: 14)), ClockSource.ais),
          const {},
        ),
        // 14 minutes past 13:45 with no spans to sit inside: 14:00 is nearer.
        0,
      );
    });

    test('a filtered list still lands somewhere sensible', () {
      // The decisions and favourites filters hand this a subset. The clock does
      // not move, so the strip opens on the nearest recording it is allowed to
      // show rather than on the newest one.
      final favourites = [files[0], files[2]];
      expect(
        clockFileIndex(
          favourites,
          StreamClock.pinned(t1345.add(const Duration(minutes: 2)), ClockSource.decision),
          durations,
        ),
        1, // 13:30, whose span ends 2 minutes before — nearer than 14:00.
      );
    });

    test('ties keep the newer recording, every time', () {
      // Equidistant between 13:45's end (14:00) and 14:00's start. Same input,
      // same answer, or the strip drifts between rebuilds.
      final tie = [file(t14), file(t1345)];
      expect(
        clockFileIndex(tie, StreamClock.pinned(t14, ClockSource.ais), durations),
        0,
      );
    });
  });
}
