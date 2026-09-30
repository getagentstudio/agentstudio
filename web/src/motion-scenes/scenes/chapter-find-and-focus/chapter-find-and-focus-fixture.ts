// Settled-frame content for "Find it, focus it". Curated neutral agent output
// only; no usage banners, modes, or personal paths.
import type { ChapterStepId } from "../../../chapters/chapter-ids";
import type {
  KitCommandBarModel,
  KitPaneFooterModel,
  KitTerminalLine,
  KitToolbarModel,
} from "../../../recreation-kit/recreation-kit-model";

export const findAndFocusParts = {
  arrangementZoom: "arrangement-zoom",
  commandBar: "command-bar",
  commandPlaceholder: "command-placeholder",
  commandQuery: "command-query",
  commandShortcut: "command-shortcut",
  recentSection: "recent-repositories",
  panesSection: "pane-results",
  worktreesSection: "worktree-results",
  targetPane: "target-pane",
  targetTerminal: "target-terminal",
  targetFocusRing: "target-focus-ring",
  targetZoomedChip: "target-zoomed-chip",
} as const;

/** The element that carries each beat's point; tests require it visible soon after the label. */
export const chapterFindAndFocusStepKeyParts = {
  "quick-find": findAndFocusParts.commandBar,
  "pane-zoom": findAndFocusParts.targetZoomedChip,
} as const satisfies Partial<Record<ChapterStepId, string>>;

export const findAndFocusAccessibleLabel =
  "Recreated Agent Studio window. The command bar finds a pane by name, then Pane Zoom gives that pane the whole workspace while the agent keeps working.";

export const findAndFocusToolbar: KitToolbarModel = {
  arrangementLabel: "1 · Layout 1",
  arrangementSuffix: "Zoom",
  tabs: [
    { title: "parallel work", shortcutNumber: 1, selected: true },
    { title: "docs pass", shortcutNumber: 2, selected: false },
    { title: "agent-studio · main", shortcutNumber: 3, selected: false },
  ],
  tabCount: 3,
};

export const findAndFocusCommandBar: KitCommandBarModel = {
  placeholder: "Search or jump to...",
  query: "tool",
  contextLabel: "sidebar-filter",
  shortcutHint: "⌘P",
  sections: [
    {
      title: "RECENT REPOSITORIES",
      settledPresence: "collapsed",
      scenePart: findAndFocusParts.recentSection,
      rows: [
        {
          icon: "folder",
          label: "agent-studio",
          meta: "3 worktrees · 2 open",
          selected: true,
          settledPresence: "shown",
        },
        {
          icon: "folder",
          label: "agent-vm",
          meta: "2 worktrees · 1 open",
          selected: false,
          settledPresence: "shown",
        },
      ],
    },
    {
      title: "PANES",
      settledPresence: "shown",
      scenePart: findAndFocusParts.panesSection,
      rows: [
        {
          icon: "terminal",
          label: "Terminal — tool-portal",
          subtitle: "parallel work · Tab 1 · Pane 2 · Active",
          selected: true,
          settledPresence: "shown",
        },
      ],
    },
    {
      title: "WORKTREES",
      settledPresence: "shown",
      scenePart: findAndFocusParts.worktreesSection,
      rows: [
        {
          icon: "worktree",
          label: "agent-vm.tool-portal",
          meta: "tool-portal",
          selected: false,
          settledPresence: "shown",
        },
      ],
    },
  ],
  scopeHints: ["> cmd", "$ pane", "# repo"],
  closeHint: "esc Close",
  actionHints: [
    { icon: "return", label: "Open" },
    { icon: "arrow-right", label: "Drill in" },
  ],
};

export const findAndFocusLeftTerminal: readonly KitTerminalLine[] = [
  {
    kind: "shell-prompt",
    worktreeName: "agent-studio.sidebar-filter",
    branchName: "sidebar-filter",
    command: "agent",
  },
  { kind: "blank" },
  { kind: "user-message", text: "Filter repos and worktrees." },
  { kind: "blank" },
  { kind: "agent-message", text: "Ready for review." },
  { kind: "agent-input" },
];

export const findAndFocusTargetTerminal: readonly KitTerminalLine[] = [
  {
    kind: "shell-prompt",
    worktreeName: "agent-vm.tool-portal",
    branchName: "tool-portal",
    command: "agent",
  },
  { kind: "blank" },
  { kind: "user-message", text: "Route leases via the controller." },
  { kind: "blank" },
  { kind: "agent-activity", text: "Reading src/lease.ts" },
  { kind: "agent-message", text: "Leases now use the controller." },
  { kind: "agent-message", text: "Updated the lease tests." },
  { kind: "agent-activity", text: "Ran the lease tests" },
  { kind: "agent-message", text: "Ready for review." },
  { kind: "agent-input" },
];

/** Target lines the agent writes after the pane is zoomed. */
export const findAndFocusTargetLateLineIndexes = [6, 7, 8] as const;

export const findAndFocusRightTerminal: readonly KitTerminalLine[] = [
  {
    kind: "shell-prompt",
    worktreeName: "agent-studio.docs-pass",
    branchName: "docs-pass",
    command: "agent",
  },
  { kind: "blank" },
  { kind: "user-message", text: "Tighten the README install steps." },
  { kind: "blank" },
  { kind: "agent-activity", text: "Reading README.md" },
  { kind: "agent-message", text: "Shortened the install section." },
  { kind: "agent-input" },
];

export const findAndFocusLeftFooter: KitPaneFooterModel = {
  badges: [{ kind: "diff", added: 37, removed: 6 }],
  zoomed: false,
};

export const findAndFocusTargetFooter: KitPaneFooterModel = {
  badges: [{ kind: "diff", added: 42, removed: 7 }],
  zoomed: true,
};

export const findAndFocusRightFooter: KitPaneFooterModel = {
  badges: [{ kind: "diff", added: 12, removed: 9 }],
  zoomed: false,
};
