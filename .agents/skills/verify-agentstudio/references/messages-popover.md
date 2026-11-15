# J9 — Messages through real entries and service

Oracle: the tracked [specification O31 and O40–O44](../../../../docs/specs/2026-10-24-pane-context-display/2026-10-24-pane-context-display-specification.md)
and [Program Design](../../../../docs/specs/2026-10-24-pane-context-display/2026-10-24-pane-context-display-program-design.md).
The specification at `f00068402` incorporates D62–D79a. For targets adopting
D83/a/b/c, D84a and D85/a/b/c/d, those later owner decisions supersede its retired
inline expansion, disclosure reservation, filter menu and newline-based font
rules as described below. Keep the target's adopted decision pins with its
oracle; earlier board captions cannot override them. The E5 table, O8/O14/O32
and V5 retain their state/effect contracts.
Decisions ledgers are optional context, not required files. A historical target
needs its explicitly supplied oracle; if absent, return UNKNOWN/setup gap. Never
search a sibling worktree for a substitute. A commissioned board comparison
requires its exact original and provenance. Load shared setup, scenario recipes
and visual quality. Already-unlocked granted native input/capture is required;
`window.render` excludes outside-content popovers.
This updated recipe is draft for live coverage until driven on a declared target.

Entry path: sidebar/toolbar chip or card link → `PaneContextPreparedPopoverHost`
→ `PaneContextPopoverHostBindings` → `PaneContextPopoverRefreshOwner` reading the
real service/SQLite and scoped canonical inputs → off-main shaping through
`PaneContextPopoverDetailFamily` → materialized value → actual
`MessagesPopover`. Actions return through the refresh owner's person-service
path and immediate refresh. A publication or callback is not native application;
observe committed state and the actual panel.

## Open and capture

1. Establish/record scenario facts before pressing the actual chip, Show messages
   or +N more with the granted computer-use route (Peekaboo secondary). Cover
   every distinct entry; each must open the intended scope.
2. Save PID/start-guarded native inventory before and after opening:
   `pane-chrome.sh inventory PID EXECUTABLE LSTART NEW_ABSOLUTE_JSON`.
   Select the actual popover/window ID by visible content and ownership.
   Inventory can omit a non-renderable popover: absence is UNKNOWN, not evidence
   of an app failure. Use only the later target's granted capture route.
3. `pane-chrome.sh capture PID NATIVE_WINDOW_ID EXECUTABLE LSTART NEW_ABSOLUTE_PNG`
   collects one local window. Open the original and confirm Messages is visibly
   included. Capture its separate window when needed; a main frame without it
   proves no popover. If the tool cannot include it, retain inventory/error and
   return UNKNOWN. Do not unlock, activate an unrelated app or change TCC/route.

## Read, scroll and act

Record actual popover width separately from V2's outer-window widths. D43/D43a
choose the width once at the opening's first ready content: **560pt if any shown
message has a body with a line break; 480pt otherwise**. Loading starts at clamped
480pt; one Loading→first-ready width change is allowed. The choice clamps to the
hosting screen's visible width minus 16pt on each side, with a 440pt floor unless
the screen itself is narrower. After first ready content, later arrivals, body
changes and age updates do not change that opening's width. Reopen as a new observation to choose from
the new content. With a declared held-read fixture, capture Loading then first
ready content; without one, native Loading-transition coverage stays UNKNOWN.

Native width witnesses use a roomy declared debug target: only one-line messages
at first ready content must yield 480pt; compiler-output notice N1b present before
opening must yield 560pt at first ready content. Keep the one-line case open while
a multiline notice arrives and verify its width stays 480pt; reopen and verify
560pt. Keep the wide case open through a later content change and verify it stays
560pt. Retain before/after content facts and measured native bounds. Never stretch
a PNG or force an
arbitrary panel width to fill a cell. D43's clamp/floor is **unit-proven coverage,
not natively observed by J9**: cite the declared target's pure-function tests and
receipt for `(has multiline body, screen visible width) → width`; without that
receipt it remains UNKNOWN. Native 480/560 frames alone do not prove the clamp.

Record content-driven height (max 480pt), scale and edges. Short content must not
reserve maximum-height blank space. Long content scrolls. Capture top and final
scroll positions; open Details and read its final body line, then the list explanation,
source and actions. O42 initially caps the **body only** at six visual lines;
S17's six-line specimen alone cannot exercise its disclosure branch.

