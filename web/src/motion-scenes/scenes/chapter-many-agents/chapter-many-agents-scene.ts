import type { SceneBuildOptions, SceneModule, SceneTimeline } from "../../scene-contract";
import {
  requireLine,
  requireScenePart,
  requireTerminalLines,
  ScenePartMissingError,
  SceneTimelineBuilder,
} from "../scene-timeline-builder";
import { manyAgentsParts } from "./chapter-many-agents-fixture";

const totalDurationSeconds = 9;

function hasNonWhitespaceDirectText(element: HTMLElement): boolean {
  return Array.from(element.childNodes).some(
    (childNode) =>
      childNode.nodeType === Node.TEXT_NODE && (childNode.textContent ?? "").trim().length > 0,
  );
}

interface ManyAgentsElements {
  readonly leftTerminal: HTMLElement;
  readonly leftFooterBadges: HTMLElement;
  readonly leftOverlapTextElements: readonly HTMLElement[];
  readonly leftLines: readonly HTMLElement[];
  readonly rightLines: readonly HTMLElement[];
  readonly filterPlaceholder: HTMLElement;
  readonly filterQuery: HTMLElement;
  readonly filterClear: HTMLElement;
  readonly mainWorktree: HTMLElement;
  readonly agentVmRepo: HTMLElement;
  readonly agentVmWorktrees: readonly HTMLElement[];
}

// Every element is resolved before the first tween exists, so incomplete
// markup fails without leaving a half-animated frame behind.
function resolveManyAgentsElements(root: HTMLElement): ManyAgentsElements {
  const leftTerminal = requireScenePart(root, manyAgentsParts.leftTerminal);
  const leftFooterBadges = requireScenePart(
    root,
    manyAgentsParts.leftPane,
  ).querySelector<HTMLElement>(".kit-badges");
  if (leftFooterBadges === null) {
    throw new ScenePartMissingError("left pane footer badges");
  }
  return {
    leftTerminal,
    leftFooterBadges,
    leftOverlapTextElements: [...leftTerminal.querySelectorAll<HTMLElement>("*")].filter(
      hasNonWhitespaceDirectText,
    ),
    leftLines: requireTerminalLines(leftTerminal, manyAgentsParts.leftTerminal, 9),
    rightLines: requireTerminalLines(
      requireScenePart(root, manyAgentsParts.rightTerminal),
      manyAgentsParts.rightTerminal,
      9,
    ),
    filterPlaceholder: requireScenePart(root, manyAgentsParts.filterPlaceholder),
    filterQuery: requireScenePart(root, manyAgentsParts.filterQuery),
    filterClear: requireScenePart(root, manyAgentsParts.filterClear),
    mainWorktree: requireScenePart(root, manyAgentsParts.mainWorktree),
    agentVmRepo: requireScenePart(root, manyAgentsParts.agentVmRepo),
    agentVmWorktrees: [
      requireScenePart(root, manyAgentsParts.agentVmMainWorktree),
      requireScenePart(root, manyAgentsParts.agentVmToolPortalWorktree),
    ],
  };
}

function buildManyAgentsScene(
  root: HTMLElement,
  timeline: SceneTimeline,
  options: SceneBuildOptions,
): void {
  const elements = resolveManyAgentsElements(root);
  const builder = new SceneTimelineBuilder(timeline, options.seed);
  const groupingLabel = [...root.querySelectorAll<HTMLElement>(".kit-sidebar__ellipsis")].find(
    (label) => label.textContent === "agent-studio.sidebar-grouping",
  );
  if (groupingLabel === undefined) {
    throw new ScenePartMissingError("sidebar-grouping label");
  }
  groupingLabel.setAttribute("data-layout-allow-overflow", "");
  const left = (lineIndex: number): HTMLElement => requireLine(elements.leftLines, lineIndex);
  const right = (lineIndex: number): HTMLElement => requireLine(elements.rightLines, lineIndex);

  // Beat 1: both agents already hold their tasks (prompt and request are
  // static), and both start answering at once.
  builder.label("parallel-agents", 0);
  builder.reveal(left(4), 0.2, { duration: 0.15 });
  builder.reveal(right(4), 0.25, { duration: 0.15 });
  builder.showAndTypeLine(left(5), 0.4, 80);
  builder.showAndTypeLine(right(5), 0.55, 80);
  builder.showAndTypeLine(left(6), 1.1, 80);
  builder.showAndTypeLine(right(6), 1.35, 80);
  builder.reveal(left(7), 1.9, { duration: 0.15 });
  builder.reveal(right(7), 2.1, { duration: 0.15 });

  // Beat 2: the watched folder fills the sidebar with every repo and worktree.
  // The phone crop slides the sidebar over the pane for this beat and the next.
  builder.label("watch-folders", 2.8);
  // Only the phone sidebar covers the visible left pane, and it stays to the end.
  if (options.width <= 600) {
    const sidebarOpenAt = 2.8;
    for (const coveredContainer of [elements.leftTerminal, elements.leftFooterBadges]) {
      timeline.set(
        coveredContainer,
        {
          attr: { "data-layout-allow-occlusion": "" },
          onReverseComplete: () => coveredContainer.removeAttribute("data-layout-allow-occlusion"),
        },
        sidebarOpenAt,
      );
    }
    for (const terminalTextElement of elements.leftOverlapTextElements) {
      timeline.set(
        terminalTextElement,
        {
          attr: { "data-layout-allow-overlap": "" },
          onReverseComplete: () => terminalTextElement.removeAttribute("data-layout-allow-overlap"),
        },
        sidebarOpenAt,
      );
    }
  }
  builder.variable(root, {
    name: "--scene-sidebar-focus",
    from: 0,
    to: 1,
    at: 2.8,
    duration: 0.35,
  });
  builder.expand(elements.mainWorktree, 2.9, 0.35);
  builder.expand(elements.agentVmRepo, 3.0, 0.4);
  elements.agentVmWorktrees.forEach((worktree, offset) => {
    builder.reveal(worktree, 3.3 + offset * 0.25, { duration: 0.25, fromX: -8 });
  });

  // Beat 3: a filter narrows the sidebar to the worktrees that match.
  builder.label("navigation", 4.6);
  builder.conceal(elements.filterPlaceholder, 4.65, { duration: 0.1 });
  const typedQueryEnd = builder.type(elements.filterQuery, 4.7, builder.vary(10, 0.1));
  builder.reveal(elements.filterClear, typedQueryEnd + 0.05, { duration: 0.2 });
  builder.collapse(elements.mainWorktree, typedQueryEnd + 0.2, 0.35);
  builder.collapse(elements.agentVmRepo, typedQueryEnd + 0.25, 0.4);
  // Both agents finish while the map narrows.
  builder.showAndTypeLine(left(8), 6.1, 60);
  builder.showAndTypeLine(right(8), 6.5, 60);

  builder.holdUntil(totalDurationSeconds);
}

export const chapterManyAgentsScene: SceneModule = {
  sceneId: "chapter-many-agents",
  steps: [
    { stepId: "parallel-agents", timelineLabel: "parallel-agents" },
    { stepId: "watch-folders", timelineLabel: "watch-folders" },
    { stepId: "navigation", timelineLabel: "navigation" },
  ],
  buildScene: buildManyAgentsScene,
};
