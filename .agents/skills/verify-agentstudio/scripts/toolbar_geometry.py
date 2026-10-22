#!/usr/bin/env python3
"""Measure fixed toolbar glyphs and declared bar paint edges in existing PNGs.

No app/process/network/image writes. Requires numpy and Pillow. Nine named
baseline rectangles and bar search bands must be chosen from the original PNG
before comparison. PASS means geometry only; text/ellipsis/warning remain visual
judgments. Exit 0=geometry stable, 1=measured movement, 2=UNKNOWN/input gap.
"""

import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image


ICONS = {"drawer", "add", "pin", "pencil", "pull_request", "editor_menu", "folder", "copy", "zoom"}


def numbers(value, count):
    result = tuple(int(part) for part in value.split(","))
    if len(result) != count:
        raise ValueError(f"Expected {count} comma-separated integers")
    return result


def patch(pixels, rectangle):
    left, top, width, height = rectangle
    if min(left, top) < 0 or min(width, height) <= 0:
        raise ValueError("Invalid rectangle")
    if left + width > pixels.shape[1] or top + height > pixels.shape[0]:
        raise ValueError("Rectangle exceeds original image")
    return pixels[top:top + height, left:left + width]


def foreground(pixels):
    luminance = pixels.mean(axis=2)
    return np.maximum(luminance - np.median(luminance), 0)


def locate(baseline, observed, rectangle, radius, search):
    left, top, width, height = rectangle
    template = foreground(patch(baseline, rectangle))
    template_norm = np.linalg.norm(template)
    ink_y, ink_x = np.where(template > 16)
    if not template_norm or not len(ink_x):
        raise ValueError("Empty baseline glyph; cannot prove geometry")
    if search:
        search_left, search_top, search_width, search_height = search
        patch(observed, search)
        x_start, x_stop = search_left, search_left + search_width - width + 1
        y_start, y_stop = search_top, search_top + search_height - height + 1
    else:
        x_start, x_stop = max(0, left - radius), min(observed.shape[1] - width, left + radius) + 1
        y_start, y_stop = max(0, top - radius), min(observed.shape[0] - height, top + radius) + 1
    if x_start >= x_stop or y_start >= y_stop:
        raise ValueError("Search region cannot fit glyph")
    best = (-1.0, 0, 0)
    for y in range(y_start, y_stop):
        for x in range(x_start, x_stop):
            sample = foreground(patch(observed, (x, y, width, height)))
            denominator = template_norm * np.linalg.norm(sample)
            score = float(np.sum(template * sample) / denominator) if denominator else 0.0
            if score > best[0]:
                best = (score, x, y)
    return {"template_x": best[1], "template_y": best[2],
            "glyph_x": best[1] + int(ink_x.min()), "glyph_y": best[2] + int(ink_y.min()),
            "dx": best[1] - left, "dy": best[2] - top,
            "correlation": round(best[0], 6),
            "measurement": "matched" if best[0] >= 0.995 else "candidate-only"}


def bar_bounds(pixels, x_span, top_band, bottom_band):
    start, end = x_span
    if not 0 <= start < end <= pixels.shape[1]:
        raise ValueError("Invalid bar x span")
    profile = np.median(pixels[:, start:end].mean(axis=2), axis=1)
    edges = np.abs(np.diff(profile))
    bounds = []
    for lower, upper in (top_band, bottom_band):
        if not 0 <= lower < upper <= len(edges) or not np.any(edges[lower:upper] > 0):
            raise ValueError("Missing bar edge in declared search band")
        bounds.append(int(np.argmax(edges[lower:upper])) + lower + 1)
    if bounds[1] <= bounds[0]:
        raise ValueError("Bar edge bands are reversed")
    return {"top": bounds[0], "bottom_exclusive": bounds[1], "height": bounds[1] - bounds[0]}


