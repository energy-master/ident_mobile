/// GitHub-style heatmaps for jumping to a moment in a stream.
///
/// Two pickers share this file because they share their whole visual language
/// (shading ramp, legend, tile chrome) and the caller runs them back-to-back:
///
/// * [showDateHeatmapPicker] — one month at a time; cells shade by recordings
///   per day. A stream's recordings are dense enough that a month grid reads
///   as data rather than gaps, and paginating by month keeps the picker the
///   same size no matter how long the range is.
/// * [showHourHeatmapPicker] — the 24 hours of the picked day, six across;
///   cells shade by recordings that hour. Minutes aren't offered — the caller
///   already snaps to the nearest recording, and hour precision is what an
///   operator scrubbing through a stream is actually deciding at.
///
/// Presentation matches the rest of the app: fullscreen on phone (the whole
/// window is small enough that a dialog would just crop it), an inset panel on
/// tablet (there is room to keep the surrounding tiles in view).
library;

import 'package:flutter/material.dart';

import '../theme.dart';
import 'layout.dart';

/// The five-step ramp: empty slot + four count buckets, interpolated between
/// the raised surface and the accent. Both ends come from the palette so the
/// heatmap reads the same way in light mode as it does in dark.
List<Color> _shadesFor(IdentPalette palette) => [
      palette.surfaceRaised,
      Color.lerp(palette.surfaceRaised, palette.accent, 0.30)!,
      Color.lerp(palette.surfaceRaised, palette.accent, 0.55)!,
      Color.lerp(palette.surfaceRaised, palette.accent, 0.80)!,
      palette.accent,
    ];

Color _shadeForCount(int count, int maxCount, IdentPalette palette) {
  final shades = _shadesFor(palette);
  if (maxCount == 0 || count == 0) return shades[0];
  final t = count / maxCount;
  if (t <= 0.25) return shades[1];
  if (t <= 0.5) return shades[2];
  if (t <= 0.75) return shades[3];
  return shades[4];
}

/// Show the heatmap and return the picked local-midnight [DateTime], or null.
///
/// [counts] must be keyed by local-midnight dates (`DateTime(y, m, d)`), which
/// is what the caller has anyway when it groups files by day.
Future<DateTime?> showDateHeatmapPicker({
  required BuildContext context,
  required Map<DateTime, int> counts,
  required DateTime initialDate,
  required DateTime firstDate,
  required DateTime lastDate,
}) {
  final picker = _DateHeatmapPicker(
    counts: counts,
    initialDate: initialDate,
    firstDate: firstDate,
    lastDate: lastDate,
  );

  final palette = identColors(context);
  if (isTabletLayout(context)) {
    return showDialog<DateTime>(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: palette.surface,
        insetPadding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440, maxHeight: 560),
          child: picker,
        ),
      ),
    );
  }

  return Navigator.of(context).push<DateTime>(
    MaterialPageRoute<DateTime>(
      fullscreenDialog: true,
      builder: (_) => Scaffold(
        backgroundColor: palette.shell,
        appBar: AppBar(title: const Text('Jump to date')),
        body: SafeArea(child: picker),
      ),
    ),
  );
}

/// Show a 24-cell heatmap for the picked day and return the tapped hour (0-23).
///
/// [counts] is keyed by hour of the local day; missing keys are treated as
/// zero, and hours with no recordings are not tappable. [dayLabel] shows in
/// the header so the user knows which day these hours belong to.
Future<int?> showHourHeatmapPicker({
  required BuildContext context,
  required Map<int, int> counts,
  required String dayLabel,
  int initialHour = 0,
}) {
  final picker = _HourHeatmapPicker(
    counts: counts,
    dayLabel: dayLabel,
    initialHour: initialHour,
  );

  final palette = identColors(context);
  if (isTabletLayout(context)) {
    return showDialog<int>(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: palette.surface,
        insetPadding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440, maxHeight: 420),
          child: picker,
        ),
      ),
    );
  }

  return Navigator.of(context).push<int>(
    MaterialPageRoute<int>(
      fullscreenDialog: true,
      builder: (_) => Scaffold(
        backgroundColor: palette.shell,
        appBar: AppBar(title: const Text('Jump to hour')),
        body: SafeArea(child: picker),
      ),
    ),
  );
}

class _DateHeatmapPicker extends StatefulWidget {
  const _DateHeatmapPicker({
    required this.counts,
    required this.initialDate,
    required this.firstDate,
    required this.lastDate,
  });

  final Map<DateTime, int> counts;
  final DateTime initialDate;
  final DateTime firstDate;
  final DateTime lastDate;

  @override
  State<_DateHeatmapPicker> createState() => _DateHeatmapPickerState();
}

class _DateHeatmapPickerState extends State<_DateHeatmapPicker> {
  late DateTime _month =
      DateTime(widget.initialDate.year, widget.initialDate.month);
  late final int _maxCount =
      widget.counts.values.fold<int>(0, (m, v) => v > m ? v : m);

  DateTime get _firstMonth =>
      DateTime(widget.firstDate.year, widget.firstDate.month);
  DateTime get _lastMonth =>
      DateTime(widget.lastDate.year, widget.lastDate.month);

  bool get _canPrev => _month.isAfter(_firstMonth);
  bool get _canNext => _month.isBefore(_lastMonth);

  void _goPrev() =>
      setState(() => _month = DateTime(_month.year, _month.month - 1));
  void _goNext() =>
      setState(() => _month = DateTime(_month.year, _month.month + 1));

