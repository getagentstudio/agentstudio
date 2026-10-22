# Data ownership, storage and replication: observable contracts

This is the DS02 slice of the [system Specification](../../2026-10-15-agentstudio-daemon.md). The separate [Requirements](../../user-requirements.md) authorize its meaning; the [domain definitions](../../domain-entities.md) and shared [operation interpretation](../../capability-contracts.md#shared-interpretation-of-an-operation) apply. Its [design brief](README.md) owns scope, inputs and unresolved work. R15/R16 and C5/V7 give the state-boundary and observation obligations; exact profiles remain explicit gaps. No target schema or replication engine is selected here.
The [initial profile](../../initial-profile.md) supplies the selected IP1–IP12 directions. Remaining gaps concern their exact contracts and realization; they do not reopen the selected high-level choices.


## K11 — Shared state, observations and publication

**Consumer / entities / basis:** concurrent clients, service integrator and detached operator; E1/E7–E11/E15–E19/E22/E25/E26; U4/U9/U13/U15/U16/U18/U22 and S24–S26; R15–R17. Canonical state, retained operational history, replaceable cache, observation coverage, shared arrangement/read state and actual native view memory have different meanings. Current SQL transactions do not imply a multi-writer remote database or atomic cross-service update.

For each selected fact, the contract must declare subject/source lifetime, scope/currentness, ordered-fact versus replaceable-latest meaning, subscription coverage, loss/overflow outcome and retained-history promise. Current local unbounded, outbound newest-128 and bounded shared replay queues are different mechanisms, not a reliable global bus. A registered `events.subscribe` method and a notification enum do not establish a live terminal publisher.

Swift must receive the state and control results needed to display/interact. U13 requires reevaluating the boundary rather than moving every actor or atom verbatim. Current atom rules constrain publication: shared UI/atom state is assigned on MainActor; admission, derivation, I/O, ordering, deadlines and domain policy are not work for atom methods. “Nothing on MainActor” cannot literally include native/UI publication. The Host backend versus native client boundary is selected; concrete Rust owners/channels, state homes and thin Swift publication adapters are Program Design questions after the remaining G4–G9 semantics are settled.

**Proof:** real ordered/loss/currentness scenarios, stale-source rejection, unchanged semantic value suppression and actual native publication at the selected observation boundary. A bus throughput benchmark or several in-process subscribers does not prove multi-device consistency, durable history or native responsiveness.

## C5 — State meaning and observation scenarios

R15/R16 in the spine are the normative obligations. The following questions are independent: a retained record can be private; authoritative state can have copied representations and derived readers; a derived result can itself be stored. Its representation does not select its data audience or lifetime.

| Contract dimension | What the consumer must be able to distinguish | Choice still owned by the selected profile |
| --- | --- | --- |
| Meaning and subject | Which defined resource/fact is addressed, including Host-qualified identity where applicable | Exact selected records, fields and capability exposure |
| Authority | The source that decides a domain mutation versus a reader or prepared observation | Concrete home and admitted mutation interface; R14 already fixes central writer-lease authority |
| Lifetime | Current value, retained operational record and transient progress; promised survival across view/connection/source loss | Retention, restart/re-adoption and recovery coverage under G3/G6/G9 |
| Representation | Source facts, faithful copies and derived/filtered/joined observations | Selected schema/units, materialization and rebuild contracts |
| Data audience | The principal/target scope permitted to read or change the selected data | Credential/delegation/revocation and whole-copy access under G8/G12 |
| Change delivery | Ordered facts versus replaceable state; gap/overflow/resume meaning | The selected notification/history contract; SQL capture is not automatically a public domain event |
| Validity | Subject/source lifetime, declared coverage, known incomplete/superseded state and coverage/continuity not established for the scope under R16 | Validity, freshness, refusal and cross-client read profiles; no global ordering or deadline is inferred |

This contract concerns what an operation or observation means. Exact crates, SQL files, record/wire shapes, channels, derivation owners and native publication mechanisms belong to Program Design after those meanings are fixed.

| Consumer situation | Observable distinction under C5 | What would violate it |
| --- | --- | --- |
| Two Hosts have the same path or local record label | A Host-qualified result retains the addressed Host's subject/source identity | Returning or mutating another Host's facts through an inferred local default |
| A read or subscription has known incomplete/superseded coverage, or coverage/continuity has not been established | The result preserves that validity distinction under R16; the exact allowed stale-result versus refusal profile remains G9 | Describing partial, superseded or unestablished coverage as complete current state |
| The value is equal but observation continuity is not established | Equal values do not establish uninterrupted source coverage under E22; R16 forbids asserting complete current coverage while continuity remains unestablished | Treating payload equality as proof that a source gap never happened |
| A client receives or displays retained notice/annotation/output state | State arrival, delivery acknowledgement, person action and an E15 destination effect remain separate observations | Claiming a person read a notice or a native output succeeded merely because rows arrived |
| Swift or every Gateway (macOS or iOS) disappears while the Host continues | The R9/R10 selected Host-local work/facts remain independent of that presentation loss | Making the only required fact source depend on a renderer or connected viewer |
| Selected private data has a copied representation | Its declared audience still applies; connection authentication alone does not settle permission to receive the whole data scope | Expanding data access solely because a reader receives a database copy |
| A consumer asks for earlier changes after a gap | Its result follows the selected history/retention contract, rather than inferring history from current rows | Presenting latest state or a transport replay buffer as a complete domain history without that promise |
| A user accesses shared tabs/layout or read marks from another device | R17/C6 preserve the same E25/E26 meaning at each resource's reported established version, and require participating authorized devices presenting the state or requesting its current value on an available continuing path to converge after changes quiesce; actual native projection and actual viewing remain distinct | A per-device-only fork, a permanently stale healthy reader, or marking read solely because copied data arrived |
| A Host is unreachable while authorized last-known data is available | IP1 preserves explicit offline/currentness meaning under the data's actual audience | Presenting the cached observation as a successful current Host read or using it to authorize a mutation |
| A required database-writer grant is invalid | IP4 pause/refusal and truthful coverage/partial outcomes are separate from continuing execution and Gateway presence | Hidden spool acceptance, invalid writes, presentation-driven termination or claiming missing coverage was recorded |

IP11/IP12 and R17/C6 require shared tabs/layout and read marks; the choice is not per-device-only. IP1/IP4/IP5 fix the initial offline-display, invalid-writer and retention directions. Exact E25/E26 element/subject/audience binding, authority/storage, export/unit cuts, synchronization/conflict and lifetime/gate outcomes remain G3/G6/G8/G9/G12/G13. The [source schema evidence](research/schema-prerequisites.md) establishes current declarations and candidate-profile conflicts; it neither allocates those internal owners nor proves C5/C6.

V7 requires current-source/data inspection for inventory claims and real selected source-to-observation/effect interactions for application claims. Source-form checks, binary transport success and SQL replay are different proof boundaries. No new persistence tier, outbox, event log, atom or bus case is implied by these scenarios.
