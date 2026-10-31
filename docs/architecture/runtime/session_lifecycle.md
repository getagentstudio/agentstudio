# Session Lifecycle Architecture

## TL;DR

A pane's identity (`PaneId`) is stable across its entire lifecycle — creation, layout changes, view switches, close/undo, persistence, and restore. `WorkspaceStore` owns pane records. `SessionRuntime` tracks runtime health. `WorkspaceSurfaceCoordinator` bridges panes to surfaces. Closed panes can be restored from the durable SQLite Undo journal. The zmx backend provides persistence across app restarts.

---

## Identity Contract (Canonical)

`PaneId` is the pane's primary identity. Every terminal pane also owns a
separate, non-optional opaque `ZmxSessionID`. New pane and session identities
are independent UUIDv7 values minted at terminal-pane creation; neither is
derived from the other. SQLite stores the `ZmxSessionID` text verbatim, and zmx
attach receives that exact value. Restore preserves every existing nonempty
stored identity, including historical `as-*` values, without interpretation or
rewrite. Repository, worktree, path, launch-directory, drawer, pane fragments, and live
daemon inventory never participate in session identity.

### Identifier Types

| Identifier | Type | Owner | Persisted | Generation | Used For |
|------------|------|-------|-----------|------------|----------|
| `PaneId` | `PaneId` (`struct` wrapping `UUID`) | `WorkspaceStore` | Yes | `Pane.init(id: UUID = UUIDv7.generate(), ...)` with `PaneMetadata.paneId = PaneId(uuid: id)` | Universal pane identity across store/layout/view/runtime/surface |
| `ZmxSessionID` | strong opaque value type | `TerminalState` | Yes (existing `pane_content_terminal.zmx_session_id` text column) | New values independently use UUIDv7 at terminal-state creation; existing nonempty values restore verbatim | Exact zmx daemon/socket identity for every terminal pane |

### Session Identity Rules

1. Terminal-state construction mints one fresh UUIDv7 `ZmxSessionID`.
2. The type is non-optional. Persistence decoding accepts an existing nonempty
   opaque value and does not interpret its format.
3. Repository decode/write boundaries require the strong non-optional type and
   round-trip the existing SQLite text exactly. This cut adds no schema or data
   migration.
4. Restore is read-only with respect to session identity: strict decode, one
   composition apply, activation, then attach with the exact stored ID.
5. No session-identity repair, hydration, adoption, discovery, inference,
   backfill, fallback, or mutation exists during restore or startup.
6. No migration rewrites an existing session identity.
7. The zmx subprocess boundary accepts only the strong `ZmxSessionID` type,
   never caller-supplied raw text. This is a security boundary as well as a
   domain invariant; restored historical values remain exact typed identities.

### PaneId Lifecycle (ASCII)

```text
USER ACTION (open terminal / split / drawer)
    |
    v
WorkspaceSurfaceCoordinator.create/open*
    |
    v
WorkspaceStore.createPane(...)
    -> Pane(id = UUIDv7.generate())      <-- PaneId minted once
    -> panes[paneId] = Pane
    |
    v
Tab/Layout references created
    -> Tab.panes[] contains paneId
    -> Layout.leaf(paneId)
    |
    v
Persist (core.sqlite)
    -> Pane.id stored
    -> Tab/Layout paneId references stored
    |
    v   app relaunch
Restore (WorkspaceStore.restore)
    -> strict SQLite decode of a complete valid composition
    -> narrow pane-association soft-reference reconciliation against topology
    -> one composition apply; no session-identity or layout repair
    |
    v
WorkspaceSurfaceCoordinator.restoreAllViews()
    -> lookup Pane by paneId
    -> create/reattach surface + register view by paneId
```

### zmx Interplay and Lookups (ASCII)

