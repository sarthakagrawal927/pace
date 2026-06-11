#!/usr/bin/env python3
"""Generates the Pace app icon set from code so the design is reproducible.

Design: macOS rounded-square tile (dark, subtle vertical sheen) holding the
Pace cursor arrow — gradient blue fill, soft white highlight edge, outer
glow, drop shadow — matching CodexArrowShape's gradient/stroke/dual-shadow
look from the cursor overlay.

Usage: python3 scripts/generate-app-icon.py
Writes every size into leanring-buddy/Assets.xcassets/AppIcon.appiconset/.
"""

import math
import os

from PIL import Image, ImageDraw, ImageFilter

CANVAS = 1024
SS = 4  # supersampling factor
S = CANVAS * SS

OUTPUT_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "leanring-buddy/Assets.xcassets/AppIcon.appiconset",
)
SIZES = {16: "16-mac.png", 32: "32-mac.png", 64: "64-mac.png",
         128: "128-mac.png", 256: "256-mac.png", 512: "512-mac.png",
         1024: "1024-mac.png"}


def rounded_tile_mask(size, box, radius):
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, radius=radius, fill=255)
    return mask


def vertical_gradient(size, top_rgb, bottom_rgb):
    gradient = Image.new("RGB", (1, size))
    for y in range(size):
        t = y / (size - 1)
        gradient.putpixel((0, y), tuple(
            int(top_rgb[i] + (bottom_rgb[i] - top_rgb[i]) * t) for i in range(3)
        ))
    return gradient.resize((size, size))


def arrow_polygon(size):
    # Pace cursor arrow: a sleek left-pointing arrowhead, slightly rotated,
    # echoing the on-screen CodexArrowShape. Coordinates in unit space.
    unit_points = [(0.18, 0.50), (0.78, 0.22), (0.64, 0.50), (0.78, 0.78)]
    cx, cy, rotation_degrees = 0.495, 0.50, -8
    theta = math.radians(rotation_degrees)
    points = []
    for ux, uy in unit_points:
        dx, dy = ux - cx, uy - cy
        rx = cx + dx * math.cos(theta) - dy * math.sin(theta)
        ry = cy + dx * math.sin(theta) + dy * math.cos(theta)
        points.append((rx * size, ry * size))
    return points


def build_icon():
    icon = Image.new("RGBA", (S, S), (0, 0, 0, 0))

    # --- macOS tile: ~80% of canvas, squircle-ish radius, drop shadow ---
    margin = int(S * 0.098)
    tile_box = (margin, margin, S - margin, S - margin)
    tile_radius = int((S - 2 * margin) * 0.2237)

    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    shadow_mask = rounded_tile_mask(S, tile_box, tile_radius)
    shadow.paste((0, 0, 0, 110), (0, int(S * 0.012)), shadow_mask)
    icon = Image.alpha_composite(icon, shadow.filter(ImageFilter.GaussianBlur(S * 0.012)))

    tile = vertical_gradient(S, (32, 34, 38), (12, 13, 15)).convert("RGBA")
    tile_mask = rounded_tile_mask(S, tile_box, tile_radius)
    icon.paste(tile, (0, 0), tile_mask)

    # Faint top sheen inside the tile.
    sheen = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sheen_draw = ImageDraw.Draw(sheen)
    sheen_draw.rounded_rectangle(
        (margin, margin, S - margin, int(S * 0.45)),
        radius=tile_radius, fill=(255, 255, 255, 14),
    )
    icon = Image.alpha_composite(icon, sheen.filter(ImageFilter.GaussianBlur(S * 0.02)))

    # Hairline tile edge highlight.
    edge = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(edge).rounded_rectangle(
        tile_box, radius=tile_radius, outline=(255, 255, 255, 26), width=max(2, SS * 2)
    )
    icon = Image.alpha_composite(icon, edge)

    # --- arrow: glow, gradient fill, highlight stroke ---
    points = arrow_polygon(S)

    arrow_mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(arrow_mask).polygon(points, fill=255)
    # Soften corners slightly: blur then re-threshold.
    arrow_mask = arrow_mask.filter(ImageFilter.GaussianBlur(S * 0.006)).point(
        lambda v: 255 if v > 128 else 0
    ).filter(ImageFilter.GaussianBlur(SS))

    glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    glow.paste((64, 156, 255, 150), (0, 0), arrow_mask)
    icon = Image.alpha_composite(icon, glow.filter(ImageFilter.GaussianBlur(S * 0.028)))

    arrow_gradient = vertical_gradient(S, (132, 196, 255), (38, 116, 255)).convert("RGBA")
    arrow_layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    arrow_layer.paste(arrow_gradient, (0, 0), arrow_mask)
    icon = Image.alpha_composite(icon, arrow_layer)

    stroke = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(stroke).polygon(points, outline=(255, 255, 255, 165), width=max(3, SS * 3))
    icon = Image.alpha_composite(icon, stroke.filter(ImageFilter.GaussianBlur(SS)))

    return icon


def main():
    icon = build_icon()
    for size, filename in SIZES.items():
        resized = icon.resize((size, size), Image.LANCZOS)
        resized.save(os.path.join(OUTPUT_DIR, filename))
        print(f"wrote {filename}")


if __name__ == "__main__":
    main()
