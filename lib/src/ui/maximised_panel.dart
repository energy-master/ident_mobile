/// The full-screen face of one dashboard panel.
///
/// Opened from a tile's ⤢ button in the iPad dashboard. Fills the entire
/// screen with the chosen panel and floats a small dock (four panel icons +
/// "back to dashboard") over the bottom so the operator can flip between
/// panels without collapsing back to the grid every time. Restoring to the
/// grid is one tap.
///
/// The AIS panel gets a special treatment while maximised: the recording
/// strip is laid over its bottom or right edge, and tapping a thumbnail pins
/// the application clock to that recording — the same effect as choosing it
/// in the Live images window, without leaving the map.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models.dart';
import '../providers.dart';
import '../stream_clock.dart';
import '../theme.dart';
import 'ais_page.dart';
import 'decisions_page.dart';
import 'file_strip.dart';
import 'images_page.dart';
import 'notifications_page.dart';
import 'panel_frame.dart';

/// Which panel is on screen. Order matches the phone dashboard's page ring.
enum DashboardPanel {
  liveImages,
  ais,
  decisions,
  notifications;

  String get title => switch (this) {
        DashboardPanel.liveImages => 'Live images',
        DashboardPanel.ais => 'AIS',
        DashboardPanel.decisions => 'Decisions',
        DashboardPanel.notifications => 'Notifications',
      };

  IconData get icon => switch (this) {
        DashboardPanel.liveImages => Icons.image_outlined,
        DashboardPanel.ais => Icons.map_outlined,
        DashboardPanel.decisions => Icons.list_alt,
        DashboardPanel.notifications => Icons.notifications_outlined,
      };
}

class MaximisedPanelScreen extends StatefulWidget {
  const MaximisedPanelScreen({
    super.key,
    required this.stream,
    required this.initial,
  });

  final String stream;
  final DashboardPanel initial;

  @override
  State<MaximisedPanelScreen> createState() => _MaximisedPanelScreenState();
}

class _MaximisedPanelScreenState extends State<MaximisedPanelScreen> {
  late DashboardPanel _panel = widget.initial;

  void handleSelect(DashboardPanel next) {
    if (next == _panel) return;
    setState(() => _panel = next);
  }

  @override
  Widget build(BuildContext context) {
    // Keyed by panel so switching between them tears down the previous one
    // rather than trying to reparent its state — each panel owns pollers and
    // controllers that must reset when it appears fresh.
    final body = switch (_panel) {
      DashboardPanel.liveImages => ImagesPage(
          key: const ValueKey('max-live'),
          stream: widget.stream,
        ),
      DashboardPanel.ais => _AisMaximised(
          key: const ValueKey('max-ais'),
          stream: widget.stream,
        ),
      DashboardPanel.decisions => DecisionsPage(
          key: const ValueKey('max-decisions'),
          stream: widget.stream,
        ),
      DashboardPanel.notifications => NotificationsPage(
          key: const ValueKey('max-notifications'),
          stream: widget.stream,
        ),
    };

    return Scaffold(
      backgroundColor: identColors(context).shell,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 88),
                child: PanelFrame(
                  title: '${widget.stream} · ${_panel.title}',
                  onRestore: () => Navigator.of(context).pop(),
                  child: body,
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 12,
              child: Center(
                child: _PanelDock(
                  current: _panel,
                  onSelect: handleSelect,
                  onClose: () => Navigator.of(context).pop(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Pill of four panel icons plus a "back to dashboard" close.
///
/// Floats above the panel content rather than docking into the frame, so it
/// works with panels that already own their vertical space (the AIS map, the
/// notifications list). The current panel's icon reads as selected without
/// covering it.
class _PanelDock extends StatelessWidget {
  const _PanelDock({
    required this.current,
    required this.onSelect,
    required this.onClose,
  });

  final DashboardPanel current;
  final ValueChanged<DashboardPanel> onSelect;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(
          color: identColors(context).surface.withValues(alpha: 0.95),
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: const Color(0x2AFFFFFF)),
          boxShadow: const [
            BoxShadow(color: Color(0x66000000), blurRadius: 12, offset: Offset(0, 4)),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final panel in DashboardPanel.values)
              _DockButton(
                icon: panel.icon,
                tooltip: panel.title,
                selected: panel == current,
                onPressed: () => onSelect(panel),
              ),
            const SizedBox(width: 4),
            Container(
              width: 1,
              height: 24,
              color: const Color(0x2AFFFFFF),
            ),
            const SizedBox(width: 4),
            _DockButton(
              icon: Icons.grid_view_outlined,
              tooltip: 'Back to dashboard',
              selected: false,
              onPressed: onClose,
            ),
          ],
        ),
      ),
    );
  }
}

class _DockButton extends StatelessWidget {
  const _DockButton({
    required this.icon,
    required this.tooltip,
    required this.selected,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = identColors(context);
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: onPressed,
        radius: 24,
        child: Container(
          width: 44,
          height: 44,
          margin: const EdgeInsets.symmetric(horizontal: 2),
          decoration: BoxDecoration(
            color: selected ? palette.accent : Colors.transparent,
            shape: BoxShape.circle,
          ),
          child: Icon(
            icon,
            size: 20,
            color: selected ? palette.shell : palette.textSecondary,
          ),
        ),
      ),
    );
  }
}

