# Bridge client data: metadata, content and application

**The Gateway read contract must start from what the consumer needs to display and apply.** Current Bridge reads include metadata projections, issued descriptors, finite byte content and client publication state. Their names do not give them one storage or completion guarantee.

This source catalog records seven bounded current read families at AgentStudio `624300332f5e50f7bb8cbb9fc786d5e5b4a3d462`, including all five declared finite-content kinds. It is evidence for DS08/DS10, not a selected target DTO/schema, export list, complete Bridge UI census or accepted Program Design. Deciding declarations/production functions were read; the earlier annotation query's deeper SQL/source analysis is reused explicitly at the same HEAD. No runtime, native rendering, socket, target service or performance proof is claimed. The [source rows](../../research/evidence/2026-10-17-daemon-capability-placement/bridge-read-needs.json) retain the evidence boundary.

The [16 semantic calls](bridge-operation-map.md) and [22 nested annotation operations](annotation-operation-map.md) own the corresponding entry/effect inventory. These read families overlap those layers and are not additional features.

Field names below follow the current Swift declarations. Encoders can add literal discriminants or use different wire keys; nested shapes and validation remain in their source contracts. This catalog is not a second hand-maintained wire schema. Current optional-field layouts are evidence to interpret, not automatically the target Rust/Swift type design.

## Current data and acquisition

### File metadata rows

Current types: `BridgeProductFileTreeRow`.

- **Fields:** `changeStatus`, `depth`, `fileId`, `fileClass`, `isDirectory`, `lineCount`, `name`, `parentPath`, `path`, `rowId`, `sizeBytes`.
- **Acquisition:** Installed File subscription emits accepted source, acquires shared construction, prepares optional Git status and enumerates initial tree. Product row encoding maps the current native tree row and chunks by encoded-byte/member bounds.
- **Currentness:** Subscription/product-source/admission and construction lifetime are distinct from a displayed row. This pass did not retrace every incremental/deferred file update.
- **Read-side state/effect:** Opening source metadata installs context and acquires construction custody; not a pure durable-row query.
- **Storage meaning:** Current live source/manifest/projection data; not proof that file bytes or row catalog are retained in SQL.

Sources: [source 1](../../../../../Sources/AgentStudio/Features/Bridge/Models/Transport/BridgeProductFileMetadataValueContracts.swift:14), [source 2](../../../../../Sources/AgentStudio/Features/Bridge/Transport/BridgePaneProductFileMetadataEncoding.swift:29), [source 3](../../../../../Sources/AgentStudio/Features/Bridge/Transport/BridgePaneProductFileMetadataSource+InitialEnumeration.swift:8).

### Review package metadata

Current types: `IPCBridgeReviewPackageResult`.

- **Fields:** `paneId`, `status`, `error`, `selectedItemId`, `packageId`, `reviewGeneration`, `revision`, `summary`, `comparisonOrigin`, `reviewedSubjectLabel`, `items`.
- **Acquisition:** Current IPC controller projects paneState.diff.packageMetadata/status/error, native selection and item summaries; validates response budget.
- **Currentness:** Current native publication/package/generation/selection, not source file bytes, DOM or new Git capture.
- **Read-side state/effect:** This inspected projection reads current state; surrounding mounted-controller admission remains required.
- **Storage meaning:** Live native product projection; no retained exported table is established by this DTO.

Sources: [source 1](../../../../../Sources/AgentStudioProgrammaticControl/IPCBridgeContracts.swift:112), [source 2](../../../../../Sources/AgentStudio/Features/Bridge/Runtime/BridgePaneController+IPCProjection.swift:74).

### File content

Current types: `BridgeProductFileContentDescriptor`, `BridgeProductFileContentWindow`. Finite-content kind: `file.content`.

- **Fields:** `declaredByteLength`, `descriptorId`, `expectedSha256`, `fileId`, `maximumBytes`, `source`, `window(maximumBytes,maximumLines;prefix startByte0)`.
- **Acquisition:** Descriptor must match an issued manifest read plan under matching product/source admission. Factory opens a validated contained regular file; streaming closes the reader on completion/cancellation/error and checks observed byte count/hash before terminal end.
- **Currentness:** Issued source/descriptor, current work admission and actual file bytes; opening/descriptor acceptance is separate from complete content. Current File validation requires declared length, request maximum and window maximum to match. Its prefix window is not a promise of arbitrary ranged-file reads. [Validation](../../../../../Sources/AgentStudio/Features/Bridge/Models/Transport/BridgeProductContentContracts.swift:278).
- **Read-side state/effect:** Runtime issued-descriptor/read-plan lookup and content lease/reader lifecycle; no file write selected.
- **Storage meaning:** Finite filesystem content; does not become replicated SQL by being transferred.

