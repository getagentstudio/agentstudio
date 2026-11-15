# Shared setup for J4–J10

This reference owns the debug identity, IPC and capture mechanics. Inputs are
the Lead's declared commit/build/CLI, debug code, PID/start/marker, workspace
window UUID, owned proof pane, granted evidence directory and operator/capture roles. Return
that receipt, successful health reads and each missing prerequisite before a
journey starts. It grants no launch, build, app action or permission change.
For J7, also require `agent-setups.md`'s provider-host containment receipt before
starting a real turn. A debug pane/client does not isolate a remote agent host.

The Lead's **observation grant** names the debug PID/start/bundle, workspace
window UUID, owned panes, sole state-driving operator, capture owner, permitted
mutations/evidence path and hold/cleanup owner. Keep its message reference.
App renders support static layout/text observations while locked; no native
input or Screen Recording is needed for that route. A separate native route
needs its own capture/input grant and an already unlocked screen. Neither an
unlocked screen nor another task's grant supplies this assignment.

## Bind one target

Record the worktree/branch/clean HEAD, prepared executable and bundled executable
provenance, bundle ID, marker, full CLI path/hash, PID and start time. Compare
source dependencies again after a main merge. A matching source file does not
attest an installed binary. Keep one debug identity per worktree: if its app is
already running, adopt it only under the Lead's declaration or wait for its
owning launcher to retire that exact incarnation. Changing debug codes to evade
the already-running guard is not a recovery route.

Use locale-stable guards; compare the complete strings with the saved receipt:

```bash
LC_ALL=C /bin/ps -p "$PID" -o comm=
LC_ALL=C /bin/ps -p "$PID" -o lstart=
```

Normalize leading/trailing whitespace in `lstart`, not its date fields. Stop on
a changed executable/start/window/marker, denied inventory or ambiguous PID.
Obtain the workspace window UUID from the owned `window.list` response. It is
not Peekaboo's native numeric window ID. Only for a separately granted native
capture, confirm that numeric ID with `peekaboo window list --pid "$PID" --json`.
Never target the app by name.

## Escrow-only IPC outside the fixture shell

The owning launcher supplies an escrow path and a CLI from the declared build.
Keep the file private; never display its contents or put resolved credentials in
commands, reports or screenshots. The corrected wrapper is:

```bash
env -u AGENTSTUDIO_PANE_TOKEN -u AGENTSTUDIO_WORKSPACE_ID \
  -u AGENTSTUDIO_IPC_SPOOL_DIR -u AGENTSTUDIO_PANE_ID \
  -u ZMX_DIR -u ZMX_SESSION -u ZMX_SESSION_PREFIX \
  -u AGENTSTUDIO_IPC_SOCKET -u AGENTSTUDIO_CLI \
  AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW="$ESCROW" "$CLI" system.identify
```

Use that same wrapper for `window.list`, `pane.list`, `command.list` and every
owned operator call. Do not add `--socket`, a metadata endpoint or an inherited
`AGENTSTUDIO_IPC_SOCKET`: explicit endpoint selection disables the escrow read.
This is source-backed by `AgentStudioIPCClientDiscovery.debugEscrowCredential`
in `AgentStudioIPCClientConfiguration.swift`, called by `parseGlobal` in
`AgentStudioIPCClientArguments.swift`.
Keep health JSON/statuses and check the declared runtime, version and pane.
Failure is an access/setup gap, not permission to switch auth or touch production.

The fixture shell is different: it uses its own declared pane environment and
the pinned CLI, so hooks/line/notify actually originate in that owned pane.
Only a deliberately invalid fixture string or removed token is used in J6;
the operator's escrow identity is not the credential under test.

Line writes take one of two declared routes, preserving the pane's own identity:

- **Fixture shell:** run the pinned `"$CLI" line "<text>"` or `"$CLI" line --clear`
  inside the owned pane's environment; retain actual stdout/stderr and exit-0
  applied completion. For message age, bracket that CLI child with precise UTC
  and monotonic bounds.
- **Foreground hold:** only when the commission supplies this fixture protocol,
  keep its foreground holder alive and send `line <text>` to its stdin through
  `terminal.send`. The holder runs the pinned line CLI as a child in its own
  pane environment and emits `hold.line` with text, exit, `t_before`, `t_after`,
  `mono_before` and `mono_after`. Require the matching exit-0 fact; acceptance of
  terminal input is not completion. A `hold.ended`/driver failure ends the wait
  as failed or UNKNOWN. Do not background the holder: that can lose the verified
  live binding. This fixture protocol is not a new app CLI command; use only its
  declared operations, including a clear operation if one was supplied.

Do not substitute an operator-escrow `pane.line.set` for a pane-origin writer.
A synthetic line/hold fixture is useful for J4/J5 but does not establish J7's
real agent turn or provider-host containment.

