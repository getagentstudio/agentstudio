# J5 — pane card, requests, distinct clocks and exact copy

Oracle: specification r5 O1–O8/O30–O33/V3/V5, owner R1/R8–R10 and
`pane-contract.md`. Load shared setup, scenario recipes and visual quality.
Keep target/CLI provenance, owned pane, permission/evidence and current owner
facts. No target is established by the recipe itself. Use `focusPane` followed
by window-scoped `toggleManagementLayer`; confirm it opened. Close explicitly
with `managementLayerExit` under the action grant.

Production capture reads keyed facts then shapes off-main; the card's live
request controller reads the selected source/message through the real service.
A mounted snapshot or a controller's changed model does not prove the actual
card rebound. Final-build entry anchors: `PaneLeafContainer`,
`PaneManagementIdentityCapture`, `ManagementPaneIdentityStrip`,
`PaneContextPopoverController` and `PaneContextService`.

## One card, current facts

| Order | Deciding observation |
| --- | --- |
| Title | Same normalized/agent title as sidebar; leading terminal spinners absent. Preserve natural one/two-line title behavior and tooltip. |
| Status | Known verified status icon/chip only. Scoped compact prompt supplies reason/optional summary. If the request block shows that summary, the chip omits it; if an E5 ask occupies the block, the prompt summary remains on the chip. No activity/play chips. |
| Agent Line | One line: fixed neutral message icon, text clamped to existing `AppStyles.Shell.Sidebar.agentLineMaxWidth` (220pt), ellipsis before the complete adjacent bracketed age. No reserved second line or 360pt card cap (D23). |
| Request | Oldest open scoped ask: row head has full body with plain age and Dismiss beside it; answer form below. Approval reason field precedes Approve/Deny. Otherwise first scoped provider prompt, optional actual summary, terminal instruction and Go to pane. +N more only for other needs-you items, opens Messages (D25). |
| Unread | N unread · Show messages only above zero, **below the whole request block**, info included, E7 excluded. Press and inspect the actual Messages scope. |
| Existing optional content | Warning and note retain their existing conditional placement. No warning in sidebar/toolbar. |
| Metadata/git | Conditional identity rows remain, plus plain ACTIVE age when E6 known; no ACTIVE when unknown. Existing git chips stay last. |

Asks take priority over provider prompts, even when the oldest ask is outside the
first detail page or comes from a drawer. Selection tie order is the adopted
source order/position. Do not page until a convenient ask appears. Observe actual
selected message identity and exact settlement; failed refresh must remove its
actionable form. Hide/retirement cancels the controller; old returns must not
restore a form. Missing runtime failure fixture leaves failure-path observation
UNKNOWN; product tests at the existing port seam remain separate.

## Forms and settlement

Use actual service-created forms from the scenario recipes. One single-choice
press submits once; multiple choice toggles then Submit; free text then Submit;
approval optional reason field first, then Approve/Deny. Dismiss belongs beside
the dated body in the row head, never below the form; the unread summary follows
the whole request block. Elicitation shows Answer… here and
opens Messages with that exact request's inline schema. Exercise main/drawer
source and all entry locations; callback equality is supporting proof only.

For D23, retain a long-line native witness at 390/520/1400 with measured text
width ≤220pt, one painted line, ellipsis on overflowing text and the whole
bracketed age. A short fitting line needs no ellipsis. The cap constrains text,
not the full icon/text/age extent. For D25, compare S15's real native frames at
those widths with the approved render: dated body + adjacent Dismiss → optional
reason → decisions → unread summary. The shared Messages ask row uses the same
row-head Dismiss placement. Geometry/AX content alone cannot prove painted order.

For pending/confirmed/unconfirmed, mount/hold the real card and settle through
the service; await owner readback and live rebind. Every answer/dismiss control
for the settled request must be absent, not just disabled or hidden in a model.
The next oldest open ask may legitimately replace it: identify controls by source
and message, and check the correct request. A real independent prompt must keep
Needs you after answering; the UI never manufactures E3. Follow the held-receipt
recipe: confirmation requires the agent's reported cursor, not answer success.

## Conditional fields and copy, unchanged

Field order is REPO, BRANCH, WORKTREE, CWD, SESSION, PANE; ACTIVE is the added
plain-age metadata row. WORKTREE appears only when different from REPO; CWD only
when different from worktree root. SESSION retains the existing verified-live
identity rule; verified-ended may still show Idle · ended without SESSION.
PANE always appears; include no-repo fallback. One caption column sized for
WORKTREE keeps value edges aligned even when that row is absent. No width-based
HStack or abandoned blank rows. Git chips remain last.