  @override
  Widget build(BuildContext context) {
    final year = _month.year;
    final month = _month.month;
    final daysInMonth = DateTime(year, month + 1, 0).day;
    // Dart weekday: Mon=1..Sun=7. Grid runs Mon..Sun, so leading blanks = wd-1.
    final leading = DateTime(year, month, 1).weekday - 1;
    final today = DateTime.now();
    final selected = DateTime(
      widget.initialDate.year,
      widget.initialDate.month,
      widget.initialDate.day,
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left),
                tooltip: 'Previous month',
                onPressed: _canPrev ? _goPrev : null,
              ),
              Expanded(
                child: Text(
                  '${_monthName(month)} $year',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: identColors(context).textPrimary,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                tooltip: 'Next month',
                onPressed: _canNext ? _goNext : null,
              ),
            ],
          ),
          const SizedBox(height: 4),
          const _WeekdayHeader(),
          const SizedBox(height: 6),
          Expanded(
            child: GridView.builder(
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 7,
                mainAxisSpacing: 6,
                crossAxisSpacing: 6,
              ),
              itemCount: leading + daysInMonth,
              itemBuilder: (context, i) {
                if (i < leading) return const SizedBox.shrink();
                final day = i - leading + 1;
                final date = DateTime(year, month, day);
                final count = widget.counts[date] ?? 0;
                return _HeatCell(
                  label: '$day',
                  count: count,
                  maxCount: _maxCount,
                  isToday: _sameDay(date, today),
                  isSelected: _sameDay(date, selected),
                  semanticNoun: 'Day $day',
                  onTap: count > 0 ? () => Navigator.of(context).pop(date) : null,
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          const _Legend(),
        ],
      ),
    );
  }
}

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

class _HourHeatmapPicker extends StatelessWidget {
  const _HourHeatmapPicker({
    required this.counts,
    required this.dayLabel,
    required this.initialHour,
  });

  final Map<int, int> counts;
  final String dayLabel;
  final int initialHour;

  @override
  Widget build(BuildContext context) {
    // Per-day scale — a busy day's peak hour and a quiet day's peak hour should
    // both light up the ramp, otherwise a quiet day would look empty even where
    // it isn't.
    final maxCount = counts.values.fold<int>(0, (m, v) => v > m ? v : m);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            dayLabel,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: identColors(context).textPrimary,
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: GridView.builder(
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 6,
                mainAxisSpacing: 6,
                crossAxisSpacing: 6,
                childAspectRatio: 1.4,
              ),
              itemCount: 24,
              itemBuilder: (context, hour) {
                final count = counts[hour] ?? 0;
                return _HeatCell(
                  label: hour.toString().padLeft(2, '0'),
                  count: count,
                  maxCount: maxCount,
                  isToday: false,
                  isSelected: hour == initialHour,
                  semanticNoun: '${hour.toString().padLeft(2, '0')}:00',
                  onTap: count > 0
                      ? () => Navigator.of(context).pop(hour)
                      : null,
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          const _Legend(),
        ],
      ),
    );
  }
}

class _WeekdayHeader extends StatelessWidget {
  const _WeekdayHeader();

  static const _labels = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];

  @override
  Widget build(BuildContext context) {
    final color = identColors(context).textSecondary;
    return Row(
      children: [
        for (final label in _labels)
          Expanded(
            child: Center(
              child: Text(
                label,
                style: TextStyle(fontSize: 11, color: color),
              ),
            ),
          ),
      ],
    );
  }
}

class _HeatCell extends StatelessWidget {
  const _HeatCell({
    required this.label,
    required this.count,
    required this.maxCount,
    required this.isToday,
    required this.isSelected,
    required this.semanticNoun,
    this.onTap,
  });

  final String label;
  final int count;
  final int maxCount;
  final bool isToday;
  final bool isSelected;

  /// The thing this cell represents, phrased for a screen reader, e.g. `"Day 4"`
  /// or `"14:00"`. Gets suffixed with the count.
  final String semanticNoun;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final palette = identColors(context);
    final shade = _shadeForCount(count, maxCount, palette);
    // Deep shades wash out light text, so flip the number colour once the cell
    // is bright enough that the accent starts to dominate the readout.
    final onDeep = count > 0 && count >= (maxCount * 0.5);
    final textColor = count == 0
        ? palette.textSecondary.withValues(alpha: 0.55)
        : (onDeep ? palette.onAccent : palette.textPrimary);

    final border = isSelected
        ? Border.all(color: palette.textPrimary, width: 1.4)
        : isToday
            ? Border.all(color: palette.accent, width: 1)
            : Border.all(color: palette.hairline);

    return Semantics(
      button: onTap != null,
      label: count == 0
          ? '$semanticNoun, no recordings'
          : '$semanticNoun, $count ${count == 1 ? 'recording' : 'recordings'}',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          decoration: BoxDecoration(
            color: shade,
            borderRadius: BorderRadius.circular(6),
            border: border,
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              color: textColor,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend();

  @override
  Widget build(BuildContext context) {
    final palette = identColors(context);
    final shades = _shadesFor(palette);
    final labelStyle = TextStyle(fontSize: 11, color: palette.textSecondary);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text('Fewer', style: labelStyle),
        const SizedBox(width: 8),
        for (final shade in shades) ...[
          Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              color: shade,
              borderRadius: BorderRadius.circular(3),
              border: Border.all(color: palette.hairline),
            ),
          ),
          const SizedBox(width: 4),
        ],
        const SizedBox(width: 4),
        Text('More', style: labelStyle),
      ],
    );
  }
}

String _monthName(int month) => const [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ][month - 1];
