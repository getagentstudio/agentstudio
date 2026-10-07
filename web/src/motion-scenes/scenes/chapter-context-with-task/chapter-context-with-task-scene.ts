import { recreationKitPhoneMaxWidthPx } from "../../../recreation-kit/recreation-kit-phone-breakpoint";
import type { SceneBuildOptions, SceneModule, SceneTimeline } from "../../scene-contract";
import { scheduleLayoutWaiver } from "../layout-waivers";
import { collectSceneTextLeaves } from "../scene-text-leaves";
import {
  requireLine,
  requireScenePart,
  requireTerminalLines,
  SceneTimelineBuilder,
  ScenePartMissingError,
} from "../scene-timeline-builder";
import {
  contextWithTaskFileTree,
  contextWithTaskParts,
  contextWithTaskSource,
} from "./chapter-context-with-task-fixture";

const totalDurationSeconds = 8.5;

interface ContextWithTaskElements {
  readonly agentTerminal: HTMLElement;
  readonly drawerTerminal: HTMLElement;
  readonly terminalOverlapTextElements: readonly HTMLElement[];
  readonly agentLines: readonly HTMLElement[];
  readonly drawer: HTMLElement;
  readonly drawerLines: readonly HTMLElement[];
  readonly footerBadges: HTMLElement;
  readonly sourceView: HTMLElement;
  readonly sourceCode: HTMLElement;
  readonly sourceLines: readonly HTMLElement[];
  readonly fileTree: HTMLElement;
  readonly fileTreeRows: readonly HTMLElement[];
}

function resolveContextWithTaskElements(root: HTMLElement): ContextWithTaskElements {
  const sourceView = requireScenePart(root, contextWithTaskParts.sourceView);
  const sourceCode = sourceView.querySelector<HTMLElement>(".kit-source-view__code");
  if (sourceCode === null) {
    throw new ScenePartMissingError("source code area");
  }
  const agentTerminal = requireScenePart(root, contextWithTaskParts.agentTerminal);
  const drawerTerminal = requireScenePart(root, contextWithTaskParts.drawerTerminal);
  return {
    agentTerminal,
    drawerTerminal,
    terminalOverlapTextElements: [agentTerminal, drawerTerminal].flatMap(collectSceneTextLeaves),
    agentLines: requireTerminalLines(agentTerminal, contextWithTaskParts.agentTerminal, 7),
    drawer: requireScenePart(root, contextWithTaskParts.drawer),
    drawerLines: requireTerminalLines(drawerTerminal, contextWithTaskParts.drawerTerminal, 9),
    footerBadges: requireScenePart(root, contextWithTaskParts.footerBadges),
    sourceView,
    sourceCode,
    sourceLines: contextWithTaskSource.lines.map((_line, lineIndex) =>
      requireScenePart(root, `${contextWithTaskParts.sourceLinePrefix}-${String(lineIndex)}`),
    ),
    fileTree: requireScenePart(root, contextWithTaskParts.fileTree),
    fileTreeRows: contextWithTaskFileTree.map((_row, rowIndex) =>
      requireScenePart(root, `${contextWithTaskParts.fileTreeRowPrefix}-${String(rowIndex)}`),
    ),
  };
}

