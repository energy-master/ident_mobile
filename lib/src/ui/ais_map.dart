/// The AIS chart: tracks, fixes, vessels and the sensor's range.
///
/// A port of the web app's `js/sensor-map.js` onto `flutter_map`, which is the
/// direct Flutter counterpart of Leaflet — `TileLayer`, `PolylineLayer`,
/// `CircleLayer` and `MarkerLayer` line up almost one-to-one with `L.tileLayer`,
/// `L.polyline`, `L.circleMarker` and `L.marker`. Where this deliberately
/// differs from the web:
///
///   * **Hover does not exist on a phone.** The web map distinguishes a hovered
///     vessel from a selected one; here there is one highlight and tapping is
///     the only way to set it.
///   * **Hit testing is ours, not the package's.** flutter_map's own hitbox for
///     a circle is its drawn radius, and a 2.5 px fix dot cannot be tapped with
///     a finger. [hitTestAis] gives finger-sized slop, lets fix dots beat track
///     lines deterministically, and — unlike `hitNotifier`, which reports null
///     for every non-hit pointer event including drags — can tell "tapped open
///     water" from "not a tap at all", which is what deselecting needs.
///   * **Fix dots are a `CircleLayer`, never markers.** The circle painter
///     groups by colour and radius and issues one `drawPoints` per group, so
///     2400 dots cost a handful of draw calls; markers are real widgets and
///     would cost 2400 of them per frame.
///
/// **Layer instances are cached in `State` fields on purpose.** Every layer in
/// flutter_map throws away its projection cache in `didUpdateWidget`, so handing
/// it a new-but-equal widget re-projects every point. Reusing the identical
/// widget instance makes `Element.update` short-circuit instead. That is why
/// selection is drawn as a thin extra layer on top rather than by restyling the
/// base one: highlighting re-projects one track, not all of them.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../ais_map_geometry.dart';
import '../models.dart';
import '../providers.dart';
import '../theme.dart';
import 'ais_sheets.dart';

/// Basemap: Esri's world ocean base.
///
/// Chosen over the web app's plain OSM street map because this is a marine
/// tool: it carries bathymetry, so a vessel track reads against depth and
/// seabed shape rather than against empty blue. Global coverage, so it works
/// for Canadian waters where the US-only NOAA chart services do not. Note the
/// {y}/{x} order — Esri's REST tile path is row-then-column, the reverse of the
/// usual XYZ convention.
const oceanTileUrl =
    'https://services.arcgisonline.com/ArcGIS/rest/services/Ocean/World_Ocean_Base/MapServer/tile/{z}/{y}/{x}';

/// Place and feature labels for the ocean base, as a separate transparent layer.
const oceanLabelsUrl =
    'https://services.arcgisonline.com/ArcGIS/rest/services/Ocean/World_Ocean_Reference/MapServer/tile/{z}/{y}/{x}';

/// Seamarks — buoys, lights, channel markers — as a transparent overlay.
///
/// Community-run and sparse outside busy waters, so it is layered on top rather
/// than relied on: where there is nothing to draw the tiles are simply empty.
const seamarkTileUrl = 'https://tiles.openseamap.org/seamark/{z}/{x}/{y}.png';

const oceanAttribution =
    'Esri, GEBCO, NOAA, National Geographic, and other contributors';
const seamarkAttribution = '© OpenSeaMap contributors';

/// Identifies this client to the tile servers, which OSM-family policies require.
const tileUserAgent = 'ai.goident.mobile';

/// Esri serves the ocean basemap to z13 and no further. Without these the map
/// happily requests tiles that do not exist as soon as the user zooms in.
const oceanMaxNativeZoom = 13;
const oceanMaxZoom = 16.0;
const seamarkMaxZoom = 18.0;

/// Range ring colour — the web map's `#4aa3ff`.
const rangeRingColour = Color(0xFF4AA3FF);

const _trackWidth = 2.5;
const _highlightWidth = 4.0;
const _fixRadius = 2.5;
const _highlightFixRadius = 3.5;

/// One polyline per segment, coloured by age.
///
/// Segments rather than one gradient polyline because flutter_map's gradient is
/// a straight screen-space ramp between the line's first and last points, which
/// is simply wrong for a track that curves or doubles back. This is also what
/// the web map does, for the same reason (Leaflet strokes are single-colour).
List<Polyline<int>> buildTrackSegments(
  List<VesselTrack> tracks, {
  double width = _trackWidth,
  double alpha = 0.55,
}) {
  final out = <Polyline<int>>[];
  for (final t in tracks) {
    final points = t.points;
    final colours = segmentColours(points.length);
    for (var i = 0; i < colours.length; i++) {
      out.add(
        Polyline(
          points: [points[i], points[i + 1]],
          strokeWidth: width,
          color: colours[i].withValues(alpha: alpha),
          hitValue: t.mmsi,
        ),
      );
    }
  }
  return out;
}

