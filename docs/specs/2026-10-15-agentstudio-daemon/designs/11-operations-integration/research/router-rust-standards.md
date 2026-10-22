# Codex Router Rust conventions: checked source baseline

The requested Rust reference provides concrete workspace, type and task-ownership conventions. It does not select AgentStudio's public protocol, dependency-safety scope or exact toolchain pins. This is source evidence for [R8/K15](../specification.md), not a build or runtime result.

Inspected Router source: `691cd560347d6e570dd3db0315b9ddb3ee259f84`, branch `agent-collaboration-icon`. The checkout had an unrelated untracked work-trail folder; the inspected tracked files were unchanged. AgentStudio remains at `624300332f5e50f7bb8cbb9fc786d5e5b4a3d462`.

## Workspace and lint ownership

| Checked source | Observed convention | What transfers to this design |
| --- | --- | --- |
| [Workspace manifest](/Users/shravansunder/code/projects/codex-router/Cargo.toml:1) | Resolver3; workspace package edition2024; centralized dependency declarations;27 members. | One workspace-level convention owner, inherited by each first-party member. These observations do not select a new crate per capability. |
| [Workspace Rust/Clippy lints](/Users/shravansunder/code/projects/codex-router/Cargo.toml:101) | `unsafe_code = "forbid"`; deny unwrap/expect/panic/todo/unimplemented/unreachable, indexing/string slicing, held-lock issues and the other declared lints. | First-party enforcement must include all actual members and target configurations, not just the main executable. |
| [Host member manifest](/Users/shravansunder/code/projects/codex-router/crates/codex-router-host/Cargo.toml:1) and every declared member | All27 members explicitly opt into workspace lints. | Defining root lints alone is not the inheritance proof. The member inventory is a useful admission check. No Cargo build was run. |
| [Toolchain](/Users/shravansunder/code/projects/codex-router/rust-toolchain.toml:1), [format](/Users/shravansunder/code/projects/codex-router/rustfmt.toml:1), [Clippy test allowances](/Users/shravansunder/code/projects/codex-router/clippy.toml:1) | Toolchain1.98.1 with Clippy/rustfmt/rust-src; formatter edition2024; named test allowances for expect/indexing/panic/unwrap. | Reproduce the policy explicitly where appropriate. Toolchain and dependency numbers are inspected pins, not a latest-version recommendation or demonstrated Mac/Linux build pairing. Test allowances do not waive production rules. |
| [Cargo configuration](/Users/shravansunder/code/projects/codex-router/.cargo/config.toml:1) | Offline SQLx checking; an Apple Silicon debug signing runner. | Query/schema proof and process identity matter where applicable. The Router signing script and private SQL behavior are not AgentStudio mechanisms to copy. Linux has its own artifact/profile obligations. |

Cargo's [official manifest reference](https://doc.rust-lang.org/cargo/reference/manifest.html#the-lints-section), fetched during this check, describes package lint scope separately from dependency compilation. Thus the root unsafe prohibition is not proof that dependency internals or native FFI contain no unsafe implementation. U10/IP6 already selects the safety boundary: first-party code, including generated scaffolding, forbids unsafe; pinned dependencies may be used through safe interfaces. G11 retains the concrete binding inventory and compliance evidence, not a pending interpretation of that selected boundary.

## Dependency responsibility and type examples

The [core manifest](/Users/shravansunder/code/projects/codex-router/crates/codex-router-core/Cargo.toml:1) does not depend on Tokio. The [Host manifest](/Users/shravansunder/code/projects/codex-router/crates/codex-router-host/Cargo.toml:1) composes domain/service/storage/client dependencies and Tokio/tokio-util. This is a source example of keeping asynchronous process integration outside a rules crate, not proof that the whole Router DAG is ideal for AgentStudio.

The shared dependency list includes `tokio`, `tokio-util`, `bytes`, `serde`/`serde_json`, `thiserror`, `tracing`, `uuid` and `chrono`. It also includes specialized HTTP/proxy/keychain/SQL/MCP libraries. Their presence does not make them all daemon dependencies. Select a library for an actual owning boundary; keep serializer/RPC/network/SQL choices under the relevant contract.

Two checked type patterns matter:

- [PositiveSeconds](/Users/shravansunder/code/projects/codex-router/crates/collaboration-protocol/src/automation_timing_contract.rs:1) routes deserialization through `TryFrom<u32>` and supplies matching bounded schema metadata. Successful Serde shape decoding cannot bypass this constructor's range check. Its actual limits/defaults are Router policy and are not copied into AgentStudio.
- [Lifecycle observation](/Users/shravansunder/code/projects/codex-router/crates/collaboration-protocol/src/lifecycle_observation.rs:1) uses tagged variants and explicit subject/source/generation checks. Its `validate` method establishes rules only when an admission path calls it; deriving Deserialize alone does not prove those cross-field checks run. This evidence does not adopt its public vocabulary or string error type for AgentStudio.

## Task lifetime example and its limits

The [proxy connection loop](/Users/shravansunder/code/projects/codex-router/crates/codex-router-proxy/src/server/runtime_config.rs:530) interleaves accept, shutdown and guarded `JoinSet` completion. In its tracked path it joins handlers, closes/waits an affinity `TaskTracker` and separately drains credential refresh work. An unlimited/no-shutdown branch delegates handler supervision instead. These are different ownership paths; this reading does not prove every Router operation drains or that those policies suit a durable Host session.

The [provider FIFO](/Users/shravansunder/code/projects/codex-router/crates/codex-router-host/src/provider_acp_message_fifo.rs:1) owns bounded per-session senders, worker handles and cancellation. Its128/1024 capacities, retry timing and settlement defaults are that subsystem's policy. They do not become daemon limits or automatic terminal retries.

AgentStudio must preserve the lifetime distinction its requirements already choose: delivery task loss can end an attachment; it cannot by itself become explicit execution termination. Host restart/re-adoption remains G3. Cancelling a Rust task is not an observation that an external backend effect was undone.

## Existing proof paths and remaining gaps

[Router CI](/Users/shravansunder/code/projects/codex-router/.github/workflows/ci.yml:48) invokes formatting, workspace Clippy, file-size and dependency policies, checked-query metadata and Nextest lanes. Those commands were read, not executed. Router-specific signing, feature flags, schema databases and test splits are not AgentStudio proof commands.

For AgentStudio, proof still needs actual first-party member inheritance, supported platform/feature/generated-code compilation, behavioral failure/interleaving tests, real Swift/socket schemas and the declared native/backend journeys. A manifest inventory cannot replace those layers. This source check does not complete G11's binding/compliance evidence, select a new toolchain pin or establish implementation readiness.