```text
Terminal-pane creation
  - independently mint PaneId UUIDv7 and ZmxSessionID UUIDv7
                  |
                  v
TerminalState.zmxSessionID
  - required opaque value restored from pane_content_terminal.zmx_session_id
                  |
                  v
SQLite strict decode
  - reject missing or empty identity; preserve existing text exactly
                  |
                  v
pane-association soft-reference reconciliation, then one composition apply
                  |
                  v
terminal activation
  - zmx attach receives the exact stored ZmxSessionID
  - no session-identity discovery, inference, adoption, fallback, backfill, or write
```

### Lookup Ownership Table

| Lookup | Source of Truth | API/Path |
|--------|------------------|----------|
| `paneId -> Pane` | `WorkspaceStore.panes` | `store.pane(paneId)` / dictionary lookup |
| `paneId -> View` | `ViewRegistry` | `viewRegistry.view(for: paneId)` |
| `paneId -> RuntimeStatus` | `SessionRuntime.statuses` | `runtime.status(for: paneId)` |
| `paneId -> Surface` | `SurfaceManager` attachment state | Current/most-recent attachment ID; retained Undo attachment |
| `paneId -> zmx session name` | required `TerminalState.zmxSessionID` | strict SQLite decode and immutable terminal activation input |
| `zmx session name -> live daemon` | zmx process state in `ZMX_DIR` | `zmx list` parse |

### Socket Path Budget (Darwin)

`zmx` creates Unix socket paths as:
`socketPath = zmxDir + "/" + sessionName`

Darwin `sockaddr_un.sun_path` is 104 bytes, so practical max is:
`socketPath.count <= 103`

This makes session name length a hard runtime constraint, not just formatting.
`ZmxTestHarness` uses short `/tmp/zt-<id>` paths specifically to stay under this limit.

### Debug App Identity Budget

Debug observability launches first try an app-bundle launch.
[`scripts/run-debug-observability.sh`](../../../scripts/run-debug-observability.sh) computes a deterministic four-character
base36 code from the canonical worktree path and uses it for debug app
identity:

| Field | Shape |
|-------|-------|
| app display name | `Agent Studio Debug <code>` |
| bundle id | `com.agentstudio.app.debug` |
| signed Info.plist code | `AgentStudioDebugCode = <code>` |
| data root | `~/.agentstudio-db/<code>` |
| zmx dir | `~/.agentstudio-db/<code>/z` |
| URL scheme | none |

This code isolates debug worktrees while keeping app names, zmx paths, and Unix
socket paths short. The shared bundle ID preserves TCC identity; the code scopes
app-owned defaults and persistent WebKit storage. It is not a pane/session identifier.
The debug observability bundle removes URL-handler registration entirely so it
cannot claim stable production `agentstudio://` callbacks or deep links.
Debug isolation is owned by bundle id, app name, data root, and zmx root.
The generated debug bundle, logs, traces, and zmx root live under
`~/.agentstudio-db/<code>` instead of the repo checkout, which keeps autonomous
agent test launches from requiring `~/Documents` access just to read their own
app artifact. If LaunchServices/Gatekeeper rejects the generated local bundle,
the debug launcher may fall back to direct `Contents/MacOS/AgentStudio`
execution and records
`AGENTSTUDIO_OBSERVABILITY_LAUNCH_METHOD=direct_executable` in its state file.
That fallback is valid for Victoria/OTLP debug proof and keeps the same isolated
data/zmx root. It is not beta promotion proof and not full GUI proof.
The short debug worktree code scopes the zmx root only. It never contributes to
the opaque session name; all newly generated names use UUIDv7.

## Session Properties

Every pane carries metadata that determines its behavior:

```
Pane
├── id: UUID                    ← immutable primary key
├── content: PaneContent        ← .terminal/.webview/.codeViewer/.bridgePanel
├── metadata: PaneMetadata      ← title/launchDirectory/live facets/tags
├── kind: PaneKind              ← .layout or .drawerChild
└── residency: SessionResidency ← .active/.pendingUndo/.backgrounded
```

---

## Session Lifecycle States

### Residency (Persisted)

