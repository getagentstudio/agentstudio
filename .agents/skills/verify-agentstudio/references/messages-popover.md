# J9 — Messages through real entries and service

Oracle for the interior redesign: the owner-accepted N1b/N2/Q1/Q3/A1 originals
in `tmp/design-workflows/2026-10-26-popover-redesign/renders/`, then that folder's
`implementation-brief.md`, with D42/D43/D43a, D44 and D49 in
`tmp/design-workflows/2026-10-25-decisions-ledger.md`, plus the off-main design in
`tmp/design-workflows/2026-10-27-popover-offmain/design.md`.
D43/D43a supersede the boards' width captions. The r5 E5 table,
O8/O14/O31/O32/O40–O43 and V5 still govern message state and effects. Load shared
setup, scenario recipes and visual quality. Already-unlocked granted native
input/capture is required; `window.render` excludes outside-content popovers.
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
scroll positions without changing state; read the last body line, explanation,
source and actions. S17's six lines are a specimen, never a permitted line cap.

D49 keeps the Messages title and footer pinned, with the adopted separator while
scrolled. Section headings are ordinary scrolling content: compare top, middle
and bottom originals, with headings leaving the viewport with their rows. No
sticky heading band is expected. D49 supersedes D45/D45a's sticky-band treatment.

| Subject | Required observation |
| --- | --- |
| Groups | Failed / Needs you / Done / Info / Resolved; empty hidden; newest first, mixed E5/E7 and adopted ties. Sentence-case neutral primary heading (13pt medium), then a plain secondary regular count; no kind chip in a heading. N2 is the visual oracle. No old filters, Count informational or Mark read control. |
| Notice | Kind icon/colour; full body, explanation if present, plain age on its own line, drawer source. Read rows dimmed; read attention/failure are Resolved/Read; read done/info stay in their kind groups. |
| Open ask | Full body, age on its own secondary line, then the form; icon-only Dismiss at the first line's top trailing edge. Messages uses the board layout; D25 remains the card arrangement under D42. Observe each form and its exact service result as below. |
| Settled ask | Exact E5 label; no answer/dismiss/action controls for pending, confirmed, unconfirmed, handedBack, dismissed, expired, withdrawn or stale. Observe real reread/rebinding. |
| Withdrawn/dismissed notice | Withdrawn is Resolved with its label and no actions. Dismissed notice is absent. |
| E7 | Actual reason/optional summary, plain age on its own line, terminal instruction; all returned prompts and omitted count. No invented summary, message identity/form or repeated row Go to pane. |
| Footer | Dismiss all notices only with retained unread/read notices, leading; Go to pane trailing. Both are utility actions with icon and label. Dismiss all leaves asks/prompts/other panes intact. |

## Row and action appearance

Compare native originals to the accepted boards, with the pointer outside first
and a separately granted hover observation. Rows reserve a 16pt glyph box with
the same 12pt SF Symbol/Octicon size, centered on the first text line, then an 8pt
gap to the text. Rows without a glyph keep that text edge. Dismiss has a 24×24pt
hit area at the top right; body wrapping must not shift it down. Age and row
actions sit under the body, with actions under the age.
Every message body with a line break uses the 11pt monospaced system font and
preserves spaces/newlines. A one-line body uses 12pt regular system text with
16pt line height; code-like words alone do not select fixed-width text.

| Role | Visible outcome and controls |
| --- | --- |
| Utility | Icon plus catalog label, no resting fill, hover fill in normal tone. Go to pane, Dismiss all notices, Open file, Open pull request and More messages/panes. |
| Row dismiss | Icon only, catalog Dismiss accessibility label and tooltip; 24×24pt target. No visible Dismiss word in the Messages row. |
| Alternative | Outlined, text only, 6pt radius, at least 24pt high, 12pt text. Single-choice answers and Deny. |
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

- Q1: outlined, text-only single-choice answers wrap as a row. One press sends
  exactly that option once; there is no separate selection-and-Submit step.
- Q3: native checkbox rows align to the body text edge. Toggling does not submit;
  a left-aligned, text-only solid Submit below them sends the chosen IDs once.
- A1: Reason (optional) label above a bordered native field, two lines when empty
  and growing to four; then left-aligned Approve (solid) followed by Deny
  (outlined), both text only. Exercise Approve with a reason and a separate Deny
  without one. Return in the field fires neither decision. Use correlated input
  completion and owner readback for that negative; if unavailable, mark
  native Return coverage UNKNOWN and retain real-path keyboard-test evidence
  separately. Do not infer absence from a delay or manufacture an answer.
- Free text and elicitation keep their schemas, callbacks and enablement; their
  Submit uses the commit role. Card forms keep D25's arrangement under D42; J5
  owns the unanswered-question card witness and shared-role checks.

Retain the N1b, N2, Q1, Q3 and A1 native originals beside their accepted board
originals, with measured width and any extra fixture content identified. D43
makes N1b's multiline opening 560pt despite the older 480pt caption. One-line
N2/Q1/Q3/A1 openings are 480pt; a commissioned 560pt form witness needs a multiline
message already present at open. Compare actual layout and paint, not rescaled
images. Functional and taste judgments remain separate; the Lead owns the final
board comparison.

## Read state and refresh

Program Design r5 removes the collapsed disclosure and its read-on-expand
trigger with flat rows. No UI read trigger replaces it: opening or scrolling
Messages leaves unread notices counted until Dismiss/Dismiss all. Check that
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
   **Eligible capture intervals and age verdicts** in `pane-card.md`. That timing
   owner defines per-consumer eligibility, stale-age and cross-surface results.
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
