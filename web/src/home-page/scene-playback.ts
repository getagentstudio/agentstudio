import { gsap } from "gsap";

import { sceneRootAttribute } from "../chapters/chapter-dom-contract";
import {
  chapterStepRequestedEventName,
  createChapterStepEvent,
  createSceneStepTimingEvent,
  readChapterStepEventStepId,
  sceneStepReachedEventName,
} from "../chapters/chapter-step-events";
import {
  isSceneId,
  type SceneId,
  type SceneModule,
  type SceneTimeline,
} from "../motion-scenes/scene-contract";
import { resolveSceneModule } from "../motion-scenes/scene-registry";
import { createDeferredProofVideo } from "./deferred-proof-video";
import { findSceneProofLayer, type SceneProofTransition } from "./scene-proof-layer";
import { publishSceneStepTiming } from "./scene-step-timing-publisher";
import { combineSurfacePlaybacks, type SurfacePlayback } from "./surface-playback";

// Same thresholds and replay delay as the scroll-autoplay video, so a scene and
// a video on the page start, stop, and loop at the same scroll positions.
const startProgress = 0.95;
const stopProgress = 0.9;
export const sceneReplayDelayMs = 3000;
const sceneSeed = 1;
const reducedMotionQuery = "(prefers-reduced-motion: reduce)";

/** The visitor's play/pause control for a scene; hidden until motion can run. */
const scenePlaybackToggleSelector = "[data-scene-playback-toggle]";
export const scenePlaybackReadyEventName = "scene-playback-ready";

export interface ScenePlaybackControl {
  readonly duration: number;
  pause(): void;
  seek(seconds: number): void;
  finish(): void;
}

export type SceneModuleResolver = (sceneId: SceneId) => SceneModule | undefined;

/**
 * `settled` means no timeline exists and the markup shows the scene's final,
 * no-script state. `awaiting-replay` holds that final frame between loops.
 */
export type ScenePlaybackPhase = "settled" | "playing" | "paused" | "awaiting-replay";

type PlaybackIntent = "auto" | "manual-pause" | "manual-play";

export interface ScenePlaybackProps {
  readonly resolveModule?: SceneModuleResolver;
  readonly sceneRoot: HTMLElement;
  readonly surface: HTMLElement;
  /** The page controller owns the single playing slot across chapter surfaces. */
  readonly onManualPlay?: (() => void) | undefined;
}

interface ScenePlaybackState {
  autoplayEnabled: boolean;
  awaitingReplay: boolean;
  buildFailed: boolean;
  intent: PlaybackIntent;
  lastReportedStepId: string | undefined;
  latestProgress: number;
  phase: ScenePlaybackPhase;
  proofVideoEnded: boolean;
  replayTimer: number | undefined;
  /** A manual play paused only because the document is hidden; intent is kept. */
  suspendedWhileHidden: boolean;
  timeline: SceneTimeline | undefined;
}

function readSceneModule(
  sceneRoot: HTMLElement,
  resolveModule: SceneModuleResolver,
): SceneModule | undefined {
  const sceneId = sceneRoot.getAttribute(sceneRootAttribute) ?? "";
  return isSceneId(sceneId) ? resolveModule(sceneId) : undefined;
}

function findStepAtTime(module: SceneModule, timeline: SceneTimeline): string | undefined {
  const playheadTime = timeline.time();
  let reachedStep: { readonly stepId: string; readonly labelTime: number } | undefined;
  for (const step of module.steps) {
    const labelTime = timeline.labels[step.timelineLabel];
    if (
      labelTime !== undefined &&
      labelTime <= playheadTime &&
      (reachedStep === undefined || labelTime >= reachedStep.labelTime)
    ) {
      reachedStep = { stepId: step.stepId, labelTime };
    }
  }
  return reachedStep?.stepId;
}

/**
 * Plays one scene module inside a glass surface with the scroll-autoplay
 * video's semantics: play when centered, pause with hysteresis when leaving,
 * replay after a delay while still centered, and let manual intent win.
 * Each completed pass hands the stage to the real capture until the replay.
 * Reduced motion or an unregistered module never builds tweens; reduced
 * motion shows the real capture as the static view.
 */
