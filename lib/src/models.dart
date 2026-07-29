/// Typed views over the `api/idapi/*` JSON payloads.
///
/// Every model parses defensively: the API is an evolving surface shared with
/// the web app and the brahma framework, so an unexpected null or a field that
/// has not shipped yet must degrade to a sensible default rather than throw
/// halfway through building a list.
library;

import 'time_format.dart';

/// Traffic-light state for one health check. Mirrors the `status` string the
/// server sends; anything unrecognised is treated as [warn] so an unknown
/// verdict is never silently drawn as healthy.
enum CheckStatus {
  ok,
  warn,
  error;

  static CheckStatus parse(Object? raw) => switch (raw) {
        'ok' => CheckStatus.ok,
        'error' => CheckStatus.error,
        _ => CheckStatus.warn,
      };
}

/// One stream folder the signed-in user may read.
class StreamFolder {
  const StreamFolder({
    required this.name,
    this.durationMs,
    this.sampleRate,
    this.channels,
    this.hasLabels = false,
  });

  final String name;
  final int? durationMs;
  final int? sampleRate;
  final int? channels;
  final bool hasLabels;

  factory StreamFolder.fromJson(Map<String, dynamic> json) => StreamFolder(
        name: (json['name'] ?? '').toString(),
        durationMs: _asInt(json['duration_ms']),
        sampleRate: _asInt(json['sample_rate']),
        channels: _asInt(json['channels']),
        hasLabels: json['has_labels'] == true,
      );
}

/// One health check within a stream's diagnostics: acoustic data, model runs
/// or the AIS feed. `metrics` is kept as raw JSON so the detail view can render
/// new numbers the server starts sending without a client change.
class DiagnosticCheck {
  const DiagnosticCheck({
    required this.id,
    required this.label,
    required this.status,
    required this.verdict,
    required this.summary,
    required this.metrics,
  });

  final String id;
  final String label;
  final CheckStatus status;
  final String verdict;
  final String summary;
  final Map<String, dynamic> metrics;

  factory DiagnosticCheck.fromJson(Map<String, dynamic> json) => DiagnosticCheck(
        id: (json['id'] ?? '').toString(),
        label: (json['label'] ?? 'Check').toString(),
        status: CheckStatus.parse(json['status']),
        verdict: (json['verdict'] ?? '').toString(),
        summary: (json['summary'] ?? '').toString(),
        metrics: json['metrics'] is Map
            ? Map<String, dynamic>.from(json['metrics'] as Map)
            : const <String, dynamic>{},
      );

  /// The newest recording's filename, when this is the acoustic-data check.
  /// Used to show a stream's live time on its card.
  String? get newestName => metrics['newest_name']?.toString();

  /// Age in minutes of the newest recording, when known.
  double? get newestAgeMin => _asDouble(metrics['newest_age_min']);
}

/// A stream's full diagnostics response.
class StreamDiagnostics {
  const StreamDiagnostics({
    required this.stream,
    required this.nowMs,
    required this.checks,
  });

  final String stream;
  final int nowMs;
  final List<DiagnosticCheck> checks;

  factory StreamDiagnostics.fromJson(Map<String, dynamic> json) => StreamDiagnostics(
        stream: (json['stream'] ?? '').toString(),
        nowMs: _asInt(json['now_ms']) ?? DateTime.now().millisecondsSinceEpoch,
        checks: (json['checks'] as List<dynamic>? ?? const [])
            .whereType<Map>()
            .map((c) => DiagnosticCheck.fromJson(Map<String, dynamic>.from(c)))
            .toList(growable: false),
      );

  /// The worst status across all checks — what the card's overall tint uses.
  CheckStatus get worst {
    var worst = CheckStatus.ok;
    for (final c in checks) {
      if (c.status == CheckStatus.error) return CheckStatus.error;
      if (c.status == CheckStatus.warn) worst = CheckStatus.warn;
    }
    return worst;
  }

  DiagnosticCheck? checkById(String id) {
    for (final c in checks) {
      if (c.id == id) return c;
    }
    return null;
  }
}

