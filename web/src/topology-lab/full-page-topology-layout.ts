// Measures the chapter DOM contract hooks, composes the topology, and writes it
// into the artwork: the mainline, one group per route (clearance + core path),
// and one node per row. Rendering is keyed so unchanged frames rewrite nothing.
//
// Relative imports keep this module loadable by Vitest, which has no "@/" alias.
import {
  railAnchorAttribute,
  railMediaTargetAttribute,
  railStepLineTargetAttribute,
  railSurfaceTargetAttribute,
  railTargetEdgeAttribute,
  railTerminalTargetAttribute,
} from "../chapters/chapter-dom-contract";
import {
  composeFullPageTopology,
  type TopologyAnchorMeasurement,
  type TopologyComposition,
  type TopologyRect,
  type TopologyRoute,
  type TopologyRowDot,
} from "./full-page-topology-composition";
import { topologyMergeNodeRadius } from "./full-page-topology-model";

const svgNamespace = "http://www.w3.org/2000/svg";
// The node vocabulary, smallest to largest: commit and fork dots, the chapter
// ring and the two-parent merge ring, then the current chapter's terminal
// (r=7, from the retired artwork).
export const topologyNodeRadii = {
  commit: 3.5,
  chapter: 5.5,
  merge: topologyMergeNodeRadius,
  mergeCore: 2.5,
  terminal: 7,
} as const;

/** `<g data-topology-chapter-node="<anchorId>">`: the mainline dot level with each chapter anchor. */
export const topologyChapterNodeAttribute = "data-topology-chapter-node";
/** The gradient a port's stroke shifts along, from its source lane to primary. */
export const topologyPortGradientAttribute = "data-topology-port-gradient";
/** `"left" | "top"` on a chapter node: the glass edge its branch enters; its glass lights when current. */
export const topologyChapterTargetEdgeAttribute = "data-topology-target-edge";

function createSvgElement<TTagName extends keyof SVGElementTagNameMap>(
  ownerDocument: Document,
  tagName: TTagName,
): SVGElementTagNameMap[TTagName] {
  return ownerDocument.createElementNS(svgNamespace, tagName);
}

function setAttributeIfChanged(element: Element, name: string, value: string): void {
  if (element.getAttribute(name) !== value) {
    element.setAttribute(name, value);
  }
}

/**
 * The first rendered element per non-empty id wins, so a duplicated id cannot
 * draw two branches and a `display: none` responsive variant cannot claim one.
 */
function elementsById(ownerDocument: Document, attribute: string): Map<string, HTMLElement> {
  const elements = new Map<string, HTMLElement>();
  for (const element of ownerDocument.querySelectorAll<HTMLElement>(`[${attribute}]`)) {
    const id = element.getAttribute(attribute)?.trim() ?? "";
    if (id !== "" && !elements.has(id) && element.getClientRects().length > 0) {
      elements.set(id, element);
    }
  }
  return elements;
}

/**
 * The anchor's copy block: the outermost rendered ancestor of the anchor that
 * does not contain the media target and ends above it (the chapter header or
 * the hero copy column). Boxless `display: contents` wrappers are skipped, and
 * the anchor itself is the fallback.
 */
function findCopyBlock(anchor: HTMLElement, media: HTMLElement): Element {
  const mediaTop = media.getBoundingClientRect().top;
  let copyBlock: Element = anchor;
  for (
    let ancestor = anchor.parentElement;
    ancestor !== null && !ancestor.contains(media);
    ancestor = ancestor.parentElement
  ) {
    if (
      ancestor.getClientRects().length > 0 &&
      ancestor.getBoundingClientRect().bottom <= mediaTop + 0.5
    ) {
      copyBlock = ancestor;
    }
  }
  return copyBlock;
}

