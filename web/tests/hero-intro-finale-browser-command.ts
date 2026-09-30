import { defineBrowserCommand } from "@vitest/browser-playwright";

import { planHeroRailStaircase } from "../src/hero-intro/hero-intro-rail-draw";

interface FinaleSample {
  readonly time: number | "settled";
  readonly firstLine: number;
  readonly secondLine: number;
  readonly firstPayoff: number;
  readonly secondPayoff: number;
  readonly payoffOverflow: number;
  readonly installTransform: string;
  readonly installOpacity: number;
  readonly realCommandLines: readonly string[];
  readonly visibleDecodeLines: number;
  readonly readyOpacity: number;
  readonly claudeProgressOpacities: readonly number[];
  readonly codexTypedText: string;
  readonly codexWorkingOpacity: number;
  readonly worktreeRowOpacities: readonly number[];
  readonly worktreeResultOpacity: number;
  readonly copyOpacity: number;
  readonly railClip: string;
  readonly railRevealY: number;
  readonly heroNodeY: number;
  readonly introDotOpacities: readonly number[];
  readonly introDotScales: readonly number[];
  readonly introDotYs: readonly number[];
  readonly introDotCenterDeltas: readonly number[];
  readonly introDotTransformIdentities: readonly boolean[];
  readonly introDotDebug: readonly string[];
  readonly heroBranchDashOffset: number;
  readonly forkDashOffsets: readonly number[];
  readonly rowOpacity: readonly number[];
  readonly tokenCount: number;
  readonly tokenTextOverlaps: number;
  readonly tokenVisuals: readonly {
    readonly opacity: number;
    readonly fontSize: number;
    readonly weight: string;
    readonly fill: string;
  }[];
  readonly railBurstTargetDistance: number;
  readonly installBurstSourceXGap: number;
  readonly installBurstSourceYGap: number;
  readonly installBurstTargetXGap: number;
  readonly installBurstTargetYGap: number;
  readonly installTokenVerticalStrays: number;
  readonly installArrivalTokens: readonly {
    readonly index: number;
    readonly distance: number;
    readonly opacity: number;
  }[];
  readonly tokenLayerViewportOffset: number;
  readonly claudeInputText: string;
  readonly codexInputText: string;
  readonly transcriptClearances: readonly number[];
  readonly transcriptScrollTops: readonly number[];
  readonly transcriptOverflows: readonly number[];
  readonly firstVisibleRowTopGaps: readonly number[];
  readonly firstVisibleRowDebug: readonly string[];
  readonly worktreeRowLineCounts: readonly number[];
  readonly claudeRowLineCounts: readonly number[];
  readonly wrappedClaudeRows: readonly string[];
  readonly resultVisibleInPane: boolean;
  readonly offscreenRowPaintLeaks: number;
  readonly codexHeaderVisible: boolean;
  readonly claudeSpinnerVisible: boolean;
  readonly heroText: string;
  readonly codexHeaderText: string;
  readonly codexFooterText: string;
  readonly worktreeTexts: readonly string[];
  readonly appTop: number;
  readonly windowHeight: number;
  readonly chapterNodeY: number;
}

export interface FinaleObservation {
  readonly wheelScrolls: readonly {
    readonly pane: string;
    readonly transcriptBefore: number;
    readonly transcriptAfter: number;
    readonly pageBefore: number;
    readonly pageAfter: number;
  }[];
  readonly samples: readonly FinaleSample[];
  readonly directSeekSpinnerVisible: boolean;
  readonly scrollProbe: {
    readonly overflow: number;
    readonly scrollTop: number;
    readonly resultVisible: boolean;
  };
  readonly staircase: ReturnType<typeof planHeroRailStaircase>;
  readonly resizeRailClip: string;
  readonly resizeRailStyle: string | null;
  readonly resizeSceneInlineStyles: number;
  readonly resizeRailIntroMarkers: number;
  readonly resizeRailResidualTransforms: number;
  readonly skipRailClip: string;
  readonly skipFinaleOpacity: readonly number[];
  readonly skipSceneInlineStyles: number;
  readonly skipRailIntroMarkers: number;
  readonly skipRailResidualTransforms: number;
  readonly reducedRailClip: string;
  readonly reducedFinaleOpacity: readonly number[];
  readonly reducedRailIntroMarkers: number;
  readonly reducedRailResidualTransforms: number;
}

