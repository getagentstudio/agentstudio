import { afterEach, describe, expect, it, vi } from "vitest";

import {
  readChapterStepEventStepId,
  sceneStepReachedEventName,
} from "../src/chapters/chapter-step-events";
import { createScenePlayback } from "../src/home-page/scene-playback";
import { initializeScrollMaterialSurfaces } from "../src/home-page/scroll-material-surface-controller";
import type { SceneModule, SceneTimeline } from "../src/motion-scenes/scene-contract";
import { resolveSceneModule } from "../src/motion-scenes/scene-registry";

const fixtures: HTMLElement[] = [];

function addFixture(markup: string): HTMLElement {
  const fixture = document.createElement("div");
  fixture.innerHTML = markup;
  document.body.append(fixture);
  fixtures.push(fixture);
  return fixture;
}

function requiredHtmlElement(parent: ParentNode, selector: string): HTMLElement {
  const element = parent.querySelector(selector);
  if (!(element instanceof HTMLElement)) {
    throw new Error(`Scene playback fixture is missing required element: ${selector}`);
  }
  return element;
}

function stubReducedMotion(reduced: boolean): void {
  vi.spyOn(window, "matchMedia").mockImplementation(
    (query): MediaQueryList =>
      ({
        addEventListener: vi.fn(),
        addListener: vi.fn(),
        dispatchEvent: vi.fn(() => true),
        matches: reduced && query === "(prefers-reduced-motion: reduce)",
        media: query,
        onchange: null,
        removeEventListener: vi.fn(),
        removeListener: vi.fn(),
      }) satisfies MediaQueryList,
  );
}

interface FakeSceneFixture {
  readonly buildScene: ReturnType<typeof vi.fn>;
  readonly module: SceneModule;
  readonly playbackState: () => string | undefined;
  readonly sceneRoot: HTMLElement;
  readonly surface: HTMLElement;
  readonly timeline: () => SceneTimeline;
  readonly toggle: HTMLButtonElement;
}

// The real-capture layer a scene stage renders beside its recreation, hidden until proof.
const proofLayerMarkup = `
  <div data-scene-proof="chapter-many-agents" data-scene-proof-state="hidden" aria-hidden="true">
    <img alt="Agent Studio with two agents" src="data:," />
    <span>Real capture</span>
  </div>
`;

interface ProofObservation {
  readonly labelText: string;
  readonly proofAriaHidden: string | null;
  readonly recreationAriaHidden: string | null;
  readonly state: string | undefined;
  readonly transition: string | undefined;
}

function observeProof(surface: HTMLElement): ProofObservation {
  const proof = requiredHtmlElement(surface, "[data-scene-proof]");
  const sceneRoot = requiredHtmlElement(surface, "[data-scene-root]");
  return {
    labelText: proof.textContent.trim(),
    proofAriaHidden: proof.getAttribute("aria-hidden"),
    recreationAriaHidden: sceneRoot.getAttribute("aria-hidden"),
    state: proof.dataset["sceneProofState"],
    transition: proof.dataset["sceneProofTransition"],
  };
}

// A test-local scene: two labelled beats, each fading one settled element in.
function createFakeSceneFixture(): FakeSceneFixture {
  const fixture = addFixture(`
    <section data-surface>
      <div data-scene-root="chapter-many-agents">
        <p data-beat="first">First beat</p>
        <p data-beat="second">Second beat</p>
      </div>
      ${proofLayerMarkup}
      <button
        type="button"
        data-scene-playback-toggle
        data-play-label="Play animation"
        data-pause-label="Pause animation"
        hidden
      >Pause animation</button>
    </section>
  `);
  const surface = requiredHtmlElement(fixture, "[data-surface]");
  const sceneRoot = requiredHtmlElement(surface, "[data-scene-root]");
  const toggle = surface.querySelector("[data-scene-playback-toggle]");
  if (!(toggle instanceof HTMLButtonElement)) {
    throw new Error("Scene playback fixture is missing its toggle");
  }
  let builtTimeline: SceneTimeline | undefined;
  const buildScene = vi.fn((root: HTMLElement, timeline: SceneTimeline): void => {
    builtTimeline = timeline;
    timeline
      .addLabel("beat-parallel", 0)
      .fromTo(
        root.querySelector('[data-beat="first"]'),
        { opacity: 0 },
        { opacity: 1, duration: 1 },
      )
      .addLabel("beat-watch")
      .fromTo(
        root.querySelector('[data-beat="second"]'),
        { opacity: 0 },
        { opacity: 1, duration: 1 },
      );
  });
  const module: SceneModule = {
    sceneId: "chapter-many-agents",
    steps: [
      { stepId: "parallel-agents", timelineLabel: "beat-parallel" },
      { stepId: "watch-folders", timelineLabel: "beat-watch" },
    ],
    buildScene,
  };
  return {
    buildScene,
    module,
    playbackState: (): string | undefined => sceneRoot.dataset["scenePlaybackState"],
    sceneRoot,
    surface,
    timeline: (): SceneTimeline => {
      if (builtTimeline === undefined) {
        throw new Error("The fake scene has not been built");
      }
      return builtTimeline;
    },
    toggle,
  };
}

