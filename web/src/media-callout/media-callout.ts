import type { gsap } from "gsap";

import { localDropTurnPath } from "../topology-lab/full-page-topology-paths.ts";

const svgNamespace = "http://www.w3.org/2000/svg";
const mediaCalloutNodeRadius = 6;
const mediaCalloutLabelGap = 24;
const mediaCalloutStageInset = 16;
const mediaCalloutBendOffset = 24;
const mediaCalloutInDurationSeconds = 0.4;
const mediaCalloutNodeDurationSeconds = 0.12;
const mediaCalloutRouteDurationSeconds = 0.16;
const mediaCalloutLabelDurationSeconds = 0.12;

export const mediaCalloutStagePresets = [
  { name: "landscape-1920x1200", width: 1920, height: 1200 },
  { name: "portrait-1080x1350", width: 1080, height: 1350 },
] as const;

export const mediaCalloutStepPillClassName =
  "chapter-step-active-label floating-glass-material rounded-full px-3 py-1 whitespace-nowrap text-ink";

export type MediaCalloutStageSize = (typeof mediaCalloutStagePresets)[number];

export interface MediaCalloutTarget {
  readonly x: number;
  readonly y: number;
}

export type MediaCalloutLabelPosition = "auto" | "left" | "right" | "above" | "below";

export type MediaCalloutAnimation = "in" | "out" | "held";

export interface MediaCalloutParameters {
  readonly stage: Pick<MediaCalloutStageSize, "width" | "height">;
  readonly target: MediaCalloutTarget;
  readonly labelPosition: MediaCalloutLabelPosition;
  readonly text: string;
  readonly animation: MediaCalloutAnimation;
  readonly startAtSeconds?: number;
}

export type MediaCalloutTimeline = ReturnType<typeof gsap.timeline>;

export interface MediaCalloutMount {
  readonly root: HTMLDivElement;
  readonly targetNode: SVGSVGElement;
  readonly route: SVGPathElement;
  readonly label: HTMLSpanElement;
  readonly labelPosition: Exclude<MediaCalloutLabelPosition, "auto">;
  readonly startAtSeconds: number;
  readonly endAtSeconds: number;
  readonly animation: MediaCalloutAnimation;
}

interface MediaCalloutLabelLayout {
  readonly left: number;
  readonly top: number;
  readonly edgeX: number;
  readonly edgeY: number;
  readonly remainingRoom: number;
}

interface MediaCalloutPositionCandidate extends MediaCalloutLabelLayout {
  readonly position: Exclude<MediaCalloutLabelPosition, "auto">;
  readonly fits: boolean;
}

function createSvgElement<TTagName extends keyof SVGElementTagNameMap>(
  ownerDocument: Document,
  tagName: TTagName,
): SVGElementTagNameMap[TTagName] {
  return ownerDocument.createElementNS(svgNamespace, tagName);
}

function clamp(value: number, minimum: number, maximum: number): number {
  return Math.min(Math.max(value, minimum), maximum);
}

function isMediaCalloutStageSize(value: MediaCalloutParameters["stage"]): boolean {
  return mediaCalloutStagePresets.some(
    (preset) => preset.width === value.width && preset.height === value.height,
  );
}

function validateMediaCalloutParameters(parameters: MediaCalloutParameters): void {
  if (!isMediaCalloutStageSize(parameters.stage)) {
    throw new RangeError(
      `Unsupported media callout stage ${String(parameters.stage.width)}×${String(parameters.stage.height)}.`,
    );
  }
  if (
    !Number.isFinite(parameters.target.x) ||
    !Number.isFinite(parameters.target.y) ||
    parameters.target.x < mediaCalloutNodeRadius ||
    parameters.target.y < mediaCalloutNodeRadius ||
    parameters.target.x > parameters.stage.width - mediaCalloutNodeRadius ||
    parameters.target.y > parameters.stage.height - mediaCalloutNodeRadius
  ) {
    throw new RangeError("The target point must fit inside the selected media callout stage.");
  }
  if (parameters.text.trim() === "" || /[\r\n]/u.test(parameters.text)) {
    throw new RangeError("Media callout text must be a non-empty single line.");
  }
  if (
    parameters.startAtSeconds !== undefined &&
    (!Number.isFinite(parameters.startAtSeconds) || parameters.startAtSeconds < 0)
  ) {
    throw new RangeError("Media callout startAtSeconds must be a finite non-negative number.");
  }
}