/// AIS while maximised — the map, plus a floating recording strip.
///
/// The strip is laid over the map's bottom edge in portrait and its right
/// edge in landscape, so the primary axis of the map is preserved either way.
/// Tapping a thumbnail pins the application clock to that recording; nothing
/// else opens. The map re-fetches its vessels for the new moment, which is the
/// whole point of picking a recording from an AIS view.
class _AisMaximised extends ConsumerWidget {
  const _AisMaximised({super.key, required this.stream});

  final String stream;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final files = ref.watch(streamFilesProvider(stream)).valueOrNull;
    final active = ref.watch(activeFileProvider(stream));

    // Landscape → strip runs down the right edge; portrait → along the bottom.
    // Same rule the file viewer uses, so the two placements read as the same
    // control at the same size.
    final isLandscape = MediaQuery.orientationOf(context) == Orientation.landscape;

    final _AisFileStrip? strip = (files == null || files.isEmpty)
        ? null
        : _AisFileStrip(
            stream: stream,
            files: files,
            activeName: active?.name,
            vertical: isLandscape,
          );

    return Stack(
      children: [
        // Full-bleed map underneath — the strip is a true overlay rather than
        // a docked panel, so the map keeps every pixel of its axis. Full-
        // gesture, because inside this route nothing competes with a
        // one-finger pan.
        Positioned.fill(
          child: AisPage(stream: stream, fullGestureMap: true),
        ),
        if (strip != null)
          if (isLandscape)
            Positioned(
              top: 0,
              bottom: 0,
              right: 0,
              width: kFileStripThickness,
              child: strip,
            )
          else
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: kFileStripThickness,
              child: strip,
            ),
      ],
    );
  }
}

class _AisFileStrip extends ConsumerWidget {
  const _AisFileStrip({
    required this.stream,
    required this.files,
    required this.activeName,
    required this.vertical,
  });

  final String stream;
  final List<StreamFile> files;
  final String? activeName;
  final bool vertical;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Which entry in `files` is the current one. When the clock lands between
    // recordings the resolver returns nothing, and passing -1 is what the
    // strip reads as "no active lane" — nothing is highlighted, nothing is
    // scrolled to.
    final activeIndex = activeName == null
        ? -1
        : files.indexWhere((f) => f.name == activeName);

    return FileStrip(
      folder: stream,
      files: files,
      activeIndex: activeIndex,
      vertical: vertical,
      anchor: FileStripAnchor.end,
      background: identColors(context).surface.withValues(alpha: 0.92),
      onTap: (i) {
        // Tap pins the application clock. No popup, no drawer — the user asked
        // for the recording behind that thumbnail, so put the app there. The
        // AIS view re-queries against the new moment automatically.
        ref
            .read(streamClockProvider(stream).notifier)
            .pin(files[i].startTime, ClockSource.recording);
      },
    );
  }
}