/// A dot per drawn fix, in the vessel's own colour.
///
/// [emphasise] marks the fixes reported while the recording was being made. In
/// the wider history ranges that is the difference between "this is what the
/// recording heard" and "this is context either side of it", and without it
/// widening the window quietly discards the whole point of the page.
List<CircleMarker<AisHit>> buildFixDots(
  List<VesselTrack> tracks, {
  double radius = _fixRadius,
  bool Function(TrackPoint)? emphasise,
}) {
  final out = <CircleMarker<AisHit>>[];
  for (final t in tracks) {
    for (var i = 0; i < t.fixes.length; i++) {
      final p = t.fixes[i];
      final inSpan = emphasise?.call(p) ?? false;
      out.add(
        CircleMarker(
          point: LatLng(p.lat, p.lng),
          radius: radius,
          color: t.colour.withValues(alpha: 0.75),
          borderStrokeWidth: inSpan ? 1.5 : 0,
          borderColor: IdentColors.textPrimary,
          hitValue: (mmsi: t.mmsi, fixIndex: i),
        ),
      );
    }
  }
  return out;
}

/// Concentric 1–5 km rings round the sensor.
List<CircleMarker<Object>> buildRangeRings(LatLng sensor) => [
      for (final km in rangeRingKm)
        CircleMarker(
          point: sensor,
          radius: km * 1000,
          useRadiusInMeter: true,
          color: const Color(0x00000000),
          borderStrokeWidth: 1,
          borderColor: rangeRingColour.withValues(alpha: 0.55),
        ),
    ];

/// A heading arrow per moving vessel, a dot per vessel that never moved.
List<Marker> buildVesselArrows(
  List<VesselTrack> tracks, {
  int? highlightMmsi,
}) =>
    [
      for (final t in tracks)
        if (t.latest != null)
          Marker(
            point: t.latest!,
            width: 30,
            height: 30,
            child: _VesselArrow(
              track: t,
              highlighted: t.mmsi == highlightMmsi,
            ),
          ),
    ];

/// The `N km` labels sitting on the northern edge of each ring.
List<Marker> buildRingLabels(LatLng sensor) => [
      for (final km in rangeRingKm)
        Marker(
          point: ringLabelPoint(sensor, km * 1000),
          width: 44,
          height: 18,
          child: _RangeRingLabel(km: km),
        ),
    ];

class AisMap extends ConsumerStatefulWidget {
  const AisMap({
    super.key,
    required this.stream,
    required this.vessels,
    required this.sensor,
    required this.recordingStart,
    required this.recordingEnd,
    required this.fullScreen,
    required this.refitKey,
    this.onExpand,
  });

  final String stream;

  /// The vessels as the provider returned them. Held by identity: capping,
  /// colouring and decimation happen here, once per data change.
  final List<Vessel> vessels;

  final Sensor? sensor;

  /// The active recording's own span, used to mark which fixes it covers.
  final DateTime recordingStart;
  final DateTime recordingEnd;

  /// True in the full-screen route, where nothing competes for gestures.
  final bool fullScreen;

  /// What the camera is framing — the stream, the recording, the range.
  ///
  /// The camera is reframed when this changes, not when the vessels do. The two
  /// came apart with the live range: it refetches every minute, and refitting on
  /// new data would drag the chart back to its default framing each time,
  /// undoing whatever the operator had zoomed into.
  final Object refitKey;

  final VoidCallback? onExpand;

  @override
  ConsumerState<AisMap> createState() => _AisMapState();
}

class _AisMapState extends ConsumerState<AisMap> {
  final _controller = MapController();

  /// Map rotation, held outside `setState` so spinning the chart repaints one
  /// small button instead of re-projecting every layer.
  final _rotation = ValueNotifier<double>(0);

  late List<VesselTrack> _tracks;

  /// Framing for the first paint. `initialCameraFit` is applied once and only
  /// once, so later data changes go through [MapController.fitCamera] instead.
  CameraFit? _initialFit;

