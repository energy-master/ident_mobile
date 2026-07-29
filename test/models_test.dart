/// JSON parsing.
///
/// The API is shared with the web app and the brahma framework and grows new
/// fields over time, so these tests pin the two behaviours that matter: numbers
/// arriving as strings (MySQL DECIMAL/SUM columns do this through PHP's
/// json_encode) must still parse, and missing fields must degrade rather than
/// throw halfway through building a list.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ident_mobile/src/models.dart';

void main() {
  group('CheckStatus', () {
    test('maps the three known states', () {
      expect(CheckStatus.parse('ok'), CheckStatus.ok);
      expect(CheckStatus.parse('warn'), CheckStatus.warn);
      expect(CheckStatus.parse('error'), CheckStatus.error);
    });

    test('treats anything unrecognised as warn, never as healthy', () {
      expect(CheckStatus.parse('banana'), CheckStatus.warn);
      expect(CheckStatus.parse(null), CheckStatus.warn);
      expect(CheckStatus.parse(7), CheckStatus.warn);
    });
  });

  group('StreamDiagnostics', () {
    Map<String, dynamic> check(String id, String status) => {
          'id': id,
          'label': id,
          'status': status,
          'verdict': 'v',
          'summary': 's',
          'metrics': <String, dynamic>{},
        };

    test('worst returns the most severe status present', () {
      final allOk = StreamDiagnostics.fromJson({
        'stream': 'a',
        'now_ms': 1,
        'checks': [check('files', 'ok'), check('ais', 'ok')],
      });
      expect(allOk.worst, CheckStatus.ok);

      final withWarn = StreamDiagnostics.fromJson({
        'stream': 'a',
        'now_ms': 1,
        'checks': [check('files', 'ok'), check('ais', 'warn')],
      });
      expect(withWarn.worst, CheckStatus.warn);

      // An error outranks a warn regardless of order.
      final withError = StreamDiagnostics.fromJson({
        'stream': 'a',
        'now_ms': 1,
        'checks': [check('files', 'error'), check('ais', 'warn')],
      });
      expect(withError.worst, CheckStatus.error);
    });

    test('survives a response with no checks at all', () {
      final d = StreamDiagnostics.fromJson({'stream': 'a', 'now_ms': 1});
      expect(d.checks, isEmpty);
      expect(d.worst, CheckStatus.ok);
      expect(d.checkById('files'), isNull);
    });

    test('reads newest recording metrics whether numeric or string', () {
      final d = StreamDiagnostics.fromJson({
        'stream': 'a',
        'now_ms': 1,
        'checks': [
          {
            'id': 'files',
            'label': 'Acoustic data',
            'status': 'ok',
            'verdict': 'ok',
            'summary': 'Streaming',
            'metrics': {'newest_name': '_20260728_132408_000.wav', 'newest_age_min': '4.5'},
          },
        ],
      });
      final files = d.checkById('files')!;
      expect(files.newestName, '_20260728_132408_000.wav');
      expect(files.newestAgeMin, 4.5);
    });
  });

  group('NotificationItem', () {
    test('parses a full row and exposes the timestamp as UTC', () {
      final n = NotificationItem.fromJson({
        'id': 91,
        'stream_folder': 'china-creek',
        'sent_at': '2026-07-28 13:22:07',
        'sent_at_ms': 1785417727000,
        'kind': 'detection',
        'channel': 'email',
        'recipient': 'a@b.com',
        'model_id': 4,
        'subject': 'Detection',
        'detail': 'Something',
        'success': true,
      });
      expect(n.id, 91);
      expect(n.success, isTrue);
      expect(n.sentAtUtc!.isUtc, isTrue);
      expect(n.sentAtUtc!.millisecondsSinceEpoch, 1785417727000);
    });

    test('tolerates nulls and a missing timestamp', () {
      final n = NotificationItem.fromJson({
        'id': 1,
        'stream_folder': 's',
        'sent_at': '',
        'kind': 'detection',
        'channel': 'email',
        'success': false,
      });
      expect(n.recipient, isNull);
      expect(n.modelId, isNull);
      expect(n.sentAtUtc, isNull);
      expect(n.success, isFalse);
    });
  });

  group('NotificationItem file link', () {
    NotificationItem withFile(Object? fileName) => NotificationItem.fromJson({
          'id': 1,
          'stream_folder': 's',
          'file_name': fileName,
          'sent_at': '',
          'kind': 'detection-file',
          'channel': 'email',
          'success': true,
        });

    test('exposes a linked recording', () {
      final n = withFile('_20260728_132408_000.wav');
      expect(n.hasFile, isTrue);
      expect(n.fileName, '_20260728_132408_000.wav');
    });

    test('treats null and empty alike — an hourly digest links to nothing', () {
      expect(withFile(null).hasFile, isFalse);
      expect(withFile('').hasFile, isFalse);
      // Empty string must normalise to null, or the UI would offer to open a
      // recording with no name and fail after the user tapped it.
      expect(withFile('').fileName, isNull);
    });
  });

  group('Decision', () {
    test('parses geometry and computes duration', () {
      final d = Decision.fromJson({
        'model_id': 42,
        'model_name': 'engine-cnn',
        'target': 'engine',
        'tmin': 12.5,
        'tmax': 14.0,
        'score': 0.91,
        'threshold': 0.5,
        'source': 'db',
      });
      expect(d.modelId, 42);
      expect(d.duration, closeTo(1.5, 1e-9));
      expect(d.isSidecar, isFalse);
    });

    test('a sidecar decision has no model id', () {
      final d = Decision.fromJson({
        'model_id': null,
        'model_name': 'offbox',
        'tmin': '3',
        'tmax': '4',
        'source': 'sidecar',
      });
      expect(d.modelId, isNull);
      expect(d.isSidecar, isTrue);
      // Numbers arriving as strings still parse.
      expect(d.tmin, 3);
      expect(d.tmax, 4);
    });

    test('empty target normalises to null', () {
      final d = Decision.fromJson({'model_name': 'm', 'target': '', 'source': 'db'});
      expect(d.target, isNull);
    });
  });

  group('DecisionList', () {
    test('reports truncation', () {
      final l = DecisionList.fromJson({
        'decisions': [
          {'model_name': 'm', 'tmin': 1, 'tmax': 2, 'source': 'db'},
        ],
        'n_decisions': 900,
        'truncated': true,
      });
      expect(l.decisions, hasLength(1));
      expect(l.total, 900);
      expect(l.truncated, isTrue);
    });

    test('defaults to empty rather than throwing', () {
      final l = DecisionList.fromJson({'ok': true});
      expect(l.decisions, isEmpty);
      expect(l.truncated, isFalse);
    });
  });

  group('Vessel', () {
    test('parses a collapsed track', () {
      final v = Vessel.fromJson({
        'mmsi': 316001234,
        'name': 'SEASPAN',
        'type': 'cargo',
        'track': [
          {'lat': 48.4, 'lng': -123.3, 't': 1000, 't_last': 1000, 'n': 1, 'sog': 8.2},
          {'lat': 48.5, 'lng': -123.4, 't': 2000, 't_last': 5000, 'n': 4},
        ],
      });
      expect(v.mmsi, 316001234);
      expect(v.label, 'SEASPAN');
      expect(v.track, hasLength(2));
      expect(v.isMoving, isTrue);
      expect(v.latest!.n, 4);
      expect(v.latest!.tLast, 5000);
    });

    test('normalises a snapshot row into a one-point track', () {
      // Snapshot mode has no `track` — the position is on the row itself. Both
      // modes must present the same shape or the map has to branch.
      final v = Vessel.fromJson({
        'mmsi': 1,
        'lat': 48.4,
        'lng': -123.3,
        'sog': 0.0,
      });
      expect(v.track, hasLength(1));
      expect(v.track.first.lat, 48.4);
      expect(v.isMoving, isFalse);
    });

    test('falls back to the MMSI when the vessel has no name', () {
      expect(Vessel.fromJson({'mmsi': 42, 'track': []}).label, '42');
      expect(Vessel.fromJson({'mmsi': 42, 'name': '   ', 'track': []}).label, '42');
    });

    test('a single-point track is not moving', () {
      final v = Vessel.fromJson({
        'mmsi': 1,
        'track': [
          {'lat': 1, 'lng': 2, 't': 1, 'n': 900},
        ],
      });
      expect(v.isMoving, isFalse);
    });
  });

  group('Sensor', () {
    test('parses a positioned sensor', () {
      final s = Sensor.fromJson({
        'name': 'China Creek',
        'latitude': 48.4284,
        'longitude': -123.3656,
        'data_type': 'hydrophone audio',
        'owner': 'Jane Doe',
      });
      expect(s.hasPosition, isTrue);
      expect(s.latitude, closeTo(48.4284, 1e-9));
    });

    test('a sensor without coordinates cannot anchor a map', () {
      final s = Sensor.fromJson({'name': 'Unplaced'});
      expect(s.hasPosition, isFalse);
    });
  });

  group('NotificationPage', () {
    test('defaults to an empty page rather than throwing', () {
      final p = NotificationPage.fromJson({'ok': true});
      expect(p.items, isEmpty);
      expect(p.hasMore, isFalse);
    });
  });

  group('StreamFile', () {
    test('derives the snapshot name by swapping the extension', () {
      expect(
        const StreamFile(name: '_20260728_132408_000.wav', sizeBytes: 1, modified: 1).thumbName,
        '_20260728_132408_000.png',
      );
      expect(
        const StreamFile(name: 'a.b.flac', sizeBytes: 1, modified: 1).thumbName,
        'a.b.png',
      );
      // A name with no extension keeps its stem rather than losing characters.
      expect(
        const StreamFile(name: 'noext', sizeBytes: 1, modified: 1).thumbName,
        'noext.png',
      );
    });

    test('recognises the audio formats the stream folders hold', () {
      bool audio(String n) => StreamFile(name: n, sizeBytes: 0, modified: 0).isAudio;
      expect(audio('a.wav'), isTrue);
      expect(audio('a.FLAC'), isTrue);
      expect(audio('a.mp3'), isTrue);
      expect(audio('a.png'), isFalse);
      expect(audio('notes.txt'), isFalse);
    });

    test('startTime prefers the filename over the mtime', () {
      // mtime says 1 Jan 2020; the name says 28 Jul 2026. The name wins.
      final f = StreamFile(name: '_20260728_132408_000.wav', sizeBytes: 0, modified: 1577836800);
      expect(f.startTime.year, 2026);
      expect(f.startTime.hour, 13);
    });

    test('ordering follows recording time, not download order', () {
      // The exact regression: a downloader fetched these out of order, so mtime
      // order is scrambled relative to when the recordings were actually made.
      // Sorting on mtime while displaying filename times made the feed look
      // random — the sort key must be the key that is shown.
      final files = [
        StreamFile(name: '_20260728_130000_000.wav', sizeBytes: 0, modified: 3000), // oldest recording, fetched last
        StreamFile(name: '_20260728_140000_000.wav', sizeBytes: 0, modified: 1000), // newest recording, fetched first
        StreamFile(name: '_20260728_133000_000.wav', sizeBytes: 0, modified: 2000),
      ];

      files.sort((a, b) {
        final t = b.startTime.compareTo(a.startTime);
        return t != 0 ? t : b.name.compareTo(a.name);
      });

      expect(
        files.map((f) => f.name).toList(),
        [
          '_20260728_140000_000.wav',
          '_20260728_133000_000.wav',
          '_20260728_130000_000.wav',
        ],
        reason: 'newest recording first, regardless of mtime',
      );
    });

    test('ordering is total and stable when start times tie', () {
      // Names with no parseable timestamp fall back to mtime; equal mtimes must
      // still produce a deterministic order rather than shuffling per refresh.
      final files = [
        const StreamFile(name: 'b.wav', sizeBytes: 0, modified: 500),
        const StreamFile(name: 'a.wav', sizeBytes: 0, modified: 500),
        const StreamFile(name: 'c.wav', sizeBytes: 0, modified: 500),
      ];
      files.sort((a, b) {
        final t = b.startTime.compareTo(a.startTime);
        return t != 0 ? t : b.name.compareTo(a.name);
      });
      expect(files.map((f) => f.name).toList(), ['c.wav', 'b.wav', 'a.wav']);
    });

    test('parses size and mtime arriving as strings', () {
      final f = StreamFile.fromJson({
        'name': 'a.wav',
        'size_bytes': '42000000',
        'modified': '1785419048',
      });
      expect(f.sizeBytes, 42000000);
      expect(f.modified, 1785419048);
    });
  });
}
