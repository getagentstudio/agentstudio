import type { ChapterStepId } from "../../../chapters/chapter-ids";
import type {
  KitDiffViewModel,
  KitFileTreeRow,
  KitPaneFooterModel,
  KitToolbarModel,
} from "../../../recreation-kit/recreation-kit-model";

export const reviewParts = {
  diffView: "review-diff-view",
  changedLine: "review-changed-line",
  commentThread: "review-comment-thread",
} as const;

export const chapterReviewStepKeyParts = {
  "review-diff": reviewParts.changedLine,
  "review-comment": reviewParts.commentThread,
} as const satisfies Partial<Record<ChapterStepId, string>>;

export const reviewAccessibleLabel =
  "Recreated Agent Studio review. Diff lines appear, a changed line is highlighted, and a Markdown review comment opens beside it.";

export const reviewToolbar: KitToolbarModel = {
  arrangementLabel: "4 · Review",
  tabs: [
    { title: "skills changes", shortcutNumber: 1, selected: true },
    { title: "codex", shortcutNumber: 2, selected: false },
  ],
  tabCount: 2,
};

export const reviewDiff: KitDiffViewModel = {
  fileName: "AGENTS.md",
  added: 3,
  removed: 2,
  lines: [
    { kind: "collapsed", label: "45 unchanged lines" },
    { kind: "context", lineNumber: 47, text: "| Path | Role |" },
    { kind: "removed", lineNumber: 48, text: "| docs/repo-index/ | Local notes |" },
    { kind: "added", lineNumber: 48, text: "| docs/repo-index/ | Source pins and scope |" },
    {
      kind: "added",
      lineNumber: 49,
      text: "| docs/repo-index-changelog/ | Dated comparisons |",
      scenePart: reviewParts.changedLine,
    },
    { kind: "context", lineNumber: 50, text: "| CHANGELOG.md | Release history |" },
    { kind: "collapsed", label: "54 unchanged lines" },
  ],
};

export const reviewFiles: readonly KitFileTreeRow[] = [
  { kind: "folder", name: "docs", depth: 0, expanded: true },
  { kind: "folder", name: "repo-index", depth: 1, expanded: true },
  { kind: "markdown", name: "current.md", depth: 2 },
  { kind: "folder", name: "repo-index-changelog", depth: 1, expanded: true },
  { kind: "markdown", name: "2026-09-26.md", depth: 2, selected: true },
  { kind: "markdown", name: "AGENTS.md", depth: 0 },
];

export const reviewFooter: KitPaneFooterModel = {
  badges: [{ kind: "diff", added: 3, removed: 2 }],
  zoomed: false,
};
