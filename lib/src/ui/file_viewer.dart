/// The recording viewer — the live feed itself, and the target of a
/// notification's "Open recording".
///
/// Shows one recording at a time: its time span, its spectrogram at the largest
/// size the screen allows, a thumbnail strip for moving between recordings, a
/// favourite star, and the detections recorded against it. There is deliberately
/// no intermediate list of files — the strip *is* the list, always in view, so
/// reaching a recording never costs a screen transition.
///
/// The strip is the only way to change recording by gesture: a horizontal drag
/// belongs to the dashboard, which swipes between its data windows. See
/// `_buildPager`.
///
/// Orientation is never forced. The spectrogram keeps its natural wide aspect
/// either way; what changes is where the strip lives — along the bottom in
/// portrait, down the side in landscape, where vertical space is the scarce
/// resource. Taking over device rotation to "help" would be a worse trade than
/// letting the layout adapt to however the user is holding it.
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api_client.dart';
import '../models.dart';
import '../providers.dart';
import '../spectrogram_geometry.dart';
import '../theme.dart';
import '../time_format.dart';

/// Embeddable viewer. Hosts its own header, so it works both inside a tab (the
/// live feed) and inside a Scaffold (opened from a notification).
class FileViewer extends ConsumerStatefulWidget {
  const FileViewer({
    super.key,
    required this.folder,
    required this.files,
    this.initialIndex = 0,
  });

  final String folder;

  /// Ordered newest-first. The strip moves between these without re-fetching.
  final List<StreamFile> files;

  final int initialIndex;

  @override
  ConsumerState<FileViewer> createState() => _FileViewerState();
}

class _FileViewerState extends ConsumerState<FileViewer> {
  late final PageController _pages = PageController(initialPage: _startIndex);
  final ScrollController _strip = ScrollController();
  late int _index = _startIndex;

  bool _showDecisions = false;

  /// Fixed extent per strip item, so centring the active one is arithmetic
  /// rather than a measured guess.
  static const double _stripItemExtent = 76;
  static const double _stripThickness = 74;

  int get _lastIndex => widget.files.isEmpty ? 0 : widget.files.length - 1;
  int get _startIndex => widget.initialIndex.clamp(0, _lastIndex);