function measureAnchors(artwork: SVGSVGElement): readonly TopologyAnchorMeasurement[] {
  const ownerDocument = artwork.ownerDocument;
  const origin = artwork.getBoundingClientRect();
  const measure = (element: Element): TopologyRect => {
    const bounds = element.getBoundingClientRect();
    return {
      left: bounds.left - origin.left,
      top: bounds.top - origin.top,
      width: bounds.width,
      height: bounds.height,
    };
  };
  const surfaces = elementsById(ownerDocument, railSurfaceTargetAttribute);
  const medias = elementsById(ownerDocument, railMediaTargetAttribute);
  const stepLines = elementsById(ownerDocument, railStepLineTargetAttribute);
  return [...elementsById(ownerDocument, railAnchorAttribute)].map(([id, anchor]) => {
    const surface = surfaces.get(id);
    const media = medias.get(id);
    const stepLine = stepLines.get(id);
    const firstLine = firstLineBox(anchor);
    const declaredEdge = surface?.getAttribute(railTargetEdgeAttribute);
    return {
      id,
      chapter: anchor.closest("[data-chapter]") !== null,
      rect: measure(anchor),
      surface: surface === undefined ? undefined : measure(surface),
      targetEdge: declaredEdge === "top" || declaredEdge === "left" ? declaredEdge : undefined,
      terminalTarget: surface?.hasAttribute(railTerminalTargetAttribute) === true,
      media: media === undefined ? undefined : measure(media),
      stepLine: stepLine === undefined ? undefined : measure(stepLine),
      copyBlock: media === undefined ? undefined : measure(findCopyBlock(anchor, media)),
      lineY:
        firstLine === undefined ? undefined : firstLine.top - origin.top + firstLine.height / 2,
    };
  });
}

/** The box of an element's first rendered line of text, in viewport coordinates. */
function firstLineBox(element: Element): DOMRect | undefined {
  const range = element.ownerDocument.createRange();
  range.selectNodeContents(element);
  return [...range.getClientRects()].find((box) => box.width > 0 && box.height > 0);
}

function progressForY(composition: TopologyComposition, y: number): number {
  const startY = composition.rowYs[0] ?? 0;
  const endY = composition.rowYs.at(-1) ?? startY;
  return endY <= startY ? 1 : Math.min(Math.max((y - startY) / (endY - startY), 0), 1);
}

/**
 * A port leaving a worktree lane shifts hue along its length: a gradient from
 * the lane's stroke color to the port's muted primary, laid out in user space
 * from the port's start to its end. Ports leaving the mainline (already
 * primary) need none.
 */
function portGradientFor(
  ownerDocument: Document,
  route: TopologyRoute,
): SVGLinearGradientElement | undefined {
  if (
    route.kind !== "attach" ||
    route.sourceAccent === undefined ||
    route.sourceAccent === "main"
  ) {
    return undefined;
  }
  const gradient = createSvgElement(ownerDocument, "linearGradient");
  gradient.id = `topology-port-gradient-${route.id}`;
  gradient.setAttribute("gradientUnits", "userSpaceOnUse");
  gradient.setAttribute(topologyPortGradientAttribute, "");
  for (const [offset, accent] of [
    ["0", route.sourceAccent],
    ["1", "port"],
  ] as const) {
    const stop = createSvgElement(ownerDocument, "stop");
    stop.setAttribute("offset", offset);
    stop.setAttribute("class", `topology-port-stop topology-port-stop-${accent}`);
    gradient.append(stop);
  }
  return gradient;
}

/** The first point of a path's data (its `M x y`). */
function pathStartPoint(pathData: string): { readonly x: number; readonly y: number } {
  const [, x = "0", y = "0"] = /^M\s*(-?[\d.]+)[\s,]+(-?[\d.]+)/u.exec(pathData) ?? [];
  return { x: Number(x), y: Number(y) };
}

