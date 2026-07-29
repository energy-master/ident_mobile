/// AIS — vessel traffic during the active recording.
///
/// The map is tied to whichever recording is selected in the Live images
/// window: swipe here after choosing a file and you see the vessels that were
/// present *while that recording was made*. That framing is the point. A live
/// snapshot would answer "what is out there now", which tells you nothing about
/// a detection from three days ago.
///
/// **Gesture handling.** This window lives inside a horizontally-swiping
/// dashboard, so one-finger panning is deliberately disabled: dragging west and
/// "go to the previous window" are the same gesture, and the map would eat every
/// swipe. Two fingers move and zoom the map in place, and the expand button
/// opens a full-screen map where all gestures are available because nothing is
/// competing for them.
library;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../models.dart';
import '../providers.dart';
import '../theme.dart';
import '../time_format.dart';

/// Basemap tiles.
///
/// This mirrors the web app (js/leaflet.js), but note that OpenStreetMap's tile
/// usage policy discourages distributed apps pointing at their public servers.
/// Before this ships widely, point [tileUrl] at a keyed provider or a
/// self-hosted cache — it is deliberately a single constant so that is a
/// one-line change.
const tileUrl = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
const tileAttribution = '© OpenStreetMap contributors';

/// Identifies this client to the tile server, which OSM's policy requires.
const tileUserAgent = 'ai.goident.mobile';

class AisPage extends ConsumerWidget {
  const AisPage({super.key, required this.stream});

  final String stream;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(activeFileProvider(stream));

    if (active == null) {
      return const _NoActiveFile();
    }

    // This recording's own duration, not the folder's — folders mix lengths,
    // and querying AIS over 5 minutes for a 5-second recording would show
    // traffic that was never there while it was recording.
    final durationMs = ref.watch(fileDurationsProvider(stream))[active.name];
    final start = active.startTime;
    final end = durationMs != null
        ? start.add(Duration(milliseconds: durationMs))
        : start.add(const Duration(minutes: 15));

    final sensor = ref.watch(sensorProvider(stream)).valueOrNull;
    final vessels = ref.watch(vesselsProvider((stream: stream, from: start, to: end)));

    return Column(
      children: [
        _Header(start: start, end: end, vessels: vessels.valueOrNull),
        Expanded(
          child: switch (vessels) {
            AsyncData(:final value) => _MapView(
                vessels: value,
                sensor: sensor,
                interactive: false,
                onExpand: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => _FullScreenMap(
                      stream: stream,
                      vessels: value,
                      sensor: sensor,
                      start: start,
                      end: end,
                    ),
                  ),
                ),
              ),
            AsyncError(:final error) => _Error(
                message: '$error',
                onRetry: () => ref.invalidate(
                  vesselsProvider((stream: stream, from: start, to: end)),
                ),
              ),
            _ => const Center(child: CircularProgressIndicator()),
          },
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.start, required this.end, required this.vessels});

  final DateTime start;
  final DateTime end;
  final List<Vessel>? vessels;

  @override
  Widget build(BuildContext context) {
    final moving = vessels?.where((v) => v.isMoving).length;
    final total = vessels?.length;

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
      decoration: const BoxDecoration(
        color: IdentColors.surface,
        border: Border(bottom: BorderSide(color: Color(0x1FFFFFFF))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            formatTimeSpan(start, end),
            style: const TextStyle(
              color: IdentColors.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          Text(
            total == null
                ? 'Loading vessels…'
                : total == 0
                    ? 'No vessels logged during this recording'
                    : '$total vessel${total == 1 ? '' : 's'} · $moving moving',
            style: const TextStyle(color: IdentColors.textSecondary, fontSize: 11.5),
          ),
        ],
      ),
    );
  }
}

class _MapView extends StatelessWidget {
  const _MapView({
    required this.vessels,
    required this.sensor,
    required this.interactive,
    this.onExpand,
  });

  final List<Vessel> vessels;
  final Sensor? sensor;

  /// When false, one-finger drag is left to the dashboard's page swipe.
  final bool interactive;

  final VoidCallback? onExpand;

