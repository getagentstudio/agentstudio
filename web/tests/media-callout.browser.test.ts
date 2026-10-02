import { gsap } from "gsap";
import { afterEach, beforeAll, describe, expect, inject, it, vi } from "vitest";
import { commands } from "vitest/browser";

import type { MediaCalloutMount, MediaCalloutParameters } from "../src/media-callout/media-callout";
import { mediaCalloutStagePresets } from "../src/media-callout/media-callout";
import type {
  BuiltMediaCalloutFiles,
  StepPillStyleObservation,
} from "./media-callout-browser-command";
import type { BuiltSceneBundleFiles } from "./scene-bundle-browser-command";

declare module "vitest/browser" {
  interface BrowserCommands {
    buildMediaCalloutForBrowserTest(pageUrl: string): Promise<BuiltMediaCalloutFiles>;
    buildSceneBundlesForBrowserTest(): Promise<readonly BuiltSceneBundleFiles[]>;
  }
}

declare global {
  interface Window {
    AgentStudioMediaCallout?: MediaCalloutBrowserApi;
  }
}

interface MediaCalloutBrowserApi {
  readonly mountMediaCallout: (
    stageElement: HTMLElement,
    parameters: MediaCalloutParameters,
    timeline: ReturnType<typeof gsap.timeline>,
  ) => MediaCalloutMount;
}

interface MediaCalloutManifestReading {
  readonly schemaVersion: 1;
  readonly componentId: string;
  readonly websiteRevision: string;
  readonly websiteTreeClean: boolean;
  readonly gsap: {
    readonly version: string;
    readonly loading: "external-script";
    readonly scriptUrl: string;
  };
  readonly stagePresets: readonly {
    readonly name: string;
    readonly width: number;
    readonly height: number;
  }[];
  readonly parametersSchema: { readonly properties: Readonly<Record<string, unknown>> };
  readonly sha256: Readonly<Record<string, string>>;
}

const mountedStages: HTMLElement[] = [];
const mountedTimelines: ReturnType<typeof gsap.timeline>[] = [];
let mediaCalloutApi: MediaCalloutBrowserApi;
let stepPillReferenceStyle: StepPillStyleObservation;
let builtFiles: BuiltMediaCalloutFiles;
let mediaCalloutManifest: MediaCalloutManifestReading;

function mediaCalloutApiFromWindow(ownerWindow: Window): MediaCalloutBrowserApi {
  const api = ownerWindow.AgentStudioMediaCallout;
  if (api === undefined) {
    throw new Error("The built callout.js did not register its public mount function.");
  }
  return api;
}

function isRecord(value: unknown): value is Readonly<Record<string, unknown>> {
  return typeof value === "object" && value !== null;
}

function isStringRecord(value: unknown): value is Readonly<Record<string, string>> {
  return isRecord(value) && Object.values(value).every((entry) => typeof entry === "string");
}

function isMediaCalloutManifest(value: unknown): value is MediaCalloutManifestReading {
  if (!isRecord(value)) {
    return false;
  }
  const gsapManifest = value["gsap"];
  const parametersSchema = value["parametersSchema"];
  const stagePresets = value["stagePresets"];
  return (
    value["schemaVersion"] === 1 &&
    typeof value["componentId"] === "string" &&
    typeof value["websiteRevision"] === "string" &&
    typeof value["websiteTreeClean"] === "boolean" &&
    isRecord(gsapManifest) &&
    typeof gsapManifest["version"] === "string" &&
    gsapManifest["loading"] === "external-script" &&
    typeof gsapManifest["scriptUrl"] === "string" &&
    Array.isArray(stagePresets) &&
    stagePresets.every(
      (preset) =>
        isRecord(preset) &&
        typeof preset["name"] === "string" &&
        typeof preset["width"] === "number" &&
        typeof preset["height"] === "number",
    ) &&
    isRecord(parametersSchema) &&
    isRecord(parametersSchema["properties"]) &&
    isStringRecord(value["sha256"])
  );
}

function readMediaCalloutManifest(manifestText: string): MediaCalloutManifestReading {
  const parsed: unknown = JSON.parse(manifestText);
  if (!isMediaCalloutManifest(parsed)) {
    throw new Error("The media callout manifest has an invalid shape.");
  }
  return parsed;
}

