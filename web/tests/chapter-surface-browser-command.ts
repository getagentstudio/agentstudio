import { defineBrowserCommand } from "@vitest/browser-playwright";

/** One chapter's title anchor and its rail node, read from the served home page. */
export interface ChapterTitleAnchorObservation {
  readonly width: number;
  readonly chapterId: string;
  readonly anchorTagName: string;
  /** Elements inside the chapter whose whole text reads "Chapter N". */
  readonly eyebrowCount: number;
  readonly titleFirstLineCenterY: number;
  readonly nodeCenterY: number;
}

/** One step tab in the step list. */
export interface ChapterStepTabObservation {
  readonly stepId: string;
  readonly accessibleName: string;
  readonly centerX: number;
  readonly centerY: number;
  readonly width: number;
  readonly height: number;
  /** Whether the step label inside the tab is visibly rendered. */
  readonly labelVisible: boolean;
}

/** The step region at one moment: which copy is visible and where focus is. */
export interface ChapterStepSnapshot {
  readonly visiblePanelIds: readonly string[];
  /** Visible text of the visible panels. */
  readonly visibleText: string;
  readonly focusedStepId: string | undefined;
  readonly selectedStepId: string | undefined;
  readonly activeLabelGap: number;
  readonly activeBranchAnimationCount: number;
  readonly captionHeight: number;
  readonly nextSectionTop: number;
  readonly progressWidth: number;
  readonly expectedProgressWidth: number;
  readonly visibleStepLabels: readonly string[];
  readonly panelHeights: readonly number[];
  readonly panelStyles: readonly string[];
}

interface ViewportRect {
  readonly top: number;
  readonly bottom: number;
  readonly left: number;
  readonly right: number;
}

/** Where the title, stage, steps, and branch endpoint sit relative to the chapter's glass. */
export interface ChapterGlassLayoutObservation {
  readonly glass: ViewportRect;
  readonly pill: ViewportRect;
  readonly caption: ViewportRect;
  readonly title: ViewportRect;
  readonly stage: ViewportRect;
  readonly stepList: ViewportRect;
  readonly lineStart: ViewportRect;
  /** Whether each part is a descendant of the glass surface element. */
  readonly titleInGlass: boolean;
  readonly stageInGlass: boolean;
  readonly stepListInPill: boolean;
  readonly stepPanelsInCaption: boolean;
  readonly glassChildCount: number;
  readonly realCaptureTextCount: number;
  readonly captionRadius: string;
  readonly captionBackground: string;
  readonly captionBackgroundImage: string;
  readonly captionBackdropFilter: string;
  readonly captionBorderColor: string;
  readonly captionTextColor: string;
  readonly captionIconCount: number;
  readonly pillMaterialMatchesHeader: boolean;
  readonly stepLineBackdrop: string;
  /** Elements in the chapter measured for autoplay centring, and whether the one is the stage. */
  readonly playbackStageCount: number;
  readonly playbackStageIsStage: boolean;
  readonly branchEndpoint: { readonly x: number; readonly y: number };
  readonly targetEdge: string | undefined;
  readonly portNodeCount: number;
}

export interface ChapterStepRowObservation {
  readonly width: number;
  readonly glassLayout: ChapterGlassLayoutObservation;
  readonly orientation: string | null;
  readonly role: string | null;
  readonly tabs: readonly ChapterStepTabObservation[];
  readonly labels: Readonly<Record<string, string>>;
  readonly initial: ChapterStepSnapshot;
  readonly afterSceneAdvance: ChapterStepSnapshot;
  readonly afterArrowRight: ChapterStepSnapshot;
  readonly afterHome: ChapterStepSnapshot;
  readonly afterEnd: ChapterStepSnapshot;
  readonly afterClicks: readonly ChapterStepSnapshot[];
  /** The same chapter served with JavaScript off. */
  readonly withoutScript: ChapterStepSnapshot;
}

interface ChapterStepRowRequest {
  readonly pageUrl: string;
  readonly width: number;
  readonly height?: number;
  readonly chapterId: string;
}

export interface ChapterLayoutObservation {
  readonly pillCount: number;
  readonly descriptionCount: number;
  readonly titleBottom: number;
  readonly titleLeft: number;
  readonly glassTop: number;
  readonly glassBottom: number;
  readonly glassLeft: number;
  readonly captionTop: number;
  readonly captionLeft: number;
  readonly targetEdge: string | null;
}

