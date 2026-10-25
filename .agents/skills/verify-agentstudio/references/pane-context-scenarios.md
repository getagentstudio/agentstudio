# Pane-context setup recipes — S1–S19 and hard cases

Use with J4/J5/J8/J9/J10. These recipes prepare inputs, then each journey observes
its actual consumer. They grant no launch, binding fabrication, datastore install,
UI interaction or external opener effect. The Lead declares exact target, owned
panes, sole operator, fixture paths, mutations/capture and cleanup before a run.

Oracle: repository `docs/specs/2026-10-24-pane-context-display/` requirements,
specification r5, **verbatim** `owner-rules-checklist.md` R1–R10, storyboard and
renders; Program Design r4's later contracts. Open these adopted sources when
the commission selects this feature; do not infer expected values from output.
Expected values belong in the run's facts table, never computed by the rules
under test. No script self-test is a real-target observation.

## Source-backed paths and completion

| Input | Entry → owner → observed result | Source in the declared target |
| --- | --- | --- |
| Line/title | Pane CLI ordered writer → own-pane IPC → service SQLite write → publication → consumers; require applied plus current readback | `Sources/AgentStudioIPCClientCore/PaneCLICommandRunner.swift`, `AgentStudioAppIPC/AppIPCPaneContextMethodRegistrations.swift`, `Core/PaneContext/PaneContextService+OrderedWrites.swift` |
| Notice/ask | Own-pane send/ask → service admission/SQLite → counts/detail; answer UI → person service → settlement → reread | `Sources/AgentStudioProgrammaticControl/IPCPaneMessageContracts.swift`, `Core/PaneContext/PaneContextService+Messages.swift`, `PaneContextAskSettlement.swift` |
| E7 | Session event/hook → App adapter → Sessions ingestion/reducer → status publication and session summary → scoped shapers | `App/IPCComposition/AgentStudioIPCSessionsAdapter+ProviderMapping.swift`, `Features/Sessions/Models/SessionStatusState.swift`, `SessionsStatusRuntime.swift`, `SessionSummaryProjection.swift` |
| E6 | Terminal/hook activity → PaneActivityClock → keyed activity publication | `Core/RuntimeEventSystem/PaneActivity/PaneActivityClock.swift`, `App/Boot/AppDelegate+PaneActivityBoot.swift` |
| Detail/interaction | Popover/card host → controller → real service/reader → off-main shaping → rebound actual view | `App/PaneContext/PaneContextPopoverHost.swift`, `PaneContextPopoverController.swift`, `Core/PaneContext/PaneContextService+Detail.swift` |

The shorter `App/`, `Core/` and `Features/` source paths above are under
`Sources/AgentStudio/`. Read final-build registrations and descriptors before
using a wire request. If missing or changed, return a setup gap rather than
inventing a command or weakening the oracle.

Retain child stdout/stderr/exit, request/correlation, actual source/message IDs,
current session/count/detail/line facts and capture bounds. A session event's
`admitted` result alone does not establish verified binding or applied status.
`terminal.send` acceptance is not child completion. Use existing producer facts,
typed terminal completion and readback; no readiness sleeps/polling. The capture
consumer's documented 3s settle follows completion and is not test correctness.

## Pane-origin inputs and form payload helper

All writer operations below run in the **owned fixture shell/provider holder**
with the pinned CLI and that pane's real environment, not operator escrow.
Never print tokens. `pane.*` author methods require own-pane principal and
`handle:"self"`; automation escrow is not an alternate writer identity.

```bash
"$CLI" line "Running tests (3/7)"
"$CLI" line --clear
"$CLI" title "Assistant capabilities overview"
"$CLI" notify "Branch rebased onto main" --kind info
"$CLI" notify "Tests passed (412)" --kind done
"$CLI" notify "Review the migration plan before I apply it" --kind attention
"$CLI" notify "Build failed: 3 errors in SessionsIngestion.swift" --kind failure --open "$OWNED_FILE:3"
"$CLI" ask "Pick a color for the test?" --reason question --choice red,blue
"$CLI" ask "Describe the next step" --reason question
"$CLI" approval "Approve running the migration?" --timeout 300
```

The approval verb is the adopted P6 contract; require it in the **delivered**
CLI/help/schema before use. Its timeout bounds a blocking request, not a test
speed verdict. The current simple ask CLI creates single choice or free text;
multiple choice/schema use the real raw IPC request below. No new CLI flag is
implied. E5 asks need a verified session writer; notices/lines may be pane-written.

The input helper emits complete **synthetic** requests, sends nothing and creates
no identities. Supply a private owned envelope JSON with handle `self`, fresh
repository-generated UUIDv7 `messageId`/`correlationId`, and
`writer:{provider,conversationId}` taken from that verified source. It contains
no credential. For multiple choice or schema, from that fixture shell:

