# Worktree fork and platform counterpart: observable contracts

This is the DS06 slice of the [system Specification](../../2026-10-15-agentstudio-daemon.md). The separate [Requirements](../../user-requirements.md) authorize its meaning; the [domain definitions](../../domain-entities.md) and shared [operation interpretation](../../capability-contracts.md#shared-interpretation-of-an-operation) apply. Its [design brief](README.md) owns scope, inputs and unresolved work. Existing open gaps are preserved; this partition selects no new behavior.
The [initial profile](../../initial-profile.md) supplies the selected IP1–IP12 directions. Remaining gaps concern their exact contracts and realization; they do not reopen the selected high-level choices.


## K4 — Worktree fork and application worktree policy

**Consumer / entities / basis:** Mac/Linux worktree user; E7/E8/E22; U5/U6/U11, R2/R4. The full [fork worksheet](research/worktree-fork-contracts.md) supplies W1–W11 source-qualified behavior and target gaps. Fork is a complete worktree operation, not a file-data-clone benchmark.

The contract must account for eligibility, source/destination validation, registration/HEAD/index, branch attachment, file content and admissible metadata, ignored files, symlinks/special nodes, cleanup/rollback and joined cancellation. Current success is not a complete manifest of every source entry: socket handling is path-specific, ignored exclusions can be count-only, nested paths have distinct observations, and vanished ENOENT entries may be unreported. A success receipt must not be described as a census the implementation does not provide.

Linux counterpart behavior remains required on IP7's one qualified initial profile. Its actual filesystem/kernel eligibility, clone-versus-copy behavior, non-UTF-8/collision rules, xattrs/mode/ownership/time, hardlinks/special nodes and residue must be explicit under G7. A supported leaf primitive does not satisfy that complete contract. No universal filesystem guarantee or silent byte-copy fallback is selected.

Application create/remove/archive/prune additionally has branch/evidence/activity policy outside SDK mechanics. Preview may fetch; it is not necessarily a pure read. Activity `notChecked` is not idle evidence. Target policy must preserve that distinction without copying Mac presentation or conflating stale-administration prune with removal of an integrated live worktree.

**Proof:** complete real worktree/ref/index/filesystem interaction on both platforms, metadata/name/special-node profile cases, cancellation and residual state. The prospective E4 Linux probe is feasibility evidence only; it cannot establish whole-feature parity.
