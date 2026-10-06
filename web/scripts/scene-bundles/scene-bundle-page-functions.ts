// Functions the scene bundle build runs inside headless Chrome. Each one is
// sent as source text, so it must be self-contained: no references to module
// scope, only its JSON arguments. Type-only imports are erased and safe.

// The registry module also declares `window.AgentStudioScenes`, which scene.js fills.
import type { RegisteredSceneBundle } from "./scene-bundle-registry.ts";
import type { SelectorProbe, SelectorReach } from "./scene-stylesheet-model.ts";

export interface ReadSceneMarkupInput {
  readonly homePageHtml: string;
  readonly sceneId: string;
}

/** A stylesheet the page applies, in cascade order. */
export type PageStylesheetSource =
  | { readonly kind: "linked"; readonly href: string }
  | { readonly kind: "inline"; readonly cssText: string };

export interface SceneMarkupReading {
  readonly sceneMarkup: string;
  readonly stylesheetSources: readonly PageStylesheetSource[];
}

/** The scene's settled markup and the page's stylesheets in document order. */
export function readSceneMarkupInPage(input: ReadSceneMarkupInput): SceneMarkupReading {
  const page = new DOMParser().parseFromString(input.homePageHtml, "text/html");
  const sceneRoot = page.querySelector(`[data-scene-root="${input.sceneId}"]`);
  if (sceneRoot === null) {
    throw new Error(`The built home page has no scene root for ${input.sceneId}.`);
  }
  const stylesheetElements = page.querySelectorAll('link[rel~="stylesheet"], style');
  const stylesheetSources = Array.from(stylesheetElements, (element): PageStylesheetSource =>
    element instanceof HTMLLinkElement
      ? { kind: "linked", href: element.getAttribute("href") ?? "" }
      : { kind: "inline", cssText: element.textContent },
  );
  return { sceneMarkup: sceneRoot.outerHTML, stylesheetSources };
}

export interface MeasureSelectorReachInput {
  readonly sceneMarkup: string;
  readonly selectorProbes: readonly SelectorProbe[];
}

/**
 * Matches each selector's probe against the scene alone, outside the page, so
 * rules that need the page around the scene (a chapter stage, the site header)
 * fall away. Selectors Chrome does not support reach nothing, as in the page.
 */
export function measureSelectorReachInPage(
  input: MeasureSelectorReachInput,
): Readonly<Record<string, SelectorReach>> {
  const isolatedDocument = document.implementation.createHTMLDocument("scene");
  isolatedDocument.body.innerHTML = input.sceneMarkup;
  const sceneRoot = isolatedDocument.body.firstElementChild;
  if (sceneRoot === null) {
    throw new Error("Scene markup has no root element.");
  }
  const reachBySelector: Record<string, SelectorReach> = {};
  for (const { selector, probe } of input.selectorProbes) {
    if (!CSS.supports(`selector(${selector})`)) {
      reachBySelector[selector] = "none";
      continue;
    }
    let matchesRoot: boolean;
    let matchesDescendant: boolean;
    try {
      matchesRoot = sceneRoot.matches(probe);
      matchesDescendant = sceneRoot.querySelector(probe) !== null;
    } catch (error: unknown) {
      throw new Error(
        `Probe "${probe}" for supported selector "${selector}" is invalid: ${String(error)}`,
        { cause: error },
      );
    }
    reachBySelector[selector] =
      matchesRoot && matchesDescendant
        ? "root-and-descendants"
        : matchesRoot
          ? "root"
          : matchesDescendant
            ? "descendants"
            : "none";
  }
  return reachBySelector;
}

/** Runs a classic script the way a `<script>` tag would, surfacing its errors. */
export function runClassicScriptInPage(scriptText: string): void {
  const reportedErrors: string[] = [];
  const recordError = (event: ErrorEvent): void => {
    reportedErrors.push(String(event.error ?? event.message));
  };
  window.addEventListener("error", recordError);
  const script = document.createElement("script");
  script.textContent = scriptText;
  document.head.append(script);
  script.remove();
  window.removeEventListener("error", recordError);
  if (reportedErrors.length > 0) {
    throw new Error(`Classic script failed: ${reportedErrors.join("; ")}`);
  }
}

/** Where the measured scene's buildScene comes from. */
export type SceneBuilderSource =
  | {
      /** The bare Vite IIFE, which declares `globalName` with the module as `exportName`. */
      readonly kind: "bundle-export";
      readonly bundleCode: string;
      readonly globalName: string;
      readonly exportName: string;
    }
  | {
      /** The finished scene.js, which registers on `window.AgentStudioScenes`. */
      readonly kind: "registered";
      readonly sceneScript: string;
    };

export interface MeasureSceneTimelineInput {
  readonly sceneId: string;
  readonly sceneMarkup: string;
  readonly sceneCss: string;
  readonly stage: { readonly width: number; readonly height: number };
  readonly seed: number;
  readonly builderSource: SceneBuilderSource;
}