async function sha256Hex(content: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(content));
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function mountStage(width: number, height: number): HTMLElement {
  const stage = document.createElement("div");
  stage.className = "media-callout-preview-stage";
  stage.style.position = "relative";
  stage.style.width = `${String(width)}px`;
  stage.style.height = `${String(height)}px`;
  stage.style.left = "0";
  stage.style.top = "0";
  document.body.append(stage);
  mountedStages.push(stage);
  return stage;
}

function createTimeline(): ReturnType<typeof gsap.timeline> {
  const timeline = gsap.timeline({ paused: true });
  mountedTimelines.push(timeline);
  return timeline;
}

function expectLabelFits(stage: HTMLElement, mount: MediaCalloutMount): void {
  const stageBounds = stage.getBoundingClientRect();
  const labelBounds = mount.label.getBoundingClientRect();
  expect(labelBounds.left).toBeGreaterThanOrEqual(stageBounds.left - 1);
  expect(labelBounds.top).toBeGreaterThanOrEqual(stageBounds.top - 1);
  expect(labelBounds.right).toBeLessThanOrEqual(stageBounds.right + 1);
  expect(labelBounds.bottom).toBeLessThanOrEqual(stageBounds.bottom + 1);
  expect(mount.label.scrollWidth).toBeLessThanOrEqual(mount.label.clientWidth + 1);

  const targetBounds = mount.targetNode.getBoundingClientRect();
  const targetCenterX = targetBounds.left + targetBounds.width / 2;
  const targetCenterY = targetBounds.top + targetBounds.height / 2;
  const gapX = Math.max(labelBounds.left - targetCenterX, 0, targetCenterX - labelBounds.right);
  const gapY = Math.max(labelBounds.top - targetCenterY, 0, targetCenterY - labelBounds.bottom);
  expect(Math.hypot(gapX, gapY)).toBeGreaterThan(6);
}

function expectCalloutRouteConnects(mount: MediaCalloutMount): void {
  const labelBounds = mount.label.getBoundingClientRect();
  const matrix = mount.route.getScreenCTM();
  if (matrix === null) {
    throw new Error("The callout path has no screen transform.");
  }
  const firstPoint = mount.route.getPointAtLength(0).matrixTransform(matrix);
  const lastPoint = mount.route
    .getPointAtLength(mount.route.getTotalLength())
    .matrixTransform(matrix);
  const targetBounds = mount.targetNode.getBoundingClientRect();
  const targetCenter = {
    x: targetBounds.left + targetBounds.width / 2,
    y: targetBounds.top + targetBounds.height / 2,
  };
  expect(
    Math.hypot(firstPoint.x - targetCenter.x, firstPoint.y - targetCenter.y),
  ).toBeLessThanOrEqual(1);

  const labelEdges = [
    Math.abs(lastPoint.x - labelBounds.left),
    Math.abs(lastPoint.x - labelBounds.right),
    Math.abs(lastPoint.y - labelBounds.top),
    Math.abs(lastPoint.y - labelBounds.bottom),
  ];
  expect(Math.min(...labelEdges)).toBeLessThanOrEqual(1);
  expect(lastPoint.x).toBeGreaterThanOrEqual(labelBounds.left - 1);
  expect(lastPoint.x).toBeLessThanOrEqual(labelBounds.right + 1);
  expect(lastPoint.y).toBeGreaterThanOrEqual(labelBounds.top - 1);
  expect(lastPoint.y).toBeLessThanOrEqual(labelBounds.bottom + 1);
  expect(mount.route.getAttribute("d")).toMatch(/^M\s[-\d.]+\s[-\d.]+\s+C\s/u);
  for (let sampleIndex = 1; sampleIndex < 20; sampleIndex += 1) {
    const point = mount.route
      .getPointAtLength((mount.route.getTotalLength() * sampleIndex) / 20)
      .matrixTransform(matrix);
    const crossesLabelInterior =
      point.x > labelBounds.left + 2 &&
      point.x < labelBounds.right - 2 &&
      point.y > labelBounds.top + 2 &&
      point.y < labelBounds.bottom - 2;
    expect(crossesLabelInterior, `route sample ${String(sampleIndex)}`).toBe(false);
  }
}

