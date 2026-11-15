# Studio, Router, tasks and delegation: boundary research

Research cutoff: local date 2026-11-01. Initial source inspection was followed by the bounded native prototype reported in [observed results](native-continuity-results.md). This is not an adopted specification, deployment decision, implementation plan or full product Host-upgrade proof.

Later source/design evidence is recorded separately in the [2026-11-02 ACP reuse update](../2026-11-02-acp-control-reuse.md). It preserves this earlier snapshot while linking the owning Router design, shared-prompt/cancellation refinements and corrected proof boundaries.

**Latest direct owner decision:** active provider turns must keep running through a planned Host upgrade; qualify independent execution custody. Recorded on the daemon work root as `01a19980-ee41-7591-9609-9dccda2a7ada`. This supersedes the earlier recommendation to wait for settlement. The mechanism remains open; interruption plus restored history is insufficient. This outcome selects no crash/power-loss guarantee or execution-owner replacement policy.

**Second direct owner decision:** support standalone and board-linked delegation, with durable execution identity, outcome and recovery in either case. Recorded as `01a19990-14b4-755a-9388-2f8ff3b42ea6`. Standalone execution does not need a synthetic saved board task or schedule. A linked execution supplies evidence to the existing board-task authority. Exact control/acceptance rights, storage shape and cancellation policy remain open.

## Answer

Keep two maps: **who owns each truth and operation**, and **which owners share an executable, machine, transaction and release**. One integrated Studio product can reuse Router's agent-control implementation while retaining distinct terminal, provider, task, mail, Git, storage and presentation responsibilities. A Rust module, an application service and an OS process answer different questions.

The strongest existing integration seam is Router's shared session-command/event backend, already used by ACP and the reverse app-server frontend. Composing it into the Studio Host is credible. Composing the entire existing Router Host is more involved: it also owns installation identity, singleton authority, update/replacement and multiple retained subsystems. There is no compiled or running combined Host in this research.

The task discussion adds a second important separation: durable work, execution attempts, delegation relationships and message custody have different identities and outcomes. Router already has durable automation runs and exact-turn settlement evidence. Investigate reuse before inventing another run journal. The relation between board tasks and those runs is still a contract to establish, not something this note selects.

## Owner scope and what stays open

- Confirmed directly in the main conversation: the Studio daemon includes ZMX/terminal control **and** ACP/native agent-session control, plus the previously discussed machine capabilities.
- Confirmed: loose messaging and an actual task system are separate capabilities. The task system is more than a request written in a message.
- Existing direction retained: Mac/Linux Host; device Gateway on Mac and embedded within the iOS app lifecycle; native clients display and control through declared adapters; multiple Hosts per Gateway.
- Existing corrected CLI direction retained: machine-scoped worktree commands use/activate the attached local Host independently of Gateway availability. Frontend/UX CLI remains a separate Gateway route. Remote CLI transport details remain open.
- Existing direction retained: writer leases belong to a separately injected central control-plane authority. Gateway is a copy/read-model consumer, not its issuer. Transfer policy remains out of this research.
- Still open: one combined Host process versus separate Router and Studio processes; exact delegated-task ownership/acceptance/cancellation rules; semantic guarantees for unmodified CLIs; restart/re-adoption and service packaging; physical database partitioning.

The owner's supplied [side-conversation note](../../../../wip/2026-11-01-task-board-execution-discussion.md:1) explicitly calls its conceptual model a proposal. Its T3 source pointers were checked below; its suggested task model was not promoted to owner policy.

## Questions and source classes

1. Which responsibilities need distinct owners even if they share a process?
2. Which existing seams permit sharing a Rust runtime, and which lifecycle assumptions complicate that?
3. What differs between durable board work, delegated execution, provider sessions and direct messages?
4. Where do Gateway views, writer transactions, replication sessions and central authority fit?
5. Which failures distinguish the plausible process arrangements, and what evidence is still needed?

Source walk: local Studio docs/code and the supplied note; adjacent Router and fleet-sync code; pinned T3 comparison source; DeepWiki pointers; official Tokio documentation. Memory was used only to locate earlier daemon work and then superseded by current reads. No provider session/transcript files were read. No saved Reader material or UI observation was relevant. The initial source pass was followed by independent source advice and the separately recorded [native Operator fixture](native-continuity-results.md). This is not a formal independent review.

