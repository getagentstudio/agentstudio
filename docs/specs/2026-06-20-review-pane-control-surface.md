# Review Pane Control Surface Spec

Date: 2026-06-20

## Goal

Define the product boundary for the Review Pane, the internal Bridge primitive
boundary, and the typed command/programmatic-control surface for review actions.

The Review Pane must be usable by a human through the app UI and by automation
through semantic commands or typed IPC. The same product actions must not split
into unrelated UI-only and automation-only behavior.

## Current Evidence

The current pane/content model persists review UI as `PaneContent.bridgePanel`
with `BridgePaneState(panelKind: .diffViewer)`. Runtime/storage identify the
surface as `.diff`, while `PaneContentType.review` already exists but is not used
by the bridge-backed review pane.

The app opener is product-specific: `openBridgeReview` creates a read-only
review pane titled "Bridge Review", but it currently defaults the source to a
workspace diff with `.unstaged` baseline. This is why clean branches can open an
empty native review pane even when the branch has changes against `origin/main`.

IPC already splits command presentation from headless command execution.
`command.list` is now a projection from `AppCommandSpec.ipcExposure` into
`IPCCommandListEntry`. `IPCCommandListEntry` is only the public programmatic
projection; it is not the app's internal display base and it must not own
tooltip provenance or copy policy. `command.execute` remains reserved for
explicitly headless semantic commands. Review-specific automation currently
lives under Bridge IPC methods such as `bridge.diff.refresh`,
`bridge.diff.selectFile`, `bridge.fileTree.search`, and
`bridge.fileTree.setFilter`.

BridgeWeb already uses Zod schemas and discriminated unions for review
projection modes and refinements. Search is the exception: it is currently a raw
`treeSearchText: string`, and programmatic control exposes
`bridge.fileTree.search(searchText)`.

## Mental Model

```text
User / Agent / Test
  |
  |  product intent
  v
Review Pane
  - review source and compare target
  - review mode
  - file projection and filters
  - file/tree selection
  - content render mode
  - telemetry and proof hooks
  |
  |  internal transport
  v
Bridge Primitive
  - WebKit app host
  - custom resource scheme
  - typed JS bridge/RPC
  - package/content push transport
  - page-control dispatch
  - OTLP/debug telemetry plumbing
```

The Review Pane is the product surface. Bridge is the internal host and transport
primitive. Future panes may reuse Bridge, but review source semantics, search,
filters, compare target, and file selection are Review Pane concerns.

## Product Boundary Decisions

1. Product language is "Review Pane" and "Review".

   UI labels, command labels, documentation, and future user-visible IPC docs
   should use Review terminology. Existing Swift implementation names containing
   `Bridge` may remain during a bounded migration if the plan names the debt and
   proof gates.

2. Bridge remains a primitive.

   Bridge owns WebKit/RPC/resource transport mechanics. It must not become the
   product command namespace for every future pane.

3. Native Review opening defaults to default-branch comparison.

   Opening Review from a worktree should compare against the configured/default
   branch when available, not only unstaged workspace changes. Unstaged/staged
   review remains a selectable compare source, not the default product behavior.
   Compare targets must be modeled explicitly, not collapsed into a raw string:
   local default branch, origin default branch, named branch, arbitrary Git
   ref/SHA/tag, staged index, and unstaged working tree are distinct product
   choices.

4. Review Pane actions are semantic and typed.

   UI commands, IPC methods, and BridgeWeb page-control commands should describe
   product intent, not raw WebKit operations. No public automation method should
   expose `evaluateJavaScript` or raw postMessage.

5. Command specs, tooltips, and IPC are related but not identical.

   `AppCommand` / `AppCommandSpec` owns app-visible command identity, shortcut
   metadata, command-bar rows, tooltip source projection, and IPC exposure
   metadata. Pane-local Review operations with explicit pane handles belong on
   the Review/Bridge IPC port. If a command row is automatable, it must have an
   explicit typed execution path; it must not drive the command palette as a
   side effect.

## Review Actions

