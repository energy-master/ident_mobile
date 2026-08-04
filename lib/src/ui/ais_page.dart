/// AIS — vessel traffic at the application clock.
///
/// The map is tied to the moment the app is at: the recording covering the
/// clock is the window it plots, so you see the vessels that were present
/// *while that recording was made*. That framing is the point. A live snapshot
/// would answer "what is out there now", which tells you nothing about a
/// detection from three days ago.
///
/// **`Live` here is not the clock's live.** The AIS poller and the acoustic
/// feed are separate pipelines that land at different times, so the newest fix
/// and the newest recording are rarely the same moment. This window's `Live`
/// range means the newest AIS, and the two are deliberately left unlinked: an
/// operator who has asked for current traffic keeps it, whatever the clock is
/// doing, and the header always says which range is in force.
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
import 'maximised_panel.dart';

/// Fallback span for a recording whose duration could not be estimated.
const _assumedDuration = Duration(minutes: 15);

/// The span actually plotted, which in the wider ranges is not the recording's.
///
/// Taken from the fixes themselves rather than from the query: `All` has no
/// window to quote, and a windowed query returns whatever the poller happened to
/// log inside it, which is usually narrower than what was asked for. Falls back
/// to the recording's span when nothing came back, so the header still says
/// which recording produced the empty answer.
/// The date is always carried, because this page is as often used on archive
/// material as on today's traffic: a bare `13:24:08 – 13:29:08` invites the
/// reader to assume it means today, and the whole point of the window is that it
/// usually does not.
String aisSpanLabel(List<Vessel>? vessels, DateTime start, DateTime end) {
  final all = [for (final v in vessels ?? const <Vessel>[]) ...v.track];
  if (all.isEmpty) return '${formatUtcDate(start)} · ${formatTimeSpan(start, end)}';

  var first = all.first.t;
  var last = all.first.t;
  for (final p in all) {
    if (p.t < first) first = p.t;
    if (p.t > last) last = p.t;
  }
  final a = DateTime.fromMillisecondsSinceEpoch(first, isUtc: true);
  final b = DateTime.fromMillisecondsSinceEpoch(last, isUtc: true);

  // Once the span crosses into another day, one date at the front would be
  // wrong for half of what is drawn, so both ends carry their own.
  final sameDay = a.year == b.year && a.month == b.month && a.day == b.day;
  return sameDay
      ? '${formatUtcDate(a)} · ${formatTimeSpan(a, b)}'
      : '${formatUtcShortWithYear(a)} – ${formatUtcShortWithYear(b)} UTC';
}

/// What came back, and whether the map is drawing all of it.
String aisCountLabel(List<Vessel>? vessels, AisHistory history) {
  if (vessels == null) return 'Loading vessels…';
  if (vessels.isEmpty) {
    return switch (history) {
      AisHistory.all => 'No AIS logged for this sensor',
      AisHistory.live => 'Nothing reporting in the last hour',
      _ => 'No vessels logged in this range',
    };
  }
  final moving = vessels.where((v) => v.isMoving).length;
  // Silence about a cap would read as "this is everything".
  final capped = vessels.length > maxDrawnVessels
      ? ' · drawing the $maxDrawnVessels nearest'
      : '';
  return '${vessels.length} vessel${vessels.length == 1 ? '' : 's'} · '
      '$moving moving$capped';
}

class AisPage extends ConsumerStatefulWidget {
  const AisPage({
    super.key,
    required this.stream,
    this.fullGestureMap = false,
  });

  final String stream;

  /// True when this page owns its whole route — every gesture reaches the map
  /// (one-finger pan included) and the expand button is hidden, because the
  /// map is already at its largest.
  ///
  /// The dashboard's embedded AIS window leaves this false: a one-finger swipe
  /// belongs to the ring, not to the map.
  final bool fullGestureMap;

  @override
  ConsumerState<AisPage> createState() => _AisPageState();
}

class _AisPageState extends ConsumerState<AisPage> {
  /// The last vessels drawn, held across a refresh of the same view.
  ///
  /// The live range refetches every minute, and each fetch is a different
  /// provider key, so without this the map would be torn down and replaced by a
  /// spinner once a minute — losing the camera, the selection and any sense that
  /// this is one chart updating rather than four charts a minute.
  List<Vessel>? _lastVessels;

