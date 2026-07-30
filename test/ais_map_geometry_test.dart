/// The AIS map's arithmetic.
///
/// Every rule here fails silently when it is wrong: a reversed age gradient
/// still draws a pretty track, a decimation that drops the newest fix still
/// draws a plausible one, and a hit test that misses by a few pixels just feels
/// fiddly. So they are checked directly rather than by looking at a map.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ident_mobile/src/ais_map_geometry.dart';
import 'package:ident_mobile/src/models.dart';
import 'package:latlong2/latlong.dart';

TrackPoint p(double lat, double lng, {int t = 0, double? sog, double? cog}) =>
    TrackPoint(lat: lat, lng: lng, t: t, sog: sog, cog: cog);

Vessel vessel(int mmsi, List<TrackPoint> track, {String? name}) =>
    Vessel(mmsi: mmsi, track: track, name: name);

/// A projection that is easy to reason about: 100 px per degree, y down.
Offset fakeProject(LatLng ll) =>
    Offset(ll.longitude * 100, -ll.latitude * 100);

void main() {
  group('decimateFixes', () {
    List<TrackPoint> run(int n) =>
        [for (var i = 0; i < n; i++) p(i.toDouble(), 0, t: i)];

    test('leaves a track that is already short enough alone', () {
      final points = run(10);
      expect(identical(decimateFixes(points, cap: 60), points), isTrue);
      expect(decimateFixes(run(60), cap: 60), hasLength(60));
    });

    test('samples down to the cap', () {
      expect(decimateFixes(run(500), cap: 60), hasLength(60));
      expect(decimateFixes(run(61), cap: 60), hasLength(60));
    });

    test('always keeps the first and the newest fix', () {
      // The newest fix is where the vessel actually is; losing it to rounding
      // puts the course arrow minutes behind the truth.
      final out = decimateFixes(run(500), cap: 60);
      expect(out.first.t, 0);
      expect(out.last.t, 499);
    });

    test('keeps the fixes in time order', () {
      final out = decimateFixes(run(500), cap: 37);
      for (var i = 1; i < out.length; i++) {
        expect(out[i].t, greaterThan(out[i - 1].t));
      }
    });

    test('degenerate caps do not throw', () {
      expect(decimateFixes(run(10), cap: 1), hasLength(1));
      expect(decimateFixes(run(10), cap: 1).single.t, 9);
      expect(decimateFixes(run(10), cap: 2).map((e) => e.t), [0, 9]);
      expect(decimateFixes(const [], cap: 60), isEmpty);
      expect(decimateFixes(run(3), cap: 0), isEmpty);
    });
  });

  group('trackAgeColour', () {
    test('runs from the oldest colour to the newest', () {
      expect(trackAgeColour(0), gradFrom);
      expect(trackAgeColour(1), gradTo);
    });

    test('clamps out-of-range fractions', () {
      expect(trackAgeColour(-1), gradFrom);
      expect(trackAgeColour(2), gradTo);
    });

    test('quantises to at most gradientSteps colours', () {
      final seen = {
        for (var i = 0; i <= 200; i++) trackAgeColour(i / 200),
      };
      expect(seen.length, lessThanOrEqualTo(gradientSteps));
    });

    test('is monotone, so batching cannot reorder the ramp', () {
      var lastGreen = -1.0;
      for (var i = 0; i <= 100; i++) {
        final g = trackAgeColour(i / 100).g;
        expect(g, greaterThanOrEqualTo(lastGreen));
        lastGreen = g;
      }
    });
  });

  group('segmentColours', () {
    test('gives one colour per segment', () {
      expect(segmentColours(5), hasLength(4));
      expect(segmentColours(1), isEmpty);
      expect(segmentColours(0), isEmpty);
    });

    test('a two-point track is drawn entirely in the newest colour', () {
      // The web map's rule, and the easy one to get backwards: with a single
      // segment there is no age to show, and red would claim the vessel was
      // only ever there long ago.
      expect(segmentColours(2), [gradTo]);
    });

    test('a three-point track runs oldest to newest', () {
      expect(segmentColours(3), [gradFrom, gradTo]);
    });

    test('longer tracks start old and end new', () {
      final colours = segmentColours(40);
      expect(colours.first, gradFrom);
      expect(colours.last, gradTo);
    });
  });

  group('paletteIndicesFor', () {
    test('assigns by first appearance and is stable across calls', () {
      final vessels = [
        vessel(3, [p(0, 0)]),
        vessel(1, [p(0, 0)]),
        vessel(3, [p(1, 1)]),
      ];
      expect(paletteIndicesFor(vessels), {3: 0, 1: 1});
      expect(paletteIndicesFor(vessels), paletteIndicesFor(vessels));
    });

    test('the first eight vessels are all different colours', () {
      final vessels = [for (var i = 0; i < 8; i++) vessel(i, [p(0, 0)])];
      final indices = paletteIndicesFor(vessels);
      final colours = {for (final v in vessels) vesselColour(indices[v.mmsi]!)};
      expect(colours, hasLength(8));
    });

    test('wraps past the end of the palette', () {
      expect(vesselColour(8), vesselPalette.first);
      expect(vesselColour(-1), vesselPalette[1]);
    });
  });

  group('capVessels', () {
    test('leaves a small list alone', () {
      final vessels = [for (var i = 0; i < 5; i++) vessel(i, [p(0, 0)])];
      expect(identical(capVessels(vessels, null, cap: 40), vessels), isTrue);
    });

    test('keeps the vessels nearest the sensor', () {
      const sensor = LatLng(48.0, -123.0);
      final far = vessel(1, [p(49.0, -123.0)]); // ~111 km
      final near = vessel(2, [p(48.01, -123.0)]); // ~1 km
      final mid = vessel(3, [p(48.1, -123.0)]); // ~11 km
      final kept = capVessels([far, near, mid], sensor, cap: 2);
      expect(kept.map((v) => v.mmsi), [2, 3]);
    });

    test('without a sensor, the most recently seen win', () {
      final old = vessel(1, [p(0, 0, t: 100)]);
      final fresh = vessel(2, [p(0, 0, t: 900)]);
      expect(capVessels([old, fresh], null, cap: 1).single.mmsi, 2);
    });
  });

  group('range rings', () {
    const sensor = LatLng(48.4284, -123.3656);

    test('a 5 km ring is about 0.09° tall', () {
      final b = ringBounds(sensor, 5000);
      expect(b.north - b.south, closeTo(0.09, 0.005));
      expect(b.north, greaterThan(sensor.latitude));
      expect(b.south, lessThan(sensor.latitude));
    });

    test('is wider in degrees than it is tall, away from the equator', () {
      // Guards against the web map's degrees-of-latitude shortcut, which would
      // make the ring square in degrees and so half as wide as it should be.
      final b = ringBounds(sensor, 5000);
      expect(b.east - b.west, greaterThan((b.north - b.south) * 1.3));
    });

    test('the label sits due north, on the ring', () {
      final label = ringLabelPoint(sensor, 5000);
      expect(label.longitude, closeTo(sensor.longitude, 1e-6));
      expect(
        distanceKm(sensor, label),
        closeTo(5, 0.05),
      );
    });
  });

  group('contentBounds', () {
    test('returns null when there is nothing to frame', () {
      // LatLngBounds.fromPoints asserts on an empty list, so this must not
      // simply be passed through.
      expect(contentBounds(), isNull);
      expect(contentBounds(fixes: const []), isNull);
    });

    test('frames the sensor ring and every fix', () {
      const sensor = LatLng(48.0, -123.0);
      final b = contentBounds(
        sensor: sensor,
        fixes: [const LatLng(48.5, -122.5)],
        sensorRingMetres: 5000,
      )!;
      expect(b.north, closeTo(48.5, 1e-6));
      expect(b.east, closeTo(-122.5, 1e-6));
      expect(b.south, lessThan(48.0));
      expect(b.west, lessThan(-123.0));
    });

    test('works with fixes but no sensor', () {
      final b = contentBounds(
        fixes: const [LatLng(1, 2), LatLng(3, 4)],
      )!;
      expect(b.north, 3);
      expect(b.west, 2);
    });
  });

  group('vesselsNearSensor', () {
    const sensor = LatLng(48.0, -123.0);

    test('flags vessels that came inside the radius', () {
      final inside = vessel(1, [p(48.04, -123.0)]); // ~4.4 km
      final outside = vessel(2, [p(48.06, -123.0)]); // ~6.7 km
      expect(vesselsNearSensor([inside, outside], sensor), {1});
    });

    test('uses the closest point of the whole track', () {
      final passing = vessel(3, [p(49.0, -123.0), p(48.01, -123.0)]);
      expect(vesselsNearSensor([passing], sensor), {3});
    });

    test('no sensor means nothing is near', () {
      expect(vesselsNearSensor([vessel(1, [p(48, -123)])], null), isEmpty);
    });
  });

  group('hitTestAis', () {
    final track = VesselTrack(
      vessel: vessel(7, [p(0, 0), p(0, 1)]),
      fixes: [p(0, 0, t: 1), p(0, 1, t: 2)],
      colour: vesselPalette.first,
    );

    test('finds the fix under the finger', () {
      final hit = hitTestAis(
        tap: const Offset(2, 0),
        project: fakeProject,
        tracks: [track],
      );
      expect(hit, (mmsi: 7, fixIndex: 0));
    });

    test('a fix beats the line it sits on', () {
      // Both are within slop at the endpoint; the dot is the thing carrying
      // data worth opening.
      final hit = hitTestAis(
        tap: const Offset(100, 0),
        project: fakeProject,
        tracks: [track],
      );
      expect(hit!.fixIndex, 1);
    });

    test('falls back to the track line between fixes', () {
      final hit = hitTestAis(
        tap: const Offset(50, 4),
        project: fakeProject,
        tracks: [track],
      );
      expect(hit, (mmsi: 7, fixIndex: null));
    });

    test('open water is a miss, which is what deselects', () {
      expect(
        hitTestAis(
          tap: const Offset(50, 400),
          project: fakeProject,
          tracks: [track],
        ),
        isNull,
      );
    });

    test('the nearest of two overlapping fixes wins', () {
      final other = VesselTrack(
        vessel: vessel(9, [p(0, 0.1)]),
        fixes: [p(0, 0.1)],
        colour: vesselPalette[1],
      );
      final hit = hitTestAis(
        tap: const Offset(9, 0),
        project: fakeProject,
        tracks: [track, other],
      );
      expect(hit!.mmsi, 9);
    });

    test('an empty chart is a miss', () {
      expect(
        hitTestAis(tap: Offset.zero, project: fakeProject, tracks: const []),
        isNull,
      );
    });
  });

  group('aisQueryFor', () {
    final start = DateTime.utc(2026, 7, 30, 23, 55);
    final end = DateTime.utc(2026, 7, 30, 23, 55, 5);

    test('the recording range asks for exactly the recording', () {
      final q = aisQueryFor(AisHistory.recording, start, end);
      expect(q.from, start);
      expect(q.to, end);
      expect(q.all, isFalse);
    });

    test('the wide range pads an hour either side, across midnight', () {
      final q = aisQueryFor(AisHistory.aroundRecording, start, end);
      expect(q.from, DateTime.utc(2026, 7, 30, 22, 55));
      expect(q.to, DateTime.utc(2026, 7, 31, 0, 55, 5));
      expect(q.all, isFalse);
    });

    test('all mode drops the window rather than sending one to be ignored', () {
      final q = aisQueryFor(AisHistory.all, start, end);
      expect(q.from, isNull);
      expect(q.to, isNull);
      expect(q.all, isTrue);
    });

    test('live ignores the recording and asks for the last hour', () {
      final q = aisQueryFor(
        AisHistory.live,
        start,
        end,
        now: DateTime.utc(2026, 8, 1, 9, 30, 41),
      );
      expect(q.to, DateTime.utc(2026, 8, 1, 9, 30));
      expect(q.from, DateTime.utc(2026, 8, 1, 8, 30));
      expect(q.all, isFalse);
    });

    test('live windows are stable within a minute', () {
      // The query is the provider's cache key, so a window that moved with the
      // clock would refetch on every rebuild rather than once a minute.
      final a = aisQueryFor(AisHistory.live, start, end,
          now: DateTime.utc(2026, 8, 1, 9, 30, 1));
      final b = aisQueryFor(AisHistory.live, start, end,
          now: DateTime.utc(2026, 8, 1, 9, 30, 59));
      expect(a, b);

      final next = aisQueryFor(AisHistory.live, start, end,
          now: DateTime.utc(2026, 8, 1, 9, 31, 0));
      expect(next, isNot(b));
    });
  });

  group('floorToMinute', () {
    test('discards seconds and below', () {
      expect(
        floorToMinute(DateTime.utc(2026, 8, 1, 9, 30, 41, 512)),
        DateTime.utc(2026, 8, 1, 9, 30),
      );
    });

    test('a whole minute is already floored', () {
      final t = DateTime.utc(2026, 8, 1, 9, 30);
      expect(floorToMinute(t), t);
    });
  });

  group('shouldAutoWiden', () {
    test('a recording shorter than an AIS report cannot hold a track', () {
      expect(shouldAutoWiden(const Duration(seconds: 5)), isTrue);
      expect(shouldAutoWiden(const Duration(seconds: 119)), isTrue);
    });

    test('a long recording is left as it is', () {
      expect(shouldAutoWiden(const Duration(minutes: 2)), isFalse);
      expect(shouldAutoWiden(const Duration(minutes: 5)), isFalse);
    });
  });

  group('prepareTracks', () {
    test('caps, colours and decimates in one pass', () {
      final vessels = [
        vessel(1, [for (var i = 0; i < 200; i++) p(48.0 + i / 1000, -123, t: i)]),
        vessel(2, [p(48.0, -123)]),
      ];
      final tracks = prepareTracks(vessels, const LatLng(48, -123), fixCap: 10);
      expect(tracks, hasLength(2));
      expect(tracks.first.fixes, hasLength(10));
      expect(tracks.first.colour, vesselPalette[0]);
      expect(tracks[1].colour, vesselPalette[1]);
    });

    test('drops vessels with no position at all', () {
      expect(prepareTracks([vessel(1, const [])], null), isEmpty);
    });
  });
}