| Product action | UI command spec | Programmatic method | Owner |
| --- | --- | --- | --- |
| Open Review for worktree | `Review` command on worktree targets | `review.open` or existing `bridge.diff.load` with review open params | App + Review opener |
| Set compare target | Review-pane control | typed review source/config method | Review Pane |
| Refresh package | Review-pane command | `review.refresh` / existing bridge refresh adapter | Review runtime |
| Set review mode | segmented control | typed review mode setter | Review Pane |
| Set filters | filter button/popover | typed filter setter | Review Pane + BridgeWeb |
| Set search query | search field | typed search setter | Review Pane + BridgeWeb |
| Reveal/select file | file tree / CodeView selection | typed select/reveal method | Review runtime |
| Fetch content | content renderer | typed content get by handle | Bridge content store |
| Flush telemetry | debug/control action | telemetry flush method | Review telemetry |

The current public method names may remain during migration, but new contracts
should prefer Review product vocabulary unless they are truly primitive Bridge
transport APIs.

## Command, Tooltip, And IPC Projection

Review controls must follow the typed tooltip source contract landed in PR
#188. The app display path is:

```text
AppCommandSpec
  -> CommandDisplayDescriptor
  -> ControlTooltipSource
  -> ControlTooltipRenderValue
  -> SwiftUI/AppKit/shared UI render adapter
```

UI-only Review actions use:

```text
LocalActionSpec.actionSpec
  -> CommandDisplayDescriptor
  -> ControlTooltipSource
  -> ControlTooltipRenderValue
```

IPC discovery uses a separate projection:

```text
AppCommandSpec.ipcExposure
  -> IPCCommandListEntry
```

`IPCCommandListEntry` is not the internal display base. It must not be used by
BridgeWeb, SharedComponents, SwiftUI controls, AppKit buttons, or custom hover
presenters to decide tooltip text.

SharedComponents may render `ControlTooltipRenderValue`, but must not consume
`AppCommandSpec`, `LocalActionSpec`, `ActionSpec`, `ControlTooltipSource`,
`AppCommand`, or IPC DTOs. Review Pane UI wrappers own semantic sources and pass
render values plus closures into shared render-only controls.

Review dense controls must not introduce raw `.help("...")`, direct AppKit
`toolTip = ...`, or custom hover strings in covered dense-control surfaces. The
`agentstudio_toolbar_tooltip_source` architecture lint rule is the enforcement
path.

For Review commands, `AppCommandSpec.ipcExposure` should expose discovery
metadata only when the command has a stable programmatic meaning. Commands that
open pickers or need interactive input should advertise presentation or
parameter requirements and fail closed through `command.execute` until a typed
Review IPC method exists.

## Search And Filter Semantics

Search is a filter dimension, but it should remain a transient tree-navigation
filter in this phase. It composes after semantic projection filters.

Execution order:

```text
review package
  -> projection mode
  -> semantic refinements
  -> visible projected paths
  -> tree search query
  -> select/reveal/render content
```

Projection filters shape the dataset and may use the projection worker. Tree
search narrows or reveals matches inside the projected tree and must not rebuild
projection on every keystroke.

Search query must become typed:

```ts
export const reviewTreeSearchQuerySchema = z.discriminatedUnion('kind', [
  z.object({
    kind: z.literal('plainText'),
    text: z.string(),
    caseSensitivity: z.enum(['smart', 'insensitive', 'sensitive']).default('smart'),
  }),
  z.object({
    kind: z.literal('regex'),
    pattern: z.string().min(1),
    flags: z.string().regex(/^[imsu]*$/).default(''),
    target: z.enum(['displayPath', 'candidatePaths']).default('candidatePaths'),
  }),
]);

export type ReviewTreeSearchQuery = z.infer<typeof reviewTreeSearchQuerySchema>;
```

Plain text is the default UI behavior. Regex is explicit, either through a UI
toggle or a recognized `regex:` / `/pattern/flags` entry mode. Invalid regex
must return a typed rejected probe/result with a visible error state; it must not
silently show no matches.

Regex should initially target file paths, not file contents. Content search is a
separate workload with different performance and privacy characteristics.

## Compare Target Semantics

Review compare target state is a product input, not a BridgeWeb rendering detail.
The Swift Review source model and the future typed IPC payload must preserve the
selected target kind:

```text
local default branch       -> local branch name, usually main or master
origin default branch      -> remote + branch, usually origin/main
named branch               -> branch name selected by the user or automation
arbitrary ref/SHA/tag      -> Git ref string selected by the user or automation
staged index               -> index delta against HEAD
unstaged working tree      -> working-tree delta against index/HEAD
```

The initial native opener may choose the best known default synchronously from
repo enrichment, with `origin/main` as a safe fallback. The richer selector and
IPC path own validation and user-visible errors for missing branches, tags, and
SHAs. They must fail closed with typed errors instead of silently returning an
empty package.

