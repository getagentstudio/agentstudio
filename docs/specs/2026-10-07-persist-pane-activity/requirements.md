# Requirements: pane activity survives an app restart

Owner decision, 2026-10-06 (question tool, after the sitrep): "Persist last activity (Recommended)". Save each pane's last activity time and source with a coalesced write, so the sidebar's recency grouping survives restarts.

| Id | Need |
|---|---|
| U1 | After the app restarts, every pane that existed before shows the same activity recency it had: its age chip ("4h"), its group ("Active", "Today", "Last 7 days"…), and its order. Panes must not fall into "No activity" just because the app restarted. |
| U2 | The activity source (agent hook or terminal output) is kept, so the row means the same thing after a restart. |
| U3 | Activity lives exactly as long as the pane can come back. A pane closed but still restorable with Undo keeps its activity, and gets it back after Undo, even across a restart. A permanently gone pane leaves nothing behind. |
| U4 | Saving never slows an agent or blocks the main thread. Database work happens off the MainActor, and hooks and terminal input never wait for a save. Saving is best-effort: if it fails, or the app quits before a save lands, activity behaves as it does today (in memory). |

Out of scope: session status (already persisted by Sessions), terminal-only activity detection, any change to how activity is produced.

Why it matters: activity time lives only in memory today (`PaneActivityTimeAtom` is "runtime-only"). After every restart the sidebar's "Last hour" grouping is empty until each agent's next hook. Observed in the debug app 2026-10-06: panes from before a relaunch sit in "No activity" with a "—" clock while their status line still says "Idle · done".
