import { defineBrowserCommand } from "@vitest/browser-playwright";
import type { BrowserCommandContext } from "vitest/node";

export interface HeroLayoutObservation {
  readonly viewport: string;
  readonly rowsInsideWindow: boolean;
  readonly installBottom: number;
  readonly windowLeft: number;
  readonly windowRight: number;
  readonly windowTop: number;
  readonly windowBottom: number;
  readonly windowRadius: string;
  readonly appRadius: string;
  readonly headlineBottom: number;
  readonly columnTop: number;
  readonly rootTop: number;
  readonly appLeft: number;
  readonly appRight: number;
  readonly appBottom: number;
  readonly appTop: number;
  readonly scrollCueVisible: boolean;
  readonly scrollCueBottom: number;
  readonly scrollCueTop: number;
  readonly installCopyTop: number;
  readonly firstScreenHeight: number;
  readonly columnMarginTop: string;
  readonly descriptionTop: number;
  readonly descriptionWidth: number;
  readonly captionTop: number;
  readonly captionLeft: number;
  readonly captionRight: number;
  readonly captionRadius: string;
  readonly captionBackgroundImage: string;
  readonly captionBackdropFilter: string;
  readonly captionIconCount: number;
  readonly installCenterOffset: number;
  readonly paintedStackTop: number;
  readonly stackAngles: readonly number[];
  readonly stackPlaneLeftOffsets: readonly number[];
  readonly stackPlaneTopOffsets: readonly number[];
  readonly stackPlaneLeftPeeks: readonly number[];
  readonly stackPlaneTopPeeks: readonly number[];
  readonly stackPeekLeft: number;
  readonly stackPeekTop: number;
  readonly cursorCount: number;
  readonly documentWidth: number;
  readonly viewportWidth: number;
  readonly codexVisible: boolean;
  readonly canvasColor: string;
  readonly visibleBashRows: number;
  readonly bashSplitTokens: readonly string[];
  readonly codexPassedColor: string | undefined;
  readonly earlierExchangeVisible: boolean;
  readonly overflowElements: readonly string[];
}

export interface HeroScrollCueObservation {
  readonly visibleAtRest: boolean;
  readonly hiddenAfterScroll: boolean;
  readonly reachedFirstImage: boolean;
}

/** The phone layout must fit before the finale's responsive script can run. */
export const verifyHeroNoScriptWidth = defineBrowserCommand(
  async (
    { context },
    pageUrl: string,
  ): Promise<{ readonly documentWidth: number; readonly shortLabels: boolean }> => {
    const browser = context.browser();
    if (browser === null) throw new Error("Browser context is unavailable");
    const noScriptContext = await browser.newContext({ javaScriptEnabled: false });
    try {
      const page = await noScriptContext.newPage();
      await page.setViewportSize({ width: 390, height: 844 });
      await page.goto(pageUrl, { waitUntil: "domcontentloaded" });
      await page.locator("[data-finale-root]").waitFor();
      return await page.evaluate(async () => {
        await document.fonts.ready;
        const finale = document.querySelector<HTMLElement>("[data-finale-root]");
        if (finale === null) throw new Error("Finale is missing");
        return {
          documentWidth: document.documentElement.scrollWidth,
          shortLabels: finale.hasAttribute("data-short-labels"),
        };
      });
    } finally {
      await noScriptContext.close();
    }
  },
);

export const verifyHeroScrollCue = defineBrowserCommand(
  async ({ context }, pageUrl: string): Promise<HeroScrollCueObservation> => {
    const page = await context.newPage();
    try {
      await page.emulateMedia({ reducedMotion: "reduce" });
      await page.setViewportSize({ width: 390, height: 844 });
      await page.goto(pageUrl, { waitUntil: "domcontentloaded" });
      await page.locator("[data-hero-scroll-cue]").waitFor();
      return await page.evaluate(async (): Promise<HeroScrollCueObservation> => {
        const cue = document.querySelector<HTMLButtonElement>("[data-hero-scroll-cue]");
        const hero = document.querySelector<HTMLElement>("[data-hero-intro-root]");
        const image = document.querySelector<HTMLElement>("[data-hero-app-frame]");
        if (cue === null || hero === null || image === null) throw new Error("Hero cue is missing");
        const visibleAtRest = getComputedStyle(cue).opacity === "1";
        const reachedFirstImage = await new Promise<boolean>((resolve) => {
          const onScroll = (): void => {
            if (window.scrollY < 40 || image.getBoundingClientRect().top >= window.innerHeight)
              return;
            window.removeEventListener("scroll", onScroll);
            resolve(image.getBoundingClientRect().top < window.innerHeight);
          };
          window.addEventListener("scroll", onScroll, { passive: true });
          cue.click();
        });
        return {
          visibleAtRest,
          hiddenAfterScroll:
            hero.hasAttribute("data-hero-scrolled") &&
            getComputedStyle(cue).pointerEvents === "none",
          reachedFirstImage,
        };
      });
    } finally {
      await page.close();
    }
  },
);

export interface HeroPhoneFlowObservation {
  readonly promptBeforeWork: boolean;
  readonly progressBeforeReady: boolean;
  readonly readyAfterDecode: boolean;
  readonly streamedBeforeResult: boolean;
  readonly mapTypedBeforeWork: boolean;
  readonly phoneWorkingBeforeRows: boolean;
  readonly noCodexBurst: boolean;
  readonly resultVisible: boolean;
  readonly settledRows: readonly string[];
  readonly largestTranscriptGap: number;
  readonly clippedAtAnySample: boolean;
  readonly gapDebug: string;
}

