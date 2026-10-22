# AgentStudio daemon: all design documents

Each Markdown source below has a local HTML reader. The system guide and feature tree explain the project; the folders hold its detailed contracts, proposed realization, research, experiment procedures and bounded results. Their source status remains authoritative.

[System guide](explainer/index.html) · [Feature hierarchy](explainer/features.html) · [Walkthroughs](explainer/walkthroughs.html) · [MVP and phases](explainer/delivery.html)

## Shared contracts and references

| Document | Markdown | HTML |
| --- | --- | --- |
| AgentStudio service system: observable specification | [Source](2026-10-15-agentstudio-daemon.md) | [Reader](2026-10-15-agentstudio-daemon.html) |
| AgentStudio daemon design | [Source](README.md) | [Reader](README.html) |
| Capability and interface contracts | [Source](capability-contracts.md) | [Reader](capability-contracts.html) |
| Delivery increments: from remote terminal to the full Host backend | [Source](delivery-increments.md) | [Reader](delivery-increments.html) |
| Service domain and identity | [Source](domain-entities.md) | [Reader](domain-entities.html) |
| AgentStudio daemon: design-set entry | [Source](index.md) | [Reader](design-index.html) |
| Initial service profile | [Source](initial-profile.md) | [Reader](initial-profile.html) |
| AgentStudio Host and Gateway: user requirements | [Source](user-requirements.md) | [Reader](user-requirements.html) |

## Service contracts

| Document | Markdown | HTML |
| --- | --- | --- |
| DS01 — Service contracts and protocol | [Source](designs/01-service-contracts/README.md) | [Reader](designs/01-service-contracts/README.html) |
| Communication: what crosses each boundary | [Source](designs/01-service-contracts/communication-design.md) | [Reader](designs/01-service-contracts/communication-design.html) |
| Swift and Rust socket compatibility qualification | [Source](designs/01-service-contracts/experiments/swift-socket-compatibility.md) | [Reader](designs/01-service-contracts/experiments/swift-socket-compatibility.html) |
| Where the 57 existing app RPC methods lead | [Source](designs/01-service-contracts/rpc-operation-map.md) | [Reader](designs/01-service-contracts/rpc-operation-map.html) |
| Service contracts and protocol: observable contracts | [Source](designs/01-service-contracts/specification.md) | [Reader](designs/01-service-contracts/specification.html) |

## Data ownership and replication

| Document | Markdown | HTML |
| --- | --- | --- |
| DS02 — Data ownership, storage and replication | [Source](designs/02-data-ownership-replication/README.md) | [Reader](designs/02-data-ownership-replication/README.html) |
| AgentStudio data ownership, storage and materialization survey | [Source](designs/02-data-ownership-replication/research/data-ownership-survey.md) | [Reader](designs/02-data-ownership-replication/research/data-ownership-survey.html) |
| AgentStudio data structures and replication: decision tree | [Source](designs/02-data-ownership-replication/research/data-replication-decisions.md) | [Reader](designs/02-data-ownership-replication/research/data-replication-decisions.html) |
| Where durable delivery fits AgentStudio | [Source](designs/02-data-ownership-replication/research/durable-delivery-fit.md) | [Reader](designs/02-data-ownership-replication/research/durable-delivery-fit.html) |
| How agent-fleet-sync fits AgentStudio | [Source](designs/02-data-ownership-replication/research/fleet-sync-consumer-fit.md) | [Reader](designs/02-data-ownership-replication/research/fleet-sync-consumer-fit.html) |
| Which data does a client view actually need? | [Source](designs/02-data-ownership-replication/research/query-data-dependencies.md) | [Reader](designs/02-data-ownership-replication/research/query-data-dependencies.html) |
| Reading a Gateway copy honestly | [Source](designs/02-data-ownership-replication/research/replica-read-contract.md) | [Reader](designs/02-data-ownership-replication/research/replica-read-contract.html) |
| Current SQL keys and replication prerequisites | [Source](designs/02-data-ownership-replication/research/schema-prerequisites.md) | [Reader](designs/02-data-ownership-replication/research/schema-prerequisites.html) |
| Current use of every catalogued table | [Source](designs/02-data-ownership-replication/research/table-use-index.md) | [Reader](designs/02-data-ownership-replication/research/table-use-index.html) |
| Which current writes must stay together? | [Source](designs/02-data-ownership-replication/research/transaction-boundaries.md) | [Reader](designs/02-data-ownership-replication/research/transaction-boundaries.html) |
| Typed input processing: sources, reduction and publication | [Source](designs/02-data-ownership-replication/research/typed-input-processing.md) | [Reader](designs/02-data-ownership-replication/research/typed-input-processing.html) |
| Data ownership, storage and replication: observable contracts | [Source](designs/02-data-ownership-replication/specification.md) | [Reader](designs/02-data-ownership-replication/specification.html) |
| Where each kind of state lives | [Source](designs/02-data-ownership-replication/storage-placement-design.md) | [Reader](designs/02-data-ownership-replication/storage-placement-design.html) |
| Every current table: proposed placement | [Source](designs/02-data-ownership-replication/storage-placement-matrix.md) | [Reader](designs/02-data-ownership-replication/storage-placement-matrix.html) |

