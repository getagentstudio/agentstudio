# Drawer Presentation — Requirements

Make the existing floating drawer reliable in normal mode and intentional in
Pane Zoom. The drawer keeps its owning pane and supporting children while its
presentation changes.

[Requirements](./requirements.md) → [Specification](./specification.md) →
[Program Design](./program-design.md).

## Scope

This is track 1 from the owner's separation of drawer presentation, Bridge
source/CWD switching, multi-worktree support, and file navigation. It covers:

- normal top-edge height resizing and the reported jitter;
- normal height memory per owning pane;
- fixed full-screen drawer geometry and the unintended bottom gap;
- full-screen terminal/Bridge-side commands and overlay gutters;
- preservation of drawer ownership, child content, and Bridge-owned drawers.

Full-screen means **Pane Zoom**, the terminal/Bridge composition in the supplied
screenshots. A Bridge tab in an ordinary arrangement uses normal drawer behavior.

Bridge source switching, multi-repo membership, Command-P file search and
file-open IPC are separate tracks. This slice owns the drawer content rule
confirmed on 2026-09-23 (below) as an admission rule for new drawer children; it
does not migrate or delete existing content. Bridge tabs may keep their own
drawers.

## Authority and source

The owner requested the smaller first version on 2026-09-13: no side-edge
resizing; normal top resize fixed; no resize handles in full-screen; two
full-screen positions; approximately 15% exposed above; width follows the
actual selected side, reduced by 2–5%; preserve drawers owned by Bridge tabs.
The owner also requested per-pane, mode-independent presentation memory.
Saved choices include ordinary shutdown/restart and restoration of the same
pane; this preserves the ordinary lifetime of a saved preference. No additional
abnormal-termination durability guarantee is introduced.

The exact quoted statements remain at S9–S15 in the
[original source record](../2026-09-12-bridge-navigation/2026-09-12-requirements.md#source-of-the-needs).
The [system analysis](../../wip/2026-09-13-drawer-bridge-system-analysis.md) is
observational evidence at source HEAD `85ae48f5e`; it is not authority to keep
today's global height preference or suspect geometry calculation.

Owner statements on 2026-09-23 (orchestrator session f4ba41d2), which refine
this slice:

| ID | Statement (transcribed voice) |
| --- | --- |
| S-DP-23a | "In full screen it's one drawer on both sides, should be easy to move on both sides, just to allow flexibility." |
| S-DP-23b | The move control: "This button can be in the drawer itself as an overlay [in] management mode." The side switch remains catalog commands: "all commands go through the command [system]; that's why the IPC works." |
| S-DP-23c | Drawer content: "They can hold web views, like browsers, but they cannot hold a bridge." and "absolutely no code viewers in the drawer." |

The U-BN-08–U-BN-12 identities below are moved from the combined requirements,
not new or duplicated needs. Their producer-owned authority state is
**authorized**, from the owner statements above. Relative delivery priority is
unranked; the owner has not assigned an order.

## User requirements

| Identity | Human need and why | Source |
| --- | --- | --- |
| U-BN-08 | Reliably resize a normal drawer's top edge and remember height independently for each owning pane, so the edge tracks the pointer and adjusting one drawer does not resize another. | S9/S10/S11 |
| U-BN-09 | In Pane Zoom, use a fixed-height floating drawer with no resize handles and approximately 15% exposed above it, so the underlying context remains recognizable. | S11 |
| U-BN-10 | Easily move the one full-screen drawer between the terminal and Bridge regions — with a control on the drawer itself shown in management mode, and through two catalog commands; follow that region's actual width with 2–5% less total width for shadow/context. There is no 50% minimum. | S12/S13/S14, S-DP-23a, S-DP-23b |
| U-BN-11 | Keep the same drawer owner, children, and supporting work across mode/side changes, with independent normal and full-screen preferences. | S10/S12/S15 |
| U-BN-12 | Remove the unintended full-screen bottom gap while keeping the panel, connector and surrounding overlay visually coherent. | S9/S12 |

Preservation constraint from
[U-BN-07](../2026-09-12-bridge-navigation/2026-09-12-requirements.md#user-requirements):
a normal Bridge tab can own a drawer. Drawer children are terminals or browsers
only; Bridge and code-viewer content is never added to a drawer (S-DP-23c,
U-BN-07). Dragging Bridge into ordinary pane layouts remains with the separate
Bridge-placement track.

## Human journey

```text
Open pane A's drawer                                      U-BN-11
  → drag its top edge in normal mode                      U-BN-08
    Current pain: jitter; one shared saved height
    Desired: stable drag; pane A's independent height
  → enter Pane Zoom                                      U-BN-09, U-BN-12
    Current pain: ordinary resize/offset rules remain
    Desired: fixed overlay; clear top context; no lower gap
  → place it over terminal or Bridge                     U-BN-10, U-BN-11
    Desired: fit chosen region; same owner and children
  → leave Zoom and reopen the normal drawer              U-BN-08, U-BN-11
    Desired: recover A's normal height without affecting B
```

The same normal-mode journey applies when the owner is a Bridge tab. Drawer
collapse is not content deletion, and side placement is not child reparenting.

## Side behavior selected by the owner

- **D-DP-1 — Initial side:** superseded on 2026-11-06. The owner chose “in full
  screen it should open on the bridge side by default”, so a pane with no saved
  choice now opens its Zoom drawer on the Bridge side at 95% height, and the last
  side per pane is still remembered. Saved choices are kept. See
  [drawer browser requirement U11](../2026-11-06-agent-open/requirements.md).
  The original 2026-09-13 choice was “Terminal side initially; remember the last
  side per pane.”
- **D-DP-2 — Hidden Bridge:** “Temporarily use terminal; retain the saved
  Bridge-side choice.” When Bridge is shown again, the effective overlay returns
  to that saved side. The temporary fallback does not overwrite the preference.

The first-version shape, actual-region width rule, absence of full-screen resize
handles, and these side transitions are selected. Unrelated source-selection
and mixed-layout policy questions do not block this drawer slice.

## Outcome evidence

Normal drag/reversal and bounds behavior need native pointer/edge evidence, plus
independent height retention across two panes and normal/Zoom/normal transitions.
Full-screen proof needs actual terminal/Bridge compositions at equal and unequal
split ratios, visible shadow/top context, no resize hit targets, and agreement
between displayed bounds, child terminal sizing and input hit regions.

Existing child ownership, close/undo, collapse/dismissal and Bridge-owned drawer
behavior remain preservation evidence. Applicable marker-scoped performance
proof remains required; this work introduces no separate latency SLA.

The jitter and bottom-gap explanations are source-backed hypotheses awaiting
native measurement. A proposed repair must not claim causation merely because
it changes the suspected code.
