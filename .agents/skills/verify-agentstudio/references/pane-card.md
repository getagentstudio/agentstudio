# J5 — one field per line, distinct clocks and exact copy values

Oracle: `pane-contract.md`, card and message/activity clock sections. The card
has one field per line; PANE always appears, SESSION only for a verified live
binding. Select current or explicitly declared historical warning policy before
driving. Source/build evidence is required for the target, not copied from an
older image.

Inputs: shared target receipt, held pane/readbacks, Working hook status, original
row/card/toolbar frames, an unverified failed-action fixture and a verified-live
identity positive. Require shared setup's observation grant; static app-rendered
layout/age works while locked. Actual copy/pasteboard observation still needs a
separately granted interaction route and stays UNKNOWN when unavailable.
`focusPane` selects the proof pane and the
window-scoped `toggleManagementLayer` opens its card. Retain the applied receipt
and verify it is open. Close only when allowed with `managementLayerExit`.

## Current card: same order and shape at every width

Use the shared quality procedure at its required widths and tolerance.
Headless split/equalize produces equal widths; there is no ratio verb for
different-width siblings. Their side-by-side comparison needs a separately
granted native divider drag on an already unlocked screen. Without that route,
Sibling spacing and Same shape stay UNKNOWN. Sequential single-pane frames,
normalized to each card's origin, can still judge local alignment.
Keep off-target layout frames as calibration, labelled with measured width;
further layout attempts are allowed, and only a frame within ±2 pt fills a cell.
A frame showing a product defect keeps its verdict and is never replaced or
hidden.

Use J4's no-message, fresh-message, same-message-aged and 200-byte long-message
states; also cover note, real warning, verified/unverified session, no-repo,
long-title and long-branch fixtures. Preserve the real producer's icons and
conditional fields; don't manufacture a verified session with a warning that
the real policy suppresses. Keep a comparator and the original frames.

Each populated field takes its own line in this fixed order at every width:

| Order | Deciding observation |
| --- | --- |
| Title | Same agent/normalized terminal title as the sidebar; natural one- or two-line height. Oversized titles tail-truncate after two lines with full tooltip; normal titles fit at 420pt. |
| State | Hook status chip, existing activity-age chip and active glyph together on one line. They match the same sidebar pane at the same instant; no detached age-only extra row. |
| Message | Fixed neutral message icon, message and its own age; message may wrap to **two lines**, with no reserved blank second line when short. |
| Warning | Existing plain connection/credential warning on its own line, in the **card only** after #57. |
| Note | Pane note on its own line when present. |
| Caption grid | One field per Grid row: icon, fixed caption column, value and inline copy where applicable. Same caption/value edges across all cards. |
| Git chips | Existing git chips last, only when present. The owner's retained git chip in the drawer is not a duplicate to remove. |

Caption-grid field order is **REPO, BRANCH, WORKTREE, CWD, SESSION, PANE**.
WORKTREE appears only when its name differs from REPO. CWD appears only when it
differs from the worktree root. SESSION appears only for a verified live binding;
PANE always appears. Include the real fallback row for a pane without a repo.
The caption column is sized for **WORKTREE in every card**, even if omitted in
that card, so all values share the same local x. No width-based switch to an
HStack/two-column card; the Grid is only the three-column field-line alignment.

Check natural heights and matching sibling gaps. Copy buttons follow their
values at the same small gap, not at the card's trailing edge. Normal repo,
branch and 36-character pane/session IDs must be fully readable at 420pt and
wider. Oversized path/branch/ID values may use the adopted **middle truncation**
with full tooltip; don't confuse that boundary with clipped normal IDs. A long
title/message follows its separate two-line tail boundary. Every element stays
inside the card's inner bounds; no abandoned column or empty reserved row.

On every original, also verify:

- State precedes message; title stays above both. The message has one fixed
  spec-owned icon, neutral paint and no motion, not another session-status dot.
- Message age follows the message in row/card/toolbar. Its labels are **just now**,
  **1 min ago**, **N min ago**, **N hr ago**, **N days ago**. No message means no
  message icon or message-age suffix; activity chips may still have deadlines.
- The card retains a plain warning for a real refusal. The sidebar and toolbar
  have **no warning/error line** after #57. A matching empty row is insufficient:
  require the retained refusal data and the positive card warning through J6.
  No raw credentialNotRecognized text or “?” placeholder chip is user-facing.
- Normal pane ID always paints completely. Session ID requires actual verified-live
  `session.query`/reader evidence taken immediately before capture for that same
  pane. Compare the full rendered SESSION to that verified-live owner fact;
  Working alone does not establish it. Test an unverified negative and a
  verified positive. Read full IDs, including middle
  characters, at all five required widths. AX full values can
  hide truncation. Include lineless and long-message layouts and a comparator.
- Activity recency/active chips match the same sidebar row at the same instant.
  **Message age uses message.updatedAt; activity chips use pane activity.** Their
  unit transitions share the adopted pure projection, not a common timestamp.
  The message has no age-dependent tone/motion; keep chip color tiers unchanged.

## Copy SESSION means only the session ID