```bash
REQUEST=$(/bin/bash .agents/skills/verify-agentstudio/scripts/pane-context-input.sh form multiple "$FORM_ENVELOPE")
"$CLI" pane.message.send --json "$REQUEST"
```

Other helper form kinds are `single`, `freeText`, `elicitation`, `approval`.
Every operation needs fresh UUIDv7s; do not reuse the example/test IDs. For
approval's CLI proof use the actual new verb, not the helper's nonblocking ask.
Payload definitions come from `IPCPaneMessageContracts.swift`,
`IPCPaneMessageValues.swift`, `IPCPaneAskForms.swift`; P6 adds approval's shape.

Native actions: single choice once; multiple Swift+BridgeWeb then Submit; free
text exact body then Submit; schema Environment=staging/Dry run=true then Submit;
approval Approve with reason and a separate Deny without. Inspect exact returned/
stored answer and one submission. On card schema, Answer… opens its exact row in
Messages. Cover sidebar, pane and card permissions. A model/callback alone is not
a real interaction. Refusal, invalid values and held failure cases stay with
real-boundary product tests unless a live failure fixture is declared.

## Provider prompts through the real adapter — labelled synthetic

First establish verified-live E2 with the declared contained provider/hook fixture.
Keep its holder and provider identity/turn alive. Use valid complete provider
payloads from current installed hook projection; e.g. UserPromptSubmit needs
session_id and hook_event_name. No status flag on `line` substitutes for E3.
No fake provider process/binding claim is created by this skill.

For controlled E7 stimulus, the helper's hook envelope has handle `self`, actual
`provider:{identifier,version,mode}`, fresh correlation/occurrence UUIDv7s and
`event:{conversationId,turnId,occurrenceId,elicitationId}`. Retain the literal
envelope as synthetic stimulus and its actual `session.query` result separately.

```bash
REQUEST=$(/bin/bash .agents/skills/verify-agentstudio/scripts/pane-context-input.sh hook permission "$HOOK_ENVELOPE")
"$CLI" session.event --json "$REQUEST"
```

`permission` emits a Bash permission **without summary**. `question-summary`
emits an elicitation with "Use staging DB?" and the supplied distinct elicitation
key; it is a **question**. `close-question` emits elicitationResult for that same
key with fresh occurrence/correlation. The real App adapter/reducer stays in
the path. Require verified owner readback; a refused/ineligible synthetic hook
is a fixture gap, not successful prompt setup. Stop/turnStart/tool completion
may clear prompts: avoid them while holding the scene. Use distinct keys for
coexisting prompts, not a repeated idempotent message.

**G07/G08 disposition: real ingress cannot produce; proven by synthetic product
tests.** This names the assigned proof class, not a claim the product tests have
already passed. Require their labelled result/receipt before citing them. No
producer mapping or prompt-limit change is authorized to manufacture a frame.

- S16a approval+summary has no current production ingress: permission creates
  approval with nil summary; elicitation summary produces question. Keep its
  native V2 cell UNKNOWN/real ingress unavailable. Never relabel a question.
- S18 exact two-listed/one-omitted cannot come from the current 16-prompt limit.
  Three yield 3/0; seventeen yield 16/1. Exact S18 is synthetic product coverage,
  native cell UNKNOWN. A supplementary 17-key adapter run proves actual 16/1
  omission and +N arithmetic at the real limit, labelled supplementary.
- An actual contained provider prompt validates fixture assumptions; synthetic
  adapter events never count as J7's real turn/four-provider topology coverage.

## Drawers, evidence gates and source identity

Under the owned-layout grant use the current `drawer.addPane` descriptor with
`parentPaneHandle`, optional terminal content and fresh correlation. Retain the
returned child UUID and before/after topology; this adds a background drawer,
not a selected foreground pane. Native selection/own shell setup is separate.
Source: `IPCLayoutMethodDescriptors.swift`, `AppIPCBuiltInLayoutAndTerminalRegistrations.swift`
and `AgentStudioIPCLayoutAdapter.addDrawerPane`. Use no guessed command.execute
verb. Create two owned drawers and an unrelated comparator pane. Generate E5/E7
from each pane's own holder, then observe main aggregate, drawer-alone isolation,
drawer source labels and actual focus target. Product tests additionally use
colliding message IDs with different forms; exact stored row must settle.

