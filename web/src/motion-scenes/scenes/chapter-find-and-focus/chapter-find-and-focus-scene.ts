import type { SceneBuildOptions, SceneModule, SceneTimeline } from "../../scene-contract";
import {
  requireLine,
  requireScenePart,
  requireTerminalLines,
  ScenePartMissingError,
  SceneTimelineBuilder,
} from "../scene-timeline-builder";
import {
  findAndFocusParts,
  findAndFocusTargetLateLineIndexes,
} from "./chapter-find-and-focus-fixture";

const totalDurationSeconds = 8;

function hasNonWhitespaceDirectText(element: HTMLElement): boolean {
  return Array.from(element.childNodes).some(
    (childNode) =>
      childNode.nodeType === Node.TEXT_NODE && (childNode.textContent ?? "").trim().length > 0,
  );
}

interface FindAndFocusElements {
  readonly arrangementZoom: HTMLElement;
  readonly commandBar: HTMLElement;
  readonly commandPlaceholder: HTMLElement;
  readonly commandQuery: HTMLElement;
  readonly recentSection: HTMLElement;
  readonly panesSection: HTMLElement;
  readonly worktreesSection: HTMLElement;
  readonly targetLines: readonly HTMLElement[];
  readonly paneTextContainers: readonly HTMLElement[];
  readonly paneOverlapTextElements: readonly HTMLElement[];
  readonly rightPaneCoveredText: HTMLElement;
  readonly targetFocusRing: HTMLElement;
  readonly targetZoomedChip: HTMLElement;
}

function resolveFindAndFocusElements(root: HTMLElement): FindAndFocusElements {
  const rightPaneCoveredText = root.querySelector<HTMLElement>(
    '.kit-pane-grid > .kit-pane:last-child [data-line="5"] [data-kit-typed]',
  );
  if (rightPaneCoveredText === null) {
    throw new ScenePartMissingError("right pane covered text");
  }
  return {
    arrangementZoom: requireScenePart(root, findAndFocusParts.arrangementZoom),
    commandBar: requireScenePart(root, findAndFocusParts.commandBar),
    commandPlaceholder: requireScenePart(root, findAndFocusParts.commandPlaceholder),
    commandQuery: requireScenePart(root, findAndFocusParts.commandQuery),
    recentSection: requireScenePart(root, findAndFocusParts.recentSection),
    panesSection: requireScenePart(root, findAndFocusParts.panesSection),
    worktreesSection: requireScenePart(root, findAndFocusParts.worktreesSection),
    targetLines: requireTerminalLines(
      requireScenePart(root, findAndFocusParts.targetTerminal),
      findAndFocusParts.targetTerminal,
      9,
    ),
    paneTextContainers: [...root.querySelectorAll<HTMLElement>(".kit-pane-grid .kit-terminal")],
    paneOverlapTextElements: [
      ...root.querySelectorAll<HTMLElement>(".kit-pane-grid .kit-terminal *"),
    ].filter((element) => element !== rightPaneCoveredText && hasNonWhitespaceDirectText(element)),
    rightPaneCoveredText,
    targetFocusRing: requireScenePart(root, findAndFocusParts.targetFocusRing),
    targetZoomedChip: requireScenePart(root, findAndFocusParts.targetZoomedChip),
  };
}

function buildFindAndFocusScene(
  root: HTMLElement,
  timeline: SceneTimeline,
  options: SceneBuildOptions,
): void {
  const elements = resolveFindAndFocusElements(root);
  const builder = new SceneTimelineBuilder(timeline, options.seed);

  // Beat 1: Cmd+P opens the command bar, a short query finds the pane, Enter jumps to it.
  builder.label("quick-find", 0);
  // Let the pane entrance settle before the overlay crosses terminal text.
  const barOpenAt = 0.45;
  for (const paneTextContainer of elements.paneTextContainers) {
    timeline.set(paneTextContainer, { attr: { "data-layout-allow-occlusion": "" } }, barOpenAt);
  }
  for (const paneTextElement of elements.paneOverlapTextElements) {
    timeline.set(
      paneTextElement,
      {
        attr: { "data-layout-allow-overlap": "" },
        onReverseComplete: () => paneTextElement.removeAttribute("data-layout-allow-overlap"),
      },
      barOpenAt,
    );
  }
  timeline.set(
    elements.rightPaneCoveredText,
    { attr: { "data-layout-allow-overlap": "" } },
    barOpenAt,
  );
  builder.reveal(elements.commandBar, barOpenAt, { duration: 0.25, fromScale: 0.97, fromY: -8 });
  builder.conceal(elements.commandPlaceholder, 0.8, { duration: 0.1 });
  const queryTyped = builder.type(elements.commandQuery, 0.85, builder.vary(9, 0.1));
  // Empty-query recents leave before the first glyph; the selected match then holds for reading.
  builder.collapse(elements.recentSection, 0.85, 0);
  builder.expand(elements.panesSection, queryTyped, 0.3);
  builder.expand(elements.worktreesSection, queryTyped + 0.1, 0.3);
  const barClosed = builder.conceal(elements.commandBar, 2.8, { duration: 0.2 });
  for (const paneTextContainer of elements.paneTextContainers) {
    timeline.set(
      paneTextContainer,
      {
        onComplete: () => paneTextContainer.removeAttribute("data-layout-allow-occlusion"),
        onReverseComplete: () => paneTextContainer.setAttribute("data-layout-allow-occlusion", ""),
      },
      barClosed,
    );
  }
  for (const paneTextElement of elements.paneOverlapTextElements) {
    timeline.set(
      paneTextElement,
      {
        onComplete: () => paneTextElement.removeAttribute("data-layout-allow-overlap"),
        onReverseComplete: () => paneTextElement.setAttribute("data-layout-allow-overlap", ""),
      },
      barClosed,
    );
  }
  timeline.set(
    elements.rightPaneCoveredText,
    {
      onComplete: () => elements.rightPaneCoveredText.removeAttribute("data-layout-allow-overlap"),
      onReverseComplete: () =>
        elements.rightPaneCoveredText.setAttribute("data-layout-allow-overlap", ""),
    },
    barClosed,
  );
  builder.reveal(elements.targetFocusRing, barClosed + 0.05, { duration: 0.25 });

  // Beat 2: Pane Zoom gives the found pane the workspace; its agent keeps going.
  builder.label("pane-zoom", 3.2);
  const zoomed = builder.variable(root, {
    name: "--scene-zoom",
    from: 0,
    to: 1,
    at: 3.2,
    duration: 0.5,
  });
  builder.reveal(elements.arrangementZoom, 3.3, { duration: 0.25 });
  builder.reveal(elements.targetZoomedChip, 3.35, { duration: 0.25, fromY: 4 });
  findAndFocusTargetLateLineIndexes.forEach((lineIndex, offset) => {
    builder.showAndTypeLine(
      requireLine(elements.targetLines, lineIndex),
      zoomed + 0.2 + offset * 0.6,
      60,
    );
  });

  builder.holdUntil(totalDurationSeconds);
}

export const chapterFindAndFocusScene: SceneModule = {
  sceneId: "chapter-find-and-focus",
  steps: [
    { stepId: "quick-find", timelineLabel: "quick-find" },
    { stepId: "pane-zoom", timelineLabel: "pane-zoom" },
  ],
  buildScene: buildFindAndFocusScene,
};
