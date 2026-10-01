# AgentStudio IPC Architecture

AgentStudio app IPC is the app-level programmatic-control boundary for local
automation, pane agents, and future MCP adapters. It exposes semantic app
methods over local transports without exposing zmx daemon IPC as a public API.

Command verbs, labels, and `ipcSpec` classification live in
[Command Specs](command_specs.md) — not in this transport document. Adding a
**command.execute** verb requires classifying `ipcSpec` on an `AppCommand` in
the same change. Transport methods (`command.list`, `pane.*`, `terminal.*`,
`events.subscribe`, auth) live in the IPC registry and are not `AppCommand`
cases.

## Status

This section is a transport inventory, not a command catalog. Verbs live in
[Command Specs](command_specs.md). Do not add a `command.execute` RPC without
`AppCommand.ipcSpec`. Do not invent a dummy `AppCommand` for `pane.*` /
`terminal.*` / `events.subscribe`.

The phase-1 foundation currently owns:

- SwiftPM target split for transport, public contracts, and app IPC services.
- JSON-RPC 2.0 request/response and server-notification codec over
  newline-delimited JSON frames.
- Unix-domain socket transport primitives and peer-credential checks.
- Socket path and runtime metadata trust checks.
- Subject-token authentication, principal registry, and redaction helpers.
- Debug-only unsafe no-auth mode and debug-token escrow mode for local live
  control proof. Both are gated to debug runtime channel composition and are not
  beta/stable access modes.
- Phase-1 method catalog, handle parsing, authorization, grant ledger, and
  permission broker policy/delegation primitives.
- Concrete app query adapter for system/window/workspace/pane read snapshots.
- Concrete layout adapter for `pane.focus`, `pane.split`, `pane.close`,
  `drawer.addPane`, and `drawer.toggle` through existing app/workspace action
  owners.
- Layout-control stability guard: terminal panes created by split/drawer
  control get placeholder hosts before entering visible layout, and recoverable
  restored missing-host gaps are logged instead of terminating the debug app.
- Concrete terminal runtime adapter for `terminal.status`,
  `terminal.snapshot`, and `terminal.send`.
- Explicit command/UI split: `command.list` projects each `AppCommand` through
  `AppCommandSpec` (label) plus independent `ipcSpec` (exposure, targets,
  privilege, arguments). `command.execute` remains reserved for commands whose
  `ipcSpec.exposure` is `.headless` or `.headlessAndInteractive`. UI presentation lives under
  `ui.commandBar.open` with `uiPresent` authority.
- Generic app-owned IPC contribution substrate for feature-local method
  definitions under approved app composition folders. The substrate merges
  contributed methods with the base registry, validates namespaces/security
  contracts, and dispatches through typed app ports instead of feature imports.
- App-owned Unix socket server lifecycle from `AppDelegate`, including runtime
  metadata publication, same-UID peer gate, pre-auth ping/login, per-connection
  principals, request dispatch, and shutdown cleanup.
- Debug launcher support for owner-only IPC roots, a short trusted socket
  directory, and explicit forwarding of debug IPC auth environment variables.
- DEBUG-only `ipc-terminal-smoke` startup diagnostic that opens a floating
  terminal through the app owner and records success only after the terminal
  has a view, surface reference, mounted surface, valid geometry, and ready
  runtime proof.
- Pane-agent bootstrap primitive that delivers a single-use subject token
  through a close-on-exec file descriptor while environment variables carry
  only socket/runtime routing metadata.
- App-owned pane-agent launch owner under [`App/PaneAgents`](../../../Sources/AgentStudio/App/PaneAgents) that remaps exactly
  one bootstrap fd into `agentstudio-pane-agent` with
  `POSIX_SPAWN_CLOEXEC_DEFAULT`.
- `agentstudio-pane-agent` helper executable that reads the bootstrap fd once,
  closes it, authenticates with `auth.login`, and verifies the runtime id via
  `system.identify` without importing app/server targets.
- Bound-principal invalidation on the IPC server that revokes pane-bound tokens
  and closes authenticated sockets for that pane principal.
- Public event-name contracts and permission-event DTOs for phase-1 exported
  notifications.
