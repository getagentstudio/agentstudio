# Git experiment coverage — bounded source evidence

Status: **complete source comparison**, 2026-10-16. This document accounts for the existing 44 Git protocol requirements and F01–F13 against the written, unexecuted E1–E6 procedures. It does not author product requirements, test additions, a parity selection, or an execution plan. Counts describe this source catalog, not product acceptance or runtime coverage.

AgentStudio baseline is `624300332f5e50f7bb8cbb9fc786d5e5b4a3d462`; the inspected sibling Git checkout is clean at the exact consumer pin `4cca397dfc869857064da4e9ec8289ea46adc479`. Existing modified images and untracked daemon documents belong to the outer task. Only this evidence file was written. No build, test, probe, native app, VM, Fly, credential, runtime, network-service, board, helper, or Advisor operation was performed.

**Platform axis:** all 44 known current SDK-reference realizations in this comparison are macOS reference paths. The manifest supplies an [XCFramework-backed local target][platform-package], the remote process implementation [imports Darwin][platform-process], and native promotion [imports CLibGit2Local][platform-promotion]. This is evidence about the inspected realization, not a claim of impossibility derived solely from `Package.platforms`, nor a global claim about other OSS/Linux implementations. Shared behavioral wording could apply to a future Linux candidate, but these procedures qualify no concrete 44-operation Linux integration harness/realization. E4's proposed Linux leaf stimuli are a separate platform/API discriminator.

## Governing meaning and comparison rule

[Requirements U4–U6 and U11][requirements] require the full survey, Linux fork counterpart, explicit platform contracts and Host macOS/Linux parity. [Requirement boundary][requirement-boundary] still leaves per-capability allocation and acceptance meaning open. [Owner-source README][owner-source] fixes client → socket → Gateway → Host, macOS/Linux Host, macOS Gateway and advisory status of research mechanisms. The [295-line survey][survey] is observational input; its catalog is not an experiment result.

The [primary map][primary] explicitly says no experiment has executed. Its E2 source desk catalog mentions all 44 operations, but the [A0–A14 procedure][a-cases] expressly says its small case set does not replace operation-specific feature coverage. The [Linux procedure][linux-boundary] is a leaf/API discriminator, with full fork parity deferred. [E5][cost-boundary] distinguishes cost from feature parity.

Classification is the strongest written relationship found for a row:

- **Named stimulus:** an operation-distinguishing action is explicitly named, even if its Swift identifier is not written. This does not imply complete variants or an implemented harness.
- **Generic class:** a named workload/failure class is analogous, or the primary map names later expansion, but no operation-specific population, variant and oracle are bound.
- **Prerequisite only:** a fixture needs related identity/ref/validation/staging evidence before another assay. The relationship is an inference from the procedure and catalog, not an instruction to call that SDK method; raw fixture observations could supply it instead.
- **Absent:** no distinguishing case or applicable named workload class was found beyond the blanket 44-row catalog, general E2 rules, or generic “Git” wording. This means absent from these procedure texts, not absent from existing code/tests or future scope.

For conservative accounting, the generic A6 loss-at-four-boundaries rule is not credited to every API automatically. Nor does the word “clone” in the Linux filesystem probe mean remote Git `clone`. Independent local-ref observation does not mean network `remoteReferences`. A leaf FICLONE/metadata probe does not mean a `forkWorktree` invocation.

## Protocol identity check and operation matrix — 44/44

Direct extraction from [local/remote protocols][sdk] and [discovery protocol][discovery] yielded 33 + 10 + 1 distinct names. Equality against the existing [E2 Git catalog][git-catalog] yielded empty differences in both directions. Convenience overloads/default implementations are not additional requirements. Existing production-use tags below come from that catalog: **P** production-called, **S** SDK-only; they were not re-surveyed in this bounded task.

Result under the rule above: **3 named-stimulus, 14 generic-class, 6 prerequisite-only, 21 absent** rows. These disjoint labels are platform-independent document-specificity counts, **never Linux coverage scores**. The known current SDK realization/reference axis for every row is macOS; future Linux operation integration is unbound. Every row has **zero executed evidence** here.

