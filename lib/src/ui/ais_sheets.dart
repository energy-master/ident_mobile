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
import '../theme.dart';
import '../time_format.dart';

/// Details of one AIS fix, and what can be done from it.
Future<void> showFixDetailSheet(
  BuildContext context, {
  required String stream,
  required VesselTrack track,
  required int fixIndex,
  required bool popMapAfterNavigate,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: IdentColors.surface,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _FixDetail(
      stream: stream,
      track: track,
      fix: track.fixes[fixIndex],
      popMapAfterNavigate: popMapAfterNavigate,
    ),
  );
}

class _FixDetail extends ConsumerStatefulWidget {
  const _FixDetail({
    required this.stream,
    required this.track,
    required this.fix,
    required this.popMapAfterNavigate,
  });

  final String stream;
  final VesselTrack track;
  final TrackPoint fix;
  final bool popMapAfterNavigate;

  @override
  ConsumerState<_FixDetail> createState() => _FixDetailState();
}

class _FixDetailState extends ConsumerState<_FixDetail> {
  bool _seeking = false;

  Vessel get _vessel => widget.track.vessel;

  /// Move the Live images window to the recording covering this fix.
  ///
  /// The dashboard listens on [fileFocusRequestProvider] and swipes itself back
  /// to the viewer, which is the same route `decisions_page.dart` takes to get
  /// from a detection to its recording.
  Future<void> _goToThisTime() async {
    // Captured before the await and before any pop: this sheet is gone by the
    // time the second pop runs, so its context cannot be used to find them.
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);

    setState(() => _seeking = true);
    try {
      final files = await ref.read(streamFilesProvider(widget.stream).future);
      if (!mounted) return;
      final durations = ref.read(fileDurationsProvider(widget.stream));
      final file = recordingAt(widget.fix.time, files, durations);

      if (file == null) {
        // Real, not defensive: in the wider history ranges a fix can easily
        // predate the oldest recording still on disk.
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              'No recording covers ${formatUtcTimeOnly(widget.fix.time)} UTC.',
            ),
          ),
        );
        return;
      }

      ref.read(fileFocusRequestProvider(widget.stream).notifier).state =
          file.name;
      navigator.pop();
      // Leaving the full-screen map open would hide the window we just asked to
      // move, so the jump would look like nothing happened.
      if (widget.popMapAfterNavigate) navigator.pop();
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
                  style: const TextStyle(
                    color: IdentColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                'MMSI ${_vessel.mmsi}',
                style: const TextStyle(
                  color: IdentColors.textSecondary,
                  fontSize: 11.5,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          if (identity.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              identity,
              style: const TextStyle(
                color: IdentColors.textSecondary,
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
    backgroundColor: IdentColors.surface,
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
    final view = ref.watch(aisViewProvider(stream));
    final notifier = ref.read(aisViewProvider(stream).notifier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 12, 6),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'Vessels',
                  style: TextStyle(
                    color: IdentColors.textPrimary,
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
                const Expanded(
                  child: Text(
                    'Showing one vessel only.',
                    style: TextStyle(
                      color: IdentColors.warn,
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
                        ? IdentColors.accent
                        : IdentColors.textPrimary,
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
                  style: const TextStyle(
                    color: IdentColors.textSecondary,
                    fontSize: 11.5,
                  ),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.filter_alt_outlined, size: 18),
                      color: view.isolatedMmsi == t.mmsi
                          ? IdentColors.accent
                          : IdentColors.textSecondary,
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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 82,
            child: Text(
              label,
              style: const TextStyle(
                color: IdentColors.textSecondary,
                fontSize: 12.5,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                color: IdentColors.textPrimary,
                fontSize: 12.5,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
