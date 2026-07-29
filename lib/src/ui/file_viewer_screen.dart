/// One recording, in full.
///
/// Opened by tapping a lane in the live feed, or from a notification that names
/// its recording. Shows the file's time span, its spectrogram at the largest
/// size the screen allows, a strip for moving between recordings, a favourite
/// star, and the detections recorded against it.
///
/// Orientation is never forced. The spectrogram keeps its natural wide aspect
/// either way; what changes is where the strip lives — along the bottom in
/// portrait, down the side in landscape, where vertical space is the scarce
/// resource. Taking over the device rotation to "help" would be a worse trade
/// than letting the layout adapt to however the user is holding it.
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api_client.dart';
import '../models.dart';
import '../providers.dart';
import '../theme.dart';
import '../time_format.dart';

class FileViewerScreen extends ConsumerStatefulWidget {
  const FileViewerScreen({
    super.key,
    required this.folder,
    required this.files,
    required this.initialIndex,
  });

  final String folder;

  /// The full ordered list, so the strip can move between recordings without
  /// another request. Newest first, matching the feed.
  final List<StreamFile> files;

  final int initialIndex;

  @override
  ConsumerState<FileViewerScreen> createState() => _FileViewerScreenState();
}

class _FileViewerScreenState extends ConsumerState<FileViewerScreen> {
  late final PageController _pages = PageController(initialPage: widget.initialIndex);
  late final ScrollController _strip = ScrollController();
  late int _index = widget.initialIndex;

  bool _showDecisions = false;

  /// Fixed extent per strip item, so scrolling the strip to a given index is
  /// arithmetic rather than a measured guess.
  static const double _stripItemExtent = 76;
  static const double _stripThickness = 74;

  @override
  void dispose() {
    _pages.dispose();
    _strip.dispose();
    super.dispose();
  }

  StreamFile get _file => widget.files[_index];

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

  /// Keep the active thumbnail roughly centred as the user pages through.
  void _centreStrip(int i) {
    if (!_strip.hasClients) return;
    final viewport = _strip.position.viewportDimension;
    final target = (i * _stripItemExtent) - (viewport / 2) + (_stripItemExtent / 2);
    _strip.animateTo(
      target.clamp(_strip.position.minScrollExtent, _strip.position.maxScrollExtent),
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> handleToggleFavourite() async {
    try {
      await ref.read(favouritesProvider(widget.folder).notifier).toggle(_file.name);
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not update favourite: ${e.message}')),
        );
      }
    } on NetworkException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Offline — favourite not saved.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isLandscape = MediaQuery.orientationOf(context) == Orientation.landscape;
    final favourites = ref.watch(favouritesProvider(widget.folder));
    final isFavourite = favourites.valueOrNull?.contains(_file.name) ?? false;

    final folderMeta = ref.watch(streamFolderProvider(widget.folder));
    final start = recordingTime(_file.name, _file.modified);
    final end = folderMeta?.durationMs == null
        ? null
        : start.add(Duration(milliseconds: folderMeta!.durationMs!));

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(formatTimeSpan(start, end), style: const TextStyle(fontSize: 14)),
            Text(
              '${formatUtcDateOnly(start)} · ${_index + 1} of ${widget.files.length}',
              style: const TextStyle(fontSize: 11.5, color: IdentColors.textSecondary),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(isFavourite ? Icons.star : Icons.star_border),
            color: isFavourite ? IdentColors.warn : null,
            tooltip: isFavourite ? 'Remove from favourites' : 'Add to favourites',
            onPressed: handleToggleFavourite,
          ),
          IconButton(
            icon: Icon(_showDecisions ? Icons.list_alt : Icons.list_alt_outlined),
            color: _showDecisions ? IdentColors.accent : null,
            tooltip: _showDecisions ? 'Hide detections' : 'Show detections',
            onPressed: () => setState(() => _showDecisions = !_showDecisions),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: isLandscape ? _buildLandscape() : _buildPortrait(),
      ),
    );
  }

  /// Portrait: image above, strip along the bottom, detections beneath.
  Widget _buildPortrait() {
    return Column(
      children: [
        Expanded(flex: 3, child: _buildPager()),
        SizedBox(height: _stripThickness, child: _buildStrip(vertical: false)),
        if (_showDecisions)
          Expanded(flex: 4, child: _DecisionsPanel(folder: widget.folder, file: _file)),
      ],
    );
  }

  /// Landscape: vertical space is scarce, so the strip moves to the side and
  /// detections become a side panel rather than stacking below.
  Widget _buildLandscape() {
    return Row(
      children: [
        Expanded(
          flex: 3,
          child: Column(
            children: [Expanded(child: _buildPager())],
          ),
        ),
        if (_showDecisions)
          SizedBox(
            width: 300,
            child: _DecisionsPanel(folder: widget.folder, file: _file),
          ),
        SizedBox(width: _stripThickness, child: _buildStrip(vertical: true)),
      ],
    );
  }

  /// Swiping the image moves between recordings — the same gesture the strip
  /// performs by tap, so either habit works.
  Widget _buildPager() {
    final client = ref.watch(apiClientProvider);

    return PageView.builder(
      controller: _pages,
      onPageChanged: handlePageChanged,
      itemCount: widget.files.length,
      itemBuilder: (context, i) {
        final f = widget.files[i];
        return Padding(
          padding: const EdgeInsets.all(8),
          child: Center(
            child: InteractiveViewer(
              maxScale: 6,
              child: _Spectrogram(
                url: client?.thumbUrl(widget.folder, f).toString(),
                headers: client?.imageHeaders ?? const {},
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildStrip({required bool vertical}) {
    final client = ref.watch(apiClientProvider);
    final favourites = ref.watch(favouritesProvider(widget.folder)).valueOrNull ?? const <String>{};

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

/// The spectrogram itself, at its rendered aspect (200x64).
class _Spectrogram extends StatelessWidget {
  const _Spectrogram({required this.url, required this.headers});

  final String? url;
  final Map<String, String> headers;

  @override
  Widget build(BuildContext context) {
    if (url == null) {
      return const _Unavailable(message: 'Not signed in.');
    }
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
/// a small marker so favourites are findable while scrubbing.
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
    final t = recordingTime(file.name, file.modified);

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
                    formatUtcHhmm(t),
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
    // Colour by confidence relative to the model's own threshold when it has
    // one — an absolute scale would misread models tuned differently.
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
