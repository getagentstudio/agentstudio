# What each part owns: Studio, Router and task execution

Research map, 2026-11-01. This makes the existing feature survey and the newer task discussion easier to navigate. It does not adopt a new process topology, public protocol, database schema or implementation sequence. [Evidence, exact heads and the independent lifecycle check](research-ledger.md).

**Owner-selected outcome:** active provider turns must keep running through a planned Host upgrade; qualify independent execution custody. The process/handover mechanism is still open. Restoring a conversation after interruption does not satisfy this selected outcome. Abrupt crash and execution-owner upgrade behavior remain separate contracts.

**Owner-selected delegation scope:** support both standalone and board-linked execution, with durable execution identity/outcome/recovery in either case. Board linkage is optional; native execution tracking does not require a synthetic board task or schedule.

**Observed qualification input:** [one real native command/turn continued after requester SIGKILL](native-continuity-results.md), with a retained observer as prototype custody. This is a bounded local result, not implemented Host upgrade, whole-task recovery or completed migration of the feature tree.

## Start with responsibilities

The user sees one integrated AgentStudio system. Internally, each responsibility needs one owner and a contract. Several owners can share a process without sharing all their data, lifetimes or permissions.

```text
AgentStudio
├── Work on an addressed machine
│   ├── Terminal execution and attachment control
│   ├── Native provider conversations and turns
│   ├── Git, worktrees, discovery and files
│   └── Context, annotations and other declared workflows
├── Coordinate work
│   ├── Durable tasks, assignments, dependencies and accepted outcomes
│   └── Delegation/execution associations and result reporting
├── Communicate between agents
│   └── Direct message custody and delivery
├── Prepare data for a device
│   └── Gateway connections, subscriptions, eligible copies and read models
├── Display and interact
│   └── Native rendering, actual focus, keyboard and destination effects
└── Integrate with Fleet and central authority
    └── Selected machine discovery/admission and database writer leases
```

These are logical owners. In particular, “coordinate work” and “communicate” do not imply two additional daemons. A Host deployment's relationship to one or several workspaces remains open. Fleet workspace membership and Studio's shared visual workspace are not silently made the same entity.

## Responsibility, interface and deployment are three maps

| Part | Decides / owns | What other parts request or read | Hosting status |
| --- | --- | --- | --- |
| Machine Host | Effects and admitted truth on the addressed machine; Git/files, execution and declared workflows | Explicit capability commands and qualified source observations | Mac/Linux role required; combined Router process versus separate lifecycle remains open |
| Router provider integration | Provider-native session/turn operations, capabilities, interaction correlation and actual operation evidence | Shared session-command/event interfaces, with deliberate frontend exposure | Existing implementation; whole-Host lifecycle and dependency graph need fit checks |
| Terminal owner and ZMX adapter | Execution identity, attach/control/resize admission and backend association | Create/list/attach/detach/terminate and binary terminal traffic | New Rust integration unproven; ZMX remains a real backend process |
| Task owner | Durable obligation, assignment, dependency and acceptance decisions | Task requests, authorized execution associations and result submissions | Existing board work model is relevant; new delegation contract/placement not yet selected |
| Execution association / settlement owner | Which actual provider attempt serves the work; observed outcome and stop progress | Launch/control requests to provider owner; evidence to task owner | Reuse narrower Router mechanisms where they fit; scheduled RunRecord is not assumed generic |
| Direct mail owner | Immutable item, addressed recipient, custody and carrier receipt | Send/cancel delivery and inspect its actual outcome | Existing mail domain; a delivered message does not acquire task authority |
| Gateway | Connections to several Hosts, desired client interests, qualified copies, view preparation and delivery | Host commands; subscriptions; prepared semantic values | Separate Mac service and embedded iOS role in retained design; binding/startup still need qualification |
| Native UX client | Actual pixels, focus/responder/viewport, keyboard input, platform dialogs and effects | Prepared values, finite content, terminal buffers and explicitly addressed native operations | Swift/other platform client; required UI publication stays at its actual native owner |
| Central lease authority | Which writer holds the selected database unit's authority | Renewal/admission results consumed by the actual Host write gate | Separately injected control-plane boundary; later server and transfer behavior remain out of scope |