- Permission recovery queries for requester-owned request/grant state and
  delegated approval visibility.
- Event broker subscription state, notification encoding, visibility filtering,
  inbound server-event rejection, and slow-subscriber ejection.

The remaining app integration boundaries are:

- pane-agent lifecycle integration:
  `PaneAgentLaunchOwner` can launch and authenticate the helper through the fd
  bootstrap path, and `AgentStudioAppIPCServer.invalidatePrincipals(...)` can
  tear down bound-principal socket authority. The real pane close/child-exit
  owner still needs to call that revocation seam and own auth-timeout
  diagnostics.
- terminal completion/readback proof:
  live debug proof shows app IPC can identify the debug runtime, reject
  command-bar presentation through `command.execute`, present command-bar
  scope through `ui.commandBar.open`, split panes, create drawer panes, toggle
  drawers, and verify generic debug observability. A clean `ipc-terminal-smoke`
  launch can request and dispatch the startup diagnostic, but current proof
  blocks before terminal command control when Ghostty surface creation fails to
  mount (`terminal_view.count=1`, `surface_reference.count=0`, `surface.count=0`,
  `valid_geometry.count=0`). Earlier terminal proof showed `terminal.status`,
  `pane.focus`, `terminal.send`, and `terminal.wait(titleChanged,
  afterSequence:)` can reach a ready runtime through the debug app socket. The
  current required follow-up is to restore reliable terminal surface readiness,
  then prove shell command completion, shell output, cwd changes, or prompt
  readiness through exported events.

## Target Ownership

```
AgentStudioIPCTransport
  Owns:     Unix socket primitives, NDJSON framing, JSON-RPC codec,
            peer-credential lookup.
  Imports:  Foundation, Darwin.
  Must not: Import AgentStudio, app state, runtime owners, or product models.

AgentStudioProgrammaticControl
  Owns:     Public semantic contracts: handles, principals, scopes,
            method metadata, permission DTOs, schema descriptions.
  Imports:  Foundation.
  Must not: Import SwiftUI/AppKit, AgentStudio, app state, or concrete runtime
            owners.

AgentStudioAppIPC
  Owns:     App IPC service shell, socket path trust, authentication,
            method registry, authorization, grant ledger, permission broker,
            event broker, app-method contribution validation/dispatch, and
            protocol ports into app/runtime owners.
  Imports:  Transport and ProgrammaticControl targets.
  Must not: Import concrete app/runtime owner types or read atoms directly.

AgentStudio/App/Boot + AgentStudio/App/IPCComposition
  Owns:     AppDelegate server composition/lifecycle plus concrete port adapters
            from AgentStudioAppIPC protocols into WorkspaceSurfaceCoordinator,
            RuntimeRegistry, PaneRuntime, app state owners, and app-owned
            feature contribution registration.
  Imports:  AgentStudioAppIPC plus the concrete app modules it adapts.

AgentStudioIPCClientCore
  Owns:     CLI socket discovery, command-to-JSON-RPC request mapping, and
            Unix socket calls/streams for smoke/use.
  Imports:  AgentStudioIPCTransport, AgentStudioPrimitives, and
            AgentStudioProgrammaticControl.
  Must not: Import AgentStudioAppIPC, AgentStudioInfrastructure, or the
            AgentStudio executable target.

AgentStudioIPCClient
  Owns:     `agentstudio-cli` entrypoint and early worktree/IPC dispatch.
  Imports:  AgentStudioIPCClientCore, AgentStudioPrimitives,
            AgentStudioProgrammaticControl and AgentStudioWorktreeOperations.
  Must not: Import app/runtime owner targets, or AgentStudioInfrastructure.
```

The executable remains a leaf target. `AgentStudioWorktreeOperations` depends
on `AgentStudioGit` and `AgentStudioPrimitives` for local Git operations. Keep
`AgentStudioInfrastructure` out of the CLI dependency graph: it also brings
GRDB, Logging, Metrics, Tracing, OTel and ServiceLifecycle, along with the app's
AppKit, SwiftUI, WebKit and SQLite dependencies. Shared Foundation-only helpers
stay in `AgentStudioPrimitives`, which Infrastructure re-exports.
`CommandLineClientLeafTargetArchitectureTests` pins the allowed imports of all
four CLI-side targets.

