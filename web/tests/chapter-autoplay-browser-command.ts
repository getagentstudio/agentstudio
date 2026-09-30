import { createHash } from "node:crypto";

import { defineBrowserCommand } from "@vitest/browser-playwright";

import type { SceneStepTimingDetail } from "../src/chapters/chapter-step-events.ts";
import type { ScenePlaybackControl } from "../src/home-page/scene-playback.ts";

export interface ChapterAutoplayObservation {
  readonly width: number;
  readonly stageVisibleFraction: number;
  readonly selectedStep: string;
  readonly sceneState: string | undefined;
}

export interface ChapterClickObservation {
  readonly stepId: string;
  readonly selectedStepId: string;
  readonly sceneState: string | undefined;
  readonly stageImageHash: string;
  readonly clickTiming: SceneStepTimingDetail;
}

interface ChapterClickFact {
  readonly selectedStepId: string;
  readonly sceneState: string | undefined;
  readonly timing: SceneStepTimingDetail | undefined;
}

interface ChapterClickCapture {
  control: ScenePlaybackControl | undefined;
  requestedStepId: string | undefined;
  timing: SceneStepTimingDetail | undefined;
  readonly facts: Record<string, ChapterClickFact>;
}

interface ChapterClickWindow extends Window {
  chapterClickCapture?: ChapterClickCapture;
}

export interface ManualChapterClaimObservation {
  readonly afterManualPlay: readonly string[];
  readonly afterReadingLineCrossing: readonly string[];
  readonly automaticPause: boolean;
}

/** A manual play of a non-current chapter must claim the one scene slot. */
export const verifyManualChapterClaim = defineBrowserCommand(
  async ({ context }, pageUrl: string): Promise<ManualChapterClaimObservation> => {
    const applicationPage = await context.newPage();
    try {
      await applicationPage.setViewportSize({ width: 1600, height: 1000 });
      await applicationPage.goto(pageUrl, { waitUntil: "domcontentloaded" });
      await applicationPage.evaluate(async (): Promise<void> => {
        await document.fonts.ready;
        const chapter = document.getElementById("many-agents");
        if (chapter === null) throw new Error("Many-agents chapter is missing");
        window.scrollTo({
          top: window.scrollY + chapter.getBoundingClientRect().top - 96,
          behavior: "instant",
        });
      });
      await applicationPage.waitForSelector(
        '#many-agents [data-scene-root][data-scene-playback-state="playing"]',
      );
      return await applicationPage.evaluate(async (): Promise<ManualChapterClaimObservation> => {
        const first = document.querySelector<HTMLElement>("#many-agents [data-scene-root]");
        const second = document.querySelector<HTMLElement>("#context-with-task [data-scene-root]");
        const secondToggle = document.querySelector<HTMLButtonElement>(
          "#context-with-task [data-scene-playback-toggle]",
        );
        const secondTitle = document.querySelector<HTMLElement>(
          "#context-with-task .chapter-title",
        );
        if (first === null || second === null || secondToggle === null || secondTitle === null)
          throw new Error("Two chapter scenes and their controls are required");
        let automaticPause = false;
        first.addEventListener("agentstudio:scene-step-timing", (event: Event): void => {
          if (event instanceof CustomEvent)
            automaticPause = event.detail.running === false && event.detail.manualPause === false;
        });
        const phases = (): readonly string[] => [
          first.dataset["scenePlaybackState"] ?? "missing",
          second.dataset["scenePlaybackState"] ?? "missing",
        ];
        secondToggle.click();
        const afterManualPlay = phases();
        const changed = new Promise<void>((resolve) => {
          document.addEventListener("chapter-activity-changed", () => resolve(), { once: true });
        });
        window.scrollTo({
          top: window.scrollY + secondTitle.getBoundingClientRect().top - window.innerHeight * 0.45,
          behavior: "instant",
        });
        await changed;
        return { afterManualPlay, afterReadingLineCrossing: phases(), automaticPause };
      });
    } finally {
      await applicationPage.close();
    }
  },
);

