# E2 Git operation effects and receipts — desk evidence

Date: 2026-10-15. Researcher: assigned Rust coordination Worker; Lead retains validation and integration.

## Scope, source cutoff and coverage

This is current-source classification, not experiment execution or a proposed API, persistence scheme, retry policy, backend, or ownership model. The required frontend route remains client socket → Gateway → Host; no CLI bypass is introduced. Host macOS/Linux parity and macOS-only Gateway scope are governing requirements. The inspected SDK is a macOS implementation; this report does not establish a Linux realization.

- AgentStudio worktree: `/Users/shravansunder/code/projects/agentstudio.feat-daemon`, HEAD `624300332f5e50f7bb8cbb9fc786d5e5b4a3d462`. Existing dirty images and daemon documents belong to the outer task.
- Git SDK: `/Users/shravansunder/code/projects/agentstudio-git`, HEAD `4cca397dfc869857064da4e9ec8289ea46adc479`, clean when inspected. No SDK `AGENTS.md` was found with `rg --files --hidden -g AGENTS.md`.
- Governing experiment artifact read end-to-end: [primary experiments][experiments], especially E2 effect receipts and E4 Linux parity. [Survey Git section][survey-git] and [second-pass evidence][second-pass] were discovery pointers; implementation claims were checked against SDK request/result types and backend owners.
- **44/44 public protocol requirements covered:** 33 local, 10 remote, 1 narrow discovery. Convenience overloads and pure helper APIs are not additional requirements. [Local/remote protocols][protocols]; [discovery protocol][discovery-contract].
- **36 production-called versus 8 SDK-only preserved:** 28 local + 7 remote + 1 discovery have call matches in current AgentStudio `Sources`. The eight SDK-only operations are marked `S` below: `pruneStaleWorktree`, `lockWorktree`, `unlockWorktree`, `isPathIgnored`, `ignoredPaths`, `clone`, `push`, `remoteReferences`. Searching all eight produced only unrelated `NSCursor.push()` and embedded JavaScript `push` matches. Absence of a production caller does not authorize removing or exposing an SDK operation.
- Only this explicitly authorized evidence file was written. No builds, tests, runtime/device actions, credentials, network calls, Git mutations, board posts, or new agents were used for this assignment.

## Reading the classification

`P` means production-called; `S` means SDK-only. Execution/cancellation custody codes apply to each row:

| Code | Current execution and cancellation custody |
| --- | --- |
| Q | Native blocking read executor. The async continuation waits for the synchronous body; task cancellation is not forwarded into the C/read operation. No SDK Git mutation was found on the inspected query path. Lost reply loses an observation; another read can observe a different live state. |
| W | Ordinary local mutation on the repository writer lane. The lane is a dedicated FIFO serial queue keyed by the path-derived canonical common-directory repository ID, not actor non-reentrancy. The facade does not forward task cancellation into these operations. Custody continues until the complete submitted body returns. |
| F | Fork uses that lane plus explicit cancellation forwarding. Planning/workers check a cancellation object at bounded boundaries; in-flight leaf work completes and rollback is joined before the lane/call returns. The in-memory journal explicitly provides no crash recovery. |
| P | System-Git process runner. Cancellation signals the process group; the wait coordinator escalates and waits for the direct child's wait result, then performs bounded output-reader completion waits. This is process custody, not rollback of Git/server effects or proof of every descendant's extinction. |
| T | Promotion's native `@concurrent nonisolated` body. It acquires native ref locks and runs the transaction synchronously; no explicit task-cancellation checks/rollback are present. It does not use the local writer registry. |

Sources: [local facade][facade], [blocking executor][read-executor], [writer registry/lane][writer-lane], [fork cancellation][fork-cancellation], [fork journal][fork-journal], [process runner][process-runner], [wait coordinator][process-wait], [native promoter][promoter].

“Query” below means no requested Git ref/index/worktree mutation in the inspected SDK path, not a pure function over immutable inputs or absence of incidental OS/helper activity. Native reads are not serialized with writers. A typed query result is not automatically an atomic repository snapshot, durable receipt, current authorization, or permission for a later mutation.

