# AgentStudio Host/Gateway topology: reduced risks and open decisions

The Host daemon must have feature parity on macOS and Linux. Under S28 the Rust Gateway runs on macOS and iOS, between each UX client and its addressed Hosts. Frontend requests use that Gateway route; authorized Host-local session input and machine-scoped worktree CLI are separate under R9/R12/IP3. Swift remains a native client for display, user interaction and terminal control. These are owner constraints; bus wiring, socket/network transport, serialization, data ownership and local deployment still need qualification.

**20 October backend update:** [observed terminal behavior](../designs/04-terminal-runtime/research/backend-observations-2026-10-20.md) supersedes the earlier unexecuted Capture analysis where stated. Same-connection FIFO ordering was observed, while the tested reconstruction failed; ZMX leadership is not controller authority. The original source pins below remain historical baselines, not current adoption decisions.

This catalog reduces the source survey into ten design cruxes and a small set of blind-spot probes. It does not certify exhaustive coverage, select a final architecture, or claim runtime/performance results. Atom classes, current buffering sizes and existing implementation accidents are not automatically future requirements.

## Evidence boundary

- AgentStudio: `624300332f5e50f7bb8cbb9fc786d5e5b4a3d462`.
- AgentStudio Git: `4cca397dfc869857064da4e9ec8289ea46adc479`.
- Current vendored ZMX: `8bab1f0173b07e79835ea372d749af3dbf0d0842`, also the commit behind latest release `v0.8.1` as checked on 2026-10-15.
- Earlier ZMX main candidate: `2d23c0d440583736f365a55aa09cb2c82b0fe7fa`; ten commits beyond the release as checked on 2026-10-15. The newer experiment pin is `0a18bee7d3555b7822d1cb79cca2304d6ef2711b`, built only in scratch on 20 October. Both display 0.8.1; neither the version string nor these experiments authorizes updating existing running sessions.
- Current rendered Ghostty vendor: `2fb0c9cacb3fc75dbc8aedee9b7ed4321f091d33`. ZMX separately pins its own Ghostty VT dependency; they are not assumed identical.
- Codex Router example: `691cd560347d6e570dd3db0315b9ddb3ee259f84`; its lockfile resolves Tokio `1.52.3`, tokio-util `0.7.18`, Quinn `0.11.11`. Quinn `0.11.12` and Tokio `1.53.3` were also inspected as separately labeled research sources, not dependency choices.

The original survey read source and existing test bodies without execution. Later bounded backend runs are recorded in the linked 20 October evidence. No product vendor update, complete service integration or platform-parity proof follows.

## K01 — State ownership is the first topology decision

Repository inventory, process/session custody, workspace membership, local UI continuation, operational history and rebuildable enrichment are different truths. Moving every current atom into one Host would conflate them; leaving independent Swift/Rust domain writers would split authority.

UI pane, durable execution session, terminal attachment and current controller are also different identities/lifetimes. Current single-app relationships do not automatically define multi-client targeting or revocation.

The later supplied lifetime research reinforces this separation, but its “until explicitly terminated” wording is not a proven process-lifetime guarantee. Natural exit, process loss and reboot remain different from transport loss. Today's final pane/Undo retirement can end the process, while ZMX attach can recreate an absent session under the same name; neither should be hidden in reconnect. The owner has now selected separate detach/terminate primitives and closing a pane as detachment. Optional detached-session cleanup is a later UX/policy choice; no fifteen-minute default is adopted.

Current core and local commits are not atomic together; a save with an Undo change returns after core without entering the local-write branch. Pane title/line writes validate the current Sessions binding inside the write transaction; affected-source publication follows the write and is not a durable effect log. CLI notice effect and handled cursor commit together. These are real consistency boundaries, not incidental actor placement. Sources: [datastore commit/early return](../../../../Sources/AgentStudio/Core/State/SQLite/WorkspaceSQLiteDatastoreActor.swift:184), [ordered write](../../../../Sources/AgentStudio/Core/PaneContext/PaneContextService+OrderedWrites.swift:24), [cursor participant](../../../../Sources/AgentStudio/App/PaneAgents/CLIOutboxCursorCommitParticipant.swift:6).

**Failure to prevent:** stale authority, duplicated history, accepted core changes reported as rolled back, or a reconstructed cache erasing operational user data.

