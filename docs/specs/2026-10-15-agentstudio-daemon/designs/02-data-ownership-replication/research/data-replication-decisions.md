# AgentStudio data structures and replication: decision tree

Use the supplied `agent-fleet-sync` plan as the shared-mechanism research baseline: protocol, resumable sessions, transport adapters, writer/capture/retention, lease rules, receiver/apply/snapshot/hooks, service host and owned SQLx drivers. AgentStudio still owns its domain schema, data meaning, deployment, authentication and policy. This map does not select application lease configuration, a migration, a production crate graph or an implementation plan.

The [2026-10-17 consumer-fit update](fleet-sync-consumer-fit.md) replaces the earlier plan-only implementation picture with the inspected six-PR stack. Its replicated keys are immutable canonical UUIDv7 values, with explicitly non-null TEXT key columns; arbitrary existing primary keys are not admitted unchanged. The update also separates ordinary Gateway followers, any explicitly designated authoritative copy, optional durable delivery and committed apply acknowledgement from completed external effects. No AgentStudio package adoption or runtime pass is claimed.

Current owner constraints: **the central control plane owns lease-registry authority; the Gateway assumes ready, connected machines; database-writer transfer remains out of scope; building the server comes later.** Keep authority integration separately composable through an appropriate crate or module. [Exact owner source](../../../research/owner-inputs/central-control-plane-selection.json). This supersedes the earlier Gateway-hosted assumption. Machine preparation, moving and copying are future control-plane work; this selection does not choose lease duration/expiry or waive autonomous Host outcomes.

The [current inventory](data-catalog.json) covers 86 logical tables / 597 columns / 35 expanded value containers. Every table now has a preliminary fleet-sync membership evaluation; this is a recommendation family, not an adopted export list or proof that its DDL is admissible. The [storage survey](data-ownership-survey.md) remains the detailed current-source explanation.

The [current storage-placement design](../storage-placement-design.md) and [complete matrix](../storage-placement-matrix.md) carry the newer concrete owner/transaction classification. This decision map remains a mechanism/decision reference; IP1–IP12 and S28 supersede earlier open high-level scope labels.

## The tree

```text
AgentStudio data and replication
├── 1. Truth and its owner
│   ├── Machine work and workflow records → addressed Host
│   ├── Portable workspace/tabs/splits    → shared; designated Host proposal
│   ├── Native window/browser/input      → native client
│   ├── Credentials and producer claims  → private owning boundary
│   └── Search/sidebar/current views     → rebuildable projections
├── 2. Replication units and membership
│   ├── Host-wide metadata vs per-project databases
│   ├── Exact declared application tables and fields
│   ├── Transaction/FK closure across selected tables
│   ├── Separate client-composition units, if needed
│   └── Exclude private, ephemeral and derived-only state by default
├── 3. Identities and schema
│   ├── Host / database / incarnation / writer epoch
│   ├── Peer / receiver-copy / protocol session / connection
│   ├── Terminal / agent conversation / attachment / view
│   ├── Legacy key audit → immutable UUIDv7 replicated key components
│   └── Migrations, exact SQL values and restored-database identity
├── 4. Lease authority and placement
│   ├── Central control plane owns registry; one issuer per database
│   ├── Authority/copy binding and initial setup remain to define
│   ├── Expiry, renewal and exactly which writes are gated
│   ├── Database-writer transfer OUT OF SCOPE
│   └── Separate integration; authority-server build DEFERRED
├── 5. Copies, history and recovery
│   ├── Independent position for every copy
│   ├── Delivery retention versus retained product history
│   ├── Snapshot cut, schema cut and large-transaction staging
│   ├── Last-known / caught-up / current-authority read meanings
│   └── Original Host restart/restore versus replica refill
├── 6. Commit, hooks and effects
│   ├── Replica rows + hook SQL + position + durable work intent
│   ├── Meaning of acknowledgement after that commit
│   ├── After-commit retries, identity and terminal failures
│   ├── SQL changes → typed invalidations/prepared views
│   └── Commands and native effects retain their actual owner
└── 7. Client delivery and proof
    ├── Swift socket schemas and compact publication
    ├── Separate terminal/file byte lanes
    ├── Permission scope for whole copies and subscriptions
    ├── Real transaction/reconnect/lease/two-copy experiments
    └── Capture/apply/query/native-publication cost
```