**Keys are not deduplication promises.** Repository/worktree IDs are based on canonical paths, not filesystem birth/incarnation identity. Expected OIDs guard particular ref transitions. A staging UUID selects a private namespace. None alone establishes execution identity, exactly-once behavior, or safe replay after a lost reply. No general operation-ID/deduplication contract appears in these 44 requirements.

## Local operations — 33/33

Each operation has its own row. Shared custody definitions above do not merge their result, scope, or reconciliation semantics.

| # | Operation / use / custody | Actual effects and result boundary | Keys, readback and lost-reply limits |
| --- | --- | --- | --- |
| L01 | [repositoryIdentity][identity] · P · Q | Reads `.git`/`commondir` and canonicalizes paths; returns repository ID/common directory/main path. No registration or repair. | Exact supplied worktree-root metadata resolution; ID is `common:<path>`. Re-resolving confirms current paths, not the same directory incarnation. |
| L02 | [worktrees][worktrees] · P · Q | Native listing of main and registered linked worktrees, with current HEAD/lock/path snapshots. No fetch, prune or repair. | Repository path/common directory and path-derived worktree IDs. Missing/unreadable registration can fail listing. Useful current post-state for create/remove/lock, not causal attribution or historical completion. |
| L03 | [validateWorktree][validate-worktree] · P · Q | Opens repository, validates linked registration; returns `snapshot/isValid`. Missing repository and invalid linked registration can be nonthrowing invalid results. No repair. | Uses ordinary repository opening, unlike discovery's exact-candidate `NO_SEARCH` path. Current validity does not prove who created it or reserve it against a later change. |
| L04 | [createWorktree][create-worktree] · P · W | Creates detached linked administration/checkout at a pinned start, validates, attaches branch, optionally writes upstream, then disarms rollback and performs nonthrowing local LFS-store fill. Success includes worktree plus materialized/missing/scan/residue detail. | New branch absence or existing `expectedTip`/optional descendant fast-forward; native branch lock repeats branch-use and tip checks. Attach commit can land despite an error. Compensation rereads branch undo, but other cleanup failures are suppressed; generic error is not proof of zero residue. Read back registration, HEAD/ref, config, files and LFS payloads separately. |
| L05 | [forkWorktree][fork-worktree] · P · F | Multi-step destination/admin/copy-or-changes-only/rehoming/index/validation/branch transaction. Success follows final attached validation and cancellation checks; failures/cancellation compensate before returning, or return `cleanupIncomplete(primary,residue)`. | Captured source HEAD/index/state, descriptor/file identities and destination ownership evidence; new/existing/detached branch targets and expected-tip native locking. Journal distinguishes attempted from confirmed owned paths and protects foreign replacements/locks. Readback can inspect artifacts/ref/index/content, but cannot reconstruct the full materialization receipt after crash/reply loss; journal is not persisted. |
| L06 | [forkWorktreeEligibility][eligibility] · P · Q | Read-only host/volume/File Provider/capability availability check, not source-tree materialization or a reservation. | Source/destination/materialization inputs. A later fork rechecks actual preconditions; eligibility success is not future success or Linux capability proof. |
| L07 | [pruneStaleWorktree][prune-stale] · S · W | Checks linked-worktree prunability, then calls native prune with default options. No working-directory removal flag is requested. Success returns pruned ID; native failure throws generic error without per-artifact effect receipt. | Repository path + linked ID; locked/live worktrees are refused. Read current registration/admin path independently. Native failure/lost reply does not supply a complete partial-effect history. |
| L08 | [removeWorktree][remove-worktree] · P · W | Refuses main/path mismatch/locked and, unless forced, staged/dirty/untracked data. Native prune may remove administration and optionally directory. Returns independently observed administration/directory dispositions plus optional failure, rather than treating return as unconditional success. | Worktree ID and optional canonical path agreement; force/remove-directory flags. No expected directory incarnation or HEAD OID in the public request. Directory deletion may destroy uncommitted data. `removed/retained/partial/unknown/notRequested` are separate; readback requires both paths, not listing absence alone. |
| L09 | [lockWorktree][lock-worktree] · S · W | Writes lock marker/reason, then rereads a snapshot. A reread failure can follow the lock effect. | Linked worktree ID; no expected prior lock state/reason or operation token. Read current lock/reason via listing/validation. Current locked state is not proof this call performed it. |
| L10 | [unlockWorktree][unlock-worktree] · S · W | Removes lock marker, then rereads a snapshot; later read error does not undo removal. | Linked ID; no expected lock-owner/reason token. Current unlocked state is observable but does not identify an execution. |
| L11 | [statusObservationPlan][status-plan] · P · Q | Reads observation scopes/config/attribute coverage; returns supported/unsupported plan and scope identity. Does not install a watcher or read full status. | Identity encodes the sorted observation-scope descriptor, not repository contents or a monotonic revision. It must not be used as a standalone clean-state proof. |
| L12 | [statusFacts][status-facts] · P · Q | Native entries/branch/origin summary, no exact line-count computation. Status uses `GIT_STATUS_OPT_NO_REFRESH`. Optional exact-clean baseline requires supported unchanged plan, literal `pathspecs == nil`, untracked included and empty entries. | Pathspecs scope entries and entry counts; HEAD/upstream/origin remain repository-wide. `[]` walks unrestricted but cannot mint the baseline because it is not literal `nil`. SDK baseline is not app continuity authority by itself. |
| L13 | [exactLineCountDetail][line-detail] · P · Q | Full-worktree tree-to-workdir-with-index line statistics, with explicit submodule inclusion choice. No fetch or index write. | Worktree + `excludeSubmodules`; no pathspec parameter. Returns independent timestamped detail, not a ref/working-tree fence or a clean-state authorization. |
| L14 | [completeStatus][complete-status] · P · Q | Sequentially combines status facts and exact line detail. Does not become an atomic snapshot merely by returning one aggregate. | Facts honor pathspecs; line counts remain full-worktree. Mutable refs/files can change between subreads. Read-only repeat can differ; do not conflate scoped entries with full counts. |
| L15 | [trackedPaths][tracked-paths] · P · Q | Reads stage-zero index entries, kinds and optional directory scope; returns raw index entry count separately from filtered entries. No index edit. | Worktree/index + normalized scope path; no expected index checksum. Current index readback is possible; it is not a durable catalog revision. |
| L16 | [isPathIgnored][ignore-one] · S · Q | Native ignore query for one normalized relative path. No ignore-rule write. | Repository + relative path and current Git ignore/config inputs. A boolean is an observation, not persisted policy or an execution receipt. |
| L17 | [ignoredPaths][ignore-many] · S · Q | Same native query session maps supplied paths into checks; errors throw rather than returning a partial successful array. | Repository + ordered input paths; mutable rules can differ on a later call. No write or reservation. |
| L18 | [branches][branches] · P · Q | Local branch names/current/upstream snapshots. No remote network query. | Repository refs/config; returned branch snapshots do not carry tip OIDs. Use revision resolution/current native refs when an exact tip is required. |
| L19 | [remoteNames][remote-names] · P · Q | Reads configured remote names through libgit2. No fetch or remote contact. | Repository configuration; names are not remote existence/currentness evidence. |
| L20 | [branchUse][branch-use] · P · Q | Reads all worktree administration for HEAD, rebase and bisect branch holding. Unreadable administration throws instead of becoming `free`. | Repository + branch name; current use only. Not a reservation; create/fork repeat under the native ref lock. |
| L21 | [aheadBehind][ahead-behind] · P · Q | Graph counts for two validated pinned commits. Distinguishes strictly behind from diverged. | Two full commit OIDs + repository. No current named-ref or remote freshness assertion. |
| L22 | [assessBranchIntegration][integration] · P · Q | Computes branch integration grades against target commit, including unknown outcomes and bounded squash search. Before/after history guards can downgrade history-dependent results. No branch deletion. | Branch names, resolved target, shallow/replace/graft/history guard and limit. Assessment is not deletion authority or an expected-tip mutation lock. |
| L23 | [deleteLocalBranch][delete-branch] · P · W | Locks branch before expected-commit comparison, refuses checked-out/non-direct invalid cases, stages deletion and commits. Reprobes after commit, then reserves absent name during config/reflog cleanup. Returns `deleted(cleanup)`, `retained(reason)` or `uncertain(error)` with residue. | Exact `expectedCommit` under native ref lock; packed-ref/config locks and branch recreation matter. Metadata cleanup can remain deferred/failed. Read exact ref plus config/reflog independently; absent/ref-at-OID is current state, not proof of one execution. |
| L24 | [resolveReviewDefaultTarget][review-default] · P · Q | Resolves a local review-default target or absence. No fetch. | Current local reference/config selection; not a captured future remote target. |
| L25 | [captureReviewComparisonTargets][review-targets] · P · Q | Bounded target catalog with caller capture/cutoff times, maximum rows and truncation indication. No ref mutation. | Repository/current-reference inputs and resolved row evidence; collection is not an atomic ref transaction or authorization revision. |
| L26 | [resolveRevision][resolve-revision] · P · Q | Resolves named/HEAD/OID target to commit OID and optional short name. No ref update. | Resolved OID can identify immutable object content; name resolution can change between calls and is not CAS admission. |
| L27 | [readTree][read-tree] · P · Q | Reads resolved commit tree or subtree, object IDs/modes, best-effort blob sizes. No checkout or blob creation. | Revision + optional tree path; result carries resolved revision. Optional missing size is not an absence verdict for the object. |
| L28 | [diff][diff] · P · Q | Reads supported commit/HEAD/index/working-tree target combinations and rename/content information. Unsupported combinations throw. No patch application or staging. | Base/compare target kinds; names resolve now, index/worktree are mutable. The returned diff alone is not a coherent future mutation guard. |
| L29 | [countCommitRange][commit-range] · P · Q | Bounded graph traversal yielding exact count, at-least limit, unrelated or traversal-limit result. No ref edit. | Base/candidate revisions and independent count/traversal budgets. Not interchangeable with ahead/behind or a branch-retirement verdict. |
| L30 | [summarizeDiffImpact][diff-impact] · P · Q | Bounded file/line/blob impact computation with conservative limit/oversized outcomes. No object/index write. | Base/compare and explicit budgets; bounded/conservative result is not complete full-diff evidence. |
| L31 | [contributionDiff][contribution] · P · Q | Reads contribution-base-to-working-tree comparison. Complete or proportional calculation returns snapshot, successor seed and disposition/reason; proportional may fall back. | Seed key binds common/worktree paths, comparison kind/options, target name/resolved OIDs, HEAD and contribution base; key recheck does not make every live file immutable. Seed is a read-computation artifact, not operation deduplication. |
| L32 | [directReviewComparison][direct-review] · P · Q | Reads selected-target-to-working-tree comparison, separately from contribution/merge-base meaning; complete/proportional/fallback result. | Similar seed identity but `direct` comparison and selected-target effective base. It is not semantically interchangeable with L31. |
| L33 | [content][content] · P · Q | Reads raw commit blob, stage-zero index blob, or contained working-tree file; enforces optional size cap and returns bytes/hash/binary flag. No checkout, LFS fill or write. | Revision/target kind + path; SHA-256 describes returned bytes. Working-tree pre-stat and subsequent read are not a general filesystem snapshot; changed content can produce a later different result. |

