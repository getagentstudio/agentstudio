# Worktree refusals and partial effects

This reference owns interpreting worktree parser errors, stops and failed/partial outcomes. Start with exact stdout/stderr, exit, JSON result when available, requested mode and any known effects. Return the reason, resulting state and supported next action. Complete only when work/evidence and remaining effects are accounted for; an invariant failure or unknown cleanup stays unresolved.

Begin with a non-fetching inventory or preview when it is relevant and reachable:

```sh
"$AS_CLI" worktree list --repo "$REPO" --no-fetch --json
"$AS_CLI" worktree remove "$TARGET" --repo "$REPO" --dry-run --no-fetch --json
```

Printed options describe capabilities, not permission. Preserve the actual paths, branch names, counts, OIDs, effects and lock residue before deciding. Never turn every failure into a force/remove/retry command.

## Parser errors (stderr, exit 64)

Angle-bracket slots below are dynamic values, not literal arguments. `--json` does not convert parser failures into JSON.

| Exact message/template | Next safe action |
| --- | --- |
| `usage: agentstudio worktree new\|list\|remove\|prune [target...]` | Read `"$AS_CLI" worktree --help` and choose a supported verb. Bare worktree normally shows overview help. |
| `unknown worktree subcommand; expected new, list, remove, or prune; use new -c <branch> --from <worktree> to copy a source` | Express source-copy intent with `new -c BRANCH --from SOURCE`. There is no fork alias. |
| `a branch name is required for worktree new` | Supply the one intended branch name. |
| `at least one target is required for worktree remove` | Inspect inventory and supply exact authorized targets. |
| `unexpected positional argument` | New takes one branch; prune takes no positional targets. Check the chosen verb's help. |
| `unknown worktree option` | Use that verb's local help; do not invent aliases or equals syntax. |
| `option is not supported for this worktree subcommand` | Choose an option supported by that verb and intent. |
| `--from-branch requires a branch name` | Supply the existing intended start branch. |
| `<option> requires a path` / `<option> path must not be empty` | Supply a nonempty real path for --repo, --from or --archive-to. |
| `--from-branch branch name must not be empty` | Supply a nonempty start branch. |
| `<option> may be specified only once` | Keep one occurrence; short/long aliases share identity. |
| `<first> and <second> cannot be used together` | Select one intent: separate -D from keep-branch; choose one archive/discard policy; separate changes-only from no-fork/from-branch. |
| `<option> creates a new branch, so it needs -c (--create)` | Add -c only when creation is intended; otherwise remove the creation-only option. |

## Stops and their exact catalog messages

Creation human output is `refused: <reason>[ <path>][ <detail>][ <alternative flags>]`, optionally followed by `; options: [<action>: <effect>; ...]` and a fetch line. Its JSON can carry the catalog message. Removal prints `refused <target>; stop=<reason>; <message>` with optional `; details: ...` and `; options: [...]`. A planned removal can include the same stop despite exit 0.

