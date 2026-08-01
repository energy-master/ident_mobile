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
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api_client.dart';
import '../models.dart';
import '../providers.dart';
import '../spectrogram_geometry.dart';
import '../stream_clock.dart';
import '../theme.dart';
import '../time_format.dart';
import 'file_strip.dart';

/// Where the viewer should sit after its file list is replaced.
///
/// The live feed re-reads its folder every minute, so this runs constantly and
/// decides whether the user keeps their place. Extracted from the widget because
/// the rules are easy to get subtly wrong and impossible to see once wrong: an
/// off-by-one shows up as the feed drifting one recording per refresh.
///
/// [index] is the position in [oldNames]. Returns the position in [newNames]:
///   * pinned and already on the newest → follow the new newest (index 0);
///   * otherwise → wherever the recording they were reading moved to;
///   * and if that recording is gone entirely, the nearest surviving position.
int nextIndexAfterRefresh({
  required List<String> oldNames,
  required List<String> newNames,
  required int index,
  required bool pinToNewest,
}) {
  if (newNames.isEmpty) return 0;
  final last = newNames.length - 1;
  if (oldNames.isEmpty) return index.clamp(0, last);

  // "On the newest" is what makes pinning safe: someone who has scrubbed back
  // into history is reading, and must not be dragged forward by an arrival.
  if (pinToNewest && index == 0) return 0;

  final current = oldNames[index.clamp(0, oldNames.length - 1)];
  final found = newNames.indexOf(current);
  return found >= 0 ? found : index.clamp(0, last);
}

/// Embeddable viewer. Hosts its own header, so it works both inside a tab (the
/// live feed) and inside a Scaffold (opened from a notification).
class FileViewer extends ConsumerStatefulWidget {
  const FileViewer({
    super.key,
    required this.folder,
    required this.files,
    this.initialIndex = 0,
    this.pinToNewest = false,
  });

  final String folder;

  /// Ordered newest-first. The strip moves between these without re-fetching.
  final List<StreamFile> files;

  final int initialIndex;

  /// Follow new arrivals — the live feed's behaviour.
  ///
  /// Only while the user is actually sitting on the newest recording. Someone
  /// who has scrubbed back into history is reading something, and yanking them
  /// forward because a new file landed is the rudest thing this screen could do.
  final bool pinToNewest;

  @override
  ConsumerState<FileViewer> createState() => _FileViewerState();
}

class _FileViewerState extends ConsumerState<FileViewer> {
  late final PageController _pages = PageController(initialPage: _startIndex);
  late int _index = _startIndex;

  bool _showDecisions = false;

  /// A focus request already queued for the end of this frame, so several
  /// rebuilds before it lands do not queue it several times.
  String? _focusScheduled;

  /// The same, for a move the clock has asked for.
  int? _clockScheduled;

  int get _lastIndex => widget.files.isEmpty ? 0 : widget.files.length - 1;
  int get _startIndex => widget.initialIndex.clamp(0, _lastIndex);