## What the shared plan covers

| Shared mechanism | AgentStudio must still supply |
| --- | --- |
| Faithful one-way row/schema replication; per-copy apply positions | Which databases exist, what their records mean, and which tables are declared |
| Lease registry/holder/write gate; shared library also has holder-change mechanics | Central control plane owns registry authority; choose its database/copy bindings, setup and duration/renewal/expiry. AgentStudio writer transfer is excluded; the shared library's APIs do not select current exposure |
| Logical session independent of connection; WebSocket adapter | Peer enrollment, credentials, resource authorization and service discovery. Terminal execution lifetime is separate from the shared protocol session |
| Consumer hook inside apply; durable after-commit work | A bounded projection/invalidation hook and operation-specific delivery/deduplication/failure semantics |
| Exact SQL values and immutable canonical UUIDv7 replicated key components | Target key/association design, explicitly non-null TEXT declarations, supported DDL/migrations and private-data policy; local-only keys remain outside this replicated-key contract |
| Copies as read-only Turso databases | Read models, freshness labels, native publication and current-authority revalidation before effects |

These mechanisms do not implement terminal restoration, process migration, Git worktree movement, browser/profile sync or conflict merging. A SQL write lease is also different from a terminal input/resize controller grant.

## Data shapes to define

Reuse the shared protocol's database, peer, receiver, epoch, position, session and connection types; do not create second AgentStudio encodings of those same meanings. AgentStudio still needs its own domain shapes at their real boundaries:

- **Host-qualified resource reference:** a repository, worktree, execution session or provider conversation on a specific Host. A local path or provider ID is not a global identity.
- **Execution association:** provider evidence/binding/agent context attached to execution, separately mapped to zero or more client views and terminal attachments.
- **Replica read result:** data plus its source database/incarnation, epoch/position and declared currentness/coverage. Starting, last-known, following, needs-snapshot and unavailable are explicit states, not a boolean bag. A following replica does not by itself establish current Host liveness or authoritative-tail acceptance.
- **Operation outcome:** accepted/committed/refused/partial/unknown as the operation actually supports. Replica apply acknowledgement and external-effect completion remain different values.
- **Prepared client view:** declared Host inputs plus client intent and validity/revision context; native publication is a separate boundary. The schema crossing Swift's socket is not a SQL row or a raw CDC entry.

These are responsibilities to specify, not finalized structs/wire fields. Runtime native state, transport replay bookkeeping and retained workflow rows keep distinct types and lifetimes.

## Data families to carry forward

| Data family today | Current evidence | Replication direction to evaluate |
| --- | --- | --- |
| Repository/watch/membership/absence/activity | Machine paths, filesystem coverage and machine-relative clocks; repository identity and recency may be path-derived | Host-owned published metadata candidate. Scope every public reference by Host. Local paths, boot/uptime and volume positions retain origin and validity |
| Execution ownership, provider evidence/bindings, context/asks/answer settlement | Current schema mixes pane/view keys with execution; context checks binding within its write transaction | Host workflow candidate after the execution/view split. Keep the real atomic admission predicate inside one authoritative unit |
| Annotations, drafts/edit fences, prepared output and finalization | Exact saved revisions/membership/bytes and atomic workflow writes; external file/clipboard effect outside SQL | Host workflow candidate. Copying output-attempt rows never replays the external effect. Preserve native destination identity |
| Workspace/tab/layout/drawer/Undo and saved navigation | Client composition, with references to Host resources; Undo currently also carries execution custody | Separate client-owned meaning from execution. Mobility/sharing and physical home remain open. Undo expiry must not terminate execution |
| Native window/chrome/editor/browser state | Native frame/focus/renderer, browser website store and client-specific preferences | Keep native state with its client by default. A specific portable preference would need its own meaning; no automatic whole-profile replication |
| Credential verifiers and admission authority | Separate Host session authority and Gateway/frontend authority; some runtime grants are memory-only | Private authority boundary, not a default client replica. SQL access to an entire copy requires data authorization, not just a valid peer identity |
| CLI producer state | Pending claims/counter allocation and printed-answer positions differ from accepted Host state | Producer-local, private by default. A new transport does not make these duplicate truth. Legacy notice queue outcome remains open |
| Enrichment and search | Cached observations; search uses an in-memory ordinary table plus FTS virtual table | Host published observations may be inputs; Gateway builds derived views/indexes separately. Do not replicate the derived search database through this engine |
| Dormant Inbox and recovery witnesses | Retained read/write code/data; current dormancy. Recovery meaning depends on affected store | No feature resurrection or removal selected. Recovery witnesses stay with their actual store; no generic global recovery flag |