| Reason | Exact catalog message | Safe next action |
| --- | --- | --- |
| `defaultBranch` | The default branch cannot be deleted. | Keep the branch; no bypass is offered. |
| `defaultBranchUnverified` | The default branch could not be verified, so no branch was deleted. | Restore readable default-branch state through its owner, then inspect again. |
| `mainWorktree` | The main worktree cannot be removed. | Choose the intended linked worktree; no main-removal repair. |
| `gitLockUnidentified` | Git is blocked by a lock whose file could not be identified. | Wait for the owning operation; retry inspection after the lock clears. Do not delete guessed paths. |
| `notFound` | The requested worktree or branch was not found. | Read inventory and correct the exact target. |
| `alreadyRemoved` | The requested worktree or branch is already absent. | Check whether the requested directory and branch effects are satisfied; do not recreate just to remove. |
| `startBranchNotFound` | The requested start branch was not found. | Verify spelling/local/origin refs and select a real start branch. |
| `unsupportedWorkingState` | The source worktree has a state this operation cannot copy. | Inspect returned path/reason; resolve that state or explicitly choose a supported content mode. |
| `targetIsCurrent` | The current worktree cannot be removed from inside itself. | Run from outside the target with `--repo REPO`; retain target authority. |
| `worktreeLocked` | The worktree is locked. | Ask the lock owner. `git worktree unlock PATH` is a separately authorized ownership decision, not automatic recovery. |
| `dirty` | The worktree contains uncommitted changes. | Inspect staged/unstaged/untracked/conflicted paths. Preserve through authorized commit/copy; -f discards them and requires that explicit loss. |
| `changesUnknown` | The worktree's uncommitted changes could not be read. | Restore readable status and inspect again. Unknown changes are not permission for -f. |
| `evidenceInTmp` | The worktree contains evidence in tmp/. | Choose an authorized archive destination; inspect archive completion before removal. Discard is separate permission. |
| `evidenceUnknown` | The worktree's tmp/ evidence could not be read. | Restore readability and inspect; do not infer empty evidence. |
| `openInPane` | The worktree is open in Agent Studio panes. | Coordinate the listed consumers. Shared `closePanes`/`removeWithOpenPanes` actions are not local flags. Raw pane.close uses --handle/JSON and own-pane authority. |
| `gitLockHeld` | A Git lock file is blocking this operation. | Wait for its owner. Only an identified, rechecked stale lock can use an authorized --remove-stale-lock. |
| `archiveDestinationExists` | The archive destination already exists. | Choose an unused destination outside the target; inspect existing evidence, never overwrite it automatically. |
| `archiveDestinationInsideWorktree` | The archive destination is inside the worktree being removed. | Choose an authorized destination outside that worktree. |
| `forkUnavailable` | A copy-on-write fork is unavailable. | Inspect reason. A deliberately chosen --no-fork loses source overlay/ignored outputs; changes-only is offered only for compatible source-copy intent. |
| `changesOnlyNeedsFrom` | --changes-only requires --from. | Supply SOURCE in `new -c BRANCH --from SOURCE --changes-only`. |
| `branchCheckedOut` | The branch is checked out in another worktree. | Work at the returned path; do not compete for the branch. |
| `branchMoved` | The branch moved after it was resolved, so nothing was changed. | Inspect current refs, then make a new intended call if still needed. |
| `branchAlreadyExists` | A branch with that name already exists. | Open it with new BRANCH without -c, or choose a genuinely new name. |
| `noSuchBranch` | No branch with that name exists locally or on origin. | Correct the name; use -c only if creation is intended. |
| `originCheckFailed` | Origin could not be asked whether the branch exists, so nothing was created. | Restore external access, or deliberately choose --no-fetch with the stale-ref tradeoff stated. |
| `configInvalid` | The repository copy configuration could not be read. | Report the config diagnostic to its owner. Tracked-only checkout changes copy scope and needs a deliberate choice. |
| `sourceIndexUnreadable` | The source index could not be read. | Restore readable source and inspect before a new call. |
| `sourceIndexUnsupported` | The source index format is not supported. | Report the limitation or deliberately choose tracked-only checkout, losing the requested overlay. |

Other creation reasons use these exact human prefixes: `refused: notInRepository <absolute-path>`, `refused: notInWorktree <absolute-path>`, `refused: noDefaultBranch`, `refused: invalidBranchName <detail>`, `refused: emptyBranchSlug`, `refused: destinationExists <absolute-path>`, `refused: destinationParentMissing <absolute-parent>` and `refused: unsupportedRepositoryLayout <absolute-path>`. Inspect/reselect --repo or the same-repository source for the first two. A missing/unborn start HEAD needs an intended committed start through ordinary project work. Destination/layout failures need inspection or another valid name/layout, never automatic deletion/directory fabrication.