## Authority and leases

| Document | Markdown | HTML |
| --- | --- | --- |
| DS03 — Authority, leases and central control plane | [Source](designs/03-authority-control-plane/README.md) | [Reader](designs/03-authority-control-plane/README.html) |
| Authority, leases and central control plane: observable contracts | [Source](designs/03-authority-control-plane/specification.md) | [Reader](designs/03-authority-control-plane/specification.html) |

## Terminal runtime

| Document | Markdown | HTML |
| --- | --- | --- |
| DS04 — Terminal sessions, attachments and facts | [Source](designs/04-terminal-runtime/README.md) | [Reader](designs/04-terminal-runtime/README.html) |
| Execution creation, facts and terminal attachment ownership | [Source](designs/04-terminal-runtime/execution-lifecycle-design.md) | [Reader](designs/04-terminal-runtime/execution-lifecycle-design.html) |
| E1 terminal restoration, continuation and stream cut | [Source](designs/04-terminal-runtime/experiments/terminal-restoration.md) | [Reader](designs/04-terminal-runtime/experiments/terminal-restoration.html) |
| What the terminal backend experiments establish | [Source](designs/04-terminal-runtime/research/backend-observations-2026-10-20.md) | [Reader](designs/04-terminal-runtime/research/backend-observations-2026-10-20.html) |
| Remote shell environment: source evidence and qualification boundary | [Source](designs/04-terminal-runtime/research/remote-shell-environment.md) | [Reader](designs/04-terminal-runtime/research/remote-shell-environment.html) |
| Session operations inside the Rust Host | [Source](designs/04-terminal-runtime/session-operation-boundaries.md) | [Reader](designs/04-terminal-runtime/session-operation-boundaries.html) |
| Terminal sessions, attachments and facts: observable contracts | [Source](designs/04-terminal-runtime/specification.md) | [Reader](designs/04-terminal-runtime/specification.html) |
| Terminal APIs: execution facts and native view facts | [Source](designs/04-terminal-runtime/terminal-api-ownership.md) | [Reader](designs/04-terminal-runtime/terminal-api-ownership.html) |

## Git and repository discovery

| Document | Markdown | HTML |
| --- | --- | --- |
| DS05 — Git operations, discovery and observations | [Source](designs/05-git-discovery/README.md) | [Reader](designs/05-git-discovery/README.html) |
| How the 44 Git SDK operations fit the Host | [Source](designs/05-git-discovery/git-operation-map.md) | [Reader](designs/05-git-discovery/git-operation-map.html) |
| Git parity reference: app policy plus pinned SDK | [Source](designs/05-git-discovery/research/parity-reference-2026-10-22.md) | [Reader](designs/05-git-discovery/research/parity-reference-2026-10-22.html) |
| Git operations, discovery and observations: observable contracts | [Source](designs/05-git-discovery/specification.md) | [Reader](designs/05-git-discovery/specification.html) |

## Worktree fork

| Document | Markdown | HTML |
| --- | --- | --- |
| DS06 — Worktree fork and platform counterpart | [Source](designs/06-worktree-fork/README.md) | [Reader](designs/06-worktree-fork/README.html) |
| First Linux feasibility probe | [Source](designs/06-worktree-fork/experiments/linux-feasibility.md) | [Reader](designs/06-worktree-fork/experiments/linux-feasibility.html) |
| Worktree fork: behavior baseline and Linux counterpart contract gaps | [Source](designs/06-worktree-fork/research/worktree-fork-contracts.md) | [Reader](designs/06-worktree-fork/research/worktree-fork-contracts.html) |
| Worktree fork and platform counterpart: observable contracts | [Source](designs/06-worktree-fork/specification.md) | [Reader](designs/06-worktree-fork/specification.html) |

## Agents and context

| Document | Markdown | HTML |
| --- | --- | --- |
| DS07 — Agents, provider input and retained context | [Source](designs/07-agents-context/README.md) | [Reader](designs/07-agents-context/README.html) |
| Context counts: Host meaning, Gateway composition | [Source](designs/07-agents-context/context-count-preparation.md) | [Reader](designs/07-agents-context/context-count-preparation.html) |
| E2 Host autonomy, authority and effect evidence | [Source](designs/07-agents-context/experiments/host-autonomy.md) | [Reader](designs/07-agents-context/experiments/host-autonomy.html) |
| Host-local agents and context lifetime | [Source](designs/07-agents-context/host-context-lifecycle-design.md) | [Reader](designs/07-agents-context/host-context-lifecycle-design.html) |
| Context-count reads: local engine source qualification | [Source](designs/07-agents-context/research/count-read-engine-evidence.md) | [Reader](designs/07-agents-context/research/count-read-engine-evidence.html) |
| Session status: shared execution facts and viewed state | [Source](designs/07-agents-context/research/session-status-ownership.md) | [Reader](designs/07-agents-context/research/session-status-ownership.html) |
| Agents, provider input and retained context: observable contracts | [Source](designs/07-agents-context/specification.md) | [Reader](designs/07-agents-context/specification.html) |

