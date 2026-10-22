# Bridge: separate source work from native application

**The Host supplies file/review data and annotation workflow; the client owns its view and renderer.** The 16 current semantic calls mix those responsibilities. Moving the whole Bridge controller to Rust would also move native publication authority that belongs to a particular client.

The source baseline is AgentStudio `624300332f5e50f7bb8cbb9fc786d5e5b4a3d462`. The [operation evidence map](../../research/evidence/2026-10-17-daemon-capability-placement/git-bridge-operation-source-map.json) and [reconciliation notes](../../research/evidence/2026-10-17-daemon-capability-placement/git-bridge-operation-source-map-notes.md) distinguish newly checked declarations/dispatch from reused same-HEAD effects in the [Bridge operation desk](../../research/evidence/2026-10-15-daemon-extraction-survey/e2-bridge-operation-evidence.md). These are source classifications, not new SQL, native, rendered, restart or Linux observations. **Proposed placement is the Lead's structural proposal, not selected public exposure or a completed Program Design.**

This is the `product.call` semantic layer. The [app RPC map](../01-service-contracts/rpc-operation-map.md) is a different entry layer; [annotation operations](annotation-operation-map.md) are nested under two semantic envelopes here. Seven control variants, five finite-content kinds, content reads and subscriptions also exist outside these 16 names; the [full Bridge surface inventory](../../research/evidence/2026-10-15-daemon-extraction-survey/bridge-surface-inventory.md) remains the broader boundary. These overlapping sets are not additive feature counts.

## Source authority and finite annotation projections

**Proposed path.** Host validates the addressed root/review source and owns annotation SQL reads and semantic projection input. Gateway prepares selected client views and routes bounded content; native/worker consumers retain publication/application authority for their own surface. The source/generation, SQL snapshot and client installation lifetimes must remain explicit across that path.

| Current semantic call | Current acquisition / effect | Receipt and currentness limit |
| --- | --- | --- |
| `file.source.current` · [source](../../../../../Sources/AgentStudio/Features/Bridge/Transport/BridgePaneProductSchemeProvider.swift:315) | Validates the current worktree root and returns File source authority/spec; does not refresh a file catalog. | Source availability/spec or typed root-access error. No refreshed catalog, durable commit, or render completion implied. |
| `file.annotations.projection.query` · [source](../../../../../Sources/AgentStudio/Features/Bridge/Transport/BridgePaneProductSchemeProvider.swift:284) | Captures coherent SQL snapshot and current File placement material, reserves query-scoped paged finite content. | Content descriptor or typed sourceStale(currentSourceGeneration); worker/session/derivation/query-lifetime bound. Not mutation/render receipt. |
| `review.annotations.projection.query` · [source](../../../../../Sources/AgentStudio/Features/Bridge/Transport/BridgePaneProductSchemeProvider.swift:284) | Captures coherent SQL snapshot and retained Review placement material, reserves query-scoped paged finite content. | Same snapshot/page evidence plus retained Review publication authority. |

**Boundary to finish.** DS08/DS02 must bind coherent snapshot/currentness, content/range/lease bounds, scoped export and worker cancellation. A projection query is not a persisted source.refresh command, and file.source.current is not a completed file-catalog refresh.

## Annotation command envelopes and immutable attempt inspection

**Proposed path.** The Host annotation workflow owns operation-specific transactions and immutable output-attempt bytes. Gateway routes typed requests and prepares permitted history/detail. A declared native destination executes only at its actual client/machine owner, then reports that effect for Host finalization. The enclosing Review context and nested workflow operation are separate admission layers.

| Current semantic call | Current acquisition / effect | Receipt and currentness limit |
| --- | --- | --- |
| `file.annotations.command` · [source](../../../../../Sources/AgentStudio/Features/Bridge/Transport/BridgePaneProductSchemeProvider.swift:294) | Nested operation selects SQL read/mutation, runtime demand/edit authority, or native output; handler is awaited before generic control completion. | Seven editing operations return canonical message/removal receipts; viewed/output/history operations have distinct payloads; others return bounded status/session. Not a uniform durable mutation. |
| `review.annotations.command` · [source](../../../../../Sources/AgentStudio/Features/Bridge/Transport/BridgePaneProductSchemeProvider.swift:356) | Same nested operation classes, with current Review publication source-generation resolution before dispatch. | Same operation-specific receipts plus Review publication currentness. Even a historical nested read can fail first because its Review context is unavailable. |
| `file.annotations.output.inspect` · [source](../../../../../Sources/AgentStudio/Features/Bridge/Transport/BridgePaneProductSchemeProvider.swift:308) | Rereads immutable prepared-attempt bytes/metadata and issues a surface-bound content descriptor; does not perform clipboard/file output. | Exact bytes/hash/length and surface; not a report that clipboard/file output succeeded. Attempt/history state is separate. |
| `review.annotations.output.inspect` · [source](../../../../../Sources/AgentStudio/Features/Bridge/Transport/BridgePaneProductSchemeProvider.swift:308) | Same SQL attempt read with Review surface descriptor; this dispatch arm does not add Review source-generation validation. | Same immutable-byte evidence; no additional Review source-generation check in this arm. |

**Boundary to finish.** Use the separate 22-operation map below for SQL, demand, edit and output differences. DS08/DS03 must define source context, caller/edit authority, native destination custody, history permissions and partial/unknown outcomes. Immutable-byte inspection does not execute output.

