// Builds the production site into a private directory and reads back the home
// page and its stylesheets: the real components' rendered markup and CSS.

import { mkdir, mkdtemp, readdir, readFile, rm } from "node:fs/promises";
import path from "node:path";

import { build as buildAstroSite } from "astro";

export interface BuiltHomePage {
  readonly homePageHtml: string;
  /** Every emitted stylesheet, keyed by the root-relative href pages link it with. */
  readonly stylesheetTextByHref: Readonly<Record<string, string>>;
}

async function readEmittedStylesheets(
  outputDirectory: string,
): Promise<Readonly<Record<string, string>>> {
  const entries = await readdir(outputDirectory, { recursive: true, withFileTypes: true });
  const stylesheets = entries.filter((entry) => entry.isFile() && entry.name.endsWith(".css"));
  return Object.fromEntries(
    await Promise.all(
      stylesheets.map(async (stylesheet): Promise<[string, string]> => {
        const filePath = path.join(stylesheet.parentPath, stylesheet.name);
        const href = `/${path.relative(outputDirectory, filePath).split(path.sep).join("/")}`;
        return [href, await readFile(filePath, "utf8")];
      }),
    ),
  );
}

export async function buildHomePageForSceneBundles(webRoot: string): Promise<BuiltHomePage> {
  // Every path stays inside web/ and unique per call: Astro stages prerender
  // output under cwd/.astro when outDir is outside cwd, and Vite defaults to the
  // shared node_modules/.vite, so concurrent builds would delete each other's files.
  const isolatedBuildsDirectory = path.join(
    webRoot,
    "node_modules",
    ".cache",
    "astro-isolated-builds",
  );
  await mkdir(isolatedBuildsDirectory, { recursive: true });
  const isolatedBuildRoot = await mkdtemp(path.join(isolatedBuildsDirectory, "build-"));
  const outputDirectory = path.join(isolatedBuildRoot, "dist");
  try {
    await buildAstroSite({
      root: webRoot,
      outDir: outputDirectory,
      cacheDir: path.join(isolatedBuildRoot, "cache"),
      vite: { cacheDir: path.join(isolatedBuildRoot, "vite-cache") },
      logLevel: "warn",
    });
    return {
      homePageHtml: await readFile(path.join(outputDirectory, "index.html"), "utf8"),
      stylesheetTextByHref: await readEmittedStylesheets(outputDirectory),
    };
  } finally {
    await rm(isolatedBuildRoot, { force: true, recursive: true });
  }
}
