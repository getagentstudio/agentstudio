#!/usr/bin/env python3
"""Localise changes in a declared row of original PID-targeted captures.

A moving-region result is pixel evidence, not a semantic animation verdict.
No app, process, credential, preference, image file or frame is modified.
"""
import argparse
import json
import re
import sys
import typing as t
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import numpy.typing as npt
from PIL import Image

PixelFrame = npt.NDArray[np.uint8]
PixelMask = npt.NDArray[np.bool_]
LabelGate = t.Literal["label-stable", "repaint-spanned", "UNKNOWN"]
RegionCheck = (
    tuple[t.Literal["checked"], bool]
    | tuple[t.Literal["repaint-spanned", "UNKNOWN"], None]
)


@dataclass(frozen=True)
class PixelRegion:
    name: str
    left: int
    top: int
    width: int
    height: int

    @property
    def right(self) -> int:
        return self.left + self.width

    @property
    def bottom(self) -> int:
        return self.top + self.height

    def contains(self, other: "PixelRegion") -> bool:
        return (
            self.left <= other.left
            and self.top <= other.top
            and self.right >= other.right
            and self.bottom >= other.bottom
        )


def parse_rectangle(value: str, name: str) -> PixelRegion:
    coordinates = tuple(int(part) for part in value.split(","))
    if len(coordinates) != 4:
        raise ValueError("A rectangle is x,y,width,height")
    left, top, width, height = coordinates
    if min(left, top) < 0 or min(width, height) <= 0:
        raise ValueError("Rectangle needs nonnegative origin and positive dimensions")
    return PixelRegion(name, left, top, width, height)


def region_slices(region: PixelRegion, scope: PixelRegion) -> tuple[slice, slice]:
    if not scope.contains(region):
        raise ValueError(f"Region {region.name!r} is outside the declared row scope")
    return (
        slice(region.top - scope.top, region.bottom - scope.top),
        slice(region.left - scope.left, region.right - scope.left),
    )


def changed_pixel_mask(first: PixelFrame, second: PixelFrame, threshold: int) -> PixelMask:
    if first.shape != second.shape or first.ndim != 3 or first.shape[2] != 3:
        raise ValueError("Frames must have identical RGB shapes")
    difference = np.abs(first.astype(np.int16) - second.astype(np.int16))
    return np.any(difference > threshold, axis=2)


def mask_bounds(mask: PixelMask, scope: PixelRegion) -> list[int] | None:
    vertical, horizontal = np.nonzero(mask)
    if horizontal.size == 0:
        return None
    return [
        int(horizontal.min()) + scope.left,
        int(vertical.min()) + scope.top,
        int(horizontal.max()) + scope.left + 1,
        int(vertical.max()) + scope.top + 1,
    ]


def expectation_holds(changed_pixels: int, expected: str) -> bool:
    match expected:
        case "moving":
            return changed_pixels > 0
        case "still":
            return changed_pixels == 0
        case _:
            raise ValueError("Expectation must be moving or still")


def classify_label_stability(
    before: str, after: str, prior_repaint_spanned: int
) -> tuple[LabelGate, int]:
    """Apply the Lead's 2026-10-17 monotonic recency-label rule verbatim."""
    if not before.strip() or not after.strip():
        raise ValueError("Read nonempty chip labels from both AX snapshots")
    if not 0 <= prior_repaint_spanned <= 2:
        raise ValueError("Stop after three consecutive repaint-spanned bursts")
    if before == after:
        return "label-stable", 0
    consecutive = prior_repaint_spanned + 1
    if consecutive == 3:
        return "UNKNOWN", 3
    return "repaint-spanned", consecutive


def evaluate_region_expectation(
    changed_pixels: int, expected: str, region_name: str, label_gate: LabelGate
) -> RegionCheck:
    if region_name in {"chip", "text"} and expected == "still":
        match label_gate:
            case "repaint-spanned":
                return "repaint-spanned", None
            case "UNKNOWN":
                return "UNKNOWN", None
            case "label-stable":
                pass
    return "checked", expectation_holds(changed_pixels, expected)


def combine_region_checks(
    checks: list[bool | None], unassigned_changed_pixels: int
) -> tuple[bool | None, int]:
    if not checks:
        raise ValueError("No region checks were made")
    if unassigned_changed_pixels != 0 or any(check is False for check in checks):
        return False, 1
    if any(check is None for check in checks):
        return None, 2
    return True, 0


def load_scoped_frame(
    path: Path, scope: PixelRegion, expected_size: tuple[int, int] | None
) -> tuple[PixelFrame, tuple[int, int]]:
    with Image.open(path) as screenshot:
        dimensions = screenshot.size
        if expected_size is not None and dimensions != expected_size:
            raise ValueError("Capture dimensions changed; frame registration is invalid")
        if scope.right > dimensions[0] or scope.bottom > dimensions[1]:
            raise ValueError("Row scope is outside the original capture")
        row_image = screenshot.convert("RGB").crop(
            (scope.left, scope.top, scope.right, scope.bottom)
        )
        return np.array(row_image, dtype=np.uint8), dimensions