function createMediaCalloutRoot(ownerDocument: Document): HTMLDivElement {
  const root = ownerDocument.createElement("div");
  root.className = "media-callout-layer";
  root.setAttribute("data-scene-root", "media-callout");
  root.setAttribute("data-media-callout", "");
  root.setAttribute("role", "note");
  return root;
}

function createMediaCalloutRoute(
  ownerDocument: Document,
  stage: MediaCalloutParameters["stage"],
): { readonly svg: SVGSVGElement; readonly path: SVGPathElement } {
  const svg = createSvgElement(ownerDocument, "svg");
  svg.classList.add("media-callout__routes");
  svg.setAttribute("viewBox", `0 0 ${String(stage.width)} ${String(stage.height)}`);
  svg.setAttribute("preserveAspectRatio", "none");
  svg.setAttribute("aria-hidden", "true");

  const path = createSvgElement(ownerDocument, "path");
  path.classList.add("media-callout__route");
  svg.append(path);
  return { svg, path };
}

function createMediaCalloutNode(ownerDocument: Document): SVGSVGElement {
  const node = createSvgElement(ownerDocument, "svg");
  node.classList.add("media-callout__target-node");
  node.setAttribute("viewBox", "0 0 14 14");
  node.setAttribute("aria-hidden", "true");

  const ring = createSvgElement(ownerDocument, "circle");
  ring.classList.add("media-callout__node-ring");
  ring.setAttribute("cx", "7");
  ring.setAttribute("cy", "7");
  ring.setAttribute("r", String(mediaCalloutNodeRadius));

  const core = createSvgElement(ownerDocument, "circle");
  core.classList.add("media-callout__node-core");
  core.setAttribute("cx", "7");
  core.setAttribute("cy", "7");
  core.setAttribute("r", "2.5");
  node.append(ring, core);
  return node;
}

function createMediaCalloutNodeAnchor(
  ownerDocument: Document,
  targetNode: SVGSVGElement,
): HTMLSpanElement {
  const anchor = ownerDocument.createElement("span");
  anchor.className = "media-callout__node-anchor";
  anchor.setAttribute("data-media-callout-target-node", "");
  anchor.setAttribute("aria-hidden", "true");
  anchor.append(targetNode);
  return anchor;
}

function createMediaCalloutLabel(ownerDocument: Document, text: string): HTMLSpanElement {
  const label = ownerDocument.createElement("span");
  label.className = `${mediaCalloutStepPillClassName} media-callout__label`;
  label.setAttribute("data-media-callout-label", "");
  label.textContent = text;
  return label;
}

function createMediaCalloutPositionCandidate(
  position: Exclude<MediaCalloutLabelPosition, "auto">,
  target: MediaCalloutTarget,
  stage: MediaCalloutParameters["stage"],
  labelWidth: number,
  labelHeight: number,
): MediaCalloutPositionCandidate {
  const aboveRoom =
    target.y - mediaCalloutNodeRadius - mediaCalloutLabelGap - mediaCalloutStageInset;
  const belowRoom =
    stage.height -
    target.y -
    mediaCalloutNodeRadius -
    mediaCalloutLabelGap -
    mediaCalloutStageInset;
  const verticalBend = aboveRoom > belowRoom ? -mediaCalloutBendOffset : mediaCalloutBendOffset;

  let left: number;
  let top: number;
  let edgeX: number;
  let edgeY: number;
  let remainingRoom: number;

  if (position === "right" || position === "left") {
    left =
      position === "right"
        ? target.x + mediaCalloutNodeRadius + mediaCalloutLabelGap
        : target.x - mediaCalloutNodeRadius - mediaCalloutLabelGap - labelWidth;
    const centerY = clamp(
      target.y + verticalBend,
      mediaCalloutStageInset + labelHeight / 2,
      stage.height - mediaCalloutStageInset - labelHeight / 2,
    );
    top = centerY - labelHeight / 2;
    edgeX = position === "right" ? left : left + labelWidth;
    edgeY = centerY;
    remainingRoom =
      position === "right"
        ? stage.width - target.x - mediaCalloutNodeRadius - mediaCalloutLabelGap - labelWidth
        : target.x - mediaCalloutNodeRadius - mediaCalloutLabelGap - labelWidth;
  } else {
    left = clamp(
      target.x - labelWidth / 2,
      mediaCalloutStageInset,
      stage.width - mediaCalloutStageInset - labelWidth,
    );
    if (position === "above") {
      top = target.y - mediaCalloutNodeRadius - mediaCalloutLabelGap - labelHeight;
      edgeY = top + labelHeight;
      remainingRoom = aboveRoom - labelHeight;
    } else {
      top = target.y + mediaCalloutNodeRadius + mediaCalloutLabelGap;
      edgeY = top;
      remainingRoom = belowRoom - labelHeight;
    }
    const positiveBendX = target.x + mediaCalloutBendOffset;
    const negativeBendX = target.x - mediaCalloutBendOffset;
    edgeX = clamp(
      positiveBendX,
      left + mediaCalloutStageInset,
      left + labelWidth - mediaCalloutStageInset,
    );
    if (Math.abs(edgeX - target.x) < mediaCalloutStageInset) {
      edgeX = clamp(
        negativeBendX,
        left + mediaCalloutStageInset,
        left + labelWidth - mediaCalloutStageInset,
      );
    }
  }

  const fits =
    left >= mediaCalloutStageInset &&
    top >= mediaCalloutStageInset &&
    left + labelWidth <= stage.width - mediaCalloutStageInset &&
    top + labelHeight <= stage.height - mediaCalloutStageInset;

  return { position, left, top, edgeX, edgeY, remainingRoom, fits };
}

