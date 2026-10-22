# Host parity, bus, client and transport evidence

Current source baseline: AgentStudio `624300332`, Git `4cca397d`. This is the Lead's reduced evidence from four Sol xhigh lanes plus the latest-ZMX xhigh comparison and the prior bounded source lanes. No implementation, test execution, benchmark, native launch or vendor update. The frozen second-opinion packet is `docs/wip/2026-10-15-daemon-topology-risks.md`; this file is supplementary evidence, not a parallel Specification.

## Scope now fixed

Host feature parity applies to macOS and Linux, including Mac-local work. Gateway is Rust on macOS only. Swift remains a native client. The earlier Mac-local question is closed by the explicit owner clarification. Mobile/UniFFI/relay and canonical transcript proposals in the supplied memo have not become current delivery requirements. The owner permits evaluating newer ZMX.

## Current bus and actor map

| Layer | Current owner / contract | Important non-equivalence |
| --- | --- | --- |
| Raw terminal admission | Exhaustive Ghostty disposition before semantic publication | Mouse/search/local presentation and activity samples do not become arbitrary bus facts |
| Direct command | RuntimeRegistry resolves one runtime; dispatcher validates and awaits result | Not broadcast, not an AppEvent command loop |
| Pane channel | Local subscribers/sequence/replay plus `bufferingNewest(128)` outbound worker | 128 is outbound-only; an unbounded downstream subscriber cannot recover a drop before it |
| Local replay | Count/estimated-byte/TTL bounds and explicit gap result | Two defaulted constructors exist; effective no-argument selection was not executed/established |
| Shared runtime facts | `EventBus<RuntimeEnvelope>`, source/topic interest and per-subscriber policy; replay256/source | Enqueue/consumed accounting is not applied effect or durable receipt |
| Git/Forge consumers | Lossy-newest subscriptions plus source identity/currentness, demand and deadlines | A shared critical consumer does not make every producer/consumer lossless |
| Cache/topology consumers | Critical subscriptions; replaceable projection coalescing flushed before non-coalescable events | Native registration is not canonical topology mutation |
| Topology effects | Direct ordered removal/adoption/fs synchronization | No extra unordered bus hop |
| Presentation reducer | Immediate/visibility-tier critical work plus latest `(source,key)` contraction on a frame cadence | Separate from source contraction, transport queues and canonical state |
| App notifications | Native terminal termination/handled acknowledgement and bell | Not portable business-command dispatch |

Primary anchors: [channel](../../../../../../Sources/AgentStudio/Core/RuntimeEventSystem/Runtime/PaneRuntimeEventChannel.swift:25), [replay](../../../../../../Sources/AgentStudio/Core/RuntimeEventSystem/Replay/EventReplayBuffer.swift:50), [shared replay](../../../../../../Sources/AgentStudio/Core/RuntimeEventSystem/Events/EventChannels.swift:7), [bus post](../../../../../../Sources/AgentStudio/Core/RuntimeEventSystem/Events/EventBus.swift:334), [reducer](../../../../../../Sources/AgentStudio/Core/RuntimeEventSystem/Reduction/NotificationReducer.swift:51), [Git subscription](../../../../../../Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryProjector.swift:202), [Forge subscription](../../../../../../Sources/AgentStudio/Core/RuntimeEventSystem/Forge/ForgeActor.swift:81), [topology effect](../../../../../../Sources/AgentStudio/App/Coordination/TopologyEffectHandler.swift:3).

Tokio channel facts were verified against Router-resolved Tokio1.52.3/tokio-util0.7.18. `broadcast` can overwrite slow-receiver history and report lag; `watch` is latest state and plain `send` does not retain a replacement without receivers; bounded `mpsc` bounds messages, not all upstream tasks or bytes; `oneshot` send does not confirm consumption. CancellationToken notification is not task exit. TaskTracker waits for closed-and-empty tracked-task completion, but closing it does not prohibit new admission. None supplies durable reconnect semantics.

