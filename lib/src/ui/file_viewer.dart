/// The recording viewer — the live feed itself, and the target of a
/// notification's "Open recording".
///
/// Shows one recording at a time: its time span, its spectrogram at the largest
/// size the screen allows, a thumbnail strip for moving between recordings, a
/// favourite star, and the detections recorded against it. There is deliberately
/// no intermediate list of files — the strip *is* the list, always in view, so
/// reaching a recording never costs a screen transition.
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
    // Centre the strip on the opening recording once the first frame has laid
    // it out — before that the controller has no viewport to measure against.
    WidgetsBinding.instance.addPostFrameCallback((_) => _centreStrip(_index, animate: false));
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

    final folderMeta = ref.watch(streamFolderProvider(widget.folder));
    final start = _file.startTime;
    final end = folderMeta?.durationMs == null
        ? null
        : start.add(Duration(milliseconds: folderMeta!.durationMs!));

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

  /// Swiping the image moves between recordings — the same thing the strip does
  /// by tap, so either habit works.
  Widget _buildPager() {
    final client = ref.watch(apiClientProvider);

    return PageView.builder(
      controller: _pages,
      onPageChanged: handlePageChanged,
      itemCount: widget.files.length,
      itemBuilder: (context, i) => Padding(
        padding: const EdgeInsets.all(8),
        child: Center(
          child: InteractiveViewer(
            maxScale: 6,
            child: _Spectrogram(
              url: client?.thumbUrl(widget.folder, widget.files[i]).toString(),
              headers: client?.imageHeaders ?? const {},
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStrip(Set<String> favourites, {required bool vertical}) {
    final client = ref.watch(apiClientProvider);

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
        itemExtent: _stripItemExtent,
        itemCount: widget.files.length,
        itemBuilder: (context, i) {
          final f = widget.files[i];
          return _StripItem(
            file: f,
            active: i == _index,
            favourite: favourites.contains(f.name),
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

/// The spectrogram, at its rendered aspect (200x64).
class _Spectrogram extends StatelessWidget {
  const _Spectrogram({required this.url, required this.headers});

  final String? url;
  final Map<String, String> headers;

  @override
  Widget build(BuildContext context) {
    if (url == null) return const _Unavailable(message: 'Not signed in.');

    return AspectRatio(
      aspectRatio: 200 / 64,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: CachedNetworkImage(
          imageUrl: url!,
          httpHeaders: headers,
          fit: BoxFit.contain,
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
      ),
    );
  }
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
    required this.url,
    required this.headers,
    required this.onTap,
  });

  final StreamFile file;
  final bool active;
  final bool favourite;
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
              child: ClipRRect(
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
