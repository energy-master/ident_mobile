/// One stream's dashboard.
///
/// Three data windows, reached by swiping: **Live images**, **Notifications**
/// and **Decisions**. There is no tab bar — the windows are siblings and a menu
/// across the top would cost vertical space on every screen to say something a
/// swipe already says. The current window's name lives in the app bar, which
/// exists anyway, alongside a row of dots so the set stays discoverable without
/// a control of its own.
///
/// **One data flow per screen, at every size.** The windows are never tiled
/// side by side, even where a tablet has the room: each is a distinct thing to
/// read, and splitting the screen halves both without making either easier to
/// follow.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import '../theme.dart';
import 'ais_page.dart';
import 'decisions_page.dart';
import 'images_page.dart';
import 'notifications_page.dart';
import 'streams_screen.dart' show DiagnosticsDetail;

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key, required this.stream});

  final String stream;

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  final _pages = PageController();
  int _page = 0;

  // AIS sits next to Live images because it reads the recording selected there
  // — the two are meant to be swiped between.
  static const _titles = ['Live images', 'AIS', 'Notifications', 'Decisions'];

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  /// Diagnostics is a sheet rather than a fourth window: it is a health check
  /// glanced at, not a feed read alongside the others.
  void handleShowDiagnostics() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: IdentColors.surface,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
        child: Consumer(
          builder: (context, ref, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.stream,
                style: const TextStyle(
                  color: IdentColors.textPrimary,
                  fontWeight: FontWeight.w600,
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: 12),
              DiagnosticsDetail(diag: ref.watch(diagnosticsProvider(widget.stream))),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.stream,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 15),
            ),
            Row(
              children: [
                Text(
                  _titles[_page],
                  style: const TextStyle(fontSize: 11.5, color: IdentColors.textSecondary),
                ),
                const SizedBox(width: 8),
                _Dots(count: _titles.length, active: _page),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.health_and_safety_outlined),
            tooltip: 'Diagnostics',
            onPressed: handleShowDiagnostics,
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: PageView(
          controller: _pages,
          onPageChanged: (i) => setState(() => _page = i),
          children: [
            ImagesPage(stream: widget.stream),
            AisPage(stream: widget.stream),
            NotificationsPage(stream: widget.stream),
            DecisionsPage(stream: widget.stream),
          ],
        ),
      ),
    );
  }
}

/// Swipe position, small enough to ride inside the app bar's subtitle line.
class _Dots extends StatelessWidget {
  const _Dots({required this.count, required this.active});

  final int count;
  final int active;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Window ${active + 1} of $count',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < count; i++)
            Container(
              width: i == active ? 12 : 5,
              height: 5,
              margin: const EdgeInsets.only(right: 3),
              decoration: BoxDecoration(
                color: i == active ? IdentColors.accent : IdentColors.idle,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
        ],
      ),
    );
  }
}