## Remote and discovery operations — 11/11

Remote read commands remain distinct from native libgit2 reads: they launch system Git and may use configured transport, credential and trust helpers. This report classifies requested Git state effects; it does not certify arbitrary helper programs as globally side-effect-free.

| # | Operation / use / custody | Actual effects and result boundary | Keys, readback and lost-reply limits |
| --- | --- | --- | --- |
| R01 | [clone][clone] · S · P | Creates destination Git administration, objects and checkout. Exit success yields destination path only. No SDK rollback or partial-clone receipt on failure/cancellation. | Remote URL/destination/optional branch; no expected destination identity. Independently inspect repository identity, refs and checkout. Existing destination or partial clone is not a deduplication result. |
| R02 | [fetch][fetch] · P · P | Whole-remote fetch delegates configured Git behavior. Branch-targeted fetch restricts refmap/tags/pruning/submodules, but writes objects, tracking ref and FETCH_HEAD; post-fetch commit resolution can fail after effects. Result has remote name, optional commit and optional lock residue. | Branch-targeted ref is constructed from configured remote/name, with no expected old OID. Targeted candidate locks are observed; whole-remote residue is `nil` (unobserved), not `[]`. Re-read exact refs/objects/FETCH_HEAD; process error does not prove no update. |
| R03 | [captureRemoteTrackingSnapshot][remote-snapshot] · P · P | Local system-Git config/get-url/common-dir/for-each-ref reads, no network fetch. Returns configured/effective URL provenance and canonical direct tracking refs/OIDs. | Several sequential commands; not atomic capture. Common directory + remote namespace/URLs/refs form subsequent stage provenance, not execution identity. |
| R04 | [stageFetch][stage-fetch] · P · P | Validates snapshot/common directory and empty private namespace; fetches objects plus private heads using `--atomic`, no FETCH_HEAD/tags/prune/maintenance/commit-graph writes requested. Then reads staged refs and may create promotion-guard ref in another transaction. | Caller staging UUID + common directory; snapshot's configured/effective fetch URL and captured refs. No shared writer-lane admission. Failure after fetch or guard creation can leave objects/private refs without result. Known handle permits targeted cleanup; exact private-ref readback is internal/fixture evidence, not a public general staging-query operation. |
| R05 | [promoteStagedFetch][promote-stage] · P · T | Reconstructs/validates full stage plan; locks canonical/staging/guard refs in sorted order; verifies old OIDs/absence and staged OIDs; updates/deletes canonical refs and consumes private refs/guard. Result lists updated/deleted canonical names. | Expected-reference checks protect the transition, not replay identity. Native refs commit individually: commit error explicitly throws `remoteRefTransactionIndeterminate`, with no rollback or per-ref partial receipt. Re-read all relevant canonical/private refs before inferring current state. |
| R06 | [cleanupStagedFetch][cleanup-stage] · P · P | Enumerates bounded pages in one UUID namespace and commits expected-OID deletion per page. Success returns deleted names and empty retained names. No object-store cleanup. | Common directory + staging UUID; each deletion protects observed OID. Earlier pages may be committed when a later page/cancellation/output/commit fails; thrown error does not return the accumulated list. Re-enumerate exact namespace; absent guard can also revoke later promotion. |
| R07 | [cleanupAbandonedStagedFetches][cleanup-abandoned] · P · P | Sweeps recognized UUID namespaces except caller-retained UUIDs; preserves unrecognized refs; bounded expected-OID page commits; success lists deleted/retained names. | Caller retained-ID set, reserved prefix and current OIDs. No age/timer policy. Omitting a live stage from that set can revoke it. Same page-level partial/error ambiguity as R06; preserved refs and objects are separate. |
| R08 | [push][push] · S · P | Sends caller refspec via system Git; remote/server refs and configured hooks may act before failure/reply loss. Success receipt repeats refspec, not per-ref OIDs or server transaction identity. | Repository + configured remote + refspec; no explicit expected-remote-OID/lease argument or atomic-push requirement in SDK. Remote ref queries can observe current heads, not prove execution provenance or hook completion. |
| R09 | [remoteReferences][remote-refs] · S · P | Network `ls-remote --symref` query; parses refs/OIDs/peeled/symref fields. No fetch/local ref update requested. Output/process/parser failure yields no successful observation. | Explicit remote URL and protocol policy. Later query may differ; transport failure is not remote absence. |
| R10 | [probeRemoteBranch][probe-branch] · P · P | Configured-remote `ls-remote --exit-code` for one validated branch; returns `present(commit)` or `absent`; other process failures throw. No fetch. | Repository/remote/branch, including Git's current Unicode/config interpretation. Unreachable, timeout or refusal is not absence. Current remote OID is observation, not mutation CAS or proof of a prior push. |
| D01 | [readDiscoveryCandidate][discovery] · P · Q | Exact candidate open with `GIT_REPOSITORY_OPEN_NO_SEARCH`; checks bare/main/linked validation/lock state without index/status scan or repair. Returns `validated`, reasoned `notRepository`, or `failed`, not a thrown discovery error. | Canonical candidate/worktree/Git/common paths + path-derived repository ID + registration. Exact candidate negative is distinct from I/O/initialization failure. Not the same lookup as ordinary native repository reads. |

