# BridgeWeb Design-Token Architecture

BridgeWeb and native Agent Studio have separate styling authorities:
[AppStyles.swift](../../../Sources/AgentStudio/Infrastructure/AppStyles.swift) for native
presentation and [bridge-app.css](../../../BridgeWeb/src/app/bridge-app.css) for web
presentation. Values correlate by convention; there is no generator or runtime coupling.

For equivalent native and web controls, compare the existing native composition
and command-display contract, including label, icon and shortcut presentation.
Reuse their meaning through each surface's owned implementation.

## Source and rendering paths

```text
CSS primitive palette → semantic roles/scales → owned UI primitives/content slots
                                           → shared patterns and feature components
                     ↘ annotation context → canvas-relative annotation surfaces
                     ↘ checked TypeScript mirror → Pierre static theme overrides

Native AppStyles → native controls
Native startup   → dark Aqua appearance
```

[Owned primitives](../../../BridgeWeb/src/components/ui/) define control typography,
height, padding, icon size, radius, border, fill, foreground, and interaction states.
Consumers choose a semantic variant and size, provide behavior/accessibility attributes,
and compose layout. Shared viewer wrappers may retain shared attributes and composition;
they do not append control paint or geometry. Width, placement, and containing layout
remain with the feature.

Base element resets live in `@layer base`. An unlayered `font: inherit` on a button
outranks Tailwind's layered typography utilities, even when those utilities have higher
selector specificity. Do not repair that precedence mistake with important classes.

## Component language contract

This is the current presentation authority for ordinary BridgeWeb UI. Read it
after BridgeWeb/AGENTS.md and before editing a primitive or feature composition.
Earlier trial specifications remain historical decision context where they
disagree with the palette, surface-relative control fills or full-height Share
described here. Domain contracts for annotation eligibility, transport and output
remain authoritative in their own documents; this section does not supersede them.

```text
CSS palette / roles / scales       AppStyles core scales
             |                    same values by convention
             v
owned shadcn primitives: full paint, geometry, type and state recipes
             v
shared compositions: headers, bodies, card sections, action areas
             v
feature components: domain content, callbacks and outer layout
```

Shadcn provides composable source recipes, not automatic enforcement of our
product language. Adapt centrally to the existing compact scale. A feature may
compose Card, Field and Item slots; it must not restyle those slots or their
descendants. Native synchronization is by convention, not generated or runtime.

### Typography hierarchy

| Role | Owned recipe | Meaning |
|---|---|---|
| Panel title | DrawerTitle: 14/20px, semibold, foreground | Names the task, e.g. Compare Worktree. |
| Section/card title | CardTitle / CollapsibleHeading: 13/18px, medium, foreground | Names a meaningful group, never a muted caption. CollapsibleHeading composes the standard button interaction for expandable sections. |
| Item identity | ItemLabel: 13/18px, regular, foreground | Branch or file name; not a heading merely because it is prominent. |
| Body / field value | 12/16px, regular, foreground | Comment body, summary value or user input. |
| Description / metadata | CardDescription / DrawerDescription / ItemDescription: 12/16px, regular, muted-foreground | Dates, ranges and explanations remain readable. |
| Compact control / field label | Existing Button / Field slots: 11/14px, medium | Names an action or input, not a section. |

Choose text by semantic role, not by whichever imported component is convenient.
A setting label names a preference; it is not automatically a compact action.
The current `Field orientation="setting"` candidate uses body-size regular text;
its final visual acceptance remains separate from the compact-label rule above.
Do not propagate either recipe to unrelated fields to hide this distinction.

Use system sans-serif for ordinary UI; code and revisions alone use monospace.
Heading levels follow semantic nesting independently of font size: panel heading,
then subordinate section heading. Do not mute headings to manufacture hierarchy,
nor make metadata tiny. Hover and selection preserve size, weight and text roles.

### Surfaces, spacing and composition

The Colors and states section below owns exact values. Drawer header, body and
footer share the floating fill. Cards use the separate lighter card role. Do not
add cards around individual search results or add a divider beside a card boundary.
Use one footer separator only where fixed actions meet scrolling content.