## Recommended initial unit model

This is a source-grounded recommendation for discussion, not an adopted schema/file split. A unit means one coherent database identity, one write-authority history and one transaction boundary for the selected state; it does not mean all files or processes associated with it have moved.

| Candidate boundary | Keep together / separate | Why |
| --- | --- | --- |
| Host operational unit | Execution association, provider binding/evidence, context ordering, asks and answer settlement in one authoritative Host transaction domain | Title/line/ask admission reads the current binding inside the write. Splitting Sessions from context across services would weaken this predicate unless explicitly redesigned |
| Host annotation workflow | Keep saved revisions, draft/edit fences, exact output membership and finalization together. Initially it may share the Host operational database | Finalization updates the attempt/event, exact revision membership's handled state and session revision atomically. Native output is outside that transaction |
| Host topology/observation | Keep source-owned repository/worktree/watch/absence/coverage meaning at Host. Physical co-location with operational state is a starting option, not an inferred current cross-file transaction | Current Core topology and Local activity commits already differ. An FSEvents volume cursor is private source-resume state, not evidence of current coverage on another Host |
| Client composition unit | Workspace/tab/split/Undo/navigation intent separate from execution custody | A layout may reference several Hosts. Shared scope is selected; a designated existing Host is the current authority proposal. Exact field/Undo/navigation cuts remain; a read copy is not another layout writer |
| Private authority/producer boundaries | Separate meaning and export policy, not necessarily a separate physical database file | Credentials/grants and CLI pending claims are not UI metadata. A private intake cursor can still participate in the same Host transaction as its admitted effect |
| Derived local read models | Gateway/native projections and search remain separate from faithfully copied rows | A projected/indexed shape changes for a different reason, may be rebuildable and does not acquire Host mutation authority |

Start the schema study with a coherent Host operational unit, rather than one unit per pane/session/project. Add a project partition only when a selected isolation/mobility/size requirement justifies cutting the existing transaction groups. This recommendation does not require merging every Host table into one unit. It keeps the strongest current predicates visible while the exact target table list is designed.

### Transaction edges the unit split must preserve

The [current transaction walkthrough](transaction-boundaries.md) traces notice/cursor admission, output preparation/effect/finalization, private local tables and the newer writer/receiver boundaries. It distinguishes actual wired paths from optional repository seams.

| Current edge | Exact boundary | Consequence |
| --- | --- | --- |
| Sessions binding → context title/line/ask | [Ordered writes](../../../../../../Sources/AgentStudio/Core/PaneContext/PaneContextService+OrderedWrites.swift:25), [message admission](../../../../../../Sources/AgentStudio/Core/PaneContext/PaneContextService+Messages.swift:20) read and write inside the same database closure | No network preflight followed by an unfenced write |
| Admitted CLI notice → handled intake position | [Commit participant](../../../../../../Sources/AgentStudio/App/PaneAgents/CLIOutboxCursorCommitParticipant.swift:6) writes using the effect's transaction. The current notice drain supplies it; a hook repository's optional participant seam is not evidence of a wired hook-intake cursor | Private-from-readers does not mean independent transaction or disposable state |
| Annotation finalization → exact handled membership/session revision | [Output finalization](../../../../../../Sources/AgentStudio/Features/Bridge/State/SQLite/WorktreeAnnotations/WorktreeAnnotationSQLiteRepository+Output.swift:362) | Moving only output attempt rows to the client would split a real atomic workflow |
| Repository activity → volume watermark | [Activity commit](../../../../../../Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceLocalRepository+RepositoryLocalActivity.swift:12) | A copied activity row alone is not a valid source checkpoint on another machine |
| Core composition → Local memory | [Core/Local save](../../../../../../Sources/AgentStudio/Core/State/SQLite/WorkspaceSQLiteDatastoreActor.swift:147) are separate commits | Do not invent atomicity across every current table just because one Swift store coordinates them |

### Reading a copy and starting a new writer are different capabilities

Database-writer transfer is now outside current scope. The different-writer capability below is future work, not a current adoption gate. Same-owner Host restart/restore, initial setup and faithful Gateway refill still need their selected recovery contracts.

