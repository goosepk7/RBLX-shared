#!/usr/bin/env python3
"""Rasterizes SVG icons to PNG (brief §5.6).

    python3 tools/rasterize.py                 # all of assets/icons/svg
    python3 tools/rasterize.py icon_wins ...   # specific icons

Outputs assets/icons/png/256/<name>.png (store/badge/shop art; the 64-unit
SVG grid already includes the 24 px padding at 256) and
assets/icons/png/64/<name>.png (HUD). Requires `pip install cairosvg`.
"""

from __future__ import annotations

import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "assets", "icons", "svg")
SIZES = (256, 64)


def main(argv: list[str]) -> int:
    try:
        import cairosvg  # type: ignore
    except ImportError:
        print("cairosvg is not installed: pip install cairosvg", file=sys.stderr)
        return 1

    names = argv or sorted(f[:-4] for f in os.listdir(SRC) if f.endswith(".svg"))
    for size in SIZES:
        os.makedirs(os.path.join(ROOT, "assets", "icons", "png", str(size)), exist_ok=True)
    for name in names:
        src = os.path.join(SRC, name + ".svg")
        if not os.path.exists(src):
            print(f"missing {src}", file=sys.stderr)
            return 1
        for size in SIZES:
            out = os.path.join(ROOT, "assets", "icons", "png", str(size), name + ".png")
            cairosvg.svg2png(url=src, write_to=out, output_width=size, output_height=size)
        print("rasterized", name)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
