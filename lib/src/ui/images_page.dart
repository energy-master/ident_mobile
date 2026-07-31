/// Live images — the stream's spectrograms.
///
/// Opens on whatever recording the application clock is at — the newest one
/// while the clock is live, and the recording covering that moment once
/// something has moved it. There is no intermediate file list: the viewer's
/// thumbnail strip is the list, always in view, so reaching a recording never
/// costs a screen transition.
///
/// **The window comes back to where the app is, not to the newest file.** This
/// window is torn down whenever it is swiped off screen, and it used to rebuild
/// on the newest recording every time — so choosing a detection, swiping to the
/// AIS chart and swiping back landed the operator somewhere they had not asked
/// to be, silently. It now rebuilds on the clock, which is the same moment
/// every other window is showing.
///
/// The filters choose what the strip contains:
///   Live        every recording, following new arrivals as they land.
///   Decisions   only recordings a model actually fired on.
///   Favourites  only starred recordings.
///
/// Live is also the way back. It is highlighted only while the app is actually
/// on live data, so the moment anything pins the clock the highlight goes out —
/// which is the only indication the operator gets that the app has stopped
/// following the feed, and tapping it is what returns them.
///
/// Nothing is decoded on the handset: the images are the PNG snapshots the
/// Brahma service renders server-side, which is what makes a stream of
/// thousands of recordings usable on a phone.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models.dart';
import '../providers.dart';
import '../stream_clock.dart';
import '../theme.dart';
import 'file_viewer.dart';

enum FeedMode { live, decisions, favourites }

/// How often the live view looks for new recordings. The acoustic feed drops a
/// file every ~15 min, so this is unhurried on purpose — it exists to catch new
/// arrivals, not to poll aggressively.
const _liveRefresh = Duration(minutes: 1);

class ImagesPage extends ConsumerStatefulWidget {
  const ImagesPage({super.key, required this.stream});

  final String stream;

  @override
  ConsumerState<ImagesPage> createState() => _ImagesPageState();
}

