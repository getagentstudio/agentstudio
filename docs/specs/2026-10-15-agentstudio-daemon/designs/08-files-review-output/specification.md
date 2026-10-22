# Files, reviews, annotations and output: observable contracts

This is the DS08 slice of the [system Specification](../../2026-10-15-agentstudio-daemon.md). The separate [Requirements](../../user-requirements.md) authorize its meaning; the [domain definitions](../../domain-entities.md) and shared [operation interpretation](../../capability-contracts.md#shared-interpretation-of-an-operation) apply. Its [design brief](README.md) owns scope, inputs and unresolved work. Existing open gaps are preserved; this partition selects no new behavior.
The [initial profile](../../initial-profile.md) supplies the selected IP1–IP12 directions. Remaining gaps concern their exact contracts and realization; they do not reopen the selected high-level choices.


## K9 — File/review construction and finite content

**Consumer / entities / basis:** file/review viewer; E7/E8/E12/E20/E22; U3/U4/U9/U13. The complete [Bridge vocabulary](../../research/evidence/2026-10-15-daemon-extraction-survey/bridge-surface-inventory.md) accounts for sixteen semantic calls, five finite-content kinds and the nested annotation operations. These overlap app RPCs; counts are not additive.

File open/content/preview, diff load/refresh/package/render-state/select/scroll/expand/collapse and tree search/filter/reveal distinguish product construction, session/source admission, finite-content delivery, worker application, DOM and presented pixels. A generic command completion can follow provider installation and can wrap partial/failed inner outcomes. Release/cancellation/currentness checks are operation-specific.

Finite content needs a declared descriptor/lease, content kind, source/publication currentness, range/length/digest and explicit completion/refusal/limit boundary. End-of-stream, valid hash and receiver credit do not establish render/application/current source. Numerical budgets, cache/revalidation scope, supported media/path encodings and cross-version kinds remain G7–G10. None is chosen by using `bytes` or a compact codec.

**Proof:** real source bytes and currentness races across construction, transport and supported worker/native viewer. Correct hashing or HTTP response alone is insufficient. The existing debug Bridge host can exercise real domain composition but its loopback/debug identity and substituted effects do not prove a shipped Host or native rendering.

## K10 — Annotation editing and output effects

**Consumer / entities / basis:** reviewer and integration caller; E12–E15/E20/E22; U4/U9/U13. All twenty-two [annotation operations](../../research/evidence/2026-10-15-daemon-extraction-survey/bridge-surface-inventory.md) remain accounted for as session/thread/message mutation, edit ownership, demand/recovery, source refresh and output prepare/perform/history/repeat. Their revisions/currentness checks are operation-specific, not one generic CRUD version.

Annotation saved revision, draft/edit ownership and refreshed source are distinct. Source refresh can commit before a stale response. Prepared output captures exact saved revisions, membership, bytes and destination; later edits do not silently change those bytes. Known effect plus failed finalization is partial success. Prepared recovery can become unknown; repeating unknown creates a new attempt with exact bytes and lineage, rather than proving the old attempt failed or replaying it automatically.

IP12/R17 settle completed-agent viewed sharing. Whether annotation and review-file viewed state join that shared set is the G9 family-scope question with Sun; they are neither silently included nor excluded. If selected, their E26 reader/subject/revision binding must be specified. Draft edit custody, handled-output state and actual user viewing are not interchangeable marker kinds or automatic effects of copy delivery.

Destination effect is explicit: clipboard, JSON/file output or native presentation. Clipboard clear can occur before set-data failure. Exclusive file-write failure can leave residue if cleanup fails. Destination cancellation can occur after preparation; it does not universally mean “no attempt or persistence.” Bounded history that excludes cancellations is not a complete durable audit.

**Proof:** actual annotation transaction/revision races, destination bytes and prepared-attempt identity, induced finalization failure after known effect, uncertain recovery/repeat, clipboard mutation and real file residue. A prepared payload or returned generic success cannot prove the final effect. Destination locality, retention/restart and remote effect authority remain G3/G8/G9/G12.
