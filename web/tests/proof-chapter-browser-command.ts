import { defineBrowserCommand } from "@vitest/browser-playwright";

export interface ProofClipMediaObservation {
  readonly playedSteps: readonly string[];
  readonly finalStep: string;
  readonly finalState: string;
  readonly paused: boolean;
  readonly posterPreserved: boolean;
  readonly replayedFinalState: string;
}

export const verifyProofClipMedia = defineBrowserCommand(
  async ({ context }, pageUrl: string, failMedia: boolean): Promise<ProofClipMediaObservation> => {
    const page = await context.newPage();
    try {
      await page.setViewportSize({ width: 1280, height: 1000 });
      if (failMedia) await page.route("**/*proof-video.mp4*", (route) => route.abort());
      await page.goto(pageUrl, { waitUntil: "load" });
      return await page.evaluate(async (shouldFail): Promise<ProofClipMediaObservation> => {
        const root = document.querySelector<HTMLElement>('[data-chapter-steps-root="proof"]');
        const stage = root?.querySelector<HTMLElement>("[data-chapter-clips]");
        if (root === null || stage === null || stage === undefined)
          throw new Error("Proof media fixture missing");
        const playedSteps: string[] = [];
        await new Promise<void>((resolve, reject): void => {
          root.addEventListener(
            "play",
            (event): void => {
              if (event.target instanceof HTMLVideoElement)
                playedSteps.push(event.target.dataset["chapterClipStep"] ?? "");
            },
            { capture: true },
          );
          root.addEventListener("agentstudio:scene-step-timing", (): void => {
            if (stage.dataset["clipPlaybackState"] === "ended") resolve();
          });
          root.addEventListener(
            "error",
            (): void => {
              if (shouldFail) resolve();
              else reject(new Error("Real fixture media failed to play"));
            },
            { capture: true },
          );
          root.querySelector<HTMLButtonElement>('[data-chapter-step="proof-run"]')?.click();
        });
        const active = stage.querySelector<HTMLVideoElement>("video:not([hidden])");
        if (active === null) throw new Error("Final Proof video missing");
        const observed: ProofClipMediaObservation = {
          playedSteps: [...playedSteps],
          finalStep: stage.dataset["activeClipStep"] ?? "",
          finalState: stage.dataset["clipPlaybackState"] ?? "",
          paused: active.paused,
          posterPreserved:
            active.poster !== "" &&
            root.querySelector('[data-chapter-step-panel="proof-run"]') !== null,
          replayedFinalState: "",
        };
        if (shouldFail) return observed;
        await active.play();
        const replayedFinalState = stage.dataset["clipPlaybackState"] ?? "";
        active.pause();
        return { ...observed, replayedFinalState };
      }, failMedia);
    } finally {
      await page.close();
    }
  },
);

export interface ProofChapterObservation {
  readonly stepIds: readonly string[];
  readonly initialStep: string;
  readonly initialSource: string;
  readonly changedStep: string;
  readonly changedSource: string;
  readonly keyboardStep: string;
  readonly autoStep: string;
  readonly inactiveSourceCount: number;
  readonly durationMatchesClip: boolean;
  readonly pausedOnDeactivate: boolean;
  readonly railJoinsStepLine: boolean;
}

export const verifyProofChapter = defineBrowserCommand(
  async ({ context }, pageUrl: string, width: number): Promise<ProofChapterObservation> => {
    const page = await context.newPage();
    try {
      await page.setViewportSize({ width, height: 1000 });
      // Reduced motion bounds the static observation, independently of clip length.
      await page.emulateMedia({ reducedMotion: "reduce" });
      await page.goto(pageUrl, { waitUntil: "load" });
      return await page.evaluate(async (): Promise<ProofChapterObservation> => {
        const root = document.querySelector<HTMLElement>('[data-chapter-steps-root="proof"]');
        if (root === null) throw new Error("Proof fixture chapter missing");
        const videos = Array.from(
          root.querySelectorAll<HTMLVideoElement>("[data-chapter-clip-step]"),
        );
        const tabs = Array.from(root.querySelectorAll<HTMLButtonElement>("[data-chapter-step]"));
        const activeVideo = (): HTMLVideoElement => {
          const video = videos.find((candidate) => !candidate.hidden);
          if (video === undefined) throw new Error("Active Proof clip missing");
          return video;
        };
        const sourceUrl = (): string =>
          activeVideo().querySelector("source")?.getAttribute("src") ?? "";
        const loadActiveClip = async (): Promise<void> => {
          const video = activeVideo();
          if (video.readyState >= 1) return;
          await new Promise<void>((resolve, reject): void => {
            video.addEventListener("loadedmetadata", () => resolve(), { once: true });
            video.addEventListener("error", () => reject(new Error("Fixture clip failed")), {
              once: true,
            });
            video.dispatchEvent(new Event("pointerdown"));
          });
        };
        await loadActiveClip();
        const initialStep = activeVideo().dataset["chapterClipStep"] ?? "";
        const initialSource = sourceUrl();
        const inactiveSourceCount = videos.filter(
          (video) => video.hidden && video.querySelector("source[src]") !== null,
        ).length;
        tabs[1]?.click();
        await loadActiveClip();
        const changedStep = activeVideo().dataset["chapterClipStep"] ?? "";
        const changedSource = sourceUrl();
        tabs[1]?.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true }));
        const keyboardStep = activeVideo().dataset["chapterClipStep"] ?? "";
        tabs[0]?.click();
        await loadActiveClip();
        let dwellSeconds = 0;
        root.addEventListener("agentstudio:scene-step-timing", (event): void => {
          if (
            event instanceof CustomEvent &&
            typeof event.detail === "object" &&
            event.detail !== null &&
            "dwellSeconds" in event.detail &&
            typeof event.detail.dwellSeconds === "number"
          )
            dwellSeconds = event.detail.dwellSeconds;
        });
        const firstVideo = activeVideo();
        firstVideo.dispatchEvent(new Event("timeupdate"));
        const durationMatchesClip = dwellSeconds === firstVideo.duration;
        // The actual media event is the step-completion boundary; no timer drives it.
        firstVideo.dispatchEvent(new Event("ended"));
        const autoStep = activeVideo().dataset["chapterClipStep"] ?? "";
        return {
          stepIds: tabs.map((tab) => tab.dataset["chapterStep"] ?? ""),
          initialStep,
          initialSource,
          changedStep,
          changedSource,
          keyboardStep,
          autoStep,
          inactiveSourceCount,
          durationMatchesClip,
          pausedOnDeactivate: firstVideo.paused,
          railJoinsStepLine:
            root.querySelector('[data-rail-step-line-target="proof"]') !== null &&
            document.querySelector('[data-route-anchor="proof"]') !== null,
        };
      });
    } finally {
      await page.close();
    }
  },
);
