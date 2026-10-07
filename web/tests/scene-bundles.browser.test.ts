import { gsap } from "gsap";
import { afterEach, beforeAll, describe, expect, inject, it, vi } from "vitest";
import { commands, page } from "vitest/browser";

// The registry module also declares `window.AgentStudioScenes`, which scene.js fills.
import type { RegisteredSceneBundle } from "../scripts/scene-bundles/scene-bundle-registry.ts";
import { sceneIds } from "../src/motion-scenes/scene-contract";
import { resolveSceneModule } from "../src/motion-scenes/scene-registry";
import { contextWithTaskPhoneDrawerScrollPixels } from "../src/motion-scenes/scenes/chapter-context-with-task/chapter-context-with-task-fixture";
import { hasNonWhitespaceDirectText } from "../src/motion-scenes/scenes/scene-text-leaves";
import { kitPhoneAttribute } from "../src/recreation-kit/recreation-kit-dom";
import { recreationKitPhoneMaxWidthPx } from "../src/recreation-kit/recreation-kit-phone-breakpoint";
import { observeQuickFindScene } from "./quickfind-scene-observation";
import type { BuiltSceneBundleFiles } from "./scene-bundle-browser-command.ts";

declare module "vitest/browser" {
  interface BrowserCommands {
    buildSceneBundlesForBrowserTest(): Promise<readonly BuiltSceneBundleFiles[]>;
  }
}

interface ManifestReading {
  readonly sceneId: string;
  readonly websiteRevision: string;
  readonly durationSeconds: number;
  readonly labels: Readonly<Record<string, number>>;
  readonly stage: { readonly width: number; readonly height: number };
  readonly phoneBreakpoint: { readonly containerName: string; readonly maxWidthPx: number };
  readonly seed: number;
  readonly sha256: Readonly<Record<string, string>>;
}

interface SceneBundleUnderTest {
  readonly sceneJs: string;
  readonly sceneHtml: string;
  readonly sceneCss: string;
  readonly manifest: ManifestReading;
}

// Building runs the production Astro build and headless Chrome; this bounds a
// hang, it is not a speed budget.
const bundleBuildHangBoundMs = 240_000;

let bundlesBySceneId: ReadonlyMap<string, SceneBundleUnderTest>;
let sceneScriptFindingsBySceneId: ReadonlyMap<string, readonly string[]>;
const mountedElements: Element[] = [];

function requireBuiltFindings(sceneId: string): readonly string[] {
  const findings = sceneScriptFindingsBySceneId.get(sceneId);
  if (findings === undefined) {
    throw new Error(`No scene.js audit for ${sceneId}`);
  }
  return findings;
}

function isRecord(value: unknown): value is Readonly<Record<string, unknown>> {
  return typeof value === "object" && value !== null;
}

function isRecordOf<TValue>(
  value: unknown,
  isEntryValue: (entryValue: unknown) => entryValue is TValue,
): value is Readonly<Record<string, TValue>> {
  return isRecord(value) && Object.values(value).every(isEntryValue);
}

const isNumber = (value: unknown): value is number => typeof value === "number";
const isString = (value: unknown): value is string => typeof value === "string";

function isManifestReading(value: unknown): value is ManifestReading {
  if (!isRecord(value)) {
    return false;
  }
  const { stage, phoneBreakpoint } = value;
  return (
    isString(value["sceneId"]) &&
    isString(value["websiteRevision"]) &&
    isNumber(value["durationSeconds"]) &&
    isNumber(value["seed"]) &&
    isRecordOf(value["labels"], isNumber) &&
    isRecordOf(value["sha256"], isString) &&
    isRecord(stage) &&
    isNumber(stage["width"]) &&
    isNumber(stage["height"]) &&
    isRecord(phoneBreakpoint) &&
    isString(phoneBreakpoint["containerName"]) &&
    isNumber(phoneBreakpoint["maxWidthPx"])
  );
}

function readManifest(manifestText: string): ManifestReading {
  const manifest: unknown = JSON.parse(manifestText);
  if (!isManifestReading(manifest)) {
    throw new Error(`Malformed scene bundle manifest: ${manifestText}`);
  }
  return manifest;
}

const roundToQuarter = (value: number): number => Math.round(value * 4) / 4;

function phoneHiddenWidths(root: HTMLElement): readonly number[] {
  return Array.from(root.querySelectorAll(`[${kitPhoneAttribute}="hidden"]`), (element) =>
    Math.round(element.getBoundingClientRect().width),
  );
}

function directTextContent(element: Element): string {
  return Array.from(element.childNodes)
    .filter((childNode) => childNode.nodeType === Node.TEXT_NODE)
    .map((childNode) => childNode.textContent ?? "")
    .join("")
    .trim();
}

function requireBundle(sceneId: string): SceneBundleUnderTest {
  const bundle = bundlesBySceneId.get(sceneId);
  if (bundle === undefined) {
    throw new Error(`No scene bundle was emitted for ${sceneId}`);
  }
  return bundle;
}

async function sha256Hex(fileText: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(fileText));
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function mountStyle(cssText: string): void {
  const style = document.createElement("style");
  style.textContent = cssText;
  document.head.append(style);
  mountedElements.push(style);
}

function mountStage(markup: string, width: number, height: number): HTMLElement {
  const stage = document.createElement("div");
  stage.style.width = `${String(width)}px`;
  stage.style.height = `${String(height)}px`;
  stage.style.container = "recreation-kit / inline-size";
  stage.innerHTML = markup;
  document.body.append(stage);
  mountedElements.push(stage);
  const root = stage.firstElementChild;
  if (!(root instanceof HTMLElement)) {
    throw new Error("scene.html has no root element");
  }
  return root;
}

function runClassicScript(scriptText: string): void {
  const script = document.createElement("script");
  script.textContent = scriptText;
  document.head.append(script);
  script.remove();
}

/** Every style rule in a stylesheet, including those inside grouping rules. */
function collectStyleRules(rules: CSSRuleList): readonly CSSStyleRule[] {
  return Array.from(rules).flatMap((rule): readonly CSSStyleRule[] => {
    if (rule instanceof CSSStyleRule) {
      return [rule];
    }
    return rule instanceof CSSGroupingRule ? collectStyleRules(rule.cssRules) : [];
  });
}

function collectRuleTypeNames(rules: CSSRuleList): readonly string[] {
  const typeNames: string[] = [];
  for (const rule of Array.from(rules)) {
    typeNames.push(rule.constructor.name);
    if (rule instanceof CSSGroupingRule && !(rule instanceof CSSStyleRule)) {
      typeNames.push(...collectRuleTypeNames(rule.cssRules));
    }
  }
  return typeNames;
}

