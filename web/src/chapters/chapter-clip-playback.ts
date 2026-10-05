import { createDeferredProofVideo } from "../home-page/deferred-proof-video";
import type { SurfacePlayback } from "../home-page/surface-playback";
import { isChapterStepId } from "./chapter-ids";
import {
  chapterStepRequestedEventName,
  createChapterStepEvent,
  createSceneStepTimingEvent,
  readChapterStepEventStepId,
  sceneStepReachedEventName,
} from "./chapter-step-events";

const absentClipPlayback: SurfacePlayback = {
  synchronize: (): void => undefined,
  dispose: (): void => undefined,
};

type ClipPlaybackIntent = "auto" | "manual-play" | "manual-pause";

/** The video's media clock drives the existing chapter tabs and countdown. */
export function createChapterClipPlayback(
  surface: HTMLElement,
  claimManualPlay?: () => void,
): SurfacePlayback {
  const stage = surface.querySelector<HTMLElement>("[data-chapter-clips]");
  if (stage === null) return absentClipPlayback;
  const videos = Array.from(stage.querySelectorAll<HTMLVideoElement>("[data-chapter-clip-step]"));
  const stepIds = videos.map((video) => video.dataset["chapterClipStep"] ?? "");
  const root = surface.closest("[data-chapter-steps-root]");
  const tabStepIds = Array.from(
    root?.querySelectorAll<HTMLElement>("[data-chapter-step]") ?? [],
    (tab) => tab.dataset["chapterStep"],
  );
  if (
    videos.length !== 3 ||
    stepIds.some((stepId, index) => !isChapterStepId(stepId) || stepId !== tabStepIds[index])
  )
    return absentClipPlayback;

  const lifecycle = new AbortController();
  const deferredVideos = videos.map((video) => createDeferredProofVideo(video, false));
  const automaticPlays = new Set<HTMLVideoElement>();
  const automaticPauses = new Set<HTMLVideoElement>();
  const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
  let selectedIndex = 0;
  let progress = 0;
  let autoplayEnabled = false;
  let playbackIntent: ClipPlaybackIntent = "auto";
  let completed = false;
  let nearViewport = false;

  const publishTiming = (): void => {
    const video = videos[selectedIndex];
    const stepId = stepIds[selectedIndex];
    if (video === undefined || stepId === undefined) return;
    stage.dataset["clipPlaybackState"] = completed ? "ended" : video.paused ? "paused" : "playing";
    if (!Number.isFinite(video.duration) || video.duration <= 0) return;
    stage.dispatchEvent(
      createSceneStepTimingEvent({
        stepId,
        dwellSeconds: video.duration,
        elapsedSeconds: video.currentTime,
        running: !video.paused && !completed,
        manualPause: playbackIntent === "manual-pause",
      }),
    );
  };
  const pauseVideo = (video: HTMLVideoElement): void => {
    if (video.paused) return;
    automaticPauses.add(video);
    video.pause();
  };
  const primeActiveVideo = (): void => deferredVideos[selectedIndex]?.prime();
  const playActiveVideo = (): void => {
    const video = videos[selectedIndex];
    if (
      video === undefined ||
      completed ||
      playbackIntent === "manual-pause" ||
      reducedMotion.matches ||
      !autoplayEnabled ||
      progress < 0.95
    )
      return;
    primeActiveVideo();
    if (
      video.error !== null ||
      !video.paused ||
      video.readyState < HTMLMediaElement.HAVE_FUTURE_DATA
    )
      return;
    automaticPlays.add(video);
    void video.play().catch((): void => {
      automaticPlays.delete(video);
      publishTiming();
    });
  };
  const selectClip = (stepIndex: number): void => {
    const video = videos[stepIndex];
    const stepId = stepIds[stepIndex];
    if (video === undefined || stepId === undefined) return;
    for (const candidate of videos) pauseVideo(candidate);
    selectedIndex = stepIndex;
    completed = false;
    playbackIntent = "auto";
    video.currentTime = 0;
    videos.forEach((candidate, index): void => {
      candidate.hidden = index !== selectedIndex;
      if (candidate.hidden) candidate.setAttribute("aria-hidden", "true");
      else candidate.removeAttribute("aria-hidden");
    });
    stage.dataset["activeClipStep"] = stepId;
    stage.dispatchEvent(createChapterStepEvent(sceneStepReachedEventName, stepId));
    if (nearViewport || progress >= 0.95) primeActiveVideo();
    publishTiming();
    playActiveVideo();
  };

  videos.forEach((video, index): void => {
    for (const eventName of ["loadedmetadata", "timeupdate", "seeking", "seeked"] as const) {
      video.addEventListener(
        eventName,
        (): void => {
          if (index === selectedIndex) publishTiming();
        },
        { signal: lifecycle.signal },
      );
    }
    video.addEventListener(
      "canplay",
      (): void => {
        if (index === selectedIndex) playActiveVideo();
      },
      { signal: lifecycle.signal },
    );
    video.addEventListener(
      "play",
      (): void => {
        if (index !== selectedIndex) {
          pauseVideo(video);
          return;
        }
        completed = false;
        if (!automaticPlays.delete(video)) {
          playbackIntent = "manual-play";
          claimManualPlay?.();
        }
        publishTiming();
      },
      { signal: lifecycle.signal },
    );
    video.addEventListener(
      "pause",
      (): void => {
        if (automaticPauses.delete(video) || index !== selectedIndex || video.ended) return;
        playbackIntent = "manual-pause";
        publishTiming();
      },
      { signal: lifecycle.signal },
    );
    video.addEventListener(
      "ended",
      (): void => {
        if (index !== selectedIndex) return;
        if (index < videos.length - 1) selectClip(index + 1);
        else {
          completed = true;
          publishTiming();
        }
      },
      { signal: lifecycle.signal },
    );
    video.addEventListener(
      "error",
      (): void => {
        if (index !== selectedIndex) return;
        playbackIntent = "manual-pause";
        pauseVideo(video);
        publishTiming();
      },
      { signal: lifecycle.signal },
    );
  });
  surface.addEventListener(
    chapterStepRequestedEventName,
    (event): void => {
      const stepId = readChapterStepEventStepId(event);
      const stepIndex = stepIds.findIndex((candidate) => candidate === stepId);
      if (stepIndex < 0) return;
      claimManualPlay?.();
      progress = 1;
      autoplayEnabled = !reducedMotion.matches;
      selectClip(stepIndex);
      primeActiveVideo();
    },
    { signal: lifecycle.signal },
  );
  const observer = new IntersectionObserver(
    (entries): void => {
      nearViewport = entries.some((entry) => entry.isIntersecting);
      if (nearViewport) primeActiveVideo();
    },
    { rootMargin: `${window.innerHeight}px 0px` },
  );
  observer.observe(stage);
  selectClip(0);

  return {
    synchronize: (nextProgress: number, nextAutoplayEnabled: boolean): void => {
      progress = nextProgress;
      autoplayEnabled = nextAutoplayEnabled;
      if (playbackIntent === "manual-play") {
        publishTiming();
        return;
      }
      if (!autoplayEnabled || progress < 0.9) {
        const video = videos[selectedIndex];
        if (video !== undefined) pauseVideo(video);
        publishTiming();
      } else playActiveVideo();
    },
    restart: (): void => selectClip(0),
    deactivate: (): void => {
      autoplayEnabled = false;
      for (const video of videos) pauseVideo(video);
      publishTiming();
    },
    dispose: (): void => {
      lifecycle.abort();
      observer.disconnect();
      for (const deferredVideo of deferredVideos) deferredVideo.dispose();
      for (const video of videos) pauseVideo(video);
    },
  };
}
