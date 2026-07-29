/// Decisions — the stream's detection feed.
///
/// Every detection the subscribed models have recorded across the stream,
/// newest recording first and grouped by recording. Tapping any row opens that
/// recording in the viewer, positioned on it — which is the point of this
/// screen: a detection is only useful if you can immediately see what fired it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models.dart';
import '../providers.dart';
import '../theme.dart';
import '../time_format.dart';
import 'file_viewer.dart';

class DecisionsPage extends ConsumerWidget {
  const DecisionsPage({super.key, required this.stream});

  final String stream;

  /// Open the recording a detection came from.
  ///
  /// The live listing is the source of truth for what still exists — a stream
  /// rolls old recordings off, so a detection can outlive its file.
  Future<void> handleOpen(BuildContext context, WidgetRef ref, String fileName) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    List<StreamFile> files;
    try {
      files = await ref.read(streamFilesProvider(stream).future);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not load the stream: $e')));
      return;
    }

    final index = files.indexWhere((f) => f.name == fileName);
    if (index < 0) {
      messenger.showSnackBar(
        const SnackBar(content: Text('That recording is no longer in the stream folder.')),
      );
      return;
    }

    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => FileViewerScreen(folder: stream, files: files, initialIndex: index),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(streamDecisionsProvider(stream));

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(streamDecisionsProvider(stream));
        await ref.read(streamDecisionsProvider(stream).future);
      },
      child: switch (async) {
        AsyncData(:final value) when value.decisions.isEmpty => const _Empty(),
        AsyncData(:final value) => _buildList(context, ref, value),
        AsyncError(:final error) => _Error(
            message: '$error',
            onRetry: () => ref.invalidate(streamDecisionsProvider(stream)),
          ),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }

  Widget _buildList(BuildContext context, WidgetRef ref, DecisionList list) {
    final rows = list.decisions;

    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: rows.length + 1,
      itemBuilder: (context, i) {
        if (i == rows.length) return _Footer(list: list);

        final d = rows[i];
        final prev = i == 0 ? null : rows[i - 1];
        // A header whenever the recording changes, so a burst of detections in
        // one file reads as one block rather than repeating the filename.
        final newFile = prev == null || prev.fileName != d.fileName;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (newFile && d.fileName != null) _FileHeader(fileName: d.fileName!),
            _DecisionRow(
              decision: d,
              onTap: d.fileName == null
                  ? null
                  : () => handleOpen(context, ref, d.fileName!),
            ),
          ],
        );
      },
    );
  }
}

class _FileHeader extends StatelessWidget {
  const _FileHeader({required this.fileName});

  final String fileName;

  @override
  Widget build(BuildContext context) {
    final t = parseFileStartTime(fileName);

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
      child: Row(
        children: [
          const Icon(Icons.graphic_eq, size: 13, color: IdentColors.accent),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              t == null ? fileName : formatUtcStamp(t),
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: IdentColors.textSecondary,
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DecisionRow extends StatelessWidget {
  const _DecisionRow({required this.decision, required this.onTap});

  final Decision decision;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final score = decision.score;
    // Judge against the model's own threshold — an absolute scale would misread
    // models tuned differently.
    final threshold = decision.threshold;
    final strong = score != null && threshold != null && score >= threshold;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 3,
              height: 32,
              decoration: BoxDecoration(
                color: strong ? IdentColors.ok : IdentColors.warn,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${decision.tmin.toStringAsFixed(1)}s – ${decision.tmax.toStringAsFixed(1)}s',
                    style: const TextStyle(
                      color: IdentColors.textPrimary,
                      fontSize: 13.5,
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
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: IdentColors.textSecondary, fontSize: 11.5),
                  ),
                ],
              ),
            ),
            if (score != null) ...[
              Text(
                score.toStringAsFixed(2),
                style: TextStyle(
                  color: strong ? IdentColors.ok : IdentColors.textSecondary,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 6),
            ],
            if (onTap != null)
              const Icon(Icons.chevron_right, size: 18, color: IdentColors.idle),
          ],
        ),
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({required this.list});

  final DecisionList list;

  @override
  Widget build(BuildContext context) {
    // Never let a cap read as "that's everything" — say what was withheld.
    final text = list.truncated
        ? 'Showing the newest ${list.decisions.length} detections'
        : '${list.decisions.length} detection${list.decisions.length == 1 ? '' : 's'}';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Center(
        child: Text(text, style: const TextStyle(color: IdentColors.idle, fontSize: 12)),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: const [
        SizedBox(height: 100),
        Icon(Icons.rule, size: 44, color: IdentColors.idle),
        SizedBox(height: 14),
        Center(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              'No detections recorded on this stream yet.\n'
              'They appear here once a subscribed model fires.',
              textAlign: TextAlign.center,
              style: TextStyle(color: IdentColors.textSecondary),
            ),
          ),
        ),
      ],
    );
  }
}

class _Error extends StatelessWidget {
  const _Error({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(32),
      children: [
        const SizedBox(height: 60),
        const Icon(Icons.cloud_off, size: 44, color: IdentColors.idle),
        const SizedBox(height: 14),
        Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(color: IdentColors.textSecondary),
        ),
        const SizedBox(height: 18),
        Center(child: FilledButton.tonal(onPressed: onRetry, child: const Text('Try again'))),
      ],
    );
  }
}
