#!/usr/bin/env python3
"""Generates the shared core icon SVGs (brief §5.6) into assets/icons/svg/.

Style ("premium sticker"), applied uniformly by `part()`:
  * solid filled shapes on a 64x64 grid with 6 px padding (24 px at 256),
  * 2.5 px outline in Ink at 85%,
  * two-tone shading: base + a darker shade (base mixed 22% toward Ink) on the
    lower third of each shape,
  * one top-left highlight ellipse at 18% white per icon.

The SVGs are the source of truth and are committed; edit this file and re-run
`python3 tools/icons/build_icons.py`, then `python3 tools/rasterize.py`.
"""

from __future__ import annotations

import math
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "assets", "icons", "svg")

# Colors come from src/UI/Tokens.luau (palette + per-game accents).
INK = "#1E2235"
INK_SOFT = "#5A6178"
PAPER = "#FFFFFF"
PAPER2 = "#F3F5FA"
LINE = "#D9DEEA"
LINE_DARK = "#B9C0D3"
SUCCESS = "#3DD68C"
DANGER = "#FF5A6E"
WARNING = "#FFC53D"
INFO = "#4DA3FF"
GOLD = "#FFD166"
VIOLET = "#6C5CE7"  # Stilts secondary
AMBER = "#FF9F1C"  # Car secondary
TEAL = "#2EC4B6"  # Car primary

OUTLINE = 2.5
OUTLINE_OPACITY = 0.85
HIGHLIGHT_OPACITY = 0.18
SHADE_AMOUNT = 0.22


def hex_to_rgb(h: str) -> tuple[int, int, int]:
    h = h.lstrip("#")
    return int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)


def shade(h: str, amount: float = SHADE_AMOUNT) -> str:
    r, g, b = hex_to_rgb(h)
    ir, ig, ib = hex_to_rgb(INK)
    mix = lambda a, c: round(a + (c - a) * amount)  # noqa: E731
    return "#%02X%02X%02X" % (mix(r, ir), mix(g, ig), mix(b, ib))


class Icon:
    def __init__(self, name: str, transform: str | None = None):
        self.name = name
        self.transform = transform
        self.body: list[str] = []
        self.defs: list[str] = []
        self.count = 0
        self.highlighted = False

    def part(
        self,
        shape: str,
        fill: str,
        box: tuple[float, float, float, float],
        *,
        shaded: bool = True,
        highlight: bool = False,
        outline: bool = True,
        evenodd: bool = False,
    ) -> None:
        """Draws one sticker part. `shape` is an SVG element without fill/stroke
        attributes; `box` is its bounding box (x0, y0, x1, y1)."""
        self.count += 1
        cid = f"{self.name}-c{self.count}"
        rule = ' fill-rule="evenodd" clip-rule="evenodd"' if evenodd else ""
        x0, y0, x1, y1 = box
        self.defs.append(f'<clipPath id="{cid}">{self._attrs(shape, rule)}</clipPath>')
        self.body.append(self._attrs(shape, f' fill="{fill}"{rule}'))
        inner: list[str] = []
        if shaded:
            top = y0 + (y1 - y0) * 2 / 3
            inner.append(
                f'<rect x="{x0 - 2:g}" y="{top:g}" width="{x1 - x0 + 4:g}" '
                f'height="{y1 - top + 2:g}" fill="{shade(fill)}"/>'
            )
        if highlight:
            assert not self.highlighted, f"{self.name}: only one highlight per icon"
            self.highlighted = True
            w, h = x1 - x0, y1 - y0
            inner.append(
                f'<ellipse cx="{x0 + w * 0.3:g}" cy="{y0 + h * 0.24:g}" rx="{w * 0.2:g}" ry="{h * 0.11:g}" '
                f'transform="rotate(-30 {x0 + w * 0.3:g} {y0 + h * 0.24:g})" '
                f'fill="#FFFFFF" fill-opacity="{HIGHLIGHT_OPACITY}"/>'
            )
        if inner:
            self.body.append(f'<g clip-path="url(#{cid})">{"".join(inner)}</g>')
        if outline:
            self.body.append(
                self._attrs(
                    shape,
                    f' fill="none" stroke="{INK}" stroke-opacity="{OUTLINE_OPACITY}" '
                    f'stroke-width="{OUTLINE}" stroke-linejoin="round" stroke-linecap="round"',
                )
            )

    def line(self, d: str, color: str, width: float, outlined: bool = True) -> None:
        """A stroked line (check marks, ticks). Outlined lines get an Ink
        under-stroke so they match the sticker outline."""
        if outlined:
            self.body.append(
                f'<path d="{d}" fill="none" stroke="{INK}" stroke-opacity="{OUTLINE_OPACITY}" '
                f'stroke-width="{width + OUTLINE * 2:g}" stroke-linecap="round" stroke-linejoin="round"/>'
            )
        self.body.append(
            f'<path d="{d}" fill="none" stroke="{color}" stroke-width="{width:g}" '
            f'stroke-linecap="round" stroke-linejoin="round"/>'
        )

    @staticmethod
    def _attrs(shape: str, attrs: str) -> str:
        assert shape.endswith("/>"), shape
        return shape[:-2] + attrs + "/>"

    def svg(self) -> str:
        group_open = f'<g transform="{self.transform}">' if self.transform else "<g>"
        return (
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="64" height="64">'
            f'<title>{self.name}</title><defs>{"".join(self.defs)}</defs>'
            f'{group_open}{"".join(self.body)}</g></svg>\n'
        )


