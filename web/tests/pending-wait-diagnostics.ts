import type { BrowserCommandContext } from "vitest/node";

declare module "vitest/browser" {
  interface BrowserCommands {
    capturePendingWaitDiagnostics(): Promise<PendingWaitDiagnosticResult>;
  }
}

// Vitest resolves browser hookTimeout to 30,000ms when it is not configured.
export const pendingWaitDiagnosticHookTimeoutMilliseconds = 30_000;
export const pendingWaitDiagnosticMarginMilliseconds = 1_000;

interface PendingWaitRecord {
  readonly waitName: string;
  readonly timelineAtBeginMs: number | null;
  readonly beganAtMs: number;
}

interface PendingWaitTracker {
  readonly pendingWait: PendingWaitRecord | null;
  readCommandState?: () => Record<string, unknown>;
  begin(waitName: string): void;
  end(waitName: string): void;
}

declare global {
  interface Window {
    __pendingWaitTracker?: PendingWaitTracker;
  }
}

export function installPendingWaitTracker(): void {
  let pendingWait: PendingWaitRecord | null = null;
  window["__pendingWaitTracker"] = {
    get pendingWait(): PendingWaitRecord | null {
      return pendingWait;
    },
    begin(waitName: string): void {
      pendingWait = {
        waitName,
        timelineAtBeginMs:
          typeof document.timeline.currentTime === "number" ? document.timeline.currentTime : null,
        beganAtMs: performance.now(),
      };
    },
    end(waitName: string): void {
      if (pendingWait?.waitName === waitName) pendingWait = null;
    },
  };
}

export interface CommandPageRegistration {
  readonly page: DiagnosticPage;
}

export type DiagnosticPage = Awaited<ReturnType<BrowserCommandContext["context"]["newPage"]>>;

const commandPageRegistry = new Map<string, CommandPageRegistration>();

export function registerCommandPageForDiagnostics(
  sessionId: string,
  registration: CommandPageRegistration,
): () => void {
  commandPageRegistry.set(sessionId, registration);
  return (): void => {
    if (commandPageRegistry.get(sessionId)?.page === registration.page)
      commandPageRegistry.delete(sessionId);
  };
}

export type PendingWaitDiagnosticResult =
  | {
      readonly kind: "captured";
      readonly wait: string | null;
      readonly timelineAdvancedMs: number | null;
      readonly wallElapsedMs: number | null;
      readonly visibilityState: string;
      readonly hidden: boolean;
      readonly stateReader: "installed" | "missing";
      readonly state: Record<string, unknown>;
    }
  | { readonly kind: "no-active-command-page" }
  | { readonly kind: "capture-failed"; readonly reason: string };

export const capturePendingWaitDiagnostics = async ({
  sessionId,
}: BrowserCommandContext): Promise<PendingWaitDiagnosticResult> => {
  const registration = commandPageRegistry.get(sessionId);
  if (registration === undefined) return { kind: "no-active-command-page" };
  try {
    return await registration.page.evaluate((): PendingWaitDiagnosticResult => {
      try {
        const tracker = window["__pendingWaitTracker"];
        const pending = tracker?.pendingWait ?? null;
        const visibilityState = String(
          Object.getOwnPropertyDescriptor(Document.prototype, "visibilityState")?.get?.call(
            document,
          ) ?? "",
        );
        const hidden = Boolean(
          Object.getOwnPropertyDescriptor(Document.prototype, "hidden")?.get?.call(document),
        );
        const timelineNow =
          typeof document.timeline.currentTime === "number" ? document.timeline.currentTime : null;
        const wallNow = performance.now();
        const state = tracker?.readCommandState?.() ?? {};
        if (typeof state !== "object" || state === null || Array.isArray(state))
          throw new Error("Command state reader did not return a plain object");
        return {
          kind: "captured",
          wait: pending?.waitName ?? null,
          timelineAdvancedMs:
            pending === null || timelineNow === null || pending.timelineAtBeginMs === null
              ? null
              : timelineNow - pending.timelineAtBeginMs,
          wallElapsedMs: pending === null ? null : wallNow - pending.beganAtMs,
          visibilityState,
          hidden,
          stateReader: typeof tracker?.readCommandState === "function" ? "installed" : "missing",
          state,
        };
      } catch (error: unknown) {
        return {
          kind: "capture-failed",
          reason: error instanceof Error ? error.message : String(error),
        };
      }
    });
  } catch (error: unknown) {
    return {
      kind: "capture-failed",
      reason: error instanceof Error ? error.message : String(error),
    };
  }
};

interface FailedTaskContext {
  readonly task: { readonly name: string };
}

export async function reportPendingWaitDiagnostic(
  { task }: FailedTaskContext,
  capture: () => Promise<PendingWaitDiagnosticResult>,
  timeoutMilliseconds: number = pendingWaitDiagnosticHookTimeoutMilliseconds,
): Promise<void> {
  try {
    let timeoutHandle: ReturnType<typeof setTimeout> | undefined;
    const capturePromise = capture();
    const timeout = new Promise<PendingWaitDiagnosticResult>((resolve) => {
      timeoutHandle = setTimeout(
        () => resolve({ kind: "capture-failed", reason: "capture-timeout" }),
        timeoutMilliseconds - pendingWaitDiagnosticMarginMilliseconds,
      );
    });
    const result = await Promise.race([capturePromise, timeout]);
    if (timeoutHandle !== undefined) clearTimeout(timeoutHandle);
    if (result.kind === "captured")
      console.error(`PENDING_WAIT_DIAGNOSTIC ${JSON.stringify({ test: task.name, ...result })}`);
    else
      console.error(
        `PENDING_WAIT_DIAGNOSTIC unavailable reason=${result.kind === "capture-failed" ? result.reason : result.kind}`,
      );
  } catch {
    console.error("PENDING_WAIT_DIAGNOSTIC unavailable reason=handler-error");
  }
}
