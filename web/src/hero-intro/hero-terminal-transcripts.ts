export type TranscriptTier = "full" | "compact" | "phone";

type TranscriptRowKind =
  | "blank"
  | "user-band"
  | "assistant-text"
  | "tool-call"
  | "tool-result"
  | "diff-removed"
  | "diff-added"
  | "codex-action"
  | "codex-detail"
  | "codex-prose";

export type TranscriptRow = {
  readonly kind: TranscriptRowKind;
  readonly text: string;
  readonly tiers: readonly TranscriptTier[];
  readonly beat?: "progress" | "working" | "prompt" | "running" | "command" | "worktree" | "result";
  readonly earlierContext?: true;
};

const allTiers = ["full", "compact", "phone"] as const;
const desktopTiers = ["full", "compact"] as const;

export const claudePreludeTranscript: readonly TranscriptRow[] = [
  { kind: "blank", text: "", tiers: ["full"] },
  {
    kind: "user-band",
    text: "› inspect sidebar filter ordering",
    tiers: ["full", "phone"],
    earlierContext: true,
  },
  {
    kind: "assistant-text",
    text: "● I'll check the current sort.",
    tiers: ["full", "phone"],
    earlierContext: true,
  },
  {
    kind: "tool-call",
    text: "● Search(src/sidebar/filter.ts)",
    tiers: ["full", "phone"],
    earlierContext: true,
  },
  {
    kind: "tool-result",
    text: "  ⎿ Found the pinned-row comparator",
    tiers: ["full", "phone"],
    earlierContext: true,
  },
  {
    kind: "tool-call",
    text: "● Read(src/sidebar/filter.ts)",
    tiers: ["full", "phone"],
    earlierContext: true,
  },
  {
    kind: "tool-result",
    text: "  ⎿ Pinned rows sort after matches",
    tiers: ["full", "phone"],
    earlierContext: true,
  },
  {
    kind: "assistant-text",
    text: "● I'll put pinned rows first.",
    tiers: ["full", "phone"],
    earlierContext: true,
  },
  {
    kind: "user-band",
    text: "› fix the sidebar filter ordering",
    tiers: ["full", "phone"],
    earlierContext: true,
  },
  {
    kind: "tool-call",
    text: "● Update(src/sidebar/filter.ts)",
    tiers: ["full", "phone"],
    earlierContext: true,
  },
  {
    kind: "tool-result",
    text: "  ⎿ Added 8 lines, removed 3 lines",
    tiers: ["full", "phone"],
    earlierContext: true,
  },
  { kind: "diff-removed", text: "45 - if (!query) return rows;", tiers: ["full"] },
  {
    kind: "diff-added",
    text: "45 + if (!query) return pinnedFirst(rows);",
    tiers: ["full"],
  },
  { kind: "blank", text: "", tiers: ["full"] },
];

export const codexTranscript: readonly TranscriptRow[] = [
  { kind: "blank", text: "", tiers: desktopTiers },
  { kind: "user-band", text: "› route leases through the controller", tiers: desktopTiers },
  { kind: "blank", text: "", tiers: ["full"] },
  { kind: "codex-action", text: "• Explored", tiers: ["full"] },
  { kind: "codex-detail", text: "  └ Read src/lease.ts", tiers: ["full"] },
  { kind: "blank", text: "", tiers: ["full"] },
  { kind: "codex-action", text: "• Ran", tiers: desktopTiers },
  { kind: "codex-detail", text: "  └ pnpm test lease", tiers: desktopTiers },
  { kind: "codex-detail", text: "  └ 14 passed · 0 failed · 3.1s", tiers: desktopTiers },
  { kind: "blank", text: "", tiers: desktopTiers },
  {
    kind: "codex-prose",
    text: "• Leases now route through the controller client.",
    tiers: desktopTiers,
  },
];

// The agents independently act in one workspace; this is not a cross-pane handoff.
export const codexFinaleTranscript: readonly TranscriptRow[] = [
  { kind: "user-band", text: "› map the worktrees", tiers: desktopTiers },
  {
    kind: "codex-action",
    text: "• Working (2s • esc to interrupt)",
    tiers: desktopTiers,
    beat: "working",
  },
  { kind: "codex-action", text: "• Ran", tiers: desktopTiers, beat: "running" },
  { kind: "codex-detail", text: "  └ git worktree list", tiers: desktopTiers, beat: "command" },
  { kind: "codex-detail", text: "  └ ~/agent-studio  main", tiers: desktopTiers, beat: "worktree" },
  {
    kind: "codex-detail",
    text: "  └ ~/agent-studio.drawer  drawer-improvements",
    tiers: desktopTiers,
    beat: "worktree",
  },
  {
    kind: "codex-detail",
    text: "  └ ~/agent-studio.review  review-comments",
    tiers: desktopTiers,
    beat: "worktree",
  },
  {
    kind: "codex-detail",
    text: "  └ 3 worktrees · 5 branches",
    tiers: desktopTiers,
    beat: "result",
  },
];

export const claudeFinaleTranscript: readonly TranscriptRow[] = [
  { kind: "user-band", text: "› set up Agent Studio for me", tiers: allTiers },
  { kind: "assistant-text", text: "● I'll install it with Homebrew.", tiers: allTiers },
  {
    kind: "tool-call",
    text: "● Bash(brew tap getagentstudio/agentstudio && brew install --cask agent-studio)",
    tiers: desktopTiers,
  },
  { kind: "tool-call", text: "● Bash(brew install --cask agent-studio)", tiers: ["phone"] },
  {
    kind: "tool-result",
    text: "  ⎿ ==> Tapping getagentstudio/agentstudio",
    tiers: desktopTiers,
    beat: "progress",
  },
  {
    kind: "tool-result",
    text: "     ==> Downloading agent-studio",
    tiers: desktopTiers,
    beat: "progress",
  },
  {
    kind: "tool-result",
    text: "     ==> Installing Cask agent-studio",
    tiers: desktopTiers,
    beat: "progress",
  },
  { kind: "tool-result", text: "  ⎿ Installing agent-studio", tiers: ["phone"], beat: "progress" },
  { kind: "tool-result", text: "  ⎿ ✓ Ready. Copy it below ↓", tiers: allTiers },
  { kind: "user-band", text: "› map the worktrees", tiers: allTiers, beat: "prompt" },
  { kind: "tool-result", text: "  ⎿ Ran", tiers: allTiers, beat: "working" },
  { kind: "tool-result", text: "  ⎿ git worktree list", tiers: allTiers, beat: "command" },
  {
    kind: "tool-result",
    text: "  ⎿ ~/agent-studio          main",
    tiers: desktopTiers,
    beat: "worktree",
  },
  { kind: "tool-result", text: "  ⎿ ~/agent-studio  main", tiers: ["phone"], beat: "worktree" },
  {
    kind: "tool-result",
    text: "  ⎿ ~/agent-studio.drawer   drawer-improvements",
    tiers: desktopTiers,
    beat: "worktree",
  },
  {
    kind: "tool-result",
    text: "  ⎿ ~/agent-studio.drawer  drawer",
    tiers: ["phone"],
    beat: "worktree",
  },
  {
    kind: "tool-result",
    text: "  ⎿ ~/agent-studio.review   review-comments",
    tiers: desktopTiers,
    beat: "worktree",
  },
  {
    kind: "tool-result",
    text: "  ⎿ ~/agent-studio.review  review",
    tiers: ["phone"],
    beat: "worktree",
  },
  { kind: "tool-result", text: "  ⎿ 3 worktrees · 5 branches", tiers: allTiers, beat: "result" },
];