export const verifyChapterSceneClicks = defineBrowserCommand(
  async (
    { context },
    pageUrl: string,
    width: number,
    height: number,
  ): Promise<ChapterClickObservation[]> => {
    const applicationPage = await context.newPage();
    const samples: ChapterClickObservation[] = [];
    try {
      await applicationPage.addInitScript((): void => {
        const capture: ChapterClickCapture = {
          control: undefined,
          requestedStepId: undefined,
          timing: undefined,
          facts: {},
        };
        (window as ChapterClickWindow).chapterClickCapture = capture;
        document.addEventListener("scene-playback-ready", (event: Event): void => {
          if (
            event instanceof CustomEvent &&
            event.target instanceof HTMLElement &&
            event.target.dataset["sceneRoot"] === "chapter-many-agents"
          )
            capture.control = event.detail as ScenePlaybackControl;
        });
        const isChapterRequest = (event: Event): event is CustomEvent<{ stepId: string }> =>
          event instanceof CustomEvent &&
          event.target instanceof HTMLElement &&
          event.target.dataset["railSurfaceTarget"] === "many-agents";
        document.addEventListener(
          "agentstudio:chapter-step-requested",
          (event: Event): void => {
            if (!isChapterRequest(event)) return;
            capture.requestedStepId = event.detail.stepId;
            capture.timing = undefined;
          },
          { capture: true },
        );
        document.addEventListener("agentstudio:scene-step-timing", (event: Event): void => {
          if (
            !(event instanceof CustomEvent) ||
            !(event.target instanceof HTMLElement) ||
            event.target.dataset["sceneRoot"] !== "chapter-many-agents"
          )
            return;
          const detail = event.detail as SceneStepTimingDetail;
          if (detail.stepId === capture.requestedStepId) capture.timing = { ...detail };
        });
        document.addEventListener("agentstudio:chapter-step-requested", (event: Event): void => {
          if (!isChapterRequest(event)) return;
          // The scene owner has handled the request and posted its real
          // running fact. Record that fact before holding the capture clock.
          capture.facts[event.detail.stepId] = {
            selectedStepId:
              document
                .querySelector('#many-agents [data-chapter-step][aria-selected="true"]')
                ?.getAttribute("data-chapter-step") ?? "",
            sceneState: document.querySelector<HTMLElement>("#many-agents [data-scene-root]")
              ?.dataset["scenePlaybackState"],
            timing: capture.timing,
          };
          capture.requestedStepId = undefined;
          capture.control?.pause();
        });
      });
      await applicationPage.route(/\.(mp4|webm)(\?|$)/u, async (route) => {
        await route.abort();
      });
      await applicationPage.setViewportSize({ width, height });
      await applicationPage.goto(pageUrl, { waitUntil: "domcontentloaded" });
      await applicationPage.evaluate(async () => {
        await document.fonts.ready;
      });
      await applicationPage.evaluate(() => {
        const chapter = document.getElementById("many-agents");
        if (chapter === null) throw new Error("Many-agents chapter is missing");
        window.scrollTo({
          top: window.scrollY + chapter.getBoundingClientRect().top - 96,
          behavior: "instant",
        });
      });
      await applicationPage.waitForSelector(
        '#many-agents [data-scene-root][data-scene-playback-state="playing"]',
      );
      for (const stepId of ["parallel-agents", "watch-folders", "navigation"]) {
        await applicationPage.click(`#many-agents [data-chapter-step="${stepId}"]`);
        const clickFact = await applicationPage.evaluate((requestedStepId: string) => {
          const capture = (window as ChapterClickWindow).chapterClickCapture;
          const fact = capture?.facts[requestedStepId];
          if (capture?.control === undefined || fact?.timing === undefined)
            throw new Error(`Missing scene-owned click timing fact for ${requestedStepId}`);
          return { ...fact, timing: fact.timing };
        }, stepId);
        await applicationPage.evaluate(async (): Promise<void> => {
          const preview = document.querySelector<HTMLElement>(
            "#many-agents [data-scene-step-preview]",
          );
          if (preview === null) return;
          await Promise.all(preview.getAnimations().map((animation) => animation.finished));
        });
        const geometry = await applicationPage.evaluate(() => {
          const stage = document.querySelector("#many-agents [data-scroll-playback-stage]");
          const scene = document.querySelector<HTMLElement>("#many-agents [data-scene-root]");
          const selected = document.querySelector<HTMLElement>(
            '#many-agents [data-chapter-step][aria-selected="true"]',
          );
          if (stage === null || scene === null || selected === null)
            throw new Error("Chapter click state is missing");
          const bounds = stage.getBoundingClientRect();
          const x = Math.max(0, bounds.left);
          const y = Math.max(0, bounds.top);
          return {
            x,
            y,
            width: Math.min(bounds.right, innerWidth) - x,
            height: Math.min(bounds.bottom, innerHeight) - y,
            sceneState: scene.dataset["scenePlaybackState"],
            selectedStepId: selected.dataset["chapterStep"] ?? "",
          };
        });
        const image = await applicationPage.screenshot({
          clip: { x: geometry.x, y: geometry.y, width: geometry.width, height: geometry.height },
        });
        samples.push({
          stepId,
          selectedStepId: clickFact.selectedStepId,
          sceneState: clickFact.sceneState,
          clickTiming: clickFact.timing,
          stageImageHash: createHash("sha256").update(image).digest("hex"),
        });
        if (stepId === "parallel-agents") {
          await applicationPage.evaluate(() => window.scrollBy({ top: 1, behavior: "instant" }));
          await applicationPage.waitForFunction(() => {
            const artwork = document.querySelector<SVGSVGElement>("[data-full-page-topology]");
            const progress = Number(artwork?.dataset["topologyScrollProgress"]);
            const maxScroll = Math.max(document.documentElement.scrollHeight - innerHeight, 1);
            return Number.isFinite(progress) && Math.abs(progress - scrollY / maxScroll) < 0.0001;
          });
          const stillFirst = await applicationPage.evaluate(() => ({
            selected: document
              .querySelector('#many-agents [data-chapter-step][aria-selected="true"]')
              ?.getAttribute("data-chapter-step"),
            state: document.querySelector<HTMLElement>("#many-agents [data-scene-root]")?.dataset[
              "scenePlaybackState"
            ],
          }));
          if (stillFirst.selected !== "parallel-agents" || stillFirst.state !== "playing") {
            throw new Error(`Clicked first step stopped playing: ${JSON.stringify(stillFirst)}`);
          }
        }
      }
      return samples;
    } finally {
      await applicationPage.close();
    }
  },
);