A Gateway read copy needs the selected query state. A future writer seeded from a copy needs **all state necessary to preserve the selected write contract**: ordering/duplicate receipts, writer fences, recovery state and any authority re-enrollment contract, not only visible rows. Excluding private/internal tables is not automatically compatible with writer takeover.

For each unit, select one of these meanings before its export schema is fixed:

- **Writer-recoverable unit:** the authoritative snapshot plus explicitly declared re-enrollment/reconstruction is sufficient to create a new writer without weakening its admission guarantees. Public copies may still need a separate read-access policy; possession of the whole DB is a data-access grant.
- **Read publication:** sufficient to display/query selected state, with no claim that it can seed the operational writer. If implemented as its own replicated DB it has its own meaning and writer, not a transformed copy silently substituted for the source DB.

The shared library supplies faithful replication, not automatic conversion between these capabilities. No second publication database is selected here. The distinction is the schema/recovery question that must be answered before deciding which private tables can be omitted.

## Decisions, in dependency order

Every row is an AgentStudio consumer decision or research question. A Lead recommendation is not an owner selection. The shared library's algorithm is not reopened by this map.

| ID | Decision | Current recommendation / evidence | What depends on it |
| --- | --- | --- | --- |
| D01 | Separate Host work, client composition, native facts, private authority and projections | Preserve these semantic owners. The SQL filename is not the domain boundary | Every unit, table list and read API |
| D02 | Host-wide metadata versus per-project replication units | Start by testing a coherent Host metadata unit; per-project cuts must preserve cross-repo/session/binding checks. Do not cut by today's pane or workspace alone | Atomic operations, DB IDs, lease scope and selective data access |
| D03 | Exact declared tables and fields | Candidate families above; current mixed pane containers need a domain split before target tables are chosen. Private authority/producer state and derived FTS are not default exports | Data exposure, schema and copy readers |
| D04 | Shared composition realization | IP11/IP12 select shared tabs/layout and read state. The designated-existing-Host proposal supplies authority; exact navigation, Undo/custody and target schema remain to design | Shared unit membership, revision checks and native projection |
| D05 | Public resource identity and row keys | Host-qualified references; distinct database/incarnation/epoch/session/view identities. The inspected engine requires immutable canonical UUIDv7 values in every replicated PK component, declared TEXT NOT NULL. Composite UUIDv7 keys can qualify; legacy integers/provider/path/order keys are not presumed admissible. Local-only keys have their own contract | Target identity/association mapping, routing, deduplication, joins, migration and recovery |
| D06 | Target DDL and migration contract | Keep private storage rows distinct from wire/domain types where responsibilities differ. Every declared table needs a PK; no replicated triggers/virtual tables under the shared profile. Preserve integrity rules in the chosen target realization | Engine admission and migration proof |
| D07 | Central authority binding and initial setup | Central control-plane lease authority selected by the owner. Bind exactly one issuer per database across Hosts/Gateways; define the registry's relationship to authoritative replication copies separately. Gateway routing/projections consume authority | Renewal independent of Mac presence, initial setup and source/copy availability; exact copy binding still to define |
| D08 | Lease expiry and write-gate coverage | Specify exactly which operations pause and which running processes/terminal interactions continue. Four hours/15 minutes are Router configuration, not inherited AgentStudio values | No-client outcome, input admission, terminal fact collection and UI errors |
| D09 | Database-writer transfer | **Out of current scope by owner instruction.** No current move/takeover or automatic promotion of another writer. Initial setup/renewal and same-owner recovery are separate contracts | No transfer API/UI or transfer-specific AgentStudio proof gate now; shared library remains reusable |
| D10 | Incarnation after restore/recreation | A DB ID with rolled-back history cannot silently reuse old positions. Preserve identity or refuse/reseed through a declared operation | Cursor validity, backups, cloned hosts and recovery |
| D11 | Delivery retention and product retention | Evaluate bounded delivery retention/resnapshot for absent Gateways. Choose retained asks/evidence/annotations/receipts separately. Time alone does not bound bytes | Disk quotas, catch-up and offline reads |
| D12 | Replica read freshness and recovery | [Read-contract evidence and offline profiles](replica-read-contract.md). Preserve source/copy/position/epoch and declared validity; copy progress does not prove source coverage or command effect. Revalidate actions at the authoritative Host. The shared SO17 takeover-tail case is future work for this consumer | Honest status/ask/history UI, refill and same-owner recovery |
| D13 | Atomic receiver hook and acknowledgement | Current receiver documentation requires applied rows/position and durable follow-up intent committed before answering. AgentStudio must honor that host contract; external delivery/effect completion remains separate and follow-ups can repeat with the same call identity | Correct host transaction integration, sender pruning, hook failures and effect-specific handling |
| D14 | After-commit effect outcomes | At-least-once dispatch needs a stable work ID and operation-specific deduplication or explicit unknown/partial outcomes. A replica refill cannot trigger business actions merely because rows reappear | Projections, native effects, retries and crash proof |
| D15 | Domain notifications and prepared views | Use bounded typed invalidations/views derived from a committed transaction; select ordered versus latest-state per domain. No automatic domain event per CDC row | Bus, subscriptions, query indexes, MainActor volume |
| D16 | Permissions and version compatibility | Consumer authenticates peers, authorizes database/table scope and operations. Preserve supported Swift/UDS/Rust schemas separately from internal SQL migrations and replica protocol | Safe copy access, rollout/refusal behavior and tests |
| D17 | Bulk/terminal lane boundaries | Metadata replication carries selected retained state. Stateful VT/input and large file content have their own flow/currentness/control contracts | Interactive latency, backpressure and memory |
| D18 | Required proof and performance bounds | Real source→capture→session→receiver→query/client path, induced failures and controlled lease clocks; measure before selecting quantitative limits | Adoption eligibility and accepted performance |

