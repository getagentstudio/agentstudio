import { defineBrowserCommand } from "@vitest/browser-playwright";
import type { BrowserCommandContext } from "vitest/node";

import {
  installPendingWaitTracker,
  registerCommandPageForDiagnostics,
  type DiagnosticPage,
  type CommandPageRegistration,
} from "./pending-wait-diagnostics";

interface FixtureRegistration {
  readonly page: DiagnosticPage;
  readonly unregister: () => void;
}

const fixturePages = new Map<string, FixtureRegistration>();

function readFixtureState(): Record<string, unknown> {
  return { fixtureState: document.body.dataset["fixtureState"] ?? "missing" };
}

export const startPendingWaitFixture = defineBrowserCommand(
  async (
    { context, sessionId }: BrowserCommandContext,
    freezeTimeline: boolean,
  ): Promise<{ readonly started: true }> => {
    const page = await context.newPage();
    try {
      await page.addInitScript(installPendingWaitTracker);
      await page.goto("about:blank");
      if (freezeTimeline) {
        const cdp = await page.context().newCDPSession(page);
        await cdp.send("Animation.enable");
        await cdp.send("Animation.setPlaybackRate", { playbackRate: 0 });
      }
      const registration: CommandPageRegistration = { page, readCommandState: readFixtureState };
      const unregister = registerCommandPageForDiagnostics(sessionId, registration);
      await page.evaluate(() => {
        const tracker = window["__pendingWaitTracker"];
        if (tracker === undefined) throw new Error("Pending wait tracker is missing");
        document.body.dataset["fixtureState"] = "pending";
        tracker.begin("fixture-wait");
        const release = (): void => {
          tracker.end("fixture-wait");
          document.body.dataset["fixtureState"] = "released";
        };
        Object.defineProperty(window, "__releasePendingWaitFixture", {
          configurable: true,
          value: release,
        });
      });
      fixturePages.set(sessionId, { page, unregister });
      return { started: true };
    } catch (error: unknown) {
      await page.close();
      throw error;
    }
  },
);

export const releasePendingWaitFixture = defineBrowserCommand(
  async ({ sessionId }: BrowserCommandContext): Promise<{ readonly released: true }> => {
    const registration = fixturePages.get(sessionId);
    if (registration === undefined) return { released: true };
    fixturePages.delete(sessionId);
    try {
      await registration.page.evaluate(() => {
        const release = window["__releasePendingWaitFixture"];
        if (release !== undefined) release();
      });
    } finally {
      registration.unregister();
      await registration.page.close();
    }
    return { released: true };
  },
);

declare global {
  interface Window {
    __releasePendingWaitFixture?: () => void;
  }
}