Sources: [source 1](../../../../../Sources/AgentStudio/Features/Bridge/Models/Transport/BridgeProductContentContracts.swift:210), [source 2](../../../../../Sources/AgentStudio/Features/Bridge/Models/Transport/BridgeProductContentContracts.swift:135), [source 3](../../../../../Sources/AgentStudio/Features/Bridge/Transport/BridgePaneProductFileMetadataSource+ContentReadPlan.swift:22), [source 4](../../../../../Sources/AgentStudio/Features/Bridge/Transport/BridgePaneProductFileContentSource.swift:90), [source 5](../../../../../Sources/AgentStudio/Features/Bridge/Transport/BridgePaneProductSchemeProvider.swift:807).

### Review content

Current types: `BridgeProductReviewContentSourceDescriptor`, `BridgeProductReviewContentDescriptor`, `BridgeProductReviewContentWindow`. Finite-content kind: `review.content`.

- **Fields:** `contentDigest`, `descriptorId`, `encoding`, `endpointId`, `handleId`, `isBinary`, `itemId`, `language`, `mimeType`, `packageId`, `reviewGeneration`, `role`, `sourceIdentity`, `wholeByteLength`, `declaredByteLength`, `expectedSha256`, `maximumBytes`, `window(startByte,maximumBytes)`.
- **Acquisition:** Acquire matching content authority lease; load observed range from current loader cache; compare handle and any declared range/hash/whole-length witnesses; settle content lease. Provider sends qualified buffered range with end-of-source disposition.
- **Currentness:** Package/item/handle/source/generation and range identity; metadata-only getContent does not supply these bytes or prove rendered application.
- **Read-side state/effect:** Content authority leases and loader/cache lifecycle; not durable effect execution.
- **Storage meaning:** Current backing content/ranges behind retained product authority; actual storage lifetime is source-specific, not generic SQL replication.

Sources: [source 1](../../../../../Sources/AgentStudio/Features/Bridge/Models/Transport/BridgeProductReviewContentContracts.swift:90), [source 2](../../../../../Sources/AgentStudio/Features/Bridge/Models/Transport/BridgeProductReviewContentContracts.swift:240), [source 3](../../../../../Sources/AgentStudio/Features/Bridge/Models/Transport/BridgeProductReviewContentContracts.swift:293), [source 4](../../../../../Sources/AgentStudio/Features/Bridge/Transport/BridgePaneProductReviewContentSource.swift:91), [source 5](../../../../../Sources/AgentStudio/Features/Bridge/Transport/BridgePaneProductSchemeProvider.swift:745).

### Annotation projection page

Current types: `BridgeProductAnnotationProjectionContentDescriptor`, `BridgeProductAnnotationProjectionPageContract`. Finite-content kind: `annotation.projection`.

- **Fields:** `descriptorID`, `maximumBytes`, `page`, `surface`.
- **Acquisition:** Prior same-HEAD query walk supplies SQL/source analysis and query reservation. The freshly inspected claim consumes a matching descriptor/authority reservation and permits continuation for a nonfinal page; producer streams the reserved page and emits terminal byte-count/hash facts.
- **Currentness:** Query snapshot, source/publication generation, worker/session/derivation and page lifetime; descriptor alone is not current rendered comments.
- **Read-side state/effect:** Query/page reservation and one-use claim; no automatic output effect.
- **Storage meaning:** SQL workflow/source-derived finite projection; runtime reservations are not retained workflow rows.

Sources: [source 1](../../../../../Sources/AgentStudio/Features/Bridge/Models/Transport/BridgeProductWorktreeAnnotationProjectionQueryContracts.swift:333), [source 2](../../../../../Sources/AgentStudio/Features/Bridge/Transport/WorktreeAnnotations/BridgePaneProductWorktreeAnnotationProjectionSource.swift:236), [source 3](../../../../../Sources/AgentStudio/Features/Bridge/Transport/WorktreeAnnotations/BridgePaneProductWorktreeAnnotationProjectionSource.swift:260), [source 4](../../../../../Sources/AgentStudio/Features/Bridge/Transport/WorktreeAnnotations/BridgePaneProductSchemeProvider+AnnotationProjection.swift:79), [source 5](../../../../../BridgeWeb/src/core/comm-worker/bridge-comm-worker-annotation-projection-query-controller.ts:90).

### Annotation output bytes

Current types: `BridgeProductAnnotationOutputContentDescriptor`. Finite-content kind: `annotation.output`.

- **Fields:** `attemptID`, `contentType`, `declaredByteLength`, `descriptorID`, `expectedSHA256`, `formatVersion`, `maximumBytes`, `outputKind`, `surface`.
- **Acquisition:** Descriptor and body each inspect the immutable SQL attempt. Body consumes a matching issued descriptor, rereads the attempt, reconstructs/compares descriptor and returns exact prepared bytes/hash; producer transfers buffered content.
- **Currentness:** Attempt identity and immutable bytes/metadata, separately from destination effect and SQL finalization outcome.
- **Read-side state/effect:** Bounded issued-descriptor registration/one-use removal; inspecting/transferring bytes does not execute clipboard/file output.
- **Storage meaning:** Exact attempt bytes are current workflow SQL state; export/history selection still belongs to the target contract.

