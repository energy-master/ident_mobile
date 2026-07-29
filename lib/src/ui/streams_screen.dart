/// The stream list — the app's home screen.
///
/// One card per stream the user can read, each showing the stream's live time
/// and a status light per health check (acoustic data, model runs, AIS feed).
/// Tapping a card opens that stream's dashboard; the chevron expands the
/// diagnostics detail in place.
///
/// Polling matches js/my-streams.js at 30 s — the underlying checks move on the
/// order of minutes, so anything faster would just be load. Polling stops while
/// the screen is off-view or the app is backgrounded.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api_client.dart';
import '../models.dart';
import '../providers.dart';
import '../theme.dart';
import '../time_format.dart';
import 'dashboard_screen.dart';
import 'ident_logo.dart';
import 'notifications_page.dart';
import 'status_dot.dart';

const _pollInterval = Duration(seconds: 30);

class StreamsScreen extends ConsumerStatefulWidget {
  const StreamsScreen({super.key});

  @override
  ConsumerState<StreamsScreen> createState() => _StreamsScreenState();
}

class _StreamsScreenState extends ConsumerState<StreamsScreen> with WidgetsBindingObserver {
  Timer? _poll;
  final _expanded = <String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startPolling();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // No point refreshing checks nobody can see, and it drains the battery.
    if (state == AppLifecycleState.resumed) {
      _startPolling();
      _refreshChecks();
    } else {
      _poll?.cancel();
    }
  }

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(_pollInterval, (_) => _refreshChecks());
  }

  /// Re-run the diagnostics for every stream currently listed. The folder list
  /// itself changes rarely, so a poll does not re-fetch it.
  void _refreshChecks() {
    final streams = ref.read(streamsProvider).valueOrNull;
    if (streams == null) return;
    for (final s in streams) {
      ref.invalidate(diagnosticsProvider(s.name));
    }
  }

  Future<void> handleRefresh() async {
    ref.invalidate(streamsProvider);
    _refreshChecks();
    await ref.read(streamsProvider.future);
  }

  void handleOpenStream(String name) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => DashboardScreen(stream: name)),
    );
  }

  void handleOpenInbox() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        // Untitled app bar: it exists for the back button, not to announce a
        // screen whose contents are self-evident.
        builder: (_) => Scaffold(
          appBar: AppBar(),
          body: const SafeArea(
            child: NotificationsPage(stream: null, showStreamNames: true),
          ),
        ),
        settings: const RouteSettings(name: 'all-notifications'),
      ),
    );
  }

  Future<void> handleSignOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: IdentColors.surface,
        title: const Text('Sign out?'),
        content: const Text('This device will need to sign in again.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Sign out')),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(authControllerProvider).signOut();
    }
  }

  @override
  Widget build(BuildContext context) {
    final streams = ref.watch(streamsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const _Branding(),
        actions: [
          IconButton(
            icon: const Icon(Icons.notifications_outlined),
            tooltip: 'All notifications',
            onPressed: handleOpenInbox,
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Sign out',
            onPressed: handleSignOut,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: handleRefresh,
        child: switch (streams) {
          AsyncData(:final value) when value.isEmpty => const _EmptyState(),
          AsyncData(:final value) => ListView.separated(
              padding: const EdgeInsets.all(12),
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: value.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, i) {
                final folder = value[i];
                return _StreamCard(
                  name: folder.name,
                  expanded: _expanded.contains(folder.name),
                  onTap: () => handleOpenStream(folder.name),
                  onToggleExpand: () => setState(() {
                    if (!_expanded.remove(folder.name)) _expanded.add(folder.name);
                  }),
                );
              },
            ),
          AsyncError(:final error) => _ErrorState(
              message: error is ApiException || error is NetworkException
                  ? '$error'
                  : 'Could not load your streams.',
              onRetry: handleRefresh,
            ),
          _ => const Center(child: CircularProgressIndicator()),
        },
      ),
    );
  }
}

/// Home-screen title: the IDent wordmark, with the account's company logo to
/// its right when the lead has uploaded one — the same order as the SPA splash.
class _Branding extends ConsumerWidget {
  const _Branding();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final branding = ref.watch(meProvider).valueOrNull?.branding;
    final client = ref.watch(apiClientProvider);

    final logoUrl = (branding != null && client != null && branding.logoPath != null)
        ? client.siteUrl(branding.logoPath!).toString()
        : null;

    return BrandingRow(logoUrl: logoUrl, companyName: branding?.companyName);
  }
}

