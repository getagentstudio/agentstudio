import { defineBrowserCommand } from "@vitest/browser-playwright";

import {
  observeFinalePillSurface,
  type FinalePillSurfaceObservation,
} from "./finale-pill-surface-observation";

/** The final branch, lane closures and rendered path extent in page coordinates. */
export interface TopologyEndObservation {
  readonly endColourMaskEdge: number;
  readonly endTerminalNodeBottom: number;
  readonly attachJoinStroke: string;
  readonly width: number;
  readonly captionToFinaleGap: number;
  readonly pillLeft: number;
  readonly lastGlassLeft: number;
  readonly stageLeft: number;
  readonly titleLeft: number;
  readonly stageRight: number;
  readonly titleFontSize: number;
  readonly noteLeft: number;
  readonly stageCenterY: number;
  readonly titleCenterY: number;
  readonly stageHeight: number;
  readonly titleLineHeight: number;
  readonly artworkStates: readonly FinaleArtworkObservation[];
  readonly pillCenterY: number;
  readonly branchEndX: number;
  readonly branchEndY: number;
  readonly nodeRightX: number;
  readonly ringRadius: number;
  readonly coreRadius: number;
  readonly haloRadius: number;
  readonly ringStroke: string;
  readonly coreFill: string;
  readonly branchStroke: string;
  readonly branchStartY: number;
  readonly branchStartX: number;
  readonly bendDotCount: number;
  readonly bendDotOffset: number;
  readonly bendDotPlain: boolean;
  readonly innermostLaneX: number;
  readonly mainlineEndY: number;
  readonly branchViewportMaxFraction: number;
  readonly minimumTitleClearance: number;
  readonly lastGlassBottomY: number;
  readonly laneMergeYs: readonly number[];
  readonly laneStopYs: readonly number[];
  readonly duplicateRowDotCount: number;
  readonly lowestRailY: number;
  readonly laneCount: number;
  readonly terminalNodeCount: number;
  readonly terminalRouteCount: number;
  readonly branchColumnSpan: number;
  readonly branchBendCount: number;
  readonly mainlineBendCount: number;
  readonly branchMonotonicX: boolean;
  readonly branchPathData: string;
  readonly mainlinePathData: string;
  readonly pathData: readonly { readonly kind: "rail" | "step"; readonly d: string }[];
}

export interface FinaleBookendObservation extends FinalePillSurfaceObservation {
  readonly readyOutlineAt03: boolean;
  readonly traceOpacityAt03: number;
  readonly readyOutlineAt08: boolean;
  readonly traceOpacityAt08: number;
  readonly traceDashFractionAt08: number;
  readonly readyOutlineAfterReverseSeek: boolean;
  readonly traceOpacityAfterReverseSeek: number;
  readonly resizedTraceWidthDelta: number;
  readonly resizedViewBoxWidthDelta: number;
  readonly settledDashCleared: boolean;
  readonly pillWidth: number;
  readonly pillHeight: number;
  readonly tracePathData: string;
  readonly pillBorderColor: string;
  readonly pillBorderWidth: string;
  readonly pillOverflowX: string;
  readonly starLeftOffset: number;
  readonly copyRightRadius: string;
  readonly terminalHaloDisplay: string;
  readonly transitionalFanAngles: readonly number[];
  readonly transitionalPlaneBorderWidths: readonly number[];
  readonly eventCount: number;
  readonly href: string;
  readonly finalState: string | undefined;
  readonly logoOpacity: string;
  readonly traceOpacity: string;
  readonly copiedIconVisible: boolean;
  readonly railStartFraction: number;
  readonly railArrivalFraction: number;
  readonly nodeStartOpacity: string;
  readonly nodeArrivalOpacity: string;
  readonly sectionHeightDelta: number;
  readonly footerTopDelta: number;
  readonly oldInstallBoxCount: number;
  readonly ctaParagraphCount: number;
  readonly splitPillCount: number;
  readonly starText: string;
  readonly copyText: string;
  readonly copiedText: string;
  readonly copyCount: number;
  readonly copiedLabel: string;
  readonly phoneOneRow: boolean;
  readonly phoneShortLabels: boolean;
  readonly phoneOverflow: number;
  readonly reducedMotionState: string | undefined;
  readonly reducedMotionTimelineCreated: boolean;
  readonly reducedMotionLogoOpacity: string;
  readonly pointerSkipState: string | undefined;
  readonly resizeSettleState: string | undefined;
  readonly narrowTitleFontSize: number;
  readonly narrowHeadingOverflow: number;
}

export interface FinaleArtworkObservation {
  readonly width: number;
  readonly state: "initial" | "settled";
  readonly pillLeft: number;
  readonly artworkLeft: number;
  readonly artworkRight: number;
  readonly artworkHeight: number;
  readonly titleLeft: number;
  readonly titleFontSize: number;
  readonly titleCapHeight: number;
}

