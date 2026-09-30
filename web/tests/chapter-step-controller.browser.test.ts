import { afterEach, describe, expect, it, vi } from "vitest";
import { page, userEvent } from "vitest/browser";

import { initializeChapterSteps } from "../src/chapters/chapter-step-controller";
import {
  chapterStepRequestedEventName,
  readChapterStepEventStepId,
} from "../src/chapters/chapter-step-events";
import { createScenePlayback } from "../src/home-page/scene-playback";
import type { SceneModule } from "../src/motion-scenes/scene-contract";

const fixtures: HTMLElement[] = [];
const stepIds = ["task-drawers", "git-context", "files"] as const;

function requiredHtmlElement(parent: ParentNode, selector: string): HTMLElement {
  const element = parent.querySelector(selector);
  if (!(element instanceof HTMLElement)) {
    throw new Error(`Chapter step fixture is missing required element: ${selector}`);
  }
  return element;
}

function requiredButton(parent: ParentNode, selector: string): HTMLButtonElement {
  const element = parent.querySelector(selector);
  if (!(element instanceof HTMLButtonElement)) {
    throw new Error(`Chapter step fixture is missing required button: ${selector}`);
  }
  return element;
}

// Mirrors ChapterSurface's static markup: the first step is shown, selectors are
// disabled and carry no tab semantics until the controller validates the DOM.
function createChapterStepsFixture(): HTMLElement {
  const fixture = document.createElement("div");
  fixture.innerHTML = `
    <section data-chapter-steps-root="context-with-task">
      <div data-chapter-step-line><svg data-chapter-step-ring><circle data-chapter-step-ring-progress /></svg><span data-chapter-step-pause-glyph hidden>❚❚</span><span data-chapter-step-active-label><span data-chapter-step-active-label-text></span></span><svg><path data-chapter-step-branch /></svg></div>
      <div data-chapter-step-list>
        ${stepIds
          .map(
            (stepId, index) => `
              <button
                type="button"
                data-chapter-step="${stepId}"
                data-step-state="${index === 0 ? "current" : "upcoming"}"
                aria-label="${stepId}"
                disabled
                tabindex="-1"
              ><span class="chapter-step__dot"></span>${stepId}</button>`,
          )
          .join("")}
      </div>
      ${stepIds
        .map(
          (stepId, index) =>
            `<div data-chapter-step-panel="${stepId}" aria-hidden="${index !== 0}">${stepId} copy</div>`,
        )
        .join("")}
      <div data-rail-surface-target="context-with-task"><div data-scene-root="chapter-context-with-task"></div></div>
    </section>
  `;
  document.body.append(fixture);
  fixtures.push(fixture);
  return requiredHtmlElement(fixture, "[data-chapter-steps-root]");
}

function selectedStepId(root: HTMLElement): string | undefined {
  return (
    root.querySelector<HTMLElement>('[data-chapter-step][aria-selected="true"]')?.dataset[
      "chapterStep"
    ] ?? undefined
  );
}

function reportSceneStep(root: HTMLElement, stepId: string): void {
  requiredHtmlElement(root, "[data-scene-root]").dispatchEvent(
    new CustomEvent("agentstudio:scene-step-reached", { bubbles: true, detail: { stepId } }),
  );
}

afterEach(() => {
  for (const fixture of fixtures.splice(0)) {
    fixture.remove();
  }
  vi.restoreAllMocks();
});