D49 keeps the Messages title and footer pinned, with the adopted separator while
scrolled. Section headings are ordinary scrolling content: compare top, middle
and bottom originals, with headings leaving the viewport with their rows. No
sticky heading band is expected. D49 supersedes D45/D45a's sticky-band treatment.

| Subject | Required observation |
| --- | --- |
| Groups | Failed / Needs you / Done / Info / Resolved; empty hidden; newest first, mixed E5/E7 and adopted ties. Sentence-case neutral primary heading (13pt medium), then a plain secondary regular count; no kind chip in a heading. The four inline filter chips are specified below; no Count informational or Mark read control. |
| Notice | Kind icon/colour; six-line body with disclosure when needed, separate explanation, plain age and drawer source. Read rows dimmed; read attention/failure are Resolved/Read; read done/info stay in their kind groups. |
| Open ask | Body/disclosure, age on its own secondary line, then the form; icon-only Dismiss at the first line's top trailing edge. Messages follows O42; D25 remains the card arrangement. Observe each form and its exact service result as below. |
| Settled ask | Exact E5 label; no answer/dismiss/action controls for pending, confirmed, unconfirmed, handedBack, dismissed, expired, withdrawn or stale. Observe real reread/rebinding. |
| Withdrawn/dismissed notice | Withdrawn is Resolved with its label and no actions. Dismissed notice is absent. |
| E7 | Actual reason/optional summary, plain age on its own line, terminal instruction; all returned prompts and omitted count. No invented summary, message identity/form or repeated row Go to pane. |
| Footer | Compact paint Dismiss all only with retained unread/read notices, leading; To pane trailing. Full AX/help remains Dismiss all notices / Go to pane. Both are utility actions. Bulk dismissal keeps its full pane/drawer scope with any filter active and leaves asks/prompts/other panes intact. |

## Disclosure, filters and opening-local state

Before body width/font layout is ready, the first paint caps the body at six
visual lines with **no reserved disclosure row** (D84a). When the worker's
width/font measurement lands, only a body exceeding six visual lines gains a
truncated preview ending in one ellipsis and a `Details ›` trigger. Explanation,
age, source and actions remain outside the cap. Short rows keep no trigger,
empty slot or extra gap before or after count landing. For long rows the new
trigger can change row height; do not require the retired reserved-slot geometry.
Wrapped text uses the measured visual lines, never a fixed newline count. See
[body measurement](../../../../Sources/AgentStudio/App/PaneContext/PaneContextMessageBodyMeasurement.swift)
and [rendering](../../../../Sources/AgentStudio/SharedComponents/PaneContext/PaneContextTruncatedMessageBody.swift).

Press actual Details and observe **one shared right details pane**, widening the
popover while the list body stays capped. The pane title is the item's own title
or first nonempty line, cut to one line; its close control is ⊗. Scroll and read
the complete final body line. D85c keeps the full content, including the first
line repeated by the title. Full AX text alone proves neither list truncation
nor painted full content. The open item's Details trigger uses the shared
selected button paint. On inline asks it sits beside Submit in the existing
form commit row (D85d); approval keeps Approve/Deny and Details in that row.
Notices and provider prompts keep their body Details trigger. Open another item
and confirm the same pane shows that item's content. Close the pane or press
Escape to return to the unchanged list; Escape clears Details before closing
the popover. Do not look for inline Show-more/Show-less controls.

The header has `Messages N` on the left and the SF filter icon plus inline
**Needs you / Failed / Done / Info** chips with counts on the right. Each chip
toggles independently; none selected shows everything, including Resolved, and
multiple selected chips show their union. Verify none, one and two selected
states, then toggle one off without clearing the other. Every chip is clickable,
even with count zero and no loaded rows. Counts are scoped **unread** counts,
not loaded-row counts; include read Done/Info and provider prompts/omissions in
appropriate zero-unread witnesses. When the selected types have no loaded rows, the empty state names them,
for example `No info messages` or `No done or info messages`, rather than
the generic no-loaded label. Missing read-state setup leaves that live cell
UNKNOWN. Filtering hides loaded groups only; More messages/panes keeps shared
paging across sources and can load hidden kinds. Verify Inbox remains unchanged.

