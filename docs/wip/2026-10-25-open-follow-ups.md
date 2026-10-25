# Open follow-ups

The open follow-up work. Each item says what it is, what we know, and the next step.

## Needs an owner decision

### Pane context display: status and Agent Line

The same pane tells different stories on different surfaces. The ⌘R card can say "Needs you · question" while the sidebar row says "Idle · ready", and the question's text appears nowhere. Ages float away from the text they date, and the Messages popover cuts off its buttons.

- **State:** designed, not built. The requirements, the specification and an HTML storyboard of realistic renders are drafted. Their artifacts are not included in this checkout.
- **Next:** Program Design, independent review, plan, build, then native frames checked at three widths against the storyboard.

### Codex restore: binding shows ended after a successful resume (J2-Codex)

After an app restart, restore resumes a Codex pane into its exact conversation. But the pane's session binding stays *ended* until the person sends the next message.

- **Why:** Codex holds its resume `SessionStart` hook until its next turn. Foreground process looks record evidence only; by design they never reopen or end a binding.
- **Decision:**
  - Should a resumed agent's live foreground process count as a live binding before its first hook?
  - Or should the pane say "resumed, waiting for the agent" until that hook arrives?
- Claude restores cleanly; this is Codex-only.

### Agent status model (#68)

How a pane's agent status is derived, and what happens when a pane's IPC credential is not recognized. Today, a protected call with an unrecognized credential requires the owner to restart that pane's shell. Line/title and hook-status reporting can continue through their existing-pane fallback without a recognized token. Parked while the owner thinks it through.

### Parked designs

These are named but not designed:

- **Conversation ↔ pane identity:** which server-side conversation belongs to which pane. It is kept separate from process identity and from which pane is viewing it.
- **Restore for background agents:** agents running under codex-router or Claude and ACP background sessions, viewed through a pane.
- **Direct zmx socket control:** controlling a session through its socket instead of through the `zmx attach` client. A side connection's resize is ignored while another client leads, so direct resize control needs an explicit leadership or attachment arrangement.
- **Tooltips:** the routes for oversized titles, paths and branches. Needs scoping.

## Bugs

### Reattached panes come back narrow

After an app restart, some reattached Codex panes draw much narrower than their pane.

**What we know:**

- Ghostty starts an embedded surface at 800×600 and opens the PTY with that initial grid, before the app's first size reaches it.
- The app's first size commit is rejected until its view joins a window, because there is no content scale yet. A correction is scheduled when the view joins a window.
- zmx resizes the inner PTY only for the leading client, and it discards the `TIOCSWINSZ` result.

**What's open:** the cause is unknown. In ranked order:

1. the narrow bootstrap plus a missed correction later;
2. wide PTYs with a stale Codex repaint;
3. hidden or drawer reveal geometry.

**Next:** run the deciding experiment on a debug app with a non-production `ZMX_DIR`. It restores two PTYs and measures how the width converges at each edge: Ghostty grid, outer PTY, attach `Resize` payloads, daemon leadership, inner PTY.

### Review content may stay on "loading" (#89)

Selected Review content can remain loading, and the producer's terminal outcome is not established.

- **What the evidence can't tell:** whether the content was never requested or was requested and never delivered.
- **Cause:** unknown. This may be a real product bug, not only a test problem.
- **Next:** add correlated telemetry for the selected-content producer: request, native terminal outcome, worker application and page render.

### Sidebar workload and the Show Pinned toggle (#72)

In `scripts/verify-sidebar-performance-workload.sh`, `toggle_panes_shows_pinned_pair` dispatches `togglePanesShowsPinned`. It then requires a Panes projection newer than the one before the toggle.

- **Decide which side is wrong:**
  - Does the app correctly equal-suppress an unchanged projection? The fixture has no pinned panes.
  - Or is the workload expecting a publication that shouldn't happen?

## Test reliability

### Chromium sometimes hangs on launch (#77)

Under heavy machine load, headless Chrome for the BridgeWeb E2E lane can fail to finish launching. Its child process blocks in a fork-time lock wait.

- **What exists today:** the harness owns the browser host process and stops it at a bound, so a hang fails the lane instead of hanging the run.
- **What's not fixed:** the launch hang itself.
- **Next:**
  1. Confirm the signature: sample the stuck child and record the Chrome version.
  2. Choose a fix:
     - retry only the browser launch once after stopping the hung host (needs owner approval);
     - pin a Chrome build without the hang;
     - reduce load on the affected host.

### Dev-server annotation draft 404 after a host restart (#82)

`BridgeDevelopmentAnnotationHTTPRoutingTests.annotationDraftSurvivesDevelopmentHostRestart` can get HTTP 404 for an annotation draft after the development host restarts.

- **Next:** find whether this is a test synchronization gap or a dev-server restart race, and fix it at its owner.

### Grandfathered polling waits (#78)

172 existing test waits in 75 files are grandfathered under `agentstudio_no_polling_wait_in_tests`, in `Tools/AgentStudioArchitectureLint/architecture-debt-ledger.tsv`. A wait that yields or polls instead of awaiting an event depends on machine speed, and it can starve on 3-core CI runners.

- **Plan:** classify every site:
  - (A) a fact exists;
  - (B) test support can supply the wait;
  - (C) a production signal is needed, which is an owner decision;
  - (D) the test isn't worth keeping.

  Then convert A and B in batches, removing ledger rows in the same PR.

## Measurement

### Restore cost with many panes

Measure the existing six restore-cost phases with 15–20 panes.

- **Next:** run a debug-app restore on the M4. Read the diagnostics through the observability verifier, not JSONL.

## Code cleanup

### Two readers of process arguments (`KERN_PROCARGS2`)

Two separate code paths read a process's argument list with `sysctl(KERN_PROCARGS2)`. They use different strategies:

| Reader | Strategy |
| --- | --- |
| `DarwinColdStartObserverSyscalls.singleProcessArgumentsRead(pid:)` in `ColdStartObserverSyscalls.swift` | One data read into a zero-filled buffer sized by the cached `KERN_ARGMAX` (falling back to 256 KiB). `readProcessArgumentsBuffer` retries failed reads. |
| `DarwinProcessChainExecutableReader.argumentZero(of:)`, using `DarwinProcessChainArgumentsReader`, in `DarwinProcessChainExecutableReader.swift` | Queries the size, caps it at `ARG_MAX`, fetches that capacity, then queries the size again. It also compares the fetched byte count rounded to an `Int32` boundary with the original size. A mismatch returns `nil`, rejecting a possibly raced read. |

Both pass the bytes to the shared `ProcessArgumentsBufferParser`. The cost is two answers to the same kernel question: a fix to one, such as a new failure mode or a size rule, won't reach the other.

**Next:**

1. Pick one reader and one owner in `Core/RuntimeEventSystem/Runtime/`.
2. Keep the consistency check.
3. Move both callers to it.

## Watching

### Production crash evidence

If the production app crashes again, read the scan scheduler fault breadcrumb and the Ghostty crash capture together.