The target split is intentionally stricter than the folder split. A file in
`AgentStudioProgrammaticControl` cannot accidentally call app code because the
compiler has no dependency edge for it. `AgentStudioAppIPC` can define ports and
own policy, but concrete behavior enters through protocol implementations in
the app target.

## Query Snapshot Boundary

Phase-1 read methods are served through `AgentStudioIPCQueryAdapter` in
`AgentStudio/App/IPCComposition`. The adapter does not read atoms directly. It
depends on two snapshot seams:

```
AppIPC query method
  -> AgentStudioIPCQueryAdapter
  -> WorkspaceStore.programmaticControlSnapshot()
       owns atom reads inside WorkspaceStore
  -> WorkspaceWindowLifecycleReading.snapshot()
       owns window lifecycle atom reads outside IPC composition
  -> AgentStudioProgrammaticControl DTO
```

The query adapter intentionally exposes a sanitized app-level view. Pane
snapshots include stable app identity facts such as pane id, content kind,
residency, active state, tab id, repo id, and worktree id. They do not include
titles, raw URLs, cwd paths, command lines, terminal buffers, zmx session ids, or
backend daemon details. Terminal content requires the dedicated terminal runtime
adapter and stricter terminal privileges in later slices.

## Layout Boundary

Layout methods are app-control methods, not atom mutations. Phase 1 routes
focus through the existing focus seam and structural mutations through the
workspace action executor seam:

```
pane.focus
  -> AgentStudioIPCLayoutAdapter
       verifies active workspace window
       resolves pane handle by UUID or friendly ordinal
  -> PaneFocusAppControlling
  -> PaneTabViewControllerPaneFocusAppControl
       validates pane belongs to a tab and has a native host
  -> PaneTabViewController.submitTargetedPaneFocus(...).value
       awaits the exact submitted focus operation
  -> existing PaneFocusTrigger / PaneFocusOrchestrator / PaneFocusExecutor path

pane.split / pane.close / drawer.addPane / drawer.toggle
  -> AgentStudioIPCLayoutAdapter
       verifies active workspace window
       resolves pane handle by UUID or friendly ordinal
       resolves owning tab where the action requires it
  -> WorkspaceActionExecutor.execute(WorkspaceActionCommand)
  -> existing PaneTabViewController / workspace mutation owner path
```

This split keeps IPC responsible for protocol concerns and keeps layout
behavior owned by the existing app/workspace action pipeline. The adapter maps
no-active-window, missing-target, and validation-rejected outcomes into AppIPC
layout errors so the JSON-RPC layer can publish stable error codes without
reaching into controller internals.

Programmatic layout methods must preserve the pane-host invariant that the UI
renderer depends on: a terminal pane needs a `ViewRegistry` slot and placeholder
host before it is exposed through a tab or drawer layout. The coordinator owns
that ordering because it is the component that mutates pane graph membership and
creates terminal views. The render layer still logs unexpected missing-host
state for restore/debugging, but it must not crash a live debug app while IPC
automation is exercising recoverable layout state.

## Command And UI Presentation Boundary

IPC command methods and UI presentation methods are intentionally separate.
`command.list` is command discovery. It enumerates `AppCommand.allCases` and
projects `AppCommandSpec` labels plus the independent `ipcSpec` contract
(execution modes, durable handle kinds, privileges, argument schema) into a
typed IPC list entry. This keeps one command identity: do not hand-write a
second IPC verb catalog.

`command.execute` is reserved for headless semantic command execution. It must
not present the command bar, picker UI, sheets, or prompts as an implicit side
effect. A command-spec row that requires UI presentation or interactive input
fails closed with a stable `requires presentation` or `parameters required`
error until a semantic method with explicit parameters exists. Commands execute
only when `AppCommand.ipcSpec.exposure` is `.headless` or
`.headlessAndInteractive`. `AppCommandSpec` has no headless field; it forwards
`ipcExposure` from `ipcSpec`. The adapter validates
`command.ipcSpec.argumentContract` before active window lookup or shell-owner
dispatch. The initial narrow argument shape is a
string enum, used by `setRepoSidebarSortOrder` with `order = ascending |
descending`; broader JSON Schema, nested objects, or command-bar selection state
require a new spec/design pass. The public command-id wrapper remains open so
future command ids and version-skewed clients can fail with `unsupported
capability` instead of parameter-decoding errors.