export interface CaptionTextObservation {
  readonly width: number;
  readonly captions: readonly {
    readonly paragraphWidth: number;
    readonly innerWidth: number;
    readonly lineCount: number;
    readonly lastLineWordCount: number;
    readonly textWrap: string;
  }[];
}

export const verifyCaptionTextLayout = defineBrowserCommand(
  async (
    { context },
    pageUrl: string,
    widths: readonly number[],
  ): Promise<CaptionTextObservation[]> => {
    const page = await context.newPage();
    try {
      const observations: CaptionTextObservation[] = [];
      for (const width of widths) {
        await page.setViewportSize({ width, height: 1000 });
        await page.goto(pageUrl, { waitUntil: "domcontentloaded" });
        observations.push(
          await page.evaluate(() => {
            const captions = [
              ...document.querySelectorAll<HTMLElement>(
                "[data-hero-caption], [data-chapter-caption]",
              ),
            ];
            return {
              width: innerWidth,
              captions: captions.map((caption) => {
                const paragraph = [
                  ...caption.querySelectorAll<HTMLElement>(
                    ".chapter-caption__copy p, p.chapter-caption__copy",
                  ),
                ].find((candidate) => {
                  const panel = candidate.closest("[data-chapter-step-panel]");
                  return (
                    getComputedStyle(candidate).display !== "none" &&
                    panel?.getAttribute("aria-hidden") !== "true"
                  );
                });
                if (paragraph === undefined) throw new Error("Visible caption paragraph missing");
                const textNode = paragraph.firstChild;
                if (textNode === null || textNode.nodeType !== Node.TEXT_NODE)
                  throw new Error("Caption text node missing");
                const content = textNode.textContent ?? "";
                const lineWordCounts = new Map<number, number>();
                for (const match of content.matchAll(/\S+/gu)) {
                  const range = document.createRange();
                  range.setStart(textNode, match.index);
                  range.setEnd(textNode, match.index + match[0].length);
                  const top = Math.round(range.getBoundingClientRect().top);
                  lineWordCounts.set(top, (lineWordCounts.get(top) ?? 0) + 1);
                }
                const lastLineWordCount = [...lineWordCounts.values()].at(-1) ?? 0;
                return {
                  paragraphWidth: paragraph.getBoundingClientRect().width,
                  innerWidth:
                    caption.clientWidth -
                    parseFloat(getComputedStyle(caption).paddingLeft) -
                    parseFloat(getComputedStyle(caption).paddingRight),
                  lineCount: lineWordCounts.size,
                  lastLineWordCount,
                  textWrap: getComputedStyle(paragraph).textWrap,
                };
              }),
            };
          }),
        );
      }
      return observations;
    } finally {
      await page.close();
    }
  },
);

export const verifyChapterLayout = defineBrowserCommand(
  async ({ context }, request: ChapterStepRowRequest): Promise<ChapterLayoutObservation> => {
    const applicationPage = await context.newPage();
    try {
      await openChapter(applicationPage, request);
      await applicationPage.waitForSelector('.site-header[data-visual-state="floating"]');
      await applicationPage.waitForSelector(
        `[data-route-kind="attach"][data-route-anchor="${request.chapterId}"]`,
        { state: "attached" },
      );
      return await applicationPage.evaluate((chapterId): ChapterLayoutObservation => {
        const article = document.getElementById(chapterId);
        const title = article?.querySelector("[data-rail-anchor]");
        const glass = article?.querySelector("[data-rail-surface-target]");
        const caption = article?.querySelector(".chapter-caption");
        const route = document.querySelector(
          `[data-route-kind="attach"][data-route-anchor="${chapterId}"]`,
        );
        if (
          article === null ||
          title === null ||
          glass === null ||
          caption === null ||
          route === null ||
          article === undefined ||
          title === undefined ||
          glass === undefined ||
          caption === undefined
        ) {
          throw new Error(`Chapter layout ${chapterId} is incomplete`);
        }
        const titleRect = title.getBoundingClientRect();
        const glassRect = glass.getBoundingClientRect();
        const captionRect = caption.getBoundingClientRect();
        return {
          pillCount: article.querySelectorAll("[data-chapter-step-list]").length,
          descriptionCount: caption.querySelectorAll("[data-chapter-step-panel]").length,
          titleBottom: titleRect.bottom,
          titleLeft: titleRect.left,
          glassTop: glassRect.top,
          glassBottom: glassRect.bottom,
          glassLeft: glassRect.left,
          captionTop: captionRect.top,
          captionLeft: captionRect.left,
          targetEdge: route.getAttribute("data-target-edge"),
        };
      }, request.chapterId);
    } finally {
      await applicationPage.close();
    }
  },
);

