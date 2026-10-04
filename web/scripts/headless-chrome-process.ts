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

export async function stopBrowserProcess(
  browserProcess: ReturnType<typeof spawn>,
  { forcedExitAfterMs = 5_000 }: StopBrowserProcessOptions = {},
): Promise<void> {
  if (browserProcess.exitCode !== null || browserProcess.signalCode !== null) return;

  await new Promise<void>((resolveExit) => {
    let settled = false;

    const finish = (): void => {
      if (settled) return;

      settled = true;
      clearTimeout(forcedExitTimeout);
      browserProcess.off("exit", finish);
      resolveExit();
    };

    // SIGKILL cannot be ignored, so the exit event still arrives; resolving before it
    // would let callers delete the profile while Chrome is still writing to it.
    const forcedExitTimeout = setTimeout((): void => {
      browserProcess.kill("SIGKILL");
    }, forcedExitAfterMs);

    browserProcess.once("exit", finish);
    if (browserProcess.exitCode !== null || browserProcess.signalCode !== null) {
      finish();
      return;
    }
    browserProcess.kill("SIGTERM");
  });
}