| Existing row | Operation | Use | Procedure relationship | Exact anchor and observed limit |
| --- | --- | --- | --- | --- |
| L01 | `repositoryIdentity` | P | Prerequisite only | [A witness][a-witness] and [Linux environment receipt][linux-receipt] need identity evidence; neither selects the SDK path-derived repository-ID read or its missing/inaccessible cases. |
| L02 | `worktrees` | P | Absent | [A11][a-cases] observes refs/private namespace, not main/linked worktree listing, head/lock snapshots or unreadable registration. A list-shaped post-state is not specified. |
| L03 | `validateWorktree` | P | Prerequisite only | A11's owned repository and [run qualification][a-profiles] require valid setup; no invalid registration/missing-worktree result assay or SDK validation call is named. |
| L04 | `createWorktree` | P | Generic class | [E4 expansion][e4] names Git administration/index/CAS and A6 names effect loss. Ordinary detached-checkout/attach/upstream/LFS creation and its distinct rollback limits are not bound to a case; fork is not its substitute. |
| L05 | `forkWorktree` | P | Named stimulus | **A11: macOS realization/reference; future Linux integration unbound.** [A11][a-cases] explicitly includes joined fork cancellation. [E4][e4] names later F01–F13 expansion; [C10][linux-cases] is proposed Linux leaf cleanup, explicitly not full Linux fork cancellation. Materialization variants, every transaction phase and full receipts are not thereby covered. |
| L06 | `forkWorktreeEligibility` | P | Generic class | [C1/C3][linux-cases] characterize clone success/refusal and [E4][e4] names platform profiles. No SDK read-only eligibility operation, nonreservation property or stale eligibility→mutation scenario is bound. |
| L07 | `pruneStaleWorktree` | S | Absent | No stale-administration prune stimulus. Leaf unlink/cleanup and policy-level prune are different operations; neither supplies this API's prunability result. |
| L08 | `removeWorktree` | P | Generic class | [A6/A11][a-cases] provide general partial-effect/cleanup analogy and [E4][e4] names partial effects. No removal request or separate administration/directory disposition population is specified. |
| L09 | `lockWorktree` | S | Absent | Ref-lock/CAS wording in [E4][e4] is not Git worktree lock-marker/reason mutation followed by snapshot reread. |
| L10 | `unlockWorktree` | S | Absent | No worktree unlock stimulus, post-unlock reread failure or prior lock-state scenario. |
| L11 | `statusObservationPlan` | P | Generic class | [E4][e4] names filesystem-observation continuity/overflow; [E3][e3] names currentness. No SDK scope/config/attribute-plan result, support refusal or identity distinction is bound. |
| L12 | `statusFacts` | P | Generic class | [E5 workload][e5-work] names bounded Git/review work and [E4][e4] continuity. No literal-nil versus empty pathspec, untracked/submodule options or clean-baseline assay is bound. |
| L13 | `exactLineCountDetail` | P | Absent | No independently timestamped full-worktree line-detail stimulus, explicit submodule choice, or separation from scoped facts. Generic Git load does not name this read. |
| L14 | `completeStatus` | P | Generic class | [E5 workload][e5-work] can exercise a Git result class, but no sequential facts/line-detail aggregate or mutation-between-subreads case is selected. |
| L15 | `trackedPaths` | P | Absent | [E4][e4] index adoption is an internal fork operation, not stage-zero tracked-path query/scoping/raw-count behavior. |
| L16 | `isPathIgnored` | S | Absent | No one-path ignore-query input/result or ignore-rule-change stimulus. Ignored-copy inclusion in the deferred fork list is not this query. |
| L17 | `ignoredPaths` | S | Absent | No batch-ignore ordered input/result or all-error-versus-partial-array case. |
| L18 | `branches` | P | Prerequisite only | [A11][a-cases] needs independently known refs for an owned repository. No local branch/current/upstream catalog assay is named and its snapshot carries different evidence from exact ref OIDs. |
| L19 | `remoteNames` | P | Absent | No configured remote-name catalog or name-splitting case. A staged namespace is not configured remote inventory. |
| L20 | `branchUse` | P | Generic class | [E4 expansion][e4] names ref locks/CAS and [F11][fork-catalog] names branch use. No HEAD/rebase/bisect holding or unreadable-administration query population is bound in the procedures. |
| L21 | `aheadBehind` | P | Absent | No pinned graph same/ahead/behind/diverged count population. General ref readback does not supply it. |
| L22 | `assessBranchIntegration` | P | Absent | No same-commit/ancestor/content/empty-delta/squash/remaining/unknown/history-limit assay. Ref CAS is not integration assessment. |
| L23 | `deleteLocalBranch` | P | Generic class | [E4][e4] ref-lock/CAS and [A11][a-cases] partial-ref effects are analogous; no locked expected-tip deletion, checkout protection, absent-name reservation, config/reflog cleanup or uncertain result case is bound. |
| L24 | `resolveReviewDefaultTarget` | P | Absent | [E5 retained-seed arm][e5-work] does not select default-target resolution or absence/fallback behavior. |
| L25 | `captureReviewComparisonTargets` | P | Absent | No capture/cutoff/maximum-row/truncated catalog population. A generic bounded response is not the target-capture operation. |
| L26 | `resolveRevision` | P | Prerequisite only | [A11][a-cases] requires expected/current ref evidence and [E5 run freeze][cost-freeze] fixes payload/oracle identity. Neither names revision-resolution target variants, failure, or a selected SDK observer. |
| L27 | `readTree` | P | Absent | No commit tree/subtree, mode/OID or missing best-effort size assay. “Review/file-content” does not choose a tree API. |
| L28 | `diff` | P | Generic class | [E5 workload][e5-work] names review work; no supported/unsupported base/compare pair, rename/binary/mode/hash population is bound. |
| L29 | `countCommitRange` | P | Absent | No exact/at-least/unrelated/traversal-limit graph count case. |
| L30 | `summarizeDiffImpact` | P | Absent | No bounded/conservative impact or file/line/blob budget population. |
| L31 | `contributionDiff` | P | Generic class | [E5][e5-work] explicitly retains seed versus full-recomputation as a scoped sub-arm; it does not distinguish contribution-base semantics, bind a seed identity/fallback corpus or an actual route realization. |
| L32 | `directReviewComparison` | P | Generic class | Same [E5 sub-arm][e5-work]; direct selected-target meaning is not separately selected. [Local seed contract][seed] is not a serialized request shape. |
| L33 | `content` | P | Generic class | [E5][e5-work] names file-content work and [P5][cost-cases] decoded-byte comparison; no commit/index/contained-working-tree target, size cap, binary/hash or changing-file population is bound. |
| R01 | `clone` | S | Absent | [C1][linux-cases] is filesystem data cloning, not remote Git clone. [Linux scope][linux-scope] explicitly uses no external Git remote; no partial destination/checkout/auth clone case is named elsewhere. |
| R02 | `fetch` | P | Generic class | [A11][a-cases] concerns staged refs, not ordinary whole/branch-targeted fetch, FETCH_HEAD, post-fetch resolution or residue observation. General process/effect loss is only analogy. |
| R03 | `captureRemoteTrackingSnapshot` | P | Prerequisite only | A11's staged promotion needs captured/staged provenance in its fixture; no sequential configured/effective-URL/common-dir/tracking-ref capture assay or actual SDK setup invocation is bound. |
| R04 | `stageFetch` | P | Prerequisite only | A11 needs a stage to promote/clean; it does not specify failing network stage/object/private-ref fetch or promotion-guard creation as the assay. Setup is not stage-effect coverage. |
| R05 | `promoteStagedFetch` | P | Named stimulus | **A11: macOS realization/reference; future Linux integration unbound.** [A11][a-cases] explicitly fails staged-ref promotion and observes expected refs/private namespace. [Native promoter][promoter] confirms commit failure is indeterminate; no complete lock/expected-old/absence/conflicting-stage population is bound. |
| R06 | `cleanupStagedFetch` | P | Named stimulus | **A11: macOS realization/reference; future Linux integration unbound.** [A11][a-cases] explicitly fails a later cleanup page and observes the exact private namespace. [Cleanup implementation][cleanup] confirms pagewise effects. This is a class identification, not a chosen injected page/harness or exhaustive namespace corpus. |
| R07 | `cleanupAbandonedStagedFetches` | P | Generic class | A11's later-page failure also applies by analogy to this [separate sweep][cleanup-sweep], but the procedure does not name retained active IDs, malformed/unrecognized refs or cross-namespace sweep cases. |
| R08 | `push` | S | Absent | No remote server ref/hook mutation or lost push reply stimulus; generic transport loss is not a selected Git push case. |
| R09 | `remoteReferences` | S | Absent | No network ls-remote/symref/peeled-ref parsing or remote unavailability observation; A11 inspects local canonical/private refs. |
| R10 | `probeRemoteBranch` | P | Absent | No present/absent/unreachable/timeout configured-remote branch probe population. |
| D01 | `readDiscoveryCandidate` | P | Absent | No exact-candidate NO_SEARCH/bare/invalid-registration/failure population. Linux path containment and file identity do not exercise repository discovery. |