`SessionResidency` tracks application placement. Closed pane snapshots now live in the Undo journal;
the pendingUndo node below denotes durable Undo ownership, not an authoritative live pane row. Filesystem availability and
repository/worktree association are separate dimensions and never transition a
pane between residency states. `.active` means eligible for workspace
presentation and content mounting; an active pane may still be in an inactive
tab, minimized, or otherwise not currently visible.

```mermaid
stateDiagram-v2
    [*] --> active: createPane()
    active --> pendingUndo: commit close snapshot to journal
    active --> backgrounded: explicit background action
    pendingUndo --> active: undoCloseTab()
    pendingUndo --> [*]: undo expires / GC
    backgrounded --> active: explicit reactivation
    backgrounded --> [*]: explicit removal
    legacyOrphaned --> active: boot repair; tab/drawer owned
    legacyOrphaned --> backgrounded: boot repair; unowned
```

The legacy persisted `.orphaned(worktreeNotFound:)` value is accepted only as
boot-repair input. Current runtime code does not create it. Boot reconciliation
uses canonical tab/drawer ownership, not path existence or Git topology, to
convert it to `.active` or `.backgrounded` and persist the repaired state.

Filesystem and Git state evolve independently:

```mermaid
stateDiagram-v2
    associated --> unassociated: worktree/repository disappears
    unassociated --> associated: current CWD matches topology
    associated --> associated: shell changes CWD within known topology
    unassociated --> unassociated: CWD absent or outside topology
```

Every transition in this second diagram preserves pane identity, residency,
tab/drawer ownership, terminal runtime, and the last observed CWD value.

### Runtime Status (Not Persisted)

`SessionRuntimeStatus` tracks live backend state per pane. Created fresh on each app launch.

```mermaid
stateDiagram-v2
    [*] --> initializing: initializeSession()
    initializing --> running: markRunning() / backend.start()
    running --> exited: markExited() / process exit
    running --> unhealthy: health check failed
    unhealthy --> exited: backend terminated
    exited --> [*]: session removed
```

| Status | Meaning |
|--------|---------|
| `.initializing` | Session created, backend not yet ready |
| `.running` | Backend is running and healthy |
| `.exited` | Backend process has exited |
| `.unhealthy` | Health check failed, session may be stale. Terminal until backend exits. |

---

## Terminal Creation Flow

```mermaid
sequenceDiagram
    participant User
    participant PC as WorkspaceSurfaceCoordinator
    participant Store as WorkspaceStore
    participant SM as SurfaceManager
    participant VR as ViewRegistry
    participant RT as SessionRuntime

    User->>PC: openTerminal(worktree, repo)
    PC->>PC: Check if worktree already has active pane
    alt Already open
        PC->>Store: setActiveTab(existingTab.id)
    else New session needed
        PC->>Store: create terminal pane (new PaneId + ZmxSessionID UUIDv7 values)
        Store-->>PC: Pane with required terminal session identity
        PC->>SM: createSurface(config, metadata)
        SM-->>PC: ManagedSurface
        PC->>SM: attach(surfaceId, paneId)
        PC->>VR: register(view, paneId)
        PC->>RT: markRunning(paneId)

        Note over Store,PC: Pane and placement commit before native creation
        alt Surface creation failed
            Note over PC: Keep committed pane ownership; report rendering failure for retry
        else Success
            Note over PC: Surface mounted in already committed placement
        end
    end
```

---

## Close & Undo Flow

### Close pane or tab

The coordinator prepares a complete close snapshot and commits the composition change plus
`workspace_undo_close` and its members in the existing serialized SQLite writer. Only after
commit does it detach native views and then publish placement. The last pane uses the tab-close path.
Available entries retain native surfaces through SurfaceManager; the manager has no independent TTL.

