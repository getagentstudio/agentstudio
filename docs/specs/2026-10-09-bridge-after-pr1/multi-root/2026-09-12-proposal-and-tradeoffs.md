# Bridge Navigation — Proposal and Tradeoffs

The selected direction separates **opened documents, browsing worktrees, and Git
Review** inside one stable receiving Bridge collection. Terminal IPC targets that
terminal's associated Bridge; drawer callers use their owner pane's Bridge. Files exposes every member worktree tree together
with individually opened documents outside those roots; Review remains one
member worktree and comparison at a time. Commands manage known membership without moving the terminal. Agent addition
and human/debug removal retain their separate authority classifications.

This document records the product tradeoffs behind that selection. The
[Requirements](./2026-09-12-requirements.md) own the user needs and decisions;
the [Specification](./2026-09-12-bridge-navigation.md) owns observable behavior.
Internal realization is deliberately left to Program Design.

Requirements S18–S35, including the no-known-CWD/standalone settlement,
supersede the earlier Git-only Files scope, undecided terminal receiver, and
single-tree recommendation. The remaining alternatives concern future control
presentation; they do not reopen the collection behavior.
Drawer choices remain in their dedicated Specification, including preserving
drawers owned by Bridge tabs.

## What the app already provides

These are observations of checkout `improvements-viewing` at `85ae48f5e`, checked
on 2026-09-12. They are source evidence, not a demonstration of the installed app.

| Evidence | Current behavior | Source |
| --- | --- | --- |
| E1 | Command-P opens Quick Find. Its scopes cover app entities, commands, panes, and repos; there is no file-entry scope. | [Shortcut](../../../Sources/AgentStudio/Core/Actions/Commands/AppShortcut.swift), [scopes](../../../Sources/AgentStudio/Core/Models/CommandBarScope.swift), [root rows](../../../Sources/AgentStudio/Features/CommandBar/CommandBarDataSource.swift) |
| E2 | Worktree actions offer Files/Review, reuse of an eligible Bridge for that worktree, and explicit new-tab variants. Independent Bridge creation captures that worktree root. | [Worktree actions](../../../Sources/AgentStudio/Features/CommandBar/CommandBarDataSource+WorktreeRows.swift), [opening](../../../Sources/AgentStudio/App/Coordination/WorkspaceSurfaceCoordinator+BridgeReviewOpening.swift), [reuse](../../../Sources/AgentStudio/Core/Actions/BridgePaneCommandResolver.swift) |
| E3 | Production IPC has `bridge.fileView.open`, `bridge.diff.load`, tree search/reveal/filter, and Review selection/scroll controls. Open accepts an optional worktree ID; reveal uses a pane handle and exact worktree-relative path. | [Contracts](../../../Sources/AgentStudioProgrammaticControl/IPCBridgeContracts.swift), [adapter](../../../Sources/AgentStudio/App/IPCComposition/AgentStudioIPCBridgeAdapter.swift), [production routing](../../../Sources/AgentStudioAppIPC/AgentStudioAppIPCServer+AuthenticatedRouting.swift) |
| E4 | The full-screen terminal companion follows the terminal's registered worktree association. Moving between worktrees replaces its Bridge context. Independent tabs capture a root instead. | [Companion](../../../Sources/AgentStudio/App/Coordination/WorkspaceSurfaceCoordinator+ZoomCompanion.swift), [CWD routing](../../../Sources/AgentStudio/App/Coordination/WorkspaceSurfaceCoordinator.swift), [root precedence](../../../Sources/AgentStudio/Features/Bridge/Runtime/ReviewFoundation/BridgeReviewSourceProviderFactory.swift) |
| E5 | Annotation catalogs are worktree-scoped. Root changes therefore affect which annotations are relevant, not just a title or path. | [Catalog queries](../../../Sources/AgentStudio/Features/Bridge/State/SQLite/WorktreeAnnotations/WorktreeAnnotationSQLiteRepository+CatalogLoading.swift), [Bridge annotation context](../../../Sources/AgentStudio/Features/Bridge/Runtime/BridgePaneController+Bootstrap.swift) |
| E6 | File reveal requires the active surface's known file row. The open response does not prove that row is available or rendered. IPC targets workspace panes, which excludes the transient companion's separate identity. | [Reveal listener](../../../BridgeWeb/src/file-viewer/use-bridge-file-viewer-control-event-listeners.ts), [control result](../../../Sources/AgentStudio/Features/Bridge/Runtime/BridgePaneController+IPCProjection.swift), [pane inventory](../../../Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceStore+ProgrammaticControlSnapshot.swift) |
| E7 | Bridge search already has Command-Shift-F while the viewer receives keyboard input. | [Shortcut definition](../../../BridgeWeb/src/app/bridge-viewer-local-shortcuts.ts), [active listener](../../../BridgeWeb/src/app/use-bridge-viewer-toolbar-shortcuts.ts) |
| E8 | Normal opening requires a registered repo/worktree. File source admission checks repo ID, worktree ID, and root identity. | [Opening context](../../../Sources/AgentStudio/App/Coordination/WorkspaceSurfaceCoordinator+BridgeReviewOpening.swift), [File admission](../../../Sources/AgentStudio/Features/Bridge/Runtime/WorktreeFileSurface/BridgeWorktreeFileSourceProvider.swift) |

