import { expect, inject, it } from "vitest";
import { commands } from "vitest/browser";

import { createChapterClipPlayback } from "../src/chapters/chapter-clip-playback";
import type { StepLineJoinObservation } from "./chapter-step-join-browser-command";
import type {
  ProofChapterObservation,
  ProofClipMediaObservation,
} from "./proof-chapter-browser-command";

declare module "vitest/browser" {
  interface BrowserCommands {
    verifyStepLineJoins(
      pageUrl: string,
      widths: readonly number[],
    ): Promise<StepLineJoinObservation[]>;
    verifyProofChapter(pageUrl: string, width: number): Promise<ProofChapterObservation>;
    verifyProofClipMedia(pageUrl: string, failMedia: boolean): Promise<ProofClipMediaObservation>;
  }
}

it("keeps one fork node and lands the Proof rail on the existing step line", async () => {
  const observations = await commands.verifyStepLineJoins(
    new URL("/__test/proof-chapter", inject("siteHeaderBrowserTestUrl")).href,
    [390, 1280, 1600],
  );
  for (const observation of observations) {
    const proof = observation.joins.find((join) => join.anchorId === "proof");
    expect(observation.joins).toHaveLength(6);
    expect(proof?.stepDotCount).toBe(3);
    expect(proof?.nodeCountAtFork).toBe(1);
    expect(proof?.visibleInterveningNodeCount).toBe(0);
    expect(proof?.targetGap).toBeLessThanOrEqual(1);
    expect(proof?.landsOnGlassEdge).toBe(false);
    expect(proof?.activeLabelText).toBe(proof?.selectedStepLabel);
  }
});

it("honors native manual play when autoplay is disabled and pauses on disposal", async () => {
  const fixtureUrl = new URL("/__test/proof-chapter", inject("siteHeaderBrowserTestUrl"));
  fixtureUrl.hostname = location.hostname;
  const response = await fetch(fixtureUrl);
  const parsed = new DOMParser().parseFromString(await response.text(), "text/html");
  const originalRoot = parsed.querySelector('[data-chapter-steps-root="proof"]');
  if (originalRoot === null) throw new Error("Proof fixture missing");
  const root = document.importNode(originalRoot, true);
  document.body.append(root);
  const surface = root.querySelector<HTMLElement>('[data-rail-surface-target="proof"]');
  const video = root.querySelector<HTMLVideoElement>('video[data-chapter-clip-step="proof-run"]');
  if (surface === null || video === null) throw new Error("Proof fixture surface missing");
  const playback = createChapterClipPlayback(surface);
  try {
    const loaded = new Promise<void>((resolve, reject): void => {
      video.addEventListener("canplay", () => resolve(), { once: true });
      video.addEventListener("error", () => reject(new Error("Manual clip failed to load")), {
        once: true,
      });
    });
    video.dispatchEvent(new Event("pointerdown"));
    await loaded;
    await video.play();
    playback.synchronize(1, false);
    expect(video.paused).toBe(false);
  } finally {
    playback.dispose();
    expect(video.paused).toBe(true);
    root.remove();
  }
});

it("advances all three real fixture clips on native media completion and holds the last frame", async () => {
  const observed = await commands.verifyProofClipMedia(
    new URL("/__test/proof-chapter", inject("siteHeaderBrowserTestUrl")).href,
    false,
  );
  expect(observed.playedSteps).toEqual(["proof-run", "proof-review", "proof-panes"]);
  expect(observed.finalStep).toBe("proof-panes");
  expect(observed.finalState).toBe("ended");
  expect(observed.replayedFinalState).toBe("playing");
  expect(observed.paused).toBe(true);
});

it("preserves the poster and copy when real media loading fails", async () => {
  const observed = await commands.verifyProofClipMedia(
    new URL("/__test/proof-chapter", inject("siteHeaderBrowserTestUrl")).href,
    true,
  );
  expect(observed.playedSteps).toEqual([]);
  expect(observed.finalStep).toBe("proof-run");
  expect(observed.paused).toBe(true);
  expect(observed.posterPreserved).toBe(true);
});

it.each([1600, 390])(
  "uses real chapter tabs and deferred clips on the rail at %i",
  async (width) => {
    const observed = await commands.verifyProofChapter(
      new URL("/__test/proof-chapter", inject("siteHeaderBrowserTestUrl")).href,
      width,
    );
    expect(observed.stepIds).toEqual(["proof-run", "proof-review", "proof-panes"]);
    expect(observed.initialStep).toBe("proof-run");
    expect(observed.initialSource).toContain(width === 390 ? "phone" : "desktop");
    expect(observed.changedStep).toBe("proof-review");
    expect(observed.changedSource).toContain("proof-review");
    expect(observed.keyboardStep).toBe("proof-panes");
    expect(observed.autoStep).toBe("proof-review");
    expect(observed.inactiveSourceCount).toBe(0);
    expect(observed.durationMatchesClip).toBe(true);
    expect(observed.pausedOnDeactivate).toBe(true);
    expect(observed.railJoinsStepLine).toBe(true);
  },
);