## Cross-cutting receipt and policy findings

1. **No universal commit boundary.** Create/fork write paths before branch attach; upstream and LFS materialization have their own outcome boundaries. Removal has separate administration and directory effects. Branch deletion separates ref outcome from config/reflog cleanup. Stage fetch, guard creation, promotion and each cleanup page are different effects.
2. **Current state is useful but not historical proof.** A ref now at an OID, an absent directory, or a present worktree may have been produced/recreated/moved by another actor. Source OIDs and path IDs do not answer who executed an operation. The SDK's stronger typed outcomes must not be flattened into a boolean success/failure.
3. **Lock accounting has explicit limits.** `GitLockedOperationFailure.lockResidue == nil` means unobserved; `[]` means observed none. Fork protects foreign locks and identity-mismatched paths; ordinary create uses untracked attach locks and discards some cleanup results. [Lock contract][lock-contract], [ordinary create rollback][create-rollback], [fork journal][fork-journal].
4. **Ordering is not one global Git queue.** Local mutation lanes order calls within a registry/process by common directory. Native ref locks cover selected interprocess ref transitions. Remote process operations and native promotion do not enter that local lane. Reads can overlap either. No cross-process total command order is established.
5. **Status layers must remain distinct.** Pure result mapping is not native Git I/O. SDK status facts, exact full-worktree line detail and complete aggregate are distinct. Scoped facts cannot stand in for a full clean baseline; an empty-array pathspec is an especially important distinction. App exact-clean authority additionally uses a prepare/read/commit continuity witness, and its physical gate retains custody until the read completes. [SDK status implementation][status-facts], [status scope contract][status-scope], [app provider][status-provider].
6. **SDK query versus app fetching read.** SDK `worktrees`, branch/integration/review/status reads do not fetch. App `WorktreeOperationRunner.list` and `WorktreePruneRunner.run` invoke `WorktreeFetchStep` before reading/projecting results, including prune preview paths. Their fetching/partial network effects must be classified separately from the native query rows. [List policy][list-policy], [prune policy][prune-policy].
7. **Cancellation is not an effect verdict.** Ordinary native operations do not gain cancellation from losing an RPC reply. Fork has explicit joined compensation; remote process cancellation terminates local process work but cannot roll back already-written refs, objects, files or remote effects. Output-limit, post-read, timeout and cancellation errors may occur after mutation.
8. **E4 remains a realization/proof gap.** The package declares macOS and uses Darwin/APFS-specific implementation surfaces. This source inventory defines existing observable receipt/error contracts to preserve or explicitly account for; it does not demonstrate safe Rust wrappers, Linux clone/metadata/lock parity, or a supported Linux profile. [Package platform][package-platform], [fork error/refusal contract][fork-errors].

