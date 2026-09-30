import { expect, inject, it } from "vitest";
import { commands } from "vitest/browser";

import type { SkipLinkObservation } from "./website-access-browser-command";

declare module "vitest/browser" {
  interface BrowserCommands {
    verifySkipToContent(pageUrl: string, width: number): Promise<SkipLinkObservation>;
  }
}

it.each([1600, 390])("offers first-Tab skip navigation to main at %ipx", async (width) => {
  const result = await commands.verifySkipToContent(inject("siteHeaderBrowserTestUrl"), width);
  expect(result.initiallyVisible).toBe(false);
  expect(result.firstFocusText).toBe("Skip to content");
  expect(result.visibleOnFocus).toBe(true);
  expect(result.mainFocused).toBe(true);
  expect(result.headingClearsHeader).toBe(true);
});