```
command.list / command.execute
  -> AgentStudioIPCCommandAdapter
       lists AppCommand.allCases with AppCommandSpec labels + ipcSpec
       rejects non-headless ipcSpec exposure for command.execute
       validates typed string-enum arguments from ipcSpec
  -> injected shell/app command owner
  -> AgentStudioProgrammaticControl DTO

ui.commandBar.open
  -> AgentStudioIPCUIPresentationAdapter
  -> AgentStudioIPCUIPresenting
  -> AppDelegate command-bar presenter
  -> CommandBarPanelController
```

`ui.commandBar.open` is useful automation, but it is presentation, not command
completion. Its result proves that the app presenter accepted a scope for a
workspace window; it does not claim that a command was selected or applied.
Because phase 1 has no public window target, `ui.commandBar.open` is authorized
only against app scope. Pane-scoped `uiPresent` grants must not drive whichever
workspace window happens to be focused.
Structural operations such as `pane.split` and `drawer.addPane` are not routed
through command-bar UI because they have explicit target and mode parameters.
Picker-oriented flows, such as repo/worktree selection, should stay under
`ui.commandBar.open(scope: repos)` until they have a semantic method contract.

## Sidebar Semantic Boundary

Repo Explorer grouping uses the generic command IPC path. Runtime proof and
automation call `command.execute` with headless Repo grouping commands, then
use the read-only sidebar methods for state inspection:

- `command.execute(commandId: setRepoSidebarGroupingRepo|setRepoSidebarGroupingPane|setRepoSidebarGroupingTab)`
- `sidebar.grouping.get(surface: repo)`
- `sidebar.surface.get()`

Repo grouping accepts only `repo`, `pane`, and `tab` because those are the only
grouping commands exposed as headless commands. `sidebar.surface.get()` always
reports Repo Explorer. A stale Inbox-valued grouping query is rejected before
feature state is read. Retained Inbox command identities are not exposed over
IPC. The `sidebar.*.get` methods are query-only read-back surfaces;
`sidebar.grouping.set` and `sidebar.surface.set` are not registered IPC methods.

These command and read methods require authenticated IPC. Debug-token escrow
creates the local automation principal used by verifier scripts. Unsafe no-auth
debug sockets do not get sidebar method access, so proof cannot accidentally
pass through the broader unsafe path.

## App IPC Contribution Boundary

Phase A lets app-owned composition register additional IPC methods without
moving feature behavior into the central IPC service. Contributions live under
approved `Sources/AgentStudio/App/IPCComposition/...` folders, carry a typed
method definition plus security contract, and dispatch through an
`AppIPCContributionDispatchContext` that exposes only narrow ports such as the
query adapter and handle decoder.

```
feature-owned capability idea
  -> app-owned contribution file under App/IPCComposition/<Feature>/
       declares method definition and authorization target vocabulary
  -> AgentStudioAppIPC registry merge
       rejects duplicate/base-owned namespaces and pre-auth contributors
  -> AgentStudioAppIPC authorization
       evaluates principal kind, grants, and target handles
  -> contribution dispatch context
       calls typed app port; never imports feature code into AppIPC
```

The first concrete contribution is `pane.snapshot`. It is registered by app
composition, canonicalizes friendly pane handles before authorization, and
dispatches to the query port. Future feature methods such as Bridge review/diff
controls should follow the same ownership pattern from their own worktree:
feature-specific method files live in app composition, while the shared
`AgentStudioAppIPC` substrate remains generic and unaware of Bridge internals.

## Terminal Runtime Boundary

Terminal runtime methods are runtime/app-control methods, not shell-completion
or terminal-buffer APIs. Phase 1 routes them through `AgentStudioIPCRuntimeAdapter`:

