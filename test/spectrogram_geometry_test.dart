/// Placing detections on the spectrogram snapshot.
///
/// The frequency axis inverts (the image is written with low frequency at the
/// bottom, thumbnail.js:131) and stops short of Nyquist (pooling drops the top
/// bin). Both are easy to get subtly wrong in a way that still *looks*
/// plausible on screen, so they are pinned here rather than trusted to review.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ident_mobile/src/models.dart';
import 'package:ident_mobile/src/spectrogram_geometry.dart';

Decision d({
  double tmin = 0,
  double tmax = 1,
  double? fmin,
  double? fmax,
}) =>
    Decision(
      modelName: 'm',
      tmin: tmin,
      tmax: tmax,
      fmin: fmin,
      fmax: fmax,
      source: 'db',
    );

void main() {
  group('time axis', () {
    test('maps seconds to a fraction of the width', () {
      final box = spectrogramBoxFor(
        d(tmin: 75, tmax: 150),
        durationSeconds: 300,
      )!;
      expect(box.left, closeTo(0.25, 1e-9));
      expect(box.right, closeTo(0.50, 1e-9));
    });

    test('clamps a detection running past the end of the recording', () {
      final box = spectrogramBoxFor(d(tmin: 290, tmax: 400), durationSeconds: 300)!;
      expect(box.right, 1.0);
    });

    test('returns null without a usable duration — there is no time axis', () {
      expect(spectrogramBoxFor(d(), durationSeconds: 0), isNull);
      expect(spectrogramBoxFor(d(), durationSeconds: -5), isNull);
    });
  });

  group('frequency axis', () {
    // 96 kHz sonar: Nyquist 48 kHz, of which the image shows 127/128.
    const sampleRate = 96000;
    final maxShown = displayedMaxFrequency(sampleRate)!;

    test('stops just short of Nyquist, because pooling drops the top bin', () {
      expect(maxShown, closeTo(48000 * 127 / 128, 1e-6));
      expect(maxShown, lessThan(48000));
    });

    test('inverts: a HIGH frequency sits near the TOP of the image', () {
      final high = spectrogramBoxFor(
        d(fmin: maxShown * 0.8, fmax: maxShown * 0.9),
        durationSeconds: 300,
        sampleRate: sampleRate,
      )!;
      // top is measured from the top edge, so a high band gives a small top.
      expect(high.top, closeTo(0.1, 1e-6));
      expect(high.bottom, closeTo(0.2, 1e-6));
      expect(high.top, lessThan(high.bottom));
    });

    test('a LOW frequency sits near the BOTTOM', () {
      final low = spectrogramBoxFor(
        d(fmin: 0, fmax: maxShown * 0.1),
        durationSeconds: 300,
        sampleRate: sampleRate,
      )!;
      expect(low.bottom, closeTo(1.0, 1e-6));
      expect(low.top, closeTo(0.9, 1e-6));
    });

    test('clamps a band above the displayed range to the top edge', () {
      final box = spectrogramBoxFor(
        d(fmin: maxShown * 0.5, fmax: 99999999),
        durationSeconds: 300,
        sampleRate: sampleRate,
      )!;
      expect(box.top, 0.0);
    });
  });

  group('missing frequency bounds', () {
    test('spans the full height rather than inventing a band', () {
      final box = spectrogramBoxFor(
        d(tmin: 30, tmax: 60),
        durationSeconds: 300,
        sampleRate: 96000,
      )!;
      expect(box.hasFrequency, isFalse);
      expect(box.top, 0.0);
      expect(box.bottom, 1.0);
      // The time extent is still exact — that part is known.
      expect(box.left, closeTo(0.1, 1e-9));
      expect(box.right, closeTo(0.2, 1e-9));
    });

    test('an unknown sample rate also falls back to full height', () {
      final box = spectrogramBoxFor(
        d(fmin: 100, fmax: 200),
        durationSeconds: 300,
        sampleRate: null,
      )!;
      expect(box.hasFrequency, isFalse);
      expect(box.bottom, 1.0);
    });

    test('a nonsensical sample rate is treated as unknown, not divided by', () {
      expect(displayedMaxFrequency(0), isNull);
      expect(displayedMaxFrequency(-1), isNull);
    });
  });
}