DrawerHeader owns its 8px inset and no-divider default. DrawerBody owns 8px inset,
shrinking and scrolling. DrawerFooter owns 8px inset and action gap. Card slots
own 8px padding; a following content/footer slot avoids duplicate top padding.
The optional `CardHeader variant="divided"` adds an inset bottom `separator`
rule without changing the card background or spacing. Its default variant has no divider.
CardFooter wraps actions with an 8px gap. Controls own their own icon geometry;
headers must not reach into nested controls with blanket SVG selectors.

Composition spacing: adjacent cards 8px; independent sections 16px; related
content 4px; existing two-line Item content gap 2px. Existing 4/6/8px compact
spacing and 20/24/28/32px action ladder remain; descriptive rows retain 44px.
External placement, available width and virtual positions remain feature-owned.

```text
Compare                           Share
  shared panel header               shared panel header
  current comparison Card           Pending / All scope control
    title / target / metadata       file identity + thread Card
  target selection Card               author / range / full body
    Field + ToggleGroup             History disclosure
    search + continuous results       attempt Cards + wrapping actions
                                    fixed output footer
```

Both panels fill the existing inset viewer-height frame. They remain mutually
exclusive peers. Their existing close/focus/busy guards and domain callbacks
remain with the feature/controller, not with presentation slots. History stays
collapsed initially; it is output history, not a second comment list.

Annotations navigation remains visible and openable without export readiness;
All remains selectable when empty or unavailable. Only output actions require
eligible, ready, authorized content. Pending/All scopes the drawer preview and
output only; it must not filter annotation membership in the main code canvas.

### Composition patterns

Choose product content before choosing controls. A renderer/API option is not
automatically a user setting. Library examples illustrate interaction and
composition, not product scope. Changing available choices, defaults, reset scope
or domain behavior requires an explicit product decision, not a styling shortcut.

- **Settings:** compose a Popover with labelled Field setting rows; booleans use
  Switch and exclusive choices use the shared segmented ToggleGroup. Align
  label/icon starts and equivalent controls across rows. The main settings body
  uses `FieldGroup layout="settings"` as one two-column grid; section wrappers
  and `Field orientation="setting"` rows inherit its columns through subgrid.
  Controls align at their right edge within the shared control column and retain
  intrinsic sizes; labels stay left-aligned. Titles and Reset
  stay outside this grid. Reserve readable labels
  and control clearance at supported widths; use a responsive composition when
  they cannot fit, rather than shrinking text or clipping labels. See the
  [settings consumer](../../../BridgeWeb/src/app/bridge-viewer-view-settings-menu.tsx)
  and [Field recipe](../../../BridgeWeb/src/components/ui/field.tsx).
- **Menus:** use owned groups, labels and items. The checkbox item is the sole
  interactive owner; SwitchIndicator is passive. Review exposes status/category
  groups directly in two columns where space permits; Files exposes categories
  directly. Group labels retain the compact 11px scale, semibold foreground and
  a neutral identifying icon, with one quiet separator and 6px space before choices.
  Category icons are neutral; only Git status icons use semantic status colors.
  Selectable categories are All, Source code, Tests, Documentation, Configuration
  and Test data. Generated, vendor/build and unmatched classes remain backend
  metadata, not exposed category choices; removing a choice does not reclassify
  files or change default visibility. Test data means fixture directories.
- **Persistent search:** compose search, ComboboxViewport, continuous
  [Item rows](../../../BridgeWeb/src/components/ui/item-content.tsx) and supporting
  notes. Preserve 8px search/results/note clearance, selection/checkmark clearance
  and identity/metadata hierarchy. Keyboard highlight and selected value remain
  distinct. Results are not individual cards.
- **Drawers:** follow the Compare/Share composition above. Shared header/body/
  footer slots and meaningful Card groups own their insets. Preserve full comment
  bodies, scrolling and reachable actions; no doubled padding or boundaries.
- **Annotations:** shared controls render within the annotation context below.
  Preserve canvas-relative text/surfaces and active-thread feedback; ordinary
  popover/card roles do not replace annotation roles.

