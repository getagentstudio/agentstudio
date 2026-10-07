# Session restore after a reboot: what must be true

Date: 2026-09-30, revision 10 (owner, 2026-09-30, option A: every warm or unverified reconnect carries the restore script, so a lost session shows SR3's notice; the "couldn't be checked" notice is dropped). Revision 9 (R3 review round 3, N1 and N3: SR11c now says looks are taken when something could have changed the foreground, as the owner directed, instead of "every minute"; output arms a look when it starts, not only after it goes quiet; an exit prompts a fresh look and is never recorded as "a shell" by itself; a refused exit watch has its own row). Revision 8 (the F3 residual: unordered evidence has a durable "cutoff not yet known" state and a conservative fence). Revision 7 (R3 review round 2 residuals:
- the stale window is stated in full;
- unordered evidence recovers only from a later recording;
- the late-end limitation is stated).

Revision 6 (R3 review round 1, F1–F7:
- a binding ended only by the launch sweep stays eligible;
- failure rows are conditional on the recorded evidence;
- intake order is by durable recording, with an honest fallback;
- a report's provenance is decided by when it was recorded, not by which path delivered it;
- every cold pane waits for intake;
- a resumed start is a new occurrence).

Revision 5 (R3 written: the owner's 2026-09-29/30 settlements; SR11–SR12 replaced; E5 refined; E8–E10 added). Revision 4.1 (round 3: SR7 no longer assumes a dirty signal). Revision 4 (design review round 2: R2-2 session identity, R2-8 best-effort snapshots and achievable file outcomes, the capture's output source; the owner's F6 decision carried in. The resume rules SR11–SR12 wait for the owner's auto-resume policy decision). Revision 3 (design review round 1: F2, F3, F5, F9). Revision 2 (Panes review, seq 2943: restore phase, identity, resume safety, one retirement route, privacy). Serves [the Requirements](2026-09-28-session-restore-requirements.md) (RS1–RS10).

## Things

| Id | Thing | Same when | Always true | States |
| --- | --- | --- | --- | --- |
| E1 | Terminal pane | same pane id | has a stored zmx session id and a saved folder | — |
| E2 | zmx session | same session id | belongs to one E1 | alive (its daemon answers), dead (proven absent or refused), or unknown (the check timed out, failed or was incomplete) |
| E3 | Scrollback snapshot | one per E1 | the pane's terminal contents from its last **accepted** capture. A capture is accepted when it is non-empty and finished within its deadline. That's best effort: a capture cut short inside zmx can still be accepted (owner, 2026-09-29, F6). Bounded size | absent, current, replaced |
| E4 | Restore kind | one per pane per launch | decided before attach, and rechecked at attach | warm (E2 alive), cold (E2 dead), unverified (E2 unknown) |
| E5 | Agent binding | as Sessions defines it | the pane's latest agent session: provider, the provider's own session id, and how it ended. Only the provider's session start and session end reports (E9) change it. A launch sweep ends it for bookkeeping but never erases that no end was **reported** | active; ended by a reported end (the provider's reason is kept, or "not given"); ended only by a launch sweep (no end was reported, possibly across several launches); none |
| E6 | Resume command | one per cold-restored E1 | built only from E5's provider and exact session id, and only for a **likely interrupted** E10 | present or absent |
| E7 | Restore phase | one per cold-restored E1 | runs from the cold start until its end; everything the pane prints during it is restore output, not pane activity | active, ended |
| E8 | Foreground look | the latest one per E1 | which program held the pane's terminal foreground when the app last looked, which E2 incarnation it looked at, which E5 binding was current then, and where it falls in the app's own order of looks (never a clock) | shell, Claude Code, Codex, other, unknown |
| E9 | Lifecycle report | same report id (one per hook run) | a session start or session end that an agent in a pane reported. The CLI records every one before delivering it. The app takes each in at most once, in the order they were recorded. A report recorded **before** this app launch was listening is **historical** (it happened while the app was closed or starting), whichever path delivered it. One recorded after is **live** | waiting, taken in, refused |
| E10 | Resume verdict | one per cold-restored E1 per launch | decided from E5 (after every E9 is taken in) and the E8 taken **before** the pane's session was restored | known exited, likely interrupted, unknown |