## Checked revisions

| Source | Local revision | Evidence limit |
| --- | --- | --- |
| Studio daemon worktree | `a3c9457389046df9a9fe1e0171c3bb842575844d` | Current Swift implementation plus retained design proposal; not a product Rust implementation |
| Router | `1cf0ce5a6fe23bf840452f39ba7e61e2bc2282e8` | Source only; installed binaries are not attested by the checkout |
| agent-fleet-sync | `3a2153ec98de531085b4c4e618b972dffbb1f08e` | Shared library source, not Studio consumer integration |
| T3 local checkout | `3fd2b855c5c6b9169cdfe3733b34011c1c5ed4b7` | Pinned local comparison; not a claim about the latest upstream deployment |

## Boundary vocabulary

| Boundary | Question it answers | What crossing it requires |
| --- | --- | --- |
| Domain/module | Who decides what this means and which changes are legal? | Typed operations and explicit facts; no access to another owner's private rows |
| Application service/API | What can another caller request or observe? | Target, caller authority, result meaning, cancellation and compatibility contract |
| OS process | What starts, exits, crashes and is replaced together? | Supervision, IPC if separate, resource ownership and restart/re-adoption policy |
| Machine/network | Where do the filesystem, credentials and live resources exist? | Authenticated addressed transport and explicit uncertainty after disconnection |
| SQL transaction | Which predicates and changes commit together? | One actual transaction scope; external process/network effects remain separate |
| Replication unit | Which committed history and table set reach which copies? | Writer identity/epoch, source position, audience, retention and refill rules |

**Inference:** these boundaries need not coincide. Several domain modules can share one process or physical database. One process can still have several transaction and authorization scopes. Putting a child process outside the daemon does not automatically define what survives daemon replacement.

## Responsibility map to evaluate

This is a conceptual ownership map, not a process/deployment selection.

```text
Integrated AgentStudio system
├── Native UX client
│   └── Rendering, keyboard/focus, windows, platform effects
├── Device Gateway
│   └── Host connections, routing, subscriptions, eligible copies and prepared views
├── Addressed machine's Host capabilities
│   ├── Terminal execution and attachment control → ZMX backend
│   ├── Semantic agent control → existing Router/provider adapters
│   ├── Git, worktrees, files and discovery
│   ├── Context, annotations and other declared machine workflows
│   └── Guarded writes and selected replication delivery
├── Work coordination
│   ├── Durable board tasks, roles, dependencies and accepted work outcomes
│   └── Execution/delegation state linked to actual provider work
├── Direct agent mail
│   └── Immutable delivery items, custody, receipts and cancellation of delivery
└── Fleet / central control-plane integrations
    └── Selected discovery/admission responsibilities and designated writer-lease authority
```

Work coordination and mail can be hosted alongside other components while preserving their own owners. Their placement in this tree creates no requirement for two new daemons. Fleet connectivity and the fleet-sync storage library are different concerns; using one does not select the other's deployment.

## Findings, evidence and limits

### F1 — One provider implementation can serve several frontends

**Direct observation, investigated/accepted as source fact.** Router's [SessionCommandPort](</Users/shravansunder/code/projects/codex-router/crates/collaboration-contracts/src/session_command_port.rs:111>) defines create/load/resume/prompt/steer/queue/cancel/close operations separately from the event hub. [HostSessionCommandPort](</Users/shravansunder/code/projects/codex-router/crates/codex-router-host/src/provider_session_command_port.rs:43>) implements that port. [Startup composition](</Users/shravansunder/code/projects/codex-router/crates/codex-router-host/src/collaboration_runtime/startup_composition.rs:596>) constructs one shared commands/events backend and passes it to ACP and reverse app-server frontends through line 658.

**Inference:** reuse these semantic owners in the Studio integration. MCP, CLI, native UI and a new network adapter should be frontends to those operations, each with intentional exposure/admission. They should not each become another provider-control engine. The current port's exact methods/results still need a fit check against every promised Studio operation; its existence does not prove full coverage.

### F2 — Same-process composition is credible, not drop-in