  /// What [_lastVessels] belongs to. When this changes the held data is stale in
  /// a way a refresh is not: a different recording's traffic is a different
  /// answer, not a newer one, and showing it briefly would be wrong.
  Object? _lastKey;

  @override
  Widget build(BuildContext context) {
    final stream = widget.stream;
    final view = ref.watch(aisViewProvider(stream));
    final live = view.history == AisHistory.live;
    final active = ref.watch(activeFileProvider(stream));

    // Live is the one range that does not need a recording: "what is out there
    // now" stands on its own.
    if (active == null && !live) {
      // Distinguish "nothing to anchor to" from "not read the folder yet".
      // The clock resolves against the file listing, so while that is in flight
      // there is no recording — which is a wait, not an answer.
      if (ref.watch(streamFilesProvider(stream)).isLoading) {
        return const Center(child: CircularProgressIndicator());
      }
      return _NoRecordingAtClock(
        onShowLive: () =>
            ref.read(aisViewProvider(stream).notifier).setHistory(AisHistory.live),
      );
    }

    // This recording's own duration, not the folder's — folders mix lengths,
    // and querying AIS over 5 minutes for a 5-second recording would show
    // traffic that was never there while it was recording.
    final durationMs = active == null
        ? null
        : ref.watch(fileDurationsProvider(stream))[active.name];
    final now = DateTime.now().toUtc();
    final start = active?.startTime ?? now;
    final length = durationMs != null
        ? Duration(milliseconds: durationMs)
        : (active == null ? Duration.zero : _assumedDuration);
    final end = start.add(length);

    // Watching the tick only in the live range is what moves "now" on, and so
    // what refetches. Nothing is running in the other ranges.
    if (live) ref.watch(aisLiveTickProvider);

    // Widen for a recording too short to hold a track, unless the operator has
    // already made the choice themselves. Deferred out of build: writing to a
    // provider mid-build is exactly the reentrancy Riverpod forbids.
    final autoWiden =
        active != null && shouldAutoWiden(length) && !view.historyChosen;
    if (autoWiden && view.history == AisHistory.recording) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref
            .read(aisViewProvider(stream).notifier)
            .setHistory(AisHistory.aroundRecording, byUser: false);
      });
    }

    final q = aisQueryFor(view.history, start, end, now: now);
    final query = (stream: stream, from: q.from, to: q.to, all: q.all);
    final sensor = ref.watch(sensorProvider(stream)).valueOrNull;
    final vessels = ref.watch(vesselsProvider(query));

    // The camera follows this, not the data: a live refresh must not drag the
    // chart back to its default framing every minute.
    // The recording is deliberately not part of the live key: scrubbing through
    // recordings in the images window must not reset a live chart, which is not
    // showing them anyway.
    final viewKey = (stream, view.history, live ? null : active?.name);
    if (_lastKey != viewKey) {
      _lastKey = viewKey;
      _lastVessels = null;
    }
    if (vessels.hasValue) _lastVessels = vessels.value;

    final drawn = vessels.valueOrNull ?? _lastVessels;

    return Column(
      children: [
        _Header(
          stream: stream,
          start: start,
          end: end,
          length: length,
          history: view.history,
          autoWidened: autoWiden,
          refreshing: live && vessels.isLoading,
          onRefresh: () => ref.invalidate(vesselsProvider(query)),
          vessels: drawn,
        ),
        Expanded(
          child: switch (vessels) {
            _ when drawn != null => AisMap(
                // Keyed by stream so swapping streams builds a fresh map rather
                // than animating one sensor's camera to another's.
                key: ValueKey(stream),
                stream: stream,
                vessels: drawn,
                sensor: sensor,
                recordingStart: start,
                recordingEnd: end,
                fullScreen: widget.fullGestureMap,
                refitKey: viewKey,
                // In the max screen the expand button is redundant — the map
                // is already at its largest — so it is hidden by leaving
                // onExpand null. See AisMap: the button only draws when
                // onExpand is non-null and the map is not itself full-screen.
                onExpand: widget.fullGestureMap
                    ? null
                    : () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => MaximisedPanelScreen(
                              stream: stream,
                              initial: DashboardPanel.ais,
                            ),
                          ),
                        ),
              ),
            AsyncError(:final error) => _Error(
                message: '$error',
                onRetry: () => ref.invalidate(vesselsProvider(query)),
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
    required this.refreshing,
    required this.onRefresh,
    required this.vessels,
  });

  final String stream;
  final DateTime start;
  final DateTime end;
  final Duration length;
  final AisHistory history;
  final bool autoWidened;

  /// A live refresh is in flight over data already on screen.
  final bool refreshing;

  /// Re-ask the server for the range currently shown.
  final VoidCallback onRefresh;

  final List<Vessel>? vessels;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = identColors(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
      decoration: BoxDecoration(
        color: palette.surface,
        border: const Border(bottom: BorderSide(color: Color(0x1FFFFFFF))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  aisSpanLabel(vessels, start, end),
                  style: TextStyle(
                    color: palette.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              if (refreshing)
                const Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 1.6),
                  ),
                ),
            ],
          ),
          Text(
            aisCountLabel(vessels, history),
            style: TextStyle(
              color: palette.textSecondary,
              fontSize: 11.5,
            ),
          ),
          const SizedBox(height: 6),
          _HistoryChips(
            stream: stream,
            history: history,
            onRefresh: onRefresh,
          ),
          if (history == AisHistory.live)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Live: the last hour, refreshed every minute.',
                style: TextStyle(color: palette.ok, fontSize: 10.5),
              ),
            ),
          if (autoWidened)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Widened: a ${formatDuration(length)} recording is shorter '
                'than one AIS report.',
                style: TextStyle(
                  color: palette.warn,
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
  const _HistoryChips({
    required this.stream,
    required this.history,
    required this.onRefresh,
  });

  final String stream;
  final AisHistory history;

  /// Re-ask the server for the range currently shown.
  final VoidCallback onRefresh;

  static const _labels = {
    AisHistory.recording: 'Recording',
    AisHistory.aroundRecording: '±1 h',
    AisHistory.live: 'Live',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = identColors(context);
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        for (final entry in _labels.entries)
          ChoiceChip(
            label: Text(entry.value),
            selected: history == entry.key,
            avatar: entry.key == AisHistory.live
                ? Icon(
                    Icons.circle,
                    size: 8,
                    // Green reads as "this is running", which is the one thing
                    // that separates this range from the other three.
                    color: history == entry.key
                        ? palette.shell
                        : palette.ok,
                  )
                : null,
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            labelStyle: TextStyle(
              fontSize: 11,
              color: history == entry.key
                  ? palette.shell
                  : palette.textSecondary,
            ),
            selectedColor: entry.key == AisHistory.live
                ? palette.ok
                : palette.accent,
            backgroundColor: palette.surfaceRaised,
            side: BorderSide.none,
            showCheckmark: false,
            onSelected: (_) {
              ref.read(aisViewProvider(stream).notifier).setHistory(entry.key);
              // Tapping Live again means "get me the newest", so it re-asks
              // rather than doing nothing because the range already matches.
              if (entry.key == AisHistory.live && history == AisHistory.live) {
                onRefresh();
              }
            },
          ),
      ],
    );
  }
}

