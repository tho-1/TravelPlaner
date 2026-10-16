"""Regenerate the app icon (all platforms) from geometry.

The previous icon was a hand-cut polygon that read as a
lopsided triangle, not a plane (the user's report a,
2026-10-16). This script draws the mark from explicit
points instead -- a teal tile (the app's theme seed), a
white paper plane built from two triangles, and the gold
dotted flight arc behind it -- so the drawing is symmetric,
reproducible and re-runnable:

    python mobile/tools/generate_app_icons.py

Outputs:

* ``mobile/app_icon.png``                    -- 1024 px master
* ``mobile/windows/runner/resources/app_icon.ico``
* ``mobile/android/app/src/main/res/mipmap-*/ic_launcher.png``

The colours are the app's own: the teal theme seed and the
favourite-star gold from ``lib/ui/theme.dart``.
"""

from __future__ import annotations

import math
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent

TEAL_TOP = (32, 148, 158)  # lightened top of the tile
TEAL_BOTTOM = (9, 92, 101)  # darkened bottom of the tile
WHITE = (255, 255, 255)
FOLD = (206, 231, 234)  # the shaded far wing
GOLD = (246, 177, 0)  # accentFavourite
CORNER = 0.20  # tile corner radius, fraction of the side

#: The paper plane in a unit box (x right, y down): the
#: nose, the two tail tips and the notch between them. The
#: crease runs nose -> notch, which is what makes the shape
#: read as folded paper rather than a plain triangle.
NOSE = (0.96, 0.50)
TOP_TAIL = (0.04, 0.10)
NOTCH = (0.36, 0.50)
BOTTOM_TAIL = (0.04, 0.90)
PLANE_ANGLE = -32.0  # degrees; nose points up-right
PLANE_SCALE = 0.44  # fraction of the canvas
PLANE_CENTER = (0.52, 0.42)

#: The dotted flight arc: a quadratic Bezier behind the
#: plane, lower-left rising to upper-right.
ARC_FROM = (0.16, 0.80)
ARC_VIA = (0.44, 0.82)
ARC_TO = (0.80, 0.62)
ARC_DOTS = 9


def _lerp(a: tuple, b: tuple, t: float) -> tuple:
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


def _transform(point: tuple, center: tuple, scale: float, angle: float) -> tuple:
    """Unit-box point -> canvas pixels: rotate, scale, place."""
    radians = math.radians(angle)
    x, y = point[0] - 0.5, point[1] - 0.5
    rotated = (
        x * math.cos(radians) - y * math.sin(radians),
        x * math.sin(radians) + y * math.cos(radians),
    )
    return (
        center[0] + rotated[0] * scale,
        center[1] + rotated[1] * scale,
    )


def _bezier(p0: tuple, p1: tuple, p2: tuple, t: float) -> tuple:
    u = 1 - t
    return (
        u * u * p0[0] + 2 * u * t * p1[0] + t * t * p2[0],
        u * u * p0[1] + 2 * u * t * p1[1] + t * t * p2[1],
    )


def draw_icon(size: int) -> Image.Image:
    """The mark at ``size`` x ``size``, drawn on the master
    canvas and downscaled by the caller."""
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(canvas)

    # The tile: rounded square with a vertical teal gradient.
    gradient = Image.new("RGBA", (size, size))
    top = ImageDraw.Draw(gradient)
    for row in range(size):
        top.line(
            [(0, row), (size, row)],
            fill=_lerp(TEAL_TOP, TEAL_BOTTOM, row / max(1, size - 1)),
        )
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, size - 1, size - 1),
        radius=int(size * CORNER),
        fill=255,
    )
    canvas = Image.composite(gradient, canvas, mask)
    draw = ImageDraw.Draw(canvas)

    # The dotted flight arc (behind the plane).
    dot_radius = size * 0.016
    for index in range(ARC_DOTS):
        t = index / (ARC_DOTS - 1)
        x, y = _bezier(ARC_FROM, ARC_VIA, ARC_TO, t)
        px, py = x * size, y * size
        # Dots grow towards the plane, like a trail.
        radius = dot_radius * (0.7 + 0.6 * t)
        draw.ellipse(
            (px - radius, py - radius, px + radius, py + radius),
            fill=GOLD,
        )

    # The paper plane: bright near wing, shaded far wing.
    def place(point: tuple) -> tuple:
        x, y = _transform(
            point, (PLANE_CENTER[0] * size, PLANE_CENTER[1] * size),
            PLANE_SCALE * size, PLANE_ANGLE,
        )
        return (x, y)

    nose = place(NOSE)
    top_tail = place(TOP_TAIL)
    notch = place(NOTCH)
    bottom_tail = place(BOTTOM_TAIL)
    draw.polygon([nose, top_tail, notch], fill=WHITE)
    draw.polygon([nose, notch, bottom_tail], fill=FOLD)
    # The crease, a hair darker, so the fold reads at size.
    draw.line([nose, notch], fill=(168, 208, 212), width=max(1, size // 300))
    return canvas


def main() -> None:
    master = draw_icon(1024)
    master.save(ROOT / "app_icon.png")

    ico_sizes = [16, 24, 32, 48, 64, 128, 256]
    master.save(
        ROOT / "windows" / "runner" / "resources" / "app_icon.ico",
        format="ICO",
        sizes=[(s, s) for s in ico_sizes],
    )

    mipmap = ROOT / "android" / "app" / "src" / "main" / "res"
    for name, size in [
        ("mipmap-mdpi", 48),
        ("mipmap-hdpi", 72),
        ("mipmap-xhdpi", 96),
        ("mipmap-xxhdpi", 144),
        ("mipmap-xxxhdpi", 192),
    ]:
        master.resize((size, size), Image.LANCZOS).save(
            mipmap / name / "ic_launcher.png"
        )

    # A quick-look preview at 256 px next to the master.
    master.resize((256, 256), Image.LANCZOS).save(
        ROOT / "tools" / "app_icon_preview.png"
    )
    print("icons written: master 1024, .ico", ico_sizes, "+ 5 Android mipmaps")


if __name__ == "__main__":
    main()
