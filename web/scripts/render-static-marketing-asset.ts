import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

import sharp from "sharp";

import { resolveChromeExecutable, stopBrowserProcess } from "./headless-chrome-process.ts";

interface StaticTemplateReplacement {
  readonly token: string;
  readonly value: string;
}

interface RenderStaticMarketingAssetProps {
  readonly assetName: string;
  readonly height: number;
  readonly outputPath: string;
  readonly renderScale?: number;
  readonly replacements: readonly StaticTemplateReplacement[];
  readonly templatePath: string;
  readonly temporaryDirectoryPrefix: string;
  readonly width: number;
}

async function waitForScreenshot(props: {
  readonly assetName: string;
  readonly browserProcess: ReturnType<typeof spawn>;
  readonly screenshotPath: string;
}): Promise<void> {
  await new Promise<void>((resolveScreenshot, rejectScreenshot) => {
    let settled = false;

    const finish = (error?: Error): void => {
      if (settled) return;

      settled = true;
      clearInterval(screenshotInterval);
      clearTimeout(screenshotTimeout);
      if (error === undefined) resolveScreenshot();
      else rejectScreenshot(error);
    };

    const inspectScreenshot = (): void => {
      void stat(props.screenshotPath)
        .then((screenshotStats): void => {
          if (screenshotStats.size > 0) finish();
        })
        .catch((): void => {
          // Chrome has not finished writing the screenshot yet.
        });
    };

    const screenshotInterval = setInterval(inspectScreenshot, 50);
    const screenshotTimeout = setTimeout(
      (): void =>
        finish(new Error(`Chrome did not render the ${props.assetName} within 30 seconds.`)),
      30_000,
    );

    props.browserProcess.once("error", (error): void => finish(error));
    inspectScreenshot();
  });
}

function applyTemplateReplacements(props: {
  readonly replacements: readonly StaticTemplateReplacement[];
  readonly template: string;
}): string {
  return props.replacements.reduce((renderedTemplate, replacement) => {
    if (!renderedTemplate.includes(replacement.token)) {
      throw new Error(`Static asset template is missing token ${replacement.token}.`);
    }
    return renderedTemplate.replaceAll(replacement.token, replacement.value);
  }, props.template);
}

export async function renderStaticMarketingAsset(
  props: RenderStaticMarketingAssetProps,
): Promise<void> {
  const renderScale = props.renderScale ?? 1;
  if (!Number.isInteger(renderScale) || renderScale < 1) {
    throw new Error(`Invalid render scale for ${props.assetName}.`);
  }
  const temporaryDirectory = await mkdtemp(resolve(tmpdir(), props.temporaryDirectoryPrefix));
  // True while Chrome may still be writing to the profile inside temporaryDirectory.
  let browserExitUnconfirmed = false;

  try {
    const template = await readFile(props.templatePath, "utf8");
    const renderedTemplate = applyTemplateReplacements({
      replacements: props.replacements,
      template,
    });
    const temporaryTemplatePath = resolve(temporaryDirectory, "asset.html");
    const rawScreenshotPath = resolve(temporaryDirectory, "asset-browser.png");
    const chromeProfileDirectory = resolve(temporaryDirectory, "chrome-profile");
    await writeFile(temporaryTemplatePath, renderedTemplate, "utf8");

    const chromeExecutable = await resolveChromeExecutable(`Generating the ${props.assetName}`);
    const browserProcess = spawn(
      chromeExecutable,
      [
        "--headless=new",
        "--disable-background-networking",
        "--disable-component-update",
        "--disable-gpu",
        `--force-device-scale-factor=${renderScale}`,
        "--hide-scrollbars",
        "--no-first-run",
        `--screenshot=${rawScreenshotPath}`,
        `--user-data-dir=${chromeProfileDirectory}`,
        `--window-size=${props.width},${props.height}`,
        pathToFileURL(temporaryTemplatePath).href,
      ],
      { stdio: "ignore" },
    );

    try {
      await waitForScreenshot({
        assetName: props.assetName,
        browserProcess,
        screenshotPath: rawScreenshotPath,
      });
    } finally {
      browserExitUnconfirmed = true;
      await stopBrowserProcess(browserProcess);
      browserExitUnconfirmed = false;
    }

    const rawMetadata = await sharp(rawScreenshotPath).metadata();
    const expectedRawWidth = props.width * renderScale;
    const expectedRawHeight = props.height * renderScale;
    if (rawMetadata.width !== expectedRawWidth || rawMetadata.height !== expectedRawHeight) {
      throw new Error(
        `Chrome rendered ${rawMetadata.width ?? "unknown"}x${rawMetadata.height ?? "unknown"}; expected ${expectedRawWidth}x${expectedRawHeight}.`,
      );
    }

    await sharp(rawScreenshotPath)
      .resize(props.width, props.height, { fit: "fill", kernel: "lanczos3" })
      .withMetadata({ icc: "srgb" })
      .png({ compressionLevel: 9 })
      .toFile(props.outputPath);
  } finally {
    // The Chrome profile lives inside. When Chrome's exit could not be confirmed the
    // folder is left in place rather than deleted under a live browser. Helper
    // processes can still flush files just after the browser exits, so rm retries
    // on ENOTEMPTY/EBUSY.
    if (!browserExitUnconfirmed) {
      await rm(temporaryDirectory, {
        force: true,
        recursive: true,
        maxRetries: 10,
        retryDelay: 100,
      });
    }
  }
}
