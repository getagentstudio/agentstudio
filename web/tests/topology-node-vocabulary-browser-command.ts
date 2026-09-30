import { defineBrowserCommand } from "@vitest/browser-playwright";

/** One rendered glyph, read from the served home page with its real styles. */
export interface TopologyGlyphObservation {
  readonly kind: string;
  readonly finaleTerminal: boolean;
  readonly chapterState: string | undefined;
  readonly revealed: boolean;
  /** The lane color the node sits on (the group's `color`). */
  readonly laneColor: string;
  /** The primary glyph: the dot, the chapter ring, or the merge ring. */
  readonly glyph: {
    readonly radius: number;
    readonly fill: string;
    readonly stroke: string;
    readonly strokeWidth: string;
    readonly display: string;
    /** The glyph's own `color`: the incoming lane for a merge ring. */
    readonly color: string;
  };
  /** Merge and finale end rings: the inner dot. */
  readonly core:
    | { readonly radius: number; readonly fill: string; readonly opacity: string }
    | undefined;
  readonly terminalDisplay: string | undefined;
}

/** One port's line, read with its real styles. */
export interface TopologyPortObservation {
  readonly stepLine: boolean;
  readonly source: string;
  readonly terminal: boolean;
  readonly strokeWidth: string;
  readonly laneStrokeWidth: string;
  /** The computed stroke, including a gradient reference for non-step worktree ports. */
  readonly stroke: string;
  readonly firstStopColor: string | undefined;
  /** The computed stroke of the lane the port leaves. */
  readonly sourceLaneStroke: string | undefined;
  readonly nodeCount: number;
  readonly endpointOffset: number;
}

export interface TopologyNodeVocabularyResult {
  readonly canvasColor: string;
  readonly primaryColor: string;
  readonly beforeReveal: readonly TopologyGlyphObservation[];
  readonly afterReveal: readonly TopologyGlyphObservation[];
  readonly ports: readonly TopologyPortObservation[];
  readonly stepLineCount: number;
  readonly routeFilters: readonly string[];
}

function readPorts(): TopologyPortObservation[] {
  const artwork = document.querySelector("[data-full-page-topology]");
  if (artwork === null) {
    throw new Error("The home page has no topology artwork");
  }
  const laneCore = (accent: string): SVGPathElement | null =>
    artwork.querySelector<SVGPathElement>(
      `[data-route-kind="worktree"].accent-${accent} > [data-topology-path-role="core"]`,
    );
  const anyLane =
    artwork.querySelector<SVGPathElement>(
      '[data-route-kind="worktree"] > [data-topology-path-role="core"]',
    ) ?? artwork.querySelector<SVGPathElement>("[data-mainline]");
  return [...artwork.querySelectorAll<SVGGElement>('[data-route-kind="attach"]')].map((group) => {
    const core = group.querySelector<SVGPathElement>('[data-topology-path-role="core"]');
    if (core === null || anyLane === null) {
      throw new Error("An attach branch is missing its line");
    }
    const anchorId = group.dataset["routeAnchor"];
    const target =
      (group.dataset["targetEdge"] === "left"
        ? document.querySelector(`[data-rail-step-line-target="${anchorId ?? ""}"]`)
        : null) ?? document.querySelector(`[data-rail-surface-target="${anchorId ?? ""}"]`);
    if (target === null) throw new Error("An attach branch has no target");
    const matrix = core.getScreenCTM();
    if (matrix === null) throw new Error("An attach branch has no screen transform");
    const endpoint = core.getPointAtLength(core.getTotalLength()).matrixTransform(matrix);
    const bounds = target.getBoundingClientRect();
    const endpointOffset =
      group.dataset["targetEdge"] === "top"
        ? Math.abs(endpoint.y - bounds.top)
        : Math.abs(endpoint.x - bounds.left);
    const source = group.dataset["routeSource"] ?? "";
    const stepLine =
      document.querySelector(`[data-rail-step-line-target="${anchorId ?? ""}"]`) !== null;
    const firstStop = group.querySelector("[data-topology-port-gradient] stop");
    const sourceLane = stepLine
      ? artwork.querySelector<SVGPathElement>(
          `[data-route-kind="worktree"][data-route-column="${group.dataset["routeParentColumn"] ?? ""}"] > [data-topology-path-role="core"]`,
        )
      : laneCore(source);
    return {
      stepLine,
      source,
      terminal: group.hasAttribute("data-topology-terminal-route"),
      strokeWidth: getComputedStyle(core).strokeWidth,
      laneStrokeWidth: getComputedStyle(anyLane).strokeWidth,
      stroke: getComputedStyle(core).stroke,
      firstStopColor: firstStop === null ? undefined : getComputedStyle(firstStop).stopColor,
      sourceLaneStroke: sourceLane === null ? undefined : getComputedStyle(sourceLane).stroke,
      nodeCount: group.querySelectorAll("[data-topology-port-node]").length,
      endpointOffset,
    };
  });
}

