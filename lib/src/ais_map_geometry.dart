/// The rules behind the AIS map: colour, decimation, framing and hit testing.
///
/// Kept out of the widgets for the same reason as `spectrogram_geometry.dart` —
/// every rule here is arithmetic that looks plausible when it is wrong. A
/// reversed age gradient still draws a pretty line; a decimation that drops the
/// newest fix still draws a track; a hit test that misses by 10 px still feels
/// like "the map is a bit fiddly". None of those announce themselves, so they
/// are tested directly rather than eyeballed.
///
/// The constants mirror `js/sensor-map.js` in the web app deliberately. A vessel
/// must look the same in both clients: an operator who learns that the blue
/// track is the ferry on a desktop should not have to relearn it on a phone.
library;

import 'dart:ui' show Color, Offset;

import 'package:flutter_map/flutter_map.dart' show LatLngBounds;
import 'package:latlong2/latlong.dart';

import 'models.dart';

/// Eight colours, assigned per vessel so overlapping tracks stay tellable apart.
///
/// Same list, same order as `VESSEL_COLORS` in the web map. Chosen to survive
/// being drawn at 2.5 px over a blue-green bathymetric chart, which rules out
/// most of the darker end of any palette.
const vesselPalette = <Color>[
  Color(0xFFFFB347),
  Color(0xFF5AD1FF),
  Color(0xFF9B8CFF),
  Color(0xFF7DDE8C),
  Color(0xFFFF7EB6),
  Color(0xFFFFE066),
  Color(0xFFFF8C66),
  Color(0xFF66D9C2),
];

/// The palette colour at [index], wrapping.
Color vesselColour(int index) =>
    vesselPalette[index.remainder(vesselPalette.length).abs()];

/// Colour index per MMSI, assigned by order of first appearance.
///
/// A pure function of the vessel list rather than a memo that accumulates
/// across fetches: a given query is cached and returns a stable list, so purity
/// costs nothing and buys a test. The consequence is that changing the history
/// range, which changes the vessel set, can recolour vessels — acceptable, and
/// the alternative (a session-long map) would leak colours across streams.
Map<int, int> paletteIndicesFor(List<Vessel> vessels) {
  final out = <int, int>{};
  for (final v in vessels) {
    out.putIfAbsent(v.mmsi, () => out.length);
  }
  return out;
}

/// Cap on fixes drawn per vessel.
///
/// A busy area hands us vessels with hundreds of fixes each. A segment and a dot
/// for every one swamps the map for no gain: at 60 the track shape and the
/// latest position are both preserved and the difference is invisible.
const maxFixesPerVessel = 60;

/// Evenly sample [points] down to at most [cap], always keeping first and last.
///
/// Returns the original list unchanged when it is already small enough. The
/// explicit overwrite of the final entry matters: without it the rounding can
/// land one short and the map shows a vessel a few minutes behind where it
/// actually was, which is exactly the kind of error nobody notices.
List<TrackPoint> decimateFixes(
  List<TrackPoint> points, {
  int cap = maxFixesPerVessel,
}) {
  if (cap < 1) return const [];
  if (points.length <= cap) return points;
  if (cap == 1) return [points.last];

  final step = (points.length - 1) / (cap - 1);
  final out = <TrackPoint>[
    for (var i = 0; i < cap; i++) points[(i * step).round()],
  ];
  out[out.length - 1] = points.last; // guarantee the newest fix
  return out;
}

/// Oldest end of the track gradient, as RGB channels.
const _gradFromRgb = [224, 82, 74];

/// Newest end of the track gradient, as RGB channels.
const _gradToRgb = [61, 220, 132];

/// Oldest end of the track gradient.
const gradFrom = Color(0xFFE0524A);

/// Newest end of the track gradient.
const gradTo = Color(0xFF3DDC84);

/// Distinct colours the gradient is quantised to.
///
/// flutter_map's polyline painter batches consecutive polylines that share a
/// paint into one path. A continuous ramp gives every segment its own colour and
/// therefore its own draw call — 59 per vessel. Twelve steps batch to twelve and
/// are indistinguishable at 2.5 px.
const gradientSteps = 12;

/// Track colour at age fraction [f] — 0 is the oldest fix, 1 the newest.
Color trackAgeColour(double f) {
  final clamped = f.clamp(0.0, 1.0);
  final q = (clamped * (gradientSteps - 1)).round() / (gradientSteps - 1);
  int channel(int i) =>
      (_gradFromRgb[i] + (_gradToRgb[i] - _gradFromRgb[i]) * q).round();
  return Color.fromARGB(255, channel(0), channel(1), channel(2));
}

/// One colour per segment of a track with [pointCount] fixes.
///
/// Note the single-segment case: a two-point track is drawn entirely in the
/// *newest* colour, not the oldest. That is the web's rule and it is the right
/// one — with one segment there is no age to show, and green reads as "this is
/// current" rather than implying the vessel was only ever here long ago.
List<Color> segmentColours(int pointCount) {
  final segments = pointCount - 1;
  if (segments <= 0) return const [];
  return [
    for (var i = 0; i < segments; i++)
      trackAgeColour(segments == 1 ? 1 : i / (segments - 1)),
  ];
}