E1 is terminal restoration, E3 is coordination/fanout and E6 is phone lifecycle. Their common currentness/cancellation/native/transport disciplines can constrain a later Git arm, but the primary texts at [E1][e1], [E3][e3] and [E6][e6] do not select additional Git operations. E2 A13's typed wire gate does not identify which of these 44 methods is transported. E5 P1 expressly says a fixture echo is not a real Git result, but likewise does not select a concrete Git operation.

## Fork/platform matrix — F01–F13

This uses the existing [edge-case IDs and meanings][fork-catalog], not the differently grouped thirteen-item summary from an earlier handback. **8 rows have explicit but partial concrete stimuli; 5 have generic/deferred expansion only.** These are partial, platform-qualified source relationships, not Linux integration coverage scores. Current SDK fork semantics supply the macOS reference; C0–C10 describe proposed Linux leaf probes. All 13 are named by the broad E4 expansion; none is established by an executed result or fully discharged by the leaf procedure. “Deferred” records the written source boundary, not a recommendation to defer a product feature.

| Existing row | Current case | Relationship to actual written procedure | Remaining source-specific limit |
| --- | --- | --- | --- |
| F01 | Unsupported filesystem/device/managed location | Named stimulus, partial: [C1–C3][linux-cases], [profiles P0–P3][linux-profiles] distinguish supporting/refusing/cross-mount/bad-FD/permission cases. | Managed/File-Provider analogue and full fork eligibility/result API are not a case. Profile refusal is not Linux-wide unsupported policy. |
| F02 | Symlink/ancestor replacement escape | Named stimulus, partial: [C4/C6][linux-cases] exercise constrained lookup, bind-mount alternative and post-open moved directory. | C6 characterizes limits; it cannot pass a continuous-ancestry promise not selected. Full fork traversal/copy/cleanup integration remains outside the leaf assay. |
| F03 | Source changes before clone/index adoption | Named stimulus, partial: [C5][linux-cases] replaces leaf/kind between planning/open; [C0][linux-cases] qualifies identity observations. | No explicit source-write-during-clone or resulting Git index-adoption case. One-file clone consistency is not multi-file snapshot proof. |
| F04 | ACL/xattr/mode/time/flag preservation | Named stimulus, partial: [C7/C8][linux-cases] and [ACL arms][linux-acl] characterize raw clone metadata, setters, malformed ACL and ACL/chmod order with independent permission observation. | Darwin-to-Linux ACL mapping and product normalization/failure policy remain explicitly outside the Linux-only candidate; some namespaces/flags can remain unobservable. |
| F05 | Symlink text/inode metadata differs | Named stimulus, partial: [C9][linux-cases] and [metadata API arms][linux-links] name no-follow read/stat/time/owner and target protection. | Linux fixed modes and held-parent/name replacement window are characterized, not silently normalized into full Mac equivalence. |
| F06 | Hardlinks/protection/rewrite interference | Named stimulus, partial: [C0/C9][linux-cases] include alias calibration and destination-internal hardlink groups separate from source. | Protected flags, ACL-protected replacement, hardlinked administrative pointer rewrite/refusal are not concrete leaf cases. |
| F07 | FIFO/socket/device/dataless node | Named stimulus, partial: [corpus][linux-corpus] and [C9][linux-cases] include FIFO creation/metadata and relative symlink. | Corpus explicitly excludes device/dataless content and has no socket skip/refusal assay. Those omissions are not authority to weaken fork parity. |
| F08 | Non-UTF-8 name | Generic/deferred: [E4 expansion][e4] names admitted name behavior; [later full fork list][linux-later] explicitly retains non-UTF-8. | No invalid-byte filename corpus, wire encoding/refusal or receiving-filesystem collision case. |
| F09 | Nested repository/submodule/alternates/config closure | Generic/deferred: [E4][e4] names nested Git administration and [later list][linux-later] retains topology. | First Linux probe is synthetic files only; no Git administration or pointer-closure case/oracle. |
| F10 | Sparse index/ignored inclusion/LFS/rewritten metadata | Generic/deferred: [E4][e4] names index adoption/LFS; [later list][linux-later] retains ignored/LFS/index behavior. | Sparse file in C1 is not a Git sparse index. No materialization-variant, ignored selection, local LFS-store fill or rewrite receipt assay. |
| F11 | Branch use/movement before attach/rollback | Generic/deferred: [E4][e4] says ref locks/CAS and [later list][linux-later] keeps branch locks. | A11's staged-ref promotion is a different transaction. No fork attach branch-use/expected-tip race or conditional branch undo stimulus. |
| F12 | Cancellation/failure with blocking work/cleanup live | Named stimulus, partial, separate platforms: [A11][a-cases] credits joined fork cancellation to the **macOS realization/reference only; future Linux integration unbound**. [C10][linux-cases] credits only **proposed Linux leaf cleanup**, with controlled failure and before/after-check replacement. | Neither relationship establishes full Linux fork cancellation. C10 says not full fork/crash recovery. The macOS-reference [journal][journal] is in-memory with identity-owned compensation, not restart preservation. No full Linux phase/worker residue population or qualified integrated fork realization is bound. |
| F13 | Native error/residue across platform/protocol | Generic/deferred: [E4 oracle][e4] names accurate typed residue/partial effects; C3 captures errno; A13 names generic wire validation. | No named Git error DTO crossing a real route, native-platform tag population, or combined fork error/ordered-residue oracle is bound. Errno readback alone is not protocol parity. |

