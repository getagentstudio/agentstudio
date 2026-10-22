# J4 — drawer toolbar geometry, message and age

Oracle: `pane-contract.md`, drawer/message section. The toolbar retains its
fixed controls/existing git chip and Agent Line; it gains no status or warning.
The message icon is fixed, text truncatable and age a separate complete suffix.
Choose applicability from the declared target: historical work-state glyphs
without age are not failures against an outcome that had not shipped then.

Inputs: shared setup receipt, fixed window/split sizes and scale, a declared
proof pane, real CLI/provider states and original PNGs. One operator drives and
holds each state;
the capture owner saves originals; the Verifier opens them before acknowledging.
Keep a lineless comparator where the declared matrix supplies one. A fresh
owned pane establishes the baseline without clearing a real agent's state.

## Post-#57 held states

Use the pinned full CLI path in the owned fixture shell, with its declared pane
environment. The two entries are `"$CLI" line "<message>"` and
`"$CLI" line --clear`. Actual exit-0/applied receipts are required;
`terminal.send` acceptance is not completion. Preserve a Working hook status.

| State | Real setup | Deciding visible observation |
| --- | --- | --- |
| No message | Successful clear, or fresh pane with no line. | Empty middle message/age slot; record fixed controls and natural bar height. Working stays in row/card only. |
| Fresh message | Successful short message write. | One fixed, neutral, still message icon; actual text and **just now** in one line inside the middle slot. No second status dot. |
| Same message after a minute | Same continuously visible surfaces; no further hook, line/title, focus or card-open command. | Complete **1 min ago**, with the whole per-frame age interval in [60,120)s. Message text and updatedAt do not change. Use J5's message-write t0, not hook time. |
| Long message | Maximum admitted **200 UTF-8 bytes**, using wide glyphs. | Message truncates before a **separate, complete age suffix**. Icon + message + suffix fit within 360pt and the available gap; no second row, clipped suffix, overlap or moved controls. |
| Failed protected action | J6's genuine failed notify on an unverified pane. | Toolbar still shows only icon/message/age. Warning is in the card only; the sidebar also has no warning row after #57. |

Verify bytes, not character count. Read exact text from authorized readback or
from the original pixels plus its actual write receipt. No direct model injection
stands in for the native CLI route. Native time collection requires an unlocked
GUI and the native observation grant defined in shared setup. Do not add input
to repair a missed age window.

## Historical pre-#57 matrix

Retain separate results for no agent/no line; unverified Working/refusal with no
line; the same state with a short line; and a 200-byte long line.
A warning-on-failure build requires a genuine failed action to seed the refusal;
a quiet hook does not do that. Working text does not establish a verified session.

## Measure geometry, then read the pixels

Use the shared quality width matrix. Keep a separate fixed-width geometry
matrix per width: resizing between states cannot prove zero icon displacement.

Record original dimensions and pixel-to-point scale. Keep window identity,
splits, scale and scroll position fixed throughout a comparison. Locate drawer,
add, pin, pencil, pull request, editor menu, folder, copy and zoom in the baseline.
Use a fixture containing all required controls; name any unavailable control as
UNKNOWN instead of silently reducing coverage. A chooser chevron is not a PR
control. Do not transfer template coordinates between windows or resized images.

`scripts/toolbar_geometry.py` takes raw baseline/repeated frames, nine named
x,y,width,height templates and bar-edge search bands. It subtracts background
before correlation. Return every glyph's x/y, dx/dy and correlation, plus bar
top/bottom/height. Required: **dx=0 and dy=0** for every control, unchanged bar
geometry. Missing/empty templates, low correlation, changed image dimensions or
unregistered captures are UNKNOWN, never PASS. The selected paint contour must
actually be the bar edge; shared paint alone cannot certify natural frame height.

Keep the known-bad no-agent/Working-refusal sensitivity check: editor/folder
about 1053px left, copy 1054px left and controls 5px down (owner described about 6).
That historical build lacks the PR control: its eight-glyph calibration is
separate from a nine-control current fixture. Its low-confidence horizontal
candidates need the retained independent pixel-region measurement; do not lower
0.995 correlation to certify them. Synthetic horizontal displacement also checks
the matcher. Prior good 1× captures had all offsets 0/0 and a 32px bar; re-establish
coordinates and height for the next target instead of assuming those values.

A fixed group does not prove a visible message or suffix. Personally read both
in the original; an AX label can exist while no text paints. Measure the full
icon/message/age extent against the literal 360pt limit. Treat message and suffix
as distinct regions: a suffix appended inside the same truncatable Text must
fail if it disappears. Check tail ellipsis on the message, **not on the age**.
At a separately authorized narrower width, the message must yield space before
the suffix or fixed controls. Keep that width's matrix separate.

Complete with per-state geometry and independent visibility/order/icon/age/cap/
no-warning verdicts. Exact sidebar baseline parity still needs the same repository
association/row fixture. A row-only crop cannot prove card or toolbar behavior.
Retain originals, crops and sensitivity evidence; owned cleanup stays with the
operator after all journeys using that pane finish.
