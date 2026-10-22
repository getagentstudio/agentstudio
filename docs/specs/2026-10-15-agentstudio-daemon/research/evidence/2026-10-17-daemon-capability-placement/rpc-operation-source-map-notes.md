# RPC operation source-map receipt

2026-10-17 · Researcher Worker · bounded current-source enumeration · completed

Source root: `/Users/shravansunder/code/projects/agentstudio.feat-daemon`; branch `feat/daemon`; HEAD `624300332f5e50f7bb8cbb9fc786d5e5b4a3d462`. No product/configuration/design edits, tests, builds, runtime/probes, credentials, network services, Git mutation, fanout or board messages. This commission authored only [rpc-operation-source-map.json](rpc-operation-source-map.json) and this receipt; the earlier native/CLI note was not changed.

source: The JSON array accounts for **exactly 57 unique declared method names**, once each. It records current source/execution owners, effect or state boundaries and required native context. It assigns no future Host/Gateway/Swift home and does not select public exposure. Declaration coverage does not establish successful features. ([Compiled index](../../../../../../Sources/AgentStudioProgrammaticControl/BuiltInDescriptors/IPCBuiltInMethodIndex.swift:15).)

## Enumeration reconciliation

```json
{
  "sourceHead": "624300332f5e50f7bb8cbb9fc786d5e5b4a3d462",
  "indexedBuiltinReferences": 54,
  "resolvedBuiltinRecipeNames": 54,
  "compositionNames": 3,
  "authoritativeNames": 57,
  "rows": 57,
  "uniqueMethods": 57,
  "missing": [],
  "extra": [],
  "duplicates": []
}
```

source: Enumeration was extracted from the actual 54 `*MethodDescriptors.*Entry.erased` references in the compiled index, resolving each referenced recipe to its literal `name`; all 54 references resolved uniquely. The index's three composition-help entries resolve to `command.list`, `command.execute` and `system.capabilities`. The JSON method-name set was compared with that resolved set. This was source-data analysis, not compilation or a catalog-runtime invocation. ([Index references](../../../../../../Sources/AgentStudioProgrammaticControl/BuiltInDescriptors/IPCBuiltInMethodIndex.swift:35), [command names](../../../../../../Sources/AgentStudioProgrammaticControl/IPCCommandMethodComposition.swift:12), [capabilities name](../../../../../../Sources/AgentStudioProgrammaticControl/IPCSystemCapabilitiesComposition.swift:25).)

The JSON has the seven requested fields on every row:

- `methodName`: exact current declaration.
- `currentSourceClass`: descriptive category of today's acquired data/effect; not a future component partition.
- `presentOwner`: actual current adapter, service, runtime or native/page owner.
- `effectOrStateBoundary`: what is read or changed and what result means.
- `requiredNativeContext`: operation-specific current dependency. All methods additionally share today's app-server composition boundary below.
- `decisiveSourcePointers`: repository-relative path, line and evidence-reuse label.
- `proofLimit`: row-specific boundary between current source evidence and unobserved/deeper behavior.

Artifact readback: `jq -r '.[].methodName'` read the saved JSON; its 57 names matched both the constructed rows and authoritative resolved source set, with missing `[]` and extra `[]`. `jq` field checks returned rows `57`, unique methods `57`, complete rows `true` and nonempty pointers `true`. Readback command exit `0`. Saved artifacts contain 1,772 JSON lines and 92 note lines before this readback paragraph was added. HEAD remained unchanged; no product source changes were reported by status. These are artifact/inventory checks, not product tests or runtime proof.

## Evidence reuse and shared limits

source: The complete 84-line [E2 app-RPC evidence](../../../../../../tmp/practices-research/2026-10-15-daemon-extraction-survey/e2-app-rpc-evidence.md:1) was read in bounded chunks, together with the [57-name survey inventory](../../extraction-survey.md:84). Its source pin equals the checked current HEAD. Existing path claims were reused explicitly rather than reporting 57 freshly traced deep paths. Its historical future-topology/gap prose is not adopted by this current-source crosswalk.

Evidence labels in the JSON:

- `enumeration-only-current-source`: exact recipe/composition name inspected for inventory; establishes declaration, not behavior.
- `opened-current-pass`: stated primary function/registration/wiring opened in this pass.
- `reused-prior-worker-pass-same-head`: primary source directly read in this Worker's earlier five-family commission and reused at unchanged HEAD.
- `reused-E2-primary-pointer-same-head`: deeper primary-source anchor carried by the complete E2 report, not freshly opened here.
- `reused-same-head-report`: exact row of the E2 evidence supplying bounded baseline meaning.

