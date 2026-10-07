import { gsap } from "gsap";
import { afterEach, beforeAll, describe, expect, inject, it } from "vitest";

import { chapterCatalog } from "../src/chapters/chapter-catalog";
import { sceneRootAttribute } from "../src/chapters/chapter-dom-contract";
import type { ChapterStepId } from "../src/chapters/chapter-ids";
import {
  isSceneId,
  sceneIds,
  type SceneId,
  type SceneTimeline,
} from "../src/motion-scenes/scene-contract";
import { resolveSceneModule } from "../src/motion-scenes/scene-registry";
import { chapterComeBackStepKeyParts } from "../src/motion-scenes/scenes/chapter-come-back/chapter-come-back-fixture";
import { chapterContextWithTaskStepKeyParts } from "../src/motion-scenes/scenes/chapter-context-with-task/chapter-context-with-task-fixture";
import { chapterFindAndFocusStepKeyParts } from "../src/motion-scenes/scenes/chapter-find-and-focus/chapter-find-and-focus-fixture";
import { chapterManyAgentsStepKeyParts } from "../src/motion-scenes/scenes/chapter-many-agents/chapter-many-agents-fixture";
import { chapterReviewStepKeyParts } from "../src/motion-scenes/scenes/chapter-review/chapter-review-fixture";
import { kitPhoneAttribute, scenePartSelector } from "../src/recreation-kit/recreation-kit-dom";

declare module "vitest" {
  export interface ProvidedContext {
    siteHeaderBrowserTestUrl: string;
  }
}

// The home page mounts every chapter scene, so the real page is the markup source.
const sceneMarkupPagePath = "/";

const desktopStage = { width: 1100, height: 688 } as const;
// A 390px phone viewport leaves a 330px-wide stage, portrait 4:5 below the phone breakpoint.
const phoneStage = { width: 330, height: 412 } as const;

// Smallest recreation text a phone reader can read without zooming.
const minimumPhoneFontSizePx = 11;

// Each beat must show its subject within half a second of its label.
const keyElementDeadlineSeconds = 0.5;

const sceneStepKeyParts: Readonly<
  Record<SceneId, Readonly<Partial<Record<ChapterStepId, string>>>>
> = {
  "chapter-many-agents": chapterManyAgentsStepKeyParts,
  "chapter-context-with-task": chapterContextWithTaskStepKeyParts,
  "chapter-find-and-focus": chapterFindAndFocusStepKeyParts,
  "chapter-review": chapterReviewStepKeyParts,
  "chapter-come-back": chapterComeBackStepKeyParts,
};

interface SceneMarkupSource {
  readonly styles: readonly HTMLStyleElement[];
  readonly rootsBySceneId: ReadonlyMap<SceneId, HTMLElement>;
}

let sceneMarkupSource: SceneMarkupSource;
const mountedStages: HTMLElement[] = [];

async function loadSceneMarkupSource(): Promise<SceneMarkupSource> {
  const pageUrl = new URL(sceneMarkupPagePath, inject("siteHeaderBrowserTestUrl"));
  // Chrome refuses this page's fetch to the 127.0.0.1 spelling of the loopback
  // server; the test page's own host name reaches the same server.
  pageUrl.hostname = location.hostname;
  const response = await fetch(pageUrl);
  if (!response.ok) {
    throw new Error(`Scene markup page answered ${String(response.status)}`);
  }
  const page = new DOMParser().parseFromString(await response.text(), "text/html");
  const rootsBySceneId = new Map<SceneId, HTMLElement>();
  for (const root of page.querySelectorAll<HTMLElement>(`[${sceneRootAttribute}]`)) {
    const sceneId = root.getAttribute(sceneRootAttribute) ?? "";
    if (isSceneId(sceneId)) {
      rootsBySceneId.set(sceneId, root);
    }
  }
  return { styles: Array.from(page.querySelectorAll("head style")), rootsBySceneId };
}

function mountScene(
  sceneId: SceneId,
  stage: { readonly width: number; readonly height: number },
): HTMLElement {
  const sourceRoot = sceneMarkupSource.rootsBySceneId.get(sceneId);
  if (sourceRoot === undefined) {
    throw new Error(`Scene markup page has no root for ${sceneId}`);
  }
  const stageElement = document.createElement("div");
  stageElement.style.width = `${String(stage.width)}px`;
  stageElement.style.height = `${String(stage.height)}px`;
  const root = document.importNode(sourceRoot, true);
  stageElement.append(root);
  document.body.append(stageElement);
  mountedStages.push(stageElement);
  return root;
}