```
terminal.status / terminal.snapshot
  -> AgentStudioIPCRuntimeAdapter
       resolves pane handle by UUID or friendly ordinal
       requires a terminal pane
  -> RuntimeRegistry.runtime(for:)
  -> PaneRuntime.snapshot()
  -> allowlisted AgentStudioProgrammaticControl DTO

terminal.send
  -> AgentStudioIPCRuntimeAdapter
       resolves pane handle by UUID or friendly ordinal
       requires a terminal pane and registered runtime
  -> PaneRuntimeCommandDispatching
  -> WorkspaceSurfaceCoordinator.dispatchRuntimeCommand
  -> RuntimeRegistry.runtime(for:)
  -> PaneRuntime.handleCommand(...)

terminal.wait
  -> AgentStudioIPCRuntimeAdapter
       resolves pane handle by UUID or friendly ordinal
       requires a terminal pane and registered runtime
  -> PaneRuntime.eventsSince(afterSequence)
  -> PaneRuntime.subscribe()
  -> allowlisted terminal wait result
```

The socket server canonicalizes pane handles to concrete pane ids before
authorization. Friendly ordinals remain workspace-local convenience handles, but
they do not collapse to `selfPane`; a pane-bound principal needs an explicit
grant before a `pane:N` handle can operate on a different pane.

`terminal.send` success means the runtime command path accepted the input bytes.
It does not mean the shell command completed, produced output, or reached a
particular prompt. Those higher-level observations belong to `terminal.wait`
conditions and runtime events.

`terminal.wait` resolves only stable exported facts. `attachReady` is currently
proven from a ready registered runtime. `titleChanged` is product-proven through
`terminal.wait(titleChanged, afterSequence:)` after an accepted `terminal.send`
call. `commandFinished`, cwd/readback, prompt-readiness, and broader shell
completion remain follow-up runtime facts. Wait results must carry only
command/correlation ids and safe scalar data such as exit code, duration, and
renderer health; they must not expose terminal titles, cwd paths, or progress
payload text.

For cursor-bearing waits, the adapter subscribes to the owning runtime before
checking runtime replay so an event cannot fall between the replay read and live
subscription. `afterSequence` is a strict floor for both replayed and live
events, and a replay gap maps to a stable `replay gap` error so callers refresh
their terminal snapshot instead of attributing a later event to an old command.

The terminal DTOs intentionally omit terminal output, scrollback, raw PTY bytes,
cwd/launch paths, command lines, zmx session identifiers, raw runtime objects,
and content-bearing UI state such as search/progress details. The adapter maps
missing panes, missing runtimes, runtime-not-ready, unsupported command,
backend-unavailable, validation-rejected, and timeout outcomes into AppIPC
runtime errors for the future JSON-RPC layer.

## Event And Permission Recovery Boundary

Phase 1 exposes a stable event vocabulary in `AgentStudioProgrammaticControl`.
The exported names are semantic app/runtime facts, not internal enum cases:

```
permission.requestCreated
permission.requestResolved
permission.grantRevoked
permission.grantExpired
terminal.attachReady
terminal.commandFinished
terminal.rendererHealthy
terminal.titleChanged
terminal.cwdChanged
terminal.progressChanged
```

Live subscriptions are owned by `IPCEventBroker` in `AgentStudioAppIPC`:

```
events.subscribe
  -> authenticated connection principal
  -> AuthorizationService(eventsRead, target scope)
  -> IPCEventBroker.subscribe(...)
       stores subscription id, principal, allowed event names, subscriber sink

public app/runtime fact
  -> IPCEventNotification
  -> IPCEventBroker.publish(...)
       filters by event-name allowlist
       filters by principal visibility
       encodes JSON-RPC events.notification frame
       removes subscribers that report backpressure or delivery failure

events.unsubscribe
  -> authenticated connection principal
  -> IPCEventBroker.unsubscribe(...)
       succeeds only for a subscription owned by the same principal
```

The broker does not approve grants, mutate app state, or inspect raw runtime
envelopes. It receives already-projected public DTOs and an explicit visibility
predicate from the owning projector. Client-sent `events.notification` frames
and frames whose method is a server event name are rejected as reserved inbound
notifications; event notifications are server-to-client facts only.

