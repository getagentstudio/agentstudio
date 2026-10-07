// Settled-frame content for "Context stays with the task". Curated neutral
// agent output and git lines only; no usage banners, modes, or personal paths.
import type { ChapterStepId } from "../../../chapters/chapter-ids";
import type {
  KitCodeToken,
  KitCodeTone,
  KitFileTreeRow,
  KitPaneFooterModel,
  KitSourceLine,
  KitSourceViewModel,
  KitTerminalLine,
  KitToolbarModel,
} from "../../../recreation-kit/recreation-kit-model";

export const contextWithTaskParts = {
  agentTerminal: "agent-terminal",
  agentFirstMessage: "agent-first-message",
  drawerLogPrompt: "drawer-log-prompt",
  drawer: "task-drawer",
  drawerTerminal: "drawer-terminal",
  footerBadges: "agent-footer-badges",
  filesPanel: "files-panel",
  sourceView: "source-view",
  sourceLinePrefix: "source-line",
  fileTree: "file-tree",
  fileTreeRowPrefix: "tree-row",
} as const;

/** The element that carries each beat's point; tests require it visible soon after the label. */
export const chapterContextWithTaskStepKeyParts = {
  "task-drawers": contextWithTaskParts.agentFirstMessage,
  "git-context": contextWithTaskParts.drawerLogPrompt,
  files: contextWithTaskParts.sourceView,
} as const satisfies Partial<Record<ChapterStepId, string>>;

export const contextWithTaskAccessibleLabel =
  "Recreated Agent Studio window. An agent pane keeps a Git drawer attached, shows its branch and pull request in that drawer, then opens the changed file in Files beside the task.";

export const contextWithTaskToolbar: KitToolbarModel = {
  arrangementLabel: "1 · Task",
  tabs: [
    { title: "tool-portal", shortcutNumber: 1, selected: true },
    { title: "sidebar-filter", shortcutNumber: 2, selected: false },
    { title: "agent-studio · main", shortcutNumber: 3, selected: false },
  ],
  tabCount: 3,
};

// Keep the drawer prompt compact at every stage; the branch label identifies the shell context.
const toolPortalWorktree = "";
const toolPortalBranch = "tool-portal";

export const contextWithTaskAgentTerminal: readonly KitTerminalLine[] = [
  {
    kind: "shell-prompt",
    worktreeName: toolPortalWorktree,
    branchName: toolPortalBranch,
    command: "agent",
  },
  // The phone crop shares the pane with the drawer, so spacing lines and the input row drop there.
  { kind: "blank", phoneRole: "hidden" },
  { kind: "user-message", text: "Route leases via the controller." },
  { kind: "blank", phoneRole: "hidden" },
  { kind: "agent-activity", text: "Reading src/lease.ts" },
  {
    kind: "agent-message",
    text: "Leases now use the controller.",
    scenePart: contextWithTaskParts.agentFirstMessage,
  },
  { kind: "agent-message", text: "Updated the lease tests." },
  { kind: "agent-input", phoneRole: "hidden" },
];

export const contextWithTaskDrawerTerminal: readonly KitTerminalLine[] = [
  {
    kind: "shell-prompt",
    worktreeName: toolPortalWorktree,
    branchName: toolPortalBranch,
    command: "git status -sb",
  },
  {
    kind: "output",
    segments: [
      { text: "## ", tone: "plain" },
      { text: "tool-portal", tone: "path" },
      { text: "...", tone: "plain" },
      { text: "origin/tool-portal", tone: "remote" },
      { text: " [ahead 2]", tone: "plain" },
    ],
  },
  {
    kind: "output",
    segments: [
      { text: " M ", tone: "hash" },
      { text: "src/lease.ts", tone: "plain" },
    ],
  },
  {
    kind: "output",
    segments: [
      { text: " M ", tone: "hash" },
      { text: "src/lease.test.ts", tone: "plain" },
    ],
  },
  {
    kind: "output",
    segments: [
      { text: "?? ", tone: "muted" },
      { text: "docs/tool-portal.md", tone: "plain" },
    ],
  },
  {
    kind: "shell-prompt",
    worktreeName: toolPortalWorktree,
    branchName: toolPortalBranch,
    command: "git log --oneline -2",
    scenePart: contextWithTaskParts.drawerLogPrompt,
  },
  {
    kind: "output",
    segments: [
      { text: "3f9c2a1 ", tone: "hash" },
      { text: "Route leases ", tone: "plain" },
      { text: "(#201)", tone: "reference" },
    ],
  },
  {
    kind: "output",
    segments: [
      { text: "8d41b07 ", tone: "hash" },
      { text: "Add the lease client", tone: "plain" },
    ],
  },
  { kind: "shell-prompt", worktreeName: toolPortalWorktree, branchName: toolPortalBranch },
];