function resolveMediaCalloutLabelLayout(
  parameters: MediaCalloutParameters,
  label: HTMLSpanElement,
): MediaCalloutPositionCandidate {
  const bounds = label.getBoundingClientRect();
  if (bounds.width > parameters.stage.width - mediaCalloutStageInset * 2) {
    throw new RangeError("Media callout text is too wide to fit on one line in this stage.");
  }

  const positions: readonly Exclude<MediaCalloutLabelPosition, "auto">[] =
    parameters.labelPosition === "auto"
      ? ["right", "left", "above", "below"]
      : [parameters.labelPosition];
  const candidates = positions.map((position) =>
    createMediaCalloutPositionCandidate(
      position,
      parameters.target,
      parameters.stage,
      bounds.width,
      bounds.height,
    ),
  );
  const fittingCandidates = candidates.filter((candidate) => candidate.fits);
  const chosenCandidate = fittingCandidates.toSorted(
    (first, second) => second.remainingRoom - first.remainingRoom,
  )[0];
  if (chosenCandidate === undefined) {
    throw new RangeError(
      `No ${parameters.labelPosition} label position fits inside the selected media callout stage.`,
    );
  }
  return chosenCandidate;
}

function applyMediaCalloutLayout(
  parameters: MediaCalloutParameters,
  route: SVGPathElement,
  targetAnchor: HTMLSpanElement,
  label: HTMLSpanElement,
): Exclude<MediaCalloutLabelPosition, "auto"> {
  const layout = resolveMediaCalloutLabelLayout(parameters, label);
  label.style.left = `${String(layout.left)}px`;
  label.style.top = `${String(layout.top)}px`;
  targetAnchor.style.left = `${String(parameters.target.x)}px`;
  targetAnchor.style.top = `${String(parameters.target.y)}px`;
  const routeCommands = localDropTurnPath(
    parameters.target.x,
    layout.edgeX,
    parameters.target.y,
    layout.edgeY,
  );
  route.setAttribute("d", routeCommands.join(" "));
  return layout.position;
}

function mediaCalloutPrefersReducedMotion(ownerWindow: Window): boolean {
  return ownerWindow.matchMedia("(prefers-reduced-motion: reduce)").matches;
}

function prepareMediaCalloutHeldState(
  targetNode: SVGSVGElement,
  route: SVGPathElement,
  label: HTMLSpanElement,
  pathLength: number,
): void {
  targetNode.style.opacity = "1";
  targetNode.style.transform = "scale(1)";
  route.style.strokeDasharray = String(pathLength);
  route.style.strokeDashoffset = "0";
  route.style.opacity = "1";
  label.style.opacity = "1";
}

function addMediaCalloutIntro(
  timeline: MediaCalloutTimeline,
  targetNode: SVGSVGElement,
  route: SVGPathElement,
  label: HTMLSpanElement,
  pathLength: number,
  startAtSeconds: number,
): void {
  timeline.fromTo(
    targetNode,
    { autoAlpha: 0, scale: 0, transformOrigin: "50% 50%" },
    {
      autoAlpha: 1,
      scale: 1,
      duration: mediaCalloutNodeDurationSeconds,
      ease: "back.out(1.5)",
    },
    startAtSeconds,
  );
  timeline.fromTo(
    route,
    { strokeDashoffset: pathLength },
    { strokeDashoffset: 0, duration: mediaCalloutRouteDurationSeconds, ease: "none" },
    startAtSeconds + mediaCalloutNodeDurationSeconds,
  );
  timeline.fromTo(
    label,
    { autoAlpha: 0 },
    { autoAlpha: 1, duration: mediaCalloutLabelDurationSeconds, ease: "power1.out" },
    startAtSeconds + mediaCalloutNodeDurationSeconds + mediaCalloutRouteDurationSeconds,
  );
}

