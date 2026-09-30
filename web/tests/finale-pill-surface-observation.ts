export interface FinalePillSurfaceObservation {
  readonly pillStyle: Readonly<Record<string, string>>;
  readonly stepPillStyle: Readonly<Record<string, string>>;
  readonly segmentColorsMatch: boolean;
  readonly iconsAreThinOutlines: boolean;
  readonly ancestorPaintExtent: number;
  readonly nodeTangentDelta: number;
  readonly nodeCenterYDelta: number;
  readonly traceEdgeDelta: number;
  readonly dividerHeightFraction: number;
}

/** Serialized into the real page by the existing browser command. */
export function observeFinalePillSurface(): FinalePillSurfaceObservation {
  const root = document.querySelector<HTMLElement>("[data-finale-root]");
  const pill = root?.querySelector<HTMLElement>("[data-finale-split-pill]");
  const stepPill = document.querySelector<HTMLElement>(".chapter-step-active-label");
  const star = root?.querySelector<HTMLElement>("[data-final-star-button]");
  const copy = root?.querySelector<HTMLElement>("[data-install-copy]");
  const trace = root?.querySelector<SVGPathElement>("[data-finale-border-trace]");
  const ring = document.querySelector<SVGCircleElement>(
    "[data-topology-terminal-node] .node-end-ring",
  );
  if (!root || !pill || !stepPill || !star || !copy || !trace || !ring)
    throw new Error("Finale painted surface proof missing");
  const paint = (element: HTMLElement): Readonly<Record<string, string>> => {
    const style = getComputedStyle(element);
    return {
      background: style.background,
      borderTopColor: style.borderTopColor,
      borderTopWidth: style.borderTopWidth,
      borderRadius: style.borderRadius,
      color: style.color,
      fontSize: style.fontSize,
      fontWeight: style.fontWeight,
      boxShadow: style.boxShadow,
    };
  };
  const pillBox = pill.getBoundingClientRect();
  let ancestorPaintExtent = 0;
  for (
    let ancestor = pill.parentElement;
    ancestor !== null && root.contains(ancestor);
    ancestor = ancestor.parentElement
  ) {
    const style = getComputedStyle(ancestor);
    const hasPaint =
      style.backgroundImage !== "none" ||
      !["transparent", "rgba(0, 0, 0, 0)"].includes(style.backgroundColor) ||
      style.boxShadow !== "none";
    if (!hasPaint) continue;
    const bounds = ancestor.getBoundingClientRect();
    ancestorPaintExtent = Math.max(
      ancestorPaintExtent,
      pillBox.left - bounds.left,
      bounds.right - pillBox.right,
      pillBox.top - bounds.top,
      bounds.bottom - pillBox.bottom,
    );
  }
  // Canonical circles live in SVG defs; the visible rail uses that same geometry.
  const artwork = ring.ownerSVGElement;
  const matrix = artwork?.getScreenCTM();
  if (matrix === null || matrix === undefined) throw new Error("Terminal rail matrix missing");
  const ringCenter = new DOMPoint(ring.cx.baseVal.value, ring.cy.baseVal.value).matrixTransform(
    matrix,
  );
  const ringRight = new DOMPoint(
    ring.cx.baseVal.value + ring.r.baseVal.value,
    ring.cy.baseVal.value,
  ).matrixTransform(matrix);
  const traceBox = trace.getBoundingClientRect();
  return {
    pillStyle: paint(pill),
    stepPillStyle: paint(stepPill),
    segmentColorsMatch: [star, copy].every(
      (segment) => getComputedStyle(segment).color === getComputedStyle(stepPill).color,
    ),
    iconsAreThinOutlines: [star, copy].every((segment) => {
      const shapes = [...segment.querySelectorAll<SVGElement>("svg path, svg rect")];
      return (
        shapes.length > 0 &&
        shapes.every((shape) => {
          const style = getComputedStyle(shape);
          return style.fill === "none" && style.stroke !== "none" && style.strokeWidth === "1.5px";
        })
      );
    }),
    ancestorPaintExtent,
    nodeTangentDelta: Math.abs(ringRight.x - pillBox.left),
    nodeCenterYDelta: Math.abs(ringCenter.y - (pillBox.top + pillBox.bottom) / 2),
    traceEdgeDelta: Math.max(
      Math.abs(traceBox.left - pillBox.left),
      Math.abs(traceBox.right - pillBox.right),
      Math.abs(traceBox.top - pillBox.top),
      Math.abs(traceBox.bottom - pillBox.bottom),
    ),
    dividerHeightFraction:
      Number.parseFloat(getComputedStyle(copy, "::before").height) /
      copy.getBoundingClientRect().height,
  };
}