function observeTitleAnchors(width: number): ChapterTitleAnchorObservation[] {
  return [...document.querySelectorAll<HTMLElement>("article[data-chapter]")].map((article) => {
    const chapterId = article.dataset["chapter"] ?? "";
    const anchor = article.querySelector<HTMLElement>("[data-rail-anchor]");
    const node = document.querySelector(`[data-topology-chapter-node="${chapterId}"] circle`);
    if (anchor === null || node === null) {
      throw new Error(
        `Chapter ${chapterId} at ${width}px is missing ${anchor === null ? "anchor" : "rail node"}; nodes=${document.querySelectorAll("[data-topology-chapter-node]").length}`,
      );
    }
    const range = document.createRange();
    range.selectNodeContents(anchor);
    const firstLine = [...range.getClientRects()].find((box) => box.width > 0 && box.height > 0);
    const artwork = document.querySelector<SVGSVGElement>("[data-full-page-topology]");
    if (artwork === null) throw new Error("Topology artwork is missing");
    const nodeY = Number(node.getAttribute("cy"));
    return {
      width,
      chapterId,
      anchorTagName: anchor.tagName,
      eyebrowCount: [...article.querySelectorAll("*")].filter((element) =>
        /^chapter\s+\d+$/iu.test(element.textContent.trim()),
      ).length,
      titleFirstLineCenterY:
        firstLine === undefined ? Number.NaN : firstLine.top + firstLine.height / 2,
      nodeCenterY: artwork.getBoundingClientRect().top + nodeY,
    };
  });
}

/**
 * Loads the served home page at each width with reduced motion (so glass
 * surfaces do not lift mid-read) and reports every chapter's title anchor and
 * the rail node drawn for it.
 */
export const verifyChapterTitleAnchors = defineBrowserCommand(
  async (
    { context },
    pageUrl: string,
    widths: readonly number[],
  ): Promise<ChapterTitleAnchorObservation[]> => {
    const observations: ChapterTitleAnchorObservation[] = [];
    /* eslint-disable no-await-in-loop -- Each width needs its own fresh page. */
    for (const width of widths) {
      const applicationPage = await context.newPage();
      try {
        await applicationPage.emulateMedia({ reducedMotion: "reduce" });
        await applicationPage.setViewportSize({ width, height: 900 });
        await applicationPage.goto(pageUrl, { waitUntil: "domcontentloaded" });
        await applicationPage.evaluate(async () => {
          await document.fonts.ready;
        });
        await applicationPage.waitForSelector(
          "[data-full-page-topology][data-topology-reveal-edge-y] [data-topology-chapter-node]",
          { state: "attached" },
        );
        observations.push(...(await applicationPage.evaluate(observeTitleAnchors, width)));
      } finally {
        await applicationPage.close();
      }
    }
    /* eslint-enable no-await-in-loop */
    return observations;
  },
);

function readStepTabs(chapterId: string): {
  readonly orientation: string | null;
  readonly role: string | null;
  readonly tabs: ChapterStepTabObservation[];
  readonly labels: Record<string, string>;
} {
  const root = document.querySelector(`[data-chapter-steps-root="${chapterId}"]`);
  const list = root?.querySelector("[data-chapter-step-list]");
  if (root === null || root === undefined || list === null || list === undefined) {
    throw new Error(`Chapter ${chapterId} has no step list`);
  }
  const labels: Record<string, string> = {};
  const tabs = [...list.querySelectorAll<HTMLButtonElement>("[data-chapter-step]")].map((tab) => {
    const stepId = tab.dataset["chapterStep"] ?? "";
    const label = tab.querySelector<HTMLElement>("[data-chapter-step-label]");
    const bounds = tab.getBoundingClientRect();
    const labelBounds = label?.getBoundingClientRect();
    labels[stepId] = label?.textContent.trim() ?? "";
    return {
      stepId,
      accessibleName: (tab.getAttribute("aria-label") ?? tab.textContent).trim(),
      centerX: bounds.left + bounds.width / 2,
      centerY: bounds.top + bounds.height / 2,
      width: bounds.width,
      height: bounds.height,
      labelVisible: labelBounds !== undefined && labelBounds.width > 1 && labelBounds.height > 1,
    };
  });
  return {
    orientation: list.getAttribute("aria-orientation"),
    role: list.getAttribute("role"),
    tabs,
    labels,
  };
}