function observeFinaleArtwork(props: {
  width: number;
  state: "initial" | "settled";
}): FinaleArtworkObservation {
  const { width, state } = props;
  const root = document.querySelector<HTMLElement>("[data-finale-root]");
  const title = root?.querySelector<HTMLElement>("#final-cta-title");
  const pill = root?.querySelector<HTMLElement>("[data-finale-split-pill]");
  const logo = root?.querySelector<HTMLImageElement>("[data-finale-logo]");
  if (
    root === null ||
    title === null ||
    title === undefined ||
    pill === null ||
    pill === undefined ||
    logo === null ||
    logo === undefined
  )
    throw new Error("Finale artwork proof markup is missing");
  const titleStyle = getComputedStyle(title);
  const canvas = document.createElement("canvas");
  const context = canvas.getContext("2d");
  if (context === null) throw new Error("Canvas context unavailable for artwork proof");
  context.font = `${titleStyle.fontWeight} ${titleStyle.fontSize} ${titleStyle.fontFamily}`;
  const titleCapHeight = context.measureText("H").actualBoundingBoxAscent;
  let left: number;
  let right: number;
  let top: number;
  let bottom: number;
  if (state === "initial") {
    const planes = [...root.querySelectorAll<HTMLElement>(".finale-plane, .finale-terminal")];
    if (planes.length !== 4) throw new Error("Finale fan artwork is missing");
    const boxes = planes.map((plane) => plane.getBoundingClientRect());
    left = Math.min(...boxes.map((box) => box.left));
    right = Math.max(...boxes.map((box) => box.right));
    top = Math.min(...boxes.map((box) => box.top));
    bottom = Math.max(...boxes.map((box) => box.bottom));
  } else {
    if (!logo.complete || logo.naturalWidth === 0) throw new Error("Finale logo is not loaded");
    canvas.width = logo.naturalWidth;
    canvas.height = logo.naturalHeight;
    context.drawImage(logo, 0, 0);
    const pixels = context.getImageData(0, 0, canvas.width, canvas.height).data;
    let minX = canvas.width;
    let maxX = 0;
    let minY = canvas.height;
    let maxY = 0;
    for (let y = 0; y < canvas.height; y += 1) {
      for (let x = 0; x < canvas.width; x += 1) {
        if ((pixels[(y * canvas.width + x) * 4 + 3] ?? 0) < 26) continue;
        minX = Math.min(minX, x);
        maxX = Math.max(maxX, x);
        minY = Math.min(minY, y);
        maxY = Math.max(maxY, y);
      }
    }
    if (minX > maxX || minY > maxY) throw new Error("Finale logo has no visible pixels");
    const box = logo.getBoundingClientRect();
    left = box.left + (minX / canvas.width) * box.width;
    right = box.left + ((maxX + 1) / canvas.width) * box.width;
    top = box.top + (minY / canvas.height) * box.height;
    bottom = box.top + ((maxY + 1) / canvas.height) * box.height;
  }
  return {
    width,
    state,
    pillLeft: pill.getBoundingClientRect().left,
    artworkLeft: left,
    artworkRight: right,
    artworkHeight: bottom - top,
    titleLeft: title.getBoundingClientRect().left,
    titleFontSize: Number.parseFloat(titleStyle.fontSize),
    titleCapHeight,
  };
}