const leakCheckedProperties = [
  "display",
  "position",
  "box-sizing",
  "margin-top",
  "padding-top",
  "border-top-width",
  "color",
  "background-color",
  "font-family",
  "font-size",
  "line-height",
  "opacity",
  "visibility",
] as const;

function snapshotComputedStyles(elements: readonly Element[]): readonly string[] {
  return elements.map((element) => {
    const computedStyle = getComputedStyle(element);
    return leakCheckedProperties
      .map((property) => `${property}=${computedStyle.getPropertyValue(property)}`)
      .join(" ");
  });
}

// Computed values that decide what a frame shows; layout is checked through each
// element's box relative to the scene root.
const renderedProperties = [
  "display",
  "position",
  "box-sizing",
  "margin-top",
  "margin-left",
  "padding-top",
  "padding-left",
  "border-top-width",
  "border-top-color",
  "border-top-left-radius",
  "color",
  "background-color",
  "font-family",
  "font-size",
  "font-weight",
  "line-height",
  "letter-spacing",
  "white-space",
  "opacity",
  "visibility",
  "transform",
  "translate",
  "clip-path",
  "overflow-x",
  "flex-grow",
  "grid-template-rows",
  "container-name",
] as const;

let websiteStylesheets: readonly string[] | undefined;

/** The dev server's `/` styles: the website's own CSS for the same components. */
async function loadWebsiteStylesheets(): Promise<readonly string[]> {
  if (websiteStylesheets !== undefined) {
    return websiteStylesheets;
  }
  const pageUrl = new URL("/", inject("siteHeaderBrowserTestUrl"));
  // Chrome refuses this page's fetch to the 127.0.0.1 spelling of the loopback
  // server; the test page's own host name reaches the same server.
  pageUrl.hostname = location.hostname;
  const response = await fetch(pageUrl);
  if (!response.ok) {
    throw new Error(`Website page answered ${String(response.status)}`);
  }
  const page = new DOMParser().parseFromString(await response.text(), "text/html");
  websiteStylesheets = Array.from(
    page.querySelectorAll("head style"),
    (style) => style.textContent,
  );
  return websiteStylesheets;
}

/** Renders scene markup under only the given CSS, in its own document. */
function renderInFrame(
  stylesheets: readonly string[],
  markup: string,
  width: number,
  height: number,
): readonly string[] {
  const frame = document.createElement("iframe");
  frame.style.width = `${String(width)}px`;
  frame.style.height = `${String(height)}px`;
  frame.style.border = "0";
  document.body.append(frame);
  mountedElements.push(frame);
  const frameDocument = frame.contentDocument;
  if (frameDocument === null) {
    throw new Error("Rendering frame has no document");
  }
  for (const stylesheet of stylesheets) {
    const style = frameDocument.createElement("style");
    style.textContent = stylesheet;
    frameDocument.head.append(style);
  }
  frameDocument.body.style.margin = "0";
  const stage = frameDocument.createElement("div");
  stage.style.width = `${String(width)}px`;
  stage.style.height = `${String(height)}px`;
  stage.innerHTML = markup;
  frameDocument.body.append(stage);
  const root = stage.firstElementChild;
  if (root === null) {
    throw new Error("scene.html has no root element");
  }
  const rootBounds = root.getBoundingClientRect();
  const frameWindow = frameDocument.defaultView ?? window;
  return [root, ...Array.from(root.querySelectorAll("*"))].map((element, index) => {
    const computedStyle = frameWindow.getComputedStyle(element);
    const bounds = element.getBoundingClientRect();
    const box = [
      bounds.left - rootBounds.left,
      bounds.top - rootBounds.top,
      bounds.width,
      bounds.height,
    ].map(roundToQuarter);
    return [
      `${String(index)} <${element.tagName.toLowerCase()} class="${element.getAttribute("class") ?? ""}">`,
      `box=${box.join(",")}`,
      ...renderedProperties.map(
        (property) => `${property}=${computedStyle.getPropertyValue(property)}`,
      ),
    ].join(" ");
  });
}

