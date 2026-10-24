# Taste pass — every original, every supported width

For **J2, J4, J5, J6 and J7**, functional correctness and visual quality are
separate observations. The owner's directions are the oracle: readable content,
aligned siblings, deliberate use of space, and the same card shape in every pane.
For cards, use `pane-contract.md` and J5. A new frame needs a judgment;
a previous tasteful build or an Implementer's description cannot supply it.

This recipe grants no app operation, resizing, preference change or capture.
The live commission must name the operator, capture owner and permitted route.

## Capture the width/state matrix

1. Before driving, list **every state** in the selected journey and the supported
   widths for each surface. Cards require **420, 520, 640, 780 and 1000 pt** at
   every state. Record the actual card width, not terminal columns or full-window
   width: measure original card-frame pixels divided by capture scale; each
   required width allows **±2pt**, so 518–522pt fills the 520pt cell. Retain the
   measured value. An off-target layout attempt is a **calibration frame**: keep
   it labelled with its measured width; further layout attempts are allowed.
   Only a frame within ±2pt fills the cell. Use the layout route in
   `pane-proof-setup.md` before driving.
   Rows and toolbars need the declared supported narrow/typical/wide
   widths and layout variants; obtain their bounds from the target's source or
   live size receipt. If a required width cannot be reached, keep that cell
   UNKNOWN with its reason; do not quietly omit it or substitute a simulated image.
2. Hold content, pane identity, font/scale and sibling fixtures stable when
   comparing widths. Capture different-width panes side by side to judge shared
   alignment. Headless split/equalize gives equal widths, with no ratio verb.
   Different-width siblings need a separately granted native divider drag on an
   already unlocked screen; without it, Sibling spacing and Same shape stay
   UNKNOWN. Sequential single-pane frames normalized to each card's origin
   still judge local alignment. Cover every card state including no-message,
   long-message, warning, note, verified session and no-repo cases. A capture may
   cover several cells only when all required surfaces are actually visible.
   Repeat obscured ones.
3. Preserve each full original PNG with commit/binary, PID/start/window, pane,
   state/setup, actual surface width in points, PNG dimensions, scale, and capture
   UTC/monotonic bounds and capture owner/method. App renders also retain
   response metadata, original `image.path`, moved evidence path, owner facts
   and before/after lock probes. Use shared setup's 3 s consumer settle and one
   render after each state change, including while locked. Crops keep original
   pixel origins and point conversions: surface point coordinates × image.scale.
   `surfaces[]` locates the region; measure its actual ink/edges in the PNG.
   Resized images cannot establish a width or hide a clipped edge.
4. For a J2 burst, judge taste on frame 0 and frames at the glyph's extremes,
   including clipping/overlap there. Inspect the others and record "same as
   frame 0 outside the glyph region" within the declared surface only when true;
   any other change needs
   its own judgment. Retain all original paths. J4 compares fixed controls only
   between equal-width states; use a separate geometry matrix for each width.
   J5's continuously open minute observation needs its own valid time bounds at
   each width. Resize/setup **before** that timed pair; do not reopen or resize
   between its fresh and aged frames. One width's clock proof covers only it.

App renders draw the live AppKit content hierarchy, including any animation in
flight. They support static layout/text/taste judgments but omit native tab bar,
titlebar, shadow, background vibrancy, outside-subtree tooltip/popover/menu and
pasteboard payloads. Exact Metal terminal/WKWebView pixels are unverified and may
be blank/stale. A stale/in-flight frame after the settle fails that observation;
no longer wait or retry. J2 motion and final native appearance still require an
already unlocked, separately granted Peekaboo route. No run unlocks the screen.
Match asynchronous SESSION/status fields with the same pane's owner facts taken
immediately before capture; metadata or expected producer values are not ink.

## Judge each frame

Open every original personally at readable scale. Use a table with one row per
judged original, explicit axis judgments with concrete
observations, and its functional/taste verdicts:

