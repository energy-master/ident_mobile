/// The recording strip — the horizontal-or-vertical thumbnail rail that scrolls
/// with the application clock.
///
/// Lifted out of `file_viewer.dart` so that the maximised AIS map can lay it
/// over its own bottom or right edge, keeping the recording context in view
/// while the map has the whole screen. The rules are the same either way:
///
///   * newest at the end (bottom or right), history extending back from it —
///     matches the waterfall's arrow of time;
///   * the active recording is highlighted and scrolled into view;
///   * a tap pins the clock to that recording. Whoever mounted the strip
///     supplies the callback that does the pinning; the strip itself has no
///     opinion about what pinning *means* to the surrounding screen.
///
/// The active recording can be either centred in the viewport (the file viewer,
/// which reads both sides of the current file) or anchored to the end (the AIS
/// overlay, where "what is playing now" belongs against the leading edge). See
/// [FileStripAnchor].
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models.dart';
import '../providers.dart';
import '../theme.dart';
import '../time_format.dart';

/// Where the active item sits in the viewport.
enum FileStripAnchor {
  /// Centred, so both sides of the current recording are readable at once.
  centre,

  /// Pinned to the leading edge (bottom or right), so history trails away from
  /// it. What the maximised AIS overlay wants — the current recording is where
  /// the strip *ends*, not where it stops.
  end,
}

/// Default per-item and cross-axis extents. Match the values the file viewer
/// has always used, so the two placements read as the same control at the same
/// size.
const double kFileStripItemExtent = 76;
const double kFileStripThickness = 74;

class FileStrip extends ConsumerStatefulWidget {
  const FileStrip({
    super.key,
    required this.folder,
    required this.files,
    required this.activeIndex,
    required this.vertical,
    required this.onTap,
    this.anchor = FileStripAnchor.centre,
    this.itemExtent = kFileStripItemExtent,
    this.thickness = kFileStripThickness,
    this.background,
  });

  final String folder;

  /// Newest-first, the same ordering used everywhere else in the app.
  final List<StreamFile> files;

  /// Which entry is currently playing. Highlighted and scrolled to.
  final int activeIndex;

  final bool vertical;

  /// Called with the tapped index. The strip does not touch the clock itself;
  /// the caller decides whether a tap is a clock pin, a viewer scroll, or both.
  final ValueChanged<int> onTap;

  final FileStripAnchor anchor;
  final double itemExtent;
  final double thickness;

  /// Background surface. Defaults to the app's opaque surface so the strip
  /// reads as its own container; the AIS overlay passes a translucent one so
  /// the map continues underneath.
  final Color? background;

  @override
  ConsumerState<FileStrip> createState() => _FileStripState();
}

