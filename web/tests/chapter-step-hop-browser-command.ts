import { defineBrowserCommand } from "@vitest/browser-playwright";

export interface StepHopObservation {
  readonly ringFraction: number;
  readonly autoHeldState: string | undefined;
  readonly autoHeldGlyphVisible: boolean;
  readonly autoHeldRingOpacity: string;
  readonly clickedState: string | undefined;
  readonly togglePausedState: string | undefined;
  readonly togglePauseGlyphVisible: boolean;
  readonly toggleResumedState: string | undefined;
  readonly replayedElapsedSeconds: number | undefined;
  readonly pauseGlyphVisible: boolean;
  readonly glyphGlassClearance: number;
  readonly previewCount: number;
  readonly previewCountAfterFinish: number;
  readonly travelDuration: number;
  readonly branchDrawEnd: number;
  readonly labelUnfoldEnd: number;
  readonly newLabelOpacityAtStart: string;
  readonly outgoingLabelOpacity: Readonly<Record<"30" | "60" | "100", number>>;
  readonly outgoingBranchVisibleAt130: number;
  readonly travelDelta: number;
  readonly wrapDelta: number;
  readonly layoutShift: number;
  readonly resumedState: string | undefined;
}

export const verifyChapterStepHop = defineBrowserCommand(
  async ({ context }, pageUrl: string, width: number): Promise<StepHopObservation> => {
    const page = await context.newPage();
    try {
      await page.setViewportSize({ width, height: width < 620 ? 844 : 1000 });
      await page.addInitScript((): void => {
        // Browser projects run in parallel tabs; this scenario requires the
        // page to be visible so the real autoplay host emits readiness.
        Object.defineProperty(document, "hidden", { configurable: true, get: () => false });
        Object.defineProperty(document, "visibilityState", {
          configurable: true,
          get: () => "visible",
        });
        (window as Window & { chapterHopReady?: Promise<void> }).chapterHopReady = new Promise(
          (resolve) => {
            const onReady = (event: Event): void => {
              if (
                !(event instanceof CustomEvent) ||
                !(event.target instanceof HTMLElement) ||
                event.target.dataset["sceneRoot"] !== "chapter-many-agents"
              )
                return;
              document.removeEventListener("scene-playback-ready", onReady);
              const control = event.detail as { pause(): void; seek(seconds: number): void };
              control.pause();
              (window as Window & { chapterHopControl?: typeof control }).chapterHopControl =
                control;
              resolve();
            };
            document.addEventListener("scene-playback-ready", onReady);
          },
        );
      });
      await page.goto(`${pageUrl}#many-agents`, { waitUntil: "load" });
      await page.evaluate((): void => {
        document
          .querySelector('[data-chapter="many-agents"] [data-scroll-playback-stage]')
          ?.scrollIntoView({ block: "center", behavior: "instant" });
        window.dispatchEvent(new Event("scroll"));
      });
      return await page.evaluate(async (): Promise<StepHopObservation> => {
        await (window as Window & { chapterHopReady?: Promise<void> }).chapterHopReady;
        const control = (window as Window & { chapterHopControl?: { seek(seconds: number): void } })
          .chapterHopControl;
        const root = document.querySelector<HTMLElement>('[data-chapter-steps-root="many-agents"]');
        const scene = root?.querySelector<HTMLElement>('[data-scene-root="chapter-many-agents"]');
        const ring = root?.querySelector<SVGSVGElement>("[data-chapter-step-ring]");
        const progress = ring?.querySelector<SVGCircleElement>("[data-chapter-step-ring-progress]");
        const steps = [...(root?.querySelectorAll<HTMLButtonElement>("[data-chapter-step]") ?? [])];
        if (
          control === undefined ||
          root === null ||
          scene === undefined ||
          scene === null ||
          ring === undefined ||
          ring === null ||
          progress === undefined ||
          progress === null ||
          steps.length !== 3
        )
          throw new Error("Step hop runtime parts missing");
        const stepLine = root.querySelector<HTMLElement>("[data-chapter-step-line]");
        const pauseGlyph = root.querySelector<HTMLElement>("[data-chapter-step-pause-glyph]");
        if (stepLine === null || pauseGlyph === null)
          throw new Error("Step playback state markup missing");
        const held = new Promise<void>((resolve) => {
          const observer = new MutationObserver((): void => {
            if (
              scene.dataset["scenePlaybackState"] !== "paused" ||
              stepLine.dataset["stepPlayback"] !== "held"
            )
              return;
            observer.disconnect();
            resolve();
          });
          observer.observe(root, {
            attributes: true,
            attributeFilter: ["data-step-playback", "data-scene-playback-state"],
            subtree: true,
          });
          if (
            scene.dataset["scenePlaybackState"] === "paused" &&
            stepLine.dataset["stepPlayback"] === "held"
          ) {
            observer.disconnect();
            resolve();
          }
        });
        window.scrollTo({ top: 0, behavior: "instant" });
        window.dispatchEvent(new Event("scroll"));
        await held;
        const autoHeldState = stepLine.dataset["stepPlayback"];
        const autoHeldGlyphVisible = !pauseGlyph.hidden;
        const autoHeldRingOpacity = getComputedStyle(ring).opacity;
        const toggle = root.querySelector<HTMLButtonElement>("[data-scene-playback-toggle]");
        if (toggle === null) throw new Error("Many-agents playback toggle missing");
        toggle.click();
        control.seek(1.4);
        const countdown = progress.getAnimations()[0];
        const timing = countdown?.effect?.getTiming();
        const ringFraction = Number(countdown?.currentTime) / Number(timing?.duration);
        const nextChapter = document.querySelector<HTMLElement>(
          '[data-chapter="context-with-task"]',
        );
        const beforeY = nextChapter?.getBoundingClientRect().top ?? Number.NaN;
        steps[1]?.click();
        const clickedState = root.querySelector<HTMLElement>("[data-chapter-step-line]")?.dataset[
          "stepPlayback"
        ];
        const pauseGlyphVisible =
          root.querySelector<HTMLElement>("[data-chapter-step-pause-glyph]")?.hidden === false;
        const preview = root.querySelector<HTMLElement>("[data-scene-step-preview]");
        const previewCount = root.querySelectorAll("[data-scene-step-preview]").length;
        const travel = ring
          .getAnimations()
          .find((animation) => animation.effect?.getTiming().duration === 160);
        const travelKeyframes =
          travel?.effect instanceof KeyframeEffect ? travel.effect.getKeyframes() : [];
        const travelDelta = Number(
          String(travelKeyframes[0]?.["transform"]).match(/-?\d+(?:\.\d+)?/u)?.[0],
        );
        const travelDuration = Number(travel?.effect?.getTiming().duration);
        const branch = root.querySelector<SVGPathElement>("[data-chapter-step-branch]");
        const label = root.querySelector<HTMLElement>("[data-chapter-step-active-label]");
        const branchAnimation = branch?.getAnimations()[0];
        const labelAnimation = label?.getAnimations()[0];
        const outgoingLabel = root.querySelector<HTMLElement>(
          ".chapter-step-active-label:not([data-chapter-step-active-label])",
        );
        const outgoingBranch = root.querySelector<SVGPathElement>(
          ".chapter-step-active-branch:not([data-chapter-step-branch])",
        );
        const outgoingLabelAnimation = outgoingLabel?.getAnimations()[0];
        const outgoingBranchAnimation = outgoingBranch?.getAnimations()[0];
        if (
          outgoingLabel === null ||
          outgoingBranch === null ||
          outgoingLabelAnimation === undefined ||
          outgoingBranchAnimation === undefined
        )
          throw new Error("Outgoing hop animations missing");
        outgoingLabelAnimation.pause();
        outgoingBranchAnimation.pause();
        const opacityAt = (time: number): number => {
          outgoingLabelAnimation.currentTime = time;
          return Number(getComputedStyle(outgoingLabel).opacity);
        };
        const outgoingLabelOpacity = {
          "30": opacityAt(30),
          "60": opacityAt(60),
          "100": opacityAt(100),
        };
        outgoingBranchAnimation.currentTime = 130;
        const outgoingBranchVisibleAt130 = Math.max(
          0,
          outgoingBranch.getTotalLength() -
            Number.parseFloat(getComputedStyle(outgoingBranch).strokeDashoffset),
        );
        const branchTiming = branchAnimation?.effect?.getTiming();
        const labelTiming = labelAnimation?.effect?.getTiming();
        if (labelAnimation === undefined) throw new Error("Commit-hop label animation missing");
        labelAnimation.currentTime = 0;
        const newLabelOpacityAtStart = label === null ? "" : getComputedStyle(label).opacity;
        const branchDrawEnd = Number(branchTiming?.delay) + Number(branchTiming?.duration);
        const labelUnfoldEnd = Number(labelTiming?.delay) + Number(labelTiming?.duration);
        const previewAnimation = preview?.getAnimations()[0];
        travel?.finish();
        previewAnimation?.finish();
        await Promise.all([travel?.finished, previewAnimation?.finished]);
        toggle.click();
        const togglePausedState = scene.dataset["scenePlaybackState"];
        const togglePauseGlyphVisible = !pauseGlyph.hidden;
        const glass = root.querySelector<HTMLElement>("[data-rail-surface-target]");
        const glyphGlassClearance =
          glass === null
            ? Number.NaN
            : pauseGlyph.getBoundingClientRect().top - glass.getBoundingClientRect().bottom;
        const previewCountAfterFinish = root.querySelectorAll("[data-scene-step-preview]").length;
        const layoutShift = Math.abs(
          (nextChapter?.getBoundingClientRect().top ?? Number.NaN) - beforeY,
        );
        toggle.click();
        const toggleResumedState = scene.dataset["scenePlaybackState"];
        control.seek(3.8);
        let replayedElapsedSeconds: number | undefined;
        root.addEventListener(
          "agentstudio:scene-step-timing",
          (event: Event): void => {
            if (event instanceof CustomEvent && event.detail.stepId === "watch-folders")
              replayedElapsedSeconds = event.detail.elapsedSeconds;
          },
          { once: true },
        );
        steps[1]?.click();
        const resumedState = scene.dataset["scenePlaybackState"];
        control.seek(4.6);
        for (const animation of ring.getAnimations())
          if (animation.effect?.getTiming().duration === 160) animation.finish();
        control.seek(0);
        const wrap = ring
          .getAnimations()
          .find((animation) => animation.effect?.getTiming().duration === 160);
        const wrapKeyframes =
          wrap?.effect instanceof KeyframeEffect ? wrap.effect.getKeyframes() : [];
        const wrapDelta = Number(
          String(wrapKeyframes[0]?.["transform"]).match(/-?\d+(?:\.\d+)?/u)?.[0],
        );
        return {
          ringFraction,
          autoHeldState,
          autoHeldGlyphVisible,
          autoHeldRingOpacity,
          clickedState,
          togglePausedState,
          togglePauseGlyphVisible,
          toggleResumedState,
          replayedElapsedSeconds,
          pauseGlyphVisible,
          glyphGlassClearance,
          previewCount,
          previewCountAfterFinish,
          travelDuration,
          branchDrawEnd,
          labelUnfoldEnd,
          newLabelOpacityAtStart,
          outgoingLabelOpacity,
          outgoingBranchVisibleAt130,
          travelDelta,
          wrapDelta,
          layoutShift,
          resumedState,
        };
      });
    } finally {
      await page.close();
    }
  },
);

export const verifyReducedMotionStepLine = defineBrowserCommand(
  async (
    { context },
    pageUrl: string,
    width: number,
  ): Promise<{ readonly ringHidden: boolean; readonly animationCount: number }> => {
    const page = await context.newPage();
    try {
      await page.emulateMedia({ reducedMotion: "reduce" });
      await page.setViewportSize({ width, height: width < 620 ? 844 : 1000 });
      await page.goto(`${pageUrl}#many-agents`, { waitUntil: "domcontentloaded" });
      await page.locator('[data-chapter-steps-root="many-agents"][data-enhanced="true"]').waitFor();
      return await page.evaluate(() => {
        const root = document.querySelector<HTMLElement>('[data-chapter-steps-root="many-agents"]');
        const ring = root?.querySelector<SVGSVGElement>("[data-chapter-step-ring]");
        root?.querySelectorAll<HTMLButtonElement>("[data-chapter-step]")[1]?.click();
        return {
          ringHidden: ring?.hasAttribute("data-ring-hidden") ?? false,
          animationCount:
            root
              ?.querySelector<HTMLElement>("[data-chapter-step-line]")
              ?.getAnimations({ subtree: true }).length ?? -1,
        };
      });
    } finally {
      await page.close();
    }
  },
);
