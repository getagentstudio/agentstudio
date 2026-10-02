// Emits the website-owned callout as a small, source-pinned media asset.
// `callout.css` contains only the built website styles the pill fixture reaches.

import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs, promisify } from "node:util";

import { build, type Rolldown } from "vite";

import {
  mediaCalloutStagePresets,
  mediaCalloutStepPillClassName,
} from "../src/media-callout/media-callout.ts";
import { openHeadlessChromePage } from "./scene-bundles/headless-chrome-page.ts";
import { measureSelectorReachInPage } from "./scene-bundles/scene-bundle-page-functions.ts";
import { buildHomePageForSceneBundles } from "./scene-bundles/scene-source-site-build.ts";
import { parseBuiltStylesheet } from "./scene-bundles/scene-stylesheet-parser.ts";
import {
  buildScopedSceneStylesheet,
  collectSelectorProbes,
} from "./scene-bundles/scene-stylesheet-scoping.ts";

const webRoot = path.resolve(import.meta.dirname, "..");
const repositoryRoot = path.resolve(webRoot, "..");
const runFile = promisify(execFile);
const componentDirectory = path.join(webRoot, "src", "media-callout");
const componentEntryPath = path.join(componentDirectory, "media-callout.ts");

interface WebsiteRevision {
  readonly revision: string;
  readonly treeClean: boolean;
}

interface GsapRuntime {
  readonly version: string;
  readonly externalScript: string;
}

interface MediaCalloutFiles {
  readonly "callout.html": string;
  readonly "callout.css": string;
  readonly "callout.js": string;
}

interface MediaCalloutManifest {
  readonly schemaVersion: 1;
  readonly componentId: "media-callout";
  readonly websiteRevision: string;
  readonly websiteTreeClean: boolean;
  readonly gsap: {
    readonly version: string;
    readonly loading: "external-script";
    readonly scriptUrl: string;
  };
  readonly stagePresets: typeof mediaCalloutStagePresets;
  readonly parametersSchema: Readonly<Record<string, unknown>>;
  readonly sha256: Readonly<Record<keyof MediaCalloutFiles, string>>;
}

function mediaCalloutParametersSchema(): Readonly<Record<string, unknown>> {
  return {
    $schema: "https://json-schema.org/draft/2020-12/schema",
    type: "object",
    required: ["stage", "target", "labelPosition", "text", "animation"],
    properties: {
      stage: {
        oneOf: mediaCalloutStagePresets.map((preset) => ({
          title: preset.name,
          const: { width: preset.width, height: preset.height },
        })),
      },
      target: {
        type: "object",
        required: ["x", "y"],
        properties: {
          x: { type: "number", minimum: 6 },
          y: { type: "number", minimum: 6 },
        },
        additionalProperties: false,
      },
      labelPosition: { enum: ["auto", "left", "right", "above", "below"] },
      text: { type: "string", minLength: 1, pattern: "^[^\\r\\n]+$" },
      animation: { enum: ["in", "out", "held"] },
      startAtSeconds: { type: "number", minimum: 0, default: 0 },
    },
    additionalProperties: false,
  };
}

async function readWebsiteRevision(): Promise<WebsiteRevision> {
  const { stdout: revision } = await runFile("git", ["rev-parse", "HEAD"], {
    cwd: repositoryRoot,
  });
  const { stdout: changes } = await runFile("git", ["status", "--porcelain", "--", "web"], {
    cwd: repositoryRoot,
  });
  return { revision: revision.trim(), treeClean: changes.trim() === "" };
}

async function readGsapRuntime(): Promise<GsapRuntime> {
  const packageDirectory = path.dirname(fileURLToPath(import.meta.resolve("gsap")));
  const packageJson: unknown = JSON.parse(
    await readFile(path.join(packageDirectory, "package.json"), "utf8"),
  );
  if (
    typeof packageJson !== "object" ||
    packageJson === null ||
    !("version" in packageJson) ||
    typeof packageJson.version !== "string"
  ) {
    throw new Error("Could not read the installed GSAP version.");
  }
  const version = packageJson.version;
  return {
    version,
    externalScript: `https://cdn.jsdelivr.net/npm/gsap@${version}/dist/gsap.min.js`,
  };
}