The durable journal owns the 300-second deadline and ten-entry oldest-first capacity per workspace.
Expiry/eviction commits the ownership transition before retiring unowned pane resources. Session
cleanup eligibility checks both live terminal rows and available Undo members across workspaces.
After boot recovery, the cleanup consumer waits five minutes before reading pending work.
This startup delay does not renew individual Undo deadlines. Buffered expiry/discard wakeups
cannot bypass the delay. The consumer reads only journal-known pending session IDs, verifies
native attachments are gone, and records process evidence before conditional retirement.
A failed attempt remains pending for bounded retry. Previously recorded process evidence
must match before Kill; completion reconciles the original processes and PTY group. For an
unobserved session, a positively absent endpoint can complete its NULL-evidence pending row;
permission and transport failures are not absence. This does not claim extinction of an
unobserved historical process group. Completed history is pruned in bounded batches.

### Undo (`Cmd+Shift+T`)

Inspect newest-first available entries, skipping invalid placement without consuming them. Commit
restored composition and consumed Undo state together, then publish and materialize. Reuse the
retained surface by current/most-recent pane attachment ID when available. Rendering failure keeps
the restored logical ownership so the pane can be retried. Restore does not pop an in-memory
entry before validation and does not rely on matching creation metadata or global surface LIFO.

---

## App Launch Restore

```mermaid
sequenceDiagram
    participant AD as AppDelegate
    participant Store as WorkspaceStore
    participant DB as WorkspaceSQLiteDatastoreActor
    participant Coord as WorkspaceSurfaceCoordinator

    AD->>Store: restore()
    Store->>DB: strict decode of core/local SQLite composition
    DB-->>Store: complete immutable WorkspaceSQLiteSnapshot
    Store->>Store: normalize legacy orphaned residency from canonical tab ownership
    Store->>Store: reconcile pane association soft references against decoded topology
    Store->>Store: strictly prepare the complete composition
    Store->>Store: apply composition once
    Store-->>DB: best-effort persist when residency or association changed

    AD->>Coord: activate accepted terminal composition
    loop each scheduled terminal pane
        Coord->>Coord: create surface and attach exact stored ZmxSessionID
    end

    AD->>AD: Create MainWindowController
```

Restore is read-only for session identity and layout: strict SQLite decode,
one composition apply, terminal activation, then exact-ID zmx attach. Before
strict composition preparation, `WorkspaceStore` converts only legacy
`.orphaned` residency: panes owned by any canonical `Tab.allPaneIds` become
`.active`, while unowned recoverable panes become `.backgrounded`. It then
performs one narrow pane-association housekeeping pass: a missing soft-reference
pair may be backfilled from CWD, and a pair that does not resolve in the decoded
topology is cleared unless its repository is known to be temporarily
unavailable. If either pass changes state, the corrected snapshot is persisted
best-effort; persistence failure is non-fatal to the already accepted in-memory
composition. Missing or invalid required state remains a decode/restore failure.
Startup does not otherwise normalize the graph, prune or invent layout
references, repair cursors, infer session identities, or mutate a stored
`ZmxSessionID`. Repository/topology startup never gates or mutates session
identity.

---

## App Termination

```
AppDelegate.applicationWillTerminate / applicationShouldTerminate
  └── WorkspaceStore.flush()
        ├── Cancel pending debounced save
        ├── Filter temporary sessions from output
        ├── Prune layouts in the serialized copy
        └── Commit SQLite snapshot immediately
```

---

## Persistence