class _ImagesPageState extends ConsumerState<ImagesPage> with WidgetsBindingObserver {
  FeedMode _mode = FeedMode.live;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _syncPolling();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    super.dispose();
  }

  /// A backgrounded phone has nobody watching the feed, and every poll re-reads
  /// the whole folder — thousands of recordings for the larger streams. Matches
  /// what the stream list already does with its diagnostics poll.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _syncPolling();
      ref.invalidate(streamFilesProvider(widget.stream));
    } else {
      _poll?.cancel();
    }
  }

  /// Only a live clock polls; sitting at a moment in history has nothing to
  /// wait for.
  ///
  /// The test is inside the tick rather than around the timer because the clock
  /// can be pinned and unpinned from four other places — a detection, an AIS
  /// fix, the Live filter, the strip itself — and a timer that had to be torn
  /// down and rebuilt from each of them is a timer that eventually leaks or
  /// stops. A tick that reads the clock and returns costs nothing.
  void _syncPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(_liveRefresh, (_) {
      if (!mounted) return;
      if (!ref.read(streamClockProvider(widget.stream)).isLive) return;
      ref.invalidate(streamFilesProvider(widget.stream));
    });
  }

  void handleModeChanged(FeedMode mode) {
    setState(() => _mode = mode);
  }

  /// Back to the live feed: the newest recording, following new arrivals.
  ///
  /// Both halves matter. Returning the clock alone would leave a strip still
  /// filtered to favourites claiming to be live, and switching the filter alone
  /// would leave the app pinned to whatever moment it had been dropped at.
  void handleGoLive() {
    ref.read(streamClockProvider(widget.stream).notifier).goLive();
    handleModeChanged(FeedMode.live);
  }

  void handleRefresh() {
    // An explicit refresh is also the one moment to re-ask for snapshots this
    // folder had none of: they are built server-side and can appear at any
    // time, so the "no snapshot" verdicts must not outlive a deliberate reload.
    ref.read(missingThumbsProvider).clear(widget.stream);
    ref.invalidate(streamFilesProvider(widget.stream));
    ref.read(favouritesProvider(widget.stream).notifier).load();
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(streamFilesProvider(widget.stream));
    final favourites = ref.watch(favouritesProvider(widget.stream)).valueOrNull ?? const <String>{};
    final counts = ref.watch(decisionCountsProvider(widget.stream)).valueOrNull ?? const <String, int>{};
    final clock = ref.watch(streamClockProvider(widget.stream));

    // Landscape is where the spectrogram earns its space, so the filter row
    // steps out of the way. The mode still applies — it just isn't adjustable
    // until the phone comes back to portrait.
    final isPortrait = MediaQuery.orientationOf(context) == Orientation.portrait;

    return Column(
      children: [
        if (isPortrait)
          _ModeSelector(
            mode: _mode,
            isLive: clock.isLive,
            onChanged: handleModeChanged,
            onGoLive: handleGoLive,
            onRefresh: handleRefresh,
          ),
        Expanded(
          child: switch (async) {
            AsyncData(:final value) when value.isEmpty => const _Empty(),
            AsyncData(:final value) => _buildViewer(value, favourites, counts, clock),
            AsyncError(:final error) => _Error(message: '$error', onRetry: handleRefresh),
            _ => const Center(child: CircularProgressIndicator()),
          },
        ),
      ],
    );
  }

  Widget _buildViewer(
    List<StreamFile> all,
    Set<String> favourites,
    Map<String, int> counts,
    StreamClock clock,
  ) {
    final files = switch (_mode) {
      FeedMode.favourites =>
        all.where((f) => favourites.contains(f.name)).toList(growable: false),
      FeedMode.decisions =>
        all.where((f) => (counts[f.name] ?? 0) > 0).toList(growable: false),
      FeedMode.live => all,
    };

    // A recording another window asked for that this filter hides would land
    // nowhere: the viewer cannot scroll to a file that is not in its list, and
    // the request would sit unconsumed while the user looked at the wrong
    // recording. The filter steps aside instead — the request was explicit, the
    // filter was not.
    final focus = ref.watch(fileFocusRequestProvider(widget.stream));
    if (focus != null &&
        _mode != FeedMode.live &&
        !files.any((f) => f.name == focus) &&
        all.any((f) => f.name == focus)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) handleModeChanged(FeedMode.live);
      });
    }

    // Neither filter is restricted to what is on screen, so an empty result is
    // a normal state rather than a data problem — say which filter emptied it.
    if (files.isEmpty) return _FilterEmpty(mode: _mode);

    // One key per mode, and nothing in it that changes as recordings arrive.
    //
    // Live used to key on the newest filename so a new arrival re-mounted the
    // viewer onto it. That worked, but it rebuilt several thousand strip cells
    // and restarted every thumbnail request once a minute, forever. The viewer
    // now follows new arrivals itself (see FileViewer.didUpdateWidget), so the
    // key only has to change when the *contents* mean something different —
    // which is when the filter changes.
    //
    // The clock is deliberately not in the key. It moves far more often than
    // the filter does, and remounting the viewer for each move would throw away
    // the strip and every thumbnail request in flight to achieve what
    // FileViewer._followClock does by scrolling.
    final key = switch (_mode) {
      FeedMode.live => const ValueKey('live'),
      FeedMode.decisions => const ValueKey('decisions'),
      FeedMode.favourites => const ValueKey('favourites'),
    };

    return FileViewer(
      key: key,
      folder: widget.stream,
      files: files,
      // Where the app already is. This is the whole of the "swiping back goes
      // to the latest file" fix: the window is rebuilt from scratch on every
      // swipe, so its opening position *is* its position.
      initialIndex: clockFileIndex(
        files,
        clock,
        ref.watch(fileDurationsProvider(widget.stream)),
      ),
      // Following new arrivals is what live means, in whichever filter.
      pinToNewest: clock.isLive,
    );
  }
}