  StreamFile get _file => widget.files[_index.clamp(0, _lastIndex)];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _alignClockToOpening();
    });
  }

  /// Move the app to the recording it actually opened on, when that is not the
  /// one the clock names.
  ///
  /// Narrowing the filter is what causes this: the app is sitting at a moment
  /// in a recording that is not starred, the strip is rebuilt holding only
  /// favourites, and the nearest one it can open on is somewhere else. Left
  /// alone the header would show one recording while the AIS window answered
  /// about another, which is the exact disagreement the clock exists to stop.
  ///
  /// A live clock is left alone. It has no moment to be inconsistent with, and
  /// publishing here would take the feed off live every time this window was
  /// rebuilt — which is every swipe.
  void _alignClockToOpening() {
    if (widget.files.isEmpty) return;
    final at = ref.read(streamClockProvider(widget.folder)).at;
    if (at == null) return;

    final file = widget.files[_index];
    final start = file.startTime;
    final ms = ref.read(fileDurationsProvider(widget.folder))[file.name] ?? 0;
    final end = start.add(Duration(milliseconds: ms));

    if (at.isBefore(start) || at.isAfter(end)) _publishClock(_index);
  }

  /// Put the whole app at this recording's moment.
  ///
  /// Only ever called for a move the operator made. The viewer must not pin the
  /// clock for a move it made itself — following a new arrival, or catching up
  /// to a clock that moved elsewhere — or the live feed would take itself off
  /// live once a minute.
  void _publishClock(int i) {
    if (i < 0 || i >= widget.files.length) return;
    ref
        .read(streamClockProvider(widget.folder).notifier)
        .pin(widget.files[i].startTime, ClockSource.recording);
  }

  /// Catch up with a clock that moved somewhere this viewer is not.
  ///
  /// This is how tapping Live gets back to the newest recording, and how a jump
  /// made from the decisions feed or the AIS chart reaches the strip. It moves
  /// the viewer and deliberately does not publish: the clock is already where
  /// it wants to be, and re-publishing would pin a live clock to whatever file
  /// it had just landed on.
  /// The mark is held until the move *lands*, not merely until the frame ends.
  /// The pager takes a fifth of a second to animate and `_index` only catches up
  /// when it settles, so a mark cleared any earlier would let every rebuild in
  /// between re-issue the same move — each one restarting the animation it was
  /// already running.
  void _followClock(StreamClock clock, Map<String, int> durations) {
    if (widget.files.isEmpty) return;
    final target = clockFileIndex(widget.files, clock, durations);
    if (target == _index || target == _clockScheduled) return;

    _clockScheduled = target;
    // After this frame: this runs during build, where the pager may not be laid
    // out yet.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _moveTo(target);
    });
  }

  /// Focus a recording another window asked for, whether the request arrived
  /// while this viewer was on screen or was left waiting while it was not.
  ///
  /// It has to be read from the provider's current value, not merely listened
  /// for. The dashboard keeps no cache extent, so the window nobody is looking
  /// at is disposed: a request raised from the Decisions window lands while this
  /// viewer does not exist, and a listener registered when it is rebuilt a
  /// moment later never fires, because by then the value has already changed.
  /// That was every request made from more than one window away — which was all
  /// the ones worth making, and why tapping a detection landed on the newest
  /// recording rather than the one that fired.
  ///
  /// The request is cleared only once it has been acted on. A recording the
  /// current filter hides is left pending on purpose, so that images_page can
  /// widen the filter and the viewer it rebuilds can pick the request up.
  ///
  /// It moves without publishing, for the same reason [_followClock] does:
  /// whoever raised the request already set the clock, and often to a finer
  /// moment than this file's start — the instant a detection fired, or the
  /// instant a vessel reported. Republishing would round that off.
  void _consumeFocusRequest(String? name) {
    if (name == null || name == _focusScheduled) return;
    final i = widget.files.indexWhere((f) => f.name == name);
    if (i < 0) return;

    _focusScheduled = name;
    // After this frame: this runs during build, where the pager may not yet
    // have been laid out and writing to a provider would be reentrant.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusScheduled = null;
      if (!mounted) return;
      _moveTo(i);
      ref.read(fileFocusRequestProvider(widget.folder).notifier).state = null;
    });
  }

  /// Absorb a refreshed file list in place, rather than being rebuilt around it.
  ///
  /// The live feed re-reads the folder every minute. This viewer used to be
  /// keyed on the newest filename, so each new arrival tore the whole thing down
  /// and built it again — new controllers, a new strip, and every thumbnail
  /// request in flight restarted from nothing. On a folder of several thousand
  /// recordings that was the app's single largest repeating cost, and it also
  /// lost the user's position every time.
  ///
  /// So the list is now absorbed: hold the user on the recording they were
  /// reading (its index moves as files are prepended), and only follow the
  /// newest when they were already on it.
  @override
  void didUpdateWidget(FileViewer old) {
    super.didUpdateWidget(old);
    if (identical(old.files, widget.files) || widget.files.isEmpty) return;

    final next = nextIndexAfterRefresh(
      oldNames: old.files.map((f) => f.name).toList(growable: false),
      newNames: widget.files.map((f) => f.name).toList(growable: false),
      index: _index,
      pinToNewest: widget.pinToNewest,
    );

    if (next != _index) setState(() => _index = next);

    // After this frame: the PageView has not yet laid out against the new
    // itemCount, so jumping now would measure against the old extent.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_pages.hasClients && _pages.page?.round() != _index) {
        _pages.jumpToPage(_index);
      }
    });
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void handlePageChanged(int i) {
    if (_clockScheduled == i) _clockScheduled = null;
    setState(() => _index = i);
  }

  /// Choosing a recording — the operator's move, so the app time goes with it.
  ///
  /// Including when they tap the newest recording while the feed is live. That
  /// does take the app off live, which looks like nothing happened until the
  /// next file lands and the strip stays put; it is the honest reading of a
  /// deliberate tap, and the Live filter beside it is one tap back.
  void handleStripTap(int i) {
    _publishClock(i);
    _moveTo(i);
  }

  /// Move the viewer, without touching the clock.
  void _moveTo(int i) {
    if (!_pages.hasClients) return;
    _pages.animateToPage(
      i,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
    );
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
    final durations = ref.watch(fileDurationsProvider(widget.folder));
    final durationMs = durations[_file.name];
    final start = _file.startTime;
    final end = durationMs == null ? null : start.add(Duration(milliseconds: durationMs));

    // The app time moved somewhere else — back to live, or to a moment picked
    // in another window.
    _followClock(ref.watch(streamClockProvider(widget.folder)), durations);

    // Another window asked to focus a recording.
    _consumeFocusRequest(ref.watch(fileFocusRequestProvider(widget.folder)));

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
          child: isLandscape ? _buildLandscape() : _buildPortrait(),
        ),
      ],
    );
  }

  Widget _buildPortrait() {
    return Column(
      children: [
        Expanded(flex: 3, child: _buildPager()),
        SizedBox(height: kFileStripThickness, child: _buildStrip(vertical: false)),
        if (_showDecisions)
          Expanded(flex: 4, child: _DecisionsPanel(folder: widget.folder, file: _file)),
      ],
    );
  }

  Widget _buildLandscape() {
    return Row(
      children: [
        Expanded(child: _buildPager()),
        if (_showDecisions)
          SizedBox(width: 300, child: _DecisionsPanel(folder: widget.folder, file: _file)),
        SizedBox(width: kFileStripThickness, child: _buildStrip(vertical: true)),
      ],
    );
  }

  Widget _buildStrip({required bool vertical}) {
    return FileStrip(
      folder: widget.folder,
      files: widget.files,
      activeIndex: _index,
      vertical: vertical,
      onTap: handleStripTap,
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
    final missing = ref.read(missingThumbsProvider);

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
                missing: missing.contains(widget.folder, widget.files[i].thumbName),
                onMissing: () => missing.add(widget.folder, widget.files[i].thumbName),
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

/// True when a failed image fetch means the server holds no snapshot for this
/// recording, as opposed to the phone being unable to reach it.
///
/// Only the former is worth remembering. Writing off a lane because the network
/// dropped for a moment would leave it blank until the next explicit refresh,
/// which reads as missing data rather than as the transient it was.
bool _isMissingSnapshot(Object? error) =>
    error is HttpExceptionWithStatus && error.statusCode == 404;

/// The spectrogram, at its rendered aspect (200x64), with detections drawn over it.
class _Spectrogram extends StatelessWidget {
  const _Spectrogram({
    required this.url,
    required this.headers,
    required this.missing,
    required this.onMissing,
    this.decisions = const [],
    this.durationMs,
    this.sampleRate,
  });

  final String? url;
  final Map<String, String> headers;

  /// Already known to have no snapshot — draw the placeholder without asking.
  final bool missing;

  /// Called when the server answers 404, so the strip and the pager stop
  /// re-requesting this recording on every rebuild.
  final VoidCallback onMissing;

  final List<Decision> decisions;
  final int? durationMs;
  final int? sampleRate;

  static const _noSnapshot = 'This recording has no rendered spectrogram yet.';

  @override
  Widget build(BuildContext context) {
    if (url == null) return const _Unavailable(message: 'Not signed in.');
    if (missing) return const _Unavailable(message: _noSnapshot);

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
              errorWidget: (_, _, error) {
                if (_isMissingSnapshot(error)) onMissing();
                return const _Unavailable(message: _noSnapshot);
              },
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
