/// One notification, in full.
///
/// The list truncates subject and detail to keep rows scannable; this screen is
/// where the whole text lives, along with the provenance an operator needs to
/// act on an alert — which stream, which model, where it was sent, and whether
/// the dispatch actually succeeded.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models.dart';
import '../providers.dart';
import '../theme.dart';
import '../time_format.dart';
import 'file_viewer.dart';

class NotificationDetailScreen extends ConsumerWidget {
  const NotificationDetailScreen({super.key, required this.item});

  final NotificationItem item;

  /// Jump to the recording this alert fired on.
  ///
  /// The feed listing is the source of truth for what still exists, so we look
  /// the name up there rather than trusting the alert: a stream rolls old
  /// recordings off, and a months-old notification can easily outlive its file.
  Future<void> handleOpenRecording(BuildContext context, WidgetRef ref) async {
    final fileName = item.fileName;
    if (fileName == null) return;

    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    List<StreamFile> files;
    try {
      files = await ref.read(streamFilesProvider(item.streamFolder).future);
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
        builder: (_) => FileViewerScreen(
          folder: item.streamFolder,
          files: files,
          initialIndex: index,
        ),
      ),
    );
  }

  void handleCopy(BuildContext context) {
    final t = item.sentAtUtc;
    final lines = <String>[
      item.subject ?? 'Notification',
      if (t != null) formatUtcStamp(t),
      'Stream: ${item.streamFolder}',
      if (item.modelId != null) 'Model: ${item.modelId}',
      if (item.detail?.trim().isNotEmpty == true) '',
      if (item.detail?.trim().isNotEmpty == true) item.detail!.trim(),
    ];
    Clipboard.setData(ClipboardData(text: lines.join('\n')));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Copied to clipboard')),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = item.sentAtUtc;

    return Scaffold(
      appBar: AppBar(
        // No title: the alert's own subject is the heading, immediately below.
        // A generic "Notification" label would only repeat what the screen
        // already makes obvious.
        actions: [
          IconButton(
            icon: const Icon(Icons.copy_all_outlined),
            tooltip: 'Copy details',
            onPressed: () => handleCopy(context),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (!item.success)
            Container(
              margin: const EdgeInsets.only(bottom: 16),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: IdentColors.error.withValues(alpha: 0.12),
                border: Border.all(color: IdentColors.error.withValues(alpha: 0.5)),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Row(
                children: [
                  Icon(Icons.error_outline, color: IdentColors.error, size: 18),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'This alert was raised but could not be delivered.',
                      style: TextStyle(color: IdentColors.error, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),

          Text(
            item.subject?.trim().isNotEmpty == true ? item.subject! : 'Notification',
            style: const TextStyle(
              color: IdentColors.textPrimary,
              fontSize: 19,
              fontWeight: FontWeight.w600,
              height: 1.3,
            ),
          ),
          if (t != null) ...[
            const SizedBox(height: 6),
            Text(
              '${formatUtcStamp(t)} · ${formatAge(DateTime.now().toUtc().difference(t))}',
              style: const TextStyle(color: IdentColors.textSecondary, fontSize: 13),
            ),
          ],

          if (item.detail?.trim().isNotEmpty == true) ...[
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: IdentColors.surface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0x2AFFFFFF)),
              ),
              child: SelectableText(
                item.detail!,
                style: const TextStyle(
                  color: IdentColors.textPrimary,
                  fontSize: 14,
                  height: 1.5,
                ),
              ),
            ),
          ],

          // Only per-file alerts can be traced to a recording; an hourly digest
          // covers many, so there is nothing single to open.
          if (item.hasFile) ...[
            const SizedBox(height: 20),
            FilledButton.tonalIcon(
              onPressed: () => handleOpenRecording(context, ref),
              icon: const Icon(Icons.graphic_eq, size: 18),
              label: const Text('Open recording'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ],

          const SizedBox(height: 24),
          const Text(
            'DETAILS',
            style: TextStyle(
              color: IdentColors.textSecondary,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 8),
          _Row(label: 'Stream', value: item.streamFolder),
          if (item.hasFile) _Row(label: 'Recording', value: item.fileName!),
          _Row(label: 'Type', value: _kindLabel(item.kind)),
          _Row(label: 'Channel', value: item.channel),
          if (item.recipient != null) _Row(label: 'Sent to', value: item.recipient!),
          if (item.modelId != null) _Row(label: 'Model ID', value: '${item.modelId}'),
          _Row(label: 'Delivered', value: item.success ? 'Yes' : 'No'),
        ],
      ),
    );
  }

  static String _kindLabel(String kind) => switch (kind) {
        'detection' => 'Detection',
        'ais' => 'Vessel proximity',
        _ => kind,
      };
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: const TextStyle(color: IdentColors.textSecondary, fontSize: 13),
            ),
          ),
          Expanded(
            child: SelectableText(
              value.isEmpty ? '—' : value,
              style: const TextStyle(color: IdentColors.textPrimary, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
