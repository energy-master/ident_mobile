/// The site addresses and usernames this device has signed in with before.
///
/// Two independent lists, not paired profiles: the same person may use one
/// account across several sites, or several accounts on one, and pairing them
/// would offer combinations that were never real while hiding ones that are.
///
/// Passwords are deliberately absent. They belong to the platform password
/// manager, which the sign-in screen hands them to via `AutofillGroup` and
/// `TextInput.finishAutofillContext()`. Nothing here should ever grow a
/// password field — the moment it does, this app becomes the custodian of a
/// secret it has no business holding.
///
/// The value types below are pure so they can be tested without a binding; only
/// [RecentSignInStore] touches the keystore.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'api_client.dart';

/// Which list an entry belongs to, and how many of them are worth keeping.
///
/// Eight is chosen to be longer than anyone's real set of sites or accounts but
/// short enough that the menu never needs scrolling on a phone.
enum RecentKind {
  site(cap: 8),
  username(cap: 8);

  const RecentKind({required this.cap});

  final int cap;

  /// The form that is stored and shown.
  String canonical(String raw) =>
      this == RecentKind.site ? siteCanonical(raw) : raw.trim();

  /// The identity two entries are considered the same by.
  ///
  /// For sites this is the canonical form itself. For usernames it is
  /// case-folded — see [usernameKey].
  String keyOf(String raw) =>
      this == RecentKind.site ? siteCanonical(raw) : usernameKey(raw);
}

/// A site address reduced to the one spelling we store it under.
///
/// [ApiClient.normaliseBaseUrl] does the trimming, scheme and trailing-slash
/// work. On top of that the scheme and host are lower-cased, because both are
/// case-insensitive by RFC and `https://GoIdent.ai` must not become a second
/// entry beside `https://goident.ai`.
///
/// The **path is left exactly as typed**. IDent supports subdirectory installs
/// (`auth.php` derives BASE_PATH from DOCUMENT_ROOT), and on a case-sensitive
/// filesystem folding `/IDent` to `/ident` produces an address that 404s. The
/// port is kept for the same reason.
String siteCanonical(String raw) {
  final normalised = ApiClient.normaliseBaseUrl(raw);
  if (normalised.isEmpty) return '';
  final uri = Uri.tryParse(normalised);
  if (uri == null || uri.host.isEmpty) {
    // Not parseable as a URL — hand it back untouched and let
    // validateSiteAddress refuse it, rather than inventing a canonical form
    // for something that is not an address.
    return normalised;
  }
  return uri
      .replace(scheme: uri.scheme.toLowerCase(), host: uri.host.toLowerCase())
      .toString();
}

/// What two usernames must share to count as the same account.
///
/// Case-folded, because the field accepts "username or email" and email
/// addresses are case-insensitive in practice — the same person typing
/// `Rahul@x.com` on Monday and `rahul@x.com` on Tuesday should not accumulate
/// two rows.
///
/// The *stored* value keeps the most recent spelling rather than the first. That
/// is safe only because usernames are recorded on outright success (see
/// login_screen.dart), so whatever spelling is held has actually authenticated.
/// The residual risk — a server with genuinely distinct `Bob` and `bob`
/// accounts — is not worth the everyday cost of duplicate rows.
String usernameKey(String raw) => raw.trim().toLowerCase();

/// Why a site address cannot be used, or null when it can.
///
/// Exists as a free function with no widget dependency because it has two call
/// sites: the field's own validator, and a pre-flight in `handleSubmit` that has
/// to run even when the field is hidden and therefore unmounted — a `Form` only
/// validates the `FormField`s currently in the tree.
String? validateSiteAddress(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return 'Enter your IDent site address';

  // The scheme has to be judged on the RAW text, before normalisation.
  // normaliseBaseUrl prepends https:// to anything that does not already carry
  // an http(s) scheme, so by the time it has run "ftp://x" has become
  // "https://ftp://x" and the foreign scheme is no longer visible.
  final scheme = _schemePrefix.firstMatch(trimmed)?.group(1)?.toLowerCase();
  if (scheme != null && scheme != 'http' && scheme != 'https') {
    return 'Use http:// or https://';
  }

  final normalised = ApiClient.normaliseBaseUrl(raw);
  final uri = Uri.tryParse(normalised);
  if (uri == null) return 'That does not look like a web address';
  if (uri.host.isEmpty) return 'That address is missing a host name';
  // A space survives Uri.tryParse in some forms and is never valid in a host.
  if (trimmed.contains(' ')) return 'Addresses cannot contain spaces';
  if (uri.hasQuery || uri.hasFragment) {
    return 'Enter the site address only, without ? or #';
  }
  return null;
}