“Execution association / settlement owner” names a responsibility to bind, not a newly approved service or database. The task owner may compose it within its own service when the contract supports that. The map creates no second writable Task.status.

## Coverage of the existing Studio feature tree

An index audit re-counted **42 feature leaves** across eight branches. It also re-counted **86 authored logical tables and 597 columns** in the retained JSON census. The app source paths and Package.swift have no diff between source baseline `624300332f5e50f7bb8cbb9fc786d5e5b4a3d462` and documentation HEAD `a3c9457389046df9a9fe1e0171c3bb842575844d`. This is coverage of the recorded inventory, not a fresh exhaustive code survey or target parity proof. Every migration checkbox remains unchanged.

| Existing feature branch | Leaves | Machine/domain part | Gateway part | Native part |
| --- | ---: | --- | --- | --- |
| Repositories, Git and worktrees | 7 | Discovery, Git/Forge acquisition, clone/fetch/push/branch/worktree/fork effects | Host-qualified inventory and status views | Folder choice, local editor/browser/Finder actions |
| Terminals and continuing sessions | 5 | Execution establishment, identity, attachment/control and facts | Addressed attach/input route, subscriptions and bounded byte delivery | Terminal renderer, actual input and rendered-history navigation |
| Agents, hooks and context | 5 | Admitted provider/binding/evidence/context/ask and integration-package work | Qualified session/status/context views | Actual viewing, answering and intentional native interaction |
| Files, comparisons and viewers | 5 | Exact file/Git comparison sources and finite content | Descriptors, content route and semantic metadata | Code/Markdown/web rendering and native viewer controls |
| Annotations, drafts and output | 5 | Saved workflow, edit fences, prepared output and finalization | Authorized workflow views and destination routing | Live editor buffer and actual declared clipboard/file dialog effects |
| Windows, panes and everyday interaction | 8 | Shared logical state at its designated authority; execution separate | Semantic search/grouping/read preparation | Windows, mounting, focus, geometry, native modes and command presentation |
| Settings, integrations and operation | 5 | Actual process/credential/writer/admission owners | Connection/preferences/view responsibilities where declared | Platform consent and actual local settings/effects |
| Unavailable, debug and uncertain paths | 2 | Preserve exact supported/refused disposition | Present the actual outcome | Retain dormancy rather than reactivate a control implicitly |

[Existing feature tree](../../designs/11-operations-integration/migration-feature-checklist.md:1), [capability acquisition map](../../designs/11-operations-integration/capability-placement-map.md:1), [command/operation crosswalk](../../designs/11-operations-integration/migration-operation-crosswalk.md:1), [table/column census](../../designs/02-data-ownership-replication/research/data-catalog.json).

The newer integration of Router semantic control, peer mail and the actual delegated-task system is additional work to bind to this baseline. Those are not assumed already covered by the 42 Studio leaves. Existing board task records and existing Studio context notices also remain different concepts.

## Six paths that explain the boundaries

### Start an execution and display it

```text
Client intent → Gateway → addressed Host execution owner → backend establishment
Attach later → Host attachment owner → terminal stream → Gateway → native renderer
```

Creation and attachment are separate operations. Current Studio [createPaneSession](../../../../../Sources/AgentStudio/Core/RuntimeEventSystem/Runtime/ZmxBackend.swift:182) prepares a handle and relies on first attach to start execution. The proposed remote create boundary must establish execution without a hidden native view before it reports that outcome. Backend establishment, registry commit, reply delivery and native rendering are separate observations.

### Assign/delegate actual work

```text
Task authority records work/assignment
  → authorized execution request to addressed machine
  → provider create/load/prompt/control owner
  → exact execution settlement
  → task result submission and acceptance under the task contract
```

A board task, a delegated execution, a provider conversation/turn and a message item keep their own identities. Existing [Router session commands](</Users/shravansunder/code/projects/codex-router/crates/collaboration-contracts/src/session_command_port.rs:111>) and [exact settlement](</Users/shravansunder/code/projects/codex-router/crates/automation-storage/src/run_completion_state.rs:9>) are reuse candidates. [Scheduled RunRecord](</Users/shravansunder/code/projects/codex-router/crates/agent-automation/src/run_execution.rs:75>) has a mandatory schedule and different completion meanings; it is not adopted as the task-attempt schema. Parent/child task relationships do not themselves establish authority to cancel every descendant process or unrelated turn in a reused conversation.

