# Shared setup for J4–J7

This reference owns the debug identity, IPC and capture mechanics. Inputs are
the Lead's declared commit/build/CLI, debug code, PID/start/marker, native window,
owned proof pane, granted evidence directory and operator/capture roles. Return
that receipt, successful health reads and each missing prerequisite before a
journey starts. It grants no launch, build, app action or permission change.
For J7, also require `agent-setups.md`'s provider-host containment receipt before
starting a real turn. A debug pane/client does not isolate a remote agent host.

The Lead's **native observation grant** is a written assignment naming the
debug PID/start/bundle/window, owned panes, sole state-driving operator, capture
owner, permitted mutations/evidence path and hold/cleanup owner. Keep its
message/receipt reference. An unlocked screen or another task's grant is not
this assignment. This is what a journey requires before driving the live UI.

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
peekaboo window list --pid "$PID" --json
```

Normalize leading/trailing whitespace in `lstart`, not its date fields. Stop on
a changed executable/start/window/marker, denied inventory or ambiguous PID.
An IPC window UUID is not the native numeric window ID used by Peekaboo. Confirm
the latter in that PID's current window list. Never target the app by name.

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

## Capture without focus

Use the authorized capture owner with working Screen Recording; attribute its
raw PNGs and have the Verifier open them independently. A permission error stops
that route. Do not retry via
an alternate identity, change TCC, activate the app or trigger a prompt.

```bash
peekaboo see --pid "$PID" --window-id "$WINDOW_ID" \
  --mode window --no-elements --path "$PNG"
# Optional crop; retain the original and its pixel dimensions.
sips -c "$HEIGHT" "$WIDTH" --cropOffset "$Y" "$X" "$PNG" --out "$CROP"
```

The opt-in `scripts/pane-chrome.sh capture` repeats the executable/start guard
and this exact capture command. Its exit 0 means collection only; check the PNG,
dimensions and state. A locked GUI both blocks capture and can throttle timers:
restart J5
after unlock with fresh t0 evidence (activity fact for the activity chip, actual
successful line-write interval for message age), not an aged open card. Mere
elapsed wall time during lock establishes nothing.

Do not retry a blocked computer-use call in a held run or bypass its approval
through another transport. Return the actual access gap to the Lead.

## Reach the declared card widths

The observation grant must name the layout route and five owned pane layouts
for 420/520/640/780/1000pt cards (simultaneous when the screen permits, otherwise
successive held layouts plus a side-by-side sibling comparison). Read the
declared `command.list` for `splitRight`/`splitLeft` pane arguments and
`equalizePanes` tab arguments. These create/equalize splits; don't invent a
ratio-setting IPC verb. An approved split-divider drag through the permitted
UI route can set the ratio. Alternatively, place one proof pane in an owned
window and use a separately granted PID/window resize:

```bash
peekaboo window resize --pid "$PID" --window-id "$WINDOW_ID" \
  --width "$WINDOW_WIDTH_PT" --height "$WINDOW_HEIGHT_PT" --json
```

Read actual card bounds after layout: outer window width is **not** card width.
Use measured delta to set the next window width/divider position, then retain
the receipt and full frame. Stop if the app clamps the size or the route is
denied/ungranted; report that width UNKNOWN. The shared quality reference owns
measurement/tolerance. Finish layout before J5's timed pair and hold it fixed.

Complete when identity, health, fixture ownership, capture access and the real
entry/result route are established. Leave the app and existing sessions intact
unless the Lead grants their exact cleanup. J1's lifecycle grant is separate.