def self_test():
    blank = np.zeros((40, 80, 3), dtype=np.uint8)
    original = blank.copy()
    original[12:15, 30:34] = 180
    original[14:18, 32:34] = 255
    rectangle = (27, 10, 10, 10)
    moved = blank.copy()
    moved[17:20, 7:11] = 180
    moved[19:23, 9:11] = 255
    stable = locate(original, original, rectangle, 6, None)
    shifted = locate(original, moved, rectangle, 6, (0, 0, 80, 40))
    missing = locate(original, blank, rectangle, 6, None)
    empty_rejected = False
    try:
        locate(blank, blank, rectangle, 6, None)
    except ValueError:
        empty_rejected = True
    bar = np.zeros((90, 80, 3), dtype=np.uint8)
    bar[30:62] = 25
    taller_bar = np.zeros_like(bar)
    taller_bar[24:62] = 25
    missing_edge_rejected = False
    try:
        bar_bounds(bar, (10, 70), (0, 5), (55, 70))
    except ValueError:
        missing_edge_rejected = True
    checks = [stable["dx"] == stable["dy"] == 0,
              shifted["dx"] == -23 and shifted["dy"] == 5,
              shifted["correlation"] == 1.0,
              missing["correlation"] == 0.0, empty_rejected,
              bar_bounds(bar, (10, 70), (20, 40), (55, 70)) == {
                  "top": 30, "bottom_exclusive": 62, "height": 32},
              bar_bounds(taller_bar, (10, 70), (20, 40), (55, 70))["height"] == 38,
              missing_edge_rejected]
    for index, passed in enumerate(checks, 1):
        print(f"{'PASS' if passed else 'FAIL'} geometry sensitivity {index}")
    print(f"{sum(checks)} passed, {len(checks) - sum(checks)} failed; synthetic arithmetic only")
    return int(not all(checks))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path)
    parser.add_argument("--frame", action="append", default=[], type=Path)
    parser.add_argument("--icon", action="append", default=[], help="name:x,y,width,height; all nine required")
    parser.add_argument("--radius", type=int, default=6)
    parser.add_argument("--search", help="x,y,width,height full search for --broad-icons")
    parser.add_argument("--broad-icons", default="editor_menu,folder,copy")
    parser.add_argument("--bar-x-span", help="left,right-excluded; background median across this span")
    parser.add_argument("--top-band", help="lower,upper-excluded original y edge search")
    parser.add_argument("--bottom-band", help="lower,upper-excluded original y edge search")
    parser.add_argument("--calibration-eight", action="store_true", help="Historical bad control only: lacks pull_request")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    try:
        if (not args.baseline or not args.frame or args.radius < 0
                or not args.bar_x_span or not args.top_band or not args.bottom_band):
            raise ValueError("Need baseline, distinct frame(s), nonnegative radius and all bar search bands")
        icons = {}
        for value in args.icon:
            name, rectangle = value.split(":", 1)
            if name in icons:
                raise ValueError("Duplicate glyph name")
            icons[name] = numbers(rectangle, 4)
        expected = ICONS - {"pull_request"} if args.calibration_eight else ICONS
        if set(icons) != expected:
            raise ValueError("Supply the complete declared glyph set")
        baseline_path = args.baseline.resolve(strict=True)
        paths = [path.resolve(strict=True) for path in args.frame]
        if len(set([baseline_path] + paths)) != len(paths) + 1:
            raise ValueError("Duplicate PNG paths cannot establish state comparison")
        with Image.open(baseline_path) as image:
            baseline = np.array(image.convert("RGB"))
        x_span = numbers(args.bar_x_span, 2)
        top_band, bottom_band = numbers(args.top_band, 2), numbers(args.bottom_band, 2)
        reference_bar = bar_bounds(baseline, x_span, top_band, bottom_band)
        search = numbers(args.search, 4) if args.search else None
        broad = set(args.broad_icons.split(","))
        if not broad <= ICONS:
            raise ValueError("Unknown broad-search glyph")
        reports, moved, uncertain = [], False, False
        for path in paths:
            with Image.open(path) as image:
                pixels = np.array(image.convert("RGB"))
            if pixels.shape != baseline.shape:
                raise ValueError("Capture dimensions changed; re-register before measuring")
            glyphs = {name: locate(baseline, pixels, rect, args.radius, search if name in broad else None)
                      for name, rect in icons.items()}
            current_bar = bar_bounds(pixels, x_span, top_band, bottom_band)
            uncertain |= any(value["correlation"] < 0.995 for value in glyphs.values())
            moved |= current_bar != reference_bar or any(
                (value["dx"] != 0 or value["dy"] != 0) and value["correlation"] >= 0.995
                for value in glyphs.values())
            reports.append({"frame": str(path), "bar": current_bar, "glyphs": glyphs})
        verdict = "FAIL" if moved else "UNKNOWN" if uncertain else "PASS"
        print(json.dumps({"baseline": str(baseline_path), "dimensions": [baseline.shape[1], baseline.shape[0]],
                          "reference_bar": reference_bar, "correlation_minimum": 0.995,
                          "calibration_only": args.calibration_eight, "frames": reports,
                          "geometry_result": verdict, "visible_text_ellipsis_warning_result": "UNKNOWN: inspect originals"}, indent=2))
        return 1 if moved else 2 if uncertain else 0
    except (ValueError, TypeError, OSError) as error:
        print(f"UNKNOWN: {error}")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
