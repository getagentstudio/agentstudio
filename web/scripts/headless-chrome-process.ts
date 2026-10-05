import type { spawn } from "node:child_process";
import { access } from "node:fs/promises";

// The Chrome that local asset scripts drive headless. CHROME_BIN overrides the
// macOS application paths.
const chromeCandidates = [
  process.env["CHROME_BIN"],
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  "/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary",
  "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
].filter((candidate): candidate is string => candidate !== undefined);

export async function resolveChromeExecutable(purpose: string): Promise<string> {
  const resolvedCandidates = await Promise.all(
    chromeCandidates.map(async (candidate): Promise<string | null> => {
      try {
        await access(candidate);
        return candidate;
      } catch {
        return null;
      }
    }),
  );
  const chromeExecutable = resolvedCandidates.find(
    (candidate): candidate is string => candidate !== null,
  );

  if (chromeExecutable !== undefined) {
    return chromeExecutable;
  }

  throw new Error(`${purpose} requires Chrome or Brave. Set CHROME_BIN to a Chromium executable.`);
}

export interface StopBrowserProcessOptions {
  /** How long a SIGTERM may go unanswered before the process is killed. */
  readonly forcedExitAfterMs?: number;
}

/**
 * Resolves once the browser process has exited, so callers may then delete its
 * profile. Rejects when the process cannot be signalled, because its liveness is
 * then unknown and deleting the profile would race a running browser.
 */
export async function stopBrowserProcess(
  browserProcess: ReturnType<typeof spawn>,
  { forcedExitAfterMs = 5_000 }: StopBrowserProcessOptions = {},
): Promise<void> {
  if (browserProcess.exitCode !== null || browserProcess.signalCode !== null) return;
  // A spawn that failed has no pid and emits "error" then "close", never "exit";
  // no browser ever ran, so nothing can be writing to the profile.
  if (browserProcess.pid === undefined) return;

  await new Promise<void>((resolveExit, rejectStop) => {
    let settled = false;

    const settle = (signalFailure?: Error): void => {
      if (settled) return;

      settled = true;
      clearTimeout(forcedExitTimeout);
      browserProcess.off("exit", onExit);
      browserProcess.off("error", onSignalFailure);
      if (signalFailure === undefined) resolveExit();
      else rejectStop(signalFailure);
    };
    const onExit = (): void => settle();
    const onSignalFailure = (error: Error): void => settle(error);
    const sendSignal = (signal: NodeJS.Signals): void => {
      try {
        browserProcess.kill(signal);
      } catch (error: unknown) {
        settle(error instanceof Error ? error : new Error(String(error)));
      }
    };

    // SIGKILL cannot be ignored, so the exit event still arrives; resolving before it
    // would let callers delete the profile while Chrome is still writing to it.
    const forcedExitTimeout = setTimeout((): void => sendSignal("SIGKILL"), forcedExitAfterMs);

    browserProcess.once("exit", onExit);
    browserProcess.on("error", onSignalFailure);
    if (browserProcess.exitCode !== null || browserProcess.signalCode !== null) {
      settle();
      return;
    }
    sendSignal("SIGTERM");
  });
}