Permission event payloads are built from broker records and scoped through
`PermissionEventProjector`. Visibility is intentionally narrower than ordinary
event subscription:

```
permission record
  -> PermissionEventProjector
  -> requester principal
       always sees its own request/grant events
  -> delegated approver principal
       sees routed requests only when token authority covers the full scope
  -> app/policy approval principal
       sees app/human approval requests only when policy authority covers scope
  -> unrelated principal
       sees nothing
```

Missed permission events are recoverable through explicit queries rather than a
durable event log. Requesters recover their own state through
`permission.requestStatus` and `permission.grantStatus`; delegated approvers
recover routed pending requests through `permission.pendingApprovals`.

## Request Authority Path

```
local client
  -> Unix socket + NDJSON frame
  -> JSON-RPC request
  -> peer credential gate
  -> auth.login / subject token check
  -> IPCPrincipal
  -> AppIPCMethodRegistry
  -> target handle canonicalization
  -> AuthorizationService
       baseline self-pane privileges
       + GrantLedger elevated grants
  -> AppIPC port protocol
  -> App/IPCComposition adapter
  -> app/runtime owner
```

IPC methods are not command-bus messages. The app IPC layer validates method
identity, principal authority, target scope, and grants before calling the
smallest app-owned protocol port that can satisfy the operation.

The live app listener is composed by [`AppDelegate+IPC.swift`](../../../Sources/AgentStudio/App/Boot/AppDelegate+IPC.swift) after workspace
boot wires lifecycle consumers. It writes runtime metadata under
`AppDataPaths.rootDirectory()/ipc`, refuses to steal an existing live socket,
unlinks only stale dead sockets, and stops before termination persistence drains
so new clients cannot race shutdown.

## CLI Boundary

The `agentstudio-cli` Swift executable is bundled at
`AgentStudio.app/Contents/Helpers/agentstudio`. Its product name stays distinct
from `AgentStudio`: on a case-insensitive volume, a product named `agentstudio`
shares one build-directory file with the app executable, and
`Contents/MacOS/agentstudio` is the same path as
`Contents/MacOS/AgentStudio`. The entrypoint checks the first user argument
before it constructs the IPC runner or reads the process environment:

```
agentstudio-cli executable (bundled as Contents/Helpers/agentstudio)
  -> AgentStudioIPCClient (early dispatch)
       argv[1] == "worktree" -> WorktreeCommandLine
         -> AgentStudioWorktreeOperations
           -> LibGit2AgentStudioGitLocalClient (in-process, libgit2)
           -> AgentStudioPrimitives
       other arguments -> AgentStudioIPCClientCommandLineRunner
         -> local provider/package commands
         -> AgentStudioIPCClientCore
           -> AgentStudioIPCTransport and AgentStudioProgrammaticControl
```

`agentstudio worktree new`, `fork`, `list`, `remove`, and `prune` use the local
Git client inside the CLI process. They do not read IPC credentials, open the
app socket, or use app permissions. Other arguments continue through the
existing command-line runner, which handles local provider/package commands
and sends app-backed methods through `AgentStudioIPCClientCore`.

```sh
agentstudio worktree new feature/cleanup --repo /path/to/repository
agentstudio worktree fork feature/experiment --from /path/to/repository
agentstudio worktree list --repo /path/to/repository
```

`--repo` and `--from` accept a folder inside the relevant worktree. Without
either option, the command starts from the current directory. `--from-branch`
starts `new` at the tip of an existing local branch and creates a new branch.
`fork` copies the current worktree by default; `--changes-only` carries tracked
changes and eligible untracked files without ignored files. `list` accepts
optional worktree or branch targets and reports working-change, integration,
evidence, lock, and removal-readiness state. `remove` accepts one or more
targets. `prune` previews eligible linked worktrees by default; `--apply`
performs the removals.

