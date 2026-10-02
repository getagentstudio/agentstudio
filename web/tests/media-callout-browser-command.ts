import { spawn } from "node:child_process";
import { once } from "node:events";
import { mkdtemp, readFile, readdir, rmdir, unlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";

import { defineBrowserCommand } from "@vitest/browser-playwright";

const webRoot = path.resolve(import.meta.dirname, "..");
const outputFileNames = ["callout.html", "callout.css", "callout.js", "manifest.json"] as const;

export interface BuiltMediaCalloutFiles {
  readonly html: string;
  readonly css: string;
  readonly javascript: string;
  readonly manifest: string;
  readonly stepPillStyle: StepPillStyleObservation;
}

export interface StepPillStyleObservation {
  readonly backgroundColor: string;
  readonly backgroundImage: string;
  readonly borderTopColor: string;
  readonly borderTopStyle: string;
  readonly borderTopWidth: string;
  readonly borderTopLeftRadius: string;
  readonly color: string;
  readonly fontFamily: string;
  readonly fontSize: string;
  readonly fontWeight: string;
  readonly lineHeight: string;
  readonly letterSpacing: string;
  readonly paddingBottom: string;
  readonly paddingLeft: string;
  readonly paddingRight: string;
  readonly paddingTop: string;
}

async function removeTemporaryBundleFiles(directory: string): Promise<void> {
  let fileNames: string[];
  try {
    fileNames = await readdir(directory);
  } catch (error: unknown) {
    if (error instanceof Error && "code" in error && error.code === "ENOENT") {
      return;
    }
    throw error;
  }
  await Promise.all(
    fileNames.map(async (fileName) => await unlink(path.join(directory, fileName))),
  );
  await rmdir(directory);
}

/** Runs the real media-callout build into an OS temporary directory for browser proof. */
export const buildMediaCalloutForBrowserTest = defineBrowserCommand(
  async ({ context }, pageUrl: string): Promise<BuiltMediaCalloutFiles> => {
    const temporaryRoot = await mkdtemp(path.join(tmpdir(), "agent-studio-media-callout-test-"));
    const outputDirectory = path.join(temporaryRoot, "bundle");
    try {
      const environment: NodeJS.ProcessEnv = { ...process.env, ASTRO_TELEMETRY_DISABLED: "1" };
      for (const variableName of ["VITEST", "VITEST_MODE", "VITEST_POOL_ID", "VITEST_WORKER_ID"]) {
        delete environment[variableName];
      }
      const buildProcess = spawn(
        process.execPath,
        [
          "--experimental-strip-types",
          path.join(webRoot, "scripts", "build-media-callout.ts"),
          "--output-directory",
          outputDirectory,
        ],
        { cwd: webRoot, env: environment, stdio: ["ignore", "ignore", "pipe"] },
      );
      let stderr = "";
      buildProcess.stderr.on("data", (chunk: Buffer): void => {
        stderr += chunk.toString("utf8");
      });
      const [exitCode]: unknown[] = await once(buildProcess, "exit");
      if (exitCode !== 0) {
        throw new Error(`build-media-callout exited with ${String(exitCode)}:\n${stderr}`);
      }

      const [html, css, javascript, manifest] = await Promise.all(
        outputFileNames.map(
          async (fileName) => await readFile(path.join(outputDirectory, fileName), "utf8"),
        ),
      );
      if (
        html === undefined ||
        css === undefined ||
        javascript === undefined ||
        manifest === undefined
      ) {
        throw new Error("The media-callout build omitted a required output file.");
      }
      const sitePage = await context.newPage();
      try {
        await sitePage.goto(pageUrl, { waitUntil: "domcontentloaded" });
        const stepPill = sitePage.locator("[data-chapter-step-active-label]").first();
        await stepPill.waitFor({ state: "attached" });
        const stepPillStyle = await stepPill.evaluate((element): StepPillStyleObservation => {
          const computedStyle = getComputedStyle(element);
          return {
            backgroundColor: computedStyle.backgroundColor,
            backgroundImage: computedStyle.backgroundImage,
            borderTopColor: computedStyle.borderTopColor,
            borderTopStyle: computedStyle.borderTopStyle,
            borderTopWidth: computedStyle.borderTopWidth,
            borderTopLeftRadius: computedStyle.borderTopLeftRadius,
            color: computedStyle.color,
            fontFamily: computedStyle.fontFamily,
            fontSize: computedStyle.fontSize,
            fontWeight: computedStyle.fontWeight,
            lineHeight: computedStyle.lineHeight,
            letterSpacing: computedStyle.letterSpacing,
            paddingBottom: computedStyle.paddingBottom,
            paddingLeft: computedStyle.paddingLeft,
            paddingRight: computedStyle.paddingRight,
            paddingTop: computedStyle.paddingTop,
          };
        });
        return { html, css, javascript, manifest, stepPillStyle };
      } finally {
        await sitePage.close();
      }
    } finally {
      await removeTemporaryBundleFiles(outputDirectory);
      await rmdir(temporaryRoot);
    }
  },
);
