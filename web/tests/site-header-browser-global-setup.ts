import { spawn, type ChildProcess } from "node:child_process";
import { once } from "node:events";
import { existsSync } from "node:fs";
import path from "node:path";

import type { TestProject } from "vitest/node";

interface ReadyMessage {
  readonly kind: "ready";
  readonly port: number;
}

function isReadyMessage(message: unknown): message is ReadyMessage {
  if (typeof message !== "object" || message === null) {
    return false;
  }
  const candidate = message as { readonly kind?: unknown; readonly port?: unknown };
  return candidate.kind === "ready" && Number.isInteger(candidate.port);
}

async function waitForOwnedServer(childProcess: ChildProcess): Promise<number> {
  return await new Promise<number>((resolve, reject): void => {
    const cleanup = (): void => {
      childProcess.off("error", rejectOwnedServer);
      childProcess.off("exit", rejectExitedServer);
      childProcess.off("message", resolveReadyServer);
    };
    const rejectOwnedServer = (error: Error): void => {
      cleanup();
      reject(error);
    };
    const rejectExitedServer = (exitCode: number | null): void => {
      rejectOwnedServer(
        new Error(`Astro header browser-test process exited with ${String(exitCode)}`),
      );
    };
    const resolveReadyServer = (message: unknown): void => {
      if (isReadyMessage(message)) {
        cleanup();
        resolve(message.port);
      }
    };
    // Astro's cold import/optimizer can exceed five seconds while still starting
    // correctly. Readiness is the IPC fact; the outer test job owns the hang bound.
    childProcess.once("error", rejectOwnedServer);
    childProcess.once("exit", rejectExitedServer);
    childProcess.on("message", resolveReadyServer);
  });
}

async function stopOwnedServer(childProcess: ChildProcess): Promise<void> {
  if (childProcess.exitCode !== null || childProcess.signalCode !== null) {
    return;
  }
  const exitPromise = once(childProcess, "exit");
  childProcess.kill("SIGTERM");
  await exitPromise;
}

export default async function setupSiteHeaderBrowserServer(
  project: TestProject,
): Promise<() => Promise<void>> {
  // This setup runs once at the root so both browser projects share one server. A run that
  // selects no browser project (for example `--project unit`) needs no server.
  if (!project.vitest.projects.some((testProject) => testProject.config.browser.enabled)) {
    return async (): Promise<void> => {};
  }
  const rootCandidates = [project.config.root, path.join(project.config.root, "web")];
  const websiteRoot = rootCandidates.find((candidateRoot): boolean =>
    existsSync(path.join(candidateRoot, "src", "pages", "index.astro")),
  );
  if (websiteRoot === undefined) {
    throw new Error("Browser global setup could not resolve the Astro website root");
  }
  const serverScript = path.join(websiteRoot, "tests", "site-header-browser-server.ts");
  const serverEnvironment: NodeJS.ProcessEnv = { ...process.env, NODE_ENV: "development" };
  for (const variableName of ["VITEST", "VITEST_MODE", "VITEST_POOL_ID", "VITEST_WORKER_ID"]) {
    delete serverEnvironment[variableName];
  }
  const childProcess = spawn(
    process.execPath,
    ["--experimental-strip-types", serverScript, websiteRoot, "0"],
    { cwd: websiteRoot, env: serverEnvironment, stdio: ["ignore", "ignore", "ignore", "ipc"] },
  );
  let port: number;
  try {
    port = await waitForOwnedServer(childProcess);
  } catch (error: unknown) {
    await stopOwnedServer(childProcess);
    throw error;
  }
  const siteHeaderBrowserTestUrl = `http://127.0.0.1:${port}/`;
  project.provide("siteHeaderBrowserTestUrl", siteHeaderBrowserTestUrl);

  return async (): Promise<void> => {
    await stopOwnedServer(childProcess);
  };
}
