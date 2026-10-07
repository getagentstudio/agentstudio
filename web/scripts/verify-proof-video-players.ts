import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

const renderedHomepagePath =
  process.argv[2] ?? fileURLToPath(new URL("../dist/index.html", import.meta.url));
const renderedHomepage = await readFile(renderedHomepagePath, "utf8");

interface ProofVideoPlayer {
  readonly markup: string;
  readonly sceneId: string | undefined;
  readonly clipContainer: ClipContainer | undefined;
}

interface ChapterStepContract {
  readonly chapterId: string;
  readonly stepIds: string[];
}

interface ClipContainer {
  readonly chapterId: string;
  readonly proofId: string | undefined;
  readonly chapter: ChapterStepContract | undefined;
  readonly videoStepIds: (string | undefined)[];
}

function readAttribute(tag: string, attributeName: string): string | undefined {
  const match = new RegExp(
    `\\s${attributeName}(?:=(?:"([^"]*)"|'([^']*)'|([^\\s>]+)))?(?=\\s|/?>)`,
    "u",
  ).exec(tag);
  return match === null ? undefined : (match[1] ?? match[2] ?? match[3] ?? "");
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

/** Discover proof-container descendants and explicit markers so neither can hide a broken player. */
function readProofVideoPlayers(homepage: string): {
  readonly players: readonly ProofVideoPlayer[];
  readonly clipContainers: readonly ClipContainer[];
} {
  const openElements: {
    readonly elementName: string;
    readonly proofSceneId: string | undefined;
    readonly chapter: ChapterStepContract | undefined;
    readonly clipContainer: ClipContainer | undefined;
  }[] = [];
  const proofPlayers: ProofVideoPlayer[] = [];
  const clipContainers: ClipContainer[] = [];
  // Comments and raw-text elements cannot introduce rendered descendants.
  const elementTokens = homepage.matchAll(
    /<!--[\s\S]*?-->|<(script|style|textarea|title)\b[^>]*>[\s\S]*?<\/\1\s*>|<\/?[a-z][\w:-]*\b(?:[^<>"']|"[^"]*"|'[^']*')*>/giu,
  );
  for (const token of elementTokens) {
    const [markupToken] = token;
    if (markupToken.startsWith("<!--")) continue;
    const tag =
      token[1] === undefined
        ? markupToken
        : (/^<[a-z][\w:-]*\b(?:[^<>"']|"[^"]*"|'[^']*')*>/iu.exec(markupToken)?.[0] ?? markupToken);
    const elementName = /^<\/?([\w:-]+)/u.exec(tag)?.[1]?.toLowerCase();
    if (elementName === undefined) continue;
    if (tag.startsWith("</")) {
      const openIndex = openElements.findLastIndex(
        (element) => element.elementName === elementName,
      );
      if (openIndex >= 0) openElements.splice(openIndex);
      continue;
    }
    const hasPlayerMarker = /\sdata-scene-proof-video(?:\s|=|>)/u.test(tag);
    if (hasPlayerMarker && elementName !== "video") {
      throw new Error("An element marked data-scene-proof-video must be a video element.");
    }
    if (token[1] !== undefined) continue;
    const inheritedChapter = openElements.findLast(
      (element) => element.chapter !== undefined,
    )?.chapter;
    const chapterId = readAttribute(tag, "data-chapter-steps-root");
    const chapter = chapterId === undefined ? inheritedChapter : { chapterId, stepIds: [] };
    const tabStepId = readAttribute(tag, "data-chapter-step");
    if (tabStepId !== undefined) chapter?.stepIds.push(tabStepId);
    const clipsChapterId = readAttribute(tag, "data-chapter-clips");
    const clipContainer =
      clipsChapterId === undefined
        ? openElements.findLast((element) => element.clipContainer !== undefined)?.clipContainer
        : {
            chapterId: clipsChapterId,
            proofId: readAttribute(tag, "data-scene-proof"),
            chapter,
            videoStepIds: [],
          };
    if (clipsChapterId !== undefined && clipContainer !== undefined)
      clipContainers.push(clipContainer);
    if (elementName === "video") {
      const sceneId = openElements.findLast(
        (element) => element.proofSceneId !== undefined,
      )?.proofSceneId;
      if (sceneId !== undefined || hasPlayerMarker) {
        const markup = /^<video\b[^>]*>[\s\S]*?<\/video\s*>/iu.exec(
          homepage.slice(token.index),
        )?.[0];
        if (markup === undefined)
          throw new Error("Rendered proof video is missing its closing tag.");
        proofPlayers.push({ markup, sceneId, clipContainer });
        clipContainer?.videoStepIds.push(readAttribute(tag, "data-chapter-clip-step"));
      }
    }
    if (!voidElementNames.has(elementName) && !tag.endsWith("/>")) {
      openElements.push({
        elementName,
        proofSceneId: readAttribute(tag, "data-scene-proof"),
        chapter,
        clipContainer,
      });
    }
  }
  return { players: proofPlayers, clipContainers };
}

let proofVideoCount = 0;

const { players, clipContainers } = readProofVideoPlayers(renderedHomepage);
for (const { markup: videoMarkup, sceneId, clipContainer } of players) {
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
  if (
    clipContainer === undefined &&
    (sceneId === undefined || !renderedHomepage.includes(`data-scene-root="${sceneId}"`))
  ) {
    throw new Error(
      `Rendered proof video ${proofVideoCount} must render both its recreation and proof layer.`,
    );
  }
}

for (const container of clipContainers) {
  const { chapter } = container;
  if (
    chapter === undefined ||
    chapter.chapterId !== container.chapterId ||
    container.proofId !== container.chapterId ||
    chapter.stepIds.length !== 3 ||
    new Set(chapter.stepIds).size !== 3 ||
    container.videoStepIds.length !== 3 ||
    container.videoStepIds.some((stepId, index) => stepId !== chapter.stepIds[index])
  ) {
    throw new Error(
      "A clips container must belong to its chapter and render three step-paired clips.",
    );
  }
}

console.log(`Verified ${proofVideoCount} rendered proof video players.`);
