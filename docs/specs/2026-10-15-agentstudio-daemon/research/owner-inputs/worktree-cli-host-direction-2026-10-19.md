# Worktree CLI uses the Host daemon

Direct owner messages in the Lead session, in order:

> start formal review.  worktree li starts gateway

> but honestly its reverse, wotkree cli shodu work with deamon not gateway

The second message corrects the first: machine-scoped worktree CLI operations belong to the addressed Host daemon, rather than the device Gateway. This supersedes the earlier S25/IP3 classification for this class; it does not change UX client → Gateway → Host access.

The Advisor separately relayed first-hand owner statements on the existing daemon work thread, activity 8876, message `01a15715-d917-7620-9dc5-232820c0e793`:

> yes start worktree cli works w2ith deamon not gateway?

> it shoud work with remote deamon, nto srue why it woukdl work with gateway?

That relay records “yes start” as selecting start or activation of an absent local Host daemon. This bootstrap statement is owner meaning relayed by the Advisor, not a direct quotation observed in the Lead session. The Lead's preceding message has the same start intent and is corrected to the Host role by the subsequent direct message.

Selected consequences: worktree CLI machine operations use their executing machine's attached Host on macOS/Linux; Gateway absence is not a dependency. Exact startup/supervision/readiness, non-session caller admission, supported artifacts and truthful failure/results remain design work. Whether a Mac-side CLI can directly address a different remote Host remains open; the phrase “remote daemon” does not settle that access mode. UX-only CLI verbs need explicit classification rather than moving every CLI action to the Host. No service implementation, lease issuer, privilege escalation, remote auto-provisioning or mutation retry is authorized here.

## Later first-hand Advisor relay: remote command use

The owner's record supplied by the Advisor to the 20 October independent review includes a Mac CLI invocation addressing `--host vm-1`, alongside these quoted owner statements:

> fpyi th emac would have a deamon

> same arhciecture we can make it efficient

The retained [L1 review packet](../../../../../tmp/practices-research/2026-10-20-full-spec-review/packets/L1.prompt.md) records that first-hand relay; [Advisor synthesis](../../../../../tmp/practices-research/2026-10-20-full-spec-review/SYNTHESIS.md) O-B still treats local-Mac-Host relay versus a direct remote CLI connection and its credential as open. The remote worktree command use case is therefore required, rather than excluded merely because it starts on a Mac. These supplied statements do not by themselves select either of those network paths. Gateway is not the worktree execution owner. Existing local Host activation is not permission to provision or start an unavailable remote machine.
