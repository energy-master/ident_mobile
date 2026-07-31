#!/usr/bin/env python3
"""Regenerate the iOS/Android app icons and the iOS launch image.

The IDent Dynamics mark is CSS-set type — `#app-logo` in the web app's
styles.css, and code-drawn in `lib/src/ui/ident_logo.dart` here. There is no
logo file anywhere to export, so both are rebuilt from the same constants the
originals use.

The launcher icon is the **φ** that closes the web lockup (`.logo-phi`,
styles.css:956): U+03C6 in Courier, green on the app shell. Alone it is the one
piece of the mark that survives 29pt, where "IDent dynamics" is unreadable.
Range rings sit behind it, echoing the sensor rings on the AIS chart. The launch
image is the full lockup — wordmark, divider, φ — matching the SPA splash.

Everything renders at 4x and downsamples, because the settings icon is where
thin Courier strokes fall apart.

    python3 tool/generate_icons.py

Requires Pillow, Nimbus Mono PS (URW's Courier, `fonts-urw-base35`) and DejaVu
Sans Mono.
"""

import json
import os
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICONSET = os.path.join(ROOT, "ios/Runner/Assets.xcassets/AppIcon.appiconset")
LAUNCHSET = os.path.join(ROOT, "ios/Runner/Assets.xcassets/LaunchImage.imageset")
ANDROID = os.path.join(ROOT, "android/app/src/main/res")

# Straight from lib/src/theme.dart and lib/src/ui/ident_logo.dart.
GREEN = (0x3D, 0xD6, 0x8C)
SHELL = (0x0B, 0x0D, 0x12)
SURFACE = (0x14, 0x18, 0x21)

MONO_BOLD = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf"
MONO = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"
# The web app sets the φ in "Courier New", Courier, monospace. Nimbus Mono PS is
# URW's Courier — the same metrics and the same thin stroke, which is what makes
# the glyph read as light without a light weight existing.
COURIER = "/usr/share/fonts/opentype/urw-base35/NimbusMonoPS-Regular.otf"

PHI = "φ"

LAUNCH_W, LAUNCH_H = 260, 96  # @1x points; mirrored in LaunchScreen.storyboard

SS = 4  # supersample factor


def _font(path, size):
    try:
        return ImageFont.truetype(path, size)
    except OSError as e:
        raise SystemExit(
            f"missing font {path}. Install fonts-dejavu and fonts-urw-base35, "
            f"or point the font constants at equivalent faces."
        ) from e


def _centred(draw, xy, text, font, fill):
    """Draw text centred on xy by its ink box, not its line box.

    Monospace line boxes carry ascender/descender padding that a single glyph
    never fills, so centring on the line box floats the mark high.
    """
    l, t, r, b = draw.textbbox((0, 0), text, font=font)
    draw.text((xy[0] - (l + r) / 2, xy[1] - (t + b) / 2), text, font=font, fill=fill)


def _fit_by_ink(draw, path, text, target_height):
    """Largest font size whose rendered ink is `target_height` tall.

    Courier sets a glyph small inside its em box, and φ's stem overshoots both
    the ascender and the baseline, so no fixed fraction of the em predicts the
    mark's real height. Measure it instead.
    """
    lo, hi = 4, int(target_height * 6)
    while lo < hi:
        mid = (lo + hi + 1) // 2
        _, t, _, b = draw.textbbox((0, 0), text, font=_font(path, mid))
        if b - t <= target_height:
            lo = mid
        else:
            hi = mid - 1
    return _font(path, lo)


def build_icon(size):
    """The 1024px master, rendered at `size` * SS then downsampled."""
    n = size * SS
    img = Image.new("RGB", (n, n), SHELL)
    d = ImageDraw.Draw(img, "RGBA")

    # Vertical shell -> surface gradient. Flat black reads as a hole in the
    # home screen next to Apple's own icons.
    for y in range(n):
        f = y / (n - 1)
        d.line(
            [(0, y), (n, y)],
            fill=tuple(round(SURFACE[i] + (SHELL[i] - SURFACE[i]) * f) for i in range(3)),
        )

    # Range rings, centred on the monogram.
    cx, cy = n / 2, n * 0.5
    for i, (radius, alpha) in enumerate(((0.30, 46), (0.42, 34), (0.54, 22))):
        r = n * radius
        d.ellipse(
            [cx - r, cy - r, cx + r, cy + r],
            outline=GREEN + (alpha,),
            width=max(1, round(n * 0.006)),
        )

    # The φ, sized by its ink so it fills the frame the way Apple's own marks do.
    _centred(d, (cx, cy), PHI, _fit_by_ink(d, COURIER, PHI, n * 0.62), GREEN)

    return img.resize((size, size), Image.LANCZOS)


