# Swift clients, commands and native interaction: observable contracts

This is the DS10 slice of the [system Specification](../../2026-10-15-agentstudio-daemon.md). The separate [Requirements](../../user-requirements.md) authorize its meaning; the [domain definitions](../../domain-entities.md) and shared [operation interpretation](../../capability-contracts.md#shared-interpretation-of-an-operation) apply. Its [design brief](README.md) owns scope, inputs and unresolved work. Existing open gaps are preserved; this partition selects no new behavior.
The [initial profile](../../initial-profile.md) supplies the selected IP1–IP12 directions. Remaining gaps concern their exact contracts and realization; they do not reopen the selected high-level choices.


## K6 — Command catalog, targets and workspace interaction

**Consumer / entities / basis:** GUI/CLI/MCP caller; E4/E16/E25/E26; U4/U9/U13/U17/U22. The current [154-command catalog](../../research/evidence/2026-10-15-daemon-extraction-survey/command-surface-inventory.md) has independent exposure, channel, target, privilege, mode and eligibility axes. Command identity/display copy stay one catalog; transport methods do not become new `command.execute` verbs.

`window/workspace/pane` list/current/snapshot/focus/split/close, drawer operations, command listing/execution, sidebar and UI-open methods must retain kind-qualified targets. Current/focused is a client view observation. A split result currently identifies the targeted pane, not necessarily a newly created pane; command accepted-without-value does not prove a view/effect. Headless-tagged does not mean app-independent.

IP11/IP12/R17 require shared logical tabs/layout and read marks. E25/E26 are distinct from each actual E16 native projection: shared-state acceptance, physical native application and user viewing are different observations. Exact logical/native element mapping, authority/storage, concurrent/offline and close/Undo projection contracts remain G4/G8/G9/G12, not the question whether sharing is wanted.

Four worktree-create command identities, dormant Inbox and retired settings currently report unavailable. IP10 preserves selected external native automation without making every enum case a working/public capability. Exact subset and hard-cutover names remain G1/G8. Administrative Host capability is not generic remote UI authority.

**Proof:** actual supported client command entry, exact target/effect and independent refusal/channel/eligibility cases. Native display needs native evidence; declaring a spec or dispatching a callback is insufficient.

## K12 — Native effects and platform ingress

**Consumer / entities / basis:** Mac app user and supported device client; E2/E4/E16/E20; U4/U6/U11/U13. Client display, keyboard/mouse/accessibility, AppKit lifecycle, chooser, clipboard, editor/browser/Finder and local UI continuation are client-platform effects. Rust Host feature parity does not require a Linux Finder/clipboard acting on the Mac's behalf.

An operation must identify the actual effect machine and kind-qualified target. A Host path is not a local file URL. Opening an application/URL or accepting a chooser is not proof of document load, pixels or external editor success. Client termination notification is not proof that an execution ended. Credential OAuth callbacks/configuration remain separate from visible login command presence; current provider IDs/placeholders and token exchange/storage TODOs do not establish implemented sign-in.

Current [terminal clipboard callbacks](../../../../../Sources/AgentStudio/Features/Terminal/Ghostty/GhosttyCallbackRouter.swift:106) retain beta auto-approval for reads and writes. That is baseline behavior, not a selected remote-Host policy. Which Host-originated clipboard/link/editor/Finder effects are permitted, how their origin is shown, and what consent/refusal means remain G8/G9/G12. No policy change or authority grant is implied by transport extraction.

**Proof:** actual supported native surface, target and effect, with missing/unrepresentable remote path and unavailable application cases. Existing placeholder/unavailable features remain explicit until selected. Shared window/layout, phone UX, detached-session screen and accessibility changes are G4/G9; no current UI establishes those new experiences.
