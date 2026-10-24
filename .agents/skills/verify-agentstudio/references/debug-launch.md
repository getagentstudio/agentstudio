# J1 — launch, reach and retire one debug app

Oracle: `CLAUDE.md` Proof/Native UI rules; architecture
`docs/architecture/observability/observability_and_traceability.md`, Local proof
launch and Manual and stress verification. Mechanics:
`scripts/run-debug-observability.sh` and this skill's `scripts/debug-lifecycle.sh`.

## Declared target and prerequisites

Take full commit, prepared build path, four-character debug code and existing
watch folder from the Lead's declaration. Obtain a build receipt tying the binary
hash/UUID to that commit; the driver records a declaration, not an embedded
source attestation. Never type an older commit to satisfy a guard.

The watch fixture is an owner-controlled directory named by the run, with no
private content. If absent, obtain a supplied fixture or a grant to create an
empty directory in runtime scratch; there is no dependency on another run's
gitignored fixture. The standard launcher needs prepared vendors and a shared
collector. Build/setup/stack startup are separate grants. Managed writes include
the isolated debug root and `tmp/debug-observability/latest-observability.env`.
Escrow/evidence needs its own granted `tmp/verify-agentstudio/<run>/` directory.

## Exact route

From the repository root after installation:

```bash
DRIVER=.agents/skills/verify-agentstudio/scripts/debug-lifecycle.sh
# RUN, BUILD_PATH, COMMIT, DEBUG_CODE and WATCH_FOLDER come from the declaration.
/bin/bash "$DRIVER" preflight "$DEBUG_CODE" "$BUILD_PATH"
/bin/bash "$DRIVER" launch "$RUN" "$BUILD_PATH" "$COMMIT" "$DEBUG_CODE" "$WATCH_FOLDER"
/bin/bash "$DRIVER" health "$RUN"
```

The live launch, after scrubbing every inherited `AGENTSTUDIO_*` variable, is:

```bash
AGENTSTUDIO_STARTUP_WATCH_FOLDER="$WATCH_FOLDER" \
AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW="$ABSOLUTE_RUN_DIR/ipc-escrow.json" \
mise run run-debug-observability -- --detach --skip-build --build-path "$BUILD_PATH"
```

1. Preflight must see its own shell through `ps`, preserve `pgrep` status/stderr,
   and inspect returned candidate executable paths. A denied or incomplete
   inventory blocks launch. An existing debug instance is a hold; never quit it.
   The launcher's swallowed `pgrep` failure is not proof of absence.
2. Launch once, preserving output/status. A failure must not source a stale
   handoff, retry, switch transports or fall back to a different binary.
   The launcher waits for the published CLI's `system.ping` through the supplied
   escrow before reporting `running`. PID discovery and health share its
   existing launch deadline. `launch_failed` with `REASON=ipc_health_timeout`
   means IPC did not become usable within that deadline; retain the failure
   state and log. It does not prove that the process exited.
3. A successful handoff must report `running`, flavor `debug`, matching code,
   build path, generated executable/bundle id, isolated data/zmx roots and
   `ACTIVATION_MODE=background`. Direct-executable fallback does not prove a
   background launch. Record it and retire only a process whose ownership is
   independently established.
4. The driver saves `owner.env` immediately after validating the new launch.
   Before actions it compares executable and `ps` start string with that receipt,
   and PID/kernel-start/marker with the current launcher handoff. The `ps` start
   string is coarser than the launcher's kernel identity; this driver does not
   independently recompute the latter. If incarnation remains uncertain, hold
   mutation and request the launcher's existing identity-validation route as a
   needed grant. The handoff itself is not proof.
5. `health` invokes the published bundle's `Contents/Helpers/agentstudio`, with
   only `AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW` among the `AGENTSTUDIO_*` environment.
   Inspect successful `pane.list` and `window.list` JSON and expected handles.
   Its first pane list is retained as the baseline; J2/J3 reject existing panes.
6. Read `terminal.status`/`terminal.snapshot` for a chosen new fixture pane;
   `terminal.wait(attachReady)` may establish registered runtime readiness. A
   live process, port or accepted input cannot stand for usable shell readiness.

```bash
/bin/bash "$DRIVER" cli "$RUN" pane.list
/bin/bash "$DRIVER" cli "$RUN" window.list
/bin/bash "$DRIVER" cli "$RUN" command.list
/bin/bash "$DRIVER" cli "$RUN" terminal.snapshot '{"handle":"<returned-pane-uuid>"}'
```

Angle-bracket values are required returned handles, not literal working inputs.
Create disposable fixture terminals through the live command catalog. The
source-backed `newTerminalInTab` shape is:
`{"commandId":"newTerminalInTab","arguments":{"kind":"tab","tabId":"<returned-tab-uuid>"},"correlationId":"<fresh-UUIDv7>"}`.
Confirm it against `command.list` before dispatch. Use the commissioning harness's
fresh UUIDv7 correlations, never replay a prior command id. Keep the before/after
pane lists and use only newly created panes. Shared debug roots do not grant
ownership of earlier zmx processes.

## Owned quit and deciding evidence

```bash
/bin/bash "$DRIVER" quit "$RUN"
# If quit was accepted but retirement is not yet observable, after its completion signal:
/bin/bash "$DRIVER" confirm-quit "$RUN"
```

After verifying the still-owned process, the mutating command is
`/usr/bin/osascript` targeting only the receipt's `com.agentstudio.app.debug.d<code>`.
A permission/TCC prompt stops the run. Retirement requires an available inspection
path and an absent recorded PID. If it is still present, report that intermediate
state; no polling, sleeps, arbitrary kill or inferred retirement. Leave terminal
sessions intact in J1 and confirm the evidence survives.

Passing evidence rejects a wrong bundle, stale PID/marker, unauthenticated CLI,
foreground launch and quit of an unowned app. Return the launch/build receipt,
authenticated health results, readiness and actual owned retirement separately;
name an access failure without turning it into a product defect or absence.
