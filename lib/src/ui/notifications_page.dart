/// Notifications — the dashboard's primary page.
///
/// Detection and AIS-proximity alerts, newest first, grouped under day headers.
/// Tapping one opens its detail screen. Scrolling to the end pages backwards by
/// keyset cursor, so alerts arriving while the user reads cannot duplicate or
/// skip rows.
///
/// Used in two places: scoped to one stream inside its dashboard, and unscoped
/// as the all-streams inbox from the home screen (which is when
/// [showStreamNames] earns its keep).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models.dart';
import '../providers.dart';
import '../theme.dart';
import '../time_format.dart';
import 'notification_detail_screen.dart';

class NotificationsPage extends ConsumerStatefulWidget {
  const NotificationsPage({
    super.key,
    required this.stream,
    this.showStreamNames = false,
  });

  /// Stream folder to scope to, or null for every stream.
  final String? stream;

  /// Label each row with the stream it came from — on in the unscoped inbox.
  final bool showStreamNames;

  @override
  ConsumerState<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends ConsumerState<NotificationsPage> {
  final _scroll = ScrollController();

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
    if (!_scroll.hasClients) return;
    // Prefetch a screen early so the list does not visibly stall at the bottom.
    final remaining = _scroll.position.maxScrollExtent - _scroll.position.pixels;
    if (remaining < 600) {
      ref.read(notificationsProvider(widget.stream).notifier).loadMore();
    }
  }

  Future<void> handleRefresh() =>
      ref.read(notificationsProvider(widget.stream).notifier).refresh();

  void handleOpen(NotificationItem item) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => NotificationDetailScreen(item: item),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(notificationsProvider(widget.stream));
    final notifier = ref.read(notificationsProvider(widget.stream).notifier);

    return RefreshIndicator(
      onRefresh: handleRefresh,
      child: switch (async) {
        AsyncData(:final value) when value.isEmpty => const _Empty(),
        AsyncData(:final value) => ListView.builder(
            controller: _scroll,
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.only(bottom: 24),
            // One trailing slot for the paging footer.
            itemCount: value.length + 1,
            itemBuilder: (context, i) {
              if (i == value.length) {
                return _Footer(
                  hasMore: notifier.hasMore,
                  count: value.length,
                );
              }
              final item = value[i];
              final prev = i == 0 ? null : value[i - 1];
              final showHeader = _needsDayHeader(prev, item);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (showHeader) _DayHeader(item: item),
                  _NotificationTile(
                    item: item,
                    showStream: widget.showStreamNames,
                    onTap: () => handleOpen(item),
                  ),
                ],
              );
            },
          ),
        AsyncError(:final error) => _Error(message: '$error', onRetry: handleRefresh),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }

  /// A header is needed whenever the calendar day changes (or at the top).
  /// Items with no parseable timestamp never trigger one, so a malformed row
  /// cannot split a day in two.
  static bool _needsDayHeader(NotificationItem? prev, NotificationItem item) {
    final t = item.sentAtUtc;
    if (t == null) return false;
    if (prev == null) return true;
    final p = prev.sentAtUtc;
    if (p == null) return true;
    return p.year != t.year || p.month != t.month || p.day != t.day;
  }
}

class _DayHeader extends StatelessWidget {
  const _DayHeader({required this.item});

  final NotificationItem item;

  @override
  Widget build(BuildContext context) {
    final t = item.sentAtUtc;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
      child: Text(
        t == null ? '' : formatDayLabel(t).toUpperCase(),
        style: const TextStyle(
          color: IdentColors.textSecondary,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

class _NotificationTile extends StatelessWidget {
  const _NotificationTile({
    required this.item,
    required this.showStream,
    required this.onTap,
  });

  final NotificationItem item;
  final bool showStream;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = item.sentAtUtc;
    final subtitleParts = <String>[
      if (showStream && item.streamFolder.isNotEmpty) item.streamFolder,
      if (t != null) formatUtcShort(t),
      item.channel,
    ];

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: _KindIcon(kind: item.kind, success: item.success),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.subject?.trim().isNotEmpty == true
                        ? item.subject!
                        : _fallbackTitle(item.kind),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: IdentColors.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      height: 1.3,
                    ),
                  ),
                  if (item.detail?.trim().isNotEmpty == true) ...[
                    const SizedBox(height: 2),
                    Text(
                      item.detail!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: IdentColors.textSecondary,
                        fontSize: 12.5,
                        height: 1.35,
                      ),
                    ),
                  ],
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      // Marks the alerts that can be opened straight to their
                      // recording, so the ones that can't don't look broken.
                      if (item.hasFile) ...[
                        const Icon(Icons.graphic_eq, size: 11, color: IdentColors.accent),
                        const SizedBox(width: 4),
                      ],
                      Flexible(
                        child: Text(
                          subtitleParts.join(' · '),
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: IdentColors.idle, fontSize: 11.5),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, size: 18, color: IdentColors.idle),
          ],
        ),
      ),
    );
  }

  static String _fallbackTitle(String kind) => switch (kind) {
        'detection' => 'Detection alert',
        'ais' => 'Vessel proximity alert',
        _ => 'Notification',
      };
}

class _KindIcon extends StatelessWidget {
  const _KindIcon({required this.kind, required this.success});

  final String kind;
  final bool success;

  @override
  Widget build(BuildContext context) {
    // A failed dispatch is the exception worth flagging: the alert fired but the
    // user may never have received it, so it must not look like a normal row.
    final colour = success ? IdentColors.accent : IdentColors.error;
    final icon = !success
        ? Icons.error_outline
        : switch (kind) {
            'detection' => Icons.graphic_eq,
            'ais' => Icons.directions_boat_outlined,
            _ => Icons.notifications_outlined,
          };

    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(icon, size: 18, color: colour),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({required this.hasMore, required this.count});

  final bool hasMore;
  final int count;

  @override
  Widget build(BuildContext context) {
    if (hasMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Center(
        child: Text(
          '$count notification${count == 1 ? '' : 's'}',
          style: const TextStyle(color: IdentColors.idle, fontSize: 12),
        ),
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
        Icon(Icons.notifications_off_outlined, size: 44, color: IdentColors.idle),
        SizedBox(height: 14),
        Center(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              'No notifications yet.\nAlerts appear here when a subscribed model detects something.',
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
  final Future<void> Function() onRetry;

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
        Center(
          child: FilledButton.tonal(onPressed: () => onRetry(), child: const Text('Try again')),
        ),
      ],
    );
  }
}