Use established action icons where they help recognition; retain labels where an
icon alone is ambiguous. Additional icons, headings and borders do not substitute
for a clear action and grouping. Current consumers demonstrate wiring, not proof
of visual acceptance; verify the actual candidate before copying its composition.
File boundaries use one header `separator`, without top/bottom container shadows.

### Change and proof discipline

1. Identify the semantic role, owner and every consumer before editing.
2. Review the full composition against this contract, not an isolated screenshot.
3. Reuse the existing slot. If it lacks a recipe, fix the shared owner and all
   consumers; a new variant requires a distinct named meaning, not a feature name.
4. Preserve palette and domain behavior unless separately authorized.
5. Test rendered hierarchy relationships, contrast, icon/control clearance,
   narrow and long content, scrolling, focus and compound states. Class-name
   assertions alone cannot establish this contract.
6. Verify current dev and packaged-native surfaces and obtain independent visual
   review before a visible checkpoint is declared ready. Report each missing gate.

Size the inventory to the change: all consumers of a shared recipe, or the changed
composition and its matching File/Review peer. Expand only for shared dependencies.
For visual comparisons hold content, state, viewport and scale constant. Include
current uncommitted UI and apply each candidate consistently across surfaces that
share the affected role; name intentional exceptions before comparing.
Record behavior/geometry proof separately from visual acceptance. Passing tests,
an imported primitive or an earlier screenshot cannot accept a later composition.

Source owners: [Drawer](../../../BridgeWeb/src/components/ui/drawer.tsx),
[Card](../../../BridgeWeb/src/components/ui/card.tsx),
[Item content](../../../BridgeWeb/src/components/ui/item-content.tsx),
[typography proof](../../../BridgeWeb/src/components/ui/typography-roles.browser.test.tsx).
Use the enforcement section below for legal layout versus recipe overrides.

### Shell boundaries and resizing

Swift titlebar/repository sidebar and Bridge viewer/file-tree toolbars share
RGB(25,27,31) by convention. Native bottom pane toolbar remains RGB(29,31,35).
File headers, file-tree background and code-view scrollbar track derive from the
same neutral-n2 primitive RGB(28,32,38), not separately authored hex values.
Terminal/code canvas remains RGB(40,44,52).

Top viewer/tree toolbars have no horizontal divider or divider shadow. The
resizable separator is the sole vertical pane boundary; the rail must not add
another input-strength outline beside it. Its resting 1px line uses `separator`;
hover, active drag and keyboard focus use the focus role and visible grip.
The library owns an invisible minimum hit area of 16px for fine pointers and 28px
for coarse pointers; the thin visible line is not the pointer target size.
Keyboard resize behavior and accessible separator semantics remain library-owned.

## Compact scale

| Meaning | Web value |
|---|---|
| `text-2xs` | 9 / 12 px font / line-height; tiny auxiliary and shortcut hints |
| `text-xs` | 11 / 14 px; control and menu labels |
| `text-sm` | 12 / 16 px; metadata, field/search values and body text |
| `text-base` | 13 / 18 px; descriptive list and navigation titles |
| `text-lg` | 14 / 20 px; drawer titles; compact popover/menu titles use `text-xs` |
| `text-xl`, `text-2xl` | 16 / 22 and 24 / 30 px |
| `rounded-sm/md/lg/xl` | 4 / 6 / 8 / 14 px |
| control xs / sm / default / lg | 20 / 24 / 28 / 32 px |
| corresponding icons | 10 / 12 / 14 / 16 px |
| compact spacing | 4 / 6 / 8 px |
| motion fast / standard | 120 / 200 ms |

Icon-only sizes are square. A segmented ToggleGroup owns its 24 px well and 20 px items.
Menu/combobox action rows are 28 px with 11 px labels. Descriptive rows are 44 px
with 13/18 px names, 12/16 px supporting text, a 2 px line gap and 4 px vertical
insets. ItemContent owns the shrinking column; selectable roots reserve check
clearance. CSS row lengths have a checked numeric mirror in
[bridge-design-row-metrics.ts](../../../BridgeWeb/src/design-tokens/bridge-design-row-metrics.ts)
for virtualizer estimates; actual root measurement remains authoritative.
The empty Textarea minimum is 48 px. Checkbox is a named compact 14 px
indicator. Circle/status glyphs and renderer metrics are distinct from button radii.