function buildContextWithTaskScene(
  root: HTMLElement,
  timeline: SceneTimeline,
  options: SceneBuildOptions,
): void {
  const elements = resolveContextWithTaskElements(root);
  // Measure the settled content before entrance transforms or typing clips render.
  // The phone crop keeps newest output at the bottom; desktop retains its static layout.
  const drawerOverflowPixels =
    options.width <= recreationKitPhoneMaxWidthPx
      ? Math.max(0, elements.drawerTerminal.scrollHeight - elements.drawerTerminal.clientHeight)
      : 0;
  const builder = new SceneTimelineBuilder(timeline, options.seed);
  const agent = (lineIndex: number): HTMLElement => requireLine(elements.agentLines, lineIndex);
  const drawer = (lineIndex: number): HTMLElement => requireLine(elements.drawerLines, lineIndex);

  // Beat 1: the task is already on screen (prompt and request are static) and
  // the agent answers at once; a Git terminal rises in the drawer it owns.
  builder.label("task-drawers", 0);
  builder.reveal(agent(4), 0.05, { duration: 0.12 });
  builder.showAndTypeLine(agent(5), 0.15, 90);
  builder.showAndTypeLine(agent(6), 0.7, 90);
  builder.reveal(elements.drawer, 1.0, { duration: 0.5, fromYPercent: 100, ease: "power3.out" });
  const statusTyped = builder.showAndTypeLine(drawer(0), 1.55, 30);
  [1, 2, 3, 4].forEach((lineIndex, offset) => {
    builder.reveal(drawer(lineIndex), statusTyped + 0.08 + offset * 0.1, { duration: 0.12 });
  });

  // Beat 2: branch status and the pull request print beside the task.
  builder.label("git-context", 3.0);
  builder.reveal(elements.footerBadges, 3.0, { duration: 0.3, fromY: 4 });
  builder.variable(root, {
    name: "--scene-drawer-scroll",
    from: 0,
    to: drawerOverflowPixels,
    at: 3.0,
    duration: 0.35,
  });
  const logTyped = builder.showAndTypeLine(drawer(5), 3.05, 40);
  builder.reveal(drawer(6), logTyped + 0.1, { duration: 0.15 });
  builder.reveal(drawer(7), logTyped + 0.25, { duration: 0.15 });
  builder.reveal(drawer(8), logTyped + 0.4, { duration: 0.05 });

  // Beat 3: Files opens the changed source beside the same task.
  builder.label("files", 5.0);
  // The phone source view takes over the task and drawer through scene end.
  // Desktop keeps them beside Files; drawer command lines wrap at their edge.
  const sourceOpenAt = 5.05;
  if (options.width <= recreationKitPhoneMaxWidthPx) {
    scheduleLayoutWaiver({
      timeline,
      elements: [elements.agentTerminal, elements.drawerTerminal, elements.footerBadges],
      attribute: "data-layout-allow-occlusion",
      fromSeconds: sourceOpenAt,
    });
    scheduleLayoutWaiver({
      timeline,
      elements: elements.terminalOverlapTextElements,
      attribute: "data-layout-allow-overlap",
      fromSeconds: sourceOpenAt,
    });
  } else {
    // Like a real editor, long lines extend horizontally beyond the code viewport.
    // CSS clips those pixels; the audit still measures their full span rectangles.
    scheduleLayoutWaiver({
      timeline,
      elements: [elements.sourceCode],
      attribute: "data-layout-allow-occlusion",
      fromSeconds: sourceOpenAt,
    });
  }
  builder.variable(root, {
    name: "--scene-files-reveal",
    from: 0,
    to: 1,
    at: 5.0,
    duration: 0.55,
  });
  builder.reveal(elements.sourceView, 5.05, { duration: 0.25 });
  builder.reveal(elements.fileTree, 5.1, { duration: 0.25 });
  elements.fileTreeRows.forEach((row, rowIndex) => {
    builder.reveal(row, 5.3 + rowIndex * 0.06, { duration: 0.2, fromX: -6 });
  });
  elements.sourceLines.forEach((line, lineIndex) => {
    builder.reveal(line, 5.3 + lineIndex * 0.045, { duration: 0.2, fromX: -6 });
  });

  builder.holdUntil(totalDurationSeconds);
}

export const chapterContextWithTaskScene: SceneModule = {
  sceneId: "chapter-context-with-task",
  steps: [
    { stepId: "task-drawers", timelineLabel: "task-drawers" },
    { stepId: "git-context", timelineLabel: "git-context" },
    { stepId: "files", timelineLabel: "files" },
  ],
  buildScene: buildContextWithTaskScene,
};
