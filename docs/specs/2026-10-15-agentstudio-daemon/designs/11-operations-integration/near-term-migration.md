# Next migration slice: the remote-session spine

**Make one real path through AgentStudio work before multiplying subsystems.** The proposed near-term focus connects the native terminal to its Gateway and an addressed Host backend, with continuing execution independent of the view. This refines the existing [remote-terminal increment](../../increments/01-remote-terminal/specification.md); it does not declare that increment ready, choose release scope or waive later features.

The [whole migration map](migration-map.md) and [hierarchical feature checklist](migration-feature-checklist.md) keep the rest visible. Fleet/bot servers and deployment/workspace cardinality are outside this slice. Host macOS/Linux and Gateway macOS/iOS remain the project obligations; mobile hosting is an explicit qualification dependency, not an assumed separate iOS daemon.

## The current path and the replacement boundary

Current: native workspace/surface composition prepares a terminal, Ghostty startup launches local `zmx attach`, and the app's pane/Undo/custody model participates in cleanup. See [actual lifecycle paths](../04-terminal-runtime/execution-lifecycle-design.md#current-entry-to-effect-path), [ZMX backend](../../../../../Sources/AgentStudio/Core/RuntimeEventSystem/Runtime/ZmxBackend.swift:182) and [current native command boundaries](../10-swift-client/command-execution-map.md). The recorded source baseline is app `624300332f5e50f7bb8cbb9fc786d5e5b4a3d462`.

Target proposal: Host session owner establishes the backend execution; a separate admitted attachment bridges ordered terminal data through Gateway to the actual native surface. Swift keeps rendering/input/native application and the selected command catalog; it no longer supplies the Host's execution lifetime or sole fact source. [DS04](../04-terminal-runtime/execution-lifecycle-design.md) owns that cut, including old queued cleanup work.

```mermaid
sequenceDiagram
    participant UX as Native terminal
    participant G as Device Gateway
    participant H as Addressed Host
    participant B as Terminal backend
    UX->>G: Addressed session intent
    G->>H: Admitted create or access operation
    H->>B: Establish / inspect execution
    B-->>H: Actual readiness or failure
    H-->>G: Session result
    G-->>UX: Qualified session result
    UX->>G: Attach and request control under policy
    G->>H: Admitted attachment
    H->>B: Attach backend
    B-->>H: Ordered restoration and live output
    H-->>G: Bound attachment byte lane
    G-->>UX: Ordered terminal output
    Note over UX,H: Closing this view detaches; termination is a separate admitted operation
```

The final byte relay and restore/live handoff still need the recorded feasibility work; the byte lane uses the declared Host and Gateway hops. Backend evidence, Host registry mutation, remote response and native publication stay separate outcomes.

### Where the current responsibilities split