function readGlassLayout(chapterId: string): ChapterGlassLayoutObservation {
  const article = document.getElementById(chapterId);
  if (article === null) {
    throw new Error(`Chapter ${chapterId} is missing`);
  }
  const glass = document.querySelector(`[data-rail-surface-target="${chapterId}"]`);
  const title = article.querySelector("[data-rail-anchor]");
  const stage = article.querySelector("[data-rail-media-target]");
  const stepList = article.querySelector("[data-chapter-step-list]");
  const pill = article.querySelector("[data-chapter-step-line]");
  const lineStart = article.querySelector("[data-rail-step-line-target]");
  const caption = article.querySelector(".chapter-caption");
  const attachGroup = document.querySelector(
    `[data-route-kind="attach"][data-route-anchor="${chapterId}"]`,
  );
  const branch = attachGroup?.querySelector<SVGPathElement>('[data-topology-path-role="core"]');
  if (
    glass === null ||
    title === null ||
    stage === null ||
    stepList === null ||
    pill === null ||
    lineStart === null ||
    caption === null ||
    branch === undefined ||
    branch === null
  ) {
    throw new Error(`Chapter ${chapterId} is missing its glass, parts, or branch`);
  }
  const box = (element: Element): ViewportRect => {
    const bounds = element.getBoundingClientRect();
    return { top: bounds.top, bottom: bounds.bottom, left: bounds.left, right: bounds.right };
  };
  const matrix = branch.getScreenCTM();
  if (matrix === null) throw new Error(`Chapter ${chapterId} branch has no screen transform`);
  const endpoint = branch.getPointAtLength(branch.getTotalLength()).matrixTransform(matrix);
  const playbackStages = [...article.querySelectorAll("[data-scroll-playback-stage]")];
  const floatingHeader = document.querySelector<HTMLElement>(
    '.site-header[data-visual-state="floating"]',
  );
  if (floatingHeader === null) throw new Error("Floating site header is missing");
  const headerMaterial = getComputedStyle(floatingHeader);
  const pillMaterial = getComputedStyle(pill);
  return {
    glass: box(glass),
    pill: box(pill),
    caption: box(caption),
    title: box(title),
    stage: box(stage),
    stepList: box(stepList),
    lineStart: box(lineStart),
    titleInGlass: glass.contains(title),
    stageInGlass: glass.contains(stage),
    stepListInPill: pill.contains(stepList),
    stepPanelsInCaption: [...article.querySelectorAll("[data-chapter-step-panel]")].every((panel) =>
      caption.contains(panel),
    ),
    glassChildCount: glass.children.length,
    realCaptureTextCount: [...document.querySelectorAll("body *")].filter(
      (element) => element.children.length === 0 && element.textContent?.trim() === "Real capture",
    ).length,
    captionRadius: getComputedStyle(caption).borderRadius,
    captionBackground: getComputedStyle(caption).backgroundColor,
    captionBackgroundImage: getComputedStyle(caption).backgroundImage,
    captionBackdropFilter: getComputedStyle(caption).backdropFilter,
    captionBorderColor: getComputedStyle(caption).borderTopColor,
    captionTextColor: getComputedStyle(caption).color,
    captionIconCount: caption.querySelectorAll("[data-chapter-caption-icon]").length,
    pillMaterialMatchesHeader:
      pillMaterial.background === headerMaterial.background &&
      pillMaterial.borderColor === headerMaterial.borderColor &&
      pillMaterial.backdropFilter === headerMaterial.backdropFilter,
    stepLineBackdrop: getComputedStyle(pill).backdropFilter,
    playbackStageCount: playbackStages.length,
    playbackStageIsStage: playbackStages[0] === stage,
    branchEndpoint: { x: endpoint.x, y: endpoint.y },
    targetEdge: attachGroup?.getAttribute("data-target-edge") ?? undefined,
    portNodeCount: attachGroup?.querySelectorAll("[data-topology-port-node]").length ?? 0,
  };
}