describe("scene bundles for HyperFrames", () => {
  beforeAll(async () => {
    const builtBundles = await commands.buildSceneBundlesForBrowserTest();
    sceneScriptFindingsBySceneId = new Map(
      builtBundles.map((builtBundle) => [builtBundle.sceneId, builtBundle.sceneScriptFindings]),
    );
    bundlesBySceneId = new Map(
      builtBundles.map((builtBundle): [string, SceneBundleUnderTest] => [
        builtBundle.sceneId,
        {
          sceneJs: builtBundle.files["scene.js"] ?? "",
          sceneHtml: builtBundle.files["scene.html"] ?? "",
          sceneCss: builtBundle.files["scene.css"] ?? "",
          manifest: readManifest(builtBundle.files["manifest.json"] ?? ""),
        },
      ]),
    );
  }, bundleBuildHangBoundMs);

  afterEach(() => {
    for (const element of mountedElements.splice(0)) {
      element.remove();
    }
    delete window.AgentStudioScenes;
  });

  it("renders GSAP function-property waivers during suppressed seeks and revert", () => {
    const element = document.createElement("span");
    let waiverState = 0;
    const proxy = {
      waiver(value?: number): number {
        if (value !== undefined) {
          waiverState = value;
          if (value >= 0.5) {
            element.setAttribute("data-layout-allow-overlap", "");
          } else {
            element.removeAttribute("data-layout-allow-overlap");
          }
        }
        return waiverState;
      },
    };
    const timeline = gsap.timeline({ paused: true });
    try {
      timeline.set(proxy, { waiver: 1 }, 1);
      timeline.set(proxy, { waiver: 0 }, 3);
      timeline.to({}, { duration: 1 }, 3);
      timeline.seek(2);
      expect(element.hasAttribute("data-layout-allow-overlap")).toBe(true);
      timeline.pause(0);
      expect(element.hasAttribute("data-layout-allow-overlap")).toBe(false);
      timeline.seek(4);
      expect(element.hasAttribute("data-layout-allow-overlap")).toBe(false);
      timeline.seek(2);
      expect(element.hasAttribute("data-layout-allow-overlap")).toBe(true);
      timeline.revert();
      expect(element.hasAttribute("data-layout-allow-overlap")).toBe(false);
    } finally {
      timeline.revert();
      timeline.kill();
    }
  });

  it.each([
    {
      sceneId: "chapter-context-with-task",
      coveredTime: 6,
      label: "task-drawers",
      terminalSelector: '[data-scene-part="agent-terminal"]',
    },
    {
      sceneId: "chapter-many-agents",
      coveredTime: 4,
      label: "parallel-agents",
      terminalSelector: '[data-scene-part="left-terminal"]',
    },
    {
      sceneId: "chapter-find-and-focus",
      coveredTime: 2,
      label: "quick-find",
      terminalSelector: ".kit-pane-grid .kit-terminal",
    },
  ])(
    "restores $sceneId waivers through real host replay calls",
    ({ sceneId, coveredTime, label, terminalSelector }) => {
      const bundle = requireBundle(sceneId);
      mountStyle(bundle.sceneCss);
      const root = mountStage(bundle.sceneHtml, 600, bundle.manifest.stage.height);
      runClassicScript(bundle.sceneJs);
      const timeline = gsap.timeline({ paused: true });
      try {
        window.AgentStudioScenes?.[sceneId]?.buildScene(root, timeline, {
          width: 600,
          height: bundle.manifest.stage.height,
          seed: bundle.manifest.seed,
        });
        const terminals = [...root.querySelectorAll<HTMLElement>(terminalSelector)];
        const leaves = terminals.flatMap((terminal) =>
          [...terminal.querySelectorAll<HTMLElement>("*")].filter(hasNonWhitespaceDirectText),
        );
        expect(terminals.length).toBeGreaterThan(0);
        expect(leaves.length).toBeGreaterThan(0);
        const assertWaivers = (expected: boolean): void => {
          for (const terminal of terminals) {
            expect.soft(terminal.hasAttribute("data-layout-allow-occlusion")).toBe(expected);
          }
          for (const leaf of leaves) {
            expect.soft(leaf.hasAttribute("data-layout-allow-overlap")).toBe(expected);
          }
        };
        timeline.seek(coveredTime);
        assertWaivers(true);
        timeline.pause(0);
        assertWaivers(false);
        timeline.seek(coveredTime);
        assertWaivers(true);
        timeline.play(label);
        assertWaivers(false);
        timeline.pause();
        timeline.seek(coveredTime);
        assertWaivers(true);
        timeline.restart();
        assertWaivers(false);
        timeline.pause();
        timeline.seek(coveredTime);
        assertWaivers(true);
        timeline.revert();
        assertWaivers(false);
      } finally {
        timeline.revert();
        timeline.kill();
      }
    },
  );

  it.each([
    ["chapter-review", { "review-diff": 0, "review-comment": 1.65 }],
    ["chapter-come-back", { "quit-in-flight": 0, persistence: 2.15 }],
  ] as const)("publishes the split %s labels at unchanged animation times", (sceneId, labels) => {
    expect(requireBundle(sceneId).manifest.labels).toEqual(labels);
    expect(requireBundle(sceneId).manifest.durationSeconds).toBe(8);
  });

  it.each([600, 1280])(
    "shows the selected pane search result before quick-find jumps at %ipx",
    async (stageWidth) => {
      const bundle = requireBundle("chapter-find-and-focus");
      await page.viewport(stageWidth, bundle.manifest.stage.height);
      mountStyle(bundle.sceneCss);
      const root = mountStage(bundle.sceneHtml, stageWidth, bundle.manifest.stage.height);
      runClassicScript(bundle.sceneJs);
      const timeline = gsap.timeline({ paused: true });
      try {
        window.AgentStudioScenes?.["chapter-find-and-focus"]?.buildScene(root, timeline, {
          width: stageWidth,
          height: bundle.manifest.stage.height,
          seed: bundle.manifest.seed,
        });
        const samples = [];
        for (let index = 5; index <= 25; index += 1) {
          const time = index / 10;
          timeline.time(time);
          samples.push(observeQuickFindScene(root, time));
        }
        const selected = samples.filter(
          (sample) =>
            sample.query === "tool" &&
            sample.paneVisible &&
            sample.paneSelected &&
            !sample.recentVisible,
        );
        expect(selected.length).toBeGreaterThan(0);
        expect
          .soft((selected.at(-1)?.time ?? 0) - (selected[0]?.time ?? 0))
          .toBeGreaterThanOrEqual(0.6 - 0.000001);
        expect.soft(samples.find((sample) => sample.time === 0.8)?.shortcutVisible).toBe(true);
        expect.soft(selected.every((sample) => sample.subtitleVisible)).toBe(true);
        expect
          .soft(
            samples
              .filter((sample) => sample.query !== "")
              .every((sample) => !sample.recentVisible),
          )
          .toBe(true);
      } finally {
        timeline.revert();
        timeline.kill();
      }
    },
  );

  it.each([600, 1280])(
    "uses native quick-find pane anatomy before the focus jump at %ipx",
    (stageWidth) => {
      const bundle = requireBundle("chapter-find-and-focus");
      mountStyle(bundle.sceneCss);
      const root = mountStage(bundle.sceneHtml, stageWidth, bundle.manifest.stage.height);
      runClassicScript(bundle.sceneJs);
      const timeline = gsap.timeline({ paused: true });
      try {
        window.AgentStudioScenes?.["chapter-find-and-focus"]?.buildScene(root, timeline, {
          width: stageWidth,
          height: bundle.manifest.stage.height,
          seed: bundle.manifest.seed,
        });
        timeline.time(2);
        const selected = observeQuickFindScene(root, 2);
        expect.soft(selected.paneTitle).toBe("Terminal — tool-portal");
        expect.soft(selected.paneSubtitle).toBe("parallel work · Tab 1 · Pane 2 · Active");
        expect(selected).toMatchObject({
          query: "tool",
          paneVisible: true,
          paneSelected: true,
          subtitleVisible: true,
          recentVisible: false,
          shortcutVisible: true,
        });
        expect(
          root.querySelector('[data-scene-part="pane-results"] .kit-command-bar__section')
            ?.textContent,
        ).toBe("PANES");
        const focusRing = root.querySelector('[data-scene-part="target-focus-ring"]');
        expect(Number(gsap.getProperty(focusRing, "opacity"))).toBe(0);
        timeline.time(3.4);
        expect(Number(gsap.getProperty(focusRing, "opacity"))).toBeGreaterThan(0.9);
        const activityLineTextElements = [
          ...root.querySelectorAll<HTMLElement>(".kit-pane-grid .kit-terminal__line--activity *"),
        ].filter(hasNonWhitespaceDirectText);
        expect(activityLineTextElements.length).toBeGreaterThan(0);
        timeline.time(2.8);
        expect(
          activityLineTextElements.every((element) =>
            element.hasAttribute("data-layout-allow-overlap"),
          ),
        ).toBe(true);
        timeline.time(3.1);
        expect(
          activityLineTextElements.every(
            (element) => !element.hasAttribute("data-layout-allow-overlap"),
          ),
        ).toBe(true);
      } finally {
        timeline.revert();
        timeline.kill();
      }
    },
  );

  it("keeps the quick-find overlay behind the settled panes and scopes its text occlusion", () => {
    const bundle = requireBundle("chapter-find-and-focus");
    const { width, height } = bundle.manifest.stage;
    mountStyle(bundle.sceneCss);
    const root = mountStage(bundle.sceneHtml, width, height);
    runClassicScript(bundle.sceneJs);
    const timeline = gsap.timeline({ paused: true });
    window.AgentStudioScenes?.["chapter-find-and-focus"]?.buildScene(root, timeline, {
      width,
      height,
      seed: bundle.manifest.seed,
    });
    const commandBar = root.querySelector<HTMLElement>('[data-scene-part="command-bar"]');
    const paneTextContainers = [
      ...root.querySelectorAll<HTMLElement>(".kit-pane-grid .kit-terminal"),
    ];
    expect(paneTextContainers).toHaveLength(3);
    const coveredRightLine = root.querySelector<HTMLElement>(
      '.kit-pane-grid > .kit-pane:last-child [data-line="5"] [data-kit-typed]',
    );

    timeline.seek(0.17);
    expect(Number(gsap.getProperty(commandBar, "opacity"))).toBe(0);
    expect(
      paneTextContainers.every((pane) => !pane.hasAttribute("data-layout-allow-occlusion")),
    ).toBe(true);
    expect(coveredRightLine?.hasAttribute("data-layout-allow-overlap")).toBe(false);
    timeline.seek(0.8);
    expect(Number(gsap.getProperty(commandBar, "opacity"))).toBeGreaterThan(0);
    expect(
      paneTextContainers.every((pane) => pane.hasAttribute("data-layout-allow-occlusion")),
    ).toBe(true);
    expect(coveredRightLine?.hasAttribute("data-layout-allow-overlap")).toBe(true);
    timeline.seek(2.8);
    expect(
      paneTextContainers.every((pane) => pane.hasAttribute("data-layout-allow-occlusion")),
    ).toBe(true);
    timeline.seek(3.1);
    expect(
      paneTextContainers.every((pane) => !pane.hasAttribute("data-layout-allow-occlusion")),
    ).toBe(true);
    expect(coveredRightLine?.hasAttribute("data-layout-allow-overlap")).toBe(false);
    timeline.revert();
    timeline.kill();
  });

  it.each([600, 1280])(
    "marks every find-and-focus terminal text element as an allowed overlap only while the bar is open at %ipx",
    (stageWidth) => {
      const bundle = requireBundle("chapter-find-and-focus");
      mountStyle(bundle.sceneCss);
      const root = mountStage(bundle.sceneHtml, stageWidth, bundle.manifest.stage.height);
      runClassicScript(bundle.sceneJs);
      const timeline = gsap.timeline({ paused: true });
      window.AgentStudioScenes?.["chapter-find-and-focus"]?.buildScene(root, timeline, {
        width: stageWidth,
        height: bundle.manifest.stage.height,
        seed: bundle.manifest.seed,
      });

      const terminalTextElements = [
        ...root.querySelectorAll<HTMLElement>(".kit-pane-grid .kit-terminal *"),
      ].filter(hasNonWhitespaceDirectText);
      const coveredLeaseText = terminalTextElements.find(
        (element) => directTextContent(element) === "Reading src/lease.ts",
      );
      expect(terminalTextElements.length).toBeGreaterThan(0);
      expect(coveredLeaseText).toBeDefined();

      for (const [time, expected] of [
        [0.3, false],
        [0.6, true],
        [1.7, true],
        [2.9, true],
        [3.1, false],
        [1.7, true],
        [0.3, false],
      ] as const) {
        timeline.seek(time);
        expect(
          terminalTextElements.every((element) =>
            element.hasAttribute("data-layout-allow-overlap"),
          ),
          `every terminal text element at ${stageWidth}px, t=${time}`,
        ).toBe(expected);
        expect(
          coveredLeaseText?.hasAttribute("data-layout-allow-overlap"),
          `lease typed text span itself at ${stageWidth}px, t=${time}`,
        ).toBe(expected);
      }
      timeline.revert();
      timeline.kill();
    },
  );

  it.each(sceneIds)("keeps the %s CSS phone breakpoint aligned with scene logic", (sceneId) => {
    expect(requireBundle(sceneId).manifest.phoneBreakpoint.maxWidthPx).toBe(
      recreationKitPhoneMaxWidthPx,
    );
  });

  it.each([
    { width: 330, height: 412 },
    { width: 1100, height: 688 },
    { width: 1280, height: 800 },
  ])(
    "keeps the newest drawer output inside the visible bottom at $width x $height",
    ({ width, height }) => {
      const bundle = requireBundle("chapter-context-with-task");
      mountStyle(bundle.sceneCss);
      const root = mountStage(bundle.sceneHtml, width, height);
      const settledDrawerScroll = getComputedStyle(
        root.querySelector<HTMLElement>('[data-scene-part="drawer-terminal"]') ?? root,
      )
        .getPropertyValue("--scene-drawer-scroll")
        .trim();
      runClassicScript(bundle.sceneJs);
      const timeline = gsap.timeline({ paused: true });
      try {
        window.AgentStudioScenes?.["chapter-context-with-task"]?.buildScene(root, timeline, {
          width,
          height,
          seed: bundle.manifest.seed,
        });
        const drawerBody = root.querySelector<HTMLElement>(".kit-drawer__body");
        const terminal = root.querySelector<HTMLElement>('[data-scene-part="drawer-terminal"]');
        const lastLine = terminal?.querySelector<HTMLElement>('[data-line="8"]');
        if (
          drawerBody === null ||
          terminal === null ||
          lastLine === undefined ||
          lastLine === null
        ) {
          throw new Error("Missing drawer terminal or final cursor prompt");
        }
        if (width === 330) {
          expect(terminal.scrollHeight - terminal.clientHeight).toBe(
            contextWithTaskPhoneDrawerScrollPixels,
          );
          expect(settledDrawerScroll).toBe(String(contextWithTaskPhoneDrawerScrollPixels));
        }
        const statusLine = terminal.querySelector<HTMLElement>('[data-line="0"]');
        if (statusLine === null) {
          throw new Error("Missing initial Git status prompt");
        }
        timeline.seek(2.9);
        const preBeatBodyBounds = drawerBody.getBoundingClientRect();
        const preBeatStatusBounds = statusLine.getBoundingClientRect();
        expect(preBeatStatusBounds.top).toBeGreaterThanOrEqual(preBeatBodyBounds.top);
        expect(preBeatStatusBounds.bottom).toBeLessThanOrEqual(preBeatBodyBounds.bottom + 1);
        expect(getComputedStyle(statusLine).translate).toMatch(/0px(?: 0px)?|none/);
        timeline.seek(3.4);
        const scrollTranslation = getComputedStyle(statusLine).translate;
        if (width === 330) {
          expect(scrollTranslation).toContain("-88px");
        } else {
          expect(scrollTranslation).toMatch(/0px(?: 0px)?|none/);
        }
        timeline.seek(2.9);
        expect(getComputedStyle(statusLine).translate).toMatch(/0px(?: 0px)?|none/);
        timeline.restart();
        timeline.pause();
        expect(getComputedStyle(statusLine).translate).toMatch(/0px(?: 0px)?|none/);
        timeline.seek(2.9);
        const lastBottomBeforeScroll = lastLine.getBoundingClientRect().bottom;
        for (const time of [4.5, 8.4]) {
          timeline.seek(time);
          const bodyBounds = drawerBody.getBoundingClientRect();
          const lastBounds = lastLine.getBoundingClientRect();
          expect
            .soft(lastBounds.bottom, `final prompt bottom at t=${time}`)
            .toBeLessThanOrEqual(bodyBounds.bottom + 1);
          expect
            .soft(lastBounds.top, `final prompt top at t=${time}`)
            .toBeGreaterThanOrEqual(bodyBounds.top);
          if (width <= recreationKitPhoneMaxWidthPx) {
            const paddingBottom = Number.parseFloat(getComputedStyle(terminal).paddingBottom);
            expect
              .soft(bodyBounds.bottom - lastBounds.bottom, `final prompt at bottom edge, t=${time}`)
              .toBeLessThanOrEqual(paddingBottom + 1);
            for (const lineIndex of [6, 7]) {
              const outputLine = terminal.querySelector<HTMLElement>(`[data-line="${lineIndex}"]`);
              if (outputLine === null) {
                throw new Error("Missing Git log output");
              }
              const outputBounds = outputLine.getBoundingClientRect();
              expect.soft(outputBounds.top).toBeGreaterThanOrEqual(bodyBounds.top);
              expect.soft(outputBounds.bottom).toBeLessThanOrEqual(bodyBounds.bottom + 1);
            }
          } else if (time === 4.5) {
            expect
              .soft(
                Math.abs(lastBounds.bottom - lastBottomBeforeScroll),
                "fitting desktop content does not scroll",
              )
              .toBeLessThanOrEqual(1);
          }
        }
      } finally {
        timeline.revert();
        timeline.kill();
      }
    },
  );

  it.each([390, 1280])(
    "wraps drawer lines and scopes desktop editor overflow at %ipx",
    (stageWidth) => {
      const bundle = requireBundle("chapter-context-with-task");
      mountStyle(bundle.sceneCss);
      const root = mountStage(bundle.sceneHtml, stageWidth, bundle.manifest.stage.height);
      runClassicScript(bundle.sceneJs);
      const timeline = gsap.timeline({ paused: true });
      try {
        window.AgentStudioScenes?.["chapter-context-with-task"]?.buildScene(root, timeline, {
          width: stageWidth,
          height: bundle.manifest.stage.height,
          seed: bundle.manifest.seed,
        });
        const codeArea = root.querySelector<HTMLElement>(".kit-source-view__code");
        const drawerLines = [
          ...root.querySelectorAll<HTMLElement>(".kit-drawer .kit-terminal__line"),
        ];
        expect(codeArea).not.toBeNull();
        expect(drawerLines.length).toBeGreaterThan(0);
        for (const drawerLine of drawerLines) {
          expect.soft(getComputedStyle(drawerLine).whiteSpace).toBe("pre-wrap");
          expect.soft(getComputedStyle(drawerLine).overflowWrap).toBe("anywhere");
        }
        for (const [time, covering] of [
          [4.9, false],
          [5.2, true],
          [8.4, true],
          [4.9, false],
          [8.4, true],
          [0, false],
        ] as const) {
          timeline.seek(time);
          expect
            .soft(codeArea?.hasAttribute("data-layout-allow-occlusion"), `code at t=${time}`)
            .toBe(covering && stageWidth > recreationKitPhoneMaxWidthPx);
        }
        for (const replay of [
          (): void => {
            timeline.pause(0);
          },
          (): void => {
            timeline.play("task-drawers");
          },
          (): void => {
            timeline.restart();
          },
        ]) {
          timeline.seek(8.4);
          replay();
          expect(codeArea?.hasAttribute("data-layout-allow-occlusion")).toBe(false);
          timeline.pause();
        }
        if (stageWidth === 1280) {
          const drawerBody = root.querySelector<HTMLElement>(".kit-drawer__body");
          if (drawerBody === null) {
            throw new Error("Missing drawer body");
          }
          for (const time of [3.5, 8.4, 8.5]) {
            timeline.seek(time);
            const bodyBounds = drawerBody.getBoundingClientRect();
            for (const drawerLine of drawerLines) {
              expect(drawerLine.getBoundingClientRect().bottom).toBeLessThanOrEqual(
                bodyBounds.bottom + 1,
              );
            }
            for (const commandArguments of drawerBody.querySelectorAll<HTMLElement>(
              ".kit-terminal__command + .kit-terminal__preformatted",
            )) {
              expect(commandArguments.getBoundingClientRect().right).toBeLessThanOrEqual(
                bodyBounds.right + 1,
              );
            }
          }
        }
        timeline.seek(8.4);
        timeline.revert();
        expect(codeArea?.hasAttribute("data-layout-allow-occlusion")).toBe(false);
      } finally {
        timeline.revert();
        timeline.kill();
      }
    },
  );

  it.each([390, recreationKitPhoneMaxWidthPx, 1280])(
    "scopes context-with-task Files takeover markers and restores them on rewind at %ipx",
    (stageWidth) => {
      const bundle = requireBundle("chapter-context-with-task");
      mountStyle(bundle.sceneCss);
      const root = mountStage(bundle.sceneHtml, stageWidth, bundle.manifest.stage.height);
      runClassicScript(bundle.sceneJs);
      const timeline = gsap.timeline({ paused: true });
      try {
        window.AgentStudioScenes?.["chapter-context-with-task"]?.buildScene(root, timeline, {
          width: stageWidth,
          height: bundle.manifest.stage.height,
          seed: bundle.manifest.seed,
        });
        const agentTerminal = root.querySelector<HTMLElement>('[data-scene-part="agent-terminal"]');
        const drawerTerminal = root.querySelector<HTMLElement>(
          '[data-scene-part="drawer-terminal"]',
        );
        const footerBadges = root.querySelector<HTMLElement>(
          '[data-scene-part="agent-footer-badges"]',
        );
        const terminalTextElements = [
          ...root.querySelectorAll<HTMLElement>(".kit-pane .kit-terminal *"),
        ].filter(hasNonWhitespaceDirectText);
        expect(agentTerminal).not.toBeNull();
        expect(drawerTerminal).not.toBeNull();
        expect(footerBadges).not.toBeNull();
        expect(terminalTextElements.length).toBeGreaterThan(0);
        expect(
          terminalTextElements.some(
            (element) => directTextContent(element) === "Reading src/lease.ts",
          ),
        ).toBe(true);

        for (const [time, covering] of [
          [4.9, false],
          [5.1, true],
          [5.375, true],
          [6.139, true],
          [8.5, true],
          [4.9, false],
          [6.139, true],
          [0, false],
        ] as const) {
          timeline.seek(time);
          const phoneCovering = covering && stageWidth <= recreationKitPhoneMaxWidthPx;
          expect
            .soft(
              drawerTerminal?.hasAttribute("data-layout-allow-occlusion"),
              `drawer at t=${time}`,
            )
            .toBe(phoneCovering);
          expect
            .soft(agentTerminal?.hasAttribute("data-layout-allow-occlusion"), `agent at t=${time}`)
            .toBe(phoneCovering);
          expect
            .soft(footerBadges?.hasAttribute("data-layout-allow-occlusion"), `footer at t=${time}`)
            .toBe(phoneCovering);
          for (const element of terminalTextElements) {
            expect
              .soft(
                element.hasAttribute("data-layout-allow-overlap"),
                `${directTextContent(element)} at t=${time}`,
              )
              .toBe(phoneCovering);
          }
        }
      } finally {
        timeline.revert();
        timeline.kill();
      }
    },
  );

  it("clips context-with-task source code and drawer before their scene starts", () => {
    const bundle = requireBundle("chapter-context-with-task");
    mountStyle(bundle.sceneCss);
    const root = mountStage(bundle.sceneHtml, 1280, bundle.manifest.stage.height);
    const codeArea = root.querySelector<HTMLElement>(".kit-source-view__code");
    expect(codeArea).not.toBeNull();
    if (codeArea === null) {
      throw new Error("Missing source code area");
    }
    expect(getComputedStyle(codeArea).overflowX).toBe("clip");
    expect(getComputedStyle(codeArea).overflowY).toBe("clip");
    const drawerBody = root.querySelector<HTMLElement>(".kit-drawer__body");
    expect(drawerBody).not.toBeNull();
    if (drawerBody === null) {
      throw new Error("Missing drawer body");
    }
    expect(getComputedStyle(drawerBody).overflowX).toBe("clip");
    expect(getComputedStyle(drawerBody).overflowY).toBe("clip");
    expect(
      root.querySelector(
        ".kit-source-view [data-layout-allow-occlusion], .kit-source-view [data-layout-allow-overlap]",
      ),
    ).toBeNull();
  });

  it.each([390, recreationKitPhoneMaxWidthPx, 1280])(
    "scopes many-agents sidebar takeover markers and restores them on rewind at %ipx",
    (stageWidth) => {
      const bundle = requireBundle("chapter-many-agents");
      mountStyle(bundle.sceneCss);
      const root = mountStage(bundle.sceneHtml, stageWidth, bundle.manifest.stage.height);
      runClassicScript(bundle.sceneJs);
      const timeline = gsap.timeline({ paused: true });
      try {
        window.AgentStudioScenes?.["chapter-many-agents"]?.buildScene(root, timeline, {
          width: stageWidth,
          height: bundle.manifest.stage.height,
          seed: bundle.manifest.seed,
        });
        const terminal = root.querySelector<HTMLElement>('[data-scene-part="left-terminal"]');
        const footerBadges = root.querySelector<HTMLElement>(
          '[data-scene-part="left-pane"] .kit-badges',
        );
        const terminalTextElements = [
          ...root.querySelectorAll<HTMLElement>('[data-scene-part="left-terminal"] *'),
        ].filter(hasNonWhitespaceDirectText);
        expect(terminal).not.toBeNull();
        expect(footerBadges).not.toBeNull();
        expect(terminalTextElements.length).toBeGreaterThan(0);
        expect(
          terminalTextElements.some(
            (element) => directTextContent(element) === "Reading the sidebar list model",
          ),
        ).toBe(true);
        for (const [time, covering] of [
          [2.7, false],
          [2.9, true],
          [3.125, true],
          [4.875, true],
          [9, true],
          [2.7, false],
          [4.875, true],
          [0, false],
        ] as const) {
          timeline.seek(time);
          const phoneCovering = covering && stageWidth <= recreationKitPhoneMaxWidthPx;
          expect
            .soft(terminal?.hasAttribute("data-layout-allow-occlusion"), `terminal at t=${time}`)
            .toBe(phoneCovering);
          expect
            .soft(footerBadges?.hasAttribute("data-layout-allow-occlusion"), `footer at t=${time}`)
            .toBe(phoneCovering);
          for (const element of terminalTextElements) {
            expect
              .soft(
                element.hasAttribute("data-layout-allow-overlap"),
                `${directTextContent(element)} at t=${time}`,
              )
              .toBe(phoneCovering);
          }
          expect
            .soft(
              root.querySelector('[data-scene-part="right-terminal"] [data-layout-allow-overlap]'),
            )
            .toBeNull();
        }
        expect(
          [...root.querySelectorAll(".kit-sidebar__ellipsis")]
            .find((element) => element.textContent === "agent-studio.sidebar-grouping")
            ?.hasAttribute("data-layout-allow-overflow"),
        ).toBe(true);
      } finally {
        timeline.revert();
        timeline.kill();
      }
    },
  );

  it.each([600, 1280])(
    "renders the Review thread inline after line 49 with responsive file tree at %ipx",
    (stageWidth) => {
      const bundle = requireBundle("chapter-review");
      mountStyle(bundle.sceneCss);
      const root = mountStage(bundle.sceneHtml, stageWidth, bundle.manifest.stage.height);
      runClassicScript(bundle.sceneJs);
      const timeline = gsap.timeline({ paused: true });
      window.AgentStudioScenes?.["chapter-review"]?.buildScene(root, timeline, {
        width: stageWidth,
        height: bundle.manifest.stage.height,
        seed: bundle.manifest.seed,
      });

      const changedLine = root.querySelector<HTMLElement>(
        '[data-scene-part="review-changed-line"]',
      );
      const nextLine = [...root.querySelectorAll<HTMLElement>(".kit-diff-view__line")].find(
        (line) => line.querySelector(".kit-diff-view__number")?.textContent === "50",
      );
      const thread = root.querySelector<HTMLElement>('[data-scene-part="review-comment-thread"]');
      const threadSlot = thread?.closest<HTMLElement>(".kit-diff-view__annotation");
      const fileTree = root.querySelector<HTMLElement>(".kit-file-tree");
      expect(changedLine).not.toBeNull();
      expect(nextLine).toBeDefined();
      expect(thread).not.toBeNull();
      expect(threadSlot).not.toBeNull();
      expect(fileTree).not.toBeNull();
      expect(getComputedStyle(fileTree as HTMLElement).display).toBe(
        stageWidth === 600 ? "none" : "flex",
      );

      timeline.time(1.0);
      expect((threadSlot as HTMLElement).getBoundingClientRect().height).toBeLessThan(1);
      timeline.time(2.2);
      expect(changedLine?.nextElementSibling).toBe(threadSlot);
      expect((threadSlot as HTMLElement).getBoundingClientRect().top).toBeGreaterThanOrEqual(
        (changedLine as HTMLElement).getBoundingClientRect().bottom - 1,
      );
      expect((nextLine as HTMLElement).getBoundingClientRect().top).toBeGreaterThanOrEqual(
        (threadSlot as HTMLElement).getBoundingClientRect().bottom - 1,
      );
      expect(["absolute", "fixed"]).not.toContain(getComputedStyle(thread as HTMLElement).position);
      expect(thread?.textContent).toContain("1 comment");
      expect(thread?.textContent).toContain("Open");
      expect(thread?.querySelector(".scene-review__avatar")?.textContent).toBe("Y");
      expect(thread?.querySelector(".scene-review__metadata strong")?.textContent).toBe("You");
      expect(thread?.textContent).toContain("2m");
      expect(thread?.textContent).toContain("Keep the comparison dated.");
      expect(thread?.textContent).toContain("The current.md pin can stay brief.");
      expect(thread?.textContent).toContain("Reply");
      expect(thread?.textContent).toContain("Resolve");
      const bodyFontSize = Number.parseFloat(
        getComputedStyle(thread?.querySelector("p") as HTMLElement).fontSize,
      );
      const diffFontSize = Number.parseFloat(getComputedStyle(changedLine as HTMLElement).fontSize);
      const metadataFontSize = Number.parseFloat(
        getComputedStyle(thread?.querySelector(".scene-review__metadata") as HTMLElement).fontSize,
      );
      expect(bodyFontSize / diffFontSize).toBeGreaterThanOrEqual(0.9);
      expect(bodyFontSize / diffFontSize).toBeLessThanOrEqual(1.05);
      expect(metadataFontSize).toBeLessThan(bodyFontSize);
      timeline.time(1.0);
      expect((threadSlot as HTMLElement).getBoundingClientRect().height).toBeLessThan(1);
      timeline.revert();
      timeline.kill();
    },
  );

  it("marks only the truthful truncated sidebar label as allowed overflow", () => {
    const bundle = requireBundle("chapter-many-agents");
    const { width, height } = bundle.manifest.stage;
    mountStyle(bundle.sceneCss);
    const root = mountStage(bundle.sceneHtml, width, height);
    runClassicScript(bundle.sceneJs);
    const timeline = gsap.timeline({ paused: true });
    window.AgentStudioScenes?.["chapter-many-agents"]?.buildScene(root, timeline, {
      width,
      height,
      seed: bundle.manifest.seed,
    });
    const labels = [...root.querySelectorAll(".kit-sidebar__ellipsis")];
    const grouping = labels.find((label) => label.textContent === "agent-studio.sidebar-grouping");
    expect(grouping?.hasAttribute("data-layout-allow-overflow")).toBe(true);
    expect(labels.filter((label) => label.hasAttribute("data-layout-allow-overflow"))).toEqual([
      grouping,
    ]);
    timeline.revert();
    timeline.kill();
  });

  it("emits exactly one bundle folder per scene", () => {
    // Arrange / Act
    const emittedSceneIds = Array.from(bundlesBySceneId.keys()).toSorted();

    // Assert
    expect(emittedSceneIds).toEqual([...sceneIds].toSorted());
  });

  for (const sceneId of sceneIds) {
    describe(sceneId, () => {
      it("pins its three files by the sha256 recorded in the manifest", async () => {
        // Arrange
        const bundle = requireBundle(sceneId);

        // Act
        const actualHashes = {
          "scene.js": await sha256Hex(bundle.sceneJs),
          "scene.html": await sha256Hex(bundle.sceneHtml),
          "scene.css": await sha256Hex(bundle.sceneCss),
        };

        // Assert
        expect(bundle.manifest.sceneId).toBe(sceneId);
        expect(bundle.manifest.websiteRevision).toMatch(/^[0-9a-f]{40}$/);
        expect(actualHashes).toEqual(bundle.manifest.sha256);
      });

      it("labels its timeline with the scene's declared steps, in order", () => {
        // Arrange
        const bundle = requireBundle(sceneId);

        // Act
        const labelNamesInTimeOrder = Object.entries(bundle.manifest.labels)
          .toSorted(([, firstTime], [, secondTime]) => firstTime - secondTime)
          .map(([labelName]) => labelName);

        // Assert
        expect(labelNamesInTimeOrder).toEqual(
          resolveSceneModule(sceneId)?.steps.map((step) => step.timelineLabel),
        );
      });

      it("registers a scene whose timeline matches the manifest when loaded as a classic script", () => {
        // Arrange
        const bundle = requireBundle(sceneId);
        const { width, height } = bundle.manifest.stage;
        mountStyle(bundle.sceneCss);
        const root = mountStage(bundle.sceneHtml, width, height);

        // Act
        runClassicScript(bundle.sceneJs);
        const registeredScene: RegisteredSceneBundle | undefined =
          window.AgentStudioScenes?.[sceneId];
        const timeline = gsap.timeline({ paused: true });
        registeredScene?.buildScene(root, timeline, { width, height, seed: bundle.manifest.seed });

        // Assert
        expect(root.getAttribute("data-scene-root")).toBe(sceneId);
        expect(registeredScene?.durationSeconds).toBe(bundle.manifest.durationSeconds);
        expect(registeredScene?.labels).toEqual(bundle.manifest.labels);
        expect(timeline.duration()).toBe(bundle.manifest.durationSeconds);
        expect(timeline.labels).toEqual(bundle.manifest.labels);
        timeline.revert();
        timeline.kill();
      });

      it("ships scene.js with no module imports and no network access", () => {
        // Arrange
        // Scene fixtures print source code, so "import" appears inside string
        // literals; the audit reads the syntax tree, not the text.
        const bundle = requireBundle(sceneId);
        const { width, height } = bundle.manifest.stage;
        mountStyle(bundle.sceneCss);
        const root = mountStage(bundle.sceneHtml, width, height);
        const fetchSpy = vi
          .spyOn(window, "fetch")
          .mockRejectedValue(new Error("scene.js must not fetch"));
        const xhrOpenSpy = vi
          .spyOn(XMLHttpRequest.prototype, "open")
          .mockImplementation((): void => undefined);

        // Act
        // oxlint-disable-next-line typescript/no-implied-eval -- parses the classic script without running it.
        const parseAsClassicScript = (): unknown => new Function(bundle.sceneJs);
        try {
          runClassicScript(bundle.sceneJs);
          const timeline = gsap.timeline({ paused: true });
          window.AgentStudioScenes?.[sceneId]?.buildScene(root, timeline, {
            width,
            height,
            seed: bundle.manifest.seed,
          });
          timeline.progress(0.5);
          timeline.progress(1);
          timeline.revert();
          timeline.kill();
        } finally {
          fetchSpy.mockRestore();
          xhrOpenSpy.mockRestore();
        }

        // Assert
        expect(parseAsClassicScript).not.toThrow();
        expect(requireBuiltFindings(sceneId)).toEqual([]);
        expect(fetchSpy).not.toHaveBeenCalled();
        expect(xhrOpenSpy).not.toHaveBeenCalled();
      });

      it("renders every element as the website's own stylesheets do", async () => {
        // Arrange
        const bundle = requireBundle(sceneId);
        const { width, height } = bundle.manifest.stage;

        // Act
        const bundleRendering = renderInFrame([bundle.sceneCss], bundle.sceneHtml, width, height);
        const pageRendering = renderInFrame(
          await loadWebsiteStylesheets(),
          bundle.sceneHtml,
          width,
          height,
        );

        // Assert
        expect(bundleRendering.length).toBeGreaterThan(20);
        expect(pageRendering.length).toBe(bundleRendering.length);
        expect(
          bundleRendering.flatMap((elementRendering, index) =>
            elementRendering === pageRendering[index]
              ? []
              : [`bundle ${elementRendering}\npage   ${pageRendering[index] ?? "missing"}`],
          ),
        ).toEqual([]);
      });

      it("scopes every selector in scene.css under the scene root", () => {
        // Arrange
        const bundle = requireBundle(sceneId);
        const sceneRoot = `[data-scene-root="${sceneId}"]`;
        const stylesheet = new CSSStyleSheet();
        stylesheet.replaceSync(bundle.sceneCss);

        // Act
        const styleRules = collectStyleRules(stylesheet.cssRules);
        const complexSelectors = styleRules.flatMap((rule) =>
          rule.selectorText.split(/,(?![^(]*\))/).map((selector) => selector.trim()),
        );

        // Assert
        expect(styleRules.length).toBeGreaterThan(20);
        expect(complexSelectors.filter((selector) => !selector.startsWith(sceneRoot))).toEqual([]);
        expect(
          collectRuleTypeNames(stylesheet.cssRules).filter(
            (typeName) =>
              ![
                "CSSStyleRule",
                "CSSMediaRule",
                "CSSContainerRule",
                "CSSSupportsRule",
                "CSSLayerBlockRule",
                "CSSLayerStatementRule",
              ].includes(typeName),
          ),
        ).toEqual([]);
      });

      it("leaves a copy of the scene outside its root unstyled", () => {
        // Arrange
        const bundle = requireBundle(sceneId);
        const { width, height } = bundle.manifest.stage;
        mountStage(bundle.sceneHtml, width, height);
        const decoyRoot = mountStage(bundle.sceneHtml, width, height);
        decoyRoot.removeAttribute("data-scene-root");
        const decoyElements = [decoyRoot, ...Array.from(decoyRoot.querySelectorAll("*"))];
        const unstyledDecoy = snapshotComputedStyles(decoyElements);

        // Act
        mountStyle(bundle.sceneCss);
        const decoyWithSceneCss = snapshotComputedStyles(decoyElements);

        // Assert
        expect(decoyElements.length).toBeGreaterThan(20);
        expect(decoyWithSceneCss).toEqual(unstyledDecoy);
      });

      it("fills its stage and switches to the phone crop at the manifest's breakpoint", () => {
        // Arrange
        const bundle = requireBundle(sceneId);
        const { maxWidthPx } = bundle.manifest.phoneBreakpoint;
        mountStyle(bundle.sceneCss);

        // Act
        const nativeRoot = mountStage(
          bundle.sceneHtml,
          bundle.manifest.stage.width,
          bundle.manifest.stage.height,
        );
        const phoneRoot = mountStage(bundle.sceneHtml, maxWidthPx, maxWidthPx * 0.625);
        const widerRoot = mountStage(bundle.sceneHtml, maxWidthPx + 1, (maxWidthPx + 1) * 0.625);

        // Assert
        expect(nativeRoot.clientWidth).toBe(bundle.manifest.stage.width);
        expect(nativeRoot.clientHeight).toBe(bundle.manifest.stage.height);
        expect(phoneHiddenWidths(phoneRoot).length).toBeGreaterThan(0);
        expect(phoneHiddenWidths(phoneRoot).every((elementWidth) => elementWidth === 0)).toBe(true);
        expect(phoneHiddenWidths(widerRoot).some((elementWidth) => elementWidth > 0)).toBe(true);
      });
    });
  }
});