function readGlyphs(): TopologyGlyphObservation[] {
  const artwork = document.querySelector("[data-full-page-topology]");
  if (artwork === null) {
    throw new Error("The home page has no topology artwork");
  }
  return [...artwork.querySelectorAll<SVGGElement>("[data-node]")].map((node) => {
    const glyph = node.querySelector<SVGCircleElement>(
      ".node-commit, .node-chapter, .node-merge-ring, .node-end-ring",
    );
    if (glyph === null) {
      throw new Error("A topology node has no glyph");
    }
    const glyphStyle = getComputedStyle(glyph);
    const core = node.querySelector<SVGCircleElement>(".node-merge-core, .node-end-core");
    const terminal = node.querySelector<SVGCircleElement>(".node-terminal");
    return {
      kind: node.dataset["nodeKind"] ?? "",
      finaleTerminal: node.hasAttribute("data-topology-terminal-node"),
      chapterState: node.dataset["chapterState"],
      revealed: node.hasAttribute("data-topology-node-revealed"),
      laneColor: getComputedStyle(node).color,
      glyph: {
        radius: glyph.r.baseVal.value,
        fill: glyphStyle.fill,
        stroke: glyphStyle.stroke,
        strokeWidth: glyphStyle.strokeWidth,
        display: glyphStyle.display,
        color: glyphStyle.color,
      },
      core:
        core === null
          ? undefined
          : {
              radius: core.r.baseVal.value,
              fill: getComputedStyle(core).fill,
              opacity: getComputedStyle(core).opacity,
            },
      terminalDisplay: terminal === null ? undefined : getComputedStyle(terminal).display,
    };
  });
}

/**
 * Loads the served home page at 1920×1080 and reads every topology glyph's
 * computed style twice: at first paint (nodes below the fog are unrevealed)
 * and after scrolling to the end (everything revealed, transitions settled).
 */
export const verifyTopologyNodeVocabulary = defineBrowserCommand(
  async ({ context }, pageUrl: string): Promise<TopologyNodeVocabularyResult> => {
    const applicationPage = await context.newPage();
    try {
      await applicationPage.setViewportSize({ width: 1920, height: 1080 });
      await applicationPage.goto(pageUrl, { waitUntil: "domcontentloaded" });
      await applicationPage.waitForSelector(
        "[data-full-page-topology][data-topology-reveal-edge-y]",
        {
          state: "attached",
        },
      );
      const beforeReveal = await applicationPage.evaluate(readGlyphs);
      const routeFilters = await applicationPage.evaluate(() =>
        [...document.querySelectorAll<SVGGElement>("[data-topology-route-group]")].map(
          (route) => getComputedStyle(route).filter,
        ),
      );
      await applicationPage.evaluate(() => {
        window.scrollTo(0, document.documentElement.scrollHeight);
      });
      await applicationPage.evaluate(
        async (): Promise<void> =>
          await new Promise((resolve): void => {
            const artwork = document.querySelector("[data-full-page-topology]");
            if (artwork === null) throw new Error("Topology artwork is missing");
            const allNodesRevealed = (): boolean =>
              [...artwork.querySelectorAll("[data-node]")].every((node) =>
                node.hasAttribute("data-topology-node-revealed"),
              );
            const observer = new MutationObserver((): void => {
              if (!allNodesRevealed()) return;
              observer.disconnect();
              resolve();
            });
            observer.observe(artwork, {
              attributes: true,
              attributeFilter: ["data-topology-node-revealed"],
              subtree: true,
            });
            if (allNodesRevealed()) {
              observer.disconnect();
              resolve();
            }
          }),
      );
      // The final glyph state is independent of transition timing. Disable
      // motion after the scroll has revealed every node before reading paint.
      await applicationPage.emulateMedia({ reducedMotion: "reduce" });
      const afterReveal = await applicationPage.evaluate(readGlyphs);
      const { canvasColor, primaryColor } = await applicationPage.evaluate(() => {
        const branch = document.querySelector("[data-route-kind=attach]");
        return {
          canvasColor: getComputedStyle(document.body).backgroundColor,
          primaryColor: branch === null ? "" : getComputedStyle(branch).color,
        };
      });
      const ports = await applicationPage.evaluate(readPorts);
      const stepLineCount = await applicationPage.evaluate(
        () => document.querySelectorAll("[data-rail-step-line-target]").length,
      );
      return {
        canvasColor,
        primaryColor,
        beforeReveal,
        afterReveal,
        ports,
        stepLineCount,
        routeFilters,
      };
    } finally {
      await applicationPage.close();
    }
  },
);