def self_test() -> int:
    # Known input pixels are an independent arithmetic oracle. These controls
    # catch a probe that always returns no movement, wrong uint8 subtraction,
    # misplaced original-coordinate bounds, and a vacuous still/moving verdict.
    black: PixelFrame = np.zeros((4, 5, 3), dtype=np.uint8)
    white_point = black.copy()
    white_point[2, 3, 0] = 255
    scope = PixelRegion("row", 100, 200, 5, 4)
    still_mask = changed_pixel_mask(black, black, 0)
    moving_mask = changed_pixel_mask(black, white_point, 0)
    stable_gate, stable_count = classify_label_stability("Now", "Now", 0)
    repaint_gate, repaint_count = classify_label_stability("Now", "1m", 0)
    unknown_gate, unknown_count = classify_label_stability("2m", "3m", 2)
    reset_gate, reset_count = classify_label_stability("3m", "3m", 2)
    missing_label_rejected = False
    try:
        classify_label_stability("", "Now", 0)
    except ValueError:
        missing_label_rejected = True
    checks: list[tuple[str, bool]] = [
        ("identical frames stay still", int(still_mask.sum()) == 0),
        ("one changed channel is one changed pixel", int(moving_mask.sum()) == 1),
        ("original-coordinate bounds", mask_bounds(moving_mask, scope) == [103, 202, 104, 203]),
        ("stationary probe cannot pass moving expectation", not expectation_holds(0, "moving")),
        ("changed probe cannot pass still expectation", not expectation_holds(1, "still")),
        ("real change can pass moving expectation", expectation_holds(1, "moving")),
        ("reverse subtraction does not wrap", int(changed_pixel_mask(white_point, black, 254).sum()) == 1),
        ("stable label checks whole-chip stillness", evaluate_region_expectation(0, "still", "chip", stable_gate) == ("checked", True) and stable_count == 0),
        ("stable label catches a one-pixel chip change", evaluate_region_expectation(1, "still", "chip", stable_gate) == ("checked", False)),
        ("changed label defers chip without pass or fail", evaluate_region_expectation(1, "still", "chip", repaint_gate) == ("repaint-spanned", None) and repaint_count == 1 and combine_region_checks([True, None], 0) == (None, 2)),
        ("third consecutive repaint is UNKNOWN", evaluate_region_expectation(1, "still", "chip", unknown_gate) == ("UNKNOWN", None) and unknown_count == 3),
        ("stable label resets the repaint streak", reset_gate == "label-stable" and reset_count == 0),
        ("text stillness uses the same label gate", evaluate_region_expectation(1, "still", "text", stable_gate) == ("checked", False) and evaluate_region_expectation(1, "still", "text", repaint_gate) == ("repaint-spanned", None)),
        ("glyph failure survives a chip repaint", evaluate_region_expectation(0, "moving", "glyph", repaint_gate) == ("checked", False) and combine_region_checks([False, None], 0) == (False, 1)),
        ("missing AX label cannot pass as stable", missing_label_rejected),
    ]
    for name, passed in checks:
        print(f"{'PASS' if passed else 'FAIL'} {name}")
    failed_count = sum(not passed for _, passed in checks)
    print(f"{len(checks) - failed_count} passed, {failed_count} failed; synthetic sensitivity only")
    return int(failed_count != 0)


def build_argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("frames", nargs="*", type=Path, help="Original PNGs in capture order")
    parser.add_argument("--scope", help="Row scope x,y,width,height in original PNG pixels")
    parser.add_argument("--region", action="append", default=[], help="name:x,y,width,height")
    parser.add_argument("--expect", action="append", default=[], help="name=moving or name=still")
    parser.add_argument("--threshold", type=int, default=0, help="Declare channel delta threshold before evaluation (default exact)")
    parser.add_argument("--chip-label-before", help="Exact chip label read from this burst's before AX snapshot")
    parser.add_argument("--chip-label-after", help="Exact chip label read from this burst's after AX snapshot")
    parser.add_argument("--prior-repaint-spanned", type=int, choices=range(3), default=0, help="Consecutive repaint-spanned bursts immediately before this one (0, 1 or 2)")
    parser.add_argument("--self-test", action="store_true", help="In-memory pixel and AX-label-gate controls; no filesystem or app effects")
    parser.add_argument("--oracle-commit", help="Full design-oracle commit from the run declaration, separate from the build")
    return parser