export const verifyFinaleBookend = defineBrowserCommand(
  async (
    { context },
    pageUrl: string,
    proofWidth: number = 1600,
  ): Promise<FinaleBookendObservation> => {
    const applicationPage = await context.newPage();
    const reducedMotionPage = await context.newPage();
    const skipPage = await context.newPage();
    const installEventCounter = (): void => {
      const proofWindow = window as Window & {
        topologyEndEventCount?: number;
        finaleControl?: { pause(): void; seek(seconds: number): void };
        copiedInstall?: string;
        copyCount?: number;
      };
      proofWindow.topologyEndEventCount = 0;
      proofWindow.copyCount = 0;
      document.addEventListener("topology-end-reached", () => {
        const pageWindow = window as Window & { topologyEndEventCount?: number };
        pageWindow.topologyEndEventCount = (pageWindow.topologyEndEventCount ?? 0) + 1;
      });
      document.addEventListener("finale-bookend-ready", (event) => {
        if (!(event instanceof CustomEvent)) return;
        proofWindow.finaleControl = event.detail as { pause(): void; seek(seconds: number): void };
        proofWindow.finaleControl.pause();
      });
      Object.defineProperty(navigator, "clipboard", {
        configurable: true,
        value: {
          writeText: (value: string): Promise<void> => {
            proofWindow.copyCount = (proofWindow.copyCount ?? 0) + 1;
            proofWindow.copiedInstall = value;
            return Promise.resolve();
          },
        },
      });
    };
    try {
      await applicationPage.setViewportSize({
        width: proofWidth,
        height: proofWidth < 620 ? 844 : 1000,
      });
      await applicationPage.addInitScript(installEventCounter);
      await applicationPage.goto(pageUrl, { waitUntil: "domcontentloaded" });
      await applicationPage.evaluate(async () => await document.fonts.ready);
      await applicationPage.evaluate(() => window.dispatchEvent(new WheelEvent("wheel")));
      await applicationPage.waitForSelector('[data-hero-intro-state="settled"]');
      await applicationPage.waitForSelector("[data-finale-timeline-created]");
      await applicationPage.evaluate(() =>
        window.scrollTo(0, document.documentElement.scrollHeight),
      );
      await applicationPage.waitForSelector("[data-topology-end-reached]");
      const normal = await applicationPage.evaluate(async () => {
        const proofWindow = window as Window & {
          topologyEndEventCount?: number;
          finaleControl?: { pause(): void; seek(seconds: number): void };
          copiedInstall?: string;
          copyCount?: number;
        };
        const root = document.querySelector<HTMLElement>("[data-finale-root]");
        const button = document.querySelector<HTMLAnchorElement>("[data-final-star-button]");
        const copy = document.querySelector<HTMLButtonElement>(
          "[data-finale-split-pill] [data-install-copy]",
        );
        const footer = document.querySelector<HTMLElement>("footer");
        const logo = root?.querySelector<HTMLElement>("[data-finale-logo]");
        const trace = root?.querySelector<SVGPathElement>("[data-finale-border-trace]");
        const terminalRoute = document.querySelector<SVGGElement>("[data-topology-terminal-route]");
        const railPath = terminalRoute?.querySelector<SVGPathElement>(
          '[data-topology-path-role="core"]',
        );
        const endNode = terminalRoute?.querySelector<SVGGElement>("[data-topology-terminal-node]");
        if (
          root === null ||
          button === null ||
          copy === null ||
          footer === null ||
          logo === null ||
          logo === undefined ||
          trace === null ||
          trace === undefined ||
          railPath === null ||
          railPath === undefined ||
          endNode === null ||
          endNode === undefined ||
          proofWindow.finaleControl === undefined
        )
          throw new Error("Finale proof markup or control is missing");
        proofWindow.finaleControl.seek(0);
        const fanFront = root.querySelector<HTMLElement>(".finale-plane--front");
        const fanRearTwo = root.querySelector<HTMLElement>(".finale-plane--rear-two");
        const fanRearOne = root.querySelector<HTMLElement>(".finale-plane--rear-one");
        if (fanFront === null || fanRearTwo === null || fanRearOne === null)
          throw new Error("Finale fan is missing");
        const fanPlanes = [fanFront, fanRearTwo, fanRearOne];
        const transitionalFanAngles = fanPlanes.map((plane) => {
          const transform = new DOMMatrixReadOnly(getComputedStyle(plane).transform);
          return Math.atan2(transform.b, transform.a) * (180 / Math.PI);
        });
        const finaleTerminal = root.querySelector<HTMLElement>(".finale-terminal");
        if (finaleTerminal === null) throw new Error("Finale terminal card is missing");
        const transitionalPlaneBorderWidths = [...fanPlanes, finaleTerminal].map((plane) =>
          Number.parseFloat(getComputedStyle(plane).borderTopWidth),
        );
        const railStartFraction =
          Number.parseFloat(railPath.style.strokeDashoffset) / railPath.getTotalLength();
        const nodeStartOpacity = getComputedStyle(endNode).opacity;
        const initialHeight = root.getBoundingClientRect().height;
        const initialFooterTop = footer.getBoundingClientRect().top + scrollY;
        const sampleShift = (): number =>
          Math.max(
            Math.abs(root.getBoundingClientRect().height - initialHeight),
            Math.abs(footer.getBoundingClientRect().top + scrollY - initialFooterTop),
          );
        const starText = button.textContent?.trim() ?? "";
        const copyText = copy.textContent?.trim() ?? "";
        const pill = copy.closest<HTMLElement>("[data-finale-split-pill]");
        if (pill === null) throw new Error("Finale split pill is missing");
        const stepPill = document.querySelector<HTMLElement>(".chapter-step-active-label");
        if (stepPill === null) throw new Error("Chapter step-label pill missing");
        const restingShadow = getComputedStyle(stepPill).boxShadow;
        proofWindow.finaleControl.seek(0.3);
        const readyOutlineAt03 = getComputedStyle(pill).boxShadow !== restingShadow;
        const traceOpacityAt03 = Number(getComputedStyle(trace).opacity);
        proofWindow.finaleControl.seek(0.35);
        const railArrivalFraction =
          Number.parseFloat(railPath.style.strokeDashoffset) / railPath.getTotalLength();
        const nodeArrivalOpacity = getComputedStyle(endNode).opacity;
        proofWindow.finaleControl.seek(0.8);
        const readyOutlineAt08 = getComputedStyle(pill).boxShadow !== restingShadow;
        const traceOpacityAt08 = Number(getComputedStyle(trace).opacity);
        const traceDashFractionAt08 =
          Number.parseFloat(trace.style.strokeDashoffset) / trace.getTotalLength();
        proofWindow.finaleControl.seek(0.3);
        const readyOutlineAfterReverseSeek = getComputedStyle(pill).boxShadow !== restingShadow;
        const traceOpacityAfterReverseSeek = Number(getComputedStyle(trace).opacity);
        proofWindow.finaleControl.seek(0.8);
        const midTraceShift = sampleShift();
        proofWindow.finaleControl.seek(1.8);
        const midFoldShift = sampleShift();
        proofWindow.finaleControl.seek(2.4);
        const finalShift = sampleShift();
        copy.click();
        await Promise.resolve();
        return {
          readyOutlineAt03,
          traceOpacityAt03,
          readyOutlineAt08,
          traceOpacityAt08,
          traceDashFractionAt08,
          readyOutlineAfterReverseSeek,
          traceOpacityAfterReverseSeek,
          eventCount: proofWindow.topologyEndEventCount ?? 0,
          pillWidth:
            copy.closest<HTMLElement>("[data-finale-split-pill]")?.getBoundingClientRect().width ??
            0,
          pillHeight:
            copy.closest<HTMLElement>("[data-finale-split-pill]")?.getBoundingClientRect().height ??
            0,
          tracePathData: trace.getAttribute("d") ?? "",
          pillBorderColor: getComputedStyle(
            copy.closest<HTMLElement>("[data-finale-split-pill]") ?? root,
          ).borderTopColor,
          pillBorderWidth: getComputedStyle(
            copy.closest<HTMLElement>("[data-finale-split-pill]") ?? root,
          ).borderTopWidth,
          pillOverflowX: getComputedStyle(
            copy.closest<HTMLElement>("[data-finale-split-pill]") ?? root,
          ).overflowX,
          starLeftOffset:
            button.getBoundingClientRect().left -
            (copy.closest<HTMLElement>("[data-finale-split-pill]")?.getBoundingClientRect().left ??
              0),
          copyRightRadius: getComputedStyle(copy).borderTopRightRadius,
          terminalHaloDisplay: getComputedStyle(
            endNode.querySelector<SVGCircleElement>(".node-terminal-halo") ?? endNode,
          ).display,
          transitionalFanAngles,
          transitionalPlaneBorderWidths,
          href: button.href,
          finalState: root.dataset["finaleState"],
          logoOpacity: getComputedStyle(logo).opacity,
          traceOpacity: getComputedStyle(trace.closest("svg") ?? trace).opacity,
          copiedIconVisible:
            copy
              .querySelector("[data-install-copied-icon]")
              ?.hasAttribute("data-install-icon-hidden") === false &&
            copy
              .querySelector("[data-install-copy-icon]")
              ?.hasAttribute("data-install-icon-hidden") === true,
          railStartFraction,
          railArrivalFraction,
          nodeStartOpacity,
          nodeArrivalOpacity,
          sectionHeightDelta: Math.max(midTraceShift, midFoldShift, finalShift),
          footerTopDelta: footer.getBoundingClientRect().top + scrollY - initialFooterTop,
          oldInstallBoxCount: root.querySelectorAll(".install-command").length,
          ctaParagraphCount: root.querySelectorAll("p").length,
          splitPillCount: root.querySelectorAll("[data-finale-split-pill]").length,
          starText,
          copyText,
          copiedText: proofWindow.copiedInstall ?? "",
          copyCount: proofWindow.copyCount ?? 0,
          copiedLabel:
            [...copy.querySelectorAll<HTMLElement>("[data-install-copy-feedback]")].find(
              (label) => getComputedStyle(label).display !== "none",
            )?.textContent ?? "",
        };
      });
      await applicationPage.evaluate(async () => {
        const label = document.querySelector<HTMLElement>(
          "[data-finale-split-pill] [data-install-copy-feedback]",
        );
        if (label === null) throw new Error("Finale copy label missing");
        if (label.textContent?.startsWith("Copy") === true) return;
        await new Promise<void>((resolve) => {
          const observer = new MutationObserver(() => {
            if (label.textContent?.startsWith("Copy") !== true) return;
            observer.disconnect();
            resolve();
          });
          observer.observe(label, { childList: true, characterData: true, subtree: true });
        });
      });
      await applicationPage.evaluate(async () => {
        const pill = document.querySelector<HTMLElement>("[data-finale-split-pill]");
        const trace = document.querySelector<SVGPathElement>("[data-finale-border-trace]");
        const svg = trace?.ownerSVGElement;
        if (!pill || !trace || !svg) throw new Error("Finale trace resize signal missing");
        const matchesPill = (): boolean =>
          Math.abs(svg.viewBox.baseVal.width - pill.getBoundingClientRect().width) <= 0.5 &&
          Math.abs(svg.viewBox.baseVal.height - pill.getBoundingClientRect().height) <= 0.5;
        if (matchesPill()) return;
        await new Promise<void>((resolve) => {
          const observer = new MutationObserver(() => {
            if (!matchesPill()) return;
            observer.disconnect();
            resolve();
          });
          observer.observe(svg, {
            attributes: true,
            attributeFilter: ["viewBox", "d"],
            subtree: true,
          });
        });
      });
      const pillSurface = await applicationPage.evaluate(observeFinalePillSurface);
      const resizedTrace = await applicationPage.evaluate(async () => {
        const pill = document.querySelector<HTMLElement>("[data-finale-split-pill]");
        const trace = document.querySelector<SVGPathElement>("[data-finale-border-trace]");
        const svg = trace?.closest("svg");
        if (
          pill === null ||
          trace === null ||
          trace === undefined ||
          svg === null ||
          svg === undefined
        )
          throw new Error("Settled finale outline is missing");
        const originalWidth = pill.getBoundingClientRect().width;
        const resized = new Promise<void>((resolve) => {
          const observer = new ResizeObserver(() => {
            if (Math.abs(pill.getBoundingClientRect().width - originalWidth) < 2) return;
            observer.disconnect();
            resolve();
          });
          observer.observe(pill);
        });
        pill.style.width = `${String(originalWidth - 80)}px`;
        await resized;
        await Promise.resolve();
        const width = pill.getBoundingClientRect().width;
        const viewBoxWidth = Number(svg.getAttribute("viewBox")?.split(/\s+/u)[2]);
        return {
          resizedTraceWidthDelta: Math.abs(trace.getBBox().width - (width - 1)),
          resizedViewBoxWidthDelta: Math.abs(viewBoxWidth - width),
          settledDashCleared:
            trace.style.strokeDasharray === "" && trace.style.strokeDashoffset === "",
        };
      });

      await reducedMotionPage.emulateMedia({ reducedMotion: "reduce" });
      await reducedMotionPage.setViewportSize({ width: 390, height: 844 });
      await reducedMotionPage.goto(pageUrl, { waitUntil: "domcontentloaded" });
      await reducedMotionPage.evaluate(() =>
        window.scrollTo(0, document.documentElement.scrollHeight),
      );
      await reducedMotionPage.waitForSelector("[data-topology-end-reached]");
      const reduced = await reducedMotionPage.evaluate(() => {
        const root = document.querySelector<HTMLElement>("[data-finale-root]");
        const pill = root?.querySelector<HTMLElement>("[data-finale-split-pill]");
        const star = root?.querySelector<HTMLElement>("[data-final-star-button]");
        const copy = root?.querySelector<HTMLElement>("[data-install-copy]");
        const logo = root?.querySelector<HTMLElement>("[data-finale-logo]");
        if (
          root === null ||
          pill === null ||
          pill === undefined ||
          star === null ||
          star === undefined ||
          copy === null ||
          copy === undefined ||
          logo === null ||
          logo === undefined
        )
          throw new Error("Reduced-motion finale markup is missing");
        return {
          phoneOneRow:
            Math.abs(star.getBoundingClientRect().top - copy.getBoundingClientRect().top) <= 0.5,
          phoneShortLabels: root.hasAttribute("data-short-labels"),
          phoneOverflow: pill.scrollWidth - pill.clientWidth,
          reducedMotionState: root.dataset["finaleState"],
          reducedMotionTimelineCreated: root.hasAttribute("data-finale-timeline-created"),
          reducedMotionLogoOpacity: getComputedStyle(logo).opacity,
        };
      });
      await skipPage.setViewportSize({ width: 390, height: 844 });
      await skipPage.goto(pageUrl, { waitUntil: "domcontentloaded" });
      await skipPage.waitForSelector("[data-finale-timeline-created]");
      await skipPage.evaluate(() => {
        document
          .querySelector<HTMLElement>("[data-finale-root]")
          ?.dispatchEvent(new Event("pointerdown", { bubbles: true }));
      });
      const pointerSkipState =
        (await skipPage.locator("[data-finale-root]").getAttribute("data-finale-state")) ??
        undefined;
      await skipPage.reload({ waitUntil: "domcontentloaded" });
      await skipPage.waitForSelector("[data-finale-timeline-created]");
      await skipPage.setViewportSize({ width: 430, height: 844 });
      await skipPage.waitForSelector('[data-finale-root][data-finale-state="settled"]');
      const resizeSettleState =
        (await skipPage.locator("[data-finale-root]").getAttribute("data-finale-state")) ??
        undefined;
      await skipPage.setViewportSize({ width: 320, height: 844 });
      const narrow = await skipPage.evaluate(() => {
        const heading = document.querySelector<HTMLElement>("[data-finale-heading]");
        const title = heading?.querySelector<HTMLElement>("h2");
        if (heading === null || title === null || title === undefined)
          throw new Error("Narrow finale heading is missing");
        return {
          narrowTitleFontSize: Number.parseFloat(getComputedStyle(title).fontSize),
          narrowHeadingOverflow: heading.getBoundingClientRect().right - window.innerWidth,
        };
      });
      return {
        ...normal,
        ...pillSurface,
        ...resizedTrace,
        ...reduced,
        ...narrow,
        pointerSkipState,
        resizeSettleState,
      };
    } finally {
      await Promise.all([applicationPage.close(), reducedMotionPage.close(), skipPage.close()]);
    }
  },
);