/// One dispatched alert — a detection or AIS-proximity notification.
class NotificationItem {
  const NotificationItem({
    required this.id,
    required this.streamFolder,
    required this.sentAt,
    required this.kind,
    required this.channel,
    required this.success,
    this.fileName,
    this.sentAtMs,
    this.recipient,
    this.modelId,
    this.subject,
    this.detail,
  });

  final int id;
  final String streamFolder;

  /// The recording that fired this alert, when there is exactly one. Null for
  /// hourly digests, which span many recordings — so a client must treat
  /// "open the recording" as an optional action, not a guaranteed one.
  final String? fileName;

  final String sentAt;
  final int? sentAtMs;
  final String kind;
  final String channel;
  final bool success;
  final String? recipient;
  final int? modelId;
  final String? subject;
  final String? detail;

  /// Whether this alert can be traced to a single recording.
  bool get hasFile => fileName != null && fileName!.isNotEmpty;

  factory NotificationItem.fromJson(Map<String, dynamic> json) => NotificationItem(
        id: _asInt(json['id']) ?? 0,
        streamFolder: (json['stream_folder'] ?? '').toString(),
        fileName: (json['file_name']?.toString().isEmpty ?? true)
            ? null
            : json['file_name'].toString(),
        sentAt: (json['sent_at'] ?? '').toString(),
        sentAtMs: _asInt(json['sent_at_ms']),
        kind: (json['kind'] ?? 'detection').toString(),
        channel: (json['channel'] ?? 'email').toString(),
        success: json['success'] == true,
        recipient: json['recipient']?.toString(),
        modelId: _asInt(json['model_id']),
        subject: json['subject']?.toString(),
        detail: json['detail']?.toString(),
      );

  /// Server timestamps are UTC; expose them as UTC so the UI can decide whether
  /// to show local or UTC rather than being handed an ambiguous local time.
  DateTime? get sentAtUtc => sentAtMs == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(sentAtMs!, isUtc: true);
}

/// One page of notifications plus its keyset cursor.
class NotificationPage {
  const NotificationPage({required this.items, required this.hasMore});

  final List<NotificationItem> items;
  final bool hasMore;

  factory NotificationPage.fromJson(Map<String, dynamic> json) => NotificationPage(
        items: (json['notifications'] as List<dynamic>? ?? const [])
            .whereType<Map>()
            .map((n) => NotificationItem.fromJson(Map<String, dynamic>.from(n)))
            .toList(growable: false),
        hasMore: json['has_more'] == true,
      );
}

/// One recording in a stream folder. `modified` is the server-side mtime in
/// epoch seconds — the reliable time axis for the images page.
class StreamFile {
  const StreamFile({
    required this.name,
    required this.sizeBytes,
    required this.modified,
  });

  final String name;
  final int sizeBytes;
  final int modified;

  factory StreamFile.fromJson(Map<String, dynamic> json) => StreamFile(
        name: (json['name'] ?? '').toString(),
        sizeBytes: _asInt(json['size_bytes']) ?? 0,
        modified: _asInt(json['modified']) ?? 0,
      );

  /// The rendered spectrogram snapshot is the recording stem + `.png` — the
  /// same derivation js/stream-histogram.js uses, so both clients ask the
  /// Brahma service for identical filenames.
  String get thumbName {
    final dot = name.lastIndexOf('.');
    final stem = dot <= 0 ? name : name.substring(0, dot);
    return '$stem.png';
  }

  bool get isAudio {
    final n = name.toLowerCase();
    return n.endsWith('.wav') || n.endsWith('.flac') || n.endsWith('.mp3');
  }

  /// When the recording actually began.
  ///
  /// The filename wins over `modified`, because the mtime is when the writer
  /// finished or copied the file — a downloader that backfills, retries, or
  /// fetches concurrently produces mtimes in a completely different order from
  /// the recordings themselves. This is the single value used for BOTH ordering
  /// and display: sorting by mtime while showing filename times is what makes a
  /// correctly-sorted list look shuffled.
  DateTime get startTime => recordingTime(name, modified);
}