/// No recording covers where the app currently is.
///
/// Either the folder holds none at all, or the clock is sitting further from
/// every recording than `recordingSearchTolerance` allows — which happens on
/// archive streams whose files have rolled off since the AIS was logged.
class _NoRecordingAtClock extends StatelessWidget {
  const _NoRecordingAtClock({required this.onShowLive});

  final VoidCallback onShowLive;

  @override
  Widget build(BuildContext context) {
    final palette = identColors(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.map_outlined, size: 44, color: palette.idle),
            const SizedBox(height: 14),
            Text(
              'No recording covers the time the app is at.\n'
              'Choose one in Live images and the map shows the vessels '
              'present while it was recorded.',
              textAlign: TextAlign.center,
              style: TextStyle(color: palette.textSecondary),
            ),
            const SizedBox(height: 18),
            // The one view that stands without a recording, so it is offered
            // here rather than left behind a selection the operator may not
            // want to make.
            FilledButton.tonalIcon(
              onPressed: onShowLive,
              icon: Icon(Icons.circle, size: 10, color: palette.ok),
              label: const Text('Show live traffic'),
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
    final palette = identColors(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, size: 44, color: palette.idle),
            const SizedBox(height: 14),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: palette.textSecondary),
            ),
            const SizedBox(height: 18),
            FilledButton.tonal(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}
