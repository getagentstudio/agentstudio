# Agent IPC v2 and Agent Package — Program Design

Date: 2026-09-16. Source baseline: `ipc-improvements@d93f2755`. **Amended 2026-10-07** (owner, finding #6; stopgap until a daemon owns pane tokens): issuance after IPC readiness schedules the verifier's persistence (verifier continuity below).
Requirements: [user-requirements.md](user-requirements.md).
Specification: [specification.md](specification.md).
Decisions: [decision-record.md](decision-record.md).

## Integrated design

Keep the Unix socket, typed App ports, command identities, workspace mutation
pipeline and prepared application-local SQLite database. ProgrammaticControl
owns shared method descriptors. The server registers them with handlers; the
bundled Swift `agentstudio` CLI compiles those same definitions for invocation,
validation and help. ClientCore remains the Swift transport/client library.
Sessions owns report ingestion, evidence reduction, durable messages and queries.
App composition joins these owners and recovers offline notifications after IPC readiness without a new UI.
Normal IDE startup and terminal creation/attachment never await that work.

```text
Provider hooks / installed model skill
                 |
      agentstudio CLI + retained ClientCore
        |                   |
        | notification only | shared compiled descriptors
        v                   v
 owner-only spool    Unix socket -> AppIPC admission
        |                          |             |
        +---- IPC recovery drain --+             |
                              App typed ports    |
                              /             \    |
                    SessionsIngestion      debugTesting adapter
                         |                       |
                reducer + repository       existing command/runtime owners
                         |
                  Core prepared SQLite
                         |
                 Sessions query / explicit acknowledgment

Typed terminal facts -> Contract 7 -> named App subscriber -> SessionsIngestion
Stable/beta registry excludes debugTesting; pane authority cannot enable it.
```

Transport receipt, queued notification, durable admission and current evidence are
separate outcomes. A queued notification survives through files until database
commit; a late fact never acquires current authority merely by arriving later.

## Current foundation

| Current source | Observed behavior and consequence |
| --- | --- |
| [IPC boot](../../../Sources/AgentStudio/App/Boot/AppDelegate+IPC.swift) | Currently composes adapters, catalog, service and socket synchronously after window presentation but before post-presentation boot continues. Move catalog/filesystem/socket and optional persistence readiness out of the first-frame and terminal-activation paths. |
| [Server](../../../Sources/AgentStudioAppIPC/AgentStudioAppIPCServer.swift), [typed registration](../../../Sources/AgentStudioAppIPC/AppIPCTypedMethodRegistration.swift) | Peer UID, frames, authenticated connection context, typed target resolution/authorization and typed ports exist. Keep this listener/registry; add Sessions methods and retain hash-based pane credential verification through it. |
| [Contracts](../../../Sources/AgentStudioProgrammaticControl/IPCContracts.swift) | Typed schemas, examples, target kinds, relationships and channel exposure metadata now compile into the registry. Continue the same descriptor system for the remaining report/package surface; do not create another catalog. |
| [Authentication](../../../Sources/AgentStudioAppIPC/AgentStudioIPCAuthentication.swift), [continuity resolver](../../../Sources/AgentStudio/App/PaneAgents/IPCContinuityCredentialResolver.swift) | The principal registry currently owns in-memory leases/invalidation while the resolver performs exact durable verifier lookup. Extend that same registry with current-runtime pane-verifier admission, retain durable fallback for older tokens, then check canonical membership and lease validity. Keep hash-only verification and use `.automationSameUser` for authenticated diagnostic clients. |
| [Terminal startup](../../../Sources/AgentStudio/App/Coordination/WorkspaceSurfaceCoordinator+ViewLifecycle.swift), [surface](../../../Sources/AgentStudio/Features/Terminal/Ghostty/GhosttySurfaceView.swift) | Terminal construction consumes supplied environment. Restoration is reattachment to the existing zmx shell, so it retains the shell's original environment/token and adds no credential replacement or mount coordination. |
| [Zmx backend](../../../Sources/AgentStudio/Core/RuntimeEventSystem/Runtime/ZmxBackend.swift) | The pinned zmx attach loop (`src/main.zig:695-737`) reuses an existing daemon/session when present. The daemonization path (`src/daemonize.zig:43-76`) inherits supplied environment only when it creates a genuine new shell. No vendor change, restore-time probe or running-shell environment rewrite is selected. |
| [Retained-surface Undo](../../../Sources/AgentStudio/App/Coordination/WorkspaceSurfaceCoordinator+Undo.swift) | Close retains the existing shell/surface and Undo remounts it. Canonical membership therefore denies the same credential while closed and restores eligibility on Undo; final discard/expiry permanently revokes it. No persisted suspended state is added for renderer retention. |
| [IPC projection](../../../Sources/AgentStudio/App/Commands/AppCommand+IPCProjection.swift), [dispatcher](../../../Sources/AgentStudio/App/Commands/AppCommandDispatcher.swift) | Exhaustive AppCommand classification and execution remain their respective owners. Extend typed headless arguments without a second command identity catalog. |
| [Datastore actor](../../../Sources/AgentStudio/Core/State/SQLite/WorkspaceSQLiteDatastoreActor.swift), [local migrations](../../../Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceLocalMigrations.swift) | Owns the one prepared local database and neutral application-local read/write entries. Sessions and IPC migrations are currently in the pre-window full migrator. Split registration into boot-required and optional full-migrate sets while preserving this owner/writer. |
| [Pane identity](../../../Sources/AgentStudio/App/PaneAgents/PaneIPCIdentityOwner.swift), [Sessions ingestion](../../../Sources/AgentStudio/Features/Sessions/Runtime/SessionsIngestion.swift) | Identity persistence and Sessions domain/repository code exist but have no production object consumer. Pane identity remains IPC-owned and hash-only; replace the identity owner's current prepare/activate-per-mount lifecycle with one cached environment token per logical pane/app runtime, while terminal code only copies that environment. Compose Sessions after optional schema readiness. |
| [Client core](../../../Sources/AgentStudioIPCClientCore/AgentStudioIPCClientCore.swift), [arguments](../../../Sources/AgentStudioIPCClientCore/AgentStudioIPCClientArguments.swift), [package](../../../Package.swift) | Retain framing, response-ID validation and client library/test ownership. Replace hand-mapped phase-1 verbs with descriptor-driven parsing; reuse the thin executable target for the agentstudio product. |

The old debug client required hand-mapped verbs, manually assembled JSON and
socket/token-input ceremony; incomplete schemas could not explain valid calls.
Shared typed descriptors supply executable help and correction data. Pane env supplies agent context; debug invocation automatically discovers trusted
runtime metadata and ClientCore reads the reusable credential on each call,
without token argv or manual socket/path assembly. This removes
repeated plumbing while preserving the server's channel and authority gates.

## Owners and placement

```text
Component / placement                       Responsibility and reason to change

IPCMethodDefinition + typed schema          Protocol shapes, model-call metadata,
  AgentStudioProgrammaticControl            exposure, examples; protocol evolution

agentstudio thin executable                 Descriptor-driven argv/stdin/help and
  existing AgentStudioIPCClient target       short model replies; invocation UX

ClientCore                                 Socket/auth/response IDs, correlation,
  AgentStudioIPCClientCore                   notification-only spool fallback; client behavior

AppIPCMethodRegistry + IPCRequestAdmission  Typed registration, target/auth gates,
  AgentStudioAppIPC                         replay and handler dispatch; admission

AgentStudioIPCPrincipalRegistry            In-memory pane/debug verifier admission, lazy
  AgentStudioAppIPC                         durable fallback lookup and shared lease gate;
                                            authority and connection revocation

PaneIPCIdentityOwner                       Logical pane identity, hash verifier,
  App/PaneAgents                            close/Undo/revoke lifecycle

IPCContinuityRepository                     Write-behind pane/debug verifiers, forward-only
  App/PaneAgents                            continuity SQL, not domain evidence

PaneReportSpool actor                       Drain notification files after IPC
  App/PaneAgents                            readiness (AE minimal spool)

Notification file append                    flock + append + fsync of one request
  AgentStudioIPCClientCore                  line per pane file (AE)

SessionsIngestion actor                    Ordered binding/report/ack/source-end;
  Features/Sessions/Runtime                 domain admission and queue policy

SessionsEvidenceReducer                    Pure matching, precedence and transitions;
  Features/Sessions/Models                  evidence semantics

SessionsRepository                         Domain transactions and snapshot queries;
  Features/Sessions/State/SQLite            durable Sessions data

ProviderAdapterRegistry                    Built-in exact-version event profiles;
  Features/Sessions/Providers               native dialect and qualification

SessionsSQLiteAccess / IPC adapters         Translate ports and domain types;
  App/IPCComposition/Sessions               cross-target composition

SessionsTerminalFactSubscriber (deferred, AH) Existing admitted facts to Sessions port;
  App/IPCComposition/Sessions               subscription lifetime and translation

AgentPackage                               Native install/config ownership, hooks,
  AgentPackage/                             shared model skill; provider installation
```

Add production target AgentStudioSessions and paired AgentStudioSessionsTests.
Sessions depends on Core, Infrastructure and GRDB; App depends on Sessions.
Sessions imports no sibling Feature, AppIPC or ProgrammaticControl. App-only
adapters translate protocol types into domain types. ProgrammaticControl stays
Foundation-only and cannot import Core's AppCommand. App explicitly depends on
Transport for spool primitives and GRDB for database adapters where required.
ClientCore and its tests remain; the existing executable target can be renamed
without adding another executable layer. Transport contains no Sessions schema,
provider, authority or retention policy.

App composition owns one lazily initialized identity/principal pair; creating it performs no
external work and occurs only when IPC-side initialization needs it. Fallible
schema, persistence, spool, catalog and server initialization run on the IPC side after interactive startup;
boot does not await it. App composition also owns one spool actor, ingestion actor and named terminal
subscriber, including shutdown. There are no per-conversation actors/timers, new atoms, snapshot Store
wrappers, event families or generic coordinator.
WorkspaceSurfaceCoordinator receives only close/Undo/discard lifecycle calls; it
gains no token issuance, credential persistence, evidence or spool policy.
ViewRegistry, prepared-mount ownership, geometry waits and zmx restoration/attach
control flow do not change. Terminal code consumes environment but does not own
logical IPC identity.
Repositories use the same Core-prepared database and never open another pool.

### Interfaces and concurrency

Proposed names describe contracts rather than existing APIs:

- `IPCMethodDefinition<Params, Result>` contains typed schema, name, examples,
  exposure, privilege/data scope, allowed target kinds, command relationship,
  mutation flag, offline-eligibility classification and optional model-call projection. Server composition attaches
  a typed handler separately; schema decoding returns field correction data.
- `IPCRequestAdmission.admit` accepts immutable request and authenticated context,
  checks channel/schema/correlation/target/authority, then replays or invokes one
  handler. Domain ports are async Sendable ports; they are not blanket MainActor.
- App composition owns the existing `AgentStudioIPCPrincipalRegistry` independently of the server and
  injects that same lazily created instance into `PaneIPCIdentityOwner` and `AgentStudioAppIPCServer`.
  The server no longer privately constructs a second registry. This changes ownership of the existing type;
  it does not add a fresh credential registry.
- The principal registry stores immutable current-runtime hash records keyed by
  opaque credential record ID. It exposes a snapshot of records not yet known
  durable and annotates successful in-memory authentication with the matching
  persistence candidate. The IPC service coalesces candidates by record ID,
  submits them through its injected continuity port and marks successful records
  durable in the registry. A failed write remains eligible at the next IPC-owned
  boundary; authentication and terminal use never wait for it. The service tracks
  accepted writes in its existing shutdown lifecycle. Normal shutdown first
  snapshots and coalesces every still-unsaved issued RAM verifier, then drains
  the accepted writes, without a timer or new worker.
- `PaneIPCIdentityOwner` owns logical pane identity, one cached environment per
  logical pane/app runtime and the hash-only verifier lifecycle. Its first
  environment request for that pane/runtime mints one 256-bit token plus an opaque
  credential record ID, admits the verifier to the existing principal registry,
  and caches the environment. The identity owner itself performs no SQL, wait,
  activation, retirement or flush. After IPC readiness, the registry's admission
  hands the new record to the IPC service's enqueue-only issuance sink (amended
  2026-10-07), which queues the write and returns. Every later mount or attachment request
  receives the same cached environment. Mount
  code only copies it: an existing zmx shell ignores the supplied environment and
  keeps its original token, while a genuinely new shell inherits it. No raw token
  is persisted or reconstructed. The environment also supplies AGENTSTUDIO_CLI
  as its owning bundle's absolute executable path and prepends that directory to
  PATH.
  Undo-eligible close makes the pane canonically ineligible and closes leases
  immediately. Undo restores eligibility for the same retained-shell credential
  through canonical membership; `revoke` at discard/expiry is permanent. Only
  verifier registration and final revocation require credential persistence; no
  new durable suspended/reactivated state is introduced. These transitions never
  delete spool files and never delay pane close or Undo.
