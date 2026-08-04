/// IDent Dynamics — mobile companion.
///
/// A read-only monitor for the streams a user is subscribed to: their health at
/// a glance, the alerts they have raised, and the live spectrogram waterfall.
/// Authoring, model editing and the WebGL render stay in the web app.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/auth.dart';
import 'src/providers.dart';
import 'src/theme.dart';
import 'src/theme_mode.dart';
import 'src/ui/ident_logo.dart';
import 'src/ui/login_screen.dart';
import 'src/ui/streams_screen.dart';

/// Ceiling on decoded spectrogram snapshots held in memory.
///
/// Flutter's default is 1000 images / 100 MiB, which was written for a screen
/// showing a handful of photographs. This app scrolls a thumbnail strip across
/// folders of several thousand recordings, so it will fill whatever it is given
/// and then sit at that size for the rest of the session.
///
/// Snapshots are 200x64, so ~51 KB decoded: 400 of them is about 20 MB, and the
/// strip only ever shows six or seven at once. Anything evicted is still on
/// disk — `cached_network_image` re-reads it without touching the network.
const _imageCacheCount = 400;
const _imageCacheBytes = 32 << 20;   // 32 MiB

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  PaintingBinding.instance.imageCache
    ..maximumSize = _imageCacheCount
    ..maximumSizeBytes = _imageCacheBytes;
  runApp(const ProviderScope(child: IdentApp()));
}

class IdentApp extends ConsumerStatefulWidget {
  const IdentApp({super.key});

  @override
  ConsumerState<IdentApp> createState() => _IdentAppState();
}

class _IdentAppState extends ConsumerState<IdentApp> {
  @override
  void initState() {
    super.initState();
    // Restore any stored session before the first frame settles, so a returning
    // user goes straight to their streams rather than flashing the login form.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(authControllerProvider).restore();
    });
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    final themeMode = ref.watch(themeModeProvider);

    return MaterialApp(
      title: 'IDent Dynamics',
      debugShowCheckedModeBanner: false,
      theme: buildIdentTheme(brightness: Brightness.light),
      darkTheme: buildIdentTheme(brightness: Brightness.dark),
      themeMode: themeMode,
      home: switch (auth.state) {
        AuthLoading() => const _Splash(),
        AuthSignedOut(:final lastBaseUrl, :final error) => LoginScreen(
            // Keyed so that a session expiry rebuilds the form rather than
            // reusing the previous one's field state.
            key: ValueKey(error),
            initialBaseUrl: lastBaseUrl,
            notice: error,
          ),
        AuthSignedIn() => const StreamsScreen(),
      },
    );
  }
}

/// First frame the app draws while auth is being restored.
///
/// The lockup sits on top of the product's tagline, "Go / beyond /
/// automation.", one word per line and left-justified — the mark and the
/// promise as one composition, sized to earn most of the screen rather than
/// float as a small badge in the middle. A quiet spinner underneath does
/// double duty as the load indicator; nothing else moves.
class _Splash extends StatelessWidget {
  const _Splash();

  /// Fraction of the shortest screen side the splash block should occupy.
  ///
  /// Keyed to the short side rather than to width or height alone so the
  /// composition holds together on a phone, an iPad in portrait and an iPad
  /// in landscape without a per-orientation layout.
  static const _fillFraction = 0.70;

  @override
  Widget build(BuildContext context) {
    final palette = identColors(context);
    return Scaffold(
      body: Center(
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Size the composition to a square [_fillFraction] of the
            // shortest side, then let it grow with the taller axis if there
            // is room. Bounded either way, so the tagline stays legible on a
            // narrow phone and stays proportioned on a wide iPad.
            final short = constraints.biggest.shortestSide;
            final side = short * _fillFraction;

            // Three lines of tagline plus the lockup: allot roughly a fifth of
            // the block's height to each line, and a quarter to the lockup and
            // the gap beneath it. Font size follows line height with a small
            // margin for descenders.
            final lineHeight = side * 0.22;
            final fontSize = lineHeight * 0.95;
            final lockupScale = side / 90;

            return SizedBox(
              width: side,
              height: side,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  IdentLockup(scale: lockupScale),
                  SizedBox(height: side * 0.08),
                  Text(
                    'Go\nbeyond\nautomation.',
                    textAlign: TextAlign.left,
                    style: TextStyle(
                      color: palette.textPrimary,
                      fontSize: fontSize,
                      fontWeight: FontWeight.w300,
                      height: 1.0,
                      letterSpacing: -fontSize * 0.02,
                    ),
                  ),
                  SizedBox(height: side * 0.08),
                  const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
