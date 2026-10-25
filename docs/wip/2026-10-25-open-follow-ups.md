# Open follow-ups

Open work as of 2026-10-25, on `main` at `e5da452ce`. Each item says what it is, what we know, and the next step. Numbers like #77 are the Lead's tracking numbers, not GitHub PRs.

## Needs an owner decision

### Pane context display: status and Agent Line

The same pane tells different stories on different surfaces. The ⌘R card can say "Needs you · question" while the sidebar row says "Idle · ready", and the question's text appears nowhere. Ages float away from the text they date, and the Messages popover cuts off its buttons.

- **State:** designed, not built. The requirements, the specification and an HTML storyboard of realistic renders are drafted under `docs/specs/2026-10-24-pane-context-display/`. That folder is not committed yet.
- **Waiting on:** owner approval of the storyboard, plus three open choices:
  1. whether an approval has a reason text box;
  2. `?` or `⚑` as the question mark;
  3. how the card avoids counting the same item twice.
- **Next:** after approval, Program Design, independent review, plan, build, then native frames checked at three widths.

### Codex restore: binding shows ended after a successful resume (J2-Codex)

After an app restart, restore resumes a Codex pane into its exact conversation. But the pane's session binding stays *ended* until the person sends the next message.

- **Why:** Codex holds its resume `SessionStart` hook until its next turn. Foreground process looks record evidence only; by design they never reopen or end a binding.
- **Decision:**
  - Should a resumed agent's live foreground process count as a live binding before its first hook?
  - Or should the pane say "resumed, waiting for the agent" until that hook arrives?
- Claude restores cleanly; this is Codex-only.

### Agent status model (#68)

How a pane's agent status is derived, and what happens when a pane loses its IPC token. The current default for a lost token is restarting the process. Parked while the owner thinks it through.

### Parked designs

These are named but not designed:

- **Conversation ↔ pane identity:** which server-side conversation belongs to which pane. It is kept separate from process identity and from which pane is viewing it.
- **Restore for background agents:** agents running under codex-router or Claude and ACP background sessions, viewed through a pane.
- **Direct zmx socket control:** controlling a session through its socket instead of through the `zmx attach` client. Today a side connection is ignored while an attach client leads, so real direct control means replacing attach.
- **Tooltips:** the routes for oversized titles, paths and branches. Needs scoping.

## Bugs

### Reattached panes come back narrow

After an app restart, some reattached Codex panes draw at about 68 of 175 columns.

**What we know:**

- Ghostty starts an embedded surface at 800×600 and spawns the PTY before the app's first size reaches it.
- The app's first size commit is rejected until its view joins a window, because there is no content scale yet.
- zmx resizes the inner PTY only for the leading client, and it ignores the ioctl result.

**What the evidence rules out and leaves open:**

- A stale second attach client is ruled out.
- The cause is unknown. In ranked order:
  1. the narrow bootstrap plus a missed correction later;
  2. wide PTYs with a stale Codex repaint;
  3. hidden or drawer reveal geometry.

**Next:** the deciding experiment, run on a debug app with a non-production `ZMX_DIR`. It restores two PTYs and measures how the width converges at each edge: Ghostty grid, outer PTY, attach `Resize` payloads, daemon leadership, inner PTY.

### Review content may stick on "loading" (#89)

In a CI WebKit run, the selected Review content wait never got its content. The entry sample, taken once when the wait started, read `loading`, generation 2, 0 lines, after metadata publications had arrived.

- **What the evidence can't tell:** whether the content was never requested or was requested and never delivered.
- **Cause:** unknown. This may be a real product bug, not only a test problem.
- **Next:** add correlated telemetry for the selected-content producer: request, native terminal outcome, worker application and page render. Then catch it again.

### Sidebar workload stops at the Show Pinned toggle (#72)

`verify-sidebar-performance-workload.sh --baseline` passes the first Panes gate. It then stops in `toggle_panes_shows_pinned_pair`, because no Panes projection newer than the initial one arrives after `togglePanesShowsPinned`.

