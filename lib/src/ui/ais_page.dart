/// AIS — vessel traffic during the active recording.
///
/// The map is tied to whichever recording is selected in the Live images
/// window: swipe here after choosing a file and you see the vessels that were
/// present *while that recording was made*. That framing is the point. A live
/// snapshot would answer "what is out there now", which tells you nothing about
/// a detection from three days ago.
///
/// **The history range exists because the framing has a floor.** The AIS poller
/// logs a fix every half minute or so, and folders like `repmus25` are full of
/// five-second recordings. Asked strictly, "who was here during those five
/// seconds" returns at most one fix per vessel — no track, no course, no age —
/// on a stretch of water that may have been busy. So the window can be widened,
/// the header always says which range is in force, and the fixes that fall
/// inside the recording itself keep a white ring so the original question is
/// still answerable at a glance.
///
/// **Gesture handling.** This window lives inside a horizontally-swiping
/// dashboard, so one-finger panning is deliberately disabled: dragging west and
/// "go to the previous window" are the same gesture, and the map would eat every
/// swipe. Two fingers move and zoom the map in place, and the expand button
/// opens a full-screen map where all gestures are available because nothing is
/// competing for them.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ais_map_geometry.dart';
import '../models.dart';
import '../providers.dart';
import '../theme.dart';
import '../time_format.dart';
import 'ais_map.dart';

/// Fallback span for a recording whose duration could not be estimated.
const _assumedDuration = Duration(minutes: 15);

/// The span actually plotted, which in the wider ranges is not the recording's.
///
/// Taken from the fixes themselves rather than from the query: `All` has no
/// window to quote, and a windowed query returns whatever the poller happened to
/// log inside it, which is usually narrower than what was asked for. Falls back
/// to the recording's span when nothing came back, so the header still says
/// which recording produced the empty answer.
String aisSpanLabel(List<Vessel>? vessels, DateTime start, DateTime end) {
  final all = [for (final v in vessels ?? const <Vessel>[]) ...v.track];
  if (all.isEmpty) return formatTimeSpan(start, end);

  var first = all.first.t;
  var last = all.first.t;
  for (final p in all) {
    if (p.t < first) first = p.t;
    if (p.t > last) last = p.t;
  }
  final a = DateTime.fromMillisecondsSinceEpoch(first, isUtc: true);
  final b = DateTime.fromMillisecondsSinceEpoch(last, isUtc: true);

  // Once the range crosses a day the time alone is ambiguous.
  return b.difference(a).inHours >= 12
      ? '${formatUtcShort(a)} – ${formatUtcShort(b)} UTC'
      : formatTimeSpan(a, b);
}

/// What came back, and whether the map is drawing all of it.
String aisCountLabel(List<Vessel>? vessels, AisHistory history) {
  if (vessels == null) return 'Loading vessels…';
  if (vessels.isEmpty) {
    return history == AisHistory.all
        ? 'No AIS logged for this sensor'
        : 'No vessels logged in this range';
  }
  final moving = vessels.where((v) => v.isMoving).length;
  // Silence about a cap would read as "this is everything".
  final capped = vessels.length > maxDrawnVessels
      ? ' · drawing the $maxDrawnVessels nearest'
      : '';
  return '${vessels.length} vessel${vessels.length == 1 ? '' : 's'} · '
      '$moving moving$capped';
}

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
    final length = durationMs != null
        ? Duration(milliseconds: durationMs)
        : _assumedDuration;
    final end = start.add(length);

    final view = ref.watch(aisViewProvider(stream));

    // Widen for a recording too short to hold a track, unless the operator has
    // already made the choice themselves. Deferred out of build: writing to a
    // provider mid-build is exactly the reentrancy Riverpod forbids.
    final autoWiden = shouldAutoWiden(length) && !view.historyChosen;
    if (autoWiden && view.history == AisHistory.recording) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref
            .read(aisViewProvider(stream).notifier)
            .setHistory(AisHistory.aroundRecording, byUser: false);
      });
    }

    final q = aisQueryFor(view.history, start, end);
    final sensor = ref.watch(sensorProvider(stream)).valueOrNull;
    final vessels = ref.watch(
      vesselsProvider((stream: stream, from: q.from, to: q.to, all: q.all)),
    );

    return Column(
      children: [
        _Header(
          stream: stream,
          start: start,
          end: end,
          length: length,
          history: view.history,
          autoWidened: autoWiden,
          vessels: vessels.valueOrNull,
        ),
        Expanded(
          child: switch (vessels) {
            AsyncData(:final value) => AisMap(
                // Keyed by stream so swapping streams builds a fresh map rather
                // than animating one sensor's camera to another's.
                key: ValueKey(stream),
                stream: stream,
                vessels: value,
                sensor: sensor,
                recordingStart: start,
                recordingEnd: end,
                fullScreen: false,
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
                  vesselsProvider(
                    (stream: stream, from: q.from, to: q.to, all: q.all),
                  ),
                ),
              ),
            _ => const Center(child: CircularProgressIndicator()),
          },
        ),
      ],
    );
  }
}

/// What is loaded, over what span, and how to change it.
class _Header extends ConsumerWidget {
  const _Header({
    required this.stream,
    required this.start,
    required this.end,
    required this.length,
    required this.history,
    required this.autoWidened,
    required this.vessels,
  });

  final String stream;
  final DateTime start;
  final DateTime end;
  final Duration length;
  final AisHistory history;
  final bool autoWidened;
  final List<Vessel>? vessels;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
            aisSpanLabel(vessels, start, end),
            style: const TextStyle(
              color: IdentColors.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          Text(
            aisCountLabel(vessels, history),
            style: const TextStyle(
              color: IdentColors.textSecondary,
              fontSize: 11.5,
            ),
          ),
          const SizedBox(height: 6),
          _HistoryChips(stream: stream, history: history),
          if (autoWidened)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Widened: a ${formatDuration(length)} recording is shorter '
                'than one AIS report.',
                style: const TextStyle(
                  color: IdentColors.warn,
                  fontSize: 10.5,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _HistoryChips extends ConsumerWidget {
  const _HistoryChips({required this.stream, required this.history});

  final String stream;
  final AisHistory history;

  static const _labels = {
    AisHistory.recording: 'Recording',
    AisHistory.aroundRecording: '±1 h',
    AisHistory.all: 'All',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Wrap(
      spacing: 6,
      children: [
        for (final entry in _labels.entries)
          ChoiceChip(
            label: Text(entry.value),
            selected: history == entry.key,
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            labelStyle: TextStyle(
              fontSize: 11,
              color: history == entry.key
                  ? IdentColors.shell
                  : IdentColors.textSecondary,
            ),
            selectedColor: IdentColors.accent,
            backgroundColor: IdentColors.surfaceRaised,
            side: BorderSide.none,
            showCheckmark: false,
            onSelected: (_) =>
                ref.read(aisViewProvider(stream).notifier).setHistory(entry.key),
          ),
      ],
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
      body: AisMap(
        stream: stream,
        vessels: vessels,
        sensor: sensor,
        recordingStart: start,
        recordingEnd: end,
        fullScreen: true,
      ),
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