function buildMountedScene(sceneId: SceneId, root: HTMLElement, seed: number): SceneTimeline {
  const sceneModule = resolveSceneModule(sceneId);
  if (sceneModule === undefined) {
    throw new Error(`No scene module registered for ${sceneId}`);
  }
  const timeline = gsap.timeline({ paused: true });
  sceneModule.buildScene(root, timeline, {
    width: root.clientWidth,
    height: root.clientHeight,
    seed,
  });
  return timeline;
}

function elementPath(root: HTMLElement, element: Element): string {
  if (element === root) {
    return "root";
  }
  return String(Array.from(root.querySelectorAll("*")).indexOf(element));
}

// GSAP links its own runtime objects into vars; only the scene's declared values count.
function declaredValue(key: string, value: unknown): unknown {
  if (key.startsWith("_") || key === "parent" || value instanceof gsap.core.Animation) {
    return undefined;
  }
  return value instanceof Element ? "element" : value;
}

/** Every tween as start, duration, target positions, and its declared values. */
function describeTweens(root: HTMLElement, timeline: SceneTimeline): readonly string[] {
  return timeline.getChildren(true, true, false).map((tween) => {
    const targets = tween
      .targets()
      .map((target: unknown) => (target instanceof Element ? elementPath(root, target) : "hold"));
    return JSON.stringify(
      [tween.startTime(), tween.duration(), targets, tween.vars],
      declaredValue,
    );
  });
}

function animatedElements(timeline: SceneTimeline): readonly HTMLElement[] {
  const elements = timeline
    .getChildren(true, true, false)
    .flatMap((tween) => tween.targets())
    .filter((target: unknown): target is HTMLElement => target instanceof HTMLElement);
  return Array.from(new Set(elements));
}

// Visually equivalent spellings: GSAP leaves an identity transform or a fully
// open inset where the markup has none.
function canonicalStyleValue(value: string): string {
  if (value === "matrix(1, 0, 0, 1, 0, 0)" || value === "inset(0%)") {
    return "none";
  }
  return value.trim();
}

const snapshotProperties = [
  "opacity",
  "visibility",
  "transform",
  "clip-path",
  "grid-template-rows",
  "flex-grow",
  "translate",
  "--scene-zoom",
  "--scene-files-reveal",
  "--scene-drawer-scroll",
] as const;

function snapshotVisibleState(elements: readonly HTMLElement[]): readonly string[] {
  return elements.map((element) => {
    const computedStyle = getComputedStyle(element);
    return snapshotProperties
      .map(
        (property) =>
          `${property}=${canonicalStyleValue(computedStyle.getPropertyValue(property))}`,
      )
      .join(" ");
  });
}

function ownText(element: Element): string {
  return Array.from(element.childNodes)
    .filter((node) => node.nodeType === Node.TEXT_NODE)
    .map((node) => node.textContent ?? "")
    .join("")
    .trim();
}

/** Font sizes of every element that renders its own text (display: none excluded). */
function renderedTextFontSizes(root: HTMLElement): readonly { text: string; sizePx: number }[] {
  return [root, ...root.querySelectorAll("*")]
    .filter((element) => ownText(element) !== "" && element.getClientRects().length > 0)
    .map((element) => ({
      text: ownText(element),
      sizePx: Number.parseFloat(getComputedStyle(element).fontSize),
    }));
}

/** Visible means rendered, not faded out, and at least partly inside the stage. */
function describeVisibility(root: HTMLElement, element: Element): string {
  const bounds = element.getBoundingClientRect();
  const stageBounds = root.getBoundingClientRect();
  const overlapWidth =
    Math.min(bounds.right, stageBounds.right) - Math.max(bounds.left, stageBounds.left);
  const overlapHeight =
    Math.min(bounds.bottom, stageBounds.bottom) - Math.max(bounds.top, stageBounds.top);
  let fadedAncestor = "";
  for (let current: Element | null = element; current !== null; current = current.parentElement) {
    if (Number.parseFloat(getComputedStyle(current).opacity) === 0) {
      fadedAncestor = current === element ? "itself" : current.className;
      break;
    }
    if (current === root) {
      break;
    }
  }
  if (bounds.width === 0 || bounds.height === 0) {
    return "not rendered";
  }
  if (getComputedStyle(element).visibility !== "visible") {
    return "visibility hidden";
  }
  if (fadedAncestor !== "") {
    return `opacity 0 (${fadedAncestor})`;
  }
  if (overlapWidth <= 0 || overlapHeight <= 0) {
    return "outside the stage";
  }
  return "visible";
}

