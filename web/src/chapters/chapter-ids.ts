// The chapter and step id vocabularies on their own, with no copy or image
// imports, so client controllers can validate ids read from the DOM without
// pulling the chapter catalog into the browser bundle.

export const chapterIds = [
  "proof",
  "many-agents",
  "context-with-task",
  "find-and-focus",
  "review",
  "come-back",
] as const;

export type ChapterId = (typeof chapterIds)[number];

export const chapterStepIds = [
  "proof-run",
  "proof-review",
  "proof-panes",
  "parallel-agents",
  "watch-folders",
  "navigation",
  "task-drawers",
  "git-context",
  "files",
  "quick-find",
  "pane-zoom",
  "review-diff",
  "review-comment",
  "quit-in-flight",
  "persistence",
] as const;

export type ChapterStepId = (typeof chapterStepIds)[number];

export function isChapterStepId(value: string): value is ChapterStepId {
  return (chapterStepIds as readonly string[]).includes(value);
}