def build_launch(width, height):
    """The full lockup — IDent/dynamics, divider, φ — transparent, for the
    launch storyboard.

    Proportions follow `#app-logo` in the web app's styles.css: 1.35rem over
    0.95rem at 0.18em tracking, a 0.6rem gap either side of a 1px divider at
    0.45 alpha, and the φ at 2.4rem.

    The φ is centred on the divider, **not** anchored to its top as the CSS
    `align-self: flex-start` would have it. Faithful to the web is not the same
    as right here: the φ's ink is about half the divider's height, so anchoring
    it to the top leaves it sitting against "IDent" with nothing beside
    "dynamics", and the mark reads as floating above its own wordmark rather
    than closing it.
    """
    n_w, n_h = width * SS, height * SS
    img = Image.new("RGBA", (n_w, n_h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    rem = n_h / 4.6  # the lockup is a shade under five rem tall
    f1 = _font(MONO_BOLD, round(rem * 1.35))
    f2 = _font(MONO, round(rem * 0.95))
    fphi = _font(COURIER, round(rem * 2.4))

    line1, line2 = "IDent", "dynamics"
    track2 = round(rem * 0.95 * 0.18)  # 0.18em, applied per gap below

    def tracked_width(text, font, tracking):
        return sum(d.textlength(c, font=font) for c in text) + tracking * (len(text) - 1)

    def draw_tracked(x, y, text, font, tracking, fill):
        for c in text:
            d.text((x, y), c, font=font, fill=fill)
            x += d.textlength(c, font=font) + tracking

    w1 = tracked_width(line1, f1, round(rem * 1.35 * 0.04))
    w2 = tracked_width(line2, f2, track2)
    stack_w = max(w1, w2)

    _, pt, _, pb = d.textbbox((0, 0), PHI, font=fphi)
    phi_w = d.textlength(PHI, font=fphi)
    gap = rem * 0.6

    total = stack_w + gap + max(1, round(n_w / 400)) + gap + phi_w
    x0 = (n_w - total) / 2

    # Vertical: the stack is centred, and the divider spans it.
    stack_h = rem * 1.35 * 1.25 + rem * 0.15 + rem * 0.95 * 1.25
    y0 = (n_h - stack_h) / 2

    draw_tracked(x0, y0, line1, f1, round(rem * 1.35 * 0.04), GREEN + (255,))
    draw_tracked(
        x0, y0 + rem * 1.35 * 1.25 + rem * 0.15, line2, f2, track2, GREEN + (230,)
    )

    div_x = x0 + stack_w + gap
    div_w = max(1, round(n_w / 400))
    d.rectangle([div_x, y0, div_x + div_w, y0 + stack_h], fill=GREEN + (115,))

    # φ centred on the divider by its ink box. Centring on the line box would
    # float it high all over again — Courier carries ascender and descender
    # padding this single glyph never fills, which is the same reason _centred
    # exists for the icon.
    phi_y = y0 + (stack_h - (pb - pt)) / 2 - pt
    d.text((div_x + div_w + gap, phi_y), PHI, font=fphi, fill=GREEN + (255,))

    return img.resize((width, height), Image.LANCZOS)


def main():
    # iOS icons: sizes come from the asset catalogue, so adding an entry there
    # is enough — no list to keep in step here.
    with open(os.path.join(ICONSET, "Contents.json")) as fh:
        catalogue = json.load(fh)

    written = {}
    for entry in catalogue["images"]:
        pt = float(entry["size"].split("x")[0])
        px = round(pt * int(entry["scale"].rstrip("x")))
        name = entry["filename"]
        if name in written:
            continue
        # The App Store marketing icon must have no alpha; the rest are opaque
        # anyway because the icon is built on an opaque background.
        build_icon(px).save(os.path.join(ICONSET, name))
        written[name] = px
    print(f"iOS icons:  {len(written)} files -> {ICONSET}")

    # Wider than the stock 168x185 Flutter mark, because the lockup is a row.
    # LaunchScreen.storyboard declares these same @1x dimensions — keep in step.
    for scale, name in ((1, "LaunchImage.png"), (2, "LaunchImage@2x.png"), (3, "LaunchImage@3x.png")):
        build_launch(LAUNCH_W * scale, LAUNCH_H * scale).save(os.path.join(LAUNCHSET, name))
    print(f"Launch:     3 files -> {LAUNCHSET}")

    # Android launcher icons, so the two platforms don't drift apart.
    android_sizes = {
        "mipmap-mdpi": 48,
        "mipmap-hdpi": 72,
        "mipmap-xhdpi": 96,
        "mipmap-xxhdpi": 144,
        "mipmap-xxxhdpi": 192,
    }
    count = 0
    for folder, px in android_sizes.items():
        path = os.path.join(ANDROID, folder)
        if not os.path.isdir(path):
            continue
        build_icon(px).save(os.path.join(path, "ic_launcher.png"))
        count += 1
    print(f"Android:    {count} files -> {ANDROID}")


if __name__ == "__main__":
    main()
