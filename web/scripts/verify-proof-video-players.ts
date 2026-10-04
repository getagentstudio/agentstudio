import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

const renderedHomepagePath = fileURLToPath(new URL("../dist/index.html", import.meta.url));
const renderedHomepage = await readFile(renderedHomepagePath, "utf8");
const videoMarkups = renderedHomepage.match(/<video\b[^>]*>[\s\S]*?<\/video>/gu) ?? [];
const proofLayers = [
  ...renderedHomepage.matchAll(/<div\b[^>]*\sdata-scene-proof="([^"]+)"[^>]*>[\s\S]*?<\/div>/gu),
];
let proofVideoCount = 0;

for (const videoMarkup of videoMarkups) {
  const videoTag = videoMarkup.slice(0, videoMarkup.indexOf(">") + 1);
  if (!/\sdata-scene-proof-video(?:\s|=|>)/u.test(videoTag)) continue;
  proofVideoCount += 1;
  for (const attribute of ["controls", "muted", "playsinline"] as const) {
    if (!new RegExp(`\\s${attribute}(?:\\s|=|>)`, "u").test(videoTag)) {
      throw new Error(`Rendered proof video ${proofVideoCount} is missing ${attribute}.`);
    }
  }
  if (!/\spreload="none"(?:\s|>)/u.test(videoTag)) {
    throw new Error(`Rendered proof video ${proofVideoCount} is missing preload="none".`);
  }
  for (const attribute of ["poster", "aria-label"] as const) {
    if (!new RegExp(`\\s${attribute}="[^"]+"`, "u").test(videoTag)) {
      throw new Error(`Rendered proof video ${proofVideoCount} is missing ${attribute}.`);
    }
  }
  if (
    /<(?:video|source)\b[^>]*\ssrc=/u.test(videoMarkup) ||
    !/<source\b[^>]*\sdata-src="[^"]+"/u.test(videoMarkup)
  ) {
    throw new Error(
      `Rendered proof video ${proofVideoCount} must retain a deferred source without any eager src.`,
    );
  }
  if (/\s(?:autoplay|data-scroll-autoplay-video)(?:\s|=|>)/u.test(videoTag)) {
    throw new Error(`Rendered proof video ${proofVideoCount} must wait for its scene handoff.`);
  }
  const proofLayer = proofLayers.find(([markup]) => markup.includes(videoMarkup));
  const sceneId = proofLayer?.[1];
  if (sceneId === undefined || !renderedHomepage.includes(`data-scene-root="${sceneId}"`)) {
    throw new Error(
      `Rendered proof video ${proofVideoCount} must render both its recreation and proof layer.`,
    );
  }
}

console.log(`Verified ${proofVideoCount} rendered proof video players.`);