class _StreamCard extends ConsumerWidget {
  const _StreamCard({
    required this.name,
    required this.expanded,
    required this.onTap,
    required this.onToggleExpand,
  });

  final String name;
  final bool expanded;
  final VoidCallback onTap;
  final VoidCallback onToggleExpand;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final diag = ref.watch(diagnosticsProvider(name));

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 6, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      name,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: IdentColors.textPrimary,
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _Dots(diag: diag),
                  const SizedBox(width: 4),
                  const Icon(Icons.chevron_right, size: 20, color: IdentColors.textSecondary),
                ],
              ),
              const SizedBox(height: 2),
              _LiveTime(diag: diag),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: onToggleExpand,
                  icon: Icon(expanded ? Icons.expand_less : Icons.expand_more, size: 18),
                  label: const Text('Diagnostics'),
                  style: TextButton.styleFrom(
                    foregroundColor: IdentColors.textSecondary,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ),
              if (expanded)
                Padding(
                  padding: const EdgeInsets.fromLTRB(0, 4, 8, 8),
                  child: DiagnosticsDetail(diag: diag),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One dot per check. While the first fetch is in flight the row is a slim
/// spinner rather than three grey dots, which would read as "all unknown".
class _Dots extends StatelessWidget {
  const _Dots({required this.diag});

  final AsyncValue<StreamDiagnostics> diag;

  @override
  Widget build(BuildContext context) {
    return switch (diag) {
      AsyncData(:final value) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final c in value.checks) ...[
              StatusDot(
                status: c.status,
                semanticLabel: '${c.label}: ${c.summary}',
              ),
              const SizedBox(width: 6),
            ],
          ],
        ),
      AsyncError() => const Icon(Icons.cloud_off, size: 16, color: IdentColors.idle),
      _ => const SizedBox(
          height: 12,
          width: 12,
          child: CircularProgressIndicator(strokeWidth: 1.6),
        ),
    };
  }
}

/// `2026-07-28 13:24:08 UTC · 5 min ago`, from the acoustic-data check —
/// the same line js/my-streams.js draws.
class _LiveTime extends StatelessWidget {
  const _LiveTime({required this.diag});

  final AsyncValue<StreamDiagnostics> diag;

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(color: IdentColors.textSecondary, fontSize: 12);

    return switch (diag) {
      AsyncData(:final value) => Builder(builder: (_) {
          final files = value.checkById('files');
          final parts = <String>[];
          final newest = files?.newestName;
          if (newest != null) {
            final t = parseFileStartTime(newest);
            if (t != null) parts.add(formatUtcStamp(t));
          }
          final age = files?.newestAgeMin;
          if (age != null) parts.add(formatAgeMinutes(age));
          if (parts.isEmpty) return const Text('No recordings yet', style: style);
          return Text(parts.join(' · '), style: style);
        }),
      AsyncError() => const Text('Diagnostics unavailable', style: style),
      _ => const Text('Loading…', style: style),
    };
  }
}

/// The expanded per-check detail: status light, label, summary.
class DiagnosticsDetail extends StatelessWidget {
  const DiagnosticsDetail({super.key, required this.diag});

  final AsyncValue<StreamDiagnostics> diag;

  @override
  Widget build(BuildContext context) {
    return switch (diag) {
      AsyncData(:final value) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final c in value.checks)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: StatusDot(status: c.status, size: 9),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            c.label,
                            style: const TextStyle(
                              color: IdentColors.textPrimary,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            c.summary,
                            style: const TextStyle(
                              color: IdentColors.textSecondary,
                              fontSize: 12,
                              height: 1.35,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      AsyncError(:final error) => Text(
          '$error',
          style: const TextStyle(color: IdentColors.error, fontSize: 12),
        ),
      _ => const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: SizedBox(
            height: 16,
            width: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
    };
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: const [
        SizedBox(height: 120),
        Icon(Icons.waves, size: 48, color: IdentColors.idle),
        SizedBox(height: 16),
        Center(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              'No streams on your account yet.\nStreams granted to you will appear here.',
              textAlign: TextAlign.center,
              style: TextStyle(color: IdentColors.textSecondary),
            ),
          ),
        ),
      ],
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(32),
      children: [
        const SizedBox(height: 80),
        const Icon(Icons.cloud_off, size: 48, color: IdentColors.idle),
        const SizedBox(height: 16),
        Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(color: IdentColors.textSecondary),
        ),
        const SizedBox(height: 20),
        Center(
          child: FilledButton.tonal(
            onPressed: () => onRetry(),
            child: const Text('Try again'),
          ),
        ),
      ],
    );
  }
}
