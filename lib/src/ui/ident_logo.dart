/// The IDent dynamics wordmark, and the branding row that pairs it with the
/// account's company logo.
///
/// The web app has no logo image to copy — `#app-logo` in index.php is CSS-set
/// type (styles.css:900), so this reproduces it: monospace, weight 700, in
/// #3dd68c, with "IDent" over a wider-tracked lowercase "dynamics". The company
/// mark sits to its right behind a divider, the same order as the SPA splash.
library;

import 'package:flutter/material.dart';

/// Wordmark green, from `#app-logo` in styles.css.
const identGreen = Color(0xFF3DD68C);

class IdentLogo extends StatelessWidget {
  const IdentLogo({super.key, this.scale = 1});

  /// 1 matches the app-bar size; raise it for splash-sized use.
  final double scale;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'IDent dynamics',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'IDent',
            style: TextStyle(
              color: identGreen,
              fontFamily: 'monospace',
              fontWeight: FontWeight.w700,
              fontSize: 15 * scale,
              letterSpacing: 0.04 * 15 * scale,
              height: 1.05,
            ),
          ),
          Text(
            'dynamics',
            style: TextStyle(
              color: identGreen.withValues(alpha: 0.9),
              fontFamily: 'monospace',
              fontWeight: FontWeight.w500,
              fontSize: 9 * scale,
              // 0.18em tracking is what gives the mark its spread-out lower line.
              letterSpacing: 0.18 * 9 * scale,
              height: 1.1,
            ),
          ),
        ],
      ),
    );
  }
}

/// The IDent wordmark, then the company logo when the account's lead has one.
///
/// Failure is silent: a missing or slow logo collapses to the wordmark alone
/// rather than showing a broken-image box or a gap, because branding is
/// decoration and must never read as an error.
class BrandingRow extends StatelessWidget {
  const BrandingRow({super.key, this.logoUrl, this.companyName});

  final String? logoUrl;
  final String? companyName;

  @override
  Widget build(BuildContext context) {
    final url = logoUrl;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const IdentLogo(),
        if (url != null) ...[
          const SizedBox(width: 10),
          Container(width: 1, height: 26, color: const Color(0x3DFFFFFF)),
          const SizedBox(width: 10),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 28, maxWidth: 120),
            child: Image.network(
              url,
              fit: BoxFit.contain,
              semanticLabel: (companyName == null || companyName!.isEmpty)
                  ? 'Company logo'
                  : '$companyName logo',
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
              loadingBuilder: (context, child, progress) =>
                  progress == null ? child : const SizedBox.shrink(),
            ),
          ),
        ],
      ],
    );
  }
}