/// One detection recorded against a recording.
///
/// `tmin`/`tmax` are seconds from the start of the file, which is what lets the
/// viewer place a marker along the spectrogram without knowing wall-clock time.
class Decision {
  const Decision({
    required this.modelName,
    required this.tmin,
    required this.tmax,
    required this.source,
    this.fileName,
    this.modelId,
    this.target,
    this.score,
    this.fmin,
    this.fmax,
    this.threshold,
  });

  /// The recording this detection is in. Present in the stream-wide feed, where
  /// rows come from many files; null in the per-file list, where the file is
  /// already the context.
  final String? fileName;

  /// Null for a folder sidecar — an off-box detector has no model row.
  final int? modelId;
  final String modelName;
  final String? target;
  final double tmin;
  final double tmax;
  final double? score;
  final double? fmin;
  final double? fmax;
  final double? threshold;

  /// `db` or `sidecar`.
  final String source;

  double get duration => (tmax - tmin).abs();

  bool get isSidecar => source == 'sidecar';

  factory Decision.fromJson(Map<String, dynamic> json) => Decision(
        fileName: (json['file_name']?.toString().isEmpty ?? true)
            ? null
            : json['file_name'].toString(),
        modelId: _asInt(json['model_id']),
        modelName: (json['model_name'] ?? '').toString(),
        target: (json['target']?.toString().isEmpty ?? true) ? null : json['target'].toString(),
        tmin: _asDouble(json['tmin']) ?? 0,
        tmax: _asDouble(json['tmax']) ?? 0,
        score: _asDouble(json['score']),
        fmin: _asDouble(json['fmin']),
        fmax: _asDouble(json['fmax']),
        threshold: _asDouble(json['threshold']),
        source: (json['source'] ?? 'db').toString(),
      );
}

/// A file's decision list plus whether the server capped it.
class DecisionList {
  const DecisionList({
    required this.decisions,
    required this.total,
    required this.truncated,
  });

  final List<Decision> decisions;
  final int total;
  final bool truncated;

  factory DecisionList.fromJson(Map<String, dynamic> json) => DecisionList(
        decisions: (json['decisions'] as List<dynamic>? ?? const [])
            .whereType<Map>()
            .map((d) => Decision.fromJson(Map<String, dynamic>.from(d)))
            .toList(growable: false),
        total: _asInt(json['n_decisions']) ?? 0,
        truncated: json['truncated'] == true,
      );
}

/// One position in a vessel's track.
///
/// The server collapses consecutive fixes at the same position into a single
/// point, so [n] is how many raw fixes were merged and [tLast] when the vessel
/// was last seen there. A moored vessel therefore appears as one point with a
/// large [n] rather than thousands of stacked markers.
class TrackPoint {
  const TrackPoint({
    required this.lat,
    required this.lng,
    required this.t,
    this.tLast,
    this.cog,
    this.sog,
    this.n = 1,
  });

  final double lat;
  final double lng;

  /// Epoch ms when the vessel arrived at this position.
  final int t;

  /// Epoch ms when it was last seen here.
  final int? tLast;

  final double? cog;
  final double? sog;
  final int n;

  DateTime get time => DateTime.fromMillisecondsSinceEpoch(t, isUtc: true);

  factory TrackPoint.fromJson(Map<String, dynamic> json) => TrackPoint(
        lat: _asDouble(json['lat']) ?? 0,
        lng: _asDouble(json['lng']) ?? 0,
        t: _asInt(json['t']) ?? 0,
        tLast: _asInt(json['t_last']),
        cog: _asDouble(json['cog']),
        sog: _asDouble(json['sog']),
        n: _asInt(json['n']) ?? 1,
      );
}

/// A vessel near the sensor.
///
/// In track mode [track] holds its path through the requested window; in
/// snapshot mode it holds a single current position.
class Vessel {
  const Vessel({
    required this.mmsi,
    required this.track,
    this.name,
    this.type,
    this.flag,
    this.dest,
  });

  final int mmsi;
  final List<TrackPoint> track;
  final String? name;
  final String? type;
  final String? flag;
  final String? dest;

  /// A label worth showing — falls back to the MMSI, which is always present.
  String get label => (name != null && name!.trim().isNotEmpty) ? name!.trim() : '$mmsi';

  /// Moving vessels are the interesting ones; a single point means it sat still
  /// for the whole window.
  bool get isMoving => track.length >= 2;

