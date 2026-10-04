import { spawnSync } from "node:child_process";
import { copyFile, mkdir, mkdtemp, rmdir, unlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";

import { expect, it } from "vitest";

const verifierPath = path.resolve(import.meta.dirname, "../scripts/verify-proof-video-players.ts");
const validProof =
  '<div data-scene-root="test"></div><div data-scene-proof="test"><video controls muted playsinline preload="none" poster="test.jpg" aria-label="Test proof" data-scene-proof-video><source data-src="test.mp4" type="video/mp4"></video></div>';

async function runVerifier(
  homepage: string,
): Promise<{ readonly status: number | null; readonly stderr: string }> {
  const fixtureRoot = await mkdtemp(path.join(tmpdir(), "proof-video-verifier-"));
  const scriptsPath = path.join(fixtureRoot, "scripts");
  const distPath = path.join(fixtureRoot, "dist");
  const scriptPath = path.join(scriptsPath, "verify-proof-video-players.ts");
  const homepagePath = path.join(distPath, "index.html");
  try {
    await mkdir(scriptsPath);
    await mkdir(distPath);
    await copyFile(verifierPath, scriptPath);
    await writeFile(homepagePath, homepage);
    const result = spawnSync(process.execPath, ["--experimental-strip-types", scriptPath], {
      encoding: "utf8",
    });
    return { status: result.status, stderr: result.stderr };
  } finally {
    await unlink(scriptPath);
    await unlink(homepagePath);
    await rmdir(scriptsPath);
    await rmdir(distPath);
    await rmdir(fixtureRoot);
  }
}

it("allows a built page with no proof videos", async () => {
  expect((await runVerifier('<main data-scene-root="chapter-come-back"></main>')).status).toBe(0);
});

it("verifies every proof video with arbitrary clip and accessibility names", async () => {
  expect(
    (await runVerifier(validProof + validProof.replaceAll("test.mp4", "review.mp4"))).status,
  ).toBe(0);
});

it("rejects an unmarked proof video", async () => {
  const result = await runVerifier(validProof.replace(" data-scene-proof-video", ""));
  expect(result.status).not.toBe(0);
  expect(result.stderr).toContain("data-scene-proof-video");
});

it("still discovers a proof container whose scene identity is missing", async () => {
  const missingSceneProof = validProof.replace('data-scene-proof="test"', "data-scene-proof");
  const result = await runVerifier(missingSceneProof.replace(" data-scene-proof-video", ""));
  expect(result.status).not.toBe(0);
  expect(result.stderr).toContain("data-scene-proof-video");
  const markedResult = await runVerifier(missingSceneProof);
  expect(markedResult.status).not.toBe(0);
  expect(markedResult.stderr).toContain("both its recreation and proof layer");
});

it("rejects an unmarked eager player after a valid marked proof video", async () => {
  const unmarkedEagerProof = validProof
    .replace(" data-scene-proof-video", "")
    .replace('data-src="test.mp4"', 'src="test.mp4"')
    .replace('preload="none"', 'preload="metadata"');
  const result = await runVerifier(validProof + unmarkedEagerProof);
  expect(result.status).not.toBe(0);
  expect(result.stderr).toContain("data-scene-proof-video");
});

it("discovers players after nested children in any proof-container element", async () => {
  const nestedProof = validProof
    .replace(
      '<div data-scene-proof="test">',
      '<section data-scene-proof="test"><div>Caption</div><div>',
    )
    .replace("</video></div>", "</video></div></section>");
  expect((await runVerifier(nestedProof)).status).toBe(0);
  const result = await runVerifier(nestedProof.replace(" data-scene-proof-video", ""));
  expect(result.status).not.toBe(0);
  expect(result.stderr).toContain("data-scene-proof-video");
});

it("allows empty proof containers and keeps the hero video outside proof scope", async () => {
  const hero = '<video preload="metadata"><source src="hero.mp4"></video>';
  expect((await runVerifier(hero + '<section data-scene-proof="test"></section>')).status).toBe(0);
  expect((await runVerifier(hero + validProof)).status).toBe(0);
});

it.each([
  ['preload="none"', 'preload="metadata"', 'preload="none"'],
  ['data-src="test.mp4"', 'src="test.mp4"', "deferred source"],
  ["controls muted", "muted", "controls"],
  ['aria-label="Test proof"', "", "aria-label"],
  ["data-scene-proof-video", "data-scene-proof-video autoplay", "scene handoff"],
] as const)(
  "rejects a proof player violating %s even after a valid player",
  async (before, after, error) => {
    const result = await runVerifier(validProof + validProof.replace(before, after));
    expect(result.status).not.toBe(0);
    expect(result.stderr).toContain(error);
  },
);

it("rejects a proof video without its paired recreation", async () => {
  const result = await runVerifier(
    validProof.replace('data-scene-root="test"', 'data-scene-root="other"'),
  );
  expect(result.status).not.toBe(0);
  expect(result.stderr).toContain("both its recreation and proof layer");
});