**Direct observation.** [CollaborationRuntime startup](</Users/shravansunder/code/projects/codex-router/crates/codex-router-host/src/collaboration_runtime/startup_composition.rs:11>) exposes asynchronous constructors; lines 73–93 load service/installation identity and create a service epoch. [Its retained fields](</Users/shravansunder/code/projects/codex-router/crates/codex-router-host/src/collaboration_runtime.rs:111>) include board admission/subscriptions, provider storage/supervision, publication, tasks, automation and schedules. [HostRuntime](</Users/shravansunder/code/projects/codex-router/crates/codex-router-host/src/lifecycle_owner.rs:190>) acquires singleton authority and supports inherited authority across whole-Host replacement.

**Inference:** a common Tokio composition root is a credible target. It must choose one lifecycle/update owner rather than instantiate two competing whole-Host lifecycles. Native provider executables and ZMX remain backend processes where required. Modular code can be reused without committing to shared process hosting.

**Unresolved:** Linux/iOS target/dependency closure, startup/shutdown interaction, packaging, native-provider custody on replacement and actual crash/re-adoption. No performance, memory, combined compile or runtime claim was established.

### F3 — Terminal execution, provider conversation and connection are separate identities

**Direct observation.** Studio's [ZmxSessionControl](../../../../../Sources/AgentStudio/Core/RuntimeEventSystem/Runtime/ZmxSessionControl.swift:26) binds observations to process/socket identity and checks incarnation before retirement. Sending Kill returns pending, not proof of extinction, at lines 80–83. This is Darwin-specific current code, not Linux parity or validation of every listener/fork pattern. [SessionsRepository](../../../../../Sources/AgentStudio/Features/Sessions/State/SQLite/SessionsRepository.swift:8) loads provider/pane/conversation binding context, reduces admitted evidence and commits changes within the actual SQLite write.

**Inference:** controlled launch and socket evidence can support association and authority checks. They cannot alone provide native turn/cancel/approval/conversation semantics or a complete transcript. Preserve distinct resource identity and provider-admitted binding. Scope of support for an unmodified CLI remains an owner question.

### F4 — Task status, execution settlement and mail delivery answer different questions

**Direct observation.** Router's [board Task](</Users/shravansunder/code/projects/codex-router/crates/message-board/src/work_records.rs:42>) has stable work identity, status and revision; its links are BlockedBy/RelatedTo. Router also has [RunPhase](</Users/shravansunder/code/projects/codex-router/crates/agent-automation/src/run_lifecycle.rs:6>) and [native/provider settlement](</Users/shravansunder/code/projects/codex-router/crates/automation-storage/src/run_completion_state.rs:9>). That completion code checks the exact turn or provider operation before settling a run. [Run interruption](</Users/shravansunder/code/projects/codex-router/crates/automation-storage/src/run_stop_state.rs:1>) records stop intent without releasing execution ownership. [Mail status](</Users/shravansunder/code/projects/codex-router/crates/collaboration-mail-protocol/src/mail_outcome.rs:1>) separately records custody and carrier acceptance.

**Inference:** first map task assignment/acceptance to existing run and provider operations before adding new records. A result reaching an inbox is not itself acceptance of a durable task. Board-task identity, automation-run identity, provider conversation/turn identity and message-item identity need explicit associations. This source inspection is not a proof that the complete proposed delegated-task system already exists in Router.

### F5 — T3 supplies useful execution contracts, including a cross-machine crash gap

**Direct observation of the pinned comparison source.** T3's [delegation tools](</Users/shravansunder/code/opensource/agent-workspaces/t3code/apps/server/src/mcp/toolkits/orchestrator/tools.ts:86>) expose real task create/status/cancel interfaces. Its [result contract](</Users/shravansunder/code/opensource/agent-workspaces/t3code/packages/contracts/src/orchestratorMcp.ts:148>) separates task state, child identity, pending descendants, results and pending questions/approvals. [Local delegation](</Users/shravansunder/code/opensource/agent-workspaces/t3code/apps/server/src/mcp/OrchestratorMcpService.ts:2400>) records parent thread/run/node and completion-delivery policy. [Cancellation](</Users/shravansunder/code/opensource/agent-workspaces/t3code/apps/server/src/mcp/OrchestratorMcpService.ts:2507>) checks child/descendant authority before stopping local descendants.