| Evidence fixture | Setup and deciding readback |
| --- | --- |
| Verified live | Actual contained provider hook binds; session.query live + matching provider/session; status must show when known. |
| Verified ended | Same owned sender emits sessionEnd/finishes through the existing lifecycle; query ended, retained Idle · ended shown. SESSION keeps its existing live-only rule. |
| Unbound/none | Fresh pane, no binding; query unbound. E4/E5 may still be present as pane writer. |
| Unverified | J6's owned claim-only fixture with non-unknown Working hook and no verified binding. Retain actual unverified ingress facts as well as query unbound; E3/E7 must be hidden while E4/E5 remain. |

The claim-only path is `session.status` with `paneClaim`, tokenOutcome and full
hook report (`IPCSessionStatusContracts.swift` → unverified adapter →
`UnverifiedPaneStatusRuntime`). Use the Lead's supplied eligible process-chain
fixture/protocol; do not forge or strip a credential to bypass identity admission.
If no such fixture is declared, this negative stays UNKNOWN; an empty unknown
pane cannot replace deliberately non-unknown claim-only status. Also cover
verified-bound unknown status. Direct atom fixtures are supporting tests only.

## Owned offline pre-aged Agent Line

Use a disposable fixture whose line was first written through the real service.
Retain its exact pane, body, writer, updatedAt and declared database location.
The Lead confirms that fixture app's PID retired and supplies the closed database
and exact offline-copy/install grant; WAL/journal sidecars must be absent. This
does not authorize copying production data or changing a running datastore.

```bash
/bin/bash .agents/skills/verify-agentstudio/scripts/offline-pane-line.sh copy \
  "$CLOSED_SOURCE_DB" "$NEW_OFFLINE_COPY" "$PANE_UUID" "$OLD_UPDATED_AT_MICROSECONDS"
```

Choose the integer Unix-microsecond timestamp from the intended capture time
minus eight days; retain calculation, precision and expected age interval. The
helper copies with SQLite backup and changes **only** that line's timestamp in
the new copy; source and other panes remain unchanged. It neither installs the
copy nor creates topology/writer/body. The Lead installs it into that same owned,
retired fixture's declared datastore before launch, retaining the original and
exact load receipt. The loading operation/path must come from that target's
datastore/launcher declaration; absent declaration means old-line runtime UNKNOWN.

After the declared app loads it, require actual matching owner readback and
painted "8 days ago" across applicable consumers, future next-change deadline,
then controlled replace/clear in a separate scene. The script's receipt is
synthetic setup, not no-expiry proof. Never wait eight days, reset system time,
or rewrite the line to refresh a missed age. Source codec: `PaneContextStorage`
uses rounded Unix microseconds; `PaneContextStorage+CurrentValues` reads without
an age-expiry predicate. Real product tests use injected service clock.

## Held receipts and every E5 lifecycle row

Use a nonblocking session-written ask with its exact source/message ID and no
automatic answers reader. After a real UI answer, owner detail must show pending
and controls must disappear from the rebound real view. Only then read
`pane.message.changes` with `after` at the prior cursor. Retain its matching answer
position/nextPosition; do not report the new cursor until pending is captured.
Then call again with that returned cursor and a fresh correlation; actual receipt
becomes confirmed. `IPCPaneMessageChangesParams` has handle/writer/after/correlation;
`PaneContextService+Changes` owns confirmation. CLI `answers` advances its local
cursor; a later call reports it. Wait/answer stdout alone is not confirmation.

For unconfirmed: answer while holding the same sender without reporting cursor,
then end/replace that owned sender through real lifecycle. Read unconfirmed,
Resolved label and absent controls. Keep independent E7 outstanding so status
cannot be optimistically forced to Working. If E3 legitimately changes through
Sessions open-ask reduction, compare it to that current fact, not a fixed value.

| State | Real setup / proof |
| --- | --- |
| Read notice | Use the preserved disclosure/read path from the actual UI; retain the mark-read result and changed detail. Opening/expanding can change unread counts, so capture unread scenes first. No removed Mark read button is invented. |
| Dismissed notice | Actual Dismiss or Dismiss all; row absent. Other asks/prompts/sources unchanged. |
| Withdrawn notice/ask | Sender's `withdraw ID` while retained; exact label, no forbidden actions. |
| Handed back | Actual Dismiss on an open blocking `ask --wait`; service returns handedBack. |
| Dismissed ask | Actual Dismiss on a nonblocking ask; service returns dismissed. |
| Expired | Blocking request with declared deadline; wait for owner's deadline result, then read exact state. No fixed sleep/test-time budget. |
| Stale | Declared owned shutdown/restart fixture crossing appStopping with a retained blocking ask. Require actual stale readback; callerGone withdrawal does not count. No fault/restart without that later grant. |

If the preserved read route, shutdown fixture or unavailable/failure fixture is
absent on the delivered target, record the exact setup gap; retain product-test
coverage without pretending it was a runtime scene. Existing retention applies;
finish resolved scenes before their rows age out. No retention policy changes.

