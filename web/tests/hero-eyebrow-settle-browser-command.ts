import { defineBrowserCommand } from "@vitest/browser-playwright";

export interface HeroEyebrowSettleObservation {
  readonly viewport: string;
  readonly animatedSpacing: number;
  readonly settledSpacing: number;
  readonly animatedWidth: number;
  readonly settledWidth: number;
  readonly settledState: string | null;
}

export const verifyHeroEyebrowSettle = defineBrowserCommand(
  async (
    { context },
    pageUrl: string,
    width: number,
    height: number,
  ): Promise<HeroEyebrowSettleObservation> => {
    const page = await context.newPage();
    try {
      await page.setViewportSize({ width, height });
      await page.addInitScript(() => {
        Object.defineProperty(document, "hidden", { configurable: true, get: () => false });
        let markReady: () => void = () => {};
        const ready = new Promise<void>((resolve) => {
          markReady = resolve;
        });
        (window as Window & { heroEyebrowReady?: Promise<void> }).heroEyebrowReady = ready;
        document.addEventListener(
          "hero-intro-playback-ready",
          (event) => {
            if (!(event instanceof CustomEvent)) return;
            const control = event.detail as {
              pause(): void;
              seek(seconds: number): void;
              finish(): void;
            };
            control.pause();
            (window as Window & { heroEyebrowControl?: typeof control }).heroEyebrowControl =
              control;
            markReady();
          },
          { once: true },
        );
      });
      await page.goto(pageUrl, { waitUntil: "domcontentloaded" });
      await page.evaluate(async () => {
        await (window as Window & { heroEyebrowReady?: Promise<void> }).heroEyebrowReady;
        await document.fonts.ready;
      });
      return await page.evaluate((viewport) => {
        const hero = document.querySelector<HTMLElement>("[data-hero-intro-root]");
        const eyebrow = document.querySelector<HTMLElement>("[data-hero-intro-eyebrow-settled]");
        const control = (
          window as Window & {
            heroEyebrowControl?: { seek(seconds: number): void; finish(): void };
          }
        ).heroEyebrowControl;
        if (hero === null || eyebrow === null || control === undefined)
          throw new Error("Hero eyebrow playback control is missing");
        control.seek(10);
        const progressAtTen = Number(hero.getAttribute("data-hero-intro-progress"));
        if (progressAtTen <= 0 || progressAtTen >= 1)
          throw new Error(`Unexpected hero progress at 10s: ${String(progressAtTen)}`);
        const duration = 10 / progressAtTen;
        control.seek(duration - 1 / 60);
        const animatedSpacing = Number.parseFloat(getComputedStyle(eyebrow).letterSpacing);
        const animatedWidth = eyebrow.getBoundingClientRect().width;
        control.finish();
        return {
          viewport,
          animatedSpacing,
          settledSpacing: Number.parseFloat(getComputedStyle(eyebrow).letterSpacing),
          animatedWidth,
          settledWidth: eyebrow.getBoundingClientRect().width,
          settledState: hero.getAttribute("data-hero-intro-state"),
        };
      }, `${width}x${height}`);
    } finally {
      await page.close();
    }
  },
);
