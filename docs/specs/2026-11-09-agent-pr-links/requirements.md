# Agent PR links: Requirements

Any agent working with Agent Studio can attach the GitHub pull requests it works on to a pane, and the person sees and manages them in a well-designed PR popover on that pane's drawer toolbar.

## Who needs this

| Who | Job | Pain today | What changes |
| --- | --- | --- | --- |
| The person (owner) | Keep track of which PRs each agent is working on, per pane, and open or check them in one click. | The drawer toolbar's GitHub PR button shows only the one PR found from the pane's worktree. An agent whose working directory spans several worktrees, or that works on another repository's PR, leaves no trace there. The button opens the PR straight away; there is no place to see details. | Every PR an agent attached is listed, with details, in a popover from that button. |
| An agent in a pane | Tell the person "this is the PR I'm on". | No command exists. A 2026-09-26 design (`pane.link.add`) was never built, and it would only have accepted an agent bound to its own pane. | One `agentstudio` command adds or removes a PR on a pane. |
| An agent running elsewhere (a server agent behind the Router) | The same, for the pane that shows its conversation. | Its credential belongs to the pane that started its server, so "its own pane" is the wrong pane. | It names the pane with `--target`, as it already does for `drawer browse`. |

## Today and the change

The PR button sits in the pane's drawer toolbar, left of the Bridge and file controls ([owner screenshot](../../../tmp/2026-11-09-agent-pr-links/toolbar-today.png)):

```text
 today                                          after
 ┌──────────────────────────────────────────┐   ┌──────────────────────────────────────────┐
 │  ⎇  │ </> ⌃⌄ │ 🗀 │ ⧉ │ ⛶                │   │  ⎇ 3 │ </> ⌃⌄ │ 🗀 │ ⧉ │ ⛶              │
 └──────────────────────────────────────────┘   └──────────────────────────────────────────┘
  ⎇ = GitHub PR button                            ⎇ opens the PR popover:
  opens the worktree's one PR in the browser      ┌──────────────────────────────────┐
  (or nothing when there is none)                 │ #680 Drawer browser   ✓ checks  … │
                                                  │      added by Codex · 2h          │
                                                  │ #681 Agent PR links   ● running … │
                                                  │      added by Claude · 5m         │
                                                  │ #677 (from this worktree)       … │
                                                  └──────────────────────────────────┘
```

The popover's content and layout are a design proposal to iterate on with the owner (owner, 2026-11-09: "we can iterate design tomorrow"); this sketch fixes only that the button leads to a list of PRs with details.

## Needs

Scope is one concern: a pane's GitHub PRs. No capability level.

| ID | Need or outcome | Why it matters | Basis | Authority | Priority |
| --- | --- | --- | --- | --- | --- |
| U1 | Any agent using Agent Studio can add a GitHub PR to a main pane from the `agentstudio` CLI, naming the pane exactly as `drawer browse` does: `--target <pane id>` or `--target-env`. Only callers the app authenticates may do it. | Agents run in panes and behind the Router; both must reach the pane the person watches. | Owner 2026-11-09: "any agent should be able to add links with the same drawer browser target or target env for github links"; "so any agent using agent-studio can do this". The `drawer.browse` precedent: owner 2026-11-07, any main pane, authenticated callers only. | authorized | Must |
| U2 | A pane's PRs come from explicit adds, not only from the pane's worktree association. | One agent working directory can touch several worktrees, and an agent can work on a PR whose branch isn't checked out in the pane. | Owner 2026-11-09: "not just get it from the associations since same cwd agent can work on multiple worktrees". | authorized | Must |
| U3 | The drawer toolbar's GitHub PR button opens a popover that lists the pane's PRs with their details. It is designed well and built from the app's shared popover components. | The person needs one place per pane to see what each agent is working on and its state. | Owner 2026-11-09: "have a popup … using shared components"; "its a popup with details etc should be designed well"; "good shared component popover and design". | authorized | Must |
| U4 | Scope is GitHub pull requests only, and the command, labels and icon belong to the existing GitHub icon family rather than a generic "link". | A narrow, well-named feature fits the toolbar the person already reads. | Owner 2026-11-09: "this is only for github so the name should be better in the existing gh icon system". | authorized | Must |
| U5 | Each added PR records who added it: an agent (provider and session when known), the person, or the app. An agent removes only PRs it added; the person can remove any. Re-adding a removed PR is a normal add. | The person can tell agents' claims apart and clean up; agents can't erase each other's work. | Pane-context design N9, owner-accepted 2026-09-26, author and removal rules; the refusal of callers without a bound agent session is superseded by U1 (owner 2026-11-09). | authorized | Must |
| U6 | The person sees the popover content stay current: a PR's state, checks and review update without reopening the app. | A stale "checks running" is wrong news. | Pane-context design N11 (2026-09-26): links shown "with their PR status summary". Freshness bound not stated by the owner. | hypothesis | Should |
| U7 | A pane's added PRs survive an app restart, follow the pane through close and Undo, and go away when the pane is permanently gone. | Agents' context isn't lost on relaunch. | Pane-context design N14 (2026-09-26), records that follow the pane. | authorized | Must |

## Limits and non-goals

- **Not** generic links, worktree links (N9's `addMember`), or non-GitHub forges in this work (U4).
- **Not** creating, merging, reviewing or commenting on PRs from Agent Studio; the popover shows and opens.
- **Not** telling an agent that the person removed its PR; N9's R19 deferral stands (owner 2026-10-02).
- **Not** a change to `drawer.browse` or to any other method's eligibility; this adds one new method family.
- **Not** a new forge credential flow. PR facts use the access Agent Studio already has; a PR it cannot read is shown with that state.
- **Repository limit:** this repository only; the branch builds on PR #680 (`drawer browse` targeting and the shared popover parts live there).

## Open owner choices

The owner asked for the design and the build now, and to iterate the design tomorrow (2026-11-09: "design that and build it as separate worktree … we can iterate design tomorrow"). Each choice below is therefore built as the proposal shown, marked as provisional in the Specification, and confirmed or changed on the design page before merge. A change reopens the rows it touches.

| # | Choice | Proposal built now |
| --- | --- | --- |
| 1 | Does the worktree PR appear in the same list? | Yes, first, labelled "this worktree"; one row when an agent also added it. |
| 2 | Row details and the button summary | Number, title, repository when different, state, checks, review, blocker, authors, time; button shows the count when > 1 and the most urgent checks colour. |
| 3 | Freshness of details (U6) | 180 s, the app's existing forge freshness, only for visible toolbars and open popovers. |
| 4 | An agent lists a pane's PRs from the CLI | Yes: `agentstudio pr list`. |
| 5 | Where agent-added PRs are stored. The 2026-09-26 design (S11, R18–R19) put links in Bridge's membership as its only writer. | Pane-context records in the pane-context lane of `local.sqlite`, owned by the pane-context service. Like pane messages, they are lost if that database is quarantined and recreated after corruption. **Owner selected (2026-11-09, design page): "yes" to A.** This supersedes S11 for PR links only and accepts the reset loss. |
| 6 | Proof for agents behind the Router | Prove the server-agent path in the debug app with a server process started from one pane acting for another; the real Router-hosted run waits for an installed build that contains this. **Owner selected (2026-11-09): "this is deferred, we will do this later".** It runs on the first beta containing this change and doesn't gate merge. |
