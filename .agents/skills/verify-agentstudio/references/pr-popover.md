# J12 — PR popover (draft)

Oracle: `docs/specs/2026-11-09-agent-pr-links/specification.md` R8–R15 and
`verification-design.md` U2, U3, U5, U6 and Fixtures. This route has not been
driven on the feature build; a draft is not a product observation.

## Setup and safe control

Use J1's owned, declared debug instance and J11's pane and PR fixtures. Retain
actual pane handles, independent PR identities and author contributions. Confirm
`gh` access and the fixture PRs' current state; inaccessible details are UNKNOWN
for real-fetch proof. Include an intentionally nonexistent PR and identify it
separately from real rows. Keep the same state for the J4 PR button check.

Drive the app with Computer Use. Before any key, require
`lsappinfo info -only bundleid "$(lsappinfo front)"` to match the declared debug
bundle. Bring only that bundle forward with `open -b <debug bundle id>`. Establish
identity with that frontmost gate plus an accessibility value matched in a
screenshot on a non-terminal control; terminal text is never identity. A locked
screen, installed app frontmost or uncertain target stops the drive. The lock
check treats absent `CGSSessionScreenIsLocked` as unlocked. Do not ask the owner
to operate the app. Use Computer Use screenshots and accessibility, not
`pane-chrome.sh` inventory/capture, Peekaboo or screencapture.

## Observe

1. Record the prior focused accessibility element, selected pane/tab and drawer,
   and the PR button's enabled state, count and colour. Click the actual button.
   The popover must open immediately, including while details load. Save original
   screenshots and the accessibility observations of its actual rows.
2. Compare rows independently with R11 and the fixture: worktree first and
   labelled, then newest added; one row for the worktree PR even if explicitly
   added; other-repository name, number/title, state, checks, review, blocker
   when present, authors and time. Compare `pr list` for the same pane. A
   worktree-only row has no remove; removing contributions from a mixed row
   retains its worktree source. Change association and check the label moves.
3. Observe real details arrive and the nonexistent PR report unavailable/not
   found without blocking other rows. If authorization or network prevents
   this, retain the failure and mark the affected real-fetch cell UNKNOWN.
4. Click a row's open action and independently read the default browser's
   front-tab URL through accessibility; compare it to that row's PR. Restore
   the debug app and re-establish its identity before further input.
5. With focus in the popover, use arrows to select a known added row and Return
   to open it; verify the browser URL. Reopen, select a known added row and use
   Command-Delete; `pr list` must show all its contributions removed. Exercise
   the visible remove control too, including a mixed worktree row. Escape must
   close the popover and restore the recorded prior focused element. Check the
   frontmost gate before every key, including each arrow.
6. Compare A and B's pre/post add/remove focus, selected pane/tab, drawer state
   and notice counts from `pane.context.get`; none may change. Compare real
   frames with the owner's approved design when available; until approval the
   taste verdict is UNKNOWN even if content and interaction pass.

## Driver gap and evidence

No validated J12 script exists yet. The declared build must establish usable
Computer Use accessibility, screenshot, browser URL and focus readbacks before
the route is considered operable. Keep originals, target identity, actual
selection, URLs, list and notice readbacks, and per-case PASS/FAIL/UNKNOWN in
the granted run directory. A screenshot of the main window without the actual
popover does not prove its contents.