afterEach(() => {
  for (const fixture of fixtures.splice(0)) {
    fixture.remove();
  }
  vi.useRealTimers();
  vi.restoreAllMocks();
});

describe("scene playback", () => {
  it("publishes step timing on step changes, not on every playing frame", () => {
    stubReducedMotion(false);
    const scene = createFakeSceneFixture();
    const reachedSteps: string[] = [];
    const timedSteps: string[] = [];
    scene.sceneRoot.addEventListener(sceneStepReachedEventName, (event: Event): void => {
      reachedSteps.push(readChapterStepEventStepId(event) ?? "unreadable");
    });
    scene.sceneRoot.addEventListener("agentstudio:scene-step-timing", (event: Event): void => {
      if (event instanceof CustomEvent) timedSteps.push(event.detail.stepId);
    });
    const playback = createScenePlayback({
      resolveModule: () => scene.module,
      sceneRoot: scene.sceneRoot,
      surface: scene.surface,
    });

    playback.synchronize(1, true);
    reachedSteps.length = 0;
    timedSteps.length = 0;
    scene.timeline().time(0.1);
    scene.timeline().time(0.2);
    scene.timeline().time(0.3);
    expect(reachedSteps).toEqual([]);
    expect(timedSteps).toEqual([]);

    scene.timeline().time((scene.timeline().labels["beat-watch"] ?? 0) + 0.1);
    expect(reachedSteps).toEqual(["watch-folders"]);
    expect(timedSteps).toEqual(["watch-folders"]);
    playback.dispose();
  });

  it("plays when centered and pauses with the video hysteresis when leaving", () => {
    stubReducedMotion(false);
    const scene = createFakeSceneFixture();
    const timing: Array<{ manualPause?: boolean; running: boolean }> = [];
    scene.surface.addEventListener("agentstudio:scene-step-timing", (event: Event): void => {
      if (event instanceof CustomEvent) timing.push(event.detail);
    });
    const playback = createScenePlayback({
      resolveModule: () => scene.module,
      sceneRoot: scene.sceneRoot,
      surface: scene.surface,
    });

    playback.synchronize(0.94, true);
    expect(scene.buildScene).not.toHaveBeenCalled();
    expect(scene.playbackState()).toBe("settled");

    playback.synchronize(0.95, true);
    expect(scene.buildScene).toHaveBeenCalledTimes(1);
    expect(scene.playbackState()).toBe("playing");
    expect(scene.timeline().paused()).toBe(false);
    expect(scene.toggle.hidden).toBe(false);

    playback.synchronize(0.92, true);
    expect(scene.playbackState()).toBe("playing");

    playback.synchronize(0.89, true);
    expect(scene.playbackState()).toBe("paused");
    expect(scene.timeline().paused()).toBe(true);
    expect(timing.at(-1)).toMatchObject({ running: false, manualPause: false });

    playback.synchronize(0.95, true);
    expect(scene.playbackState()).toBe("playing");
    expect(scene.buildScene).toHaveBeenCalledTimes(1);

    playback.dispose();
  });

  it("replays from the start after the delay while still centered", () => {
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
    stubReducedMotion(false);
    const scene = createFakeSceneFixture();
    const playback = createScenePlayback({
      resolveModule: () => scene.module,
      sceneRoot: scene.sceneRoot,
      surface: scene.surface,
    });

    playback.synchronize(1, true);
    scene.timeline().progress(1);
    expect(scene.playbackState()).toBe("awaiting-replay");

    vi.advanceTimersByTime(2999);
    expect(scene.playbackState()).toBe("awaiting-replay");

    vi.advanceTimersByTime(1);
    expect(scene.playbackState()).toBe("playing");
    expect(scene.timeline().progress()).toBe(0);

    playback.dispose();
  });

  it("does not replay after the delay once the visitor has left", () => {
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
    stubReducedMotion(false);
    const scene = createFakeSceneFixture();
    const playback = createScenePlayback({
      resolveModule: () => scene.module,
      sceneRoot: scene.sceneRoot,
      surface: scene.surface,
    });

    playback.synchronize(1, true);
    scene.timeline().progress(1);
    playback.synchronize(0.5, true);
    vi.advanceTimersByTime(3000);

    expect(scene.playbackState()).toBe("awaiting-replay");
    playback.dispose();
  });

  it("keeps a manual pause until the visitor leaves the autoplay zone", () => {
    stubReducedMotion(false);
    const scene = createFakeSceneFixture();
    const playback = createScenePlayback({
      resolveModule: () => scene.module,
      sceneRoot: scene.sceneRoot,
      surface: scene.surface,
    });

    playback.synchronize(1, true);
    scene.toggle.click();
    expect(scene.playbackState()).toBe("paused");
    expect(scene.toggle.getAttribute("aria-label")).toBe("Play animation");

    playback.synchronize(1, true);
    expect(scene.playbackState()).toBe("paused");

    playback.synchronize(0.89, true);
    playback.synchronize(0.95, true);
    expect(scene.playbackState()).toBe("playing");
    expect(scene.toggle.getAttribute("aria-label")).toBe("Pause animation");

    playback.synchronize(0.89, true);
    scene.toggle.click();
    playback.synchronize(0.2, true);
    expect(scene.playbackState()).toBe("playing");

    playback.dispose();
  });

  it("pauses a manually played scene while the document is hidden and resumes on return", () => {
    stubReducedMotion(false);
    const scene = createFakeSceneFixture();
    const playback = createScenePlayback({
      resolveModule: () => scene.module,
      sceneRoot: scene.sceneRoot,
      surface: scene.surface,
    });
    const setVisibility = (visibilityState: DocumentVisibilityState): void => {
      Object.defineProperty(document, "visibilityState", {
        configurable: true,
        value: visibilityState,
      });
    };

    try {
      setVisibility("visible");
      playback.synchronize(1, true);
      scene.toggle.click();
      scene.toggle.click();
      expect(scene.playbackState()).toBe("playing");

      // The glass controller reports a hidden document as (1, false).
      setVisibility("hidden");
      playback.synchronize(1, false);
      expect(scene.timeline().paused()).toBe(true);
      expect(scene.playbackState()).toBe("paused");

      setVisibility("visible");
      playback.synchronize(1, true);
      expect(scene.timeline().paused()).toBe(false);
      expect(scene.playbackState()).toBe("playing");

      // Manual intent survived the hidden interval: leaving the zone keeps playing.
      playback.synchronize(0.2, true);
      expect(scene.playbackState()).toBe("playing");
    } finally {
      playback.dispose();
      Reflect.deleteProperty(document, "visibilityState");
    }
  });

  it("seeks to a requested step and keeps playing", () => {
    stubReducedMotion(false);
    const scene = createFakeSceneFixture();
    const playback = createScenePlayback({
      resolveModule: () => scene.module,
      sceneRoot: scene.sceneRoot,
      surface: scene.surface,
    });
    const reachedSteps: string[] = [];
    const timing: Array<{ manualPause?: boolean }> = [];
    scene.surface.addEventListener("agentstudio:scene-step-timing", (event: Event): void => {
      if (event instanceof CustomEvent) timing.push(event.detail);
    });
    scene.surface.addEventListener(sceneStepReachedEventName, (event: Event): void => {
      reachedSteps.push(readChapterStepEventStepId(event) ?? "unreadable");
    });

    scene.surface.dispatchEvent(
      new CustomEvent("agentstudio:chapter-step-requested", {
        detail: { stepId: "watch-folders" },
      }),
    );

    expect(scene.playbackState()).toBe("playing");
    expect(timing.at(-1)?.manualPause).toBe(false);
    expect(scene.timeline().time()).toBe(scene.timeline().labels["beat-watch"]);
    expect(reachedSteps).toEqual(["watch-folders"]);
    playback.synchronize(1, true);
    expect(scene.timeline().paused()).toBe(false);
    expect(reachedSteps).toEqual(["watch-folders"]);

    playback.dispose();
  });

  it("publishes exact step timing and replays the current step from its label", () => {
    stubReducedMotion(false);
    const scene = createFakeSceneFixture();
    const playback = createScenePlayback({
      resolveModule: () => scene.module,
      sceneRoot: scene.sceneRoot,
      surface: scene.surface,
    });
    const timing: Array<{
      stepId: string;
      dwellSeconds: number;
      elapsedSeconds: number;
      running: boolean;
    }> = [];
    scene.surface.addEventListener("agentstudio:scene-step-timing", (event: Event): void => {
      if (event instanceof CustomEvent) timing.push(event.detail);
    });

    playback.synchronize(1, true);
    scene.timeline().pause().time(0.5);
    expect(timing.at(-1)).toMatchObject({
      stepId: "parallel-agents",
      dwellSeconds: 1,
      elapsedSeconds: 0.5,
      running: false,
    });

    scene.surface.dispatchEvent(
      new CustomEvent("agentstudio:chapter-step-requested", {
        detail: { stepId: "watch-folders" },
      }),
    );
    expect(timing.at(-1)).toMatchObject({ stepId: "watch-folders", running: true });
    scene.timeline().time(1.5);
    scene.surface.dispatchEvent(
      new CustomEvent("agentstudio:chapter-step-requested", {
        detail: { stepId: "watch-folders" },
      }),
    );
    expect(scene.playbackState()).toBe("playing");
    expect(timing.at(-1)).toMatchObject({
      stepId: "watch-folders",
      running: true,
      elapsedSeconds: 0,
    });
    expect(scene.timeline().time()).toBe(scene.timeline().labels["beat-watch"]);
    playback.dispose();
  });

  it("crossfades exactly one inert preview on a manual step jump", async () => {
    stubReducedMotion(false);
    const scene = createFakeSceneFixture();
    const playback = createScenePlayback({
      resolveModule: () => scene.module,
      sceneRoot: scene.sceneRoot,
      surface: scene.surface,
    });
    playback.synchronize(1, true);
    scene.surface.dispatchEvent(
      new CustomEvent("agentstudio:chapter-step-requested", {
        detail: { stepId: "watch-folders" },
      }),
    );
    const previews = scene.surface.querySelectorAll<HTMLElement>("[data-scene-step-preview]");
    expect(previews).toHaveLength(1);
    expect(previews[0]?.getAttribute("aria-hidden")).toBe("true");
    expect(previews[0]?.inert).toBe(true);
    const previewAnimation = previews[0]?.getAnimations()[0];
    expect(previewAnimation?.effect?.getTiming()).toMatchObject({ delay: 160, duration: 90 });
    previewAnimation?.finish();
    await previewAnimation?.finished;
    expect(scene.surface.querySelectorAll("[data-scene-step-preview]")).toHaveLength(0);
    playback.dispose();
  });

  it("leaves the settled markup untouched under reduced motion", () => {
    stubReducedMotion(true);
    const scene = createFakeSceneFixture();
    const playback = createScenePlayback({
      resolveModule: () => scene.module,
      sceneRoot: scene.sceneRoot,
      surface: scene.surface,
    });

    playback.synchronize(1, false);
    playback.synchronize(1, true);
    scene.surface.dispatchEvent(
      new CustomEvent("agentstudio:chapter-step-requested", {
        detail: { stepId: "watch-folders" },
      }),
    );

    expect(scene.buildScene).not.toHaveBeenCalled();
    expect(scene.playbackState()).toBe("settled");
    expect(scene.toggle.hidden).toBe(true);
    expect(requiredHtmlElement(scene.sceneRoot, '[data-beat="first"]').getAttribute("style")).toBe(
      null,
    );
    // Real pixels are the static view: the proof shows and the recreation steps back.
    expect(observeProof(scene.surface)).toMatchObject({
      proofAriaHidden: null,
      recreationAriaHidden: "true",
      state: "shown",
    });
    playback.dispose();
  });

  it("crossfades to the real capture when the scene completes and back on replay", () => {
    // Arrange
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
    stubReducedMotion(false);
    const scene = createFakeSceneFixture();
    const playback = createScenePlayback({
      resolveModule: () => scene.module,
      sceneRoot: scene.sceneRoot,
      surface: scene.surface,
    });
    const reachedSteps: string[] = [];
    scene.surface.addEventListener(sceneStepReachedEventName, (event: Event): void => {
      reachedSteps.push(readChapterStepEventStepId(event) ?? "unreadable");
    });
    playback.synchronize(1, true);
    const whilePlaying = observeProof(scene.surface);

    // Act: the timeline completes, then the replay hold elapses.
    scene.timeline().progress(1);
    const atProofBeat = observeProof(scene.surface);
    const lastStepAtProofBeat = reachedSteps.at(-1);
    vi.advanceTimersByTime(3000);
    const afterReplay = observeProof(scene.surface);

    // Assert
    expect(whilePlaying).toMatchObject({
      proofAriaHidden: "true",
      recreationAriaHidden: null,
      state: "hidden",
    });
    expect(atProofBeat).toEqual({
      labelText: "Real capture",
      proofAriaHidden: null,
      recreationAriaHidden: "true",
      state: "shown",
      transition: "fade",
    });
    expect(lastStepAtProofBeat).toBe("watch-folders");
    expect(afterReplay).toMatchObject({
      proofAriaHidden: "true",
      recreationAriaHidden: null,
      state: "hidden",
      transition: "fade",
    });
    expect(scene.playbackState()).toBe("playing");
    expect(scene.timeline().progress()).toBe(0);
    playback.dispose();
  });

  it("plays a proof video only after the scene and holds it through its end before replay", () => {
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
    stubReducedMotion(false);
    const scene = createFakeSceneFixture();
    const proof = requiredHtmlElement(scene.surface, "[data-scene-proof]");
    proof.innerHTML = "<video data-scene-proof-video controls muted playsinline></video>";
    const video = proof.querySelector("video");
    if (!(video instanceof HTMLVideoElement)) throw new Error("Proof video is missing");
    Object.defineProperty(video, "readyState", { configurable: true, value: 3 });
    let videoPaused = true;
    Object.defineProperty(video, "paused", { configurable: true, get: (): boolean => videoPaused });
    Object.defineProperty(video, "duration", { configurable: true, get: (): number => 5 });
    const play = vi.spyOn(video, "play").mockImplementation((): Promise<void> => {
      videoPaused = false;
      video.dispatchEvent(new Event("play"));
      return Promise.resolve();
    });
    const pause = vi.spyOn(video, "pause").mockImplementation((): void => {
      videoPaused = true;
      video.dispatchEvent(new Event("pause"));
    });
    const playback = createScenePlayback({
      resolveModule: () => scene.module,
      sceneRoot: scene.sceneRoot,
      surface: scene.surface,
    });
    const proofTiming: Array<{ stepId: string; dwellSeconds: number; elapsedSeconds: number }> = [];
    scene.surface.addEventListener("agentstudio:scene-step-timing", (event: Event): void => {
      if (event instanceof CustomEvent) proofTiming.push(event.detail);
    });

    playback.synchronize(1, true);
    expect(play).not.toHaveBeenCalled();
    scene.timeline().progress(1);
    expect(observeProof(scene.surface).state).toBe("shown");
    expect(play).toHaveBeenCalledTimes(1);
    vi.advanceTimersByTime(3000);
    expect(scene.playbackState()).toBe("awaiting-replay");
    video.dispatchEvent(new Event("ended"));
    expect(proofTiming.at(-1)).toMatchObject({ stepId: "watch-folders", dwellSeconds: 9 });
    expect(proofTiming.at(-1)?.elapsedSeconds).toBeCloseTo(6, 2);
    vi.advanceTimersByTime(3000);
    expect(scene.playbackState()).toBe("playing");
    expect(observeProof(scene.surface).state).toBe("hidden");
    expect(pause).toHaveBeenCalled();
    playback.dispose();
  });

  it("recovers a source error that arrives before the proof handoff", () => {
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
    stubReducedMotion(false);
    const scene = createFakeSceneFixture();
    requiredHtmlElement(scene.surface, "[data-scene-proof]").innerHTML =
      "<video data-scene-proof-video controls muted playsinline></video>";
    const video = scene.surface.querySelector("video");
    if (video === null) throw new Error("Proof video missing");
    Object.defineProperty(video, "readyState", { configurable: true, value: 0 });
    Object.defineProperty(video, "error", {
      configurable: true,
      value: { code: 4, message: "Source unavailable" },
    });
    const play = vi.spyOn(video, "play").mockRejectedValue(new Error("Source unavailable"));
    const playback = createScenePlayback({
      resolveModule: () => scene.module,
      sceneRoot: scene.sceneRoot,
      surface: scene.surface,
    });
    try {
      playback.synchronize(1, true);
      video.dispatchEvent(new Event("error"));
      scene.timeline().progress(1);
      vi.advanceTimersByTime(3000);
      expect(scene.playbackState()).toBe("playing");
      expect(observeProof(scene.surface).state).toBe("hidden");
      expect(play).not.toHaveBeenCalled();
    } finally {
      playback.dispose();
    }
  });

  it.each(["error", "rejected-play"])("replays after a proof video %s", async (failure) => {
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
    stubReducedMotion(false);
    const scene = createFakeSceneFixture();
    const proof = requiredHtmlElement(scene.surface, "[data-scene-proof]");
    proof.innerHTML = "<video data-scene-proof-video controls muted playsinline></video>";
    const video = proof.querySelector("video");
    if (!(video instanceof HTMLVideoElement)) throw new Error("Proof video is missing");
    Object.defineProperty(video, "readyState", { configurable: true, value: 3 });
    vi.spyOn(video, "play").mockImplementation(() =>
      failure === "rejected-play" ? Promise.reject(new Error("decode failed")) : Promise.resolve(),
    );
    const playback = createScenePlayback({
      resolveModule: () => scene.module,
      sceneRoot: scene.sceneRoot,
      surface: scene.surface,
    });
    playback.synchronize(1, true);
    scene.timeline().progress(1);
    if (failure === "error") video.dispatchEvent(new Event("error"));
    else await Promise.resolve();
    vi.advanceTimersByTime(3000);
    expect(scene.playbackState()).toBe("playing");
    expect(observeProof(scene.surface).state).toBe("hidden");
    playback.dispose();
  });

  it("keeps a visitor-paused proof video paused instead of treating it as a failure", () => {
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
    stubReducedMotion(false);
    const scene = createFakeSceneFixture();
    requiredHtmlElement(scene.surface, "[data-scene-proof]").innerHTML =
      "<video data-scene-proof-video controls muted playsinline></video>";
    const video = scene.surface.querySelector("video");
    if (!(video instanceof HTMLVideoElement)) throw new Error("Proof video is missing");
    Object.defineProperty(video, "readyState", { configurable: true, value: 3 });
    let paused = true;
    Object.defineProperty(video, "paused", { configurable: true, get: () => paused });
    vi.spyOn(video, "play").mockImplementation(() => {
      paused = false;
      video.dispatchEvent(new Event("play"));
      return Promise.resolve();
    });
    vi.spyOn(video, "pause").mockImplementation(() => {
      paused = true;
      video.dispatchEvent(new Event("pause"));
    });
    const playback = createScenePlayback({
      resolveModule: () => scene.module,
      sceneRoot: scene.sceneRoot,
      surface: scene.surface,
    });
    playback.synchronize(1, true);
    scene.timeline().progress(1);
    video.pause();
    vi.advanceTimersByTime(3000);
    expect(scene.playbackState()).toBe("awaiting-replay");
    expect(observeProof(scene.surface).state).toBe("shown");
    playback.dispose();
  });

  it("hides the proof at once and seeks when a step is chosen during the proof beat", () => {
    // Arrange
    stubReducedMotion(false);
    const scene = createFakeSceneFixture();
    const playback = createScenePlayback({
      resolveModule: () => scene.module,
      sceneRoot: scene.sceneRoot,
      surface: scene.surface,
    });
    playback.synchronize(1, true);
    scene.timeline().progress(1);

    // Act
    scene.surface.dispatchEvent(
      new CustomEvent("agentstudio:chapter-step-requested", {
        detail: { stepId: "watch-folders" },
      }),
    );

    // Assert
    expect(observeProof(scene.surface)).toMatchObject({
      proofAriaHidden: "true",
      recreationAriaHidden: null,
      state: "hidden",
      transition: "instant",
    });
    expect(scene.playbackState()).toBe("playing");
    expect(scene.timeline().time()).toBe(scene.timeline().labels["beat-watch"]);
    playback.dispose();
  });

  it("keeps the settled markup when the scene module is not registered", () => {
    stubReducedMotion(false);
    const scene = createFakeSceneFixture();
    const playback = createScenePlayback({
      resolveModule: () => undefined,
      sceneRoot: scene.sceneRoot,
      surface: scene.surface,
    });

    playback.synchronize(1, true);

    expect(scene.playbackState()).toBe("settled");
    expect(scene.toggle.hidden).toBe(true);
    playback.dispose();
  });

  it("keeps the settled markup once, without retrying, when the scene markup lacks a part", () => {
    // Arrange: the real scene module over markup that has none of its parts.
    stubReducedMotion(false);
    const warn = vi.spyOn(console, "warn").mockImplementation((): void => undefined);
    const realModule = resolveSceneModule("chapter-many-agents");
    if (realModule === undefined) {
      throw new Error("chapter-many-agents is not registered");
    }
    const buildScene = vi.fn((...buildArguments: Parameters<SceneModule["buildScene"]>): void =>
      realModule.buildScene(...buildArguments),
    );
    const fixture = addFixture(`
      <section data-surface>
        <div data-scene-root="chapter-many-agents"><p data-settled>Settled frame</p></div>
        ${proofLayerMarkup}
        <button type="button" data-scene-playback-toggle hidden>Play animation</button>
      </section>
    `);
    const surface = requiredHtmlElement(fixture, "[data-surface]");
    const sceneRoot = requiredHtmlElement(surface, "[data-scene-root]");
    const toggle = requiredHtmlElement(surface, "[data-scene-playback-toggle]");
    const playback = createScenePlayback({
      resolveModule: () => ({ ...realModule, buildScene }),
      sceneRoot,
      surface,
    });

    // Act
    playback.synchronize(1, true);
    playback.synchronize(0.5, true);
    playback.synchronize(1, true);
    toggle.click();
    surface.dispatchEvent(
      new CustomEvent("agentstudio:chapter-step-requested", {
        detail: { stepId: "watch-folders" },
      }),
    );

    // Assert
    expect(buildScene).toHaveBeenCalledTimes(1);
    expect(sceneRoot.dataset["scenePlaybackState"]).toBe("settled");
    expect(toggle.hidden).toBe(true);
    expect(requiredHtmlElement(sceneRoot, "[data-settled]").getAttribute("style")).toBe(null);
    expect(warn).toHaveBeenCalledTimes(1);
    expect(String(warn.mock.calls[0]?.[0])).toContain("chapter-many-agents");
    expect(observeProof(surface)).toMatchObject({
      proofAriaHidden: null,
      recreationAriaHidden: "true",
      state: "shown",
    });
    playback.dispose();
  });

  it("restores the settled markup on dispose", () => {
    stubReducedMotion(false);
    const scene = createFakeSceneFixture();
    const playback = createScenePlayback({
      resolveModule: () => scene.module,
      sceneRoot: scene.sceneRoot,
      surface: scene.surface,
    });

    playback.synchronize(1, true);
    scene.timeline().seek(0.5);
    playback.dispose();

    expect(requiredHtmlElement(scene.sceneRoot, '[data-beat="first"]').style.opacity).toBe("");
    expect(scene.playbackState()).toBe("settled");
  });
});