## Remaining app-policy and interface evidence

- **Native/CLI create:** [survey:145][creation-policy] records distinct plain/default/selected/native-copy-all and config-selected CLI fork paths plus publication hold/rescan. E2 A11 chooses fork cancellation; neither native publication reconciliation nor CLI branch/start/network/config/changes-only/no-fork behavior has a distinguishing case in these procedures. This is an observed procedure omission, not an extraction or test decision.
- **Evidence-aware remove/list/prune:** [survey:143][policy-module] and [catalog findings:94–100][catalog-findings] distinguish fetching reads/previews, archive, working-change discard, tmp policy, branch retirement, per-artifact results, lock accounting and unknown activity. C10 leaf unlink and A11 staged-ref cleanup are not evidence archival or policy removal. No archive byte/link verification, partial archive, current/main refusal, target aggregation, preview fetch or prune eligibility stimulus was found.
- **Process/auth:** [Git catalog custody:20–32][git-custody] records native read/writer/fork/process/promotion differences. E2 A6/A13 and E5 P1/P9 supply generic loss/cancellation/auth/codec probes, not system-Git SSH/HTTPS credential-helper, environment scrub, prompt policy, bounded output/descendant custody or actual remote auth cases. Fly authentication/control prerequisites at [Linux:35–58][linux-control] concern the experiment operator, not product Git authentication.
- **Opaque review seed:** [source:57–92][seed] directly confirms local-only nonserializable seed and complete/proportional/fallback meanings. [Primary E5:115][e5-work] explicitly proposes retained seed versus full recomputation as a scoped sub-arm, but no method-specific route/lifetime/seed-identity/fallback population is bound. This is a concrete named cost concept with unbound operation realization, not absence of the concept.
- **E1/E3/E6 and generic wire gates:** they can supply prerequisite observations or class-level disciplines without covering all Git APIs. No published number of cataloged methods supplies their actual stimulus, effect oracle, failure injection or platform result. The documents themselves preserve this proof limit.

