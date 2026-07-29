/// Time parsing and display helpers.
///
/// Recording filenames encode when the recording began, which is more accurate
/// than the file's mtime (the mtime is when the writer finished or copied it).
/// js/decisions.js parses the strict `_YYYYMMDD_HHMMSS_<frac>` convention; we
/// accept that first, then fall back to finding a `YYYYMMDD` + `HHMMSS` pair
/// anywhere in the name, so streams that prefix a device id still get a real
/// start time. When neither matches, callers fall back to the server's
/// `modified` timestamp — always present, so the time axis is never empty.
library;

import 'package:intl/intl.dart';

/// Strict convention, matching FILENAME_RE in js/decisions.js.
final _strict = RegExp(r'^_(\d{8})_(\d{6})_(\d{1,6})');

/// Tolerant fallback: a date and time pair anywhere in the name, optionally
/// separated by `_`, `-`, or `T`, with optional fractional seconds.
final _loose = RegExp(r'(\d{8})[_\-T](\d{6})(?:[._](\d{1,6}))?');

/// Extract a recording's UTC start time from its filename, or null.
DateTime? parseFileStartTime(String filename) {
  final base = filename.split(RegExp(r'[\\/]')).last;
  final m = _strict.firstMatch(base) ?? _loose.firstMatch(base);
  if (m == null) return null;

  final ymd = m.group(1)!;
  final hms = m.group(2)!;
  final frac = m.groupCount >= 3 ? m.group(3) : null;

  final year = int.tryParse(ymd.substring(0, 4));
  final month = int.tryParse(ymd.substring(4, 6));
  final day = int.tryParse(ymd.substring(6, 8));
  final hour = int.tryParse(hms.substring(0, 2));
  final minute = int.tryParse(hms.substring(2, 4));
  final second = int.tryParse(hms.substring(4, 6));
  if (year == null || month == null || day == null ||
      hour == null || minute == null || second == null) {
    return null;
  }
  // Reject impossible components rather than letting DateTime silently roll
  // them over (month 19 would become the following year).
  if (month < 1 || month > 12 || day < 1 || day > 31 || hour > 23 || minute > 59 || second > 60) {
    return null;
  }

  // `frac` is fractional seconds with as many digits as it has.
  var ms = 0;
  if (frac != null && frac.isNotEmpty) {
    final value = int.tryParse(frac) ?? 0;
    ms = (value / _pow10(frac.length) * 1000).round();
  }

  return DateTime.utc(year, month, day, hour, minute, second, ms);
}

int _pow10(int n) {
  var r = 1;
  for (var i = 0; i < n; i++) {
    r *= 10;
  }
  return r;
}

/// The best available start time for a recording: filename first, mtime second.
DateTime recordingTime(String filename, int modifiedEpochSeconds) =>
    parseFileStartTime(filename) ??
    DateTime.fromMillisecondsSinceEpoch(modifiedEpochSeconds * 1000, isUtc: true);

final _utcStamp = DateFormat('yyyy-MM-dd HH:mm:ss');
final _utcShort = DateFormat('dd MMM HH:mm');
final _dayLabel = DateFormat('EEE d MMM yyyy');

/// `2026-07-28 13:24:08 UTC` — the format the web app's stream cards use.
String formatUtcStamp(DateTime t) => '${_utcStamp.format(t.toUtc())} UTC';

/// `28 Jul 13:24` — compact, for dense lists and the scrub readout.
String formatUtcShort(DateTime t) => _utcShort.format(t.toUtc());

/// `Tue 28 Jul 2026` — date-separator headers.
String formatDayLabel(DateTime t) => _dayLabel.format(t.toUtc());

/// Humanised age, e.g. `4 min ago`, `2 h ago`, `3 d ago`.
String formatAge(Duration age) {
  if (age.isNegative) return 'just now';
  final minutes = age.inMinutes;
  if (minutes < 1) return 'just now';
  if (minutes < 60) return '$minutes min ago';
  final hours = age.inHours;
  if (hours < 24) return '$hours h ago';
  return '${age.inDays} d ago';
}

/// Age from a minutes figure the server already computed.
String formatAgeMinutes(double minutes) =>
    formatAge(Duration(seconds: (minutes * 60).round()));
