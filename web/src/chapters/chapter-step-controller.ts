import { localDropTurnPath } from "../topology-lab/full-page-topology-paths";
import { isChapterStepId, type ChapterStepId } from "./chapter-ids";
import {
  chapterStepRequestedEventName,
  createChapterStepEvent,
  readChapterStepEventStepId,
  readSceneStepTiming,
  type SceneStepTimingDetail,
  sceneStepReachedEventName,
  sceneStepTimingEventName,
} from "./chapter-step-events";

// Tab semantics follow the retired product plate's proven contract: static and
// disabled until the whole step/panel correspondence validates, then roving
// focus, arrows/Home/End, and aria-selected. Scene progress selects a step
// without moving focus; a visitor's selection asks the scene to seek there.

const stepSelector = "[data-chapter-step]";
const panelSelector = "[data-chapter-step-panel]";

export type ChapterStepState = "passed" | "current" | "upcoming";

interface ChapterStepElements {
  readonly panel: HTMLElement;
  readonly selector: HTMLButtonElement;
  readonly stepId: ChapterStepId;
}

interface ChapterStepsDomContract {
  readonly list: HTMLElement;
  readonly root: HTMLElement;
  readonly steps: readonly ChapterStepElements[];
}

export interface ChapterStepsController {
  readonly destroy: () => void;
}

type StepMovement = "first" | "last" | "next" | "previous";

function validateChapterStepsDom(root: HTMLElement): ChapterStepsDomContract {
  const list = root.querySelector<HTMLElement>("[data-chapter-step-list]");
  if (list === null) {
    throw new Error("Chapter steps markup is missing its step list.");
  }
  const selectors = Array.from(list.querySelectorAll(stepSelector));
  const panels = Array.from(root.querySelectorAll<HTMLElement>(panelSelector));
  if (selectors.length === 0 || selectors.length !== panels.length) {
    throw new Error("Chapter steps markup has mismatched steps and panels.");
  }
  const seenStepIds = new Set<ChapterStepId>();
  const steps = selectors.map((selector): ChapterStepElements => {
    const stepId = selector.getAttribute("data-chapter-step") ?? "";
    if (!(selector instanceof HTMLButtonElement) || !isChapterStepId(stepId)) {
      throw new Error(`Chapter step selector is invalid: ${stepId}`);
    }
    if (seenStepIds.has(stepId)) {
      throw new Error(`Chapter step is duplicated: ${stepId}`);
    }
    const panel = panels.find((candidate) => candidate.dataset["chapterStepPanel"] === stepId);
    if (panel === undefined) {
      throw new Error(`Chapter step has no panel: ${stepId}`);
    }
    seenStepIds.add(stepId);
    return { panel, selector, stepId };
  });
  return { list, root, steps };
}

function stepStateFor(stepIndex: number, selectedIndex: number): ChapterStepState {
  if (stepIndex === selectedIndex) {
    return "current";
  }
  return stepIndex < selectedIndex ? "passed" : "upcoming";
}

function renderStaticContract(contract: ChapterStepsDomContract): void {
  contract.list.removeAttribute("role");
  contract.list.removeAttribute("aria-orientation");
  contract.steps.forEach(({ panel, selector }, stepIndex): void => {
    selector.disabled = true;
    selector.tabIndex = -1;
    selector.removeAttribute("role");
    selector.removeAttribute("aria-controls");
    selector.removeAttribute("aria-selected");
    selector.dataset["stepState"] = stepStateFor(stepIndex, 0);
    panel.removeAttribute("hidden");
    panel.setAttribute("aria-hidden", String(stepIndex !== 0));
    panel.removeAttribute("role");
    panel.removeAttribute("aria-labelledby");
    panel.removeAttribute("tabindex");
  });
  contract.root.dataset["enhanced"] = "false";
}