function countRenderedPanes(root: HTMLElement): number {
  return Array.from(root.querySelectorAll<HTMLElement>(".kit-pane")).filter((pane) => {
    const bounds = pane.getBoundingClientRect();
    return bounds.width > 1 && getComputedStyle(pane).opacity !== "0";
  }).length;
}

describe("motion scenes on their real markup", () => {
  beforeAll(async () => {
    sceneMarkupSource = await loadSceneMarkupSource();
    for (const style of sceneMarkupSource.styles) {
      document.head.append(document.importNode(style, true));
    }
  });

  afterEach(() => {
    for (const stage of mountedStages.splice(0)) {
      stage.remove();
    }
  });

  it.each([
    ["chapter-review", { "review-diff": 0, "review-comment": 1.65 }],
    ["chapter-come-back", { "quit-in-flight": 0, persistence: 2.15 }],
  ] as const)(
    "splits %s at its existing animation boundary without retiming",
    (sceneId, labels) => {
      const root = mountScene(sceneId, desktopStage);
      const timeline = buildMountedScene(sceneId, root, 1);
      try {
        expect(timeline.labels).toEqual(labels);
        expect(timeline.duration()).toBe(8);
        for (const labelTime of Object.values(labels)) timeline.time(labelTime);
        expect(timeline.time()).toBe(Object.values(labels).at(-1));
      } finally {
        timeline.revert();
        timeline.kill();
      }
    },
  );

  it("renders come-back as a full stage with no empty proof frame", async () => {
    const pageUrl = new URL(sceneMarkupPagePath, inject("siteHeaderBrowserTestUrl"));
    pageUrl.hostname = location.hostname;
    const response = await fetch(pageUrl);
    const page = new DOMParser().parseFromString(await response.text(), "text/html");
    const stage = page.querySelector("#come-back .chapter-scene-stage");
    expect(stage).not.toBeNull();
    expect(stage?.querySelector('[data-scene-root="chapter-come-back"]')).not.toBeNull();
    expect(stage?.querySelector("[data-scene-proof], .chapter-scene-proof, video")).toBeNull();
    const root = mountScene("chapter-come-back", desktopStage);
    expect(root.getBoundingClientRect().width).toBeCloseTo(desktopStage.width, 0);
    expect(root.getBoundingClientRect().height).toBeCloseTo(desktopStage.height, 0);
  });

  for (const sceneId of sceneIds) {
    describe(sceneId, () => {
      it("labels its timeline with the chapter's steps and lasts 8 to 14 seconds", () => {
        // Arrange
        const chapter = chapterCatalog.find(
          (candidate) => candidate.stage.kind === "scene" && candidate.stage.sceneId === sceneId,
        );
        const root = mountScene(sceneId, desktopStage);

        // Act
        const timeline = buildMountedScene(sceneId, root, 1);
        const labelsInTimeOrder = Object.entries(timeline.labels)
          .toSorted(([, firstTime], [, secondTime]) => firstTime - secondTime)
          .map(([labelName]) => labelName);

        // Assert
        expect(labelsInTimeOrder).toEqual(
          resolveSceneModule(sceneId)?.steps.map((step) => step.timelineLabel),
        );
        expect(resolveSceneModule(sceneId)?.steps.map((step) => step.stepId)).toEqual(
          chapter?.steps.map((step) => step.id),
        );
        expect(timeline.duration()).toBeGreaterThanOrEqual(8);
        expect(timeline.duration()).toBeLessThanOrEqual(14);
      });

      it("builds the same tween list for the same seed", () => {
        // Arrange
        const firstRoot = mountScene(sceneId, desktopStage);
        const secondRoot = mountScene(sceneId, desktopStage);

        // Act
        const firstTweens = describeTweens(firstRoot, buildMountedScene(sceneId, firstRoot, 7));
        const secondTweens = describeTweens(secondRoot, buildMountedScene(sceneId, secondRoot, 7));

        // Assert
        expect(firstTweens.length).toBeGreaterThan(5);
        expect(secondTweens).toEqual(firstTweens);
      });

      it("ends on its settled markup and returns there after out-of-order seeks", () => {
        // Arrange
        const root = mountScene(sceneId, desktopStage);
        const settledMarkupRoot = mountScene(sceneId, desktopStage);
        const timeline = buildMountedScene(sceneId, root, 1);
        const targets = animatedElements(timeline);
        const settledTargets = targets.map((target) => {
          const path = elementPath(root, target);
          return path === "root"
            ? settledMarkupRoot
            : (settledMarkupRoot.querySelectorAll<HTMLElement>("*")[Number(path)] ??
                settledMarkupRoot);
        });
        const settledMarkupState = snapshotVisibleState(settledTargets);

        // Act
        // A paused GSAP timeline can defer its first render until explicitly sought.
        timeline.time(0);
        const startState = snapshotVisibleState(targets);
        timeline.progress(1);
        const endState = snapshotVisibleState(targets);
        timeline.progress(0.4);
        timeline.progress(0);
        timeline.progress(1);
        const replayedEndState = snapshotVisibleState(targets);

        // Assert
        expect(startState).not.toEqual(settledMarkupState);
        expect(endState).toEqual(settledMarkupState);
        expect(replayedEndState).toEqual(settledMarkupState);
      });

      it("renders every recreation text at a readable size on a phone stage", () => {
        // Arrange
        const root = mountScene(sceneId, phoneStage);
        const timeline = buildMountedScene(sceneId, root, 1);
        const undersizedTexts = new Set<string>();

        // Act: every label's beat, since collapsed elements render later.
        for (const labelTime of [...Object.values(timeline.labels), timeline.duration()]) {
          timeline.time(labelTime + keyElementDeadlineSeconds);
          for (const { text, sizePx } of renderedTextFontSizes(root)) {
            if (sizePx < minimumPhoneFontSizePx) {
              undersizedTexts.add(`${text} (${String(sizePx)}px)`);
            }
          }
        }

        // Assert
        expect(renderedTextFontSizes(root).length).toBeGreaterThan(5);
        expect(Array.from(undersizedTexts)).toEqual([]);
      });

      for (const [stageName, stage] of [
        ["desktop", desktopStage],
        ["phone", phoneStage],
      ] as const) {
        it(`shows each beat's key element within half a second of its label on ${stageName}`, () => {
          // Arrange
          const root = mountScene(sceneId, stage);
          const timeline = buildMountedScene(sceneId, root, 1);
          const steps = resolveSceneModule(sceneId)?.steps ?? [];

          // Act
          const visibilityByStep = steps.map((step) => {
            const keyPart = sceneStepKeyParts[sceneId][step.stepId];
            const keyElement =
              keyPart === undefined ? null : root.querySelector(scenePartSelector(keyPart));
            timeline.time((timeline.labels[step.timelineLabel] ?? 0) + keyElementDeadlineSeconds);
            return `${step.stepId}: ${
              keyElement === null ? "no key element" : describeVisibility(root, keyElement)
            }`;
          });

          // Assert
          expect(steps.length).toBeGreaterThan(0);
          expect(visibilityByStep).toEqual(steps.map((step) => `${step.stepId}: visible`));
        });
      }

      it("stays beneath a host layer painted over it, as the real-capture proof is", () => {
        // Arrange: the host stacks an opaque layer after the scene, like ChapterStage's proof.
        const root = mountScene(sceneId, phoneStage);
        const timeline = buildMountedScene(sceneId, root, 1);
        timeline.progress(1);
        const stageElement = root.parentElement;
        if (stageElement === null) {
          throw new Error("Mounted scene has no stage");
        }
        stageElement.style.position = "relative";
        const hostLayer = document.createElement("div");
        hostLayer.style.cssText = "position:absolute;inset:0;background:#000";
        stageElement.append(hostLayer);
        const stageBounds = stageElement.getBoundingClientRect();

        // Act
        const probePoints = [0.25, 0.5, 0.75].flatMap((xFraction) =>
          [0.25, 0.5, 0.75].map((yFraction) =>
            document.elementFromPoint(
              stageBounds.left + stageBounds.width * xFraction,
              stageBounds.top + stageBounds.height * yFraction,
            ),
          ),
        );

        // Assert
        expect(probePoints.every((element) => element === hostLayer)).toBe(true);
      });

      it("shows fewer panes in the phone crop than on desktop", () => {
        // Arrange
        const desktopRoot = mountScene(sceneId, desktopStage);
        const phoneRoot = mountScene(sceneId, phoneStage);

        // Act
        const phoneHiddenElements = Array.from(
          phoneRoot.querySelectorAll<HTMLElement>(`[${kitPhoneAttribute}="hidden"]`),
        );

        // Assert
        expect(phoneHiddenElements.length).toBeGreaterThan(0);
        expect(
          phoneHiddenElements.every((element) => element.getBoundingClientRect().width === 0),
        ).toBe(true);
        expect(countRenderedPanes(phoneRoot)).toBeLessThanOrEqual(countRenderedPanes(desktopRoot));
        expect(countRenderedPanes(phoneRoot)).toBeGreaterThan(0);
      });
    });
  }
});
