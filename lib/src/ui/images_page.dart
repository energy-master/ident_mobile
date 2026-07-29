/// Live data images — the stream's spectrogram waterfall.
///
/// One lane per recording, newest first, each showing the snapshot PNG the
/// Brahma service renders server-side (`api/idapi/stream_thumb.php`). Nothing is
/// decoded on the handset: no audio download, no STFT, no WebGL. That is what
/// makes a multi-thousand-recording stream scrollable on a phone.
///
/// Streams run to thousands of recordings, so the list is virtualised on a
/// fixed lane height. The fixed extent is also what makes the scrub bar exact —
/// index maps to scroll offset arithmetically rather than by measurement.
///
/// Two ways to move through time:
///   - the scrub rail down the right edge, which drags across the whole span
///     and shows the time under the thumb as you go;
///   - the date/time search in the app bar, which jumps to the nearest
///     recording to a chosen moment.
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models.dart';
import '../providers.dart';
import '../theme.dart';
import '../time_format.dart';

/// Height of one lane. Snapshots are rendered 200x64 (js/thumbnail.js), so a
/// ~3.1:1 image sits inside this with room for the time gutter.
const double _laneHeight = 92;

class ImagesPage extends ConsumerStatefulWidget {
  const ImagesPage({super.key, required this.stream});

  final String stream;

  @override
  ConsumerState<ImagesPage> createState() => _ImagesPageState();
}

class _ImagesPageState extends ConsumerState<ImagesPage> {
  final _scroll = ScrollController();