  // Cached layer widgets. See the library comment: handing flutter_map a new
  // instance of an unchanged layer throws away its projection cache.
  PolylineLayer<int>? _trackLayer;
  CircleLayer<AisHit>? _dotLayer;
  MarkerLayer? _arrowLayer;
  CircleLayer<Object>? _ringLayer;
  MarkerLayer? _ringLabelLayer;
  Object? _baseSignature;
  int? _arrowHighlight;
  bool _arrowsDirty = true;

  LatLng? get _sensorPoint =>
      widget.sensor != null && widget.sensor!.hasPosition
          ? LatLng(widget.sensor!.latitude!, widget.sensor!.longitude!)
          : null;

  @override
  void initState() {
    super.initState();
    _tracks = prepareTracks(widget.vessels, _sensorPoint);
    _initialFit = _cameraFit();
    _pruneView();
  }

  @override
  void didUpdateWidget(AisMap old) {
    super.didUpdateWidget(old);
    if (!identical(old.vessels, widget.vessels) ||
        old.sensor != widget.sensor) {
      _tracks = prepareTracks(widget.vessels, _sensorPoint);
      _pruneView();
    }
    if (old.refitKey != widget.refitKey) {
      // A new recording means new traffic somewhere else; keeping the old
      // camera would leave the operator looking at empty water. Within one
      // recording the camera is left exactly where they put it.
      final fit = _cameraFit();
      if (fit != null) _controller.fitCamera(fit);
    }
  }

