# DS06 — Worktree fork and platform counterpart

## Read this folder

- [Folder HTML reader](index.html).
- [Specification: Markdown](specification.md) · [HTML](specification.html).
- [Shared Requirements](../../user-requirements.md) · [overall Specification](../../2026-10-15-agentstudio-daemon.md).

Fork eligibility and complete source/destination/registration/HEAD/index/content/metadata behavior, plus application create/remove/archive/prune policy outside Git SDK mechanics.

## Contract and inputs

- Requirements: [shared authoritative source](../../user-requirements.md), scoped to U4/U5/U6/U11.
- Specification: [this design's capability contracts](specification.md), owning K4; apply R2/R4 and the shared [observable spine](../../2026-10-15-agentstudio-daemon.md).
- Domain definitions: [global identity appendix](../../domain-entities.md) and E1–E6 in the spine. This folder creates no new identity merely by being separate.
- Required contract inputs: [DS05](../05-git-discovery/README.md)

## What this design must settle

- Choose eligible filesystem/kernel profiles and clone-versus-copy policy; no silent byte-copy fallback is selected.
- Define ignored entries, symlinks, special nodes, hardlinks, xattrs, ownership/times and non-UTF-8/collision outcomes.
- Preserve joined cancellation, cleanup residue and the difference between activity not checked and proved idle.

## Result consumed by later designs

A Linux counterpart contract tied to the Mac reference, including admitted filesystem/name/metadata profiles and truthful failure/cancellation receipts.

## Evidence to reopen

- [2026-10-16-daemon-worktree-fork-contracts.md](research/worktree-fork-contracts.md)
- [2026-10-15-daemon-linux-feasibility-probe.md](experiments/linux-feasibility.md)
- [fork-package-contract-evidence.md](../../research/evidence/2026-10-15-daemon-extraction-survey/fork-package-contract-evidence.md)

## Proof boundary

Complete real worktree/ref/index/filesystem journeys and profile/metadata/special-node/cancellation/residue cases on both platforms. E4; no Fly provisioning or probe execution is authorized by this folder.

## Design cycle

Use the [common cycle and completion rule](../README.md#each-design-cycle). The scoped Specification here contains carried-forward draft contracts, not a completed Program Design. Author its structural realization after the affected meaning is settled, then complete Verification Design and independent four-document review. Bring only actual unresolved owner decisions to Sun; there is no generic structural-confirmation gate. There is no empty `program-design.md` standing in for unfinished work. Required missing meaning remains explicit, and unrelated source research can proceed.
