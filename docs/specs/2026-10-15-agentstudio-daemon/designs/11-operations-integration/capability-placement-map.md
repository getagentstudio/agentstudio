# How each capability gets data and reaches its client

**The Host acquires and processes machine data; the Gateway prepares client views; the client supplies native interaction and presentation. Each capability needs its own complete path through those responsibilities.** A method catalog, a database inventory and a bus diagram answer different parts of that question.

This working realization map accounts for the eighteen families in the [existing capability catalog](../../capability-contracts.md#complete-surveyed-family-disposition). **Current acquisition** below is source evidence at AgentStudio `624300332f5e50f7bb8cbb9fc786d5e5b4a3d462`, with Git package `4cca397dfc869857064da4e9ec8289ea46adc479`. **Proposed placement** is the Lead's structural interpretation of the selected Host/Gateway/native roles, not a frozen public API or accepted complete Program Design. The individual K contracts remain authoritative in their existing folders. Family coverage does not establish that every operation, argument branch or failure is fully designed.

## Read the map at three levels

1. The coverage index finds a capability and its contract home.
2. Each family explains acquisition, processing/state, proposed placement and the exact boundary still to finish.
3. The linked code and scoped specifications supply operations and detailed failure meaning. The [86-table catalog](../02-data-ownership-replication/research/data-catalog.json) is a separate data view, not a second capability list or an export selection.

The last column is reader navigation into the delivery explainer's **non-governing proposal**. It assigns no release priority, implementation order or deferral of a capability's requirements.

| Existing survey family | Contract home | Delivery-proposal navigation only |
| --- | --- | --- |
| CLI worktree commands | [DS05](../05-git-discovery/specification.md), [DS06](../06-worktree-fork/specification.md), [DS09](../09-gateway-cli/specification.md) | I4, broader CLI I7 |
| CLI package install/uninstall | [DS09](../09-gateway-cli/specification.md), [DS11](specification.md) | Provider integration I2; operation I7 |
| CLI provider hooks | [DS07](../07-agents-context/specification.md), [DS03](../03-authority-control-plane/specification.md) | I2 |
| CLI pane verbs | [DS07](../07-agents-context/specification.md), [DS01](../01-service-contracts/specification.md) | I2 |
| RPC framing/descriptors | [DS01](../01-service-contracts/specification.md) | I0 and every exposed increment |
| RPC serving/authority | [DS01](../01-service-contracts/specification.md), [DS03](../03-authority-control-plane/specification.md) | I0 onward |
| Workspace/layout/command queries | [DS10](../10-swift-client/specification.md) | Native integration I1 onward; shared arrangement profile I6/I7 |
| Sessions/pane context | [DS07](../07-agents-context/specification.md) | I2 |
| Repository inventory | [DS05](../05-git-discovery/specification.md) | I3 |
| Git/remote/Forge refresh | [DS05](../05-git-discovery/specification.md), [DS02](../02-data-ownership-replication/specification.md) | I3 reads; I4 mutations |
| Native worktree creation | [DS05](../05-git-discovery/specification.md), [DS06](../06-worktree-fork/specification.md) | I4 |
| Git package | [DS05](../05-git-discovery/specification.md), [DS06](../06-worktree-fork/specification.md) | I3/I4; feasibility I0 |
| Terminal | [DS04](../04-terminal-runtime/specification.md) | I1 execution/attachment; I2 autonomous facts |
| Bridge File/Review | [DS08](../08-files-review-output/specification.md) | I3 finite reads; I5 full workflow |
| Annotations/output | [DS08](../08-files-review-output/specification.md), [DS10](../10-swift-client/specification.md) | I5 |
| Native OS ingress/effects | [DS10](../10-swift-client/specification.md) | Every native increment; broader profiles I7 |
| Observability/configuration | [DS11](specification.md), [DS02](../02-data-ownership-replication/specification.md) | I0 onward |
| Bridge development HTTP host | [DS08](../08-files-review-output/specification.md), [DS11](specification.md) | Existing qualification surface; no production-service increment selected |

The [delivery explainer](../../delivery-increments.md) proposes usable cuts for the owner's requested MVP/integration discussion. The [source qualification](../../research/owner-inputs/mvp-and-integration-explainer-request.md) preserves that request without approving its I-label order. Data ownership, export, transaction and identity obligations apply to every included capability regardless of a reader-navigation label. No new service, crate, release ranking or implementation sequence follows from a family row.

## Operation-level maps

These views expand the family index at the existing declaration layers. Counts overlap; they are not a total feature count. Current source/effect classification and proposed realization remain visibly separate.

| Declaration layer | Detailed map | Coverage limit |
| --- | --- | --- |
| 57 app RPC methods | [Sources, native prerequisites and proposed paths](../01-service-contracts/rpc-operation-map.md) | Every name; not every argument branch or all nested command handlers |
| 44 Git SDK requirements | [Host acquisition, effects and currentness](../05-git-discovery/git-operation-map.md) | 42 non-fork operations plus two fork entries owned by DS06; not automatic public RPC |
| 16 Bridge semantic calls | [Source versus native application](../08-files-review-output/bridge-operation-map.md) | Semantic calls only; finite content and controls have their broader inventory |
| 22 nested annotation kinds | [Transactions, edit custody and output](../08-files-review-output/annotation-operation-map.md) | Shared nested kinds in two outer contexts; not one uniform mutation guarantee |
| 154 command identities | [Native dispatch overview](../10-swift-client/command-operation-map.md) · [Every typed execution path](../10-swift-client/command-execution-map.md) | Exact names/exposure/mode and immediate owners/refusals mapped; full transitive effects and target contracts remain to bind |

This closes the named-operation inventories, not the complete structural design. Per-operation parameters, source races, authority, selected table export, native target routing, cancellation, restart and real target proof still belong in the scoped contracts and their authored designs.

## What clients actually read

The operation layer does not describe every value the UI consumes. These bounded catalogs trace current output fields, source/transform owners, publication and native-only facts. Their family/type counts overlap the operation inventories and one another.

| Consumer boundary | Detailed source catalog | What the target design must preserve |
| --- | --- | --- |
| Repository and Pane sidebars | [16 prepared families, nine input groups and five publication paths](../10-swift-client/sidebar-read-needs.md) | Source-qualified membership/status/activity, client composition and native application are separate |
| Sessions, context and native facts | [14 current families / 36 type-field groups](../10-swift-client/session-native-read-needs.md) | Status/count/detail/receipt boundaries, effectful reads and actual native observation |
| Bridge metadata and content | [Seven bounded read families, including all five finite-content kinds](../08-files-review-output/client-read-needs.md) | Metadata, descriptor custody, exact bytes and publication/effect application are different |
| Proposed Gateway preparation | [Concrete inputs, interfaces, flows and failure boundaries](../09-gateway-cli/prepared-view-boundaries.md) | Portable semantic preparation in Gateway; authoritative work at Host; native metrics/application at client; exact schemas/policies still open |

## Backend acquisition and worktree operations

### CLI worktree commands

- **Current acquisition:** `worktree new/list/remove/prune` enters the worktree runner before IPC credentials are built. It reads the current directory, Git identities/refs/status, configuration and filesystem evidence through the pinned local/remote clients. Even listing can fetch according to its explicit fetch policy. [CLI entry](../../../../../Sources/AgentStudioIPCClient/main.swift:13), [runner and listing](../../../../../Sources/AgentStudioWorktreeOperations/WorktreeOperationRunner.swift:9).
- **Proposed placement:** the addressed Host owns machine policy and Git/filesystem effects. CLI parsing/formatting stays a thin adapter; machine-scoped worktree commands call their executing machine's attached Host daemon. UX/frontend CLI is a separate Gateway entry. Current in-process execution is an extraction surface, not a future Mac-local fallback.
- **State and client view:** Git administration/files and any retained operation/evidence records differ from a Gateway worktree-list projection. A copy becoming current does not prove that a requested remove/prune completed. Preserve operation-specific ref/directory/archive outcomes.
- **Boundary to finish:** public operation subset, attached-machine discovery, exact local Host activation/readiness/failure, cancellation and partial/unknown receipts. IP3 now selects worktree machine CLI → attached local Host daemon and start/activation when absent, independently of Gateway availability. Non-session authority, remote Mac CLI use is required, while direct connection versus local Host relay, its credential and frontend-verb classification remain open. DS05/DS06/DS09 own the remaining contracts; a generic CLI-to-RPC rewrite is insufficient.

### Repository inventory

- **Current acquisition:** watched roots, filesystem callbacks, manual/startup refresh and fallback scanning feed the scanner and exact Git discovery. A completed scan becomes a scoped observation; the app then rechecks source, sequence, root and membership baseline before canonical topology application. [Production scanner](../../../../../Sources/AgentStudio/Core/RuntimeEventSystem/Filesystem/WatchedFolderScanScheduler+Production.swift:5), [topology admission](../../../../../Sources/AgentStudio/App/Coordination/WorkspaceCacheCoordinator+ScopedTopology.swift:7).
- **Proposed placement:** Host discovery owns machine traversal, validation, coverage and admitted repository/worktree membership. Native folder choice supplies an addressed root request; it is not the scanner. Gateway prepares correctly attributed inventory/sidebar reads from selected observations and membership.
- **State and client view:** watched-root configuration, canonical membership, partial scan evidence and displayed rows are separate state. Unknown/inaccessible/lost coverage cannot become a successful empty inventory. A derived sidebar index is not another membership writer.
- **Boundary to finish:** stable root/repository incarnation, allowed paths/aliases, Linux watcher/continuity counterpart, no-client coverage, retention and complete/partial recovery. DS05/DS02 own those contracts.

### Git/remote/Forge refresh

- **Current acquisition:** local status, remote references and Forge receive different demand sets. Local work uses the Git status provider; remote work stages/promotes references; the present Forge provider invokes `gh api graphql` for demanded branches. [Demand fanout](../../../../../Sources/AgentStudio/App/Coordination/FilesystemGitPipeline.swift:344), [remote provider](../../../../../Sources/AgentStudio/App/Boot/WorkspaceRemoteReferenceProvider.swift:25), [actual Forge command](../../../../../Sources/AgentStudio/Core/RuntimeEventSystem/Forge/GitHubCLIForgeStatusProvider.swift:201).
- **Proposed placement:** Host capability owners perform machine/credential-dependent acquisition and validate source/generation/currentness. Gateway combines client interests and prepares repository/branch/PR views. Interest is a scheduling input, not permission to make Swift the sole fact source or a second Git owner.
- **State and client view:** status scope, remote freshness/cleanup debt and Forge branch coverage retain independent meaning. Git refs remain Git state; cached observations may be selected for retention/export. No demanded branches is not a full repository PR census.
- **Boundary to finish:** cross-client demand policy, autonomous coverage, force-refresh effect, budgets/backoff and credentials. Preserve failed, rate-limited, truncated, unavailable, stale and complete-empty distinctions; no Host-wide refresh cadence is selected here.

Host-side Forge acquisition requires an explicitly admitted credential capability on that Host. The current `gh` invocation does not establish that every VM has credentials, authorize copying the person's credentials there, or select a credential broker. Missing credentials must retain their declared unavailable/refusal meaning; private fleet pairing is not a Forge account grant.

### Native worktree creation

- **Current acquisition:** the app resolves topology/destination, excludes concurrent destination work, holds publication and calls ordinary creation or fork. It releases the hold and rescans after failure as well as success. [Creation owner](../../../../../Sources/AgentStudio/App/Coordination/WorktreeCreationCoordinator.swift:81).
- **Proposed placement:** Host owns machine mutation and reconciliation through the selected Git mechanics boundary. Swift owns native command interaction and resulting view actions. The existing CLI and native policy differences must be preserved or deliberately resolved; they cannot disappear behind one generic create call.
- **State and client view:** created filesystem/Git state, admitted inventory and native pane/sidebar application are distinct. Gateway prepares resulting inventory and operation status; `.created` is not automatically a receipt for every subscriber's display.
- **Boundary to finish:** selected creation modes, reconciliation and residue, controller/task custody, native result semantics, complete Mac/Linux fork and any launch-after-create behavior. DS05/DS06/DS10 own the affected contracts.

### Git package

- **Current acquisition:** the separately pinned library owns Git mechanics. Local read execution and repository writer custody differ; fork has its own forwarded-cancellation transaction. App callers own demand, topology and publication. [Package boundary](../../../../architecture/state/agentstudio_git.md), [pinned reader](https://github.com/getagentstudio/agentstudio-git/blob/4cca397dfc869857064da4e9ec8289ea46adc479/Sources/AgentStudioGitLocal/LibGit2AgentStudioGitLocalClient.swift#L175), [pinned writer/fork](https://github.com/getagentstudio/agentstudio-git/blob/4cca397dfc869857064da4e9ec8289ea46adc479/Sources/AgentStudioGitLocal/LibGit2AgentStudioGitLocalClient.swift#L66).
- **Proposed placement:** Host capabilities call a separately owned mechanics interface with explicit Mac/Linux realizations. A Rust executable cannot simply import a Swift package; its Rust/library/adapter binding is still a structural decision. No second ad-hoc Git data plane is authorized in AgentStudio.
- **State and client view:** native Git objects/index/refs/files remain their physical source. Host operational records and observations describe them; replication does not turn a database row into the Git repository itself. Gateway consumes declared observations and results.
- **Boundary to finish:** all selected methods' types/effects, safe dependency/FFI scope, repository custody and platform/fork profiles. The forty-four-operation source inventory is not forty-four approved remote methods or a completed Rust implementation.

### Concrete Git construction sites to cut over

The strangler must account for these concrete local constructions as well as protocol-typed consumers. The first two already accept an injected query; calling them an absence of dependency injection would be inaccurate. Their local defaults still need explicit composition when a resource becomes remote.

| Current site | Existing seam / operation | Migration responsibility |
| --- | --- | --- |
| [Branch-list cache default](../../../../../Sources/AgentStudio/App/Coordination/WorktreeCreationPorts.swift:60) | Injectable `BranchQuery`; default constructs the local client and calls `branches` | Supply the addressed Host read at the selected remote composition boundary, retaining opening-token/currentness rules. Never run the default against a remote path on the Mac. |
| [Fork eligibility default](../../../../../Sources/AgentStudio/App/Coordination/WorktreeCreationPorts.swift:125) | Injectable eligibility query; default calls the SDK's machine/volume/File Provider policy | Run policy at the destination/source machine under the selected Mac/Linux profile. A previously available chooser row is not final fork admission. |
| [Annotation material provider](../../../../../Sources/AgentStudio/Features/Bridge/Transport/WorktreeAnnotations/WorktreeAnnotationSourceCapture.swift:660) | Concrete local client supplied while collecting selected source candidates | Bind the Host content/source owner when that annotation capability migrates, preserving fingerprint, candidate membership and byte/currentness contracts. |
| [Review-client convenience initializer](../../../../../Sources/AgentStudio/Features/Bridge/Runtime/ReviewFoundation/AgentStudioGitBridgeReviewDataClient.swift:847) | A generic client seam exists, but this constrained initializer constructs the local implementation | Replace the selected remote review composition, retaining actual Git comparison/content semantics; a local URL cannot identify its Host. |

Unmigrated local capabilities retain their current owner until their own cutover. A remote capability cannot silently enter one of these local defaults. This table is a finite source-discovery addition, not proof that no other construction exists or permission to reimplement Git in the app.

## Provider, context and terminal paths

### CLI provider hooks

- **Current acquisition:** Codex and Claude have separate argument/environment/stdin decoders and projections. They submit the compiled `session.event` contract. Recognized hooks can return zero after refusal or failed delivery. [Codex path](../../../../../Sources/AgentStudioIPCClientCore/ProviderHooks/ProviderHookInvocation.swift:115), [Claude path](../../../../../Sources/AgentStudioIPCClientCore/ProviderHooks/ClaudeCodeHookInvocation.swift:32).
- **Proposed placement:** an authorized hook inside a Host session enters that Host locally, independently of every Mac and renderer. Host provider admission/reduction owns the binding/evidence meaning; the frontend route remains Gateway-only for the separate frontend class.
- **State and client view:** provider conversation/turn/tool identities, execution session and binding generation remain distinct. Required retained evidence and derived current status have different replacement rules. Gateway serves selected context/status views; it does not infer admission from hook exit zero.
- **Boundary to finish:** actual Host-local credentials and effect-time validation, provider versions/variants, source currentness and result/recovery contract. DS07/DS03 own these. The notice-only offline queue is not a hook delivery mechanism.

### CLI pane verbs

- **Current acquisition:** typed CLI intents use compiled request recipes and writer context. Private CLIStore tracks selected progress; an eligible never-submitted notice can queue locally. The app resolves writer/binding before calling the context service. [CLI runner](../../../../../Sources/AgentStudioIPCClientCore/PaneCLICommandRunner.swift:14), [queue eligibility](../../../../../Sources/AgentStudioIPCClientCore/OfflineOutbox/PaneNotificationOfflineHandler.swift:59), [context adapter](../../../../../Sources/AgentStudio/App/IPCComposition/AgentStudioIPCPaneContextAdapter.swift:32).
- **Proposed placement:** Host owns retained messages, writer order and ask settlement for its session. CLI remains a formatter/requester; Gateway routes frontend calls and supplies declared client views. Host-local authorized inputs continue without Gateway reachability.
- **State and client view:** current `changes` reads also update receipt positions and can prune retained events. They cannot silently become read-only replica queries. A context display, an answer receipt and a human viewing state are different contracts. [Changes transaction](../../../../../Sources/AgentStudio/Core/PaneContext/PaneContextService+Changes.swift:11).
- **Boundary to finish:** split read versus acknowledgement semantics where needed, private bookkeeping/export membership, blocking-wait/reconnect and unknown-delivery outcomes. No generic spool or automatic replay is selected. DS07/DS01/DS02 own the respective parts.

### Sessions/pane context

- **Current acquisition:** the registered provider-event port enters an ordered ingestion FIFO and transactional binding/evidence reducer. Context sends/settlement use the shared prepared application-local transaction boundary. Later status projection consumes evidence, open asks and viewed inputs, then coalesces complete keyed display values. [Sessions repository](../../../../../Sources/AgentStudio/Features/Sessions/State/SQLite/SessionsRepository.swift:8), [context transaction](../../../../../Sources/AgentStudio/Core/PaneContext/PaneContextService+Messages.swift:11), [complete source walk](../07-agents-context/research/session-status-ownership.md).
- **Proposed placement:** Host owns authoritative evidence/binding/context workflows and required facts. Gateway prepares a client status/context view using the selected client/user scope. Swift publishes native state and supplies actual relevant viewing input.
- **State and client view:** preserve binding/message/intake-cursor transaction closure when selected; private records can share a transaction without becoming exported. Persisted facts, runtime provider correlation, status projection and client attention are separate. Current hook limits do not bound every mutation class, and a coalesced wake requires the keyed pending bank behind it.
- **Boundary to finish:** exact units, export/audience/history, restart and viewing policy, record/result schemas and transaction/effect receipts. Existing `admitted`, ignored, recorded-only and UI-published states cannot collapse into one success flag. DS07/DS02/DS10 retain their distinct decisions.

### Terminal

- **Current acquisition:** backend preparation returns a directory/handle; the later attach command can establish execution. Backend inventory uses `zmx list`. Current status/snapshot read the native runtime registry; Ghostty supplies classified metadata/activity/control callbacks. [Backend](../../../../../Sources/AgentStudio/Core/RuntimeEventSystem/Runtime/ZmxBackend.swift:182), [inventory](../../../../../Sources/AgentStudio/Core/RuntimeEventSystem/Runtime/ZmxBackend.swift:274), [runtime adapter](../../../../../Sources/AgentStudio/App/IPCComposition/AgentStudioIPCRuntimeAdapter.swift:30), [source classification](../../../../../Sources/AgentStudio/Features/Terminal/Ghostty/GhosttyActionDisposition.swift:33).
- **Proposed placement:** [Host execution creation and fact-source owners](../04-terminal-runtime/execution-lifecycle-design.md) establish execution independently of views, own backend attachment/control, and admit the selected renderer-independent observations. Gateway owns addressed delivery; Swift/Ghostty own rendering and native input. Terminal bytes keep an ordered binary lane instead of becoming materialized SQL rows.
- **State and client view:** execution registry, temporary connection, attachment, parser restoration and metadata/status are separate. The current `terminal.snapshot` is runtime metadata, not screen cells. A backend handle or runtime-ready state is not a shell/handshake witness; frame delivery is not child consumption.
- **Boundary to finish:** E1 restoration/live handoff and actual native relay, controller/resize/focus policy, qualification of the owned fact-source port, execution identity/re-adoption, input acknowledgements and bounded slow-viewer behavior. DS04 owns these; execution continuity does not by itself complete the autonomous-fact obligation.

## File, review and annotation products

### Bridge File/Review

- **Current acquisition:** production File metadata combines product source authority, status, Git read context and shared construction. Review constructs a Git source provider through the actual data client. Finite file content separately opens a validated contained regular file and checks the requested descriptor. [File wiring](../../../../../Sources/AgentStudio/Features/Bridge/Runtime/BridgePaneController+Bootstrap.swift:646), [review factory](../../../../../Sources/AgentStudio/Features/Bridge/Runtime/ReviewFoundation/BridgeReviewSourceProviderFactory.swift:56), [finite file opening](../../../../../Sources/AgentStudio/Features/Bridge/Transport/BridgePaneProductFileContentSource.swift:79).
- **Proposed placement:** Host owns remote-source acquisition, comparison/content meaning and source-sensitive product computation. Gateway prepares selected tree/review metadata and demand views and carries finite content. Native/BridgeWeb clients own installation/application/rendering at their actual surface.
- **State and client view:** manifests, comparison/source generations, publication/content leases, byte buffers and rendered state are different. A file tree is not file content; a copied descriptor is not proof that later live bytes remain identical. Large content does not become a large control/view DTO.
- **Boundary to finish:** exact product/source/pane bindings, content kinds/ranges/limits, currentness/release and receiver/worker application contracts. DS08/DS01/DS10 own them. Hash/length or transport success alone does not prove current rendered content.

### Annotations/output

- **Current acquisition:** annotation edits use source/revision/edit-ownership guards and SQL mutation; committed change then invalidates/publishes projections. Output captures exact saved membership/bytes and prepares SQL before invoking the destination effect, then finalizes. [Committed publication](../../../../../Sources/AgentStudio/Features/Bridge/Runtime/WorktreeAnnotations/WorktreeAnnotationServiceActor.swift:543), [prepare then effect](../../../../../Sources/AgentStudio/Features/Bridge/Runtime/WorktreeAnnotations/WorktreeAnnotationOutputCoordinatorActor.swift:295).
- **Proposed placement:** Host owns authoritative saved annotation/workflow state and source validity. Gateway prepares read/placement views from selected coherent data; the exact placement computation/cache split must preserve its source fence. A native clipboard/chooser/editor/file destination stays explicitly addressed to its actual effect machine/client.
- **State and client view:** saved revision, draft/edit custody, derived placement, prepared output and final effect receipt are distinct. Selected replica application cannot rerun a clipboard write or agent command. Known effect plus failed finalization remains partial/unknown rather than an invented rollback.
- **Boundary to finish:** edit/draft sharing, source capture coherence, exact output authority/custody and destination, retained recovery/history and data units. DS08/DS02/DS10 own those choices. The twenty-two-operation annotation inventory remains the operation coverage source; these representative paths do not replace it.

## Protocol, native surfaces and operation

### RPC framing/descriptors

- **Current acquisition:** socket bytes enter NDJSON framing and JSON-RPC shape/version/method checks; typed method registration normalizes/validates parameters, correlation and exposure before dispatch. [Frame decoder](../../../../../Sources/AgentStudioIPCTransport/NDJSONFrameDecoder.swift:75), [RPC decoder](../../../../../Sources/AgentStudioIPCTransport/JSONRPCCodec.swift:264), [typed admission](../../../../../Sources/AgentStudioAppIPC/AppIPCTypedMethodRegistration.swift:216).
- **Proposed placement:** thin client/Gateway/Host adapters share one schema authority and delegate domain work to its owner. Carrier, logical session, operation, subscription and terminal execution retain distinct lifetimes. Native clients need strongly typed socket contracts, without an obligatory embedded Rust/Swift FFI layer.
- **State and client view:** frame buffers and request correlation are transport/session state, not application truth or a transaction receipt. Typed views, operations/events and binary lanes declare their own semantics.
- **Boundary to finish:** complete chosen method/event/error/frame schemas, versions, fragmentation/limits, deadlines and cancellation. DS01 owns those choices and real Swift/socket compatibility; existing codec/size constants are baseline evidence, not new target defaults.

### RPC serving/authority

- **Current acquisition:** authentication resolves credential context and rechecks lifetime/invalidation after awaited lookup. Registered metadata and principal scope govern authorization. Broker subscriptions bind principal and connection; failed/backpressured delivery removes them. [Authentication](../../../../../Sources/AgentStudioAppIPC/AgentStudioIPCAuthentication.swift:265), [authorization](../../../../../Sources/AgentStudioAppIPC/AgentStudioIPCRegistryAuthorization.swift:374), [broker](../../../../../Sources/AgentStudioAppIPC/IPCEventBroker.swift:66).
- **Proposed placement:** Gateway validates frontend admission and addressed routing; Host validates permitted domain effects and Host-local input. Native effects retain their own target/authority boundary. Central remains the database-writer lease authority, not a per-keystroke operation router or Gateway-local lease issuer.
- **State and client view:** credentials, connection principals, grants, logical session positions, subscriptions and domain ownership are separate. Current subscriber `delivered` maps to writer enqueue acceptance, not peer processing. [Actual mapping](../../../../../Sources/AgentStudioAppIPC/AgentStudioAppIPCConnectionWriter.swift:149).
- **Boundary to finish:** enrollment/delegation/revocation, supported device/channel pairs, leased writes during central outage, subscription recovery and aggregate resource admission. DS03/DS01 own them; shared rows never bypass authorization.

### Workspace/layout/command queries

- **Current acquisition:** workspace queries combine live workspace snapshots with native window lifecycle; some current/snapshot queries require a current window. Command discovery uses the spec catalog and dispatch reaches actual execution owners. [Query adapter](../../../../../Sources/AgentStudio/App/IPCComposition/AgentStudioIPCQueryAdapter.swift:39), [command adapter](../../../../../Sources/AgentStudio/App/IPCComposition/AgentStudioIPCCommandAdapter.swift:60).
- **Proposed placement:** Swift retains actual window/pane/focus/renderer truth. Gateway prepares selected client-scoped reads from supplied native/shared Host facts, without manufacturing a current window from a Host database. Host commands call the Host; selected client-native commands use [Gateway→addressed native owner dispatch](../01-service-contracts/communication-design.md#client-native-operations-reach-their-actual-owner), with actual native admission/result and no inferred default client.
- **State and client view:** portable arrangement intent, current native residency/focus and repository/session association are separate. Their persistence/mobility scope is not chosen by their current shared snapshot type. One command identity/display catalog remains the consumer contract.
- **Boundary to finish:** shared arrangement/focus policy, command-by-command supported exposure and actual result/effect shape. DS10/DS02 own those choices. Current unavailable/debug-only/dormant branches remain explicitly classified rather than counted as working features.

### Native OS ingress/effects

- **Current acquisition:** AppKit/window callbacks and system clock/timezone notifications produce native facts; clipboard/editor/Finder/chooser effects use actual OS objects. Source reads and backend scanning remain separate from those native actions. [Native monitor](../../../../../Sources/AgentStudio/App/Lifecycle/ApplicationLifecycleMonitor.swift:63), [background time inputs](../../../../../Sources/AgentStudio/App/Lifecycle/ApplicationLifecycleMonitor.swift:174).
- **Proposed placement:** native client adapters supply selected relevant semantic inputs and execute declared native effects. Gateway may use client context to prepare views; Host acquisition does not require a native window or a Mac clipboard. Native events are not all forwarded as raw Host bus traffic.
- **State and client view:** OS readiness/focus/visibility and prepared semantic data have different owners. Receiving content is not viewing it; initiating an external app is not proof of document load. A remote filesystem path is not a local native URL.
- **Boundary to finish:** effect locality, consent/refusal, remote path representation, supported device UX and currentness. DS10/DS03 retain these. Host parity does not require Linux Finder or Mac-native presentation effects on the Host.

### CLI package install/uninstall

- **Current acquisition:** installers read explicit/environment/default provider roots, shipped resources and existing provider configuration. They run locally before normal IPC setup; Codex prevalidates and then performs sequential per-file writes. [Installer](../../../../../Sources/AgentStudioIPCClientCore/AgentPackage/CodexPackageInstaller.swift:60).
- **Proposed placement:** selected install work executes at its declared machine/provider root under the attached-machine rule. CLI remains a requester/formatter; Host owns selected remote installation effects. Local resource/bootstrap and native consent branches require their own explicit disposition rather than an automatic service-absent fallback.
- **State and client view:** provider files and installation evidence differ from provider trust, live process identity or authentication. Gateway may expose installation status for the addressed machine, without copying private credentials into a client view.
- **Boundary to finish:** packaging/resource/version pairing, supported platforms, unavailable-service policy, preflight refusal versus partial writes and uninstall ownership. DS09/DS11/DS03 own these; per-file atomic writes do not imply aggregate rollback.

### Observability/configuration

- **Current acquisition:** startup reads channel/root/environment/bundle/file configuration; trace producers combine events with service context and dispatch to selected sinks. Configuration input exists before any RPC. [Preference bootstrap](../../../../../Sources/AgentStudio/App/Boot/GlobalPreferencesBootstrap.swift:7), [trace record](../../../../../Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioTraceRuntime.swift:170).
- **Proposed placement:** each process owns its declared machine/channel configuration and telemetry production. Gateway exposes only selected operational views; shared configuration and native preferences need classified homes. The services consume the existing observability system instead of owning a new collector stack.
- **State and client view:** configuration status, private credential material, operational diagnostics and source-scrubbed telemetry differ. Collector absence is not loss of Host domain authority; a producer call is not exporter/collector receipt. Telemetry is not the replication data plane.
- **Boundary to finish:** supported roots/channel identities, selected portable settings, export policy, artifact/service lifetime and fail-open/shutdown outcomes. DS11/DS02/DS03 own these. No raw data/credential export is authorized by distributed execution.

### Bridge development HTTP host

- **Current acquisition:** a debug-only executable prepares real Core/Bridge owners, product source and filesystem/Git observation; a service group owns HTTP and parent-input/signal lifetime. Its address is loopback. [Main composition](../../../../../Sources/AgentStudioBridgeDevelopmentServer/AgentStudioBridgeDevelopmentServerMain.swift:8), [loopback configuration](../../../../../Sources/AgentStudioBridgeDevelopmentServer/BridgeDevelopmentServerConfiguration.swift:16).
- **Proposed placement:** retain this as evidence and an eligible qualification surface. Reusable construction/finite-content behavior can inform Host extraction; its development HTTP server is not selected as a production service or frontend bypass.
- **State and client view:** seeded Core/local SQL, product runtime, actual file bytes and substituted development output effects have their own boundaries. It demonstrates separable composition in source, not shipped native behavior.
- **Boundary to finish:** which real owners/ports are reusable and which proof remains substituted; shipping identities, network trust, full native rendering and Linux realization remain independent. DS08/DS11 own that disposition; no extra daemon is created by this row.

## What a complete per-operation specification still needs

For each operation or background transition within these families, its owning design must bind the actual input and source, kind-qualified machine/resource, authority, acquisition/refresh policy, domain transform, state/transaction/effect, copy disposition (including explicitly not copied), derived view, native consumer, failure/recovery and observation seam. The typed boundary needs a real closed shape and schema home; a prose role assignment is not that shape. Existing [entity bindings and interface gaps](program-design-workbench.md#bind-the-specifications-entities-before-naming-packages) remain part of the integrated workbench.

The current [full operation/effect catalogs](../../research/extraction-survey.md#ipc-and-cli-inventory) retain the fifty-seven RPC names, forty-four Git APIs, sixteen Bridge calls, twenty-two annotation operations and separate command identities. These are overlapping layers, not additive feature counts. Internal helpers map to a capability owner; they do not all become remote methods.

Prepared state never replaces a write/acknowledgement or native effect. The [initial profile](../../initial-profile.md) fixes the sharing, control, offline, invalid-writer and safety directions. [Shared-state realization](../10-swift-client/shared-client-state-design.md) proposes the Host authority and Client/native split. Exact data units, marker scope, retention/currentness, handoff, schemas and gate/partial outcomes remain with their owning contracts; the [transaction](../02-data-ownership-replication/research/transaction-boundaries.md), [copy-read](../02-data-ownership-replication/research/replica-read-contract.md) and [delivery](../02-data-ownership-replication/research/durable-delivery-fit.md) evidence still constrains them. No open field is an implementer default.
