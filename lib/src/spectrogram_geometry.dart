/// Mapping a detection onto the spectrogram snapshot.
///
/// The snapshot's axes are fully determined by `js/thumbnail.js` in the web
/// repo, and both are linear, so this is arithmetic rather than estimation:
///
///   **Time** — the image spans the whole recording across its width, so a
///   detection at `tmin` seconds sits at `tmin / duration` of the way across.
///
///   **Frequency** — the thumbnail STFT uses `FFT_SIZE = 256`, giving 129 bins,
///   average-pooled by 2 into `THUMB_BINS = 64`. That pooling discards the
///   topmost bin, so the image covers `0 … 127/128 × Nyquist` rather than the
///   full band. Y is flipped when the pixels are written (thumbnail.js:131) so
///   the LOWEST frequency sits at the BOTTOM — which is why the vertical
///   mapping inverts.
///
/// Kept separate from the painter so the mapping can be tested directly; an
/// off-by-one inversion here would draw every box in the wrong half of the
/// image while still looking plausible.
library;

import 'models.dart';

/// Fraction of Nyquist actually shown, after pooling drops the top bin.
const displayedNyquistFraction = 127 / 128;

/// A detection's position on the image, in 0…1 fractions of width and height.
///
/// `top`/`bottom` are measured from the TOP of the image, matching how canvases
/// address pixels — so `top` corresponds to the detection's HIGH frequency.
class SpectrogramBox {
  const SpectrogramBox({
    required this.left,
    required this.right,
    required this.top,
    required this.bottom,
    required this.hasFrequency,
  });

  final double left;
  final double right;
  final double top;
  final double bottom;

  /// False when the detection carried no frequency bounds and the box was
  /// drawn full-height.
  final bool hasFrequency;
}

/// The top of the image in Hz, or null when the sample rate is unknown.
double? displayedMaxFrequency(int? sampleRate) =>
    (sampleRate == null || sampleRate <= 0)
        ? null
        : (sampleRate / 2) * displayedNyquistFraction;

/// Place [decision] on an image of a recording lasting [durationSeconds].
///
/// Returns null when the duration is unknown or nonsensical — without it there
/// is no time axis, and a box drawn anyway would be pure fiction.
///
/// A detection with no frequency bounds spans the full height: many carry only
/// a time range, and inventing a band would place it somewhere specific and
/// wrong, which is worse than saying "somewhere in this time range".
SpectrogramBox? spectrogramBoxFor(
  Decision decision, {
  required double durationSeconds,
  int? sampleRate,
}) {
  if (durationSeconds <= 0) return null;

  final left = (decision.tmin / durationSeconds).clamp(0.0, 1.0);
  final right = (decision.tmax / durationSeconds).clamp(0.0, 1.0);

  final maxFreq = displayedMaxFrequency(sampleRate);
  final fmin = decision.fmin;
  final fmax = decision.fmax;

  if (maxFreq == null || fmin == null || fmax == null) {
    return SpectrogramBox(
      left: left,
      right: right,
      top: 0,
      bottom: 1,
      hasFrequency: false,
    );
  }

  // Invert: frequency rises up the image, so the HIGH bound gives the TOP edge.
  final top = 1 - (fmax / maxFreq).clamp(0.0, 1.0);
  final bottom = 1 - (fmin / maxFreq).clamp(0.0, 1.0);

  return SpectrogramBox(
    left: left,
    right: right,
    top: top,
    bottom: bottom,
    hasFrequency: true,
  );
}
