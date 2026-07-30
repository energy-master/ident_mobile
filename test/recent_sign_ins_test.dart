/// What the sign-in screen remembers between sessions.
///
/// These pin the rules that are easy to "simplify" into bugs: which spelling of
/// an address counts as the same site (host case yes, path case no), that a
/// corrupt store degrades to "no suggestions" rather than breaking sign-in, and
/// that writing a list never touches the session keys next to it.
///
/// Deliberately not covered here, because a unit test cannot see it — the
/// `AutofillGroup` handshake, the save prompt appearing on success and not on a
/// rejected password, and the recall menu itself. Those are device checks.
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ident_mobile/src/recent_sign_ins.dart';

void main() {
  RecentValues sites(List<String> v) => RecentValues(RecentKind.site, v);
  RecentValues users(List<String> v) => RecentValues(RecentKind.username, v);

  group('used', () {
    test('puts a new value at the front', () {
      final after = users(['bob']).used('alice');
      expect(after.values, ['alice', 'bob']);
    });

    test('promotes an existing value rather than duplicating it', () {
      final after = users(['alice', 'bob', 'carol']).used('carol');
      expect(after.values, ['carol', 'alice', 'bob']);
    });

    test('drops the oldest once the cap is reached', () {
      var list = users(const []);
      for (var i = 0; i < RecentKind.username.cap + 3; i++) {
        list = list.used('user$i');
      }
      expect(list.length, RecentKind.username.cap);
      expect(list.mostRecent, 'user${RecentKind.username.cap + 2}');
      expect(list.values, isNot(contains('user0')));
    });

    test('ignores blank input, returning the same instance', () {
      final before = users(['alice']);
      expect(identical(before.used('   '), before), isTrue);
    });

    test('returns the same instance when the value is already at the front', () {
      // The point of this: signing in to the same site again is the common
      // case, and it must not cost a keystore write.
      final before = sites(['https://goident.ai', 'https://x.example']);
      expect(identical(before.used('https://goident.ai'), before), isTrue);
      expect(identical(before.used('goident.ai/'), before), isTrue);
    });

    test('rewrites the front entry when only its spelling changed', () {
      final after = users(['Alice']).used('alice');
      expect(after.values, ['alice']);
    });
  });

  group('forget', () {
    test('removes by key, not by exact spelling', () {
      final after = users(['Alice', 'bob']).forget('alice');
      expect(after.values, ['bob']);
    });

    test('is a no-op for a value that is not there', () {
      final before = users(['alice']);
      expect(identical(before.forget('zoe'), before), isTrue);
    });

    test('preserves the order of the survivors', () {
      final after = users(['a', 'b', 'c', 'd']).forget('b');
      expect(after.values, ['a', 'c', 'd']);
    });
  });

  group('siteCanonical', () {
    test('folds scheme and host case, and the trailing slash', () {
      expect(siteCanonical('HTTPS://GoIdent.AI/'), 'https://goident.ai');
      expect(siteCanonical('  goident.ai '), 'https://goident.ai');
    });

    test('collapses hosts differing only in case to one entry', () {
      final after = sites(['https://a.com']).used('https://A.com');
      expect(after.values, ['https://a.com']);
    });

    test('keeps the path exactly as typed', () {
      // Subdirectory installs are served from a case-sensitive filesystem;
      // folding /IDent to /ident produces an address that 404s.
      expect(siteCanonical('https://example.com/IDent'), 'https://example.com/IDent');
      expect(
        sites(['https://example.com/IDent']).used('https://example.com/ident').values,
        ['https://example.com/ident', 'https://example.com/IDent'],
      );
    });

    test('keeps a non-default port', () {
      expect(siteCanonical('http://localhost:8080'), 'http://localhost:8080');
    });

    test('hands back unparseable input untouched rather than inventing a form', () {
      expect(siteCanonical(''), '');
    });
  });

  group('usernameKey', () {
    test('folds case so one account is one row', () {
      expect(usernameKey('  Rahul@X.com '), 'rahul@x.com');
    });

    test('stores the most recent spelling', () {
      final after = users(['Rahul']).used('rahul');
      expect(after.values, ['rahul']);
    });
  });

  group('validateSiteAddress', () {
    test('accepts the addresses people actually type', () {
      expect(validateSiteAddress('goident.ai'), isNull);
      expect(validateSiteAddress('marlin.goident.ai'), isNull);
      expect(validateSiteAddress('localhost:8080'), isNull);
      expect(validateSiteAddress('http://192.168.1.5/ident'), isNull);
    });

    test('rejects blank', () {
      expect(validateSiteAddress('   '), isNotNull);
    });

    test('rejects an embedded space', () {
      expect(validateSiteAddress('my site.com'), isNotNull);
    });

    test('rejects a scheme with no host', () {
      expect(validateSiteAddress('https://'), isNotNull);
    });

    test('rejects a scheme we cannot speak', () {
      expect(validateSiteAddress('ftp://x.com'), isNotNull);
    });

    test('rejects a query string or fragment', () {
      expect(validateSiteAddress('https://x.com/?a=1'), isNotNull);
      expect(validateSiteAddress('https://x.com/#a'), isNotNull);
    });
  });

  group('codec', () {
    test('round-trips', () {
      final before = sites(['https://a.com', 'https://b.com']);
      expect(RecentValues.decode(RecentKind.site, before.encode()).values, before.values);
    });

    test('treats an absent or corrupt store as no suggestions', () {
      // A hand-edited or half-written keystore must never be a reason sign-in
      // fails; the worst it can cost is the menu.
      for (final raw in [null, '', 'not json', '{"a":1}', '[1,2,3]']) {
        expect(RecentValues.decode(RecentKind.site, raw).isEmpty, isTrue, reason: 'for $raw');
      }
    });

    test('re-applies the cap and de-duplication on the way in', () {
      final oversized = List.generate(RecentKind.site.cap + 4, (i) => '"https://s$i.com"');
      final decoded = RecentValues.decode(RecentKind.site, '[${oversized.join(',')}]');
      expect(decoded.length, RecentKind.site.cap);
      expect(decoded.mostRecent, 'https://s0.com');

      final duped = RecentValues.decode(
        RecentKind.username,
        '["Alice","alice","bob"]',
      );
      expect(duped.values, ['Alice', 'bob']);
    });
  });

  group('RecentSignInStore', () {
    test('reads both lists from their own keys', () async {
      FlutterSecureStorage.setMockInitialValues({
        RecentSignInStore.kSites: '["https://a.com"]',
        RecentSignInStore.kUsernames: '["alice"]',
      });
      final read = await RecentSignInStore().read();
      expect(read.sites.values, ['https://a.com']);
      expect(read.usernames.values, ['alice']);
    });

    test('starts empty on a device that has never signed in', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final read = await RecentSignInStore().read();
      expect(read.sites.isEmpty, isTrue);
      expect(read.usernames.isEmpty, isTrue);
    });

    test('writing a list leaves the session keys alone', () async {
      // Same keystore as AuthStore. A write here touching ident.token would sign
      // the user out for choosing a username from a menu.
      FlutterSecureStorage.setMockInitialValues({'ident.token': 'tok'});
      const storage = FlutterSecureStorage();
      await RecentSignInStore(storage).write(users(['alice']));
      expect(await storage.read(key: 'ident.token'), 'tok');
      expect(await storage.read(key: RecentSignInStore.kUsernames), '["alice"]');
      expect(await storage.read(key: RecentSignInStore.kSites), isNull);
    });
  });
}