Invalid-name detail is `branch name is empty`, `maximum length is 200 characters`, `contains whitespace or a control character`, `contains forbidden character <character>`, `contains forbidden sequence <sequence>`, `has an invalid component boundary` or `Git rejected the branch name`. Correct the name; forbidden characters include ~ ^ : ? * [ and backslash; sequences include .., @{ and //. Empty/colliding ASCII slugs need a distinct name.

For changed `.gitattributes`, printed options include committing/stashing it or a compatible full CoW copy. Choose only the source-preserving option the task authorizes. Do not add --no-fork while leaving incompatible --changes-only in the command.

## Failed creation/read and cleanup

Generic failure is `failed: <failure>; leftovers: <leftovers>`, possibly with a fetch line. Keep both parts:

| Failure payload/template | Safe next action |
| --- | --- |
| `readFailed <git-error>` | Restore readable repository/ref state; retry reads before mutation. |
| `createFailed <git-error>` / `forkGitFailed <git-error>` | Inspect branch, folder and administration plus cleanup result before another operation. |
| `sourceChanged <relative-path> <race-reason>` | Quiesce/reinspect source and leftovers, then decide on a new intent. |
| `entryFailed <relative-path> <entry-reason>[ errno <n>]` | Resolve the actual filesystem/access/copy limitation; preserve returned diagnostics. |
| `validationFailed <validation-reason>[ <relative-path>]` | Preserve state and report the invariant failure; no universal CLI repair. |
| `workingStateUnsupported <working-state-reason>[ <relative-path>]` | Resolve that source state or obtain a deliberate supported-mode choice. |
| `cancelled` / `rejectedAfterChange <SDK-rejection>` | Inspect cleanup; cancellation/rejection does not prove nothing changed. |
| `rejectedAfterChange branchCheckedOut <absolute-path>` | Inspect leftovers and use the holding checkout. |
| `branchMoveNotUndone <branch> from <oid> to <oid>` | Read current branch tip before deciding: these are attempted-move OIDs, not proof of current state. |
| `failed: readFailed; leftovers: notNeeded; <fetch-line>` | Top-level fetching read failed; fix read/access cause and inspect again. |
| `failed: outputEncodingFailed` | Output could not be encoded; operation state is not established by this reply. Inspect independently and report the defect. |

Leftovers are `notNeeded`, `noLeftovers`, `unverified` or `incomplete`, optionally listing kind/location and attempted move. Listed kinds can be destinationContent, linkedWorktreeAdministration, nestedAdministration, createdBranch, temporaryArtifact, lockFile or branchMoveNotUndone. Inspect them; a leftovers list is not a deletion checklist.

Use the returned reason to select the responsible owner, rather than inventing a different mode:

- Copy capability/layout: clientCapabilityUnavailable, unsupportedOperatingSystem, sourceFilesystemNotAPFS, destinationFilesystemNotAPFS, crossDevice, cloneCapabilityUnavailable, administrativeStoreOnDifferentDevice, sourceNotWorktreeRoot, sourceHeadUnavailable, invalidDestinationPath, overlappingRoots, linkedWorktreeNameInUse, invalidStart, fastForwardNotDescendant, invalidUpstream, fileProviderManagedLocation, datalessContent. Correct the actual source/layout/access condition or choose an explicitly acceptable tracked-only alternative.
- Working state: conflicts, operationInProgress, submoduleChanged, nestedRepository, sparseOrSkipWorktree, intentToAdd, unsupportedEntryKind, customFilter, attributesChanged. Finish/preserve the source operation with its owner; do not silently omit it.
- Source races: entryMissing, entryKindChanged, entryIdentityChanged, containmentEscape, contentChanged, repositoryStateChanged. Stabilize and reinspect source/cleanup before a new intent.
- Entry failures: unsupportedEntryKind, datalessFile, datalessPolicyUnavailable, strictCloneFailed, entryCreationFailed, metadataNotReproducible, unreadableEntry, unresolvableGitAdministration. Keep the exact path/errno; resolve the real storage/read/copy limitation.
- Validation failures: worktreeRegistrationInvalid, headMismatch, branchMismatch, entryCountMismatch, entryKindMismatch, hardLinkGroupBroken, indexTreeMismatch, indexStatNotRefreshed, sparseStateMismatch, submoduleStateMismatch, nestedRepositoryUnusable, sourceAdministrationReference, transactionArtifactRemains. Preserve evidence and report the failed invariant; no generic safe repair command exists.
- Git failures: repositoryNotFound, worktreeNotFound, locked, lockHeld, lockUnidentified, permissionDenied, worktreeNotPrunable, unsafeWorktreeRemoval, contentTooLarge, pathEscapesRepository, revisionUnavailable, headUnavailable, requiredObjectNotFound, noSharedHistory, multipleBestMergeBases, processFailed, processTimedOut, processCancelled, processOutputTooLarge, remoteRefTransactionIndeterminate, libgit2Failure, unsupported, branchMoved, branchCheckedOut, branchMoveNotUndone. Inspect the relevant repository/path/ref/lock or external-access cause; indeterminate/changed-state results require readback before any mutation.

## Remove/prune, fetch and retained branches

Removal reports `removed`, `alreadyRemoved`, `refused`, `failed` or `planned` per target. Prune reports `removed`, `wouldRemove`, `skipped` or `failed`. Failed entries can name archiveFailed, activityChanged, pruneFailed, observationFailed, removalIncomplete, branchDeletionUncertain, branchDeletionFailed(GIT_REASON) or lockCleanupIncomplete. Read actual directory/administration/branch/evidence/activity/lock-residue effects; preserve partial archives and uncertain branch deletion for inspection, not replay.

Branch effects distinguish deleted, retained, alreadyAbsent and unknown. Retention reasons such as defaultBranch, branchPolicyKeep, defaultBranchUnverified, movedSinceAssessment, checkoutUnknown, hasRemainingContribution, unknownAssessment or checkedOut need different actions: keep protected/policy-kept branches; inspect changed/unknown refs; coordinate holding worktrees; preserve remaining contribution unless deletion is explicitly authorized. A printed remove -D suggestion is still destructive.

Prune skips can name a stop above, notIntegrated, assessmentUnknown(REASON), detached or defaultBranch. An unknown integration assessment can be noTarget, branchNotFound, noMergeBase, multipleMergeBases, historyLimitReached, incompleteHistory, missingObjects or readFailed. Inspect history/target/access rather than upgrading unknown to integrated or forcing deletion. Local `activity=notChecked` supplies no idle guarantee.

Fetch lines are `fetch: fetched <commit>`, `fetch: skipped (<reason>)` or `fetch: failed (<reason>)<details>`; creation additionally includes remote/branch or `fetch: notOnRemote <remote>/<branch>`. Skip reasons are noFetchFlag/noRemote/noTarget/notNeeded where applicable. Failure reasons are networkFailure, authenticationFailure, gitLockHeld, gitLockUnidentified, upstreamNotOrigin, processFailure or unknown. Resolve the actual access/lock/upstream cause or intentionally use --no-fetch with its stale-ref cost. Never borrow credentials or delete a guessed lock.

Fetch details can include lock path/resource and `leftover lock paths`; retain them for the owner. A created result can leave large files as pointers: inspect `largeFiles`; an authorized `git -C WORKTREE lfs pull` is separate network work, not proof creation materialized them.

Exit 64 means parser failure; top-level creation refusal is 1, failed/encoding/read failure 2. Removal exits 2 for failed entries, 1 for refused/not-found stopped plans, otherwise 0; other stopped previews can be 0. Prune exits 2 for failed entries, otherwise 0 including all-skipped. Fetch failures and retained branches can coexist with 0. Complete only at the requested per-entry effects; dynamic diagnostics or an unlisted reason stay exact unresolved data with the next owner/action named.