**Decision/evidence needed:** define each truth's scope and observable commit boundary, including whether workspace layout is shared across clients or is client continuation. Only then assign one authoritative owner and define projection/reconciliation. SQLite WAL and actor isolation do not answer that question.

## K02 — There is no single current bus guarantee to port

Current coordination includes direct request/response commands, source admission, pane-local subscriptions/replay, a bounded outbound handoff, shared fact fanout, consumer coalescing, and native App notifications. The pane outbound queue is `bufferingNewest(128)` before any critical-unbounded shared subscriber. Shared replay is 256 records per source. The effective no-argument pane replay default is not established by this survey because two defaulted initializers exist; count/byte/TTL/gap mechanics are established.

Sources: [direct dispatch](../../../../Sources/AgentStudio/App/Coordination/WorkspaceSurfaceCoordinator+RuntimeDispatch.swift:15), [outbound channel](../../../../Sources/AgentStudio/Core/RuntimeEventSystem/Runtime/PaneRuntimeEventChannel.swift:25), [shared replay](../../../../Sources/AgentStudio/Core/RuntimeEventSystem/Events/EventChannels.swift:7), [local replay constructors](../../../../Sources/AgentStudio/Core/RuntimeEventSystem/Replay/EventReplayBuffer.swift:50), [consumer reducer](../../../../Sources/AgentStudio/Core/RuntimeEventSystem/Reduction/NotificationReducer.swift:51).

**Failure to prevent:** silently losing a required transition, treating a stream enqueue as a committed effect, or making unrelated traffic consume a shared replay ring and evict relevant facts.

**Decision/evidence needed:** classify each consumer obligation as exact ordered transition, replaceable complete state, request/result, native lifecycle, or raw terminal bytes. Pick primitives per class. A global `broadcast` or generic event envelope is not an ownership model.

The existing [Bridge sealed keyed batch](../../../../Sources/AgentStudio/Features/Bridge/Transport/BridgeProductSealedViewBatch.swift:8) is a stronger recovery precedent for replaceable state than copying current replay capacities: it freezes one capture with handle/incarnation, base/target revision, part ordering and covered scope. A future Gateway replica could use this kind of contract. Fact-hub wiring and replica recovery are separate design axes; either wiring candidate still needs a recovery policy. Current empty-buffer replay does not establish an end-to-end continuity guarantee.