- `SessionsIngestion.submit` accepts a normalized report plus server-issued
  scope/origin/freshness. One non-reentrant FIFO consumer serializes bind,
  report, acknowledgment and source-end across awaited database work.
- `SessionsRepository.apply` reads prior context and runs an ingestion-supplied
  pure reduction closure inside one transaction, committing domain mutations,
  correlation/occurrence deduplication and source cursor together. It resolves a
  caller-supplied occurrence identity before applying evidence-derived attention
  or results: equivalent reuse returns the retained outcome, while conflicting
  semantic reuse fails the whole transaction. Failure advances none.
- `SessionsSQLiteAccess` injects synchronous Database transaction closures with
  Sendable results through Core's neutral prepared-local operation. Database
  handles never escape; Core never imports Sessions types.
- Core's existing local migration owner exposes two full-migrate phases over the
  same prepared writer: the boot-required migrations and the optional
  Sessions/IPC migrations. GRDB enters `barrierWriteWithoutTransaction`; moving
  the call off-main does not erase same-writer scheduling contention. The optional
  owner starts only after interactive/terminal release and its proof measures
  overlap with local writes. It adds no pool, store or coordinator.
- `PaneReportSpool.drain` reads every line of a pane file under `flock`, submits
  each eligible notification through normal admission forced late, and truncates
  the file only when every line was admitted or was a duplicate (AE).

The principal registry's existing lock owns a shared generation/lease gate.
Canonical-pane snapshots come through a narrow App-injected MainActor read
port; effects revalidate pane lifetime at the native owner immediately before
application. MainActor applies compact validated state/native operations.
Blocking files use explicit off-main helpers (`@concurrent nonisolated` where
needed under Swift 6.2); admission, reduction and deadlines stay off-main.

## Descriptor, CLI and authority composition

The schema algebra covers objects, arrays, scalars, nullability and typed
alternatives. Field descriptors bind decoding, requiredness, defaults, bounds,
examples and JSON Schema projection so documentation cannot invent absent fields.
Product limits live in AppPolicies and enter composed metadata as values.
Open strings at the wire boundary preserve unknown-method/command errors.

Shared method descriptors and typed command-argument variants compile into both
CLI and server dependencies. App's exhaustive ipcSpec remains the sole mapping
from AppCommand identity to exposure, argument variant and target/privilege.
For command.execute, the CLI uses the shared method/variant decoders and the
live command.list/system.capabilities projection to validate an open commandId.
It does not duplicate Core identities or import App. Runtime capability data
is distinct from a JSON build input. There is no JSON export generation step,
CLI parity gate or second hand-written method/argument map.

