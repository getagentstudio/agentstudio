# Annotation refresh and Copy/Export: Specification

Revision 5. Governing requirements: `2026-10-15-annotation-refresh-settlement-requirements.md` (U1–U4).

Owner decision, 2026-10-15: Copy/Export send the exact comments being output. Revision 5.1 owner decisions (2026-10-15, after review): export content stays as today, meaning each comment's stored original excerpt plus its placement evaluated by native at export time, in native's canonical order. A Review export whose displayed publication has already been replaced keeps today's `unavailable` result. This **replaces** revision 3's refresh-settlement holds (E5, Updating, unresolved epochs), which are withdrawn. It amends the PR1 annotation specification (`pr1-specification.md` lines 712–717): output no longer binds the displayed projection revision or source generation, and binds the exact comment identities and saved revisions instead.

## Entities

| ID | Term | Identity and meaning |
|---|---|---|
| E1 | Annotation session | A durable session identified by its session ID, belonging to a worktree lineage. A worktree resolves to a session set (PR1 lines 430–437). When a session is selected and demanded, its File and Review surfaces share it. |
| E2 | Output comment | One saved message the user is copying or exporting, identified by `messageId` and bound to its `savedRevision`. Only saved messages without an open draft are eligible, matching today's eligibility. |
| E3 | Output batch | The set of output comments (E2) the Share panel displays for the chosen scope (Pending or All) when the user clicks Copy or Export. Native orders it canonically, as today. |
| E4 | Source refresh | A page-initiated `source.refresh` for one demanded session on one surface. |

## Obligations

- **R1.** Copy and Export MUST send the output batch (E3): each `messageId` with its `savedRevision`, plus the scope label, output kind and destination. Native outputs exactly that set. It MUST NOT add or drop comments based on a newer Pending/All state. Output order stays native's canonical order (unchanged).
- **R2.** A listed comment that no longer exists, has a different saved revision, has an open draft, or belongs to another session MUST produce an exact no-effect `conflict` at every native boundary where it is detected: the initial read and materialization, and inside the preparation transaction. Share stays open. Genuinely invalid or fabricated canonical data stays a distinct non-conflict failure.
- **R3.** Native MUST NOT refuse output because the session revision, the service projection revision, the surface source generation, the session's lifecycle, source relationship or accepted fingerprint, or a listed comment's thread resolution changed. A source refresh, re-anchor, resolve, another worktree's change, or a change to an unlisted comment does not by itself affect Copy/Export. Integrity checks remain: identity and lineage, saved body and revision, immutable origin, canonical bytes, prepared-attempt exclusion, edit locking, product admission, and recovery availability.
- **R4.** Export content is unchanged from today: each comment's stored original excerpt, and its placement summary evaluated by native at export time. For File, evaluation uses the current file. For Review, it uses the publication the page displays. If that publication is no longer retained, today's `unavailable` result is kept (owner decision 2026-10-15); there is no new conflict mapping.
- **R5.** A source refresh MUST wait for the matching committed demand acquisition (#560).
- **R6.** A demand acquisition that has exhausted its consecutive-failure budget and is parked MUST be re-admitted at most once for each observed current-source opportunity. Source changes during one in-flight attempt coalesce to the latest source. The budget is not reset, and a replacement worker still waits for its first convergence.
- **R7.** No timers, polling, or clock-driven retries.

Output history, handled marking, `output.handled.clear` and repeat behave as today, applied to the listed comments. Save, reply, edit and resolve fences are unchanged.

## Proof obligations

| Obligation | Stimulus → observable |
|---|---|
| R1 | Page unit/component: Copy and Export send the displayed set for Pending and for All. Native: when a new unlisted comment appears or a listed Pending comment becomes handled or resolved, output is still exactly the listed set. |
| R2 | Native: a changed revision, a deleted message, an open draft, and a foreign-session id each produce exact `failed: conflict`, both when stale before materialization and when made stale during a held preparation dependency. Each case leaves zero effects and no prepared attempt, membership or event. The fabricated-canonical-body rejection stays a distinct failure. Page: Share stays open on `conflict`. |
| R3 | Native, held between capture and preparation: a source refresh (relationship or fingerprint change), a thread resolve, an unlisted comment edit, an unrelated worktree publication, and a projection bump. In each case output succeeds with exactly the listed set. This covers the exact race in the native WebKit trace. |
| R4 | Native: after relocation, Markdown and JSON keep the stored original excerpt and show the export-time placement. Review: output against the displayed retained publication; a no-longer-retained publication keeps today's `unavailable`. Repeat and historical exact bytes are unchanged. |
| R5 | The held acquisition-before-refresh unit cases, and the Vite annotation and copy/churn journeys (a refresh after opening a file is not refused). |
| R6 | The held-transport demand cases: parked recovery, a late final rejection, one attempt per later source opportunity, and replacement convergence. Receipts for the earlier red/green are in the Sunclaw tree's `tmp/tq105-fix-evidence/`. |
| U2 end to end | The native WebKit Share journey (`packagedFileAndReviewSharePerformsExactEffectsAndUnhandle`) at least 10 of 10 on Sunclaw. Reported baseline with #560: 3 of 3 failing. |
| Whole change | Full `mise run test` gate plus green hosted CI. |