export const verifyHeroPhoneMidIntro = defineBrowserCommand(
  async (
    { context },
    pageUrl: string,
    width: number,
    height: number,
  ): Promise<HeroPhoneFlowObservation> => {
    const page = await context.newPage();
    try {
      await page.setViewportSize({ width, height });
      await page.addInitScript((): void => {
        Object.defineProperty(document, "hidden", { configurable: true, get: () => false });
        Object.defineProperty(document, "visibilityState", {
          configurable: true,
          get: () => "visible",
        });
        (window as Window & { phoneIntroReady?: Promise<void> }).phoneIntroReady = new Promise(
          (resolve) => {
            document.addEventListener("hero-intro-playback-ready", (event) => {
              if (!(event instanceof CustomEvent)) return;
              const control = event.detail as {
                pause(): void;
                seek(seconds: number): void;
                finish(): void;
              };
              control.pause();
              (window as Window & { phoneIntroControl?: typeof control }).phoneIntroControl =
                control;
              resolve();
            });
          },
        );
      });
      await page.goto(pageUrl, { waitUntil: "commit" });
      return await page.evaluate(async (): Promise<HeroPhoneFlowObservation> => {
        await (window as Window & { phoneIntroReady?: Promise<void> }).phoneIntroReady;
        const control = (
          window as Window & { phoneIntroControl?: { seek(seconds: number): void; finish(): void } }
        ).phoneIntroControl;
        if (control === undefined) throw new Error("Phone intro control is missing");
        const prompt = document.querySelector<HTMLElement>("[data-hero-intro-typed-input]");
        const ready = document.querySelector<HTMLElement>("[data-hero-intro-ready]");
        const install = document.querySelector<HTMLElement>("[data-hero-intro-install]");
        const windowNode = document.querySelector<HTMLElement>("[data-hero-terminal-window]");
        const pane = document.querySelector<HTMLElement>(".hero-terminal-pane--claude");
        if (
          prompt === null ||
          ready === null ||
          install === null ||
          windowNode === null ||
          pane === null
        )
          throw new Error("Phone intro transcript is incomplete");
        const clipped = (): boolean => windowNode.scrollHeight > windowNode.clientHeight + 1;
        control.seek(3.2);
        const promptBeforeWork =
          (prompt.textContent?.length ?? 0) > 0 &&
          Number(getComputedStyle(ready).opacity) === 0 &&
          Number(getComputedStyle(install).opacity) === 0;
        let clippedAtAnySample = clipped();
        control.seek(5.5);
        const progressBeforeReady =
          [...pane.querySelectorAll<HTMLElement>("[data-hero-progress-row]")].some(
            (row) =>
              getComputedStyle(row).display !== "none" && Number(getComputedStyle(row).opacity) > 0,
          ) && Number(getComputedStyle(ready).opacity) === 0;
        clippedAtAnySample ||= clipped();
        control.seek(6.8);
        const readyBeforeDecodeEnds = Number(getComputedStyle(ready).opacity) > 0;
        control.seek(7.2);
        const readyAfterDecode =
          !readyBeforeDecodeEnds && Number(getComputedStyle(ready).opacity) > 0.99;
        clippedAtAnySample ||= clipped();
        control.seek(9.4);
        const mapTypedBeforeWork =
          (prompt.textContent ?? "").startsWith("map") &&
          (prompt.textContent?.length ?? 0) < "map the worktrees".length;
        const noCodexBurst =
          pane.querySelectorAll("[data-hero-token-layer] text").length === 0 &&
          document.querySelectorAll("[data-hero-token-layer] text").length === 0;
        control.seek(9.9);
        const phoneWorkingBeforeRows =
          Number(
            getComputedStyle(pane.querySelector<HTMLElement>("[data-hero-phone-working]") ?? pane)
              .opacity,
          ) > 0 &&
          [...pane.querySelectorAll<HTMLElement>("[data-hero-worktree-row]")].every(
            (row) => Number(getComputedStyle(row).opacity) === 0,
          );
        control.seek(11.3);
        const streamedBeforeResult =
          [...pane.querySelectorAll<HTMLElement>("[data-hero-worktree-row]")].some(
            (row) => Number(getComputedStyle(row).opacity) > 0,
          ) &&
          Number(
            getComputedStyle(pane.querySelector<HTMLElement>("[data-hero-worktree-result]") ?? pane)
              .opacity,
          ) === 0;
        clippedAtAnySample ||= clipped();
        control.finish();
        const visibleRows = [...pane.querySelectorAll<HTMLElement>(".hero-transcript-row")].filter(
          (row) =>
            getComputedStyle(row).display !== "none" &&
            Number(getComputedStyle(row).opacity) > 0.99,
        );
        const startupBottom = pane
          .querySelector<HTMLElement>(".hero-claude-startup")
          ?.getBoundingClientRect().bottom;
        const footerTop = pane
          .querySelector<HTMLElement>(".hero-claude-footer")
          ?.getBoundingClientRect().top;
        const rowRects = visibleRows.map((row) => row.getBoundingClientRect());
        const transcript = pane.querySelector<HTMLElement>(".hero-terminal-transcript");
        const result = pane.querySelector<HTMLElement>("[data-hero-worktree-result]");
        const resultVisible =
          transcript !== null &&
          result !== null &&
          result.getBoundingClientRect().bottom <=
            transcript.getBoundingClientRect().bottom + 0.5 &&
          result.getBoundingClientRect().bottom > transcript.getBoundingClientRect().top;
        const edges = [startupBottom, ...rowRects.map((rect) => rect.bottom)];
        const starts = [...rowRects.map((rect) => rect.top), footerTop];
        const largestTranscriptGap = Math.max(
          0,
          ...starts.map((top, index) =>
            top === undefined || edges[index] === undefined ? 0 : top - edges[index],
          ),
        );
        return {
          promptBeforeWork,
          progressBeforeReady,
          readyAfterDecode,
          streamedBeforeResult,
          mapTypedBeforeWork,
          phoneWorkingBeforeRows,
          noCodexBurst,
          resultVisible,
          settledRows: visibleRows.map((row) => row.textContent?.trim() ?? ""),
          largestTranscriptGap,
          gapDebug: JSON.stringify({
            transcriptHeight: transcript?.clientHeight,
            scrollHeight: transcript?.scrollHeight,
            scrollTop: transcript?.scrollTop,
            startupBottom,
            resultBottom: result?.getBoundingClientRect().bottom,
            footerTop,
            rows: visibleRows.length,
          }),
          clippedAtAnySample: clippedAtAnySample || clipped(),
        };
      });
    } finally {
      await page.close();
    }
  },
);