## Source coverage, queries and limits

Read inputs: Requirements 108 lines; owner-source README 39; main survey 295; primary experiments 153; autonomy 99; Linux probe 158; route-cost procedure 106; existing Git desk evidence 200; edge cases 59. These are mutable outer-task documents read on this wake, not frozen accepted specifications. Historical memo bodies, other E1/E3/E6 leaf documents and other evidence files linked inside these inputs were not recursively re-researched: this assignment selects the primary family map plus E2/E4/E5 procedures. No claim here depends on their unsearched implementation/runtime content.

The initial comparison read **six decisive package source units**: `AgentStudioGitSDK.swift`, `GitDiscoveryReadContracts.swift`, `GitReviewComparisonContracts.swift`, `WorktreeForkRollbackJournal.swift`, `LibGit2StagedFetchPromoter.swift`, and `SystemGitRemoteClient+StagedFetchCleanup.swift`. They establish exact API-set identity, opaque-seed boundary, absence of persisted fork recovery, indeterminate promotion and distinct targeted-versus-abandoned cleanup semantics. The bounded platform-axis correction additionally read `Package.swift:1–86` and `PosixGitProcess.swift:1–43`: **eight units total**. Those anchors establish the current artifact/target and Darwin process coupling; no compilation or claim that `Package.platforms` alone prohibits Linux follows. Other product behavior is explicitly attributed to the existing survey/desk evidence, not presented as freshly re-audited backend proof. No new OSS/API question required a network route.

