/// The Riverpod graph.
///
/// One rule runs through all of it: any 401 from the API means the token is
/// dead, and the only correct response is to tear down the session and return
/// to sign-in. [_guard] centralises that so no individual screen has to
/// remember it, and no screen ever renders a "not authorised" error state that
/// the user cannot act on.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'ais_map_geometry.dart' show AisHistory, liveRefreshInterval;
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

/// Recordings the server has no rendered spectrogram snapshot for.
///
/// A 404 from the thumbnail endpoint is ordinary — most folders are only
/// partially rendered, and several are not rendered at all — but
/// `cached_network_image` does not remember a failed fetch. Without this memo
/// the strip re-requests every unrendered lane on every scroll pass and on
/// every rebuild: for a 1,777-recording folder with no snapshots that is 1,777
/// round trips per pass, each one costing the API two database queries and a
/// hop to the Brahma service. Recording the verdict once turns the second pass
/// into a placeholder drawn from memory.
///
/// Deliberately not persisted and cleared by an explicit refresh: snapshots are
/// built server-side and a folder that has none can acquire them at any time, so
/// a permanent "missing" verdict would hide them once they arrived.
class MissingThumbs {
  final Map<String, Set<String>> _byFolder = {};

  bool contains(String folder, String file) =>
      _byFolder[folder]?.contains(file) ?? false;

  void add(String folder, String file) =>
      _byFolder.putIfAbsent(folder, () => <String>{}).add(file);

  /// Forget one folder's verdicts, so the next build re-asks the server.
  void clear(String folder) => _byFolder.remove(folder);
}

final missingThumbsProvider = Provider<MissingThumbs>((ref) => MissingThumbs());

/// The sensor anchoring a stream's map.
final sensorProvider =
    FutureProvider.autoDispose.family<Sensor?, String>((ref, stream) {
  return _guard(ref, (c) => c.sensor(stream));
});

/// Vessels present during a given window.
///
/// Keyed by the window itself so each recording's traffic is cached separately
/// and swiping back to an earlier file is instant rather than re-fetched.
typedef VesselQuery = ({String stream, DateTime? from, DateTime? to, bool all});

final vesselsProvider =
    FutureProvider.autoDispose.family<List<Vessel>, VesselQuery>((ref, q) {
  return _guard(
    ref,
    (c) => c.vessels(q.stream, from: q.from, to: q.to, all: q.all),
  );
});

/// What the AIS map is currently showing, beyond the data itself.
///
/// Selection, hidden vessels and the history range are all *view* state, but
/// they cannot live in the map widget: the map is built twice — embedded in the
/// dashboard and again in the full-screen route — and the detail sheets are
/// routes of their own. Holding this in the widget would reset the operator's
/// selection every time they expanded the map, which reads as the app losing
/// their place. Same reasoning as [activeFileProvider].
@immutable
class AisView {
  const AisView({
    this.selectedMmsi,
    this.isolatedMmsi,
    this.hiddenMmsi = const {},
    this.history = AisHistory.recording,
    this.historyChosen = false,
  });

  /// The vessel whose track is highlighted, if any.
  final int? selectedMmsi;

  /// When set, only this vessel is drawn — the "Track only" action.
  final int? isolatedMmsi;

  /// Vessels switched off in the vessel list.
  final Set<int> hiddenMmsi;

  final AisHistory history;

  /// True once the operator has picked a range themselves.
  ///
  /// Auto-widening for a too-short recording must not keep overriding a choice
  /// the operator has made, and must not be mistaken for one either.
  final bool historyChosen;

  bool visible(int mmsi) =>
      isolatedMmsi != null ? mmsi == isolatedMmsi : !hiddenMmsi.contains(mmsi);

  AisView copyWith({
    int? selectedMmsi,
    bool clearSelected = false,
    int? isolatedMmsi,
    bool clearIsolated = false,
    Set<int>? hiddenMmsi,
    AisHistory? history,
    bool? historyChosen,
  }) =>
      AisView(
        selectedMmsi: clearSelected ? null : (selectedMmsi ?? this.selectedMmsi),
        isolatedMmsi: clearIsolated ? null : (isolatedMmsi ?? this.isolatedMmsi),
        hiddenMmsi: hiddenMmsi ?? this.hiddenMmsi,
        history: history ?? this.history,
        historyChosen: historyChosen ?? this.historyChosen,
      );

  /// Drop references to vessels that are no longer in the data.
  ///
  /// Widening the history range changes which vessels exist, and a selection
  /// pointing at one that is no longer drawn leaves the map with an invisible
  /// highlight and the vessel list with a phantom row.
  AisView prunedTo(Set<int> present) {
    final hidden = hiddenMmsi.where(present.contains).toSet();
    return AisView(
      selectedMmsi:
          present.contains(selectedMmsi) ? selectedMmsi : null,
      isolatedMmsi:
          present.contains(isolatedMmsi) ? isolatedMmsi : null,
      hiddenMmsi: hidden,
      history: history,
      historyChosen: historyChosen,
    );
  }
}

class AisViewNotifier extends StateNotifier<AisView> {
  AisViewNotifier() : super(const AisView());

  /// Select a vessel, or pass null to clear — tapping open water deselects.
  void select(int? mmsi) => state = mmsi == null
      ? state.copyWith(clearSelected: true)
      : state.copyWith(selectedMmsi: mmsi);

  void toggleVisible(int mmsi) {
    final hidden = state.hiddenMmsi.toSet();
    if (!hidden.remove(mmsi)) hidden.add(mmsi);
    state = state.copyWith(hiddenMmsi: hidden);
  }

  void showAll() =>
      state = state.copyWith(hiddenMmsi: const {}, clearIsolated: true);

  /// Hide everything. Isolation is cleared too: the two are different answers
  /// to the same question and leaving both set is ambiguous.
  void hideAll(Iterable<int> mmsis) =>
      state = state.copyWith(hiddenMmsi: mmsis.toSet(), clearIsolated: true);

  /// Draw only this vessel, or pass null to go back to all of them.
  void isolate(int? mmsi) => state = mmsi == null
      ? state.copyWith(clearIsolated: true)
      : state.copyWith(
          isolatedMmsi: mmsi,
          selectedMmsi: mmsi,
          hiddenMmsi: const {},
        );

  void setHistory(AisHistory history, {bool byUser = true}) {
    if (state.history == history && (!byUser || state.historyChosen)) return;
    state = state.copyWith(
      history: history,
      historyChosen: byUser || state.historyChosen,
      clearSelected: true,
    );
  }

  void prune(Set<int> present) {
    final next = state.prunedTo(present);
    if (next.selectedMmsi != state.selectedMmsi ||
        next.isolatedMmsi != state.isolatedMmsi ||
        next.hiddenMmsi.length != state.hiddenMmsi.length) {
      state = next;
    }
  }
}

/// Ticks while the AIS map is in its live range.
///
/// Watched only in that range, so nothing is running when the map is showing
/// history. Each tick moves the live window's end to the new minute, which
/// changes [vesselsProvider]'s key and so fetches — the tick itself carries no
/// data, it is only the thing that makes "now" move.
final aisLiveTickProvider = StreamProvider.autoDispose<int>((ref) {
  return Stream<int>.periodic(liveRefreshInterval, (i) => i);
});

/// The AIS map's view state for one stream.
///
/// Not autoDispose and keyed by folder: it must outlive the full-screen route
/// and the dashboard swiping this window off screen, and two streams must never
/// share a selection.
final aisViewProvider =
    StateNotifierProvider.family<AisViewNotifier, AisView, String>(
  (ref, stream) => AisViewNotifier(),
);

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