  /// Index under the scrub thumb, or the first visible lane when idle.
  int _cursor = 0;
  bool _scrubbing = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrubbing || !_scroll.hasClients) return;
    final index = (_scroll.position.pixels / _laneHeight).round();
    if (index != _cursor) setState(() => _cursor = index);
  }

  void _jumpToIndex(int index, {bool animate = false}) {
    if (!_scroll.hasClients) return;
    final target = (index * _laneHeight).clamp(
      _scroll.position.minScrollExtent,
      _scroll.position.maxScrollExtent,
    );
    if (animate) {
      _scroll.animateTo(
        target,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
    } else {
      _scroll.jumpTo(target);
    }
  }

  /// Pick a date and time, then land on the recording closest to it.
  ///
  /// "Closest" rather than "at or before" because a stream can have gaps; an
  /// exact-match rule would leave the user staring at an empty result when the
  /// nearest recording is a few minutes the wrong side of their choice.
  Future<void> handleSearch(List<StreamFile> files) async {
    if (files.isEmpty) return;

    final newest = recordingTime(files.first.name, files.first.modified);
    final oldest = recordingTime(files.last.name, files.last.modified);

    final date = await showDatePicker(
      context: context,
      initialDate: newest.toLocal(),
      firstDate: oldest.toLocal().subtract(const Duration(days: 1)),
      lastDate: newest.toLocal().add(const Duration(days: 1)),
      helpText: 'Jump to date',
    );
    if (date == null || !mounted) return;

    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(newest.toLocal()),
      helpText: 'Jump to time',
    );
    if (!mounted) return;

    // Times are chosen in the user's local zone but recordings are stamped UTC.
    final localTarget = DateTime(
      date.year,
      date.month,
      date.day,
      time?.hour ?? 0,
      time?.minute ?? 0,
    );
    final target = localTarget.toUtc();

    var bestIndex = 0;
    var bestDelta = Duration(days: 36500);
    for (var i = 0; i < files.length; i++) {
      final t = recordingTime(files[i].name, files[i].modified);
      final delta = (t.difference(target)).abs();
      if (delta < bestDelta) {
        bestDelta = delta;
        bestIndex = i;
      }
    }

    setState(() => _cursor = bestIndex);
    _jumpToIndex(bestIndex, animate: true);

    if (!mounted) return;
    final landed = recordingTime(files[bestIndex].name, files[bestIndex].modified);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Nearest recording: ${formatUtcStamp(landed)}')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(streamFilesProvider(widget.stream));

    return switch (async) {
      AsyncData(:final value) when value.isEmpty => const _Empty(),
      AsyncData(:final value) => _buildList(value),
      AsyncError(:final error) => _Error(
          message: '$error',
          onRetry: () async => ref.invalidate(streamFilesProvider(widget.stream)),
        ),
      _ => const Center(child: CircularProgressIndicator()),
    };
  }

  Widget _buildList(List<StreamFile> files) {
    final client = ref.watch(apiClientProvider);
    final safeCursor = _cursor.clamp(0, files.length - 1);
    final cursorTime = recordingTime(files[safeCursor].name, files[safeCursor].modified);

    return Column(
      children: [
        _TimeBar(
          time: cursorTime,
          count: files.length,
          position: safeCursor + 1,
          onSearch: () => handleSearch(files),
        ),
        Expanded(
          child: Row(
            children: [
              Expanded(
                child: RefreshIndicator(
                  onRefresh: () async {
                    ref.invalidate(streamFilesProvider(widget.stream));
                    await ref.read(streamFilesProvider(widget.stream).future);
                  },
                  child: ListView.builder(
                    controller: _scroll,
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemExtent: _laneHeight,
                    itemCount: files.length,
                    itemBuilder: (context, i) => _Lane(
                      file: files[i],
                      url: client?.thumbUrl(widget.stream, files[i]).toString(),
                      headers: client?.imageHeaders ?? const {},
                      highlighted: i == safeCursor && _scrubbing,
                    ),
                  ),
                ),
              ),
              _ScrubRail(
                count: files.length,
                index: safeCursor,
                label: formatUtcShort(cursorTime),
                scrubbing: _scrubbing,
                onScrubStart: () => setState(() => _scrubbing = true),
                onScrubEnd: () => setState(() => _scrubbing = false),
                onChanged: (i) {
                  setState(() => _cursor = i);
                  _jumpToIndex(i);
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Header: where in time the list currently sits, plus the date/time search.
class _TimeBar extends StatelessWidget {
  const _TimeBar({
    required this.time,
    required this.count,
    required this.position,
    required this.onSearch,
  });

  final DateTime time;
  final int count;
  final int position;
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
      decoration: const BoxDecoration(
        color: IdentColors.surface,
        border: Border(bottom: BorderSide(color: Color(0x1FFFFFFF))),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  formatUtcStamp(time),
                  style: const TextStyle(
                    color: IdentColors.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                Text(
                  '$position of $count recordings',
                  style: const TextStyle(color: IdentColors.textSecondary, fontSize: 11.5),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.event_outlined),
            tooltip: 'Jump to date and time',
            onPressed: onSearch,
          ),
        ],
      ),
    );
  }
}

/// One recording: its time in the gutter, its spectrogram snapshot alongside.
class _Lane extends StatelessWidget {
  const _Lane({
    required this.file,
    required this.url,
    required this.headers,
    required this.highlighted,
  });

  final StreamFile file;
  final String? url;
  final Map<String, String> headers;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final t = recordingTime(file.name, file.modified);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      color: highlighted ? IdentColors.accent.withValues(alpha: 0.10) : null,
      child: Row(
        children: [
          SizedBox(
            width: 52,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  formatUtcShort(t).split(' ').last, // HH:mm
                  style: const TextStyle(
                    color: IdentColors.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                Text(
                  formatUtcShort(t).split(' ').take(2).join(' '), // dd MMM
                  style: const TextStyle(color: IdentColors.idle, fontSize: 10.5),
                ),
              ],
            ),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: _Snapshot(url: url, headers: headers),
            ),
          ),
        ],
      ),
    );
  }
}

/// The snapshot itself. A 404 is ordinary — it means the Brahma service has not
/// rendered this recording yet — so it gets a quiet placeholder rather than an
/// error, which would make a normal stream look broken.
class _Snapshot extends StatelessWidget {
  const _Snapshot({required this.url, required this.headers});

  final String? url;
  final Map<String, String> headers;

  @override
  Widget build(BuildContext context) {
    if (url == null) return const _SnapshotPlaceholder(icon: Icons.image_not_supported_outlined);

    return CachedNetworkImage(
      imageUrl: url!,
      httpHeaders: headers,
      fit: BoxFit.fill,
      height: double.infinity,
      width: double.infinity,
      fadeInDuration: const Duration(milliseconds: 120),
      placeholder: (_, _) => const _SnapshotPlaceholder(),
      errorWidget: (_, _, _) => const _SnapshotPlaceholder(
        icon: Icons.hourglass_empty,
        hint: 'Not rendered yet',
      ),
    );
  }
}

class _SnapshotPlaceholder extends StatelessWidget {
  const _SnapshotPlaceholder({this.icon, this.hint});

  final IconData? icon;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF11151D),
      alignment: Alignment.center,
      child: icon == null
          ? const SizedBox(
              height: 14,
              width: 14,
              child: CircularProgressIndicator(strokeWidth: 1.5, color: IdentColors.idle),
            )
          : Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 14, color: IdentColors.idle),
                if (hint != null) ...[
                  const SizedBox(width: 6),
                  Text(hint!, style: const TextStyle(color: IdentColors.idle, fontSize: 11)),
                ],
              ],
            ),
    );
  }
}

