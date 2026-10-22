# Git parity reference: app policy plus pinned SDK

The Rust Host comparison must preserve both AgentStudio's application policy and `agentstudio-git` semantics. The reference is AgentStudio `624300332f5e50f7bb8cbb9fc786d5e5b4a3d462` with SDK `4cca397dfc869857064da4e9ec8289ea46adc479`. These are source findings; no Rust Git engine, Linux counterpart or new parity experiment has run.

## Worktree copy policy is not wholly in the SDK

The app reads `.agentstudio.config.json` as a nested `worktree` object with an `include` array; a literal search for `worktree.include` misses it. [Config decoding and pattern compilation](../../../../../../Sources/AgentStudioWorktreeOperations/AgentStudioRepositoryConfigReader.swift:19) defaults an absent array to empty and reports malformed entries as `configInvalid`. `GitPathPattern` in the pinned SDK owns the positive gitignore-pattern grammar, anchoring and directory matching.

The caller makes the materialization distinction explicit: [creationCopyRules](../../../../../../Sources/AgentStudioWorktreeOperations/WorktreeOperationRunner+Creation.swift:82) skips this config for plain checkout, supplies `.copyAll` for changes-only, and supplies `.copyMatching(compiledPatterns)` for copy-on-write. That is the policy for **ignored roots**, not a filter over every untracked path. Missing, invalid and unreadable config need distinct fixtures; `--no-fork` must retain its escape from invalid fork config.

The earlier SDK-only search correctly found no application key in that package. It cannot establish that the application lacks the behavior. The app and SDK together are the parity reference for Host worktree creation/forking.

## Compare meanings and effects, not display strings

- **Scoped status.** The SDK derives scoped file counts from entries while retaining repository head/upstream facts. Its exact-clean-baseline gate requires literal full scope (`pathspecs == nil`), supported current observation coverage and no entries; an empty array is not the same authority. [Status owner](https://github.com/getagentstudio/agentstudio-git/blob/4cca397dfc869857064da4e9ec8289ea46adc479/Sources/AgentStudioGitLocal/Status/LibGit2StatusReader.swift#L50).
- **Staged refs.** A failed native transaction commit is reported as `remoteRefTransactionIndeterminate`; the source warns that updates commit individually. Observe canonical and staging refs independently after failure. A clean worktree or Codable roundtrip cannot establish atomic ref effects. [Promotion owner](https://github.com/getagentstudio/agentstudio-git/blob/4cca397dfc869857064da4e9ec8289ea46adc479/Sources/AgentStudioGitRemote/LibGit2StagedFetchPromoter.swift#L11).
- **Config coverage.** Compare dependency scopes and support separately from exact status facts. The source reports incomplete include coverage rather than manufacturing a clean baseline. The bounded source reports below identify global/XDG/conditional-include fixtures; their outcomes remain unrun here.
- **Worktree effects.** Compare registration, branch/index/contents and cleanup residue separately. A Linux leaf reflink result or an ordinary filesystem copy is not a counterpart for the full fork operation.

## Next bounded experiment

Freeze one Rust candidate and exact fixtures before running. Start with scoped status/rename boundaries, ordinary add/remove/prune, the app's materialization-specific include policy, staged-ref failure readback, and config dependency changes. Run the real Swift SDK on Mac against the same initial states; compare typed values, refusals and side effects. Qualify Linux build/filesystem prerequisites separately. No new application `git` shell-out path or fallback-copy mechanism is selected by this research.

The two source-only Worker handbacks retain the detailed fixtures and limits: [status/worktree](../../../../../../tmp/practices-research/2026-10-22-git-parity/R-status-worktree.md) and [refs/config](../../../../../../tmp/practices-research/2026-10-22-git-parity/R-refs-config.md). They are reference gathering, not executed parity proof.