Sources: [source 1](../../../../../Sources/AgentStudio/Features/Bridge/Models/Transport/BridgeProductWorktreeAnnotationOutputContentContracts.swift:36), [source 2](../../../../../Sources/AgentStudio/Features/Bridge/Transport/WorktreeAnnotations/BridgePaneProductWorktreeAnnotationOutputSource.swift:28), [source 3](../../../../../Sources/AgentStudio/Features/Bridge/Transport/WorktreeAnnotations/BridgePaneProductWorktreeAnnotationOutputSource.swift:45), [source 4](../../../../../Sources/AgentStudio/Features/Bridge/Transport/BridgePaneProductSchemeProvider.swift:782).

### Review comparison target catalog

Current types: `BridgeProductReviewComparisonTargetsContentDescriptor`, `BridgeReviewComparisonTargetProducedCatalog`. Finite-content kind: `review.comparisonTargets`.

- **Fields:** `descriptorId`, `maximumBytes`, `body`, `sha256`, `rowCount`, `isTruncated`.
- **Acquisition:** Current authorized query reservation is claimed once; producer captures comparison targets through real reviewSourceProvider with capture/cutoff/max-row inputs, encodes bounded catalog and transfers it with qualified delivery disposition.
- **Currentness:** Request/reservation and current target/source observations with explicit truncation; catalog is not an atomic immutable refs snapshot or native selection application.
- **Read-side state/effect:** Consumes runtime reservation and performs real source acquisition; no Git mutation selected by this catalog read.
- **Storage meaning:** Finite generated catalog, not proof of a retained target table.

Sources: [source 1](../../../../../Sources/AgentStudio/Features/Bridge/Models/Transport/BridgeProductContentContracts.swift:13), [source 2](../../../../../Sources/AgentStudio/Features/Bridge/Transport/BridgePaneProductSchemeProvider+ComparisonTargetContent.swift:26), [source 3](../../../../../Sources/AgentStudio/Features/Bridge/Transport/BridgeReviewComparisonTargetCatalogProducer.swift:6), [source 4](../../../../../Sources/AgentStudio/Features/Bridge/Transport/BridgeReviewComparisonTargetCatalogProducer.swift:45), [source 5](../../../../../Sources/AgentStudio/Features/Bridge/Transport/BridgePaneProductSchemeProvider+ComparisonTargetProducer.swift:10).

## The transfer context is separate from the displayed value

Current content admission carries content kind/request identity, optional declared length/hash, exact content identity, lease and correlation, maximum bytes, pane session, wire version, worker derivation epoch and worker instance. These are different scopes. [Admission shape](../../../../../Sources/AgentStudio/Features/Bridge/Models/Transport/BridgeProductContentContracts.swift:533).

The inspected producer waits for the opening content-frame acknowledgement before selecting the concrete content producer, then rechecks admission. This is protocol progress, separate from final byte verification, worker application and visible pixels. [Producer handoff](../../../../../Sources/AgentStudio/Features/Bridge/Transport/BridgePaneProductSchemeProvider.swift:680).

The worker's exhaustive content registry obtains declared length/hash from File, Review and annotation-output requests; annotation projections and comparison catalogs instead have no declared exact facts in that request helper. It separately compares accepted identity and maximum, and File content terminal requires end-of-source. That makes exact-content facts and identity/currentness separate checks; neither is permission or rendering proof. [Current consumer registry](../../../../../BridgeWeb/src/core/comm-worker/bridge-product-content-application-registry.ts:19).

## What the target interface must resolve

| Boundary | Design consequence already visible from the current reads | Exact work still open |
| --- | --- | --- |
| Host source acquisition | Actual Git/filesystem and authoritative annotation workflow supply data; native DOM is not their substitute | Host source/identity/currentness interfaces, permissions and qualified Mac/Linux realization |
| Gateway prepared view | A compact view can combine authorized metadata without containing every file/output byte | Selected value shape, source witnesses, invalidation, demand, coherent reads and cache/retention bounds |
| Finite content | Descriptor admission, claimed content, completed bytes and cancellation retain distinct lifetimes | Addressed Host/content identity, binary transfer, declared limits, source replacement and cross-service lease custody |
| Native application | Package selection, worker derivation and publication application belong to a declared client/surface | Portable client target, installation/generation fence, exact native application result and unavailable-client behavior |
| Workflow and copies | SQL attempt bytes/history differ from runtime descriptor/page reservations; transferring bytes never repeats an output effect | Target unit/table export, history authorization, private state and finalization/reconciliation contract |

The owning contracts must bind those boundaries before an implementer can turn a current app controller into a remote service. The planned interface should supply the consumer's actual value and validity needs while preserving operation-specific side effects. A raw copied SQL row, a descriptor and a rendered Bridge result are different observations.