| Command | Options |
| --- | --- |
| `new <branch>` | `--repo <path>`, `--from-branch <local-branch>`, `--json` |
| `fork <branch>` | `--from <worktree-path>`, `--changes-only`, `--json` |
| `list [target...]` | `--repo <path>`, `--no-fetch`, `--json` |
| `remove <target...>` | `--repo <path>`, `--no-fetch`, `-f` / `--force`, `-D`, `--no-delete-branch`, `--archive-to-main`, `--archive-to <path>`, `--discard-tmp`, `--remove-stale-lock`, `--dry-run`, `--json` |
| `prune` | `--repo <path>`, `--no-fetch`, `--archive-to-main`, `--archive-to <path>`, `--apply`, `--json` |

`-f` and `--force` are aliases for discarding working changes during
`remove`. `-D` permits deletion of a branch with remaining contribution;
`--no-delete-branch` keeps the branch. `--archive-to-main` and
`--archive-to <path>` copy `tmp/` evidence before removal. `--discard-tmp`
discards that evidence. `--remove-stale-lock` removes an identified stale lock
after checking its identity and age. `--dry-run` reports the removal plan
without changing the worktree lifecycle; the automatic fetch still runs unless
`--no-fetch` is supplied. `prune` accepts neither `-f` / `--force` nor `-D`.
Its only mutation option is `--apply`.

The worktree commands use these exit codes:

| Code | Meaning |
| --- | --- |
| 0 | Creation or listing succeeded. Removal has no refused or failed entry. Prune has no failed entry; skipped worktrees do not change its exit code. |
| 1 | Creation or fork was refused, or removal includes a refused entry and no entry failed. A dry-run target that cannot be resolved also returns 1. |
| 2 | A command failed, a removal entry failed, or a prune entry failed. |
| 64 | Malformed arguments. One usage line goes to stderr; stdout stays empty, including with `--json`. |

The IPC client remains a client surface. It cannot import `AgentStudioAppIPC`
or the app executable target, so it cannot bypass authentication,
authorization, grants, or app/runtime owner ports.

IPC bearer tokens must not be passed as argv. Explicit interactive or
automation auth uses `--token-stdin`; app-spawned pane agents receive their
pane-bound credential through an explicitly remapped bootstrap fd owned by
`PaneAgentLaunchOwner`.

The current IPC client surface includes query/control verbs for debug proof:
`auth-status`, `identify`, `capabilities`, `list-windows`, `list-workspaces`,
`list-panes`, `pane-focus`, `pane-snapshot`, `terminal-status`, `terminal-snapshot`,
`terminal-send`, `terminal-wait`, `command-list`, and `command-execute`.
`command-execute` is intentionally narrow: it accepts open string command ids so
version-skewed clients get `unsupported capability` instead of parameter decode
failure, but only allowlisted headless semantic ids may execute. Current
command-bar-backed rows return `requires presentation`. Direct JSON-RPC clients
can pass headless command arguments through the `arguments` object, for example
`{"commandId":"setRepoSidebarSortOrder","arguments":{"order":"descending"}}`.
They can also call the app-level method registry, including
`ui.commandBar.open`, `pane.split`, `pane.close`, `drawer.addPane`, and
`drawer.toggle`, subject to authentication and authorization.

## Auth And Permissions

Authentication and authorization are separate:

- Authentication proves the caller is a known local principal.
- Authorization decides whether that principal can use a method against a
  target and data scope.

Phase 1 uses opaque subject tokens issued by the app. Spawn environments may
carry non-secret routing metadata such as socket path, runtime id, and a
bootstrap fd number, but they must not carry bearer tokens. The bootstrap
factory marks both pipe ends close-on-exec; `PaneAgentLaunchOwner` uses
`posix_spawn` with `POSIX_SPAWN_CLOEXEC_DEFAULT` and one `dup2` action so only
the intended bootstrap fd is inheritable in the pane-agent helper. If the
parent-side read fd already equals the child bootstrap fd number, the launch
owner first duplicates it to a staged close-on-exec fd and then maps that staged
fd into the child; this avoids accidentally closing the only readable token fd
while preparing spawn actions. A spawned pane agent receives its pane-bound
credential by reading that fd once through `AgentStudioIPCBootstrapTokenReader`;
`auth.login` binds the token to the principal recorded in the registry, and the
caller cannot upgrade itself by passing a different pane hint. Tokens are
single-use in the current phase-1 foundation so replayed bearer material cannot
create a second connection-bound principal after first login.

