# Pane UI outcomes

This is the portable oracle for J4–J7, transcribed from the owner's adopted
2026-10-21 Agent Line/warning decisions, 2026-10-22 card/displaying-agent decisions
and 2026-10-23 ID truncation/copy decision. Use the run's declared applicability;
old screenshots do not change these outcomes. A later owner decision must be
supplied explicitly, not inferred from current rendering. The detailed
measurements live in each journey.

## Drawer and Agent Line

- Drawer controls stay at the same x **and y**, with the same bar height across
  every held J4 state: no message, fresh message, same message aged, long
  200-UTF-8-byte message, and failed protected action.
- Agent Line occupies only the middle gap after the left control group. Its
  message icon is fixed and neutral; message may tail-truncate, but the separate
  age suffix stays complete, all inside 360pt and without moving controls.
- Session status and connection/credential warnings never enter the toolbar.
  The existing git chip is retained by owner choice.
- Agent Line is a message, not hook status. Message age is based on its successful
  write's updatedAt; activity-chip age is based on pane activity. The expanded
  message units and time intervals are specified in J5. Neither clock substitutes
  for the other, and time refresh must work without reopening the card.

## Card: one field per line in every pane

Fixed order: title, state line, message, warning, note, caption-grid fields, git
chips. Only populated optional fields appear. Title and message take natural
one- or two-line height; oversized text tail-truncates at two lines with full
tooltip. State contains hook status, activity-age chip and active glyph together.

Caption fields are REPO, BRANCH, WORKTREE (only if name differs from REPO), CWD
(only if different from worktree root), SESSION (verified live binding only),
PANE (always), with the real no-repo fallback where applicable. Every card uses
one caption width sized for WORKTREE, so values align across panes. Copy buttons
follow values inline at the same small gap. Normal names fit at 420pt and wider.
SESSION and PANE IDs may middle-truncate wherever the full ID does not fit, with
a readable prefix and suffix, full-ID tooltip and always-visible small inline
copy icon right after the value. Oversized path/branch values use
middle truncation and full tooltip. J5 owns the painted-ID and copy checks.
No width-dependent card arrangement, duplicate repo/worktree/CWD values or
reserved blank second line.

SESSION displays provider plus reference but **copies only sessionRef.value**.
PANE copies the full pane UUID. An AX value/tooltip does not prove readable
pixels or actual clipboard content. Git chips remain last. Required card widths
are 420, 520, 640, 780 and 1000pt; J5/shared quality specifies reaching/measuring.

## Warnings

Quiet hook/message/title fallback succeeds without creating or clearing a
credential refusal. A real protected failure records the actual refusal.
Unrelated failures must not be relabelled credentials. Retain original outcomes,
ordering, retirement and verified-session suppression.

The **current policy (#57)** is message-only Agent Line with its own age and
card-only warnings. For a target declared with it, plain warning belongs in the **card only**:
no warning/error row in compact/expanded sidebar or drawer. It never exposes raw
reason codes or question-mark chips. A later quiet success retains the entire
refusal (including count/time) in the same holder. A verified binding can suppress
the warning; use an unverified fixture for the placement positive. Earlier
warning-on-failure targets expected row **and** card warnings; select that
historical policy only when explicitly declared for the run.

## The pane displaying the agent

Every pane that displays a live agent shows **that agent's status**. Provider
execution host and displaying terminal may differ. Four setups are foreground,
**(b) remote app-server**, Claude daemon/attach and Cursor. In slot (b), a Codex
app-server executes the agent and the pane holds only `codex --remote`.
A standalone app-server started from a debug pane **fills (b) and counts toward
N** when J7's phase criteria pass. Report it as
**"(b) remote app-server — Router wrapper not exercised"**, including that phrase in the coverage line. Try an
isolated Router service first only when its CLI help supports it; the standalone
route preserves the host/viewer split but leaves Router's wrapper unobserved.
J7 records the actual host variant, hook recipient and outcome rather than replacing remote
or daemon evidence with foreground evidence. Known missing attribution is a
FAIL when safely observed; an unsafe or unauthenticated run is UNKNOWN with its
specific prerequisite. Test status/message/title after a real turn in each.

During a real turn expect Working; after a successful stop expect **Idle · done**,
then **Idle · ready** when acknowledged/readied. A real outstanding approval or
provider question expects **Needs you · approval/question**. Source owners: provider hook projections
in `Sources/AgentStudioIPCClientCore/ProviderHooks/`, status reduction in
`Sources/AgentStudio/Features/Sessions/Models/SessionStatusState.swift`, and
`PaneContextLineActionSpecs.sessionStatus` for the displayed labels. J7 defines
the bounded stimulus and phases required for its coverage count.

Source map for the adopted presentation: card/context in
`Sources/AgentStudio/App/Panes/Hosting/ManagementPaneIdentityStrip.swift` and
`Sources/AgentStudio/Core/Views/Panes/PaneManagementContext.swift`; message and
session line projection in `Sources/AgentStudio/Features/RepoExplorer/Models/`.
These sources help locate the real route; they do not override the outcomes.
