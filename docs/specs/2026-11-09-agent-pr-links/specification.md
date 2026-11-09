# Agent PR links: Specification

What must be observably true when agents add GitHub pull requests to a pane and the person reads them in the PR popover. Requirements: [requirements.md](requirements.md). This document defines the nouns, the CLI contract, the popover's observable behaviour, failures and proof obligations. It names no component, type, table or wire field; [Program Design](program-design.md) binds them.

```text
 agent (any pane, or a server agent)            person
        │  agentstudio pr add <PR> --target <pane>     │ clicks the PR button
        ▼                                              ▼
 ┌──────────────────────── Agent Studio (one opaque system) ────────────────────────┐
 │  the pane's PR list  ◄── worktree PR (existing, derived)                          │
 │        │                                                                          │
 │        └──► PR popover: rows with details, open, remove                           │
 └───────────────────────────────────────────────────────────────────────────────────┘
        ▲  details read from GitHub with the access Agent Studio already has
```

## Problem and outcomes

| ID | Statement | Needs |
| --- | --- | --- |
| P1 | A pane shows at most one PR, derived from its worktree's current branch; agents have no way to say which PRs they work on, and the toolbar button opens that one PR with no details. | U1, U2, U3 |
| O1 | Any authenticated agent can add and remove GitHub PRs on any main pane, from the CLI, with the `drawer browse` targeting. | U1, U4, U5 |
| O2 | The PR button opens a popover listing every PR on the pane with its details, where the person opens or removes them. | U2, U3, U6 |
| O3 | The list keeps its authors, survives restart and follows the pane's life. | U5, U7 |

## Entities

| ID | Term | Identity rule | Relationships | Invariants | Observable states | Canonicalizes | Basis |
| --- | --- | --- | --- | --- | --- | --- | --- |
| E1 | **GitHub PR** | host `github.com` + owner + repository + number. Owner and repository compare case-insensitively, as GitHub does; `https://github.com/O/R/pull/7`, `https://github.com/o/r/pull/7/files` and `O/R#7` name the same E1. | referenced by 0..n E2 | number ≥ 1 | open · draft · merged · closed (from GitHub) | "PR", "pull request", "gh pr"; excludes issues, commits and branches | U1, U4 |
| E2 | **Pane PR** | one main pane + one E1. Adding an E1 already on that pane does not make a second E2. | belongs to exactly one main pane; references exactly one E1; has 1..n E3 | at most 20 per pane; never on a drawer pane | present · removed | "link", "attached PR" | U1, U2, U5 |
| E3 | **Contribution** | one E2 + one E4. A second add by the same author changes nothing. | belongs to exactly one E2 | an E2 with no contributions does not exist | present · withdrawn | "added by" | U5 |
| E4 | **Author** | **pane agent:** the source pane of the caller's pane credential, plus its conversation (provider + conversation id) when the caller names one and Agent Studio finds it bound to the source pane, now or earlier; otherwise the source pane alone · **client:** an authenticated caller whose credential has no pane (an automation or MCP client), identified by its credential · **person** | contributes 0..n E3 | identity comes only from the authenticated credential and Agent Studio's own binding records; a named conversation never bound to the source pane is ignored; two session-less callers from one source pane are one author; the same conversation after a rebind is the same author | — | "who added it"; excludes the target pane | U1, U5 (N9) |
| E5 | **Worktree PR** | the existing single open PR derived from the pane's worktree branch (unchanged behaviour). | 0..1 per pane; may name the same E1 as an E2 | not added or removed by anyone; follows the worktree | present · absent | "PR from the association" | U2 |

A server agent's credential belongs to the pane that started its server, so its PRs read "added by an agent in <that pane>" unless its conversation is bound there. That is the honest limit of what the credential proves.
| E6 | **PR details** | one E1 at one read time | describes one E1 | never written by agents | loaded · loading · unavailable(reason) | title, state, checks, review, mergeability, updated time | U3, U6 |

A pane's **PR list** is its E2 entries plus its E5 when present, with one row per distinct E1. A row's **sources** are "this worktree" when E5 names it and the authors of its E3 when an E2 exists; a row can have both.

**Proposed, adopted provisionally.** R6, R10, R11 and R14 settle choices the Requirements list as open. The owner asked for the design and the build now and to iterate tomorrow (2026-11-09), so they are built as written and confirmed or changed on the design page; a change reopens the affected rows here and downstream.

## Requirements

### Adding and removing (O1)

