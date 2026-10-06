import type { ChapterStepId } from "../../../chapters/chapter-ids";
import type {
  KitPaneFooterModel,
  KitTerminalLine,
  KitToolbarModel,
} from "../../../recreation-kit/recreation-kit-model";

export const comeBackParts = {
  leftTerminal: "come-back-left-terminal",
  rightTerminal: "come-back-right-terminal",
  processCounter: "come-back-process-counter",
} as const;

export const chapterComeBackStepKeyParts = {
  "quit-in-flight": comeBackParts.processCounter,
  persistence: comeBackParts.processCounter,
} as const satisfies Partial<Record<ChapterStepId, string>>;

export const comeBackAccessibleLabel =
  "Recreated Agent Studio window. Two agent panes keep running while the app closes and reopens with the same sessions.";

export const comeBackToolbar: KitToolbarModel = {
  arrangementLabel: "3 · Sessions",
  tabs: [
    { title: "agent-studio · main", shortcutNumber: 1, selected: true },
    { title: "agent-vm · fix", shortcutNumber: 2, selected: false },
  ],
  tabCount: 2,
};

export const comeBackLeftTerminal: readonly KitTerminalLine[] = [
  { kind: "shell-prompt", worktreeName: "agent-studio", branchName: "main", command: "agent" },
  { kind: "blank" },
  { kind: "user-message", text: "Keep the UI session alive." },
  { kind: "agent-activity", text: "Watching the build" },
  { kind: "agent-message", text: "The session is still running." },
  { kind: "output", segments: [{ text: "✓ build watcher active", tone: "added" }] },
  { kind: "agent-input" },
];

export const comeBackRightTerminal: readonly KitTerminalLine[] = [
  { kind: "shell-prompt", worktreeName: "agent-vm", branchName: "fix", command: "agent" },
  { kind: "blank" },
  { kind: "user-message", text: "Keep the worker running." },
  { kind: "agent-activity", text: "Indexing workspace" },
  { kind: "agent-message", text: "Work continues while you're away." },
  { kind: "output", segments: [{ text: "✓ worker process active", tone: "added" }] },
  { kind: "agent-input" },
];

export const comeBackFooter: KitPaneFooterModel = { badges: [], zoomed: false };