The live registry returns protocol/catalog compatibility identity, complete
available schemas, examples, privileges, target kinds, command relationship
and qualified provider profiles. Metadata projects to later MCP tools without
an MCP server or SDK now. Curated methods declare reused AppCommand identity
or noInteractiveIdentity. App's exhaustive ipcSpec switch provides a typed debug
argument variant for every AppCommand, including interactive cases; debug
composition merges every variant, while stable/beta merge only admitted headless
variants. The CLI derives plain-argument invocation from this same projection.
No default branch or missing-argument placeholder can stand in for a command.

Picker-backed execution names selections explicitly: repo/worktree IDs for
openWorktree/openWorktreeInPane, destination tab ID for movePaneToTab, names for
rename actions, and explicit pane/window context where focus previously selected
an owner. Selection commands validate those IDs through the existing owner;
they do not open a picker and assume selection. Presentation-only variants
include showCommandBarEverything/QuickOpen/Commands/Panes/Repos, filterSidebar,
and openPaneLocationInEditorMenu; their typed context selects the presenting
window/pane and their result is presented, never completion of the later user
action. Authentication presentation reports initiation, not sign-in completion.
Every identity reaches its existing dispatcher/owner; dormant feature commands
return typed unavailable without reviving Inbox or adding file.open internals.
The command catalog's interactive presence is never execution authority.

The CLI offers descriptor-derived catalog method invocation with --json/stdin
and structured results. Shared modelCall metadata additionally projects the
small scalar vocabulary in Specification C3. This is one semantic descriptor
set with two input/output presentations. The CLI supplies self and correlation;
the app derives bound conversation/source/turn context. `needs-you` upserts one
current deliberate assertion; `needs-you --clear` resolves that assertion in
its generation; `done` coalesces the current episode's AGENT REPORTED result.
The model vocabulary is message, needs-you, needs-you --clear and done;
message is the sole message-text verb, with no separate message kind for a note.
Needs-you explanation is private durable content associated with attention;
it is never interpolated into logs. Missing context yields a short binding
failure, not a request for model-authored IDs. Default reply rendering emits
one controlled line such as saved/queued/rejected, with explicit detail mode
for full tooling output. It never implicitly discovers and prints a catalog.

Production pane principals have self baseline only. Target parsing shares
self/UUID/pane:N spellings but dispatch uses each method's declared kind and
canonical data ownership. A message, conversation or request ID is not authority.
Cross-pane/workspace requests return missingGrant; there is no grant issuance.

Debug composition contributes every AppCommand's typed debug variant plus the
curated layout, terminal, bridge.*, ui.*, snapshot and session.message.ack
methods. The acknowledgment port accepts only the in-process App entry reserved
for future Sessions UI or the debug testing principal; pane principals remain
denied. Stable/beta omit/refuse debug-only variants, retaining their admitted
headless command variants. Server channel decides composition, never a CLI flag.

Off-critical-path debug IPC initialization replaces single-use escrow with one reusable random credential.
Its SHA-256 verifier lives only in the in-memory principal registry for the
runtime's lifetime (AJ); nothing about it is persisted, and local_ipc_credential
holds pane verifiers only.
The authenticated principal is `.automationClient` with `.automationSameUser`;
`.unsafeDebugClient` and `.unsafeDebug` remain exclusive to the explicit
unsafe-no-auth composition.
A debug-channel authorization check admits the authenticated pair by kind and
access mode. It admits the unsafe pair only when the explicit unsafe-no-auth
configuration created it; neither pair can be inferred from channel alone or
substituted for the other.
A 0600 owner-only file holds the raw debug credential for ClientCore to read on
every invocation. This Y-authorized debug-only file is distinct from pane-token
policy: pane bearers still never persist. Publish runtime metadata only after
verifier/file setup succeeds. A failed setup reports debug auth unavailable;
it never enables unsafe auth. Each CLI call can connect, authenticate, execute
and disconnect without changing the file or generation.

Shutdown drops the in-memory debug verifier, closes its connections and
deletes the escrow file. Replacement writes a new token to the file before
publishing readiness. A crash leaves a stale file whose token matches no
running registry and is refused; the next launch overwrites it. Stable/beta
never create this file. Unsafe-no-auth remains a separately explicit opt-in.

Debug discovery (AF). No shared runtime registry directory exists. The launcher
that starts a debug app passes AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW, the path of
an owner-only 0600 file. When the off-critical-path debug IPC service becomes
ready, the App writes that file with the runtime ID, socket path and the
reusable raw debug credential, and deletes it at shutdown or replacement.
ClientCore reads the same env variable on every debug invocation; an operator
in an unrelated shell exports the value the launcher printed. A missing or
unreadable file, a runtime-ID mismatch or a dead socket probe returns a concise
start instruction. Multi-runtime selection, entry pruning and enumeration are
outside round 1; one escrow path names one runtime. Stable/beta never write
the file. Ordinary report/message calls use pane env authority; debug intent
selects this separate path.

Descriptor projections provide plain debug arguments (for example split with a
pane handle, terminal send with text, command.execute with command ID and typed
scalars). Defaults select the discovered runtime, not a guessed target. Replies
are one-line applied/presented/unavailable or concise requested snapshot readback;
explicit detail returns structured tooling output. Repoint existing terminal and
sidebar/grouping proof consumers at this CLI. The installed skill must suffice
for the Haiku/Luna-class start/discover/split/send/command/snapshot proof.

### Credential lifetime

`PaneIPCIdentityOwner` owns logical pane identity. Persist only a SHA-256 verifier,
canonical pane/workspace, opaque credential record ID and status; raw credentials stay
in memory and shell environment. On the first environment request for a logical
pane in an app runtime, the identity owner mints one 256-bit token and opaque
credential record ID, admits the verifier to the existing principal registry,
caches the complete environment and returns it. The identity owner does no SQL
and never waits: it doesn't activate a durable row, retire a credential or flush
accepted work. Its one storage-facing edge (amended 2026-10-07) is the registry's
admission handing the new record to the IPC service's enqueue-only issuance sink
after readiness; the write itself runs later on the existing persistence lane.
Every later mount or attachment request for that pane/runtime receives the same
cached environment. Mount code neither decides whether the shell is new nor owns
credential persistence or lifecycle. An existing zmx shell ignores the supplied
environment; a genuinely new shell inherits it. No per-attachment credential pool,
HMAC/master key, raw-token persistence or ordered credential generation is added.

Restoration is reattachment to the existing zmx shell. That shell keeps the
original environment/token, so restore does not preload, look up, rotate, save,
recover, persist or rewrite it. On an IPC request, authentication hashes the
presented token, resolves the stored verifier, and checks canonical pane/workspace
membership. A durable active row for a closed/nonmember pane is rejected and
cannot resurrect authority. The principal registry's existing lease/invalidation
gate applies after successful verification.

`IPCContinuityRepository` persists registration and final revocation through the
same prepared Core-owned local writer, fenced by pane plus an opaque credential
record ID and immutable workspace/verifier identity. Close/Undo eligibility comes
from canonical membership and the existing lease gate, not a new durable state.
The existing IPC service owns persistence scheduling through an injected
continuity port. After post-frame IPC readiness it snapshots issued in-memory
verifiers and schedules their writes; successful authentication/admission schedules
a write for a newly used in-memory verifier; a verifier issued after readiness is
scheduled at issuance through the registry's issuance sink (amended 2026-10-07);
normal IPC shutdown snapshots and
schedules every still-unsaved issued RAM verifier before draining accepted writes.
These are IPC-owned boundaries, not pane, mount or terminal callbacks. They add
no timer, polling worker or coordinator.
Final revocation dominates delayed registration. No raw bearer is written or
reconstructed. Previously durable verifier rows remain valid while their canonical
pane is live and eligible; issuing the current runtime's cached token does not
automatically supersede them. The opaque credential record ID keys persistence,
correlation and replay identity only; it does not order shell authority. Renderer
or surface recreation creates no credential transition.

