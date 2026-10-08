import type { BrowserCommandContext } from "vitest/node";

declare module "vitest/browser" {
  interface BrowserCommands {
    capturePendingWaitDiagnostics(): Promise<PendingWaitDiagnosticResult>;
  }
}

export const pendingWaitDiagnosticHookTimeoutMilliseconds = 10_000;
export const pendingWaitDiagnosticMarginMilliseconds = 1_000;

interface PendingWaitRecord {
  readonly waitName: string;
  readonly timelineAtBeginMs: number;
  readonly beganAtMs: number;
}

interface PendingWaitTracker {
  readonly pendingWait: PendingWaitRecord | null;
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
        timelineAtBeginMs: Number(document.timeline.currentTime),
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
  readonly readCommandState: () => Record<string, unknown>;
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
      readonly state: Record<string, unknown>;
    }
  | { readonly kind: "no-active-command-page" }
  | { readonly kind: "capture-failed"; readonly reason: string };

let captureDiagnostic: (() => Promise<PendingWaitDiagnosticResult>) | undefined;

export function registerPendingWaitDiagnosticCapture(
  capture: () => Promise<PendingWaitDiagnosticResult>,
): void {
  captureDiagnostic = capture;
}

interface CaptureInput {
  readonly readerSource: string;
}

export const capturePendingWaitDiagnostics = async ({
  sessionId,
}: BrowserCommandContext): Promise<PendingWaitDiagnosticResult> => {
  const registration = commandPageRegistry.get(sessionId);
  if (registration === undefined) return { kind: "no-active-command-page" };
  try {
    const input: CaptureInput = { readerSource: registration.readCommandState.toString() };
    return await registration.page.evaluate(
      ({ readerSource }: CaptureInput): PendingWaitDiagnosticResult => {
        try {
          // oxlint-disable-next-line no-implied-eval
          const readerFactory = Function(`return (${readerSource})`);
          const readerUnknown: unknown = readerFactory();
          if (typeof readerUnknown !== "function")
            throw new Error("Command state reader is not callable");
          const reader = (): Record<string, unknown> => {
            const state: unknown = readerUnknown();
            if (typeof state !== "object" || state === null || Array.isArray(state))
              throw new Error("Command state reader did not return an object");
            return Object.fromEntries(Object.entries(state));
          };
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
          const timelineNow = Number(document.timeline.currentTime);
          const wallNow = performance.now();
          return {
            kind: "captured",
            wait: pending?.waitName ?? null,
            timelineAdvancedMs: pending === null ? null : timelineNow - pending.timelineAtBeginMs,
            wallElapsedMs: pending === null ? null : wallNow - pending.beganAtMs,
            visibilityState,
            hidden,
            state: reader(),
          };
        } catch (error: unknown) {
          return {
            kind: "capture-failed",
            reason: error instanceof Error ? error.message : String(error),
          };
        }
      },
      input,
    );
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
  timeoutMilliseconds: number = pendingWaitDiagnosticHookTimeoutMilliseconds,
): Promise<void> {
  try {
    let timeoutHandle: ReturnType<typeof setTimeout> | undefined;
    if (captureDiagnostic === undefined) throw new Error("Pending wait capture is not registered");
    const capture = captureDiagnostic();
    const timeout = new Promise<PendingWaitDiagnosticResult>((resolve) => {
      timeoutHandle = setTimeout(
        () => resolve({ kind: "capture-failed", reason: "capture-timeout" }),
        timeoutMilliseconds - pendingWaitDiagnosticMarginMilliseconds,
      );
    });
    const result = await Promise.race([capture, timeout]);
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