This is the first migration boundary in concrete terms. The names below reuse the [existing entity/module bindings](program-design-workbench.md#bind-the-specifications-entities-before-naming-packages); they do not create a crate for every row or select public method names.

| Current responsibility | Target owner and boundary | What its caller may conclude |
| --- | --- | --- |
| [Prepare a backend handle and directory](../../../../../Sources/AgentStudio/Core/RuntimeEventSystem/Runtime/ZmxBackend.swift:183) | `host_session_runtime` consumes a backend-establishment port independent of E2/E16. The adapter performs the selected real backend start/inspection. | Handle preparation, actual execution establishment and retained registry work are distinct observations. Returning a handle alone cannot mean the child is running. |
| [Prepare native `zmx attach` startup](../../../../../Sources/AgentStudio/App/Coordination/WorkspaceSurfaceCoordinator+ViewLifecycle.swift:402) | Native startup creates the renderer/view; Host `terminal_attachment` owns the admitted association with the selected E1. Gateway relays the bound lane. | A native surface can be ready while remote attach failed, or attach can succeed before the native surface is usable. Neither result substitutes for the other. |
| Route create, attach and control | Gateway routing preserves the explicit Host/session target and attempt identity. Host admission and the capability owner decide the operation. | A valid socket/frame or a Gateway handoff is not Host permission, backend completion or child input consumption. A lost reply cannot justify another create or uncertain keystroke replay. |
| Collect terminal facts without a view | Host `host_terminal_facts` owns its qualified source, admission and selected observation writes for E1's lifetime. Gateway preparation consumes qualified inputs. | A renderer-free source still needs qualification; output bytes alone are not title/CWD, shell completion or physical exit. A stale copy cannot establish current Host liveness. |
| [Retire an unreferenced pane/Undo session](../../../../../Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceCoreRepository+SessionOwnership.swift:174) | Client reference/history cleanup stays separate. Only an explicit admitted termination enters the Host session owner and backend effect adapter. | No local pane or available Undo reference is not termination authority. The old [cleanup worker](../../../../../Sources/AgentStudio/App/Coordination/WorkspaceSurfaceCoordinator+SessionCleanup.swift:70) must lose that destructive ownership for migrated executions. |
| [Observe the termination effect](../../../../../Sources/AgentStudio/Core/RuntimeEventSystem/Runtime/ZmxSessionControl.swift:46) | The backend adapter preserves the intended execution's identity and reports its actual platform observation through the owning domain result. | Sent Kill remains pending in the current source; replacement identity and denied inspection are not extinction. The Rust Mac/Linux counterpart must preserve those distinctions. |

For example, suppose creation targets Host A and the Gateway disconnects after the Host has started backend work. The native client has lost its response path; that fact does not tell it whether creation happened. The Host's creation task and execution custody cannot become children of that Gateway connection, and another connected Host B is not a fallback destination. G3/G8 must supply the selected inspect/reconcile contract before the caller can decide what to do next. This example requires no workspace-to-deployment cardinality choice and adds no automatic retry or durable operation journal.

The Rust import boundary follows those jobs: session/attachment rules consume validated domain values and their own backend/storage/clock ports; transport and platform adapters implement those ports; process composition supplies Tokio and supervises their work. Native identifiers, SQL rows, socket streams and backend handles do not become session-domain types. The required actual schemas, variant payloads and unsettled guarantees remain the closures below, rather than implementation defaults hidden in an adapter.

## Near-term contract closures

These are detailed design obligations for this slice. They are not checked off by this document and do not prescribe task/file order.

- [ ] **Execution identity and lifecycle** — E1/E23: Host-qualified session separate from E2 attachment, E3 connection, E10 provider binding and E16/E25 native/logical nodes. Domain execution state must not contain `detached` as if it were an OS-process state; attachment presence is an independent observation. Define creation readiness, natural exit, explicit termination and the selected restart/retained-record promise. [DS04](../04-terminal-runtime/specification.md), [existing bindings](program-design-workbench.md#bind-the-specifications-entities-before-naming-packages).
  - [ ] Split the actual execution/backend association from the legacy pane/custody/Undo container. The [whole legacy custody row is held](../02-data-ownership-replication/storage-placement-matrix.md); it cannot be exported unchanged or block defining the separate execution contract forever.
  - [ ] Settle required Host runtime/registry state and its actual persistence/write gate. Do not invent a new database table solely from an inventory gap; no restart recovery is inferred from a UUID or backend name.
  - [ ] Define the Host shell's local socket, execution/context credential, CLI store/channel and installed CLI/hook executable before launch. Current [environment construction](../../../../../Sources/AgentStudio/App/PaneAgents/PaneIPCIdentityOwner.swift:119) supplies `AGENTSTUDIO_IPC_SOCKET`, `AGENTSTUDIO_PANE_TOKEN`, `AGENTSTUDIO_PANE_ID`, `AGENTSTUDIO_WORKSPACE_ID`, `AGENTSTUDIO_CLI_STORE`, `AGENTSTUDIO_CLI_STORE_CHANNEL` and `AGENTSTUDIO_CLI`. Bind equivalents to the actual Host and admitted execution/context; never inherit a Mac socket/token/store path into a remote shell. Preserve eligible Host-local input without every Gateway. Provider hooks can [silently return zero without credentials](../../../../../Sources/AgentStudioIPCClientCore/ProviderHooks/ProviderHookInvocation.swift:126), so hook exit is not enrollment or delivery proof. Qualify the Linux CLI/hook artifact; the existing package declares macOS. Minimum bootstrap/admission belongs here even when full context feature delivery is a parallel branch. This selects no new spool, writer-lease issuer or credential distribution policy.
  - [ ] Define the complete Host shell launch environment, beyond authority variables. The [source evidence](../04-terminal-runtime/research/remote-shell-environment.md) traces app-versus-daemon base environment, shell/working-directory inputs, PATH/helper lookup and `GHOSTTY_BIN_DIR`, current clearing of inherited `NO_COLOR`, plus `ZMX_DIR` and nested `ZMX_SESSION`/`ZMX_SESSION_PREFIX` handling. Preserve the selected launch semantics with Host-local paths/resources and admitted overrides; do not copy the Mac bundle or every daemon environment value into the child by accident.
  - [ ] Qualify terminal capability and shell-integration resources on the Host. Bind the actual advertised `TERM`, available terminfo/`TERMINFO`, `GHOSTTY_RESOURCES_DIR` or equivalent selected resource mechanism and supported shell producer. Resource presence alone is not integration injection, and a local relay's environment is not the inner shell's. Exercise selected completion/CWD/title/progress sources without native clients/Gateways; their coverage feeds the renderer-free fact and wait contracts. This requires no second Host terminal emulator by assumption.
  - [ ] When the selected local notice path uses the existing CLI outbox, bind its actual Host-local consumer and lifecycle. The [producer](../../../../../Sources/AgentStudioIPCClientCore/OfflineOutbox/PaneNotificationOfflineHandler.swift:7) queues only eligible own-pane notices under declared never-submitted/unreachable dispositions; this does not permit replay of an uncertain mutation, title/line/ask or provider event. Preserve store/channel/subject qualification and the [consumer's intake-cursor/domain-write boundary](../../../../../Sources/AgentStudio/App/PaneAgents/PaneCLIOutboxDrain.swift:13). Producer-local queued acknowledgement is not Host admission or human delivery, and a missing drainer cannot be presented as a functioning integration. The private producer store is not a replicated Host copy; actual writer gating still applies to consumer commits. This preserves an existing narrow path, not a new general spool or lease bypass.

    Preserve the actual [send transaction's predicates](../../../../../Sources/AgentStudio/Core/PaneContext/PaneContextService+Messages.swift:20): scope admission precedes duplicate lookup; a same-intent duplicate can commit its participant before returning; a new ask requires current session binding, while a new notice does not. Do not make every Host-local notice wait for provider binding merely because asks use it.
  - [ ] Bind any repository/worktree association as Host-qualified E7/E8 references, including launch-directory interpretation and preserved sidebar/grouping meaning. Existing [pane facets are optional](../../../../../Sources/AgentStudio/Core/Models/Pane.swift:131); a genuinely unassociated terminal is different from silently dropping an existing association. Current [path-derived keys](../../../../../Sources/AgentStudio/Core/Models/StableKey.swift:7) and [globally unique topology rows](../../../../../Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceCoreMigrations+GlobalTopology.swift:9) cannot merge equal paths from different Hosts or resolve a remote path on the Mac. The first associated remote integration must settle its namespace/import/native projection; this does not automatically choose a global SQLite re-key or settle deployment/workspace cardinality.
- [ ] **Operation boundary** — E4/E5: create/access, attach/detach, claim/release control and explicit termination have operation-specific closed outcomes, actual authority, target scope and uncertain-result handling. Existing frontend method names are discovery inputs, not automatically the selected wire surface. [DS01](../01-service-contracts/specification.md), [DS03](../03-authority-control-plane/specification.md).
  - [ ] Realize the [Host session operation boundaries](../04-terminal-runtime/session-operation-boundaries.md): separate server-constructed frontend and Host-local origins, backend observations, guarded record work and operation custody. Host-local input is not E4. Backend identity/readiness, record commit and caller delivery remain separate; invalid inspection or failed storage cannot become known noncreation/termination.
  - [ ] One schema home supplies Rust and generated/validated Swift shapes; real opposite-language production encoding/decoding must be covered. Select supported version/size/framing refusal, not codec self-roundtrip proof.
  - [ ] Host and native target kinds cannot be exchanged. Ordinary frontend traffic uses Gateway; eligible session-local input remains Host-local.
  - [ ] Complete the [per-method/per-field terminal ownership map](../04-terminal-runtime/terminal-api-ownership.md) into selected callable shapes and no-view outcomes. `terminal.status`, metadata-only `terminal.snapshot`, Unicode `terminal.send` and the six `terminal.wait` conditions currently depend on native pane runtime sources. Bind actual Host execution/fact/input observations separately from addressed renderer health/read-only/secure-input facts. No hidden viewer, fabricated readiness or silently changed pane/session identity may bridge a missing contract.
- [ ] **Backend attachment** — E1/E2: actual ZMX version/profile, establishment/attach readiness, control/resize and terminal mode/query response path. [Restoration experiment](../04-terminal-runtime/experiments/terminal-restoration.md).
  - [ ] Establish a complete reconstruction and ordered snapshot-to-live cut through the real backend and fresh native renderer. The [20 October experiment](../04-terminal-runtime/research/backend-observations-2026-10-20.md) preserved the same-connection byte cut but failed Capture/Init reconstruction in its finite profile. Redesign or qualify the checkpoint mechanism before integrating it; an output sequence number alone cannot recover omitted parser/screen state.
  - [ ] Bound viewer buffering, preserve canonical reading progress and refuse/resynchronize a slow viewer without arbitrary VT loss. Exact capacities follow workload evidence.
- [ ] **Control and concurrency** — IP2: one input/resize controller, other viewers; attachment alone never steals control. Define no-controller, handoff/revocation, viewport/focus and child-visible input/resize semantics. [Terminal contract](../04-terminal-runtime/specification.md).
  - [ ] Distinguish accepted/written input from child consumption and visible echo. Do not replay uncertain keystrokes after disconnect.
  - [ ] One Host's failure or identical session label cannot redirect to another Host. Several Gateways retain independent delivery/attachment state.
- [ ] **Native integration** — E16: current Ghostty startup and native input/render owners bind to the Gateway attachment through the qualified relay. Font/geometry/focus/publication remain native; decode/admit/derive/schedule off MainActor. [Swift client contract](../10-swift-client/specification.md), [native read needs](../10-swift-client/session-native-read-needs.md).
  - [ ] Surface readiness, native application failure and view closure are observed separately from Host command success. Keep the command display/shortcut identity; replace its relevant backend route.
  - [ ] macOS and iOS Gateway hosting/socket custody are explicit platform adapters. Mac proof is not iOS qualification. No business FFI requirement follows from safe mobile runtime startup.
- [ ] **Authority/data integration** — actual source transaction predicates and central writer validity apply to whatever this slice writes. Host renewal is independent of all Gateways. [IP4](../../initial-profile.md), [storage placement](../02-data-ownership-replication/storage-placement-design.md).
  - [ ] Classify each required write under valid/invalid authority and its truthful refusal/partial/coverage outcome. Private co-commit checkpoints are not automatically moved into an ungated store.
  - [ ] Define finite last-known reads and audience. A copy position does not establish Host liveness or authorize an effect. No temporary Gateway issuer or durable intake spool is introduced.
- [ ] **Task/resource custody** — composition owns the Tokio runtime and actual accept/connection/attachment/backend task handles. Cancelling delivery must not terminate continuing execution. [Rust engineering](rust-engineering-design.md).
  - [ ] Pin backend/native dependencies and first-party lint inheritance, safe APIs and target features. Handle cancellation/join, socket/path/process custody and packaging at their actual owners.
- [ ] **Cutover from current cleanup** — prevent the old pane/Undo cleanup coordinator and queued backend retirement from killing a newly service-owned session. Preserve existing user data and selected Undo meaning; session survival is already fixed by R5/R6. [Lifecycle cutover](../04-terminal-runtime/execution-lifecycle-design.md).
  - [ ] Inventory and drain/join old work before changing ownership; cancellation is not reversal of an already sent backend effect. Define installed-session handling rather than silently replacing live sessions.
  - [ ] Remove the old backend path for the selected capability after integration proof. Retained native presentation code is not obsolete merely because it stays Swift.

## Cohesive implementation units to plan after those contracts close

| Unit | Output / reason to change | Depends on | Boundary that ends the unit |
| --- | --- | --- | --- |
| Terminal contracts and domain rules | Validated session/attachment/control values and decisions | Selected DS01/03/04 meanings | Callers cannot confuse identities or construct invalid outcomes |
| Host session/attachment owner | Backend operation and continuing execution/task custody | Domain rules; backend/storage/clock ports | Actual backend readiness/termination/attachment observation |
| Gateway session routing | Explicit Host routing, desired interests and independent delivery | Selected operations/network adapter | Wrong Host cannot receive a request; connection loss is not execution loss |
| Native socket/surface adapter | Actual app consumer and native renderer/input path | Swift-compatible contracts, attachment relay | Real surface presents restored/live data and sends addressed control |
| Packaging/composition and source facts | Runtime/dependency resource wiring, minimal diagnostics and renderer-free fact source where selected | Actual platform adapters and source profile | Supported packaged path and honest fact coverage under presentation loss |

These are responsibilities from the existing binding map, not five required crates or PRs. The implementation plan will choose exact files, dependency order, commands and red/green steps only when the slice's governing design and Verification Design permit it. Farther feature plans remain high-level.

## What must be observed before calling it migrated

The actual reference is the [remote-terminal increment's journey](../../increments/01-remote-terminal/specification.md#what-proves-this-increment), not an echo service. The following hierarchy separates proof that can be prepared independently from the integrated result. It does not rank releases or declare any experiment executed.

- **Types and operation contracts**
  - Derive or validate Swift and Rust consumers from the one selected schema authority; reject wrong target kinds and malformed semantic values at the trusted boundary. Structural/type checks cannot establish actual socket interoperability or permission.
  - [Swift/socket qualification](../01-service-contracts/experiments/swift-socket-compatibility.md) must drive real opposite-language producers/consumers, declared versions, fragmented/coalesced frames and semantic refusals. Separately qualify the remote Gateway/Host pair. A same-codec roundtrip or a successful connection fails to decide either obligation.
- **Backend restoration and native rendering, as separate component questions**
  - [E1](../04-terminal-runtime/experiments/terminal-restoration.md) separates owned VT state, backend protocol, real PTY, native component and full-route evidence. Compare the known prefix, restored state and subsequent suffix under independently specified expectations. Matching visible text alone must not pass a broken continuation/history case.
  - Native qualification must feed actual producer output into the existing Ghostty command-backed path and separately observe native input, query returns, geometry and redraw. Passing remote output to a paste API is not output rendering. A native relay component and backend restoration can be investigated independently; neither substitutes for their eventual composition.
- **Full client → socket → Gateway → Host → backend route**
  - Combine the qualified components, then observe real input/resize/output and ordered return to the same execution. Known bytes at a socket or a backend acknowledgement cannot stand in for native application or child consumption.
  - Remove the final view, app and every Gateway while an independently observed workload continues; return through the declared route. Separately test controller/viewer authority, no arbitrary VT loss, bounded slow viewers and explicit termination with actual backend outcome.
  - Use multiple Hosts and Gateways, including equal local session labels. One Host/link loss must not redirect to another Host or cancel its unrelated work. Malformed/refused/partial/unknown outcomes and late completions remain distinct.
- **Platform, custody and installed-session cutover**
  - Qualify the selected macOS and Linux Host profiles. The required iOS Gateway needs its own [startup/socket/lifecycle qualification](research/ios-gateway-hosting-evidence.md); Mac success is not phone evidence and mobile suspension is not Host execution termination.
  - Observe old queued cleanup versus transferred execution custody, task cancellation/join and real authoritative/native state readback. A clean development fixture cannot prove installed-session adoption; an old backend effect already sent cannot be undone by cancelling its worker.

### What the existing tests actually supply

These are inspected predecessor tests, not a claim that they ran or that the new route already has coverage.

| Existing source | Boundary it exercises | Remote proof still needed |
| --- | --- | --- |
| [Backend integration tests](../../../../../Tests/AgentStudioTests/Integration/ZmxBackendIntegrationTests.swift:47) | The create case validates the returned UUIDv7 handle and explicitly starts no session; adjacent cases check attach command/directory setup. | Actual renderer-free Host execution establishment, operation outcome and later attach. A handle-only implementation would pass the current create case. |
| [Live ZMX cleanup case](../../../../../Tests/AgentStudioTests/Integration/ZmxE2ETests.swift:20) | Real local backend identity/effect plus reopened SQLite cleanup and replacement protection. | Gateway/Host/native routing, view-independent execution custody and Mac/Linux counterpart. The inspected case also uses wall-clock/yield polling, which cannot be copied unchanged into the required event-driven proof. Its dedicated [mise lane](../../../../../.mise.toml:518) is opt-in, not evidence that routine tests establish these outcomes. |
| [NDJSON codec tests](../../../../../Tests/AgentStudioIPCTransportTests/NDJSONFrameCodecTests.swift:7) | Swift decoder/encoder fragmentation, bounds, invalid UTF-8 and deterministic scan-work checks. | Real Swift/Rust producers and consumers, selected schema/version semantics, admission and separate remote compatibility. These tests do not select NDJSON for the new protocol. |

No project `verify-agentstudio` journey was found at the checked `.agents/skills/` or `.codex/skills/` locations. The slice therefore needs a lasting real-route journey that drives the actual app/client entry and reads the native result, Host execution/effect and target isolation at their real owners. Exact schema/profile references and remaining state/observer seams must be settled before its separate Verification Design can claim complete rows; a new test name or green transport status cannot fill that gap.

Full provider hook/context/fact behavior still has its own branch; a surviving shell cannot close it. Tests or stand-ins that omit a real boundary must name that unverified interaction. No product tests, probes or implementation have run as a result of this map.
