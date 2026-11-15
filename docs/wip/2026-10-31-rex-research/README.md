# Rex research: UI and agent location

Two research tracks, preserved together so they can be found and continued:

| Report | Questions it answers |
| --- | --- |
| [UI and pane improvements](ui-and-panes.html) | Popover opening, pane movement, sidebar collapse, resizing, and what the checked Rex videos and binary reveal about composition and rendering. |
| [Agent identity and location](agent-location.html) | Where execution happens, which terminal client is in a pane, which conversation it displays, and how launchers, plugins, metadata and protocol observations can supply evidence. |

Open the HTML files locally in a browser. Their Pages menu links the two reports;
the shared Demistify theme and runtime require network access. GitHub displays
HTML source rather than running the reports.

These are **dated research snapshots and experiment candidates**, not an
approved architecture, implemented improvement, or current-main performance
verdict. The reports identify their inspected source versions and distinguish
observations, supplied measurements, proposals and unverified behavior.

## Preserved evidence

- [Source register and proof limits](sources.md), including the original public
  videos and the credited frame excerpts stored in `assets/`.
- [Rex static binary inspection](evidence/rex-binary-inspection.md), with the
  inspected build hash, relative metadata records and instruction anchors.
- [Earlier launch/registration proposal](evidence/launch-identity-proposal.html),
  retained as historical design discussion.
- [Hook and pane prior art](evidence/hooks-prior-art.md), with pinned Herdr
  source references and the limits of inherited launch context.

The identity report includes an executed upstream plugin experiment:
**26 tests passed, 0 failed, 49 assertions**. It runs the actual ccmux plugin
against a fake OpenCode context and temporary marker files. It does not prove
stock Claude/Codex selection tracking or AgentStudio integration. Native-client
selection and app performance experiments remain separately identified as
unexecuted.

The reports were preserved from the October 2026 investigation. Historical
source links use immutable commits, so moving or removing a local worktree
does not break those references.
