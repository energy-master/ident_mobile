/// Sign-in state and its durable storage.
///
/// The bearer token is the whole of the app's credential, so it lives in the
/// platform keystore (Keychain on iOS, EncryptedSharedPreferences on Android)
/// via flutter_secure_storage — never in plain preferences. The server URL and
/// the cached user are not secret and ride along in the same store purely to
/// keep all session state in one place.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'api_client.dart';
import 'models.dart';

/// A restored or freshly-created session.
@immutable
class Session {
  const Session({required this.baseUrl, required this.token, required this.user});

  final String baseUrl;
  final String token;
  final AuthUser user;
}

/// Where the app is in its sign-in lifecycle.
sealed class AuthState {
  const AuthState();
}

/// Reading the keystore on launch — shows a splash rather than flashing login.
class AuthLoading extends AuthState {
  const AuthLoading();
}

/// No usable session; [error] is set when the previous one was rejected.
class AuthSignedOut extends AuthState {
  const AuthSignedOut({this.lastBaseUrl, this.error});
  final String? lastBaseUrl;
  final String? error;
}

class AuthSignedIn extends AuthState {
  const AuthSignedIn(this.session);
  final Session session;
}

/// Reads and writes the session. Kept separate from the controller so it can be
/// faked in tests without touching platform channels.
class AuthStore {
  AuthStore([FlutterSecureStorage? storage])
      // Android encrypts via the plugin's own ciphers now (the Jetpack Security
      // path is deprecated upstream), so only the iOS accessibility class needs
      // stating: first_unlock lets a background refresh read the token after a
      // reboot without the user having unlocked the device again.
      : _storage = storage ??
            const FlutterSecureStorage(
              iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
            );

  final FlutterSecureStorage _storage;

  static const _kToken = 'ident.token';
  static const _kBaseUrl = 'ident.base_url';
  static const _kUser = 'ident.user';

  Future<Session?> read() async {
    final token = await _storage.read(key: _kToken);
    final baseUrl = await _storage.read(key: _kBaseUrl);
    final userRaw = await _storage.read(key: _kUser);
    if (token == null || token.isEmpty || baseUrl == null || baseUrl.isEmpty) {
      return null;
    }
    AuthUser user = const AuthUser(id: 0, username: '', email: '', role: 'user');
    if (userRaw != null && userRaw.isNotEmpty) {
      try {
        user = AuthUser.fromJson(Map<String, dynamic>.from(jsonDecode(userRaw) as Map));
      } on FormatException {
        // Corrupt cache is not worth failing a restore over — the token is what
        // actually authenticates, and the profile refreshes on next login.
      }
    }
    return Session(baseUrl: baseUrl, token: token, user: user);
  }

  Future<void> write(Session session) async {
    await _storage.write(key: _kToken, value: session.token);
    await _storage.write(key: _kBaseUrl, value: session.baseUrl);
    await _storage.write(key: _kUser, value: jsonEncode(session.user.toJson()));
  }

  /// Clear the token but keep the server URL, so a user signing back in on the
  /// same install does not have to retype it.
  Future<String?> clear() async {
    final baseUrl = await _storage.read(key: _kBaseUrl);
    await _storage.delete(key: _kToken);
    await _storage.delete(key: _kUser);
    return baseUrl;
  }
}

/// Owns [AuthState] and the [ApiClient] bound to the current session.
class AuthController extends ChangeNotifier {
  AuthController({AuthStore? store}) : _store = store ?? AuthStore();

  final AuthStore _store;

  AuthState _state = const AuthLoading();
  AuthState get state => _state;

  ApiClient? _client;

  /// The authenticated client. Only valid while [state] is [AuthSignedIn].
  ApiClient get client {
    final c = _client;
    if (c == null) {
      throw StateError('ApiClient requested while signed out');
    }
    return c;
  }

  void _set(AuthState next) {
    _state = next;
    notifyListeners();
  }

  /// Restore a stored session on launch. The token is not validated here — the
  /// first real request does that, and a 401 routes through [handleAuthFailure].
  /// Validating up front would add a blocking round trip to every cold start.
  Future<void> restore() async {
    final session = await _store.read();
    if (session == null) {
      _set(const AuthSignedOut());
      return;
    }
    _client = ApiClient(baseUrl: session.baseUrl, token: session.token);
    _set(AuthSignedIn(session));
  }

  Future<void> signIn({
    required String baseUrl,
    required String login,
    required String password,
    required String device,
  }) async {
    final normalised = ApiClient.normaliseBaseUrl(baseUrl);
    final anon = ApiClient(baseUrl: normalised);
    final result = await anon.login(login: login, password: password, device: device);
    final session = Session(
      baseUrl: normalised,
      token: result.token,
      user: result.user,
    );
    await _store.write(session);
    _client = anon.withToken(result.token);
    _set(AuthSignedIn(session));
  }

  /// User-initiated sign-out. Revoking server-side is best-effort so that being
  /// offline can never trap someone in a session they asked to leave.
  Future<void> signOut() async {
    try {
      await _client?.logout();
    } on ApiException {
      // Token already invalid — nothing to revoke.
    } on NetworkException {
      // Offline — the local clear below still takes effect.
    }
    final lastBaseUrl = await _store.clear();
    _client = null;
    _set(AuthSignedOut(lastBaseUrl: lastBaseUrl));
  }

  /// A request came back 401: the token was revoked or expired. Drop the
  /// session and send the user back to sign-in with an explanation.
  Future<void> handleAuthFailure([String? message]) async {
    final lastBaseUrl = await _store.clear();
    _client = null;
    _set(AuthSignedOut(
      lastBaseUrl: lastBaseUrl,
      error: message ?? 'Your session has ended. Please sign in again.',
    ));
  }
}