  /// Forget selections and hidden vessels that this data no longer contains.
  ///
  /// Widening the history range changes which vessels exist. Left alone, a
  /// selection would highlight nothing and the vessel list would carry a row for
  /// a vessel that is not on the chart. Deferred a frame because this runs
  /// during build and initState, where writing to a provider is reentrant.
  void _pruneView() {
    final present = {for (final t in _tracks) t.mmsi};
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(aisViewProvider(widget.stream).notifier).prune(present);
      }
    });
  }

  @override
  void dispose() {
    // FlutterMap only disposes controllers it created itself.
    _controller.dispose();
    _rotation.dispose();
    super.dispose();
  }

  /// What the camera should frame: the sensor's outermost ring plus every fix.
  CameraFit? _cameraFit() {
    final bounds = contentBounds(
      sensor: _sensorPoint,
      fixes: [for (final t in _tracks) ...t.points],
      sensorRingMetres: rangeRingKm.last * 1000,
    );
    if (bounds == null) return null;
    return CameraFit.bounds(
      bounds: bounds,
      padding: const EdgeInsets.all(28),
      maxZoom: oceanMaxZoom,
    );
  }

  bool _inRecording(TrackPoint p) {
    final t = p.time;
    return !t.isBefore(widget.recordingStart) && !t.isAfter(widget.recordingEnd);
  }

  void _handleTap(TapPosition _, LatLng point) {
    final notifier = ref.read(aisViewProvider(widget.stream).notifier);
    final view = ref.read(aisViewProvider(widget.stream));
    final visible = [for (final t in _tracks) if (view.visible(t.mmsi)) t];

    final hit = hitTestAis(
      tap: _controller.camera.latLngToScreenOffset(point),
      project: _controller.camera.latLngToScreenOffset,
      tracks: visible,
    );

    if (hit == null) {
      notifier.select(null);
      return;
    }
    notifier.select(hit.mmsi);

    if (hit.fixIndex != null) {
      final track = visible.firstWhere((t) => t.mmsi == hit.mmsi);
      showFixDetailSheet(
        context,
        stream: widget.stream,
        track: track,
        fixIndex: hit.fixIndex!,
        popMapAfterNavigate: widget.fullScreen,
      );
    }
  }

  void _showVessels() {
    showVesselListSheet(
      context,
      stream: widget.stream,
      tracks: _tracks,
      near: vesselsNearSensor(widget.vessels, _sensorPoint),
      onFocus: (track) {
        final points = track.points;
        if (points.isEmpty) return;
        _controller.fitCamera(
          CameraFit.bounds(
            bounds: LatLngBounds.fromPoints(points),
            padding: const EdgeInsets.all(48),
            maxZoom: oceanMaxZoom,
          ),
        );
      },
    );
  }

  /// Rebuild only the layers whose inputs actually moved.
  void _refreshLayers(AisView view) {
    final sensor = _sensorPoint;
    final signature = Object.hash(
      identityHashCode(_tracks),
      view.isolatedMmsi,
      Object.hashAllUnordered(view.hiddenMmsi),
      sensor,
    );

    if (signature != _baseSignature) {
      _baseSignature = signature;
      final visible = [for (final t in _tracks) if (view.visible(t.mmsi)) t];

      _trackLayer = PolylineLayer(
        polylines: buildTrackSegments(visible),
        // Every polyline here is two points; simplifying them is pure overhead.
        simplificationTolerance: 0,
      );
      _dotLayer = CircleLayer(
        circles: buildFixDots(visible, emphasise: _inRecording),
      );
      _ringLayer = sensor == null
          ? null
          : CircleLayer(circles: buildRangeRings(sensor));
      _ringLabelLayer =
          sensor == null ? null : MarkerLayer(markers: buildRingLabels(sensor));
      // A flag rather than clearing _arrowHighlight: "no vessel selected" is a
      // legitimate value for it, so null could not mean "stale" as well.
      _arrowsDirty = true;
    }

    if (_arrowsDirty || _arrowHighlight != view.selectedMmsi) {
      _arrowsDirty = false;
      _arrowHighlight = view.selectedMmsi;
      final visible = [for (final t in _tracks) if (view.visible(t.mmsi)) t];
      _arrowLayer = MarkerLayer(
        markers: buildVesselArrows(visible, highlightMmsi: view.selectedMmsi),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final view = ref.watch(aisViewProvider(widget.stream));
    _refreshLayers(view);

    final sensor = _sensorPoint;
    final selected = view.selectedMmsi == null
        ? null
        : _tracks.where((t) => t.mmsi == view.selectedMmsi).firstOrNull;

    return Stack(
      children: [
        FlutterMap(
          mapController: _controller,
          options: MapOptions(
            initialCameraFit: _initialFit,
            initialCenter: sensor ?? const LatLng(0, 0),
            initialZoom: 11,
            // The default is a light grey that flashes between tiles on this
            // app's near-black shell.
            backgroundColor: IdentColors.shell,
            // Keeps projections alive while the dashboard's PageView has this
            // window off screen.
            keepAlive: true,
            onTap: _handleTap,
            onMapEvent: (e) => _rotation.value = e.camera.rotation,
            interactionOptions: InteractionOptions(
              // Dropping `drag` is what lets a one-finger horizontal swipe reach
              // the dashboard's PageView instead of panning the map. Two-finger
              // gestures stay, and the expand button gives a map with everything
              // enabled.
              flags: widget.fullScreen
                  ? InteractiveFlag.all
                  : InteractiveFlag.pinchZoom |
                      InteractiveFlag.pinchMove |
                      InteractiveFlag.doubleTapZoom,
            ),
          ),
          children: [
            TileLayer(
              urlTemplate: oceanTileUrl,
              userAgentPackageName: tileUserAgent,
              maxZoom: oceanMaxZoom,
              maxNativeZoom: oceanMaxNativeZoom,
            ),
            // Overlay layers: flutter_map 8 paints no background of its own, so
            // these sit transparently over the basemap.
            TileLayer(
              urlTemplate: oceanLabelsUrl,
              userAgentPackageName: tileUserAgent,
              maxZoom: oceanMaxZoom,
              maxNativeZoom: oceanMaxNativeZoom,
            ),
            TileLayer(
              urlTemplate: seamarkTileUrl,
              userAgentPackageName: tileUserAgent,
              maxZoom: seamarkMaxZoom,
              // Seamark coverage is patchy; a missing tile is normal and must
              // not paint an error square over the chart.
              errorTileCallback: (_, _, _) {},
            ),
            ?_ringLayer,
            // Tracks under dots, dots under arrows, so nothing hides the thing
            // above it.
            _trackLayer!,
            if (selected != null)
              PolylineLayer(
                polylines: buildTrackSegments(
                  [selected],
                  width: _highlightWidth,
                  alpha: 0.95,
                ),
                simplificationTolerance: 0,
              ),
            _dotLayer!,
            if (selected != null)
              CircleLayer(
                circles: buildFixDots(
                  [selected],
                  radius: _highlightFixRadius,
                  emphasise: _inRecording,
                ),
              ),
            ?_ringLabelLayer,
            _arrowLayer!,
            if (sensor != null)
              MarkerLayer(
                markers: [
                  Marker(
                    point: sensor,
                    width: 30,
                    height: 30,
                    child: const _SensorMarker(),
                  ),
                ],
              ),
            const RichAttributionWidget(
              attributions: [
                TextSourceAttribution(oceanAttribution),
                TextSourceAttribution(seamarkAttribution),
              ],
            ),
          ],
        ),
        Positioned(
          top: 8,
          left: 8,
          child: _VesselsChip(
            count: _tracks.where((t) => view.visible(t.mmsi)).length,
            total: _tracks.length,
            onTap: _tracks.isEmpty ? null : _showVessels,
          ),
        ),
        Positioned(
          top: 8,
          right: 8,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (!widget.fullScreen)
                MapButton(
                  icon: Icons.open_in_full,
                  tooltip: 'Full screen map',
                  onTap: widget.onExpand,
                ),
              MapButton(
                icon: Icons.my_location,
                tooltip: 'Frame everything',
                onTap: () {
                  final fit = _cameraFit();
                  if (fit != null) _controller.fitCamera(fit);
                },
              ),
              ValueListenableBuilder<double>(
                valueListenable: _rotation,
                builder: (_, rotation, _) => rotation % 360 == 0
                    ? const SizedBox.shrink()
                    : MapButton(
                        icon: Icons.explore,
                        tooltip: 'North up',
                        onTap: () => _controller.rotate(0),
                      ),
              ),
              if (!widget.fullScreen) const _TwoFingerHint(),
            ],
          ),
        ),
      ],
    );
  }
}