/// A vessel prepared for drawing: decimated fixes plus its stable colour.
class VesselTrack {
  const VesselTrack({
    required this.vessel,
    required this.fixes,
    required this.colour,
  });

  final Vessel vessel;

  /// The fixes actually drawn — [decimateFixes] applied to the vessel's track.
  final List<TrackPoint> fixes;

  final Color colour;

  int get mmsi => vessel.mmsi;
  String get label => vessel.label;

  /// Every fix as a map coordinate, in time order.
  List<LatLng> get points => [for (final p in fixes) LatLng(p.lat, p.lng)];

  /// Where the vessel was last seen, or null for an empty track.
  LatLng? get latest =>
      fixes.isEmpty ? null : LatLng(fixes.last.lat, fixes.last.lng);
}

/// Prepare [vessels] for drawing: assign colours, decimate, drop empty tracks.
List<VesselTrack> buildTracks(
  List<Vessel> vessels, {
  int cap = maxFixesPerVessel,
}) {
  final indices = paletteIndicesFor(vessels);
  return [
    for (final v in vessels)
      if (v.track.isNotEmpty)
        VesselTrack(
          vessel: v,
          fixes: decimateFixes(v.track, cap: cap),
          colour: vesselColour(indices[v.mmsi] ?? 0),
        ),
  ];
}

/// How many vessels are drawn at once.
///
/// The web map has no cap — a desktop canvas absorbs a hundred tracks. A phone
/// does not, and a hundred overlapping tracks is unreadable anyway. Beyond this
/// the nearest to the sensor are kept and the header says so, so the operator
/// knows there is more rather than silently seeing a subset.
const maxDrawnVessels = 40;

const _distance = Distance();

/// Kilometres between two positions.
double distanceKm(LatLng a, LatLng b) => _distance(a, b) / 1000;

/// A vessel's closest approach to [sensor], in km, or null when unknowable.
double? closestApproachKm(Vessel vessel, LatLng? sensor) {
  if (sensor == null || vessel.track.isEmpty) return null;
  var best = double.infinity;
  for (final p in vessel.track) {
    final km = distanceKm(sensor, LatLng(p.lat, p.lng));
    if (km < best) best = km;
  }
  return best.isFinite ? best : null;
}

/// The [cap] vessels worth drawing, nearest the sensor first.
///
/// Without a sensor position there is no "nearest", so the most recently seen
/// win instead — the same tie-break the server uses for its stationary cap.
List<Vessel> capVessels(
  List<Vessel> vessels,
  LatLng? sensor, {
  int cap = maxDrawnVessels,
}) {
  if (vessels.length <= cap) return vessels;

  final sorted = [...vessels];
  if (sensor != null) {
    sorted.sort((a, b) {
      final ka = closestApproachKm(a, sensor) ?? double.infinity;
      final kb = closestApproachKm(b, sensor) ?? double.infinity;
      return ka.compareTo(kb);
    });
  } else {
    sorted.sort((a, b) => (b.latest?.t ?? 0).compareTo(a.latest?.t ?? 0));
  }
  return sorted.take(cap).toList(growable: false);
}

/// Everything the map draws, from the raw vessel list.
///
/// Capping then colouring, in that order, so the colours belong to the vessels
/// actually on screen. Pure and deterministic, so the map and the vessel list
/// can each call it and agree on every colour without sharing state.
List<VesselTrack> prepareTracks(
  List<Vessel> vessels,
  LatLng? sensor, {
  int vesselCap = maxDrawnVessels,
  int fixCap = maxFixesPerVessel,
}) =>
    buildTracks(capVessels(vessels, sensor, cap: vesselCap), cap: fixCap);

/// Range rings drawn round the sensor, in kilometres.
const rangeRingKm = <int>[1, 2, 3, 4, 5];

/// The bounds of a circle of [metres] radius round [centre].
///
/// Computed by walking the four cardinal points rather than the web's
/// `km / 111.32` degrees-of-latitude shortcut, which is only correct
/// north-south: at 60°N a degree of longitude is half a degree of latitude, so
/// the shortcut frames a ring twice as wide as it should.
LatLngBounds ringBounds(LatLng centre, double metres) {
  final north = _distance.offset(centre, metres, 0);
  final east = _distance.offset(centre, metres, 90);
  final south = _distance.offset(centre, metres, 180);
  final west = _distance.offset(centre, metres, 270);
  return LatLngBounds.unsafe(
    north: north.latitude,
    south: south.latitude,
    east: east.longitude,
    west: west.longitude,
  );
}

/// Where a range ring's "N km" label sits — due north of the centre, on the ring.
LatLng ringLabelPoint(LatLng centre, double metres) =>
    _distance.offset(centre, metres, 0);