export const verifyHeroIntroLayout = defineBrowserCommand(
  async (
    { context },
    pageUrl: string,
    viewports: readonly { readonly width: number; readonly height: number }[],
  ): Promise<HeroLayoutObservation[]> => {
    const observations: HeroLayoutObservation[] = [];
    const applicationPage = await context.newPage();
    try {
      await applicationPage.emulateMedia({ reducedMotion: "reduce" });
      await applicationPage.goto(pageUrl, { waitUntil: "domcontentloaded" });
      await applicationPage.evaluate(async () => await document.fonts.ready);
      for (const viewport of viewports) {
        await applicationPage.setViewportSize(viewport);
        await applicationPage.evaluate(async (): Promise<void> => {
          const hero = document.querySelector<HTMLElement>("[data-hero-intro-root]");
          const image = document.querySelector<HTMLElement>("[data-hero-app-frame]");
          if (hero === null || image === null) throw new Error("Hero cue target missing");
          const isCurrent = (): boolean =>
            hero.hasAttribute("data-hero-frame-below-fold") ===
            image.getBoundingClientRect().top >= innerHeight;
          if (isCurrent()) return;
          await new Promise<void>((resolve) => {
            const observer = new MutationObserver((): void => {
              if (!isCurrent()) return;
              observer.disconnect();
              resolve();
            });
            observer.observe(hero, {
              attributes: true,
              attributeFilter: ["data-hero-frame-below-fold"],
            });
          });
        });
        observations.push(
          await applicationPage.evaluate(
            async ({ width, height }): Promise<HeroLayoutObservation> => {
              await document.fonts.ready;
              const windowNode = document.querySelector<HTMLElement>("[data-hero-terminal-window]");
              const appFrame = document.querySelector<HTMLElement>("[data-hero-app-frame]");
              const install = document.querySelector<HTMLElement>(
                ".hero [data-install-command-root]",
              );
              const codex = document.querySelector<HTMLElement>(".hero-terminal-pane--codex");
              const scrollCue = document.querySelector<HTMLElement>("[data-hero-scroll-cue]");
              if (windowNode === null || appFrame === null || install === null || codex === null) {
                throw new Error("Hero intro layout is incomplete");
              }
              const windowRect = windowNode.getBoundingClientRect();
              const appRect = appFrame.getBoundingClientRect();
              const description = document.querySelector<HTMLElement>(
                "[data-hero-intro-description]",
              );
              const caption = document.querySelector<HTMLElement>("[data-hero-caption]");
              const frontPlane = document.querySelector<HTMLElement>("[data-hero-icon-front]");
              const rearPlanes = [
                ...document.querySelectorAll<HTMLElement>("[data-hero-icon-rear]"),
              ];
              if (
                description === null ||
                caption === null ||
                frontPlane === null ||
                rearPlanes.length !== 2
              ) {
                throw new Error("Hero stack or description is missing");
              }
              const padding = parseFloat(getComputedStyle(windowNode).borderTopWidth);
              const angle = (element: HTMLElement): number => {
                const transform = new DOMMatrixReadOnly(getComputedStyle(element).transform);
                return Math.atan2(transform.b, transform.a) * (180 / Math.PI);
              };
              const fanPlanes = [frontPlane, ...[...rearPlanes].reverse()];
              const paintedRows = [
                ...windowNode.querySelectorAll<HTMLElement>("[data-transcript-tier]"),
              ].filter((row) => {
                if (row.getClientRects().length === 0) return false;
                for (
                  let element: HTMLElement | null = row;
                  element !== windowNode;
                  element = element.parentElement
                ) {
                  if (element === null || Number(getComputedStyle(element).opacity) === 0)
                    return false;
                }
                return true;
              });
              const bashArgs = paintedRows
                .find((row) => row.textContent?.includes("Bash("))
                ?.querySelector<HTMLElement>(".hero-terminal-muted");
              const bashSplitTokens: string[] = [];
              if (bashArgs !== undefined && bashArgs !== null) {
                const textNodes = document.createTreeWalker(bashArgs, NodeFilter.SHOW_TEXT);
                while (textNodes.nextNode()) {
                  const bashText = textNodes.currentNode;
                  for (const match of bashText.textContent?.matchAll(/\S+/gu) ?? []) {
                    const start = match.index;
                    if (start === undefined) continue;
                    const range = document.createRange();
                    range.setStart(bashText, start);
                    range.setEnd(bashText, start + match[0].length);
                    if (range.getClientRects().length > 1) bashSplitTokens.push(match[0]);
                  }
                }
              }
              const codexPassed = [...windowNode.querySelectorAll<HTMLElement>("span")].find(
                (span) => span.textContent === "14 passed",
              );
              return {
                viewport: `${width}x${height}`,
                rowsInsideWindow: paintedRows.every((row) => {
                  const rect = row.getBoundingClientRect();
                  const transcript = row.closest<HTMLElement>(".hero-terminal-transcript");
                  if (transcript !== null) {
                    const clipStyle = getComputedStyle(transcript).overflowY;
                    if (clipStyle !== "auto" && clipStyle !== "hidden") return false;
                    const clip = transcript.getBoundingClientRect();
                    const paintedTop = Math.max(rect.top, clip.top);
                    const paintedBottom = Math.min(rect.bottom, clip.bottom);
                    // The separate offscreenRowPaintLeaks assertion probes browser hit-testing.
                    if (paintedTop >= paintedBottom) return true;
                    return (
                      paintedTop >= windowRect.top + padding - 1 &&
                      paintedBottom <= windowRect.bottom - padding + 1
                    );
                  }
                  return (
                    rect.top >= windowRect.top + padding - 1 &&
                    rect.bottom <= windowRect.bottom - padding + 1
                  );
                }),
                installBottom: install.getBoundingClientRect().bottom,
                windowLeft: windowRect.left,
                windowRight: windowRect.right,
                windowTop: windowRect.top,
                windowBottom: windowRect.bottom,
                windowRadius: getComputedStyle(windowNode).borderTopLeftRadius,
                appRadius: getComputedStyle(appFrame).borderTopLeftRadius,
                headlineBottom:
                  document.querySelector("#hero-title")?.getBoundingClientRect().bottom ?? NaN,
                columnTop:
                  document.querySelector(".hero-intro-column")?.getBoundingClientRect().top ?? NaN,
                rootTop:
                  document.querySelector(".hero-intro-root")?.getBoundingClientRect().top ?? NaN,
                appLeft: appRect.left,
                appRight: appRect.right,
                appBottom: appRect.bottom,
                appTop: appRect.top,
                scrollCueVisible:
                  scrollCue !== null && Number(getComputedStyle(scrollCue).opacity) > 0.9,
                scrollCueBottom: scrollCue?.getBoundingClientRect().bottom ?? Number.NaN,
                scrollCueTop: scrollCue?.getBoundingClientRect().top ?? Number.NaN,
                installCopyTop: install.getBoundingClientRect().top,
                firstScreenHeight:
                  document.querySelector<HTMLElement>(".hero-first-screen")?.getBoundingClientRect()
                    .height ?? Number.NaN,
                columnMarginTop: getComputedStyle(
                  document.querySelector<HTMLElement>(".hero-intro-column") ?? windowNode,
                ).marginTop,
                descriptionTop: description.getBoundingClientRect().top,
                descriptionWidth: description.getBoundingClientRect().width,
                captionTop: caption.getBoundingClientRect().top,
                captionLeft: caption.getBoundingClientRect().left,
                captionRight: caption.getBoundingClientRect().right,
                captionRadius: getComputedStyle(caption).borderRadius,
                captionBackgroundImage: getComputedStyle(caption).backgroundImage,
                captionBackdropFilter: getComputedStyle(caption).backdropFilter,
                captionIconCount: caption.querySelectorAll("[data-hero-caption-icon]").length,
                installCenterOffset: Math.abs(
                  (install.getBoundingClientRect().left + install.getBoundingClientRect().right) /
                    2 -
                    (windowRect.left + windowRect.right) / 2,
                ),
                paintedStackTop: Math.min(
                  frontPlane.getBoundingClientRect().top,
                  ...rearPlanes.map((plane) => plane.getBoundingClientRect().top),
                ),
                stackAngles: fanPlanes.map(angle),
                stackPlaneLeftOffsets: fanPlanes.map((plane) =>
                  Number.parseFloat(getComputedStyle(plane).left),
                ),
                stackPlaneTopOffsets: fanPlanes.map((plane) =>
                  Number.parseFloat(getComputedStyle(plane).top),
                ),
                stackPlaneLeftPeeks: fanPlanes.map(
                  (plane) => windowRect.left - plane.getBoundingClientRect().left,
                ),
                stackPlaneTopPeeks: fanPlanes.map(
                  (plane) => windowRect.top - plane.getBoundingClientRect().top,
                ),
                stackPeekLeft:
                  windowRect.left -
                  Math.min(
                    frontPlane.getBoundingClientRect().left,
                    ...rearPlanes.map((plane) => plane.getBoundingClientRect().left),
                  ),
                stackPeekTop:
                  windowRect.top -
                  Math.min(
                    frontPlane.getBoundingClientRect().top,
                    ...rearPlanes.map((plane) => plane.getBoundingClientRect().top),
                  ),
                cursorCount: document.querySelectorAll("[data-hero-cursor]").length,
                documentWidth: document.documentElement.scrollWidth,
                viewportWidth: document.documentElement.clientWidth,
                codexVisible: getComputedStyle(codex).display !== "none",
                canvasColor: getComputedStyle(document.body).backgroundColor,
                visibleBashRows: paintedRows.filter((row) => row.textContent?.includes("Bash("))
                  .length,
                bashSplitTokens,
                codexPassedColor:
                  codexPassed === undefined ? undefined : getComputedStyle(codexPassed).color,
                earlierExchangeVisible: paintedRows.some((row) =>
                  row.textContent?.includes("sidebar filter ordering"),
                ),
                overflowElements: [...document.querySelectorAll<HTMLElement>("body *")]
                  .filter((element) => element.getBoundingClientRect().right > width + 1)
                  .slice(0, 10)
                  .map(
                    (element) =>
                      `${element.tagName}.${element.className} ${Math.round(element.getBoundingClientRect().right)}`,
                  ),
              };
            },
            viewport,
          ),
        );
      }
    } finally {
      await applicationPage.close();
    }
    return observations;
  },
);