/// Says why one finger doesn't pan, rather than letting it feel broken.
class _TwoFingerHint extends StatelessWidget {
  const _TwoFingerHint();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: IdentColors.shell.withValues(alpha: 0.78),
        borderRadius: BorderRadius.circular(6),
      ),
      child: const Text(
        'Two fingers to move',
        style: TextStyle(color: IdentColors.textSecondary, fontSize: 10.5),
      ),
    );
  }
}

/// A round map control, sized for a finger rather than a mouse.
class MapButton extends StatelessWidget {
  const MapButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: IdentColors.shell.withValues(alpha: 0.78),
        borderRadius: BorderRadius.circular(6),
        child: IconButton(
          icon: Icon(icon, size: 18),
          color: IdentColors.textPrimary,
          tooltip: tooltip,
          constraints: const BoxConstraints.tightFor(width: 40, height: 40),
          padding: EdgeInsets.zero,
          onPressed: onTap,
        ),
      ),
    );
  }
}

/// Opens the vessel list — the phone's answer to the web map's side panel.
class _VesselsChip extends StatelessWidget {
  const _VesselsChip({
    required this.count,
    required this.total,
    required this.onTap,
  });

  final int count;
  final int total;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final label = count == total ? '$total vessels' : '$count of $total';
    return Material(
      color: IdentColors.shell.withValues(alpha: 0.78),
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 9, 8, 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: const TextStyle(
                  color: IdentColors.textPrimary,
                  fontSize: 11.5,
                ),
              ),
              const Icon(
                Icons.expand_more,
                size: 16,
                color: IdentColors.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A vessel at its latest fix, pointed along its course when it has one.
class _VesselArrow extends StatelessWidget {
  const _VesselArrow({required this.track, required this.highlighted});

  final VesselTrack track;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final cog = track.fixes.isEmpty ? null : track.fixes.last.cog;
    final moving = track.vessel.isMoving;

    // A moored vessel is context, not a contact: drawing it as an arrow would
    // claim a heading nothing in the data supports.
    final icon = Icon(
      moving ? Icons.navigation : Icons.circle,
      size: moving ? (highlighted ? 22 : 18) : (highlighted ? 13 : 10),
      color: track.colour,
      shadows: [
        Shadow(
          color: highlighted ? Colors.black : Colors.black54,
          blurRadius: highlighted ? 5 : 3,
        ),
      ],
    );

    return Center(
      child: cog == null || !moving
          ? icon
          // rotate: false on the Marker, so this angle is relative to map north
          // and stays true when the operator rotates the chart.
          : Transform.rotate(angle: cog * math.pi / 180, child: icon),
    );
  }
}

class _SensorMarker extends StatelessWidget {
  const _SensorMarker();

  @override
  Widget build(BuildContext context) {
    return const Tooltip(
      message: 'Hydrophone',
      child: Icon(
        Icons.graphic_eq,
        size: 22,
        color: IdentColors.ok,
        shadows: [Shadow(color: Colors.black87, blurRadius: 4)],
      ),
    );
  }
}

class _RangeRingLabel extends StatelessWidget {
  const _RangeRingLabel({required this.km});

  final int km;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        '$km km',
        style: const TextStyle(
          color: rangeRingColour,
          fontSize: 10,
          fontWeight: FontWeight.w600,
          shadows: [Shadow(color: Colors.black87, blurRadius: 3)],
        ),
      ),
    );
  }
}