## Tests read, not run

These are source-backed oracles, not current green test results. No command/pass count or runtime proof is claimed.

| Test source inspected | Relevant observable assertion |
| --- | --- |
| [Worktree removal partial/unknown cases][test-removal] | Administration can be removed while directory removal is partial; inaccessible post-prune observation yields `unknown` even if fixture paths are actually absent. |
| [Create undo failure][test-create-undo] | A fast-forward whose undo cannot take the ref lock reports `branchMoveNotUndone`; the moved branch survives while created worktree content is gone. |
| [Branch deletion uncertain outcome][test-delete-uncertain] | Packed-ref lock failure after staging is returned as `uncertain`, preserving existing metadata and the foreign lock; no owned residue is invented. |
| [Fork cancellation][test-fork-cancel] | Controlled phase barrier, task cancellation and joined result assert destination/admin/branch compensation. |
| [Fork cleanup residue][test-fork-residue] | Failed owned destination cleanup returns ordered `cleanupIncomplete` residue, never success, and the named residue remains present. |
| [Promotion commit failure][test-promotion] | Commit-stage write failure must return `remoteRefTransactionIndeterminate`, not a safe rejection. |
| [Cleanup revokes deletion-only promotion][test-revoke] | Removing its guard/stage makes a later promotion fail while canonical ref remains. |
| [Process cancellation test][test-process-cancel] | Fake-Git test checks cancellation classification and local process termination. It is not remote-effect rollback proof; its polling/time-based helpers are existing tests, not proposed AgentStudio wait patterns. |

