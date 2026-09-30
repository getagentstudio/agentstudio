import { defineBrowserCommand } from "@vitest/browser-playwright";
import sharp from "sharp";

export interface RailBandPixel {
  readonly fraction: number;
  readonly railRgb: readonly number[];
  readonly canvasRgb: readonly number[];
  readonly pixelSaturation: number;
  readonly contributionBrightness: number;
}

export interface RailBandObservation {
  readonly width: number;
  readonly pixels: readonly RailBandPixel[];
  readonly trunkWidth: number;
  readonly otherLineWidths: readonly number[];
  readonly stepTrackHeights: readonly number[];
}

export const verifyRailViewportBands = defineBrowserCommand(
  async (
    { context },
    pageUrl: string,
    width: number,
    height: number,
  ): Promise<RailBandObservation> => {
    const applicationPage = await context.newPage();
    try {
      await applicationPage.setViewportSize({ width, height });
      await applicationPage.goto(pageUrl, { waitUntil: "domcontentloaded" });
      await applicationPage.evaluate(() => window.dispatchEvent(new WheelEvent("wheel")));
      await applicationPage.waitForSelector('[data-hero-intro-state="settled"]');
      await applicationPage.evaluate(async () => {
        await document.fonts.ready;
      });
      await applicationPage.evaluate(() => {
        const chapter = document.getElementById("many-agents");
        if (chapter === null) throw new Error("Many-agents chapter is missing");
        window.scrollTo({
          top: scrollY + chapter.getBoundingClientRect().top - 100,
          behavior: "instant",
        });
      });
      await applicationPage.waitForFunction(() => {
        const artwork = document.querySelector<SVGSVGElement>("[data-full-page-topology]");
        const progress = Number(artwork?.dataset["topologyScrollProgress"]);
        const maximumScroll = Math.max(document.documentElement.scrollHeight - innerHeight, 1);
        return Number.isFinite(progress) && Math.abs(progress - scrollY / maximumScroll) < 0.0001;
      });
      const mainlineX = await applicationPage.evaluate(() => {
        const path = document.querySelector<SVGPathElement>(
          "[data-full-page-topology] [data-mainline]",
        );
        const matrix = path?.getScreenCTM();
        if (path === null || matrix === null || matrix === undefined)
          throw new Error("Rail mainline is missing");
        return path.getPointAtLength(0).matrixTransform(matrix).x;
      });
      const lineWidths = await applicationPage.evaluate(() => {
        const mainline = document.querySelector<SVGPathElement>(
          "[data-full-page-topology] [data-mainline]",
        );
        if (!mainline) throw new Error("Main trunk missing");
        return {
          trunkWidth: Number.parseFloat(getComputedStyle(mainline).strokeWidth),
          otherLineWidths: [
            ...document.querySelectorAll<SVGPathElement>(
              ".topology-route > path:not(.topology-clearance), .chapter-step-active-branch",
            ),
          ].map((path) => Number.parseFloat(getComputedStyle(path).strokeWidth)),
          stepTrackHeights: [
            ...document.querySelectorAll<HTMLElement>(
              ".chapter-step-progress-track, .chapter-step-progress-fill",
            ),
          ].map((track) => Number.parseFloat(getComputedStyle(track).height)),
        };
      });
      const screenshot = await applicationPage.screenshot();
      const { data, info } = await sharp(screenshot)
        .removeAlpha()
        .raw()
        .toBuffer({ resolveWithObject: true });
      const rgbAt = (x: number, y: number): number[] => {
        const index = (y * info.width + x) * info.channels;
        return Array.from(data.subarray(index, index + 3));
      };
      const pixels = [0.5, 0.85, 0.97].map((fraction): RailBandPixel => {
        const y = Math.round(height * fraction);
        const canvasRgb = rgbAt(4, y);
        const centerX = Math.round(mainlineX);
        const candidates = Array.from({ length: 5 }, (_, index) => rgbAt(centerX + index - 2, y));
        const railRgb = candidates.reduce((brightest, candidate) =>
          candidate.reduce((sum, channel) => sum + channel, 0) >
          brightest.reduce((sum, channel) => sum + channel, 0)
            ? candidate
            : brightest,
        );
        const contribution = railRgb.map((channel, index) =>
          Math.max(0, channel - (canvasRgb[index] ?? 0)),
        );
        const maximum = Math.max(...contribution);
        const brightestChannel = Math.max(...railRgb);
        const darkestChannel = Math.min(...railRgb);
        const colourRange = brightestChannel - darkestChannel;
        return {
          fraction,
          railRgb,
          canvasRgb,
          pixelSaturation:
            colourRange === 0
              ? 0
              : colourRange / (255 - Math.abs(brightestChannel + darkestChannel - 255)),
          contributionBrightness: maximum,
        };
      });
      return { width, pixels, ...lineWidths };
    } finally {
      await applicationPage.close();
    }
  },
);