source: Current App boot constructs the query, layout, runtime, Bridge, UI/sidebar and Sessions/pane-context ports and requires an accepting main window before constructing its server. Therefore a row saying “no operation-intrinsic NSWindow/view call” does not claim that today's server runs without the app/window composition. Conversely, `window.list`, `workspace.list`, `pane.list` and sidebar preference reads do not acquire an additional live-view requirement merely because the app owns them. ([Gate/query/layout](../../../../../../Sources/AgentStudio/App/Boot/AppDelegate+IPC.swift:424), [remaining actual ports](../../../../../../Sources/AgentStudio/App/Boot/AppDelegate+IPC.swift:458).)

source: Ordinary ingress validates/authorizes then awaits handler and validates result. Cached catalog bytes are not retained mutation receipts; a schema-valid response is not a stronger domain/native effect. These general E2 qualifications remain reused, not independently re-proven across all methods in this pass. ([E2 shared qualifications](../../../../../../tmp/practices-research/2026-10-15-daemon-extraction-survey/e2-app-rpc-evidence.md:11).)

## Reads and names that hide boundaries

| Method(s) | Checked current distinction |
| --- | --- |
| `pane.message.changes` | **Durable receipt/progress mutation.** SQLite write UPSERTs monotonic reported answer position, confirms receipts, bumps revision when receipt confirmation changes and can delete aged acknowledged events. Returned `nextPosition` alone is not acknowledgement. [Fresh decisive transaction](../../../../../../Sources/AgentStudio/Core/PaneContext/PaneContextService+Changes.swift:11). |
| `pane.context.get` | Detail acquisition updates in-memory detail-version/revision tracking. Its `ensureOpen` can settle old open blocking asks on startup and drain pending retirements before ordinary detail read. It does **not** mark notices read. This is conditional service lifecycle work, not a claim every get durably mutates messages. [Detail/version](../../../../../../Sources/AgentStudio/Core/PaneContext/PaneContextService+Detail.swift:27), [opening/drain](../../../../../../Sources/AgentStudio/Core/PaneContext/PaneContextService.swift:93). |
| `session.query` | Can restore runtime status from repository, load open asks, consume viewed/retirement mailbox inputs and publish state; last-refusal read also consumes the mailbox. Open-ask source is actually wired through PaneContextService, so first demand can reach its opening/settlement boundary. No new answer receipt is acknowledged merely by querying. [Hydration](../../../../../../Sources/AgentStudio/Features/Sessions/Runtime/SessionsIngestion+Status.swift:33), [mailbox](../../../../../../Sources/AgentStudio/Features/Sessions/Runtime/SessionsIngestion+Status.swift:191), [composition](../../../../../../Sources/AgentStudio/App/PaneContext/SessionsPaneContextComposition.swift:38), [bridge](../../../../../../Sources/AgentStudio/App/PaneContext/PaneContextSessionsBridge.swift:24). |
| `bridge.fileView.getContent` | Returns content-handle metadata/MIME, **not bytes**; obtains then settles a runtime content lease. This changes lease/retiring-publication bookkeeping, not durable answer receipts. [IPC read](../../../../../../Sources/AgentStudio/Features/Bridge/Runtime/BridgePaneController+IPCProjection.swift:310), [lease insert/remove](../../../../../../Sources/AgentStudio/Features/Bridge/Runtime/ReviewFoundation/BridgeReviewPublicationCoordinator.swift:453). |
| `bridge.diff.load`, `bridge.fileView.open` | Create pane/native host/new tab and return fresh pane handle; these are not data-only diff/file reads. Deeper rollback/autosave distinction reused E2. [Fresh adapter](../../../../../../Sources/AgentStudio/App/IPCComposition/AgentStudioIPCBridgeAdapter.swift:31). |
| `bridge.diff.getPackage` | Reads current native package metadata/selection/status; does not fetch full content and does not sample DOM. [Projection](../../../../../../Sources/AgentStudio/Features/Bridge/Runtime/BridgePaneController+IPCProjection.swift:74). |
| `bridge.diff.renderState` | Executes JavaScript to sample page DOM/probes and merges native diagnostics. A successful RPC can carry `evaluateSucceeded:false`. [Projection](../../../../../../Sources/AgentStudio/Features/Bridge/Runtime/BridgePaneController+IPCProjection.swift:127). |
| `bridge.telemetry.flush` | Drains sidecar, creates/takes/cancels proof capture and records proof; distinct from observational `snapshot` and from exporter delivery. [Fresh function](../../../../../../Sources/AgentStudio/Features/Bridge/Runtime/BridgePaneController+IPCProjection.swift:365). |
| `terminal.snapshot`, `terminal.status` | Registered runtime/renderer facts, **no terminal output**. Status is not an independent live-process probe. [Adapter](../../../../../../Sources/AgentStudio/App/IPCComposition/AgentStudioIPCRuntimeAdapter.swift:30). |
| `terminal.wait` | Temporary runtime subscription/replay and condition observation, not a process-completion/durable-history API; renderer conditions depend on renderer-source facts. [Adapter](../../../../../../Sources/AgentStudio/App/IPCComposition/AgentStudioIPCRuntimeAdapter.swift:90). |
| `auth.status`, `system.capabilities`, `command.list` | Connection principal or immutable composition catalog reads, not durable credential custody, owner readiness or live enablement. [Status](../../../../../../Sources/AgentStudioAppIPC/AgentStudioAppIPCServer.swift:362), [capabilities](../../../../../../Sources/AgentStudioAppIPC/AgentStudioIPCRegistryAuthorization.swift:42), [commands](../../../../../../Sources/AgentStudioAppIPC/AppIPCCommandMethodRegistrations.swift:11). |
| `pane.split`, `session.event`, `command.execute` | Target pane rather than new pane in split reply; admitted can include ignored provider reduction; command result applies only to selected command's declared boundary. No generic completed-effect meaning. [Split adapter](../../../../../../Sources/AgentStudio/App/IPCComposition/AgentStudioIPCLayoutAdapter.swift:62), [event adapter](../../../../../../Sources/AgentStudio/App/IPCComposition/AgentStudioIPCSessionsAdapter.swift:32), [command adapter](../../../../../../Sources/AgentStudio/App/IPCComposition/AgentStudioIPCCommandAdapter.swift:117). |
| `bridge.fileView.showMarkdownPreview` | Declared native-to-page route exists, but same-HEAD E2 found both current page handlers return `unsupported_surface`; those page anchors are explicitly reused, not newly read/reviewed. [E2 availability qualification](../../../../../../tmp/practices-research/2026-10-15-daemon-extraction-survey/e2-app-rpc-evidence.md:52). |

