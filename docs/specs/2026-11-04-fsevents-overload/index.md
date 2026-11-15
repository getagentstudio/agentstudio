# FSEvents overload design set (LUNA-581)

| Document | Settles |
| --- | --- |
| [Requirements](2026-11-04-fsevents-overload-requirements.md) | who is affected, the owner's asks U1–U7, the goal boundary and non-goals |
| [Specification](2026-11-04-fsevents-overload-specification.md) | entities E1–E8, obligations R1–R8, the observable contract, proof obligations V1–V9 |
| [Program Design](2026-11-04-fsevents-overload-program-design.md) | today versus the target pipeline, owners, interfaces, the obligation lifecycle, failure handling, the trace table |
| [Verification Design](2026-11-04-fsevents-overload-verification-design.md) | how each requirement will be proven, and what stays unverified |

Human entry: [page.html](page.html).

## Reading paths

**Irrelevant churn starts no scan:** [U2](2026-11-04-fsevents-overload-requirements.md#what-the-owner-asked-for) → [R1](2026-11-04-fsevents-overload-specification.md#requirements) → [source filter on the main path](2026-11-04-fsevents-overload-program-design.md#the-main-path-step-by-step) → [R1 coverage row](2026-11-04-fsevents-overload-verification-design.md#coverage-rows)

**A burst becomes one paced scan:** [U3, U4](2026-11-04-fsevents-overload-requirements.md#what-the-owner-asked-for) → [R2–R4](2026-11-04-fsevents-overload-specification.md#requirements) → [obligation lifecycle](2026-11-04-fsevents-overload-program-design.md#the-obligations-lifecycle) → [R2–R4 rows](2026-11-04-fsevents-overload-verification-design.md#coverage-rows)

**Discovery stays correct:** [U7](2026-11-04-fsevents-overload-requirements.md#what-the-owner-asked-for) → [R5–R7](2026-11-04-fsevents-overload-specification.md#requirements) → [failure table](2026-11-04-fsevents-overload-program-design.md#failure-recovery-and-concurrency) → [R5–R7 rows](2026-11-04-fsevents-overload-verification-design.md#coverage-rows)