function createRouteGroup(ownerDocument: Document, route: TopologyRoute): SVGGElement {
  const group = createSvgElement(ownerDocument, "g");
  group.setAttribute("class", `topology-route accent-${route.accent}`);
  group.setAttribute("data-topology-route-group", "");
  group.setAttribute("data-route-id", route.id);
  group.setAttribute("data-route-kind", route.kind);
  group.setAttribute("data-end-kind", "merge");
  group.setAttribute("data-route-column", String(route.column));
  group.setAttribute("data-route-parent-column", String(route.parentColumn));
  group.setAttribute("data-route-source", route.sourceAccent ?? "");
  if (route.anchorId !== undefined) {
    group.setAttribute("data-route-anchor", route.anchorId);
  }
  const gradient = portGradientFor(ownerDocument, route);
  if (gradient !== undefined) {
    group.append(gradient);
  }
  for (const role of ["clearance", "core"] as const) {
    const path = createSvgElement(ownerDocument, "path");
    path.setAttribute(
      "class",
      `${role === "clearance" ? "topology-clearance" : "topology-line"} topology-reveal-path`,
    );
    path.setAttribute("data-route", "");
    path.setAttribute("data-topology-path-role", role);
    if (role === "core" && gradient !== undefined) {
      path.style.stroke = `url(#${gradient.id})`;
    }
    group.append(path);
  }
  if (route.terminal === true && route.targetPoint !== undefined) {
    const terminalNode = createRowNode(ownerDocument, {
      row: -1,
      x: route.targetPoint.x,
      y: route.targetPoint.y,
      ownerId: "main",
      accent: "main",
      kind: "end",
      anchorId: undefined,
      terminal: true,
    });
    terminalNode.setAttribute("data-topology-terminal-node", "");
    group.append(terminalNode);
  }
  return group;
}

function rowDotSignature(dot: TopologyRowDot): string {
  return `${dot.kind}:${dot.accent}:${dot.incomingAccent ?? ""}:${dot.ownerId}:${dot.anchorId ?? ""}:${dot.terminal === true}:${dot.suppressPaint === true}`;
}

function createCircle(
  ownerDocument: Document,
  className: string,
  radius: number,
): SVGCircleElement {
  const circle = createSvgElement(ownerDocument, "circle");
  circle.setAttribute("class", className);
  circle.setAttribute("r", String(radius));
  return circle;
}

/**
 * One row's glyph. The group's accent is the lane the dot sits on; a merge
 * ring carries the incoming lane's accent, around a core in the receiving
 * lane's color.
 */
function createRowNode(ownerDocument: Document, dot: TopologyRowDot): SVGGElement {
  const group = createSvgElement(ownerDocument, "g");
  const terminal = dot.kind === "chapter" || dot.kind === "end" || dot.terminal === true;
  group.setAttribute("class", `${terminal ? "node-terminal-group " : ""}accent-${dot.accent}`);
  group.setAttribute("data-node", "");
  group.setAttribute("data-node-kind", dot.kind);
  if (dot.kind === "end" || dot.terminal === true) {
    group.setAttribute("data-topology-terminal", "");
  }
  if (dot.anchorId !== undefined) {
    group.setAttribute(topologyChapterNodeAttribute, dot.anchorId);
  }
  if (dot.kind === "merge") {
    group.append(
      createCircle(
        ownerDocument,
        `node-merge-ring accent-${dot.incomingAccent ?? dot.accent}`,
        topologyNodeRadii.merge,
      ),
      createCircle(ownerDocument, "node-merge-core", topologyNodeRadii.mergeCore),
    );
  } else if (dot.kind === "end" && dot.terminal === true) {
    // The finale ends the rail; it is not a two-parent merge. Keep its
    // established ring and core geometry tangent to the install pill.
    group.append(
      createCircle(ownerDocument, "node-end-ring", topologyNodeRadii.merge),
      createCircle(ownerDocument, "node-end-core", topologyNodeRadii.mergeCore),
    );
  } else if (dot.kind === "chapter") {
    group.append(createCircle(ownerDocument, "node-chapter", topologyNodeRadii.chapter));
  } else {
    group.append(createCircle(ownerDocument, "node-commit", topologyNodeRadii.commit));
  }
  if (terminal) {
    group.append(createCircle(ownerDocument, "node-terminal-halo", topologyNodeRadii.terminal));
    if (dot.kind !== "merge" && dot.terminal !== true) {
      group.append(createCircle(ownerDocument, "node-terminal", topologyNodeRadii.terminal));
    }
  }
  return group;
}