/** Measured 330x412 settled overflow for the current wrapped drawer content. */
export const contextWithTaskPhoneDrawerScrollPixels = 88;

export const contextWithTaskAgentFooter: KitPaneFooterModel = {
  badges: [
    { kind: "diff", added: 42, removed: 7 },
    { kind: "sync", ahead: 2, behind: 0 },
  ],
  zoomed: false,
};

function codeLine(
  lineNumber: number,
  tokens: readonly (readonly [KitCodeTone, string])[],
): KitSourceLine {
  return {
    lineNumber,
    tokens: tokens.map(([tone, text]): KitCodeToken => ({ tone, text })),
  };
}

export const contextWithTaskSource: KitSourceViewModel = {
  filePath: "src/lease.ts",
  lines: [
    codeLine(1, [
      ["keyword", "import type "],
      ["punctuation", "{ "],
      ["type", "ControllerClient"],
      ["punctuation", " } "],
      ["keyword", "from "],
      ["string", '"./controller-client"'],
      ["punctuation", ";"],
    ]),
    codeLine(2, [
      ["keyword", "import type "],
      ["punctuation", "{ "],
      ["type", "ToolLease"],
      ["punctuation", ", "],
      ["type", "ToolLeaseRequest"],
      ["punctuation", " } "],
      ["keyword", "from "],
      ["string", '"./lease-types"'],
      ["punctuation", ";"],
    ]),
    codeLine(3, []),
    codeLine(4, [["comment", "// Requests a tool lease through the controller."]]),
    codeLine(5, [
      ["keyword", "export async function "],
      ["function", "requestToolLease"],
      ["punctuation", "("],
    ]),
    codeLine(6, [
      ["plain", "  controller"],
      ["punctuation", ": "],
      ["type", "ControllerClient"],
      ["punctuation", ","],
    ]),
    codeLine(7, [
      ["plain", "  request"],
      ["punctuation", ": "],
      ["type", "ToolLeaseRequest"],
      ["punctuation", ","],
    ]),
    codeLine(8, [
      ["punctuation", "): "],
      ["type", "Promise"],
      ["punctuation", "<"],
      ["type", "ToolLease"],
      ["punctuation", "> {"],
    ]),
    codeLine(9, [
      ["keyword", "  const "],
      ["plain", "lease "],
      ["punctuation", "= "],
      ["keyword", "await "],
      ["plain", "controller."],
      ["function", "createLease"],
      ["punctuation", "("],
      ["plain", "request"],
      ["punctuation", ");"],
    ]),
    codeLine(10, [
      ["keyword", "  return "],
      ["punctuation", "{ "],
      ["plain", "id"],
      ["punctuation", ": "],
      ["plain", "lease.id"],
      ["punctuation", ", "],
      ["plain", "expiresAt"],
      ["punctuation", ": "],
      ["plain", "lease.expiresAt"],
      ["punctuation", " };"],
    ]),
    codeLine(11, [["punctuation", "}"]]),
  ],
};

function treeRowPart(rowIndex: number): string {
  return `${contextWithTaskParts.fileTreeRowPrefix}-${String(rowIndex)}`;
}

export const contextWithTaskFileTree: readonly KitFileTreeRow[] = [
  { depth: 0, kind: "folder", name: "src", scenePart: treeRowPart(0) },
  { depth: 1, kind: "typescript", name: "controller-client.ts", scenePart: treeRowPart(1) },
  { depth: 1, kind: "typescript", name: "lease.ts", selected: true, scenePart: treeRowPart(2) },
  { depth: 1, kind: "typescript", name: "lease.test.ts", scenePart: treeRowPart(3) },
  { depth: 1, kind: "typescript", name: "lease-types.ts", scenePart: treeRowPart(4) },
  { depth: 0, kind: "folder", name: "docs", expanded: false, scenePart: treeRowPart(5) },
  { depth: 0, kind: "markdown", name: "README.md", scenePart: treeRowPart(6) },
];