final _schemePrefix = RegExp(r'^([A-Za-z][A-Za-z0-9+.\-]*)://');

/// One remembered list: most recent first, de-duplicated, capped.
@immutable
class RecentValues {
  const RecentValues(this.kind, this.values);

  const RecentValues.empty(this.kind) : values = const <String>[];

  final RecentKind kind;

  /// Most recently used first.
  final List<String> values;

  bool get isEmpty => values.isEmpty;
  bool get isNotEmpty => values.isNotEmpty;
  int get length => values.length;
  String? get mostRecent => values.isEmpty ? null : values.first;

  /// Promote [raw] to the front.
  ///
  /// Returns *this same instance* when there is nothing to change — blank
  /// input, or a value already at the front — so a caller can skip a keystore
  /// write on the overwhelmingly common case of signing in to the same site
  /// again.
  RecentValues used(String raw) {
    final value = kind.canonical(raw);
    if (value.isEmpty) return this;

    final key = kind.keyOf(raw);
    if (values.isNotEmpty && kind.keyOf(values.first) == key && values.first == value) {
      return this;
    }

    return RecentValues(kind, [
      value,
      for (final existing in values)
        if (kind.keyOf(existing) != key) existing,
    ].take(kind.cap).toList(growable: false));
  }

  /// Remove one entry, deliberately.
  RecentValues forget(String value) {
    final key = kind.keyOf(value);
    final kept = [
      for (final existing in values)
        if (kind.keyOf(existing) != key) existing,
    ];
    return kept.length == values.length
        ? this
        : RecentValues(kind, List.unmodifiable(kept));
  }

  String encode() => jsonEncode(values);

  /// Never throws. A corrupt or hand-edited store means "no suggestions yet",
  /// which must never be a reason sign-in fails — the same principle as the
  /// swallowed FormatException in AuthStore.read.
  ///
  /// De-duplication and the cap are re-applied on the way in, so a store
  /// written by an older build, or edited by hand, cannot produce a menu with
  /// repeated rows.
  static RecentValues decode(RecentKind kind, String? raw) {
    if (raw == null || raw.isEmpty) return RecentValues.empty(kind);
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return RecentValues.empty(kind);
      var out = RecentValues.empty(kind);
      // Reversed, because `used` prepends: replaying oldest-first reproduces
      // the stored order.
      for (final entry in decoded.reversed) {
        if (entry is String) out = out.used(entry);
      }
      return out;
    } on FormatException {
      return RecentValues.empty(kind);
    }
  }
}

/// Both lists together.
@immutable
class RecentSignIns {
  const RecentSignIns({required this.sites, required this.usernames});

  static const empty = RecentSignIns(
    sites: RecentValues.empty(RecentKind.site),
    usernames: RecentValues.empty(RecentKind.username),
  );

  final RecentValues sites;
  final RecentValues usernames;

  RecentSignIns copyWith({RecentValues? sites, RecentValues? usernames}) =>
      RecentSignIns(
        sites: sites ?? this.sites,
        usernames: usernames ?? this.usernames,
      );
}

/// Durable storage for the two lists.
///
/// Same keystore and the same iOS accessibility class as [AuthStore] — two
/// stores with different accessibility would behave differently across a
/// reboot, which is the kind of difference nobody notices until a user reports
/// that the app "forgets things sometimes".
class RecentSignInStore {
  RecentSignInStore([FlutterSecureStorage? storage])
      : _storage = storage ??
            const FlutterSecureStorage(
              iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
            );

  final FlutterSecureStorage _storage;

  static const kSites = 'ident.recent_sites';
  static const kUsernames = 'ident.recent_usernames';

  Future<RecentSignIns> read() async {
    try {
      return RecentSignIns(
        sites: RecentValues.decode(RecentKind.site, await _storage.read(key: kSites)),
        usernames:
            RecentValues.decode(RecentKind.username, await _storage.read(key: kUsernames)),
      );
    } catch (_) {
      // An unreadable keystore costs the user their suggestions, nothing more.
      return RecentSignIns.empty;
    }
  }

  Future<void> write(RecentValues values) async {
    final key = values.kind == RecentKind.site ? kSites : kUsernames;
    await _storage.write(key: key, value: values.encode());
  }
}
