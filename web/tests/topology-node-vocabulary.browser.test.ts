import { describe, expect, inject, it } from "vitest";
import { commands } from "vitest/browser";

import type {
  TopologyGlyphObservation,
  TopologyNodeVocabularyResult,
} from "./topology-node-vocabulary-browser-command.ts";

declare module "vitest/browser" {
  interface BrowserCommands {
    verifyTopologyNodeVocabulary(pageUrl: string): Promise<TopologyNodeVocabularyResult>;
  }
}

function ofKind(
  glyphs: readonly TopologyGlyphObservation[],
  kinds: readonly string[],
): readonly TopologyGlyphObservation[] {
  return glyphs.filter((glyph) => kinds.includes(glyph.kind));
}

describe("topology node vocabulary on the home page", () => {
  it("classifies the finale ring as the primary end node, separate from merges", async () => {
    const result = await commands.verifyTopologyNodeVocabulary(inject("siteHeaderBrowserTestUrl"));
    const terminals = result.afterReveal.filter((glyph) => glyph.finaleTerminal);
    expect(terminals).toHaveLength(1);
    expect
      .soft(
        ofKind(result.afterReveal, ["merge"])
          .filter((glyph) => glyph.glyph.color === glyph.laneColor)
          .map((glyph) => ({ kind: glyph.kind, finaleTerminal: glyph.finaleTerminal })),
      )
      .toEqual([]);
    expect(terminals[0]?.kind).toBe("end");
    expect(terminals[0]?.glyph.stroke).toBe(result.primaryColor);
    expect(terminals[0]?.glyph.fill).toBe(result.canvasColor);
    expect(terminals[0]?.glyph.radius).toBe(6);
    expect(terminals[0]?.glyph.strokeWidth).toBe("2px");
    expect(terminals[0]?.core?.radius).toBe(2.5);
    expect(terminals[0]?.core?.fill).toBe(result.primaryColor);
    expect(ofKind(result.afterReveal, ["merge"]).some((glyph) => glyph.finaleTerminal)).toBe(false);
  });

  it("draws each node kind with its own glyph, color, and size", async () => {
    // Act
    const result = await commands.verifyTopologyNodeVocabulary(inject("siteHeaderBrowserTestUrl"));
    expect(result.routeFilters.length).toBeGreaterThan(0);
    expect(result.routeFilters).toEqual(result.routeFilters.map(() => "none"));
    // Assert: before the reveal, every glyph is a faint thin outline at its own size.
    const unrevealed = result.beforeReveal.filter((glyph) => !glyph.revealed);
    expect(unrevealed.length).toBeGreaterThan(0);
    for (const glyph of unrevealed) {
      expect(glyph.glyph.fill).toBe(result.canvasColor);
      expect(glyph.glyph.strokeWidth).toBe("1px");
      expect(glyph.core?.opacity ?? "0").toBe("0");
    }
    const sizeOf = (kind: string): number | undefined =>
      result.beforeReveal.find((glyph) => glyph.kind === kind)?.glyph.radius;
    expect(sizeOf("commit")).toBeLessThan(sizeOf("chapter") ?? 0);
    expect(sizeOf("chapter")).toBeLessThanOrEqual(sizeOf("merge") ?? 0);

    // Commits and forks: small solid dots in their lane's color.
    const dots = ofKind(result.afterReveal, ["commit", "fork"]);
    expect(dots.length).toBeGreaterThan(0);
    for (const dot of dots) {
      expect(dot.glyph.fill).toBe(dot.laneColor);
      expect(dot.glyph.stroke).toBe(dot.laneColor);
    }

    // Merges: a ring in the incoming lane's color around a dot in the
    // receiving lane's color, with canvas between them.
    const merges = ofKind(result.afterReveal, ["merge"]);
    expect(merges.length).toBeGreaterThan(0);
    for (const merge of merges) {
      expect(merge.glyph.stroke).toBe(merge.glyph.color);
      expect(merge.glyph.color).not.toBe(merge.laneColor);
      expect(merge.glyph.fill).toBe(result.canvasColor);
      expect(merge.glyph.strokeWidth).toBe("2px");
      expect(merge.core?.fill).toBe(merge.laneColor);
      expect(merge.core?.opacity).toBe("1");
      expect(merge.core?.radius).toBeLessThan(merge.glyph.radius);
    }

    // Chapters: a primary ring, solid once passed, and the terminal when current.
    const chapters = ofKind(result.afterReveal, ["chapter"]);
    const current = chapters.filter((chapter) => chapter.chapterState === "current");
    const passed = chapters.filter((chapter) => chapter.chapterState === "passed");
    expect(current).toHaveLength(1);
    expect(passed.length).toBeGreaterThan(0);
    for (const chapter of passed) {
      expect(chapter.glyph.stroke).toBe(result.primaryColor);
      expect(chapter.glyph.fill).toBe(result.primaryColor);
    }
    expect(current[0]?.glyph.display).toBe("none");
    expect(current[0]?.terminalDisplay).toBe("inline");
    const upcoming = ofKind(result.beforeReveal, ["chapter"]).filter(
      (chapter) => chapter.chapterState === "upcoming" && chapter.revealed,
    );
    for (const chapter of upcoming) {
      expect(chapter.glyph.stroke).toBe(result.primaryColor);
      expect(chapter.glyph.fill).toBe(result.canvasColor);
    }

    // Attach branches keep their lane weight and end on the target edge
    // with no extra node. Step-line ports join their blue lane without a gradient.
    expect(result.ports.length).toBeGreaterThan(0);
    const fromWorktree = result.ports.filter((port) => !port.stepLine && port.source !== "main");
    const stepLinePorts = result.ports.filter((port) => port.stepLine);
    expect(result.stepLineCount).toBeGreaterThan(0);
    expect(stepLinePorts).toHaveLength(result.stepLineCount);
    for (const port of result.ports) {
      expect(port.strokeWidth).toBe(port.laneStrokeWidth);
      expect(port.nodeCount).toBe(0);
      expect(port.endpointOffset).toBeLessThanOrEqual(port.terminal ? 6.5 : 1);
    }
    for (const port of fromWorktree) {
      expect(port.stroke).toMatch(/^url\("?#topology-port-gradient-/u);
      expect(port.firstStopColor).toBe(port.sourceLaneStroke);
    }
    for (const port of stepLinePorts) {
      expect(port.sourceLaneStroke).toBeDefined();
      expect(port.stroke).toBe(result.primaryColor);
      expect(port.firstStopColor).toBeUndefined();
    }
  });
});
