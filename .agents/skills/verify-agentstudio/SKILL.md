---
name: verify-agentstudio
description: "Use when verifying a declared Agent Studio debug build's pane UI, visual quality, displayed-agent status across foreground, remote Codex app-server (Router or standalone), Claude daemon or Cursor setups, drawer toolbar, ⌘R card, credential warnings, or terminal lifecycle and restore. Not for product repairs, builds, performance acceptance, or releases."
---

# Verify Agent Studio

Observe one declared debug build through the surface its user sees. A launcher
handoff, a CLI receipt and a screenshot prove different things. Keep the target,
action and resulting visible state together. This skill grants no commands or
access beyond the current commission.

Choose the oracle from the declared source; reuse is not a new run. Recheck
permissions on the surface executing the run. Static checks and old images do
not prove a live wrapper. Every observation returns PASS, FAIL or UNKNOWN;
INVALID, inconclusive, NOT RUN, blocked and repaint-spanned are UNKNOWN reasons.
An independent observed failure still wins over an UNKNOWN sub-observation.

## Start here

1. Take the full commit, prepared build path, debug code and fixture from the
   Lead's declaration. Confirm worktree/branch/HEAD using `git status` and
   `git log`. A file's existence does not attest its binary's source commit.
2. Check the commission's command/write boundaries. This recipe's final home is
   `.agents/skills/verify-agentstudio/`; `.claude/skills/verify-agentstudio` is
   only a relative link to it. Authoring copies are not live run roots.
   Installed instruction directories are read-only for Router workspace sessions.
   Use the commission's granted runtime evidence directory; if none is granted,
   request one before a live run.
3. Use only the declared `com.agentstudio.app.debug.d<code>` and its isolated
   `~/.agentstudio-db/<code>` data/zmx/socket roots. Operate only processes this
   run launched or the Lead explicitly handed over. Refuse stable, beta, an
   unowned process, a changed pin, an escaped path or a permission/TCC prompt.
   Never `pkill AgentStudio`.
4. Preflight process inspection before launch. Preserve stderr and status.
   The launcher contains `pgrep ... || true`; its empty result can be a swallowed
   sandbox error. Empty output alone proves neither absence nor ownership.
   Do not change transport or use a direct launch to bypass a denial.
5. IF running J4–J7, load `references/pane-proof-setup.md` and return the current
   binary/CLI provenance, process/window receipt, IPC route, observation grant
   and fixture ownership. A missing prerequisite leaves the journey UNKNOWN.
   One operator drives states, the capture owner saves originals, and the
   Verifier opens and measures them before acknowledging the next state.
6. IF running a visual journey (J2, J4, J5, J6, J7), load
   `references/visual-quality.md` and return every state's supported-width frames,
   quality judgments and functional/taste/combined verdicts under that procedure.
7. IF running J4–J7, load `references/pane-contract.md` and return the applicable
   portable outcomes before driving; ignored scratch briefs are not prerequisites.

## Journey index

