import { gsap } from "gsap";
import { afterEach, beforeAll, describe, expect, inject, it, vi } from "vitest";
import { commands, page } from "vitest/browser";

// The registry module also declares `window.AgentStudioScenes`, which scene.js fills.
import type { RegisteredSceneBundle } from "../scripts/scene-bundles/scene-bundle-registry.ts";
import { sceneIds } from "../src/motion-scenes/scene-contract";
import { resolveSceneModule } from "../src/motion-scenes/scene-registry";
import { kitPhoneAttribute } from "../src/recreation-kit/recreation-kit-dom";
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

function hasNonWhitespaceDirectText(element: Element): boolean {
  return Array.from(element.childNodes).some(
    (childNode) =>
      childNode.nodeType === Node.TEXT_NODE && (childNode.textContent ?? "").trim().length > 0,
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

    timeline.time(0.17);
    expect(Number(gsap.getProperty(commandBar, "opacity"))).toBe(0);
    expect(
      paneTextContainers.every((pane) => !pane.hasAttribute("data-layout-allow-occlusion")),
    ).toBe(true);
    expect(coveredRightLine?.hasAttribute("data-layout-allow-overlap")).toBe(false);
    timeline.time(0.8);
    expect(Number(gsap.getProperty(commandBar, "opacity"))).toBeGreaterThan(0);
    expect(
      paneTextContainers.every((pane) => pane.hasAttribute("data-layout-allow-occlusion")),
    ).toBe(true);
    expect(coveredRightLine?.hasAttribute("data-layout-allow-overlap")).toBe(true);
    timeline.time(2.8);
    expect(
      paneTextContainers.every((pane) => pane.hasAttribute("data-layout-allow-occlusion")),
    ).toBe(true);
    timeline.time(3.1);
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
        timeline.time(time);
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
