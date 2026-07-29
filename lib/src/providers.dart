/// The Riverpod graph.
///
/// One rule runs through all of it: any 401 from the API means the token is
/// dead, and the only correct response is to tear down the session and return
/// to sign-in. [_guard] centralises that so no individual screen has to
/// remember it, and no screen ever renders a "not authorised" error state that
/// the user cannot act on.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api_client.dart';
import 'auth.dart';
import 'file_duration.dart';
import 'models.dart';

final authControllerProvider = ChangeNotifierProvider<AuthController>((ref) {
  return AuthController();
});

/// The authenticated client, or null when signed out.
final apiClientProvider = Provider<ApiClient?>((ref) {
  final auth = ref.watch(authControllerProvider);
  return auth.state is AuthSignedIn ? auth.client : null;
});

/// Run an API call, converting a 401 into a session teardown.
///
/// Rethrows either way: the caller still needs to fail, but by the time the
/// error surfaces the app is already routing back to the login screen.
Future<T> _guard<T>(Ref ref, Future<T> Function(ApiClient) body) async {
  final client = ref.read(apiClientProvider);
  if (client == null) {
    throw const ApiException(
      status: 401,
      error: 'unauthorized',
      message: 'Signed out.',
    );
  }
  try {
    return await body(client);
  } on ApiException catch (e) {
    if (e.isAuthFailure) {
      await ref.read(authControllerProvider).handleAuthFailure();
    }
    rethrow;
  }
}

/// The signed-in account plus its company branding.
///
/// Fetched rather than read from stored session state so a restored session
/// picks up a logo the lead changed since last launch. Kept alive for the
/// session — branding does not move often enough to re-request per screen.
final meProvider = FutureProvider<({AuthUser user, Branding? branding})>((ref) {
  return _guard(ref, (c) => c.me());
});

/// Every stream the signed-in user may read.
final streamsProvider = FutureProvider.autoDispose<List<StreamFolder>>((ref) {
  return _guard(ref, (c) => c.listStreams());
});

/// Health checks for one stream. Held for two minutes after the last listener
/// goes away, so opening a stream's dashboard and coming back does not re-fetch
/// what the list already has — but a stream the user has stopped looking at
/// still lets go rather than pinning its result for the session.
final diagnosticsProvider =
    FutureProvider.autoDispose.family<StreamDiagnostics, String>((ref, stream) {
  final link = ref.keepAlive();
  final expiry = Timer(const Duration(minutes: 2), link.close);
  ref.onDispose(expiry.cancel);
  return _guard(ref, (c) => c.diagnostics(stream));
});

/// Recordings in a stream folder — the time axis for the images page.
final streamFilesProvider =
    FutureProvider.autoDispose.family<List<StreamFile>, String>((ref, folder) {
  return _guard(ref, (c) => c.streamFiles(folder));
});

/// The folder's own metadata, looked up from the already-loaded stream list.
///
/// Recordings are fixed-length chunks, so the folder's `duration_ms` is what
/// gives the file viewer an end time for its span. Derived from [streamsProvider]
/// rather than re-fetched, so opening a file costs no extra request.
final streamFolderProvider =
    Provider.autoDispose.family<StreamFolder?, String>((ref, folder) {
  final streams = ref.watch(streamsProvider).valueOrNull;
  if (streams == null) return null;
  for (final s in streams) {
    if (s.name == folder) return s;
  }
  return null;
});

/// The recording currently selected in a stream's viewer.
///
/// Lifted out of the viewer so sibling data windows can follow it — the AIS map
/// plots the traffic present during *this* recording, which only works if
/// choosing a file in one window is visible from another. Not autoDispose: it
/// must survive swiping between windows, and it is keyed by folder so two
/// streams never share a selection.
final activeFileProvider =
    StateProvider.family<StreamFile?, String>((ref, folder) => null);

/// Per-file durations for a folder, keyed by filename.
///
/// Folders are not uniform — repmus25 mixes 5-second and 5-minute recordings —
/// and neither the file listing nor the folder metadata gives a per-file
/// duration, so this derives one. See file_duration.dart for why proportion to
/// the modal file size is the right method. Computed once per folder rather
/// than per file, since the strip and the map both need it for lists of
/// thousands.
final fileDurationsProvider =
    Provider.autoDispose.family<Map<String, int>, String>((ref, folder) {
  final files = ref.watch(streamFilesProvider(folder)).valueOrNull;
  if (files == null) return const {};
  final meta = ref.watch(streamFolderProvider(folder));
  return estimateDurations(files, folderDurationMs: meta?.durationMs);
});

/// A request to bring one recording into view in the live viewer.
///
/// Kept separate from [activeFileProvider] on purpose: that one is *state* the
/// viewer writes as the user moves, this one is a *request* other windows write
/// to move it. Merging them would have the viewer reacting to its own writes.
/// The viewer clears the request once it has acted on it.
final fileFocusRequestProvider =
    StateProvider.family<String?, String>((ref, folder) => null);

/// The sensor anchoring a stream's map.
final sensorProvider =
    FutureProvider.autoDispose.family<Sensor?, String>((ref, stream) {
  return _guard(ref, (c) => c.sensor(stream));
});

