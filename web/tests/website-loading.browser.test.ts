import { expect, inject, it } from "vitest";
import { commands } from "vitest/browser";

import type {
  DeferredVideoObservation,
  HeroProofImageObservation,
  CaptureDeliveryObservation,
} from "./website-loading-browser-command";

declare module "vitest/browser" {
  interface BrowserCommands {
    verifyDeferredProofVideo(pageUrl: string): Promise<DeferredVideoObservation>;
    verifyHeroProofImage(
      pageUrl: string,
      width: number,
      height: number,
    ): Promise<HeroProofImageObservation>;
    verifyCaptureDelivery(pageUrl: string): Promise<CaptureDeliveryObservation>;
  }
}

it("admits the proof video near view and holds its poster until real canplay", async () => {
  const observation = await commands.verifyDeferredProofVideo(inject("siteHeaderBrowserTestUrl"));
  expect(observation.initialRequests).toBe(0);
  expect(observation.initialBytes).toBe(0);
  expect(observation.initialPreload).toBe("none");
  expect(observation.initialSource).toBeNull();
  expect(observation.requestedNearViewport).toBe(true);
  expect(observation.posterWhileLoading).toBe(true);
  expect(observation.playedAfterReady).toBe(true);
});

it("serves monotonic capture variants and width-based phone sources", async () => {
  const observation = await commands.verifyCaptureDelivery(inject("siteHeaderBrowserTestUrl"));
  expect(observation.groups).toHaveLength(10);
  for (const group of observation.groups) {
    const variants = group.variants.toSorted((left, right) => left.width - right.width);
    for (let index = 1; index < variants.length; index += 1) {
      expect(
        variants[index - 1]?.bytes,
        `${group.name}: ${JSON.stringify(variants)}`,
      ).toBeLessThanOrEqual(variants[index]?.bytes ?? 0);
    }
  }
  for (const source of observation.phoneSources) {
    expect(source.srcset).toMatch(/320w.*640w.*1280w/u);
    expect(source.sizes).toContain("100vw");
  }
});

it.each([
  [1600, 1000],
  [390, 844],
])("decodes a non-prioritized hero proof before first scroll at %ix%i", async (width, height) => {
  const observation = await commands.verifyHeroProofImage(
    inject("siteHeaderBrowserTestUrl"),
    width,
    height,
  );
  expect(observation.loading).not.toBe("eager");
  expect(observation.fetchPriority).not.toBe("high");
  expect(observation.completeAtIntroEnd).toBe(true);
  expect(observation.decodedBeforeScroll).toBe(true);
});