## Review Modes And Filter Facets

The top review mode selector owns the shape of the review experience:

| Mode | Meaning |
| --- | --- |
| Review | normal human review of the selected compare source |
| Guided | AI-guided review ordering and grouping |
| Plans | plans/specs/docs-first review |

The filter popover owns dimensions that narrow files:

| Facet | Examples |
| --- | --- |
| Git | added, modified, renamed, deleted, copied |
| Type | docs/plans, tests, source, config, generated, large, binary |
| Scope | folders, extensions, languages, visibility, future change sets |

Search remains visible as a fast input because it is a primary navigation
control. It still participates in the same filter state model and programmatic
control surface.

## State And Worker Rules

Zustand remains a pure state owner. Store actions may update state, enqueue
intent, and record status. They must not directly call Swift, fetch content,
post worker messages, mutate Pierre models, or emit telemetry.

Heavy projection work stays off the main thread. Regex tree search may run on
the main thread only while it delegates to Pierre tree search or searches bounded
path metadata. If it becomes custom O(n) work over large candidate maps, it must
move to a worker lane and expose metrics.

All public TS schemas follow the project convention:

```text
camelCaseNameSchema -> Zod schema
PascalCaseName      -> z.infer type
```

Discriminated unions are required for variants. Use `Record<string, unknown>`
only for intentionally opaque payloads.

## Command And IPC Requirements

Every Review Pane product action must be available through at least one of:

1. `AppCommand` / `AppCommandSpec` when it is a user-visible app command.
2. A typed pane/runtime IPC method when it is automatable or test-critical.
3. A typed BridgeWeb page-control command only for renderer-local behavior.

Command specs must include Review-pane scope metadata so the command palette can
show review-scoped actions while a Review Pane is focused.

Command specs that render dense Review controls must also project tooltip source
through `CommandDisplayDescriptor`. UI-only local Review controls must use
`LocalActionSpec.actionSpec` or a feature-local descriptor with a declared
dynamic reason; they must not hand-write parallel tooltip copy.

Programmatic methods must resolve a target pane explicitly:

> **Superseded by [Agent IPC v2, R-08](2026-09-12-agent-ipc-v2/specification.md).**
> Methods take a `handle` with one of three spellings: `self`, a bare canonical
> pane UUID, or `pane:<n>` (a positive ordinal). `pane:<uuid>`, `pane:active`
> and `surface:<id>` are rejected with `invalidParams` at `$.handle`. The Bridge
> openers take a `worktreeId` and return the canonical handle for follow-up
> calls. The block below is the original 2026-06-20 proposal, kept as history;
> do not use these forms.

```text
target: pane:active
target: pane:<uuid>
target: surface:<id>
```

If the target is not a Review Pane, fail with a typed unsupported-target error.

## Security And Privacy

Review automation exposes repository metadata, paths, content handles, and
bounded file content. It must preserve the existing pane-handle authorization
model and must not add raw path or raw WebKit control endpoints.

Default privileges:

| Capability | Scope |
| --- | --- |
| `review.read` | package metadata and render state |
| `review.content.read` | bounded content by handle |
| `review.control` | refresh, mode, filter, search, select/reveal |
| `review.telemetry.read` | debug metrics/summaries |
| `review.telemetry.flush` | explicit flush |

OTLP output remains debug/proof-oriented and must stay source-scrubbed.

## Incoming Dependency

PR #188 (`agent-studio.tooltip-source-contract`) updates command and tooltip
source contracts, including `docs/architecture/commands/command_specs.md`.
Implementation must merge main after that PR lands and reconcile this spec with
the new command-source model before adding Review command specs.

## Non-Goals

- No patch apply, approve/reject, or source mutation.
- No raw WebKit automation API.
- No file-content regex search in this phase.
- No broad persistence rename unless the plan sizes migration and proof gates.
- No new telemetry stack ownership in this repo.

## Open Decisions

1. Should first-phase programmatic method names hard-cut to `review.*`, or keep
   current `bridge.*` names with Review aliases during one internal-only step?
2. Should regex UI use a toggle, `regex:` prefix, `/pattern/flags` syntax, or
   all three with one canonical internal representation?
3. Should Review Pane persistence use `.review` content type in this phase, or
   should that be a separate migration after command/search control lands?