  /// Frame the sensor if there is one, else the vessels, else a world view.
  LatLng get _centre {
    if (sensor != null && sensor!.hasPosition) {
      return LatLng(sensor!.latitude!, sensor!.longitude!);
    }
    final points = vessels.expand((v) => v.track).toList();
    if (points.isEmpty) return const LatLng(0, 0);
    final lat = points.map((p) => p.lat).reduce((a, b) => a + b) / points.length;
    final lng = points.map((p) => p.lng).reduce((a, b) => a + b) / points.length;
    return LatLng(lat, lng);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        FlutterMap(
          options: MapOptions(
            initialCenter: _centre,
            initialZoom: 11,
            interactionOptions: InteractionOptions(
              // Dropping `drag` is what lets a one-finger horizontal swipe reach
              // the dashboard's PageView instead of panning the map. Two-finger
              // gestures stay, and the expand button gives a map with everything
              // enabled.
              flags: interactive
                  ? InteractiveFlag.all
                  : InteractiveFlag.pinchZoom |
                      InteractiveFlag.pinchMove |
                      InteractiveFlag.doubleTapZoom,
            ),
          ),
          children: [
            TileLayer(
              urlTemplate: tileUrl,
              userAgentPackageName: tileUserAgent,
            ),
            // Tracks under markers, so a dot is never hidden by a line.
            PolylineLayer(
              polylines: [
                for (final v in vessels)
                  if (v.track.length >= 2)
                    Polyline(
                      points: [for (final p in v.track) LatLng(p.lat, p.lng)],
                      strokeWidth: 2,
                      color: IdentColors.accent.withValues(alpha: 0.75),
                    ),
              ],
            ),
            MarkerLayer(
              markers: [
                for (final v in vessels)
                  if (v.latest != null)
                    Marker(
                      point: LatLng(v.latest!.lat, v.latest!.lng),
                      width: 26,
                      height: 26,
                      child: _VesselMarker(vessel: v),
                    ),
                if (sensor != null && sensor!.hasPosition)
                  Marker(
                    point: LatLng(sensor!.latitude!, sensor!.longitude!),
                    width: 30,
                    height: 30,
                    child: const _SensorMarker(),
                  ),
              ],
            ),
            const RichAttributionWidget(
              attributions: [TextSourceAttribution(tileAttribution)],
            ),
          ],
        ),
        if (!interactive)
          Positioned(
            top: 8,
            right: 8,
            child: Column(
              children: [
                _MapButton(icon: Icons.open_in_full, tooltip: 'Full screen map', onTap: onExpand),
                const SizedBox(height: 6),
                const _TwoFingerHint(),
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

class _MapButton extends StatelessWidget {
  const _MapButton({required this.icon, required this.tooltip, required this.onTap});

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: IdentColors.shell.withValues(alpha: 0.78),
      borderRadius: BorderRadius.circular(6),
      child: IconButton(
        icon: Icon(icon, size: 18),
        color: IdentColors.textPrimary,
        tooltip: tooltip,
        visualDensity: VisualDensity.compact,
        onPressed: onTap,
      ),
    );
  }
}

class _VesselMarker extends StatelessWidget {
  const _VesselMarker({required this.vessel});

  final Vessel vessel;

  @override
  Widget build(BuildContext context) {
    // Moving vessels are what an operator is looking for; moored ones are
    // context. Distinguishing them keeps a busy anchorage readable.
    final colour = vessel.isMoving ? IdentColors.warn : IdentColors.idle;

    return Tooltip(
      message: [
        vessel.label,
        if (vessel.type != null) vessel.type!,
        if (vessel.latest?.sog != null) '${vessel.latest!.sog!.toStringAsFixed(1)} kn',
      ].join(' · '),
      child: Icon(
        vessel.isMoving ? Icons.navigation : Icons.circle,
        size: vessel.isMoving ? 18 : 10,
        color: colour,
        // Point the arrow along the course when it is known.
        shadows: const [Shadow(color: Colors.black54, blurRadius: 3)],
      ),
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

/// Full-screen map: nothing competes for gestures here, so all are enabled.
class _FullScreenMap extends StatelessWidget {
  const _FullScreenMap({
    required this.stream,
    required this.vessels,
    required this.sensor,
    required this.start,
    required this.end,
  });

  final String stream;
  final List<Vessel> vessels;
  final Sensor? sensor;
  final DateTime start;
  final DateTime end;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          formatTimeSpan(start, end),
          style: const TextStyle(fontSize: 13),
        ),
      ),
      body: _MapView(vessels: vessels, sensor: sensor, interactive: true),
    );
  }
}

class _NoActiveFile extends StatelessWidget {
  const _NoActiveFile();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.map_outlined, size: 44, color: IdentColors.idle),
            SizedBox(height: 14),
            Text(
              'Choose a recording in Live images.\n'
              'The map then shows the vessels present while it was recorded.',
              textAlign: TextAlign.center,
              style: TextStyle(color: IdentColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

class _Error extends StatelessWidget {
  const _Error({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 44, color: IdentColors.idle),
            const SizedBox(height: 14),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: IdentColors.textSecondary),
            ),
            const SizedBox(height: 18),
            FilledButton.tonal(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}