| State/setup | Surface width pt / scale | Original PNG path | Clipping/truncation | Alignment | Overlap | Duplication | Reserved blank space | Sibling spacing | Same shape | Other | Functional | Taste |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| actual held state | measured width | absolute original path | judgment + evidence | judgment + evidence | judgment + evidence | judgment + evidence | judgment + evidence | judgment + evidence | judgment + sibling comparison | defect or none | PASS/FAIL/UNKNOWN | PASS/FAIL/UNKNOWN |

- **Clipping or truncation:** can the user read the required title, status,
  message, warning, caption, ID and age? Normal card names must fit at 420pt and
  above. SESSION and PANE IDs may middle-truncate wherever the full ID does not
  fit, under J5's checks for readable prefix and suffix, full tooltip and
  always-visible inline copy icon. Adopted limits remain allowed: two-line
  title/message with tail ellipsis for oversized text, middle-truncated oversized
  field values with the full tooltip, and J4's truncatable message with a
  **complete separate age**.
  Cite that boundary rather than excusing clipped ordinary content. Tooltips/AX
  full text do not prove the pixels painted or make a hidden age acceptable.
- **Alignment:** compare local leading/trailing edges and baselines across panes
  and sibling rows. Cards have one fixed caption column sized for WORKTREE,
  even in cards without that field; values share its edge. Normalize positions
  to each card's origin before comparing. Sidebars/toolbars use their own shared
  edges; do not invent caption columns for those surfaces.
- **Overlap:** text, chips, icons, copy buttons, boundaries and neighboring panes
  have distinct space. Check the longest message/branch/ID and narrowest width.
- **Duplicated information or icons:** look for repeated repo/worktree/CWD
  values, second status dots, repeated age or detached icons. Apply the adopted
  suppression rules; the owner's title text and the deliberately retained git
  chip on another surface are not automatically duplicates to remove.
- **Reserved blank space:** short title/message consumes its natural one-line
  height, not a permanently reserved second line. Missing fields leave no empty
  rows or abandoned columns. Judge wide cards as well as narrow ones.
- **Spacing between siblings:** compare field-row gaps, icon/caption/value gaps,
  paragraph spacing and copy-button gaps across panes and widths. Copy follows
  its value inline; it is not pushed to a different trailing edge in each pane.
- **Same shape:** compare side-by-side cards in the same content state: same
  populated lines, same order, same arrangement and normalized edges at every
  width. Conditional omissions follow J5; a wide card may not become an HStack
  or use a different field layout from its narrow sibling.
- **Other:** record any additional visible defect that makes the frame look
  sloppy, with the concrete observation, rather than passing a checklist that
  missed it. Record none when no such defect is visible.

Record PASS/FAIL/UNKNOWN for each axis, with coordinates/gaps or a specific
readability observation. A bare "looks good" is insufficient; bursts use the
frame-0/extreme rule above. For a defect, keep an annotated copy alongside
the untouched original; annotations never replace the evidence.

## Return the quality result

Derive **Taste = FAIL** if any axis fails, including Same shape or Other;
**UNKNOWN** if no axis fails and any is UNKNOWN; **PASS** only when all pass.

List **every original frame path** in the handback, grouped by journey/state and
width, so the Lead can open all of them. Include missing cells and their reason,
the per-frame table, measurements/crops and functional results separately.

Any observed functional failure **or** failed taste row makes that observation
**FAIL for acceptance**, even when all automated functional checks pass.
Uncaptured/unread frames or missing width/axis judgments remain UNKNOWN; do not
turn them into PASS. Only complete functional and taste PASS across the required
matrix supports a pass recommendation. The Lead still owns acceptance. Do not
repair product code or rearrange the oracle. The no-retake rule covers product
verdicts: a frame showing a defect is never replaced or hidden, even when it is
also an off-target calibration frame.