An Undo-closed pane fails canonical membership until the existing Undo owner
restores membership; requests cannot self-restore eligibility. Lookup failure
rejects that request without affecting terminal use. Any process end before
verifier durability — abrupt or a normal exit after optional schema/storage
failure — leaves no recovery authority: the next app
rejects the unknown verifier explicitly, never spools that authentication
rejection, and requires a genuinely new shell for IPC. This is the owner-accepted
R-03 limitation, not unchanged prior semantics.

```text
RESTORATION AND REQUEST AUTHENTICATION

mount/attachment -> IPC identity owner -> cached pane/runtime environment
first environment request -> mint once + in-memory verifier admission
later environment request -> same cached environment
existing zmx attach -> supplied environment ignored -> same running shell/token
genuinely new shell -> supplied cached environment inherited
shell request -> IPC authentication: presented token -> hash -> stored verifier
IPC authentication -> canonical membership + lease gate -> admitted | denied
No credential issuance, recovery, rotation or replacement enters restoration.

VERIFIER CONTINUITY
current-runtime token -> exact in-memory verifier
older durable token -> exact durable verifier
post-frame IPC readiness -> snapshot issued RAM verifiers -> schedule persistence
verifier issued after readiness -> registry issuance sink -> schedule persistence (2026-10-07)
newly used RAM verifier -> authenticated admission -> schedule persistence
normal IPC shutdown -> snapshot unsaved RAM verifiers -> schedule + drain accepted writes
IPC continuity port -> Core local writer: hash + opaque credential record ID
Core local writer --> identity persistence: durable | unavailable
new issuance does not supersede an older verifier for the same canonical live pane
No raw token is persisted or recovered from storage.

CREDENTIAL / SOURCE LIFETIMES (separate identities)
eligible verifier -- close --> canonically ineligible
       ^                           |
       +---- same-shell Undo ------+
canonically ineligible -- discard/expiry --> all pane verifiers revoked
renderer/surface recreation -> no credential transition
delayed registration after revoke -> no state regression

active credential + admitted session.bind -> current reporting generation
app/source loss -> generation ended/stale; new binding -> fresh generation
restored credential continuity does not revive old reporting authority
```

Undo-eligible pane close removes canonical eligibility,
stops leases and invalidates connections immediately, so verification denies all
requests. The existing Undo owner restores eligibility for that same retained-shell
credential when canonical membership returns. The existing undo deadline
owner converts expiry/discard to permanent revocation of every credential for the
pane. Already admitted report work and source-end ordering finish on the IPC side
without delaying close.
Registration/revocation ordering and membership checks prevent delayed work or a
crash from resurrecting revoked or nonmember authority.
Filesystem spool admission is a
separate same-UID trust boundary, not an unauthenticated network endpoint.
Neither env bearer nor owner-only files identify a benevolent same-user process.

## Sessions state and persistence

Sessions binds provider-native conversation identity to the authenticated pane,
not a pane claimed in the payload. Profiles qualify exact provider/version/event
semantics and emit only bounded normalized fields; raw hook bodies and
transcripts are not stored. Server-assigned origin is REPORTED for qualified
native facts, AGENT REPORTED for deliberate calls and ESTIMATED for qualified
revocable inference. A missing profile remains unknown.

### Binding admission

SessionsIngestion's FIFO is the sole bind transition owner; arrival order alone
never authorizes replacement. The transaction reads current binding and ended
source generations, applies the rules below, and commits binding/source changes
and sessions_operation outcome atomically. A native transition requires qualified
provider session-start evidence identifying a new occurrence/generation; an
explicit model bind can establish/replace with visibly AGENT REPORTED authority.
Neither implicit model reports nor a bare competing conversation ID is a bind.

| Prior context / input | Admission and generation result |
| --- | --- |
| Absent + live valid bind | Establish current binding and issue a new generation with the admitted origin. |
| Current B + repeated B in its current generation | Idempotent current binding; no new generation, even with a new correlation. |
| Current A + new B with qualified session-start or explicit model bind | End A's generation and establish B's new generation atomically; model authority is AGENT REPORTED, not provider evidence. |
| Ended/older A generation arriving after B | Historical-only outcome; never replace B, including delayed A reports. |
| Late/historical provider bind with a previously unseen generation | Historical-only outcome; never establish or replace current binding. |
| Competing identity without qualified transition | bindingConflict; preserve current binding and return correction data. |
| Same correlation replay | Return recorded original outcome after authority check; do not re-run transition. |
| Matching source end | End that generation; no invented completion or automatic resurrection. |
| App restart | Restore associations/history but end their generations; first qualified bind creates a fresh generation, subsequent same-current bind repeats idempotently. |

The freshness and older-generation checks precede replacement permission. A live new session-start
occurrence (or an explicit fresh model bind) must be distinguishable from replay
of an ended generation; a profile unable to establish that ordering cannot
assert provider replacement and returns bindingConflict. Delayed same-correlation
A returns its old outcome but never changes current B. Identifier-free reports
read the resulting admitted current context; source-qualified delayed reports
remain historical. This preserves the existing descendant/precedence limits.

The Agent Sessions Specification, 2026-08-03, branch sessions-in-sidebar,
Agent State Contract supplies matching and precedence semantics retained in
Specification C5. For a current capability/turn, REPORTED outranks AGENT
REPORTED, which outranks ESTIMATED. One completion result per matching turn
can be upgraded without resetting seen. Provider-identified tool/child completion is not root done. Identifier-free
deliberate descendant calls share the pane's one assertion/episode. The reducer
applies origin precedence before state selection: AGENT REPORTED child done
cannot displace a REPORTED running root turn; the developer sees RUNNING. Child
needs-you displaces nothing stronger than AGENT REPORTED. Without provider facts,
a child done may yield DONE labeled AGENT REPORTED. The shipped skill instructs
subagents not to call done/needs-you; no new identity mechanism is introduced.

```text
BOUND SOURCE -> normalized evidence -> pure reducer -> durable projections

first filter by matching context and origin precedence
current actionable condition? -> NEEDS YOU
else matching completion?     -> DONE
else current activity?        -> RUNNING
else                         -> UNKNOWN

matching clear -> remove only that condition -> recompute from remaining facts
abort          -> end matching activity; no completion result
source loss    -> native unresolved attention stale; deliberate help not current
old turn / ended generation / offline late -> history only, never current clear
query / focus / input -> no acknowledgment and no attention resolution
explicit user acknowledgment(message occurrence) -> that message seen only
```

Provider request identity and model deliberate assertion identity are separate.
The app creates an assertion ID for a bound conversation/generation and retains
it while that assertion is current; clear resolves it atomically. A native
identifierless prompt needs a qualified matching/revalidation rule before its
resolution can be claimed. App-minted IDs alone supply no such evidence.
Offline notifications retain original binding/source metadata when available.
When a drained notification's pane/binding no longer resolves, ingestion stores
it durably as an unattributed message: original pane UUID retained, conversation
unknown, disposition unattributed, original text/report content preserved.
Missing attribution is a successful durable outcome, never a rejection or drop;
a database failure still leaves the line pending for retry. It creates no live
attention/completion and never borrows a replacement conversation. Queries expose
unattributed messages to the authorized App/debug reader; an unresolvable pane
cannot invent new authority. Domain outcome and correlation commit atomically.