export const verifyChapterAutoplayAtNaturalFraming = defineBrowserCommand(
  async (
    { context },
    pageUrl: string,
    width: number,
    height: number,
  ): Promise<ChapterAutoplayObservation> => {
    const applicationPage = await context.newPage();
    try {
      await applicationPage.route(/\.(mp4|webm)(\?|$)/u, async (route) => {
        await route.abort();
      });
      await applicationPage.setViewportSize({ width, height });
      await applicationPage.goto(pageUrl, { waitUntil: "domcontentloaded" });
      await applicationPage.evaluate(async () => {
        await document.fonts.ready;
      });
      await applicationPage.evaluate(() => {
        const chapter = document.getElementById("many-agents");
        if (chapter === null) throw new Error("Many-agents chapter is missing");
        window.scrollTo({
          top: window.scrollY + chapter.getBoundingClientRect().top - 96,
          behavior: "instant",
        });
      });
      await applicationPage.waitForSelector(
        '#many-agents [data-scene-root][data-scene-playback-state="playing"]',
      );
      await applicationPage.waitForFunction(
        () =>
          document
            .querySelector('#many-agents [data-chapter-step][aria-selected="true"]')
            ?.getAttribute("data-chapter-step") !== "parallel-agents",
      );
      return await applicationPage.evaluate((width): ChapterAutoplayObservation => {
        const stage = document.querySelector("#many-agents [data-scroll-playback-stage]");
        const scene = document.querySelector<HTMLElement>("#many-agents [data-scene-root]");
        const selected = document.querySelector<HTMLElement>(
          '#many-agents [data-chapter-step][aria-selected="true"]',
        );
        if (stage === null || scene === null || selected === null)
          throw new Error("Chapter autoplay is incomplete");
        const bounds = stage.getBoundingClientRect();
        const visible = Math.max(
          0,
          Math.min(bounds.bottom, window.innerHeight) - Math.max(bounds.top, 0),
        );
        return {
          width,
          stageVisibleFraction: visible / Math.min(bounds.height, window.innerHeight),
          selectedStep: selected.dataset["chapterStep"] ?? "",
          sceneState: scene.dataset["scenePlaybackState"],
        };
      }, width);
    } finally {
      await applicationPage.close();
    }
  },
);