This table distinguishes domain/receipt changes from runtime caches, leases, waiters, projections and lifecycle work. It is not a complete purity audit of every utility, diagnostic, lazy cache or dependency invoked by every read.

## Search account and unresolved work

Current primary refresh covered authentication closures; system/capabilities registrations; activity visibility projection; runtime adapter and terminal surface delegation; pane-context adapter/detail/changes/opening; Sessions adapter/hydration/mailbox and actual bridge wiring; Bridge adapter/IPC projection/content lease; UI/sidebar adapters; event registration/broker; and production port composition. Existing query/layout/command/native paths from the preceding Worker pass were reused at unchanged HEAD.

Representative queries included:

```text
rg -n 'name: "[a-z]+\.[A-Za-z.]+' Sources/AgentStudioProgrammaticControl/BuiltInDescriptors -g '*.swift'
rg -n 'static let [A-Za-z]+Entry|name: "[a-z]+\.[A-Za-z.]+' Sources/AgentStudioProgrammaticControl/BuiltInDescriptors -g '*MethodDescriptors.swift'
rg -n 'ensureOpen|startup|settle' Sources/AgentStudio/Core/PaneContext/PaneContextService.swift
rg -n 'readSessionStatus|restoreStatusIfNeeded|consumePaneViewedBatch' Sources/AgentStudio/Features/Sessions/Runtime/SessionsIngestion+*.swift
rg -n 'func acquireContentLease|func settleContentLease|contentLease' Sources/AgentStudio/Features/Bridge/Runtime/ReviewFoundation/BridgeReviewPublicationCoordinator*.swift
```

Null/instrument corrections: a guessed `IPCSystemCapabilitiesDescriptorFactory.swift` path was absent; discovery found the definition in `IPCSystemCapabilitiesComposition.swift`, opened above. A guessed `BridgePaneController+ProductSessionIPCProjection.swift` read was absent; no absence conclusion was adopted, and the claim was limited to the inspected IPCProjection entry and E2 dependency evidence. Some broad outputs were truncated; deciding function ranges were reopened narrowly where relied upon.

gaps: No operation remains unnamed or assigned an unresolved top-level current owner class. Deeper effect internals are not uniformly refreshed: every row's `proofLimit` and pointer label identify reused scope; `command.execute` does not expand all 154 command identities. Every real IPC/native/runtime/SQLite interaction, permission outcome, process lifetime, cancellation/race/restart case and production readiness remains unobserved here. Settling those requires a separately authorized, target-specific source/proof commission; they are not missing/extra inventory entries.

No owner choice/access problem blocked this bounded enumeration. No future allocation/design conclusion is authored by these artifacts.
