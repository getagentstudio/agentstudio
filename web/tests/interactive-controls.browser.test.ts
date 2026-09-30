import { afterEach, describe, expect, it, vi } from "vitest";

import { createScrollAutoplayVideoController } from "../src/home-page/scroll-autoplay-video-controller";
import { initializeScrollMaterialSurfaces } from "../src/home-page/scroll-material-surface-controller";
import { initializeInstallCommand } from "../src/install-command/install-command-controller";
import { marketingCopy } from "../src/marketing-copy";

const fixtures: HTMLElement[] = [];

function requiredHtmlElement(parent: ParentNode, selector: string): HTMLElement {
  const element = parent.querySelector(selector);
  if (!(element instanceof HTMLElement)) {
    throw new Error(`Browser fixture is missing required element: ${selector}`);
  }
  return element;
}

function requiredButton(parent: ParentNode, selector: string): HTMLButtonElement {
  const element = parent.querySelector(selector);
  if (!(element instanceof HTMLButtonElement)) {
    throw new Error(`Browser fixture is missing required button: ${selector}`);
  }
  return element;
}

function addFixture(markup: string): HTMLElement {
  const fixture = document.createElement("div");
  fixture.innerHTML = markup;
  document.body.append(fixture);
  fixtures.push(fixture);
  return fixture;
}

function nextTextMutation(element: HTMLElement, expectedText: string): Promise<void> {
  return new Promise((resolve): void => {
    const observer = new MutationObserver((): void => {
      if (element.textContent !== expectedText) return;
      observer.disconnect();
      resolve();
    });
    observer.observe(element, { childList: true, characterData: true, subtree: true });
  });
}

interface ControllableVideoFixture {
  readonly finishPlayback: () => void;
  readonly pauseManually: () => void;
  readonly paused: () => boolean;
  readonly playManually: () => void;
  readonly playSpy: ReturnType<typeof vi.spyOn>;
  readonly pauseSpy: ReturnType<typeof vi.spyOn>;
  readonly root: HTMLElement;
}

function createControllableVideoFixture(): ControllableVideoFixture {
  const root = addFixture(`
    <section>
      <video
        data-scroll-autoplay-video
        data-scroll-autoplay-start-progress="0.95"
        data-scroll-autoplay-stop-progress="0.9"
        data-scroll-autoplay-replay-delay-ms="3000"
      ></video>
    </section>
  `);
  const video = root.querySelector("video");
  if (!(video instanceof HTMLVideoElement)) {
    throw new Error("Autoplay fixture is missing its video");
  }

  let videoPaused = true;
  let videoEnded = false;
  Object.defineProperty(video, "paused", {
    configurable: true,
    get: (): boolean => videoPaused,
  });
  Object.defineProperty(video, "ended", {
    configurable: true,
    get: (): boolean => videoEnded,
  });

  const playSpy = vi.spyOn(video, "play").mockImplementation((): Promise<void> => {
    videoPaused = false;
    video.dispatchEvent(new Event("play"));
    return Promise.resolve();
  });
  const pauseSpy = vi.spyOn(video, "pause").mockImplementation((): void => {
    videoPaused = true;
    video.dispatchEvent(new Event("pause"));
  });

  return {
    finishPlayback: (): void => {
      videoPaused = true;
      videoEnded = true;
      video.dispatchEvent(new Event("ended"));
      videoEnded = false;
    },
    pauseManually: (): void => {
      videoPaused = true;
      video.dispatchEvent(new Event("pause"));
    },
    paused: (): boolean => videoPaused,
    playManually: (): void => {
      videoPaused = false;
      video.dispatchEvent(new Event("play"));
    },
    playSpy,
    pauseSpy,
    root,
  };
}

afterEach(() => {
  for (const fixture of fixtures.splice(0)) {
    fixture.remove();
  }
  vi.useRealTimers();
  vi.restoreAllMocks();
});

