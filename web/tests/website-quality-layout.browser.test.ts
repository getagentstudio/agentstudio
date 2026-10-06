import { expect, inject, it } from "vitest";
import { commands } from "vitest/browser";

import { getHomeChapters } from "../src/chapters/chapter-catalog";
import type { WebsiteLayoutObservation } from "./website-quality-browser-command";

declare module "vitest/browser" {
  interface BrowserCommands {
    verifyWebsiteQualityLayout(pageUrl: string): Promise<readonly WebsiteLayoutObservation[]>;
  }
}

it("renders every chapter with unclipped headings and no sideways scroll at every width", async () => {
  // Act
  const observations = await commands.verifyWebsiteQualityLayout(
    inject("siteHeaderBrowserTestUrl"),
  );

  // Assert
  expect(observations).toHaveLength(10);
  for (const observation of observations) {
    const width = `${String(observation.width)}px`;
    expect(observation.chapterCount, width).toBe(getHomeChapters().length);
    expect(observation.clippedHeadings, width).toEqual([]);
    expect(observation.horizontalOverflow, width).toBeLessThanOrEqual(1);
    expect(observation.introHorizontalOverflow, width).toBeLessThanOrEqual(1);
  }
}, 60_000);