function renderSelectedStep(
  contract: ChapterStepsDomContract,
  selectedIndex: number,
  animateBranch: boolean,
): void {
  const idPrefix = `chapter-step-${contract.root.dataset["chapterStepsRoot"] ?? "chapter"}`;
  contract.list.setAttribute("role", "tablist");
  contract.list.setAttribute("aria-orientation", "horizontal");
  contract.steps.forEach(({ panel, selector, stepId }, stepIndex): void => {
    const isSelected = stepIndex === selectedIndex;
    selector.disabled = false;
    selector.id = `${idPrefix}-tab-${stepId}`;
    selector.tabIndex = isSelected ? 0 : -1;
    selector.setAttribute("role", "tab");
    selector.setAttribute("aria-controls", `${idPrefix}-panel-${stepId}`);
    selector.setAttribute("aria-selected", String(isSelected));
    selector.dataset["stepState"] = stepStateFor(stepIndex, selectedIndex);
    panel.id = `${idPrefix}-panel-${stepId}`;
    panel.removeAttribute("hidden");
    panel.setAttribute("aria-hidden", String(!isSelected));
    panel.tabIndex = 0;
    panel.setAttribute("role", "tabpanel");
    panel.setAttribute("aria-labelledby", selector.id);
  });
  contract.root.dataset["enhanced"] = "true";
  const selected = contract.steps[selectedIndex]?.selector;
  const stepLine = contract.root.querySelector<HTMLElement>("[data-chapter-step-line]");
  const branch = stepLine?.querySelector<SVGPathElement>("[data-chapter-step-branch]");
  const label = stepLine?.querySelector<HTMLElement>("[data-chapter-step-active-label]");
  const lastDot = contract.steps.at(-1)?.selector.querySelector<HTMLElement>(".chapter-step__dot");
  const currentDot = selected?.querySelector<HTMLElement>(".chapter-step__dot");
  if (
    stepLine !== null &&
    stepLine !== undefined &&
    branch !== null &&
    branch !== undefined &&
    label !== null &&
    label !== undefined &&
    lastDot !== undefined &&
    lastDot !== null &&
    currentDot !== undefined &&
    currentDot !== null
  ) {
    const lineBounds = stepLine.getBoundingClientRect();
    const center = (dot: HTMLElement): number => {
      const bounds = dot.getBoundingClientRect();
      return (bounds.left + bounds.right) / 2 - lineBounds.left;
    };
    const currentCenter = center(currentDot);
    stepLine.style.setProperty("--chapter-step-current-center", `${currentCenter}px`);
    stepLine.style.setProperty("--chapter-step-track-width", `${center(lastDot)}px`);
    stepLine.style.setProperty("--chapter-step-progress-width", `${currentCenter}px`);

    const shouldAnimate =
      animateBranch && !window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    if (shouldAnimate) {
      const outgoingLabel = label.cloneNode(true);
      if (outgoingLabel instanceof HTMLElement) {
        outgoingLabel.removeAttribute("data-chapter-step-active-label");
        stepLine.append(outgoingLabel);
        void outgoingLabel
          .animate(
            [
              { opacity: 1, transform: "scale(1)" },
              { opacity: 0, transform: "scale(0.2)" },
            ],
            { duration: 100, easing: "ease-out", fill: "forwards" },
          )
          .finished.then(() => outgoingLabel.remove())
          .catch(() => outgoingLabel.remove());
      }
      const outgoingBranch = branch.cloneNode(true);
      if (outgoingBranch instanceof SVGPathElement) {
        outgoingBranch.removeAttribute("data-chapter-step-branch");
        branch.parentElement?.append(outgoingBranch);
        const outgoingLength = outgoingBranch.getTotalLength();
        void outgoingBranch
          .animate(
            [
              { strokeDasharray: outgoingLength, strokeDashoffset: 0 },
              { strokeDasharray: outgoingLength, strokeDashoffset: outgoingLength },
            ],
            { duration: 120, easing: "ease-in", fill: "forwards" },
          )
          .finished.then(() => outgoingBranch.remove())
          .catch(() => outgoingBranch.remove());
      }
    }

    const labelText = label.querySelector<HTMLElement>("[data-chapter-step-active-label-text]");
    if (labelText === null) throw new Error("Chapter step label text is missing");
    labelText.textContent = selected?.getAttribute("aria-label") ?? "";
    const desiredLeft = currentCenter + 24;
    const maximumLeft = Math.max(0, stepLine.clientWidth - label.scrollWidth - 4);
    const labelLeft = Math.min(desiredLeft, maximumLeft);
    label.style.left = `${labelLeft}px`;
    stepLine.style.setProperty("--chapter-step-label-left", `${labelLeft}px`);
    const dotY =
      (currentDot.getBoundingClientRect().top + currentDot.getBoundingClientRect().bottom) / 2 -
      lineBounds.top;
    const labelY = label.offsetTop + label.offsetHeight / 2;
    branch.setAttribute(
      "d",
      [
        ...localDropTurnPath(currentCenter, labelLeft - 5, dotY, labelY),
        `L ${labelLeft} ${labelY}`,
      ].join(" "),
    );
    if (shouldAnimate) {
      const length = branch.getTotalLength();
      branch.animate(
        [
          { strokeDasharray: length, strokeDashoffset: length },
          { strokeDasharray: length, strokeDashoffset: 0 },
        ],
        { duration: 100, delay: 120, easing: "ease-out", fill: "backwards" },
      );
      label.animate(
        [
          { opacity: 0, transform: "scale(0.55)" },
          { opacity: 1, transform: "scale(1)" },
        ],
        {
          duration: 100,
          delay: 150,
          fill: "backwards",
          easing: "ease-out",
        },
      );
    }
  }
}

