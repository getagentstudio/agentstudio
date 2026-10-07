# Session restore after a reboot: what it needs and why

Date: 2026-09-28; R3 settlements added 2026-09-30. Owner: workspace-control (Claude 6b0a29fc), designed with
Panes (1c8b74a0). This is Panes Stage 2 ("restart resilience"). The owner put
it ahead of PR B on 2026-09-28: "too many in-flight works, not tested and tied
together."

## The problem

Terminal panes run inside zmx sessions. An app restart is fine: the zmx
daemons keep running, and the app reattaches with scrollback and running
programs intact. A Mac reboot kills every zmx daemon. On the next launch the
app runs the same `zmx attach <id>`, and zmx silently **creates a new, empty
session under the same name** (`ZmxBackend.swift:182,207`: "zmx auto-creates
on first attach"). The pane looks restored, but:

- the scrollback is gone;
- the agent that was running (Claude Code, Codex) is gone, and nothing offers
  to bring it back;
- nothing says anything was lost.

## Who it's for

The person who runs many agent panes and reboots, or whose Mac restarts, and
wants each pane back the way it was.

## Settled by the owner

- **Stage 2, as approved:** "after a reboot, scrollback returns and each pane's
  command or agent resume is ready to run … The app may need to be open to
  capture scrollback at first; later a low-CPU daemon captures while it is
  closed." (Panes Stage 1 requirements, line 82.)
- **Resume the exact session, never "the latest in this folder"** (owner,
  2026-09-28): two panes in the same folder must each get their own session
  back.
- **Auto-resume on boot** (owner, 2026-09-28, "when we boot … it should
  automatically resume"), limited to sessions the reboot interrupted. A session
  the person exited isn't resumed.
- **Session restore first, the resume command after** (owner, 2026-09-28).
  Built as a stack of small, independently stable PRs.
- **zmx unchanged:** no fork and no zmx change (Panes Stage 1, "Protected").
- From 2026-09-26: never replace a running shell or its token; never block
  startup.

### Settled for R3 (auto-resume), 2026-09-29 and 2026-09-30

- **Resume only what was likely interrupted.** The owner accepted A or B on
  2026-09-29 ("I don't mind A or B"). A is the recommendation: resume only
  agents whose evidence says they were still running when the pane's session
  died. Anything unknown gets a shell and the session's id, never a guess.
  "Likely" is literal. RS7 is met as far as the recorded evidence shows.
  While the app runs, an agent's exit is noticed the moment it happens (push)
  and prompts a fresh look; other looks are taken when something could have
  changed the pane's foreground: its binding changes, its agent sends a
  message, or its terminal prints (a look shortly after the output goes
  quiet, and at least once a minute while it keeps going), plus on relaunch
  and on quit (pull). There's no fleet-wide timer (owner, 2026-09-30: "last
  message + delay, and on quit"). So what can still be resumed once is an
  agent suspended after the last look without anything printing, or one that
  exits while the app is closed without its end being reported (Codex
  sometimes doesn't report one). It's then idle at its prompt, with the
  notice. Covering the app-closed case needs an always-on helper (agentd),
  later.
- **Record what agents report, even while the app is closed.** "That IPC CLI
  has its own [store] and hooks are fine" (2026-09-30). The `agentstudio` CLI's
  own SQLite store keeps the agents' lifecycle hooks while the app can't be
  reached, and the app takes them in when it starts.
- **Sweep at shutdown; a crash can't be known.** "We can have a table that
  checks this and sweeps it even at shutdown. Well, crashes we don't know"
  (2026-09-29). On a normal quit the app records one last look at what each
  pane is running. After a crash or power loss, the last look taken before it
  stands in.
- **Nothing on the main actor** for this evidence (2026-09-29): gathering,
  storing and deciding all happen off it.
- **Validated, not assumed** (2026-09-29, "this is too thin … validate"): zmx
  was tested in an isolated lab (it keeps nothing about a session after its
  daemon dies), and a shell-hook alternative was tested and rejected as the
  evidence source (advisor report, 2026-09-30).

## The needs

| # | Need | Why | Priority |
| --- | --- | --- | --- |
| RS1 | After a reboot, each terminal pane knows its session was lost and restores instead of silently starting empty. After an app-only restart, live sessions reattach exactly as today. | The silent loss is the bug. | Must |
| RS2 | A restored pane opens a fresh shell in the pane's saved folder. If that folder is gone, it uses the repository's main folder and says so. | The pane is usable at once. | Must |
| RS3 | A restored pane shows its scrollback from before the reboot, up to a bounded size. | "Scrollback returns" (Stage 2). | Must |
| RS4 | Scrollback is captured while the app runs, often enough that a sudden reboot loses at most a few minutes of output, without noticeable CPU or disk cost and off the main thread. | A crash or forced reboot gives no warning. | Must |
| RS5 | Captured scrollback is stored privately (owner-only files in the app's data folder), bounded in size, and deleted when its pane is permanently gone. | Terminal output can contain secrets. | Must |
| RS6 | A pane whose agent session was interrupted by the reboot resumes **that exact session** (by the provider's own session id) automatically after restore. When the agent exits, the person is left in a shell. | Owner: auto-resume; two panes in one folder must not collide. | Must |
| RS7 | A pane whose agent session had ended before the reboot, or whose session isn't known, is not resumed and no session is guessed. | "Resume the exact session or nothing." | Must |
| RS8 | Restore never blocks app startup or the first window. Many panes restore in a bounded, staggered way. | Startup stays fast with 15+ panes. | Must |
| RS9 | A failed restore (the snapshot is missing or bad, the resume fails, the agent CLI is missing) shows the reason in the pane. There's no retry loop and no silent fallback. | Honest failure. | Must |
| RS10 | Drawer panes restore by the same rules, under their owner pane. | Drawers are panes. | Must |

## Delivery (owner: stable stacked PRs)

| PR | Delivers | Needs |
| --- | --- | --- |
| R1 | Detect dead sessions at launch; cold-restore to a fresh shell in the saved folder, with a notice. Live sessions are unchanged. | RS1, RS2, RS8, RS9, RS10 |
| R2 | Scrollback capture while the app runs, plus replay on cold restore. | RS3, RS4, RS5 |
| R3 | Auto-resume the exact interrupted agent session. | RS6, RS7 |

## Not in this change

- A daemon capturing scrollback while the app is closed (Stage 2's "later").
- Restoring the last command of a non-agent pane (it isn't recorded today).
- Changing zmx (parked for Stage 3: zmx fork, agentd, remote hosts).
- Inbound agent delivery (parked by the owner).

## Confirmed by the owner, 2026-09-30

- RS7 is judged on the recorded evidence, with the window above (push plus
  pull while the app runs; the app-closed gap waits for agentd).
- A stopped (Ctrl-Z) or background agent isn't resumed; it gets a shell plus
  its id.
- A session lost without a reboot resumes only when no end was reported.
- A session lost without a reboot can lose a later auto-resume if its old run's
  end report arrives after the resume (Spec SR13): a missed resume, never a
  wrong one.

## Decided in the Specification

- Snapshot cadence: default every 5 minutes per active pane, plus on normal
  quit (proposed; the owner didn't object).
- The bounded scrollback size.