export const verifyHeroIntroFinale = defineBrowserCommand(
  async (
    { context },
    pageUrl: string,
    width: number,
    height: number,
  ): Promise<FinaleObservation> => {
    const page = await context.newPage();
    const reducedPage = await context.newPage();
    try {
      await page.setViewportSize({ width, height });
      await page.addInitScript(() => {
        Object.defineProperty(document, "hidden", { configurable: true, get: () => false });
        Object.defineProperty(document, "visibilityState", {
          configurable: true,
          get: () => "visible",
        });
        let resolveReady: (control: {
          pause(): void;
          seek(seconds: number): void;
          finish(): void;
        }) => void = () => {};
        const ready = new Promise<{ pause(): void; seek(seconds: number): void; finish(): void }>(
          (resolve) => {
            resolveReady = resolve;
          },
        );
        (window as Window & { finaleReady?: typeof ready }).finaleReady = ready;
        document.addEventListener("hero-intro-playback-ready", (event) => {
          if (!(event instanceof CustomEvent)) return;
          const control = event.detail as Awaited<typeof ready>;
          control.pause();
          resolveReady(control);
        });
      });
      await page.goto(pageUrl, { waitUntil: "commit" });
      await page.evaluate(
        async () => await (window as Window & { finaleReady?: Promise<unknown> }).finaleReady,
      );
      await page.waitForSelector('[data-topology-chapter-node="many-agents"] circle', {
        state: "attached",
      });
      const rowCount = await page.evaluate((): number => {
        const rail = document.querySelector<SVGSVGElement>("[data-full-page-topology]");
        const hero = rail?.querySelector<SVGGElement>('[data-topology-chapter-node="hero"]');
        const branch = rail?.querySelector<SVGPathElement>(
          '[data-route-anchor="hero"] [data-topology-path-role="core"]',
        );
        if (
          rail === null ||
          hero === null ||
          branch === null ||
          hero === undefined ||
          branch === undefined
        )
          throw new Error("Hero rail rows are missing");
        const firstY = Number(hero.querySelector("circle")?.getAttribute("cy"));
        const lastY = branch.getPointAtLength(0).y;
        const ys = [...rail.querySelectorAll<SVGGElement>("[data-topology-node-progress]")]
          .map((node) => Number(node.querySelector("circle")?.getAttribute("cy")))
          .filter((y) => y >= firstY - 0.5 && y <= lastY + 0.5)
          .sort((left, right) => left - right);
        return ys.filter((y, index) => index === 0 || Math.abs(y - (ys[index - 1] ?? y)) > 0.5)
          .length;
      });
      const staircase = planHeroRailStaircase(rowCount, width >= 1024 ? 13.25 : 13.55);
      const firstHop = staircase.hops[0];
      const secondHop = staircase.hops[1];
      const finalHop = staircase.hops.at(-1);
      if (firstHop === undefined || secondHop === undefined || finalHop === undefined)
        throw new Error("Hero rail timing schedule is incomplete");
      const holdMiddle = (firstHop.arrival + secondHop.start) / 2;
      const sampleTimes = [
        ...[0.5, 0.7, 0.8, 0.9, 0.93].map((fraction) => Number((7.05 + fraction * 0.9).toFixed(3))),
        ...Array.from({ length: 21 }, (_, index) =>
          Number((7.05 + (0.6 + index * 0.02) * 0.9).toFixed(3)),
        ),
        0,
        0.2,
        0.3,
        0.45,
        0.8,
        0.9,
        1.5,
        2.2,
        2.5,
        3.2,
        3.5,
        3.75,
        3.9,
        4.15,
        4.3,
        4.35,
        4.5,
        4.9,
        5.1,
        5.2,
        5.4,
        5.5,
        5.8,
        5.85,
        5.9,
        5.99,
        6.1,
        6.25,
        6.4,
        6.5,
        6.63,
        6.75,
        6.8,
        7.0,
        7.2,
        7.22,
        7.275,
        7.4,
        7.5,
        7.56,
        7.725,
        7.96,
        7.8,
        7.76,
        7.9,
        8.0,
        8.2,
        8.82,
        8.795,
        9.02,
        9.0,
        9.245,
        9.48,
        8.3,
        8.8,
        9.22,
        9.72,
        10.3,
        9.9,
        11.0,
        11.3,
        9.9,
        10.7,
        11.4,
        11.47,
        11.65,
        11.9,
        12.3,
        12.5,
        12.575,
        12.8,
        12.875,
        13.025,
        13.1,
        13.325,
        13.56,
        13.65,
        11.7,
        staircase.start,
        holdMiddle,
        finalHop.start,
        staircase.end,
        staircase.end + 0.1,
        ...staircase.hops.flatMap((hop, index) => {
          const popStart =
            index === 0 ? staircase.start : (staircase.hops[index - 1]?.arrival ?? hop.start);
          return [popStart + 0.06, popStart + 0.22];
        }),
      ].sort((left, right) => left - right);
      const timelineProof = await page.evaluate(
        async (
          sampleTimes,
        ): Promise<{
          samples: FinaleSample[];
          scrollProbe: FinaleObservation["scrollProbe"];
          directSeekSpinnerVisible: boolean;
        }> => {
          await document.fonts.ready;
          const control = await (
            window as Window & {
              finaleReady?: Promise<{ seek(seconds: number): void; finish(): void }>;
            }
          ).finaleReady;
          if (control === undefined) throw new Error("Finale control missing");
          const observe = (time: number | "settled"): FinaleSample => {
            const root = document.querySelector<HTMLElement>("[data-hero-intro-root]");
            const rail = document.querySelector<SVGSVGElement>("[data-full-page-topology]");
            const app = document.querySelector<HTMLElement>("[data-hero-app-frame]");
            const windowNode = root?.querySelector<HTMLElement>("[data-hero-terminal-window]");
            const chapterNode = rail?.querySelector<SVGCircleElement>(
              '[data-topology-chapter-node="many-agents"] circle',
            );
            if (
              root === null ||
              rail === null ||
              app === null ||
              windowNode === null ||
              windowNode === undefined ||
              chapterNode === null ||
              chapterNode === undefined
            )
              throw new Error("Finale geometry missing");
            const target = (selector: string): HTMLElement => {
              const element = root.querySelector<HTMLElement>(selector);
              if (element === null) throw new Error(`Finale target missing: ${selector}`);
              return element;
            };
            const opacity = (selector: string): number =>
              Number(getComputedStyle(target(selector)).opacity);
            const pane = innerWidth < 1024 ? "claude" : "codex";
            const railClip = getComputedStyle(rail).clipPath;
            const bottomInset = /([\d.]+)%\)/u.exec(railClip);
            const heroNode = rail.querySelector<SVGGElement>('[data-topology-chapter-node="hero"]');
            const heroBranch = rail.querySelector<SVGPathElement>(
              '[data-route-anchor="hero"] [data-topology-path-role="core"]',
            );
            const heroNodeY = Number(heroNode?.querySelector("circle")?.getAttribute("cy"));
            const branchStartY = heroBranch?.getPointAtLength(0).y ?? Number.NaN;
            const introNodes = [
              ...rail.querySelectorAll<SVGGElement>("[data-topology-node-progress]"),
            ]
              .filter((node) => {
                const y = Number(node.querySelector("circle")?.getAttribute("cy"));
                return y >= heroNodeY && y <= branchStartY;
              })
              .sort(
                (left, right) =>
                  Number(left.querySelector("circle")?.getAttribute("cy")) -
                  Number(right.querySelector("circle")?.getAttribute("cy")),
              );
            const install = target("[data-hero-intro-install]");
            const payoff = target("[data-hero-intro-payoff-first]").parentElement;
            if (payoff === null) throw new Error("Payoff wrapper missing");
            const realCommandLines = [
              ...install.querySelectorAll<HTMLElement>(".install-command__line"),
            ].map((line) =>
              [...line.childNodes]
                .filter(
                  (node) =>
                    !(node instanceof HTMLElement && node.hasAttribute("data-install-decode-line")),
                )
                .map((node) => node.textContent ?? "")
                .join(""),
            );
            const tokens = [
              ...root.querySelectorAll<SVGTextElement>("[data-hero-token-layer] text"),
            ];
            const bashRow = [
              ...root.querySelectorAll<HTMLElement>(
                ".hero-terminal-pane--claude .hero-transcript-row--tool-call",
              ),
            ].find(
              (row) => row.getClientRects().length > 0 && row.querySelector("[data-hero-bash-dot]"),
            );
            const firstCommand = install.querySelector<HTMLElement>(".install-command__line");
            const tokenLayerForInstall =
              root.querySelector<SVGSVGElement>("[data-hero-token-layer]");
            if (bashRow === undefined || firstCommand === null)
              throw new Error("Install burst anchors missing");
            const textWalker = document.createTreeWalker(bashRow, NodeFilter.SHOW_TEXT);
            let lastTextNode: Text | undefined;
            while (textWalker.nextNode()) {
              const textNode = textWalker.currentNode;
              if (textNode instanceof Text && textNode.textContent?.trim()) lastTextNode = textNode;
            }
            if (lastTextNode === undefined) throw new Error("Bash row has no text");
            const lastGlyph = document.createRange();
            lastGlyph.setStart(lastTextNode, Math.max(0, lastTextNode.length - 1));
            lastGlyph.setEnd(lastTextNode, lastTextNode.length);
            const glyphBounds = lastGlyph.getBoundingClientRect();
            const commandBounds = firstCommand.getBoundingClientRect();
            const burstStartX = Number(
              tokenLayerForInstall?.getAttribute("data-hero-install-start-x"),
            );
            const burstStartY = Number(
              tokenLayerForInstall?.getAttribute("data-hero-install-start-y"),
            );
            const burstEndX = Number(tokenLayerForInstall?.getAttribute("data-hero-install-end-x"));
            const burstEndY = Number(tokenLayerForInstall?.getAttribute("data-hero-install-end-y"));
            const textRects = [
              ...root.querySelectorAll<HTMLElement>(
                ".hero-transcript-row, .hero-claude-input, .hero-codex-input, .hero-claude-footer, .hero-codex-footer, .install-command__line, [data-hero-intro-copy], [data-hero-intro-eyebrow-settled]",
              ),
            ]
              .filter(
                (row) =>
                  row.getClientRects().length > 0 &&
                  row.checkVisibility({ opacityProperty: true, visibilityProperty: true }),
              )
              .flatMap((row) => {
                const range = document.createRange();
                range.selectNodeContents(row);
                return [...range.getClientRects()];
              });
            const tokenTextOverlaps = tokens.filter((token) => {
              const tokenRect = token.getBoundingClientRect();
              return textRects.some(
                (rect) =>
                  tokenRect.left < rect.right &&
                  tokenRect.right > rect.left &&
                  tokenRect.top < rect.bottom &&
                  tokenRect.bottom > rect.top,
              );
            }).length;
            const tokenLayer = root.querySelector<SVGSVGElement>("[data-hero-token-layer]");
            const targetX = Number(tokenLayer?.getAttribute("data-hero-burst-end-x"));
            const targetY = Number(tokenLayer?.getAttribute("data-hero-burst-end-y"));
            const topNodeBounds = heroNode?.getBoundingClientRect();
            const railBurstTargetDistance =
              topNodeBounds === undefined || topNodeBounds === null
                ? Number.POSITIVE_INFINITY
                : Math.hypot(
                    targetX - (topNodeBounds.left + topNodeBounds.width / 2),
                    targetY - (topNodeBounds.top + topNodeBounds.height / 2),
                  );
            const transcriptMeasurements = [
              ...root.querySelectorAll<HTMLElement>(".hero-terminal-pane"),
            ]
              .filter((pane) => pane.getClientRects().length > 0)
              .map((pane) => {
                const transcript = pane.querySelector<HTMLElement>(".hero-terminal-transcript");
                const pinned = pane.querySelector<HTMLElement>(
                  ".hero-claude-footer, .hero-codex-footer",
                );
                if (transcript === null || pinned === null)
                  throw new Error("Pinned transcript structure is missing");
                const transcriptBounds = transcript.getBoundingClientRect();
                const paintedRow = (row: HTMLElement): boolean => {
                  if (row.getClientRects().length === 0) return false;
                  for (
                    let element: Element | null = row;
                    element !== null && element !== transcript;
                    element = element.parentElement
                  ) {
                    if (Number(getComputedStyle(element).opacity) < 0.05) return false;
                  }
                  return true;
                };
                const firstVisibleRow = [
                  ...transcript.querySelectorAll<HTMLElement>(
                    ".hero-claude-startup, .hero-codex-startup, .hero-transcript-row",
                  ),
                ]
                  .filter(paintedRow)
                  .find((row) => row.getBoundingClientRect().bottom > transcriptBounds.top + 0.5);
                const visibleBottom = [
                  ...transcript.querySelectorAll<HTMLElement>(".hero-transcript-row"),
                ]
                  .filter(
                    (row) =>
                      row.getClientRects().length > 0 &&
                      Number(getComputedStyle(row).opacity) > 0.05,
                  )
                  .map((row) =>
                    Math.min(row.getBoundingClientRect().bottom, transcriptBounds.bottom),
                  )
                  .filter((bottom) => bottom > transcriptBounds.top)
                  .reduce((bottom, candidate) => Math.max(bottom, candidate), transcriptBounds.top);
                return {
                  firstVisibleRowTopGap:
                    firstVisibleRow === undefined
                      ? 0
                      : firstVisibleRow.getBoundingClientRect().top - transcriptBounds.top,
                  firstVisibleRowDebug:
                    firstVisibleRow === undefined
                      ? "none"
                      : `${firstVisibleRow.className}: ${firstVisibleRow.textContent?.trim().slice(0, 50)}; bottom=${firstVisibleRow.getBoundingClientRect().bottom - transcriptBounds.top}; scroll=${transcript.scrollTop}/${transcript.scrollHeight - transcript.clientHeight}`,
                  clearance: pinned.getBoundingClientRect().top - visibleBottom,
                  scrollTop: transcript.scrollTop,
                  overflow: transcript.scrollHeight - transcript.clientHeight,
                };
              });
            const activeTranscript = root.querySelector<HTMLElement>(
              `.hero-terminal-pane--${pane} .hero-terminal-transcript`,
            );
            const activeResult = root.querySelector<HTMLElement>(
              `.hero-terminal-pane--${pane} [data-hero-worktree-result]`,
            );
            const resultVisibleInPane =
              activeTranscript !== null &&
              activeResult !== null &&
              activeResult.getBoundingClientRect().bottom <=
                activeTranscript.getBoundingClientRect().bottom + 0.5 &&
              activeResult.getBoundingClientRect().bottom >
                activeTranscript.getBoundingClientRect().top;
            const offscreenRowPaintLeaks = [
              ...root.querySelectorAll<HTMLElement>(
                ".hero-terminal-transcript .hero-transcript-row",
              ),
            ].filter((row) => {
              const transcript = row.closest<HTMLElement>(".hero-terminal-transcript");
              if (transcript === null || row.getClientRects().length === 0) return false;
              const rowRect = row.getBoundingClientRect();
              const clip = transcript.getBoundingClientRect();
              const sampleY =
                rowRect.bottom <= clip.top
                  ? Math.max(0, rowRect.bottom - 1)
                  : rowRect.top >= clip.bottom
                    ? Math.min(innerHeight - 1, rowRect.top + 1)
                    : null;
              if (sampleY === null || sampleY < 0 || sampleY >= innerHeight) return false;
              const hit = document.elementFromPoint(clip.left + clip.width / 2, sampleY);
              return hit !== null && row.contains(hit);
            }).length;
            const codexTranscript = root.querySelector<HTMLElement>(
              ".hero-terminal-pane--codex .hero-terminal-transcript",
            );
            const codexHeader = root.querySelector<HTMLElement>(".hero-codex-startup");
            const codexHeaderVisible =
              codexTranscript === null ||
              codexHeader === null ||
              innerWidth < 1024 ||
              codexHeader.getBoundingClientRect().top >=
                codexTranscript.getBoundingClientRect().top - 1;
            const claudeTranscript = root.querySelector<HTMLElement>(
              ".hero-terminal-pane--claude .hero-terminal-transcript",
            );
            const claudeSpinner = root.querySelector<HTMLElement>("[data-hero-intro-spinner]");
            const claudeSpinnerVisible =
              claudeTranscript !== null &&
              claudeSpinner !== null &&
              claudeSpinner.getBoundingClientRect().bottom <=
                claudeTranscript.getBoundingClientRect().bottom + 1 &&
              claudeSpinner.getBoundingClientRect().bottom >
                claudeTranscript.getBoundingClientRect().top;
            return {
              time,
              tokenCount: tokens.length,
              tokenTextOverlaps,
              tokenVisuals: tokens.map((token) => ({
                opacity: Number(token.getAttribute("opacity")),
                fontSize: Number(token.getAttribute("font-size")),
                weight: token.getAttribute("font-weight") ?? "",
                fill: token.getAttribute("fill") ?? "",
              })),
              railBurstTargetDistance,
              installBurstSourceXGap: burstStartX - glyphBounds.right,
              installBurstSourceYGap: Math.abs(
                burstStartY - (glyphBounds.top + glyphBounds.height / 2),
              ),
              installBurstTargetXGap: commandBounds.left - burstEndX,
              installBurstTargetYGap: Math.abs(
                burstEndY - (commandBounds.top + commandBounds.height / 2),
              ),
              installTokenVerticalStrays: tokens.filter((token) => {
                const bounds = token.getBoundingClientRect();
                return (
                  bounds.top < glyphBounds.top - 20 || bounds.bottom > commandBounds.bottom + 20
                );
              }).length,
              installArrivalTokens: tokens.map((token) => {
                const bounds = token.getBoundingClientRect();
                return {
                  index: Number(token.getAttribute("data-hero-burst-token-index")),
                  distance: Math.hypot(
                    bounds.left + bounds.width / 2 - (commandBounds.left - 14),
                    bounds.top + bounds.height / 2 - (commandBounds.top + commandBounds.height / 2),
                  ),
                  opacity: Number(token.getAttribute("opacity")),
                };
              }),
              tokenLayerViewportOffset: Math.hypot(
                tokenLayerForInstall?.getBoundingClientRect().left ?? 0,
                tokenLayerForInstall?.getBoundingClientRect().top ?? 0,
              ),
              claudeInputText:
                root.querySelector<HTMLElement>("[data-hero-intro-typed-input]")?.textContent ?? "",
              codexInputText:
                root.querySelector<HTMLElement>("[data-hero-codex-typed-input]")?.textContent ?? "",
              transcriptClearances: transcriptMeasurements.map(
                (measurement) => measurement.clearance,
              ),
              transcriptScrollTops: transcriptMeasurements.map(
                (measurement) => measurement.scrollTop,
              ),
              transcriptOverflows: transcriptMeasurements.map(
                (measurement) => measurement.overflow,
              ),
              firstVisibleRowTopGaps: transcriptMeasurements.map(
                (measurement) => measurement.firstVisibleRowTopGap,
              ),
              firstVisibleRowDebug: transcriptMeasurements.map(
                (measurement) => measurement.firstVisibleRowDebug,
              ),
              worktreeRowLineCounts: [
                ...root.querySelectorAll<HTMLElement>(
                  ".hero-terminal-pane--claude [data-hero-worktree-row]",
                ),
              ]
                .filter((row) => row.getClientRects().length > 0)
                .map((row) => {
                  const range = document.createRange();
                  range.selectNodeContents(row);
                  return new Set([...range.getClientRects()].map((rect) => Math.round(rect.top)))
                    .size;
                }),
              claudeRowLineCounts: [
                ...root.querySelectorAll<HTMLElement>(
                  ".hero-terminal-pane--claude .hero-transcript-row",
                ),
              ]
                .filter((row) => row.getClientRects().length > 0)
                .map((row) => {
                  const range = document.createRange();
                  range.selectNodeContents(row);
                  return new Set([...range.getClientRects()].map((rect) => Math.round(rect.top)))
                    .size;
                }),
              wrappedClaudeRows: [
                ...root.querySelectorAll<HTMLElement>(
                  ".hero-terminal-pane--claude .hero-transcript-row",
                ),
              ]
                .filter((row) => row.getClientRects().length > 0)
                .filter((row) => {
                  const range = document.createRange();
                  range.selectNodeContents(row);
                  return (
                    new Set([...range.getClientRects()].map((rect) => Math.round(rect.top))).size >
                    1
                  );
                })
                .map((row) => row.textContent ?? ""),
              resultVisibleInPane,
              offscreenRowPaintLeaks,
              codexHeaderVisible,
              claudeSpinnerVisible,
              heroText: root.textContent ?? "",
              codexHeaderText: root.querySelector(".hero-codex-startup")?.textContent ?? "",
              codexFooterText: root.querySelector(".hero-codex-status")?.textContent ?? "",
              worktreeTexts: [
                ...root.querySelectorAll<HTMLElement>(
                  `.hero-terminal-pane--${pane} [data-hero-worktree-row]`,
                ),
              ].map((row) => row.textContent?.trim() ?? ""),
              firstLine: opacity("[data-hero-intro-headline-first]"),
              secondLine: opacity("[data-hero-intro-headline-second]"),
              firstPayoff: opacity("[data-hero-intro-payoff-first]"),
              secondPayoff: opacity("[data-hero-intro-payoff-second]"),
              payoffOverflow: payoff.scrollWidth - payoff.clientWidth,
              installTransform: getComputedStyle(install).transform,
              installOpacity: Number(getComputedStyle(install).opacity),
              realCommandLines,
              visibleDecodeLines: [
                ...install.querySelectorAll<HTMLElement>("[data-install-decode-line]"),
              ].filter((line) => Number(getComputedStyle(line).opacity) > 0.05).length,
              readyOpacity: opacity("[data-hero-intro-ready]"),
              claudeProgressOpacities: [
                ...root.querySelectorAll<HTMLElement>("[data-hero-progress-row]"),
              ]
                .filter((row) => getComputedStyle(row).display !== "none")
                .map((row) => Number(getComputedStyle(row).opacity)),
              codexTypedText:
                root.querySelector<HTMLElement>("[data-hero-codex-typed-input]")?.textContent ?? "",
              codexWorkingOpacity: Number(
                getComputedStyle(
                  root.querySelector<HTMLElement>("[data-hero-codex-working]") ?? root,
                ).opacity,
              ),
              worktreeRowOpacities: [
                ...root.querySelectorAll<HTMLElement>(
                  `.hero-terminal-pane--${pane} [data-hero-worktree-row]`,
                ),
              ].map((row) => Number(getComputedStyle(row).opacity)),
              worktreeResultOpacity: Number(
                getComputedStyle(
                  root.querySelector<HTMLElement>(
                    `.hero-terminal-pane--${pane} [data-hero-worktree-result]`,
                  ) ?? root,
                ).opacity,
              ),
              copyOpacity: Number(getComputedStyle(target("[data-install-copy]")).opacity),
              railClip,
              heroNodeY: rail.getBoundingClientRect().top + heroNodeY,
              introDotOpacities: introNodes.map((node) => Number(getComputedStyle(node).opacity)),
              introDotScales: introNodes.map(
                (node) => new DOMMatrixReadOnly(getComputedStyle(node).transform).a,
              ),
              introDotYs: introNodes.map((node) =>
                Number(node.querySelector("circle")?.getAttribute("cy")),
              ),
              introDotCenterDeltas: introNodes.map((node) => {
                const circle = node.querySelector<SVGCircleElement>("circle");
                const parent = node.parentElement;
                if (circle === null || !(parent instanceof SVGGraphicsElement))
                  throw new Error("Intro dot circle or parent missing");
                const nodeMatrix = node.getCTM();
                const parentMatrix = parent.getCTM();
                if (nodeMatrix === null || parentMatrix === null)
                  throw new Error("Intro dot matrix missing");
                const center = new DOMPoint(
                  Number(circle.getAttribute("cx")),
                  Number(circle.getAttribute("cy")),
                );
                const expected = center.matrixTransform(parentMatrix);
                const actual = center.matrixTransform(nodeMatrix);
                return Math.hypot(actual.x - expected.x, actual.y - expected.y);
              }),
              // The current chapter's separate CSS pulse may scale the computed
              // matrix slightly; the intro must leave no GSAP-owned transform.
              introDotTransformIdentities: introNodes.map(
                (node) =>
                  node.style.transform === "" &&
                  !node.hasAttribute("transform") &&
                  !node.hasAttribute("data-svg-origin"),
              ),
              introDotDebug: introNodes.map(
                (node) =>
                  `${node.querySelector("circle")?.getAttribute("cx")},${node.querySelector("circle")?.getAttribute("cy")} origin=${node.getAttribute("data-svg-origin")} transform=${getComputedStyle(node).transform}`,
              ),
              heroBranchDashOffset:
                heroBranch === null
                  ? Number.NaN
                  : Number.parseFloat(getComputedStyle(heroBranch).strokeDashoffset),
              forkDashOffsets: [
                ...rail.querySelectorAll<SVGPathElement>(
                  '[data-route-kind="worktree"] [data-topology-path-role="core"]',
                ),
              ]
                .filter((path) => path.getPointAtLength(0).y <= branchStartY)
                .map((path) => Number.parseFloat(getComputedStyle(path).strokeDashoffset)),
              railRevealY:
                bottomInset === null
                  ? Number.POSITIVE_INFINITY
                  : rail.getBoundingClientRect().top +
                    rail.getBoundingClientRect().height * (1 - Number(bottomInset[1]) / 100),
              rowOpacity: [
                ...root.querySelectorAll<HTMLElement>(
                  `.hero-terminal-pane--${pane} [data-hero-intro-finale-row]:not([data-hero-codex-working])`,
                ),
              ]
                .filter((row) => getComputedStyle(row).display !== "none")
                .map((row) => Number(getComputedStyle(row).opacity)),
              appTop: app.getBoundingClientRect().top,
              windowHeight: windowNode.getBoundingClientRect().height,
              chapterNodeY:
                rail.getBoundingClientRect().top + Number(chapterNode.getAttribute("cy")),
            };
          };
          const observations: FinaleSample[] = [];
          control.seek(5.5);
          const directSpinner = document.querySelector<HTMLElement>("[data-hero-intro-spinner]");
          const directTranscript = directSpinner?.closest<HTMLElement>(".hero-terminal-transcript");
          const directSeekSpinnerVisible =
            directSpinner !== null &&
            directSpinner !== undefined &&
            directTranscript !== null &&
            directTranscript !== undefined &&
            Number(getComputedStyle(directSpinner).opacity) > 0.9 &&
            directSpinner.getBoundingClientRect().bottom <=
              directTranscript.getBoundingClientRect().bottom + 1;
          control.seek(0);
          for (const terminalTranscript of document.querySelectorAll<HTMLElement>(
            ".hero-terminal-transcript",
          ))
            terminalTranscript.scrollTop = 0;
          for (const second of sampleTimes) {
            control.seek(second);
            observations.push(observe(second));
          }
          const windowNode = document.querySelector<HTMLElement>("[data-hero-terminal-window]");
          const paneName = innerWidth < 1024 ? "claude" : "codex";
          const transcript = document.querySelector<HTMLElement>(
            `.hero-terminal-pane--${paneName} .hero-terminal-transcript`,
          );
          const result = transcript?.querySelector<HTMLElement>("[data-hero-worktree-result]");
          if (
            windowNode === null ||
            transcript === null ||
            transcript === undefined ||
            result === null ||
            result === undefined
          )
            throw new Error("Constrained transcript proof is incomplete");
          windowNode.style.height = "180px";
          control.seek(9.9);
          control.seek(12.75);
          const scrollProbe = {
            overflow: transcript.scrollHeight - transcript.clientHeight,
            scrollTop: transcript.scrollTop,
            resultVisible:
              result.getBoundingClientRect().bottom <=
              transcript.getBoundingClientRect().bottom + 0.5,
          };
          windowNode.style.removeProperty("height");
          control.finish();
          observations.push(observe("settled"));
          return { samples: observations, scrollProbe, directSeekSpinnerVisible };
        },
        sampleTimes,
      );
      const wheelScrolls: FinaleObservation["wheelScrolls"][number][] = [];
      for (const pane of width < 1024 ? ["claude"] : ["claude", "codex"]) {
        const transcript = page.locator(`.hero-terminal-pane--${pane} .hero-terminal-transcript`);
        const bounds = await transcript.boundingBox();
        if (bounds === null) throw new Error(`Visible ${pane} transcript missing`);
        await page.mouse.move(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2);
        const before = await transcript.evaluate((element) => {
          const scrollFinished = new Promise<void>((resolve) => {
            // Arm after the actual wheel so pending programmatic scrolls cannot close the probe.
            element.addEventListener(
              "wheel",
              () =>
                document.addEventListener("scrollend", () => resolve(), {
                  once: true,
                  capture: true,
                }),
              { once: true, passive: true },
            );
          });
          (window as Window & { wheelScrollFinished?: Promise<void> }).wheelScrollFinished =
            scrollFinished;
          return { transcript: element.scrollTop, page: window.scrollY };
        });
        await page.mouse.wheel(0, 80);
        const after = await transcript.evaluate(async (element) => {
          await (window as Window & { wheelScrollFinished?: Promise<void> }).wheelScrollFinished;
          return { transcript: element.scrollTop, page: window.scrollY };
        });
        wheelScrolls.push({
          pane,
          transcriptBefore: before.transcript,
          transcriptAfter: after.transcript,
          pageBefore: before.page,
          pageAfter: after.page,
        });
      }
      await page.reload({ waitUntil: "commit" });
      await page.evaluate(
        async () => await (window as Window & { finaleReady?: Promise<unknown> }).finaleReady,
      );
      await page.evaluate(async () =>
        (
          await (window as Window & { finaleReady?: Promise<{ seek(seconds: number): void }> })
            .finaleReady
        )?.seek(6.4),
      );
      await page.setViewportSize({ width: width < 1024 ? 430 : 1200, height });
      await page.waitForSelector('[data-hero-intro-state="settled"]');
      const resize = await page.evaluate(() => {
        const rail = document.querySelector<SVGSVGElement>("[data-full-page-topology]");
        if (rail === null) throw new Error("Resized rail missing");
        const sceneTargets = document.querySelectorAll<HTMLElement>(
          "[data-hero-intro-eyebrow-settled], [data-hero-intro-headline-first], [data-hero-intro-headline-second], [data-hero-intro-payoff-first], [data-hero-intro-payoff-second], [data-hero-intro-finale-row]",
        );
        return {
          clip: getComputedStyle(rail).clipPath,
          style: rail.getAttribute("style"),
          sceneInlineStyles: [...sceneTargets].filter((target) => target.hasAttribute("style"))
            .length,
          introMarkers: rail.querySelectorAll(
            "[data-hero-intro-rail-node], [data-hero-intro-rail-path]",
          ).length,
          residualTransforms: [...rail.querySelectorAll<SVGGElement>("[data-node]")].filter(
            (node) =>
              node.hasAttribute("transform") ||
              node.hasAttribute("data-svg-origin") ||
              node.style.transform !== "",
          ).length,
        };
      });
      await page.reload({ waitUntil: "commit" });
      await page.evaluate(
        async () => await (window as Window & { finaleReady?: Promise<unknown> }).finaleReady,
      );
      await page.evaluate(async () =>
        (
          await (window as Window & { finaleReady?: Promise<{ seek(seconds: number): void }> })
            .finaleReady
        )?.seek(6.4),
      );
      await page.keyboard.press("Escape");
      await page.waitForSelector('[data-hero-intro-state="settled"]');
      const skipped = await page.evaluate(() => {
        const rail = document.querySelector<SVGSVGElement>("[data-full-page-topology]");
        if (rail === null) throw new Error("Skipped rail missing");
        const pane = innerWidth < 1024 ? "claude" : "codex";
        return {
          clip: getComputedStyle(rail).clipPath,
          rowOpacity: [
            ...document.querySelectorAll<HTMLElement>(
              `.hero-terminal-pane--${pane} [data-hero-intro-finale-row]:not([data-hero-codex-working])`,
            ),
          ].map((row) => Number(getComputedStyle(row).opacity)),
          sceneInlineStyles: document.querySelectorAll(
            "[data-hero-intro-eyebrow-settled][style], [data-hero-intro-headline-first][style], [data-hero-intro-headline-second][style], [data-hero-intro-payoff-first][style], [data-hero-intro-payoff-second][style], [data-hero-intro-finale-row][style]",
          ).length,
          introMarkers: rail.querySelectorAll(
            "[data-hero-intro-rail-node], [data-hero-intro-rail-path]",
          ).length,
          residualTransforms: [...rail.querySelectorAll<SVGGElement>("[data-node]")].filter(
            (node) =>
              node.hasAttribute("transform") ||
              node.hasAttribute("data-svg-origin") ||
              node.style.transform !== "",
          ).length,
        };
      });
      await reducedPage.emulateMedia({ reducedMotion: "reduce" });
      await reducedPage.setViewportSize({ width, height });
      await reducedPage.goto(pageUrl, { waitUntil: "domcontentloaded" });
      const reduced = await reducedPage.evaluate(() => {
        const rail = document.querySelector<SVGSVGElement>("[data-full-page-topology]");
        if (rail === null) throw new Error("Reduced-motion rail missing");
        const pane = innerWidth < 1024 ? "claude" : "codex";
        return {
          clip: getComputedStyle(rail).clipPath,
          rowOpacity: [
            ...document.querySelectorAll<HTMLElement>(
              `.hero-terminal-pane--${pane} [data-hero-intro-finale-row]:not([data-hero-codex-working])`,
            ),
          ].map((row) => Number(getComputedStyle(row).opacity)),
          introMarkers: rail.querySelectorAll(
            "[data-hero-intro-rail-node], [data-hero-intro-rail-path]",
          ).length,
          residualTransforms: [...rail.querySelectorAll<SVGGElement>("[data-node]")].filter(
            (node) =>
              node.hasAttribute("transform") ||
              node.hasAttribute("data-svg-origin") ||
              node.style.transform !== "",
          ).length,
        };
      });
      return {
        wheelScrolls,
        samples: timelineProof.samples,
        directSeekSpinnerVisible: timelineProof.directSeekSpinnerVisible,
        scrollProbe: timelineProof.scrollProbe,
        staircase,
        resizeRailClip: resize.clip,
        resizeRailStyle: resize.style,
        resizeSceneInlineStyles: resize.sceneInlineStyles,
        resizeRailIntroMarkers: resize.introMarkers,
        resizeRailResidualTransforms: resize.residualTransforms,
        skipRailClip: skipped.clip,
        skipFinaleOpacity: skipped.rowOpacity,
        skipSceneInlineStyles: skipped.sceneInlineStyles,
        skipRailIntroMarkers: skipped.introMarkers,
        skipRailResidualTransforms: skipped.residualTransforms,
        reducedRailClip: reduced.clip,
        reducedFinaleOpacity: reduced.rowOpacity,
        reducedRailIntroMarkers: reduced.introMarkers,
        reducedRailResidualTransforms: reduced.residualTransforms,
      };
    } finally {
      await page.close();
      await reducedPage.close();
    }
  },
);