## Command routes and state completion

Read the current `command.list` descriptors before constructing requests. Use
`command.execute` with `commandId`, typed `arguments` and a fresh
UUIDv7 correlation, using the returned workspace window/tab/pane selectors:

| Entry | Typed scope / effect to confirm |
| --- | --- |
| `newTab` | `newTab` arguments: workspaceWindowId and optional launchDirectory. Save before/after pane lists; own only the newly created tab/pane. |
| `focusPane` | `pane` arguments: workspaceWindowId and paneSelector. Confirm the requested pane becomes the command target; this is pane selection, not permission to activate the macOS app. |
| `toggleManagementLayer` | Window-scoped command. Select the proof pane first; call once to open its card and confirm visible state. |
| `managementLayerExit` | Window-scoped command. Close the card explicitly instead of guessing a second toggle's starting state. |
| `closeTab` | `tab` arguments: workspaceWindowId and tabId. Close only the owned disposable fixture after its evidence is retained and no remaining journey needs it. |
| `terminal.send` | A separate IPC method, **not** a command.execute verb: handle, exact input and correlationId. Accepted input is not command completion. |

`IPCCommandArguments+Records.swift`, the current command IPC specs and
`IPCTerminalMethodDescriptors.swift` own these shapes. Use `--json` with the
complete typed request; obtain dynamic IDs from the successful readbacks, never
copy a historical ID. Keep request/result correlations. Wait for the fixture
command's own result file or
correlated terminal fact and read the actual pane/session/line state. The
operator holds each state unchanged until the Verifier acknowledges its capture.

Hooks need complete provider payloads. For a declared Claude/Codex
UserPromptSubmit fixture this includes `session_id` and
`hook_event_name:"UserPromptSubmit"`; the hook command name alone is not the
payload. A parse failure/undecodablePayload is a fixture failure, not proof of a
Working state. Use current provider fixtures and valid source/turn identities.

## Capture the live content view

Use the run's J1 receipt and the declared debug CLI through `scripts/window-frame.sh`.
The wrapper rechecks ownership and uses the existing escrow route without a
socket override. Run from the repository root with a new label per operation:

```bash
/bin/bash .agents/skills/verify-agentstudio/scripts/window-frame.sh \
  render "$RUN_DIR" "$WORKSPACE_WINDOW_UUID" card-fresh "$PANE_UUID"
```

First establish the requested management/line/session state through its existing
owner facts. Hold it unchanged. After each state change the wrapper waits 3 s,
then optionally records `session.query(handle: PANE_UUID)` immediately before
calling `window.render` **once**. It retains clocks, CLI result/error/status and
before/after lock probes, records `image.path` before transfer, and moves the
unchanged PNG into `RUN_DIR/window-frames/LABEL/frame.png`. `receipt.json` keeps
both the original source path and evidence path. Zero exit means collection,
not a visual pass or proven locked state. A timeout/refusal ends that attempt;
never rerender to conceal it.

Record host/build/OS alongside the raw `ioreg -n Root -d1 -a` probes. Confirm once
that `CGSSessionScreenIsLocked` is true in a known-locked state; without that
calibration or with missing/mixed probes, lock state is UNKNOWN. Nobody locks or
unlocks the screen on the owner's behalf. Opening the decoded PNG personally
remains required. A blank, stale or in-flight frame after the 3 s settle is a
failure; no longer wait, retry, private SwiftUI call or refresh repairs it.

`surfaces[]` is an array of locators: sidebar, tabContent, paneLeaf, paneToolbar,
paneCard, toolbarControl, agentLine and sidebarRow. Keep repeated identifiers.
Frames are visible intersections in the PNG's **top-left point space**; multiply
x/y/width/height by `image.scale` to obtain original-pixel crop coordinates.
Use `image.imagePointSize` and bitmap dimensions for image mapping;
`contentSize` is the separately reported live content size. Hidden/fully clipped
regions are excluded; `clipped` flags partial intersections. `paneId` and
`identifier` are optional. Toolbar controls/agent lines require a unique owning
pane toolbar; missing/ambiguous attribution stays UNKNOWN, never guessed from
array order. A sidebar row's identifier is opaque binding identity, not its
painted label; it can distinguish reused rows without proving their text.
The locators cannot pass pixel, truncation, spacing or age oracles.

The render draws the **live AppKit content hierarchy**, with real state/layout.
It is not a mock and does not use WindowServer composition. It can show the
on-screen frame including an animation in flight, rather than the final model
value. Static layout, painted text, clipping and spacing are judged from PNGs.
Its fidelity gaps remain:

- Native titlebar/tab bar, window shadow and vibrancy blended with the background.
- Metal terminal and WKWebView pixels: exact output is unverified and can be
  blank/stale. Use an authorized text route for terminal-output proof.