## Files, reviews and output

| Document | Markdown | HTML |
| --- | --- | --- |
| DS08 — Files, reviews, annotations and output | [Source](designs/08-files-review-output/README.md) | [Reader](designs/08-files-review-output/README.html) |
| Annotations: workflow state, edit custody and native output | [Source](designs/08-files-review-output/annotation-operation-map.md) | [Reader](designs/08-files-review-output/annotation-operation-map.html) |
| Annotation output across Host and native client | [Source](designs/08-files-review-output/annotation-output-lifecycle-design.md) | [Reader](designs/08-files-review-output/annotation-output-lifecycle-design.html) |
| Bridge: separate source work from native application | [Source](designs/08-files-review-output/bridge-operation-map.md) | [Reader](designs/08-files-review-output/bridge-operation-map.html) |
| Bridge client data: metadata, content and application | [Source](designs/08-files-review-output/client-read-needs.md) | [Reader](designs/08-files-review-output/client-read-needs.html) |
| Files, reviews, annotations and output: observable contracts | [Source](designs/08-files-review-output/specification.md) | [Reader](designs/08-files-review-output/specification.html) |

## Gateway and CLI

| Document | Markdown | HTML |
| --- | --- | --- |
| DS09 — Gateway, multi-host routing and CLI adapters | [Source](designs/09-gateway-cli/README.md) | [Reader](designs/09-gateway-cli/README.html) |
| Gateway prepared views: the concrete processing boundary | [Source](designs/09-gateway-cli/prepared-view-boundaries.md) | [Reader](designs/09-gateway-cli/prepared-view-boundaries.html) |
| Current CLI entry surface and parser boundaries | [Source](designs/09-gateway-cli/research/cli-entry-surface.md) | [Reader](designs/09-gateway-cli/research/cli-entry-surface.html) |
| Gateway, multi-host routing and CLI adapters: observable contracts | [Source](designs/09-gateway-cli/specification.md) | [Reader](designs/09-gateway-cli/specification.html) |

## Swift and native interaction

| Document | Markdown | HTML |
| --- | --- | --- |
| DS10 — Swift clients, commands and native interaction | [Source](designs/10-swift-client/README.md) | [Reader](designs/10-swift-client/README.html) |
| The 154 commands: current execution and proposed integration | [Source](designs/10-swift-client/command-execution-map.md) | [Reader](designs/10-swift-client/command-execution-map.html) |
| Command identities, native dispatch and backend capability calls | [Source](designs/10-swift-client/command-operation-map.md) | [Reader](designs/10-swift-client/command-operation-map.html) |
| E3 coordination and Swift publication experiment | [Source](designs/10-swift-client/experiments/coordination.md) | [Reader](designs/10-swift-client/experiments/coordination.html) |
| Session, context and native client read needs | [Source](designs/10-swift-client/session-native-read-needs.md) | [Reader](designs/10-swift-client/session-native-read-needs.html) |
| Shared tabs and read state: proposed realization | [Source](designs/10-swift-client/shared-client-state-design.md) | [Reader](designs/10-swift-client/shared-client-state-design.html) |
| Sidebar client data and preparation boundaries | [Source](designs/10-swift-client/sidebar-read-needs.md) | [Reader](designs/10-swift-client/sidebar-read-needs.html) |
| Swift clients, commands and native interaction: observable contracts | [Source](designs/10-swift-client/specification.md) | [Reader](designs/10-swift-client/specification.html) |

## Rust and operational integration

| Document | Markdown | HTML |
| --- | --- | --- |
| DS11 — Rust standards, operation and integrated design | [Source](designs/11-operations-integration/README.md) | [Reader](designs/11-operations-integration/README.html) |
| How each capability gets data and reaches its client | [Source](designs/11-operations-integration/capability-placement-map.md) | [Reader](designs/11-operations-integration/capability-placement-map.html) |
| E5 full-route cost and contention experiment | [Source](designs/11-operations-integration/experiments/route-performance.md) | [Reader](designs/11-operations-integration/experiments/route-performance.html) |
| Smaller branches inside the migration map | [Source](designs/11-operations-integration/migration-detail-branches.md) | [Reader](designs/11-operations-integration/migration-detail-branches.html) |
| Feature-by-feature migration checklist | [Source](designs/11-operations-integration/migration-feature-checklist.md) | [Reader](designs/11-operations-integration/migration-feature-checklist.html) |
| Migrating AgentStudio into the Rust system | [Source](designs/11-operations-integration/migration-map.md) | [Reader](designs/11-operations-integration/migration-map.html) |
| Find a command or operation in the migration | [Source](designs/11-operations-integration/migration-operation-crosswalk.md) | [Reader](designs/11-operations-integration/migration-operation-crosswalk.html) |
| Next migration slice: the remote-session spine | [Source](designs/11-operations-integration/near-term-migration.md) | [Reader](designs/11-operations-integration/near-term-migration.html) |
| Program Design workbench: how AgentStudio can consume the Rust services | [Source](designs/11-operations-integration/program-design-workbench.md) | [Reader](designs/11-operations-integration/program-design-workbench.html) |
| iOS Gateway hosting: evidence and qualification gap | [Source](designs/11-operations-integration/research/ios-gateway-hosting-evidence.md) | [Reader](designs/11-operations-integration/research/ios-gateway-hosting-evidence.html) |
| Codex Router Rust conventions: checked source baseline | [Source](designs/11-operations-integration/research/router-rust-standards.md) | [Reader](designs/11-operations-integration/research/router-rust-standards.html) |
| Rust engineering realization for the Host and Gateway | [Source](designs/11-operations-integration/rust-engineering-design.md) | [Reader](designs/11-operations-integration/rust-engineering-design.html) |
| Rust standards, operation and integrated design: observable contracts | [Source](designs/11-operations-integration/specification.md) | [Reader](designs/11-operations-integration/specification.html) |

