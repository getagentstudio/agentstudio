import { railCurrentAttribute, railSurfaceTargetAttribute } from "../chapters/chapter-dom-contract";
import {
  topologyChapterNodeAttribute,
  topologyChapterTargetEdgeAttribute,
} from "./full-page-topology-layout";

type LayoutTopologyArtwork = (artwork: SVGSVGElement) => boolean;

/** The fraction of the viewport height whose line decides the current chapter and the fog edge. */
export const topologyReadingLineRatio = 0.4;
/** Set on nodes the reveal has passed; CSS fills them with their lane color. */
export const topologyNodeRevealedAttribute = "data-topology-node-revealed";
/** `"passed" | "current" | "upcoming"` on every chapter node. */
export const topologyChapterStateAttribute = "data-chapter-state";

function clamp(value: number, minimum: number, maximum: number): number {
  return Math.min(Math.max(value, minimum), maximum);
}

export function initializeTopologyScrollReveal(
  artwork: SVGSVGElement,
  layoutArtwork: LayoutTopologyArtwork,
): () => void {
  let revealPaths: SVGPathElement[] = [];
  let revealNodes: SVGGraphicsElement[] = [];
  let routeGroups: SVGGElement[] = [];
  const queryRevealElements = (): void => {
    revealPaths = [...artwork.querySelectorAll<SVGPathElement>("[data-topology-path-start]")];
    revealNodes = [
      ...artwork.querySelectorAll<SVGGraphicsElement>("[data-topology-node-progress]"),
    ];
    routeGroups = [...artwork.querySelectorAll<SVGGElement>("[data-topology-route-group]")];
  };
  const verticalRevealSolid = artwork.querySelector<SVGRectElement>("[data-topology-reveal-solid]");
  const verticalRevealFade = artwork.querySelector<SVGRectElement>("[data-topology-reveal-fade]");
  const vibrancyGradient = artwork.querySelector<SVGLinearGradientElement>(
    "#topology-rail-vibrancy-gradient",
  );
  const vibrancyMaskRect = artwork.querySelector<SVGRectElement>(
    "[data-topology-vibrancy-mask-rect]",
  );
  const opacityGradient = artwork.querySelector<SVGLinearGradientElement>(
    "#topology-rail-opacity-gradient",
  );
  const opacityMaskRect = artwork.querySelector<SVGRectElement>(
    "[data-topology-opacity-mask-rect]",
  );
  const opacityLayer = artwork.querySelector<SVGGElement>("[data-topology-opacity-layer]");
  const colourLayer = artwork.querySelector<SVGGElement>("[data-topology-colour-layer]");
  const greyCopy = artwork.querySelector<SVGUseElement>("[data-topology-grey-copy]");
  if (
    verticalRevealSolid === null ||
    verticalRevealFade === null ||
    vibrancyGradient === null ||
    vibrancyMaskRect === null ||
    opacityGradient === null ||
    opacityMaskRect === null ||
    opacityLayer === null ||
    colourLayer === null ||
    greyCopy === null
  ) {
    throw new Error("Topology reveal or vibrancy mask is incomplete");
  }
  const lifecycle = new AbortController();
  const reducedMotionQuery = window.matchMedia("(prefers-reduced-motion: reduce)");
  let layoutNeedsUpdate = true;
  let pendingAnimationFrame: number | undefined;
  let currentNodes = new Set<SVGGraphicsElement>();
  let litTarget: HTMLElement | undefined;
  /** The lowest fog edge reached so far, in artwork coordinates; it never retreats. */
  let furthestRevealY: number | undefined;
  let endReachedDispatched = false;

  const updateCurrentNodes = (revealProgress: number, enabled: boolean): void => {
    const nextCurrentNodes = new Set<SVGGraphicsElement>();
    if (enabled) {
      const activeOwnerIds = new Set(["main"]);
      for (const group of routeGroups) {
        if (group.style.display === "none") {
          continue;
        }
        const routeId = group.dataset["routeId"];
        const route = group.querySelector<SVGPathElement>(
          '[data-route][data-topology-path-role="core"]',
        );
        if (routeId === undefined || route === null) {
          continue;
        }
        const start = Number(route.dataset["topologyPathStart"]);
        const end = Number(route.dataset["topologyPathEnd"]);
        const remainsOpen = group.dataset["endKind"] === "open";
        if (
          Number.isFinite(start) &&
          Number.isFinite(end) &&
          revealProgress >= start &&
          (remainsOpen || revealProgress < end)
        ) {
          activeOwnerIds.add(routeId);
        }
      }
      const leaderByOwnerId = new Map<
        string,
        { readonly node: SVGGraphicsElement; readonly progress: number }
      >();
      for (const node of revealNodes) {
        const routeGroup = node.closest<SVGGElement>("[data-topology-route-group]");
        const ownerId = node.dataset["nodeOwner"];
        const nodeProgress = Number(node.dataset["topologyNodeProgress"]);
        if (
          ownerId === undefined ||
          !activeOwnerIds.has(ownerId) ||
          node.style.display === "none" ||
          routeGroup?.style.display === "none" ||
          !Number.isFinite(nodeProgress) ||
          nodeProgress > revealProgress
        ) {
          continue;
        }
        const currentLeader = leaderByOwnerId.get(ownerId);
        if (currentLeader === undefined || nodeProgress > currentLeader.progress) {
          leaderByOwnerId.set(ownerId, { node, progress: nodeProgress });
        }
      }
      for (const { node } of leaderByOwnerId.values()) {
        nextCurrentNodes.add(node);
      }
    }
    for (const node of currentNodes) {
      if (!nextCurrentNodes.has(node)) {
        node.removeAttribute("data-topology-current-node");
      }
    }
    for (const node of nextCurrentNodes) {
      if (!currentNodes.has(node)) {
        node.setAttribute("data-topology-current-node", "");
      }
    }
    currentNodes = nextCurrentNodes;
  };

  const lightTarget = (nextTarget: HTMLElement | undefined): void => {
    if (litTarget === nextTarget) {
      return;
    }
    litTarget?.removeAttribute(railCurrentAttribute);
    nextTarget?.setAttribute(railCurrentAttribute, "");
    litTarget = nextTarget;
  };

  // The current chapter is the last chapter node at or above the reading line.
  // Its node becomes a terminal node, and the glass its branch enters lights.
  const updateCurrentChapter = (readingLineY: number): void => {
    const chapterNodes = [
      ...artwork.querySelectorAll<SVGGElement>(`[${topologyChapterNodeAttribute}]`),
    ];
    let currentIndex: number | undefined;
    for (const [index, node] of chapterNodes.entries()) {
      const nodeY = Number(node.querySelector("circle")?.getAttribute("cy"));
      if (!Number.isFinite(nodeY) || nodeY > readingLineY) {
        break;
      }
      currentIndex = index;
    }
    for (const [index, node] of chapterNodes.entries()) {
      const state =
        currentIndex === undefined || index > currentIndex
          ? "upcoming"
          : index === currentIndex
            ? "current"
            : "passed";
      if (node.getAttribute(topologyChapterStateAttribute) !== state) {
        node.setAttribute(topologyChapterStateAttribute, state);
      }
    }
    const currentNode = currentIndex === undefined ? undefined : chapterNodes[currentIndex];
    const anchorId = currentNode?.getAttribute(topologyChapterNodeAttribute) ?? undefined;
    const hasBranch = currentNode?.hasAttribute(topologyChapterTargetEdgeAttribute) ?? false;
    lightTarget(
      anchorId === undefined || !hasBranch
        ? undefined
        : ([
            ...artwork.ownerDocument.querySelectorAll<HTMLElement>(
              `[${railSurfaceTargetAttribute}="${anchorId}"]`,
            ),
          ].find((element) => element.getClientRects().length > 0) ?? undefined),
    );
  };

  const renderReveal = (): void => {
    pendingAnimationFrame = undefined;
    if (layoutNeedsUpdate) {
      if (!layoutArtwork(artwork)) {
        return;
      }
      layoutNeedsUpdate = false;
      queryRevealElements();
    }

    const artworkTop = artwork.getBoundingClientRect().top;
    const viewportColourEdgeY = window.innerHeight * 0.73 - artworkTop;
    const colourFadeHeight = window.innerHeight * 0.02;
    vibrancyGradient.setAttribute("y1", String(viewportColourEdgeY));
    vibrancyGradient.setAttribute("y2", String(viewportColourEdgeY + colourFadeHeight));
    vibrancyMaskRect.setAttribute("width", String(artwork.clientWidth));
    vibrancyMaskRect.setAttribute("height", String(artwork.clientHeight));
    opacityGradient.setAttribute("y1", String(window.innerHeight * 0.9 - artworkTop));
    opacityGradient.setAttribute("y2", String(window.innerHeight * 0.95 - artworkTop));
    opacityMaskRect.setAttribute("width", String(artwork.clientWidth));
    opacityMaskRect.setAttribute("height", String(artwork.clientHeight));
    greyCopy.style.display = reducedMotionQuery.matches ? "none" : "";
    if (reducedMotionQuery.matches) {
      colourLayer.removeAttribute("mask");
      opacityLayer.removeAttribute("mask");
    } else {
      colourLayer.setAttribute("mask", "url(#topology-rail-vibrancy-mask)");
      opacityLayer.setAttribute("mask", "url(#topology-rail-opacity-mask)");
    }
    const readingLineY = window.innerHeight * topologyReadingLineRatio - artworkTop;
    updateCurrentChapter(readingLineY);

    const maximumScroll = Math.max(document.documentElement.scrollHeight - window.innerHeight, 1);
    const scrollProgress = clamp(window.scrollY / maximumScroll, 0, 1);
    artwork.dataset["topologyScrollProgress"] = String(scrollProgress);
    artwork.toggleAttribute(
      "data-topology-at-end",
      !reducedMotionQuery.matches && scrollProgress >= 0.9999,
    );

    const topologyStartY = Number(artwork.dataset["topologyStartY"]);
    const topologyEndY = Number(artwork.dataset["topologyEndY"]);
    if (!Number.isFinite(topologyStartY) || !Number.isFinite(topologyEndY)) {
      return;
    }
    // The fog edge follows scroll progress through the topology and never sits
    // above the reading line. The first render reveals the whole first
    // viewport, and the edge only ever moves down, so what was seen stays lit.
    const span = Math.max(topologyEndY - topologyStartY, 1);
    const progressY = topologyStartY + span * scrollProgress;
    furthestRevealY ??= window.innerHeight - artworkTop;
    furthestRevealY = Math.max(furthestRevealY, progressY, window.innerHeight - artworkTop);
    const revealY = reducedMotionQuery.matches
      ? topologyEndY
      : Math.min(furthestRevealY, topologyEndY);
    const revealProgress = clamp((revealY - topologyStartY) / span, 0, 1);
    const fadeHeight = revealProgress >= 1 ? 0 : Math.min(288, Math.max(96, span * 0.06));
    verticalRevealSolid.setAttribute(
      "height",
      String(revealProgress >= 1 ? artwork.clientHeight : revealY),
    );
    verticalRevealFade.setAttribute("y", String(revealY));
    verticalRevealFade.setAttribute("height", String(fadeHeight));
    artwork.dataset["topologyRevealEdgeY"] = String(revealY);
    for (const path of revealPaths) {
      path.style.visibility = "visible";
    }
    for (const node of revealNodes) {
      const revealed = Number(node.dataset["topologyNodeProgress"]) <= revealProgress + 1e-6;
      node.toggleAttribute(topologyNodeRevealedAttribute, revealed);
    }
    const terminalPath = artwork.querySelector<SVGPathElement>(
      '[data-topology-terminal-route] [data-topology-path-role="core"]',
    );
    const terminalReached =
      terminalPath !== null &&
      revealProgress >= Number(terminalPath.dataset["topologyPathEnd"]) - 1e-6;
    if (scrollProgress >= 0.9999 || endReachedDispatched || terminalReached) {
      const terminalRing = artwork.querySelector<SVGCircleElement>(
        "[data-topology-terminal-node] .node-end-ring",
      );
      const pathBounds = terminalPath?.getBBox();
      const terminalBottomY = Math.max(
        pathBounds === undefined ? 0 : pathBounds.y + pathBounds.height,
        terminalRing === null
          ? 0
          : terminalRing.cy.baseVal.value +
              terminalRing.r.baseVal.value +
              Number.parseFloat(getComputedStyle(terminalRing).strokeWidth) / 2,
      );
      // Once reached, the terminal join stays wholly inside the colour copy,
      // including its ring stroke after later scroll or viewport relayout.
      const colourEdgeY = Math.max(viewportColourEdgeY, terminalBottomY + 8);
      vibrancyGradient.setAttribute("y1", String(colourEdgeY));
      vibrancyGradient.setAttribute("y2", String(colourEdgeY + colourFadeHeight));
    }
    if (!endReachedDispatched && terminalReached) {
      endReachedDispatched = true;
      artwork.setAttribute("data-topology-end-reached", "");
      artwork.ownerDocument.dispatchEvent(new Event("topology-end-reached"));
    }
    updateCurrentNodes(revealProgress, !reducedMotionQuery.matches);
  };

  const scheduleRender = (): void => {
    if (pendingAnimationFrame !== undefined || lifecycle.signal.aborted) {
      return;
    }
    pendingAnimationFrame = window.requestAnimationFrame(renderReveal);
  };

  // Glass surfaces lift with a scroll-driven transform and carry chapter
  // anchors with them, so every frame lays out again before revealing.
  const forceLayoutUpdate = (): void => {
    layoutNeedsUpdate = true;
    scheduleRender();
  };

  const artworkResizeObserver = new ResizeObserver(forceLayoutUpdate);
  artworkResizeObserver.observe(artwork);
  // The chapter wrapper, rather than its glass, now carries the scroll lift.
  // Its style mutation is the geometry change that requires a fresh attach path.
  const liftObserver = new MutationObserver(forceLayoutUpdate);
  for (const liftGroup of artwork.ownerDocument.querySelectorAll(
    "[data-scroll-material-lift-target]",
  )) {
    liftObserver.observe(liftGroup, { attributes: true, attributeFilter: ["style"] });
  }
  window.addEventListener("scroll", forceLayoutUpdate, { passive: true, signal: lifecycle.signal });
  window.addEventListener("resize", forceLayoutUpdate, { signal: lifecycle.signal });
  window.addEventListener("load", forceLayoutUpdate, { signal: lifecycle.signal });
  reducedMotionQuery.addEventListener("change", scheduleRender, { signal: lifecycle.signal });
  void document.fonts.ready.then(forceLayoutUpdate);
  scheduleRender();

  return (): void => {
    lifecycle.abort();
    artworkResizeObserver.disconnect();
    liftObserver.disconnect();
    updateCurrentNodes(0, false);
    lightTarget(undefined);
    if (pendingAnimationFrame !== undefined) {
      window.cancelAnimationFrame(pendingAnimationFrame);
    }
  };
}