# ---------------------------------------------------------------- geometry


def fmt(points: list[tuple[float, float]]) -> str:
    return " ".join(f"{x:.2f},{y:.2f}" for x, y in points)


def gear_path(cx: float, cy: float, r_out: float, r_in: float, teeth: int, hole: float) -> str:
    pts: list[tuple[float, float]] = []
    step = 2 * math.pi / teeth
    for i in range(teeth):
        a = i * step - math.pi / 2
        # tooth: base wider than tip
        for da, r in ((-0.30, r_in), (-0.17, r_out), (0.17, r_out), (0.30, r_in)):
            ang = a + da * step * 1.6
            pts.append((cx + math.cos(ang) * r, cy + math.sin(ang) * r))
    d = "M" + " L".join(f"{x:.2f} {y:.2f}" for x, y in pts) + " Z"
    d += f" M{cx + hole:.2f} {cy:.2f} A{hole} {hole} 0 1 0 {cx - hole:.2f} {cy:.2f} A{hole} {hole} 0 1 0 {cx + hole:.2f} {cy:.2f} Z"
    return d


def star_points(cx: float, cy: float, r_out: float, r_in: float) -> list[tuple[float, float]]:
    pts = []
    for i in range(10):
        r = r_out if i % 2 == 0 else r_in
        a = -math.pi / 2 + i * math.pi / 5
        pts.append((cx + math.cos(a) * r, cy + math.sin(a) * r))
    return pts


def arc_arrow(cx: float, cy: float, r: float, width: float, a0: float, a1: float) -> str:
    """Thick circular arc from a0 to a1 (degrees, clockwise) ending in an arrowhead."""
    ro, ri = r + width / 2, r - width / 2
    n = 16
    outer = [
        (cx + math.cos(math.radians(a0 + (a1 - a0) * t / n)) * ro, cy + math.sin(math.radians(a0 + (a1 - a0) * t / n)) * ro)
        for t in range(n + 1)
    ]
    inner = [
        (cx + math.cos(math.radians(a0 + (a1 - a0) * t / n)) * ri, cy + math.sin(math.radians(a0 + (a1 - a0) * t / n)) * ri)
        for t in range(n, -1, -1)
    ]
    end = math.radians(a1)
    tip_ang = math.radians(a1 + 26)
    head = [
        (cx + math.cos(end) * (ro + width * 0.55), cy + math.sin(end) * (ro + width * 0.55)),
        (cx + math.cos(tip_ang) * r, cy + math.sin(tip_ang) * r),
        (cx + math.cos(end) * (ri - width * 0.55), cy + math.sin(end) * (ri - width * 0.55)),
    ]
    pts = outer + head + inner
    return "M" + " L".join(f"{x:.2f} {y:.2f}" for x, y in pts) + " Z"


# ---------------------------------------------------------------- icons


def icon_wins() -> Icon:
    i = Icon("icon_wins")
    ring = "M{0} 23 m-8 0 a8 8 0 1 0 16 0 a8 8 0 1 0 -16 0 Z M{0} 23 m-4 0 a4 4 0 1 0 8 0 a4 4 0 1 0 -8 0 Z"
    i.part(f'<path d="{ring.format(16)}"/>', GOLD, (8, 15, 24, 31), shaded=False, evenodd=True)
    i.part(f'<path d="{ring.format(48)}"/>', GOLD, (40, 15, 56, 31), shaded=False, evenodd=True)
    i.part('<rect x="27" y="38" width="10" height="9"/>', shade(GOLD), (27, 38, 37, 47), shaded=False)
    i.part('<path d="M16 9 H48 V23 C48 33 41 40 32 40 C23 40 16 33 16 23 Z"/>', GOLD, (16, 9, 48, 40), highlight=True)
    i.part('<polygon points="%s"/>' % fmt(star_points(32, 22, 7, 3)), PAPER, (25, 15, 39, 29), shaded=False)
    i.part('<rect x="18" y="46" width="28" height="10" rx="3"/>', VIOLET, (18, 46, 46, 56))
    return i