function readStepSnapshot(chapterId: string): ChapterStepSnapshot {
  const root = document.querySelector<HTMLElement>(`[data-chapter-steps-root="${chapterId}"]`);
  if (root === null) {
    throw new Error(`Chapter ${chapterId} has no steps root`);
  }
  const visiblePanels = [...root.querySelectorAll<HTMLElement>("[data-chapter-step-panel]")].filter(
    (panel) => panel.getAttribute("aria-hidden") !== "true" && panel.getClientRects().length > 0,
  );
  const focused = document.activeElement;
  const selected = root.querySelector<HTMLElement>('[data-chapter-step][aria-selected="true"]');
  const selectedBounds = selected?.getBoundingClientRect();
  const activeLabel = root.querySelector<HTMLElement>("[data-chapter-step-active-label]");
  const activeBranch = root.querySelector<SVGPathElement>("[data-chapter-step-branch]");
  const labelBounds = activeLabel?.getBoundingClientRect();
  const caption = root.querySelector<HTMLElement>(".chapter-caption");
  const article = root.closest("article");
  const nextSection = article?.nextElementSibling;
  const progressFill = root.querySelector<HTMLElement>(".chapter-step-progress-fill");
  const lineStart = root.querySelector<HTMLElement>("[data-rail-step-line-target]");
  const selectedDot = selected?.querySelector<HTMLElement>(".chapter-step__dot");
  const lineStartBounds = lineStart?.getBoundingClientRect();
  const selectedDotBounds = selectedDot?.getBoundingClientRect();
  const visibleStepLabels = [
    ...root.querySelectorAll<HTMLElement>("[data-chapter-step-active-label]"),
  ]
    .filter(
      (label) => getComputedStyle(label).display !== "none" && label.getClientRects().length > 0,
    )
    .map((label) => label.textContent?.trim() ?? "");
  return {
    visiblePanelIds: visiblePanels.map((panel) => panel.dataset["chapterStepPanel"] ?? ""),
    visibleText: visiblePanels.map((panel) => panel.innerText).join("\n"),
    focusedStepId:
      focused instanceof HTMLElement && root.contains(focused)
        ? focused.dataset["chapterStep"]
        : undefined,
    selectedStepId: selected?.dataset["chapterStep"],
    activeLabelGap:
      selectedBounds === undefined || labelBounds === undefined
        ? Number.NaN
        : labelBounds.left - selectedBounds.right,
    activeBranchAnimationCount:
      (activeLabel?.getAnimations().length ?? 0) + (activeBranch?.getAnimations().length ?? 0),
    captionHeight: caption?.getBoundingClientRect().height ?? Number.NaN,
    nextSectionTop:
      nextSection === null || nextSection === undefined
        ? Number.NaN
        : nextSection.getBoundingClientRect().top + window.scrollY,
    progressWidth: progressFill?.getBoundingClientRect().width ?? Number.NaN,
    expectedProgressWidth:
      lineStartBounds === undefined || selectedDotBounds === undefined
        ? Number.NaN
        : (selectedDotBounds.left + selectedDotBounds.right) / 2 - lineStartBounds.left,
    visibleStepLabels,
    panelHeights: [...root.querySelectorAll<HTMLElement>("[data-chapter-step-panel]")].map(
      (panel) => panel.getBoundingClientRect().height,
    ),
    panelStyles: [...root.querySelectorAll<HTMLElement>("[data-chapter-step-panel]")].map(
      (panel) =>
        `${getComputedStyle(panel).display}/${getComputedStyle(panel).visibility}/${getComputedStyle(panel).contentVisibility}`,
    ),
  };
}

/** The slice of a Playwright page that opening a chapter needs. */
interface NavigablePage {
  emulateMedia(options: { readonly reducedMotion: "reduce" }): Promise<void>;
  setViewportSize(size: { readonly width: number; readonly height: number }): Promise<void>;
  goto(url: string, options: { readonly waitUntil: "domcontentloaded" }): Promise<unknown>;
}

async function openChapter(
  applicationPage: NavigablePage,
  request: ChapterStepRowRequest,
): Promise<void> {
  await applicationPage.emulateMedia({ reducedMotion: "reduce" });
  await applicationPage.setViewportSize({ width: request.width, height: request.height ?? 900 });
  const pageUrl = new URL(request.pageUrl);
  pageUrl.hash = request.chapterId;
  await applicationPage.goto(pageUrl.href, { waitUntil: "domcontentloaded" });
}

