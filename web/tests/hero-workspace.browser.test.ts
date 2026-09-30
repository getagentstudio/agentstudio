import { expect, inject, it } from "vitest";
import { commands } from "vitest/browser";

import type { HeroWorkspaceObservation } from "./hero-workspace-browser-command";

declare module "vitest/browser" {
  interface BrowserCommands {
    verifyHeroWorkspace(pageUrl: string): Promise<HeroWorkspaceObservation>;
  }
}

it("runs the hero Codex pane in the Agent Studio workspace", async () => {
  const observation = await commands.verifyHeroWorkspace(inject("siteHeaderBrowserTestUrl"));
  expect(observation.text).not.toMatch(/tool-portal|fix\/lease-client/u);
  expect(observation.header).toContain("directory: ~/agent-studio");
  expect(observation.model).toBe("GPT-6.1-Sol high");
  expect(observation.footer).toBe("GPT-6.1-Sol high · Context 94% left · main");
  expect(observation.footer).toContain("main");
  expect(observation.worktreeRows).toEqual([
    "└ ~/agent-studio  main",
    "└ ~/agent-studio.drawer  drawer-improvements",
    "└ ~/agent-studio.review  review-comments",
  ]);

  expect(observation.layouts.map(({ viewport }) => viewport)).toEqual([
    "1600x1000",
    "1280x800",
    "820x1180",
    "390x844",
    "675x844",
  ]);
  for (const layout of observation.layouts) {
    expect(layout.noHorizontalOverflow, layout.viewport).toBe(true);
    expect(layout.headerNoWrap, layout.viewport).toBe(true);
    expect(layout.footerNoWrap, layout.viewport).toBe(true);
    expect(layout.headerOverflow, layout.viewport).toBe(false);
    expect(layout.footerOverflow, layout.viewport).toBe(false);
    if (layout.viewportWidth >= 1024) {
      expect(layout.codexVisible, layout.viewport).toBe(true);
      expect(layout.modelLineHeightDelta, layout.viewport).toBeLessThanOrEqual(1);
      expect(layout.footerLineHeightDelta, layout.viewport).toBeLessThanOrEqual(1);
    } else {
      expect(layout.codexVisible, layout.viewport).toBe(false);
    }
  }
});