The owner now selected both standalone and board-linked delegation. The illustrative path's board work/assignment step applies when linked; standalone delegation has durable execution tracking without requiring that board record. This selects neither a second board task model nor acceptance/cancel authority merely from the parent relationship.

### Deliver a peer message

```text
Sender → direct-mail custody → addressed recipient carrier → delivery outcome
```

This can reference a task or carry a result, but the [mail receipt](</Users/shravansunder/code/projects/codex-router/crates/collaboration-mail-protocol/src/mail_outcome.rs:18>) records its delivery meaning. It does not independently accept the task, overwrite its status or attest that native work finished. The task API and message API can use shared transport/session machinery without becoming the same domain.

### Accept a Host-local notice and prepare its view

```text
Host-local producer → intake/admission → owning write transaction
  → eligible committed changes → copy/read source → Gateway prepared context → native display
```

Current [notice admission](../../../../../Sources/AgentStudio/Core/PaneContext/PaneContextService+Messages.swift:20) checks scope/current binding where required and commits the notice plus supplied cursor participant. [Cursor SQL](../../../../../Sources/AgentStudio/App/PaneAgents/CLIOutboxCursorCommitParticipant.swift:11) advances monotonically in that same database. [The caller](../../../../../Sources/AgentStudio/App/PaneAgents/PaneCLIOutboxDrain.swift:152) admits only the eligible notice variant and passes the participant. Accepted content and required handled position belong to one transaction even if their copy audiences differ.

Current [context changes](../../../../../Sources/AgentStudio/Core/PaneContext/PaneContextService+Changes.swift:11) is an effectful operation: it advances a reported answer position, confirms receipts and may delete retained events. It cannot be replaced wholesale by reading a Gateway SQL copy. A future split into pure view and acknowledgement must be explicit and preserve the owner, not emerge from a method being called “read.”

### Fork or remove a worktree

```text
Machine-scoped CLI → attached local Host → Git/worktree domain → actual filesystem/Git effects
Frontend request → Gateway → addressed Host → the same owning operation
```

The [corrected machine-local route](../../initial-profile.md:11) works independently of Gateway availability and includes local Host activation when absent. CLI parses/formats; the domain owns policy/effects. Git administration, copied directory contents, app exclusions and publication/reconciliation have different outcomes; Linux fork behavior needs its selected counterpart. Existing Swift SDK behavior is the reference, not an automatically importable Rust/Linux implementation. No new Git implementation is selected by this map.

### Produce annotation output at a native destination

```text
Host prepares exact output and membership
  → Gateway routes explicitly requested destination work
  → actual native/declared destination performs the effect
  → Host finalizes the attempt and exact handled revisions
```

The current [output coordinator](../../../../../Sources/AgentStudio/Features/Bridge/Runtime/WorktreeAnnotations/WorktreeAnnotationOutputCoordinatorActor.swift:395) performs the effect before finalization. If finalization fails after effect success, [the result is partial success](../../../../../Sources/AgentStudio/Features/Bridge/Runtime/WorktreeAnnotations/WorktreeAnnotationOutputCoordinatorActor.swift:426). There is no distributed SQL/clipboard transaction. Replicating or replaying an output-attempt row must not perform that external effect again.

## Storage cuts follow invariants, not process boxes

| Boundary to preserve | Authoritative commit | Outside that commit |
| --- | --- | --- |
| Session binding and admitted provider evidence | Current binding plus accepted evidence/reduction | Provider process behavior and later view publication |
| Context notice intake | Accepted notice plus required handled-position participant | Producer file read, display publication and separately handled refusal paths |
| Context changes/receipts | Reported position, receipt settlement and applicable event pruning | A client merely receiving a prepared view |
| Shared graph/Undo | Graph validation/replacement and applicable Undo mutation | Native mount/focus and independent backend execution |
| Annotation output | Preparation commit; later finalization commit | Clipboard/file destination effect between the commits |
| Copy apply | Declared rows, source position and admitted hook work under the receiver contract | Independent external follow-up and native application |