- **Decide which is wrong:**
  - Does the app equal-suppress an unchanged projection? The fixture has no pinned panes.
  - Or does the workload expect a publication that shouldn't happen?

## Test reliability

### Chromium hangs on launch under heavy load (#77)

Under heavy machine load (load average about 30–40), headless Chrome sometimes never finishes launching for the BridgeWeb E2E lane.

- **First seen:** on sunclaw, where its child sat in a fork-time mutex wait (`xpc_atfork_child`). Later seen once on the M4 at a similar load.
- **What's already fixed:**
  - An earlier fix gave Chromium acquisition an exit: an owned browser host the harness can stop. A hang now fails at its bound instead of hanging the whole gate.
  - Later fixes made the acquisition tests themselves deterministic.
- **What's not fixed:** neither change removes the launch hang itself.
- **Next:** diagnose it on sunclaw:
  - Chrome version;
  - whether the fork deadlock reproduces;
  - how it depends on load.

  sunclaw has also been up for weeks with heavy swap, and a reboot there is the owner's call.

### Dev-server annotation draft 404 after a host restart (#82)

`BridgeDevelopmentAnnotationHTTPRoutingTests.annotationDraftSurvivesDevelopmentHostRestart` failed once under load with HTTP 404, "annotation projection cumulative credit through 1". It has passed everywhere else.

- **Next:** find whether this is a test synchronization gap or a dev-server restart race, and fix it at its owner. Never rerun it to green.

### Grandfathered polling waits (#78)

172 existing test waits in 75 files yield or poll a fixed number of times. They pass on a 16-thread Mac and can starve on 3-core CI runners. They are listed in `Tools/AgentStudioArchitectureLint/architecture-debt-ledger.tsv` under `agentstudio_no_polling_wait_in_tests`.

- **Plan:** classify every site:
  - (A) a fact exists;
  - (B) test support can supply the wait;
  - (C) a production signal is needed, which is an owner decision;
  - (D) the test isn't worth keeping.

  Then convert A and B in batches, removing ledger rows in the same PR.
- **Branch:** `test/event-waits-not-turn-counts`.

## Measurement

### Restore cost with many panes

The session-restore work added restore cost diagnostics in six phases. They have never been read from a run with 15–20 panes.

- **Next:** run a debug-app restore with 15–20 panes on the M4. Read the diagnostics from the observability verifier, not JSONL, and record where the time goes.

## Code cleanup

### Two readers of process arguments (`KERN_PROCARGS2`)

Two separate functions read a process's argument list from the kernel with `sysctl(KERN_PROCARGS2)`. They use different strategies:

| Reader | Strategy |
| --- | --- |
| `ColdStartObserverSyscalls.singleProcessArgumentsRead` (`ColdStartObserverSyscalls.swift`) | One read into a zero-filled buffer of `KERN_ARGMAX` bytes (about 1 MiB), with retries. One read avoids the size-then-fetch race. |
| `DarwinProcessChainArgumentsReader` (`DarwinProcessChainExecutableReader.swift`) | Asks for the size, fetches exactly that size, then asks again. A changed size means the process exec'd in between. |

Both pass the bytes to the shared `ProcessArgumentsBufferParser`. Nothing is broken today. The cost is two answers to the same kernel question: a fix to one, such as a new failure mode or a size rule, won't reach the other.

**Next:**

1. Pick one reader and one owner in `Core/RuntimeEventSystem/Runtime/`.
2. Keep the exec-race check.
3. Move both callers to it.

## Watching

### Production crash evidence

If the production app crashes again, read the scan scheduler fault breadcrumb and the Ghostty crash capture together.

Three older AgentStudio crash reports, from 2026-10-17 and 2026-10-18, are no longer in `/Library/Logs/DiagnosticReports`. The cause is unknown. Their absence doesn't mean there were no crashes.
