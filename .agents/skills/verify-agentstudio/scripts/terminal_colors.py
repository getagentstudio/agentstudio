#!/usr/bin/env python3
"""Count solid colour swatches in an original PID-targeted terminal capture (J11).

The J11 fixtures paint 240 distinct 256-colour swatches and 64-step 24-bit
red, green and blue ramps as cell backgrounds. A renderer that drops or
quantises them paints far fewer distinct solid colours, so the counts decide
the colour cells; text, layout and the TUI still need the opened original.
Colour management may shift values, but it keeps distinct inputs distinct.
No app, process or image file is modified.

Run: uv run --offline --with pillow --with numpy python -I terminal_colors.py \
  {palette256|truecolor} ORIGINAL.png   |   --self-test
"""
import argparse
import json
import sys
import typing as t

import numpy as np
import numpy.typing as npt
from PIL import Image

PixelFrame = npt.NDArray[np.uint8]
ColourMode = t.Literal["palette256", "truecolor"]
MINIMUM_SWATCH_PIXELS = 120
PALETTE256_MINIMUM_SOLID = 180
TRUECOLOR_MINIMUM_PER_CHANNEL = 40


def solid_colours(frame: PixelFrame, minimum_pixels: int) -> npt.NDArray[np.int64]:
    """Return (r, g, b) rows of colours covering at least minimum_pixels."""
    packed = (
        frame[..., 0].astype(np.int64) << 16
        | frame[..., 1].astype(np.int64) << 8
        | frame[..., 2].astype(np.int64)
    ).ravel()
    values, counts = np.unique(packed, return_counts=True)
    kept = values[counts >= minimum_pixels]
    return np.stack([(kept >> 16) & 255, (kept >> 8) & 255, kept & 255], axis=1)


def dominant_counts(colours: npt.NDArray[np.int64]) -> dict[str, int]:
    """Count solid colours whose strictly largest channel is red, green or blue."""
    result: dict[str, int] = {}
    for index, name in enumerate(("red", "green", "blue")):
        others = np.delete(colours, index, axis=1)
        result[name] = int(np.sum(colours[:, index] > others.max(axis=1)))
    return result


def judge(frame: PixelFrame, mode: ColourMode) -> dict[str, object]:
    colours = solid_colours(frame, MINIMUM_SWATCH_PIXELS)
    dominant = dominant_counts(colours)
    if mode == "palette256":
        passed = len(colours) >= PALETTE256_MINIMUM_SOLID
        rule = f"solid colours >= {PALETTE256_MINIMUM_SOLID} of the 240 painted swatches"
    else:
        passed = min(dominant.values()) >= TRUECOLOR_MINIMUM_PER_CHANNEL
        rule = f"each channel ramp keeps >= {TRUECOLOR_MINIMUM_PER_CHANNEL} of 64 distinct steps"
    return {
        "mode": mode,
        "solidColours": len(colours),
        "dominantSolidColours": dominant,
        "minimumSwatchPixels": MINIMUM_SWATCH_PIXELS,
        "rule": rule,
        "colourCell": "PASS" if passed else "FAIL",
    }


def swatch_frame(colours: list[tuple[int, int, int]], cell: int = 12) -> PixelFrame:
    frame = np.zeros((cell * 2, cell * len(colours) + cell, 3), dtype=np.uint8)
    frame[:] = (24, 24, 28)
    for index, colour in enumerate(colours):
        frame[:, index * cell : (index + 1) * cell] = colour
    return frame


def self_test() -> int:
    levels = (0, 95, 135, 175, 215, 255)
    cube = [(r, g, b) for r in levels for g in levels for b in levels]
    grays = [(8 + 10 * step,) * 3 for step in range(24)]
    ramp = [step * 4 + 3 for step in range(64)]
    truecolor = [(v, 0, 0) for v in ramp] + [(0, v, 0) for v in ramp] + [(0, 0, v) for v in ramp]
    quantised = [min(levels, key=lambda level: abs(level - v)) for v in ramp]
    banded = [(v, 0, 0) for v in quantised] + [(0, v, 0) for v in quantised] + [(0, 0, v) for v in quantised]
    sixteen = cube[:: len(cube) // 16][:16]
    cases = [
        (judge(swatch_frame(cube + grays), "palette256")["colourCell"] == "PASS", "256 swatches pass"),
        (judge(swatch_frame(sixteen * 15), "palette256")["colourCell"] == "FAIL", "16-colour fallback fails"),
        (judge(swatch_frame(truecolor), "truecolor")["colourCell"] == "PASS", "24-bit ramps pass"),
        (judge(swatch_frame(banded), "truecolor")["colourCell"] == "FAIL", "256-quantised ramps fail"),
        (judge(swatch_frame([(200, 0, 0)]), "truecolor")["colourCell"] == "FAIL", "one swatch fails"),
    ]
    failed = [name for ok, name in cases if not ok]
    print(f"{len(cases) - len(failed)} passed, {len(failed)} failed; synthetic frames only")
    for name in failed:
        print(f"FAILED: {name}", file=sys.stderr)
    return 1 if failed else 0


def main() -> int:
    if sys.argv[1:] == ["--self-test"]:
        return self_test()
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("mode", choices=("palette256", "truecolor"))
    parser.add_argument("image")
    arguments = parser.parse_args()
    with Image.open(arguments.image) as image:
        frame = np.asarray(image.convert("RGB"), dtype=np.uint8)
    print(json.dumps(judge(frame, t.cast(ColourMode, arguments.mode)), sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