interface HeroWindowRect {
  readonly left: number;
  readonly top: number;
  readonly width: number;
  readonly height: number;
}

export interface HeroPlaybackObservation {
  readonly midIntroWasPlaying: boolean;
  readonly fanAnglesAtEnd: readonly number[];
  readonly fourthAngleAtEnd: number;
  readonly fanBorderWidthsAtEnd: readonly number[];
  readonly fourthBorderWidthWhileDealing: number;
  readonly terminalWindowBorderWidth: number;
  readonly midIntroHorizontalOverflow: number;
  readonly resizeSettledEvents: number;
  readonly resizeProgress: number;
  readonly resizeInlineStyles: number;
  readonly resizeInlineStyleElements: readonly string[];
  readonly resizeFourthPlanes: number;
  readonly resizedWindow: HeroWindowRect;
  readonly freshNarrowWindow: HeroWindowRect;
  readonly afterSecondResizeWindow: HeroWindowRect;
  readonly freshWideWindow: HeroWindowRect;
  readonly afterSecondResizeInlineStyles: number;
  readonly reducedMotionCreatedTimeline: boolean;
  readonly keydownSettledEvents: number;
}

const observeHeroPlaybackLayout = (): {
  rect: HeroWindowRect;
  inlineStyles: number;
  inlineStyleElements: string[];
  fourthPlanes: number;
  progress: number;
} => {
  const root = document.querySelector<HTMLElement>("[data-hero-intro-root]");
  const windowNode = root?.querySelector<HTMLElement>("[data-hero-terminal-window]");
  if (root === null || windowNode === null || root === undefined || windowNode === undefined) {
    throw new Error("Hero intro is missing");
  }
  const targets = root.querySelectorAll<HTMLElement>(
    "[data-hero-intro-copy], [data-hero-icon-stack], [data-hero-icon-front], [data-hero-icon-rear], [data-hero-icon-cursor], [data-hero-terminal-window], [data-hero-intro-content], [data-hero-intro-install], [data-hero-intro-description], [data-hero-intro-glow], [data-hero-intro-typed-input], [data-hero-intro-spinner], .hero-transcript-row",
  );
  const rect = windowNode.getBoundingClientRect();
  return {
    rect: { left: rect.left, top: rect.top, width: rect.width, height: rect.height },
    inlineStyles: [...targets].filter((target) => target.hasAttribute("style")).length,
    inlineStyleElements: [...targets]
      .filter((target) => target.hasAttribute("style"))
      .map((target) => `${target.tagName}.${target.className}: ${target.getAttribute("style")}`),
    fourthPlanes: root.querySelectorAll("[data-hero-intro-fourth-plane]").length,
    progress: Number(root.getAttribute("data-hero-intro-progress")),
  };
};

