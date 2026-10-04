import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

const renderedHomepagePath = fileURLToPath(new URL("../dist/index.html", import.meta.url));
const renderedHomepage = await readFile(renderedHomepagePath, "utf8");

interface ProofVideoPlayer {
  readonly markup: string;
  readonly sceneId: string;
}

const voidElementNames = new Set([
  "area",
  "base",
  "br",
  "col",
  "embed",
  "hr",
  "img",
  "input",
  "link",
  "meta",
  "param",
  "source",
  "track",
  "wbr",
]);

/** Discovery follows element ancestry, independent of the player marker. */
function readProofVideoPlayers(homepage: string): readonly ProofVideoPlayer[] {
  const openElements: {
    readonly elementName: string;
    readonly proofSceneId: string | undefined;
  }[] = [];
  const proofPlayers: ProofVideoPlayer[] = [];
  // Comments and raw-text elements cannot introduce rendered descendants.
  const elementTokens = homepage.matchAll(
    /<!--[\s\S]*?-->|<(script|style|textarea|title)\b[^>]*>[\s\S]*?<\/\1\s*>|<\/?[a-z][\w:-]*\b(?:[^<>"']|"[^"]*"|'[^']*')*>/giu,
  );
  for (const token of elementTokens) {
    const [tag] = token;
    if (tag.startsWith("<!--") || token[1] !== undefined) continue;
    const elementName = /^<\/?([\w:-]+)/u.exec(tag)?.[1]?.toLowerCase();
    if (elementName === undefined) continue;
    if (tag.startsWith("</")) {
      const openIndex = openElements.findLastIndex(
        (element) => element.elementName === elementName,
      );
      if (openIndex >= 0) openElements.splice(openIndex);
      continue;
    }
    if (elementName === "video") {
      const sceneId = openElements.findLast(
        (element) => element.proofSceneId !== undefined,
      )?.proofSceneId;
      if (sceneId !== undefined) {
        const markup = /^<video\b[^>]*>[\s\S]*?<\/video\s*>/iu.exec(
          homepage.slice(token.index),
        )?.[0];
        if (markup === undefined)
          throw new Error("Rendered proof video is missing its closing tag.");
        proofPlayers.push({ markup, sceneId });
      }
    }
    if (!voidElementNames.has(elementName) && !tag.endsWith("/>")) {
      const proofAttribute =
        /\sdata-scene-proof(?:=(?:"([^"]*)"|'([^']*)'|([^\s>]+)))?(?=\s|\/?>)/u.exec(tag);
      openElements.push({
        elementName,
        proofSceneId:
          proofAttribute === null
            ? undefined
            : (proofAttribute[1] ?? proofAttribute[2] ?? proofAttribute[3] ?? ""),
      });
    }
  }
  return proofPlayers;
}

let proofVideoCount = 0;

for (const { markup: videoMarkup, sceneId } of readProofVideoPlayers(renderedHomepage)) {
  const videoTag = videoMarkup.slice(0, videoMarkup.indexOf(">") + 1);
  proofVideoCount += 1;
  if (!/\sdata-scene-proof-video(?:\s|=|>)/u.test(videoTag)) {
    throw new Error(`Rendered proof video ${proofVideoCount} is missing data-scene-proof-video.`);
  }
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
  if (!renderedHomepage.includes(`data-scene-root="${sceneId}"`)) {
    throw new Error(
      `Rendered proof video ${proofVideoCount} must render both its recreation and proof layer.`,
    );
  }
}

console.log(`Verified ${proofVideoCount} rendered proof video players.`);
