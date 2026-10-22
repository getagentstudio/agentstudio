# Pane agent status by call intent — Requirements

Specification: [2026-10-15-pane-agent-status-by-intent.md](2026-10-15-pane-agent-status-by-intent.md) → Program Design: [program design](2026-10-15-pane-agent-status-by-intent-program-design.md)

## Who is affected and what hurts

The owner runs many coding agents (Claude Code, Codex) in Agent Studio panes. The Panes sidebar promises each agent's status on its row: `Working`, `Idle · done` or `Needs you · approval`. That status comes from the agent's hooks.

On 2026-10-15 the owner's production app (0.0.111) had 19 panes running an agent. Only **one** showed status. The rest showed only an activity time, which comes from terminal output, not from the agent.

- **11 panes:** the shell holds a pane token the app no longer recognizes. A pane's shell lives in zmx and outlives app upgrades and restarts, so it keeps the token it started with. The app did not keep the matching credential (a loss path fixed in 0.0.109). Every hook call from these panes is refused at login, so the agents can never report.
- **7 panes:** the token is still recognized, yet no hook call has succeeded. The reason is unknown.
- **Silent failure:** the hook exits 0 by design, so an agent turn never fails because of Agent Studio. Its only trace is a generic `provider_hook_failed` log line with no pane and no reason (760 in one hour on 2026-10-15). Nothing in the app shows that a pane's agent is not connected.

Evidence: `tmp/sol-pane-auth-report.md` and `tmp/sol-pane-status-map.md` in the implementation worktree; Lead verification of the binding rule, the client login order and the binding-keyed status store on origin/main.

## What the owner asked for

| ID | Need, in the owner's words or decision | Authority | Priority |
| --- | --- | --- | --- |
| U1 | "why don't I see any actual updates in pane sessions?" Every pane running an agent shows that agent's live status, whatever the age of its shell. | owner, 2026-10-15 | required |
| U2 | Authenticate agent calls by their intent. Status needs only the pane's identity: hook status, activity, the agent's title and the Agent Line. Identity (binding a pane to an agent session), messages (notices, asks, withdraw) and reads (the agent reading its pane or its answers) keep the pane token. Control calls are unchanged. "we don't need to protect status, activity time; the binding … can have token; we should take into account the type of call and the intent." Decision confirmed: "yes this make sense." | owner, 2026-10-15 | required |
| U3 | A rejected agent call "changes nothing and says why" (pane-context requirement N13). The owner can see which pane's agent is not connected and why, without reading logs. | N13 (owner, 2026-09-26), owner 2026-10-15 | required |
| U4 | A child `claude -p` or another non-main agent in a pane does not take over that pane's status; the pane keeps its main agent. | PR C (#447) accepted real-agent contract | required |
| U5 | No toasts or banners; use persistent indicators. | owner feedback | required |

## Boundary

- **Goal:** every pane running an agent shows its status and agent-written title and Agent Line, even when its token is stale. When the agent can't get identity, messages or reads, the pane says so and why.
- **Reuse:**
  - the Sessions status derivation (`Working`, `Idle · done`, `Needs you`) and its main-agent rule;
  - the pane activity clock;
  - Agent Title and Agent Line storage and their writer-epoch ordering;
  - the existing status copy on rows;
  - the IPC method catalog and its per-call authorization.
- **Allowed to change:**
  - how the hook and the CLI deliver status when login is refused;
  - server admission for status calls;
  - Sessions status for a pane with no verified binding;
  - where a refusal reason is kept and shown;
  - the hook's diagnostic detail.
- **Protected:**
  - binding, conversation and resume semantics;
  - authentication of messages, reads and control;
  - the credential lifecycle;
  - the same-user socket check;
  - provider hooks never blocking or failing a turn.
- **Not in this change:**
  - refreshing the token inside a live shell;
  - credential persistence (fixed in 0.0.109);
  - binding stale-token panes;
  - session restore (R1–R3, parked);
  - the telemetry field filter (its own lane).
- **Acceptable complexity:** one status-only admission route, one pane-keyed status for panes with no binding, and one refusal record per pane shown through the existing status line. No new subsystem, persistence or toast.
- **Acceptable evidence:**
  - unit and integration tests at the admission, Sessions and row boundaries;
  - a real debug app with a real Claude Code and Codex: one pane with a valid token, and one isolated fixture pane whose shell holds a token the app demonstrably does not recognize, shown by a rejected-login receipt. Issuing a second credential is not enough, because registration is additive and the old token keeps working;
  - the reason for the 7 unexplained panes, reproduced or named.