| Journey | Entry and exact procedure | Observation that decides it | Driver |
| --- | --- | --- | --- |
| J1 — isolated lifecycle | MUST load [debug-launch.md](references/debug-launch.md); return the declared pin, process preflight, background launch, authenticated reads and owned quit. Entry: `mise run run-debug-observability -- --detach --skip-build --build-path "$BUILD_PATH"`, with the documented escrow/watch-folder environment. | Declared debug executable, fresh marker and background identity; successful `pane.list`/`window.list` readbacks; that owned PID confirmed retired after bundle-id quit. | `scripts/debug-lifecycle.sh` |
| J2 — Panes row | MUST load [panes-row.md](references/panes-row.md); return separate declared build/oracle commits, compatible stimuli, AX labels, PID frames, whole-chip/row differences and visual judgment. | Working breathes, monitoring rotates, other glyphs stay still; chip never pulses, recency updates. Equal chip AX labels permit exact stillness checks; changed labels defer chip/text, UNKNOWN after three repaint-spanned bursts. Judge glyph every burst; Reduce Motion stops it; branch lines remain correct. | `scripts/panes-row.sh`, `scripts/frame_diff.py` |
| J3 — cold restore | MUST load [cold-restore.md](references/cold-restore.md); return declared restore build, explicit one-session fault grant, saved text, same pane/stored session, owned quit, isolated list/kill, relaunch and replay. | Restore notice → saved text → restart marker → usable fresh shell, in the same pane (Spec 11 / Program Design 28). A warm reconnect cannot satisfy this. | `scripts/cold-restore.sh` |
| J4 — drawer toolbar | MUST load `references/drawer-toolbar.md` and return held states, glyph x/y, bar height, cap and text/suffix observations. | Fixed groups/bar; message uses middle gap. Fixed message icon + truncatable text + complete age suffix inside 360pt. No toolbar status/warning. | `scripts/window-frame.sh render/resize`, `scripts/toolbar_geometry.py` |
| J5 — ⌘R pane card | MUST load `references/pane-card.md` and return five-width layout/identity/copy results and separate one-open-card clock evidence. | Title → state → two-line message → warning → note → caption grid → git chips, one field per line at every width. Verified SESSION copies only ID; PANE always. SESSION and PANE IDs may middle-truncate with an always-visible inline copy icon. Distinct clocks. | `scripts/window-frame.sh render/resize` |
| J6 — credential warning | MUST load `references/credential-warning.md` and return unbound receipts, target-specific placement and exact refusal comparison. | Quiet success does not create/clear refusal. Genuine failure warns card only under current policy, never toolbar. Historical row/card policy requires an explicit declaration. | `scripts/window-frame.sh render/resize` |
| J7 — agent in its displaying pane | MUST load `references/agent-setups.md` and return four owned setup results, hook recipient, real-turn row/card status/message/title and N-of-4 coverage with its required host label. | Every displaying pane shows its live agent's status: foreground, (b) remote app-server, Claude daemon/attach, Cursor. Standalone counts in (b), labelled "Router wrapper not exercised". Unsafe routes UNKNOWN with blocker; missing status FAIL. | Granted provider operator; `scripts/window-frame.sh render/resize` |

## Driver entry points

Run from the repository root; the caller supplies the runtime write grant.

```bash
/bin/bash .agents/skills/verify-agentstudio/scripts/debug-lifecycle.sh --help
/bin/bash .agents/skills/verify-agentstudio/scripts/debug-lifecycle.sh --dry-run
/bin/bash .agents/skills/verify-agentstudio/scripts/debug-lifecycle.sh --self-test
/bin/bash .agents/skills/verify-agentstudio/scripts/panes-row.sh --help
/bin/bash .agents/skills/verify-agentstudio/scripts/panes-row.sh --dry-run
/bin/bash .agents/skills/verify-agentstudio/scripts/panes-row.sh --self-test
/bin/bash .agents/skills/verify-agentstudio/scripts/cold-restore.sh --help
/bin/bash .agents/skills/verify-agentstudio/scripts/cold-restore.sh --dry-run
/bin/bash .agents/skills/verify-agentstudio/scripts/cold-restore.sh --self-test
uv run --with pillow --with numpy python -I .agents/skills/verify-agentstudio/scripts/frame_diff.py --help
uv run --with pillow --with numpy python -I .agents/skills/verify-agentstudio/scripts/frame_diff.py --self-test
/bin/bash .agents/skills/verify-agentstudio/scripts/window-frame.sh --help
/bin/bash .agents/skills/verify-agentstudio/scripts/window-frame.sh --self-test
/bin/bash .agents/skills/verify-agentstudio/scripts/pane-chrome.sh --help
/bin/bash .agents/skills/verify-agentstudio/scripts/pane-chrome.sh --self-test
uv run --with pillow --with numpy python -I .agents/skills/verify-agentstudio/scripts/toolbar_geometry.py --self-test
```

