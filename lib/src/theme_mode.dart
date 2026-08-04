/// The user's chosen day/night mode.
///
/// Persisted in the same keystore [AuthStore] and [RecentSignInStore] use, for
/// the same reasons — one accessibility class across the app so a reboot never
/// leaves the settings inconsistent. Not stored as a secret, exactly, but the
/// project already depends on `flutter_secure_storage` and it saves adding a
/// separate preferences plugin for one enum.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class ThemeModeStore {
  ThemeModeStore([FlutterSecureStorage? storage])
      : _storage = storage ??
            const FlutterSecureStorage(
              iOptions:
                  IOSOptions(accessibility: KeychainAccessibility.first_unlock),
            );

  final FlutterSecureStorage _storage;

  static const _key = 'ident.theme_mode';

  Future<ThemeMode> read() async {
    try {
      return _decode(await _storage.read(key: _key));
    } catch (_) {
      // An unreadable store costs the user their preference, nothing more.
      return ThemeMode.dark;
    }
  }

  Future<void> write(ThemeMode mode) async {
    await _storage.write(key: _key, value: _encode(mode));
  }
}

String _encode(ThemeMode m) => switch (m) {
      ThemeMode.system => 'system',
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
    };

ThemeMode _decode(String? raw) => switch (raw) {
      'light' => ThemeMode.light,
      'system' => ThemeMode.system,
      _ => ThemeMode.dark,
    };

class ThemeModeNotifier extends StateNotifier<ThemeMode> {
  ThemeModeNotifier([ThemeModeStore? store])
      : _store = store ?? ThemeModeStore(),
        super(ThemeMode.dark) {
    _load();
  }

  final ThemeModeStore _store;

  Future<void> _load() async {
    final loaded = await _store.read();
    if (mounted) state = loaded;
  }

  /// Cycle through System → Light → Dark and back. One tap surface is enough
  /// on a phone; a dropdown would burn a modal for a three-way choice.
  Future<void> cycle() async {
    final next = switch (state) {
      ThemeMode.system => ThemeMode.light,
      ThemeMode.light => ThemeMode.dark,
      ThemeMode.dark => ThemeMode.system,
    };
    if (mounted) state = next;
    await _store.write(next);
  }

  Future<void> set(ThemeMode mode) async {
    if (mode == state) return;
    if (mounted) state = mode;
    await _store.write(mode);
  }
}

final themeModeProvider =
    StateNotifierProvider<ThemeModeNotifier, ThemeMode>((ref) {
  return ThemeModeNotifier();
});
