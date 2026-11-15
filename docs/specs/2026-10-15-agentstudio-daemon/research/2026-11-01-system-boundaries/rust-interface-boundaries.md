# Rust interfaces and dependency boundaries

Design-research input, 2026-11-01. This binds the discussion to the owner's Rust standards without selecting a package count, public schema or implementation plan. [Responsibilities](capability-boundary-map.md), [source evidence](research-ledger.md) and [continuity qualification](continuity-qualification.md) remain separate views.

## Outcomes the boundaries must preserve

- The integrated Host exposes terminal/ZMX, native agent control and the declared machine features through their actual owners.
- Active provider turns continue during planned Host upgrades; execution custody must be outside that replacement lifecycle or use an equivalent qualified handover.
- Standalone and board-linked delegation both have durable execution tracking. Neither a synthetic board task nor a synthetic schedule is a prerequisite for standalone execution.
- Gateway prepares authorized views and routes operations; native clients own their actual rendering, focus, input and destination effects.
- One owner decides each truth. Execution settlement, board-task acceptance, message delivery and view publication remain separate outcomes.

## Dependency direction to evaluate

Arrows below mean imports, not runtime traffic. These are responsibility families; several can be modules in one crate.

```text
Executable composition
├── Application owners and their small dependency ports
│   └── Domain identities, states, rules and owned errors
├── Backend and storage adapters
│   └── The ports and domain values they implement
├── Protocol/transport adapters
│   └── Selected wire schema and domain translation
└── Client/view runtime
    └── Qualified read contracts and pure family transforms

Task/execution domain ──uses──► execution-control port
Optional board adapter ──implements──► board work-association port
Gateway preparation ──uses──► qualified read values
Replication integration ──uses──► shared writer/receiver/lease APIs
```

This permits a domain owner to depend on the operation its consumer needs while the concrete backend implements that port. Domain rules and pure view transforms do not import sockets, SQL rows, provider SDK handles or native renderer types. Composition constructs the real implementations and passes only the handles each owner uses.

The task/execution core must not require board storage just to represent a standalone run. A board adapter can resolve and validate the optional qualified task association. It does not create another writer of the board task's canonical status. Likewise, a Gateway build should not need provider launch/retirement code merely to display a session.

## The existing Router seam and its packaging constraint

The [session command port](</Users/shravansunder/code/projects/codex-router/crates/collaboration-contracts/src/session_command_port.rs:111>) and [event hub port](</Users/shravansunder/code/projects/codex-router/crates/collaboration-contracts/src/session_event_hub.rs:46>) provide useful semantic interfaces. [Startup composition](</Users/shravansunder/code/projects/codex-router/crates/codex-router-host/src/collaboration_runtime/startup_composition.rs:596>) shares their implementations across ACP and app-server fronts.

However, [collaboration-contracts/Cargo.toml](</Users/shravansunder/code/projects/codex-router/crates/collaboration-contracts/Cargo.toml:14>) also imports board/automation storage, fleet writer and OS dependencies. The containing crate is broader than this one interface. Reuse can mean a deliberate service client or a qualified smaller shared contract home; it cannot be assumed to mean importing the entire existing crate into iOS. This is source dependency evidence, not a measured compile failure or permission to refactor Router's published API.

The [scheduled RunRecord](</Users/shravansunder/code/projects/codex-router/crates/agent-automation/src/run_execution.rs:75>) is another boundary to respect: its mandatory schedule and destination-specific completion behavior are not standalone-delegation meanings. Exact turn/attempt settlement and stop-occupancy mechanics may be reused where their contracts fit; whole-row reuse is not selected.

Consumer fit also applies per operation: [SessionCommandPort::cancel](</Users/shravansunder/code/projects/codex-router/crates/collaboration-contracts/src/session_command_port.rs:131>) takes a session target, whereas task-attempt cancellation needs the selected attempt/native-operation identity preserved through the effect boundary. That does not make a current-session cancellation API wrong for its own contract; it means the task system cannot assume that method alone implements delayed, attempt-scoped cancellation. Qualify the existing narrower operation/turn paths before defining any adapter change.

The inspected [external-provider cancellation path](</Users/shravansunder/code/projects/codex-router/crates/codex-router-host/src/external_provider_supervisor/provider_conversation_backend.rs:359>) already accepts an exact target operation, checks target/binding generation/nonterminal prompt state, and calls the runtime's operation-specific cancel. Its outcome records cancellation requested rather than proven cessation. This is a stronger reuse candidate for an external provider's attempt control than cancelling whichever turn happens to be active. Native Codex binding/control follows its own actual path and still needs fit qualification; no universal backend capability is inferred.

Separately, the current [facade turn/interrupt handler](</Users/shravansunder/code/projects/codex-router/crates/collaboration-runtime/src/router_session_app_server_methods.rs:395>) accepts a turn ID but does not pass it through; the delivery route resolves the currently active operation. This is a concrete source gap for the intended stale-turn oracle, not merely uncertainty about a broad current-session API. Exact operation-bound cancellation below it does not repair the discarded requested identity. No repair or runtime reproduction was performed here.

## Types carry distinct meanings

No public Rust definitions or wire discriminants are frozen here. The following are the meanings that their eventual types need to preserve.

