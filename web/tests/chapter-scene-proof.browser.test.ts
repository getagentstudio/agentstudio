import { gsap } from "gsap";
import { afterEach, expect, inject, it, vi } from "vitest";

import {
  createScenePlayback,
  scenePlaybackReadyEventName,
  type ScenePlaybackControl,
} from "../src/home-page/scene-playback";
import type { SceneId, SceneModule, SceneTimeline } from "../src/motion-scenes/scene-contract";
import { resolveSceneModule } from "../src/motion-scenes/scene-registry";

const mountedStages: HTMLElement[] = [];

afterEach(() => {
  for (const stage of mountedStages.splice(0)) stage.remove();
  vi.useRealTimers();
  vi.restoreAllMocks();
  gsap.globalTimeline.clear();
});

async function mountRealChapterStage(sceneId: SceneId): Promise<{
  readonly sceneRoot: HTMLElement;
  readonly stage: HTMLElement;
  readonly proof: HTMLElement;
}> {
  const pageUrl = new URL(inject("siteHeaderBrowserTestUrl"));
  pageUrl.hostname = location.hostname;
  const response = await fetch(pageUrl);
  if (!response.ok) throw new Error(`Home page answered ${String(response.status)}`);
  const page = new DOMParser().parseFromString(await response.text(), "text/html");
  const originalRoot = page.querySelector<HTMLElement>(`[data-scene-root="${sceneId}"]`);
  const originalStage = originalRoot?.closest<HTMLElement>(".chapter-scene-stage");
  if (originalStage === null || originalStage === undefined)
    throw new Error(`${sceneId} stage missing`);
  const stage = document.importNode(originalStage, true);
  stage.style.width = "1100px";
  stage.style.height = "688px";
  document.body.append(stage);
  mountedStages.push(stage);
  const sceneRoot = stage.querySelector<HTMLElement>(`[data-scene-root="${sceneId}"]`);
  const proof = stage.querySelector<HTMLElement>(`[data-scene-proof="${sceneId}"]`);
  if (sceneRoot === null || proof === null) throw new Error(`${sceneId} scene or proof missing`);
  sceneRoot.style.width = "1100px";
  sceneRoot.style.height = "688px";
  return { sceneRoot, stage, proof };
}

for (const sceneId of ["chapter-review", "chapter-come-back"] as const) {
  it(`${sceneId} plays its rendered scene, then holds its real proof between loops`, async () => {
    const { sceneRoot, stage, proof } = await mountRealChapterStage(sceneId);
    const module = resolveSceneModule(sceneId);
    if (module === undefined) throw new Error(`${sceneId} module missing`);
    let hostTimeline: SceneTimeline | undefined;
    const measuredModule: SceneModule = {
      ...module,
      buildScene: (root, timeline, options): void => {
        module.buildScene(root, timeline, options);
        hostTimeline = timeline;
      },
    };
    const proofVideo = proof.querySelector("video");
    let videoPlayCalls = 0;
    if (proofVideo !== null) {
      Object.defineProperty(proofVideo, "readyState", { configurable: true, value: 3 });
      let paused = true;
      Object.defineProperty(proofVideo, "paused", {
        configurable: true,
        get: (): boolean => paused,
      });
      vi.spyOn(proofVideo, "play").mockImplementation((): Promise<void> => {
        videoPlayCalls += 1;
        paused = false;
        proofVideo.dispatchEvent(new Event("play"));
        return Promise.resolve();
      });
      vi.spyOn(proofVideo, "pause").mockImplementation((): void => {
        paused = true;
        proofVideo.dispatchEvent(new Event("pause"));
      });
    }
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
    let readyControl: ScenePlaybackControl | undefined;
    stage.addEventListener(scenePlaybackReadyEventName, (event) => {
      if (event instanceof CustomEvent) readyControl = event.detail as ScenePlaybackControl;
    });
    const playback = createScenePlayback({
      resolveModule: (): SceneModule => measuredModule,
      sceneRoot,
      surface: stage,
    });
    try {
      playback.synchronize(1, true);
      expect(readyControl?.duration).toBe(8);
      expect(sceneRoot.dataset["scenePlaybackState"]).toBe("playing");
      expect(proof.dataset["sceneProofState"]).toBe("hidden");
      if (hostTimeline === undefined) throw new Error(`${sceneId} host timeline missing`);
      hostTimeline.progress(1);
      expect(sceneRoot.dataset["scenePlaybackState"]).toBe("awaiting-replay");
      expect(proof.dataset["sceneProofState"]).toBe("shown");
      expect(proof.getAttribute("aria-hidden")).toBeNull();
      if (sceneId === "chapter-review") {
        expect(proof.querySelector("picture img")).not.toBeNull();
        vi.advanceTimersByTime(2999);
        expect(proof.dataset["sceneProofState"]).toBe("shown");
      } else {
        expect(proofVideo?.hasAttribute("controls")).toBe(true);
        expect(proofVideo?.hasAttribute("data-scene-proof-video")).toBe(true);
        expect(videoPlayCalls).toBe(1);
        vi.advanceTimersByTime(3000);
        expect(proof.dataset["sceneProofState"]).toBe("shown");
        proofVideo?.dispatchEvent(new Event("ended"));
        vi.advanceTimersByTime(2999);
        expect(proof.dataset["sceneProofState"]).toBe("shown");
      }
      vi.advanceTimersByTime(1);
      expect(sceneRoot.dataset["scenePlaybackState"]).toBe("playing");
      expect(proof.dataset["sceneProofState"]).toBe("hidden");
    } finally {
      playback.dispose();
    }
  });
}