function addMediaCalloutOutro(
  timeline: MediaCalloutTimeline,
  targetNode: SVGSVGElement,
  route: SVGPathElement,
  label: HTMLSpanElement,
  pathLength: number,
  startAtSeconds: number,
): void {
  timeline.to(label, { autoAlpha: 0, duration: mediaCalloutLabelDurationSeconds }, startAtSeconds);
  timeline.to(
    route,
    {
      strokeDashoffset: pathLength,
      duration: mediaCalloutRouteDurationSeconds,
      ease: "none",
    },
    startAtSeconds + mediaCalloutLabelDurationSeconds,
  );
  timeline.to(
    targetNode,
    {
      autoAlpha: 0,
      scale: 0,
      duration: mediaCalloutNodeDurationSeconds,
      ease: "power1.in",
    },
    startAtSeconds + mediaCalloutLabelDurationSeconds + mediaCalloutRouteDurationSeconds,
  );
}

export function mountMediaCallout(
  stageElement: HTMLElement,
  parameters: MediaCalloutParameters,
  timeline: MediaCalloutTimeline,
): MediaCalloutMount {
  validateMediaCalloutParameters(parameters);
  if (!timeline.paused()) {
    throw new Error("Media callout motion requires a paused, host-owned GSAP timeline.");
  }
  if (
    stageElement.clientWidth !== parameters.stage.width ||
    stageElement.clientHeight !== parameters.stage.height
  ) {
    throw new RangeError(
      `The stage element must measure ${String(parameters.stage.width)}×${String(parameters.stage.height)} CSS pixels.`,
    );
  }
  const ownerWindow = stageElement.ownerDocument.defaultView;
  if (ownerWindow === null) {
    throw new Error("The media callout stage has no owning window.");
  }
  if (ownerWindow.getComputedStyle(stageElement).position === "static") {
    throw new Error("The media callout stage must establish a positioned containing block.");
  }

  const root = createMediaCalloutRoot(stageElement.ownerDocument);
  const { svg: routeSvg, path: route } = createMediaCalloutRoute(
    stageElement.ownerDocument,
    parameters.stage,
  );
  const targetNode = createMediaCalloutNode(stageElement.ownerDocument);
  const targetAnchor = createMediaCalloutNodeAnchor(stageElement.ownerDocument, targetNode);
  const label = createMediaCalloutLabel(stageElement.ownerDocument, parameters.text);
  root.append(routeSvg, targetAnchor, label);
  stageElement.append(root);

  try {
    const labelPosition = applyMediaCalloutLayout(parameters, route, targetAnchor, label);
    const pathLength = route.getTotalLength();
    const reducedMotion = mediaCalloutPrefersReducedMotion(ownerWindow);
    const animation: MediaCalloutAnimation = reducedMotion ? "held" : parameters.animation;
    const startAtSeconds = parameters.startAtSeconds ?? 0;
    const endAtSeconds =
      animation === "held" ? startAtSeconds : startAtSeconds + mediaCalloutInDurationSeconds;

    route.style.strokeDasharray = String(pathLength);
    route.style.strokeDashoffset = animation === "in" ? String(pathLength) : "0";
    if (animation === "out") {
      prepareMediaCalloutHeldState(targetNode, route, label, pathLength);
      addMediaCalloutOutro(timeline, targetNode, route, label, pathLength, startAtSeconds);
    } else if (animation === "in") {
      targetNode.style.opacity = "0";
      targetNode.style.transform = "scale(0)";
      route.style.opacity = "1";
      label.style.opacity = "0";
      addMediaCalloutIntro(timeline, targetNode, route, label, pathLength, startAtSeconds);
    } else {
      prepareMediaCalloutHeldState(targetNode, route, label, pathLength);
    }

    return {
      root,
      targetNode,
      route,
      label,
      labelPosition,
      startAtSeconds,
      endAtSeconds,
      animation,
    };
  } catch (error: unknown) {
    root.remove();
    throw error;
  }
}
