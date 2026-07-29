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

enum FeedMode { live, all, favourites }

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

    return Column(
      children: [
        _ModeSelector(
          mode: _mode,
          favouriteCount: favourites.length,
          onChanged: handleModeChanged,
          onRefresh: handleRefresh,
        ),
        Expanded(
          child: switch (async) {
            AsyncData(:final value) when value.isEmpty => const _Empty(),
            AsyncData(:final value) => _buildViewer(value, favourites),
            AsyncError(:final error) => _Error(message: '$error', onRetry: handleRefresh),
            _ => const Center(child: CircularProgressIndicator()),
          },
        ),
      ],
    );
  }

  Widget _buildViewer(List<StreamFile> all, Set<String> favourites) {
    final files = _mode == FeedMode.favourites
        ? all.where((f) => favourites.contains(f.name)).toList(growable: false)
        : all;

    // Starring is not restricted to what is on screen, so an empty favourites
    // view is a normal state rather than a data problem — say so plainly.
    if (files.isEmpty) return const _NoFavourites();

    // The key decides when the viewer restarts at the newest recording.
    //
    // In Live it includes the newest filename, so the arrival of a new
    // recording re-mounts the viewer onto it — that is what makes it live.
    // In All and Favourites the key is stable, so a refresh in the background
    // never yanks the user away from the recording they are reading.
    final key = switch (_mode) {
      FeedMode.live => ValueKey('live-${files.first.name}'),
      FeedMode.all => const ValueKey('all'),
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

class _ModeSelector extends StatelessWidget {
  const _ModeSelector({
    required this.mode,
    required this.favouriteCount,
    required this.onChanged,
    required this.onRefresh,
  });

  final FeedMode mode;
  final int favouriteCount;
  final ValueChanged<FeedMode> onChanged;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0x1FFFFFFF))),
      ),
      child: Row(
        children: [
          Expanded(
            child: SegmentedButton<FeedMode>(
              segments: [
                const ButtonSegment(
                  value: FeedMode.live,
                  label: Text('Live'),
                  icon: Icon(Icons.sensors, size: 15),
                ),
                const ButtonSegment(
                  value: FeedMode.all,
                  label: Text('All'),
                  icon: Icon(Icons.view_carousel_outlined, size: 15),
                ),
                ButtonSegment(
                  value: FeedMode.favourites,
                  label: Text(favouriteCount > 0 ? 'Favourites ($favouriteCount)' : 'Favourites'),
                  icon: const Icon(Icons.star, size: 15),
                ),
              ],
              selected: {mode},
              onSelectionChanged: (s) => onChanged(s.first),
              showSelectedIcon: false,
              style: ButtonStyle(
                visualDensity: VisualDensity.compact,
                textStyle: WidgetStatePropertyAll(
                  Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 12),
                ),
              ),
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

class _NoFavourites extends StatelessWidget {
  const _NoFavourites();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.star_border, size: 44, color: IdentColors.idle),
            SizedBox(height: 14),
            Text(
              'No favourites yet.\nTap the star on a recording to keep it here.',
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