Debug channel composition has two explicit proof modes:

- unsafe no-auth: `AGENTSTUDIO_IPC_UNSAFE_NO_AUTH=1` creates an
  `.unsafeDebugClient` principal per connection only when the server channel is
  debug.
- debug credential escrow: `AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW` names an
  owner-only 0600 file. When the debug IPC service becomes ready the app mints
  one reusable credential, admits its SHA-256 verifier to the in-memory
  principal registry for the runtime's lifetime, and writes the runtime ID,
  socket path and raw credential into that file as JSON. The credential is
  never persisted; shutdown drops the verifier and deletes the file. Every CLI
  call exercises the same `auth.login` path as real clients.

Both modes use the debug unsafe method allowlist, cannot grant
`.debugUnsafe`, and must be ignored by beta/stable channel composition.

Baseline authority is intentionally small. A pane-bound agent gets self-pane
authority for low-risk introspection and scoped terminal operations. Anything
outside that baseline requires an explicit grant.

Phase 1 denies requested `layoutMutate` grants through `permission.request`
because the reusable grant ledger is principal-scoped and durable across
reconnects. Cross-pane or app-wide layout mutation requires a later
connection-bound or one-shot grant model before it can be approved outside
unsafe debug proof.

Permission requests flow through the permission broker:

```
permission.request
  -> canonical permission scope
  -> policy store
       approve | deny | ask
  -> optional human approval port or delegated approver principal
  -> GrantLedger state transition
  -> permission event notification
```

Delegated approval is part of the configured authority model, not a loophole in
the request path. A principal may approve only when its token/policy gives it
approval authority for the full requested scope: privilege, target, and data
scope. Self-approval fails closed unless a future design explicitly adds and
audits that policy.

Permission data scope is derived server-side from the requested privilege during
canonicalization. Clients may ask for a scope, but they do not get to choose a
grant key that differs from the authorization key the server will later check.

Human approval is app-owned through `AppIPCPermissionApprovalPort`. The broker
can route a `.humanPrompt` request to that port, but the port implementation
belongs in the app composition layer so the reusable AppIPC target does not
import concrete UI owners. The current app-owned port returns `.ask`, leaving
requests pending until an explicit app/user/policy approver flow is implemented.

## Boundary Rules

- Do not expose public `zmx.*` methods from AgentStudio app IPC.
- Do not route IPC commands through `EventBus`; events remain facts and
  notifications.
- Do not mutate atoms directly from IPC services or composition adapters.
- Do not put concrete app/runtime owner imports in `AgentStudioAppIPC`.
- Do not implement MCP in the phase-1 IPC server. MCP should be an adapter over
  the same semantic method registry after the local RPC contract is stable.

Product capabilities such as Bridge follow the same semantic port pattern. IPC
exposes typed product methods such as `bridge.diff.*`, `bridge.fileTree.*`,
`bridge.fileView.*`, and `bridge.telemetry.*`, but it must not expose renderer
transports such as raw WebKit JavaScript evaluation, raw BridgeWeb post
messages, app event-bus command routing, raw filesystem paths, or backend-daemon
namespaces. IPC owns authentication, authorization, handle resolution, and
permission checks. The product capability owner decides how to satisfy the
request and whether any renderer transport needs to be updated.

## Enforcement

Compile-time target boundaries provide the first guardrail:

- `AgentStudioIPCTransport` has no product dependency.
- `AgentStudioProgrammaticControl` has no app dependency.
- `AgentStudioAppIPC` depends on ports, not concrete app/runtime owners.

Architecture lint provides the second guardrail:

- `agentstudio_ipc_programmatic_control_boundary`
- `agentstudio_appipc_port_boundary`
- `agentstudio_ipc_composition_location`
- `agentstudio_ipc_public_surface_sanitization`
- `agentstudio_ipc_no_direct_atom_access`

Architecture docs are the third guardrail. They should explain intent and
tradeoffs, but compile-time dependencies and lint rules are the blocking
controls.
