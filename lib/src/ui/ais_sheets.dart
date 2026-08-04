/// The AIS map's two panels, as bottom sheets.
///
/// The web map puts vessel details in a hover tooltip and the vessel list in a
/// control pinned to the corner of the chart. Neither survives the move to a
/// phone: there is no hover, and a panel over a 6-inch map hides the thing it
/// describes. Both become modal sheets instead — which also keeps them clear of
/// the embedded map's deliberately restricted gestures, since a sheet is a route
/// and competes with nothing.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ais_map_geometry.dart';
import '../file_duration.dart';
import '../models.dart';
import '../providers.dart';
import '../stream_clock.dart';
import '../theme.dart';
import '../time_format.dart';

/// Details of one AIS fix, and what can be done from it.
Future<void> showFixDetailSheet(
  BuildContext context, {
  required String stream,
  required VesselTrack track,
  required int fixIndex,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: identColors(context).surface,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _FixDetail(
      stream: stream,
      track: track,
      fix: track.fixes[fixIndex],
    ),
  );
}

class _FixDetail extends ConsumerStatefulWidget {
  const _FixDetail({
    required this.stream,
    required this.track,
    required this.fix,
  });

  final String stream;
  final VesselTrack track;
  final TrackPoint fix;

  @override
  ConsumerState<_FixDetail> createState() => _FixDetailState();
}

class _FixDetailState extends ConsumerState<_FixDetail> {
  bool _seeking = false;

  Vessel get _vessel => widget.track.vessel;

  /// Put the app at the moment this vessel reported here.
  ///
  /// The clock moves to the fix's own timestamp — not to the start of whatever
  /// recording covers it — so the app is at the instant the operator picked off
  /// the chart. The sheet closes; the map behind it does not. In the tiled
  /// dashboard the fix request also raises [fileFocusRequestProvider] so the
  /// Live images tile catches up, and in the maximised route the dock is how
  /// the operator moves to another view when they are ready — nothing pops the
  /// map on their behalf.
  ///
  /// Nothing moves when no recording covers the fix. That case is real rather
  /// than defensive — in the wider history ranges a fix can easily predate the
  /// oldest recording still on disk — and moving the clock somewhere the images
  /// window cannot follow would leave the app claiming a moment it has no
  /// audio for.
  Future<void> _goToThisTime() async {
    // Captured before the await and before the pop: the sheet is gone by the
    // time the pop runs, so its context cannot be used to find them.
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);