## Design sequence

| Document | Markdown | HTML |
| --- | --- | --- |
| AgentStudio daemon: bounded design sequence | [Source](designs/README.md) | [Reader](designs/README.html) |

## Primary experiments

| Document | Markdown | HTML |
| --- | --- | --- |
| Primary experiments for AgentStudio Host and Gateway | [Source](experiments/primary-experiments.md) | [Reader](experiments/primary-experiments.html) |

## Human explainer sources

| Document | Markdown | HTML |
| --- | --- | --- |
| Find an AgentStudio feature | [Source](explainer/feature-migration-guide.md) | [Reader](explainer/features.html) |
| Understand the AgentStudio system | [Source](explainer/system-guide.md) | [Reader](explainer/index.html) |
| Follow real AgentStudio workflows | [Source](explainer/workflow-guide.md) | [Reader](explainer/walkthroughs.html) |

## I0 — Qualify the remote-terminal foundations: documents

| Document | Markdown | HTML |
| --- | --- | --- |
| I0 — Qualify the remote-terminal foundations: documents | [Source](increments/00-qualification/README.md) | [Reader](increments/00-qualification/README.html) |
| Direct Bridge delivery through the Gateway | [Source](increments/00-qualification/bridge-gateway-transport/index.md) | [Reader](increments/00-qualification/bridge-gateway-transport/index.html) |
| Native binding safety: what the compiler check establishes | [Source](increments/00-qualification/bridge-gateway-transport/native-binding-safety.md) | [Reader](increments/00-qualification/bridge-gateway-transport/native-binding-safety.html) |
| Bridge transport owners and interfaces | [Source](increments/00-qualification/bridge-gateway-transport/program-design.md) | [Reader](increments/00-qualification/bridge-gateway-transport/program-design.html) |
| Bridge transport: observable boundary | [Source](increments/00-qualification/bridge-gateway-transport/specification.md) | [Reader](increments/00-qualification/bridge-gateway-transport/specification.html) |
| Bridge transport qualification | [Source](increments/00-qualification/bridge-gateway-transport/verification-design.md) | [Reader](increments/00-qualification/bridge-gateway-transport/verification-design.html) |
| I0 — Qualify the remote-terminal foundations | [Source](increments/00-qualification/specification.md) | [Reader](increments/00-qualification/specification.html) |
| Adopt the newer ZMX in AgentStudio | [Source](increments/00-qualification/zmx-worktree-adoption/index.md) | [Reader](increments/00-qualification/zmx-worktree-adoption/index.html) |
| ZMX adoption: owners, protocol and safe cleanup | [Source](increments/00-qualification/zmx-worktree-adoption/program-design.md) | [Reader](increments/00-qualification/zmx-worktree-adoption/program-design.html) |
| ZMX worktree adoption: observable contract | [Source](increments/00-qualification/zmx-worktree-adoption/specification.md) | [Reader](increments/00-qualification/zmx-worktree-adoption/specification.html) |
| ZMX adoption: how we will prove it | [Source](increments/00-qualification/zmx-worktree-adoption/verification-design.md) | [Reader](increments/00-qualification/zmx-worktree-adoption/verification-design.html) |

## I1 — Remote-terminal MVP integrated into AgentStudio: documents

| Document | Markdown | HTML |
| --- | --- | --- |
| I1 — Remote-terminal MVP integrated into AgentStudio: documents | [Source](increments/01-remote-terminal/README.md) | [Reader](increments/01-remote-terminal/README.html) |
| I1 — Remote-terminal MVP integrated into AgentStudio | [Source](increments/01-remote-terminal/specification.md) | [Reader](increments/01-remote-terminal/specification.html) |

## I2 — Autonomous agents, facts and retained context: documents

| Document | Markdown | HTML |
| --- | --- | --- |
| I2 — Autonomous agents, facts and retained context: documents | [Source](increments/02-agents-context/README.md) | [Reader](increments/02-agents-context/README.html) |
| I2 — Autonomous agents, facts and retained context | [Source](increments/02-agents-context/specification.md) | [Reader](increments/02-agents-context/specification.html) |

