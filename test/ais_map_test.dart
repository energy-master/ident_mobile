/// The AIS map's layer builders.
///
/// Tested by calling them and inspecting the flutter_map objects they return,
/// with no map pumped: the tile layers issue real HTTP requests that the test
/// binding stubs out, and none of that would tell us whether the right segment
/// got the right colour. Same approach as `file_viewer_test.dart`.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ident_mobile/src/ais_map_geometry.dart';
import 'package:ident_mobile/src/models.dart';
import 'package:ident_mobile/src/ui/ais_map.dart';
import 'package:latlong2/latlong.dart';

TrackPoint p(double lat, double lng, {int t = 0, double? cog}) =>
    TrackPoint(lat: lat, lng: lng, t: t, cog: cog);

VesselTrack track(int mmsi, List<TrackPoint> fixes, {int colourIndex = 0}) =>
    VesselTrack(
      vessel: Vessel(mmsi: mmsi, track: fixes),
      fixes: fixes,
      colour: vesselColour(colourIndex),
    );

void main() {
  group('buildTrackSegments', () {
    test('draws one segment per gap, not one polyline per vessel', () {
      final segments = buildTrackSegments([
        track(1, [p(0, 0), p(0, 1), p(0, 2)]),
        track(2, [p(1, 0), p(1, 1)]),
      ]);
      expect(segments, hasLength(3));
      expect(segments.where((s) => s.hitValue == 1), hasLength(2));
      expect(segments.every((s) => s.points.length == 2), isTrue);
    });

    test('colours the segments by age', () {
      final segments = buildTrackSegments([
        track(1, [p(0, 0), p(0, 1), p(0, 2)]),
      ], alpha: 1);
      expect(segments.first.color, gradFrom);
      expect(segments.last.color, gradTo);
    });

    test('a vessel that never moved contributes no line', () {
      expect(buildTrackSegments([track(1, [p(0, 0)])]), isEmpty);
    });

    test('the highlight is drawn wider and more solid', () {
      final normal = buildTrackSegments([track(1, [p(0, 0), p(0, 1)])]);
      final highlighted = buildTrackSegments(
        [track(1, [p(0, 0), p(0, 1)])],
        width: 4,
        alpha: 0.95,
      );
      expect(highlighted.single.strokeWidth,
          greaterThan(normal.single.strokeWidth));
      expect(highlighted.single.color.a, greaterThan(normal.single.color.a));
    });
  });

  group('buildFixDots', () {
    test('a dot per fix, each carrying its own index', () {
      final dots = buildFixDots([
        track(1, [p(0, 0), p(0, 1), p(0, 2)]),
      ]);
      expect(dots, hasLength(3));
      expect(dots.map((d) => d.hitValue), [
        (mmsi: 1, fixIndex: 0),
        (mmsi: 1, fixIndex: 1),
        (mmsi: 1, fixIndex: 2),
      ]);
    });

    test('dots wear the vessel colour, not the age gradient', () {
      final dots = buildFixDots([
        track(1, [p(0, 0), p(0, 1)], colourIndex: 3),
      ]);
      expect(dots.first.color.r, vesselColour(3).r);
    });

    test('fixes inside the recording get a ring, the rest do not', () {
      // Without this the wider history ranges lose the page's whole framing:
      // there would be no way to see which traffic the recording covers.
      final dots = buildFixDots(
        [
          track(1, [p(0, 0, t: 10), p(0, 1, t: 500)]),
        ],
        emphasise: (fix) => fix.t >= 100,
      );
      expect(dots.first.borderStrokeWidth, 0);
      expect(dots.last.borderStrokeWidth, greaterThan(0));
    });
  });

  group('buildRangeRings', () {
    test('five rings, ascending, measured in metres', () {
      final rings = buildRangeRings(const LatLng(48, -123));
      expect(rings, hasLength(rangeRingKm.length));
      expect(rings.every((r) => r.useRadiusInMeter), isTrue);
      expect(rings.map((r) => r.radius), [1000, 2000, 3000, 4000, 5000]);
    });

    test('rings are outlines, so they do not tint the chart', () {
      final rings = buildRangeRings(const LatLng(48, -123));
      expect(rings.every((r) => r.color.a == 0), isTrue);
      expect(rings.every((r) => r.borderStrokeWidth > 0), isTrue);
    });

    test('labels sit north of the sensor, one per ring', () {
      const sensor = LatLng(48, -123);
      final labels = buildRingLabels(sensor);
      expect(labels, hasLength(rangeRingKm.length));
      expect(labels.every((l) => l.point.latitude > sensor.latitude), isTrue);
    });
  });

  group('buildVesselArrows', () {
    test('one marker per vessel, at its latest fix', () {
      final arrows = buildVesselArrows([
        track(1, [p(0, 0), p(0, 5)]),
        track(2, [p(9, 9)]),
      ]);
      expect(arrows, hasLength(2));
      expect(arrows.first.point, const LatLng(0, 5));
    });

    test('markers do not counter-rotate, so a heading stays true', () {
      // Marker.rotate would hold the arrow upright against map rotation, which
      // is the opposite of what a course arrow needs.
      final arrows = buildVesselArrows([track(1, [p(0, 0, cog: 90)])]);
      expect(arrows.single.rotate ?? false, isFalse);
    });

    test('a vessel with no fixes is not drawn', () {
      expect(buildVesselArrows([track(1, const [])]), isEmpty);
    });
  });
}
