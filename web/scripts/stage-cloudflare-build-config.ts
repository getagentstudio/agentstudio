import { copyFile, lstat, mkdir, readFile, symlink, writeFile } from "node:fs/promises";
import { resolve } from "node:path";

const projectDirectory = process.cwd();
const sourceConfigPath = resolve(projectDirectory, "cloudflare.config.ts");
const stagedConfigPath = resolve(projectDirectory, "dist", "cloudflare.config.ts");
const stagedPublicDirectory = resolve(projectDirectory, "dist", "public");
const buildOutputLinkPath = resolve(projectDirectory, ".cloudflare");
const rootPublicAssets = [
  "agent-studio-social-card.png",
  "agent-studio-x-profile-banner.png",
  "agent-studio-youtube-channel-banner.png",
  "robots.txt",
  "llms.txt",
  "sitemap.xml",
];

const sourceConfig = await readFile(sourceConfigPath, "utf8");
const sourceWorkerImport = '"./src/campaign-attribution/campaign-request-worker.ts"';
const stagedWorkerImport = '"../src/campaign-attribution/campaign-request-worker.ts"';
if (!sourceConfig.includes(sourceWorkerImport)) {
  throw new Error("Cloudflare config does not contain the expected Worker entrypoint import");
}
await writeFile(stagedConfigPath, sourceConfig.replace(sourceWorkerImport, stagedWorkerImport));
await mkdir(stagedPublicDirectory, { recursive: true });
await Promise.all(
  rootPublicAssets.map((assetName): Promise<void> =>
    copyFile(
      resolve(projectDirectory, "dist", assetName),
      resolve(stagedPublicDirectory, assetName),
    ),
  ),
);

try {
  const buildOutputLinkStats = await lstat(buildOutputLinkPath);
  if (!buildOutputLinkStats.isSymbolicLink()) {
    throw new Error(`${buildOutputLinkPath} exists but is not the generated build-output link`);
  }
} catch (error: unknown) {
  if (error instanceof Error && "code" in error && error.code === "ENOENT") {
    await symlink("dist/.cloudflare", buildOutputLinkPath, "dir");
  } else {
    throw error;
  }
}