In [remote delegation](</Users/shravansunder/code/opensource/agent-workspaces/t3code/apps/server/src/peer/RemoteDelegation.ts:256>), a scoped key associates remote launch and local task recording. Lines 324–326 explicitly identify the crash interval after launch and before parent-side recording; a retry using the same request ID can record the existing launch. This does not imply two-machine atomicity or exactly-once external effects.

Its [terminal viewer release](</Users/shravansunder/code/opensource/agent-workspaces/t3code/apps/server/src/terminal/Manager.ts:3171>) detaches observation, while the [manager finalizer](</Users/shravansunder/code/opensource/agent-workspaces/t3code/apps/server/src/terminal/Manager.ts:2830>) kills manager-owned terminal processes. **Inference:** disconnected-view durability and daemon-restart durability are different promises. ZMX's persistent execution model must have its own restart contract rather than inheriting T3's terminal finalizer.

### F6 — Replication, derived views and application operations are distinct seams

**Direct observation.** fleet-sync's [transport port](</Users/shravansunder/code/projects/agent-fleet-sync/crates/fleet-sync-session/src/transport_port.rs:65>) separates logical session code from connection send/receive/close. [ReplicationTransport](</Users/shravansunder/code/projects/agent-fleet-sync/crates/fleet-sync-writer/src/sender_contract.rs:54>) supplies session routing without holding a writer transaction/guard over the network wait. [ReplicatedDatabase::begin_write](</Users/shravansunder/code/projects/agent-fleet-sync/crates/fleet-sync-writer/src/replicated_database.rs:393>) restores actual authority and starts the owned write path. [ReceiverHook](</Users/shravansunder/code/projects/agent-fleet-sync/crates/fleet-sync-receiver/src/receiver_contract.rs:41>) distinguishes transaction-scoped apply/snapshot work from follow-up calls.

**Cited design proposal.** Studio's [storage companion](../../designs/02-data-ownership-replication/storage-placement-design.md:37) distinguishes transaction domain, physical database and replication unit. Its [integration workbench](../../designs/11-operations-integration/program-design-workbench.md:142) puts authority renewal/guarded writes in Host, selected copies/prepared views in Gateway, and central authority outside Gateway.

**Inference:** copies may feed views; they do not become another writer or replay process/native effects. Replicated SQL state does not automatically serve as a terminal stream, provider transcript, task executor or command bus. Exact table export, unit size, audiences, retention and adapter fit still require qualification. Fleet rendezvous does not establish direct QUIC reachability or a relay topology.

## Process arrangements worth comparing

These are advice, not selected changes to existing process contracts.

| Arrangement | Gain | Cost and who pays | Evidence that could change the preference |
| --- | --- | --- | --- |
| Compose Router and Studio machine owners in one Rust Host process; keep native backends separate | One machine-facing lifecycle/composition surface; removes an inter-daemon hop; shared semantic owners | Users/operators share a larger crash/update boundary; implementers reconcile dependencies, singleton/update policy and shutdown | Combined target build or replacement/re-adoption cannot preserve required execution, or one component needs independently enforceable isolation |
| Keep Router and Studio daemon processes, reuse typed client/contracts | Independent upgrade/crash scope; less initial lifecycle integration | Maintainers/operators own IPC/auth/version/startup/reconnect contracts and two packages; cross-process operations retain partial outcomes | Real integration shows lifecycle independence is useful enough to pay those costs |
| Extract reusable libraries first and retain current deployment until qualification | Makes reuse and ownership concrete without prematurely changing deployment | Temporary delivery sequencing cost; the final runtime boundary remains unresolved | Measured/observed lifecycle and platform results select one of the above |

Current research direction: reuse shared semantic libraries and explicit owners, and qualify execution custody outside the Studio Host replacement boundary. Process consolidation remains deferred until it preserves the selected active-turn continuity. Keep Gateway hosting and central authority separate from this Router/Host process choice. A crate per domain does not require a daemon per domain.

## Follow one delegated task across the boundaries

Illustrative obligations to settle, not a selected schema:

