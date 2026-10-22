---
name: agentstudio
description: Use when working with Agent Studio panes or its CLI, including worktrees, pane messages, session or terminal context, and App commands.
---

# Agent Studio

Choose scope before action. Local `worktree` commands operate on Git and files without an app connection. App commands and pane operations use the selected runtime and supplied pane identity. A method appearing in help tells you it exists; its eligibility and the user's task decide whether you may use it.

## Find the helper and target

Resolve the executable once for this shell:

```sh
AS_CLI="${AGENTSTUDIO_CLI:-/Applications/AgentStudio.app/Contents/Helpers/agentstudio}"
[ -x "$AS_CLI" ]
"$AS_CLI" --help
```

Use the supplied helper when present. Bare `agentstudio` can launch the GUI. Local help works without the app; `help --live` connects to it. If the executable is unavailable, report that gap and continue independently authorized work through ordinary tools/chat.

For pane work, `self` identifies the caller's pane. `pane.current` identifies the focused pane and can change when the person moves focus. Preserve the supplied environment and provider session identity; never borrow credentials, fabricate session IDs or retarget through focus.

A Claude background session (`CLAUDE_CODE_SESSION_KIND=bg` or nonempty `CLAUDE_JOB_DIR`) can inherit pane variables without being attached. Keep those markers intact and report progress in chat. `notify`, `ask`, `line`, `title` and their raw reporting methods refuse with `background session: not attached to a pane`. Reads, answers and withdrawal retain their normal authentication/scope rules.

Continue only when the intended local repository or app target and requested effect are identified. Discovery does not expand task authority. In particular, terminal input, closing a pane and worktree removal need authorization for their actual effects.

## Load the detail for the requested work

Use the resolved `"$AS_CLI"` in every command below and in the references. Examples with uppercase placeholders require real values from the task or returned state; do not execute them literally.

- IF the requested work creates, opens, lists, removes or prunes Git worktrees, load `references/worktrees.md` and return the selected branch/start/content mode, folder, fetch effects and outcome or unmet prerequisite.
- IF the requested work updates an Agent Line/title or sends, reads or withdraws pane notices/asks, load `references/pane-communication.md` and return the actual message/answer state and any usable decision.
- IF the requested work reads the caller pane, drawers or status-engine session context, load `references/pane-context.md` and return the relevant state, returned paging cursors and remaining truncation.
- IF the requested work discovers or executes an App command or uses raw IPC/discovery/event methods, load `references/commands-and-ipc.md` and return the selected live contract, allowed target and actual receipt boundary.
- IF the requested work inspects or controls a terminal/pane or adds a drawer child, load `references/panes-and-terminals.md` and return the resolved own-pane target and observed runtime/input/wait result.
- IF a worktree result fails or has a refusal, skip, partial effect or retained branch that must be resolved, load `references/worktree-recovery.md` and return its exact reason/effects and safe supported next command or owner action.
- IF an app/IPC call is refused, queued, uncertain or otherwise cannot supply its required result, load `references/recovery.md` and return the exact outcome, any known effects and a safe next action or explicit no-CLI-repair gap.

Perform the requested action only within its authority; an advice request returns a plan without execution. Inspect the actual result, including partial effects and retained IDs. A zero exit code, accepted input or displayed prompt is not proof of completed work or approval.

## Finish at the observed boundary

The Agent Line is a message; hooks own status, and an ask owns a pending decision. Keep these meanings separate. An expired/withdrawn/stale ask supplies no permission; a reply can also be a denial.

Preserve work and evidence when a destructive action is refused. Do not turn a printed force/discard option into permission. After uncertain delivery, inspect relevant state before any new intent; never blindly replay. Ordered stale line/title payloads are final and cannot be retried with a new number or epoch.

Complete when the supported, authorized action's actual outcome is known, relevant IDs/state are retained, and any missing result has an exact unresolved condition and safe next action. Use chat when reporting is unavailable and continue work already authorized. This skill does not authorize provider setup, plugin installation, permission changes or new CLI capabilities.