  TrackPoint? get latest => track.isEmpty ? null : track.last;

  factory Vessel.fromJson(Map<String, dynamic> json) {
    final rawTrack = json['track'];
    final track = rawTrack is List
        ? rawTrack
            .whereType<Map>()
            .map((p) => TrackPoint.fromJson(Map<String, dynamic>.from(p)))
            .toList(growable: false)
        // Snapshot mode has no `track` — the vessel's position is on the row
        // itself. Normalising it to a one-point track lets the map treat both
        // modes identically.
        : [
            TrackPoint(
              lat: _asDouble(json['lat']) ?? 0,
              lng: _asDouble(json['lng']) ?? 0,
              t: _asInt(json['t']) ?? 0,
              cog: _asDouble(json['cog']),
              sog: _asDouble(json['sog']),
            ),
          ];

    return Vessel(
      mmsi: _asInt(json['mmsi']) ?? 0,
      track: track,
      name: (json['name']?.toString().isEmpty ?? true) ? null : json['name'].toString(),
      type: (json['type']?.toString().isEmpty ?? true) ? null : json['type'].toString(),
      flag: (json['flag']?.toString().isEmpty ?? true) ? null : json['flag'].toString(),
      dest: (json['dest']?.toString().isEmpty ?? true) ? null : json['dest'].toString(),
    );
  }
}

/// The sensor registered for a stream — the map's anchor point.
class Sensor {
  const Sensor({
    required this.name,
    this.latitude,
    this.longitude,
    this.dataType,
    this.owner,
  });

  final String name;
  final double? latitude;
  final double? longitude;
  final String? dataType;
  final String? owner;

  /// A sensor with no coordinates can't anchor a map, so callers must check.
  bool get hasPosition => latitude != null && longitude != null;

  factory Sensor.fromJson(Map<String, dynamic> json) => Sensor(
        name: (json['name'] ?? '').toString(),
        latitude: _asDouble(json['latitude']),
        longitude: _asDouble(json['longitude']),
        dataType: json['data_type']?.toString(),
        owner: json['owner']?.toString(),
      );
}

/// Company branding inherited from the account lead.
///
/// The logo bytes come from the site's public `/logo.php`, not the token API —
/// so this carries only the path to request and a version that rolls whenever
/// the lead re-uploads, which is what makes the image safely cacheable.
class Branding {
  const Branding({
    required this.companyName,
    required this.hasLogo,
    this.logoPath,
  });

  final String companyName;
  final bool hasLogo;

  /// Relative to the site root, e.g. `logo.php?id=2&v=…`. Null when no logo.
  final String? logoPath;

  bool get isEmpty => !hasLogo && companyName.isEmpty;

  factory Branding.fromJson(Map<String, dynamic> json) => Branding(
        companyName: (json['company_name'] ?? '').toString(),
        hasLogo: json['has_logo'] == true,
        logoPath: (json['logo_path']?.toString().isEmpty ?? true)
            ? null
            : json['logo_path'].toString(),
      );
}

/// The signed-in account.
class AuthUser {
  const AuthUser({
    required this.id,
    required this.username,
    required this.email,
    required this.role,
  });

  final int id;
  final String username;
  final String email;
  final String role;

  factory AuthUser.fromJson(Map<String, dynamic> json) => AuthUser(
        id: _asInt(json['id']) ?? 0,
        username: (json['username'] ?? '').toString(),
        email: (json['email'] ?? '').toString(),
        role: (json['role'] ?? 'user').toString(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'username': username,
        'email': email,
        'role': role,
      };
}

// ── parsing helpers ─────────────────────────────────────────────────────────
// PHP's json_encode emits ints for whole numbers but MySQL DECIMAL/AVG columns
// arrive as strings, so every numeric field tolerates all three encodings.

int? _asInt(Object? v) => switch (v) {
      final int i => i,
      final double d => d.round(),
      final String s => int.tryParse(s) ?? double.tryParse(s)?.round(),
      _ => null,
    };

double? _asDouble(Object? v) => switch (v) {
      final int i => i.toDouble(),
      final double d => d,
      final String s => double.tryParse(s),
      _ => null,
    };