export function createScenePlayback(props: ScenePlaybackProps): SurfacePlayback {
  const { sceneRoot, surface } = props;
  const sceneModule = readSceneModule(sceneRoot, props.resolveModule ?? resolveSceneModule);
  const motionPreference = window.matchMedia(reducedMotionQuery);
  const toggle = surface.querySelector<HTMLButtonElement>(scenePlaybackToggleSelector);
  const proofVideo = surface.querySelector<HTMLVideoElement>("[data-scene-proof-video]");
  const deferredVideo = createDeferredProofVideo(proofVideo);
  const proofLayer = findSceneProofLayer(surface, sceneRoot);
  const lifecycle = new AbortController();
  const state: ScenePlaybackState = {
    autoplayEnabled: true,
    awaitingReplay: false,
    buildFailed: false,
    intent: "auto",
    lastReportedStepId: undefined,
    latestProgress: 0,
    phase: "settled",
    proofVideoEnded: false,
    replayTimer: undefined,
    suspendedWhileHidden: false,
    timeline: undefined,
  };

  const motionAllowed = (): boolean =>
    sceneModule !== undefined && !state.buildFailed && !motionPreference.matches;

  let proofVideoIntent: PlaybackIntent = "auto";
  let automaticVideoPlayPending = false;
  let automaticVideoPausePending = false;
  let activeStepPreview: HTMLElement | undefined;
  let replayTimerStartedAt: number | undefined;
  const endFailedProofBeat = (): void => {
    automaticVideoPlayPending = false;
    if (!state.awaitingReplay || proofVideoIntent !== "auto") return;
    state.proofVideoEnded = true;
    replayIfEligible();
  };
  const publishStepTiming = (): void => {
    const timeline = state.timeline;
    const stepId = state.lastReportedStepId;
    if (timeline === undefined || sceneModule === undefined || stepId === undefined) return;
    publishSceneStepTiming({
      awaitingReplay: state.awaitingReplay,
      manualPause: state.intent === "manual-pause",
      playingScene: state.phase === "playing",
      proofVideo,
      proofVideoEnded: state.proofVideoEnded,
      replayDelayMs: sceneReplayDelayMs,
      replayTimerActive: state.replayTimer !== undefined,
      replayTimerStartedAt,
      sceneModule,
      sceneRoot,
      stepId,
      timeline,
    });
  };
  const pauseProofVideoAutomatically = (): void => {
    if (proofVideo === null || proofVideo.paused || proofVideoIntent === "manual-play") return;
    automaticVideoPausePending = true;
    proofVideo.pause();
  };
  const playProofVideoAutomatically = (): void => {
    if (
      proofVideo === null ||
      !proofVideo.paused ||
      proofVideoIntent !== "auto" ||
      state.proofVideoEnded
    )
      return;
    deferredVideo.prime();
    // Near-view loading can fail before the scene hands over to its proof.
    if (proofVideo.error !== null) {
      endFailedProofBeat();
      return;
    }
    // A loading source holds the poster; canplay resumes this same proof beat.
    if (proofVideo.readyState < HTMLMediaElement.HAVE_FUTURE_DATA) return;
    automaticVideoPlayPending = true;
    void proofVideo.play().catch(endFailedProofBeat);
  };
  const resetProofVideo = (): void => {
    if (proofVideo === null) return;
    if (!proofVideo.paused) {
      automaticVideoPausePending = true;
      proofVideo.pause();
    }
    proofVideo.currentTime = 0;
    proofVideoIntent = "auto";
    state.proofVideoEnded = false;
  };

  // Show, then prove: the real capture holds the stage between loops, and it is
  // the static view whenever a registered scene cannot move (reduced motion or
  // a failed build). An unregistered module keeps the settled recreation.
  const proofBelongsToPhase = (phase: ScenePlaybackPhase): boolean =>
    phase === "awaiting-replay" ||
    (phase === "settled" &&
      sceneModule !== undefined &&
      (state.buildFailed || motionPreference.matches));

  const renderPhase = (
    phase: ScenePlaybackPhase,
    proofTransition: SceneProofTransition = "fade",
  ): void => {
    state.phase = phase;
    sceneRoot.dataset["scenePlaybackState"] = phase;
    proofLayer.render(proofBelongsToPhase(phase), proofTransition);
    publishStepTiming();
    if (phase === "awaiting-replay") {
      if (state.autoplayEnabled && state.latestProgress >= startProgress)
        playProofVideoAutomatically();
    } else {
      resetProofVideo();
    }
    if (toggle === null) {
      return;
    }
    toggle.hidden = !motionAllowed();
    toggle.dataset["playbackState"] = phase;
    const label = phase === "playing" ? toggle.dataset["pauseLabel"] : toggle.dataset["playLabel"];
    if (label !== undefined) {
      toggle.setAttribute("aria-label", label);
    }
  };

  const reportStep = (stepId: string | undefined): void => {
    if (stepId === undefined || stepId === state.lastReportedStepId) {
      return;
    }
    state.lastReportedStepId = stepId;
    sceneRoot.dispatchEvent(createChapterStepEvent(sceneStepReachedEventName, stepId));
    publishStepTiming();
  };

  const clearReplayTimer = (): void => {
    if (state.replayTimer === undefined) {
      return;
    }
    window.clearTimeout(state.replayTimer);
    state.replayTimer = undefined;
    replayTimerStartedAt = undefined;
  };

  const settle = (): void => {
    const priorStepId = state.lastReportedStepId;
    clearReplayTimer();
    state.timeline?.revert();
    state.timeline = undefined;
    state.awaitingReplay = false;
    state.intent = "auto";
    state.lastReportedStepId = undefined;
    state.suspendedWhileHidden = false;
    renderPhase("settled");
    if (priorStepId !== undefined) {
      sceneRoot.dispatchEvent(
        createSceneStepTimingEvent({
          stepId: priorStepId,
          dwellSeconds: 0,
          elapsedSeconds: 0,
          running: false,
          manualPause: false,
        }),
      );
    }
  };

  const handleTimelineComplete = (): void => {
    state.awaitingReplay = true;
    state.intent = "auto";
    renderPhase("awaiting-replay");
    replayIfEligible();
  };

  const ensureTimeline = (): SceneTimeline | undefined => {
    if (state.timeline !== undefined || sceneModule === undefined || !motionAllowed()) {
      return state.timeline;
    }
    const timeline = gsap.timeline({ paused: true });
    try {
      sceneModule.buildScene(sceneRoot, timeline, {
        height: sceneRoot.clientHeight,
        seed: sceneSeed,
        width: sceneRoot.clientWidth,
      });
    } catch (error: unknown) {
      // Markup that does not match its module (a missing scene part) is treated
      // like an unregistered module: drop the partial timeline, keep the settled
      // markup, and never retry this build.
      timeline.revert();
      timeline.kill();
      state.buildFailed = true;
      console.warn(
        `Scene "${sceneModule.sceneId}" could not build; showing its settled frame.`,
        error,
      );
      renderPhase("settled");
      return undefined;
    }
    timeline.eventCallback("onUpdate", (): void => {
      const previousStepId = state.lastReportedStepId;
      reportStep(findStepAtTime(sceneModule, timeline));
      if (previousStepId === state.lastReportedStepId && timeline.paused()) publishStepTiming();
    });
    timeline.eventCallback("onComplete", handleTimelineComplete);
    state.timeline = timeline;
    return timeline;
  };

  // Resting and awaiting-replay both show the final frame, so play restarts.
  const startTimeline = (timeline: SceneTimeline): void => {
    if (timeline.progress() >= 1) {
      timeline.restart();
    } else {
      timeline.play();
    }
    renderPhase("playing");
    if (sceneModule !== undefined) {
      reportStep(findStepAtTime(sceneModule, timeline));
    }
    sceneRoot.dispatchEvent(
      new CustomEvent<ScenePlaybackControl>(scenePlaybackReadyEventName, {
        bubbles: true,
        detail: {
          duration: timeline.duration(),
          pause: (): void => {
            timeline.pause();
          },
          seek: (seconds: number): void => {
            timeline.pause().time(seconds);
          },
          finish: (): void => {
            timeline.progress(1);
          },
        },
      }),
    );
  };

  const playAutomatically = (): void => {
    if (state.phase === "playing" || state.intent !== "auto") {
      return;
    }
    const timeline = ensureTimeline();
    if (timeline !== undefined) {
      state.awaitingReplay = false;
      startTimeline(timeline);
    }
  };

  const pauseAutomatically = (): void => {
    if (state.phase !== "playing" || state.intent === "manual-play") {
      return;
    }
    state.timeline?.pause();
    renderPhase("paused");
  };

  const replayIfEligible = (): void => {
    if (
      state.replayTimer !== undefined ||
      !state.awaitingReplay ||
      (proofVideo !== null && !state.proofVideoEnded) ||
      !state.autoplayEnabled ||
      state.intent !== "auto" ||
      state.latestProgress < startProgress
    ) {
      return;
    }
    replayTimerStartedAt = performance.now();
    state.replayTimer = window.setTimeout((): void => {
      state.replayTimer = undefined;
      replayTimerStartedAt = undefined;
      if (
        !state.autoplayEnabled ||
        state.intent !== "auto" ||
        state.latestProgress < startProgress
      ) {
        return;
      }
      playAutomatically();
    }, sceneReplayDelayMs);
    publishStepTiming();
  };

  const playManually = (timeline: SceneTimeline): void => {
    clearReplayTimer();
    state.suspendedWhileHidden = false;
    state.awaitingReplay = false;
    state.intent = "manual-play";
    props.onManualPlay?.();
    startTimeline(timeline);
  };

  proofVideo?.addEventListener(
    "play",
    (): void => {
      publishStepTiming();
      if (automaticVideoPlayPending) {
        automaticVideoPlayPending = false;
        return;
      }
      proofVideoIntent = "manual-play";
    },
    { signal: lifecycle.signal },
  );
  proofVideo?.addEventListener(
    "pause",
    (): void => {
      publishStepTiming();
      if (automaticVideoPausePending) {
        automaticVideoPausePending = false;
        return;
      }
      if (!proofVideo.ended) proofVideoIntent = "manual-pause";
    },
    { signal: lifecycle.signal },
  );
  proofVideo?.addEventListener("loadedmetadata", publishStepTiming, { signal: lifecycle.signal });
  proofVideo?.addEventListener(
    "canplay",
    (): void => {
      if (
        state.awaitingReplay &&
        state.autoplayEnabled &&
        state.latestProgress >= startProgress &&
        motionAllowed()
      )
        playProofVideoAutomatically();
    },
    { signal: lifecycle.signal },
  );
  proofVideo?.addEventListener("error", endFailedProofBeat, { signal: lifecycle.signal });
  proofVideo?.addEventListener(
    "ended",
    (): void => {
      state.proofVideoEnded = true;
      proofVideoIntent = "auto";
      proofVideo.currentTime = 0;
      replayIfEligible();
    },
    { signal: lifecycle.signal },
  );

  // Manual intent wins over scroll position, but never over a hidden document:
  // pause without changing intent, and resume on return while still centered.
  const synchronizeManualPlayVisibility = (progress: number): void => {
    if (document.visibilityState === "hidden") {
      if (state.phase === "playing") {
        state.timeline?.pause();
        state.suspendedWhileHidden = true;
        renderPhase("paused");
      }
      return;
    }
    if (!state.suspendedWhileHidden) {
      return;
    }
    if (progress >= startProgress && state.timeline !== undefined) {
      state.suspendedWhileHidden = false;
      state.timeline.play();
      renderPhase("playing");
    } else if (progress < stopProgress) {
      // Returned with the stage out of view: fall back to scroll-owned autoplay.
      state.suspendedWhileHidden = false;
      state.intent = "auto";
    }
  };

  const handleToggle = (): void => {
    if (state.phase === "playing") {
      clearReplayTimer();
      state.awaitingReplay = false;
      state.intent = "manual-pause";
      state.timeline?.pause();
      renderPhase("paused");
      return;
    }
    const timeline = ensureTimeline();
    if (timeline !== undefined) {
      playManually(timeline);
    }
  };

  const handleStepRequest = (event: Event): void => {
    const stepId = readChapterStepEventStepId(event);
    const step = sceneModule?.steps.find((candidate) => candidate.stepId === stepId);
    const timeline = step === undefined ? undefined : ensureTimeline();
    if (step === undefined || timeline === undefined) {
      return;
    }
    activeStepPreview?.remove();
    activeStepPreview = undefined;
    if (!motionPreference.matches && sceneRoot.getAttribute("aria-hidden") !== "true") {
      const preview = sceneRoot.cloneNode(true);
      const parent = sceneRoot.parentElement;
      if (preview instanceof HTMLElement && parent !== null) {
        const sceneBounds = sceneRoot.getBoundingClientRect();
        const parentBounds = parent.getBoundingClientRect();
        preview.removeAttribute(sceneRootAttribute);
        preview.dataset["sceneStepPreview"] = "";
        preview.setAttribute("aria-hidden", "true");
        preview.inert = true;
        Object.assign(preview.style, {
          position: "absolute",
          left: `${sceneBounds.left - parentBounds.left}px`,
          top: `${sceneBounds.top - parentBounds.top}px`,
          width: `${sceneBounds.width}px`,
          height: `${sceneBounds.height}px`,
          pointerEvents: "none",
          zIndex: "3",
        });
        parent.append(preview);
        activeStepPreview = preview;
        const fade = preview.animate([{ opacity: 1 }, { opacity: 0 }], {
          delay: 160,
          duration: 90,
          fill: "forwards",
        });
        void fade.finished
          .then((): void => {
            preview.remove();
            if (activeStepPreview === preview) activeStepPreview = undefined;
          })
          .catch((): void => {
            preview.remove();
            if (activeStepPreview === preview) activeStepPreview = undefined;
          });
      }
    }
    // A step chosen during the proof beat drops the proof at once, then seeks.
    proofLayer.render(false, "instant");
    clearReplayTimer();
    state.awaitingReplay = false;
    state.suspendedWhileHidden = false;
    state.intent = "auto";
    timeline.play(step.timelineLabel);
    renderPhase("playing", "instant");
    reportStep(step.stepId);
  };

  toggle?.addEventListener("click", handleToggle, { signal: lifecycle.signal });
  surface.addEventListener(chapterStepRequestedEventName, handleStepRequest, {
    signal: lifecycle.signal,
  });
  renderPhase("settled", "instant");

  return {
    restart: (): void => {
      clearReplayTimer();
      state.timeline?.pause(0);
      state.awaitingReplay = false;
      state.intent = "auto";
      state.lastReportedStepId = undefined;
      state.suspendedWhileHidden = false;
      renderPhase("paused", "instant");
    },
    deactivate: (): void => {
      clearReplayTimer();
      state.intent = "auto";
      if (state.phase === "playing" || state.phase === "awaiting-replay") {
        state.timeline?.pause();
        renderPhase("paused");
      }
    },
    dispose: (): void => {
      deferredVideo.dispose();
      lifecycle.abort();
      activeStepPreview?.remove();
      settle();
    },
    synchronize: (progress: number, autoplayEnabled: boolean): void => {
      state.latestProgress = progress;
      state.autoplayEnabled = autoplayEnabled;
      if (state.phase === "awaiting-replay") {
        if (!autoplayEnabled || progress < stopProgress) pauseProofVideoAutomatically();
        else if (progress >= startProgress) playProofVideoAutomatically();
      }
      // Follows a reduced-motion change that happens before any timeline exists.
      proofLayer.render(proofBelongsToPhase(state.phase), "instant");

      if (!motionAllowed()) {
        if (state.timeline !== undefined) {
          settle();
        }
        return;
      }
      if (progress < startProgress) {
        clearReplayTimer();
      }
      if (state.intent === "manual-play") {
        synchronizeManualPlayVisibility(progress);
        return;
      }
      if (!autoplayEnabled) {
        pauseAutomatically();
        return;
      }
      if (progress < stopProgress) {
        if (state.intent === "manual-pause") {
          state.intent = "auto";
        }
        pauseAutomatically();
        return;
      }
      if (progress < startProgress || state.intent === "manual-pause") {
        return;
      }
      if (state.awaitingReplay) {
        replayIfEligible();
        return;
      }
      playAutomatically();
    },
  };
}

/** One scene playback per `data-scene-root` inside the surface. */
export function createSurfaceScenePlayback(
  surface: HTMLElement,
  onManualPlay?: () => void,
): SurfacePlayback {
  return combineSurfacePlaybacks(
    Array.from(
      surface.querySelectorAll<HTMLElement>(`[${sceneRootAttribute}]`),
      (sceneRoot): SurfacePlayback => createScenePlayback({ sceneRoot, surface, onManualPlay }),
    ),
  );
}