## Rules

### R1: detect and restore (PR R1)

| Rule | What must be true | Needs |
| --- | --- | --- |
| SR1 | Before attaching a terminal pane at launch, the app decides E4. It never lets `zmx attach` silently recreate a dead session as if nothing happened. | RS1 |
| SR2 | Warm: attach exactly as today. The scrollback, programs and pane token are those of the live session; nothing restarts. A session is treated as dead only on proof (absent from a complete, successful inventory, or refused). A timeout or an incomplete inventory is **unknown**, never dead. | RS1 |
| SR2a | Warm and unverified panes (E2 alive or unknown) reconnect with SR3's restore script as zmx's startup command (owner, 2026-09-30, option A). zmx runs a startup command only when it has to create the session. So:
- a live session reconnects exactly as today and **nothing is printed**, because nothing was lost;
- a session that's gone when zmx checks during the reconnect (it died after the app's check, or the app's check couldn't tell) is recreated by that script, and the pane shows SR3's "Restored after restart" notice (and, with R2, its snapshot) instead of a silent empty shell;
- a session that dies in the brief moment after zmx's own check but before zmx connects (`attach` checks, then connects separately) fails that attach with zmx's "cannot connect" error, and the pane shows the ordinary exited view. It's visible, not silent, and there's no retry.

There's no separate "couldn't be checked" notice. Such a pane is **never auto-resumed**: no verdict is computed for a pane the app expected to be alive, so this is a missed resume, never a wrong one. A recreation detected after the attach (by the session's process identity, not a clock) is recorded in telemetry. | RS1, RS9 |
| SR3 | Cold: start the pane's session with a fresh login shell in the saved folder. If that folder no longer exists, use the repository's main folder; if neither exists, use the home folder. Every cold restore shows a one-line notice: "Restored after restart", plus the reason for any fallback folder. The new shell gets a fresh pane token, as any new shell does. | RS2, RS9 |
| SR4 | The decision and each cold start run off the main thread and never delay the first window. With many cold panes, starts are staggered: they begin one at a time in the existing activation order (visible first). A start doesn't wait for the previous pane's shell to be ready. Its cost is measured with 20 cold panes (Proof), and a limit on shells initializing at once is added only if that measurement shows a problem. | RS8 |
| SR5 | A cold restore that can't start its shell shows the reason in the pane. There's no retry loop and no silent ephemeral shell. | RS9 |
| SR6 | Drawer panes follow SR1–SR5 under their owner pane. | RS10 |
| SR6a | A cold restore keeps the pane's id. Only its zmx session process and pane token are new. Pins, notes, drawer→owner links and every Panes and Sessions record keyed by the pane stay attached. | RS1 |
| SR6b | Everything a cold-restored pane prints during its restore phase (E7) is **not pane activity**: the replay, the marker, the fresh prompt, and a resumed agent's startup output. The phase ends at the pane's **first person input**; for a pane that auto-resumes an agent (R3), it ends instead at the resumed agent's session-start fact if that comes first. The end is published as one typed fact per pane, `restorePhaseEnded(pane)`, which Panes' activity source binds to as its baseline. There's no timer. | RS1, RS8 |

### R2: scrollback (PR R2)