Copy icons follow values inline at the same small gap and stay visible without
hover. Normal repo/branch fit at 420pt and wider. SESSION/PANE may middle-truncate
with readable prefix/suffix, full-ID tooltip and always-visible inline copy.
Oversized paths/branch keep adopted middle truncation. The title retains its
independent natural/two-line boundary; the Agent Line follows D23's single line,
220pt text cap and protected age. Nothing leaves the card's inner bounds.
Record pointer outside the card; if pointer or hover route is unavailable,
always-visible/tooltip remains UNKNOWN separately from measured layout.

Take `session.query`/reader evidence immediately before each capture for the same
pane; Working alone is not verified identity. Compare painted SESSION prefix/
suffix and full characters where fitting to that owner fact. Compare PANE to the
actual pane UUID. AX full values are not painted-ID evidence.

Press the actual Copy Session ID control, then read/paste its real pasteboard
payload under the interaction grant. It equals **only the raw session reference**,
no provider, caption, separator, whitespace or ellipsis. Copy Pane ID equals the
full UUID. Do not set the clipboard to expected data. No SESSION/copy control on
an unverified pane. PNG, expected copyValue and tooltip cannot substitute for
this round trip; no pasteboard route means copy UNKNOWN.

## Widths and continuously-open clocks

V2 requires measured frames at 1400/520/390 **window** widths. The retained J5
identity-layout matrix uses **actual card widths** 420/520/640/780/1000pt (±2pt).
Keep those as separate dimensions; neither requested nor outer-window width
proves card width. A frame can fill more than one cell only when both measured
conditions hold. Shared quality/setup owns applied-size/calibration handling.
Different-width side-by-side siblings require the granted native divider drag;
headless equalize cannot supply that geometry. Keep unknown cells explicit.

Use no-line, fresh line, same aged line, long line, note, real warning,
verified/unverified/ended, no-repo and long-title/branch fixtures, plus S1–S19's
request/unread states. Do layout before each timing pair. Reuse actual real-path
product tests for detailed clock boundaries where applicability is established;
self-tests and pure formatting are not that observation.

1. Open once before writing the line. Bracket the **actual successful line CLI
   subprocess** with precise UTC and monotonic times; foreground hold requires
   its matching exit-0 `hold.line` fact and live holder. This is t0, not hook time,
   `terminal.send` acknowledgement or first screenshot. The service assigns
   updatedAt inside its SQLite write. Read exact updatedAt when authorized.
2. Account for timestamp precision: whole-second end bounds extend by one
   second, and source codec microsecond rounding needs its allowance. Keep
   UTC/monotonic mapping; unknown/discontinuous mapping means timing UNKNOWN.
3. After owner completion, the capture consumer observes its documented 3s
   settle and one frame. Expect [Now] only when the **whole** computed age
   interval is below 60s. Preserve line/writer/order/updatedAt evidence.
4. With the same surfaces continuously open, no hook/input/focus/line/title/
   reopen/resize, collect one frame in [60,120)s for [1 min ago], and S4's
   same-write [120,180)s frame for [2 min ago] when commissioned. Compute
   [capture-start − latest t0, capture-end − earliest t0] for every image.
   Schedule through the consumer, not a correctness-budget test or poll.
5. Independently read row/card/toolbar ages; popover ages need J9/J10 native
   frames while open. One surface never proves another. Hook activity later
   changes E6 but cannot reset E4 updatedAt or reorder activity on E4 age alone.

Words are Now under 60s; floor minutes below 1h; floor hours below 24h; 1 day ago
then N days ago. Only Agent Line age has brackets. ACTIVE and popover message/
prompt ages are plain; sidebar activity stays compact. The owned offline copy
covers an eight-day-old line without waiting or resetting the system clock.

A boundary-spanning/missed interval is INVALID/UNKNOWN; report bounds, never
retake/rewrite/reopen to repair the attempt. A complete valid bucket with stale
words, missing suffix or cross-surface mismatch is FAIL. A later valid bucket
proves only its narrower advancement, not a missing fresh baseline. A stale or
blank app render after the declared settle fails; no longer wait/retry fixes it.

For E6-only evidence, retain canonical activity ingress t0 separately, hold the
card open, and compare plain ACTIVE plus eligible compact sidebar activity. No
message means no message icon/age; unknown activity means no placeholder chip.

Return layout/identity, copy, request/settlement, unread-link, E4/E6 clocks and
quality results separately, with original paths, owner facts, actual dimensions
and time intervals. Cleanup waits for the sole fixture operator.