| Meaning | What must be explicit | Invalid combination to prevent |
| --- | --- | --- |
| Work association | Standalone, or a validated project-qualified board-task association | Standalone execution requiring a fake task/schedule, or a task ID detached from its project authority |
| Execution identity | Actual attempt/control identity, distinct from provider conversation and turn | An old cancellation naming only a reused conversation and stopping later work |
| Addressed machine resource | Host context plus resource kind and owning identity | A local path or display label silently resolving on another Host |
| Provider binding | Provider-qualified native identity and admitted current binding/generation | Treating a PID, pane, socket count or freshly restored view as native conversation identity |
| Operation outcome | Actual accepted/committed/observed/refused/uncertain boundary, with required payload for each supported state | A boolean success after an unreadable reply to an already-sent effect |
| Observation validity | Source-specific complete, partial or unestablished coverage and its actual witness | Successful empty membership inferred from source failure or equal-looking stale values |
| View candidate | Desired generation, qualified captured sources and the prepared semantic value | A late completion publishing over a newer target or changed authority |
| Native destination result | Actual effect outcome separate from Host finalization | Copied attempt state causing another clipboard/file effect |
| Interaction request | Provider request/option identity and legitimate answering authority | Reconnect silently approving, duplicating or misrouting the request |

Use closed variants with required payloads where fields are valid only together, validated newtypes where identity kinds differ, and exhaustive consumers. Newly generated application IDs follow UUIDv7. Imported provider identifiers keep their native meaning. Replicated row-key restrictions do not convert every private cursor or upstream identifier into a new application UUID.

The mapping between one execution attempt and one or more provider operations/turns still needs its contract. Distinct identity types must not hide a one-attempt-equals-one-turn assumption. A work result reported during a turn, actual turn settlement and accepted saved-task completion are different observations.

Planned Host replacement also separates the public Host interface's current instance from the continuing execution owner's identity and event source. A new connection or control-service epoch cannot mint a replacement execution and present it under the old resource label. Qualification must resolve the existing provider-qualified session/turn through an admitted association while preserving each source's actual epoch and sequence. The exact exposed binding/schema is not selected here.

Parse unknown wire/file/row values once at the boundary, then establish semantic validity. Deserialization and a well-typed actor field do not authenticate a caller or grant permission. Actual scope/currentness predicates remain at the effect owner, including the real write transaction where required.

“Compile-time transforms” means typed inputs/outputs and exhaustive domain cases in local code. Remote version mismatch, stale state, authorization and source validity still require runtime admission. No type-level framework can establish facts the source did not observe.

## Incoming data without a universal bus

```text
Raw provider / filesystem / protocol input
  → owning adapter parses and qualifies it
  → domain owner admits ordered facts or replaceable samples
  → pure typed reduction / preparation
  → required authoritative write and actual commit where applicable
  → eligible facts/copies and qualified Gateway preparation
  → native publication of changed semantic values
```

This is a responsibility pattern, not one mandatory pipeline for every feature. A terminal byte stream and a native clipboard effect have different paths. Required transaction writes do not become optional background work; a pure projection never performs Host maintenance or acknowledges an effect.

Choose delivery by meaning: direct commands; source-ordered transitions; keyed latest-state observations where replacement is valid; bounded terminal buffers; finite qualified content. Debouncing a provider approval or an accepted task transition as if it were a replaceable title sample would change behavior. Source admission and semantic contraction precede multiplexing or UI publication.

## Runtime and platform custody

One Tokio runtime is owned by each actual process composition root. Libraries receive asynchronous dependencies rather than create nested runtimes. Resource lifetimes determine task custody; a connection owns its delivery work, while continuing execution has its own owner. That execution owner must survive the selected planned Host replacement boundary.

Track and drain owned asynchronous work using the adopted runtime facilities. Keep blocking Git/filesystem/native work at a bounded blocking owner. Independent Hosts/resources must retain independent progress. A bounded channel is not, by itself, a bound on all retained memory or a complete overflow policy.

The Mac socket adapter and embedded iOS Gateway have different hosting constraints. The existing [binding-safety investigation](../../increments/00-qualification/bridge-gateway-transport/native-binding-safety.md:1) found that a green ordinary UniFFI lint does not satisfy the selected first-party generated-unsafe restriction. A new bridge must be qualified rather than move unsafe scaffolding into an unexamined exception.

## Checked Router standards to inherit deliberately

At Router `1cf0ce5a6`, [workspace lints](</Users/shravansunder/code/projects/codex-router/Cargo.toml:154>) forbid unsafe code and deny production unwrap/expect/panic/todo/unimplemented, lossy casts and held-lock hazards among the full table. [The toolchain](</Users/shravansunder/code/projects/codex-router/rust-toolchain.toml:1>) pins Rust 1.98.1; its package edition is 2024 and dependencies are workspace-owned. These are source observations, not an adoption/target-build claim for Studio.

Follow the actual full inherited lint table and package conventions rather than copying only a few convenient rules. Important modules/files name responsibilities; conventional `lib.rs`, `main.rs`, `mod.rs` and a crate error home remain conventional. Promote a module boundary to a crate when platform, dependency, reuse or independent lifecycle constraints need compiler enforcement; do not create a crate per noun.

The actual supported target/feature/generated-code graph must be built and inspected before compliance is claimed. Useful behavioral proof includes stale/cross-Host input rejection, original-turn continuity, exact cursor/effect co-commit, wrong-attempt cancellation rejection and actual producer-to-consumer schema compatibility. Roundtrips through one codec or a default-target lint alone do not decide those contracts.

## Remaining design work

Authority and accepted-result policy, reuse/fresh conversation behavior, cascade/parent-departure semantics, retained payload/audience rules and exact public DTOs remain explicit contracts. No new engine, schema, dependency version, crate count or transport was selected by this note. The next structural design should bind these meanings to the smallest existing ownership seams that preserve them, with the native qualification gaps visible.
