import { expect, it, onTestFailed, vi } from "vitest";
import { commands } from "vitest/browser";

import {
  pendingWaitDiagnosticHookTimeoutMilliseconds,
  reportPendingWaitDiagnostic,
  type PendingWaitDiagnosticResult,
} from "./pending-wait-diagnostics";
import type { PendingWaitFixtureOptions } from "./pending-wait-diagnostics-fixture-browser-command";

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

declare module "vitest/browser" {
  interface BrowserCommands {
    startPendingWaitFixture(
      options: PendingWaitFixtureOptions,
    ): Promise<{ readonly started: true }>;
    releasePendingWaitFixture(): Promise<{ readonly released: true }>;
  }
}

async function captureFixture(freezeTimeline: boolean): Promise<PendingWaitDiagnosticResult> {
  await commands.startPendingWaitFixture({ freezeTimeline, awaitFrames: true });
  try {
    return await commands.capturePendingWaitDiagnostics();
  } finally {
    await commands.releasePendingWaitFixture();
  }
}

it("captures a pending wait with a running document timeline", async () => {
  onTestFailed(
    (context) =>
      reportPendingWaitDiagnostic(context, () => commands.capturePendingWaitDiagnostics()),
    pendingWaitDiagnosticHookTimeoutMilliseconds,
  );
  const result = await captureFixture(false);
  expect(result.kind).toBe("captured");
  if (result.kind !== "captured") throw new Error("Pending fixture capture failed");
  expect(result.wait).toBe("fixture-wait");
  expect(result.timelineAdvancedMs).toBeGreaterThanOrEqual(0);
  expect(result.timelineAdvancedMs).toBeGreaterThan(1);
  expect(result.wallElapsedMs).toBeGreaterThan(0);
  expect(typeof result.visibilityState).toBe("string");
  expect(result.stateReader).toBe("installed");
  expect(result.stateError).toBeNull();
  expect(result.state).toEqual({ fixtureState: "pending" });
});

it("distinguishes a frozen document timeline from wall time", async () => {
  onTestFailed(
    (context) =>
      reportPendingWaitDiagnostic(context, () => commands.capturePendingWaitDiagnostics()),
    pendingWaitDiagnosticHookTimeoutMilliseconds,
  );
  const result = await captureFixture(true);
  expect(result.kind).toBe("captured");
  if (result.kind !== "captured") throw new Error("Frozen fixture capture failed");
  expect(result.wait).toBe("fixture-wait");
  expect(result.timelineAdvancedMs).toBeLessThanOrEqual(1);
  expect(result.wallElapsedMs).toBeGreaterThan(0);
  expect(result.wallElapsedMs).toBeGreaterThan(1);
});

it("reports the absence of a registered command page", async () => {
  await expect(commands.capturePendingWaitDiagnostics()).resolves.toEqual({
    kind: "no-active-command-page",
  });
});

it("prints the captured diagnostic line without changing the failure handler", async () => {
  onTestFailed(
    (context) =>
      reportPendingWaitDiagnostic(context, () => commands.capturePendingWaitDiagnostics()),
    pendingWaitDiagnosticHookTimeoutMilliseconds,
  );
  const errorSpy = vi.spyOn(console, "error").mockImplementation(() => undefined);
  try {
    await commands.startPendingWaitFixture({ freezeTimeline: false });
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
    expect(parsed["stateReader"]).toBe("installed");
    expect(parsed["stateError"]).toBeNull();
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
      'PENDING_WAIT_DIAGNOSTIC unavailable reason="no-active-command-page"',
    );
  } finally {
    errorSpy.mockRestore();
  }
});

it("quotes the handler-error reason", async () => {
  const errorSpy = vi.spyOn(console, "error").mockImplementation(() => undefined);
  try {
    await reportPendingWaitDiagnostic(
      { task: { name: "handler error diagnostic test" } },
      async () => {
        throw new Error("capture exploded");
      },
    );
    expect(errorSpy).toHaveBeenCalledWith(
      'PENDING_WAIT_DIAGNOSTIC unavailable reason="handler-error"',
    );
  } finally {
    errorSpy.mockRestore();
  }
});

it("keeps primary fields when the command state reader throws", async () => {
  onTestFailed(
    (context) =>
      reportPendingWaitDiagnostic(context, () => commands.capturePendingWaitDiagnostics()),
    pendingWaitDiagnosticHookTimeoutMilliseconds,
  );
  await commands.startPendingWaitFixture({ freezeTimeline: false, readerThrows: true });
  try {
    const result = await commands.capturePendingWaitDiagnostics();
    expect(result.kind).toBe("captured");
    if (result.kind !== "captured") throw new Error("Throwing-reader fixture capture failed");
    expect(result.wait).toBe("fixture-wait");
    expect(result.visibilityState).toEqual(expect.any(String));
    expect(result.wallElapsedMs).toBeGreaterThan(0);
    expect(result.stateReader).toBe("failed");
    expect(result.stateError).toBe("fixture reader failed");
    expect(result.state).toEqual({});
  } finally {
    await commands.releasePendingWaitFixture();
  }
});

it("identifies a missing command state reader", async () => {
  onTestFailed(
    (context) =>
      reportPendingWaitDiagnostic(context, () => commands.capturePendingWaitDiagnostics()),
    pendingWaitDiagnosticHookTimeoutMilliseconds,
  );
  await commands.startPendingWaitFixture({ freezeTimeline: false, withReader: false });
  try {
    const result = await commands.capturePendingWaitDiagnostics();
    expect(result.kind).toBe("captured");
    if (result.kind !== "captured") throw new Error("Missing-reader fixture capture failed");
    expect(result.stateReader).toBe("missing");
    expect(result.stateError).toBeNull();
    expect(result.state).toEqual({});
  } finally {
    await commands.releasePendingWaitFixture();
  }
});