function expectStepPillStyleMatches(mount: MediaCalloutMount): void {
  const actualStyle = getComputedStyle(mount.label);
  const comparedProperties = [
    "backgroundColor",
    "backgroundImage",
    "borderTopColor",
    "borderTopStyle",
    "borderTopWidth",
    "borderTopLeftRadius",
    "color",
    "fontFamily",
    "fontSize",
    "fontWeight",
    "lineHeight",
    "letterSpacing",
    "paddingBottom",
    "paddingLeft",
    "paddingRight",
    "paddingTop",
  ] as const;
  for (const property of comparedProperties) {
    expect(actualStyle[property], property).toBe(stepPillReferenceStyle[property]);
  }
}

beforeAll(async () => {
  builtFiles = await commands.buildMediaCalloutForBrowserTest(inject("siteHeaderBrowserTestUrl"));
  const style = document.createElement("style");
  style.textContent = builtFiles.css;
  document.head.append(style);
  const script = document.createElement("script");
  script.textContent = builtFiles.javascript;
  document.head.append(script);
  script.remove();
  mediaCalloutApi = mediaCalloutApiFromWindow(window);
  stepPillReferenceStyle = builtFiles.stepPillStyle;
  mediaCalloutManifest = readMediaCalloutManifest(builtFiles.manifest);
  await document.fonts.ready;
});

afterEach(() => {
  for (const timeline of mountedTimelines.splice(0)) {
    timeline.kill();
  }
  for (const stage of mountedStages.splice(0)) {
    stage.remove();
  }
});

