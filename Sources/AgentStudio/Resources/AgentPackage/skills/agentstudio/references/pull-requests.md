# Pull requests on a pane

This reference owns associating an existing GitHub pull request with a main pane, listing its PRs and withdrawing your contribution. Start with the resolved helper, verified local/live method support, the intended main-pane UUID, your supplied credential and the requested PR. Return the association result, remaining sources and any refusal or unknown detail. These commands do not create, merge or close the GitHub PR.

## Select the pane and PR

Use exactly one of `--target PANE_ID` or `--target-env` on every `pr` call. `--target-env` reads `AGENTSTUDIO_PANE_ID`; it is appropriate only when that is the intended pane. In a daemon, server or ACP session, use the main-pane UUID supplied for this task with `--target`: inherited environment can identify the pane that launched the server. Keep that target fixed; focus changes are not a replacement target. Drawer children are refused.

`TARGET_PANE_ID` below is the intended canonical main-pane UUID from the task or verified inventory. Replace the example PR with the authorized existing PR. Accepted references are a GitHub pull-request URL or quoted `owner/repository#number`; bare `#number`, issue links and other hosts are not accepted. The number must be between 1 and 2147483647.

```sh
"$AS_CLI" pr add 'owner/repository#123' --target "$TARGET_PANE_ID"
"$AS_CLI" pr list --target "$TARGET_PANE_ID"
"$AS_CLI" pr remove 'https://github.com/owner/repository/pull/123' --target "$TARGET_PANE_ID"
```

For an attached session whose environment identifies the intended main pane:

```sh
"$AS_CLI" pr add 'owner/repository#123' --target-env
"$AS_CLI" pr list --target-env
```

Before using these examples, the main path's discovery step checks `pane.pullRequest.add`, `pane.pullRequest.remove` or `pane.pullRequest.list` for the requested operation. If either helper or selected app lacks it, report the compatibility gap and hold that operation. Preserve credentials and use the supported app/helper pair; no guessed alias or alternate credential supplies missing support.

## Keep attribution and effects separate

The authenticated credential determines the author; there is no `--author` option. Adding is idempotent for that author on that pane. One PR can have several sources, including the worktree and other authors. Removing withdraws only your authenticated contribution: the row can remain because another source still supplies it. Do not borrow a different credential to remove someone else's contribution.

Read the operation's actual line and exit status:

| Operation/result | Meaning |
| --- | --- |
| add: `added … to the pane` / `… is already on the pane`, exit 0 | Your association was added or already present. |
| add: `the pane already has 20 pull requests`, exit 1 | Capacity refused the addition. |
| remove: `removed … from the pane` / `… is not on this pane`, exit 0 | Your contribution was removed or there was nothing for this removal to do. |
| remove: `… was added by someone else; not removed`, exit 1 | Ownership refused the removal; retain the other source. |
| list: rows or `no pull requests on this pane`, exit 0 | The pane list was read; rows include source attribution and known state. |

A successful association is not proof that GitHub details or toolbar rendering refreshed. A row's omitted state is unknown, not evidence that the PR is open or checks passed. If readback matters, list the same target and report the sources that remain.

## Refusals and completion

Exit 2 is usage, including a missing/conflicting target flag or missing target environment. Exit 1 covers rejected references, capacity/ownership refusals, missing credentials, a missing/non-main pane, no open window, unavailable storage or an unreachable app. Preserve the exact diagnostic. Correct only inputs within the intended action; an access or unavailable-runtime gap stays unresolved without changing identity or inventing a command.

Complete when the requested association/list/removal outcome is known for the intended pane and authenticated author, with remaining sources and unknown details reported. If support or access is absent, return that gap and hold the dependent action.
