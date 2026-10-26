# J9 — Messages through real entries and service

Oracle: specification r5 E5 table, O8/O14/O31/O32/O40–O43 and V5. Load shared
setup, scenario recipes and visual quality. Already-unlocked granted native
input/capture is required; `window.render` excludes outside-content popovers.

Entry path: sidebar/toolbar chip or card link → `PaneContextPopoverHost` →
controller → service/SQLite and scoped Sessions summaries → off-main shaping →
actual `MessagesPopover`. Answers/actions return through the person service and
reread. The oracle is committed state, not callback/transient feedback.

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

At V2's window widths record actual popover width (380pt in Program Design),
content-driven height (max 480pt), scale and edges. Short content must not reserve
maximum-height blank space. Long content scrolls. Capture top and final scroll
positions without changing state; read the last body line, explanation, source
and actions. S17's six lines are a specimen, never a permitted line cap.

| Subject | Required observation |
| --- | --- |
| Groups | Needs you / Done / Info / Resolved; empty hidden; newest first, mixed E5/E7 and adopted ties. No old filters, Count informational or Mark read control. |
| Notice | Kind icon/colour; full body, explanation if present, plain age, drawer source. Read rows dimmed; read attention/failure are Resolved/Read; read done/info stay in their kind groups. |
| Open ask | Full body + plain age in the row head with Dismiss beside it (D25); correct form below at sidebar/pane entries. Single choice submits on one press; multi/free-text use Submit; elicitation inline; approval optional reason field before Approve/Deny. |
| Settled ask | Exact E5 label; no answer/dismiss/action controls for pending, confirmed, unconfirmed, handedBack, dismissed, expired, withdrawn or stale. Observe real reread/rebinding. |
| Withdrawn/dismissed notice | Withdrawn is Resolved with its label and no actions. Dismissed notice is absent. |
| E7 | Actual reason/optional summary, plain age, terminal instruction; all returned prompts and omitted count. No invented summary, message identity/form or repeated row Go to pane. |
| Footer | Dismiss all notices only with retained unread/read notices; Go to pane in full. Dismiss all leaves asks/prompts/other panes intact. |

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

Return before/after/scroll originals, source/readback/action and receipt state,
actual dimensions, control absence/presence and functional/taste verdicts.
G07/G08 real-input cells stay UNKNOWN; synthetic tests cannot fill native V2.
