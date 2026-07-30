/// Sign-in.
///
/// Trades credentials for a bearer token via `api/idapi/login.php`. The address
/// is editable but prefilled, because most users are on the hosted install and
/// should never have to think about it; the field exists for self-hosted and
/// subdirectory deployments, which auth.php supports.
///
/// It asks for the **IDent Dynamics site**, not a Brahma address — the same URL
/// the web app is served from. That distinction is worth the longer label: the
/// framework runs on its own host and the site is configured against it, but
/// nothing a client renders comes from the framework directly. See the
/// "Where this app points" section of the README.
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show TextInput;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api_client.dart';
import '../providers.dart';
import '../recent_sign_ins.dart';
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

  /// Null until the user expresses an opinion, then it wins.
  ///
  /// The saved-site list loads asynchronously, after initState. Deriving
  /// visibility in build lets a late-arriving list reveal the field, while the
  /// override means it can never be yanked away from someone who has just
  /// opened it.
  bool? _showServerOverride;

  @override
  void initState() {
    super.initState();
    // Only surface the server field up front when it is not the hosted default —
    // i.e. this install has been pointed somewhere else before. Saved sites can
    // also reveal it once they load; see _showServer.
    if (widget.initialBaseUrl != null && widget.initialBaseUrl != _defaultBaseUrl) {
      _showServerOverride = true;
    }
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

    // Captured BEFORE any await. On success the app shell swaps this screen out
    // the moment auth state flips, and `ref` throws once the widget is disposed
    // — on exactly the path that has to work.
    final auth = ref.read(authControllerProvider);
    final recents = ref.read(recentSignInsProvider.notifier);

    // The site field is unmounted while hidden, and a Form only validates the
    // FormFields currently in the tree — so its own validator cannot be relied
    // on. Check it here regardless, and reveal the field to explain a failure
    // the user would otherwise not be able to see.
    final siteError = validateSiteAddress(_baseUrl.text);
    if (siteError != null) {
      setState(() {
        _showServerOverride = true;
        _error = siteError;
      });
      return;
    }
    if (!(_formKey.currentState?.validate() ?? false)) return;

    // Submit the canonical form, so the address signed in with, stored in
    // ident.base_url, and remembered in the list are byte-identical.
    final site = siteCanonical(_baseUrl.text);
    final username = _login.text.trim();

    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      await auth.signIn(
        baseUrl: site,
        login: username,
        password: _password.text,
        device: _deviceLabel,
      );

      // Offer the credential to the platform password manager — success only,
      // and before anything else, since nothing should delay the save prompt.
      // Never on a rejected password: a "save this password?" dialog for a
      // password that just failed is the worst outcome this screen has.
      //
      // Safe after the widget is disposed: finishAutofillContext is a static
      // service call with no BuildContext, and iOS defers tearing down its input
      // views precisely so a post-teardown call still saves.
      TextInput.finishAutofillContext();

      await recents.recordSite(site);
      await recents.recordUsername(username);
    } on ApiException catch (e) {
      // A 401 or 403 proves we reached something speaking the IDent JSON
      // protocol: the address is right and only the credentials are wrong, so
      // it is worth remembering. `bad_response` means the body was not JSON —
      // not an IDent site — and remembering that would fill the menu with
      // exactly the addresses the user needs to stop being offered.
      if (e.error != 'bad_response') await recents.recordSite(site);
      // The username is NOT recorded here. A 401 does not distinguish "no such
      // user" from "wrong password", so recording it would enshrine typos.
      if (mounted) {
        setState(() {
          _error = e.message;
          if (e.error == 'bad_response') _showServerOverride = true;
        });
      }
    } on NetworkException catch (e) {
      // Never reached the server, so nothing is proven about the address.
      if (mounted) {
        setState(() {
          _error = e.message;
          _showServerOverride = true;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Whether the site field is on screen.
  ///
  /// A saved non-default address, or more than one saved address, means the user
  /// is choosing between sites and should see the choice. Otherwise it stays
  /// behind the toggle, so the common case of one hosted site is two fields.
  bool _showServer(RecentSignIns recents) =>
      _showServerOverride ??
      (recents.sites.length >= 2 ||
          (widget.initialBaseUrl ?? _defaultBaseUrl) != _defaultBaseUrl ||
          (recents.sites.mostRecent ?? _defaultBaseUrl) != _defaultBaseUrl);

  void _forget(RecentKind kind, String value) {
    final recents = ref.read(recentSignInsProvider.notifier);
    if (kind == RecentKind.site) {
      recents.forgetSite(value);
    } else {
      recents.forgetUsername(value);
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('Forgot $value'),
          // Undo rather than a confirm dialog: deliberate, reversible, one tap.
          // It returns to the front of the list rather than its old position,
          // which is a fair trade for not tracking removed indices.
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () => kind == RecentKind.site
                ? recents.recordSite(value)
                : recents.recordUsername(value),
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final notice = widget.notice;
    final recents = ref.watch(recentSignInsProvider);
    final showServer = _showServer(recents);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              // One autofill context per screen. `cancel` on dispose, not the
              // default `commit`: commit-on-dispose fires on ANY teardown, so a
              // future route push or a rebuild would prompt "save this
              // password?" for whatever was half-typed. handleSubmit commits
              // explicitly, on success only.
              child: AutofillGroup(
                onDisposeAction: AutofillContextAction.cancel,
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // The real wordmark rather than a generic icon — this is the
                      // first thing a user sees, so it should be the product's own
                      // mark, at splash scale.
                      // The full lockup, φ included — `.auth-logo` in
                      // login.php carries the same mark as the app bar, only
                      // larger.
                      const Center(child: IdentLockup(scale: 2.4)),
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

                      _RecalledField(
                        controller: _login,
                        recent: recents.usernames,
                        onForget: (v) => _forget(RecentKind.username, v),
                        builder: (decoration) => TextFormField(
                          controller: _login,
                          decoration: decoration,
                          keyboardType: TextInputType.emailAddress,
                          autocorrect: false,
                          autofillHints: const [AutofillHints.username],
                          textInputAction: TextInputAction.next,
                          validator: (v) => (v == null || v.trim().isEmpty)
                              ? 'Enter your username or email'
                              : null,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'Username or email',
                          prefixIcon: Icon(Icons.person_outline),
                        ),
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

                      if (showServer) ...[
                        const SizedBox(height: 12),
                        _RecalledField(
                          controller: _baseUrl,
                          recent: recents.sites,
                          onForget: (v) => _forget(RecentKind.site, v),
                          builder: (decoration) => TextFormField(
                            controller: _baseUrl,
                            decoration: decoration,
                            keyboardType: TextInputType.url,
                            autocorrect: false,
                            // Explicitly null, not omitted. The default is `const
                            // []`, which is NOT autofill-neutral: an AutofillGroup
                            // ships every enabled client in the group to the
                            // platform, so an omitted value would enter the
                            // credential context as an untyped field — and its
                            // membership changes as this field is toggled, which
                            // breaks the rule that a group's clients are built
                            // together. Null keeps it out entirely.
                            autofillHints: null,
                            validator: (v) => validateSiteAddress(v ?? ''),
                          ),
                          decoration: const InputDecoration(
                            labelText: 'IDent site address',
                            prefixIcon: Icon(Icons.dns_outlined),
                            helperText:
                                'Your IDent Dynamics site — the same address as its web app',
                          ),
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

                      // Only offer to re-hide when the hidden value would be the
                      // known-good default. With a saved site in the field,
                      // hiding it would silently discard the address the user
                      // actually needs.
                      if (!showServer) ...[
                        const SizedBox(height: 8),
                        TextButton(
                          onPressed: () => setState(() => _showServerOverride = true),
                          child: const Text('Use a different IDent site'),
                        ),
                      ] else if (recents.sites.isEmpty &&
                          (widget.initialBaseUrl ?? _defaultBaseUrl) == _defaultBaseUrl) ...[
                        const SizedBox(height: 8),
                        TextButton(
                          onPressed: () => setState(() {
                            _baseUrl.text = _defaultBaseUrl;
                            _showServerOverride = false;
                          }),
                          child: const Text('Use the standard IDent site'),
                        ),
                      ],

                      const SizedBox(height: 20),
                      _PrivacyLink(baseUrl: _baseUrl),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The signed-in site's privacy policy, opened in the browser.
///
/// App Store review wants the policy reachable from inside the app, not only
/// from the App Store Connect metadata field, and the sign-in screen is the only
/// place every user passes through.
///
/// The URL is built from whatever site is in the field rather than hardcoded to
/// the hosted install: on a self-hosted deployment it is that operator, not
/// Vixen, who holds the user's data, and `privacy.php` is part of the site the
/// app is signing into.
class _PrivacyLink extends StatelessWidget {
  const _PrivacyLink({required this.baseUrl});

  /// The live controller, not its text: the address can be edited after this
  /// widget builds, and the policy that matters is the one for the site the
  /// user is about to sign into.
  final TextEditingController baseUrl;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: () async {
        final typed = baseUrl.text.trim();
        final base = ApiClient.normaliseBaseUrl(
          typed.isEmpty ? _defaultBaseUrl : typed,
        );
        final uri = Uri.tryParse('$base/privacy.php');
        if (uri == null) return;
        // Silent on failure — `launchUrl` throws when no handler is registered,
        // and a policy that will not open is not worth an error banner on the
        // screen someone is trying to sign in from.
        try {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        } catch (_) {}
      },
      style: TextButton.styleFrom(
        foregroundColor: IdentColors.textSecondary,
        textStyle: const TextStyle(fontSize: 12),
      ),
      child: const Text('Privacy policy'),
    );
  }
}

/// A text field that can also be filled from what this device has used before.
///
/// The field itself is built by the caller and handed straight through — the
/// same `controller`, `validator` and `autofillHints` it would have had without
/// this wrapper. All that is added is a suffix button opening a menu of past
/// values. Autofill and recall therefore never compete: the platform password
/// manager still sees an ordinary field, and this menu is an extra way in, not a
/// replacement.
///
/// A [MenuAnchor] rather than a [PopupMenuButton] or an [Autocomplete]:
///
///   * `MenuAnchor.menuChildren` is a plain widget list rendered in this
///     subtree, so an *open* menu rebuilds when an entry is forgotten.
///     `PopupMenuButton` snapshots its items into a pushed route and would keep
///     showing a row the user just deleted.
///   * `RawAutocomplete` recomputes its options only when the text changes, so
///     the same stale-row problem applies, and it pops its overlay open when the
///     OS autofills the controller — fighting the very feature this screen is
///     trying to enable.
class _RecalledField extends StatefulWidget {
  const _RecalledField({
    required this.controller,
    required this.recent,
    required this.onForget,
    required this.builder,
    required this.decoration,
  });

  final TextEditingController controller;
  final RecentValues recent;
  final ValueChanged<String> onForget;

  /// Builds the field, given the decoration with the recall button folded in.
  final Widget Function(InputDecoration) builder;

  /// The decoration the field would have had on its own.
  final InputDecoration decoration;

  @override
  State<_RecalledField> createState() => _RecalledFieldState();
}

class _RecalledFieldState extends State<_RecalledField> {
  final _menu = MenuController();

  /// Roughly the width the suffix icon occupies, used to pull the menu back
  /// under the whole field rather than hanging it off the right-hand edge.
  static const _iconSlot = 48.0;

  void _choose(String value) {
    _menu.close();
    widget.controller.value = TextEditingValue(
      text: value,
      // Caret at the end, so a value the user wants to amend rather than accept
      // is immediately editable.
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Nothing remembered yet: an ordinary field, with no button hinting at an
    // empty menu.
    if (widget.recent.isEmpty) return widget.builder(widget.decoration);

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final anchor = MenuAnchor(
          controller: _menu,
          alignmentOffset: Offset(-(width - _iconSlot), 0),
          style: MenuStyle(
            maximumSize: WidgetStatePropertyAll(Size(width, 260)),
            minimumSize: WidgetStatePropertyAll(Size(width, 0)),
          ),
          menuChildren: [
            for (final value in widget.recent.values)
              MenuItemButton(
                onPressed: () => _choose(value),
                trailingIcon: IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: 'Forget $value',
                  onPressed: () {
                    // Deliberately not closing the menu: the list is rendered
                    // in this subtree, so the row simply disappears and the
                    // user can forget several in a row.
                    widget.onForget(value);
                  },
                ),
                child: Text(value, overflow: TextOverflow.ellipsis),
              ),
          ],
          builder: (context, controller, _) => IconButton(
            icon: const Icon(Icons.expand_more),
            tooltip: 'Previously used',
            onPressed: () => controller.isOpen ? controller.close() : controller.open(),
          ),
        );
        return widget.builder(widget.decoration.copyWith(suffixIcon: anchor));
      },
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