| Table | Durable responsibility |
| --- | --- |
| local_ipc_credential | Pane scope only (AJ): pane/workspace + opaque credential record ID, SHA-256 verifier and status, never raw bearer. The pane record ID stabilizes correlation identity; it is not ordered shell authority. Debug credentials are memory-only. |
| sessions_conversation | Native/provider identity and durable conversation attribution. |
| sessions_pane_binding | Pane/conversation association and binding revisions/generations. |
| sessions_source | Qualified source context, cursor, liveness and ended generation. |
| sessions_evidence | Compact normalized evidence needed for reduction, not a general raw event log. |
| sessions_message | One agent-message kind, exact text/report content, occurrence, retained pane UUID, nullable conversation, attributed/unattributed disposition, optional attention association and explicit seen disposition. |
| sessions_attention | Request identity, private explanation association, source/turn/generation and current/resolved/stale disposition. |
| sessions_result | One matching completion result per turn with origin and durable seen disposition. |
| sessions_operation | Atomic report/ack correlation deduplication and domain outcome. |
| sessions_loss | Live-ingress state-overload counts/disposition and disclosed health only; no offline role. |

Core's WorkspaceLocalMigrations owns additive schema migrations and its existing
prepared writer/pool. It exposes two ordered registration sets without adding a
pool or migration owner:

1. The boot-required migrator contains only schemas needed to present the normal
   IDE and restore terminal structure. Boot runs its normal full `migrate()`.
2. On normal automatic restore, `AppDelegate.finishLaunchRestore` reaches the
   existing release edge only after
   `windowLifecycleStore.waitUntilFirstInteractiveFramePublished()` returns and
   `preparedMountOwners.coordinator.releaseTerminalActivation()` completes.
   That edge starts, but does not await, IPC-side initialization. When automatic
   restore is suppressed, `launchRestoreObservationState.complete()` is bookkeeping
   and is not the trigger; AppDelegate uses the existing first-frame waiter, and
   because no prepared-mount activation hold was installed, its return is the
   suppressed path's release edge. If the applicable release edge is cancelled or
   never reached, IPC stays explicitly unavailable; no poller, timer, retry worker
   or new coordinator is added. A later explicit initialization attempt or next
   launch may retry.
3. After that release edge, off-main IPC initialization asks the same datastore
   actor and writer to run a second full migrator containing the additive Sessions
   and IPC credential migrations, currently
   `011_create_sessions_ingestion_schema` and
   `012_create_ipc_credential_schema`. Server publication and spool recovery wait
   on this optional receipt; normal IDE and terminal paths do not. Surface
   construction never calls this actor.

The existing App IPC composition owns the later sequence without a new coordinator: optional migration receipt
-> construct Sessions and continuity repositories and end prior active reporting generations -> inject the
continuity port into the IPC service -> prepare the authenticated debug verifier when applicable -> compose and publish
catalog/socket/runtime metadata -> begin spool recovery and terminal-fact subscription. A failure stops the
remaining IPC-side sequence and leaves the normal app and terminals running. The next explicit IPC initialization
attempt or next app launch may retry from durable/memory authority; no polling loop or boot wait is introduced.
After service readiness, the IPC service snapshots already issued RAM verifiers
and schedules their persistence through the injected port. Later authenticated
admission schedules any newly used in-memory verifier. Normal IPC shutdown first
snapshots and schedules every still-unsaved issued RAM verifier, including one
never used for IPC, then drains accepted writes.
**Issuance (amended 2026-10-07, owner).** A verifier issued after readiness is
scheduled at issuance, so an abrupt end (crash, force quit, SIGTERM) can't lose a
token that was never used. The IPC service installs an issuance sink on the shared
principal registry when it starts, before its readiness snapshot. After admitting
a new verifier, `registerIssuedPaneCredential` hands the record to that sink, outside
its lock. The sink only enqueues onto the existing persistence lane, so the
environment request never waits on storage. If the sink and the snapshot both see
a record, the write is idempotent by credential record ID. Final revocation still
dominates, and a write that fails stays eligible at the next boundary, as before.
This is the only way an environment request reaches this sequence.

This split is compatible with databases on either side of the cut. GRDB 7.10.0 at revision
`36e30a6f1ef10e4194f6af0cff90888526f0c115` selects the last registered target for full migration
and enters `barrierWriteWithoutTransaction` (`DatabaseMigrator.swift:351-373`). It reads all applied identifiers when selecting unapplied
executions, including identifiers unknown to a particular migrator (`DatabaseMigrator.swift:614-643`). Thus the
boot-required subset tolerates a database that already contains 011/012, and the
optional subset tolerates earlier boot identifiers while preserving every table
and historical row. Neither phase uses the full migrator's `migrate(upTo:)` to
target an older identifier: GRDB deliberately traps when a known later migration
is already applied (`DatabaseMigrator.swift:617-625`), and schema-change erasure
defaults to false (`DatabaseMigrator.swift:112`). The barrier means off-main
execution alone does not prove absence of same-writer contention. S10 measures
the real optional migration against concurrent local work after the release edge;
it does not add a second writer or pool. A failed optional phase
leaves the local feature unavailable and retryable on the IPC side; it does not
replace, erase or quarantine a healthy database merely to make IPC ready.

SessionsRepository owns Sessions SQL; IPCContinuityRepository owns IPC SQL. No
Inbox transformation, save lane or startup wiring is reused.
Messages, seen and attention survive rebuilding derived state. Query pages read
one committed snapshot and carry revision/cursor; stale cursors request refresh.
Unknown or unauthorized message acknowledgment fails without mutation. Sender
receipt and result upgrades never reset the explicit user disposition.

## Offline spool and live admission

App obtains its data root from
[AppDataPaths.rootDirectory(...)](../../../Sources/AgentStudio/Infrastructure/AppDataPaths.swift).
The existing [AgentStudioIPCPathResolver](../../../Sources/AgentStudioAppIPC/AgentStudioIPCPaths.swift)
alone derives `<root>/ipc/spool/v2/`; its composed path is delivered as
AGENTSTUDIO_IPC_SPOOL_DIR. The CLI consumes that env value without a second
root-derivation implementation.

Minimal spool (AE). Each canonical pane has one owner-only append-only file
`<paneUUID>.notifications.ndjson`. Shared descriptors classify offline
eligibility: only `session.message` and the deliberate `session.report`
variants needs-you and done are eligible. needs-you --clear, controls, queries,
auth and hook lifecycle facts are ineligible: ClientCore returns "Can't clear
while Agent Studio is offline." for clear and a plain failure for the rest, and
appends nothing. Classification follows the report variant, not the method name.

App unreachability permits queuing: a missing socket path, refused connection,
or a dead/stale endpoint by the shared probe semantics. An authenticated or
protocol-level rejection proves reachability and never queues. An ambiguous
disconnect after submission remains uncertain, never an offline resubmission.
Hook lifecycle facts are dropped at the source while the app is down.

ClientCore appends the exact JSON-RPC request line (correlation and reportedAt
in params; no bearer or auth frame) under an exclusive `flock` on the file and
fsyncs before returning queued. Append or fsync failure returns explicit
failure. There is no eviction cap; the frame acceptance limit still applies.

Drain: only after optional schema and server-side admission are ready, and never
on the first-frame, terminal-activation, new-shell or existing-zmx paths, the
IPC-side drainer takes the same `flock`, reads every line, submits each through
common admission forced late, and relies on the Sessions correlation journal
for deduplication. When every line is admitted or rejected as a duplicate, the
drainer truncates the file under the lock. If any submission fails for another
reason, the file is left intact and drained again at the next IPC readiness.
Malformed lines are counted in source health and skipped; their text is never
logged. No claim/rename generations, quarantine files, per-line removal, lock
files or operator cleanup routes exist in round 1.

```text
CLI notification -> live socket -> common admission -> durable/rejected
          |
          + app unreachable -> flock -> append + fsync -> queued

IPC ready after interactive launch -> flock -> read all lines
           -> admit each forced late (dedup by correlation journal)
           -> all admitted/duplicate: truncate | other failure: retain, retry

normal startup / fresh shell / existing-zmx attach -X-> drain
controls / queries / auth / clear -> unreachable app: failure, never spool
```

