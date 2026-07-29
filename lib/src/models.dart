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
    this.modelId,
    this.target,
    this.score,
    this.fmin,
    this.fmax,
    this.threshold,
  });

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