def icon_height() -> Icon:
    i = Icon("icon_height", "rotate(18 32 32)")
    i.part('<rect x="21" y="6" width="22" height="52" rx="4"/>', WARNING, (21, 6, 43, 58), highlight=True)
    for k, y in enumerate(range(12, 56, 6)):
        length = 11 if k % 2 == 0 else 6
        i.line(f"M21 {y} H{21 + length}", INK, 2.5, outlined=False)
    return i


def coin(i: Icon, cy: float, top: bool) -> None:
    body = f'<path d="M12 {cy} A20 7 0 0 1 52 {cy} V{cy + 7} A20 7 0 0 1 12 {cy + 7} Z"/>'
    i.part(body, shade(GOLD), (12, cy - 7, 52, cy + 14), shaded=False)
    i.part(f'<ellipse cx="32" cy="{cy}" rx="20" ry="7"/>', GOLD, (12, cy - 7, 52, cy + 7), shaded=False, highlight=top)
    if top:
        i.part(f'<ellipse cx="32" cy="{cy}" rx="12" ry="3.6"/>', shade(GOLD, 0.12), (20, cy - 4, 44, cy + 4), shaded=False)


def icon_cash() -> Icon:
    i = Icon("icon_cash")
    for k, cy in enumerate((44, 33, 22, 13)):
        coin(i, cy, k == 3)
    return i


def icon_part() -> Icon:
    i = Icon("icon_part")
    i.part(f'<path d="{gear_path(32, 32, 25, 19, 10, 8)}"/>', AMBER, (7, 7, 57, 57), highlight=True, evenodd=True)
    hexagon = [(32 + math.cos(math.radians(60 * k + 30)) * 11, 32 + math.sin(math.radians(60 * k + 30)) * 11) for k in range(6)]
    hole = "M40 32 A8 8 0 1 0 24 32 A8 8 0 1 0 40 32 Z"
    i.part(f'<path d="M{fmt(hexagon).replace(" ", " L")} Z {hole}"/>', LINE, (21, 21, 43, 43), evenodd=True)
    return i


def icon_settings() -> Icon:
    i = Icon("icon_settings")
    i.part(f'<path d="{gear_path(32, 32, 26, 19, 8, 9)}"/>', LINE, (6, 6, 58, 58), highlight=True, evenodd=True)
    return i


def icon_rebirth() -> Icon:
    i = Icon("icon_rebirth")
    i.part(f'<path d="{arc_arrow(32, 32, 19, 9, 200, 330)}"/>', VIOLET, (8, 6, 58, 34), highlight=True)
    i.part(f'<path d="{arc_arrow(32, 32, 19, 9, 20, 150)}"/>', VIOLET, (6, 30, 56, 58))
    i.part('<circle cx="32" cy="32" r="5"/>', TEAL, (27, 27, 37, 37), shaded=False)
    return i


def icon_codes() -> Icon:
    i = Icon("icon_codes", "rotate(-14 32 32)")
    d = "M6 17 H58 V27 A5 5 0 0 0 58 37 V47 H6 V37 A5 5 0 0 0 6 27 Z"
    i.part(f'<path d="{d}"/>', INFO, (6, 17, 58, 47), highlight=True)
    for y in (21, 27, 33, 39):
        i.line(f"M22 {y} V{y + 3}", PAPER, 2.5, outlined=False)
    i.part('<polygon points="%s"/>' % fmt(star_points(41, 32, 8, 3.5)), PAPER, (33, 24, 49, 40), shaded=False)
    return i


def icon_leaderboard() -> Icon:
    i = Icon("icon_leaderboard")
    i.part('<rect x="7" y="33" width="17" height="23" rx="2"/>', LINE, (7, 33, 24, 56))
    i.part('<rect x="40" y="38" width="17" height="18" rx="2"/>', AMBER, (40, 38, 57, 56))
    i.part('<rect x="23" y="24" width="18" height="32" rx="2"/>', GOLD, (23, 24, 41, 56), highlight=True)
    i.part('<polygon points="%s"/>' % fmt(star_points(32, 13, 8.5, 3.8)), WARNING, (23, 4, 41, 21), shaded=False)
    return i


