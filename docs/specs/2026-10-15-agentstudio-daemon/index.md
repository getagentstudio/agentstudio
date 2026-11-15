# AgentStudio daemon: design-set entry

For a visual introduction, open the [system guide](explainer/index.html), [feature hierarchy](explainer/features.html) or [guided walkthroughs](explainer/walkthroughs.html). For source work, follow the document identities below. This index supplies navigation; it adds no requirements or architecture decisions.

For actual execution status, open [what was built and tried](explainer/progress.html). It separates Lead work, Advisor experiments and unbuilt product systems; historical evidence does not supply current implementation readiness.

The [2026-11-01 boundary walkthrough](research/2026-11-01-system-boundaries/index.html) connects Host, Gateway, provider execution, task control and messaging responsibilities. Its [native experiment](research/2026-11-01-system-boundaries/experiments.html) records a passing requester-loss primitive with retained observer custody. This research supplement also carries the newer owner decisions on planned-upgrade continuity and optional board linkage; the remaining structural contracts and full Host-upgrade proof are open.

## The four design documents

| Document | Authoritative entry | Current boundary |
| --- | --- | --- |
| Requirements | [User requirements](user-requirements.md) | Authorized outcomes, source decisions and explicit open meaning |
| Specification | [Observable spine](2026-10-15-agentstudio-daemon.md), its linked [domain definitions](domain-entities.md), [initial profile](initial-profile.md) and [capability catalog](capability-contracts.md) | Shared obligations plus the linked domain contracts; folders do not imply readiness |
| Program Design | [Integrated workbench](designs/11-operations-integration/program-design-workbench.md) and its linked structural companions | Current proposal and concrete remaining structural gaps; not a completed four-document design |
| Verification Design | Not yet authored | Existing proof obligations, proof seams and experiment procedures are inputs. They do not replace the separate requirement-by-requirement Verification Design |

## Reading paths

- **Follow direct browser delivery:** [Bridge transport entry](increments/00-qualification/bridge-gateway-transport/index.md) → its separate Specification, Program Design and Verification Design, using the existing Requirements. This is the S32 transport refinement; it does not replace the whole-system design.


- **Migrate the existing product:** [whole migration map](designs/11-operations-integration/migration-map.md) → [hierarchical feature checklist](designs/11-operations-integration/migration-feature-checklist.md) → [every recorded operation](designs/11-operations-integration/migration-operation-crosswalk.md) → [detailed near-term slice](designs/11-operations-integration/near-term-migration.md).

- **Understand the system:** [system guide source](explainer/system-guide.md) → [Requirements](user-requirements.md) → [Specification](2026-10-15-agentstudio-daemon.md) → [integrated Program Design](designs/11-operations-integration/program-design-workbench.md).
- **Find a product feature:** [feature guide](explainer/feature-migration-guide.md) → [complete capability placement](designs/11-operations-integration/capability-placement-map.md) → its owning folder in the [eleven-design sequence](designs/README.md).
- **Follow incoming data:** [workflow guide](explainer/workflow-guide.md) → [source admission and processing](designs/02-data-ownership-replication/research/typed-input-processing.md) → [Gateway preparation](designs/09-gateway-cli/prepared-view-boundaries.md) → [one concrete context-count family](designs/07-agents-context/context-count-preparation.md) → [native read needs](designs/10-swift-client/session-native-read-needs.md).
- **Understand stored state:** [data ownership contract](designs/02-data-ownership-replication/specification.md) → [storage placement and transaction design](designs/02-data-ownership-replication/storage-placement-design.md) → [every table/column disposition](designs/02-data-ownership-replication/storage-placement-matrix.md) → [replication integration](designs/02-data-ownership-replication/research/fleet-sync-consumer-fit.md) → [query dependencies](designs/02-data-ownership-replication/research/query-data-dependencies.md) → [shared-client-state proposal](designs/10-swift-client/shared-client-state-design.md).
- **Plan a usable integration slice:** [delivery overview](explainer/delivery.html) → the selected [increment folder](increments/README.md) → its referenced domain contracts. The proposed sequence does not authorize product implementation.
- **Evaluate feasibility:** [primary experiments](experiments/primary-experiments.md) → the linked procedure and its exact proof limit. The [iOS hosting note](designs/11-operations-integration/research/ios-gateway-hosting-evidence.md) separates current evidence from unqualified mobile behavior.

The **Where stored state lives** walkthrough follows the new storage-placement chapters, actual transaction examples and full matrix with continuous Next/Previous narration.

The [complete document index](documents.md) includes each source file and its HTML reader. The [walkthrough declarations](explainer/walkthrough-paths.json) carry a concept-led route across existing content; source documents retain the meaning at each stop.