Use an owned verified-live fixture with a known session reference from its
authorized public reader. Record that **raw reference** separately from the
displayed `provider · reference`. Invoke the real card's **Copy Session ID**
control through the run's permitted UI route, then read/paste the string that
action wrote to the pasteboard. It must equal the reference **exactly**, with no
provider prefix, separator, caption, extra whitespace or truncation. A label,
tooltip or expected producer value alone cannot pass this check; don't set the
pasteboard directly to supply the answer. Also check Copy Pane ID against its
full UUID and ensure an unverified pane has no SESSION/copy control.

Retain action/reader receipts and the comparison, using only owned fixture
values. If the real control or pasteboard observation cannot be exercised within
the run grant, copy is UNKNOWN independently of layout. The raw-reference
oracle does not change when an older implementation copies the display string.
Bind the declared binary to the actual copyValue producer/handler before use.

## Message age: one successful write, then no input

This message-age observation uses the successful message write as t0, never
the hook/activity time.

1. Finish all resizing/setup, establish Working and open the card once **before**
   the message write. Keep row/card/toolbar visible. Use shared setup's actual
   fixture-shell or commissioned foreground-hold route. Record high-precision UTC
   directly before the **line CLI subprocess** and after its exit-0/applied
   completion. With the foreground holder, retain the matching exit-0 `hold.line`
   and its `t_before`/`t_after` plus `mono_before`/`mono_after`; the holder stays
   foreground and alive throughout the pair.
   These bound message.updatedAt as **t0=[earliest,latest]**: the owning service
   takes wall time inside the admitted SQLite write. An outer `terminal.send`
   receipt, provider hook time or first screenshot is not this interval.
2. Include timestamp precision in the bounds. A whole-second end string means
   latest=end+1s, not that exact fractional instant. Include source timestamp
   rounding too (the pinned storage codec rounds to microseconds; ±1µs is a
   conservative allowance when reusing that source). Retain a monotonic interval
   alongside UTC to detect wall-clock discontinuity. Recheck the final target's
   wall-clock/codec mapping; if it is not established, return UNKNOWN rather
   than assume it. No denied pane.context.get or authentication bypass is needed.
   A permitted exact persisted updatedAt read can tighten the same interval.
3. Leave the already open card and all three surfaces unchanged. After the write,
   the consumer waits 3 s and takes one `window.render` with start/end UTC bounds.
   This settle does not supply t0 or a timer oracle. Accept **just now** only when
   the entire computed message-age window is below 60s. Keep the line text and
   write receipt.
4. Send no new hook, terminal input, line/title, focus, toggle or reopen command.
   Schedule one settled render of the same message in the **1 min ago** bucket,
   [t0+60s,t0+120s), with no intermediate renders. Aim safely inside it; t0 is not
   the first screenshot. A fresh frame at 59.5s followed 61s later legitimately
   has age 120.5s and reads 2 min ago.
5. Verify no message replacement/clear or timestamp reset and no card close.
   Compute **[capture-start − latest t0, capture-end − earliest t0]** for every
   frame. Every point in that interval must belong to the asserted label bucket.
   Read row/card/toolbar age text independently; one changing surface cannot
   substitute for another. Keep unchanged message/writer/order evidence where
   available through the authorized reader or retained write/continuity receipts.

Expected message unit boundaries: just now below 60s; floor(minutes) from 60s to
60m; floor(hours) from 60m to 24h; whole days thereafter, with the adopted expanded
labels above. The chip keeps its compact labels Now/1m/Nm/Nh/Nd. Future dates clamp
as the pure projection specifies. A hook/activity change must not reset message
age or mutate its updatedAt; changing age alone must not reorder pane activity.

If the interval straddles a boundary, lies outside the asserted bucket, or has
unknown clock mapping, the timing attempt is **INVALID/UNKNOWN**, not a product
failure. Stop this attempt and report its bounds; do not automatically retake,
write a new line or request input to repair the missed bucket. In a valid
1-minute interval, a retained just now, missing suffix or cross-surface mismatch
is **FAIL**; do not call a visible
product mismatch a timing error. No extra timer/input/reopen repairs the proof.

If only later buckets were captured, a valid later transition may support that
narrow advancement claim; it does not create the missing fresh baseline.
A locked run is eligible through the app-render route when state, clocks and
lock probes are established. A stale/in-flight/blank result after the observed
3 s settle fails; a longer wait, retry or unlock does not repair that attempt.
A row-only crop adds row coverage only; never infer card, toolbar, PID, geometry
or exact timing from it.

## Keep the activity clock separate

For an activity-clock-only check, retain a fresh canonical hook activity and its
send/admission interval as activity t0. With the same card continuously open,
apply the same conservative per-frame age calculation to the compact chip:
Now below 60s, 1m in [60,120)s, then later whole units. Match active state to the
sidebar policy. No activity/input/reopen may intervene. A valid later-bucket
pair supports only its measured activity advancement; it cannot supply a
message-write interval or a missing same-attempt Now frame.

## Return

Return separate layout/identity, copy-payload, activity-clock and message-age
verdicts, the shared quality result and each valid age interval. Missing real-
path test coverage, if offered, is a separate gap for the Lead. Cleanup waits
until the named operator no longer needs the owned pane.