The shell drivers expose one step at a time. They never retry a denied action,
activate the app, or quit/kill automatically during error handling. Zero status
means that step collected its result; it is not a whole-journey verdict. Read
CLI JSON, capture success fields and the actual visible result. Permission for
each individual effect must already exist.
Author checks may use the same relative paths below the assigned package root;
they must not install or launch as a side effect.

## Readiness and health

J1 records a launch ownership receipt: PID, executable, declared source/build,
marker, process start, bundle identity and debug roots. Before every action,
compare it with the current launcher handoff and live process. `health` performs
read-only `pane.list` and `window.list`; inspect the responses and terminal
readiness. `terminal.snapshot` exports lifecycle/renderer metadata, **not output**.
`terminal.send` means input accepted, not command completed. For a shell stimulus,
use the typed `terminal.wait(titleChanged, afterSequence:)` route plus its
correlated title and visible content. No sleeps or polling for readiness.

For J4–J7 static layout/text, use `window-frame.sh` through the existing escrow
CLI, including while locked. Establish the state through its owner fact first;
then the consumer waits 3 s after each change and takes **one** `window.render`.
This observed settle is separate from readiness. The renderer captures the
current frame, including animations in flight; it adds no wait. A stale or
in-flight result after the settle is a failure, not a reason for a longer wait,
retry, refresh or reopen. Match asynchronous fields such as SESSION against
that pane's owner fact taken immediately before capture. Metadata locates crops;
only the decoded PNG establishes painted text and geometry.

The fidelity gaps and optional native route are in shared setup. Keep J2 motion,
vibrancy, native tab/titlebar and final on-screen appearance with Peekaboo when
the screen is already unlocked and that route is granted. Never unlock it.

## Evidence and cleanup

Keep exact commands/statuses, stdout/stderr, original frames, AX output,
pin/ownership receipt, region coordinates and observations in the run's granted
evidence directory (for example `tmp/verify-agentstudio/<run>/`). For every app
render, retain request/result, before/after lock probes, UTC/monotonic capture
bounds, owner facts, source path and evidence path. Move each received PNG into
evidence using the wrapper; a path without an opened image proves no pixels.
Keep installed skill files read-only.
Never print or commit escrow contents. Keep runtime evidence outside the skill.

Post each actual denial with its exact command, verbatim error and exit status
to the commission's access/coordination thread, or return it to the Lead when
no such destination is supplied. An unattempted
dependency, missing build or needed grant is different from an OS denial. Post coverage and
artifact paths on the execution thread and message the Lead with the handback.

Run `window-frame.sh cleanup RUN_DIR` to recover interrupted transfers from
recorded paths before retiring the fixture when possible. It can finish those
filesystem transfers after retirement without calling the app. Preserve and
report any unresolved transfer; never sweep the app's renders directory or
remove an unreceived file. This cleanup grants no app quit.

Quit only the verified owned debug bundle id through J1, then confirm PID
retirement. A quit request alone is not retirement; an inspection error is not
absence. Hold an uncertain or unowned process. Preserve evidence after cleanup
and name any owned process left running. J3's one-session kill is its deliberate
fault step, never generic cleanup. Do not remove pane records, snapshots or app
data to tidy a run. Product tests, performance, CI, release and acceptance remain
separate, unclaimed proof layers.

For J4–J7 return PASS / FAIL / UNKNOWN separately per observation, with commit,
binary and CLI provenance, PID/window, fixture state, original PNG paths and
measurements. Fixed icon geometry does not prove text was painted. A full AX
label does not prove the full ID was visible. Record the actual capture owner;
an Implementer's description of an image is not evidence. Preserve a known-bad
calibration, and keep time/credential journeys UNKNOWN until their real path ran.
Return the shared quality report as specified by `references/visual-quality.md`. If offered
product tests are missing real-path coverage, report that gap separately to the
Lead; supporting test evidence is not a substitute for this journey's verdict.
Done when every commissioned observation has a verdict/reason and retained
evidence, shared quality is returned, and owned cleanup or an explicit held-state
owner is recorded. This completes the observation, not product acceptance.
