/// One stream's dashboard.
///
/// Four data windows, reached by swiping: **Live images**, **AIS**,
/// **Decisions** and **Notifications**. There is no tab bar — the windows are
/// siblings and a menu across the top would cost vertical space on every screen
/// to say something a swipe already says. The current window's name lives in the
/// app bar, which exists anyway, alongside a row of dots so the set stays
/// discoverable without a control of its own.
///
/// **The windows form a ring, not a row.** Swiping past either end carries on
/// into the other, so no window is ever more than two swipes away and neither
/// end is a dead stop. Notifications sits last precisely because of that: it is
/// the window most often wanted from a standing start, and putting it at the end
/// of the ring puts it one backward swipe from Live images.
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

  @override
  Widget build(BuildContext context) {
    // Another window asked to show a recording — slide across to the viewer.
    // The viewer itself handles scrolling its strip to the file; this only
    // moves the dashboard, so the two animations run together rather than the
    // user arriving at an already-settled screen.
    ref.listen(fileFocusRequestProvider(widget.stream), (_, next) {
      if (next != null) goToWindow(_imagesPage);
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
            Row(
              children: [
                Text(
                  _titles[_window],
                  style: const TextStyle(fontSize: 11.5, color: IdentColors.textSecondary),
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
        // Unbounded and built on demand, which is what closes the ring: page
        // 4003 is the same window as 3999, so there is no end to stop at in
        // either direction. Nothing is lost by building rather than listing the
        // four — a PageView keeps no cache extent, so the window you are not
        // looking at was already being disposed and rebuilt.
        child: PageView.builder(
          controller: _pages,
          onPageChanged: (i) => setState(() => _page = i),
          itemBuilder: (context, i) => switch (i % _titles.length) {
            0 => ImagesPage(stream: widget.stream),
            1 => AisPage(stream: widget.stream),
            2 => DecisionsPage(stream: widget.stream),
            _ => NotificationsPage(stream: widget.stream),
          },
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
