import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

const renderedHomepagePath = fileURLToPath(new URL("../dist/index.html", import.meta.url));
const renderedHomepage = await readFile(renderedHomepagePath, "utf8");
const sessionVideoTags = renderedHomepage.match(
  /<video\b[^>]*\bdata-session-restore-video(?:=(?:"[^"]*"|'[^']*'|[^\s>]+))?[^>]*>/gu,
);

if (sessionVideoTags?.length !== 1) {
  throw new Error(
    `Expected one rendered session-restore video, found ${sessionVideoTags?.length ?? 0}.`,
  );
}

const [sessionVideoTag] = sessionVideoTags;
const requiredAttributes = [
  "controls",
  "muted",
  "playsinline",
  'preload="none"',
  "poster=",
  'aria-label="Agent Studio persistent session restore demonstration"',
  "data-scene-proof-video",
] as const;

for (const requiredAttribute of requiredAttributes) {
  if (!sessionVideoTag.includes(requiredAttribute)) {
    throw new Error(`Rendered session-restore video is missing ${requiredAttribute}.`);
  }
}

const sessionVideoMarkup = renderedHomepage.match(
  /<video\b[^>]*data-session-restore-video[^>]*>[\s\S]*?<\/video>/u,
)?.[0];
if (
  sessionVideoMarkup === undefined ||
  /<(?:video|source)\b[^>]*\ssrc=/u.test(sessionVideoMarkup) ||
  !/data-src="[^"]+session-restore[^"/]*\.mp4"/u.test(sessionVideoMarkup)
) {
  throw new Error("Session restore must retain its deferred source without any eager src.");
}

if (/\s(?:autoplay|data-scroll-autoplay-video)(?:\s|=|>)/u.test(sessionVideoTag)) {
  throw new Error("Rendered session-restore proof video must wait for its scene handoff.");
}

if (
  !renderedHomepage.includes('data-scene-root="chapter-come-back"') ||
  !renderedHomepage.includes('data-scene-proof="chapter-come-back"')
) {
  throw new Error("Session restore must render both its recreation and real video proof.");
}

console.log("Verified the rendered session-restore player contract.");