## I3 — Remote repository discovery, Git reads and bounded content: documents

| Document | Markdown | HTML |
| --- | --- | --- |
| I3 — Remote repository discovery, Git reads and bounded content: documents | [Source](increments/03-repository-reads/README.md) | [Reader](increments/03-repository-reads/README.html) |
| I3 — Remote repository discovery, Git reads and bounded content | [Source](increments/03-repository-reads/specification.md) | [Reader](increments/03-repository-reads/specification.html) |

## I4 — Git mutations, worktree lifecycle and full Linux fork: documents

| Document | Markdown | HTML |
| --- | --- | --- |
| I4 — Git mutations, worktree lifecycle and full Linux fork: documents | [Source](increments/04-git-worktrees/README.md) | [Reader](increments/04-git-worktrees/README.html) |
| I4 — Git mutations, worktree lifecycle and full Linux fork | [Source](increments/04-git-worktrees/specification.md) | [Reader](increments/04-git-worktrees/specification.html) |

## I5 — Remote reviews, annotations and actual output destinations: documents

| Document | Markdown | HTML |
| --- | --- | --- |
| I5 — Remote reviews, annotations and actual output destinations: documents | [Source](increments/05-review-output/README.md) | [Reader](increments/05-review-output/README.html) |
| I5 — Remote reviews, annotations and actual output destinations | [Source](increments/05-review-output/specification.md) | [Reader](increments/05-review-output/specification.html) |

## I6 — Selected database replication, refill and shared-state experience: documents

| Document | Markdown | HTML |
| --- | --- | --- |
| I6 — Selected database replication, refill and shared-state experience: documents | [Source](increments/06-replication/README.md) | [Reader](increments/06-replication/README.html) |
| I6 — Selected database replication, refill and shared-state experience | [Source](increments/06-replication/specification.md) | [Reader](increments/06-replication/specification.html) |

## I7 — Supported clients, concurrent use and operational profiles: documents

| Document | Markdown | HTML |
| --- | --- | --- |
| I7 — Supported clients, concurrent use and operational profiles: documents | [Source](increments/07-clients-operation/README.md) | [Reader](increments/07-clients-operation/README.html) |
| I7 — Supported clients, concurrent use and operational profiles | [Source](increments/07-clients-operation/specification.md) | [Reader](increments/07-clients-operation/specification.html) |

## Increment sequence

| Document | Markdown | HTML |
| --- | --- | --- |
| Integratable increment specifications | [Source](increments/README.md) | [Reader](increments/README.html) |

## Source research and owner inputs

