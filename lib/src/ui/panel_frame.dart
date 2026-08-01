/// One dashboard panel, framed with a compact header.
///
/// The tiled iPad dashboard shows four of these at once — Live images, AIS,
/// Decisions and Notifications — and each has to earn its own space. The
/// existing panels already own their internal header (spans, filters, chip
/// rows), so this wrapper contributes only what the phone dashboard's app bar
/// used to: the panel's name and the maximise affordance that takes it
/// full-screen.
///
/// Nothing in here is tablet-only: the same frame is reused as the header of
/// the maximised route, so the appearance and controls stay consistent
/// between the tile and its full-screen version. Only the icon changes —
/// `maximise` in the tile, `close` in the max view.
library;

import 'package:flutter/material.dart';

import '../theme.dart';

class PanelFrame extends StatelessWidget {
  const PanelFrame({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
    this.onMaximise,
    this.onRestore,
  });

  final String title;
  final Widget child;

  /// Extra header actions, drawn to the left of the maximise button.
  final Widget? trailing;

  /// Tap → open this panel full-screen. When set, a ⤢ button is drawn.
  final VoidCallback? onMaximise;

  /// Tap → return to the tiled dashboard. When set, an ✕ button is drawn
  /// instead of the maximise one. Exactly one of the two is expected.
  final VoidCallback? onRestore;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: IdentColors.shell,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0x2AFFFFFF)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          _Header(
            title: title,
            trailing: trailing,
            onMaximise: onMaximise,
            onRestore: onRestore,
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.title,
    required this.trailing,
    required this.onMaximise,
    required this.onRestore,
  });

  final String title;
  final Widget? trailing;
  final VoidCallback? onMaximise;
  final VoidCallback? onRestore;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 4, 4, 4),
      decoration: const BoxDecoration(
        color: IdentColors.surface,
        border: Border(bottom: BorderSide(color: Color(0x1FFFFFFF))),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: IdentColors.textSecondary,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
              ),
            ),
          ),
          ?trailing,
          if (onRestore != null)
            IconButton(
              icon: const Icon(Icons.close_fullscreen),
              iconSize: 18,
              tooltip: 'Restore panel',
              onPressed: onRestore,
            )
          else if (onMaximise != null)
            IconButton(
              icon: const Icon(Icons.open_in_full),
              iconSize: 18,
              tooltip: 'Maximise panel',
              onPressed: onMaximise,
            ),
        ],
      ),
    );
  }
}