describe("chapter step tabs", () => {
  it("enhances the static steps into a horizontal tablist with synchronized panels", async () => {
    await page.viewport(1280, 800);
    const root = createChapterStepsFixture();
    const list = requiredHtmlElement(root, "[data-chapter-step-list]");
    const firstStep = requiredButton(root, '[data-chapter-step="task-drawers"]');

    expect(firstStep.disabled).toBe(true);
    expect(list.hasAttribute("role")).toBe(false);

    const controller = initializeChapterSteps(root);

    expect(root.dataset["enhanced"]).toBe("true");
    expect(list.getAttribute("role")).toBe("tablist");
    expect(list.getAttribute("aria-orientation")).toBe("horizontal");
    expect(firstStep.getAttribute("role")).toBe("tab");
    expect(firstStep.getAttribute("aria-selected")).toBe("true");
    expect(firstStep.tabIndex).toBe(0);
    const firstPanel = requiredHtmlElement(root, '[data-chapter-step-panel="task-drawers"]');
    expect(firstPanel.getAttribute("role")).toBe("tabpanel");
    expect(firstPanel.getAttribute("aria-labelledby")).toBe(firstStep.id);
    expect(firstStep.getAttribute("aria-controls")).toBe(firstPanel.id);

    controller.destroy();

    expect(root.dataset["enhanced"]).toBe("false");
    expect(list.hasAttribute("role")).toBe(false);
    expect(firstStep.disabled).toBe(true);
  });

  it("keeps the pill tablist horizontal across the breakpoint", async () => {
    // Arrange
    await page.viewport(390, 844);
    const root = createChapterStepsFixture();
    const list = requiredHtmlElement(root, "[data-chapter-step-list]");

    // Act
    const controller = initializeChapterSteps(root);

    // Assert
    expect(list.getAttribute("aria-orientation")).toBe("horizontal");
    await page.viewport(1280, 800);
    expect(list.getAttribute("aria-orientation")).toBe("horizontal");

    controller.destroy();
  });

  it("selects a clicked step, shows its panel, and asks the scene to seek there", () => {
    const root = createChapterStepsFixture();
    const requestedSteps: string[] = [];
    const receivedAtSurface: string[] = [];
    root.addEventListener(chapterStepRequestedEventName, (event: Event): void => {
      requestedSteps.push(readChapterStepEventStepId(event) ?? "unreadable");
    });
    requiredHtmlElement(root, "[data-rail-surface-target]").addEventListener(
      chapterStepRequestedEventName,
      (event: Event): void => {
        receivedAtSurface.push(readChapterStepEventStepId(event) ?? "unreadable");
      },
    );
    const controller = initializeChapterSteps(root);

    requiredButton(root, '[data-chapter-step="git-context"]').click();

    expect(selectedStepId(root)).toBe("git-context");
    expect(
      requiredHtmlElement(root, '[data-chapter-step-panel="git-context"]').getAttribute(
        "aria-hidden",
      ),
    ).toBe("false");
    expect(
      requiredHtmlElement(root, '[data-chapter-step-panel="task-drawers"]').getAttribute(
        "aria-hidden",
      ),
    ).toBe("true");
    expect(
      requiredHtmlElement(root, '[data-chapter-step="task-drawers"]').dataset["stepState"],
    ).toBe("passed");
    expect(requiredHtmlElement(root, '[data-chapter-step="files"]').dataset["stepState"]).toBe(
      "upcoming",
    );
    expect(requestedSteps).toEqual(["git-context"]);
    expect(receivedAtSurface).toEqual(["git-context"]);
    expect(requiredHtmlElement(root, "[data-chapter-step-active-label-text]").textContent).toBe(
      "git-context",
    );

    controller.destroy();
  });

  it("tracks published dwell progress and replays the selected step", async () => {
    const root = createChapterStepsFixture();
    const surface = requiredHtmlElement(root, "[data-rail-surface-target]");
    const controller = initializeChapterSteps(root);
    const ring = root.querySelector<SVGSVGElement>("[data-chapter-step-ring]");
    const progress = root.querySelector<SVGCircleElement>("[data-chapter-step-ring-progress]");
    if (ring === null || progress === null) throw new Error("Ring fixture missing");
    const requested: string[] = [];
    surface.addEventListener("agentstudio:chapter-step-requested", (event: Event): void => {
      requested.push(readChapterStepEventStepId(event) ?? "");
    });
    surface.dispatchEvent(
      new CustomEvent("agentstudio:scene-step-timing", {
        bubbles: true,
        detail: {
          stepId: "task-drawers",
          dwellSeconds: 4,
          elapsedSeconds: 2,
          running: true,
          manualPause: false,
        },
      }),
    );
    expect(ring.hasAttribute("data-ring-hidden")).toBe(false);
    const countdown = progress.getAnimations()[0];
    expect(countdown?.currentTime).toBe(2000);
    expect(countdown?.playState).toBe("running");
    if (countdown === undefined) throw new Error("Countdown animation missing");
    countdown.currentTime = 2020;
    surface.dispatchEvent(
      new CustomEvent("agentstudio:scene-step-timing", {
        bubbles: true,
        detail: {
          stepId: "task-drawers",
          dwellSeconds: 4,
          elapsedSeconds: 2.04,
          running: true,
          manualPause: false,
        },
      }),
    );
    expect(countdown.currentTime).toBe(2020);

    requiredButton(root, '[data-chapter-step="git-context"]').click();
    expect(root.querySelector("[data-chapter-step-line]")?.getAttribute("data-step-playback")).toBe(
      "playing",
    );
    expect(requiredHtmlElement(root, "[data-chapter-step-pause-glyph]").hidden).toBe(true);
    requiredButton(root, '[data-chapter-step="git-context"]').click();
    expect(requested).toEqual(["git-context", "git-context"]);
    controller.destroy();
  });

  it.each(["Space", "Enter"])("replays a selected playing tab once with %s", async (key) => {
    const root = createChapterStepsFixture();
    const surface = requiredHtmlElement(root, "[data-rail-surface-target]");
    const requested: string[] = [];
    surface.addEventListener("agentstudio:chapter-step-requested", (event: Event): void => {
      requested.push(readChapterStepEventStepId(event) ?? "unreadable");
    });
    const controller = initializeChapterSteps(root);
    const sceneRoot = requiredHtmlElement(surface, "[data-scene-root]");
    const sceneModule: SceneModule = {
      sceneId: "chapter-context-with-task",
      steps: [
        { stepId: "task-drawers", timelineLabel: "task-drawers" },
        { stepId: "git-context", timelineLabel: "git-context" },
        { stepId: "files", timelineLabel: "files" },
      ],
      buildScene: (scene, timeline): void => {
        timeline
          .addLabel("task-drawers", 0)
          .to(scene, { opacity: 0.9, duration: 1 })
          .addLabel("git-context")
          .to(scene, { opacity: 0.8, duration: 1 })
          .addLabel("files")
          .to(scene, { opacity: 1, duration: 1 });
      },
    };
    const playback = createScenePlayback({
      resolveModule: () => sceneModule,
      sceneRoot,
      surface,
    });
    playback.synchronize(1, true);
    const selected = requiredButton(root, '[data-chapter-step="git-context"]');
    selected.click();
    expect(sceneRoot.dataset["scenePlaybackState"]).toBe("playing");
    expect(root.querySelector("[data-chapter-step-line]")?.getAttribute("data-step-playback")).toBe(
      "playing",
    );
    const travel = requiredHtmlElement(root, "[data-chapter-step-line]")
      .querySelector("[data-chapter-step-ring]")
      ?.getAnimations()[0];
    if (travel !== undefined) await travel.finished;

    selected.focus();
    await userEvent.keyboard(key === "Space" ? " " : "{Enter}");

    expect(requested).toEqual(["git-context", "git-context"]);
    expect(sceneRoot.dataset["scenePlaybackState"]).toBe("playing");
    expect(root.querySelector("[data-chapter-step-line]")?.getAttribute("data-step-playback")).toBe(
      "playing",
    );
    playback.dispose();
    controller.destroy();
  });

  it("moves selection and focus with arrow, Home, and End keys", () => {
    const root = createChapterStepsFixture();
    const list = requiredHtmlElement(root, "[data-chapter-step-list]");
    const controller = initializeChapterSteps(root);
    const pressKey = (key: string): void => {
      list.dispatchEvent(new KeyboardEvent("keydown", { bubbles: true, key }));
    };

    requiredButton(root, '[data-chapter-step="task-drawers"]').focus();
    pressKey("ArrowDown");
    expect(selectedStepId(root)).toBe("git-context");
    expect(document.activeElement).toBe(requiredButton(root, '[data-chapter-step="git-context"]'));

    pressKey("End");
    expect(selectedStepId(root)).toBe("files");
    expect(document.activeElement).toBe(requiredButton(root, '[data-chapter-step="files"]'));

    pressKey("ArrowDown");
    expect(selectedStepId(root)).toBe("task-drawers");

    pressKey("ArrowUp");
    expect(selectedStepId(root)).toBe("files");

    pressKey("Home");
    expect(selectedStepId(root)).toBe("task-drawers");
    expect(requiredButton(root, '[data-chapter-step="files"]').tabIndex).toBe(-1);

    controller.destroy();
  });

  it("moves from the focused tab, not the scene-advanced selection", () => {
    const root = createChapterStepsFixture();
    const controller = initializeChapterSteps(root);
    const firstStep = requiredButton(root, '[data-chapter-step="task-drawers"]');
    const secondStep = requiredButton(root, '[data-chapter-step="git-context"]');
    firstStep.focus();

    reportSceneStep(root, "files");
    expect(selectedStepId(root)).toBe("files");
    expect(document.activeElement).toBe(firstStep);

    firstStep.dispatchEvent(new KeyboardEvent("keydown", { bubbles: true, key: "ArrowDown" }));

    expect(selectedStepId(root)).toBe("git-context");
    expect(document.activeElement).toBe(secondStep);

    controller.destroy();
  });

  it("follows scene progress without moving focus and keeps the last valid step", () => {
    const root = createChapterStepsFixture();
    const requestedSteps: string[] = [];
    root.addEventListener(chapterStepRequestedEventName, (): void => {
      requestedSteps.push("requested");
    });
    const controller = initializeChapterSteps(root);
    const outsideButton = document.createElement("button");
    document.body.append(outsideButton);
    outsideButton.focus();

    reportSceneStep(root, "files");
    expect(selectedStepId(root)).toBe("files");
    expect(document.activeElement).toBe(outsideButton);

    reportSceneStep(root, "not-a-step");
    expect(selectedStepId(root)).toBe("files");

    reportSceneStep(root, "review-diff");
    expect(selectedStepId(root)).toBe("files");
    expect(requestedSteps).toEqual([]);

    outsideButton.remove();
    controller.destroy();
  });

  it("keeps the static contract when the markup is incomplete", () => {
    const root = createChapterStepsFixture();
    requiredHtmlElement(root, '[data-chapter-step-panel="files"]').remove();
    vi.spyOn(console, "error").mockImplementation((): void => undefined);

    initializeChapterSteps(root);

    expect(root.dataset["enhanced"]).toBe("false");
    expect(requiredButton(root, '[data-chapter-step="task-drawers"]').disabled).toBe(true);
    expect(requiredHtmlElement(root, "[data-chapter-step-list]").hasAttribute("role")).toBe(false);
  });
});
