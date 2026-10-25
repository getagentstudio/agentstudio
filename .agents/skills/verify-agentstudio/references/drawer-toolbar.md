# J4 — one toolbar line, chips or Agent Line

Oracle: specification r5 O2–O4/O7/O8/O13/O20, owner R1/R3–R8/R10,
and `pane-contract.md`. For this pane-context delivery the Lead's
`tmp/design-workflows/2026-10-25-pane-context-display/plan-amendment-2.md` supplies
the **provisional constrained-width policy**, pending owner review in the PR.
Record that applicability with the target; it does not rewrite the fixed spec or
claim owner approval. Historical targets require their declared historical oracle.
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
| Chips | S5 info-only then S6–S8 all four kinds, E4 still stored | One complete failure/needs-you/done/info chip item in order, or the whole item hidden under the constrained policy below. No line replaces unread chips. Every drawn chip opens Messages. |
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
`toolbar_geometry.py`. Preserve every action button's presence, size, order and
hit area; the passive Git readout alone may yield under the policy below. Measure
drawer, add, pin, pencil, PR, editor, folder, copy and zoom where available.
Missing fixture controls are UNKNOWN. A chooser chevron is not a PR control.

The layout uses measured laid-out widths, not a guessed width breakpoint:

1. If the complete context item does not fit, hide the **passive Git readout**
   whole first. Its facts remain on the card. No action button yields or shrinks.
2. If the entire chip set still cannot fit, hide the **whole chip item**. No
   partial/clipped chip, wrapping or second line is permitted. The Agent Line
   keeps its existing text-clamp → whole-item-hide rule.
3. Draw the item divider after notes **only when the item draws**. When unread
   facts exist but the whole chip item is hidden, its divider is absent too.

At actual 520 and wide (≥1400) toolbars require all four chips **and** passive Git
readout, with the unchanged action group. At actual 390 record which branch is
painted: chips with Git hidden, or whole item hidden. Retain actual item, Git,
action-group and available-gap measurements showing that Git yielded before
the chip item. A requested window width alone cannot establish this ordering.
An absent item without those measurements is UNKNOWN, not a policy pass.

Record original pixels/point scale. The geometry helper takes nine templates
and bar-edge bands. Retain dx/dy and unchanged bar height, comparing like fit/Git
branches for fixed-position parity. Judge the action group by unchanged presence,
order, size and hit area under Amendment 2; authorized passive-Git absence is not
a missing action control. Check actual hit frames/native interaction separately:
glyph ink bounds alone cannot establish hit area. Low correlation, reused
coordinates, changed dimensions or ambiguous edges are UNKNOWN. Keep the known-bad
calibration and threshold. Fixed glyphs do not prove chips or text painted.

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
partial chip or second line is not allowed. Every chip's painted frame must be
fully inside the visible toolbar region or wholly absent as part of the hidden
item. The item divider is **after pencil** and before a drawn item; a pre-pencil
group divider cannot satisfy R6. Record the 390 branch for the owner's V2 review.

## Clock and return

Use J5's successful-write t0 and continuously-open pair: [Now] below 60s,
[1 min ago] within [60,120)s, S4 [2 min ago] within [120,180)s. The entire capture
interval must lie inside its bucket. No hook/input/rewrite/reopen between frames.
Keep E4 updatedAt separate from E6; use the offline fixture for older ages.

Return facts, actual widths, original paths, glyph geometry, independent text/
age/clamp/divider/no-status/XOR verdicts, and R1–R10 plus functional/taste checks.
Self-tests exercise drivers only, never the app.