- Tooltips, popovers and menus outside the content subtree.
- Motion/current animation advancement, and final on-screen appearance.
- Pasteboard payloads: J5 copy remains a separate actual-control observation.

J2 motion and the native fidelity checks stay with Peekaboo only when already
unlocked and separately granted. Use the PID/start/window guard and
`scripts/pane-chrome.sh capture`, or the equivalent exact PID-targeted command:

```bash
peekaboo see --pid "$PID" --window-id "$WINDOW_ID" \
  --mode window --no-remote --no-elements --path "$PNG"
```

For J9/J10 retain local PID-targeted inventories before/after opening with
`scripts/pane-chrome.sh inventory`. A native popover can be another window; its
actual numeric ID must be selected from owned/visible context. Capture it, or a
frame demonstrably including it, and open the original. Window inventory may
omit a non-renderable popover; no eligible capture leaves that cell UNKNOWN.
An app-rendered main window cannot replace this observation. The wrapper uses
the documented local `--no-remote` route, never an automatic alternate host.

Keep that original and method label separate from the app render. A denied
native route stops that route; never change identity, TCC, focus or transport to
bypass its approval. Locked app rendering is its own declared route, not a retry
of a denied computer-use action.

For interrupted file transfers, run the wrapper's `cleanup RUN_DIR`. It uses
only previously recorded responses/paths and the original J1 owner receipt;
it can finish after the app retires. It preserves evidence before deleting the
exact recorded source. A missing response, mismatching bytes or changed owner
is reported and held. Never glob or delete unreceived render files. Keep every
source/evidence path and unresolved transfer in the handback.

## V2 window receipts and measured surface widths

For pane-context r5, take 1400/520/390 as **window content width requests**.
Retain each resize request and actual applied `contentSize`, before/after
ownership, image point/pixel dimensions and scale, and measured sidebar, toolbar,
card and native popover bounds. Capture visible content only once after the
documented owner completion/settle. A 390 request clamped larger does not fill
390; preserve it as calibration/UNKNOWN. S11 separately requires actual 260pt
sidebar width. Record actual native popover width, not its parent-window width.

Keep one state/width receipt per original: scenario/branch (S16a/b, S10 receipt
phase), source fact paths, actual window/surface sizes, pane/source IDs, original
path, method/capture owner and verdict. Every applicable surface must be visible;
an obscured card is a missing cell. Link R1–R10 verbatim from the adopted source.

The existing J5 identity-layout card matrix below is retained independently.
Its 520pt card is not the same claim as V2's 520pt window. Name both dimensions;
do not silently substitute or discard either required observation.

## Reach the declared card widths

The observation grant must name the layout route and five owned pane layouts
for 420/520/640/780/1000pt cards, which can use successive held single-pane frames.
Read the declared `command.list` for `splitRight`/`splitLeft` pane arguments and
`equalizePanes` tab arguments. These give equal split widths; there is no
headless route to unequal sibling widths and no ratio-setting IPC verb.
Different-width side-by-side siblings need a separately granted native divider
drag on an already unlocked screen. Without that route, Sibling spacing and
Same shape stay UNKNOWN. Sequential single-pane frames normalized to each
card's origin still judge local alignment.
For an owned window, use `window.resize` through the same wrapper and escrow CLI,
with finite positive content dimensions and a fresh UUIDv7 correlation from the
repository's generator:

```bash
/bin/bash .agents/skills/verify-agentstudio/scripts/window-frame.sh \
  resize "$RUN_DIR" "$WORKSPACE_WINDOW_UUID" "$CONTENT_WIDTH_PT" \
  "$CONTENT_HEIGHT_PT" "$CORRELATION_UUIDV7" layout-520
/bin/bash .agents/skills/verify-agentstudio/scripts/window-frame.sh \
  render "$RUN_DIR" "$WORKSPACE_WINDOW_UUID" layout-520-frame "$PANE_UUID"
```

Resize reports the **actual applied content size**, including constraint
clamping. It does not render; the separate render performs the 3 s consumer
settle and one capture. Existing permitted split/equalize state changes follow
the same owner-fact → settle → render sequence.

Read actual card bounds after layout: outer window width is **not** card width.
An off-target layout attempt is a **calibration frame**: retain the applied size
receipt and full original, label it with the measured width, and use the measured
delta for further layout attempts. Only a frame within ±2pt fills the cell.
The no-retake rule covers product verdicts: never replace or hide a frame showing
a defect, including one that also misses the target width. A clamped/unreachable
required width or denied/ungranted route leaves that cell UNKNOWN; requested
size is not measured size. The shared quality reference owns measurement/tolerance.
Finish layout before J5's timed pair and hold it fixed.

Complete when identity, health, fixture ownership, capture access and the real
entry/result route are established. Leave the app and existing sessions intact
unless the Lead grants their exact cleanup. J1's lifecycle grant is separate.
