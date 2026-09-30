import { describe, expect, inject, it } from "vitest";
import { commands } from "vitest/browser";

import type { HeroEyebrowSettleObservation } from "./hero-eyebrow-settle-browser-command";
import type {
  HeroLayoutObservation,
  HeroPlaybackObservation,
  HeroRefreshObservation,
  HeroShiftObservation,
  HeroScrollCueObservation,
  HeroPhoneFlowObservation,
} from "./hero-intro-browser-command";

declare module "vitest/browser" {
  interface BrowserCommands {
    verifyHeroEyebrowSettle(
      pageUrl: string,
      width: number,
      height: number,
    ): Promise<HeroEyebrowSettleObservation>;
    verifyHeroIntroLayout(
      pageUrl: string,
      viewports: readonly { readonly width: number; readonly height: number }[],
    ): Promise<HeroLayoutObservation[]>;
    verifyHeroNoScriptWidth(
      pageUrl: string,
    ): Promise<{ readonly documentWidth: number; readonly shortLabels: boolean }>;
    verifyHeroIntroPlayback(pageUrl: string): Promise<HeroPlaybackObservation>;
    verifyHeroIntroRefresh(pageUrl: string): Promise<HeroRefreshObservation>;
    verifyHeroIntroShift(
      pageUrl: string,
      width: number,
      height: number,
    ): Promise<HeroShiftObservation[]>;
    verifyHeroScrollCue(pageUrl: string): Promise<HeroScrollCueObservation>;
    verifyHeroPhoneMidIntro(
      pageUrl: string,
      width: number,
      height: number,
    ): Promise<HeroPhoneFlowObservation>;
  }
}

const viewports = [
  { width: 390, height: 844 },
  { width: 414, height: 896 },
  { width: 430, height: 932 },
  { width: 375, height: 667 },
  { width: 820, height: 1180 },
  { width: 1024, height: 768 },
  { width: 1280, height: 800 },
  { width: 1366, height: 768 },
  { width: 1440, height: 900 },
  { width: 1512, height: 982 },
  { width: 1600, height: 1000 },
  { width: 1728, height: 1117 },
  { width: 1920, height: 1080 },
  { width: 2560, height: 1440 },
] as const;