An agent running a command against B does not necessarily produce a terminal CWD
change to B. The terminal's reported location is therefore a useful default,
not evidence that every file the agent touches belongs to that location.

## The pathway to make coherent

```text
Agent prepares an exact path → terminal's stable Bridge inventory
Human searches all member trees + loose files, or activates that path
                           ↓
                  same Bridge displays Files
                           ↓
           read / annotate / copy feedback / continue
                           │ explicit Review request
                           ▼
              one member worktree + comparison
```

The application owns the observable result of this journey. A caller should not
have to mistake “created a tab” for “the intended file is visible.” This does not
require a particular number of protocol calls; one high-level operation and a
documented multi-step operation are still implementation/API alternatives.

## D1 — Selected collection versus the historical single-root option

The receiving Bridge and collection behavior are settled: terminal A's request
uses A's associated Bridge, including when opening worktree B or
`/tmp/notes.md`. The design selects one collection whose Files surface exposes
all member worktree trees and individually opened files outside those roots.

| Model | Experience | Gain | Cost and foreclosed behavior |
| --- | --- | --- | --- |
| Selected: stable multi-root collection | Files shows every member tree together and defaults filename/path search across the collection. Individually opened files whose resolved locations are outside member roots remain separately available. Review independently selects one member and its retained comparison. | A task spanning repositories behaves as one coherent reading workspace. Search and browsing do not require switching a root first, while Review keeps an unambiguous Git source. | Native and web source lifecycle, row identity, search, restoration and partial loading must work across simultaneous roots. Membership removal needs explicit selection and annotation behavior. |
| Historical: one selected root at a time | Files shows one worktree tree plus a list of opened documents, and changing roots also supplies Review context. | Reuses more of the current single-source tree shape and has fewer simultaneous sources to coordinate. | Hides the other member trees, makes collection-wide browsing/search indirect, and couples choices that the selected model keeps independent. It no longer satisfies S31–S34. |

Membership and file identity are resolved separately. Opening a file does not
add a browsing root, and a file inside a member root is not a miscellaneous file
because of how it was opened. Changing a Files selection or Review selection
does not change the other. Ordinary file annotations do not become a Git
comparison and are not transferred automatically.

The terminal's current known CWD worktree is automatically included once, and
is protected from removal. When the known CWD changes, the new worktree is added
if needed and becomes protected; the previous member stays listed and becomes
removable. Files and Review selections do not change as a side effect.

With no known CWD, the collection and selections remain but no member is
protected. A standalone Bridge likewise has no protected member. Either can
remove its last root explicitly. With no roots remaining, Files contains only
eligible individually opened files, or is empty; Review has no available member.

Removing an unprotected member removes its tree and clears a displayed file from
that root. Files from the removed root do not reappear as miscellaneous entries,
while their saved annotations remain. If Review selected the removed member, it
moves to the next remaining member in collection order, wrapping when needed,
and restores that member's retained comparison. Explicit unregistration from
Agent Studio propagates this same removal rule to affected Bridges; temporary
unavailability alone does not.

## D2 — Future Command-P and picker presentation

The selected outcome does not freeze a new picker, token, or keyboard binding.
This command-first slice includes collection-wide filename/path search in the mounted Bridge worker and typed
selection inputs; new Command-P and collection-management UI remain deferred.
The alternatives below therefore describe later UX choices rather than a choice
required by the current design.

| Alternative | Gain | Cost and foreclosed behavior |
| --- | --- | --- |
| A. Preserve Quick Find; add an explicit Files mode/token | Existing Command-P behavior remains predictable. An explicit file scope can show its repo/worktree and be invoked by a named command. | Entering Files takes another action unless a dedicated binding is selected. A token alone will not make the mode discoverable. |
| B. Command-P defaults to Files when Bridge has focus | Fastest familiar file opening while reading. Global Quick Find remains reachable through another explicit action. | The same chord changes meaning by focus. Opening from a terminal versus Bridge yields different result sets. |
| C. Mix file entries into today's global results | One search field with no mode switch. | Ranking, performance, duplicate filenames, and repo scope become less obvious; results must expose their worktree context. |