| Document | Markdown | HTML |
| --- | --- | --- |
| Bridge native/web surface inventory | [Source](research/evidence/2026-10-15-daemon-extraction-survey/bridge-surface-inventory.md) | [Reader](explainer/research/bridge-surface-inventory-b383573f.html) |
| Bridge, annotations and native output capability evidence | [Source](research/evidence/2026-10-15-daemon-extraction-survey/capability-bridge-output-evidence.md) | [Reader](explainer/research/capability-bridge-output-evidence-3424edbe.html) |
| Non-fork Git capability facts — current source | [Source](research/evidence/2026-10-15-daemon-extraction-survey/capability-git-contract-evidence.md) | [Reader](explainer/research/capability-git-contract-evidence-f9adc359.html) |
| Capability transport/API and Rust engineering evidence | [Source](research/evidence/2026-10-15-daemon-extraction-survey/capability-transport-engineering-evidence.md) | [Reader](explainer/research/capability-transport-engineering-evidence-670b1a28.html) |
| Current command surface inventory | [Source](research/evidence/2026-10-15-daemon-extraction-survey/command-surface-inventory.md) | [Reader](explainer/research/command-surface-inventory-4cc8ee5d.html) |
| Application-local agent/context data: current-source evidence | [Source](research/evidence/2026-10-15-daemon-extraction-survey/data-agent-context-evidence.md) | [Reader](explainer/research/data-agent-context-evidence-f65f8515.html) |
| Local client, review and annotation data evidence | [Source](research/evidence/2026-10-15-daemon-extraction-survey/data-client-review-evidence.md) | [Reader](explainer/research/data-client-review-evidence-7d0736f7.html) |
| E1 backend and restoration-cut source evidence | [Source](research/evidence/2026-10-15-daemon-extraction-survey/e1-backend-cut-evidence.md) | [Reader](explainer/research/e1-backend-cut-evidence-077606b9.html) |
| E1 restoration oracle and observation evidence | [Source](research/evidence/2026-10-15-daemon-extraction-survey/e1-oracle-observation-evidence.md) | [Reader](explainer/research/e1-oracle-observation-evidence-ec72d128.html) |
| E2 provider/session/hook admission and revocation evidence | [Source](research/evidence/2026-10-15-daemon-extraction-survey/e2-agent-admission-evidence.md) | [Reader](explainer/research/e2-agent-admission-evidence-4cc6e70a.html) |
| E2 Bridge operation and receipt evidence | [Source](research/evidence/2026-10-15-daemon-extraction-survey/e2-bridge-operation-evidence.md) | [Reader](explainer/research/e2-bridge-operation-evidence-c4f86c9e.html) |
| E2: what each receipt actually establishes | [Source](research/evidence/2026-10-15-daemon-extraction-survey/e2-effect-boundaries.md) | [Reader](explainer/research/e2-effect-boundaries-150b2de8.html) |
| E2 Git operation effects and receipts — desk evidence | [Source](research/evidence/2026-10-15-daemon-extraction-survey/e2-git-operation-evidence.md) | [Reader](explainer/research/e2-git-operation-evidence-3fd041ba.html) |
| E2 renderer-free fact source evidence | [Source](research/evidence/2026-10-15-daemon-extraction-survey/e2-renderer-free-fact-evidence.md) | [Reader](explainer/research/e2-renderer-free-fact-evidence-d1e329ea.html) |
| E3 runtime coordination: current-source evidence | [Source](research/evidence/2026-10-15-daemon-extraction-survey/e3-runtime-flow-evidence.md) | [Reader](explainer/research/e3-runtime-flow-evidence-0dc5416d.html) |
| E3 Swift publication and source-admission evidence | [Source](research/evidence/2026-10-15-daemon-extraction-survey/e3-swift-publication-evidence.md) | [Reader](explainer/research/e3-swift-publication-evidence-2c16dba4.html) |
| E4a authentication evidence: login, logout and credential retirement | [Source](research/evidence/2026-10-15-daemon-extraction-survey/e4-fly-authentication-evidence.md) | [Reader](explainer/research/e4-fly-authentication-evidence-fa957a1f.html) |
| E4 Fly environment evidence | [Source](research/evidence/2026-10-15-daemon-extraction-survey/e4-fly-environment-evidence.md) | [Reader](explainer/research/e4-fly-environment-evidence-2e6b5e98.html) |
| E4a Fly execution-path evidence | [Source](research/evidence/2026-10-15-daemon-extraction-survey/e4-fly-execution-path-evidence.md) | [Reader](explainer/research/e4-fly-execution-path-evidence-f654267a.html) |
| E4 identity and metadata: bounded source evidence | [Source](research/evidence/2026-10-15-daemon-extraction-survey/e4-identity-metadata-evidence.md) | [Reader](explainer/research/e4-identity-metadata-evidence-13729933.html) |
| E4 safe Linux primitives — first discriminator evidence | [Source](research/evidence/2026-10-15-daemon-extraction-survey/e4-safe-linux-primitives-evidence.md) | [Reader](explainer/research/e4-safe-linux-primitives-evidence-b386e700.html) |
| E5 existing latency observations and limits | [Source](research/evidence/2026-10-15-daemon-extraction-survey/e5-latency-observation-evidence.md) | [Reader](explainer/research/e5-latency-observation-evidence-16361763.html) |
| E5 native key-to-echo observation evidence | [Source](research/evidence/2026-10-15-daemon-extraction-survey/e5-native-observation-evidence.md) | [Reader](explainer/research/e5-native-observation-evidence-2fd1eab9.html) |
| E5 transport, admission and completion observations | [Source](research/evidence/2026-10-15-daemon-extraction-survey/e5-transport-observation-evidence.md) | [Reader](explainer/research/e5-transport-observation-evidence-0e442b0d.html) |
| Daemon extraction edge-case inventory | [Source](research/evidence/2026-10-15-daemon-extraction-survey/edge-cases.md) | [Reader](explainer/research/edge-cases-2f28b60e.html) |
| Native versus standalone CLI worktree policy evidence | [Source](research/evidence/2026-10-15-daemon-extraction-survey/fork-app-policy-evidence.md) | [Reader](explainer/research/fork-app-policy-evidence-5f65a90c.html) |
| Pinned fork package contract — bounded source evidence | [Source](research/evidence/2026-10-15-daemon-extraction-survey/fork-package-contract-evidence.md) | [Reader](explainer/research/fork-package-contract-evidence-e337cb41.html) |
| Git experiment coverage — bounded source evidence | [Source](research/evidence/2026-10-15-daemon-extraction-survey/git-experiment-coverage-evidence.md) | [Reader](explainer/research/git-experiment-coverage-evidence-8df62670.html) |
| Mobile socket/lifecycle and network-path evidence | [Source](research/evidence/2026-10-15-daemon-extraction-survey/mobile-network-evidence.md) | [Reader](explainer/research/mobile-network-evidence-f7c1efa0.html) |
| Host parity, bus, client and transport evidence | [Source](research/evidence/2026-10-15-daemon-extraction-survey/second-pass-evidence.md) | [Reader](explainer/research/second-pass-evidence-9168e35c.html) |
| Current surfaces versus primary experiment coverage | [Source](research/evidence/2026-10-15-daemon-extraction-survey/surface-experiment-coverage-evidence.md) | [Reader](explainer/research/surface-experiment-coverage-evidence-2cf2639a.html) |
| Reduced state inventory | [Source](research/evidence/2026-10-16-advisor-storage-placement/R2-reduced-inventory.md) | [Reader](explainer/research/R2-reduced-inventory-9cc55da3.html) |
| Agent/context SQL key inventory | [Source](research/evidence/2026-10-16-daemon-schema-admission/context-key-evidence.md) | [Reader](explainer/research/context-key-evidence-aa2f7acb.html) |
| Core schema key and constraint evidence | [Source](research/evidence/2026-10-16-daemon-schema-admission/core-key-evidence.md) | [Reader](explainer/research/core-key-evidence-2e7d8a7b.html) |
| Review, client, CLI and search declared-key evidence | [Source](research/evidence/2026-10-16-daemon-schema-admission/review-cli-key-evidence.md) | [Reader](explainer/research/review-cli-key-evidence-c36d8da4.html) |
| DS01: current CLI and socket targeting | [Source](research/evidence/2026-10-16-daemon-targeting/research-ledger.md) | [Reader](explainer/research/research-ledger-0ea9b32c.html) |
| Turso replication as an AgentStudio storage option | [Source](research/evidence/2026-10-16-turso-replication-option/research-ledger.md) | [Reader](explainer/research/research-ledger-b35f5f29.html) |
| Annotation query dependencies and transaction boundaries | [Source](research/evidence/2026-10-17-daemon-capability-placement/bridge-query-table-closure.md) | [Reader](explainer/research/bridge-query-table-closure-b8f95acd.html) |
| Current private CLI/admission table closure | [Source](research/evidence/2026-10-17-daemon-capability-placement/cli-private-table-closure.md) | [Reader](explainer/research/cli-private-table-closure-b9ac671e.html) |
| Typed command execution source-map receipt | [Source](research/evidence/2026-10-17-daemon-capability-placement/command-execution-source-map-notes.md) | [Reader](explainer/research/command-execution-source-map-notes-b5e0dd42.html) |
| Current Session/context query table closure | [Source](research/evidence/2026-10-17-daemon-capability-placement/context-query-table-closure.md) | [Reader](explainer/research/context-query-table-closure-826084bd.html) |
| Git and Bridge operation/source reconciliation | [Source](research/evidence/2026-10-17-daemon-capability-placement/git-bridge-operation-source-map-notes.md) | [Reader](explainer/research/git-bridge-operation-source-map-notes-1c78fd1c.html) |
| RPC operation source-map receipt | [Source](research/evidence/2026-10-17-daemon-capability-placement/rpc-operation-source-map-notes.md) | [Reader](explainer/research/rpc-operation-source-map-notes-9530df43.html) |
| Current Sessions, pane-context and native read needs | [Source](research/evidence/2026-10-17-daemon-capability-placement/session-native-read-needs.md) | [Reader](explainer/research/session-native-read-needs-34cd5cb9.html) |
| Sidebar current table and runtime closure | [Source](research/evidence/2026-10-17-daemon-capability-placement/sidebar-query-table-closure.md) | [Reader](explainer/research/sidebar-query-table-closure-503b8163.html) |
| Sidebar current read requirements | [Source](research/evidence/2026-10-17-daemon-capability-placement/sidebar-read-needs.md) | [Reader](explainer/research/sidebar-read-needs-8cb27744.html) |
| Current closure of seven remaining table identities | [Source](research/evidence/2026-10-17-daemon-capability-placement/sidebar-remaining-table-closure.md) | [Reader](explainer/research/sidebar-remaining-table-closure-091dab31.html) |
| Current response, error and event representations | [Source](research/evidence/2026-10-17-daemon-capability-placement/wire-response-representation.md) | [Reader](explainer/research/wire-response-representation-a293d91a.html) |
| Key meanings and ordinary writers after declaration checks | [Source](research/evidence/2026-10-17-fleet-sync-key-semantics/research-ledger.md) | [Reader](explainer/research/research-ledger-a9c46973.html) |
| Current fleet-sync source-form census | [Source](research/evidence/2026-10-17-fleet-sync-schema-forms/research-ledger.md) | [Reader](explainer/research/research-ledger-df76830f.html) |
| Current Sessions/context transaction closures | [Source](research/evidence/2026-10-18-daemon-storage-units/context-transactions.md) | [Reader](explainer/research/context-transactions-5209a0a5.html) |
| Current repository and native storage transaction closures | [Source](research/evidence/2026-10-18-daemon-storage-units/repository-native-transactions.md) | [Reader](explainer/research/repository-native-transactions-11f6d067.html) |
| Current workspace and annotation transaction evidence | [Source](research/evidence/2026-10-18-daemon-storage-units/workspace-annotation-transactions.md) | [Reader](explainer/research/workspace-annotation-transactions-8de1088e.html) |
| EX1 — viewerless interactive-shell establishment at zmx main 0a18bee | [Source](research/evidence/2026-10-20-zmx-latest/EX1-report.md) | [Reader](explainer/research/EX1-report-7b505154.html) |
| EX2a — Capture-to-live protocol cut at zmx 0a18bee | [Source](research/evidence/2026-10-20-zmx-latest/EX2a-report.md) | [Reader](explainer/research/EX2a-report-2461364a.html) |
| EX2c: existing complete-snapshot component tests | [Source](research/evidence/2026-10-20-zmx-latest/EX2c-snapshot-component/report.md) | [Reader](explainer/research/report-d2526250.html) |
| EX5 — zmx leadership versus IP2 at main 0a18bee | [Source](research/evidence/2026-10-20-zmx-latest/EX5-report.md) | [Reader](explainer/research/EX5-report-5cb07634.html) |
| Larger Capture experiment on the newer ZMX | [Source](research/evidence/2026-10-21-daemon-progress/capture-stress-results.md) | [Reader](explainer/research/capture-stress-results-3ed0d442.html) |
| When valid Git data outruns its prerequisite | [Source](research/evidence/2026-10-21-daemon-progress/causality-results.md) | [Reader](explainer/research/causality-results-31f69e29.html) |
| Rust coordination: both candidates passed the finite profile | [Source](research/evidence/2026-10-21-daemon-progress/coordination-results.md) | [Reader](explainer/research/coordination-results-79b2791e.html) |
| First-demand views: catching lost invalidations | [Source](research/evidence/2026-10-21-daemon-progress/demand-results.md) | [Reader](explainer/research/demand-results-d271a95d.html) |
| Scheduled activity: keeping old callbacks out of new state | [Source](research/evidence/2026-10-21-daemon-progress/eligibility-results.md) | [Reader](explainer/research/eligibility-results-90c62d11.html) |
| Quiet work can disappear behind ignored traffic | [Source](research/evidence/2026-10-21-daemon-progress/eventbus-live-results.md) | [Reader](explainer/research/eventbus-live-results-586afb46.html) |
| What the next experiments must cover | [Source](research/evidence/2026-10-21-daemon-progress/remaining-experiments.md) | [Reader](explainer/research/remaining-experiments-730ff28a.html) |
| One canary across the replay and live boundary | [Source](research/evidence/2026-10-21-daemon-progress/replay-handoff-results.md) | [Reader](explainer/research/replay-handoff-results-6abc1fd0.html) |
| AgentStudio daemon extraction survey | [Source](research/extraction-survey.md) | [Reader](research/extraction-survey.html) |
| 01 local sockets and terminal transport | [Source](research/owner-inputs/01-local-sockets-and-terminal-transport.md) | [Reader](research/owner-inputs/01-local-sockets-and-terminal-transport.html) |
| 02 shared typed api and rpc stack | [Source](research/owner-inputs/02-shared-typed-api-and-rpc-stack.md) | [Reader](research/owner-inputs/02-shared-typed-api-and-rpc-stack.html) |
| 03 session connection and subscription lifetimes | [Source](research/owner-inputs/03-session-connection-and-subscription-lifetimes.md) | [Reader](research/owner-inputs/03-session-connection-and-subscription-lifetimes.html) |
| Owner research recovered from the original session | [Source](research/owner-inputs/README.md) | [Reader](research/owner-inputs/README.html) |
| Bridge and remote transport direction | [Source](research/owner-inputs/bridge-transport-direction-2026-10-22.md) | [Reader](research/owner-inputs/bridge-transport-direction-2026-10-22.html) |
| What the supplied research contributes | [Source](research/owner-inputs/disposition.md) | [Reader](research/owner-inputs/disposition.html) |
| Owner-supplied shared replication plan | [Source](research/owner-inputs/fleet-sync-plan-input.md) | [Reader](research/owner-inputs/fleet-sync-plan-input.html) |
| Owner-supplied agent-fleet-sync update — 2026-10-17 | [Source](research/owner-inputs/fleet-sync-update-2026-10-17.md) | [Reader](research/owner-inputs/fleet-sync-update-2026-10-17.html) |
| Owner directions: incremental Rust migration | [Source](research/owner-inputs/migration-directions-2026-10-19.md) | [Reader](research/owner-inputs/migration-directions-2026-10-19.html) |
| Owner request for an MVP and integration explainer | [Source](research/owner-inputs/mvp-and-integration-explainer-request.md) | [Reader](research/owner-inputs/mvp-and-integration-explainer-request.html) |
| Worktree CLI uses the Host daemon | [Source](research/owner-inputs/worktree-cli-host-direction-2026-10-19.md) | [Reader](research/owner-inputs/worktree-cli-host-direction-2026-10-19.html) |
| Owner direction: ZMX restoration and unforked Ghostty | [Source](research/owner-inputs/zmx-restoration-direction-2026-10-21.md) | [Reader](research/owner-inputs/zmx-restoration-direction-2026-10-21.html) |
| Research that travels with this design | [Source](research/retained-evidence.md) | [Reader](research/retained-evidence.html) |
| AgentStudio Host/Gateway topology: reduced risks and open decisions | [Source](research/topology-risks.md) | [Reader](research/topology-risks.html) |