Router demonstrates simpler request/response seams: [direct capability trait](/Users/shravansunder/code/projects/codex-router/crates/collaboration-client/src/collaboration_access.rs:22), [mailbox/oneshot owner](/Users/shravansunder/code/projects/codex-router/crates/collaboration-service/src/subscription_delivery/subscription_service.rs:225). Do not copy every implementation detail: [BoardStorageError](/Users/shravansunder/code/projects/codex-router/crates/message-board-storage/src/board_connection.rs:9) exposes sqlx::Error, conflicting with the requested shared boundary-error rule.

## Swift client boundary

Native synchronous inputs include IME/preedit/committed text, key release/repeat/modifier handling, reserved-shortcut consumption tied to source pane, first responder, window/backing scale and geometry. Native mounting and WebKit installation have lifetime/authority independently of logical pane identity. Clipboard/Finder/chooser/editor effects are client- and machine-local.

Domain resolution/validation, coherent graph construction, launch-directory selection, persistence ordering, expensive projections, scheduling and activity classification are not justified on MainActor merely because current owners run there. Equally, a thin client cannot remove all MainActor work or all local UI state.

The terminal-create path persists the proposal, then seeds the native slot and publishes graph, then requests surface construction. A real SQLite rejection test asserts no graph publication and no surface start (the surface is a fake). Background drawer insertion preserves newer still-valid client cursors; interactive insertion intentionally selects its committed child. This is not unconditional newest-wins.

Sources: [input/IME](../../../../../../Sources/AgentStudio/Features/Terminal/Ghostty/GhosttySurfaceView+Input.swift:45), [native geometry](../../../../../../Sources/AgentStudio/Features/Terminal/Ghostty/GhosttySurfaceView.swift:795), [durable create](../../../../../../Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceSQLiteSaveCoordinator.swift:221), [slot-before-graph publication](../../../../../../Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceStore.swift:266), [cursor policy](../../../../../../Sources/AgentStudio/Core/State/MainActor/Atoms/TabLayoutRules/TabArrangementCursorPreservation.swift:7), [durability test](../../../../../../Tests/AgentStudioTests/App/WorkspaceTerminalCreationDurabilityTests.swift:201).

Existing activity evidence also distinguishes rendered viewport last-output from raw process bytes. Receipt ACK, accepted native application and post-render fulfillment are different seams: [viewport-derived evidence](../../../../../../Sources/AgentStudio/Features/Terminal/Routing/TerminalActivityProjector.swift:56), [Bridge receipt](../../../../../../BridgeWeb/src/core/comm-worker/bridge-product-view-receipt-acknowledger.ts:15), [render fulfillment](../../../../../../BridgeWeb/src/core/comm-worker/bridge-main-render-fulfillment-coordinator.ts:453).

## State/currentness constraints

- Canonical topology and graph, operational Sessions/messages/annotation/output history, nonrebuildable UI memory and rebuildable cache have different meaning.
- Core and local database saves are sequential; core success can survive later local failure.
- Datastore persistence tails span actor reentrancy and reject stale captures; a mutex or actor name alone is not the whole serialization contract.
- Sessions binding checks and pane writer epoch/counter admission happen inside the write transaction; status projection is not authority for a new write.
- Offline notice effect and handled cursor share a commit; replacing CLIStore changes its cursor namespace.
- Annotation content, edit tokens, prepared output, native effect and durable finalization have distinct revisions/outcomes. A prepared attempt may restore as unknown.
- Paths/hashes, native monotonic timestamps, boot uptime, launch epochs and observation revisions are not interchangeable global identities/orders.

Sources: [partial commit](../../../../../../Sources/AgentStudio/Core/State/SQLite/WorkspaceSQLiteDatastoreActor.swift:184), [persistence tail](../../../../../../Sources/AgentStudio/Core/State/SQLite/WorkspaceSQLiteDatastoreActor+PersistenceOrder.swift:28), [transactional authority](../../../../../../Sources/AgentStudio/Core/PaneContext/PaneContextService+OrderedWrites.swift:24), [notice cursor](../../../../../../Sources/AgentStudio/App/PaneAgents/CLIOutboxCursorCommitParticipant.swift:6), [prepared output/finalization](../../../../../../Sources/AgentStudio/Features/Bridge/Runtime/WorktreeAnnotations/WorktreeAnnotationOutputCoordinatorActor.swift:334), [stable key](../../../../../../Sources/AgentStudio/Core/Models/StableKey.swift:4).