function observeEnd(
  width: number,
): Omit<
  TopologyEndObservation,
  "artworkStates" | "endColourMaskEdge" | "endTerminalNodeBottom" | "attachJoinStroke"
> {
  const artwork = document.querySelector<SVGSVGElement>("[data-full-page-topology]");
  const lastGlass = document.querySelector('[data-rail-surface-target="come-back"]');
  const lastCaption = document.querySelector<HTMLElement>(
    '[data-chapter="come-back"] [data-chapter-caption]',
  );
  const button = document.querySelector<HTMLElement>("[data-final-star-button]");
  const pill = button?.closest<HTMLElement>("[data-finale-split-pill]");
  const finaleRoot = button?.closest<HTMLElement>("[data-finale-root]");
  const stage = finaleRoot?.querySelector<HTMLElement>(".finale-stage");
  const heading = finaleRoot?.querySelector<HTMLElement>("[data-finale-heading]");
  const note = finaleRoot?.querySelector<HTMLElement>("p");
  const finalRoute = artwork?.querySelector<SVGGElement>("[data-topology-terminal-route]");
  const finalPath = finalRoute?.querySelector<SVGPathElement>('[data-topology-path-role="core"]');
  const mainline = artwork?.querySelector<SVGPathElement>("[data-mainline]");
  const terminalNode = finalRoute?.querySelector<SVGGElement>("[data-topology-terminal-node]");
  const ring = terminalNode?.querySelector<SVGCircleElement>(".node-end-ring");
  const core = terminalNode?.querySelector<SVGCircleElement>(".node-end-core");
  const halo = terminalNode?.querySelector<SVGCircleElement>(".node-terminal-halo");
  if (
    artwork === null ||
    lastGlass === null ||
    lastCaption === null ||
    button === null ||
    pill === null ||
    pill === undefined ||
    finalPath === null ||
    finalPath === undefined ||
    mainline === null ||
    mainline === undefined ||
    ring === null ||
    ring === undefined ||
    core === null ||
    core === undefined ||
    halo === null ||
    halo === undefined
  )
    throw new Error("The home page is missing its final glass, button or terminal branch");
  const origin = artwork.getBoundingClientRect();
  const artworkTop = origin.top + window.scrollY;
  const points: number[] = [];
  for (const path of artwork.querySelectorAll<SVGPathElement>("path[d]")) {
    const totalLength = path.getTotalLength();
    for (let step = 0; step <= 200; step += 1) {
      points.push(artworkTop + path.getPointAtLength((totalLength * step) / 200).y);
    }
  }
  for (const circle of artwork.querySelectorAll<SVGCircleElement>("circle")) {
    points.push(artworkTop + circle.cy.baseVal.value);
  }
  const glassBox = lastGlass.getBoundingClientRect();
  const buttonBox = pill.getBoundingClientRect();
  const matrix = finalPath.getScreenCTM();
  if (matrix === null) throw new Error("Terminal route has no screen transform");
  const routeLength = finalPath.getTotalLength();
  const mainlineLength = mainline.getTotalLength();
  const mainlineStart = mainline.getPointAtLength(0);
  const mainlineEnd = mainline.getPointAtLength(mainlineLength);
  const start = finalPath.getPointAtLength(0).matrixTransform(matrix);
  const bendStart = finalPath.getPointAtLength(0);
  const bendDots = [
    ...artwork.querySelectorAll<SVGGElement>("[data-node][data-resolved-row]"),
  ].filter((node) => {
    const circle = node.querySelector<SVGCircleElement>("circle");
    return (
      circle !== null &&
      Math.hypot(
        Number(circle.getAttribute("cx")) - bendStart.x,
        Number(circle.getAttribute("cy")) - bendStart.y,
      ) <= 0.5
    );
  });
  const bendDot = bendDots[0];
  const bendCircle = bendDot?.querySelector<SVGCircleElement>(".node-commit");
  const end = finalPath.getPointAtLength(routeLength).matrixTransform(matrix);
  const mergeYs = [...artwork.querySelectorAll<SVGGElement>('[data-node-kind="merge"]')]
    .filter((node) => !node.hasAttribute("data-topology-terminal-node"))
    .map((node) => Number(node.querySelector("circle")?.getAttribute("cy")) + artworkTop);
  const rowNodes = [...artwork.querySelectorAll<SVGGElement>("[data-node][data-resolved-row]")];
  const worktreeGroups = [
    ...artwork.querySelectorAll<SVGGElement>(
      '[data-topology-route-group][data-route-kind="worktree"]',
    ),
  ].toSorted(
    (left, right) => Number(left.dataset["routeColumn"]) - Number(right.dataset["routeColumn"]),
  );
  const laneStopYs = worktreeGroups.slice(0, -1).flatMap((group) => {
    const route = group.querySelector<SVGPathElement>('[data-topology-path-role="core"]');
    if (route === null) return [];
    const endpoint = route.getPointAtLength(route.getTotalLength());
    const stopDot = rowNodes.find((node) => {
      if (node.dataset["nodeKind"] !== "commit" || node.hasAttribute("data-topology-suppressed"))
        return false;
      const circle = node.querySelector<SVGCircleElement>(".node-commit");
      return (
        circle !== null &&
        Math.hypot(
          Number(circle.getAttribute("cx")) - endpoint.x,
          Number(circle.getAttribute("cy")) - endpoint.y,
        ) <= 0.5
      );
    });
    return stopDot === undefined ? [] : [endpoint.y + artworkTop];
  });
  const ctaTitle = button.closest("section")?.querySelector<HTMLElement>("#final-cta-title");
  const titleBox = ctaTitle?.getBoundingClientRect();
  if (
    ctaTitle === null ||
    ctaTitle === undefined ||
    titleBox === undefined ||
    stage === null ||
    stage === undefined ||
    heading === null ||
    heading === undefined ||
    note === null ||
    note === undefined
  )
    throw new Error("Final CTA heading, icon stage or note missing");
  const stageBox = stage.getBoundingClientRect();
  const noteBox = note.getBoundingClientRect();
  const minimumTitleClearance = Math.min(
    ...Array.from({ length: 101 }, (_, index) => {
      const point = finalPath.getPointAtLength((routeLength * index) / 100).matrixTransform(matrix);
      const dx = Math.max(titleBox.left - point.x, 0, point.x - titleBox.right);
      const dy = Math.max(titleBox.top - point.y, 0, point.y - titleBox.bottom);
      return Math.hypot(dx, dy);
    }),
  );
  return {
    width,
    captionToFinaleGap:
      heading.getBoundingClientRect().top - lastCaption.getBoundingClientRect().bottom,
    pillLeft: buttonBox.left,
    lastGlassLeft: glassBox.left,
    stageLeft: stageBox.left,
    titleLeft: titleBox.left,
    stageRight: stageBox.right,
    titleFontSize: Number.parseFloat(getComputedStyle(ctaTitle).fontSize),
    noteLeft: noteBox.left,
    stageCenterY: (stageBox.top + stageBox.bottom) / 2,
    titleCenterY: (titleBox.top + titleBox.bottom) / 2,
    stageHeight: stageBox.height,
    titleLineHeight: Number.parseFloat(getComputedStyle(ctaTitle).lineHeight),
    pillCenterY: (buttonBox.top + buttonBox.bottom) / 2 + window.scrollY,
    branchEndX: end.x,
    branchEndY: end.y + window.scrollY,
    nodeRightX: end.x + Number(ring.getAttribute("r")),
    ringRadius: Number(ring.getAttribute("r")),
    coreRadius: Number(core.getAttribute("r")),
    haloRadius: Number(halo.getAttribute("r")),
    ringStroke: getComputedStyle(ring).stroke,
    coreFill: getComputedStyle(core).fill,
    branchStroke: getComputedStyle(finalPath).stroke,
    branchStartY: start.y + window.scrollY,
    branchStartX: start.x,
    bendDotCount: bendDots.length,
    bendDotOffset:
      bendCircle === null || bendCircle === undefined
        ? Number.POSITIVE_INFINITY
        : Math.hypot(
            Number(bendCircle.getAttribute("cx")) - bendStart.x,
            Number(bendCircle.getAttribute("cy")) - bendStart.y,
          ),
    bendDotPlain:
      bendDot?.dataset["nodeKind"] === "commit" &&
      !bendDot.hasAttribute("data-topology-suppressed") &&
      bendDot.querySelector(
        ".node-terminal, .node-terminal-halo, .node-merge-ring, .node-end-ring",
      ) === null,
    innermostLaneX:
      mainlineStart.matrixTransform(mainline.getScreenCTM() ?? matrix).x +
      Number(artwork.dataset["laneCount"]) * Number(artwork.dataset["columnUnit"]),
    mainlineEndY: mainlineEnd.matrixTransform(mainline.getScreenCTM() ?? matrix).y + window.scrollY,
    branchViewportMaxFraction: Math.max(start.y, end.y) / window.innerHeight,
    minimumTitleClearance,
    lastGlassBottomY: glassBox.bottom + window.scrollY,
    laneMergeYs: mergeYs,
    laneStopYs,
    duplicateRowDotCount:
      rowNodes.length - new Set(rowNodes.map((node) => node.dataset["resolvedRow"])).size,
    lowestRailY: Math.max(...points),
    laneCount: Number(artwork.dataset["laneCount"]),
    terminalNodeCount: artwork.querySelectorAll("[data-topology-terminal]").length,
    terminalRouteCount: artwork.querySelectorAll("[data-topology-terminal-route]").length,
    branchColumnSpan: (end.x - start.x) / Number(artwork.dataset["columnUnit"]),
    branchBendCount: (finalPath.getAttribute("d")?.match(/\bC\b/gu) ?? []).length,
    mainlineBendCount: (mainline.getAttribute("d")?.match(/\bC\b/gu) ?? []).length,
    branchMonotonicX: Array.from(
      { length: 101 },
      (_, index) => finalPath.getPointAtLength((routeLength * index) / 100).x,
    ).every((x, index, xs) => index === 0 || x >= (xs[index - 1] ?? x) - 0.01),
    branchPathData: finalPath.getAttribute("d") ?? "",
    mainlinePathData: mainline.getAttribute("d") ?? "",
    pathData: [
      ...[...artwork.querySelectorAll<SVGPathElement>("path[d]")].map((path) => ({
        kind: "rail" as const,
        d: path.getAttribute("d") ?? "",
      })),
      ...[...document.querySelectorAll<SVGPathElement>("[data-chapter-step-branch]")].map(
        (path) => ({
          kind: "step" as const,
          d: path.getAttribute("d") ?? "",
        }),
      ),
    ],
  };
}