  StreamFile get _file => widget.files[_index.clamp(0, _lastIndex)];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Centre the strip on the opening recording once the first frame has laid
      // it out — before that the controller has no viewport to measure against.
      _centreStrip(_index, animate: false);
      _publishActiveFile();
    });
  }

  /// Tell sibling windows which recording is selected. The AIS map reads this
  /// to plot the traffic present while *this* recording was made, so the
  /// selection has to be visible outside the viewer.
  void _publishActiveFile() {
    if (widget.files.isEmpty) return;
    ref.read(activeFileProvider(widget.folder).notifier).state = _file;
  }

  @override
  void dispose() {
    _pages.dispose();
    _strip.dispose();
    super.dispose();
  }

  void handlePageChanged(int i) {
    setState(() => _index = i);
    _centreStrip(i);
    _publishActiveFile();
  }

  void handleStripTap(int i) {
    _pages.animateToPage(
      i,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
    );
  }

  void _centreStrip(int i, {bool animate = true}) {
    if (!_strip.hasClients) return;
    final viewport = _strip.position.viewportDimension;
    final target = (i * _stripItemExtent) - (viewport / 2) + (_stripItemExtent / 2);
    final clamped =
        target.clamp(_strip.position.minScrollExtent, _strip.position.maxScrollExtent);
    if (animate) {
      _strip.animateTo(clamped,
          duration: const Duration(milliseconds: 240), curve: Curves.easeOutCubic);
    } else {
      _strip.jumpTo(clamped);
    }
  }

  Future<void> handleToggleFavourite() async {
    try {
      await ref.read(favouritesProvider(widget.folder).notifier).toggle(_file.name);
    } on ApiException catch (e) {
      _snack('Could not update favourite: ${e.message}');
    } on NetworkException {
      _snack('Offline — favourite not saved.');
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  /// Pick a date and time, then land on the recording closest to it.
  ///
  /// "Closest" rather than "at or before" because a stream can have gaps; an
  /// exact-match rule would leave the user staring at nothing when the nearest
  /// recording is a few minutes the wrong side of their choice.
  Future<void> handleSearch() async {
    final files = widget.files;
    if (files.isEmpty) return;

    final newest = files.first.startTime;
    final oldest = files.last.startTime;

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

    // Times are chosen in the user's local zone; recordings are stamped UTC.
    final target = DateTime(
      date.year,
      date.month,
      date.day,
      time?.hour ?? 0,
      time?.minute ?? 0,
    ).toUtc();

    var bestIndex = 0;
    var bestDelta = const Duration(days: 36500);
    for (var i = 0; i < files.length; i++) {
      final delta = files[i].startTime.difference(target).abs();
      if (delta < bestDelta) {
        bestDelta = delta;
        bestIndex = i;
      }
    }

    handleStripTap(bestIndex);
    _snack('Nearest recording: ${formatUtcStamp(files[bestIndex].startTime)}');
  }

  @override
  Widget build(BuildContext context) {
    if (widget.files.isEmpty) return const SizedBox.shrink();

    final isLandscape = MediaQuery.orientationOf(context) == Orientation.landscape;
    final favourites =
        ref.watch(favouritesProvider(widget.folder)).valueOrNull ?? const <String>{};
    final isFavourite = favourites.contains(_file.name);

    // Per-file duration, not the folder's: a folder can mix 5-second and
    // 5-minute recordings, and using the folder figure puts the wrong span in
    // the header and maps the overlay against the wrong time axis.
    final durationMs = ref.watch(fileDurationsProvider(widget.folder))[_file.name];
    final start = _file.startTime;
    final end = durationMs == null ? null : start.add(Duration(milliseconds: durationMs));

    // Another window asked to focus a recording — act on it, then clear it.
    ref.listen(fileFocusRequestProvider(widget.folder), (_, next) {
      if (next == null) return;
      final i = widget.files.indexWhere((f) => f.name == next);
      if (i >= 0) handleStripTap(i);
      // Clear after this frame; writing to a provider during a listener would
      // re-enter the build that is currently running.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ref.read(fileFocusRequestProvider(widget.folder).notifier).state = null;
        }
      });
    });

    return Column(
      children: [
        _Header(
          span: formatTimeSpan(start, end),
          subtitle: '${formatUtcDateOnly(start)} · ${_index + 1} of ${widget.files.length}',
          isFavourite: isFavourite,
          showDecisions: _showDecisions,
          onSearch: handleSearch,
          onToggleFavourite: handleToggleFavourite,
          onToggleDecisions: () => setState(() => _showDecisions = !_showDecisions),
        ),
        Expanded(
          child: isLandscape ? _buildLandscape(favourites) : _buildPortrait(favourites),
        ),
      ],
    );
  }

  Widget _buildPortrait(Set<String> favourites) {
    return Column(
      children: [
        Expanded(flex: 3, child: _buildPager()),
        SizedBox(height: _stripThickness, child: _buildStrip(favourites, vertical: false)),
        if (_showDecisions)
          Expanded(flex: 4, child: _DecisionsPanel(folder: widget.folder, file: _file)),
      ],
    );
  }

  Widget _buildLandscape(Set<String> favourites) {
    return Row(
      children: [
        Expanded(child: _buildPager()),
        if (_showDecisions)
          SizedBox(width: 300, child: _DecisionsPanel(folder: widget.folder, file: _file)),
        SizedBox(width: _stripThickness, child: _buildStrip(favourites, vertical: true)),
      ],
    );
  }

  /// The image pager is driven by the strip, not by dragging the image.
  ///
  /// The dashboard swipes horizontally between its data windows, and a
  /// horizontal pager nested inside it would swallow that gesture — you could
  /// never leave Live images by swiping. So this keeps the page transition but
  /// takes no drag of its own: the strip (and the date search) move between
  /// recordings, and a horizontal drag belongs to the dashboard.
  Widget _buildPager() {
    final client = ref.watch(apiClientProvider);

    return PageView.builder(
      controller: _pages,
      physics: const NeverScrollableScrollPhysics(),
      onPageChanged: handlePageChanged,
      itemCount: widget.files.length,
      itemBuilder: (context, i) {
        final durations = ref.watch(fileDurationsProvider(widget.folder));
        final folderMeta = ref.watch(streamFolderProvider(widget.folder));
        // Only the active page draws detections. PageView builds its
        // neighbours too, and fetching their decisions would triple the
        // requests for pages the user may never stop on.
        final decisions = i == _index
            ? (ref
                    .watch(fileDecisionsProvider(
                        (folder: widget.folder, file: widget.files[i].name)))
                    .valueOrNull
                    ?.decisions ??
                const <Decision>[])
            : const <Decision>[];

        return Padding(
          padding: const EdgeInsets.all(8),
          child: Center(
            child: InteractiveViewer(
              maxScale: 6,
              child: _Spectrogram(
                url: client?.thumbUrl(widget.folder, widget.files[i]).toString(),
                headers: client?.imageHeaders ?? const {},
                decisions: decisions,
                // This file's own duration — the overlay's whole time axis.
                durationMs: durations[widget.files[i].name],
                sampleRate: folderMeta?.sampleRate,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildStrip(Set<String> favourites, {required bool vertical}) {
    final client = ref.watch(apiClientProvider);
    // One aggregated call for the whole folder — a request per thumbnail would
    // be absurd for a decoration on a scrolling strip.
    final counts =
        ref.watch(decisionCountsProvider(widget.folder)).valueOrNull ?? const <String, int>{};

    return Container(
      decoration: BoxDecoration(
        color: IdentColors.surface,
        border: Border(
          top: vertical ? BorderSide.none : const BorderSide(color: Color(0x1FFFFFFF)),
          left: vertical ? const BorderSide(color: Color(0x1FFFFFFF)) : BorderSide.none,
        ),
      ),
      child: ListView.builder(
        controller: _strip,
        scrollDirection: vertical ? Axis.vertical : Axis.horizontal,
        // Time runs the same way the web app's waterfall runs: the newest
        // recording sits at the end (right / bottom) and history extends back
        // from it, so scrolling *away* from the newest means going back in
        // time. Index 0 is still the newest, so the strip opens on it.
        reverse: true,
        itemExtent: _stripItemExtent,
        itemCount: widget.files.length,
        itemBuilder: (context, i) {
          final f = widget.files[i];
          return _StripItem(
            file: f,
            active: i == _index,
            favourite: favourites.contains(f.name),
            hasDecisions: (counts[f.name] ?? 0) > 0,
            url: client?.thumbUrl(widget.folder, f).toString(),
            headers: client?.imageHeaders ?? const {},
            onTap: () => handleStripTap(i),
          );
        },
      ),
    );
  }
}

/// Time span, position, and the viewer's actions.
class _Header extends StatelessWidget {
  const _Header({
    required this.span,
    required this.subtitle,
    required this.isFavourite,
    required this.showDecisions,
    required this.onSearch,
    required this.onToggleFavourite,
    required this.onToggleDecisions,
  });

  final String span;
  final String subtitle;
  final bool isFavourite;
  final bool showDecisions;
  final VoidCallback onSearch;
  final VoidCallback onToggleFavourite;
  final VoidCallback onToggleDecisions;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 4, 4, 4),
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
                  span,
                  style: const TextStyle(
                    color: IdentColors.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                Text(
                  subtitle,
                  style: const TextStyle(color: IdentColors.textSecondary, fontSize: 11.5),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.event_outlined),
            iconSize: 20,
            tooltip: 'Jump to date and time',
            onPressed: onSearch,
          ),
          IconButton(
            icon: Icon(isFavourite ? Icons.star : Icons.star_border),
            iconSize: 20,
            color: isFavourite ? IdentColors.warn : null,
            tooltip: isFavourite ? 'Remove from favourites' : 'Add to favourites',
            onPressed: onToggleFavourite,
          ),
          IconButton(
            icon: const Icon(Icons.list_alt),
            iconSize: 20,
            color: showDecisions ? IdentColors.accent : null,
            tooltip: showDecisions ? 'Hide detections' : 'Show detections',
            onPressed: onToggleDecisions,
          ),
        ],
      ),
    );
  }
}

/// The spectrogram, at its rendered aspect (200x64), with detections drawn over it.
class _Spectrogram extends StatelessWidget {
  const _Spectrogram({
    required this.url,
    required this.headers,
    this.decisions = const [],
    this.durationMs,
    this.sampleRate,
  });

  final String? url;
  final Map<String, String> headers;
  final List<Decision> decisions;
  final int? durationMs;
  final int? sampleRate;

  @override
  Widget build(BuildContext context) {
    if (url == null) return const _Unavailable(message: 'Not signed in.');

    return AspectRatio(
      aspectRatio: 200 / 64,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Stack(
          fit: StackFit.expand,
          children: [
            CachedNetworkImage(
              imageUrl: url!,
              httpHeaders: headers,
              fit: BoxFit.fill,
              placeholder: (_, _) => const Center(
                child: SizedBox(
                  height: 22,
                  width: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
              errorWidget: (_, _, _) => const _Unavailable(
                message: 'This recording has no rendered spectrogram yet.',
              ),
            ),
            if (decisions.isNotEmpty && durationMs != null && durationMs! > 0)
              IgnorePointer(
                child: CustomPaint(
                  painter: _DecisionOverlay(
                    decisions: decisions,
                    durationSeconds: durationMs! / 1000,
                    sampleRate: sampleRate,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Draws each detection as a box over the spectrogram.
///
/// The axis mapping lives in spectrogram_geometry.dart, where it is unit
/// tested — an inverted frequency axis would draw every box in the wrong half
/// of the image while still looking entirely plausible.
class _DecisionOverlay extends CustomPainter {
  const _DecisionOverlay({
    required this.decisions,
    required this.durationSeconds,
    required this.sampleRate,
  });

  final List<Decision> decisions;
  final double durationSeconds;
  final int? sampleRate;

  @override
  void paint(Canvas canvas, Size size) {
    // Red reads clearly against viridis, which runs blue → green → yellow and
    // contains no red anywhere.
    final fill = Paint()
      ..color = const Color(0x33FF3B30)
      ..style = PaintingStyle.fill;
    final stroke = Paint()
      ..color = const Color(0xE6FF3B30)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;

    for (final d in decisions) {
      final box = spectrogramBoxFor(
        d,
        durationSeconds: durationSeconds,
        sampleRate: sampleRate,
      );
      if (box == null) continue;

      final rect = Rect.fromLTRB(
        box.left * size.width,
        box.top * size.height,
        box.right * size.width,
        box.bottom * size.height,
      );

      // Real detections are routinely far smaller than a pixel in BOTH axes —
      // repmus25 fires 0.085 s events in a 300 s recording across 300 Hz of a
      // 48 kHz band, which is about 0.3 x 0.6 px. Drawn faithfully that is an
      // invisible hairline, so both axes get a floor. Clamping only the width
      // (as this first did) still left them invisible.
      canvas.drawRect(_atLeast(rect, size), fill);
      canvas.drawRect(_atLeast(rect, size), stroke);
    }
  }

  /// Smallest a detection may be drawn, in logical pixels. Below this it stops
  /// being visible at all; a marker slightly larger than the truth is far more
  /// useful than an exact rectangle nobody can see.
  static const _minExtent = 5.0;

  /// Grow [rect] about its centre until it is at least [_minExtent] on each
  /// axis, then nudge it back inside the image so an edge detection isn't
  /// half-clipped.
  Rect _atLeast(Rect rect, Size size) {
    var out = rect;
    if (out.width < _minExtent) {
      final c = out.center.dx;
      out = Rect.fromLTRB(c - _minExtent / 2, out.top, c + _minExtent / 2, out.bottom);
    }
    if (out.height < _minExtent) {
      final c = out.center.dy;
      out = Rect.fromLTRB(out.left, c - _minExtent / 2, out.right, c + _minExtent / 2);
    }
    final dx = out.left < 0 ? -out.left : (out.right > size.width ? size.width - out.right : 0.0);
    final dy = out.top < 0 ? -out.top : (out.bottom > size.height ? size.height - out.bottom : 0.0);
    return out.shift(Offset(dx, dy));
  }

  @override
  bool shouldRepaint(_DecisionOverlay old) =>
      old.decisions != decisions ||
      old.durationSeconds != durationSeconds ||
      old.sampleRate != sampleRate;
}

class _Unavailable extends StatelessWidget {
  const _Unavailable({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF11151D),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.hourglass_empty, size: 26, color: IdentColors.idle),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: IdentColors.idle, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

/// One thumbnail in the strip. The active one is ringed; a starred one carries
/// a marker so favourites stay findable while scrubbing.
class _StripItem extends StatelessWidget {
  const _StripItem({
    required this.file,
    required this.active,
    required this.favourite,
    required this.hasDecisions,
    required this.url,
    required this.headers,
    required this.onTap,
  });

  final StreamFile file;
  final bool active;
  final bool favourite;
  final bool hasDecisions;
  final String? url;
  final Map<String, String> headers;
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
                    child: url == null
                        ? const ColoredBox(color: Color(0xFF11151D))
                        : CachedNetworkImage(
                            imageUrl: url!,
                            httpHeaders: headers,
                            fit: BoxFit.cover,
                            width: double.infinity,
                            placeholder: (_, _) => const ColoredBox(color: Color(0xFF11151D)),
                            errorWidget: (_, _, _) => const ColoredBox(color: Color(0xFF11151D)),
                          ),
                  ),
                  // Marks a recording that fired, so detections are findable
                  // while scrubbing without opening each one.
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

/// The detections recorded against the active recording.
class _DecisionsPanel extends ConsumerWidget {
  const _DecisionsPanel({required this.folder, required this.file});

  final String folder;
  final StreamFile file;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(fileDecisionsProvider((folder: folder, file: file.name)));

    return Container(
      decoration: const BoxDecoration(
        color: IdentColors.surface,
        border: Border(top: BorderSide(color: Color(0x1FFFFFFF))),
      ),
      child: switch (async) {
        AsyncData(:final value) when value.decisions.isEmpty => const Center(
            child: Padding(
              padding: EdgeInsets.all(20),
              child: Text(
                'No detections recorded for this recording.',
                textAlign: TextAlign.center,
                style: TextStyle(color: IdentColors.textSecondary, fontSize: 12.5),
              ),
            ),
          ),
        AsyncData(:final value) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
                child: Text(
                  value.truncated
                      ? 'DETECTIONS · showing ${value.decisions.length} of ${value.total}'
                      : 'DETECTIONS · ${value.total}',
                  style: const TextStyle(
                    color: IdentColors.textSecondary,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: value.decisions.length,
                  itemBuilder: (context, i) => _DecisionRow(decision: value.decisions[i]),
                ),
              ),
            ],
          ),
        AsyncError(:final error) => Center(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Text(
                '$error',
                textAlign: TextAlign.center,
                style: const TextStyle(color: IdentColors.textSecondary, fontSize: 12),
              ),
            ),
          ),
        _ => const Center(
            child: SizedBox(
              height: 20,
              width: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
      },
    );
  }
}

class _DecisionRow extends StatelessWidget {
  const _DecisionRow({required this.decision});

  final Decision decision;

  @override
  Widget build(BuildContext context) {
    final score = decision.score;
    // Judge confidence against the model's own threshold when it has one — an
    // absolute scale would misread models tuned differently.
    final threshold = decision.threshold;
    final strong = score != null && threshold != null && score >= threshold;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 3,
            height: 30,
            decoration: BoxDecoration(
              color: strong ? IdentColors.ok : IdentColors.warn,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${decision.tmin.toStringAsFixed(1)}s – ${decision.tmax.toStringAsFixed(1)}s',
                  style: const TextStyle(
                    color: IdentColors.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                Text(
                  [
                    decision.modelName.isEmpty ? 'unknown model' : decision.modelName,
                    if (decision.target != null) decision.target!,
                    if (decision.isSidecar) 'sidecar',
                  ].join(' · '),
                  style: const TextStyle(color: IdentColors.textSecondary, fontSize: 11.5),
                ),
              ],
            ),
          ),
          if (score != null)
            Text(
              score.toStringAsFixed(2),
              style: TextStyle(
                color: strong ? IdentColors.ok : IdentColors.textSecondary,
                fontSize: 13,
                fontWeight: FontWeight.w700,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
        ],
      ),
    );
  }
}

/// Full-screen wrapper, used when a notification opens its recording.
class FileViewerScreen extends StatelessWidget {
  const FileViewerScreen({
    super.key,
    required this.folder,
    required this.files,
    required this.initialIndex,
  });

  final String folder;
  final List<StreamFile> files;
  final int initialIndex;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(folder, overflow: TextOverflow.ellipsis)),
      body: SafeArea(
        top: false,
        child: FileViewer(folder: folder, files: files, initialIndex: initialIndex),
      ),
    );
  }
}