Pinned Tokio evidence makes the distinction concrete: `broadcast` can report lag after overwriting history; `watch` keeps latest state, and `send` without receivers does not retain the replacement while `send_replace` does; bounded `mpsc` controls message admission rather than byte retention or completed effects; `oneshot` success is not consumption. Task cancellation and task completion are separate, and TaskTracker closure does not stop future admission. These are [documented primitive contracts](https://github.com/tokio-rs/tokio/blob/tokio-1.52.3/tokio/src/sync/watch.rs#L1046-L1071), not benchmark comparisons or a prescribed channel layout.

The later [E3 coordination procedure](../designs/10-swift-client/experiments/coordination.md) makes these obligations independently observable. It also records source-label/sequence-owner collisions, close-admission versus actual close, literal activity-line meaning, first-demand proof gaps and incomplete resource estimates. Current implementation debt is separated from future required behavior; the procedure has not run and neither wiring candidate is selected.

## K03 — Terminal restoration is a protocol crux, including on latest ZMX

At the newer `0a18bee` experiment pin, EX2a observes a clean FIFO Capture delimiter but counterexamples to complete reconstruction: 110/110 raw suffixes match, while 0/110 Capture and 0/55 Init final line states match the finite corpus oracle. This confirms the distinction between ordering and checkpoint completeness, without qualifying the native renderer. The paragraphs below describe the earlier C-pin source analysis; its Capture→Info compatibility check is not the M-pin detector. M has protocol version 1 and an Unsupported response. See the [current backend evidence](../designs/04-terminal-runtime/research/backend-observations-2026-10-20.md) before consuming the older analysis.

Vendored ZMX has an eight-byte raw header, no Capture tag, and different Init versus History serializers. Latest main adds Capture tag 22, which returns selected screen/scrollback formatting; its response does not itself contain a live-output cut, epoch or replay watermark. Neither byte reliability nor a screen snapshot alone establishes parser-state continuity while live output is arriving.

Current Init can follow queued live Output, uses ordinary Output for restoration, and resizes the inner VT before serialization and the PTY afterward. ZMX's VT stream retains parsing state, while restoration receives Terminal state. This raises split-escape/UTF-8/OSC and duplicate-scrollback questions; it is not an exercised bug claim. Sources: [pinned header/tags](../../../../vendor/zmx/src/ipc.zig:6), [pinned Init](../../../../vendor/zmx/src/loop.zig:950), [serializer](../../../../vendor/zmx/src/util.zig:769), [latest Capture](https://github.com/neurosnap/zmx/blob/2d23c0d440583736f365a55aa09cb2c82b0fe7fa/src/loop.zig#L1151).

The source permits a concrete overlap: accept adds the client before later broadcasts; bytes can be queued before Init and also represented in its restoration. No runtime duplication result has been observed here. Latest Capture is distinguishably framed and appended to that client's ordered buffer, which may help define a capture barrier, but its formatted rows are not a full parser/restoration checkpoint. A separately stamped byte offset is a candidate mechanism, not the only possible proof of an ordered cut. Extending ZMX or owning additional Host terminal state are different options; a third VT instance is not yet established as necessary.

The latest comparison also matters for compatibility: upstream sends Capture then Info to detect an old daemon that ignores the new tag; Info has no daemon hash/version capability field. Binary installation and local `zmx version` therefore do not establish what an already-running session supports. See [upstream capability barrier](https://github.com/neurosnap/zmx/blob/2d23c0d440583736f365a55aa09cb2c82b0fe7fa/src/main.zig#L1477-L1522). Capture limits preceding rows, not bytes, elapsed work or parser state. Latest main does not close these risks.

**Failure to prevent:** a plausible-looking restored screen followed by an invalid continuation, duplicated output, wrong modes or an apparently current terminal that cannot interpret the next bytes correctly.

**Decision/evidence needed:** prove fresh-renderer restore plus live continuation under controlled output and arbitrary sequence boundaries. Distinguish screen history, complete restoration, parser continuation and original byte transcript. Latest upstream is an eligible candidate, not proof that this boundary is closed. Here “latest/main” refers to the recorded evaluated pin, not a new upstream-status query. The [E1 procedure](../designs/04-terminal-runtime/experiments/terminal-restoration.md) separates owned VT, backend protocol, actual PTY, native and full-route proof. Its [oracle evidence](evidence/2026-10-15-daemon-extraction-survey/e1-oracle-observation-evidence.md) identifies standalone binary snapshot/continuation APIs already in the VT pins; these are neither ZMX's current Init/Capture format nor an embedded app-surface export, and the format has no stable binary-compatibility promise. No such mechanism or additional Host VT is selected.

## K04 — Direct ZMX access does not establish the Mac render entry point

The Host can be a direct ZMX socket client without introducing another Host-side PTY. ZMX already owns its shell PTY and a VT shadow. The current Mac rendered surface, however, launches a local command and owns native terminal I/O. `ghostty_surface_text` and key APIs send input; no remote-output injection entry was found in the examined rendered-surface C API. Ghostty's VT parser API is not a substitute for its full native renderer API.

Today's [zmx attach command](../../../../Sources/AgentStudio/Core/RuntimeEventSystem/Runtime/ZmxBackend.swift:202) already supplies a relay behind Ghostty's own PTY. Retaining that shape with a remote-aware relay is a credible candidate. The absent injection API does not make remote rendering impossible; relay protocol, credentials, resize ownership and added local process cost remain explicit contracts to evaluate.

Sources: [ZMX socket client](../../../../vendor/zmx/src/socket.zig:77), [native surface startup](../../../../Sources/AgentStudio/Features/Terminal/Ghostty/GhosttySurfaceView.swift:379), [rendered-surface API](../../../../vendor/ghostty/include/ghostty.h:1180), [terminal-I/O backend](../../../../vendor/ghostty/src/termio.zig:1).

**Failure to prevent:** feeding remote output into a user-input API, adding an accidental emulator/PTY layer, or designing a transport whose bytes have no supported native rendering path.

**Decision/evidence needed:** verify the real rendered-client attachment path before ranking sockets or FFI. A client-side bridge process and a native backend change have different lifecycle, security and maintenance costs; no choice is made here.

## K05 — Control ownership, input uncertainty and slow readers interact

Current ZMX permits multiple attachments but has one size leader. Input can transfer leadership; not every payload is equivalent. Input queues can drop new payloads after capacity is exhausted, without per-input acknowledgement. Client output buffers are growable; no per-client byte cap was found in the examined daemon paths. A Host continuously reading can help operationally, but is not by itself a bounded-memory or multi-viewer contract.

Init also claims vacant leadership and resizes both VT and PTY, so it is not a passive snapshot request. Non-user input from a nonleader can be ignored; output append failure skips that client's chunk. Slow-viewer recovery therefore depends on K03's valid restoration boundary. Fanout through one Host attachment versus multiple ZMX attachments changes leadership, state and recovery costs; neither is selected by “one QUIC connection.”

Focus is another child-visible consequence: ZMX [last/first Init-client transitions](../../../../vendor/zmx/src/loop.zig:248) can queue focus-out/in under DECSET1004. A retained Host attachment can suppress that transition while frontend views disappear, but separately forwarded input can still change focus. Human/native/multiple-client focus semantics therefore need an explicit controller contract. E2 records focus input and source-output differences rather than misclassifying changed workload output as fact loss; no focus policy is selected.

Sources: [input admission](../../../../vendor/zmx/src/loop.zig:866), [leadership](../../../../vendor/zmx/src/loop.zig:894), [output fanout](../../../../vendor/zmx/src/loop.zig:405), [output draining](../../../../vendor/zmx/src/loop.zig:506). Latest-source deltas are accounted for separately; unsupported snapshot/flow-control guarantees must not be inferred from unchanged tags.

**Failure to prevent:** a small viewer unexpectedly resizing another user's session, input replay after uncertain delivery, unbounded retained output, or silently dropped arbitrary VT bytes corrupting a viewer.

**Decision/evidence needed:** define controller/viewer/resize behavior and observable input/effect boundaries; account for bytes across all queues and snapshots; prove slow-viewer isolation and recovery. An optional canonical transcript is a separate storage/privacy requirement, not a queue-management shortcut.

## K06 — Thin Swift still needs native ownership and currentness

IME, keyboard interpretation, reserved-chord consumption, native focus, window/backing geometry, AppKit/WebKit installation and native effects remain client operations. Those facts do not justify leaving domain validation, storage, expensive derivation or scheduling on MainActor. A Rust result still needs scoped identity/revision checks before native publication.

Existing terminal creation persists before publication/surface launch. Background drawer creation preserves still-valid newer local cursor selections; interactive creation intentionally selects the new child. Generic whole-snapshot replacement or unconditional local-cursor preservation each loses behavior. Sources: [IME/key input](../../../../Sources/AgentStudio/Features/Terminal/Ghostty/GhosttySurfaceView+Input.swift:45), [durable creation](../../../../Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceSQLiteSaveCoordinator.swift:221), [cursor rule](../../../../Sources/AgentStudio/Core/State/MainActor/Atoms/TabLayoutRules/TabArrangementCursorPreservation.swift:7), [durability scenario](../../../../Tests/AgentStudioTests/App/WorkspaceTerminalCreationDurabilityTests.swift:201).

**Failure to prevent:** stale UI results undoing human interaction, native focus reported successful when it failed, obsolete renderer resurrection or excessive MainActor work hidden behind client adapters.

**Decision/evidence needed:** separate domain intent, client continuation and native application receipts. Preserve keyed observation and semantic equality where useful, while reevaluating atom classes and projection placement pragmatically. Required native work stays on MainActor; the goal is not literal zero MainActor execution.

## K07 — Transport, effect and render receipts are different

Current RPC has post-submit uncertainty; Bridge separately distinguishes request admission, operation settlement, delivery receipt credits and post-render fulfillment. QUIC orders bytes within one stream, not between independent streams. Request IDs do not make effects idempotent. Channel send, transport ACK, domain commit, client application, render fulfillment and process extinction must not share one success state.

Sources: [uncertain typed result](../../../../Sources/AgentStudioIPCClientCore/AgentStudioIPCClientCore.swift:247), [Bridge receipt ACK](../../../../BridgeWeb/src/core/comm-worker/bridge-product-view-receipt-acknowledger.ts:15), [post-render observation](../../../../BridgeWeb/src/core/comm-worker/bridge-main-render-fulfillment-coordinator.ts:453), [QUIC stream ordering](https://www.rfc-editor.org/rfc/rfc9000.html#section-2).

The [E2 desk classification](evidence/2026-10-15-daemon-extraction-survey/e2-effect-boundaries.md) now makes these differences concrete across the app, Git and Bridge catalogs: generic Bridge success can contain a failed/partial typed payload; annotation refresh can commit before returning stale; Git promotion can be indeterminate and cleanup can fail after committed pages. Experiment counters must observe those effect boundaries independently of wrapper replies. This is source evidence, not executed proof.

**Failure to prevent:** retrying an already-executed mutation, acknowledging an ask answer before caller receipt, a resize/control overtaking the terminal attachment it belongs to, or claiming the UI displayed a result because bytes arrived.

**Decision/evidence needed:** define effect/result states and ordering scope at each boundary, including cancellation after admission and disconnect after commit. Choose wire/schema/version admission as an explicit contract. Current app IPC NDJSON and Bridge length-prefixed metadata/binary content are different existing carriers, not one compatible protocol.

## K08 — Git parity extends beyond fork and serializable DTOs

The Git contracts have 44 required operations; the usage survey found production app/CLI callers for 36 and eight SDK-only operations. Native and CLI creation have different materialization/config/network/publication policy. Local LFS fill, staged remote promotion, ref locks/CAS, integration grades, evidence archives, partial removal and process/auth environment matter alongside status/diff/content.

Review proportional-refresh seeds are deliberately local-only and non-Codable. Moving calculation across RPC cannot simply serialize them or silently switch to complete recomputation. Linux fork has full containment, metadata, filename, Git-administration/index, cancellation and residue obligations; FICLONE covers only file-data sharing. Sources: [client protocols](../../../../../agentstudio-git/Sources/AgentStudioGitContracts/AgentStudioGitSDK.swift:3), [opaque seed](../../../../../agentstudio-git/Sources/AgentStudioGitContracts/GitReviewComparisonContracts.swift:57), [large-file receipt](../../../../../agentstudio-git/Sources/AgentStudioGitContracts/GitLargeFileFillContracts.swift:13), [fork eligibility](../../../../../agentstudio-git/Sources/AgentStudioGitLocal/WorktreeFork/WorktreeForkEligibility.swift:23).

Qualification: the existing calculation disposition already reports `proportionalFallback`. A serializable handle could refer to Host-owned seed material without serializing the seed itself. The design question is custody, scope, resource bounds and invalidation across clients/restart, preserving the existing observable fallback rather than treating non-Codable as a remote-use impossibility.

**Failure to prevent:** claiming parity from matching method names while losing currentness, proportional refresh, branch protection, dirty/unknown distinctions, network effects in previews, authentication or partial-effect receipts.

**Decision/evidence needed:** preserve a per-feature contract/test matrix on both Host platforms; decide exposed capabilities separately from SDK inventory; evaluate safe backend/API coverage without assuming native-library distribution or pure-Rust behavior parity. No first-party unsafe or fallback waiver has been made.

## K09 — Platform identity, authority and lifecycle cannot be forwarded as local paths/clocks

Current filesystem coverage, volume/file identity, process incarnation and sleep-inclusive boot time are Darwin-specific. Peer UID is local evidence. Pane bearers and CLIStore/socket/executable paths belong to a machine environment. Monotonic timestamps and launch/source epochs do not form a global cross-Host order. Close/Undo/final revocation, binding replacement, output attempts and cancellation have explicit current boundaries.

U14 exposes another boundary: today's pane close invalidates live principals and final Undo retirement revokes pane authority. Preserving only the shell while copying those rules would leave a detached agent unable to send hooks/messages. Session execution lifetime, permission subject, revocation and attachment lifetime require separate contracts; no broader authority or permanent token is inferred.

That outcome is now confirmed as U15: sessions, authorized agent inputs and terminal facts/activity continue without Swift or a connected Gateway. The design must therefore support Host-side creation/admission/fact collection independently of native panes and renderer availability. No particular credential scheme, new VT instance, replay duration or process-restart guarantee is implied.

The unexecuted [E2 procedure](../designs/07-agents-context/experiments/host-autonomy.md) separates renderer, Swift-process and Gateway absence and observes semantic facts independently of caller receipts. It retains bounded metadata/host-provenance, real admission fences and owner-close gaps rather than using native samples or ZMX Info as universal fact evidence.

U17’s frontend route and S14/S16/S30 distinguish frontend access from Host-local session work and machine-scoped worktree CLI. Phones use their own iOS Gateway under S28, with no required Mac relay. Worktree CLI uses its attached local Host and activates it when absent under IP3; the newly relayed Mac-side remote `--host` use case needs its exact authority/relay contract rather than being silently treated as a UX frontend. Both multiple Gateways per Host and multiple Hosts per Gateway are selected; identity, per-Host availability and authority remain distinct.

Sources: [boot clock](../../../../Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceUndoJournalClock.swift:4), [pane authority environment](../../../../Sources/AgentStudio/App/PaneAgents/PaneIPCIdentityOwner.swift:68), [file semantics](../../../../Sources/AgentStudio/Infrastructure/Filesystem/FilesystemPathCanonicalizer.swift:129), [process control](../../../../Sources/AgentStudio/Core/RuntimeEventSystem/Runtime/ZmxSessionControl.swift:82), [scope recheck](../../../../Tests/AgentStudioTests/App/IPC/AgentStudioIPCOwnPaneEffectRecheckTests.swift:21).

**Failure to prevent:** equal paths on different machines selecting the wrong resource, a permission failure treated as absence, stale credentials surviving an intended revocation boundary, history loss treated as cache rebuild or Gateway loss releasing a live Host session accidentally.

**Decision/evidence needed:** machine/instance/source identities, per-platform evidence contracts, allowed credential custody, client/Host lifetime promises and truthful incompatible-version outcomes. Supporting macOS and Linux is not a guarantee about every filesystem/kernel/container topology. Existing running ZMX daemons also form an upgrade boundary; evaluating latest does not authorize replacing them.

## K10 — Performance and resource bounds must measure the selected path

The current CLI benchmark includes fork/loader/auth/call/exit; it is not socket RTT. Existing probes split some compact MainActor apply, projector round trip, queue/debt/drop and Bridge receipt/render stages, but do not establish Gateway/Host attribution or terminal key-to-visible-echo. Per-producer limits are not whole-endpoint limits. Quinn priority and multiple streams are not latency reservations or independent congestion resources.

Sources: [CLI timing boundary](../../../../scripts/benchmark-cli-latency.pl:63), [terminal probes](../../../../Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder.swift:628), [producer accounting](../../../../Sources/AgentStudio/Features/Bridge/Transport/BridgeProductProducerRegistry.swift:194), [Quinn windows](https://github.com/quinn-rs/quinn/blob/eaec0db4bcb698f76df736d89938743c88a2ad5f/quinn-proto/src/config/transport.rs#L106-L157), [Quinn priority](https://github.com/quinn-rs/quinn/blob/eaec0db4bcb698f76df736d89938743c88a2ad5f/quinn/src/send_stream.rs#L213-L220).

**Failure to prevent:** optimizing a small serialization cost while UI scheduling, queueing, native rendering or network RTT dominates; claiming bounded memory from item counts; disabling correctness to hit a headline latency.

**Decision/evidence needed:** compare complete equivalent workloads and observable results, with per-owner monotonic durations and correlated IDs. No sub-millisecond, p95/p99, compression-ratio or Rust-versus-Swift speed claim has been established.

The later [E5 cost procedure](../designs/11-operations-integration/experiments/route-performance.md) separates process/socket/application/parser/pixel/presentation boundaries, priority direction and shared congestion, compression state/CPU and protocol-versus-physical byte counts. Pinned source shows additional observation limits; no experiment or performance ranking follows.

## Blind-spot probes

These are scenarios intended to expose missing contracts, not a claim to enumerate all unknown unknowns.

| Probe | Boundary it can reveal |
| --- | --- |
| Two clients rearrange/select different panes while a background creation commits | Shared workspace intent versus per-client continuation and conditional reconciliation |
| Snapshot between every CSI/OSC/DCS/UTF-8 fragment while live output continues | Rendered state versus parser continuation; exact output cut; protocol version differences |
| Large diff/file streams plus a stalled terminal viewer and interactive control | Shared congestion/queues, memory retained outside logical byte windows, priority limits |
| Gateway dies after Host effect but before caller reply; then caller retries | Lost receipt versus duplicate effect, authority incarnation and reconciliation window |
| Same path/name exists on two Hosts, including incompatible receiving-filesystem names | Machine qualification, byte-name domain, routing and client-native output destination |
| Host restarts while an ask, live annotation edit, CLI outbox prefix and process cleanup are in flight | Caller intent, durable operation state, edit authority, exact cursor/effect transaction and safe retirement |
| Host creates a session before any renderer exists | Shell environment/credential provisioning order, explicit creation receipt and renderer-independent process custody |
| No app is attached while title/CWD/last-output/activity changes | Renderer-derived facts versus Host/backend-derived facts; promised no-client behavior and viewport meaning |
| ZMX's VT snapshot is parsed by the differently pinned native Ghostty renderer | Restore/parser/mode disagreement and derived-fact parity across both VT revisions |
| Stable/beta/debug or old/new ZMX processes connect through different service versions | Capabilities, channel provenance, truthful refusal and active-resource upgrade boundaries |
| Proposed transcript or debug telemetry contains private terminal content | New durable-data purpose, retention/access and export-scrubbing boundary |

## Coordination topologies to challenge

The Lead's leading direction is **scoped Rust owners with explicit command/result ports, typed fact subscriptions, separately prepared client state and a separate terminal byte lane**. It is a candidate for challenge, not a selected full Program Design.

| Candidate | Gain | Cost and risk | Evidence that would change the choice |
| --- | --- | --- | --- |
| Scoped typed owner calls/mailboxes and subscriptions | Explicit authority, narrow dependencies and traffic-specific semantics; no ambient global command bus | More explicit wiring; cross-domain dependencies must remain understandable; recovery and generic observation still need homes | Repeated cross-domain wiring dominates without improving ownership/proof, or equivalent real-path measurements favor shared fanout |
| Shared typed fact hub per process, with domain owners outside it | Uniform fanout/filtering/replay diagnostics and easier generic observation | Shared queue/retention coupling and growing umbrella vocabulary; consumer contracts cannot be inferred from one primitive | A bounded typed hub preserves required outcomes with simpler wiring and measured lower cost; source filtering/recovery boundaries remain inspectable |

Both candidates retain direct effect ownership; neither puts arbitrary commands, raw terminal bytes, all caches or all business logic into a bus. Rust channels inside a process and the Host/Gateway network protocol are separate layers. A persistence/recovery log is a separate decision, not an automatic consequence of using either candidate.

Claude's second opinion proposes a **versioned Gateway replica of selected Host state**: keyed scope/incarnation/revisions and resnapshot on gap, with commands/effects and terminal bytes on separate planes. It gains labeled last-known reads during disconnection and one recovery model for replaceable state. Host owners pay for coherent snapshots; Gateway pays retained memory and restart/refill cost; stale replicas must never authorize effects. This complements either wiring topology. Per-client UI continuation can still have a client owner; the need for some Gateway state does not automatically move every cursor or layout there.

## Second-opinion disposition

Claude Advisor's actual handback is root message `01a141da-8bc2-7400-8a9a-1757b849bd4b`, activity6733. K01/K02/K06/K07/K09/K10 were supported; K03 narrowed, K05 sharpened, K04/K08 qualified. Lead opened decisive source anchors and accepted the qualifications above. Broader claims that a third Host VT, one particular offset mechanism, or Gateway ownership of every client continuation is mandatory remain unproved. No formal independent design acceptance, runtime result or platform parity follows from this advice.

Targeted new-evidence reply `01a141e1-ada4-7653-807a-0840b3b7fd51`, activity6735, accepted those three qualifications and sharpened the U14/authority countercase. No peer assignment remains pending. Shared typed operations, codec/cancellation limitations and detachment-policy evidence are reduced in the [research addition](../../../../tmp/practices-research/2026-10-15-daemon-extraction-survey/typed-api-lifetimes-addendum.md). The later direct owner selection U15 resolves no-client behavior; it was not inferred from a resume hook.

## What stays open for product meaning

Mac-local scope, detach/terminate separation, no-client Host operation, macOS/iOS Gateway placement, frontend socket routing, Host-local session inputs, attached-machine worktree CLI and both Gateway/Host multiplicity directions are settled. Remaining product meaning includes exact remote CLI routing/authority; controller/shared-layout policy; restart/history coverage; credential/effect custody; supported platform/path profiles; native remote-origin effects; and interaction/resource tolerances. The [current Requirements](../user-requirements.md) own these choices. No phone-placement or G5 question remains pending.

These should be reduced to one concrete outcome decision at a time after the second opinion. Library spelling, crate grouping, graph enforcement and routine proof mechanics remain Lead work. No new implementation or service replacement is authorized by this catalog.