For A, `@ ` is an illustrative proposed Files token, not an assigned binding.
The existing `> `, `$ `, and `# ` scopes remain distinct. A visible Files entry is
part of the proposal; knowing the token is not a prerequisite.

Any later UI must preserve the collection-wide default and may offer explicit
narrowing to opened documents or one member worktree. A terminal's resolved CWD
may explain or prefill context, but it must not silently replace the collection
scope or displayed selection. The exact token, picker geometry and any dedicated
keyboard chord remain deferred decisions.

## D3 — Known worktrees only

The owner narrowed this PR to already-known worktrees (Requirements S23).
Adding a worktree references the existing app catalog; it does not discover,
adopt, register or create a repository/worktree. Shared-collection and
other-Bridge mutation are excluded (S24).

An exact file can still be opened from any accessible local directory, including
inside an unknown Git repository. It is read as a local document without adding
that repository to Agent Studio. Its Git Review is unavailable until the
worktree is known through an existing, separate app workflow.

Opening a file records the document; adding a known worktree changes browsing
membership. These are separate commands and effects.

## D4 — Agent prepares; human activation is separate

**Superseded 2026-09-23 (Requirements S38–S41).** An agent-opened file is now
shown when the terminal's Bridge is visible and no draft is open; otherwise it
loads silently with an Open view item in a native bottom-bar popover the human
opens. The text below records the earlier decision.

The owner selected preparation-only for this version (Requirements S25).
An agent’s file.open retains the file in its associated Bridge without entering
fullscreen, stealing focus or replacing the document currently being read.
The receipt says prepared, not shown. Later human activation displays the file.

This trades immediate presentation for uninterrupted work. The owner explicitly
places notifications, popovers and approvals with the later Sessions-screen
redesign (S26). This PR adds no notification/session plumbing for file opening.

Preparation does not navigate away from an active annotation draft. The draft
policy for subsequent deliberate human navigation remains a separate detail of
annotation continuity; no automatic transfer to another file is implied.

## D5 — Command-first scope and deferred controls

The required outcomes cover **destination resolution, associated-Bridge
preparation, explicit activation, independent Files/Review selection,
collection-wide file search, local files outside Git, saved opened-file
locations/annotations, explicit worktree membership, and inspectable outcomes**.
They make the current pieces into a complete command-driven journey without
selecting new controls.

The broader alternative adds a complete navigation inventory: next/previous
file, search/filter control, comparison-target selection, and existing display
options on both human and programmatic surfaces. That better addresses “all the
different things in bridge mode,” but substantially increases the contract and
proof surface. The [control inventory](./2026-09-12-bridge-navigation.md#r7--use-one-command-contract-and-inspectable-outcomes)
separates what exists from what is proposed and what remains undecided.

The selected boundary delivers the complete entry-and-navigation journey through
typed commands and authorized debug activation. The broader control inventory
remains later UX work. That deferral does not drop U-BN-06 or reduce the required
multi-root Files outcome. Annotation reading/jumping and annotation mutation
remain separate automation permissions rather than an implied shared decision.

## Settled model and remaining presentation tradeoffs

The owner has selected a stable terminal-associated Bridge collection, local file
reading/annotations outside Git, saved opened-file locations, collection-wide
search, all member trees in Files, and command/IPC management of known worktree
membership. Review remains Git-scoped and independently selects one member and
comparison. Shared collections and mutation of another Bridge are excluded.

Known CWD changes add and protect the new member without duplicates, leave the
previous member removable, and preserve Files and Review selections. No known
CWD, including for a standalone receiver, means no protected member; the
collection persists until explicit removal. Removal behavior, empty-root Files
and Review outcomes, and annotation preservation are selected as described in
D1. These are requirements rather than alternatives to vote on again.

D2 retains later Command-P and picker choices. D4 records preparation-only with
explicit human or authorized debug activation. D3 records the known-worktree
boundary. D5 records the command-first delivery boundary. Closed-file history,
moved-file reconnection, and broader navigation controls remain deferred without
changing which Bridge receives terminal IPC or whether ordinary local files are
eligible.

The Specification requires unfinished-draft preservation and duplicate-safe
preparation. Exact public command/IPC spelling must align with the IPC v2 owner. Native drag
and applicable marker-scoped performance evidence remain required; a new
owner-negotiated latency SLA is not a prerequisite. Qualitative implementation
costs above are source-grounded comparisons, not measured estimates or a
completed feasibility design.
