import { defineBrowserCommand } from "@vitest/browser-playwright";

export interface SkipLinkObservation {
  readonly initiallyVisible: boolean;
  readonly firstFocusText: string;
  readonly visibleOnFocus: boolean;
  readonly mainFocused: boolean;
  readonly headingClearsHeader: boolean;
}

export const verifySkipToContent = defineBrowserCommand(
  async ({ context }, pageUrl: string, width: number): Promise<SkipLinkObservation> => {
    const page = await context.newPage();
    try {
      await page.setViewportSize({ width, height: 1000 });
      await page.emulateMedia({ reducedMotion: "reduce" });
      await page.goto(pageUrl, { waitUntil: "domcontentloaded" });
      const initiallyVisible = await page.evaluate((): boolean => {
        const link = document.querySelector<HTMLElement>("[data-skip-to-content]");
        return link !== null && link.getBoundingClientRect().bottom > 0;
      });
      await page.keyboard.press("Tab");
      const firstFocus = await page.evaluate(() => {
        const focus = document.activeElement;
        const box = focus?.getBoundingClientRect();
        return {
          text: focus?.textContent?.trim() ?? "",
          skip: focus?.hasAttribute("data-skip-to-content") ?? false,
          visible: box !== undefined && box.top >= 0 && box.bottom <= innerHeight && box.width > 0,
        };
      });
      if (!firstFocus.skip)
        return {
          initiallyVisible,
          firstFocusText: firstFocus.text,
          visibleOnFocus: firstFocus.visible,
          mainFocused: false,
          headingClearsHeader: false,
        };
      await page.keyboard.press("Enter");
      return await page.evaluate(
        (before): SkipLinkObservation => {
          const main = document.querySelector("main#top");
          const heading = main?.querySelector("h1");
          const header = document.querySelector("[data-site-header]");
          return {
            initiallyVisible: before.initiallyVisible,
            firstFocusText: before.text,
            visibleOnFocus: before.visible,
            mainFocused: document.activeElement === main,
            headingClearsHeader:
              heading !== null &&
              heading !== undefined &&
              header !== null &&
              heading.getBoundingClientRect().top >= header.getBoundingClientRect().bottom,
          };
        },
        { initiallyVisible, ...firstFocus },
      );
    } finally {
      await page.close();
    }
  },
);