1. An authorized execution request records its durable work association: standalone, or linked to an existing board task. A linked task retains its own work/assignment authority. An ordinary peer message can reference the work without becoming its canonical lifecycle.
2. An authorized execution request reaches the addressed Host/provider owner. It records enough actual operation identity to reconcile uncertain launch rather than creating another child on a blind retry.
3. The provider owner starts or attaches the declared conversation/execution, streams admitted events and routes questions/approvals to their actual authority.
4. Gateway reconnects subscriptions and prepares views. Disconnecting the requester or UI does not, by transport convention, decide cancellation of the task or its resource.
5. Exact execution settlement is recorded with its evidence. Result notification delivery is separately observable.
6. The designated task authority accepts/refuses the result or decides further work under the eventual task contract. Neither a provider turn ending nor a mailbox receipt silently takes over that decision.

Unselected: reuse versus fresh conversation, successive/concurrent attempts, requester-departure behavior, cascade cancellation, reassignment, approval authority and result acceptance. A task tree, an execution/delegation tree and an OS process tree cannot be assumed identical.

## Qualification questions and discriminating probes

No probes were executed in the initial source-only pass. Subsequent native caller-loss attempts and their bounded result are recorded separately below and in [observed results](native-continuity-results.md). These broader candidates remain research/qualification inputs, not an adopted implementation plan or performance result.

| Question | Smallest meaningful comparison | What would count against the hypothesis |
| --- | --- | --- |
| Can one Tokio composition own both services on the required targets? | Build a qualified composition using real public provider ports and the actual backend adapter; inspect target dependency closure | Unsupported target/dependency or competing singleton/lifecycle assumptions requiring a changed contract |
| What survives Host replacement? | Active ZMX execution and native provider work while replacing only the supervising Host; reconcile exact identities afterward | Wrong-resource reattachment, lost custody, unintended termination or fabricated completion |
| Is sharing a process worthwhile for responsiveness? | Same operations via in-process port and real UDS under terminal/Git/copy load; measure control latency, resource use and shutdown behavior | No material benefit or correlated stalls/isolation costs exceeding the adopted budget; no budget selected here |
| Does task launch recover without duplicate execution? | Break after remote launch/before parent record; repeat the same operation identity and inspect actual resource plus durable records | Duplicate launch, untracked live child or false completion |
| Are cancellations scoped correctly? | Cancel one attempt with independent peer work and descendants present, then observe exact cessation/unchanged work | Unrelated work stops, accepted stop reported as confirmed cessation, or an old attempt stops replacement work |
| Does multi-Host view state remain truthful? | Same paths/IDs on two addressed Hosts; lose one connection while the other updates | Wrong-Host fallback, stale copy labeled current, or view loss terminating execution |

Tokio's official [spawning guide](https://tokio.rs/tokio/tutorial/spawning) describes runtime-scheduled tasks, and its [shutdown guide](https://tokio.rs/tokio/topics/shutdown) separates detecting shutdown, notifying tasks and awaiting them. Its [process Command documentation](https://docs.rs/tokio/latest/tokio/process/struct.Command.html#method.kill_on_drop) explicitly states that dropping a child handle does not kill the child by default. These support requiring explicit process custody; they do not establish any particular current Router or Studio launch policy.

## Follow-up: lifecycle boundaries traced to their owners

Continued after the owner's resume instruction. Same source pins and research-only scope. This changes the strength of the process comparison; it does not select a new lifetime promise.

| Resource / boundary | Checked current behavior | What it establishes | What it does not establish |
| --- | --- | --- | --- |
| ZMX client attachment | `handleDetach` calls `closeClient(..., false)`; only `shutdown_on_last && zero clients` invokes shutdown | This detach path releases a viewer without terminating the backend | Host registry re-adoption, machine reboot recovery, automatic agent restore or every possible disconnect path |
| Current Studio creation | `createPaneSession` returns a handle/directory; execution starts on later attach | Source behavior still differs from the proposed renderer-free Host create operation | A successful handle return is not observed running execution |
| Router collaboration runtime | Shutdown retires admission, shuts board session and provider queue/supervisor, drains owned tasks and closes stores | Its lifecycle owns substantial behavior beyond a callable session interface | It cannot be imported as a supposedly independent provider library without accounting for those lifetimes |
| External ACP provider child | Client shutdown cancels tokens and joins the connection task; retirement emits lost-turn/unloaded state, kills a still-live child/process group and reaps it | Provider process separation alone does not give it lifetime independent of this supervisor | A clean shutdown trace does not prove what happens after SIGKILL, power loss or a provider's own crash |
| Retained Codex app-server child | Whole-Host activation invokes app-server shutdown; that routine sends terminate, escalates group kill if required and reports actual teardown outcome | The checked replacement path deliberately ends the retained child before reexec | It is not a seamless live-turn handover; automatic updater admission is not generalized from this explicit restart path |
| External provider operation store | Metadata-only records contain operation/binding/stage/effect/reconciliation identity; no prompt/reply/transcript inputs | Useful reconciliation metadata can persist separately from native history | Copying this SQL database cannot reconstruct provider conversation contents or prove uninterrupted work |

