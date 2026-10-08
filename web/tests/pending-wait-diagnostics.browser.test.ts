import { expect, it, vi } from "vitest";
import { commands } from "vitest/browser";

import {
  pendingWaitDiagnosticHookTimeoutMilliseconds,
  reportPendingWaitDiagnostic,
  type PendingWaitDiagnosticResult,
} from "./pending-wait-diagnostics";

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

declare module "vitest/browser" {
  interface BrowserCommands {
    startPendingWaitFixture(freezeTimeline: boolean): Promise<{ readonly started: true }>;
    releasePendingWaitFixture(): Promise<{ readonly released: true }>;
  }
}

async function captureFixture(freezeTimeline: boolean): Promise<PendingWaitDiagnosticResult> {
  await commands.startPendingWaitFixture(freezeTimeline);
  try {
    return await commands.capturePendingWaitDiagnostics();
  } finally {
    await commands.releasePendingWaitFixture();
  }
}

it("captures a pending wait with a running document timeline", async () => {
  const result = await captureFixture(false);
  expect(result.kind).toBe("captured");
  if (result.kind !== "captured") throw new Error("Pending fixture capture failed");
  expect(result.wait).toBe("fixture-wait");
  expect(result.timelineAdvancedMs).toBeGreaterThanOrEqual(0);
  expect(result.wallElapsedMs).toBeGreaterThan(0);
  expect(typeof result.visibilityState).toBe("string");
  expect(result.state).toEqual({ fixtureState: "pending" });
});

it("distinguishes a frozen document timeline from wall time", async () => {
  const result = await captureFixture(true);
  expect(result.kind).toBe("captured");
  if (result.kind !== "captured") throw new Error("Frozen fixture capture failed");
  expect(result.wait).toBe("fixture-wait");
  expect(result.timelineAdvancedMs).toBeLessThanOrEqual(1);
  expect(result.wallElapsedMs).toBeGreaterThan(0);
});

it("reports the absence of a registered command page", async () => {
  await expect(commands.capturePendingWaitDiagnostics()).resolves.toEqual({
    kind: "no-active-command-page",
  });
});

it("prints the captured diagnostic line without changing the failure handler", async () => {
  const errorSpy = vi.spyOn(console, "error").mockImplementation(() => undefined);
  try {
    await commands.startPendingWaitFixture(false);
    await reportPendingWaitDiagnostic(
      { task: { name: "fixture diagnostic test" } },
      () => commands.capturePendingWaitDiagnostics(),
      pendingWaitDiagnosticHookTimeoutMilliseconds,
    );
    const line = errorSpy.mock.calls.at(-1)?.[0];
    if (typeof line !== "string") throw new Error("Diagnostic line was not printed");
    expect(line.startsWith("PENDING_WAIT_DIAGNOSTIC ")).toBe(true);
    const parsed: unknown = JSON.parse(line.slice("PENDING_WAIT_DIAGNOSTIC ".length));
    if (!isRecord(parsed)) throw new Error("Diagnostic payload is not an object");
    expect(parsed["test"]).toBe("fixture diagnostic test");
    expect(parsed["wait"]).toBe("fixture-wait");
    expect(parsed["state"]).toEqual({ fixtureState: "pending" });
  } finally {
    await commands.releasePendingWaitFixture();
    errorSpy.mockRestore();
  }
});

it("prints an unavailable line when no command page is registered", async () => {
  const errorSpy = vi.spyOn(console, "error").mockImplementation(() => undefined);
  try {
    await reportPendingWaitDiagnostic(
      { task: { name: "unavailable diagnostic test" } },
      async () => ({ kind: "no-active-command-page" }),
    );
    expect(errorSpy).toHaveBeenCalledWith(
      "PENDING_WAIT_DIAGNOSTIC unavailable reason=no-active-command-page",
    );
  } finally {
    errorSpy.mockRestore();
  }
});