Queries performed:

1. `git status --short`; `git -C /Users/shravansunder/code/projects/agentstudio-git rev-parse HEAD`; `git -C /Users/shravansunder/code/projects/agentstudio-git status --short` — exact package pin/clean state verified; outer task dirty state preserved.
2. `rg --files docs tmp/practices-research/2026-10-15-daemon-extraction-survey | rg 'daemon|e2-git|edge-cases|requirements|Requirements'` — located the assigned inputs; no alternate document was substituted.
3. `wc -l` on the nine inputs above — counts recorded; direct numbered reads/chunks supplied the source anchors.
4. `rg -n 'Git|git|fork|clone|ref|seed|ACL|F0|F1|metadata|LFS|prun|worktree|auth'` on primary/autonomy/Linux/cost — found A11, broad E4/F expansion and E5 seed/workload text; matched words were inspected in context, not treated as API coverage.
5. Read-only Python extraction: `re.findall(r'^    func (\w+)', ...)` within each protocol block; catalog rows `r'^\| ((?:L|R|D)\d\d) \| \[([^]]+)\]'` — **44 unique names = 44 catalog rows**, `protocol minus catalog = []`, `catalog minus protocol = []`.
6. Exact identifier query `re.search(r'\b' + operation_name + r'\b', procedure_text)` for all 44 names against the four procedures — no operation identifier in autonomy; primary only `content`/`clone`, Linux only `content`/`clone`/`fetch`, cost only `content`. Those common words are ordinary prose/filesystem/build references, not literal bindings to SDK invocations. Named-stimulus classifications above therefore use the inspected semantic A11 wording rather than fabricated exact-name matches.