Drafts, picks and Details selection are local to one opening and composite
`(sourcePaneId, messageId)`. Verify filter/page/hide/return retains them, including
absence from a bounded page; such absence cannot prove retirement. Known
scope/owner retirement, settlement/dismissal, incompatible schema/replacement and
close clear them. Close/reopen starts fresh, and colliding message IDs must not
share input. Retained drafts grant no action authority; stale opening/version
bindings cannot mutate current input. Held interleavings remain gate evidence,
separate from live end-state observations. Provider Details follows a versioned
source/ordinal slot snapshot (D85b): a known semantic slot replacement closes
Details; age-only refresh, filtering and bounded-page absence preserve it.
Observe that insertion cannot select a new prompt while showing the old body;
a stale captured Details action cannot retarget it. Missing page content alone
is not retirement. Stable prompt-key tracking is not implied. Inspect full-scope bulk dismissal
under an active filter using exact stored outcomes, including untouched asks,
prompts and unrelated panes.

## Row and action appearance

Compare native originals to the tracked spec and any supplied board originals, with the pointer outside first
and a separately granted hover observation. Rows reserve a 16pt glyph box with
the same 12pt SF Symbol/Octicon size, centered on the first text line, then an 8pt
gap to the text. Rows without a glyph keep that text edge. Dismiss has a 24×24pt
hit area at the top right; body wrapping must not shift it down. Age and row
actions sit under the body, with actions under the age.
Message and ask prose use 12pt proportional system text by default in both list
and details pane, including text with line breaks. Only an explicit format field
or fenced code block selects 11pt monospace; build-output code stays monospaced.
Fence delimiters signal the code span and are not painted. Preserve admitted
spaces/newlines; code-like words alone do not select fixed-width text.

| Role | Visible outcome and controls |
| --- | --- |
| Utility | Icon plus spec-projected visible label, no resting fill, hover fill in normal tone. Footer paint is To pane / Dismiss all; full AX/help stays Go to pane / Dismiss all notices. File/PR/paging controls keep their projected copy. |
| Row dismiss | Icon only, catalog Dismiss accessibility label and tooltip; 24×24pt target. No visible Dismiss word in the Messages row. |
| Alternative | Shared outlined secondary paint, 6pt radius, at least 24pt high, 12pt text. Deny is text only. Details › includes its spec-projected chevron and uses the shared selected-secondary state while open; single choice uses native radio/picker controls. |
| Commit | Solid accent #409CFF with dark #1D1F21 text, same geometry, text only. Submit and Approve. |

A full-width grey option-row pill is a failure for these actions. Painted style,
hit area, accessibility label and tooltip are separate checks; a model role or
AX string alone does not prove the visible style.

## Forms through the owned debug pane

Use only the declared debug app, its own fixture pane, pinned CLI and isolated
zmx root. Take setup from `pane-context-scenarios.md`; no production writer,
production app or production zmx root is a substitute. Await pane-owned facts or
exact CLI readback of the answer, then inspect the rebound native view. A sleep,
callback acknowledgement or optimistic feedback cannot establish settlement.

- Single choice: radio for 1–4 options; for 5+ a pop-up picker only when every
  **display** label is ≤32 characters. Any longer label uses wrapping radio at
  any count. Cover 4, 5 and long-label branches with declared payloads. Display
  capitalizes the first letter; original option IDs are sent unchanged. Picking
  changes local input only. Submit starts disabled, enables after a pick, then
  actual native Submit sends that original ID exactly once.
- Q3: native checkbox rows align to the body text edge. Toggling does not submit;
  a left-aligned, text-only solid Submit below them sends the chosen IDs once.
- A1: Reason (optional) label above a bordered native field, two lines when empty
  and growing to four; then left-aligned Approve (solid) followed by Deny
  (outlined), both text only. Exercise Approve with a reason and a separate Deny
  without one. Return in the field fires neither decision. Use correlated input
  completion and owner readback for that negative; if unavailable, mark
  native Return coverage UNKNOWN and retain real-path keyboard-test evidence
  separately. Do not infer absence from a delay or manufacture an answer.
- Free text grows vertically, then Submit sends its exact content. Elicitation
  uses schema controls: checkbox for boolean, picker for enum independently of
  the single-choice option-count rule, and the declared remaining field types.
  Nonapproval forms share one filled container; Submit is their only blue
  commit control. Empty multiple choice and free text remain contractually
  allowed; do not invent requiredness. Card layout stays D25 under J5.
  For a required string/number schema field, inspect the inline asterisk beside
  its label and the aligned control beneath it.
