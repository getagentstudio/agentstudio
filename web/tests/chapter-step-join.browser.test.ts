import { describe, expect, inject, it } from "vitest";
import { commands } from "vitest/browser";

import type { StepLineJoinObservation } from "./chapter-step-join-browser-command";

declare module "vitest/browser" {
  interface BrowserCommands {
    verifyStepLineJoins(
      pageUrl: string,
      widths: readonly number[],
    ): Promise<StepLineJoinObservation[]>;
  }
}

describe("chapter step-line joins", () => {
  it("uses one solid blue and one join geometry across chapters", async () => {
    const observations = await commands.verifyStepLineJoins(
      inject("siteHeaderBrowserTestUrl"),
      [390, 1280, 1600, 1920],
    );
    for (const observation of observations) {
      expect(observation.joins).toHaveLength(5);
      expect(observation.joins.map((join) => join.anchorId)).toEqual([
        "many-agents",
        "context-with-task",
        "find-and-focus",
        "review",
        "come-back",
      ]);
      const first = observation.joins[0];
      if (first === undefined) throw new Error("No step-line joins");
      for (const join of observation.joins) {
        expect(
          join.nodeDistance,
          `${observation.width}px ${join.anchorId} node`,
        ).toBeLessThanOrEqual(1);
        expect(join.nodeCountAtFork, `${observation.width}px ${join.anchorId} one node`).toBe(1);
        expect(
          join.visibleInterveningNodeCount,
          `${observation.width}px ${join.anchorId} stray source-lane dots`,
        ).toBe(0);
        expect(
          join.targetGap,
          `${observation.width}px ${join.anchorId} line landing`,
        ).toBeLessThanOrEqual(1);
        expect(join.landsOnGlassEdge, `${observation.width}px ${join.anchorId} glass edge`).toBe(
          false,
        );
        if (join.anchorId === "review" || join.anchorId === "come-back") {
          expect(join.stepDotCount, join.anchorId).toBe(2);
          expect(join.activeLabelText, join.anchorId).toBe(join.selectedStepLabel);
          expect(join.activeLabelText.trim(), join.anchorId).not.toBe("");
        }
        if (observation.width >= 1024) {
          expect(
            join.sourceY,
            `${observation.width}px ${join.anchorId} title top`,
          ).toBeGreaterThanOrEqual(join.titleTop);
          expect(
            join.sourceY,
            `${observation.width}px ${join.anchorId} title bottom`,
          ).toBeLessThanOrEqual(join.titleBottom);
        }
        expect(join.stroke, `${observation.width}px ${join.anchorId}`).toBe(join.passedStroke);
        expect(
          Math.abs(join.drop - first.drop),
          `${observation.width}px ${join.anchorId} drop`,
        ).toBeLessThanOrEqual(1);
        expect(
          Math.abs(join.leadIn - first.leadIn),
          `${observation.width}px ${join.anchorId} lead-in`,
        ).toBeLessThanOrEqual(1);
        join.controlOffsets.forEach((offset, index) =>
          expect(
            Math.abs(offset - (first.controlOffsets[index] ?? 0)),
            `${observation.width}px ${join.anchorId} control ${index}`,
          ).toBeLessThanOrEqual(1),
        );
      }
    }
  });
});