| Rule | What must be true | Needs |
| --- | --- | --- |
| SR7 | While the app runs, each live terminal pane's scrollback is refreshed about every 5 minutes whenever its output has changed, and once on normal quit. This includes in-place redraws (full-screen programs), panes that are restoring, hidden or unattended, and live sessions with no visible surface. It doesn't depend on pane activity (SR6b). Capture runs off the main thread. It writes only when the captured contents differ from the stored snapshot, and it's bounded in the bytes it holds and in how many panes it captures at once. | RS4 |
| SR8 | A snapshot replaces the previous one only when its capture is accepted (E3). An empty or timed-out capture keeps the previous snapshot. The stored bytes are exactly what the terminal produced, trimmed only by the size cap. | RS3, RS9 |
| SR9 | Snapshots are owner-only files in the app's data folder, capped at 2 MiB per pane, including any reset and marker bytes (the newest output is kept; a single line longer than the cap is cut at a safe character and escape-sequence boundary, with a marker). They're deleted only when the pane is permanently retired, through the existing route that undo expiry and every direct discard already use. After a pane is retired, no capture that was already running may write its snapshot back. Snapshot content never reaches telemetry, OTLP or logs; only counts, sizes and durations do. | RS5 |
| SR10 | On a cold restore, a pane with a snapshot shows that snapshot first, followed by a visible "restored after restart" marker line, and then the fresh shell. The restored text becomes part of the new session's own scrollback, so it survives a later reboot too. A pane without a usable snapshot restores as in SR3, and its notice says "no saved output". That covers never captured, missing, unreadable or invalid alike: one honest notice, with no extra state kept just to tell them apart. A snapshot that fails validation is never replayed. | RS3, RS9 |

### R3: resume (PR R3)

| Rule | What must be true | Needs |
| --- | --- | --- |
| SR11 | On a cold restore, the pane automatically resumes its agent **only** when its verdict (E10) is **likely interrupted**. All of these hold:
- the latest binding (E5) has **no reported end**: it's active, or ended only by launch sweeps;
- it wasn't started from a historical report alone;
- the last foreground look (E8) from before the restore shows **that binding's provider**, taken while that binding was the pane's latest and against the session incarnation that then died;
- that session died with the machine (a different boot), or in the same boot with no end reported (SR12b);
- the id is in the provider's own session-id form.