- No form claims global/default Return. A single-line elicitation field's own
  Return submits only its own ask. Plain/Shift-Return in vertical free text and
  approval fields sends/decides nothing. Use correlated completion/readback for
  negatives, never a delay. There is **no newline-insertion assertion**. Missing
  native completion leaves that cell UNKNOWN with gate evidence separate.

With two eligible asks open and focus outside text/Submit controls, press Return
and verify neither sends. Separately activate focused Submit through its normal
button action and verify only its ask settles once. In Messages, Return in one
actual single-line elicitation field submits that field's own ask while the
other remains open. Preserve correlated completion/readback for each case.

Read [AskAnswerForm](../../../../Sources/AgentStudio/SharedComponents/PaneContext/AskAnswerForm.swift)
and [presentation shaping](../../../../Sources/AgentStudio/App/PaneContext/PaneContextPopoverShapingKernel+Values.swift)
on the declared target. Headless ordinary-binding-in plus actual native Submit
supports delivery/rebinding; physical radio/picker selection and delivery stays
a separate live obligation. Paint, full AX/help, hover tooltip and callback
result are separate checks. Compact footer text cannot replace full semantic
labels/help; J10 uses the same navigation projection.

Retain native originals beside any explicitly supplied comparison originals,
with measured width and extra fixture content identified. D43
makes N1b's multiline opening 560pt despite the older 480pt caption. One-line
N2/Q1/Q3/A1 openings are 480pt; a commissioned 560pt form witness needs a multiline
message already present at open. Compare actual layout and paint, not rescaled
images. Functional and taste judgments remain separate; the Lead owns the final
board comparison.

## Supplemental held test-helper frames

The permanent [interactive frame fixture](../../../../Tests/AgentStudioTests/App/PaneContext/PaneContextUIRoundFramesTests.swift)
supports an existing SIGUSR1 advance route. This is a **test-helper** route, never
authority to signal a production or debug app. Under a separate helper/native
capture grant, run from the declared worktree with its gate environment:

```bash
env -u AGENTSTUDIO_PANE_TOKEN -u AGENTSTUDIO_WORKSPACE_ID \
  -u AGENTSTUDIO_IPC_SPOOL_DIR -u AGENTSTUDIO_PANE_ID \
  -u ZMX_DIR -u ZMX_SESSION -u ZMX_SESSION_PREFIX \
  -u AGENTSTUDIO_IPC_SOCKET -u AGENTSTUDIO_CLI \
  DEVELOPER_DIR=/Applications/Xcode-27.app/Contents/Developer \
  MISE_TASK_SKIP_DEPENDS=1 AGENTSTUDIO_UI_ROUND_REVIEW=1 \
  mise run test:swift -- --filter '\.PaneContextUIRoundFramesTests/interactiveF1WidthTransition'
```

Its atomic receipt is
`tmp/implementation-workflows/2026-10-28-pane-context-ui-round/frames/interactive-review-current.json`.
For each distinct hold, match `state: held`, name, PID, actual helper
executable/test-bundle/filter invocation and process start to this run. Use its
popover/controls window IDs for the separately granted native capture. After
capture, send **one** `kill -USR1 "$PID"` to that verified helper, then consume
the next distinct held receipt before another signal. Stale, finished or retired
receipts authorize none. The handler is removed and prior disposition restored
between holds; a late signal is unsafe. Finish and SIGUSR1 advance the same held
step; agents need not click Finish. F1 holds compiler and mixed-form first/count
scenes separately.

`pane-chrome.sh` accepts debug-app executable paths, not test-helper paths; do not
bypass its guard. Use only the helper's granted PID-targeted native route.
Missing focus, TCC, transport or unlocked access means UNKNOWN. Cached
`cacheDisplay` images/control-flow results are supporting coverage, not
compositor paint, real provider interaction or physical radio selection. Reading
this recipe authorizes no helper launch or signal.

## Read state and refresh

The current six-line truncation and Details pane do not mark read. Opening,
scrolling and reading Details leave unread notices counted until Dismiss/Dismiss all. Check that
unchanged unread state through actual owner readback. The retained read-state
rendering above is still required, but its setup is **product-test-only**, a
named live gap. In particular, S19's read-failure component cannot be generated
by a disclosure, expand-to-read or invented Mark read action; full live S19 stays
UNKNOWN. Do not count a model/service fixture as a native journey observation.