export const verifyTopologyEnd = defineBrowserCommand(
  async (
    { context },
    pageUrl: string,
    widths: readonly number[],
    viewportHeight?: number,
  ): Promise<TopologyEndObservation[]> => {
    const applicationPage = await context.newPage();
    const observations: TopologyEndObservation[] = [];
    try {
      await applicationPage.addInitScript(() => {
        document.addEventListener("finale-bookend-ready", (event) => {
          if (!(event instanceof CustomEvent)) return;
          const control = event.detail as {
            pause(): void;
            seek(seconds: number): void;
            finish(): void;
          };
          control.pause();
          (window as Window & { finaleArtworkControl?: typeof control }).finaleArtworkControl =
            control;
        });
      });
      for (const width of widths) {
        await applicationPage.setViewportSize({
          width,
          height: viewportHeight ?? (width === 390 ? 844 : width === 1280 ? 800 : 1080),
        });
        await applicationPage.goto(pageUrl, { waitUntil: "domcontentloaded" });
        await applicationPage.waitForSelector(
          "[data-full-page-topology] [data-topology-terminal-route]",
          { state: "attached" },
        );
        await applicationPage.evaluate(() => {
          const button = document.querySelector<HTMLElement>("[data-final-star-button]");
          if (button === null) throw new Error("Final star button is missing before scroll");
          window.scrollTo({
            top:
              window.scrollY +
              button.getBoundingClientRect().top +
              button.offsetHeight / 2 -
              window.innerHeight * 0.5,
            behavior: "instant",
          });
        });
        await applicationPage.waitForSelector(
          "[data-topology-terminal-node][data-topology-node-revealed]",
          {
            state: "attached",
          },
        );
        await applicationPage.evaluate(async () => {
          const node = document.querySelector("[data-topology-terminal-node]");
          if (node === null) throw new Error("Terminal node is missing after reveal");
          const ring = node.querySelector(".node-end-ring");
          const core = node.querySelector(".node-end-core");
          await Promise.all(
            [ring, core].flatMap(
              (part) => part?.getAnimations().map((animation) => animation.finished) ?? [],
            ),
          );
        });
        await applicationPage.waitForSelector("[data-finale-timeline-created]");
        await applicationPage.evaluate(() => {
          const control = (
            window as Window & { finaleArtworkControl?: { seek(seconds: number): void } }
          ).finaleArtworkControl;
          if (control === undefined) throw new Error("Finale artwork control is missing");
          control.seek(0);
        });
        const initial = await applicationPage.evaluate(observeFinaleArtwork, {
          width,
          state: "initial" as const,
        });
        await applicationPage.locator("[data-finale-logo]").evaluate(async (element) => {
          if (!(element instanceof HTMLImageElement))
            throw new Error("Finale logo is not an image");
          await element.decode();
        });
        await applicationPage.evaluate(() => {
          const control = (window as Window & { finaleArtworkControl?: { finish(): void } })
            .finaleArtworkControl;
          if (control === undefined) throw new Error("Finale artwork control is missing");
          control.finish();
        });
        const settled = await applicationPage.evaluate(observeFinaleArtwork, {
          width,
          state: "settled" as const,
        });
        const end = await applicationPage.evaluate(observeEnd, width);
        await applicationPage.evaluate(() =>
          window.scrollTo({ top: document.documentElement.scrollHeight, behavior: "instant" }),
        );
        await applicationPage.waitForSelector("[data-full-page-topology][data-topology-at-end]");
        const colourAtEnd = await applicationPage.evaluate(() => {
          const artwork = document.querySelector<SVGSVGElement>("[data-full-page-topology]");
          const gradient = artwork?.querySelector<SVGLinearGradientElement>(
            "#topology-rail-vibrancy-gradient",
          );
          const node = artwork?.querySelector<SVGCircleElement>(
            "[data-topology-terminal-node] .node-end-ring",
          );
          const attach = artwork?.querySelector<SVGPathElement>(
            '[data-route-kind="attach"].accent-main [data-topology-path-role="core"]',
          );
          if (!gradient || !node || !attach)
            throw new Error("End colour mask or attach join missing");
          return {
            endColourMaskEdge: Number(gradient.getAttribute("y1")),
            endTerminalNodeBottom: node.cy.baseVal.value + node.r.baseVal.value,
            attachJoinStroke: getComputedStyle(attach).stroke,
          };
        });
        observations.push({ ...end, ...colourAtEnd, artworkStates: [initial, settled] });
      }
      return observations;
    } finally {
      await applicationPage.close();
    }
  },
);
