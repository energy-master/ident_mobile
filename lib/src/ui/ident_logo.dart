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

  /// The wordmark's laid-out height, from the two line boxes below.
  ///
  /// Exists so [IdentLockup] can size the divider without measuring: an
  /// `IntrinsicHeight` would have to interrogate the company logo, whose
  /// intrinsic size is zero until the bytes arrive over the network.
  static double heightFor(double scale) => (15 * 1.05 + 9 * 1.1) * scale;

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

/// The φ that closes the lockup.
///
/// `.logo-phi` in styles.css:956 — Courier rather than the wordmark's monospace,
/// and set light. Courier ships no light weight, so the web asking for 200 gets
/// regular; the stroke reads thin because Courier is thin, not because a weight
/// was found. Asking for w300 here rather than w200 keeps Flutter from
/// synthesising one.
///
/// This is also the app icon (see `tool/generate_icons.py`), which is the point:
/// the mark on the home screen is the mark that closes the header.
class IdentPhi extends StatelessWidget {
  const IdentPhi({super.key, this.scale = 1});

  /// Matches [IdentLogo.scale] — 2.4rem against the wordmark's 1.35rem.
  final double scale;

  @override
  Widget build(BuildContext context) {
    return Text(
      'φ',
      style: TextStyle(
        color: identGreen,
        fontFamily: 'Courier New',
        fontFamilyFallback: const ['Courier', 'monospace'],
        fontWeight: FontWeight.w300,
        fontSize: 15 * (2.4 / 1.35) * scale,
        // No `height: 1` despite the CSS. There it stops an inline box adding
        // leading inside a flex row; here it would crop the line box below
        // Courier's descender, and φ has one. The extra space is transparent
        // and the glyph is top-anchored, so it costs nothing visible.
      ),
    );
  }
}

/// The full mark: wordmark, divider, and a closing glyph.
///
/// One lockup, because the web has one. `#app-logo` in index.php and
/// `.auth-logo` on the sign-in pages differ only in size — both are
/// `IDent dynamics | φ`, and both swap a company mark in for the φ when the
/// install or the account has one. Keeping the sign-in screen and the app bar on
/// this single widget is what stops them drifting into two different marks.
///
/// [mark] replaces the φ; it does not sit beside it. The divider stays either
/// way, so the lockup reads as one unit at every size:
///
///     IDent dynamics  |  φ         the hosted install, no lead logo
///     IDent dynamics  |  <logo>    a client implementation
class IdentLockup extends StatelessWidget {
  const IdentLockup({super.key, this.scale = 1, this.mark});

  final double scale;

  /// What closes the lockup. Null gives the φ, which is the default state on
  /// goident.ai rather than an edge case.
  final Widget? mark;

  @override
  Widget build(BuildContext context) {
    // 0.6rem against the wordmark's 1.35rem, either side of the rule.
    final gap = 10.0 * scale;

    // Everything top-aligned, which is `align-self: flex-start` on the closing
    // glyph: it sits in line with "IDent" rather than floating against the
    // middle of the wordmark.
    //
    // Deliberately not IntrinsicHeight + `align-items: stretch`, the faithful
    // translation of the CSS. That makes the row's height depend on the
    // intrinsic height of every child, and a company logo is an `Image.network`
    // whose intrinsic height is zero until the bytes land — so the row collapses
    // around a mark that has not arrived yet. The divider spans the wordmark,
    // which is a height known without measuring anything.
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        IdentLogo(scale: scale),
        SizedBox(width: gap),
        // currentColor at 0.45 — the rule is the wordmark's own green, not a
        // neutral divider. A hairline at every scale, as in the CSS.
        SizedBox(
          width: 1,
          height: IdentLogo.heightFor(scale),
          child: ColoredBox(color: identGreen.withValues(alpha: 0.45)),
        ),
        SizedBox(width: gap),
        mark ?? IdentPhi(scale: scale),
      ],
    );
  }
}

/// The lockup as the app bar wears it, closed by the account's company logo when
/// the lead has uploaded one.
///
/// The divider used to be drawn only alongside a logo, which left goident.ai —
/// where most accounts have no lead logo — showing a bare wordmark and no φ.
///
/// Failure is silent, and now has somewhere to fall back to: a missing or slow
/// logo shows the φ rather than a broken-image box or a gap, so the lockup is
/// never caught mid-way and branding never reads as an error. That is also how
/// the web arrives at it — the SPA renders the φ and a script swaps the mark in
/// once it resolves (auth.php:145).
class BrandingRow extends StatelessWidget {
  const BrandingRow({super.key, this.logoUrl, this.companyName});

  final String? logoUrl;
  final String? companyName;

  @override
  Widget build(BuildContext context) {
    final url = logoUrl;
    if (url == null) return const IdentLockup();

    return IdentLockup(
      mark: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 28, maxWidth: 120),
        child: Image.network(
          url,
          fit: BoxFit.contain,
          semanticLabel: (companyName == null || companyName!.isEmpty)
              ? 'Company logo'
              : '$companyName logo',
          errorBuilder: (_, _, _) => const IdentPhi(),
          loadingBuilder: (context, child, progress) =>
              progress == null ? child : const IdentPhi(),
        ),
      ),
    );
  }
}
