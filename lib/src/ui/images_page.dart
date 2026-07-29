/// Live images — the stream's spectrograms.
///
/// Opens straight onto the newest recording. There is no intermediate file
/// list: the viewer's thumbnail strip is the list, always in view, so reaching
/// a recording never costs a screen transition.
///
/// The selector chooses what the strip contains and where it starts:
///   Live        every recording, pinned to the newest — and it re-pins on its
///               own as new recordings arrive.
///   All         every recording, starting at the newest, then free to browse.
///   Active      only recordings a model actually fired on.
///   Favourites  only starred recordings.
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
import '../theme.dart';
import 'file_viewer.dart';

enum FeedMode { live, all, active, favourites }

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

class _ImagesPageState extends ConsumerState<ImagesPage> {
  FeedMode _mode = FeedMode.live;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _syncPolling();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  /// Only the live view polls; browsing history has nothing to wait for.
  void _syncPolling() {
    _poll?.cancel();
    if (_mode != FeedMode.live) return;
    _poll = Timer.periodic(_liveRefresh, (_) {
      if (mounted) ref.invalidate(streamFilesProvider(widget.stream));
    });
  }

  void handleModeChanged(FeedMode mode) {
    setState(() => _mode = mode);
    _syncPolling();
  }

  void handleRefresh() {
    ref.invalidate(streamFilesProvider(widget.stream));
    ref.read(favouritesProvider(widget.stream).notifier).load();
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(streamFilesProvider(widget.stream));
    final favourites = ref.watch(favouritesProvider(widget.stream)).valueOrNull ?? const <String>{};
    final counts = ref.watch(decisionCountsProvider(widget.stream)).valueOrNull ?? const <String, int>{};

    return Column(
      children: [
        _ModeSelector(
          mode: _mode,
          onChanged: handleModeChanged,
          onRefresh: handleRefresh,
        ),
        Expanded(
          child: switch (async) {
            AsyncData(:final value) when value.isEmpty => const _Empty(),
            AsyncData(:final value) => _buildViewer(value, favourites, counts),
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
  ) {
    final files = switch (_mode) {
      FeedMode.favourites =>
        all.where((f) => favourites.contains(f.name)).toList(growable: false),
      FeedMode.active =>
        all.where((f) => (counts[f.name] ?? 0) > 0).toList(growable: false),
      _ => all,
    };

    // Neither filter is restricted to what is on screen, so an empty result is
    // a normal state rather than a data problem — say which filter emptied it.
    if (files.isEmpty) return _FilterEmpty(mode: _mode);

    // The key decides when the viewer restarts at the newest recording.
    //
    // In Live it includes the newest filename, so the arrival of a new
    // recording re-mounts the viewer onto it — that is what makes it live.
    // In All and Favourites the key is stable, so a refresh in the background
    // never yanks the user away from the recording they are reading.
    final key = switch (_mode) {
      FeedMode.live => ValueKey('live-${files.first.name}'),
      FeedMode.all => const ValueKey('all'),
      FeedMode.active => const ValueKey('active'),
      FeedMode.favourites => const ValueKey('favourites'),
    };

    return FileViewer(
      key: key,
      folder: widget.stream,
      files: files,
      initialIndex: 0,
    );
  }
}

/// Icons only, so four filters cost one compact row rather than a band of text
/// across the top of a screen whose whole point is the image below it. Each
/// carries a tooltip, and the icons echo marks used elsewhere: the star matches
/// the favourite marker, the filled dot matches the red decision dot on the
/// thumbnail strip.
class _ModeSelector extends StatelessWidget {
  const _ModeSelector({
    required this.mode,
    required this.onChanged,
    required this.onRefresh,
  });

  final FeedMode mode;
  final ValueChanged<FeedMode> onChanged;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0x1FFFFFFF))),
      ),
      child: Row(
        children: [
          SegmentedButton<FeedMode>(
            segments: const [
              ButtonSegment(
                value: FeedMode.live,
                icon: Icon(Icons.sensors, size: 17),
                tooltip: 'Live — newest recording',
              ),
              ButtonSegment(
                value: FeedMode.all,
                icon: Icon(Icons.view_carousel_outlined, size: 17),
                tooltip: 'All recordings',
              ),
              ButtonSegment(
                value: FeedMode.active,
                icon: Icon(Icons.fiber_manual_record, size: 15),
                tooltip: 'Active — recordings with detections',
              ),
              ButtonSegment(
                value: FeedMode.favourites,
                icon: Icon(Icons.star, size: 17),
                tooltip: 'Favourites',
              ),
            ],
            selected: {mode},
            onSelectionChanged: (s) => onChanged(s.first),
            showSelectedIcon: false,
            style: const ButtonStyle(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
          const Spacer(),
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
      FeedMode.active => (
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