Ingestion has bounded live queues: 256 per pane and 1024 globally. Messages and
deliberate reports are never eviction candidates: full queue/write failure
returns explicit rejection without claiming acceptance. For live lifecycle
state drops, persist sessions_loss before dropping and return a throttled/rejected
outcome for that request. sessions_loss is retained exclusively for this live
role. If persistence itself fails, reject admission and disclose unavailable
source health; never claim a durable loss receipt that was not committed. The
reducer consumes late deliberate reports only as history and preserves newer
live projections. Provider wrappers remain fail-open; durable failure is visible
without blocking provider control.
## Agent package

```text
AgentPackage/
  manifest.json                  package version and supported profiles
  skills/agentstudio/SKILL.md     env guard, scalar calls, one-line expectations
  providers/claude/              native plugin + hooks
  providers/codex/               hooks.json + plugin
  providers/cursor/              .cursor/hooks.json integration
  hooks/                        bounded provider projection -> agentstudio CLI
  installer/                    ownership-aware native config merge/remove
```

Hooks call the bundled CLI full JSON surface. The model skill teaches only C3's
small scalar calls and guard, without IDs, sequencing or catalog boilerplate;
it instructs subagents not to call done or needs-you.
Hooks and skill use AGENTSTUDIO_CLI from the identity owner's construction env;
the package never hardcodes a bundle path or persists pane credentials in native
configuration. Bare agentstudio resolves through the same construction-time PATH; a
missing/invalid AGENTSTUDIO_CLI fails the guard rather than selecting another
installed channel's executable. Installation manifests record exact owned additions, structural
keys and last installed values, not tokens or message text. Install/upgrade
preserves unrelated settings, avoids duplicate entries and reports conflicts.
Uninstall removes only still-owned additions; user-modified values remain with
an explicit conflict report. Missing executables/config access and inactive
native trust are per-provider outcomes, not global success. Native trust cannot
be bypassed by installation. pi/OpenCode are outside this package's first round.


Delivery order and installer scope (AG). The bundled CLI executable ships first
as `Contents/Helpers/agentstudio`, built from the `agentstudio-cli` executable
product (formerly `agentstudio-ipc`) and signed with the app; it is a PR gate on
its own. It cannot live in `Contents/MacOS`: on the case-insensitive volumes
macOS and the CI runners use, `agentstudio` and the app's `AgentStudio` are one
path, and a `Contents/MacOS` PATH entry would resolve bare `agentstudio` to the
app. The pane env therefore prepends `Contents/Helpers` to PATH and advertises
that file as AGENTSTUDIO_CLI.
Providers land in the order Codex CLI, Claude Code, Cursor CLI, each proven with
that provider's real entry point before the next starts. The installer is a
subcommand of the same CLI (`agentstudio package install|uninstall <provider>`).
It writes only entries carrying a package-owned marker, removes only marked
entries, and prints a one-line notice when a marked entry differs from the
package's current value before overwriting it. No manifest of last-installed
values and no conflict-diff engine exist in round 1.
## Call-path deltas

`+` added, `~` changed, `-` retired, `=` preserved. Typed outcomes return along
the initiating chain unless queued/durable distinction is shown explicitly.

```text
D1 PANE IDENTITY — R-01–R-03
Current: pane -> startup zmx env -> Ghostty -> shell without IPC identity
Target: = logical pane identity owned by IPC
        + first pane/runtime env request -> mint token + opaque credential record ID
        + principal registry -> current-runtime in-memory verifier admission
        + identity owner -> cache pane env; later mounts receive the same env
        = env request -> no SQL or wait in the identity owner; no activate/retire/flush
        + after readiness: registry admission -> IPC issuance sink -> enqueue verifier write (2026-10-07)
        = mount/attachment -> copies env only; owns no credential lifecycle
        = existing zmx attach -> ignores env; keeps original shell/token
        = genuine new shell -> inherits cached env
        = presented token -> in-memory or durable hash + canonical membership + lease gate
        + IPC readiness/issuance/auth admission/shutdown -> verifier writes -> same Core local writer
        - fd-bootstrap delivery
        + close -> immediate canonical denial/lease close
        + same retained shell Undo -> same-credential eligibility restoration
        + discard/expiry -> permanent revocation
Outcome: valid shell context or explicit unavailable integration; terminal always usable.

D2 DESCRIPTOR / WIRE / CLI — R-04–R-10, R-23
Current: hand-mapped CLI -> auth/handle rewrite -> string routing -> typed port
Target: + same compiled descriptors -> Swift CLI parsing/help -> ClientCore
        = Unix framing, peer UID and response-ID checks
        ~ schema/channel/target/auth -> replay admission -> typed handler
        = App adapter -> existing owner -> typed result
        + stable correction data, correlation, complete discovery/MCP metadata
        - phase-1 verb mappings and executable product name
Outcome: declared accepted/applied/partial/uncertain boundary, not guessed effect.

D3 REPORTS / QUERIES — R-11, R-12, R-15–R-19, R-21, R-22
Current: no Sessions domain port
Target: + hook JSON or scalar CLI -> admission -> App translation
        + live bind establish/repeat/replace; late/history/conflict -> no current change
        + FIFO ingestion -> qualified normalization -> reducer/SQL transaction
        + correlation + occurrence identity gate before evidence/derived writes
        + message/query/explicit acknowledgment -> committed Sessions snapshot
        = Core database preparation, no Inbox save lane
Outcome: durable occurrence, honest state or explicit rejection/unknown capability.

D4 TERMINAL FACTS — R-15, R-16, R-21
Current: copied callback -> Contract 7 -> runtime apply -> semantic bus fact
Target: = source contraction and thin MainActor apply
        + named App subscriber -> off-main qualified projection -> D3
Lane: often (potentially >=10 events/minute); no new MainActor hop.
      Projection and Sessions admission run off-main after the existing hop.
Proof: S6/S8 marker-scoped queue depth, admitted/dropped counts and duration.
Outcome: qualified evidence or ignored/unverified disposition; no raw screen path.

D5 SPOOL / RESTART — R-03, R-09, R-18–R-20
Current: missing/refused/dead endpoint cannot deliver notification
Target: + descriptor eligibility -> CLI flock append/fsync -> queued receipt
        + post-readiness drain -> common late admission -> atomic SQL dedup/domain commit
        + all admitted/duplicate -> truncate; other failure -> retain and retry (AE)
        + no command/clear or hook lifecycle buffering
        = first frame and terminal activation never await claim/drain
Outcome: notification survives until accepted, or explicit append/admission failure.

D6 DEBUG CONTROL — R-02, R-05, R-13
Current: diagnostic auth + phase-1 client -> existing control ports
Target: = debug channel boundary and native execution owners
        ~ off-critical reusable runtime verifier/file -> authenticated
          automationClient/automationSameUser -> per-call automatic CLI discovery/auth
        + every AppCommand debug variant -> same plain-argument CLI -> typed ports
        ~ existing smoke/verifier scripts use new CLI/context/help
        + stable/beta omission/refusal and pane-role negatives
Outcome: test readback proves the actual effect; input receipt alone does not.

D7 PACKAGE — R-14, R-22
Current: separate native integration setup
Target: + native install table -> exact ownership manifest -> per-provider outcome
        + hooks invoke bundled CLI; skill invokes scalar projections
        + idempotent upgrade/uninstall preserves unrelated or conflicting edits
        = provider trust and lifecycle; report failure is fail-open
Outcome: installed/active/qualified are separately observable.
```

The identity owner mints and caches one environment per logical pane/app runtime;
no pane action, geometry gate, renderer recreation, placeholder or mount lifecycle
owns token creation. Existing-zmx restoration/attachment receives the same cached
environment but performs no credential issuance, recovery, rotation or replacement
and does not rewrite its running shell. A genuine new shell inherits that environment.
Optional migrations, verifier persistence, catalog/socket publication and spool
recovery start from the existing release edges described above. No SQL,
filesystem, shared-actor or IPC readiness check enters Ghostty callbacks or
synchronous terminal startup. S10 measures actual construction and attachment
so this cleanup does not assume the unchanged terminal path is regression-free.

