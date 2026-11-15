# Annotation refresh and Copy/Export: Program Design

Revision 5.1 (after review round 4 and its verification; owner decisions on excerpts and the Review edge). Realizes `2026-10-15-annotation-refresh-settlement-specification.md` (R1–R7). This replaces revisions 1–3's refresh-settlement design, which is withdrawn. Anchors are at `830876e35` (#560 + main).

## Current system

```
page Copy/Export ─► output.scope.commit { scope, displayedProjectionRevision, expectedSessionRevision, sourceGeneration }
                     (bridge-product-call-contracts.ts:273-279; output-controls.tsx:279-287)
native adapter  ─► store.outputSessionDetail: projectionRevision == displayed? semanticRevision == expected?  (ServiceActor.swift:384-400)
                ─► sourceGeneration == body.sourceGeneration (twice)                                           (TransportAdapter+Output.swift:19, :48)
                ─► recompute selectedMessages from scope (saved, no draft; pending = open thread, human, unhandled) (:63-78)
                ─► OutputCoordinator.executeNew(selectedMessages: [(messageID, expectedSavedRevision)], placements, ...)
repository      ─► session revision check, canonical-snapshot validation, per-message saved-revision check (+Output.swift:~150-195)
```

The per-comment fence already exists. The three coarse fences above it are what make an unrelated change produce `conflict`.

## Selected change

| Layer | Change |
|---|---|
| Page request (`bridge-product-call-contracts.ts`, plus every mirror: worker routing, decoded schemas, runtime-dispatch fixtures) | `output.scope.commit`: remove `displayedProjectionRevision`, `expectedSessionRevision` and `sourceGeneration`; add the required non-empty, duplicate-free `messages: [{ messageId, savedRevision }]`. Keep `scope` (now a label only), `outputKind`, `destination` and `sessionId`. Strict. |
| Page controls (`worktree-annotation-output-controls.tsx` `executeOutput`) | Send exactly the displayed set for the scope, using today's eligibility. |
| Native body (Swift `OutputScopeCommitBody` and its strict keys) | Mirror the change. Hard cutover. |
| Native adapter (`executeOutputPreparation`) | Remove the projection and session-revision fence and both source-generation checks. Build the selection from `body.messages` with the caller's saved revisions; do not reselect from scope. Before materialization, validate each listed comment against the captured detail (present in this session, saved revision equal, no open draft); a mismatch is a typed selection `conflict`. Keep source capture and placement evaluation. For Review, keep evaluating against the page-named publication. If it is no longer retained, today's `unavailable` path is unchanged (owner decision). |
| Coordinator (`WorktreeAnnotationOutputCoordinatorActor`) and projector (`WorktreeAnnotationBatchProjector`) | Remove the coarse fence fields from the coordinator request and its forwarding. Map the projector's `savedMessageNotFound` (stale requested revision or draft) to selection `conflict`. Keep native canonical ordering and the current batch format unchanged. |
| Service and repository | Remove the expected-projection and session-revision checks from new-output preparation only. In `validateCanonicalSnapshotAgainstDurableState`:<br>- **keep** identity and lineage, saved body and revision, immutable origin, and canonical byte, schema and selection consistency;<br>- **drop** equality on mutable context: session lifecycle (`:724`), source relationship (`:725`), and selected-thread resolution (`:739`);<br>- **decompose** the origin comparison (`:740–745`): keep the immutable path, original range and excerpt, source identity and side, and drop only the accepted-fingerprint-derived comparison context.<br>Output admission stays at its existing owners: product/lineage authority, `requireMutationAllowed` (recovery/availability), and prepared-attempt rules. Do **not** add `requireWritableSession`; a completed or read-only session can still Copy/Export, as today.<br>Run the per-message selection check before any canonical mismatch can mask ordinary staleness, and map its failure to `conflict`. Keep `ensureNoPreparedOutputAttempt`, edit locking (`ensureMessageEditable`), handled marking from memberships, and the dedicated repeat path. `output.handled.clear` keeps its own `expectedSessionRevision`. |
| Demand sequencing (#560) and R6 | Already on the branch: #560's sequencing, and R6 committed as `2308f9c9b`. |

**Ownership is unchanged.** SQLite and the repository own durable truth. The adapter owns turning the request into a selection. The page owns what it displays and sends.

**Withdrawn:** the settlement design (E5, holds, Updating, publication reordering, late-outcome record). `source.refresh` keeps its existing `committed` status.

## Edges

- **A listed comment changed, deleted or drafted** between display and export: `conflict`, with no effect. Share stays open, and the user clicks again after the list updates.
- **Refresh, re-anchor, resolve, an unlisted-comment change, or another worktree's change:** output succeeds with exactly the listed set.
- **Pending scope where a listed comment was handled or resolved elsewhere:** still output, because it is in the list. Handled marking follows the recorded memberships.
- **Review, where the displayed publication is no longer retained:** today's `unavailable` (owner decision).
- **Empty or duplicate list:** rejected by the schema.

## Tests

- **Native, through the real adapter → coordinator → repository path:**
  - the R2 negatives, each stale both before materialization and during a held preparation dependency, asserting exact `failed: conflict` and zero effects, attempts, memberships or events;
  - R3 interleavings held between capture and preparation: refresh, resolve, unlisted edit, unrelated publication and projection bump, each succeeding with the exact set;
  - R1: a new unlisted comment, and a listed Pending comment handled or resolved, still output exactly the list;
  - R4: Markdown and JSON keep the original excerpt and the export-time placement after relocation; Review against a retained publication (no-longer-retained keeps today's `unavailable`); lifecycle changed between capture and preparation, and a completed or read-only session, still output; a malformed immutable origin is rejected independently;
  - repeat and historical bytes unchanged; the fabricated-body rejection kept distinct;
  - update the existing coarse-fence output tests, `BridgeDevelopmentAnnotationHTTPRoutingTests`, and the shared transport helpers to the new body.
- **BridgeWeb:**
  - controls send the displayed set for Pending and All;
  - schema and dispatch-fixture strictness (empty, duplicate and unknown keys);
  - Share stays open on `conflict`;
  - the demand-sequencing and R6 cases.
- **Vite E2E:** the annotation and copy/churn journeys.
- **Native WebKit Share journey:** at least 10 of 10 on Sunclaw.
- **Gates:** the full `mise run test`, then hosted CI.

## Delivery

- One PR, extending #560: demand sequencing, R6 recovery, and the Copy/Export payload change.
- Implementation by a Sol sidekick on Sunclaw. The CI Lead runs native WebKit proof, the full gate and hosted CI.