| ID | Requirement | Entities | Needs | Proof |
| --- | --- | --- | --- | --- |
| R1 | When an authenticated caller runs `agentstudio pr add <PR> (--target <pane id> \| --target-env)` naming a main pane, Agent Studio records an E3 by the caller's E4 on that pane's E2 for the named E1, creating the E2 if absent. | E1–E4 | U1, U5 | V1 |
| R2 | The PR may be given as a GitHub PR URL (any path below `/pull/<n>`, with or without query or fragment) or as `owner/repo#n`. Anything else is refused before any change, with `not a GitHub pull request: <input>`. | E1 | U1, U4 | V2 |
| R3 | The targeting matches `drawer browse` exactly: exactly one of `--target` or `--target-env`; `--target-env` reads `AGENTSTUDIO_PANE_ID`; any main pane is a valid target for an authenticated caller; a drawer child or drawer terminal is refused `not a main pane: <id>`; an unknown id is refused `pane not found: <id>`; a caller with no credential is refused. | E2, E4 | U1 | V3 |
| R4 | When the pane already has 20 E2 and the E1 is not among them, the add is refused with `the pane already has 20 pull requests`, and nothing changes. | E2 | U3 | V4 |
| R5 | `agentstudio pr remove <PR> (--target … \| --target-env)` withdraws the caller's own E3. When it was the last E3, the E2 disappears. If the caller has no E3 on that E2, nothing changes and the result says `added by someone else`. If the E2 doesn't exist, the result is `not on this pane`. | E2–E4 | U5 | V5 |
| R6 | `agentstudio pr list (--target … \| --target-env)` prints the pane's PR list, one line per E1: reference, source (`worktree` or the authors), and the last known state when details have loaded. | E2, E5, E6 | U1 | V6 |
| R7 | The app stamps E4. Nothing in the request can name or change an author. | E4 | U5 | V7 |
| R8 | Adding or removing never moves focus, never changes the visible pane, tab or drawer, and posts no notice. The PR button's summary updates. | E2 | U3 | V8 |

### The PR popover (O2)

| ID | Requirement | Entities | Needs | Proof |
| --- | --- | --- | --- | --- |
| R9 | The PR button keeps its place and icon family in the drawer toolbar. It is enabled when the pane's PR list is non-empty, and clicking it opens the PR popover; with an empty list it is disabled with help text that says how agents add PRs. | E2, E5 | U3, U4 | V9 |
| R10 | The button shows a summary of the list: the count when there is more than one PR, and the most urgent checks state across the list (failed, then running, then passed), coloured as today. | E2, E5, E6 | U3 | V10 |
| R11 | The popover lists one row per E1, the worktree PR first and labelled "this worktree", then added PRs newest first. Each row shows: number and title, repository when it differs from the pane's repository, state, checks, review decision, a blocker when there is one (conflicts, changes requested, review required, blocked merge), who added it, and when. | E1, E2, E5, E6 | U2, U3 | V11 |
| R12 | Each row opens its PR in the browser. A row with any E3 offers remove; the person's remove withdraws every E3 on that E2. The row then disappears unless "this worktree" is still a source, in which case it stays with only that source and no remove. A row whose only source is the worktree has no remove. | E2, E3, E5 | U3, U5 | V12 |
| R13 | The popover is keyboard-usable like the app's other popovers: arrow keys move the selection, Return opens the selected PR, Command-Delete removes the selected added PR, Escape closes, and focus returns to where it was. | E2 | U3 | V13 |
| R14 | While a pane's drawer toolbar is visible or its PR popover is open, E6 for each row of its PR list, the worktree row included, is read when missing or older than 180 s (proposed: the app's existing forge freshness). A row with no details yet shows `loading`; a row with details keeps showing them while a refresh runs and changes in place when it lands. Opening never waits for GitHub. | E6 | U6 | V14 |
| R15 | If GitHub can't be read for a row (no access, not found, rate limited, offline): with no earlier details the row shows `unavailable` and the reason; with earlier details it keeps them and shows `couldn't refresh` with the reason and the time of the last good read. Open and remove stay usable; other rows are unaffected; the next successful read clears the marker. | E6 | U3, U6 | V15 |

### Lifetime (O3)

| ID | Requirement | Entities | Needs | Proof |
| --- | --- | --- | --- | --- |
| R16 | A pane's E2 entries and their E3 survive an app restart unchanged. | E2, E3 | U7 | V16 |
| R17 | Closing a pane hides its E2 entries; Undo of that close brings them back unchanged. When the pane is permanently gone, its E2 entries are deleted with its other pane-context records. | E2 | U7 | V17 |

## CLI contract

`agentstudio pr add|remove|list` prints one line and exits:

| Result | Line | Exit |
| --- | --- | --- |
| Added | `added <owner/repo#n> to the pane` | 0 |
| Already there by this author | `<owner/repo#n> is already on the pane` | 0 |
| Removed | `removed <owner/repo#n> from the pane` | 0 |
| Not on the pane | `<owner/repo#n> is not on this pane` | 0 |
| Added by someone else | `<owner/repo#n> was added by someone else; not removed` | 1 |
| Not a PR | `not a GitHub pull request: <input>` | 1 |
| Pane full | `the pane already has 20 pull requests` | 1 |
| No target flag, or both | `choose one of --target or --target-env` | 2 |
| Env variable missing | `AGENTSTUDIO_PANE_ID is not set; use --target` | 2 |
| Pane unknown | `pane not found: <id>` | 1 |
| Not a main pane | `not a main pane: <id>` | 1 |
| No credential | `Agent Studio refused the call: no credential` | 1 |
| App unreachable | `Agent Studio is not reachable` | 1 |

