# J4 — one toolbar line, chips or Agent Line

Oracle: specification r5 O2–O4/O7/O8/O13/O20, owner R1/R3–R8/R10,
and `pane-contract.md`. Historical targets require their declared historical oracle.
Load shared setup, scenario recipes and visual quality before driving.

Production path: pane-origin CLI/IPC → `PaneContextService`/SQLite → publication
→ off-main toolbar shaping → `PaneSurfaceToolbarHost`. Require actual child CLI
completion and current owner counts/line; `terminal.send` only accepts input.

## Hold and observe

Use one owned pane and fixed window/split/scale per comparison. One operator
holds each state until its original PNG is inspected.

| State | Setup | Deciding observation |
| --- | --- | --- |
| Empty | Fresh pane or successful clear; no unread/open ask or E4 | No context item/trailing item divider. Record natural height and fixed controls. |
| Agent Line | No unread; successful pane-origin line write | Pencil → item divider → fixed neutral message icon, clamped text, one space and complete [Now], on one line. No status. |
| Chips | S5 info-only then S6–S8 all four kinds, E4 still stored | All nonzero failure/needs-you/done/info chips, in order. No line painted while unread > 0. Each chip opens Messages. |
| Return | Actual dismiss/settle reaches zero unread; E4 retained | Chips disappear, stored line returns without rewriting. Clear E4; item/divider disappear. |
| Long line | 200 UTF-8 bytes, wide glyphs, no unread | Text truncates before complete bracketed age; no overlap or second row. |
| E7 only | Verified prompt, no E4/E5 | Empty toolbar. E7 is not an unread count or toolbar status. |
| Refusal | J6 retained failure plus line/no unread | Positive warning in card only; none in toolbar. |

Keep the no-message comparator; include main/drawer-alone scope. Scenario
recipes supply real line/notice/ask entries. A callback is not an opened popover.

## Geometry and actual text

Use `window-frame.sh resize/render` for V2's 1400/520/390 **window** matrix;
retain actual applied and measured toolbar widths. A clamped request does not
fill its requested-width cell. Use a separate same-width state matrix for
`toolbar_geometry.py`. Preserve fixed controls/git chip; measure drawer, add,
pin, pencil, PR, editor, folder, copy and zoom where available. Missing fixture
controls are UNKNOWN. A chooser chevron is not a PR control.

Record original pixels/point scale. The geometry helper takes nine templates
and bar-edge bands: require dx=0/dy=0 and unchanged bar height. Low correlation,
reused coordinates, changed dimensions or ambiguous edges are UNKNOWN. Keep
its known-bad calibration and threshold. Fixed glyphs do not prove text painted.

Retain the historical eight-control sensitivity comparator separately from the
current nine-control fixture: no-agent versus Working/refusal displaced editor/
folder about 1053px left, copy 1054px left and controls 5px down. It lacked PR.
Keep its independent pixel-region measurement for low-confidence horizontal
candidates; never lower 0.995 correlation to certify them. The synthetic shifted
cases in `toolbar_geometry.py --self-test` are additional matcher sensitivity,
not a substitute native displacement observation.

Read text/age in the untouched PNG. Measure the **text** clamp (360pt in Program
Design) separately from icon + text + age; the old whole-run cap is superseded.
Short fitting text needs no ellipsis. O20 permits hiding the whole Agent Line
when its gap is insufficient; record the hide and available gap. A clipped age,
partial chip or second line is not allowed. The item divider is **after pencil**
and before the item; a pre-pencil group divider cannot satisfy R6.

## Clock and return

Use J5's successful-write t0 and continuously-open pair: [Now] below 60s,
[1 min ago] within [60,120)s, S4 [2 min ago] within [120,180)s. The entire capture
interval must lie inside its bucket. No hook/input/rewrite/reopen between frames.
Keep E4 updatedAt separate from E6; use the offline fixture for older ages.

Return facts, actual widths, original paths, glyph geometry, independent text/
age/clamp/divider/no-status/XOR verdicts, and R1–R10 plus functional/taste checks.
Self-tests exercise drivers only, never the app.
