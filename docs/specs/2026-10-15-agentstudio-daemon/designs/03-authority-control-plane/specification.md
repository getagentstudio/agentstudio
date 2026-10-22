# Authority, leases and central control plane: observable contracts

This is the DS03 slice of the [system Specification](../../2026-10-15-agentstudio-daemon.md). The separate [Requirements](../../user-requirements.md) authorize its meaning; the [domain definitions](../../domain-entities.md) and shared [operation interpretation](../../capability-contracts.md#shared-interpretation-of-an-operation) apply. Its [design brief](README.md) owns scope, inputs and unresolved work. Existing open gaps are preserved; this partition selects no new behavior.
The [initial profile](../../initial-profile.md) supplies the selected IP1–IP12 directions. Remaining gaps concern their exact contracts and realization; they do not reopen the selected high-level choices.


## K14 — Principal, scope, authority and revocation

Database-writer lease authority follows U20/U21/R14: central control plane, separately composable integration, later server implementation and no writer transfer. Another Gateway does not create another issuer; Gateway starts with ready, connected machines. IP4 selects pause/refusal for work requiring invalid/lapsed writer authority, without a new spool or presentation-driven execution termination. Actual setup, authority/copy binding, duration/renewal and precise gate/failure/coverage outcomes remain G13. Writer authority is distinct from principal/authentication leases. Losing a Gateway is not loss of Host-local authority; central registry ownership does not centrally place every record, copy or terminal stream.

**Consumer / entities / basis:** authorized user/agent and operator; E4/E10/E17/E18; U9/U15/U17. Valid operation shape, channel/exposure, capability availability, kind-qualified target and authority are independent admissions. Payload-provided actor/provider/device names are not authenticated identities.

Current same-UID socket/bearer/principal/lease and pane-membership checks are local evidence. IP9 selects a paired private fleet; it does not replace cross-machine credential custody, authentication, shared-user/scope binding, revocation or effect-time checks under G8/G12. One credential creating multiple principals does not prove shared grants or process identity. Internal grant functions do not create a public `permission.*` API absent from the fifty-seven-name catalog.

U15 requires authorized integration during presentation absence. In-session authorization concerns the Host execution context under R9; mere local socket reachability grants no authority. Current grant/revocation checks are a baseline foundation, not an owner-selected independently-revocable cross-service policy. Exact credential, revocation/effect races and retained receipts remain G8/G12; connection authentication does not settle them.

**Proof:** actual allowed/denied actors/scopes at the selected entry and effect boundary, stale binding, cross-target and channel refusal, independent lease survival, revoke-during-held-work and result-loss cases. For R14, additionally establish the designated central issuer, absence of Gateway-issued writer grants, and the selected renewal/expiry behavior with all Gateways (macOS and iOS) absent. Schema correctness, TLS connection or a grant in memory alone is not that proof. No process attestation, regulatory certification or authority-server implementation is implied by this design correction.
