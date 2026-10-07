# Panes Stage 1 — Requirements

Why the Panes sidebar changes now, for whom, and within what limits. The observable contract lives in the [Specification](2026-09-25-panes-stage1-specification.md). The owner of Agent Studio decides; every row below comes from the owner in conversation on the stated date. The 2026-09-23 pane-activity drafts are historical context only.

## The job

A person runs many terminal and agent panes at once. They open the Panes sidebar to answer three questions without visiting each pane:

1. **Where did something happen recently?**
2. **What is going on there?** Which agent is working on what, which PR it belongs to, and whether something needs them.
3. **How do I get there?** Jump in with the keyboard, and act inside the pane.

```mermaid
flowchart LR
    scan["Scan the Panes sidebar<br/>(Cmd+Shift+S)"] --> know["Know where and what:<br/>activity, Agent Line, chips"]
    know --> peek["Peek: click a chip,<br/>small popover"]
    know --> go["Go: Enter or number<br/>opens the pane"]
    go --> act["Act in the pane:<br/>approve, open view, PR list"]
```

The sidebar row is where the person **learns where to go**. The pane is where they **act**.

## What is wrong today

![Current Panes sidebar, 2026-09-26: pinned panes grouped Just Now and Last 7 days, other panes Just Now and Last hour; chips vary per row and rows change height](assets/current-panes-sidebar-2026-09-26.png)

*Current app (owner capture, 2026-09-26).*

- **Three clocks disagree.** The group reads when a terminal's latest line changed, the clock chip reads when the pane was last clicked or created, and ▶ means focused. A pane you just clicked looks fresh although nothing happened. The earlier capture ([2026-09-25](assets/current-panes-sidebar-owner-capture.png)) showed a "2m" chip inside "Last 7 days".
- **Rows jump.** Chips appear and disappear, and row heights change as they do, so the list shifts under the eye.
- **Rows don't say what's going on.** The third line is either the person's note or whatever the terminal printed last, e.g. "ctrl+c copy · enter copy & follow · esc clear" — noise, not information. Nothing says what an agent is working on or which PRs relate to the pane.
- **Pinned panes copy the full time taxonomy** instead of a smaller set, and the unpinned section is named "Other Panes".
- **The old inbox popups were removed** because they were confusing and did not work well. The popup design starts from scratch.

## What it should look like

![Target Panes sidebar: pinned Active, Recent, Older; drawer nested under its owner; each row shows title, worktree and branch, the person's note, the agent's Agent Line and one git/PR summary chip](assets/panes-v2-sidebar.png)

*Target illustration (details iterate later). Compare with the capture above: one activity clock, no terminal noise, and each row says what the agent is doing and how its PRs stand.*

## Authorized needs

