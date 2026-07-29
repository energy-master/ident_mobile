/// One notification, in full.
///
/// The list truncates subject and detail to keep rows scannable; this screen is
/// where the whole text lives, along with the provenance an operator needs to
/// act on an alert — which stream, which model, where it was sent, and whether
/// the dispatch actually succeeded.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models.dart';
import '../theme.dart';
import '../time_format.dart';

class NotificationDetailScreen extends StatelessWidget {
  const NotificationDetailScreen({super.key, required this.item});

  final NotificationItem item;

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
  Widget build(BuildContext context) {
    final t = item.sentAtUtc;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Notification'),
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