/**
 * Loads one chapter at one width with reduced motion (scenes stay settled, so
 * only this command moves the steps), reads the step list's geometry and
 * semantics, then drives it: the scene reports its next step, then ArrowRight,
 * Home, and End from the focused tab. Finally reads the same chapter with
 * JavaScript off.
 */
export const verifyChapterStepRow = defineBrowserCommand(
  async ({ context }, request: ChapterStepRowRequest): Promise<ChapterStepRowObservation> => {
    const applicationPage = await context.newPage();
    const { chapterId } = request;
    let semantics: ReturnType<typeof readStepTabs>;
    let glassLayout: ChapterGlassLayoutObservation;
    let initial: ChapterStepSnapshot;
    let afterSceneAdvance: ChapterStepSnapshot;
    let afterArrowRight: ChapterStepSnapshot;
    let afterHome: ChapterStepSnapshot;
    let afterEnd: ChapterStepSnapshot;
    const afterClicks: ChapterStepSnapshot[] = [];
    try {
      await openChapter(applicationPage, request);
      await applicationPage.waitForSelector(
        `[data-chapter-steps-root="${chapterId}"][data-enhanced="true"]`,
        { state: "attached" },
      );
      await applicationPage.waitForSelector(
        `[data-route-kind="attach"][data-route-anchor="${chapterId}"] [data-topology-path-role="core"]`,
        { state: "attached" },
      );
      glassLayout = await applicationPage.evaluate(readGlassLayout, chapterId);
      semantics = await applicationPage.evaluate(readStepTabs, chapterId);
      initial = await applicationPage.evaluate(readStepSnapshot, chapterId);
      const [, secondStep, thirdStep] = semantics.tabs;
      if (secondStep === undefined || thirdStep === undefined) {
        throw new Error(`Chapter ${chapterId} needs at least three steps`);
      }

      // The scene reaches its second step.
      await applicationPage.evaluate(
        ({ chapter, stepId }) => {
          document
            .querySelector(`[data-chapter-steps-root="${chapter}"] [data-scene-root]`)
            ?.dispatchEvent(
              new CustomEvent("agentstudio:scene-step-reached", {
                bubbles: true,
                detail: { stepId },
              }),
            );
        },
        { chapter: chapterId, stepId: secondStep.stepId },
      );
      await applicationPage.waitForSelector(
        `[data-chapter-step="${secondStep.stepId}"][aria-selected="true"]`,
        { state: "attached" },
      );
      afterSceneAdvance = await applicationPage.evaluate(readStepSnapshot, chapterId);

      // The visitor focuses the selected tab and moves right.
      await applicationPage.focus(`[data-chapter-step="${secondStep.stepId}"]`);
      await applicationPage.keyboard.press("ArrowRight");
      afterArrowRight = await applicationPage.evaluate(readStepSnapshot, chapterId);
      await applicationPage.keyboard.press("Home");
      afterHome = await applicationPage.evaluate(readStepSnapshot, chapterId);
      await applicationPage.keyboard.press("End");
      afterEnd = await applicationPage.evaluate(readStepSnapshot, chapterId);
      /* eslint-disable no-await-in-loop -- Each click must settle before the next segment. */
      for (const tab of semantics.tabs) {
        await applicationPage.click(`[data-chapter-step="${tab.stepId}"]`);
        afterClicks.push(await applicationPage.evaluate(readStepSnapshot, chapterId));
      }
      /* eslint-enable no-await-in-loop */
    } finally {
      await applicationPage.close();
    }

    const browser = context.browser();
    if (browser === null) {
      throw new Error("The browser context has no browser to open a script-free context");
    }
    const scriptFreeContext = await browser.newContext({ javaScriptEnabled: false });
    let withoutScript: ChapterStepSnapshot;
    try {
      const scriptFreePage = await scriptFreeContext.newPage();
      await openChapter(scriptFreePage, request);
      withoutScript = await scriptFreePage.evaluate(readStepSnapshot, chapterId);
    } finally {
      await scriptFreeContext.close();
    }

    return {
      width: request.width,
      glassLayout,
      orientation: semantics.orientation,
      role: semantics.role,
      tabs: semantics.tabs,
      labels: semantics.labels,
      initial,
      afterSceneAdvance,
      afterArrowRight,
      afterHome,
      afterEnd,
      afterClicks,
      withoutScript,
    };
  },
);