"Likely" is literal. The evidence is the last look before the pane's session died. Anything after that look that no report records (a suspended agent, or an exit whose end the provider didn't report, as Codex sometimes doesn't) still reads as running, however long ago it happened, including while the app was closed. Such an agent is resumed once: idle at its prompt, with the notice. The pane runs that provider's resume for **that exact session id**, inside the user's login shell after it has initialized (so its PATH and setup apply). The command comes only from a closed set of providers (Claude Code, Codex), each with a fixed argument template. The id must be in the provider's own session-id form (a UUID), so it can never be read as an option (such as `--last`) or a session name. It's passed as one argument, never through shell interpolation, and never taken from configuration or a payload. The pane shows "Resumed <provider> session <short id> after restart". When the agent exits, the person is in a shell. | RS6 |
| SR11a | Only the agents' **session start and session end** reports change E5 for resume: `SessionStart` and `SessionEnd` from Claude Code and from Codex. A session end counts whatever its reason, and the reason is kept. The session start's own id is what binds, so `/clear` (end, then a start with a new id) moves the binding to the new id. No other hook (prompt, tool, permission, stop, subagent, interrupt, compact) affects resume. | RS6, RS7 |
| SR11b | The `agentstudio` CLI records every session start and session end report (E9) in its own store **before** delivering it. The app takes each in at most once, even if it arrived both live and from the store. Reports apply in the order they were **recorded** (not the order the provider made them). A report the app can't read or accept is refused with a reason, and never blocks later ones. The app takes in every report recorded before its listener became ready before it decides any cold pane's verdict. If the CLI can't record a report (its store is unavailable), the report may still reach the app live, but that pane's evidence is then **unordered**. It stays unordered until a report recorded **after the app's next successful read of the store** (the fence). Every report recorded before the fence (including any that were in fact made after the unordered one) is treated as possibly older: it never replaces the unordered report, which conservatively costs a recovery rather than risking a wrong resume. Until the fence is known, and while unordered, the pane isn't auto-resumed, including across an app restart. Only session start and end are ever recorded; activity hooks never are. | RS6, RS7 |
| SR11c | While the app runs, it looks at which program holds a pane's terminal foreground (E8) **when something could have changed it**, not on a timer: the pane's binding changes; its agent sends a message; the pane's terminal starts printing (the look comes shortly after the output goes quiet, and at least once a minute while the output continues); the watched agent process exits; the app relaunches; and once on normal quit. A pane with none of these gets no looks. When a look finds an agent, the app is told the moment that agent's process exits, whether or not the agent reported an end, and **takes a fresh look at once**. An exit alone is never recorded as "a shell": if the pane's session is gone or can't be verified, nothing new is recorded and the look from before the death stands. A foreground change that produces none of these signals (no output, no report, no exit) isn't seen until the next one; that gap is accepted. A trigger that arrives while a look is running always gets a look of its own afterwards. Looking runs off the main thread and doesn't delay input or drawing. A look taken while an older binding was current, or at an older session incarnation, never replaces a newer look. The verdict uses the look from **before** the pane's session was restored, never the new session's first look. Looks store only the program kind, never command text or arguments. | RS6, RS7 |
| SR12 | Otherwise the pane isn't resumed, and no "latest session in this folder" command is ever used. **Known exited** (the latest binding reported an end): a shell only. **Unknown** (anything else: no look, a look at another binding or session, a program that isn't the binding's provider, a malformed id, or reports the app couldn't take in before its readiness limit): a shell plus a one-line notice naming the provider and the session's short id, so the person can resume it themselves. | RS7, RS9 |
| SR12a | A stopped (Ctrl-Z) or background (`&`) agent isn't in the foreground, so it isn't resumed. It gets SR12's unknown notice with its id. *(Owner confirmed 2026-09-30.)* | RS7 |
| SR12b | A session that died **without** a reboot (a zmx crash, or `zmx kill`) is treated like a reboot for SR11 **only when no end was reported**. Losing the daemon hangs up its terminal, and Claude Code then usually reports an end (`other`), which counts as known exited (SR12). *(Owner confirmed 2026-09-30.)* | RS6 |
| SR13 | A resumed agent reports its new session start through the installed hooks, and the pane binds to it as for any agent start (a new run of the same session id). **Limitation:** when a session died without a reboot, its earlier run's end report can still be in flight and arrive after the resumed start. It then ends the resumed run's binding, so that pane isn't auto-resumed at a later restart: a missed resume, never a wrong one. *(Owner confirmed 2026-09-30.)* | RS6 |
| SR14 | A resume that fails (the session no longer exists, the CLI isn't found) leaves the pane in a shell with the reason shown. It isn't retried. | RS9 |

## When things go wrong

| Situation | Result |
| --- | --- |
| App restart, zmx alive | warm: as today |
| Reboot, no snapshot yet | cold: fresh shell in the saved folder, plus the "no saved output" notice |
| The liveness check times out | unverified: reconnect with the restore script. Nothing is printed if the session is alive; SR3's notice if it was lost. Never treated as dead |
| The session dies between check and attach | if it's gone when zmx checks, the restore script recreates it: SR3's notice (with R2, the snapshot), no silent empty shell, no auto-resume. If it dies after zmx's own check, the attach fails visibly (the ordinary exited view) |
| Saved folder deleted | cold: shell in the repository's main folder, plus a notice |
| Snapshot capture fails | the previous snapshot is kept |
| The agent was exited before the reboot | shell only; no resume |
| The agent was still running when the Mac restarted, and the app had looked at it | resumes that exact session, with the notice |
| While the app runs, the agent exits without reporting an end (a lost hook, a crash) and its session lives on | the exit prompts a fresh look at once, which sees what now holds the foreground (usually the shell): shell plus the unknown notice |
| The app can't watch an agent's exit (the kernel refuses the watch) | nothing is recorded from the failure; that pane is looked at again at least once a minute until a watch succeeds or the look no longer finds an agent |
| After the app's last look, the agent was suspended; or, while the app was closed, it exited without its end being recorded | resumed once (the evidence still says running): idle at its prompt, with the notice |
| The app was closed; the person quit the agent from another terminal; then a reboot | shell only: the CLI kept the end report |
| An agent started while the app was closed, then a reboot | shell plus the unknown notice with its id: the CLI kept its start, but the app never looked at it |
| An agent's end report is lost (Codex often misses one) | if a look ran after the exit, it saw the shell: shell plus the unknown notice; if the restart came first, as the row above |
| A crash or power loss right after an agent starts, before any look | shell plus the unknown notice with its id |
| A zmx crash or `zmx kill` ends a session without a reboot | Claude usually reports an end on hang-up: shell only; with no end reported: resumes like a reboot (SR12b). The agent's exit watch fires too, but its fresh look finds the session gone and records nothing, so the look from before the death stands |
| A stopped or background agent | if a look saw the shell after it was stopped: shell plus the unknown notice with its id (SR12a); if it was stopped after the last look: as the "after the app's last look" row |
| The CLI's store was unavailable when an agent started | that pane isn't auto-resumed while its evidence is unordered: shell plus the unknown notice |
| A zmx crash; the agent is resumed; the old run's end report arrives late | the resumed run is marked ended, so no auto-resume at a later restart (SR13 limitation) |
| Two agent panes in one folder | each resumes its own session id |
| Resume target gone | shell, plus the reason |
| 20 cold panes | starts begin one at a time, visible first; first window not delayed; warm panes activate normally |

## Proof

| Rules | Evidence |
| --- | --- |
| SR1–SR6 | Integration: kill a pane's zmx daemon (the reboot-equivalent), relaunch, and observe a cold restore (fresh shell in the folder, notice when the folder is missing); a live session stays warm with the same token; startup timing unchanged |
| SR7–SR10 | Integration against a real zmx session: capture, verify, replace, the size cap, a failed capture keeping the old snapshot, retirement deleting it, replay followed by the marker then the shell |
| SR11–SR14 | Integration against real zmx, with every row of "When things go wrong" that involves an agent as one case: the verdict, whether the provider is invoked, and with which exact UUID. Two panes in one folder → two ids. Stale looks (older binding, older incarnation, older launch) rejected; the pre-restore look used, never the new session's |
| SR11b | Integration with **several real CLI processes** writing one real store:
- a report delivered live and also drained applies once;
- a numbering gap, and a refused or unreadable row before a valid one, never block;
- the app commits but the CLI's acknowledgment is lost, and replay stays single;
- a live report that overtakes a waiting one: both apply in recorded order, with the same meaning (live, not historical);
- an unavailable store makes that pane unordered, and an older recorded report (held, then drained) never replaces the unordered one or clears the flag;
- an activity hook is never recorded |
| SR11c | On a controlled clock, fed by the real output-activity source: output that never goes quiet still gets a look within a minute; a trigger that arrives during a look gets its own look afterwards; a quiet pane gets none. An agent's exit with its session alive records what the fresh look sees; `zmx kill` on a watched agent with no end reported keeps the earlier look and resumes that exact id; an exit while another program takes the foreground records that program, never "shell". A refused watch records nothing and re-looks that pane. |
| SR11c (cost) | Measured: the looks' cost with 15–20 live panes, off the main thread (a marker-scoped trace, not feel) |
| Journey (each PR) | Debug app: panes with output and agents → kill zmx (reboot-equivalent) → reopen → observe per PR (fresh shell / scrollback / resumed exact session), by focus-free IPC or computer use |

## To verify in the Program Design

- `zmx history <id> --vt` exists in the vendored zmx (confirmed 2026-09-29). An incomplete result can't be detected. The owner accepted best effort (F6).
- The session identity used by SR2a: the repo's existing zmx identity vocabulary (`ZmxSessionControl`), not `created=` seconds.
- The exact resume syntax for Claude Code and Codex CLI with a session id (proven by the 2026-09-29 POC).
- How the CLI's store and the app's intake give "at most once, in order" (SR11b), and how that fits the store PR B designed.
- Which foreground looks run where, so SR11c costs nothing on the main thread.