| ID | Priority | Need and why it matters | Source |
| --- | --- | --- | --- |
| U1 | Must | A pane's activity means **something actually happened in that terminal**: agent hook activity (Claude, Cursor, Codex) and terminal output, best effort, using what already exists. | Owner, 2026-09-25 |
| U2 | Must | Activity is **not** what was clicked, focused or looked at last. | Owner, 2026-09-25 |
| U3 | Must | Group, order, clock chip and Active indicator agree, because they describe the same activity. | Owner, 2026-09-25 |
| U4 | Must | **Pinned Panes** use a smaller set of time groups: Active, Recent, Older. | Owner, 2026-09-23; reconfirmed 2026-09-26 |
| U5 | Must | **Panes** (the unpinned section) keep the detailed time and date groups, so panes are easy to find. | Owner, 2026-09-25; reconfirmed 2026-09-26 |
| U6 | Must | The two sections are titled **Pinned Panes** and **Panes**. | Owner, 2026-09-26 |
| U7 | Must | A row reads top to bottom: **pane name, worktree · branch, Note, Agent Line, chips**. The Note line appears only when the person wrote a note; the Agent Line appears only when an agent set one. Raw terminal output is never shown on the row. | Owner, 2026-09-26 |
| U8 | Must | Rows are stable: chips appearing or changing never make rows jump or change height. | Owner, 2026-09-26 |
| U9 | Must | Chips form a designed, useful set. Clicking a chip gives a small popover that helps the person decide where to go; for example, a PR chip shows the related PRs and their statuses. | Owner, 2026-09-26 |
| U10 | Must | Drawer panes are clearly identifiable; the drawer chip comes first in the chip row. | Owner, 2026-09-25 |
| U11 | Must | An agent can tell the person what it is working on through an **Agent Line** on its pane, separate from the person's own note. | Owner, 2026-09-26 |
| U12 | Must | An agent can set its pane's terminal title. | Owner, 2026-09-26 |
| U13 | Must | An agent can send messages (notices and asks) for its pane. They show on the Panes row and in the pane. The hooks Agent Studio already installs for Claude, Codex and Cursor use the same path. | Owner, 2026-09-26 |
| U14 | Must | An agent can link and unlink related worktrees and PRs to its pane, across several repositories. The person can always see every link and remove any except the pane's current working-directory worktree. An agent removes only what it added; adding twice has no second effect. | Owner, 2026-09-26 |
| U15 | Must | Switching is fast: Cmd+Shift+S and the existing keyboard navigation get the person onto the list and into the pane. Escape or a second Cmd+Shift+S returns them to typing. | Owner, 2026-09-25 and 2026-09-26 |
| U16 | Must | Session state is listed and grouped in the separate Sessions view, not in Panes: Panes has no Running, Needs You or Done categories or sections. Each Panes row still shows its session's status on its own Session status line (needs you, failed, working, idle), taken from hook facts, so an agent waiting on a permission prompt in its own terminal is visible from Panes. | Owner, 2026-09-25; amended 2026-09-30 and 2026-10-01 |
| U17 | Must | Stage 1 does not change zmx. Agent writes go through Agent Studio's own IPC, not zmx IPC. | Owner, 2026-09-26 |
| U18 | Must | Popups for git and messages use the same popover style as the pane arrangement popup, redesigned from scratch; the removed inbox components are not revived. Visual details iterate after the first working version. In the pane, agent popups are a button in the pane's bottom icon bar with a popover; approvals open automatically. All Panes UI, including these in-pane popovers, is built by the Panes workstream; the IPC workstream supplies data and methods. | Owner, 2026-09-23 and 2026-09-26 |
| U19 | Must | Every row (main and drawer) and the pane's bottom toolbar show **one git/PR summary button**, colored like today's PR button, covering all the pane's worktrees and PRs; clicking it shows each worktree and PR with its state and who added it. It is one shared implementation, the same one Bridge uses. | Owner, 2026-09-26 |
| U20 | Must | Panes group by activity only; the Repo and Tab grouping options are removed from Panes (multi-repo work makes Repo misleading, and Tab grouping confused pins). | Owner, 2026-09-26 |
| U21 | Must | A sidebar toggle with a shortcut shows or hides drawer panes under their owner pane, like showing or hiding sub-issues. A drawer's links live on its owner pane. The owner pane's message button also surfaces its drawers' messages, including their asks. | Owner, 2026-09-26 |
| U22 | Must | What an agent puts in front of the person is one kind of thing, an **agent message**, in two shapes. A **notice** tells: it never waits and never changes status. An **ask** needs the person: it gives its reason (an approval, a question, or blocked), its form (a choice, free text, or a form), and whether the agent waits for the answer until a deadline. A message can carry actions: open a file at a line, open a PR, go to a pane. Asking to open a file in the background posts a notice with an open-file action; taking over the screen is an approval ask. From PR C, a permission request becomes a blocking approval ask answered in the app (Allow, Deny, or Ask to hand back to the agent's own prompt; a timeout never grants). A provider's other prompts in its terminal (its own questions and forms) are shown as status and answered in that terminal, never in the app. Artifacts are defined now so references are stable; publishing comes later. Each message shows who sent it and why. | Owner, 2026-09-26; simplified show and unified messages 2026-09-27 |
| U23 | Must | Each agent can check what happened on its pane since it last looked: answers to its asks and its messages the person dismissed (an expired or handed-back ask shows its outcome). *Links the person removed are DEFERRED (owner, 2026-10-02): link removal ships without agent notification; a removed link is simply absent from the pane's current links.* A removed link can be re-added as a normal add; the person tells the agent directly if a link should stay gone. | Owner, 2026-09-26 |
| U24 | Must | Messages can be filtered by how much attention they need: approvals, replies, attention, and information. The pane's badge counts what needs the person (approvals, replies, attention); informational messages stay in the list but out of the count unless the person turns them on. Approvals are never buried under informational messages. | Owner, 2026-09-27 |

Names: **Agent Line** is the name people see; `AgentStatusLine` is the name in code (owner, 2026-09-26). The person's own note stays **Note**.

## Boundary

- **Changes:** the Panes sidebar (activity clock, section titles, time groups, row lines, chip set, chip popovers, keyboard entry and exit); agent-writable pane context (Agent Line, terminal title, agent messages, related git links) and how it shows in Panes and in the pane.
- **Reused:** existing agent hooks and their qualification, terminal settled-line observation, git and PR facts the app already tracks, the person's pane note, sidebar keyboard navigation and number badges, native popovers.
- **Protected:** zmx, its protocol and daemon lifecycle; the Repos surface's behavior; Sessions state and its view.
- **Shared with the IPC workstream:** the IPC methods and permissions agents use to write pane context are designed by the IPC orchestrator (ipc-improvements) against the pane-context contract in this design set. All UI stays with Panes.
- **Non-goals:** persisting activity across app restart; detecting repeated identical output; telling a TUI redraw from real work; Running/Needs You/Done categories or sections in Panes (a row's glyph shows its status, U16); new zmx metadata; Stage 2 host or remote work.

## Delivery order

- **Stage 1 = PR A + PR B/C.** PR A makes today's Panes right on existing data: activity clock, sections, activity-only grouping, pinned groups, row lines, stable heights, drawer chip and toggle, keyboard entry and exit. PR B (IPC workstream) adds pane context over IPC: title, Agent Line, agent messages (notices and asks, with actions), session status, links, the change feed, and the pull-request summary value. PR C shows it: the Agent Line and its status glyph, the messages chip and popover (answering asks, including permission requests), and the git/PR summary button and popover.
- **Stage 2 = restart resilience:** after a reboot, scrollback returns and each pane's command or agent resume is ready to run. Agents need not start themselves. The app may need to be open to capture scrollback at first; later a low-CPU daemon captures while it is closed.
- **Stage 3 (parked):** zmx fork, agentd and remote hosts.

## Open decisions

| Item | State |
| --- | --- |
| How agents or hooks trigger writes (e.g. when a hook updates the Agent Line) | Out of scope by owner decision; this design covers what the IPC can express. |
| Cursor approval timeout: fail open or closed | Deferred; recommendation is fail closed. |
| Pushing answers into a running agent, "always allow this session" | Later stages. Asks with choice, free-text or elicitation-schema forms are Stage 1: answers are pulled by the agent, or returned to a waiting blocking ask (U22, U23). |
| Snooze (future Sessions view) | Anything time-sensitive (a live approval or question) cannot be snoozed. |