The [optional durable-delivery analysis](durable-delivery-fit.md) separates custody from local acceptance/effect, preserves the local call's uncertain outcome and compares it with today's notice-only offline queue. It chooses no operation to enqueue and no relay placement.

The [typed input/reducer map](typed-input-processing.md) evaluates D15 across the incoming families: required ordered transitions, replaceable snapshots, scope-preserving invalidations, faithful replication, terminal bytes and native ingress. Compile-time shape checks and runtime source/authority/currentness checks remain separate.

## The cuts most likely to change this design

### Registry reachability versus autonomous Host writes

The owner selected central control-plane lease authority, replacing the temporary Gateway-hosted assumption. There is one designated authority binding for each database, even when multiple Gateways read it. Gateways are authority consumers, not competing issuers. The central registry's durable state and its relationship to an authoritative replication copy still need concrete design; selecting the registry owner does not move all Host data to central.

The shared plan's SO14 pauses a writer whose lease is no longer provably valid, while U15/R9/R10 retain Host-local inputs/facts without Gateway presence. A Host therefore cannot depend on a Mac Gateway being present to renew/admit that work. The exact control-plane connection and duration/renewal/expiry profile remain G13. Central reachability is a different failure condition from Gateway absence; central placement does not select indefinite grace, a gate bypass or a silent reduction in Host autonomy.

| Responsibility | Selected role / boundary |
| --- | --- |
| Lease registry, writer grant and epoch/fence decisions | Central control-plane authority; the shared rules decide validity |
| Host domain rows and eligible writes | Addressed Host as writer under its lease; no second domain writer at central or Gateway |
| Faithful copies and query projections | Configured receivers/Gateway views; read state does not confer write authority |
| Ready-machine client access | Mac or iOS Gateway; provisioning, moving and copying machines remain future control-plane work |

The client-to-Gateway-to-Host operation route is unchanged. The lease-control contract is separate from terminal bytes, metadata replication and principal authentication; it is not a new hop for every keystroke. Exact renewal messages, transport, credentials, server storage and authoritative-copy placement are still unselected.

### Lease state versus actual application work

The shared specification's SO13–SO25 and its proposed `begin_write` API supply the constraints below. They are design contracts, not evidence of a running AgentStudio engine. IP4 selects pause/refusal for invalid/lapsed writer authority without a hidden spool or execution kill. Exact duration/renewal and operation gate coverage remain to design; no expired-write exception is selected.