async function openHeroPlaybackPage(
  context: BrowserCommandContext["context"],
): Promise<Awaited<ReturnType<BrowserCommandContext["context"]["newPage"]>>> {
  const applicationPage = await context.newPage();
  try {
    await applicationPage.addInitScript(() => {
      Object.defineProperty(document, "hidden", { configurable: true, get: () => false });
      Object.defineProperty(document, "visibilityState", {
        configurable: true,
        get: () => "visible",
      });
      let resolveReady: (state: "playing" | "settled") => void = () => {};
      const ready = new Promise<"playing" | "settled">((resolve) => {
        resolveReady = resolve;
      });
      (window as Window & { heroIntroReady?: typeof ready }).heroIntroReady = ready;
      document.addEventListener("hero-intro-playback-ready", (event) => {
        if (!(event instanceof CustomEvent)) return;
        const control = event.detail as { pause(): void; seek(seconds: number): void };
        control.pause();
        (
          window as Window & { heroIntroPlaybackControl?: typeof control }
        ).heroIntroPlaybackControl = control;
        resolveReady("playing");
      });
      document.addEventListener("hero-intro-settled", () => resolveReady("settled"), {
        once: true,
      });
    });

    await applicationPage.route(/\.(mp4|webm)(\?|$)/u, async (route) => {
      await route.abort();
    });
    return applicationPage;
  } catch (error: unknown) {
    await applicationPage.close();
    throw error;
  }
}

