import type { SceneBuildOptions, SceneModule, SceneTimeline } from "../../scene-contract";
import {
  requireLine,
  requireScenePart,
  requireTerminalLines,
  SceneTimelineBuilder,
} from "../scene-timeline-builder";
import { comeBackParts } from "./chapter-come-back-fixture";

const totalDurationSeconds = 8;

function buildComeBackScene(
  root: HTMLElement,
  timeline: SceneTimeline,
  options: SceneBuildOptions,
): void {
  const leftLines = requireTerminalLines(
    requireScenePart(root, comeBackParts.leftTerminal),
    comeBackParts.leftTerminal,
    7,
  );
  const rightLines = requireTerminalLines(
    requireScenePart(root, comeBackParts.rightTerminal),
    comeBackParts.rightTerminal,
    7,
  );
  const processCounter = requireScenePart(root, comeBackParts.processCounter);
  const builder = new SceneTimelineBuilder(timeline, options.seed);

  builder.label("quit-in-flight", 0);
  builder.reveal(requireLine(leftLines, 4), 0.15, { duration: 0.2 });
  builder.reveal(requireLine(rightLines, 4), 0.3, { duration: 0.2 });

  const processTime = { elapsed: 0 };
  timeline.set(processCounter, { textContent: "process uptime 00:12" }, 0);
  timeline.to(
    processTime,
    {
      elapsed: 4,
      duration: 3.2,
      ease: "none",
      onUpdate: () => {
        processCounter.textContent = `process uptime 00:${String(12 + Math.floor(processTime.elapsed)).padStart(2, "0")}`;
      },
    },
    0.2,
  );
  // The application leaves, while the counter's timeline continues beneath it.
  timeline.fromTo(
    root,
    { scale: 1, opacity: 1 },
    { scale: 0.86, opacity: 0, duration: 0.45, ease: "power2.in" },
    1.35,
  );
  builder.label("persistence", 2.15);
  timeline.to(root, { scale: 1, opacity: 1, duration: 0.5, ease: "back.out(1.4)" }, 2.15);
  builder.holdUntil(totalDurationSeconds);
}

export const chapterComeBackScene: SceneModule = {
  sceneId: "chapter-come-back",
  steps: [
    { stepId: "quit-in-flight", timelineLabel: "quit-in-flight" },
    { stepId: "persistence", timelineLabel: "persistence" },
  ],
  buildScene: buildComeBackScene,
};