function readSingleBundleChunk(output: Awaited<ReturnType<typeof build>>): Rolldown.OutputChunk {
  const outputs = Array.isArray(output) ? output : [output];
  const chunks = outputs.flatMap((buildOutput) =>
    "output" in buildOutput
      ? buildOutput.output.filter((item): item is Rolldown.OutputChunk => item.type === "chunk")
      : [],
  );
  const [chunk, ...extraChunks] = chunks;
  if (chunk === undefined || extraChunks.length > 0) {
    throw new Error(
      `Bundling media-callout produced ${String(chunks.length)} chunks; expected one.`,
    );
  }
  if (chunk.imports.length > 0) {
    throw new Error(`callout.js has runtime imports: ${chunk.imports.join(", ")}.`);
  }
  if (!chunk.exports.includes("mountMediaCallout")) {
    throw new Error("callout.js does not export mountMediaCallout.");
  }
  return chunk;
}

async function bundleMediaCalloutScript(): Promise<string> {
  const output = await build({
    configFile: false,
    envDir: false,
    logLevel: "warn",
    publicDir: false,
    root: webRoot,
    build: {
      write: false,
      minify: false,
      lib: {
        entry: componentEntryPath,
        formats: ["iife"],
        name: "AgentStudioMediaCallout",
        fileName: (): string => "callout.js",
      },
    },
  });
  return readSingleBundleChunk(output).code;
}

function createStyleProbeMarkup(): string {
  return [
    '<div class="media-callout-layer" data-scene-root="media-callout">',
    `<span class="${mediaCalloutStepPillClassName}" style="color:var(--color-primary);background-color:var(--color-canvas);stroke-width:var(--rail-line-width);font-family:var(--font-product);font-size:var(--text-step-label);line-height:var(--text-step-label--line-height)">Callout</span>`,
    "</div>",
  ].join("");
}

async function buildSiteStylesForCallout(): Promise<string> {
  const homePage = await buildHomePageForSceneBundles(webRoot);
  const stylesheetRules = Object.values(homePage.stylesheetTextByHref).flatMap((cssText) =>
    parseBuiltStylesheet(cssText),
  );
  const styleProbeMarkup = createStyleProbeMarkup();
  const page = await openHeadlessChromePage("Projecting media callout site styles");
  try {
    const selectorProbes = collectSelectorProbes(stylesheetRules);
    const reachBySelector = await page.evaluate(measureSelectorReachInPage, {
      sceneMarkup: styleProbeMarkup,
      selectorProbes,
    });
    const projectedStyles = buildScopedSceneStylesheet({
      sceneId: "media-callout",
      rules: stylesheetRules,
      reachBySelector: new Map(Object.entries(reachBySelector)),
      sceneMarkup: styleProbeMarkup,
    });
    const componentCss = await readFile(path.join(componentDirectory, "media-callout.css"), "utf8");
    const revision = await readWebsiteRevision();
    return [
      `/* Agent Studio media callout styles from website revision ${revision.revision}. */`,
      projectedStyles.cssText.trimEnd(),
      "",
      componentCss.trimEnd(),
      "",
    ].join("\n");
  } finally {
    await page.close();
  }
}