export const verifyHeroIntroDealtFan = defineBrowserCommand(
  async (
    { context },
    pageUrl: string,
  ): Promise<
    Pick<
      HeroPlaybackObservation,
      | "midIntroWasPlaying"
      | "fanAnglesAtEnd"
      | "fourthAngleAtEnd"
      | "fanBorderWidthsAtEnd"
      | "fourthBorderWidthWhileDealing"
      | "terminalWindowBorderWidth"
      | "midIntroHorizontalOverflow"
    >
  > => {
    const introPage = await openHeroPlaybackPage(context);
    try {
      await introPage.setViewportSize({ width: 1600, height: 1000 });
      await introPage.goto(pageUrl, { waitUntil: "commit" });
      const introReady = await introPage.evaluate(
        async () => await (window as Window & { heroIntroReady?: Promise<string> }).heroIntroReady,
      );
      if (introReady !== "playing") throw new Error(`Intro settled before control: ${introReady}`);
      await introPage.evaluate(() => {
        const control = (
          window as Window & { heroIntroPlaybackControl?: { seek(seconds: number): void } }
        ).heroIntroPlaybackControl;
        if (control === undefined) throw new Error("Hero intro playback control is missing");
        control.seek(3);
      });
      const midIntroWasPlaying = await introPage.evaluate(
        () =>
          document
            .querySelector("[data-hero-intro-root]")
            ?.getAttribute("data-hero-intro-state") === "playing",
      );
      const fourthBorderWidthWhileDealing = await introPage.evaluate(() => {
        (
          window as Window & { heroIntroPlaybackControl?: { seek(seconds: number): void } }
        ).heroIntroPlaybackControl?.seek(1.8);
        const fourth = document.querySelector("[data-hero-intro-fourth-plane]");
        if (fourth === null) throw new Error("Hero fourth plane is missing while dealing");
        return Number.parseFloat(getComputedStyle(fourth).borderTopWidth);
      });
      await introPage.evaluate(() => {
        (
          window as Window & { heroIntroPlaybackControl?: { seek(seconds: number): void } }
        ).heroIntroPlaybackControl?.seek(3.2);
      });
      const { fanAnglesAtEnd, fourthAngleAtEnd, fanBorderWidthsAtEnd, terminalWindowBorderWidth } =
        await introPage.evaluate(() => {
          const angle = (element: Element): number => {
            const transform = new DOMMatrixReadOnly(getComputedStyle(element).transform);
            return Math.atan2(transform.b, transform.a) * (180 / Math.PI);
          };
          const front = document.querySelector("[data-hero-icon-front]");
          const rearOne = document.querySelector('[data-hero-icon-rear="one"]');
          const rearTwo = document.querySelector('[data-hero-icon-rear="two"]');
          const fourth = document.querySelector("[data-hero-intro-fourth-plane]");
          const terminalWindow = document.querySelector("[data-hero-terminal-window]");
          if (
            front === null ||
            rearOne === null ||
            rearTwo === null ||
            fourth === null ||
            terminalWindow === null
          ) {
            throw new Error("Hero fan, fourth plane, or terminal window is incomplete");
          }
          const borderWidth = (element: Element): number =>
            Number.parseFloat(getComputedStyle(element).borderTopWidth);
          return {
            fanAnglesAtEnd: [front, rearTwo, rearOne].map(angle),
            fourthAngleAtEnd: angle(fourth),
            fanBorderWidthsAtEnd: [front, rearTwo, rearOne, fourth].map(borderWidth),
            terminalWindowBorderWidth: borderWidth(terminalWindow),
          };
        });
      const midIntroHorizontalOverflow = await introPage.evaluate(
        () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
      );

      return {
        midIntroWasPlaying,
        fanAnglesAtEnd,
        fourthAngleAtEnd,
        fanBorderWidthsAtEnd,
        fourthBorderWidthWhileDealing,
        terminalWindowBorderWidth,
        midIntroHorizontalOverflow,
      };
    } finally {
      await introPage.close();
    }
  },
);

export const verifyHeroIntroResize = defineBrowserCommand(
  async (
    { context },
    pageUrl: string,
  ): Promise<
    Pick<
      HeroPlaybackObservation,
      | "resizeSettledEvents"
      | "resizeProgress"
      | "resizeInlineStyles"
      | "resizeInlineStyleElements"
      | "resizeFourthPlanes"
      | "resizedWindow"
      | "freshNarrowWindow"
    >
  > => {
    const introPage = await openHeroPlaybackPage(context);
    const freshNarrowPage = await openHeroPlaybackPage(context);
    try {
      await introPage.setViewportSize({ width: 1600, height: 1000 });
      await introPage.goto(pageUrl, { waitUntil: "commit" });
      const introReady = await introPage.evaluate(
        async () => await (window as Window & { heroIntroReady?: Promise<string> }).heroIntroReady,
      );
      if (introReady !== "playing") throw new Error(`Intro settled before control: ${introReady}`);
      await introPage.evaluate(() => {
        const control = (
          window as Window & { heroIntroPlaybackControl?: { seek(seconds: number): void } }
        ).heroIntroPlaybackControl;
        if (control === undefined) throw new Error("Hero intro playback control is missing");
        control.seek(3);
      });
      await introPage.evaluate(() => {
        const control = (
          window as Window & { heroIntroPlaybackControl?: { seek(seconds: number): void } }
        ).heroIntroPlaybackControl;
        if (control === undefined) throw new Error("Hero intro playback control is missing");
        control.seek(1.8);
        control.seek(3.2);
      });
      await introPage.evaluate(() => {
        const root = document.querySelector("[data-hero-intro-root]");
        root?.setAttribute("data-test-settled-events", "0");
        root?.addEventListener("hero-intro-settled", () => {
          root.setAttribute(
            "data-test-settled-events",
            String(Number(root.getAttribute("data-test-settled-events")) + 1),
          );
        });
      });
      await introPage.setViewportSize({ width: 1100, height: 1000 });
      await introPage.waitForSelector('[data-hero-intro-state="settled"]');
      const resized = await introPage.evaluate(observeHeroPlaybackLayout);
      const resizeSettledEvents = await introPage.evaluate(() =>
        Number(
          document
            .querySelector("[data-hero-intro-root]")
            ?.getAttribute("data-test-settled-events"),
        ),
      );

      await freshNarrowPage.emulateMedia({ reducedMotion: "reduce" });
      await freshNarrowPage.setViewportSize({ width: 1100, height: 1000 });
      await freshNarrowPage.goto(pageUrl, { waitUntil: "domcontentloaded" });
      const narrow = await freshNarrowPage.evaluate(observeHeroPlaybackLayout);

      return {
        resizeSettledEvents,
        resizeProgress: resized.progress,
        resizeInlineStyles: resized.inlineStyles,
        resizeInlineStyleElements: resized.inlineStyleElements,
        resizeFourthPlanes: resized.fourthPlanes,
        resizedWindow: resized.rect,
        freshNarrowWindow: narrow.rect,
      };
    } finally {
      await Promise.all([introPage.close(), freshNarrowPage.close()]);
    }
  },
);