describe("stage-measured autoplay progress", () => {
  it("autoplays a centered media stage inside a surface taller than the viewport", async () => {
    const fixture = addFixture(`
      <section data-scroll-material-surface style="position: relative; height: 200vh;">
        <div
          data-scroll-playback-stage
          style="position: absolute; top: 35vh; left: 0; width: 100%; height: 30vh;"
        >
          <video data-scroll-autoplay-video></video>
        </div>
      </section>
    `);
    const video = fixture.querySelector("video");
    if (!(video instanceof HTMLVideoElement)) {
      throw new Error("Stage fixture is missing its video");
    }
    let videoPaused = true;
    Object.defineProperty(video, "paused", { configurable: true, get: (): boolean => videoPaused });
    const playSpy = vi.spyOn(video, "play").mockImplementation((): Promise<void> => {
      videoPaused = false;
      video.dispatchEvent(new Event("play"));
      return Promise.resolve();
    });
    window.scrollTo(0, 0);
    const surface = requiredHtmlElement(fixture, "[data-scroll-material-surface]");
    expect(surface.getBoundingClientRect().height).toBeGreaterThan(window.innerHeight);

    initializeScrollMaterialSurfaces();

    expect(playSpy).toHaveBeenCalledTimes(1);
    expect(surface.dataset["visualState"]).not.toBe("floating");
    initializeScrollMaterialSurfaces();
  });
});
