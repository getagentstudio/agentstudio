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

function installFixtureStateReader(): void {
  const tracker = window["__pendingWaitTracker"];
  if (tracker === undefined) throw new Error("Pending wait tracker is missing");
  tracker.readCommandState = (): Record<string, unknown> => ({
    fixtureState: document.body.dataset["fixtureState"] ?? "missing",
  });
}

export interface PendingWaitFixtureOptions {
  readonly freezeTimeline: boolean;
  readonly awaitFrames?: boolean;
  readonly withReader?: boolean;
  readonly readerThrows?: boolean;
}

export const startPendingWaitFixture = defineBrowserCommand(
  async (
    { context, sessionId }: BrowserCommandContext,
    {
      freezeTimeline,
      awaitFrames = false,
      withReader = true,
      readerThrows = false,
    }: PendingWaitFixtureOptions,
  ): Promise<{ readonly started: true }> => {
    const page = await context.newPage();
    const registration: CommandPageRegistration = { page };
    const unregister = registerCommandPageForDiagnostics(sessionId, registration);
    try {
      await page.addInitScript(installPendingWaitTracker);
      if (withReader) {
        if (readerThrows)
          await page.addInitScript(() => {
            const tracker = window["__pendingWaitTracker"];
            if (tracker === undefined) throw new Error("Pending wait tracker is missing");
            tracker.readCommandState = (): Record<string, unknown> => {
              throw new Error("fixture reader failed");
            };
          });
        else await page.addInitScript(installFixtureStateReader);
      }
      await page.goto("about:blank");
      if (freezeTimeline) {
        const cdp = await page.context().newCDPSession(page);
        await cdp.send("Animation.enable");
        await cdp.send("Animation.setPlaybackRate", { playbackRate: 0 });
      }
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
      if (awaitFrames)
        await page.evaluate(async (): Promise<void> => {
          const visibilityState = Object.getOwnPropertyDescriptor(
            Document.prototype,
            "visibilityState",
          )?.get?.call(document);
          if (visibilityState !== "visible")
            throw new Error(
              "Pending-wait fixture page is hidden; requestAnimationFrame would not fire",
            );
          await new Promise<void>((resolve) =>
            requestAnimationFrame(() => requestAnimationFrame(() => resolve())),
          );
        });
      fixturePages.set(sessionId, { page, unregister });
      return { started: true };
    } catch (error: unknown) {
      unregister();
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