describe("media callout browser bundle", () => {
  it("emits a hashed parameterized asset with external GSAP", async () => {
    expect(mediaCalloutManifest.schemaVersion).toBe(1);
    expect(mediaCalloutManifest.componentId).toBe("media-callout");
    expect(mediaCalloutManifest.websiteRevision).not.toBe("");
    expect(mediaCalloutManifest.gsap.loading).toBe("external-script");
    expect(mediaCalloutManifest.gsap.version).toBe("3.15.0");
    expect(mediaCalloutManifest.gsap.scriptUrl).toContain("/gsap@3.15.0/dist/gsap.min.js");
    expect(mediaCalloutManifest.stagePresets).toEqual([
      { name: "landscape-1920x1200", width: 1920, height: 1200 },
      { name: "portrait-1080x1350", width: 1080, height: 1350 },
    ]);
    for (const parameterName of ["stage", "target", "labelPosition", "text", "animation"]) {
      expect(mediaCalloutManifest.parametersSchema.properties[parameterName]).toBeDefined();
    }
    expect(mediaCalloutManifest.sha256["callout.html"]).toBe(await sha256Hex(builtFiles.html));
    expect(mediaCalloutManifest.sha256["callout.css"]).toBe(await sha256Hex(builtFiles.css));
    expect(mediaCalloutManifest.sha256["callout.js"]).toBe(await sha256Hex(builtFiles.javascript));
    expect(builtFiles.html).toContain(mediaCalloutManifest.gsap.scriptUrl);
  });

  it("uses the target point, fits the stage, joins the pill edge, and reaches held state", () => {
    for (const stageSize of mediaCalloutStagePresets) {
      const stage = mountStage(stageSize.width, stageSize.height);
      const timeline = createTimeline();
      const parameters: MediaCalloutParameters = {
        stage: stageSize,
        target: { x: stageSize.width * 0.54, y: stageSize.height * 0.46 },
        labelPosition: "auto",
        text: "Claude Code and Codex · same repo · two worktrees",
        animation: "in",
      };
      const mount = mediaCalloutApi.mountMediaCallout(stage, parameters, timeline);

      const stageBounds = stage.getBoundingClientRect();
      const nodeBounds = mount.targetNode.getBoundingClientRect();
      expect(
        Math.abs(nodeBounds.left + nodeBounds.width / 2 - stageBounds.left - parameters.target.x),
      ).toBeLessThanOrEqual(1);
      expect(
        Math.abs(nodeBounds.top + nodeBounds.height / 2 - stageBounds.top - parameters.target.y),
      ).toBeLessThanOrEqual(1);
      expectLabelFits(stage, mount);
      expectCalloutRouteConnects(mount);
      expectStepPillStyleMatches(mount);
      expect(timeline.paused()).toBe(true);
      expect(timeline.duration()).toBeLessThanOrEqual(0.4);
      expect(getComputedStyle(mount.targetNode).opacity).toBe("0");
      expect(getComputedStyle(mount.label).opacity).toBe("0");
      expect(Number.parseFloat(getComputedStyle(mount.route).strokeDashoffset)).toBeGreaterThan(0);

      timeline.seek(mount.endAtSeconds, false);
      expect(getComputedStyle(mount.targetNode).opacity).toBe("1");
      expect(getComputedStyle(mount.label).opacity).toBe("1");
      expect(Number.parseFloat(getComputedStyle(mount.route).strokeDashoffset)).toBeLessThanOrEqual(
        0.01,
      );
      expectCalloutRouteConnects(mount);
    }
  });

  it("retracts out motion within 0.4 seconds and holds immediately for reduced motion", () => {
    const stage = mountStage(1920, 1200);
    const outroTimeline = createTimeline();
    const outro = mediaCalloutApi.mountMediaCallout(
      stage,
      {
        stage: { width: 1920, height: 1200 },
        target: { x: 960, y: 600 },
        labelPosition: "above",
        text: "⌘P → any agent's pane",
        animation: "out",
      },
      outroTimeline,
    );
    expect(outroTimeline.duration()).toBeLessThanOrEqual(0.4);
    outroTimeline.seek(outro.endAtSeconds, false);
    expect(getComputedStyle(outro.targetNode).opacity).toBe("0");
    expect(getComputedStyle(outro.label).opacity).toBe("0");

    const originalMatchMedia = window.matchMedia.bind(window);
    const reducedMotionSpy = vi.spyOn(window, "matchMedia").mockImplementation((mediaQuery) => {
      const nativeList = originalMatchMedia(mediaQuery);
      return new Proxy(nativeList, {
        get(target, property, receiver) {
          return property === "matches" ? true : Reflect.get(target, property, receiver);
        },
      });
    });
    try {
      const reducedStage = mountStage(1080, 1350);
      const reducedTimeline = createTimeline();
      const reduced = mediaCalloutApi.mountMediaCallout(
        reducedStage,
        {
          stage: { width: 1080, height: 1350 },
          target: { x: 540, y: 675 },
          labelPosition: "auto",
          text: "⌘P → any agent's pane",
          animation: "in",
          startAtSeconds: 2,
        },
        reducedTimeline,
      );
      expect(reduced.animation).toBe("held");
      expect(reduced.endAtSeconds).toBe(2);
      expect(reducedTimeline.getChildren()).toHaveLength(0);
      expect(getComputedStyle(reduced.targetNode).opacity).toBe("1");
      expect(getComputedStyle(reduced.label).opacity).toBe("1");
      expect(
        Number.parseFloat(getComputedStyle(reduced.route).strokeDashoffset),
      ).toBeLessThanOrEqual(0.01);
    } finally {
      reducedMotionSpy.mockRestore();
    }
  });

  it("renders an explicit held state without adding timeline motion", () => {
    const stage = mountStage(1920, 1200);
    const timeline = createTimeline();
    const mount = mediaCalloutApi.mountMediaCallout(
      stage,
      {
        stage: { width: 1920, height: 1200 },
        target: { x: 960, y: 600 },
        labelPosition: "right",
        text: "Claude Code and Codex · same repo · two worktrees",
        animation: "held",
      },
      timeline,
    );

    expect(mount.animation).toBe("held");
    expect(mount.endAtSeconds).toBe(mount.startAtSeconds);
    expect(timeline.getChildren()).toHaveLength(0);
    expect(getComputedStyle(mount.targetNode).opacity).toBe("1");
    expect(getComputedStyle(mount.label).opacity).toBe("1");
    expect(Number.parseFloat(getComputedStyle(mount.route).strokeDashoffset)).toBeLessThanOrEqual(
      0.01,
    );
  });

  it("builds the callout and scene bundles concurrently with isolated Astro and Vite caches", async () => {
    const [calloutFiles, sceneBundles] = await Promise.all([
      commands.buildMediaCalloutForBrowserTest(inject("siteHeaderBrowserTestUrl")),
      commands.buildSceneBundlesForBrowserTest(),
    ]);

    expect(calloutFiles.manifest).toContain('"componentId": "media-callout"');
    expect(sceneBundles.length).toBeGreaterThan(0);
  });
});