describe("interactive website controllers", () => {
  it("starts and stops marked videos with scroll-progress hysteresis", () => {
    const fixture = createControllableVideoFixture();
    const controller = createScrollAutoplayVideoController(fixture.root);

    controller.synchronize(0.94, true);
    expect(fixture.playSpy).not.toHaveBeenCalled();

    controller.synchronize(0.95, true);
    expect(fixture.playSpy).toHaveBeenCalledTimes(1);
    expect(fixture.paused()).toBe(false);

    controller.synchronize(0.92, true);
    expect(fixture.pauseSpy).not.toHaveBeenCalled();

    controller.synchronize(0.89, true);
    expect(fixture.pauseSpy).toHaveBeenCalledTimes(1);
    expect(fixture.paused()).toBe(true);

    controller.synchronize(0.95, true);
    expect(fixture.playSpy).toHaveBeenCalledTimes(2);
    expect(fixture.paused()).toBe(false);

    controller.dispose();
  });

  it("preserves manual video intent until the visitor leaves the autoplay zone", () => {
    const fixture = createControllableVideoFixture();
    const controller = createScrollAutoplayVideoController(fixture.root);

    controller.synchronize(0.95, true);
    fixture.pauseManually();
    controller.synchronize(1, true);
    expect(fixture.playSpy).toHaveBeenCalledTimes(1);
    expect(fixture.paused()).toBe(true);

    controller.synchronize(0.89, true);
    controller.synchronize(0.95, true);
    expect(fixture.playSpy).toHaveBeenCalledTimes(2);

    controller.synchronize(0.89, true);
    fixture.playManually();
    controller.synchronize(0.2, true);
    expect(fixture.pauseSpy).toHaveBeenCalledTimes(1);
    expect(fixture.paused()).toBe(false);

    controller.dispose();
  });

  it("replays a completed autoplay video once after the configured delay", () => {
    vi.useFakeTimers();
    const fixture = createControllableVideoFixture();
    const controller = createScrollAutoplayVideoController(fixture.root);

    controller.synchronize(0.95, true);
    fixture.finishPlayback();

    vi.advanceTimersByTime(2999);
    expect(fixture.playSpy).toHaveBeenCalledTimes(1);

    vi.advanceTimersByTime(1);
    expect(fixture.playSpy).toHaveBeenCalledTimes(2);
    expect(fixture.paused()).toBe(false);

    controller.dispose();
  });

  it("pauses scroll-owned autoplay while the document is hidden", async () => {
    const fixture = createControllableVideoFixture();
    fixture.root.dataset["scrollMaterialSurface"] = "";
    vi.spyOn(fixture.root, "getBoundingClientRect").mockImplementation((): DOMRect => {
      const height = 400;
      const top = window.innerHeight * 0.8 - height;
      return {
        bottom: top + height,
        height,
        left: 0,
        right: 800,
        toJSON: (): object => ({}),
        top,
        width: 800,
        x: 0,
        y: top,
      };
    });
    Object.defineProperty(document, "visibilityState", {
      configurable: true,
      value: "visible",
    });

    initializeScrollMaterialSurfaces();
    expect(fixture.playSpy).toHaveBeenCalledTimes(1);

    Object.defineProperty(document, "visibilityState", {
      configurable: true,
      value: "hidden",
    });
    document.dispatchEvent(new Event("visibilitychange"));
    await new Promise<void>((resolve): void => {
      requestAnimationFrame((): void => resolve());
    });
    expect(fixture.pauseSpy).toHaveBeenCalledTimes(1);
    initializeScrollMaterialSurfaces();
    Reflect.deleteProperty(document, "visibilityState");
  });

  it("reports copy success and preserves a useful clipboard failure fallback", async () => {
    const fixture = addFixture(`
      <div data-install-root data-install-command="brew install --cask agent-studio">
        <code data-install-code>brew install --cask agent-studio</code>
        <button data-install-copy>Copy</button>
        <span data-install-status></span>
      </div>
    `);
    const root = requiredHtmlElement(fixture, "[data-install-root]");
    const writeText = vi.spyOn(navigator.clipboard, "writeText").mockResolvedValue();
    const dispose = initializeInstallCommand(root);
    const button = requiredButton(root, "[data-install-copy]");
    const status = requiredHtmlElement(root, "[data-install-status]");

    const copiedStatus = nextTextMutation(status, marketingCopy.installation.copiedStatus);
    button.click();
    await copiedStatus;
    expect(status.textContent).toBe(marketingCopy.installation.copiedStatus);
    expect(writeText).toHaveBeenCalledWith("brew install --cask agent-studio");

    writeText.mockRejectedValueOnce(new Error("clipboard unavailable"));
    const failedStatus = nextTextMutation(status, marketingCopy.installation.failedStatus);
    button.click();
    await failedStatus;
    expect(status.textContent).toBe(marketingCopy.installation.failedStatus);

    dispose();
  });

  it("initializes a shared install root once and copies once per click", async () => {
    const fixture = addFixture(`
      <div data-install-command="brew install --cask agent-studio" data-install-copied-label="Copied ✓">
        <code data-install-code>brew install --cask agent-studio</code>
        <button data-install-copy><span data-install-copy-feedback>Copy</span></button>
        <span data-install-status></span>
      </div>
    `);
    const root = requiredHtmlElement(fixture, "[data-install-command]");
    const status = requiredHtmlElement(root, "[data-install-status]");
    const label = requiredHtmlElement(root, "[data-install-copy-feedback]");
    const writeText = vi.spyOn(navigator.clipboard, "writeText").mockResolvedValue();
    const firstDispose = initializeInstallCommand(root);
    const secondDispose = initializeInstallCommand(root);
    const copiedStatus = nextTextMutation(status, marketingCopy.installation.copiedStatus);
    requiredButton(root, "[data-install-copy]").click();
    await copiedStatus;
    expect(secondDispose).toBe(firstDispose);
    expect(writeText).toHaveBeenCalledTimes(1);
    expect(label.textContent).toBe("Copied ✓");
    secondDispose();
  });

  it("reports copy failure when the Clipboard API is unavailable", async () => {
    const fixture = addFixture(`
      <div data-install-root data-install-command="brew install --cask agent-studio">
        <code data-install-code>brew install --cask agent-studio</code>
        <button data-install-copy>Copy</button>
        <span data-install-status></span>
      </div>
    `);
    const root = requiredHtmlElement(fixture, "[data-install-root]");
    Object.defineProperty(navigator, "clipboard", { configurable: true, value: undefined });
    const dispose = initializeInstallCommand(root);
    const button = requiredButton(root, "[data-install-copy]");
    const status = requiredHtmlElement(root, "[data-install-status]");

    button.click();

    expect(status.textContent).toBe(marketingCopy.installation.failedStatus);
    dispose();
    Reflect.deleteProperty(navigator, "clipboard");
  });

  it("restores the finale copy label exactly two seconds after a successful copy", async () => {
    const fixture = addFixture(`
      <div data-install-command="brew tap ShravanSunder/agentstudio\nbrew install --cask agent-studio" data-install-copied-label="Copied ✓" data-install-feedback-ms="2000">
        <code data-install-code hidden></code>
        <button data-install-copy><svg><g data-install-copy-icon></g><path data-install-copied-icon data-install-icon-hidden></path></svg><span data-install-copy-feedback>Copy install</span></button>
        <span data-install-status aria-live="polite"></span>
      </div>
    `);
    const root = requiredHtmlElement(fixture, "[data-install-command]");
    const button = requiredButton(root, "[data-install-copy]");
    const label = requiredHtmlElement(root, "[data-install-copy-feedback]");
    const status = requiredHtmlElement(root, "[data-install-status]");
    const writeText = vi.spyOn(navigator.clipboard, "writeText").mockResolvedValue();
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
    const dispose = initializeInstallCommand(root);
    button.click();
    await Promise.resolve();
    expect(writeText).toHaveBeenCalledWith(
      "brew tap ShravanSunder/agentstudio\nbrew install --cask agent-studio",
    );
    expect(label.textContent).toBe("Copied ✓");
    expect(
      root.querySelector("[data-install-copy-icon]")?.hasAttribute("data-install-icon-hidden"),
    ).toBe(true);
    expect(
      root.querySelector("[data-install-copied-icon]")?.hasAttribute("data-install-icon-hidden"),
    ).toBe(false);
    expect(status.textContent).toBe(marketingCopy.installation.copiedStatus);
    vi.advanceTimersByTime(1999);
    expect(label.textContent).toBe("Copied ✓");
    vi.advanceTimersByTime(1);
    expect(label.textContent).toBe("Copy install");
    expect(
      root.querySelector("[data-install-copy-icon]")?.hasAttribute("data-install-icon-hidden"),
    ).toBe(false);
    expect(
      root.querySelector("[data-install-copied-icon]")?.hasAttribute("data-install-icon-hidden"),
    ).toBe(true);
    expect(status.textContent).toBe("");
    dispose();
  });
});
