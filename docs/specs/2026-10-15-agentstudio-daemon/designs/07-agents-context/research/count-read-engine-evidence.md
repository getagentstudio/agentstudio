# Context-count reads: local engine source qualification

Source-only inspection on2026-10-18 of the clean local `agent-fleet-sync` main checkout at `3a2153ec98de531085b4c4e618b972dffbb1f08e`. This is a newer bounded source observation than the historical six-PR consumer-fit baseline. It does not update that baseline's PR/deployment claims, adopt this dependency, or establish an AgentStudio runtime result.

## A reader is distinct from writer admission

| Checked source | Observation | Limit |
| --- | --- | --- |
| [`replicated_database.rs:375`](https://github.com/agent-collaboration/agent-fleet-sync/blob/3a2153ec98de531085b4c4e618b972dffbb1f08e/crates/fleet-sync-writer/src/replicated_database.rs#L375) | `reader()` returns `&ReadPool` without invoking writer-state admission | It supplies a read executor, not proof that storage/recovery/caller authorization always succeeds |
| [`read_pool.rs:19`](https://github.com/agent-collaboration/agent-fleet-sync/blob/3a2153ec98de531085b4c4e618b972dffbb1f08e/crates/fleet-sync-writer/src/read_pool.rs#L19) | Public reader has no writable pool/acquire API. Each executor path checks the read statement profile, obtains a reader guard and accesses the native pool; no `LeaseHolder::writer_state` call occurs on these shown read paths | Pool closure, exclusive lifecycle work, recovery and source errors remain possible. This is not a runtime outage test |
| [`replicated_database.rs:393`](https://github.com/agent-collaboration/agent-fleet-sync/blob/3a2153ec98de531085b4c4e618b972dffbb1f08e/crates/fleet-sync-writer/src/replicated_database.rs#L393) and [`write_transaction.rs:26`](https://github.com/agent-collaboration/agent-fleet-sync/blob/3a2153ec98de531085b4c4e618b972dffbb1f08e/crates/fleet-sync-writer/src/write_transaction.rs#L26) | Guarded writes restore/check authority; transaction admission, checked statements and commit consult writer validity | A read-side maintenance write cannot use the reader to bypass this path |
| [`statement_guard.rs:87`](https://github.com/agent-collaboration/agent-fleet-sync/blob/3a2153ec98de531085b4c4e618b972dffbb1f08e/crates/fleet-sync-writer/src/statement_guard.rs#L87) | `check_read` has its own statement profile; mutation/connection-control forms have refusal variants | Parser declarations are source evidence, not an executed security/completeness audit |

The proposed count-only Host operation can therefore target a read executor separately from the writer gate. It must still use admitted application read scope and handle actual storage/lifecycle failures. Invalid writer authority alone is not a reason to invent a write in a count projection.

## The value and its witness still need one read boundary

The public reader does not expose `acquire` or a public multi-query read transaction in the inspected file. Consecutive executor calls can use different pooled connections/observations. The adapter cannot read counts, then independently read a revision, and claim that pair came from one snapshot merely because both calls used `ReadPool`.

One supported coherent query may suffice for a selected application schema and its own domain witness. Otherwise the consumer needs an explicit supported read interface. Exact SQL, schema/unit binding and engine/copy witness integration remain unimplemented and unproved. This inspection did not select a generic read-snapshot API, invent a private bookkeeping query, or establish runtime receiver-copy read behavior.

## Copy rules and full-service access differ

The later bounded source check at the same commit found an existing public copy-status rule. A private storage helper is not evidence that the consumer must parse private bookkeeping.

| Public surface | Checked behavior / limit |
| --- | --- |
| Receiver [`copy_status`](https://github.com/agent-collaboration/agent-fleet-sync/blob/3a2153ec98de531085b4c4e618b972dffbb1f08e/crates/fleet-sync-receiver/src/copy_lifecycle.rs#L112), [reexported by the crate](https://github.com/agent-collaboration/agent-fleet-sync/blob/3a2153ec98de531085b4c4e618b972dffbb1f08e/crates/fleet-sync-receiver/src/lib.rs#L41) | Accepts a borrowed public `TransactionScope` and returns `CopyStatusAnswer`. A consumer with a real coherent scope can combine that rule and its own reads without private-table SQL. The scope trait alone proves no isolation |
| Native [`TokioObject::rule_transaction`](https://github.com/agent-collaboration/agent-fleet-sync/blob/3a2153ec98de531085b4c4e618b972dffbb1f08e/crates/fleet-sync-tokio-runner/src/native_object.rs#L186) | Supplies a borrowed scope, but begins `BEGIN IMMEDIATE` under its connection lock. It is not a demonstrated concurrent read-only snapshot; local copy-apply contention must remain visible |
| Full-service [`copy_status`](https://github.com/agent-collaboration/agent-fleet-sync/blob/3a2153ec98de531085b4c4e618b972dffbb1f08e/crates/fleet-sync-service/src/service_handle.rs#L33) and [`ConsumerHandler`](https://github.com/agent-collaboration/agent-fleet-sync/blob/3a2153ec98de531085b4c4e618b972dffbb1f08e/crates/fleet-sync-service/src/service_contract.rs#L17) | Status uses its own internal copy transaction. The inspected consumer request callback receives peer/request, not a borrowed SQL scope. No public combined application-read/status callback was found on that surface in this bounded pass |

Lower-level receiver-rule composition and the full-service façade therefore have different access contracts. Their existence does not select either integration or prove that a new library primitive is necessary. Actual isolation, published-file/read lifetime, application permission, selected schema and target support still need qualification. A before/after acknowledgement number alone cannot prove coherence across source replacement, refill or independently rebuilt local projections.

No engine or AgentStudio product files were changed. No build, test, SQL execution, lease-clock experiment or iOS/Linux qualification ran. A safe local source read supplied this evidence after the external research route was unavailable; the design does not rely on an external synthesis answer.