Null results above mean searched text, not proof that no future harness could exercise a feature. Existing package tests in the desk report are source scenarios, not runs, and were not reopened beyond the six-unit bound. No new normative IDs, test cases, supported-filesystem policy, API/path contract, recovery mechanism, unsafe waiver, crate/backend choice or feature scope is authored.

Completion receipt: **complete**, 44/44 operation rows and 13/13 existing fork rows mapped; meaningful proof boundary is written-procedure specificity only. All experiment/runtime/parity evidence remains unexecuted. Lead independently checks decisive anchors and owns coverage synthesis and any next requirements/design decision.

[requirements]: ../../../user-requirements.md:27
[requirement-boundary]: ../../../user-requirements.md:83
[owner-source]: ../../owner-inputs/README.md:5
[survey]: ../../extraction-survey.md:126
[primary]: ../../../experiments/primary-experiments.md:3
[a-cases]: ../../../designs/07-agents-context/experiments/host-autonomy.md:69
[a-witness]: ../../../designs/07-agents-context/experiments/host-autonomy.md:48
[a-profiles]: ../../../designs/07-agents-context/experiments/host-autonomy.md:32
[e1]: ../../../experiments/primary-experiments.md:22
[e3]: ../../../experiments/primary-experiments.md:65
[e4]: ../../../experiments/primary-experiments.md:87
[e5-work]: ../../../experiments/primary-experiments.md:115
[e6]: ../../../experiments/primary-experiments.md:129
[linux-boundary]: ../../../designs/06-worktree-fork/experiments/linux-feasibility.md:3
[linux-scope]: ../../../designs/06-worktree-fork/experiments/linux-feasibility.md:33
[linux-control]: ../../../designs/06-worktree-fork/experiments/linux-feasibility.md:35
[linux-receipt]: ../../../designs/06-worktree-fork/experiments/linux-feasibility.md:62
[linux-profiles]: ../../../designs/06-worktree-fork/experiments/linux-feasibility.md:83
[linux-corpus]: ../../../designs/06-worktree-fork/experiments/linux-feasibility.md:98
[linux-cases]: ../../../designs/06-worktree-fork/experiments/linux-feasibility.md:102
[linux-acl]: ../../../designs/06-worktree-fork/experiments/linux-feasibility.md:118
[linux-links]: ../../../designs/06-worktree-fork/experiments/linux-feasibility.md:124
[linux-later]: ../../../designs/06-worktree-fork/experiments/linux-feasibility.md:144
[cost-boundary]: ../../../designs/11-operations-integration/experiments/route-performance.md:104
[cost-freeze]: ../../../designs/11-operations-integration/experiments/route-performance.md:32
[cost-cases]: ../../../designs/11-operations-integration/experiments/route-performance.md:69
[git-catalog]: e2-git-operation-evidence.md:34
[git-custody]: e2-git-operation-evidence.md:20
[catalog-findings]: e2-git-operation-evidence.md:92
[fork-catalog]: edge-cases.md:37
[creation-policy]: ../../extraction-survey.md:145
[policy-module]: ../../extraction-survey.md:143
[sdk]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitContracts/AgentStudioGitSDK.swift:3
[discovery]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitContracts/GitDiscoveryReadContracts.swift:23
[seed]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitContracts/GitReviewComparisonContracts.swift:57
[journal]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitLocal/WorktreeFork/WorktreeForkRollbackJournal.swift:24
[promoter]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitRemote/LibGit2StagedFetchPromoter.swift:65
[cleanup]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitRemote/SystemGitRemoteClient+StagedFetchCleanup.swift:5
[cleanup-sweep]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitRemote/SystemGitRemoteClient+StagedFetchCleanup.swift:31
[platform-package]: /Users/shravansunder/code/projects/agentstudio-git/Package.swift:17
[platform-process]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitRemote/PosixGitProcess.swift:1
[platform-promotion]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitRemote/LibGit2StagedFetchPromoter.swift:1