def icon_shop() -> Icon:
    i = Icon("icon_shop")
    i.part('<path d="M21 24 A11 11 0 0 1 43 24 H38 A6 6 0 0 0 26 24 Z"/>', LINE_DARK, (21, 13, 43, 24), shaded=False)
    i.part('<path d="M12 24 H52 L55 56 H9 Z"/>', SUCCESS, (9, 24, 55, 56), highlight=True)
    i.part('<circle cx="24" cy="32" r="2.5"/>', INK_SOFT, (21, 29, 27, 35), shaded=False, outline=False)
    i.part('<circle cx="40" cy="32" r="2.5"/>', INK_SOFT, (37, 29, 43, 35), shaded=False, outline=False)
    return i


def icon_event() -> Icon:
    i = Icon("icon_event")
    i.part('<rect x="12" y="6" width="6" height="52" rx="3"/>', INK_SOFT, (12, 6, 18, 58), shaded=False)
    i.part('<path d="M18 9 C28 4 36 15 54 9 V33 C36 39 28 28 18 33 Z"/>', DANGER, (18, 4, 54, 39), highlight=True)
    i.part('<circle cx="15" cy="6" r="4"/>', GOLD, (11, 2, 19, 10), shaded=False)
    return i


def icon_star(filled: bool) -> Icon:
    i = Icon("icon_star" if filled else "icon_star_empty")
    pts = '<polygon points="%s"/>' % fmt(star_points(32, 34, 27, 12))
    if filled:
        i.part(pts, WARNING, (5, 7, 59, 56), highlight=True)
    else:
        i.part(pts, PAPER2, (5, 7, 59, 56))
    return i


def icon_weight() -> Icon:
    i = Icon("icon_weight")
    i.part('<path d="M19 22 A13 13 0 0 1 45 22 H38 A6 6 0 0 0 26 22 Z"/>', INK_SOFT, (19, 9, 45, 22), shaded=False)
    i.part('<path d="M16 24 H48 L56 56 H8 Z"/>', LINE_DARK, (8, 24, 56, 56), highlight=True)
    i.part('<rect x="22" y="36" width="20" height="10" rx="3"/>', WARNING, (22, 36, 42, 46), shaded=False)
    return i


def icon_lock() -> Icon:
    i = Icon("icon_lock")
    i.part('<path d="M18 30 V22 A14 14 0 0 1 46 22 V30 H39 V22 A7 7 0 0 0 25 22 V30 Z"/>', LINE_DARK, (18, 8, 46, 30), shaded=False)
    i.part('<rect x="12" y="28" width="40" height="29" rx="6"/>', WARNING, (12, 28, 52, 57), highlight=True)
    i.part('<path d="M32 36 A4.5 4.5 0 0 1 34.5 44.2 L36 50 H28 L29.5 44.2 A4.5 4.5 0 0 1 32 36 Z"/>', INK, (27.5, 36, 36.5, 50), shaded=False, outline=False)
    return i


def icon_check() -> Icon:
    i = Icon("icon_check")
    i.part('<circle cx="32" cy="32" r="25"/>', SUCCESS, (7, 7, 57, 57), highlight=True)
    i.line("M20 33 L28.5 41.5 L44.5 24.5", PAPER, 6.5)
    return i


def icon_warning() -> Icon:
    i = Icon("icon_warning")
    i.part('<path d="M32 7 L58 54 H6 Z"/>', WARNING, (6, 7, 58, 54), highlight=True)
    i.line("M32 23 V37", INK, 6, outlined=False)
    i.part('<circle cx="32" cy="45.5" r="3.6"/>', INK, (28, 42, 36, 49), shaded=False, outline=False)
    return i


ICONS = [
    icon_wins,
    icon_height,
    icon_cash,
    icon_part,
    icon_rebirth,
    icon_codes,
    icon_leaderboard,
    icon_shop,
    icon_settings,
    icon_event,
    lambda: icon_star(True),
    lambda: icon_star(False),
    icon_weight,
    icon_lock,
    icon_check,
    icon_warning,
]


def main() -> int:
    os.makedirs(OUT, exist_ok=True)
    for build in ICONS:
        icon = build()
        path = os.path.join(OUT, icon.name + ".svg")
        with open(path, "w", encoding="utf-8") as f:
            f.write(icon.svg())
        print("wrote", os.path.relpath(path, ROOT))
    return 0


if __name__ == "__main__":
    sys.exit(main())