function createCalloutHtml(gsap: GsapRuntime): string {
  const previewStage = mediaCalloutStagePresets[0];
  if (previewStage === undefined) {
    throw new Error("The media callout has no default stage preset.");
  }
  return [
    "<!doctype html>",
    '<html lang="en">',
    "  <head>",
    '    <meta charset="utf-8">',
    '    <meta name="viewport" content="width=device-width, initial-scale=1">',
    "    <title>Agent Studio media callout</title>",
    '    <link rel="stylesheet" href="./callout.css">',
    `    <script src="${gsap.externalScript}"></script>`,
    '    <script src="./callout.js"></script>',
    "  </head>",
    '  <body class="media-callout-preview-body" data-scene-root="media-callout">',
    `    <main class="media-callout-preview-stage" id="media-callout-stage" data-media-callout-stage style="width:${String(previewStage.width)}px;height:${String(previewStage.height)}px"></main>`,
    "    <script>",
    '      const stage = document.getElementById("media-callout-stage");',
    "      const timeline = window.gsap.timeline({ paused: true });",
    "      window.AgentStudioMediaCallout.mountMediaCallout(stage, {",
    `        stage: { width: ${String(previewStage.width)}, height: ${String(previewStage.height)} },`,
    "        target: { x: 560, y: 600 },",
    '        labelPosition: "auto",',
    '        text: "Claude Code and Codex · same repo · two worktrees",',
    '        animation: "held"',
    "      }, timeline);",
    "    </script>",
    "  </body>",
    "</html>",
    "",
  ].join("\n");
}

function sha256Hex(value: string): string {
  return createHash("sha256").update(value, "utf8").digest("hex");
}

function createManifest(
  revision: WebsiteRevision,
  gsap: GsapRuntime,
  files: MediaCalloutFiles,
): MediaCalloutManifest {
  return {
    schemaVersion: 1,
    componentId: "media-callout",
    websiteRevision: revision.revision,
    websiteTreeClean: revision.treeClean,
    gsap: {
      version: gsap.version,
      loading: "external-script",
      scriptUrl: gsap.externalScript,
    },
    stagePresets: mediaCalloutStagePresets,
    parametersSchema: mediaCalloutParametersSchema(),
    sha256: {
      "callout.html": sha256Hex(files["callout.html"]),
      "callout.css": sha256Hex(files["callout.css"]),
      "callout.js": sha256Hex(files["callout.js"]),
    },
  };
}

async function writeMediaCalloutBundle(outputDirectory: string): Promise<void> {
  const revision = await readWebsiteRevision();
  const gsap = await readGsapRuntime();
  const files: MediaCalloutFiles = {
    "callout.html": createCalloutHtml(gsap),
    "callout.css": await buildSiteStylesForCallout(),
    "callout.js": await bundleMediaCalloutScript(),
  };
  const manifest = createManifest(revision, gsap, files);

  await mkdir(outputDirectory, { recursive: false });
  await Promise.all([
    ...Object.entries(files).map(
      async ([fileName, fileText]): Promise<void> =>
        await writeFile(path.join(outputDirectory, fileName), fileText, "utf8"),
    ),
    writeFile(
      path.join(outputDirectory, "manifest.json"),
      `${JSON.stringify(manifest, null, 2)}\n`,
      "utf8",
    ),
  ]);
  console.log(
    `media-callout: ${String(Object.keys(files).length)} files, GSAP ${gsap.version}, website ${revision.revision}${revision.treeClean ? "" : " (web tree dirty)"}`,
  );
}

const scriptArguments = process.argv.slice(2);
const forwardedArguments = scriptArguments[0] === "--" ? scriptArguments.slice(1) : scriptArguments;
const { values } = parseArgs({
  args: forwardedArguments,
  options: { "output-directory": { type: "string" } },
  allowPositionals: false,
});
const outputDirectoryArgument = values["output-directory"];
if (outputDirectoryArgument === undefined || outputDirectoryArgument.trim() === "") {
  throw new Error("Pass --output-directory <path> for the media callout bundle.");
}
const outputDirectory = path.resolve(outputDirectoryArgument);
await mkdir(path.dirname(outputDirectory), { recursive: true });
await writeMediaCalloutBundle(outputDirectory);
