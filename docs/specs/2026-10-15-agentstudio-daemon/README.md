# AgentStudio daemon design

Open the [HTML system guide](explainer/index.html), [complete feature tree](explainer/features.html), or [concept-led walkthroughs](explainer/walkthroughs.html). The walkthrough player carries one explanation across the system, feature, contract and integration pages. The current roles are Host daemon (macOS/Linux), Gateway (macOS/iOS) and UX client. The [MVP and delivery sequence](explainer/delivery.html) proposes usable cuts through that full design; [all documents](documents.md) remain linked. Every Markdown document has a same-folder HTML reader; the Markdown remains the editable source.

For source work, start with the [design-set entry and reading paths](index.md), then the [bounded design sequence](designs/README.md). It separates the large extraction surface into eleven designs, with explicit contract inputs and one home for each capability family.

The [shared-library integration picture](designs/02-data-ownership-replication/research/fleet-sync-consumer-fit.md) explains Host writes, Gateway copies, central lease control and optional durable delivery using the newer six-PR `agent-fleet-sync` implementation baseline.

The [capability acquisition and placement map](designs/11-operations-integration/capability-placement-map.md) follows all eighteen source families from acquisition to client. Its operation index opens the 57 app RPC methods, 44 Git SDK requirements, 16 Bridge calls, 22 annotation kinds and the separate 154 command identities. It distinguishes checked current sources from proposed placement and remaining contracts.

- [Requirements](user-requirements.md): authorized outcomes, constraints and owner sources.
- [Observable Specification](2026-10-15-agentstudio-daemon.md): shared entities, obligations and exact unresolved contracts.
- [Capability catalog](capability-contracts.md): all eighteen surveyed families, shared operation semantics and links to the fifteen scoped capability contracts.
- [Domain definitions](domain-entities.md): stable resource and identity meanings shared by every design.

The individual designs carry their own scope, evidence, questions and proof boundaries. Program Designs are authored when their required contracts are settled; folders and carried-forward draft specifications do not imply design readiness. This work remains design-only.

The current design completion contract has four distinct artifacts: Requirements, Specification, Program Design and Verification Design, followed by their independent review. A proof seam in Program Design or an experiment proposal does not replace Verification Design's requirement-by-requirement proof strategy. No empty downstream document stands in for unfinished design.