## Failure containment and replay

Control correlation (AD): every control carries a required correlation ID on the
wire, the server echoes it in the typed result, and no durable or in-memory
replay journal exists for controls. A repeated correlation is a new request. The
only durable deduplication is the Sessions occurrence journal
(`sessions_operation`) for reports and messages, where domain outcome and
correlation commit in one transaction. A caller that loses the response after
submission treats the outcome as uncertain and does not retry automatically.

```text
TRUST / FAILURE CONTAINMENT
bytes -> peer UID/frame -> schema/channel -> principal/target -> admitted context
  reject at any gate: typed reason/correction, no effect
  reports -> bounded FIFO -> correlation/occurrence gate -> reduction
          -> domain/dedup commit -> durable receipt
  controls -> live lease + native owner -> final/partial/uncertain (no journal)
  private text -> explicit SQLite/spool only -X-> JSONL/OTLP/logger
```

Reports and seen
acknowledgments commit their dedup row and domain change in one transaction and
therefore avoid that gap. No general transaction coordinator is introduced.

Undo-eligible close denies requests and stops leases synchronously through
canonical ineligibility; source-end ordering continues on the IPC side. Undo
restores eligibility only for the same retained-shell credential after canonical
membership returns. Expiry/discard uses the existing undo deadline/retirement
owner for final revocation. If registration and revoke overlap, the opaque record
identity and conditional write make delayed registration converge without reviving
revoked or nonmember authority. Queries see committed
snapshots. Ordinary shutdown stops new admission, ends read waits, closes
listener/subscribers, and drains already accepted registration/domain work after
startup and terminal owners no longer wait on it; unaccepted memory work is
rejected. Any process end before verifier durability, including normal shutdown
after optional storage remained unavailable, produces R-03's explicit unknown-
credential failure on next authentication. Reachable-app authentication rejection
does not spool; files already durably appended during true unreachability retain
uncommitted work. No correctness rule depends on arbitrary sleep: use protocol
barriers, injected clocks and bounded state waits at proof seams.

## Cutover, reserved seam and protected boundaries

Ship one v2 catalog and the signed/notarized bundle CLI. Retire the phase-1
agentstudio-ipc verb executable and agentstudio-pane-agent fd helper. Retain
ClientCore, its client tests and reusable transport behavior; update them for
v2. Repoint proof consumers at agentstudio. No legacy parser or dual protocol
path remains. Package/catalog version mismatch fails before mutation. Rollback
is explicit compatible binary/package selection, not concurrent schema writers.
Optional feature migration failure makes IPC/Sessions integration unavailable
without a false durable receipt; existing Core database preparation/recovery and
normal IDE/terminal availability remain authoritative.

The sole future file.open seam is an App/IPCComposition typed contribution to
the shared registry, declaring the reserved Specification C7 relationship when
later authorized. It has no registered descriptor, handler, CLI verb or current
realization here. This design selects no file-opening internals or functional
proof for that reserved contract.

Retain existing IPC programmatic-control/port/composition/import/atom-access
and surface-sanitization architecture rules. Extend their existing owning tool
for Sessions placement, complete schemas and forbidden payload logging rather
than add shell scanners. Constructor/schema tests establish descriptor validity;
no separate CLI export parity mechanism is needed. No IPC direct atom access,
renderer transport, zmx public methods, command facts bus or Inbox startup/write.

Content-safe probes use existing allowlisted tags: controlled provider/event
kinds, outcome/drop counts, queue depth and durations. Never raw identifiers,
paths, tokens, payload/error strings or message/explanation text. Marker-scoped
proof joins private query readback with scrubbed performance metrics. Changed
often/heavy lanes retain existing admission/hop/performance obligations; this
slice adds no UI observer or collector. Steering, Sessions UI, ACP, agent-to-agent,
banners, screen manifests, transcripts, answer-through, daemon/Rust core,
SDK/Rust CLI, remote transport and grant issuance remain outside the design.

## Requirement-to-owner and proof views