## Git feature coverage and platform deltas

The usage inventory is 33local+10remote+1discovery protocol operations. Production app/CLI consumers were found for28local+7remote+1discovery. Eight SDK-only operations are `pruneStaleWorktree`, `lockWorktree`, `unlockWorktree`, `isPathIgnored`, `ignoredPaths`, `clone`, `push`, `remoteReferences`; no caller in the inspected production Sources is a bounded source finding, not an instruction to remove/expose them.

| Feature group | Scope that parity must account for |
| --- | --- |
| Identity/discovery | Canonical repo/common/worktree identity, main/linked/bare/invalid registration and authoritative negative versus transient failure |
| Status | Full/scoped reads, observation/clean authority, tracked/ignored/untracked/submodule distinctions, exact detail cost and failure |
| Refs/relations | Default/start/upstream and branch-use meaning; same/ahead/behind/diverged; ref locks, expected-tip CAS and metadata cleanup |
| Review/content | OID/tree/mode/binary/hash/size/rename/content contracts, target capture bounds, contribution versus direct comparison, proportional/fallback behavior |
| Create/fork | Native/CLI policy distinctions, default CoW versus plain checkout, ignored inclusion/config, branch and network preflight, publication holds |
| LFS | Local object-store fill and missing/incomplete/residue reporting; no implied remote download API |
| Remote | Host-environment systemGit/SSH/helpers/trust, noninteractive failure, guarded staged-fetch promotion and cleanup debt |
| Remove/prune | Dirty versus unknown, main/current/locked safeguards, integration grades, preview fetch effects, tmp evidence/archive, partial removal and retained branch |
| Native/platform | Descriptor containment, metadata/link/special-node/name domain, CoW eligibility, source races, index/admin relocation, cancellation custody and typed residue |

Public review refresh carries a local-only, non-Codable `GitReviewRefreshSeed`. It cannot simply cross RPC, and losing proportional refresh is not free parity. Removal/prune have no established live app-pane closure integration despite dormant request fields. Preview/list may fetch; fully read-only intent needs its explicit existing controls. Archive verifies file bytes/link targets, not fork-level metadata fidelity.

Linux parity extends beyond fork: native-engine packaging, process/env/auth lifecycle, observation continuity, filesystem and exact-file identity, sleep-inclusive boot clock, peer/process identity, descriptor content admission and API-specific unknown/absent/error distinctions all need counterparts. Safe FICLONE alone supplies none of these guarantees.

Sources: [Git clients](/Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitContracts/AgentStudioGitSDK.swift:3), [opaque seed](/Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitContracts/GitReviewComparisonContracts.swift:57), [LFS](/Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitContracts/GitLargeFileFillContracts.swift:13), [native create](../../../../../../Sources/AgentStudio/App/Coordination/WorktreeCreationCoordinator.swift:81), [CLI policy](../../../../../../Sources/AgentStudioWorktreeOperations/WorktreeCreationBranchResolver.swift:108), [remote process](/Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitRemote/PosixGitProcess.swift:21), [branch CAS](/Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitLocal/Branches/LibGit2LocalBranchDeletionWriter.swift:107).

## ZMX version-sensitive findings

Latest releasev0.8.1 is exactly the vendored8bab commit. Main2d23 is ten commits newer and adds Capture22, terminal-reply classification fixes, no-leader switch no-op and a config symlink-loop fix. Build/dependency/target declarations are unchanged; both builds may report0.8.1. Capture is selected formatted screen/scrollback rows, not raw transcript, parser continuation or a stream-cut marker. Old daemons ignore its new tag; latest CLI uses a Capture/Info barrier to refuse unsupported old sessions.

The header is8rawpacked bytes with meaningful little-endian length at byteoffset1 on supported targets. Rust C-layout memory casting would be the wrong contract. Init restore, History and Capture serializers differ. PTY output can precede Init; split parser state and resnapshot/live continuity need real proof. Input has no per-occurrence Ack and can drop at the backend cap. Output perclient buffers grow. Process EOF/Kill request does not establish reaping/extinction. None of these risks is closed merely by choosing main.