Current [Core graph replacement](../../../../../Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceCoreRepository.swift:187) is one write. [Ordinary bundle save](../../../../../Sources/AgentStudio/Core/State/SQLite/WorkspaceSQLiteDatastoreActor.swift:149) commits Core, then later [writes Local](../../../../../Sources/AgentStudio/Core/State/SQLite/WorkspaceSQLiteDatastoreActor.swift:215); one Swift actor does not make both files one atomic transaction.

The shared library exposes [replicated table membership and private local migrations](</Users/shravansunder/code/projects/agent-fleet-sync/crates/fleet-sync-writer/src/replicated_schema.rs:4>). Its [capture normalization](</Users/shravansunder/code/projects/agent-fleet-sync/crates/fleet-sync-writer/src/capture_stream.rs:299>) skips tables outside the declared layout. This supports evaluating private co-commit checkpoints without exporting them, not a selected Studio schema. A read copy missing private writer state cannot automatically rebuild that writer.

The [table matrix](../../designs/02-data-ownership-replication/storage-placement-matrix.md:96) retains explicit holds for mixed pane/content/Undo rows, notes/pins, navigation scope and dormant Inbox data. Moving an entire legacy database to Host or Gateway would bypass those meaning decisions.

## How commands, facts and views connect

| Traffic | Owning mechanism to evaluate | Required distinction |
| --- | --- | --- |
| Commands | Direct typed operation at the actual capability owner | Caller/target admission and operation-specific outcome; no global mutation bus |
| Ordered facts | Source-owned sequence and declared replay/gap semantics | Order matters within its source; no invented global order across Hosts |
| Replaceable observations | Keyed latest-state publication after source admission | Intermediate states may be coalesced only where the domain permits replacement |
| View preparation | Immutable qualified capture, pure family transform and currentness check | Calculation, offering, delivery and native application are different stages |
| Terminal bytes | Bounded binary attachment stream | Exact ordering and explicit restore/detach behavior; not one RPC per byte |
| File/review content | Qualified finite descriptors and bounded transfer | Content identity, currentness and completion before application |

A bus can carry facts between owners. It does not decide their meaning, replace transaction predicates or make every feature event-sourced. Typed operations, per-owner streams and pure transformations can coexist in one Tokio process or behind a qualified service interface. A single global reducer or broker is not required by this research.

## What the Gateway materializes

Gateway can prepare repository/sidebar groups, session/context summaries, search results and declared metadata from authorized, qualified source inputs. It needs source-specific validity and current client intent. A Host ID plus resource kind/identity prevents same-path cross-Host confusion. A source position, a view generation and an actual native publication acknowledgement are different witnesses.

The [prepared-view design](../../designs/09-gateway-cli/prepared-view-boundaries.md:77) separates source reads, desired interest, pure preparation, delivery and native application. Host read-side maintenance remains at Host. Native metrics, actual viewing, focus and live editor buffers remain at their real client owner. SQL rows, a provider operation log and a terminal screen are not interchangeable materialized views.

## What remains open, without stopping unrelated work

- The selected planned-upgrade continuity outcome constrains process lifecycle and consolidation. Its qualified mechanism remains open; the ownership/source/API map remains usable.
- Delegation still needs assignment/acceptance/attempt/cancel authority and failure semantics; narrower Router control/settlement reuse is not a complete task system.
- Table export, audiences, transaction units and mixed field meanings remain explicit storage contracts. There is no new physical database count here.
- Gateway/Host/local-client schema, exact protocol adapters and real Mac/Linux/iOS proof remain qualification work. Current broad Router contracts dependencies need a portability fit check.
- The 42-leaf index does not establish absence of undiscovered features. Additional provider/task/mail integration must get explicit coverage. No checkbox was checked as delivered.

The next structural design can bind these interfaces one capability at a time while leaving physical process placement open. This map is a source-grounded research aid; existing governing specifications and their named gaps keep their authority.
