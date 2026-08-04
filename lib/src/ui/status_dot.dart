/// The glowing status light, ported from `.stream-dot` in styles.css.
///
/// Same three colours, same outer glow, and the same pulse on `error` — which
/// the web app disables under `prefers-reduced-motion`. Flutter surfaces that
/// same OS setting as [MediaQueryData.disableAnimations], so the opt-out is
/// honoured here too rather than dropped in the port.
library;

import 'package:flutter/material.dart';

import '../models.dart';
import '../theme.dart';

class StatusDot extends StatefulWidget {
  const StatusDot({
    super.key,
    required this.status,
    this.size = 11,
    this.semanticLabel,
  });

  final CheckStatus status;
  final double size;
  final String? semanticLabel;

  @override
  State<StatusDot> createState() => _StatusDotState();
}

class _StatusDotState extends State<StatusDot> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  void _syncAnimation({required bool allowMotion}) {
    final shouldPulse = widget.status == CheckStatus.error && allowMotion;
    if (shouldPulse && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    } else if (!shouldPulse && _pulse.isAnimating) {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final allowMotion = !MediaQuery.disableAnimationsOf(context);
    _syncAnimation(allowMotion: allowMotion);

    final colour = identColors(context).forStatus(widget.status);

    return Semantics(
      label: widget.semanticLabel,
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (context, _) {
          // Matches the CSS keyframes: blur 5→11, spread 1→3, alpha 0.55→0.95.
          final t = _pulse.value;
          final blur = widget.status == CheckStatus.error ? 5 + 6 * t : 6.0;
          final spread = widget.status == CheckStatus.error ? 1 + 2 * t : 1.0;
          final alpha = widget.status == CheckStatus.error ? 0.55 + 0.40 * t : 0.85;

          return Container(
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              color: colour,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: colour.withValues(alpha: alpha),
                  blurRadius: blur,
                  spreadRadius: spread,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
