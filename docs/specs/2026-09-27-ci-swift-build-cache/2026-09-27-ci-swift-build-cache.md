# CI Swift build cache — Specification

Status: reviewed (advisor rounds 4–5 in tmp/ci-speed/, round-5 remediation applied) · 2026-09-27 · Owner decision: option B.

Artifacts: [Requirements](2026-09-27-ci-swift-build-cache-requirements.md) · [Specification](2026-09-27-ci-swift-build-cache.md) · [Program Design](2026-09-27-ci-swift-build-cache-program-design.md)

Traces to Requirements U1–U4.

## Observable contract

- **O1** A main push never restores a Swift build. It builds cold. As soon as the cold prebuild succeeds and its inputs re-verify as unchanged, it publishes one seed, unless a newer main run has already published. It publishes before the Swift test lanes run, and whatever their results. Every Swift test lane still runs afterwards.
- **O2** A PR restores the newest main seed whose compatibility prefix equals its own, verifies it, and builds incrementally. On a miss, a failed restore, or any input change the verifier cannot prove safe, it deletes the whole build path and builds cold. There is never a warm attempt followed by a cold retry.
- **O3** Every input that differs from the seed in content, mode, kind, symlink target or directory membership is rebuilt. If that can't be guaranteed per input, the seed is discarded.
- **O4** A PR never saves a Swift build entry. Only main publishes, and only the main prune job deletes.
- **O5** After a successful prune, at most one owned seed remains. Save and prune failures degrade to "more entries or a cold build", never to a wrong build.
- **O6** Lane receipts still name the commit under test. Seed provenance (producer commit, run, fingerprint, manifest digest) is reported beside them.
- **O7** A PR reports restore, verify, stamp and build times separately. "Prebuild time" never hides the transfer cost.