    setState(() => _seeking = true);
    try {
      final files = await ref.read(streamFilesProvider(widget.stream).future);
      if (!mounted) return;
      final durations = ref.read(fileDurationsProvider(widget.stream));
      final file = recordingAt(widget.fix.time, files, durations);

      if (file == null) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              'No recording covers ${formatUtcTimeOnly(widget.fix.time)} UTC.',
            ),
          ),
        );
        return;
      }

      ref
          .read(streamClockProvider(widget.stream).notifier)
          .pin(widget.fix.time, ClockSource.ais);
      ref.read(fileFocusRequestProvider(widget.stream).notifier).state =
          file.name;
      navigator.pop();
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not open a recording: $e')),
      );
    } finally {
      if (mounted) setState(() => _seeking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = identColors(context);
    final fix = widget.fix;
    final identity = [
      if (_vessel.type != null) _vessel.type!,
      if (_vessel.flag != null) _vessel.flag!,
      if (_vessel.dest != null) 'dest ${_vessel.dest}',
    ].join(' · ');

    final speed = fix.sog == null
        ? null
        : '${fix.sog!.toStringAsFixed(1)} kn'
            '${fix.cog == null ? '' : ' @ ${fix.cog!.round()}°'}';

    final held = fix.held
        ? 'held position · ${fix.n} fixes'
            '${fix.heldFor == null ? '' : ' over ${formatDuration(fix.heldFor!)}'}'
        : null;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        24 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _Swatch(colour: widget.track.colour),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _vessel.label,
                  style: TextStyle(
                    color: palette.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                'MMSI ${_vessel.mmsi}',
                style: TextStyle(
                  color: palette.textSecondary,
                  fontSize: 11.5,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          if (identity.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              identity,
              style: TextStyle(
                color: palette.textSecondary,
                fontSize: 12.5,
              ),
            ),
          ],
          const SizedBox(height: 16),
          _Row(
            label: 'Position',
            value: '${fix.lat.toStringAsFixed(5)}, '
                '${fix.lng.toStringAsFixed(5)}',
          ),
          if (speed != null) _Row(label: 'Speed', value: speed),
          _Row(label: 'Reported', value: formatUtcStamp(fix.time)),
          _Row(
            label: 'Age',
            value: formatAge(DateTime.now().toUtc().difference(fix.time)),
          ),
          if (held != null) _Row(label: 'Repeats', value: held),
          if (fix.fetchedAt != null)
            _Row(label: 'Logged', value: '${fix.fetchedAt} UTC'),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: _seeking ? null : _goToThisTime,
                  icon: _seeking
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.schedule, size: 18),
                  label: const Text('Go to this time'),
                ),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                onPressed: () {
                  ref
                      .read(aisViewProvider(widget.stream).notifier)
                      .isolate(_vessel.mmsi);
                  Navigator.of(context).pop();
                },
                icon: const Icon(Icons.filter_alt_outlined, size: 18),
                label: const Text('Track only'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Every vessel on the chart, with what it is and whether it is drawn.
Future<void> showVesselListSheet(
  BuildContext context, {
  required String stream,
  required List<VesselTrack> tracks,
  required Set<int> near,
  required void Function(VesselTrack) onFocus,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: identColors(context).surface,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.5,
      minChildSize: 0.3,
      maxChildSize: 0.92,
      builder: (_, scrollController) => _VesselList(
        stream: stream,
        tracks: tracks,
        near: near,
        onFocus: onFocus,
        scrollController: scrollController,
      ),
    ),
  );
}

class _VesselList extends ConsumerWidget {
  const _VesselList({
    required this.stream,
    required this.tracks,
    required this.near,
    required this.onFocus,
    required this.scrollController,
  });

  final String stream;
  final List<VesselTrack> tracks;
  final Set<int> near;
  final void Function(VesselTrack) onFocus;
  final ScrollController scrollController;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = identColors(context);
    final view = ref.watch(aisViewProvider(stream));
    final notifier = ref.read(aisViewProvider(stream).notifier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 12, 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Vessels',
                  style: TextStyle(
                    color: palette.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              TextButton(
                onPressed: notifier.showAll,
                child: const Text('All'),
              ),
              TextButton(
                onPressed: () =>
                    notifier.hideAll(tracks.map((t) => t.mmsi)),
                child: const Text('Clear'),
              ),
            ],
          ),
        ),
        if (view.isolatedMmsi != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Showing one vessel only.',
                    style: TextStyle(
                      color: palette.warn,
                      fontSize: 12,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => notifier.isolate(null),
                  child: const Text('Show all'),
                ),
              ],
            ),
          ),
        Expanded(
          child: ListView.builder(
            controller: scrollController,
            itemCount: tracks.length,
            itemBuilder: (_, i) {
              final t = tracks[i];
              final visible = view.visible(t.mmsi);
              return ListTile(
                dense: true,
                leading: _Swatch(colour: t.colour),
                title: Text(
                  t.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    // The web map flags vessels that came within 5 km of the
                    // sensor; those are the ones a detection could be about.
                    color: near.contains(t.mmsi)
                        ? palette.accent
                        : palette.textPrimary,
                    fontSize: 13.5,
                    fontWeight: near.contains(t.mmsi)
                        ? FontWeight.w600
                        : FontWeight.w400,
                  ),
                ),
                subtitle: Text(
                  [
                    if (t.vessel.type != null) t.vessel.type!,
                    '${t.fixes.length} fix${t.fixes.length == 1 ? '' : 'es'}',
                  ].join(' · '),
                  style: TextStyle(
                    color: palette.textSecondary,
                    fontSize: 11.5,
                  ),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.filter_alt_outlined, size: 18),
                      color: view.isolatedMmsi == t.mmsi
                          ? palette.accent
                          : palette.textSecondary,
                      tooltip: 'Track only',
                      onPressed: () => notifier.isolate(
                        view.isolatedMmsi == t.mmsi ? null : t.mmsi,
                      ),
                    ),
                    Switch.adaptive(
                      value: visible,
                      onChanged: (_) => notifier.toggleVisible(t.mmsi),
                    ),
                  ],
                ),
                onTap: () {
                  notifier.select(t.mmsi);
                  Navigator.of(context).pop();
                  onFocus(t);
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.colour});

  final Color colour;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        color: colour,
        borderRadius: BorderRadius.circular(3),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final palette = identColors(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 82,
            child: Text(
              label,
              style: TextStyle(
                color: palette.textSecondary,
                fontSize: 12.5,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: palette.textPrimary,
                fontSize: 12.5,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