export interface SceneTimelineMeasurement {
  /** Label name and time, in time order. */
  readonly labels: readonly (readonly [string, number])[];
  readonly durationSeconds: number;
  /** Read from the mounted root, which proves the scoped CSS reached it. */
  readonly containerName: string;
  readonly rootWidth: number;
  readonly rootHeight: number;
  /** What the module declares, for a bundle export. */
  readonly declaredModule: {
    readonly sceneId: string;
    readonly timelineLabels: readonly string[];
  } | null;
  /** What scene.js registered, for a finished script. */
  readonly registration: {
    readonly labels: Readonly<Record<string, number>>;
    readonly durationSeconds: number;
  } | null;
}

/**
 * Loads a scene builder as a classic script, mounts the scene with its scoped
 * CSS on a stage, and builds it into a paused timeline with the page's GSAP,
 * the way a HyperFrames host would. One call, so scenes cannot interleave.
 */
export function measureSceneTimelineInPage(
  input: MeasureSceneTimelineInput,
): SceneTimelineMeasurement {
  interface BundledSceneModule {
    readonly sceneId: string;
    readonly steps: readonly { readonly timelineLabel: string }[];
    readonly buildScene: RegisteredSceneBundle["buildScene"];
  }
  // Guards live inside because only this function's source text reaches the page.
  // oxlint-disable-next-line unicorn/consistent-function-scoping
  const isGsapRuntime = (value: unknown): value is typeof import("gsap").gsap =>
    typeof value === "object" &&
    value !== null &&
    "timeline" in value &&
    typeof value.timeline === "function";
  // oxlint-disable-next-line unicorn/consistent-function-scoping
  const isBundledSceneModule = (value: unknown): value is BundledSceneModule =>
    typeof value === "object" &&
    value !== null &&
    "sceneId" in value &&
    typeof value.sceneId === "string" &&
    "steps" in value &&
    Array.isArray(value.steps) &&
    "buildScene" in value &&
    typeof value.buildScene === "function";

  const pageGsap: unknown = Reflect.get(window, "gsap");
  if (!isGsapRuntime(pageGsap)) {
    throw new Error("GSAP is not loaded in the measuring page.");
  }
  const { builderSource } = input;
  const reportedErrors: string[] = [];
  const recordError = (event: ErrorEvent): void => {
    reportedErrors.push(String(event.error ?? event.message));
  };
  window.addEventListener("error", recordError);
  const script = document.createElement("script");
  script.textContent =
    builderSource.kind === "bundle-export" ? builderSource.bundleCode : builderSource.sceneScript;
  document.head.append(script);
  script.remove();
  window.removeEventListener("error", recordError);
  if (reportedErrors.length > 0) {
    throw new Error(`The ${input.sceneId} script failed: ${reportedErrors.join("; ")}`);
  }

  let buildScene: RegisteredSceneBundle["buildScene"];
  let declaredModule: SceneTimelineMeasurement["declaredModule"] = null;
  let registration: SceneTimelineMeasurement["registration"] = null;
  if (builderSource.kind === "bundle-export") {
    const bundleExports: unknown = Reflect.get(window, builderSource.globalName);
    const sceneModule: unknown =
      typeof bundleExports === "object" && bundleExports !== null
        ? Reflect.get(bundleExports, builderSource.exportName)
        : undefined;
    if (!isBundledSceneModule(sceneModule)) {
      throw new Error(`The ${input.sceneId} bundle does not export ${builderSource.exportName}.`);
    }
    buildScene = sceneModule.buildScene;
    declaredModule = {
      sceneId: sceneModule.sceneId,
      timelineLabels: sceneModule.steps.map((step) => step.timelineLabel),
    };
  } else {
    const registeredScene: RegisteredSceneBundle | undefined =
      window.AgentStudioScenes?.[input.sceneId];
    if (registeredScene === undefined) {
      throw new Error(`scene.js did not register ${input.sceneId}.`);
    }
    buildScene = registeredScene.buildScene;
    registration = {
      labels: { ...registeredScene.labels },
      durationSeconds: registeredScene.durationSeconds,
    };
  }

  const style = document.createElement("style");
  style.textContent = input.sceneCss;
  document.head.append(style);
  const stage = document.createElement("div");
  stage.style.width = `${String(input.stage.width)}px`;
  stage.style.height = `${String(input.stage.height)}px`;
  stage.style.container = "recreation-kit / size";
  stage.innerHTML = input.sceneMarkup;
  document.body.append(stage);
  try {
    const sceneRoot = stage.firstElementChild;
    if (!(sceneRoot instanceof HTMLElement)) {
      throw new Error("Scene markup has no root element.");
    }
    const timeline = pageGsap.timeline({ paused: true });
    buildScene(sceneRoot, timeline, {
      width: input.stage.width,
      height: input.stage.height,
      seed: input.seed,
    });
    const measurement: SceneTimelineMeasurement = {
      labels: Object.entries(timeline.labels).toSorted(
        ([, firstTime], [, secondTime]) => firstTime - secondTime,
      ),
      durationSeconds: timeline.duration(),
      containerName: getComputedStyle(sceneRoot).containerName,
      rootWidth: sceneRoot.clientWidth,
      rootHeight: sceneRoot.clientHeight,
      declaredModule,
      registration,
    };
    timeline.revert();
    timeline.kill();
    return measurement;
  } finally {
    stage.remove();
    style.remove();
  }
}
