/// Sign-in.
///
/// Trades credentials for a bearer token via `api/idapi/login.php`. The server
/// URL is editable but prefilled, because most users are on the hosted install
/// and should never have to think about it; the field exists for self-hosted
/// and subdirectory deployments, which auth.php supports.
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api_client.dart';
import '../providers.dart';
import '../theme.dart';
import 'ident_logo.dart';

/// The hosted install. Overridable in the field below for self-hosted sites.
const _defaultBaseUrl = 'https://goident.ai';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key, this.initialBaseUrl, this.notice});

  /// Carried over from a previous session so signing back in needs no retyping.
  final String? initialBaseUrl;

  /// Why the user is here, when they did not choose to be (expired token).
  final String? notice;

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _baseUrl =
      TextEditingController(text: widget.initialBaseUrl ?? _defaultBaseUrl);
  final _login = TextEditingController();
  final _password = TextEditingController();

  bool _busy = false;
  bool _obscure = true;
  String? _error;
  bool _showServerField = false;

  @override
  void initState() {
    super.initState();
    // Only surface the server field up front when it is not the hosted default —
    // i.e. this install has been pointed somewhere else before.
    _showServerField =
        widget.initialBaseUrl != null && widget.initialBaseUrl != _defaultBaseUrl;
  }

  @override
  void dispose() {
    _baseUrl.dispose();
    _login.dispose();
    _password.dispose();
    super.dispose();
  }

  /// Names the token in the user's account page, so they can tell which handset
  /// a token belongs to and revoke it.
  String get _deviceLabel {
    if (kIsWeb) return 'web';
    try {
      return Platform.isIOS ? 'iOS device' : (Platform.isAndroid ? 'Android device' : Platform.operatingSystem);
    } catch (_) {
      return 'mobile app';
    }
  }

  Future<void> handleSubmit() async {
    if (_busy) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;

    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      await ref.read(authControllerProvider).signIn(
            baseUrl: _baseUrl.text,
            login: _login.text.trim(),
            password: _password.text,
            device: _deviceLabel,
          );
      // On success the app shell swaps this screen out; nothing to do here.
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          // A bad base URL shows up as a non-JSON response — reveal the field
          // so the user can actually fix the thing that is wrong.
          if (e.error == 'bad_response') _showServerField = true;
        });
      }
    } on NetworkException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          _showServerField = true;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final notice = widget.notice;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // The real wordmark rather than a generic icon — this is the
                    // first thing a user sees, so it should be the product's own
                    // mark, at splash scale.
                    const Center(child: IdentLogo(scale: 2.4)),
                    const SizedBox(height: 20),
                    const Text(
                      'Sign in to monitor your streams',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: IdentColors.textSecondary),
                    ),
                    const SizedBox(height: 28),

                    if (notice != null) ...[
                      _Banner(message: notice, colour: IdentColors.warn),
                      const SizedBox(height: 16),
                    ],

                    TextFormField(
                      controller: _login,
                      decoration: const InputDecoration(
                        labelText: 'Username or email',
                        prefixIcon: Icon(Icons.person_outline),
                      ),
                      keyboardType: TextInputType.emailAddress,
                      autocorrect: false,
                      autofillHints: const [AutofillHints.username],
                      textInputAction: TextInputAction.next,
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? 'Enter your username or email' : null,
                    ),
                    const SizedBox(height: 12),

                    TextFormField(
                      controller: _password,
                      decoration: InputDecoration(
                        labelText: 'Password',
                        prefixIcon: const Icon(Icons.lock_outline),
                        suffixIcon: IconButton(
                          icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                          onPressed: () => setState(() => _obscure = !_obscure),
                          tooltip: _obscure ? 'Show password' : 'Hide password',
                        ),
                      ),
                      obscureText: _obscure,
                      autofillHints: const [AutofillHints.password],
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) => handleSubmit(),
                      validator: (v) => (v == null || v.isEmpty) ? 'Enter your password' : null,
                    ),

                    if (_showServerField) ...[
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _baseUrl,
                        decoration: const InputDecoration(
                          labelText: 'Server',
                          prefixIcon: Icon(Icons.dns_outlined),
                          helperText: 'Only change this for a self-hosted install',
                        ),
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        validator: (v) =>
                            (v == null || v.trim().isEmpty) ? 'Enter the server address' : null,
                      ),
                    ],

                    if (_error != null) ...[
                      const SizedBox(height: 16),
                      _Banner(message: _error!, colour: IdentColors.error),
                    ],

                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: _busy ? null : handleSubmit,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                      child: _busy
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Sign in'),
                    ),

                    if (!_showServerField) ...[
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: () => setState(() => _showServerField = true),
                        child: const Text('Use a different server'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.message, required this.colour});

  final String message;
  final Color colour;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.12),
        border: Border.all(color: colour.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        message,
        style: TextStyle(color: colour, fontSize: 13),
      ),
    );
  }
}