## Refresh and comparison intent

**Proposed path.** Host acquires real file/Git comparison inputs; Gateway prepares selected catalogs/results. The native client owns its requested pane comparison, selection and installation. Bind refresh/build intent to the correct Host source and client consumer without moving native presentation state into shared Host truth.

| Current semantic call | Current acquisition / effect | Receipt and currentness limit |
| --- | --- | --- |
| `file.refresh.retry` · [source](../../../../../Sources/AgentStudio/Features/Bridge/Transport/BridgePaneProductSchemeProvider+CommittedEffects.swift:160) | Marker response precedes committed retry effect; retry admission/scheduling differs from eventual refresh/publication completion. | Later source/publication outcomes; payload has no completed-refresh result and proves neither start nor render. |
| `review.comparison.update` · [source](../../../../../Sources/AgentStudio/Features/Bridge/Transport/BridgePaneProductSchemeProvider+CommittedEffects.swift:169) | Changes canonical pane comparison/source, generations and construction/publication intent under current Review intent admission. | Current target/attempt/publication corroborate state. Callback disposition is discarded; call is not an awaited SQLite durability or completed-build receipt. |
| `review.comparisonTargets.query` · [source](../../../../../Sources/AgentStudio/Features/Bridge/Transport/BridgePaneProductSchemeProvider.swift:373) | Authorizes current foreground target and worker, reserves descriptor; finite catalog production/consumption is a separate step. | Request-scoped reservation and finite catalog content. Reservation consumed once; descriptor is not successful delivery. |

**Boundary to finish.** DS08/DS10 must specify intent/source generations, invalidation, result currency and cancellation. Catalog reservation, scheduled refresh, completed construction and applied publication are distinct. The current marker/callback result is not a stronger durable or rendered receipt.

## Viewer demand, intake and publication application

**Proposed path.** Native/worker consumers report their real visibility, intake and publication application; Gateway aggregates declared interests and requests Host source work as needed. Host domain acquisition can depend on that interest without depending on the Mac for required autonomous facts. Native publication admission and display application stay client-scoped unless a separate shared state is explicitly selected.

| Current semantic call | Current acquisition / effect | Receipt and currentness limit |
| --- | --- | --- |
| `file.activeViewerMode.update` · [source](../../../../../Sources/AgentStudio/Features/Bridge/Transport/BridgePaneProductSchemeProvider+CommittedEffects.swift:163) | Records accepted session/sequence/source viewer signal, can settle selection acknowledgement and fence hidden Review work. | Current accepted signal and optional correlated selection receipt. Stale sequence/source can be ignored while generic call completes. No persistence/render receipt. |
| `review.activeViewerMode.update` · [source](../../../../../Sources/AgentStudio/Features/Bridge/Transport/BridgePaneProductSchemeProvider+CommittedEffects.swift:163) | Records accepted Review viewer signal and can schedule initial, retained or catch-up construction. | Accepted signal is separate from eventual build/publication/render. |
| `review.intake.ready` · [source](../../../../../Sources/AgentStudio/Features/Bridge/Transport/BridgePaneProductSchemeProvider+CommittedEffects.swift:179) | Stream-aware intake can select initial construction, resync, or replay current publication; readiness marker is not completed build. | Stream/package/publication outcomes; no completed-build receipt. Can deliberately cause no new build. |
| `review.publication.install.admit` · [source](../../../../../Sources/AgentStudio/Features/Bridge/Transport/BridgePaneProductSchemeProvider.swift:336) | Changes display-install authority while provider builds response and returns typed admitted/rejected. | Typed admission and retained coordinator state. Not application, DOM, or durability. Generic operation flag says non-mutation despite runtime-authority change. |
| `review.publication.applied` · [source](../../../../../Sources/AgentStudio/Features/Bridge/Transport/BridgePaneProductSchemeProvider+CommittedEffects.swift:181) | Records worker/publication application and can retire older content authority; advanced/duplicate/rejected disposition is discarded. | Displayed-publication state corroborates result. Marker does not distinguish those dispositions or independently verify DOM/pixels. |
| `review.markFileViewed` · [source](../../../../../Sources/AgentStudio/Features/Bridge/Transport/BridgePaneProductSchemeProvider+CommittedEffects.swift:177) | Inserts item into native in-memory viewed set under admission; not annotation message-viewed SQL. | In-memory mutation; no storage or saved-revision receipt. Targeted search found writer/declarations but no further native-set reader in Bridge Swift/BridgeWeb. Wired mutation exists; broader downstream effect unestablished. |

**Boundary to finish.** DS08/DS10 must define per-client sequences, hidden-view contraction, replacement generations and truthful application receipts. Current review.markFileViewed changes a native set and is distinct from persisted annotation message.viewed.mark. Product-session mutation flags are uncertainty/capacity policy, not an effect or storage taxonomy.

## Integration boundary

I3 can integrate finite repository/file/review reads without pretending the whole review workflow is complete. I5 adds selected annotation/output behavior and its native effect/finalization path. Each increment must bind its actual source and content/currentness contract; successful decoding, generic Bridge completion, worker application and rendered pixels remain separate observations. All 16 current names occur once here. Actual service extraction, schema compatibility and native/render proof remain unobserved.