| Seam | Real driver, boundary and observation |
| --- | --- |
| S1 | Real genuinely-new shell env and restored existing-zmx shell to authenticated socket: one cached pane/runtime environment, new-shell inheritance, restored original token, exact in-memory and durable hash verification, coexistence of older durable verifiers for the same canonical live pane, opaque record correlation identity without authority ordering, close-time canonical denial, same-shell Undo eligibility restoration, discard/expiry revocation of all pane credentials and durable restart continuity; abrupt and storage-failed normal process ends before durability prove explicit unknown-token rejection. |
| S2 | In-process ClientCore and shell CLI to actual registry/ports: schema, errors, diagnostic targetless duplicate/conflict/reconnect/replacement replay, results and bundle identity. |
| S3 | Installed skill/scalar calls in bound agent context with AGENTSTUDIO_CLI/PATH and concurrent channel installs: no model-typed IDs/JSON, short replies, coalescing, ID-free clear and A→B/delayed-A/repeated-B/source-end/restart binding cases. |
| S4 | Haiku/Luna-class agent with only installed skill to real debug app: repo-launcher start, unrelated-shell registry discovery, two-runtime selection, split/send/command/snapshot; every typed AppCommand debug dispatch and honest presentation outcome; two sequential authenticated `.automationClient`/`.automationSameUser` calls, credential shutdown/replacement disposition, explicit unsafe-no-auth separation, targetless replay/conflict and channel negatives. |
| S5 | Installer to isolated native config/provider entry points: exact ownership, activation and fail-open outcomes. |
| S6 | Exact-version native fixtures/Contract 7 to reducer: matching evidence, binding A→B then delayed A, late/historical unseen-generation bind, repeated B/source end/restart, equivalent/conflicting occurrence reuse across correlations, descendant precedence, generation loss and unknown capabilities; D4 often-lane marker-scoped queue depth, admitted/dropped counts and duration. |
| S7 | App-down CLI and post-readiness drain to real SQLite: removed-socket and stale-socket-file unreachability, exact messages and deliberate reports once, late ordering, never-bound reports retained until the pane binds, malformed and oversized lines counted and skipped, truncate only when every line admitted or duplicate; offline-ineligible clear/command negatives; unattributed fallback. No quarantine, lock files, or operator cleanup (AE). Acknowledgment proof deferred with its entry (AH). |
| S8 | Distinctive private input to real sinks/storage and architecture checks: no forbidden content or ownership crossings; D4 probes verify off-main admission with no added MainActor hop. |
| S9 | Boot/catalog/package inspection: explicit negative space remains absent; reserved contract stays unregistered. |
| S10 | Controlled optional-readiness barriers plus real first-schema and steady-schema launches: normal restore and automatic-restore-suppressed paths cross their exact existing release edges before optional IPC starts; first interactive frame, genuine new shell and existing-zmx restoration/attachment complete while the GRDB same-writer barrier, verifier persistence, server publication and spool recovery are delayed or fail. Prove the first pane/runtime environment request performs only mint/register/cache plus, after readiness, one enqueue through the issuance sink (no SQL, no wait), and later mounts reuse that environment, a genuine shell inherits it, restoration keeps its original token without replacement, and the IPC service alone schedules writes at post-frame readiness, issuance after readiness (amended 2026-10-07), newly used authenticated admission and normal shutdown. Issuance regression (finding #6): issue a verifier after server readiness, make no login and take no graceful credential snapshot, observe the hash commit through the existing lane, then reopen the repository and a fresh registry and authenticate the retained token. A delayed or failing write still never blocks the environment request. Graceful shutdown must snapshot a still-unsaved issued verifier that was never used for IPC before draining accepted writes; interrupted shutdown or storage failure retains AB's explicit non-durable failure. Close/Undo/discard under delayed persistence cannot regress; auth rejection does not spool. Record real startup, genuine construction and reattachment measurements without a fabricated threshold. |

| Requirement | Owner | Specification contract; proof |
| --- | --- | --- |
| R-01 | PaneIPCIdentityOwner, principal registry, CLI guard | C1; S1/S10/V1/V10 |
| R-02 | Principal registry, admission, debug composition | C1/C4; S1/S4/V1/V4 |
| R-03 | Identity owner, principal registry, continuity repository, ingestion | C1/C6; S1/S7/S10/V1/V7/V10 |
| R-04 | Shared descriptors, registry, ClientCore | C2; S2/V2 |
| R-05 | ipcSpec, dispatcher, typed registered ports | C2/C4; S2/S4/V2/V4 |
| R-06 | Descriptors and discovery composition | C2; S2/V2 |
| R-07 | Schema/error projection and open wire identifiers | C2/C8; S2/V2 |
| R-08 | Typed target resolver and domain ownership lookup | C1/C2; S1/S2/V1/V2 |
| R-09 | CLI, admission, both operation repositories | C2/C3/C6; S2/S3/S7/V2/V3/V7 |
| R-10 | Shared descriptors, CLI, ClientCore, bundle packaging | C2; S2/V2 |
| R-11 | Model-call projection, ingestion context derivation | C3; S3/V3 |
| R-12 | CLI short reply renderer and installed skill | C3; S3/V3 |
| R-13 | Debug composition, registry exposure, CLI | C4; S4/S10/V4/V10 |
| R-14 | Native installer and ownership manifest | C5; S5/V5 |
| R-15 | Provider profiles and SessionsIngestion | C5; S6/V6 |
| R-16 | Reducer, profiles, Contract 7 subscriber | C5; S6/V6 |
| R-17 | Reducer, attention rows, model context projection | C3/C5; S3/S6/V3/V6 |
| R-18 | SessionsRepository, CLI/spool | C6; S7/V7 |
| R-19 | Repository, App/debug-only acknowledgment port | C6; S7/S8/V7/V8 |
| R-20 | Descriptor eligibility, ClientCore, spool actor, ingestion, live-only loss rows | C6/C8; S7/V7 |
| R-21 | Payload owners and sink allowlists | C3/C6/C8; S8/V8 |
| R-22 | Hooks, provider profiles, admission containment | C5/C8; S5/S6/V5/V6 |
| R-23 | Descriptor JSON/MCP metadata projection | C2; S2/V2 |
| R-24 | Boot, registry and package scope boundaries | C7; S9/V9 |
| R-25 | App boot, terminal construction, Core migration phases, IPC-side initialization | C1/C6/C8; S10/V10 |

Pure parsing/reducer/normalization tests prove local decisions. Real IPC,
SQLite, provider events and native effect readback prove their connections;
a fake provider cannot qualify REPORTED evidence. Process-end checks straddle
genuinely-new-shell verifier registration and spool append, commit and
line removal. Close/Undo canonical eligibility plus durable final revocation
proves retained-shell authority without a new persistence state. First-schema and
steady-schema launches prove the phased migration path and measure its real GRDB
barrier scheduling. Model token economy is reviewed beside schema DX, not inferred from
schema completeness. Required implementation gates remain future proof work.

## Approval inventory

| Category | Realization inventory |
| --- | --- |
| Targets/dependencies | AgentStudioSessions and paired tests; App depends on Sessions/Transport/GRDB; retained ClientCore/tests and reused thin Swift CLI target. |
| Contracts/composition | Shared typed/model-call/offline-eligibility descriptors, exhaustive ipcSpec, ProviderAdapterRegistry with exact-version qualification, IPCDebugLocationContract in ProgrammaticControl, Y reusable runtime-bound debug credential/automatic discovery, every AppCommand typed debug variant under Z, debug-only session.message.ack and reserved in-process App acknowledgment entry; existing IPC path resolver owns spool root. |
| Logic/derivation | SessionsEvidenceReducer owns pure matching, origin precedence and state/attention/result derivation. |
| Persistence owners | SessionsRepository and IPCContinuityRepository over one Core-prepared database; Core-owned boot-required and optional full-migration sets over the same writer; neutral transaction entry and eleven table families including diagnostic verifier/journal namespaces; sessions_loss is live-only; unattributed messages use sessions_message. |
| Actors/subscription | PaneIPCIdentityOwner with cached environments, SessionsIngestion, PaneReportSpool; principal in-memory verifier/lease gate; IPC service-owned verifier persistence scheduling; named SessionsTerminalFactSubscriber, off-main often lane. |
| Coordinator responsibilities | Existing coordinator receives close/Undo/discard lifecycle calls only; it never issues/replaces credentials, waits on IPC readiness or owns persistence. |
| Atoms/stores | None added; no new event family or coordinator class. |
| Files/package | One append-only notification file per pane drained under flock (AE); debug escrow file at the launcher-supplied path (AF); bundled `agentstudio` executable and marker-owned provider installer (AG). |
| Retired items | Phase-1 agentstudio-ipc executable/verb mapping and fd-bootstrap helper and single-use debug escrow; ClientCore remains. |
| Policy values | Live admission queues 256/pane and 1024/global; no notification eviction; no quarantine limit (AE). |

## Structural choices and limits

| Choice | Benefit and cost | Alternative and revisit signal |
| --- | --- | --- |
| Shared compiled descriptors, retained ClientCore | One protocol definition for Swift consumers; App still supplies runtime command identity/exposure because Core cannot enter the shared target. | A JSON-generated Swift client adds a build boundary and is excluded by T; reconsider only under a changed language/distribution contract. |
| Feature-owned Sessions with two repository responsibilities | Provider/domain policy stays out of IPC/Core; adds one Feature target and App translation ports, not another database. | Core ownership reduces one target but misplaces provider policy; revisit if a real shared-domain consumer needs these models. |
| One cached pane/runtime token with hash-only continuity and retained-shell Undo | The identity owner admits one current-runtime verifier in memory and caches one environment; every mount receives that environment, a new shell inherits it, and restored zmx keeps its existing token. Environment requests are RAM-only. The IPC service schedules hash persistence at its post-frame readiness and newly used authenticated-admission boundaries; graceful shutdown snapshots every still-unsaved issued RAM verifier before draining accepted writes. Older durable verifiers remain valid for the same canonical live pane; issuance does not supersede them. Canonical membership denies/restores close/Undo eligibility, and final discard/expiry revokes all pane credentials. The opaque record ID stabilizes persistence/correlation/replay without ordering shell authority. Cost: storage-unavailable or interrupted shutdown before verifier durability leaves that shell explicitly unavailable after restart. | Raw-token recovery/persistence, a new durable suspended state, ordered credential generations, per-attachment candidates and mount-owned replacement are rejected. Revisit only if the owner changes the accepted AB failure window or canonical-pane authority model. |
| Two Core-owned local migration phases on one writer | Boot runs only required schema; IPC/Sessions schema and all existing rows remain under the same owner and database while optional readiness moves after the exact release edge. GRDB's barrier is measured rather than assumed contention-free. | A second pool/owner is forbidden. Rejoin phases only if real first-schema and steady-schema measurements prove the optional work cannot preserve first frame or terminal activation. |
| One notification spool per pane | Preserves messages and deliberate reports with flock append and post-readiness drain; explicit storage failure instead of eviction (AE). Hook lifecycle history while offline stays with the provider. | A daemon changes the trust and lifecycle model; deferred. |
| No control journal (AD) | Controls execute once per request; a lost response is uncertain to the caller and a retry is a new request. | A durable journal was built for no round-1 caller; revisit only when a retrying caller exists. |

Provider qualification remains incomplete: the recorded Cursor headless
2026.09.02-c22c1a3 runs establish sessionStart/sessionEnd only; interactive TUI
and unexercised hooks remain unverified, and absent events are not inferred.
Complete Claude/Codex exact-version matrices also remain evidence inputs.
Unknown capabilities remain explicit until those exact event and operating-mode
fixtures establish their semantics.