function movementForKey(key: string): StepMovement | null {
  switch (key) {
    case "ArrowLeft":
    case "ArrowUp":
      return "previous";
    case "ArrowRight":
    case "ArrowDown":
      return "next";
    case "Home":
      return "first";
    case "End":
      return "last";
    default:
      return null;
  }
}

function movedIndex(selectedIndex: number, movement: StepMovement, stepCount: number): number {
  switch (movement) {
    case "first":
      return 0;
    case "last":
      return stepCount - 1;
    case "next":
      return (selectedIndex + 1) % stepCount;
    case "previous":
      return (selectedIndex - 1 + stepCount) % stepCount;
    default:
      return selectedIndex;
  }
}

export function initializeChapterSteps(root: HTMLElement): ChapterStepsController {
  const lifecycle = new AbortController();
  let contract: ChapterStepsDomContract | null = null;
  let countdown: Animation | undefined;
  let ringTravel: Animation | undefined;
  let pendingTiming: SceneStepTimingDetail | undefined;

  try {
    const validatedContract = validateChapterStepsDom(root);
    contract = validatedContract;
    let selectedIndex = 0;
    let countdownStepId: string | undefined;
    let countdownDurationMs = 0;
    const stepLine = root.querySelector<HTMLElement>("[data-chapter-step-line]");
    const ring = stepLine?.querySelector<SVGSVGElement>("[data-chapter-step-ring]");
    const progress = stepLine?.querySelector<SVGCircleElement>("[data-chapter-step-ring-progress]");
    const pauseGlyph = stepLine?.querySelector<HTMLElement>("[data-chapter-step-pause-glyph]");
    const setRingTiming = (
      stepId: string,
      dwellSeconds: number,
      elapsedSeconds: number,
      running: boolean,
      manualPause: boolean,
    ): void => {
      if (ringTravel?.playState === "running") {
        pendingTiming = { stepId, dwellSeconds, elapsedSeconds, running, manualPause };
        return;
      }
      if (
        ring === undefined ||
        ring === null ||
        progress === undefined ||
        progress === null ||
        stepLine === null ||
        stepLine === undefined
      )
        return;
      if (window.matchMedia("(prefers-reduced-motion: reduce)").matches || dwellSeconds <= 0) {
        ring.setAttribute("data-ring-hidden", "");
        countdown?.cancel();
        countdown = undefined;
        return;
      }
      ring.removeAttribute("data-ring-hidden");
      const radius = window.matchMedia("(width < 38.75rem)").matches ? 10 : 11;
      const circumference = 2 * Math.PI * radius;
      progress.setAttribute("r", String(radius));
      progress.style.strokeDasharray = String(circumference);
      const durationMs = dwellSeconds * 1000;
      if (
        countdown === undefined ||
        countdownStepId !== stepId ||
        countdownDurationMs !== durationMs
      ) {
        countdown?.cancel();
        countdown = progress.animate(
          [{ strokeDashoffset: String(circumference) }, { strokeDashoffset: "0" }],
          { duration: durationMs, fill: "both" },
        );
        countdownStepId = stepId;
        countdownDurationMs = durationMs;
      }
      const desiredTime = Math.min(Math.max(elapsedSeconds * 1000, 0), durationMs);
      const currentTime = countdown.currentTime;
      const keepRunning =
        running &&
        countdown.playState === "running" &&
        typeof currentTime === "number" &&
        Math.abs(currentTime - desiredTime) < 50;
      if (!keepRunning) {
        countdown.pause();
        countdown.currentTime = desiredTime;
        if (running) countdown.play();
      }
      stepLine.dataset["stepPlayback"] = running ? "playing" : manualPause ? "paused" : "held";
      if (pauseGlyph !== undefined && pauseGlyph !== null) pauseGlyph.hidden = !manualPause;
    };
    const selectStep = (stepIndex: number): void => {
      const changed = stepIndex !== selectedIndex;
      const priorCenter = stepLine?.style.getPropertyValue("--chapter-step-current-center") ?? "";
      selectedIndex = stepIndex;
      renderSelectedStep(validatedContract, selectedIndex, changed);
      if (ring !== undefined && ring !== null && stepLine !== undefined && stepLine !== null) {
        const nextCenter = stepLine.style.getPropertyValue("--chapter-step-current-center");
        ring.style.left = nextCenter;
        if (
          changed &&
          priorCenter !== "" &&
          nextCenter !== "" &&
          !window.matchMedia("(prefers-reduced-motion: reduce)").matches
        ) {
          const delta = Number.parseFloat(priorCenter) - Number.parseFloat(nextCenter);
          ringTravel?.cancel();
          const travel = ring.animate(
            [{ transform: `translateX(${delta}px)` }, { transform: "translateX(0px)" }],
            { duration: 160, easing: "ease-in-out" },
          );
          ringTravel = travel;
          void travel.finished
            .then((): void => {
              if (ringTravel !== travel) return;
              ringTravel = undefined;
              const timing = pendingTiming;
              pendingTiming = undefined;
              if (timing !== undefined)
                setRingTiming(
                  timing.stepId,
                  timing.dwellSeconds,
                  0,
                  timing.running,
                  timing.manualPause,
                );
            })
            .catch((): void => {
              if (ringTravel === travel) ringTravel = undefined;
            });
        }
      }
    };
    window.addEventListener("resize", () => selectStep(selectedIndex), {
      signal: lifecycle.signal,
    });

    // A visitor's choice enters on the glass, where the scene listens; the
    // event bubbles back to this root for other chapter observers.
    const chooseStep = (stepIndex: number): void => {
      selectStep(stepIndex);
      if (stepLine !== null && stepLine !== undefined) stepLine.dataset["stepPlayback"] = "playing";
      if (pauseGlyph !== undefined && pauseGlyph !== null) pauseGlyph.hidden = true;
      const chosenStep = validatedContract.steps[stepIndex];
      if (chosenStep !== undefined) {
        root
          .querySelector("[data-rail-surface-target]")
          ?.dispatchEvent(createChapterStepEvent(chapterStepRequestedEventName, chosenStep.stepId));
      }
    };

    selectStep(0);

    validatedContract.list.addEventListener(
      "click",
      (event: MouseEvent): void => {
        const target = event.target;
        if (!(target instanceof Element)) {
          return;
        }
        const selector = target.closest<HTMLButtonElement>(stepSelector);
        const stepIndex = validatedContract.steps.findIndex((step) => step.selector === selector);
        if (stepIndex >= 0) {
          chooseStep(stepIndex);
        }
      },
      { signal: lifecycle.signal },
    );

    validatedContract.list.addEventListener(
      "keydown",
      (event: KeyboardEvent): void => {
        if (
          (event.key === "Enter" || event.key === " ") &&
          event.target === validatedContract.steps[selectedIndex]?.selector
        ) {
          event.preventDefault();
          chooseStep(selectedIndex);
          return;
        }
        const movement = movementForKey(event.key);
        if (movement === null) {
          return;
        }
        event.preventDefault();
        // Scene progress moves the selection without moving focus, so arrows
        // move from the tab the visitor is on, not from the selected one.
        const focusedIndex = validatedContract.steps.findIndex(
          (step) =>
            (event.target instanceof Node && step.selector.contains(event.target)) ||
            step.selector === document.activeElement,
        );
        const originIndex = focusedIndex >= 0 ? focusedIndex : selectedIndex;
        chooseStep(movedIndex(originIndex, movement, validatedContract.steps.length));
        validatedContract.steps[selectedIndex]?.selector.focus();
      },
      { signal: lifecycle.signal },
    );

    // Scene progress: follow along, never steal focus, ignore unknown steps.
    root.addEventListener(
      sceneStepReachedEventName,
      (event: Event): void => {
        const stepId = readChapterStepEventStepId(event);
        const stepIndex = validatedContract.steps.findIndex((step) => step.stepId === stepId);
        if (stepIndex >= 0 && stepIndex !== selectedIndex) {
          selectStep(stepIndex);
        }
      },
      { signal: lifecycle.signal },
    );
    root.addEventListener(
      sceneStepTimingEventName,
      (event: Event): void => {
        const timing = readSceneStepTiming(event);
        if (
          timing === undefined ||
          timing.stepId !== validatedContract.steps[selectedIndex]?.stepId
        )
          return;
        setRingTiming(
          timing.stepId,
          timing.dwellSeconds,
          timing.elapsedSeconds,
          timing.running,
          timing.manualPause,
        );
      },
      { signal: lifecycle.signal },
    );
  } catch (error: unknown) {
    lifecycle.abort();
    if (contract !== null) {
      renderStaticContract(contract);
    } else {
      root.dataset["enhanced"] = "false";
    }
    console.error("Chapter step enhancement failed; static steps preserved.", error);
  }

  return {
    destroy: (): void => {
      lifecycle.abort();
      countdown?.cancel();
      ringTravel?.cancel();
      if (contract !== null) {
        renderStaticContract(contract);
      }
    },
  };
}