describe("hero intro", () => {
  it.each([
    [1600, 1000],
    [390, 844],
  ])("keeps the animated eyebrow identical to its settled CSS at %ix%i", async (width, height) => {
    const observation = await commands.verifyHeroEyebrowSettle(
      inject("siteHeaderBrowserTestUrl"),
      width,
      height,
    );
    expect(observation.settledState).toBe("settled");
    expect(
      Math.abs(observation.animatedSpacing - observation.settledSpacing),
      observation.viewport,
    ).toBeLessThanOrEqual(0.01);
    expect(
      Math.abs(observation.animatedWidth - observation.settledWidth),
      observation.viewport,
    ).toBeLessThanOrEqual(0.5);
  });
  it("fits the 390px finale before its responsive script runs", async () => {
    const observation = await commands.verifyHeroNoScriptWidth(inject("siteHeaderBrowserTestUrl"));
    expect(observation.shortLabels).toBe(false);
    expect(observation.documentWidth).toBe(390);
  });
  it("shows a scroll cue after the intro and hides it on the way to the first image", async () => {
    const cue = await commands.verifyHeroScrollCue(inject("siteHeaderBrowserTestUrl"));
    expect(cue.visibleAtRest).toBe(true);
    expect(cue.hiddenAfterScroll).toBe(true);
    expect(cue.reachedFirstImage).toBe(true);
  });
  it.each([
    [375, 667],
    [390, 844],
    [414, 896],
    [430, 932],
  ])(
    "keeps the complete phone flow in order and fills the window at %ix%i",
    async (width, height) => {
      const flow = await commands.verifyHeroPhoneMidIntro(
        inject("siteHeaderBrowserTestUrl"),
        width,
        height,
      );
      expect(flow.promptBeforeWork).toBe(true);
      expect(flow.progressBeforeReady).toBe(true);
      expect(flow.readyAfterDecode).toBe(true);
      expect(flow.streamedBeforeResult).toBe(true);
      expect(flow.mapTypedBeforeWork).toBe(true);
      expect(flow.phoneWorkingBeforeRows).toBe(true);
      expect(flow.noCodexBurst).toBe(true);
      expect(flow.resultVisible).toBe(true);
      expect(flow.clippedAtAnySample).toBe(false);
      expect(flow.largestTranscriptGap, `${width}px ${flow.gapDebug}`).toBeLessThanOrEqual(36);
      const text = flow.settledRows.join("\n");
      const orderedFragments = [
        "set up Agent Studio for me",
        "Bash(",
        "Installing agent-studio",
        "Ready. Copy it below",
        "map the worktrees",
        "git worktree list",
        "~/agent-studio",
        "~/agent-studio.drawer",
        "~/agent-studio.review",
        "3 worktrees · 5 branches",
      ];
      let lastIndex = -1;
      for (const fragment of orderedFragments) {
        const index = text.indexOf(fragment);
        expect(index, `${width}px: ${fragment}`).toBeGreaterThan(lastIndex);
        lastIndex = index;
      }
    },
  );
  it("replays from the top on reload, settles for anchors, and skips on wheel", async () => {
    const observation = await commands.verifyHeroIntroRefresh(inject("siteHeaderBrowserTestUrl"));
    expect(observation.reloadState).toBe("playing");
    expect(observation.reloadScrollY).toBe(0);
    expect(observation.programmaticScrollState).toBe("playing");
    expect(observation.wheelState).toBe("settled");
    expect(observation.hashState).toBe("settled");
    expect(observation.hashCreatedTimeline).toBe(false);
  });
  it("keeps the settled terminal, install box and canvas correct at every approved size", async () => {
    const observations = await commands.verifyHeroIntroLayout(
      inject("siteHeaderBrowserTestUrl"),
      viewports,
    );
    for (const observation of observations) {
      expect(observation.rowsInsideWindow, observation.viewport).toBe(true);
      if ([390, 414, 430, 375, 820, 1024].includes(observation.viewportWidth)) {
        const viewportHeight = Number(observation.viewport.split("x")[1]);
        if (observation.viewportWidth < 1024)
          expect(observation.firstScreenHeight, observation.viewport).toBeCloseTo(
            viewportHeight,
            0,
          );
        expect(observation.appTop, observation.viewport).toBeGreaterThanOrEqual(viewportHeight);
        expect(observation.scrollCueVisible, observation.viewport).toBe(true);
        expect(
          observation.scrollCueBottom,
          `${observation.viewport}: screen=${observation.firstScreenHeight} columnMargin=${observation.columnMarginTop} headline=${observation.headlineBottom} window=${observation.windowTop}-${observation.windowBottom} install=${observation.installCopyTop}-${observation.installBottom} app=${observation.appTop}`,
        ).toBeLessThanOrEqual(viewportHeight);
        expect(observation.scrollCueBottom, observation.viewport).toBeLessThan(observation.appTop);
        expect(
          observation.scrollCueTop - observation.installBottom,
          observation.viewport,
        ).toBeGreaterThanOrEqual(12);
      }
      if (
        observation.viewportWidth >= 1024 &&
        observation.appTop < Number(observation.viewport.split("x")[1])
      )
        expect(observation.scrollCueVisible, observation.viewport).toBe(false);
      expect(
        observation.installBottom,
        `${observation.viewport}: headline ${observation.headlineBottom}, column ${observation.columnTop}, root ${observation.rootTop}, window ${observation.windowTop}-${observation.windowBottom}`,
      ).toBeLessThanOrEqual(Number(observation.viewport.split("x")[1]));
      expect(
        Math.abs(observation.windowLeft - observation.appLeft),
        observation.viewport,
      ).toBeLessThanOrEqual(1);
      expect(
        Math.abs(observation.windowRight - observation.appRight),
        observation.viewport,
      ).toBeLessThanOrEqual(1);
      expect(observation.cursorCount, observation.viewport).toBe(1);
      if (observation.viewportWidth !== 375) {
        expect(
          observation.documentWidth,
          `${observation.viewport}: ${observation.overflowElements.join(", ")}`,
        ).toBe(observation.viewportWidth);
      }
      expect(observation.codexVisible, observation.viewport).toBe(
        Number(observation.viewport.split("x")[0]) >= 1024,
      );
      expect(observation.canvasColor, observation.viewport).toBe("rgb(25, 27, 31)");
      expect(observation.installCenterOffset, observation.viewport).toBeLessThanOrEqual(1);
      expect(observation.captionTop - observation.appBottom, observation.viewport).toBeCloseTo(
        12,
        0,
      );
      expect(
        Math.abs(observation.captionLeft - observation.appLeft),
        observation.viewport,
      ).toBeLessThanOrEqual(1);
      expect(
        Math.abs(observation.captionRight - observation.appRight),
        observation.viewport,
      ).toBeLessThanOrEqual(1);
      expect(observation.captionRadius, observation.viewport).toBe("20px");
      expect(observation.captionBackgroundImage, observation.viewport).toContain("linear-gradient");
      expect(observation.captionBackdropFilter, observation.viewport).toContain("blur(16px)");
      expect(observation.captionIconCount, observation.viewport).toBe(1);
      expect(observation.descriptionTop).toBeGreaterThan(observation.captionTop);
      expect(
        observation.paintedStackTop - observation.headlineBottom,
        `${observation.viewport}: screen=${observation.firstScreenHeight} headline=${observation.headlineBottom} window=${observation.windowTop}-${observation.windowBottom} install=${observation.installBottom} cue=${observation.scrollCueBottom}`,
      ).toBeGreaterThanOrEqual(observation.viewportWidth < 620 ? 32 : 48);
      expect(observation.visibleBashRows, observation.viewport).toBe(1);
      expect(observation.windowRadius, observation.viewport).toBe(observation.appRadius);
      if ([1024, 1280, 1600, 2560].includes(observation.viewportWidth)) {
        expect(observation.bashSplitTokens, observation.viewport).toEqual([]);
        expect(observation.codexPassedColor, observation.viewport).toBe("rgb(155, 161, 173)");
      }
      if (observation.viewport === "1600x1000" || observation.viewport === "390x844") {
        for (const [index, expectedAngle] of [0, 7, -12].entries()) {
          expect(observation.stackAngles[index], observation.viewport).toBeCloseTo(
            expectedAngle,
            1,
          );
        }
        const phone = observation.viewport === "390x844";
        expect(observation.stackPlaneLeftPeeks[0], observation.viewport).toBeGreaterThanOrEqual(
          phone ? 5 : 10,
        );
        expect(observation.stackPlaneTopPeeks[0], observation.viewport).toBeGreaterThanOrEqual(
          phone ? 5 : 10,
        );
        expect(observation.stackPlaneLeftPeeks[1], observation.viewport).toBeGreaterThan(
          observation.stackPlaneLeftPeeks[0] ?? Number.NaN,
        );
        expect(observation.stackPlaneLeftPeeks[2], observation.viewport).toBeGreaterThan(
          observation.stackPlaneLeftPeeks[1] ?? Number.NaN,
        );
        expect(observation.stackPeekLeft, observation.viewport).toBeLessThanOrEqual(
          phone ? 20 : 52,
        );
        expect(observation.stackPeekTop, observation.viewport).toBeLessThanOrEqual(phone ? 20 : 52);
      }
      if (observation.viewport === "820x1180") {
        expect(observation.earlierExchangeVisible).toBe(true);
      }
    }
  });

  it.each([
    [1600, 1000],
    [390, 844],
  ])(
    "keeps the window, image and rail fixed throughout playback at %ix%i",
    async (width, height) => {
      const samples = await commands.verifyHeroIntroShift(
        inject("siteHeaderBrowserTestUrl"),
        width,
        height,
      );
      expect(samples.map((sample) => sample.time)).toEqual([0, 3.5, 4.2, 4.6, "settled"]);
      const baseline = samples[0];
      if (baseline === undefined) throw new Error("Missing intro baseline");
      for (const sample of samples) {
        expect(
          Math.abs(sample.appTop - baseline.appTop),
          `${width}: app at ${sample.time}`,
        ).toBeLessThanOrEqual(0.5);
        expect(
          Math.abs(sample.windowHeight - baseline.windowHeight),
          `${width}: window at ${sample.time}`,
        ).toBeLessThanOrEqual(0.5);
        expect(
          Math.abs(sample.chapterNodeY - baseline.chapterNodeY),
          `${width}: rail at ${sample.time}`,
        ).toBeLessThanOrEqual(0.5);
      }
    },
  );

  it("settles once on resize or keydown and leaves CSS in charge of the final layout", async () => {
    const observation = await commands.verifyHeroIntroPlayback(inject("siteHeaderBrowserTestUrl"));
    expect(observation.midIntroWasPlaying).toBe(true);
    for (const [index, expectedAngle] of [0, 7, -12].entries()) {
      expect(observation.fanAnglesAtEnd[index]).toBeCloseTo(expectedAngle, 1);
    }
    expect(observation.fourthAngleAtEnd).toBeCloseTo(0, 1);
    expect(observation.terminalWindowBorderWidth).toBe(1);
    expect(observation.fanBorderWidthsAtEnd).toEqual([1, 1, 1, 1]);
    expect(observation.fourthBorderWidthWhileDealing).toBe(1);
    expect(observation.midIntroHorizontalOverflow).toBeLessThanOrEqual(0);
    expect(observation.resizeSettledEvents).toBe(1);
    expect(observation.resizeProgress).toBe(1);
    expect(observation.resizeInlineStyles, observation.resizeInlineStyleElements.join("\n")).toBe(
      0,
    );
    expect(observation.resizeFourthPlanes).toBe(0);
    expect(observation.reducedMotionCreatedTimeline).toBe(false);
    expect(observation.keydownSettledEvents).toBe(1);
    expect(observation.afterSecondResizeInlineStyles).toBe(0);
    for (const [actual, expected] of [
      [observation.resizedWindow, observation.freshNarrowWindow],
      [observation.afterSecondResizeWindow, observation.freshWideWindow],
    ] as const) {
      expect(Math.abs(actual.left - expected.left)).toBeLessThanOrEqual(1);
      expect(Math.abs(actual.top - expected.top)).toBeLessThanOrEqual(1);
      expect(Math.abs(actual.width - expected.width)).toBeLessThanOrEqual(1);
      expect(Math.abs(actual.height - expected.height)).toBeLessThanOrEqual(1);
    }
  });
});