## Oldest ask, live refresh and action destinations

For an oversubscribed card create a known oldest ask then a fixed inventory of
newer live requests across owned sources. Compute inventory/body sizes from the
declared target's detail/source budgets; do not assume 33 asks are admitted
(per-source open-ask cap is 32 at the source inspected). Confirm first-page
omission/truncation metadata excludes the oldest. Only that readback establishes
the case. Card must select/answer that oldest via exact `readMessage`, no paging;
verify its stored answer and unchanged newer requests. Product tests hold reads
out of order/fail refresh/hide/retire; no live injected failure is implied.

Keep card/Messages open; add/close a second or drawer-only provider prompt without
changing the first prompt/E4/E5. Read new prompt-list revision and scoped summary,
then observe updated rows/+N. Omitted-count-only changes use the actual 16 limit;
exact S18 remains synthetic. No reopen/refresh action may repair the observation.
Live age timing uses J5's actual write/UTC/monotonic bounds and owner completion;
controlled minute/hour/day tests remain with the Implementer.

For file actions use harmless existing owned files in two worktrees, then
absolute/outside-worktree and relative source-root/CWD cases. Observe exact file
in bookmarked/default editor, awaited launch outcome and readable feedback.
Stored PR identity must differ from pane cache; press and inspect exact opened
URL. Go to pane selects the actual source, including drawer. Missing editor/file,
retired source and launch failure need declared fixtures or product-test coverage;
no fake success. The adopted opener does not pass a file line; verify row label
without demanding editor line navigation. External effects require their grant.

## Scenario run matrix

Run each applicable journey at V2's 1400/520/390 windows; read independent facts
and measured surfaces before credit. Native popovers need their own originals.
The cumulative notice sequence uses separate IDs and retains unread state.

| Scenario | Setup and expected consequence |
| --- | --- |
| S1 | Verified turnDone then viewed/readied → Idle · ready; no E4/E5; known E6, compact activity/ACTIVE, empty toolbar. SessionStart alone may be unknown. |
| S2 | Valid held turnStart/UserPromptSubmit → Working, no line; no toolbar status. |
| S3 | Successful real line Running tests (3/7), [Now]; no sidebar activity chip; line in unread-free toolbar/card. |
| S4 | Same write [2 min ago], no reopen/input; E6 may separately read Now. |
| S5 | Add info Branch rebased onto main → info 1/unread 1; toolbar chips replace line. |
| S6 | Add done Tests passed (412) → done 1/info 1, unread 2. |
| S7 | Add attention migration-plan notice → needs-you 1/done 1/info 1, unread 3. Notice alone does not invent E3. |
| S8 | Add failure with owned file target → four kind chips, unread 4; real Open file effect. |
| S9 | Single-choice ask red/blue, Needs you · question; one needs-you/unread; actual form at all permitted entries. |
| S10 | Choose blue; pending then confirmed via held cursor. No settled controls. Working/Using blue require separate actual status/line producers. |
| S11 | Four unread, one drawer source, long line [4 min ago], actual 260pt sidebar; main/drawer actions preserve source. Use declared pre-aged fixture for exact ages. |
| S12 | Unbound, no line/messages, E6 9 min → compact 9m/ACTIVE 9 min ago, no status/SESSION/toolbar item. Exact aged activity needs declared fixture. |
| S13 | Pane-written Deploy preview ready [5 min ago] plus info notice, unbound; line/count visible without status/SESSION. |
| S14 | Multiple-choice helper → Swift+BridgeWeb then Submit; exact two-choice result. |
| S15 | New approval CLI → Approve with reason, separate Deny without; exact decision stdout/settlement. |
| S16a/b | E7 approval with/without summary, no E5/unread. b uses actual permission; a real-input cell UNKNOWN under G07. Supplement question-summary with its honest question label. |
| S17 | Six-line failure/no target via actual notify; complete popover body, no target action. |
| S18 | Exact 2 listed/+1 omitted and approval summary: real-input UNKNOWN under G07/G08; labelled synthetic product results, supplementary actual 16/1 only. |
| S19 | Real nonblocking dismissed ask, unconfirmed answer, withdrawn notice, read failure; Resolved, unread zero, correct dimming/forbidden-control absence. |

Also run no-E6, bound-unknown/unverified/ended, all form kinds/locations, every E5
state, loading/unavailable, oldest beyond page, live prompt/clock update and
source-collision cases. Each original gets R1–R10 from the verbatim checklist,
functional/taste judgments and UNKNOWN/N/A reason where applicable. Match a
valid fitting alternative: short text need not ellipsize; whole Agent Line may
hide for insufficient toolbar space; service-owned status can legitimately change.