/// Vertical scrub rail: drag anywhere on it to sweep the whole stream.
///
/// A rail rather than a Slider because the useful gesture here is "drag through
/// time and watch the waterfall move", which wants the whole track height as
/// the target and a live time readout pinned to the thumb.
class _ScrubRail extends StatelessWidget {
  const _ScrubRail({
    required this.count,
    required this.index,
    required this.label,
    required this.scrubbing,
    required this.onChanged,
    required this.onScrubStart,
    required this.onScrubEnd,
  });

  final int count;
  final int index;
  final String label;
  final bool scrubbing;
  final ValueChanged<int> onChanged;
  final VoidCallback onScrubStart;
  final VoidCallback onScrubEnd;

  @override
  Widget build(BuildContext context) {
    if (count <= 1) return const SizedBox(width: 0);

    return SizedBox(
      width: 34,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final height = constraints.maxHeight;

          void update(double dy) {
            final fraction = (dy / height).clamp(0.0, 1.0);
            onChanged((fraction * (count - 1)).round());
          }

          final thumbY = (index / (count - 1)) * height;

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragStart: (d) {
              onScrubStart();
              update(d.localPosition.dy);
            },
            onVerticalDragUpdate: (d) => update(d.localPosition.dy),
            onVerticalDragEnd: (_) => onScrubEnd(),
            onVerticalDragCancel: onScrubEnd,
            onTapDown: (d) => update(d.localPosition.dy),
            child: Semantics(
              slider: true,
              label: 'Scrub through time',
              value: label,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  // Track.
                  Center(
                    child: Container(
                      width: 3,
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0x24FFFFFF),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  // Thumb.
                  Positioned(
                    top: (thumbY - 8).clamp(0.0, height - 16),
                    left: 8,
                    child: Container(
                      width: 18,
                      height: 16,
                      decoration: BoxDecoration(
                        color: scrubbing ? IdentColors.accent : IdentColors.textSecondary,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Icon(Icons.drag_handle, size: 12, color: IdentColors.shell),
                    ),
                  ),
                  // Time bubble, only while dragging.
                  if (scrubbing)
                    Positioned(
                      top: (thumbY - 14).clamp(0.0, height - 28),
                      right: 40,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: IdentColors.accent,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          label,
                          style: const TextStyle(
                            color: IdentColors.shell,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
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

class _Error extends StatelessWidget {
  const _Error({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

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
            FilledButton.tonal(onPressed: () => onRetry(), child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}