Use the held receipt/lifecycle recipes for S10/S19. Keep an independent provider
prompt to catch optimistic status changes. After an action inspect the exact
stored source/message and unchanged other source, then the rebound UI. Live
loading/unavailable/failure scenes remain UNKNOWN without a declared fixture;
product-test port injection is supporting coverage only. Failure must retain the
promised note/width and not resurrect a stale actionable card form.

Keep list/card open during second-prompt/omitted-count/drawer-only changes while
the compact first prompt and E4/E5 stay equal; inspect new rows/+N without reopen.
Keep an open popover through an age transition too. Follow file/PR/focus actions
to their actual destination under the later effect grant; callbacks and URL
calculations are insufficient.

## Continuously open: F10 responsiveness and F09 survival

For F10 use the standard J1 launch in an owned CoW worktree and the normal
`~/.agentstudio-db/<code>/` root. The Lead declares the target; never use
`89x2`, custom data roots or symlink substitutions. Arrange at least 10 Info
notices (prefer 12) through the owned pane writer, with distinct bodies and
completed CLI/readback facts. Reserve one timed row and enough disposable
notices that a later single dismissal leaves at least 10.

1. Open Info through its real chip and capture the actual panel. Keep this same
   opening across **at least three minute transitions** of the recorded row;
   retain its exact write/updatedAt and UTC/monotonic capture bounds. Arrange
   layout first, then keep writes, provider turns, focus and resize unchanged
   during this passive clock phase.
2. Capture each age bucket from the native panel using J5's
   **Eligible capture intervals and age verdicts** in `pane-card.md`.
   Keep every original; no input, reopen or later refresh repairs a missed tick.
3. After the third passive observation, click the actual row Dismiss on a
   disposable notice other than the timed row. That exact row disappears while
   Messages stays open; verify stored dismissal and remaining count. This is
   the click check: a successful scroll or accepted input cannot replace it.
4. While Messages remains open, run an authenticated read such as `pane.list`
   with the declared bundled CLI/J1 wrapper. Keep start/end, exit and actual
   result. Ping alone is insufficient. Use the established command/process
   failure bound; add no correctness timeout or polling loop.
5. Press actual Go to pane. Observe physical dismissal and focus of the exact
   source, then a usable pane response. Record this D44 result separately.

Report each tick, click, CLI read and focus result. An unanswered read or
unresponsive visible control is not a PASS because ping succeeds. Preserve
partial native/AX/errors and return an unexplained stall with cause UNKNOWN.
This functional journey proves neither F10's cause nor CPU/MainActor/idle-work
claims; those remain the separate marker-scoped product proof.

For F09, keep a card with a known open ask plus another needs-you item, press its
real +N more link, then start an actual contained foreground provider turn in
that pane. Have that real turn append a uniquely identified notice through its
debug CLI. Keep the same Messages opening without another press and observe the
new notice. Save provider/binding/turn and message facts, plus before/after native
originals and inventories. Record card visibility, anchor presence and whether
the panel survives at the moment of the update. A synthetic hook or notice-only
fixture does not satisfy the real-turn cell. J5 owns D58/D59's separate end-state
checks and their gate-only intermediate-state boundary.

## D44: physical dismissal and scroll landing

Owner dismissal decisions and requested proxy scroll targets are gate evidence.
These physical outcomes require this journey on the declared native target:

| Entry/action | Deciding observation |
| --- | --- |
| Row/footer Go to pane | Popover closes and the exact source pane, including a supplied drawer source, is focused. |
| Info chip | Its section heading and target content are in view below the pinned title. |
| Show messages / bell-bearing +N more | Opening lands at the intended top and scope. |
| Card Answer… | The exact elicitation row beyond enough preceding content is visibly reached and readable. |

Keep before/after originals and exact source/control IDs. A requested target
or callback alone cannot pass a physical cell. Missing native access remains
UNKNOWN; D44 adds no native-settlement contract.

Return before/after/scroll originals, source/readback/action and receipt state,
actual dimensions, control absence/presence and functional/taste verdicts.
G07/G08 real-input cells stay UNKNOWN; synthetic tests cannot fill native V2.