Opened primary anchors:

- [ZMX detach](../../../../../vendor/zmx/src/loop.zig:1048) and [close-client condition](../../../../../vendor/zmx/src/loop.zig:662).
- [Current Studio create](../../../../../Sources/AgentStudio/Core/RuntimeEventSystem/Runtime/ZmxBackend.swift:182) and [proposed independent create](../../designs/04-terminal-runtime/execution-lifecycle-design.md:36).
- [Collaboration shutdown](</Users/shravansunder/code/projects/codex-router/crates/codex-router-host/src/collaboration_runtime/lifecycle.rs:39>) and [supervisor shutdown](</Users/shravansunder/code/projects/codex-router/crates/codex-router-host/src/external_provider_supervisor.rs:429>).
- [ACP client shutdown](</Users/shravansunder/code/projects/codex-router/crates/acp-client-runtime/src/agent_session_client/provider_client_operations.rs:460>) and [retirement plus child teardown](</Users/shravansunder/code/projects/codex-router/crates/acp-client-runtime/src/agent_session_client/provider_connection_task.rs:671>).
- [Explicit RestartHost admission and activation](</Users/shravansunder/code/projects/codex-router/crates/codex-router-host/src/lifecycle_owner/request_admission.rs:182>), [retained-child teardown](</Users/shravansunder/code/projects/codex-router/crates/codex-router-host/src/host_replacement_activation.rs:29>), [app-server shutdown](</Users/shravansunder/code/projects/codex-router/crates/codex-router-host/src/app_server_shutdown.rs:150>) and [replacement exec](</Users/shravansunder/code/projects/codex-router/crates/codex-router-host/src/lifecycle_owner/update_activation.rs:155>).
- [Provider metadata-only storage contract](</Users/shravansunder/code/projects/codex-router/crates/collaboration-runtime/src/provider_operation_store.rs:1>).

**Refined inference:** separate Router and Studio daemon processes could isolate Studio-only upgrades from Router-owned provider work, provided their new connection lifecycle preserves that custody. This does not solve interruption when Router itself upgrades. A stronger promise that active native work outlives every frontend/control-service upgrade would require an additional qualified custody/handover design or a rule deferring upgrades; neither is selected or implemented here. A durable task identity and retained conversation history can survive while a particular execution attempt is interrupted. Those are three distinct promises.

## Follow-up: what each API boundary must carry

These are obligations to bind in the eventual contracts, not newly selected wire schemas.

| Caller → owner | Request / observation meaning | Trust and lifetime boundary |
| --- | --- | --- |
| Native client → Gateway | Explicit client/Host target, operation intent; prepared view subscriptions | Native rendering/input belongs to the client; transport loss does not decide execution cancellation |
| Gateway → addressed Host | Typed capability operation and admitted origin/delegation context | A typed actor field is not authentication; the actual Host admission owner checks scope/target before effect |
| Task authority → execution owner | Authorized work/attempt association, actual launch/control operation | Task parentage alone grants no provider approval or cancellation authority; one task model must own its accepted outcome |
| Provider adapter → interaction owner | Actual approval/question identity, supported actions and settlement | Several renderers may display it; one authority settles it. Provider claims are inputs, not new grants |
| Host source → copy receiver → prepared view | Selected committed data, source position and validity witness | Read copies cannot mutate Host truth or cause native/provider effects on replay |
| Central registry → Host writer gate | Actual writer authority/epoch/validity for the selected replication unit | A database writer lease neither authenticates an arbitrary UI caller nor authorizes every capability |
| Peer sender → mail owner | Immutable item and addressed recipient, actual custody/receipt | Delivered mail is not task acceptance, native execution completion or a transcript-copy guarantee |