State is persisted through `WorkspaceSQLiteDatastoreActor` into authoritative
`core.sqlite` plus one non-authoritative app-root `local.sqlite`. Boot prepares
both databases before hydration and retains one writable owner for each
available database. Core preparation failure stops boot. Classified corruption
or an orphan local sidecar set triggers one quarantine-and-create-fresh attempt;
if local preparation remains unavailable, every local slice uses deterministic
defaults while accepted core startup continues. When local is available, an
invalid query or decode defaults only its logical slice. Legacy workspace JSON
and per-workspace local sidecars are not read. Global preferences remain in
`preferences.global.json`. See
[Component Architecture — Persistence](../structure/component_architecture.md#5-persistence)
for the full write strategy, filtering, and schema details.

Key points:
- Ordinary autosaves are debounced; terminal creation and close/Undo ownership transitions commit before publication
- `flush()` on termination for immediate write
- Temporary panes never persisted
- Window frame saved only on quit

---

## zmx Session Persistence

The zmx backend provides session persistence across app restarts. When enabled, terminal sessions survive app crashes — the user sees only a Ghostty terminal surface while zmx preserves the PTY and scrollback in the background via raw byte passthrough daemons.

Geometry readiness is a runtime activation concern only; it does not participate
in session identity or restore-time discovery.

### Architecture

zmx is a ~1000 LOC Zig tool that provides raw byte passthrough with an internal `ghostty_vt` terminal for state tracking. `TERM=xterm-ghostty` flows through natively:
- **No config file** needed
- **No terminal emulation layer** for forwarding (keyboard/mouse protocols pass through raw)
- **No custom terminfo** needed (xterm-ghostty works natively)
- One daemon per session (no shared server)
- Internal `ghostty_vt` tracks terminal state for serialization (session restore), not for rendering

### IPC Protocol

zmx uses a binary protocol over Unix domain sockets. Each message is a packed header followed by a variable-length payload. For future direct-client work, re-verify these protocol details against the pinned `vendor/zmx` sources in the primary worktree before implementation; a shared linked worktree may leave vendor source unhydrated.

**Header format (5 bytes):**

```
┌─────────┬──────────────────────┐
│ tag: u8 │ payload_len: u32 LE  │
└─────────┴──────────────────────┘
```

**IPC tags:**

| Tag | Value | Direction | Purpose |
|-----|-------|-----------|---------|
| `Input` | 0 | client → daemon | Keystrokes / stdin bytes |
| `Output` | 1 | daemon → client | PTY output bytes (broadcast to all clients) |
| `Resize` | 2 | client → daemon | New terminal dimensions (cols, rows) |
| `Detach` | 3 | client → daemon | Disconnect this client |
| `DetachAll` | 4 | client → daemon | Disconnect all clients |
| `Kill` | 5 | client → daemon | Terminate session |
| `Info` | 6 | bidirectional | Session metadata (pid, cmd, cwd, created_at) |
| `Init` | 7 | client → daemon | Initial handshake with client dimensions |
| `History` | 8 | daemon → client | Serialized terminal state on attach |
| `Run` | 9 | client → daemon | Execute command in session |
| `Ack` | 10 | daemon → client | Acknowledgment |

**Connection model:** The daemon accepts any connection to its Unix socket without authentication (socket permissions are the access control boundary). All connected clients receive broadcast Output messages. One-shot connections (connect → send → read → close) are safe and match zmx's own `probeSession()` pattern.

**Info struct (552 bytes):** Contains `clients_len: usize`, `pid: i32`, `cols: u16`, `rows: u16`, `cmd: [256]u8`, `cwd: [256]u8`, `created_at: u64`, `task_exit: u64`, `task_exit_valid: u8`, plus alignment padding.

### Session Restore and the Two-Terminal Problem

zmx has two terminals processing the same byte stream — the **outer terminal** (Ghostty surface, what the user sees) and the **inner terminal** (daemon's `ghostty_vt`, shadow tracker for state capture). These can diverge in behavior, and all zmx-related bugs trace to this divergence. See [zmx Terminal Integration](../archive/zmx_terminal_integration_lessons.md) for the full investigation.

**Restore flow with OSC 133 fix:**

```
App launches → creates Ghostty surface with zmx attach command
  │
  ▼
zmx client connects to existing daemon, sends Init with dimensions
  │
  ▼
Daemon receives Init:
  ├─ 1. Serializes internal terminal state (serializeTerminalState)
  │     └─ Rewrites OSC 133;A with redraw=0 in serialized output
  ├─ 2. Sends serialized state as Output to client
  ├─ 3. Disables shell_redraws_prompt before resize
  └─ 4. Resizes PTY and internal terminal to new client dimensions
  │
  ▼
Client receives serialized state → writes to stdout → Ghostty renders
  │
  ▼
Shell's SIGWINCH redraw arrives → Ghostty renders current prompt
```

The `redraw=0` injection tells the outer terminal "this process cannot redraw prompts — don't clear prompt rows on resize." This is the Kitty protocol extension applied via `rewritePromptRedraw()` in the daemon's output path. Without it, the outer terminal clears prompt rows expecting the shell to redraw, but the shell's redraw goes through zmx's IPC relay with cursor coordinates relative to the inner PTY. Geometry and resize sequencing do not change the stored session identity.

### ZMX_DIR Isolation

All zmx calls use `ZMX_DIR=<app-root>/z` to isolate Agent Studio sessions from any user-owned zmx sessions. The app root is channel-aware and resolved through `AppDataPaths.zmxDirectory()`.

- Destroy/list/health paths pass `ZMX_DIR` via process environment.
- Attach path passes `ZMX_DIR` through Ghostty surface environment variables.

### zmx CLI Commands

| Command | Purpose |
|---------|---------|
| `zmx attach <name> <cmd...>` | Attach to (or create) a session with the given name |
| `zmx kill <name>` | Kill a session by name |
| `zmx list` | List all active sessions (tab-delimited key=value pairs) |

### Testing

The zmx path is covered by layered tests:

1. unit tests for backend command/session behavior,
2. integration tests against a real zmx binary with isolated `ZMX_DIR`,
3. end-to-end tests for full lifecycle and backend recreation restore semantics.

### zmx Binary Resolution

The zmx binary is resolved via a fallback chain:
1. **Bundled binary**: `Contents/MacOS/zmx` (same directory as app executable)
2. **Well-known PATH locations**: `/opt/homebrew/bin/zmx`, `/usr/local/bin/zmx`
3. **`which zmx`** fallback
4. If none found: fall back to ephemeral `.ghostty` provider (no persistence)

### Canonical Session Identity

See **Identity Contract (Canonical)** above for the complete source of truth.

- Every new terminal-pane creation path mints one independent UUIDv7
  `ZmxSessionID` with the `PaneId`.
- Repository decode requires a nonempty value from the existing SQLite text
  column and reconstructs the opaque typed identity without rewriting it.
- Activation passes that same value to zmx attach.
- zmx attach, health, list, and kill boundaries accept the opaque typed identity;
  raw caller-supplied subprocess input is rejected before command creation.

### Startup Is Not a Session Reconciliation Boundary

App launch does not list zmx daemons to decide identity or restoration. It does
not hydrate, adopt, infer, backfill, repair, rename, or persist a session ID.
Operational cleanup, if separately authorized, is outside restore and cannot
use pane/path fragments, rewrite existing identities, weaken the strong type, or
change the UUIDv7 generation rule for new sessions.

---

## SessionStatus State Machine (Dormant)

A full 7-state machine exists in [`Core/Models/SessionStatus.swift`](../../../Sources/AgentStudio/Core/Models/SessionStatus.swift) for future integration with zmx backend health monitoring. It is **not yet wired** into `SessionRuntime` (which uses the simpler `SessionRuntimeStatus` enum above).

```mermaid
stateDiagram-v2
    [*] --> unknown
    unknown --> verifying: verify / create
    verifying --> verifying: socketFound (checkSessionExists)
    verifying --> alive: sessionDetected / created
    verifying --> missing: socketMissing / sessionNotDetected
    verifying --> failed: createFailed
    alive --> alive: healthCheckPassed
    alive --> dead: healthCheckFailed / sessionDied
    alive --> verifying: verify (re-check)
    dead --> recovering: attemptRecovery
    dead --> verifying: create
    missing --> verifying: create
    missing --> recovering: attemptRecovery
    recovering --> alive: recoverySucceeded
    recovering --> failed: recoveryFailed
    failed --> verifying: create / verify
```

**States:** `unknown`, `verifying`, `alive`, `dead`, `missing`, `recovering`, `failed(reason)`

**Effects:** Each transition can trigger effects (e.g., `checkSocket`, `createSession`, `scheduleHealthCheck`, `notifyAlive`, `notifyDead`) that are executed by the `Machine<SessionStatus>` effect handler.

---

## Key Files

| File | Role |
|------|------|
| [`Core/State/MainActor/Persistence/WorkspaceStore.swift`](../../../Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceStore.swift) | Main-actor persistence wrapper over the canonical workspace atoms |
| [`Core/RuntimeEventSystem/Runtime/SessionRuntime.swift`](../../../Sources/AgentStudio/Core/RuntimeEventSystem/Runtime/SessionRuntime.swift) | Runtime health monitoring and status tracking |
| [`App/Coordination/WorkspaceSurfaceCoordinator.swift`](../../../Sources/AgentStudio/App/Coordination/WorkspaceSurfaceCoordinator.swift) | Dispatches actions (open, close, split, undo, etc.) and is the sole intermediary for view/surface orchestration |
| [`Core/Models/Pane.swift`](../../../Sources/AgentStudio/Core/Models/Pane.swift) | Pane identity and content metadata |
| [`Core/Models/SessionLifetime.swift`](../../../Sources/AgentStudio/Core/Models/SessionLifetime.swift) | `.persistent` / `.temporary` enum |
| [`Core/Models/SessionResidency.swift`](../../../Sources/AgentStudio/Core/Models/SessionResidency.swift) | `.active` / `.pendingUndo` / `.backgrounded` enum |
| [`Core/Models/Layout.swift`](../../../Sources/AgentStudio/Core/Models/Layout.swift) | Value-type split layout tree (Codable for persistence) |
| [`Core/Models/Tab.swift`](../../../Sources/AgentStudio/Core/Models/Tab.swift) | Tab with layout and active pane |
| [`Core/Models/SessionConfiguration.swift`](../../../Sources/AgentStudio/Core/Models/SessionConfiguration.swift) | Config detection from env vars |
| [`Core/Models/SessionStatus.swift`](../../../Sources/AgentStudio/Core/Models/SessionStatus.swift) | 7-state machine definition for future zmx health |
| [`Infrastructure/StateMachine/StateMachine.swift`](../../../Sources/AgentStudio/Infrastructure/StateMachine/StateMachine.swift) | Generic state machine with effect handling |
| [`Infrastructure/ProcessExecutor.swift`](../../../Sources/AgentStudio/Infrastructure/ProcessExecutor.swift) | Protocol + `DefaultProcessExecutor` for CLI execution |
| [`Core/RuntimeEventSystem/Runtime/ZmxBackend.swift`](../../../Sources/AgentStudio/Core/RuntimeEventSystem/Runtime/ZmxBackend.swift) | zmx CLI wrapper — session ID gen, create/destroy/healthCheck |
| [`Features/Terminal/Hosting/TerminalPaneMountView.swift`](../../../Sources/AgentStudio/Features/Terminal/Hosting/TerminalPaneMountView.swift) | Terminal mounted content (displays surfaces, does not own them) |
| [`App/Boot/AppDelegate.swift`](../../../Sources/AgentStudio/App/Boot/AppDelegate.swift) | Launch flow — restore workspace, create window |

## Related Documentation

- **[Architecture Overview](../README.md)** — System overview and document index
- **[Component Architecture](../structure/component_architecture.md)** — Data model, service layer, data flow, persistence
- **[Surface Architecture](ghostty_surface_architecture.md)** — Surface ownership, state machine, undo close, health monitoring
- **[App Architecture](../hosting/appkit_swiftui_architecture.md)** — AppKit + SwiftUI hybrid, per-tab hosting, ViewRegistry slots
- **[zmx Terminal Integration](../archive/zmx_terminal_integration_lessons.md)** — Two-terminal problem, OSC 133 fix, design principles
- **[Remote zmx Architecture Ideas](../archive/remote_zmx_architecture_ideas.md)** — SSH tunnel architecture, fork strategy