export const verifyHeroIntroReducedMotion = defineBrowserCommand(
  async (
    { context },
    pageUrl: string,
  ): Promise<Pick<HeroPlaybackObservation, "reducedMotionCreatedTimeline">> => {
    const freshNarrowPage = await openHeroPlaybackPage(context);
    try {
      await freshNarrowPage.emulateMedia({ reducedMotion: "reduce" });
      await freshNarrowPage.setViewportSize({ width: 1100, height: 1000 });
      await freshNarrowPage.goto(pageUrl, { waitUntil: "domcontentloaded" });

      const reducedMotionCreatedTimeline = await freshNarrowPage.evaluate(
        () =>
          document
            .querySelector("[data-hero-intro-root]")
            ?.hasAttribute("data-hero-intro-timeline-created") ?? false,
      );

      return { reducedMotionCreatedTimeline };
    } finally {
      await freshNarrowPage.close();
    }
  },
);

export const verifyHeroIntroKeydown = defineBrowserCommand(
  async (
    { context },
    pageUrl: string,
  ): Promise<Pick<HeroPlaybackObservation, "keydownSettledEvents">> => {
    const keydownPage = await openHeroPlaybackPage(context);
    try {
      await keydownPage.setViewportSize({ width: 1600, height: 1000 });
      await keydownPage.goto(pageUrl, { waitUntil: "commit" });
      const keydownReady = await keydownPage.evaluate(
        async () => await (window as Window & { heroIntroReady?: Promise<string> }).heroIntroReady,
      );
      if (keydownReady !== "playing")
        throw new Error(`Keydown intro settled before control: ${keydownReady}`);
      await keydownPage.evaluate(() => {
        const control = (
          window as Window & { heroIntroPlaybackControl?: { seek(seconds: number): void } }
        ).heroIntroPlaybackControl;
        if (control === undefined) throw new Error("Hero intro playback control is missing");
        control.seek(3);
      });
      await keydownPage.evaluate(() => {
        const root = document.querySelector("[data-hero-intro-root]");
        root?.setAttribute("data-test-settled-events", "0");
        root?.addEventListener(
          "hero-intro-settled",
          () => {
            root.setAttribute("data-test-settled-events", "1");
          },
          { once: true },
        );
      });
      await keydownPage.keyboard.press("ArrowDown");
      await keydownPage.waitForSelector('[data-hero-intro-state="settled"]');
      const keydownSettledEvents = await keydownPage.evaluate(() =>
        Number(
          document
            .querySelector("[data-hero-intro-root]")
            ?.getAttribute("data-test-settled-events"),
        ),
      );
      return { keydownSettledEvents };
    } finally {
      await keydownPage.close();
    }
  },
);

export const verifyHeroIntroSecondResize = defineBrowserCommand(
  async (
    { context },
    pageUrl: string,
  ): Promise<
    Pick<
      HeroPlaybackObservation,
      "afterSecondResizeWindow" | "freshWideWindow" | "afterSecondResizeInlineStyles"
    >
  > => {
    const introPage = await openHeroPlaybackPage(context);
    const freshWidePage = await openHeroPlaybackPage(context);
    try {
      await introPage.setViewportSize({ width: 1600, height: 1000 });
      await introPage.goto(pageUrl, { waitUntil: "commit" });
      const introReady = await introPage.evaluate(
        async () => await (window as Window & { heroIntroReady?: Promise<string> }).heroIntroReady,
      );
      if (introReady !== "playing") throw new Error(`Intro settled before control: ${introReady}`);
      await introPage.evaluate(() => {
        const control = (
          window as Window & { heroIntroPlaybackControl?: { seek(seconds: number): void } }
        ).heroIntroPlaybackControl;
        if (control === undefined) throw new Error("Hero intro playback control is missing");
        control.seek(3);
      });
      await introPage.evaluate(() => {
        const control = (
          window as Window & { heroIntroPlaybackControl?: { seek(seconds: number): void } }
        ).heroIntroPlaybackControl;
        if (control === undefined) throw new Error("Hero intro playback control is missing");
        control.seek(1.8);
        control.seek(3.2);
      });
      await introPage.setViewportSize({ width: 1100, height: 1000 });
      await introPage.waitForSelector('[data-hero-intro-state="settled"]');
      await introPage.setViewportSize({ width: 1600, height: 1000 });
      const afterSecondResize = await introPage.evaluate(observeHeroPlaybackLayout);
      await freshWidePage.emulateMedia({ reducedMotion: "reduce" });
      await freshWidePage.setViewportSize({ width: 1600, height: 1000 });
      await freshWidePage.goto(pageUrl, { waitUntil: "domcontentloaded" });
      const wide = await freshWidePage.evaluate(observeHeroPlaybackLayout);

      return {
        afterSecondResizeWindow: afterSecondResize.rect,
        freshWideWindow: wide.rect,
        afterSecondResizeInlineStyles: afterSecondResize.inlineStyles,
      };
    } finally {
      await Promise.all([introPage.close(), freshWidePage.close()]);
    }
  },
);

export interface HeroRefreshObservation {
  readonly reloadState: string | null;
  readonly reloadScrollY: number;
  readonly programmaticScrollState: string | null;
  readonly wheelState: string | null;
  readonly hashState: string | null;
  readonly hashCreatedTimeline: boolean;
}