Commands go directly to their owning operations; ordered facts retain their order; replaceable observations may be coalesced at their admitted source; terminal bytes and finite content have separate bounded delivery. This follows the existing [lane proposal](../../designs/11-operations-integration/program-design-workbench.md:233), not a decision to install a universal bus or event-source every domain.

## Additional source constraints

Current source narrows two reuse claims:

- [RunRecord](</Users/shravansunder/code/projects/codex-router/crates/agent-automation/src/run_execution.rs:75>) has a required `schedule_id`. Its phase/effect/settlement machinery is useful prior art, but this scheduled-run row is not automatically a general delegated-task execution record. Reusing the implementation must account for that meaning; no schema change or new journal is selected here. A search for `TaskId|task_id|AssignmentId|assignment_id` in the three named run-execution/lifecycle/admission files found no matches. That bounded search does not prove there is no association elsewhere in Router.
- [SessionEventHub](</Users/shravansunder/code/projects/codex-router/crates/collaboration-contracts/src/session_event_hub.rs:46>) requires an atomic snapshot-plus-live subscription. Its [current provider implementation](</Users/shravansunder/code/projects/codex-router/crates/collaboration-runtime/src/provider_session_event_hub.rs:26>) keeps a per-session in-memory history and replay epoch; [history replay](</Users/shravansunder/code/projects/codex-router/crates/collaboration-runtime/src/provider_session_event_hub.rs:286>) replaces the sender and resets its retained view. The subscriber channel capacity is not a global history-retention limit. A native transcript, this normalized live/replay view, the metadata-only operation store and a Gateway projection are separate artifacts. Neither an empty local hub nor a copied metadata table establishes that the native provider has no history.

## Selected continuity: interface feasibility

The direct owner answer is recorded above and supersedes the earlier wait recommendation. A concrete mechanism to qualify is Router/provider custody outside the replaced Studio Host interface. It preserves one logical Host capability surface while making its physical restart boundary explicit. This is still a candidate, not selected process placement.

Additional decisive source reads narrow that candidate:

- [The app-server facade connection](</Users/shravansunder/code/projects/codex-router/crates/collaboration-runtime/src/router_session_app_server.rs:178>) owns connection-local queues/subscriptions; its normal cleanup aborts those [connection tasks](</Users/shravansunder/code/projects/codex-router/crates/collaboration-runtime/src/router_session_app_server.rs:338>). That source scope is different from whole-provider-runtime teardown. It does not establish every abrupt I/O failure's behavior.
- [Host prompt handling](</Users/shravansunder/code/projects/codex-router/crates/codex-router-host/src/provider_session_command_port.rs:164>) waits for the correlated turn start and returns a turn handle; [retained operation](</Users/shravansunder/code/projects/codex-router/crates/codex-router-host/src/external_provider_supervisor.rs:608>) spawns work independently of its answer receiver. These are promising ownership seams, not an observed upgrade.
- [Facade turn/start](</Users/shravansunder/code/projects/codex-router/crates/collaboration-runtime/src/router_session_app_server_methods.rs:329>) generates a new input identity. Repeating that frontend call after losing its reply cannot be treated as proven safe reconciliation. The future Host boundary needs actual operation/turn evidence, not blind request replay or guessed failure.
- [The running-turn reattach test source](</Users/shravansunder/code/projects/codex-router/crates/collaboration-runtime/src/router_session_app_server_reattach_tests.rs:296>) uses `ScriptedSessionBackend`. It is useful protocol/forwarding evidence and was read, not run here. It does not prove a real native provider turn survives Studio Host replacement.


## Current evidence and remaining contracts

The [native results](native-continuity-results.md) and [structured evidence](native-continuity-result.json) support one same-command/same-turn requester-loss primitive with retained observer custody. Full replacement-adapter reattachment, product Host upgrade, provider-process incarnation, callbacks and task-result recovery remain unqualified. The [qualification note](continuity-qualification.md) separately records the source-level stale-turn cancellation gap.

The selected outcomes above govern the next design work. Exact execution/board acceptance authority, cancellation scope, retained payload audiences, storage shape and deployment placement still require explicit contracts. No public schema, crate count, new dependency or product implementation is selected by this supplement.

Search history, assignment receipts, Advisor handbacks and delivery checkpoints remain in `tmp/practices-research/2026-11-01-system-boundaries/`. This file retains the source findings and rationale; it is not a formal review verdict.
