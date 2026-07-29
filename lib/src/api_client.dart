/// HTTP client for the IDent Dynamics headless API (`api/idapi/*`).
///
/// Every call carries `Authorization: Bearer <token>` — the token minted by
/// `api/idapi/login.php`. There is no cookie session and no CSRF token: those
/// gate the web endpoints (`api/*.php`) and would be unusable here, which is
/// precisely why the idapi surface exists.
///
/// The server answers errors as JSON with an `error` key rather than redirecting,
/// so failures surface as a typed [ApiException] carrying the server's own
/// `detail` string — which is written for humans and safe to show directly.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

/// A failed API call. [status] is the HTTP code, [error] the server's short
/// machine key (`unauthorized`, `not_found`, …), [message] its human detail.
class ApiException implements Exception {
  const ApiException({
    required this.status,
    required this.error,
    required this.message,
  });

  final int status;
  final String error;
  final String message;

  /// The token is gone or revoked — the app must return to the login screen.
  bool get isAuthFailure => status == 401;

  /// The account is disabled, unverified, or lacks a grant for this stream.
  bool get isForbidden => status == 403;

  @override
  String toString() => message;
}

/// Thrown when the server cannot be reached at all (no network, bad host, TLS
/// failure). Kept distinct from [ApiException] so the UI can offer "retry"
/// rather than "sign in again".
class NetworkException implements Exception {
  const NetworkException(this.message);
  final String message;

  @override
  String toString() => message;
}