export const verifyHeroIntroRefresh = defineBrowserCommand(
  async ({ context }, pageUrl: string): Promise<HeroRefreshObservation> => {
    const applicationPage = await context.newPage();
    const hashPage = await context.newPage();
    try {
      await applicationPage.addInitScript(() => {
        Object.defineProperty(document, "hidden", { configurable: true, get: () => false });
        document.addEventListener("hero-intro-playback-ready", (event) => {
          if (event instanceof CustomEvent) {
            (event.detail as { pause(): void }).pause();
          }
        });
      });
      await applicationPage.goto(pageUrl, { waitUntil: "domcontentloaded" });
      await applicationPage.evaluate(() => window.scrollTo(0, 1800));
      await applicationPage.reload({ waitUntil: "domcontentloaded" });
      await applicationPage.waitForSelector('[data-hero-intro-state="playing"]');
      const reloadState = await applicationPage
        .locator("[data-hero-intro-root]")
        .getAttribute("data-hero-intro-state");
      const reloadScrollY = await applicationPage.evaluate(() => window.scrollY);
      await applicationPage.evaluate(() => window.scrollTo(0, 100));
      const programmaticScrollState = await applicationPage
        .locator("[data-hero-intro-root]")
        .getAttribute("data-hero-intro-state");
      await applicationPage.evaluate(() => window.dispatchEvent(new WheelEvent("wheel")));
      const wheelState = await applicationPage
        .locator("[data-hero-intro-root]")
        .getAttribute("data-hero-intro-state");

      const hashUrl = new URL(pageUrl);
      hashUrl.hash = "many-agents";
      await hashPage.goto(hashUrl.href, { waitUntil: "domcontentloaded" });
      const hashRoot = hashPage.locator("[data-hero-intro-root]");
      const hashState = await hashRoot.getAttribute("data-hero-intro-state");
      const hashCreatedTimeline = await hashRoot.evaluate((root) =>
        root.hasAttribute("data-hero-intro-timeline-created"),
      );
      return {
        reloadState,
        reloadScrollY,
        programmaticScrollState,
        wheelState,
        hashState,
        hashCreatedTimeline,
      };
    } finally {
      await Promise.all([applicationPage.close(), hashPage.close()]);
    }
  },
);

export interface HeroShiftObservation {
  readonly time: number | "settled";
  readonly appTop: number;
  readonly windowHeight: number;
  readonly chapterNodeY: number;
}

export const verifyHeroIntroShift = defineBrowserCommand(
  async (
    { context },
    pageUrl: string,
    width: number,
    height: number,
  ): Promise<HeroShiftObservation[]> => {
    const applicationPage = await context.newPage();
    applicationPage.on("response", (response) => {
      if (response.status() >= 400)
        process.stdout.write(
          `shift ${width} ${response.status()} ${new URL(response.url()).pathname}\n`,
        );
    });
    try {
      await applicationPage.setViewportSize({ width, height });
      await applicationPage.addInitScript(() => {
        Object.defineProperty(document, "hidden", { configurable: true, get: () => false });
        Object.defineProperty(document, "visibilityState", {
          configurable: true,
          get: () => "visible",
        });
        let resolveReady: (state: "playing" | "settled") => void = () => {};
        const ready = new Promise<"playing" | "settled">((resolve) => {
          resolveReady = resolve;
        });
        (window as Window & { heroIntroReady?: typeof ready }).heroIntroReady = ready;
        document.addEventListener("hero-intro-playback-ready", (event) => {
          if (!(event instanceof CustomEvent)) return;
          const control = event.detail as {
            pause(): void;
            seek(seconds: number): void;
            finish(): void;
          };
          control.pause();
          (
            window as Window & { heroIntroPlaybackControl?: typeof control }
          ).heroIntroPlaybackControl = control;
          resolveReady("playing");
        });
        document.addEventListener("hero-intro-settled", () => resolveReady("settled"), {
          once: true,
        });
      });
      await applicationPage.goto(pageUrl, { waitUntil: "commit" });
      const ready = await applicationPage.evaluate(
        async () => await (window as Window & { heroIntroReady?: Promise<string> }).heroIntroReady,
      );
      if (ready !== "playing") throw new Error(`Shift intro settled before control: ${ready}`);
      await applicationPage.waitForSelector('[data-topology-chapter-node="many-agents"] circle', {
        state: "attached",
      });
      return await applicationPage.evaluate(async () => {
        await document.fonts.ready;
        const control = (
          window as Window & {
            heroIntroPlaybackControl?: { seek(seconds: number): void; finish(): void };
          }
        ).heroIntroPlaybackControl;
        if (control === undefined) throw new Error("Hero intro playback control is missing");
        const observe = (time: number | "settled"): HeroShiftObservation => {
          const appFrame = document.querySelector<HTMLElement>("[data-hero-app-frame]");
          const windowNode = document.querySelector<HTMLElement>("[data-hero-terminal-window]");
          const artwork = document.querySelector<SVGSVGElement>("[data-full-page-topology]");
          const chapterNode = artwork?.querySelector<SVGCircleElement>(
            '[data-topology-chapter-node="many-agents"] circle',
          );
          if (
            appFrame === null ||
            windowNode === null ||
            artwork === null ||
            chapterNode === null ||
            chapterNode === undefined
          ) {
            throw new Error("Hero or rail geometry is missing");
          }
          return {
            time,
            appTop: appFrame.getBoundingClientRect().top,
            windowHeight: windowNode.getBoundingClientRect().height,
            chapterNodeY:
              artwork.getBoundingClientRect().top + Number(chapterNode.getAttribute("cy")),
          };
        };
        const samples: HeroShiftObservation[] = [];
        for (const second of [0, 3.5, 4.2, 4.6]) {
          control.seek(second);
          samples.push(observe(second));
        }
        control.finish();
        samples.push(observe("settled"));
        return samples;
      });
    } finally {
      await applicationPage.close();
    }
  },
);
