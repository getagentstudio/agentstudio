import { expect, inject, it } from "vitest";
import { commands } from "vitest/browser";

import type {
  ChapterAutoplayObservation,
  ChapterClickObservation,
  ManualChapterClaimObservation,
} from "./chapter-autoplay-browser-command.ts";

declare module "vitest/browser" {
  interface BrowserCommands {
    verifyChapterAutoplayAtNaturalFraming(
      pageUrl: string,
      width: number,
      height: number,
    ): Promise<ChapterAutoplayObservation>;
    verifyChapterSceneClicks(
      pageUrl: string,
      width: number,
      height: number,
    ): Promise<ChapterClickObservation[]>;
    verifyManualChapterClaim(pageUrl: string): Promise<ManualChapterClaimObservation>;
  }
}

it("lets a manually played chapter claim the only playing scene", async () => {
  const observation = await commands.verifyManualChapterClaim(inject("siteHeaderBrowserTestUrl"));
  expect(observation.afterManualPlay).toEqual(["paused", "playing"]);
  expect(observation.automaticPause).toBe(true);
  expect(observation.afterReadingLineCrossing).toEqual(["paused", "playing"]);
});

for (const [width, height] of [
  [1600, 1000],
  [390, 844],
] as const) {
  it(`changes the visible scene for each clicked step and keeps playing at ${width}px`, async () => {
    const samples = await commands.verifyChapterSceneClicks(
      inject("siteHeaderBrowserTestUrl"),
      width,
      height,
    );
    expect(samples.map((sample) => sample.selectedStepId)).toEqual([
      "parallel-agents",
      "watch-folders",
      "navigation",
    ]);
    expect(samples.every((sample) => sample.sceneState === "playing")).toBe(true);
    for (const sample of samples) {
      expect(sample.clickTiming).toMatchObject({
        stepId: sample.stepId,
        running: true,
        manualPause: false,
        elapsedSeconds: 0,
      });
    }
    expect(new Set(samples.map((sample) => sample.stageImageHash)).size).toBe(3);
  });
}

for (const [width, height] of [
  [1024, 768],
  [1280, 800],
  [1600, 1000],
] as const) {
  it(`advances chapter autoplay with the naturally framed title and glass at ${width}px`, async () => {
    const observation = await commands.verifyChapterAutoplayAtNaturalFraming(
      inject("siteHeaderBrowserTestUrl"),
      width,
      height,
    );
    expect(observation.stageVisibleFraction).toBeGreaterThanOrEqual(0.6);
    expect(observation.selectedStep).not.toBe("parallel-agents");
    expect(observation.sceneState).toBe("playing");
  });
}