def main() -> int:
    parser = build_argument_parser()
    arguments = parser.parse_args()
    if arguments.self_test:
        return self_test()
    try:
        if not arguments.oracle_commit or not re.fullmatch(r"[a-fA-F0-9]{40}", arguments.oracle_commit):
            raise ValueError("Need --oracle-commit with the full declared design commit")
        if arguments.scope is None or len(arguments.frames) < 2:
            raise ValueError("Need a declared --scope and at least two original captures")
        if not 0 <= arguments.threshold <= 254:
            raise ValueError("Threshold must be between 0 and 254")
        if arguments.chip_label_before is None or arguments.chip_label_after is None:
            raise ValueError("Supply the exact chip label from both saved AX snapshots")
        label_gate, repaint_streak = classify_label_stability(
            arguments.chip_label_before, arguments.chip_label_after,
            arguments.prior_repaint_spanned,
        )
        frame_paths: list[Path] = [path.resolve(strict=True) for path in arguments.frames]
        if len(set(frame_paths)) != len(frame_paths):
            raise ValueError("Duplicate capture paths cannot establish a frame burst")
        scope = parse_rectangle(arguments.scope, "row")
        regions: list[PixelRegion] = []
        for region_argument in arguments.region:
            name, rectangle = region_argument.split(":", 1)
            if not name or any(region.name == name for region in regions):
                raise ValueError("Every region needs a unique nonempty name")
            regions.append(parse_rectangle(rectangle, name))
        expectations: dict[str, str] = {}
        for expectation_argument in arguments.expect:
            name, expected = expectation_argument.split("=", 1)
            if name in expectations or expected not in {"still", "moving"}:
                raise ValueError("Expectations need unique names and moving/still values")
            expectations[name] = expected
        if not regions or set(expectations) != {region.name for region in regions}:
            raise ValueError("Declare an expectation for every region, and no unknown region")
        if "chip" in expectations and expectations["chip"] != "still":
            raise ValueError("J2's no-pulse oracle requires chip=still")
        if any(expectations.get(name) == "still" for name in ("chip", "text")) and arguments.threshold != 0:
            raise ValueError("Label-stable chip/text checks require exact zero changed pixels")
        covered: PixelMask = np.zeros((scope.height, scope.width), dtype=np.bool_)
        for region in regions:
            region_area = region_slices(region, scope)
            if np.any(covered[region_area]):
                raise ValueError("Named regions overlap; localisation would be ambiguous")
            covered[region_area] = True
        union_mask: PixelMask = np.zeros_like(covered)
        pair_reports: list[dict[str, object]] = []
        previous_frame: PixelFrame | None = None
        frame_size: tuple[int, int] | None = None
        for index, frame_path in enumerate(frame_paths):
            current_frame, frame_size = load_scoped_frame(frame_path, scope, frame_size)
            if previous_frame is not None:
                pair_mask = changed_pixel_mask(previous_frame, current_frame, arguments.threshold)
                union_mask |= pair_mask
                pair_reports.append({
                    "from": str(frame_paths[index - 1]),
                    "to": str(frame_path),
                    "changed_pixels": int(pair_mask.sum()),
                    "bounds_xyxy_exclusive": mask_bounds(pair_mask, scope),
                })
            previous_frame = current_frame
        region_reports: list[dict[str, object]] = []
        region_checks: list[bool | None] = []
        for region in regions:
            count = int(union_mask[region_slices(region, scope)].sum())
            measurement, passed = evaluate_region_expectation(
                count, expectations[region.name], region.name, label_gate
            )
            region_checks.append(passed)
            region_reports.append({
                "name": region.name,
                "rect_xywh": [region.left, region.top, region.width, region.height],
                "changed_pixels": count,
                "expected": expectations[region.name],
                "measurement": measurement,
                "pixel_expectation_met": passed,
            })
        unassigned_change = union_mask & ~covered
        unassigned_count = int(unassigned_change.sum())
        pixel_checks_met, result_status = combine_region_checks(region_checks, unassigned_count)
        report: dict[str, object] = {
            "kind": "pixel_observation_only",
            "frames": [str(path) for path in frame_paths],
            "frame_count": len(frame_paths),
            "capture_size": frame_size,
            "scope_xywh": [scope.left, scope.top, scope.width, scope.height],
            "channel_delta_threshold": arguments.threshold,
            "oracle_commit": arguments.oracle_commit,
            "chip_label_before": arguments.chip_label_before,
            "chip_label_after": arguments.chip_label_after,
            "chip_label_gate": label_gate,
            "consecutive_repaint_spanned": repaint_streak,
            "chip_repaint_action": (
                "stop: chip UNKNOWN after three consecutive repaint-spanned bursts"
                if label_gate == "UNKNOWN" else
                "record chip=repaint-spanned; capture a fresh burst; retain glyph judgment"
                if label_gate == "repaint-spanned" else
                "check whole-chip and text pixels exactly; glyph judgment remains independent"
            ),
            "pair_observations": pair_reports,
            "region_observations": region_reports,
            "unassigned_changed_pixels": unassigned_count,
            "unassigned_bounds_xyxy_exclusive": mask_bounds(unassigned_change, scope),
            "pixel_checks_met": pixel_checks_met,
            "semantic_animation_verdict": "unknown; inspect original sequence, scenario/AX, sampling and Reduce Motion",
        }
        print(json.dumps(report, indent=2))
        return result_status
    except (ValueError, OSError) as error:
        print(f"INCONCLUSIVE: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