Native rendered Ghostty vendor and ZMX's parser dependency are different pins. Current rendered-surface public API sends input and owns command/termio; no remote-output injection entry was found in the examined C API. A direct Host ZMX socket need not add a Host PTY, but the Mac render attachment remains an explicit design/proof seam.

Sources: [comparison](https://github.com/neurosnap/zmx/compare/8bab1f0173b07e79835ea372d749af3dbf0d0842...2d23c0d440583736f365a55aa09cb2c82b0fe7fa), [latest Capture](https://github.com/neurosnap/zmx/blob/2d23c0d440583736f365a55aa09cb2c82b0fe7fa/src/loop.zig#L1151-L1165), [old-daemon barrier](https://github.com/neurosnap/zmx/blob/2d23c0d440583736f365a55aa09cb2c82b0fe7fa/src/main.zig#L1477-L1522), [current rendered API](../../../../../../vendor/ghostty/include/ghostty.h:1180), [Swift byte decoder](../../../../../../Sources/AgentStudio/Core/RuntimeEventSystem/Runtime/ZmxSessionControl.swift:175).

## Measurement questions and existing material

| Question | Needed observation / control |
| --- | --- |
| Added local process hop | Persistent-client UDS distribution versus direct equivalent call, separately from new connection/auth and fresh CLI startup |
| Queue versus semantic latency | Correlated per-owner ingress/queue/execute/effect/reply stages, using local monotonic durations; no cross-clock wall-time subtraction |
| Interactive versus bulk contention | Key-to-correct-visible-echo and control-to-effect while diff/file/terminal bulk competes; blocked writes, queue age/bytes and render stages |
| Memory isolation | Total retained allocations across producers, transport windows, caches, snapshots and slow-viewer queues, including cancellation reclamation |
| Reconnection | Migration, new connection and process restart tested separately through current revision and correct visible state; no hidden input replay |
| Compression | Identical representative payload/queue policy off/on; wire bytes, CPU, first-visible/last-byte time, allocations and interactive tails |

Existing method families in `scripts/cli-latency-workloads.json`, generated Bridge content pressure and disposable Git-pressure fixtures can provide controlled source material. They do not currently prove the two-hop route. Existing CLI timing is fork-to-waitpid; Bridge perproducer64frames/4MiB is not a global endpoint budget. Quinn streams share connection windows/congestion; priority is not preemption or a latency reservation. No stable/good p95/p99 target or throughput number has been demonstrated here.

Sources: [CLI timing](../../../../../../scripts/benchmark-cli-latency.pl:63), [method workload manifest](../../../../../../scripts/cli-latency-workloads.json:4), [Bridge workloads](../../../../../../BridgeWeb/src/review-viewer/test-support/bridge-viewer-benchmark-workloads.ts:76), [Git pressure fixture](../../../../../../scripts/verify-git-refresh-performance-workload.sh:64), [performance boundary](../../../../../../Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder.swift:628), [Quinn priority](https://github.com/quinn-rs/quinn/blob/eaec0db4bcb698f76df736d89938743c88a2ad5f/quinn/src/send_stream.rs#L213-L220).

## Source routes, nulls and proof limits

Current local docs/code and decisive test bodies → adjacent Router source → DeepWiki pointers for OSS → exact pinned primary files/RFCs/API refs. Primary source corrected multiple DeepWiki statements (Header storage, Init order, watch send-without-receivers, default fields). `web.run` was unavailable with tool-level404; read-only primary HTTP worked. Missing local OSS homes were not cloned or populated. No saved research, private logs/DBs, credentials, runtime/UI observation or empirical performance class was used.

Useful bounded nulls: no Capture at vendorpin; no generic socketRTT or two-hop trace in inspected IPC sources; no compression implementation found in searched IPC/Bridge carrier paths; no crosslanguage generator found in inspected contract/scripts/comm-worker paths; no Linux inotify/fanotify/peer/boot-clock implementation found under current Swift Sources. None is a repository-wide or future impossibility claim.

Return is evidence for Lead reduction and Claude's requested second opinion. The full capability-placement, schema, lifecycle, recovery and performance obligations remain to be authored/confirmed; source-only test descriptions are not passing runs or platform parity proof.