class _FileStripState extends ConsumerState<FileStrip> {
  final _controller = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _alignTo(widget.activeIndex, animate: false);
    });
  }

  @override
  void didUpdateWidget(FileStrip old) {
    super.didUpdateWidget(old);
    // The active file has moved — usually because the clock did. Slide the
    // strip to keep the current recording where it belongs.
    if (old.activeIndex != widget.activeIndex ||
        old.files.length != widget.files.length ||
        old.anchor != widget.anchor) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _alignTo(widget.activeIndex);
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Where the target item should sit inside the viewport.
  ///
  /// The list is `reverse: true`, so `pixels = 0` is the newest and larger
  /// offsets walk backwards through history. Item `i` (0-indexed from the
  /// newest) therefore starts at `i * extent` when measured from the reversed
  /// origin.
  void _alignTo(int index, {bool animate = true}) {
    if (!_controller.hasClients || widget.files.isEmpty) return;
    final viewport = _controller.position.viewportDimension;
    final extent = widget.itemExtent;

    final rawOffset = switch (widget.anchor) {
      // Centre the item in the viewport.
      FileStripAnchor.centre => (index * extent) - (viewport / 2) + (extent / 2),
      // Pin the item to the leading edge (which in a reversed list is the
      // *start* of the scroll axis: pixels = 0). Bring it flush against that
      // edge with a small margin so the highlight isn't clipped.
      FileStripAnchor.end => (index * extent) - (extent * 0.5),
    };

    final clamped = rawOffset.clamp(
      _controller.position.minScrollExtent,
      _controller.position.maxScrollExtent,
    );

    if (animate) {
      _controller.animateTo(
        clamped,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
      );
    } else {
      _controller.jumpTo(clamped);
    }
  }

  @override
  Widget build(BuildContext context) {
    final client = ref.watch(apiClientProvider);
    final counts = ref.watch(decisionCountsProvider(widget.folder)).valueOrNull ??
        const <String, int>{};
    final favourites =
        ref.watch(favouritesProvider(widget.folder)).valueOrNull ?? const <String>{};
    final missing = ref.read(missingThumbsProvider);

    final vertical = widget.vertical;
    final border = BorderSide(color: const Color(0x1FFFFFFF));

    return Container(
      decoration: BoxDecoration(
        color: widget.background ?? IdentColors.surface,
        border: Border(
          top: vertical ? BorderSide.none : border,
          left: vertical ? border : BorderSide.none,
        ),
      ),
      child: ListView.builder(
        controller: _controller,
        scrollDirection: vertical ? Axis.vertical : Axis.horizontal,
        // Newest at the end (bottom / right); history extends back from it,
        // matching the web app's waterfall.
        reverse: true,
        itemExtent: widget.itemExtent,
        itemCount: widget.files.length,
        itemBuilder: (context, i) {
          final f = widget.files[i];
          return _StripItem(
            file: f,
            active: i == widget.activeIndex,
            favourite: favourites.contains(f.name),
            hasDecisions: (counts[f.name] ?? 0) > 0,
            url: client?.thumbUrl(widget.folder, f).toString(),
            headers: client?.imageHeaders ?? const {},
            missing: missing.contains(widget.folder, f.thumbName),
            onMissing: () => missing.add(widget.folder, f.thumbName),
            onTap: () => widget.onTap(i),
          );
        },
      ),
    );
  }
}

bool _isMissingSnapshot(Object? error) =>
    error is HttpExceptionWithStatus && error.statusCode == 404;

/// One thumbnail lane. Active is ringed; a starred one carries a marker so
/// favourites stay findable while scrubbing.
class _StripItem extends StatelessWidget {
  const _StripItem({
    required this.file,
    required this.active,
    required this.favourite,
    required this.hasDecisions,
    required this.url,
    required this.headers,
    required this.missing,
    required this.onMissing,
    required this.onTap,
  });

  final StreamFile file;
  final bool active;
  final bool favourite;
  final bool hasDecisions;
  final String? url;
  final Map<String, String> headers;
  final bool missing;
  final VoidCallback onMissing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: active ? IdentColors.accent : const Color(0x1FFFFFFF),
            width: active ? 2 : 1,
          ),
        ),
        child: Column(
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: (url == null || missing)
                        ? const ColoredBox(color: Color(0xFF11151D))
                        : CachedNetworkImage(
                            imageUrl: url!,
                            httpHeaders: headers,
                            fit: BoxFit.cover,
                            width: double.infinity,
                            placeholder: (_, _) =>
                                const ColoredBox(color: Color(0xFF11151D)),
                            errorWidget: (_, _, error) {
                              if (_isMissingSnapshot(error)) onMissing();
                              return const ColoredBox(color: Color(0xFF11151D));
                            },
                          ),
                  ),
                  if (hasDecisions)
                    Positioned(
                      top: 3,
                      right: 3,
                      child: Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: const Color(0xFFFF3B30),
                          shape: BoxShape.circle,
                          border: Border.all(color: const Color(0x99000000), width: 0.5),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (favourite) ...[
                    const Icon(Icons.star, size: 9, color: IdentColors.warn),
                    const SizedBox(width: 2),
                  ],
                  Text(
                    formatUtcHhmm(file.startTime),
                    style: TextStyle(
                      fontSize: 9.5,
                      color: active ? IdentColors.textPrimary : IdentColors.textSecondary,
                      fontWeight: active ? FontWeight.w700 : FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