| Condition | Checked constraint | AgentStudio consequence or exact open contract |
| --- | --- | --- |
| Every Gateway disconnects | U15/R9/R10 preserve Host-local work and facts | Central renewal cannot require a Mac Gateway; frontend availability is separate |
| Central connection drops while the cached lease is provably valid | SO14 uses the holder's conservative validity bound; SO20 keeps the logical session | Connection loss alone is not lease expiry or execution-session termination; exact renewal scheduling is unselected |
| The holder can no longer prove an unexpired lease | SO14 stops accepting writes; the shared writer becomes paused | Identify every lease-governed operation. Outage duration tolerance, fact recording and any retained pending intent remain open; there is no selected extra grace or spool |
| The same epoch renews | SO14 resumes writes; SO18 replays duplicate renewal answers | Do not create a new execution session or writer epoch merely because connectivity returns; application retry/reconciliation remains operation-specific |
| The lease expires | SO15 forbids automatic holder changes | No promotion of another Host or Gateway; writer transfer remains excluded |
| An authenticated peer is revoked | SO19 ends sessions without changing its leases; SO25 also distinguishes connection credential expiry | Authentication, application permission and writer-lease validity are separate. Immediate write revocation cannot be inferred from connection closure |
| A transaction starts before expiry and reaches commit after it | The newer inspected writer checks admission at begin, guarded statements and commit, then rechecks after pending-key validation immediately before calling SQL commit; refusal rolls the transaction back | Integrate that actual write boundary and prove it with a controlled clock. This source check does not settle AgentStudio's expired-lease policy for already-running processes, external effects or all fact recording |
| An admitted context message is committed | Current message admission and its CLI handled cursor share one transaction | A lease refusal must not commit only the intake cursor or falsely report the message accepted; retain binding/message/cursor atomicity |
| An external output effect precedes SQL finalization | Current finalization commits attempt/event, exact message revisions and session revision together | Losing write authority cannot imply that an external file/clipboard effect was undone. Preserve partial/unknown outcomes and avoid blind replay |
| A shell or Git process is already executing | SQL write admission does not establish OS-process quiescence | Specify terminal input, process lifetime and fact coverage separately. No automatic process termination, suspension or filesystem rollback is selected |

The next proof slice must distinguish: Mac absence with central available; central loss before lease expiry; conservative expiry; same-epoch recovery with a lost renewal answer; transaction/expiry overlap; process or native effect before finalization; and credential revocation while a writer lease remains valid. Each needs a declared outcome before execution. A short reconnect test cannot establish this whole contract.

### Separately composable authority hosting

The selected authority home is the future central control plane. Keep its integration boundary focused on lifecycle, storage/clock/authentication dependencies, designated database bindings, current consumer operation admission and the shared rules' effects. Current operation admission excludes writer transfer even though the generic shared protocol can represent it. Lease rules stay in `fleet-sync-lease`; receiver rules stay in `fleet-sync-receiver`. Gateway routing, read-model construction and native/UI projections are separate consumers, not alternate issuers or direct writers of registry tables.

A crate is justified if it owns this integration/lifecycle boundary; a module is enough if it provides the same separation without a forwarding layer. The owner permitted either. Do not create another lease algorithm or a general service framework. No extra runtime or independent server is built for this scope.

Any later deployment or rehosting must preserve registry state, epoch history, trust and the one-active-issuer invariant; moving code alone does not migrate authority safely. This design does not introduce a temporary Gateway authority implementation while waiting for central. Authority-server work and any later deployment/data move remain distinct from a database-writer transfer feature; no migration algorithm is selected now.

### Declared tables are the copy boundary

The shared plan supplies table selection and faithful rows, not column/row filtering or transformed copies. If part of a legacy row belongs to another client or contains private authority, it needs a separately designed schema/unit or read contract before that table is declared. API-level filtering after a peer already receives the entire copy does not undo the exposure. Migrations also need a coherent selected-schema contract: a whole SQL migration must not silently introduce undeclared/private schema or break an included foreign-key dependency.

### Committed copy versus completed after-commit work

