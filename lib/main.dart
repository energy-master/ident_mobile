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
import 'src/ui/login_screen.dart';
import 'src/ui/streams_screen.dart';

void main() {
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

    return MaterialApp(
      title: 'IDent Dynamics',
      debugShowCheckedModeBanner: false,
      theme: buildIdentTheme(),
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

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.graphic_eq, size: 52, color: IdentColors.accent),
            SizedBox(height: 20),
            SizedBox(
              height: 20,
              width: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ],
        ),
      ),
    );
  }
}
