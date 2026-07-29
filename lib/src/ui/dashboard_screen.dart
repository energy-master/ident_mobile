/// One stream's dashboard.
///
/// v1.0 is deliberately an abridged version of the web dashboard: notifications
/// and the live spectrogram images. The sensor map, vessel list and live WebGL
/// render stay on the desktop for now.
///
/// **One data flow per screen, at every size.** Notifications and the live feed
/// are never shown side by side, even where a tablet has the room: each is a
/// distinct thing to read, and splitting the screen halves both without making
/// either easier to follow. The tabs swap between them; nothing tiles.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import '../theme.dart';
import 'images_page.dart';
import 'notifications_page.dart';
import 'streams_screen.dart' show DiagnosticsDetail;

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key, required this.stream});

  final String stream;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(stream, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16)),
            const Text(
              'Dashboard',
              style: TextStyle(fontSize: 11.5, color: IdentColors.textSecondary),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.health_and_safety_outlined),
            tooltip: 'Diagnostics',
            onPressed: () => _showDiagnostics(context, ref, stream),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: _PagedLayout(stream: stream),
      ),
    );
  }

  /// Diagnostics is a sheet rather than a page: it is a health check the user
  /// glances at, not something they navigate between.
  static void _showDiagnostics(BuildContext context, WidgetRef ref, String stream) {
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
                stream,
                style: const TextStyle(
                  color: IdentColors.textPrimary,
                  fontWeight: FontWeight.w600,
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: 12),
              DiagnosticsDetail(diag: ref.watch(diagnosticsProvider(stream))),
            ],
          ),
        ),
      ),
    );
  }
}

/// Phone: swipe between pages, with a dot indicator and labelled tabs.
class _PagedLayout extends StatefulWidget {
  const _PagedLayout({required this.stream});

  final String stream;

  @override
  State<_PagedLayout> createState() => _PagedLayoutState();
}

class _PagedLayoutState extends State<_PagedLayout> {
  final _controller = PageController();
  int _page = 0;

  static const _titles = ['Notifications', 'Live images'];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void handleTabTap(int index) {
    _controller.animateToPage(
      index,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _TabStrip(
          titles: _titles,
          active: _page,
          onTap: handleTabTap,
        ),
        Expanded(
          child: PageView(
            controller: _controller,
            onPageChanged: (i) => setState(() => _page = i),
            children: [
              NotificationsPage(stream: widget.stream),
              ImagesPage(stream: widget.stream),
            ],
          ),
        ),
      ],
    );
  }
}

/// Segmented page selector — doubles as the swipe position indicator.
class _TabStrip extends StatelessWidget {
  const _TabStrip({
    required this.titles,
    required this.active,
    required this.onTap,
  });

  final List<String> titles;
  final int active;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0x1FFFFFFF))),
      ),
      child: Row(
        children: [
          for (var i = 0; i < titles.length; i++)
            Expanded(
              child: InkWell(
                onTap: () => onTap(i),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        color: i == active ? IdentColors.accent : Colors.transparent,
                        width: 2,
                      ),
                    ),
                  ),
                  child: Text(
                    titles[i],
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: i == active ? IdentColors.textPrimary : IdentColors.textSecondary,
                      fontSize: 13,
                      fontWeight: i == active ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