/// The three filters, plus the way back to live.
///
/// Chips rather than a `SegmentedButton`, which is what this was. A segmented
/// button owns its selection: it cannot show none of its segments chosen
/// without `emptySelectionAllowed`, and that flag also makes tapping the
/// highlighted segment *deselect* it and report an empty set — so the one thing
/// this row has to express, "the app is off live", would have cost the ability
/// to tell which chip had been tapped. Chips carry their own selected state and
/// always report their own identity, and they match the AIS window's range
/// chips, which are the same kind of control one screen away.
///
/// The icons echo marks used elsewhere: the green dot matches the AIS live
/// chip, the red dot matches the decision marker on the thumbnail strip, the
/// star matches the favourite marker.
class _ModeSelector extends StatelessWidget {
  const _ModeSelector({
    required this.mode,
    required this.isLive,
    required this.onChanged,
    required this.onGoLive,
    required this.onRefresh,
  });

  final FeedMode mode;

  /// Whether the application clock is still following live data.
  final bool isLive;

  final ValueChanged<FeedMode> onChanged;
  final VoidCallback onGoLive;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 5, 4, 5),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0x1FFFFFFF))),
      ),
      child: Row(
        children: [
          Expanded(
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                _FilterChip(
                  label: 'Live',
                  icon: Icons.circle,
                  iconSize: 8,
                  // Live is the one chip whose highlight answers a question
                  // about the clock rather than about the filter: anything that
                  // moves the app off the newest data puts it out, wherever the
                  // strip happens to be filtered.
                  selected: isLive && mode == FeedMode.live,
                  selectedColour: IdentColors.ok,
                  tooltip: isLive
                      ? 'Live — following the newest recording'
                      : 'Back to live',
                  onTap: onGoLive,
                ),
                _FilterChip(
                  label: 'Decisions',
                  icon: Icons.fiber_manual_record,
                  iconSize: 9,
                  selected: mode == FeedMode.decisions,
                  tooltip: 'Only recordings with detections',
                  onTap: () => onChanged(FeedMode.decisions),
                ),
                _FilterChip(
                  label: 'Favourites',
                  icon: Icons.star,
                  iconSize: 11,
                  selected: mode == FeedMode.favourites,
                  tooltip: 'Only starred recordings',
                  onTap: () => onChanged(FeedMode.favourites),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            iconSize: 20,
            tooltip: 'Refresh',
            onPressed: onRefresh,
          ),
        ],
      ),
    );
  }
}

/// One filter chip, styled to match the AIS window's range chips.
class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.icon,
    required this.iconSize,
    required this.selected,
    required this.tooltip,
    required this.onTap,
    this.selectedColour = IdentColors.accent,
  });

  final String label;
  final IconData icon;
  final double iconSize;
  final bool selected;
  final String tooltip;
  final VoidCallback onTap;
  final Color selectedColour;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        avatar: Icon(
          icon,
          size: iconSize,
          // Against the chip's own fill once selected, and in its own right
          // when not — the green dot has to keep reading as "running" from
          // either side.
          color: selected ? IdentColors.shell : selectedColour,
        ),
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        labelStyle: TextStyle(
          fontSize: 11,
          color: selected ? IdentColors.shell : IdentColors.textSecondary,
        ),
        selectedColor: selectedColour,
        backgroundColor: IdentColors.surfaceRaised,
        side: BorderSide.none,
        showCheckmark: false,
        // Always fires, selected or not: tapping Live while it is already lit
        // means "get me back to now", the same way the AIS live chip re-asks.
        onSelected: (_) => onTap(),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.image_outlined, size: 44, color: IdentColors.idle),
            SizedBox(height: 14),
            Text(
              'No recordings in this stream folder yet.',
              textAlign: TextAlign.center,
              style: TextStyle(color: IdentColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

/// Says which filter emptied the view, so it never reads as missing data.
class _FilterEmpty extends StatelessWidget {
  const _FilterEmpty({required this.mode});

  final FeedMode mode;

  @override
  Widget build(BuildContext context) {
    final (icon, message) = switch (mode) {
      FeedMode.favourites => (
          Icons.star_border,
          'No favourites yet.\nTap the star on a recording to keep it here.',
        ),
      FeedMode.decisions => (
          Icons.fiber_manual_record_outlined,
          'No recordings have detections yet.\n'
              'They appear here once a subscribed model fires.',
        ),
      _ => (Icons.image_outlined, 'Nothing to show.'),
    };

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: IdentColors.idle),
            const SizedBox(height: 14),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: IdentColors.textSecondary),
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
