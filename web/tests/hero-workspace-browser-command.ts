import { defineBrowserCommand } from "@vitest/browser-playwright";

export interface HeroWorkspaceObservation {
  readonly text: string;
  readonly header: string;
  readonly model: string;
  readonly footer: string;
  readonly worktreeRows: readonly string[];
  readonly layouts: readonly HeroCodexLayoutObservation[];
}

interface HeroCodexLayoutObservation {
  readonly viewport: string;
  readonly viewportWidth: number;
  readonly codexVisible: boolean;
  readonly headerNoWrap: boolean;
  readonly footerNoWrap: boolean;
  readonly headerOverflow: boolean;
  readonly footerOverflow: boolean;
  readonly modelLineHeightDelta: number;
  readonly footerLineHeightDelta: number;
  readonly noHorizontalOverflow: boolean;
}

interface HeroWorkspacePageObservation {
  readonly text: string;
  readonly header: string;
  readonly model: string;
  readonly footer: string;
  readonly worktreeRows: readonly string[];
  readonly layout: HeroCodexLayoutObservation;
}

export const verifyHeroWorkspace = defineBrowserCommand(
  async ({ context }, pageUrl: string): Promise<HeroWorkspaceObservation> => {
    const page = await context.newPage();
    try {
      await page.setViewportSize({ width: 1600, height: 1000 });
      await page.emulateMedia({ reducedMotion: "reduce" });
      await page.goto(pageUrl, { waitUntil: "domcontentloaded" });
      await page.evaluate(async () => {
        await document.fonts.ready;
      });

      const viewports = [
        { width: 1600, height: 1000 },
        { width: 1280, height: 800 },
        { width: 820, height: 1180 },
        { width: 390, height: 844 },
        { width: 675, height: 844 },
      ] as const;
      const observations: HeroWorkspacePageObservation[] = [];
      for (const viewport of viewports) {
        await page.setViewportSize(viewport);
        observations.push(
          await page.evaluate((viewportSize): HeroWorkspacePageObservation => {
            const root = document.querySelector<HTMLElement>("[data-hero-intro-root]");
            if (root === null) throw new Error("Hero workspace is missing");
            const codexPane = root.querySelector<HTMLElement>(".hero-terminal-pane--codex");
            const headerBox = root.querySelector<HTMLElement>(".hero-codex-startup");
            const footerStatus = root.querySelector<HTMLElement>(".hero-codex-status");
            if (codexPane === null || headerBox === null || footerStatus === null) {
              throw new Error("Hero Codex workspace is incomplete");
            }
            const modelRow = Array.from(headerBox.children).find((row) =>
              row.textContent?.includes("model:"),
            );
            if (modelRow === undefined) throw new Error("Codex model row is missing");
            const modelRowText = modelRow.textContent ?? "";
            const model = modelRowText
              .replace(/^model:\s*/u, "")
              .split("/model", 1)[0]
              ?.trim();
            const headerStyle = getComputedStyle(headerBox);
            const modelLineHeight = Number.parseFloat(getComputedStyle(modelRow).lineHeight);
            const modelRowHeight = modelRow.getBoundingClientRect().height;
            const footerStyle = getComputedStyle(footerStatus);
            const footerLineHeight = Number.parseFloat(footerStyle.lineHeight);
            const footerPadding =
              Number.parseFloat(footerStyle.paddingTop) +
              Number.parseFloat(footerStyle.paddingBottom);
            const footerLineBoxHeight = footerStatus.getBoundingClientRect().height - footerPadding;

            return {
              text: root.textContent ?? "",
              header: headerBox.textContent ?? "",
              model: model ?? "",
              footer: footerStatus.textContent?.trim() ?? "",
              worktreeRows: [
                ...root.querySelectorAll<HTMLElement>(
                  ".hero-terminal-pane--codex [data-hero-worktree-row]",
                ),
              ].map((row) => row.textContent?.trim() ?? ""),
              layout: {
                viewport: `${viewportSize.width}x${viewportSize.height}`,
                viewportWidth: viewportSize.width,
                codexVisible: getComputedStyle(codexPane).display !== "none",
                headerNoWrap: headerStyle.whiteSpace === "nowrap",
                footerNoWrap: footerStyle.whiteSpace === "nowrap",
                headerOverflow: headerBox.scrollWidth > headerBox.clientWidth,
                footerOverflow: footerStatus.scrollWidth > footerStatus.clientWidth,
                modelLineHeightDelta: Math.abs(modelRowHeight - modelLineHeight),
                footerLineHeightDelta: Math.abs(footerLineBoxHeight - footerLineHeight),
                noHorizontalOverflow: document.documentElement.scrollWidth <= window.innerWidth,
              },
            };
          }, viewport),
        );
      }

      const firstObservation = observations[0];
      if (firstObservation === undefined) throw new Error("Hero Codex viewports are missing");
      return {
        text: firstObservation.text,
        header: firstObservation.header,
        model: firstObservation.model,
        footer: firstObservation.footer,
        worktreeRows: firstObservation.worktreeRows,
        layouts: observations.map((observation) => observation.layout),
      };
    } finally {
      await page.close();
    }
  },
);
