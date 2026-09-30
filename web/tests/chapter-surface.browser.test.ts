import { describe, expect, inject, it } from "vitest";
import { commands } from "vitest/browser";

import type {
  CaptionTextObservation,
  ChapterStepRowObservation,
  ChapterTitleAnchorObservation,
  SingleStepChapterObservation,
} from "./chapter-surface-browser-command.ts";

declare module "vitest/browser" {
  interface BrowserCommands {
    verifyChapterTitleAnchors(
      pageUrl: string,
      widths: readonly number[],
    ): Promise<ChapterTitleAnchorObservation[]>;
    verifyChapterStepRow(request: {
      readonly pageUrl: string;
      readonly width: number;
      readonly height?: number;
      readonly chapterId: string;
    }): Promise<ChapterStepRowObservation>;
    verifySingleStepChapter(request: {
      readonly pageUrl: string;
      readonly width: number;
      readonly height: number;
      readonly chapterId: string;
    }): Promise<SingleStepChapterObservation>;
    verifyCaptionTextLayout(
      pageUrl: string,
      widths: readonly number[],
    ): Promise<CaptionTextObservation[]>;
  }
}

const chapterWithSteps = "many-agents";

describe("chapter surfaces on the home page", () => {
  it("keeps caption copy balanced without an orphan last word", async () => {
    const observations = await commands.verifyCaptionTextLayout(
      inject("siteHeaderBrowserTestUrl"),
      [1280, 1600, 1920],
    );
    for (const observation of observations) {
      expect(observation.captions).toHaveLength(6);
      for (const caption of observation.captions) {
        expect(caption.textWrap).toBe("pretty");
        expect(caption.lineCount === 1 || caption.lastLineWordCount > 1).toBe(true);
        expect(caption.paragraphWidth).toBeGreaterThanOrEqual(caption.innerWidth * 0.9);
      }
    }
  });
  it("ignores the retired step-control query and keeps the bare line", async () => {
    const pageUrl = new URL(inject("siteHeaderBrowserTestUrl"));
    pageUrl.searchParams.set("steps", ["cap", "sule"].join(""));
    const observation = await commands.verifyChapterStepRow({
      pageUrl: pageUrl.href,
      width: 390,
      height: 844,
      chapterId: chapterWithSteps,
    });
    expect(observation.glassLayout.stepLineBackdrop).toBe("none");
  });
  for (const width of [390, 1600]) {
    it(`keeps a single-step chapter aligned with its step line at ${width}px`, async () => {
      const chapter = await commands.verifySingleStepChapter({
        pageUrl: inject("siteHeaderBrowserTestUrl"),
        width,
        height: width === 390 ? 844 : 1000,
        chapterId: "review",
      });
      expect(chapter.pillCount).toBe(1);
      expect(chapter.descriptionCount).toBe(1);
      expect(chapter.titleBottom).toBeLessThan(chapter.glassTop);
      expect(chapter.glassBottom).toBeLessThan(chapter.captionTop);
      expect(Math.abs(chapter.titleLeft - chapter.glassLeft)).toBeLessThanOrEqual(1);
      expect(Math.abs(chapter.captionLeft - chapter.glassLeft)).toBeLessThanOrEqual(1);
      expect(chapter.targetEdge).toBe("left");
    });
  }
  it("anchors each chapter on its title, with no eyebrow, and levels the rail node with the title's first line", async () => {
    // Act
    const observations = await commands.verifyChapterTitleAnchors(
      inject("siteHeaderBrowserTestUrl"),
      [390, 1280, 1920],
    );

    // Assert
    expect(observations.length).toBeGreaterThan(0);
    for (const observation of observations) {
      expect(observation.anchorTagName).toBe("H2");
      expect(observation.eyebrowCount).toBe(0);
      expect(
        Math.abs(observation.nodeCenterY - observation.titleFirstLineCenterY),
      ).toBeLessThanOrEqual(1);
    }
  });

  for (const { width, height } of [
    { width: 390, height: 844 },
    { width: 820, height: 1180 },
    { width: 1024, height: 768 },
    { width: 1280, height: 800 },
    { width: 1600, height: 1000 },
    { width: 2560, height: 1440 },
  ]) {
    it(`orders chapter G7 and keeps its caption fixed at ${width}x${height}`, async () => {
      const observation = await commands.verifyChapterStepRow({
        pageUrl: inject("siteHeaderBrowserTestUrl"),
        width,
        height,
        chapterId: chapterWithSteps,
      });
      const layout = observation.glassLayout;
      expect(layout.titleInGlass).toBe(false);
      expect(layout.stageInGlass).toBe(true);
      expect(layout.stepListInPill).toBe(true);
      expect(layout.stepPanelsInCaption).toBe(true);
      expect(layout.glassChildCount).toBe(1);
      expect(layout.realCaptureTextCount).toBe(0);
      expect(layout.captionRadius).toBe("20px");
      expect(layout.captionBackground).toBe("rgba(40, 44, 52, 0.72)");
      expect(layout.captionBackgroundImage).toContain("linear-gradient");
      expect(layout.captionBackdropFilter).toContain("blur(16px)");
      expect(layout.captionBorderColor).toBe("rgba(255, 255, 255, 0.12)");
      expect(layout.captionTextColor).toBe("rgb(234, 234, 234)");
      expect(layout.captionIconCount).toBe(observation.tabs.length);
      expect(layout.pillMaterialMatchesHeader).toBe(false);
      expect(layout.stepLineBackdrop).toBe("none");
      for (const left of [layout.glass.left, layout.pill.left, layout.caption.left]) {
        expect(Math.abs(left - layout.title.left)).toBeLessThanOrEqual(1);
      }
      if (width >= 1024) {
        expect(layout.pill.top - layout.title.bottom).toBeCloseTo(14, 0);
        expect(layout.glass.top - layout.pill.bottom).toBeCloseTo(14, 0);
        expect(layout.caption.top - layout.glass.bottom).toBeCloseTo(12, 0);
        expect(layout.targetEdge).toBe("left");
        expect(Math.abs(layout.branchEndpoint.x - layout.lineStart.left)).toBeLessThanOrEqual(1);
        expect(
          Math.abs(layout.branchEndpoint.y - (layout.lineStart.top + layout.lineStart.bottom) / 2),
        ).toBeLessThanOrEqual(1);
      } else {
        expect(layout.glass.top - layout.title.bottom).toBeCloseTo(20, 0);
        expect(layout.pill.top - layout.glass.bottom).toBeCloseTo(14, 0);
        expect(layout.caption.top - layout.pill.bottom).toBeCloseTo(10, 0);
        expect(layout.targetEdge).toBe("left");
        expect(Math.abs(layout.branchEndpoint.x - layout.lineStart.left)).toBeLessThanOrEqual(1);
        expect(
          Math.abs(layout.branchEndpoint.y - (layout.lineStart.top + layout.lineStart.bottom) / 2),
        ).toBeLessThanOrEqual(1);
      }
      expect(layout.portNodeCount).toBe(0);
      expect(layout.playbackStageCount).toBe(1);
      expect(layout.playbackStageIsStage).toBe(true);
      expect(observation.role).toBe("tablist");
      expect(observation.orientation).toBe("horizontal");
      const stepIds = observation.tabs.map((tab) => tab.stepId);
      expect(observation.initial.visiblePanelIds).toEqual([stepIds[0]]);
      expect(observation.initial.visibleText.length).toBeGreaterThan(10);
      for (const label of Object.values(observation.labels)) {
        expect(observation.initial.visibleText).not.toContain(label);
      }
      expect(observation.afterSceneAdvance.visiblePanelIds).toEqual([stepIds[1]]);
      expect(observation.afterArrowRight.visiblePanelIds).toEqual([stepIds[2]]);
      expect(observation.afterArrowRight.focusedStepId).toBe(stepIds[2]);
      expect(observation.afterHome.visiblePanelIds).toEqual([stepIds[0]]);
      expect(observation.afterEnd.visiblePanelIds).toEqual([stepIds.at(-1)]);
      const samples = [
        observation.initial,
        observation.afterSceneAdvance,
        observation.afterArrowRight,
        observation.afterHome,
        observation.afterEnd,
        ...observation.afterClicks,
      ];
      for (const sample of samples) {
        expect(sample.visiblePanelIds).toHaveLength(1);
        expect(
          Math.abs(sample.captionHeight - observation.initial.captionHeight),
          JSON.stringify(
            samples.map((item) => ({
              caption: item.captionHeight,
              panels: item.panelHeights,
              styles: item.panelStyles,
            })),
          ),
        ).toBeLessThanOrEqual(0.5);
        expect(
          Math.abs(sample.nextSectionTop - observation.initial.nextSectionTop),
        ).toBeLessThanOrEqual(0.5);
        expect(Math.abs(sample.progressWidth - sample.expectedProgressWidth)).toBeLessThanOrEqual(
          1,
        );
        expect(sample.activeLabelGap).toBeGreaterThanOrEqual(0);
        expect(sample.activeBranchAnimationCount).toBe(0);
        const labels = [observation.labels[sample.selectedStepId ?? ""]];
        expect(sample.visibleStepLabels).toEqual(labels);
      }
      for (let index = 1; index < observation.tabs.length; index += 1) {
        const currentTab = observation.tabs[index];
        const previousTab = observation.tabs[index - 1];
        if (currentTab === undefined || previousTab === undefined) throw new Error("Step missing");
        expect(currentTab.centerX - previousTab.centerX, `${width}px step spacing`).toBeCloseTo(
          width < 620 ? 22 : 68,
          0,
        );
      }
      expect(observation.tabs.every((tab) => tab.width >= 24 && tab.height >= 24)).toBe(true);
      for (const [index, sample] of observation.afterClicks.entries()) {
        expect(sample.visiblePanelIds).toEqual([stepIds[index]]);
      }
      expect(observation.withoutScript.visiblePanelIds).toEqual([stepIds[0]]);
    });
  }
});