class ApiClient {
  ApiClient({required this.baseUrl, this.token, http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  /// Site root, e.g. `https://ident.example.com` or `https://host/ident`.
  /// Stored without a trailing slash so path joining stays predictable.
  final String baseUrl;

  /// Bearer token, or null before sign-in.
  final String? token;

  final http.Client _http;

  /// Requests that reach the server but hang are worse than a clean failure —
  /// the diagnostics call fans out to the Brahma service and can be slow, so this
  /// is generous rather than tight.
  static const Duration _timeout = Duration(seconds: 30);

  ApiClient withToken(String? newToken) =>
      ApiClient(baseUrl: baseUrl, token: newToken, httpClient: _http);

  void close() => _http.close();

  static String normaliseBaseUrl(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return s;
    if (!s.startsWith('http://') && !s.startsWith('https://')) {
      s = 'https://$s';
    }
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  Uri _uri(String path, [Map<String, String>? query]) {
    final base = Uri.parse(baseUrl);
    // Preserve any subdirectory in baseUrl (auth.php supports subdir installs),
    // so `https://host/ident` + `api/idapi/x.php` resolves correctly.
    final joined = '${base.path}/$path'.replaceAll(RegExp(r'/+'), '/');
    return base.replace(
      path: joined,
      queryParameters: (query == null || query.isEmpty) ? null : query,
    );
  }

  Map<String, String> get _headers => {
        'Accept': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };

  /// Headers for an image request — used by the spectrogram tiles, which fetch
  /// bytes directly rather than through [getJson].
  Map<String, String> get imageHeaders =>
      token == null ? const {} : {'Authorization': 'Bearer $token'};

  Future<Map<String, dynamic>> _send(Future<http.Response> Function() run) async {
    late final http.Response res;
    try {
      res = await run().timeout(_timeout);
    } on TimeoutException {
      throw const NetworkException('The server took too long to respond.');
    } catch (e) {
      throw NetworkException('Could not reach the server. ($e)');
    }

    Map<String, dynamic> body;
    try {
      final decoded = jsonDecode(res.body);
      body = decoded is Map ? Map<String, dynamic>.from(decoded) : <String, dynamic>{};
    } on FormatException {
      // A non-JSON body means we hit something other than the API — most often
      // an HTML error page from a misconfigured base URL.
      throw ApiException(
        status: res.statusCode,
        error: 'bad_response',
        message: res.statusCode >= 400
            ? 'The server returned an error (HTTP ${res.statusCode}).'
            : 'That address did not return IDent Dynamics API data. Check the server URL.',
      );
    }

    if (res.statusCode >= 400 || body['ok'] != true) {
      throw ApiException(
        status: res.statusCode,
        error: (body['error'] ?? 'error').toString(),
        message: (body['detail'] ?? body['error'] ?? 'Request failed.').toString(),
      );
    }
    return body;
  }

  Future<Map<String, dynamic>> getJson(String path, [Map<String, String>? query]) =>
      _send(() => _http.get(_uri(path, query), headers: _headers));

  Future<Map<String, dynamic>> postJson(String path, Map<String, dynamic> body) =>
      _send(() => _http.post(
            _uri(path),
            headers: {..._headers, 'Content-Type': 'application/json'},
            body: jsonEncode(body),
          ));

  // ── endpoints ─────────────────────────────────────────────────────────────

  /// Exchange credentials for a bearer token. Returns the raw token and user.
  Future<({String token, AuthUser user})> login({
    required String login,
    required String password,
    required String device,
  }) async {
    final body = await postJson('api/idapi/login.php', {
      'login': login,
      'password': password,
      'device': device,
    });
    return (
      token: (body['token'] ?? '').toString(),
      user: AuthUser.fromJson(Map<String, dynamic>.from(body['user'] as Map? ?? {})),
    );
  }

  /// Revoke this token server-side. Best-effort: the caller clears local state
  /// regardless, so a user can always sign out even when offline.
  Future<void> logout() => postJson('api/idapi/logout.php', const {});

  /// The token owner plus their company branding. Null branding means the
  /// account has no lead logo and the app shows its own mark alone.
  Future<({AuthUser user, Branding? branding})> me() async {
    final body = await getJson('api/idapi/me.php');
    final b = body['branding'];
    return (
      user: AuthUser.fromJson(Map<String, dynamic>.from(body['user'] as Map? ?? {})),
      branding: b is Map ? Branding.fromJson(Map<String, dynamic>.from(b)) : null,
    );
  }

  /// Absolute URL for a site-root-relative path such as a branding logo.
  /// The logo endpoint is public, so this needs no bearer token.
  Uri siteUrl(String relativePath) {
    final base = Uri.parse(baseUrl);
    final qIndex = relativePath.indexOf('?');
    final path = qIndex < 0 ? relativePath : relativePath.substring(0, qIndex);
    final query = qIndex < 0 ? null : relativePath.substring(qIndex + 1);
    final joined = '${base.path}/$path'.replaceAll(RegExp(r'/+'), '/');
    return base.replace(path: joined, query: query);
  }

  Future<List<StreamFolder>> listStreams() async {
    final body = await getJson('api/idapi/streams_list.php');
    return (body['folders'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((f) => StreamFolder.fromJson(Map<String, dynamic>.from(f)))
        .toList(growable: false);
  }

  Future<StreamDiagnostics> diagnostics(String stream) async {
    final body = await getJson('api/idapi/diagnostics.php', {'stream': stream});
    return StreamDiagnostics.fromJson(body);
  }

  /// Notifications, newest first. Omit [stream] for every stream (the inbox);
  /// pass [beforeId] — the lowest id already held — to page backwards.
  Future<NotificationPage> notifications({
    String? stream,
    int limit = 50,
    int? beforeId,
  }) async {
    final body = await getJson('api/idapi/notifications.php', {
      'stream': ?stream,
      'limit': '$limit',
      if (beforeId != null) 'before_id': '$beforeId',
    });
    return NotificationPage.fromJson(body);
  }

  /// Recordings in a stream folder, newest first. Non-audio entries are dropped
  /// so the images page's time axis only ever contains real recordings.
  Future<List<StreamFile>> streamFiles(String folder) async {
    final body = await getJson('api/idapi/stream_files.php', {'folder': folder});
    final files = (body['files'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((f) => StreamFile.fromJson(Map<String, dynamic>.from(f)))
        .where((f) => f.isAudio)
        .toList();
    // Newest first, by when the recording BEGAN — not by mtime. See
    // StreamFile.startTime: sorting on a different key from the one displayed
    // is what made the feed look randomly ordered. Ties fall back to the name
    // so the order is total and stable across refreshes.
    files.sort((a, b) {
      final t = b.startTime.compareTo(a.startTime);
      return t != 0 ? t : b.name.compareTo(a.name);
    });
    return files;
  }

  /// URL of one recording's rendered spectrogram snapshot. `v` keys the client
  /// cache on the recording's mtime, which is what lets the response be
  /// immutable — a re-recorded file gets a different URL.
  Uri thumbUrl(String folder, StreamFile file) => _uri('api/idapi/stream_thumb.php', {
        'folder': folder,
        'file': file.thumbName,
        'v': '${file.modified}',
      });

  /// Every detection recorded against one recording, in time order.
  Future<DecisionList> fileDecisions(String folder, String file) async {
    final body = await getJson('api/idapi/file_decisions.php', {
      'folder': folder,
      'file': file,
    });
    return DecisionList.fromJson(body);
  }

  /// Detections across a whole stream, newest recording first. Each row names
  /// its recording, so the feed can open the file a detection came from.
  Future<DecisionList> streamDecisions(String folder, {int limit = 300}) async {
    final body = await getJson('api/idapi/stream_decisions_list.php', {
      'folder': folder,
      'limit': '$limit',
    });
    return DecisionList.fromJson(body);
  }

  /// How many detections each recording holds — only recordings that actually
  /// fired appear. Cheap enough to call per folder: it reads a cleartext
  /// surface column and aggregates in SQL, decrypting nothing.
  Future<Map<String, int>> decisionCounts(String folder) async {
    final body = await getJson('api/idapi/decision_counts.php', {'folder': folder});
    final raw = body['counts'];
    if (raw is! Map) return const {};
    final out = <String, int>{};
    raw.forEach((k, v) {
      final n = v is int ? v : int.tryParse('$v');
      if (n != null && n > 0) out['$k'] = n;
    });
    return out;
  }

  /// Vessels near the sensor between two instants.
  ///
  /// Passing the active recording's span is the map's normal use: it answers
  /// "what was here while this was recorded", which is the only framing in
  /// which a detection from days ago makes sense. Omit both to get a live
  /// snapshot instead.
  Future<List<Vessel>> vessels(String stream, {DateTime? from, DateTime? to}) async {
    final body = await getJson('api/idapi/ais.php', {
      'stream': stream,
      if (from != null) 'from': '${from.toUtc().millisecondsSinceEpoch ~/ 1000}',
      if (to != null) 'to': '${to.toUtc().millisecondsSinceEpoch ~/ 1000}',
    });
    return (body['vessels'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((v) => Vessel.fromJson(Map<String, dynamic>.from(v)))
        .toList(growable: false);
  }

  /// The sensor registered for a stream, or null when none is. A null sensor is
  /// ordinary — plenty of folders have no registered position.
  Future<Sensor?> sensor(String stream) async {
    final body = await getJson('api/idapi/sensor.php', {'stream': stream});
    final s = body['sensor'];
    return s is Map ? Sensor.fromJson(Map<String, dynamic>.from(s)) : null;
  }

  /// The recordings this user has starred in one folder.
  Future<Set<String>> favourites(String folder) async {
    final body = await getJson('api/idapi/favourites_list.php', {'folder': folder});
    return (body['files'] as List<dynamic>? ?? const [])
        .map((f) => f.toString())
        .toSet();
  }

  /// Star or unstar a recording. [favourite] is sent explicitly rather than
  /// letting the server flip, so a retry after a dropped connection is
  /// idempotent instead of undoing itself. Returns the state actually stored.
  Future<bool> setFavourite(String folder, String file, bool favourite) async {
    final body = await postJson('api/idapi/favourites_toggle.php', {
      'folder': folder,
      'file': file,
      'favourite': favourite,
    });
    return body['favourite'] == true;
  }
}