The newer [receiver host contract](fleet-sync-consumer-fit.md#current-library-source-and-prs) requires the host to commit replica rows/position, in-transaction hook writes and admitted follow-up intent before answering. This supersedes the earlier recommendation-only wording here. It is the recoverable apply boundary. Actual external follow-up is separate and may repeat with the same call identity; its effect is not included in the copy acknowledgement.

AgentStudio must implement that host contract and define its selected hook and follow-up outcomes. Waiting for a UI subscriber or native effect is not required to acknowledge committed apply. A person action or completed external effect needs its own observation rather than a stronger meaning silently assigned to that acknowledgement.

Hook SQL can legitimately refuse an entire piece atomically. Keep only required local projection/index work in that hook; arbitrary remote/native work belongs after commit. Required versus optional projection failure and whether a failed item blocks later items remain explicit policy. Refill/rebuild invalidations are not fresh user commands.

Hook-owned projection/outbox state must remain separate from the faithfully replicated source rows. Sharing a SQL transaction does not grant the hook a second authority to rewrite Host truth.

## Proof map — proposals, not executed experiments

| Existing family | AgentStudio-specific discriminator | Observable outcome |
| --- | --- | --- |
| E2 autonomy/effects | Real session binding + ask/answer transaction through capture and two receivers; lose reply after commit | Same admitted outcome and exact values; no half workflow, invented failure or duplicated external operation |
| E2 autonomy/effects | No Gateway reachable while central remains reachable; advance the controlled lease clock across renewal/expiry. Separately make central unreachable | Host-local work and renewal preserve Mac independence; the distinct central-outage case follows the selected G13 write-gate policy. Keeping the test below expiry proves neither |
| E2 authority placement | Attach two Gateways to one Host; inspect the real grant/renewal entry and deny a Gateway-issued writer grant | Exactly the designated central authority decides leases. Gateway attachment is not lease issuance; no authority-switch or writer-transfer workflow is built |
| E3 fanout/recovery | Stall one Gateway past retention while another advances; source continues | Independent progress; explicit needsSnapshot and a correct consistent refill |
| Deferred consumer scope | Explicit takeover/follower rejected-tail behavior | Database-writer transfer is excluded now. Shared-library transfer proof stays with that library; no new AgentStudio takeover journey is required for current adoption |
| E2 authority scope | Attempt a database-writer change through the actual exposed authority entry | The unsupported operation causes no accepted writer change. No takeover workflow is built; absence of a UI button alone does not prove the protocol boundary respects scope |
| E2/E3 | Crash between apply commit and after-commit dispatch, then replay/refill | Pending work survives under stable identity; duplicate/unknown results follow the operation contract; ack meaning remains truthful |
| E2/E3 | Valid immutable UUIDv7 keys, invalid key/schema and key-assignment refusal, migration, split transaction, source restore/new incarnation | Actual selected schema/value admission and unchanged original rows after refused key mutation; schema-ordered rows and safe cursor refusal/reseed. Legacy key changes are not a supported delete/upsert arm under the newer engine |
| E2 | Begin a transaction before lease expiry, commit after it; separately let a Git/native operation perform its effect before metadata finalization loses authority | Exact selected admission/commit/effect boundary. No assumption that a database gate rolls back filesystem work or that a fenced SQL writer's process has stopped |
| E5 route cost | Representative metadata, annotation payload and multi-Host aggregation under terminal load | Measured capture/apply/query cost, backlog bytes, refill and native publication. No every-byte VT row stream |
| E6 phone lifecycle | Phone Gateway reconnects with the same Host session available | Arrangement behavior matches the chosen client scope; execution and attachment/connection identities remain separate |

## Evidence boundary

Read whole: the supplied shared repo's [Requirements](../../../../../../../codex-router.collab-improvements/docs/specs/2026-10-16-agent-fleet-sync/requirements.md), [Specification](../../../../../../../codex-router.collab-improvements/docs/specs/2026-10-16-agent-fleet-sync/2026-10-16-agent-fleet-sync.md) and [Program Design](../../../../../../../codex-router.collab-improvements/docs/specs/2026-10-16-agent-fleet-sync/program-design.md), current working files observed 2026-10-16. Its SU7/SO13–19 select shared lease mechanics; SG8 leaves AgentStudio placement/configuration to this work. SO12/SG7 and SO17 carry the hook/follower consequences above. Its engine probes and code-line diagnoses are author-reported, not rerun here.

Source facts about AgentStudio come from the linked inventory and its inspected primary anchors. The units, membership, acknowledgement meaning and detailed experiment cases are Lead proposals. Central control-plane lease authority, the ready-machine Gateway boundary, transfer exclusion and integration separation are direct owner constraints, normalized as U20/U21/R14. No shared repository was created/edited, no package was adopted, no product source/config/runtime/migration/probe was changed or run, and the closed Advisor was not contacted. The authoritative draft remains unfinished with its other explicit gaps.
