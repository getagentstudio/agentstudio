# UI surface code map

Re-verify these anchors before the Program Design.

- One data path feeds all five surfaces: `SessionStatusAtom`, `PaneContextPresentationAtom` and `PaneActivityTimeAtom`, read through `PaneContextUIReaders` (`App/PaneContext/PaneContextUIReaders.swift:7-42`).
- **Sidebar row:**
  - `RepoExplorerPaneRowContent` (`Features/RepoExplorer/RepoExplorerPaneNavigation.swift:93-214`). Line order comes from `RepoExplorerPaneLineVisibilityTable`; the view draws its own chip row at :173-212 and ignores the variant's `chips`.
  - Projection worker: `RepoExplorerPanesActivityOrganization.paneRow` :258-326.
- **Toolbar:**
  - `DrawerIconBar` (`Core/Views/Drawer/DrawerIconBar.swift`): drawer, +, pin, then a divider and note at :175-208, then `middleContent` (the Agent Line) at :211-220, then the bell `PaneContextToolbarControls` (`App/PaneContext/PaneContextToolbarControls.swift:8-42`).
  - Today it shows the Agent Line AND the bell; R3 needs chips OR the Agent Line.
- **Card:** `ManagementPaneIdentityStrip` and `PaneManagementIdentityCapture`. Today it has no ACTIVE row, no "N unread" line and no ask block.
- **Popover:** `MessagesPopover` (`SharedComponents/PaneContext/MessagesPopover.swift`). It uses `Text(.relative)` ages, has filter buttons, and its rows don't read `importance` (no failure/done/info styling).
- **Age formatters disagree:**
  - `RepoExplorerPaneRecencyText.compactText` gives "Now" / "Nm";
  - `messageText` gives **"just now"** / "N min ago", which conflicts with owner R10 "Now";
  - three popover sites use SwiftUI `.relative`.
- **Duplication to fold:**
  - tone→chip style is written twice, with differing accents;
  - the status line is drawn two ways (the card loses the pulse);
  - there are three title-resolution paths;
  - count shaping is called from two places;
  - legacy inbox fields are dead in `DrawerOverlay.TrailingActions`.
- **Unassociated pane rows** get no lines or chips.