Pierre code remains 12 px; tree text consumes the 13 px navigation role. Existing code-row estimate/render metrics
remain aligned at 20 px and code headers at 40 px; outer web typography does not silently
change Pierre's virtualization geometry.

## Colors and states

The canonical primitive block in CSS is the only authored web value source.
[bridge-design-palette.ts](../../../BridgeWeb/src/design-tokens/bridge-design-palette.ts)
is its checked, value-identical mirror for static theme consumers.

| Meaning | Value or role |
|---|---|
| app/code canvas | Ghostty grey `#282C34` |
| header / tree and file header / floating surface | `#191B1F` / `#1C2026` / `#20242A` |
| nested card surface | `#272C34`; independent from the popover role |
| product primary and sidebar identity | `#409CFF` |
| syntax blue | Catppuccin `#89B4FA` |
| floating border | `#566171` |
| ordinary / supporting text | `#EAEAEA` / `#B8BCC4` |
| ordinary / muted / faint text | `foreground` / `muted-foreground` / `faint-foreground` |
| layout separator / card border / control boundary | `separator` (10% white) / `border` (#434B57) / `input` (#6E7787) |
| focus | `ring` → #8F98A8, independent of primary; 2px outline retained alongside an invalid boundary |
| invalid | `destructive`, 2 px at 20% |

Product primary has only solid, 15% tint, and text uses. It is not the syntax palette.
Ghost/outline hover and open/boolean pressed states use the shared surface-relative
`control-hover` (#343A44); expanded ghost controls use `control-fill` (#343A44). Selected Toggles
use product tint. Share/menu/panel-open buttons are not exclusive selection.
Disabled controls use explicit neutral foreground, icon, fill, and boundary values at
opacity 1; hover/open/selected cannot restore enabled colors. A disabled selected
toggle keeps a faint-role outline so its selected identity remains visible.
Enabled text meets 4.5:1 and meaningful indicators 3:1 on actual composited fills.
Inputs, input groups and combobox chips use the recessed `field-background` (#14181E);
segmented tracks are transparent and outlined; selected
labels use `control-selected-foreground` (#89B4FA) over primary tint. Descriptions retain their
supporting role when highlighted rather than becoming uniformly bright.

Switch checked tracks also use 15% primary with a `control-selected-foreground`
thumb; thumb position is the non-color state cue. Unchecked tracks use `input`
with a `foreground` thumb. The passive menu indicator shares the same recipe;
it is not a nested interactive switch. Disabled paint remains explicitly neutral,
and keyboard focus has the independent `ring` treatment. Check thumb contrast
against the actual composited track on each supported surface.

Menus, popovers, tooltips, toasts and comboboxes share the primitive-owned popover family.
Drawers use that same floating role. Cards use their own palette value rather than
owning the popover color. Share composes read-only thread cards with path headings
outside and author/range/body inside. Resting combobox rows remain transparent;
highlighted rows use `control-hover` plus a solid inset ring while the selected
value retains its independent checkmark. Existing menu/annotation/Pierre hover
roles remain separate; do not recolor the whole neutral ramp to change controls.
The canonical elevations are `--elevation-popover` and `--elevation-context-panel`,
exposed as `shadow-popover` and `shadow-context-panel`. The context-panel variant uses
the established directional shadow and 14 px frame radius. Placement and inset are
separate layout decisions.

Swift startup pins dark Aqua; product accent is fixed in AppStyles rather than following
the macOS accent preference. Terminal content retains its separately owned per-surface
appearance. Web roles and primitive recipes are unconditional dark, including body portals.
A `.dark` ancestor, `dark:` utility, or OS color-scheme branch must not choose web paint.

## Annotation context

`--annotation-*` roles describe surface, foreground, muted text, border, divider, hover,
active-thread fill, composer, status, and destructive feedback. Controls still use the
shared primitives. The active-thread fill uses the canonical warning role at 14% in the
existing Lab blend. It does not read a custom property that exists only inside a Pierre
shadow root, and it does not change Pierre's selection mechanism.

The outer annotation lane uses a 3% white wash and retains its active 8% warning tinge.
Annotation foreground follows `code-foreground`, not the changed ordinary UI role;
surface and hover retain their muted/accent dependencies. Annotation border and
divider use the original white stroke primitives (14% and 7.2% effective opacity),
independent of input/card outlines. The white primitive and static code foreground
remain unchanged.

## Pierre integration

A `--diffs-` prefix does not make an application variable a Pierre API. Preserve and test
the effective hooks in the installed versions, not unused declarations or name counts.

[Code options](../../../BridgeWeb/src/review-viewer/code-view/bridge-code-view-options.ts)
set header addition/deletion/modified and foreground hooks and retain the existing
annotation-selection selectors. Host CSS supplies the real code font hooks and scrollbar
override. [Code theme registration](../../../BridgeWeb/src/review-viewer/code-view/bridge-code-view-theme.ts)
retains Catppuccin syntax and obtains Bridge-owned canvas/foreground overrides from the mirror.

[Tree theme](../../../BridgeWeb/src/app/bridge-viewer-tree-theme.ts) obtains reachable static
theme/git-decoration values from the mirror and supplies semantic override inputs.
Bridge overrides win over theme fallbacks; removing a shadowed fallback is not visible
recoloring. Code/tree font settings must cross the actual host/shadow boundary. A selector
on an outer `pre` cannot style shadow-root code.

## Enforcement and editing

[The style-system checker](../../../BridgeWeb/scripts/check-bridgeweb-style-system.ts)
runs in the normal BridgeWeb check alongside the separate architecture checker. It rejects
raw colors/palette utilities, transitional aliases, control/frame recipe overrides,
appearance conditionals, CSS/palette mismatch and CSS/row-metric mismatch. It follows
returned control roots and actual render elements, carries owned content context
through imported children, and rejects nested/ancestor appearance overrides.
An outer layout section containing a Button is not itself a Button. Shared class
constants, inline styles and embedded CSS remain checked; unknown dynamic control
classes fail closed. There are no migration allowances.

Composition patterns above own menu, settings, list and drawer usage. This section
owns enforcement mechanics, not a second pattern catalog.
Alert owns card/banner/inline/floating layouts and warning/destructive presentation.
Its floating presentation uses the popover fill, border, foreground and shadow;
the feature owns viewport placement without moving document content.
StatusBadge owns badge/indicator recipes. Features supply domain meaning and
callbacks, not local control paint. Busy/disclosure icons expose state attributes
to the Button-owned motion recipe.

Layout/prose, status glyphs, inert loading canvases and installed-version Pierre metrics
are classified separately from interactive control recipes. A new exception cannot be
just a filename bypass.

The shared refresh-status group is a noninteractive 24 px container with a separator-strength
`border` outline; its child actions still select owned Button recipes. It is not a selected
ToggleGroup well, whose quiet `border` outline groups the choices. Selected
segments use 15% primary fill without a solid blue inner border; keyboard focus
keeps its separate ring. Native shared selected fill also uses 15%, with
selected text/icons matching #89B4FA by convention. Ordinary outline buttons
and segmented group frames use `border`; editable field boundaries use `input`.

Sonner injects unlayered third-party CSS. Only its owned adapter may prioritize canonical
toast title/description and elevation utilities with important modifiers to override those
rules. This exception does not permit feature-local overrides or unlayered form resets.

When editing:

1. Reuse an existing semantic role before creating one.
2. Add a new primitive value only in the marked CSS block and matching mirror.
3. Register role utilities in `@theme inline`; contexts derive from canonical roles.
4. Put complete reusable recipes in `components/ui`; select variants/sizes at call sites.
5. Run the focused behavior/check lanes, then `mise run test` for PR readiness.
6. Inspect real before/after UI where appearance changes. Source and class-string tests
   do not prove rendered typography, cascade precedence, portal parity, or shadow-root reach.
