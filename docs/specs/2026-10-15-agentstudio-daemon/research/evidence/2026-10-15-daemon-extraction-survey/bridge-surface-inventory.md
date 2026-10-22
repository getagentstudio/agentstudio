# Bridge native/web surface inventory

Source-only at AgentStudio `624300332f5e50f7bb8cbb9fc786d5e5b4a3d462`. This expands the earlier Bridge family survey into its complete named top-level vocabulary. Counts describe declarations/source-text consistency, not executed successful features or a new public Host API. These names are separate from the57 app RPC names and154 AppCommand identities; adding the counts would misstate product capability count.

## Control variants

The exhaustive [control request](../../../../../../Sources/AgentStudio/Features/Bridge/Models/Transport/BridgeProductControlRequest.swift:6) has7 variants:

| Variant | Wire kind |
| --- | --- |
| Worker session open | `workerSession.open` |
| Semantic product call | `product.call` |
| Subscribe | `subscription.open` |
| Cancel subscription | `subscription.cancel` |
| Change view scope | `subscription.setScope` |
| Resnapshot a view | `subscription.resnapshot` |
| Worker session resync | `workerSession.resync` |

Correlation includes pane session, worker instance, request ID and request sequence, with derivation/scope/currentness fields depending on the variant. Subscription cancel is explicitly a slot-free escape. These are not equivalent to terminal sessions or a durable remote event cursor.

## Semantic calls

The [semantic enum and method projection](../../../../../../Sources/AgentStudio/Features/Bridge/Models/Transport/BridgeProductCallContracts.swift:461) have16 variants; source-text extraction compared case and method-projection identity sets for equality.

| Family | Complete methods |
| --- | --- |
| File annotation | `file.annotations.command`, `file.annotations.output.inspect`, `file.annotations.projection.query` |
| File source/refresh/viewer | `file.source.current`, `file.refresh.retry`, `file.activeViewerMode.update` |
| Review viewer/comparison | `review.activeViewerMode.update`, `review.comparison.update`, `review.comparisonTargets.query` |
| Review intake/viewed/publication | `review.intake.ready`, `review.markFileViewed`, `review.publication.install.admit`, `review.publication.applied` |
| Review annotation | `review.annotations.command`, `review.annotations.output.inspect`, `review.annotations.projection.query` |

All16 were followed through the provider switch, including combined arms. Annotation projection/commands require product admission; comparison-target query additionally acquires current authorization/reservation and checks worker identity. Install admission returns an admitted/rejected outcome. Some response cases defer their actual effects to the committed-effect path; a response-returning switch arm alone must not be classified as a no-op or completed native effect.

Sources: [provider response](../../../../../../Sources/AgentStudio/Features/Bridge/Transport/BridgePaneProductSchemeProvider.swift:278), [comparison reservation](../../../../../../Sources/AgentStudio/Features/Bridge/Transport/BridgePaneProductSchemeProvider.swift:380), [committed effects](../../../../../../Sources/AgentStudio/Features/Bridge/Transport/BridgePaneProductSchemeProvider+CommittedEffects.swift:142), [native committed-call target](../../../../../../Sources/AgentStudio/Features/Bridge/Runtime/BridgePaneController+Bootstrap.swift:57).

## Annotation operations

The [annotation operation union](../../../../../../Sources/AgentStudio/Features/Bridge/Models/Transport/BridgeProductWorktreeAnnotationOperationContracts.swift:3) has22 cases. Source-text extraction compared its cases with the tagged `Kind` identity set for equality. They are nested inside the File/Review annotation command calls, not22 additional app RPC methods.

| Responsibility | Complete wire operation kinds |
| --- | --- |
| Discover/demand | `session.discover`, `demand.acquire`, `demand.release` |
| Message creation | `root.create`, `reply.create` |
| Draft/editor authority | `draft.flush`, `draft.edit.acquire`, `draft.edit.release`, `draft.save`, `draft.revert` |
| Thread/session lifecycle | `thread.resolution.set`, `session.lifecycle.set`, `continuity.choose`, `source.refresh` |
| Output preparation/effects/history | `output.scope.commit`, `output.preference.changeFolder`, `output.reveal`, `output.handled.clear`, `output.history`, `output.repeat` |
| Observation/recovery | `message.viewed.mark`, `recovery.acknowledge` |

Requests carry revision/edit/source/admission constraints according to the operation. Example: output-scope commit validates that JSON-file export has a destination while clipboard Markdown does not. This does not make either effect safe on an arbitrary machine or establish that destination selection is a Host operation. Exact edit tokens, current revisions, prepared-output/finalization and partial/unknown results remain contract requirements to preserve.

## Finite content and metadata delivery

The separate [content kind union](../../../../../../Sources/AgentStudio/Features/Bridge/Models/Transport/BridgeProductContentContracts.swift:4) has5 kinds: `annotation.output`, `annotation.projection`, `file.content`, `review.content`, `review.comparisonTargets`. File descriptors include declared length/expected hash/maximum byte/window/source data; content admission has lease/worker/session/correlation identities. These finite reads are not the same as the metadata subscription stream or an annotation mutation result.

View scope/resnapshot/receipt acknowledgements have their own [scope/incarnation/revision/delivery-sequence contracts](../../../../../../Sources/AgentStudio/Features/Bridge/Models/Transport/BridgeProductViewControlWireContract.swift:240). Source/schema validation, transport receipt credit, domain operation settlement, accepted native application and post-render fulfillment must remain distinct in the extraction.

## Admission and effect ordering observed

1. [Scheme ingress](../../../../../../Sources/AgentStudio/Features/Bridge/Transport/BridgeSchemeHandler+RPC.swift:21) requires a capability, claims an active adapter, distinguishes401/403/409/503 admission results, and owns transport-claim cleanup through cancellation/termination.
2. [Control dispatcher](../../../../../../Sources/AgentStudio/Features/Bridge/Transport/BridgeProductSchemeControlDispatcher.swift:104) admits the operation and checks current product admission around provider response construction.
3. [Completion](../../../../../../Sources/AgentStudio/Features/Bridge/Transport/BridgeProductSchemeControlDispatcher.swift:157) encodes exact response bytes, asks the session to complete control, applies the resulting committed effect, rechecks admission, then settles the operation. Unknown settlement is a separate path.
4. [Committed-effect application](../../../../../../Sources/AgentStudio/Features/Bridge/Transport/BridgePaneProductSchemeProvider+CommittedEffects.swift:142) invokes refresh/viewer/comparison/viewed/intake/publication effects after its validity checks; metadata coordinator handles other effects.

These are in-process protocol/session facts, not a claim that every step commits durable storage. Cross-process extraction must state what each acknowledgement means instead of compressing the path into one generic “success.” Existing receiver/render evidence is covered in `second-pass-evidence.md`; nothing was executed here.

## Proof and open placement

No code, config, transport schema, UI or runtime was changed. No tests/builds were run. The inventory is grounded in current declaration/dispatch/effect sources and does not establish all downstream effects, Linux support or remote behavior. A guessed `CommittedControl` filename was absent; `rg` located the actual `CommittedEffects` owner, which was read. It is not a missing-feature finding.

The mandatory future frontend route remains client→socket→Gateway→Host. This Bridge catalog supplies capability/currentness/receipt distinctions for later allocation; it does not decide that a WebKit capability is a Host credential or that every native/viewer method must run on the Host. Phone Gateway placement remains the one pending owner brief; this inventory does not depend on its answer.
