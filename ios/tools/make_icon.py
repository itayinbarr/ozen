#!/usr/bin/env python3
"""Renders the app icons from the in-app ear mark. Run from ios/: python3 tools/make_icon.py

The mark is the design's EAR_O / EAR_I strokes (Shared/OzenStyle.swift, EarPaths), centred the
way the home orb centres them (ear point (56, 50) at the middle), drawn with round caps:
  * icon-1024.png         orange #ff7f11 ear on the light background #e2e8ce (the default icon)
  * icon-1024-dark.png    orange ear on the dark background #262626
  * icon-1024-tinted.png  light-grey ear on black, for the system's tinted appearance
Rendered at 4x and box-downscaled (anti-aliased), sRGB, no alpha.
"""
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

S = 1024
SS = 4
N = S * SS

EAR_O = [((30, 40), (30, 22), (44, 12), (56, 12)),
         ((56, 12), (72, 12), (82, 26), (82, 40)),
         ((82, 40), (82, 54), (72, 60), (66, 68)),
         ((66, 68), (60, 76), (60, 88), (50, 88)),
         ((50, 88), (44, 88), (40, 84), (40, 80))]
EAR_I = [((44, 42), (44, 32), (50, 28), (57, 28)),
         ((57, 28), (64, 28), (68, 34), (68, 40)),
         ((68, 40), (68, 48), (60, 50), (58, 56))]

SCALE = 7.4          # ear units -> icon px (the ear spans ~76 units tall => ~56% of the canvas)
STROKE = 9.0         # ear units, as in the header logo
CENTER = (56, 50)    # ear point placed at the canvas centre (the orb's translate(-56 -50))


def bezier_points(seg, steps=400):
    (x0, y0), (x1, y1), (x2, y2), (x3, y3) = seg
    t = np.linspace(0, 1, steps)
    u = 1 - t
    x = u**3 * x0 + 3 * u**2 * t * x1 + 3 * u * t**2 * x2 + t**3 * x3
    y = u**3 * y0 + 3 * u**2 * t * y1 + 3 * u * t**2 * y2 + t**3 * y3
    return np.stack([x, y], axis=1)


def render(bg, fg, path):
    img = Image.new("RGB", (N, N), bg)
    d = ImageDraw.Draw(img)
    k = SCALE * SS
    r = STROKE * k / 2
    # Optical centring: the ear's bounding box is offset from (56, 50); nudge so it sits centred.
    ox = N / 2 - CENTER[0] * k
    oy = N / 2 - CENTER[1] * k
    for stroke in (EAR_O, EAR_I):
        pts = np.concatenate([bezier_points(s) for s in stroke])
        pts = pts * k + np.array([ox, oy])
        # Dense round dabs = a stroke with round caps and joins.
        for x, y in pts:
            d.ellipse((x - r, y - r, x + r, y + r), fill=fg)
    small = img.resize((S, S), Image.BOX)
    small.save(path, optimize=True)
    print(path)


if __name__ == "__main__":
    out = Path("Ozen/Resources/Assets.xcassets/AppIcon.appiconset")
    render((0xE2, 0xE8, 0xCE), (0xFF, 0x7F, 0x11), out / "icon-1024.png")
    render((0x26, 0x26, 0x26), (0xFF, 0x7F, 0x11), out / "icon-1024-dark.png")
    render((0x00, 0x00, 0x00), (0xD8, 0xD8, 0xD8), out / "icon-1024-tinted.png")
