import { expect, inject, it } from "vitest";
import { commands } from "vitest/browser";

import type { RailBandObservation } from "./rail-band-browser-command.ts";

declare module "vitest/browser" {
  interface BrowserCommands {
    verifyRailViewportBands(
      pageUrl: string,
      width: number,
      height: number,
    ): Promise<RailBandObservation>;
  }
}

for (const [width, height] of [
  [1600, 1000],
  [390, 844],
] as const) {
  it(`colours, greys and fades the rail by 75/90/95 percent at ${width}px`, async () => {
    const observation = await commands.verifyRailViewportBands(
      inject("siteHeaderBrowserTestUrl"),
      width,
      height,
    );
    expect.soft(observation.trunkWidth).toBe(1.8);
    expect.soft(observation.otherLineWidths.length).toBeGreaterThan(0);
    expect.soft(observation.otherLineWidths.every((width) => width === 1.5)).toBe(true);
    expect.soft(observation.stepTrackHeights.every((height) => height === 1.5)).toBe(true);
    expect.soft(observation.trunkWidth / 1.5).toBe(1.2);
    const [colour, grey, absent] = observation.pixels;
    if (colour === undefined || grey === undefined || absent === undefined)
      throw new Error("Rail band samples are missing");
    expect(colour.contributionBrightness).toBeGreaterThan(20);
    expect(colour.pixelSaturation).toBeGreaterThan(0.15);
    expect(grey.contributionBrightness).toBeGreaterThan(20);
    expect(grey.pixelSaturation).toBeLessThan(0.05);
    expect(absent.contributionBrightness).toBeLessThanOrEqual(1);
  });
}
