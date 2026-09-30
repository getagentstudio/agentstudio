import type { SceneBuildOptions, SceneModule, SceneTimeline } from "../../scene-contract";
import {
  requireScenePart,
  ScenePartMissingError,
  SceneTimelineBuilder,
} from "../scene-timeline-builder";
import { reviewParts } from "./chapter-review-fixture";

const totalDurationSeconds = 8;

function buildReviewScene(
  root: HTMLElement,
  timeline: SceneTimeline,
  options: SceneBuildOptions,
): void {
  const diffView = requireScenePart(root, reviewParts.diffView);
  const changedLine = requireScenePart(root, reviewParts.changedLine);
  const commentThread = requireScenePart(root, reviewParts.commentThread);
  const annotationSlot = commentThread.closest<HTMLElement>(".kit-diff-view__annotation");
  if (annotationSlot === null) throw new ScenePartMissingError("review annotation slot");
  const diffLines = [...diffView.querySelectorAll<HTMLElement>(".kit-diff-view__line")];
  if (diffLines.length < 5) throw new ScenePartMissingError("review diff lines");
  const builder = new SceneTimelineBuilder(timeline, options.seed);

  builder.label("review-diff", 0);
  for (const [lineIndex, line] of diffLines.entries()) {
    builder.reveal(line, 0.05 + lineIndex * 0.1, { duration: 0.16, fromX: -5 });
  }
  timeline.fromTo(
    changedLine,
    { boxShadow: "inset 0 0 0 1px rgb(137 180 250 / 0%)" },
    { boxShadow: "inset 0 0 0 1px rgb(137 180 250 / 80%)", duration: 0.35, ease: "power2.out" },
    1.1,
  );
  builder.expand(annotationSlot, 1.65, 0.4);
  builder.reveal(commentThread, 1.65, { duration: 0.4, ease: "power2.out" });
  builder.holdUntil(totalDurationSeconds);
}

export const chapterReviewScene: SceneModule = {
  sceneId: "chapter-review",
  steps: [{ stepId: "review-diff", timelineLabel: "review-diff" }],
  buildScene: buildReviewScene,
};
