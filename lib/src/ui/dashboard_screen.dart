/// One stream's dashboard.
///
/// Four data windows: **Live images**, **AIS**, **Decisions** and
/// **Notifications**. Two layouts, chosen from the screen's short side rather
/// than from the OS:
///
///   * **Phone (short side < 600 dp).** The windows form a ring reached by
///     swiping — no window is ever more than two swipes away and neither end
///     is a dead stop. Notifications sits last precisely because of that: it
///     is the window most often wanted from a standing start, and putting it
///     at the end of the ring puts it one backward swipe from Live images.
///
///   * **iPad (short side ≥ 600 dp).** The four windows are tiled in a 2×2
///     grid so a glance takes in all of them at once. Each tile carries a ⤢
///     button that opens the panel full-screen, with a floating dock to
///     switch between maximised panels or return to the grid.
///
/// The split is by device size, not device family. Split-screen on an iPad can
/// leave this app in a phone-shaped column, and that column earns nothing from
/// four postage stamps.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import '../theme.dart';
import 'ais_page.dart';
import 'decisions_page.dart';
import 'images_page.dart';
import 'layout.dart';
import 'maximised_panel.dart';
import 'notifications_page.dart';
import 'panel_frame.dart';
import 'streams_screen.dart' show DiagnosticsDetail;

/// The page to scroll to in order to reach [window] from [current].
///
/// The ring is built from an unbounded page index, so reaching a window is a
/// matter of stepping the shortest way round rather than jumping to a fixed
/// page. Whole-ring jumps are what this exists to avoid: from Notifications,
/// Live images is one swipe forward, and animating backwards through every other
/// window to reach it would be a two-second journey to the next screen along.
int nextPageForWindow(int current, int window, int count) {
  final forward = ((window - current) % count + count) % count;
  // A tie (two windows apart in a four-window ring) goes forward, so the same
  // pair always animates the same way rather than depending on where you came
  // from.
  final step = forward * 2 <= count ? forward : forward - count;
  return current + step;
}

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key, required this.stream});

  final String stream;

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  // AIS sits next to Live images because it reads the recording selected there
  // — the two are meant to be swiped between. Notifications sits last so that
  // one backward swipe from Live images reaches it.
  static const _titles = ['Live images', 'AIS', 'Decisions', 'Notifications'];

  /// Where the ring starts, in page numbers.
  ///
  /// The PageView is unbounded so it can be swiped either way for as long as
  /// anyone cares to; starting a long way from zero is what makes "backwards"
  /// possible at all, since page indices cannot go negative. Nobody will swipe
  /// four thousand windows to find the wall.
  static const _ringOrigin = 4000;

  final _pages = PageController(initialPage: _ringOrigin);
  int _page = _ringOrigin;

  /// Which of [_titles] the current page shows.
  int get _window => _page % _titles.length;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  /// Bring one window into view, the short way round the ring.
  void goToWindow(int window) {
    if (!_pages.hasClients) return;
    final current = _pages.page?.round() ?? _page;
    final target = nextPageForWindow(current, window, _titles.length);
    if (target == current) return;
    _pages.animateToPage(
      target,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
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

  /// The images window, which owns the viewer a focus request targets.
  static const _imagesPage = 0;

  /// Open a panel full-screen. Used by every tile in the tablet grid.
  void handleMaximise(DashboardPanel panel) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MaximisedPanelScreen(
          stream: widget.stream,
          initial: panel,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tablet = isTabletLayout(context);

    // Another window asked to show a recording — on phone that slides the
    // dashboard ring across to the viewer. On tablet all four windows are
    // already in view, so there is nowhere to slide to and the tile handles
    // the focus itself.
    ref.listen(fileFocusRequestProvider(widget.stream), (_, next) {
      if (next != null && !tablet) goToWindow(_imagesPage);
    });

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
            // Dots + current window name only make sense in the ring. In the
            // grid every window is on screen, so the app bar is just a name.
            if (!tablet)
              Row(
                children: [
                  Text(
                    _titles[_window],
                    style: const TextStyle(
                        fontSize: 11.5, color: IdentColors.textSecondary),
                  ),
                  const SizedBox(width: 8),
                  _Dots(count: _titles.length, active: _window),
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
        child: tablet ? _buildGrid() : _buildRing(),
      ),
    );
  }

  /// Phone layout: the swipe ring, unchanged.
  Widget _buildRing() {
    // Unbounded and built on demand, which is what closes the ring: page 4003
    // is the same window as 3999, so there is no end to stop at in either
    // direction. Nothing is lost by building rather than listing the four —
    // a PageView keeps no cache extent, so the window you are not looking at
    // was already being disposed and rebuilt.
    return PageView.builder(
      controller: _pages,
      onPageChanged: (i) => setState(() => _page = i),
      itemBuilder: (context, i) => switch (i % _titles.length) {
        0 => ImagesPage(stream: widget.stream),
        1 => AisPage(stream: widget.stream),
        2 => DecisionsPage(stream: widget.stream),
        _ => NotificationsPage(stream: widget.stream),
      },
    );
  }

  /// iPad layout: all four windows tiled at once.
  ///
  /// LayoutBuilder rather than a fixed aspect ratio because the tile grid has
  /// to fit exactly the available space (the app bar and the safe-area insets
  /// vary), and a GridView with `childAspectRatio` would either scroll or
  /// leave a gap. The AIS window in particular earns nothing from being
  /// letterboxed, and the notifications list is a wasted half-column at any
  /// aspect ratio the tiles would round to.
  Widget _buildGrid() {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: LayoutBuilder(
        builder: (context, constraints) {
          const gap = 8.0;
          final w = (constraints.maxWidth - gap) / 2;
          final h = (constraints.maxHeight - gap) / 2;
          return Column(
            children: [
              SizedBox(
                height: h,
                child: Row(
                  children: [
                    SizedBox(width: w, child: _tile(DashboardPanel.liveImages)),
                    const SizedBox(width: gap),
                    SizedBox(width: w, child: _tile(DashboardPanel.ais)),
                  ],
                ),
              ),
              const SizedBox(height: gap),
              SizedBox(
                height: h,
                child: Row(
                  children: [
                    SizedBox(width: w, child: _tile(DashboardPanel.decisions)),
                    const SizedBox(width: gap),
                    SizedBox(width: w, child: _tile(DashboardPanel.notifications)),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _tile(DashboardPanel panel) {
    final child = switch (panel) {
      DashboardPanel.liveImages => ImagesPage(stream: widget.stream),
      DashboardPanel.ais => AisPage(stream: widget.stream),
      DashboardPanel.decisions => DecisionsPage(stream: widget.stream),
      DashboardPanel.notifications => NotificationsPage(stream: widget.stream),
    };
    return PanelFrame(
      title: panel.title,
      onMaximise: () => handleMaximise(panel),
      child: child,
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