/// Vessels present during a given window.
///
/// Keyed by the window itself so each recording's traffic is cached separately
/// and swiping back to an earlier file is instant rather than re-fetched.
typedef VesselQuery = ({String stream, DateTime? from, DateTime? to});

final vesselsProvider =
    FutureProvider.autoDispose.family<List<Vessel>, VesselQuery>((ref, q) {
  return _guard(ref, (c) => c.vessels(q.stream, from: q.from, to: q.to));
});

/// Detection count per recording, for marking the thumbnail strip.
final decisionCountsProvider =
    FutureProvider.autoDispose.family<Map<String, int>, String>((ref, folder) {
  return _guard(ref, (c) => c.decisionCounts(folder));
});

/// Detections across a whole stream — the decisions data window.
final streamDecisionsProvider =
    FutureProvider.autoDispose.family<DecisionList, String>((ref, folder) {
  return _guard(ref, (c) => c.streamDecisions(folder));
});

/// Every detection against one recording.
final fileDecisionsProvider = FutureProvider.autoDispose
    .family<DecisionList, ({String folder, String file})>((ref, args) {
  return _guard(ref, (c) => c.fileDecisions(args.folder, args.file));
});

/// The starred recordings in one folder.
///
/// Held as a whole set rather than a flag per file: the feed needs to know the
/// state of every visible lane at once, and one request per lane would be
/// absurd. Toggling updates locally first so the star responds instantly, then
/// reconciles with whatever the server actually stored.
class FavouritesNotifier extends StateNotifier<AsyncValue<Set<String>>> {
  FavouritesNotifier(this._ref, this._folder) : super(const AsyncValue.loading()) {
    load();
  }

  final Ref _ref;
  final String _folder;

  Future<void> load() async {
    try {
      final files = await _guard(_ref, (c) => c.favourites(_folder));
      if (mounted) state = AsyncValue.data(files);
    } catch (e, st) {
      if (mounted) state = AsyncValue.error(e, st);
    }
  }

  bool isFavourite(String file) => state.valueOrNull?.contains(file) ?? false;

  /// Returns the state actually stored, or rolls back on failure.
  Future<bool> toggle(String file) async {
    final current = state.valueOrNull ?? <String>{};
    final want = !current.contains(file);

    // Optimistic — a star that lags a network round trip feels broken.
    state = AsyncValue.data(want ? {...current, file} : (current.toSet()..remove(file)));

    try {
      final stored = await _guard(_ref, (c) => c.setFavourite(_folder, file, want));
      if (!mounted) return stored;
      // Reconcile: another device may have raced us.
      final now = state.valueOrNull ?? <String>{};
      state = AsyncValue.data(stored ? {...now, file} : (now.toSet()..remove(file)));
      return stored;
    } catch (_) {
      if (mounted) state = AsyncValue.data(current);   // roll back
      rethrow;
    }
  }
}

final favouritesProvider = StateNotifierProvider.autoDispose
    .family<FavouritesNotifier, AsyncValue<Set<String>>, String>(
  (ref, folder) => FavouritesNotifier(ref, folder),
);

/// Paged notification list for one stream (or all streams when [stream] is null).
///
/// A [StateNotifier] rather than a FutureProvider because the list grows by
/// keyset paging as the user scrolls, and appending to what is already on
/// screen must not re-fetch or reorder the pages above it.
class NotificationsNotifier extends StateNotifier<AsyncValue<List<NotificationItem>>> {
  NotificationsNotifier(this._ref, this._stream) : super(const AsyncValue.loading()) {
    refresh();
  }

  final Ref _ref;
  final String? _stream;

  static const _pageSize = 50;

  bool _hasMore = true;
  bool _loadingMore = false;

  bool get hasMore => _hasMore;
  bool get isLoadingMore => _loadingMore;

  Future<void> refresh() async {
    try {
      final page = await _guard(
        _ref,
        (c) => c.notifications(stream: _stream, limit: _pageSize),
      );
      _hasMore = page.hasMore;
      if (mounted) state = AsyncValue.data(page.items);
    } catch (e, st) {
      if (mounted) state = AsyncValue.error(e, st);
    }
  }

  /// Fetch the next page using the oldest id we hold as the cursor. Keyset
  /// paging means alerts arriving mid-scroll cannot shift rows between pages.
  Future<void> loadMore() async {
    if (_loadingMore || !_hasMore) return;
    final current = state.valueOrNull;
    if (current == null || current.isEmpty) return;

    _loadingMore = true;
    try {
      final page = await _guard(
        _ref,
        (c) => c.notifications(
          stream: _stream,
          limit: _pageSize,
          beforeId: current.last.id,
        ),
      );
      _hasMore = page.hasMore;
      if (mounted) state = AsyncValue.data([...current, ...page.items]);
    } catch (_) {
      // Keep what is already on screen; the user can pull to refresh. Failing
      // a page-append must not blank a list the user is reading.
      _hasMore = false;
    } finally {
      _loadingMore = false;
    }
  }
}

final notificationsProvider = StateNotifierProvider.autoDispose
    .family<NotificationsNotifier, AsyncValue<List<NotificationItem>>, String?>(
  (ref, stream) => NotificationsNotifier(ref, stream),
);