## Proof limits and return

All 44 method rows are classified from the pinned facade, contracts and decisive backend owners. Query-owner source and its mutating-call search were inspected; this is not an exhaustive proof about libgit2 internals, arbitrary Git helpers, filesystem atime, hooks or running binaries. No new current-state observer was invented. Internal/test filesystem/ref probes are identified as such where the public SDK has no matching query. No operation-record persistence, deduplication policy, automatic retry, new public API, backend or future ownership is selected.

Remaining evidence gaps are execution and recovery guarantees: actual injected reply-loss behavior, crash survival, cross-process races on the selected future path, exact retained receipt needs, and Linux parity. The fork journal expressly does not close crash recovery. Existing tests read here do not close E2/E4.

Return token: `program-design-gap` — Lead integrates these effect/result boundaries into E2/E4 and retains all policy and ownership decisions. Work trace remains the Lead-owned root `01a1418c-c98b-7592-bdfe-bc3ea9168464`; this evidence artifact is not a second trace.

## Primary anchors

[experiments]: ../../../experiments/primary-experiments.md:42
[survey-git]: ../../extraction-survey.md:124
[second-pass]: second-pass-evidence.md:54
[protocols]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitContracts/AgentStudioGitSDK.swift:3
[discovery-contract]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitContracts/GitDiscoveryReadContracts.swift:23
[facade]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitLocal/LibGit2AgentStudioGitLocalClient.swift:44
[read-executor]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitLocal/LibGit2/LibGit2BlockingReadExecutor.swift:26
[writer-lane]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitLocal/Runtime/GitRepositoryWriterRegistry.swift:4
[fork-cancellation]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitLocal/WorktreeFork/WorktreeForkTransactionControl.swift:5
[fork-journal]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitLocal/WorktreeFork/WorktreeForkRollbackJournal.swift:24
[process-runner]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitRemote/GitProcessRunner.swift:45
[process-wait]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitRemote/GitProcessWaitCoordinator.swift:18
[promoter]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitRemote/LibGit2StagedFetchPromoter.swift:11
[identity]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitLocal/Runtime/GitRepositoryIdentityResolver.swift:7
[worktrees]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitLocal/Worktrees/LibGit2WorktreeReader.swift:12
[validate-worktree]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitLocal/Worktrees/LibGit2WorktreeReader.swift:54
[create-worktree]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitLocal/Worktrees/LibGit2WorktreeWriter.swift:34
[fork-worktree]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitLocal/WorktreeFork/LibGit2WorktreeForkWriter.swift:49
[eligibility]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitLocal/LibGit2AgentStudioGitLocalClient.swift:108
[prune-stale]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitLocal/Worktrees/LibGit2WorktreeWriter.swift:85
[remove-worktree]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitLocal/Worktrees/LibGit2WorktreeWriter.swift:113
[lock-worktree]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitLocal/Worktrees/LibGit2WorktreeWriter.swift:193
[unlock-worktree]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitLocal/Worktrees/LibGit2WorktreeWriter.swift:205
[status-plan]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitLocal/Status/LibGit2StatusObservationIdentityReader.swift:19
[status-facts]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitLocal/Status/LibGit2StatusReader.swift:24
[line-detail]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitLocal/Status/LibGit2StatusReader.swift:34
[complete-status]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitLocal/Status/LibGit2StatusReader.swift:40
[tracked-paths]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitLocal/Status/LibGit2TrackedPathReader.swift:17
[ignore-one]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitLocal/Status/LibGit2IgnoreReader.swift:12
[ignore-many]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitLocal/Status/LibGit2IgnoreReader.swift:18
[branches]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitLocal/Status/LibGit2BranchReader.swift:12
[remote-names]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitLocal/Status/LibGit2RemoteNameReader.swift:13
[branch-use]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitLocal/Branches/LibGit2BranchUseReader.swift:21
[ahead-behind]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitLocal/Branches/LibGit2AheadBehindReader.swift:14
[integration]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitLocal/Integration/LibGit2BranchIntegrationReader.swift:20
[delete-branch]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitLocal/Branches/LibGit2LocalBranchDeletionWriter.swift:28
[review-default]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitLocal/Review/LibGit2ReviewComparisonTargetReader.swift:16
[review-targets]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitLocal/Review/LibGit2ReviewComparisonTargetReader.swift:26
[resolve-revision]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitLocal/Review/LibGit2RevisionResolver.swift:6
[read-tree]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitLocal/Review/LibGit2TreeReader.swift:6
[diff]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitLocal/Review/LibGit2DiffReader.swift:8
[commit-range]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitLocal/Review/LibGit2CommitRangeCounter.swift:61
[diff-impact]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitLocal/Review/LibGit2DiffImpactSummarizer.swift:85
[contribution]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitLocal/Review/LibGit2ContributionDiffReader.swift:12
[direct-review]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitLocal/Review/LibGit2DirectReviewComparisonReader.swift:12
[content]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitLocal/Review/LibGit2ContentReader.swift:6
[clone]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitRemote/SystemGitRemoteClient.swift:173
[fetch]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitRemote/SystemGitRemoteClient.swift:184
[remote-snapshot]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitRemote/SystemGitRemoteClient+StagedFetch.swift:5
[stage-fetch]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitRemote/SystemGitRemoteClient+StagedFetch.swift:53
[promote-stage]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitRemote/SystemGitRemoteClient+StagedFetch.swift:118
[cleanup-stage]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitRemote/SystemGitRemoteClient+StagedFetchCleanup.swift:5
[cleanup-abandoned]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitRemote/SystemGitRemoteClient+StagedFetchCleanup.swift:31
[push]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitRemote/SystemGitRemoteClient.swift:249
[remote-refs]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitRemote/SystemGitRemoteClient.swift:262
[probe-branch]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitRemote/SystemGitRemoteClient+BranchProbe.swift:12
[discovery]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitLocal/Discovery/LibGit2AgentStudioGitDiscoveryReadClient.swift:21
[lock-contract]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitContracts/GitLockContracts.swift:82
[create-rollback]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitLocal/Worktrees/LibGit2WorktreeCreateRollback.swift:26
[status-scope]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitContracts/GitStatusContracts.swift:172
[status-provider]: ../../../../../../Sources/AgentStudio/Core/RuntimeEventSystem/Git/AgentStudioGitWorkingTreeStatusProvider.swift:137
[list-policy]: ../../../../../../Sources/AgentStudioWorktreeOperations/WorktreeOperationRunner.swift:78
[prune-policy]: ../../../../../../Sources/AgentStudioWorktreeOperations/WorktreePruneRunner.swift:55
[package-platform]: /Users/shravansunder/code/projects/agentstudio-git/Package.swift:39
[fork-errors]: /Users/shravansunder/code/projects/agentstudio-git/Sources/AgentStudioGitContracts/GitWorktreeForkError.swift:6
[test-removal]: /Users/shravansunder/code/projects/agentstudio-git/Tests/AgentStudioGitTests/Integration/GitWorktreeRemovalIntegrationTests.swift:128
[test-create-undo]: /Users/shravansunder/code/projects/agentstudio-git/Tests/AgentStudioGitTests/Integration/GitWorktreeCreateUndoIntegrationTests.swift:102
[test-delete-uncertain]: /Users/shravansunder/code/projects/agentstudio-git/Tests/AgentStudioGitTests/Integration/GitBranchDeletionRaceIntegrationTests.swift:130
[test-fork-cancel]: /Users/shravansunder/code/projects/agentstudio-git/Tests/AgentStudioGitTests/Integration/GitWorktreeForkCancellationIntegrationTests.swift:9
[test-fork-residue]: /Users/shravansunder/code/projects/agentstudio-git/Tests/AgentStudioGitTests/Integration/GitWorktreeForkRollbackIntegrationTests.swift:239
[test-promotion]: /Users/shravansunder/code/projects/agentstudio-git/Tests/AgentStudioGitTests/Integration/GitStagedFetchIntegrationTests.swift:8
[test-revoke]: /Users/shravansunder/code/projects/agentstudio-git/Tests/AgentStudioGitTests/Integration/GitStagedFetchIntegrationTests.swift:250
[test-process-cancel]: /Users/shravansunder/code/projects/agentstudio-git/Tests/AgentStudioGitTests/Remote/GitProcessRunnerTests.swift:271