function hideTopology(artwork: SVGSVGElement, reason: string): boolean {
  artwork.style.visibility = "hidden";
  artwork.dataset["topologyHiddenReason"] = reason;
  return true;
}

/** Lays the topology out from the current page. Returns false when the artwork has no size yet. */
export function layoutFullPageTopology(artwork: SVGSVGElement): boolean {
  if (artwork.clientWidth <= 0 || artwork.clientHeight <= 0) {
    return false;
  }
  const ownerDocument = artwork.ownerDocument;
  const ownerWindow = ownerDocument.defaultView;
  const mainline = artwork.querySelector<SVGPathElement>("[data-mainline]");
  const routeLayer = artwork.querySelector<SVGGElement>("[data-topology-routes]");
  const nodeLayer = artwork.querySelector<SVGGElement>("[data-topology-row-nodes]");
  if (ownerWindow === null || mainline === null || routeLayer === null || nodeLayer === null) {
    return hideTopology(artwork, "incomplete-artwork");
  }
  const composition = composeFullPageTopology({
    viewportWidth: ownerWindow.innerWidth,
    height: artwork.clientHeight,
    anchors: measureAnchors(artwork),
  });
  if (composition === undefined) {
    routeLayer.replaceChildren();
    nodeLayer.replaceChildren();
    mainline.removeAttribute("d");
    return hideTopology(artwork, "no-rail-anchors");
  }

  artwork.style.visibility = "visible";
  delete artwork.dataset["topologyHiddenReason"];
  setAttributeIfChanged(artwork, "viewBox", `0 0 ${artwork.clientWidth} ${artwork.clientHeight}`);
  setAttributeIfChanged(artwork, "data-column-unit", String(composition.columnUnit));
  setAttributeIfChanged(artwork, "data-lane-count", String(composition.laneXs.length));
  setAttributeIfChanged(artwork, "data-mainline-x", String(composition.mainlineX));
  setAttributeIfChanged(artwork, "data-row-count", String(composition.rows.length));
  setAttributeIfChanged(artwork, "data-topology-start-y", String(composition.rowYs[0] ?? 0));
  setAttributeIfChanged(artwork, "data-topology-end-y", String(composition.rowYs.at(-1) ?? 0));
  for (const revealRect of artwork.querySelectorAll<SVGRectElement>(
    "[data-topology-reveal-solid], [data-topology-reveal-fade]",
  )) {
    setAttributeIfChanged(revealRect, "width", String(artwork.clientWidth));
  }

  setAttributeIfChanged(mainline, "d", composition.mainlinePath);
  setAttributeIfChanged(mainline, "data-topology-path-start", "0");
  setAttributeIfChanged(mainline, "data-topology-path-end", "1");

  const routeGroups = [...routeLayer.children].filter(
    (child): child is SVGGElement => child instanceof SVGGElement,
  );
  const routesChanged =
    routeGroups.length !== composition.routes.length ||
    composition.routes.some(
      (route, index) =>
        routeGroups[index]?.dataset["routeId"] !== route.id ||
        !routeGroups[index]?.classList.contains(`accent-${route.accent}`) ||
        routeGroups[index]?.dataset["routeSource"] !== (route.sourceAccent ?? ""),
    );
  const renderedRouteGroups = routesChanged
    ? composition.routes.map((route) => createRouteGroup(ownerDocument, route))
    : routeGroups;
  if (routesChanged) {
    routeLayer.replaceChildren(...renderedRouteGroups);
  }
  for (const [index, route] of composition.routes.entries()) {
    const group = renderedRouteGroups[index];
    if (group === undefined) {
      continue;
    }
    group.toggleAttribute("data-topology-terminal-route", route.terminal === true);
    const terminalNode = group.querySelector<SVGGElement>("[data-topology-terminal-node]");
    if (terminalNode !== null && route.targetPoint !== undefined) {
      for (const circle of terminalNode.querySelectorAll("circle")) {
        setAttributeIfChanged(circle, "cx", String(route.targetPoint.x));
        setAttributeIfChanged(circle, "cy", String(route.targetPoint.y));
      }
      setAttributeIfChanged(terminalNode, "data-node-owner", "main");
      setAttributeIfChanged(
        terminalNode,
        "data-topology-node-progress",
        String(progressForY(composition, route.endY)),
      );
    }
    for (const path of group.querySelectorAll<SVGPathElement>("[data-route]")) {
      setAttributeIfChanged(path, "d", route.pathData);
      setAttributeIfChanged(
        path,
        "data-topology-path-start",
        String(progressForY(composition, route.startY)),
      );
      setAttributeIfChanged(
        path,
        "data-topology-path-end",
        String(progressForY(composition, route.endY)),
      );
    }
    if (route.targetEdge !== undefined) {
      setAttributeIfChanged(group, "data-target-edge", route.targetEdge);
    }
    const gradient = group.querySelector(`[${topologyPortGradientAttribute}]`);
    if (gradient !== null && route.targetPoint !== undefined) {
      const start = pathStartPoint(route.pathData);
      setAttributeIfChanged(gradient, "x1", String(start.x));
      setAttributeIfChanged(gradient, "y1", String(start.y));
      setAttributeIfChanged(gradient, "x2", String(route.targetPoint.x));
      setAttributeIfChanged(gradient, "y2", String(route.targetPoint.y));
    }
  }

  const rowNodes = [...nodeLayer.children].filter(
    (child): child is SVGGElement => child instanceof SVGGElement,
  );
  const nodesChanged =
    rowNodes.length !== composition.rows.length ||
    composition.rows.some(
      (dot, index) => rowNodes[index]?.dataset["nodeSignature"] !== rowDotSignature(dot),
    );
  const renderedRowNodes = nodesChanged
    ? composition.rows.map((dot) => {
        const node = createRowNode(ownerDocument, dot);
        node.dataset["nodeSignature"] = rowDotSignature(dot);
        return node;
      })
    : rowNodes;
  if (nodesChanged) {
    nodeLayer.replaceChildren(...renderedRowNodes);
  }
  const attachEdgeByAnchor = new Map(
    composition.routes.flatMap((route) =>
      route.anchorId === undefined || route.targetEdge === undefined
        ? []
        : [[route.anchorId, route.targetEdge] as const],
    ),
  );
  for (const [index, dot] of composition.rows.entries()) {
    const node = renderedRowNodes[index];
    if (node === undefined) {
      continue;
    }
    for (const circle of node.querySelectorAll("circle")) {
      setAttributeIfChanged(circle, "cx", String(dot.x));
      setAttributeIfChanged(circle, "cy", String(dot.y));
    }
    setAttributeIfChanged(node, "data-node-owner", dot.ownerId);
    node.toggleAttribute("data-topology-suppressed", dot.suppressPaint === true);
    setAttributeIfChanged(node, "data-resolved-row", String(dot.row));
    setAttributeIfChanged(
      node,
      "data-topology-node-progress",
      String(progressForY(composition, dot.y)),
    );
    if (dot.anchorId !== undefined) {
      const edge = attachEdgeByAnchor.get(dot.anchorId);
      if (edge === undefined) {
        node.removeAttribute(topologyChapterTargetEdgeAttribute);
      } else {
        setAttributeIfChanged(node, topologyChapterTargetEdgeAttribute, edge);
      }
    }
  }
  return true;
}