/// What the camera should frame, or null when there is nothing to frame.
///
/// Null rather than a world view because [LatLngBounds.fromPoints] asserts on an
/// empty list, and because "no data" is better answered by leaving the camera
/// where it is than by throwing the operator out to zoom 0.
LatLngBounds? contentBounds({
  LatLng? sensor,
  Iterable<LatLng> fixes = const [],
  double? sensorRingMetres,
}) {
  final corners = <LatLng>[];

  if (sensor != null) {
    if (sensorRingMetres != null && sensorRingMetres > 0) {
      final ring = ringBounds(sensor, sensorRingMetres);
      corners
        ..add(LatLng(ring.north, ring.east))
        ..add(LatLng(ring.south, ring.west));
    } else {
      corners.add(sensor);
    }
  }
  corners.addAll(fixes);

  if (corners.isEmpty) return null;
  return LatLngBounds.fromPoints(corners);
}

/// Distance at which a vessel counts as "near" the sensor, in km.
const nearKm = 5.0;

/// MMSIs that came within [km] of the sensor — the vessel list's "near" flag.
Set<int> vesselsNearSensor(
  List<Vessel> vessels,
  LatLng? sensor, {
  double km = nearKm,
}) {
  if (sensor == null) return const {};
  return {
    for (final v in vessels)
      if ((closestApproachKm(v, sensor) ?? double.infinity) <= km) v.mmsi,
  };
}

/// What a tap landed on: a vessel, and a specific fix when one was hit.
typedef AisHit = ({int mmsi, int? fixIndex});

/// Which vessel or fix is under [tap], in screen space.
///
/// [project] converts a coordinate to a screen offset — passed in rather than
/// taking a `MapCamera` so this can be tested without a map.
///
/// Fix dots beat track lines: the dots are the thing carrying data worth
/// opening, and a dot always sits on its own line so a stacking-order rule would
/// make them unreachable. The slop values are finger-sized rather than
/// pixel-accurate; a 2.5 px dot is otherwise untappable, which is also why
/// flutter_map's own hit testing is not used here (its hitbox is the drawn
/// radius).
AisHit? hitTestAis({
  required Offset tap,
  required Offset Function(LatLng) project,
  required List<VesselTrack> tracks,
  double fixSlop = 22,
  double lineSlop = 16,
}) {
  AisHit? bestFix;
  var bestFixDistance = double.infinity;
  AisHit? bestLine;
  var bestLineDistance = double.infinity;

  for (final t in tracks) {
    Offset? previous;
    for (var i = 0; i < t.fixes.length; i++) {
      final p = t.fixes[i];
      final here = project(LatLng(p.lat, p.lng));

      final d = (here - tap).distance;
      if (d <= fixSlop && d < bestFixDistance) {
        bestFixDistance = d;
        bestFix = (mmsi: t.mmsi, fixIndex: i);
      }

      if (previous != null) {
        final ds = _distanceToSegment(tap, previous, here);
        if (ds <= lineSlop && ds < bestLineDistance) {
          bestLineDistance = ds;
          bestLine = (mmsi: t.mmsi, fixIndex: null);
        }
      }
      previous = here;
    }
  }

  return bestFix ?? bestLine;
}

/// Shortest distance from [p] to the segment [a]–[b].
double _distanceToSegment(Offset p, Offset a, Offset b) {
  final dx = b.dx - a.dx;
  final dy = b.dy - a.dy;
  final lengthSquared = dx * dx + dy * dy;
  if (lengthSquared == 0) return (p - a).distance;

  final t = (((p.dx - a.dx) * dx + (p.dy - a.dy) * dy) / lengthSquared)
      .clamp(0.0, 1.0);
  return (p - Offset(a.dx + t * dx, a.dy + t * dy)).distance;
}

/// How much AIS history the map asks for.
///
/// [recording] is the honest answer to the page's question — "what was out there
/// while this was recorded" — but it only works when the recording is long
/// enough to contain more than one AIS report. The poller logs a fix roughly
/// every 30 seconds, so a five-second recording yields at most one fix per
/// vessel: no track, no course, no age gradient. The wider modes exist for that
/// case, and the header always states which one is in force.
enum AisHistory {
  /// The recording's own span.
  recording,

  /// The recording's span, widened by an hour either side.
  aroundRecording,

  /// Every fix the poller has logged for this sensor.
  all,
}

/// How far [AisHistory.aroundRecording] widens the window at each end.
const aroundRecordingPadding = Duration(hours: 1);

/// Below this, a recording is too short to contain a track and the map widens.
const autoWidenBelow = Duration(minutes: 2);

/// The query for a history mode over a recording running [start] to [end].
({DateTime? from, DateTime? to, bool all}) aisQueryFor(
  AisHistory history,
  DateTime start,
  DateTime end,
) =>
    switch (history) {
      // `from`/`to` are dropped in all mode rather than sent and ignored, so
      // the request and the provider's cache key both say what they mean.
      AisHistory.all => (from: null, to: null, all: true),
      AisHistory.recording => (from: start, to: end, all: false),
      AisHistory.aroundRecording => (
          from: start.subtract(aroundRecordingPadding),
          to: end.add(aroundRecordingPadding),
          all: false,
        ),
    };

/// Whether a recording of [length] is too short to plot a track from.
bool shouldAutoWiden(Duration length) => length < autoWidenBelow;