`list` prints one line per PR, then exit 0; an empty pane prints `no pull requests on this pane`. Adding does not wait for details from GitHub.

## Constraints

| ID | Constraint | Needs |
| --- | --- | --- |
| C1 | GitHub only: hosts other than `github.com` are refused as not a GitHub pull request. | U4 |
| C2 | Names: the CLI verb is `pr`; displays use "Pull Requests" and the existing PR octicons. No "link" wording. | U4 |
| C3 | The popover reuses the app's shared popover chrome, rows, keyboard routing and control projection; no feature-local copies of shared styling. | U3 |
| C4 | PR details are read only for panes whose drawer toolbar is visible or whose popover is open, at most once per PR per freshness window; hidden panes and a closed app make no GitHub calls for added PRs. | U6 |
| C5 | Agent message text, PR titles and author session ids are never recorded in telemetry. | U5 |

## Proof obligations

| ID | Decides pass when | Reference |
| --- | --- | --- |
| V1 | Through the real CLI and app, an add from pane A targeting main pane B produces exactly one row in B's list naming that PR and A's agent as author; a second identical add leaves one row and one author. | R1, the CLI table |
| V2 | Every accepted input form names the same E1; issue URLs, commit URLs, other hosts and malformed text are refused with the exact line and no change. | R2, E1 |
| V3 | Each targeting case prints its exact line and exit, identical to `drawer browse` for the same case. | R3, `drawer browse` table in `docs/architecture/commands/ipc.md` |
| V4 | The 21st distinct add is refused and the list still has 20. | R4 |
| V5 | Own remove, last-author removal, someone else's remove, and absent remove each give their line, exit and list state. | R5 |
| V6 | `list` output matches the popover's rows for the same pane. | R6, R11 |
| V7 | A request that tries to supply an author is either refused or ignored, and the stamped author is the caller's. | R7 |
| V8 | Focus, visible pane, tab and drawer are unchanged by add and remove, and no notice appears. | R8 |
| V9 | Button enabled and disabled states and the popover opening, observed in the real app. | R9 |
| V10 | The summary for lists with mixed checks shows the right count and colour. | R10 |
| V11 | Rows, order and fields match R11 for a list with a worktree PR, two added PRs from different authors and one from another repository. The visual verdict waits for the owner's review of real frames (design gate); until then V11 decides only R11's content and order. | R11; the owner's frame review once given |
| V12 | Open launches the browser at that PR; remove from the popover removes all contributions; a row that is also the worktree PR stays with only that source and no remove; a worktree-only row has no remove. | R12 |
| V13 | Each key in R13 does its action with keyboard focus in the popover, and focus returns on close. | R13 |
| V14 | A row with no details shows loading, then the fetched details; a row with details older than 180 s keeps them during the refresh and shows the new ones after; a fresh row isn't refetched; the popover never blocks or resizes for it. | R14 |
| V15 | A row for a PR the account can't read shows unavailable with a reason while other rows show details; a row that loaded once and then fails to refresh keeps its details and shows `couldn't refresh` with the reason, cleared by the next good read. | R15 |
| V16 | The list is identical before and after an app restart. | R16 |
| V17 | Close hides, Undo restores, permanent removal deletes. | R17 |

## Not specified here

- The popover's exact layout, spacing and typography: the owner-approved design frames decide them (V11).
- Which GitHub API calls fetch details, how they're cached, and where entries are stored: Program Design.
- GitHub Enterprise hosts (C1 refuses them); revisit only on the owner's word.
