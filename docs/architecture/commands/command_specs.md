# Command Specs

## TL;DR

The command system is the only place a user action gets an identity **and**
a display. One `AppCommand` is presented, shortcut, dispatched, and exposed
over IPC. Labels, icons, help, and dense tooltips are projections of
`AppCommandSpec` or `LocalActionSpec` — not strings or SF Symbols on the
control. That is how keyboard, menu, toolbar, command bar, tooltips, and
RPC stay one verb.

**When:** any new user-visible verb, keystroke, chrome control, command-bar
row, dense tooltip, or programmatic method. UI with no `AppCommand` still
uses `LocalActionSpec` / `ActionSpec` for the same display pipeline.

Load [Command Specs And Execution Owners](#command-specs-and-execution-owners)
then the [file table](#files-to-load). Code against
[Adding a new command — decision tree](#adding-a-new-command-decision-tree)
and
[Exhaustive interactive and IPC projections](#exhaustive-interactive-and-ipc-projections).
Display:
[Tooltips, help text, and compact control copy](#tooltips-help-text-and-compact-control-copy).

Inbox command identities are intentionally retained but retired. Their catalog
definitions are `.notPresented`, carry no shortcut, and the independent IPC
projection is unexposed. App shell and pane owners reject them without reading
or mutating Inbox state. Do not reconnect those identities to UI, shortcuts,
IPC, or runtime composition without a new product decision.

## Files to load

These source files own the system. Architecture claims should link here so
paths stay in sync with the tree. Each file has one job.

| File | Owns |
|------|------|
| [`AppCommand.swift`](../../../Sources/AgentStudio/Core/Actions/Commands/AppCommand.swift) | Command **identities**, `AppCommandSpec` shape (label, `CommandIcon`, `helpText`, surfaces, targeting), and dispatch protocol. |
| [`AppShortcut.swift`](../../../Sources/AgentStudio/Core/Actions/Commands/AppShortcut.swift) | Keyboard **bindings** and the contexts where they fire. |
| [`AppCommand+Catalog.swift`](../../../Sources/AgentStudio/Core/Actions/Commands/AppCommand+Catalog.swift) | Exhaustive interactive `AppCommandSpec` catalog — the only place to add command copy, icon, shortcut, surfaces, targeting, context requirements, and command-bar grouping. |
| [`CommandIcon.swift`](../../../Sources/AgentStudio/Core/Actions/CommandIcon.swift) | `CommandIcon` / `SystemSymbol` / octicon tokens used by specs. Do not invent SF Symbol names on controls. |
| [`AppCommandPresentationPolicy.swift`](../../../Sources/AgentStudio/Core/Actions/Commands/AppCommandPresentationPolicy.swift) | Typed interactive surfaces, targeting modes, presentation subjects, and the pure `shouldPresent` query. |
| [`AppCommandDispatcher.swift`](../../../Sources/AgentStudio/App/Commands/AppCommandDispatcher.swift) | The only execution entry. Hosts dispatch; they do not call owners directly. |
| [`WorkspaceFocusedPane.swift`](../../../Sources/AgentStudio/Core/State/MainActor/Atoms/WorkspaceFocusedPane.swift) | Immutable normalized focus identity and content. |
| [`WorkspaceFocusedPaneResolver.swift`](../../../Sources/AgentStudio/Core/State/MainActor/Atoms/WorkspaceFocusedPaneResolver.swift) | Pure requested-focus normalization against live workspace state. |
| [`CommandContext.swift`](../../../Sources/AgentStudio/Core/State/MainActor/Atoms/CommandContext.swift) | Immutable command-policy facts and requirements. |
| [`CommandContextDerived.swift`](../../../Sources/AgentStudio/Core/State/MainActor/Atoms/CommandContextDerived.swift) | Pure projection from focused-pane and workspace/presentation facts. |
| [`AppCommand+DisplayDescriptor.swift`](../../../Sources/AgentStudio/Core/Actions/Commands/AppCommand+DisplayDescriptor.swift) | Projection from `AppCommandSpec` into app-free display descriptors and tooltip render values. |
| [`AppCommand+IPCProjection.swift`](../../../Sources/AgentStudio/App/Commands/AppCommand+IPCProjection.swift) | Independent exhaustive `ipcSpec`: exposure, durable targets, privileges, arguments, plus public command-list DTO. |
| [`UIActionPresentation.swift`](../../../Sources/AgentStudio/Core/Actions/UIActionPresentation.swift) | `LocalActionSpec` / `ActionSpec` for UI with no `AppCommand` — labels, icons, help, compact tooltips. |
| [`ControlTooltipSource.swift`](../../../Sources/AgentStudio/Core/Actions/ControlTooltipSource.swift) | Tooltip source, provenance, copy style, and resolver. |
| [`ControlTooltipRenderValue.swift`](../../../Sources/AgentStudio/Infrastructure/ControlTooltipRenderValue.swift) | Render-only tooltip value that UI primitives and SharedComponents may consume. |

## Command Specs And Execution Owners

**Importance.** Without this catalog, every host invents its own verb. The
menu says one thing, the toolbar icon another, the shortcut a third, IPC a
fourth. Specs exist so adding a command is one identity plus two exhaustive
projections: interactive (`AppCommandSpec`) and IPC (`ipcSpec`). Display is
part of the spec, not a view concern.

**How to use it.** Add or reuse `AppCommand`, fill `AppCommandSpec` in the
catalog, classify `ipcSpec` in the same change, then bind a host. For UI
with no command identity, add or reuse `LocalActionSpec` and project
`actionSpec`. Never add a control, label, icon, tooltip, or RPC method that
the catalog cannot see.

**Display.** Hosts project; they do not copy:

```text
AppCommandSpec
  -> CommandDisplayDescriptor
  -> ControlTooltipSource
  -> ControlTooltipRenderValue
```

`AppCommandSpec.actionSpec` supplies label, `helpText`, and `CommandIcon`.
UI-only controls use `LocalActionSpec.actionSpec` into the same descriptor
shape. SharedComponents render resolved values only — they must not take
`AppCommandSpec`, `ActionSpec`, or `ControlTooltipSource`. Detail:
[Tooltips, help text, and compact control copy](#tooltips-help-text-and-compact-control-copy).

**Load.** [Files to load](#files-to-load) is the path table. Then:

- Layers and focus: [The four layers](#the-four-layers),
  [Focus, presentation, and execution](#focus-presentation-and-execution)
- Presence vs enablement: hosts ask `shouldPresent`; `canDispatch` plus
  validators are authority
- IPC: [Exhaustive interactive and IPC projections](#exhaustive-interactive-and-ipc-projections)
- Keyboard: [Keyboard Surface Contract](../hosting/appkit_swiftui_architecture.md#keyboard-surface-contract);
  display keys with `displayKeyBinding(in:)`
- Owners: [Choosing the execution owner](#choosing-the-execution-owner)
  (`AppDelegate` for app/window/sidebar shell; `PaneTabViewController` for
  pane, drawer, focus, layout, workspace)
- Add/change: [Adding a new command — decision tree](#adding-a-new-command-decision-tree)

Command-bar `>` `$` `#` rows consume this catalog; they are not how you
define a command. Host detail:
[Command Host Surfaces](../hosting/appkit_swiftui_architecture.md#command-host-surfaces).

## The four layers

```
                                     ┌──────────────────────┐
   user presses key                   │  AppShortcut         │
        │                            │  (key + context)     │
        ▼                            └──────────┬───────────┘
   ┌──────────────────────┐                    │ resolves to
   │  ShortcutDecoder     │                    ▼
   │  (event → trigger)   │            ┌──────────────────────┐
   └──────────┬───────────┘            │  AppCommand          │
              │                        │  (dispatchable id)   │
              └─── matches in context ─►└──────────┬───────────┘
                                                  │ executed by
                                                  ▼
                                       ┌──────────────────────┐
                                       │ AppCommandDispatcher │
                                       │ → handler            │
                                       └──────────────────────┘

   command bar / button asks:                ┌──────────────────────┐
        "what's this command's hint?"  ◄─────│ AppCommandSpec or    │
                                             │ LocalActionSpec      │
                                             └──────────────────────┘
```

`AppCommand` is the identity. `AppShortcut` decides which keystrokes
request it. `AppCommandSpec` declares interactive presentation, targeting, and
command-context requirements. Core projection extensions turn that display
metadata into app-free tooltip descriptors. App adds executable-only dispatch
and the independent exhaustive `AppCommand.ipcSpec` companion projection.
`LocalActionSpec` provides UI text for controls that are not
dispatcher-backed commands.

## Module Boundary

Command identity, shortcut vocabulary, metadata, and the dispatch protocol live
in `AgentStudioCore` with `package` visibility because Feature modules such as
CommandBar consume them. Concrete dispatch, AppKit key conversion, executable
handlers, and the IPC companion projection stay in the `AgentStudio` App
target.

This split lets Features depend on Core without importing App or a sibling
Feature. Do not move concrete App dispatchers into Core, create a Feature-owned
copy of the command vocabulary, or widen the command surface to `public` merely
to cross a package target boundary.

## Exhaustive interactive and IPC projections

`AppCommand` is the shared exhaustive identity, but interactive presentation
and IPC policy are independent projections:

```text
AppCommand
  ├─ exhaustive definition switch
  │   → AppCommandSpec
  │   → interactive copy, shortcut, surfaces, targeting, requirements
  └─ exhaustive ipcSpec switches
      → AppCommandIPCExposure
      → AppCommandIPCDurableTargetContract
      → AppCommandIPCArgumentContract + privilege classification
      → AppCommandExecutionArguments
```

The IPC projection represents durable targeting as
`.targetless` or `.required(primary:additional:)`, and arguments as
`.noArguments` or a typed argument/filter variant. Its command, exposure,
durable-target, privilege, and argument switches are exhaustive and have no
`default`; adding an `AppCommand` must classify both planes before the code
compiles.

`AgentStudioIPCCommandAdapter.listCommands()` enumerates
`AppCommand.allCases`, resolves the interactive definition for canonical public
copy, then projects the independent IPC contract into `IPCCommandListEntry`.
The internal unions project to the existing execution-mode, target-kind,
privilege, and argument-schema arrays only for the public DTO; its JSON shape
and encoding remain unchanged. Internal optionality and execution modes remain
discriminated unions.

## Focus, presentation, and execution

The authenticated transport methods `pane.pullRequest.add`,
`pane.pullRequest.remove`, and `pane.pullRequest.list` have no interactive
command identity. All three admit any main pane (`.anyTarget`), execute through
the pane-context service, and require `paneContextWrite` for add/remove or
`paneContextRead` for list. The app stamps the author from the caller's source
pane or stable credential identity; a request cannot supply an author. Their
CLI projection is `pr add|remove|list` with the shared drawer-browse target flags.

These are separate contracts:

```text
WorkspaceFocusOwnerAtom (sole mutable requested-focus owner)
  → WorkspaceFocusedPaneResolver
  → WorkspaceFocusedPane (normalized focus identity/content)
      ├─ status and focus presentation
      └─ CommandContextDerived + workspace/presentation facts
          → CommandContext + satisfied CommandRequirement values

AppCommandSpec + AppCommandPresentationQuery
  → shouldPresent(...) = presence only

AppCommandDispatcher.canDispatch(...) + execution validators
  → enablement and execution authority
```

`WorkspaceFocusedPaneResolver` validates requested main-pane, empty-drawer, and
drawer-child focus against the active tab and visible drawer state. Its
immutable result is the focus presentation value. `CommandContextDerived`
consumes that result and produces a separate immutable `CommandContext`;
neither type owns mutable state or consults AppKit responder objects.

Every command declares a required `AppCommandSurfacePolicy`:

- `.exposed(Set<AppCommandSurface>)` lists the interactive hosts that may
  present it.
- `.notPresented` identifies shortcut-only, IPC-only, generated-target-row, or
  internal commands with no independently presented control.

The surface vocabulary is `.commandBar`, `.mainMenu`, `.contextMenu`,
`.inlineControl`, and `.toolbar(...)`. Toolbar identity is intentionally
specific: `.toolbar(.app)`, `.toolbar(.pane)`, and
`.toolbar(.terminalZoom)` are different hosts. A normal pane toolbar must not
inherit terminal-Zoom Viewer exposure.

Hosts ask `AppCommandSpec.shouldPresent(...)` with an
`AppCommandPresentationQuery`. The subject is contextual, targeted by
`SearchItemType`, or both. The query checks surface exposure, then contextual
requirements and/or declared target-kind support. It contains no target UUID,
store, authorization, or mutable UI state.

`shouldPresent` controls presence only. Visible controls use the matching
contextual or targeted `canDispatch` overload for enabled state, and dispatch
repeats that preflight before the execution owner and its workspace/runtime
validators run. A visible command may therefore be disabled; a hidden command
does not gain or lose execution authority.

`AppCommandTargeting` declares invocation shape:

- `.contextual`
- `.targeted(nonEmptyTargetKinds)`
- `.contextualAndTargeted(nonEmptyTargetKinds, preferredInvocation:)`

The preferred invocation tells command-bar root rows whether to dispatch
contextually or drill into target selection. Dispatchers reject contextual
requests for targeted-only commands and targeted requests whose kind is not
declared before calling an execution owner.

Five contracts remain orthogonal: `shouldPresent` owns presentation,
`canDispatch` owns current capability, execution owners and validators own
effects, `ActiveKeyboardSurface`/`AppShortcutDispatchPolicy` own keyboard
routing, and `AppCommand.ipcSpec` plus the IPC adapter own programmatic
authority. UI exposure, satisfied command requirements, or interactive
targeting never grant IPC execution modes, durable handle kinds, privileges, or
arguments.

## Command planes

The command system has multiple planes. Use the narrowest plane that owns the
behavior:

```text
┌─ Command Plane Decision Map ────────────────────────────────────┐
│ AppCommand + AppCommandSpec                                      │
│   app command identity, shortcut metadata, command-bar rows      │
│                                                                  │
│ WorkspaceActionCommand                                           │
│   resolved workspace graph mutations: tabs, panes, drawers,      │
│   arrangements, worktrees, orphaned panes, repairs               │
│                                                                  │
│ PaneRuntimeCommand                                               │
│   one targeted pane runtime: terminal input/scroll/prompt jump,  │
│   browser navigation, diff/editor/runtime-specific operations    │
│                                                                  │
│ UI presentation                                                  │
│   command bar, picker, sheet, panel, prompt                      │
│                                                                  │
│ Runtime events                                                   │
│   facts after work happened; waits, subscriptions, replay        │
└──────────────────────────────────────────────────────────────────┘
```

Commands ask owners to do work. Runtime events report facts after work happened.
Do not route commands through EventBus, and do not make `command.execute`
silently present UI.

<a id="adding-a-new-command-decision-tree"></a>
## Adding a new command — decision tree

If the user can click it, type a shortcut for it, or find it in the command
bar, start here. Do not add a SwiftUI `Button`, AppKit menu/toolbar item, or
command-bar row that calls a coordinator, atom, or closure with a hardcoded
label. Toolbars resolve `AppCommand` through hosts such as
`PaneSurfaceToolbarHost`. Command-bar `>` rows come from `AppCommandSpec` via
`CommandBarDataSource`.

0. **Already an `AppCommand` or `LocalActionSpec`?** Reuse it. Bind the host
   to `AppCommandDispatcher` / the existing spec. Stop.
1. **New command identity?** Add a case to `AppCommand`.
2. **Keyboard binding?** Add a case to `AppShortcut` with its trigger and
   contexts.
3. **Interactive command metadata?** Add its exhaustive `AppCommandSpec`
   entry with label, icon, help text, surface policy, targeting policy,
   command requirements, shortcut, and command-bar grouping.
4. **IPC classification?** Classify the same identity in the exhaustive
   exposure, durable-target, privilege, and argument switches in
   [`AppCommand+IPCProjection.swift`](../../../Sources/AgentStudio/App/Commands/AppCommand+IPCProjection.swift).
5. **Interactive host?** Have the host request its exact
   `AppCommandPresentationQuery`, keep placement/order local, and use the
   matching `canDispatch` overload for enabled state.
6. **UI-only action with no command identity?** Add a `LocalActionSpec` case
   for label, help text, icon, and tooltip projection. Do not invent a
   second label string at the call site.

You almost never want to skip a layer. If you find yourself hardcoding
a key character in a view, a label string in a controller, or a `Button`
action that bypasses `AppCommandDispatcher`, you're about to create a
parallel system — back up to step 0.

## Choosing the execution owner

`AppCommandDispatcher` can route to two handler families:

| Handler | Owns | Examples |
|---------|------|----------|
| `ShellCommandHandling` (`AppDelegate`) | App/window/sidebar/command-bar shell actions that do not need pane-local focus or drawer resolution. | `newWindow`, `closeWindow`, `showCommandBarEverything`, `toggleSidebar`, `showReposSidebar`, `showPanesSidebar`, per-screen sidebar settings, sign-in flows. |
| `WorkspaceCommandHandling` (`PaneTabViewController`) | Tab, pane, drawer, and workspace actions that need active pane state, drawer focus, pane target resolution, or workspace validation. | `toggleDrawer`, `addDrawerPane`, `openPaneLocationInEditorMenu`, `openPaneLocationInFinder`, focus and layout commands. |

If a command operates on a pane, drawer, or pane-adjacent control, it
belongs in `PaneTabViewController`. Do not route pane-local commands
through `AppDelegate` and then infer the active pane from
`WorkspaceStore`; that bypasses the drawer-aware focus and selection
helpers used by the rest of the pane system.

Retained Inbox command identities are historical compatibility source, not
active handler ownership. Shell and workspace handlers reject them as
unavailable without reading or mutating Inbox state; no bell control, pane
target resolution, presentation route, or command/query owner is active.

The drawer command pattern is:

```text
AppShortcut → AppCommand → AppCommandDispatcher
  → PaneTabViewController.execute(...)
  → drawer-aware target resolver
  → atom/binding read by DrawerIconBar
```

The command bar uses the same `AppCommandDispatcher.dispatch(...)` path as
keyboard shortcuts. Root rows follow `AppCommandTargeting.preferredInvocation`:
contextual rows dispatch directly, targeted rows drill into only the declared
target kinds, and commands supporting both use their declared preference. The
dispatcher repeats contextual or targeted mode preflight before calling an
execution owner. If a command works from a button but not from `Cmd-P`, the
execution owner is probably wrong or the command is using a side channel
instead of the same binding/state model as the button.

Programmatic control shares `AppCommand` identity and canonical public copy, but
it does not derive authority from command-bar presentation. `command.list`
projects the independent `AppCommand.ipcSpec` contract for discovery, including
execution mode, durable target handle kinds, typed argument schema, and
required privileges. `command.execute` is still reserved for commands whose
`ipcSpec.exposure` is `.headless` or `.headlessAndInteractive`; it validates and
decodes the command's typed IPC argument contract before dispatching to the
app/shell owner.
Command-bar presentation remains explicit as `ui.commandBar.open`; see
[AgentStudio IPC Architecture](ipc.md#command-and-ui-presentation-boundary).
If a command row only opens a chooser or requires interactive input, add a
semantic IPC method with explicit parameters before exposing it through
`command.execute`.

Argument-bearing execution requests go directly to the app/shell execution
owner instead of consulting the parameterless `canExecute(_:)` result. IPC
derives whether every argument value is a string while decoding the wire
payload; in-process callers cannot override that validation fact.

## Multiple bindings per command — `alternateTriggers`

A command can have one **primary** trigger plus any number of
**alternate** triggers. Use this when a command needs to fire under a
different keystroke shape in a specific context.

Example — `addDrawerPane`:

```swift
case .addDrawerPane:
    return .init(
        trigger: .init(key: .character(.d), modifiers: [.command, .shift]),
        alternateTriggers: [
            .init(key: .character(.p), modifiers: []): [.emptyDrawer]
        ],
        contexts: [.global, .terminalAppOwned, .emptyDrawer]
    )
```

  ▸ **Primary**: `cmd-shift-D` — fires globally and in
    `terminalAppOwned` context. Shows in the command bar.
  ▸ **Alternate**: raw `P` (no modifier) — fires only in
    `.emptyDrawer` context. Shown in the empty-drawer hint.

Both dispatch the SAME `AppCommand.addDrawerPane`. The display layer
asks for the right one per context via
`AppShortcut.addDrawerPane.displayKeyBinding(in: .emptyDrawer)`.

## Contexts

`ShortcutContext` gates **where** a binding fires. Each binding declares
which contexts it belongs to.

| Context | Where it fires |
|---------|----------------|
| `.global` | Anywhere — installed via the app's local key monitor. |
| `.terminalAppOwned` | Inside a terminal pane host (terminal owns key routing first). |
| `.managementLayer` | When management layer is active (raw character bindings without modifiers are common here). |
| `.emptyDrawer` | Drawer is open + empty + focused. Raw-character bindings here MUST be gated upstream on a neutral responder so text fields keep receiving keystrokes. |

Add a new context only when an existing one would cause cross-routing
(a binding firing in a place it shouldn't). Don't add contexts for
"nice to organize" reasons — the routing layer enumerates contexts to
find a match, so each new context is a small cost on every keystroke.

## Displaying the bound key in the UI

Use the helper, never reach for the raw character:

```swift
Text("Press \(AppShortcut.addDrawerPane
        .displayKeyBinding(in: .emptyDrawer)?
        .displayString ?? "") to \(LocalActionSpec.addDrawerPane
        .actionSpec.helpText.lowercased())")
```

`displayKeyBinding(in:)` returns the alternate trigger when the context
prefers one (today only `.emptyDrawer` does), otherwise the primary.
`KeyBinding.displayString` formats as `⌘⇧D` / `P` / `↑` etc.

If the context's binding is non-character (an arrow, escape), the
helper returns `nil` — handle that case explicitly.

## Tooltips, help text, and compact control copy

Labels, icons, help, and dense tooltips come from the spec, not the control.
[`ActionSpec.helpText`](../../../Sources/AgentStudio/Core/Actions/UIActionPresentation.swift)
is descriptive command help for command-palette rows, menus, accessibility
descriptions, and other places where the user is reading an action
description. Icons are [`CommandIcon`](../../../Sources/AgentStudio/Core/Actions/CommandIcon.swift)
on the spec.

Icon buttons and dense toolbars need compact control text instead. Use the
typed tooltip source contract rather than hand-written `.help("...")`,
`toolTip = "..."`, or custom hover strings. The source model is projection, not
inheritance:

```text
AppCommandSpec
  -> CommandDisplayDescriptor
  -> ControlTooltipSource
  -> ControlTooltipRenderValue
```

Owned by
[`AppCommand+DisplayDescriptor.swift`](../../../Sources/AgentStudio/Core/Actions/Commands/AppCommand+DisplayDescriptor.swift),
[`ControlTooltipSource.swift`](../../../Sources/AgentStudio/Core/Actions/ControlTooltipSource.swift),
and
[`ControlTooltipRenderValue.swift`](../../../Sources/AgentStudio/Infrastructure/ControlTooltipRenderValue.swift).
For command-backed controls, App projects `AppCommandSpec` into the display
descriptor. For UI-only controls, `LocalActionSpec.actionSpec` projects into
the same descriptor shape. For feature-local shortcuts, the feature's
keyboard router and tooltip display must share one local descriptor before
producing `ShortcutDisplayText`.

`ControlTooltipRenderValue` and primitive shortcut display text may live at the
Infrastructure/render boundary so `SharedComponents` can consume them.
`SharedComponents` must not accept `AppCommandSpec`, `ActionSpec`,
`ControlTooltipSource`, or IPC command DTOs. It renders resolved values and
emits closures.

`IPCCommandListEntry` is a projection result, not an internal display base.
Programmatic control can discover command metadata, but tooltip provenance and
copy policy stay in the app/Core display path.

SwiftUI `.help(...)`, AppKit `toolTip`, and custom hover-tooltip presenters
should all read from the same resolved tooltip value for a given dense control.
Compact tooltip text must not replace accessibility labels or accessibility
descriptions.

Do not build one oversized tooltip by concatenating multiple command or local
action help strings. If a control opens a menu or summarizes several actions,
give that control one short tooltip such as "Clear notifications"; keep the
longer action-specific descriptions on the individual menu items or command
rows.

Shortcut text still comes from `AppShortcut.displayKeyBinding(in:)` when the
shortcut is app-wide. Feature-local keyboard shortcuts should use a small typed
helper near that feature's keyboard router and project to `ShortcutDisplayText`;
do not promote a local shortcut into `AppShortcut` only to render a tooltip.

## Where constants live

This decision tree governs WHICH file holds a value. Misplacing a value
is the most common drift source — once a value lives in the wrong file,
two call sites will fork and diverge.

| Goes here | When the value… | Examples |
|-----------|-----------------|----------|
| [`AppCommandSpec`](../../../Sources/AgentStudio/Core/Actions/Commands/AppCommand+Catalog.swift) | Is command identity display: label, `CommandIcon`, `helpText`, shortcut, surfaces | Catalog entry for `addDrawerPane` |
| [`AppShortcut`](../../../Sources/AgentStudio/Core/Actions/Commands/AppShortcut.swift) | Is a keyboard binding (key + modifiers + contexts) | `cmd-shift-D` for `addDrawerPane`, raw `P` for empty-drawer alt |
| [`CommandIcon`](../../../Sources/AgentStudio/Core/Actions/CommandIcon.swift) | Is the SF Symbol or octicon token on a spec | `.system(.plus)`, `.octicon(.gitPullRequest)` |
| [`AppPolicies`](../../../Sources/AgentStudio/Infrastructure/AppPolicies.swift) (for example `AppPolicies.DragAndDrop`) | Is a runtime behavioral rule that gates filtering, hit testing, ordering, what's accepted vs rejected | `drawerMaxRows = 2`, `paneRowSideZoneFloor = 24`, `paneRowSideZoneFraction = 0.25` |
| [`AppStyles`](../../../Sources/AgentStudio/Infrastructure/AppStyles.swift) (for example `AppStyles.General.Layout`) | Only changes how something LOOKS (paint width, font size, opacity) | `dropTargetMarkerWidth = 8`, `paneGap = 1` |
| [`LocalActionSpec`](../../../Sources/AgentStudio/Core/Actions/UIActionPresentation.swift) (`actionSpec.label`, `actionSpec.helpText`, `actionSpec.controlToolTip`) | Is UI text shown in buttons, menus, command rows, or compact tooltips when there is no `AppCommand` | "Add Drawer Pane", "Add a drawer pane to the active pane", "Clear notifications" |

If a value SOMETIMES gates behavior and SOMETIMES is purely visual
(rare), prefer `AppPolicies` and have the visual layer read from it.
Behavior is harder to migrate later than presentation.

Use `AppStyles` only when changing the value cannot alter routing,
validation, retention, state transitions, event emission, or which
commands are accepted. Shared UI controls, such as sidebar search
fields, should read visual constants from `AppStyles` and receive all
feature behavior through values and closures. If changing the value can
alter behavior, it belongs in `AppPolicies`.

## Adding a raw-character contextual shortcut

A common pattern: a single keystroke (no modifiers) that fires only in
one UI context. Example: `P` in empty drawer creates the first pane.

Steps:

1. Add the context to `ShortcutContext` if it doesn't exist.
2. Find the `AppShortcut` case (or add one) for the command.
3. Add the no-modifier `ShortcutTrigger` to `alternateTriggers`.
4. Include the context in the spec's `contexts` set.
5. Wire the gate site (e.g. `PaneTabViewController`) to use
   `ShortcutDecoder.shortcut(for: trigger, in: .yourContext)` — match
   the resolved `AppShortcut` against the expected case.
6. Wire the UI hint site to use
   `AppShortcut.yourCase.displayKeyBinding(in: .yourContext)`.
7. **Critical for raw characters** — gate on
   `PaneTabViewController.isNeutralResponderForRawCharacter(_:)` (or
   an equivalent neutral-responder check). Otherwise the keystroke
   will be intercepted while a text field has focus and steal user
   input.

## Common mistakes

  ▸ **Adding an ad-hoc button, menu item, toolbar control, or command-bar
    row — including its label, icon, or tooltip.** The dispatcher, shortcut,
    IPC projection, and command bar never see it. Add or reuse `AppCommand`
    / `LocalActionSpec` and bind the host; project display from the spec.
  ▸ **Hardcoding the key character in a view's text label.** Drifts
    from the AppShortcut binding. Use `displayKeyBinding(in:)`.
  ▸ **Hardcoding the action description string or SF Symbol.** Drifts from
    `AppCommandSpec` / `LocalActionSpec`. Use `actionSpec` and `CommandIcon`.
  ▸ **Creating a parallel constant for "this raw key fires this
    action".** Add an alternate trigger to the existing `AppShortcut`
    case. Parallel constants always drift — the AppShortcut system
    is the source of truth.
  ▸ **Skipping the neutral-responder gate for raw characters.** Will
    cause text fields to lose keystrokes. Check the existing helper
    or add one.
  ▸ **Adding a new ShortcutContext to disambiguate similar cases.**
    Usually means the existing routing isn't expressive enough; add
    an alternate trigger first.

## Testing

  ▸ Pure helpers (e.g. neutral-responder checks) get isolated unit
    tests — see `PaneTabViewControllerNeutralResponderTests`.
  ▸ End-to-end shortcut routing is harder to test through AppKit
    directly; pin the contract at the spec level (assert
    `AppShortcut.foo.spec.alternateTriggers` contains what you expect)
    plus the gate site's behavior with synthetic NSEvents.
  ▸ Presentation policy tests cover every surface/subject combination,
    including unsupported surfaces, unsatisfied requirements, undeclared target
    kinds, and `.notPresented`.
  ▸ Dispatcher tests prove contextual and targeted mode preflight separately
    from execution-owner capability and mutation/runtime validation.
  ▸ IPC projection tests pin exhaustive discriminated contracts, public
    command-list cardinality, and byte-equivalent sorted JSON independently
    from interactive presentation policy.
  ▸ For UI hints, snapshot the displayed string from the same helpers
    the production code uses — don't hardcode the expected character
    (it should come from the spec).
