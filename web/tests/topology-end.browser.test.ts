import { describe, expect, inject, it } from "vitest";
import { commands } from "vitest/browser";

import { installCommandText, marketingCopy } from "../src/marketing-copy";
import type {
  TopologyEndObservation,
  FinaleMainFieldGroups,
  FinaleMainFieldGroup,
  FinaleMainSample,
  FinaleReducedMotionObservation,
  FinaleSkipAndResizeObservation,
} from "./topology-end-browser-command.ts";
import { sharpCornerCount } from "./topology-path-corners";

declare module "vitest/browser" {
  interface BrowserCommands {
    verifyTopologyEnd(
      pageUrl: string,
      widths: readonly number[],
      viewportHeight?: number,
    ): Promise<TopologyEndObservation[]>;
    // Wire fields are Partial; read observations only through guardFinaleMainSample.
    observeFinaleMainPage<TGroup extends FinaleMainFieldGroup>(
      pageUrl: string,
      proofWidth: number,
      groups: readonly TGroup[],
    ): Promise<FinaleMainSample<TGroup>>;
    observeFinaleReducedMotion(pageUrl: string): Promise<FinaleReducedMotionObservation>;
    observeFinaleSkipAndResize(pageUrl: string): Promise<FinaleSkipAndResizeObservation>;
  }
}

const finaleMainFieldGroups = {
  readyOutlineAt03: "outline",
  traceOpacityAt03: "outline",
  readyOutlineAt08: "outline",
  traceOpacityAt08: "outline",
  traceDashFractionAt08: "outline",
  readyOutlineAfterReverseSeek: "outline",
  traceOpacityAfterReverseSeek: "outline",
  tracePathData: "outline",
  pillHeight: "outline",
  pillWidth: "outline",
  eventCount: "playback",
  transitionalFanAngles: "playback",
  transitionalPlaneBorderWidths: "playback",
  finalState: "playback",
  logoOpacity: "playback",
  traceOpacity: "playback",
  railStartFraction: "playback",
  railArrivalFraction: "playback",
  nodeStartOpacity: "playback",
  nodeArrivalOpacity: "playback",
  sectionHeightDelta: "playback",
  footerTopDelta: "playback",
  pillBorderColor: "pill",
  pillBorderWidth: "pill",
  pillOverflowX: "pill",
  starLeftOffset: "pill",
  copyRightRadius: "pill",
  terminalHaloDisplay: "pill",
  href: "pill",
  copiedIconVisible: "pill",
  oldInstallBoxCount: "pill",
  ctaParagraphCount: "pill",
  splitPillCount: "pill",
  starText: "pill",
  copyText: "pill",
  copiedText: "pill",
  copyCount: "pill",
  copiedLabel: "pill",
  resizedTraceWidthDelta: "resizedTrace",
  resizedViewBoxWidthDelta: "resizedTrace",
  settledDashCleared: "resizedTrace",
  pillStyle: "paint",
  stepPillStyle: "paint",
  segmentColorsMatch: "paint",
  iconsAreThinOutlines: "paint",
  ancestorPaintExtent: "paint",
  nodeTangentDelta: "paint",
  nodeCenterYDelta: "paint",
  traceEdgeDelta: "paint",
  dividerHeightFraction: "paint",
} satisfies {
  readonly [TGroup in FinaleMainFieldGroup as keyof FinaleMainFieldGroups[TGroup]]: TGroup;
};
const finaleGroupByField = new Map<string, FinaleMainFieldGroup>(
  Object.entries(finaleMainFieldGroups),
);
function guardFinaleMainSample<TGroup extends FinaleMainFieldGroup>(
  sample: FinaleMainSample<TGroup>,
  groups: readonly TGroup[],
): FinaleMainSample<TGroup> {
  return new Proxy(sample, {
    get(target, field, receiver): unknown {
      if (typeof field !== "string") return Reflect.get(target, field, receiver);
      const group = finaleGroupByField.get(field);
      if (group !== undefined) {
        if (!groups.some((requested) => requested === group))
          throw new Error(`Field ${field} belongs to unrequested group ${group}`);
        if (!Object.hasOwn(target, field))
          throw new Error(`Missing field ${field} in requested group ${group}`);
      }
      return Reflect.get(target, field, receiver);
    },
  });
}

describe("where the rail ends on the home page", () => {
  it.each([
    [1600, 1000],
    [1280, 800],
    [2000, 1200],
    [390, 844],
  ])("keeps the finale join blue inside the end colour mask at %i×%i", async (width, height) => {
    const [observation] = await commands.verifyTopologyEnd(
      inject("siteHeaderBrowserTestUrl"),
      [width],
      height,
    );
    if (observation === undefined) throw new Error("Finale end observation missing");
    expect
      .soft(observation.endColourMaskEdge)
      .toBeGreaterThanOrEqual(observation.endTerminalNodeBottom + 8);
    expect.soft(observation.branchStroke).toBe(observation.attachJoinStroke);
    expect.soft(observation.ringStroke).toBe(observation.attachJoinStroke);
  });
  it.each([1600, 1280, 390])(
    "matches the finale and step-label pill paints at %ipx",
    async (width) => {
      const groups = ["paint"] as const;
      const observation = guardFinaleMainSample(
        await commands.observeFinaleMainPage(inject("siteHeaderBrowserTestUrl"), width, groups),
        groups,
      );
      expect(observation.pillStyle).toEqual(observation.stepPillStyle);
      expect(observation.segmentColorsMatch).toBe(true);
      expect(observation.iconsAreThinOutlines).toBe(true);
      expect(observation.ancestorPaintExtent).toBeLessThanOrEqual(1);
      expect(observation.nodeTangentDelta).toBeLessThanOrEqual(1);
      expect(observation.nodeCenterYDelta).toBeLessThanOrEqual(1);
      expect(observation.traceEdgeDelta).toBeLessThanOrEqual(1);
      expect(observation.dividerHeightFraction).toBeCloseTo(0.5, 1);
    },
  );
  it("traces the split-pill outline forward and back on seeks", async () => {
    const groups = ["outline"] as const;
    const observation = guardFinaleMainSample(
      await commands.observeFinaleMainPage(inject("siteHeaderBrowserTestUrl"), 1600, groups),
      groups,
    );
    expect(observation.readyOutlineAt03).toBe(true);
    expect(observation.traceOpacityAt03).toBe(0);
    expect(observation.readyOutlineAt08).toBe(false);
    expect(observation.traceOpacityAt08).toBeGreaterThan(0.9);
    expect(observation.traceDashFractionAt08).toBeLessThan(1);
    expect(observation.readyOutlineAfterReverseSeek).toBe(true);
    expect(observation.traceOpacityAfterReverseSeek).toBe(0);
    const firstArc = /A ([\d.]+) ([\d.]+)/u.exec(observation.tracePathData);
    expect(firstArc).not.toBeNull();
    expect(Math.abs(Number(firstArc?.[1]) - observation.pillHeight / 2)).toBeLessThanOrEqual(0.5);
    expect(firstArc?.[1]).toBe(firstArc?.[2]);
  });

  it("plays the finale once at the rail end", async () => {
    const groups = ["playback"] as const;
    const observation = guardFinaleMainSample(
      await commands.observeFinaleMainPage(inject("siteHeaderBrowserTestUrl"), 1600, groups),
      groups,
    );
    expect(observation.eventCount).toBe(1);
    for (const [index, angle] of [0, 7, -12].entries())
      expect(observation.transitionalFanAngles[index]).toBeCloseTo(angle, 1);
    expect(observation.transitionalPlaneBorderWidths).toEqual([1, 1, 1, 1]);
    expect(observation.finalState).toBe("settled");
    expect(observation.logoOpacity).toBe("1");
    expect(observation.traceOpacity).toBe("0");
    expect(observation.railStartFraction).toBeCloseTo(1, 1);
    expect(observation.railArrivalFraction).toBeCloseTo(0, 1);
    expect(observation.nodeStartOpacity).toBe("0");
    expect(observation.nodeArrivalOpacity).toBe("1");
    expect(observation.sectionHeightDelta).toBeCloseTo(0, 1);
    expect(observation.footerTopDelta).toBeCloseTo(0, 1);
  });

  it("copies both install commands from the split pill", async () => {
    const groups = ["pill", "paint"] as const;
    const observation = guardFinaleMainSample(
      await commands.observeFinaleMainPage(inject("siteHeaderBrowserTestUrl"), 1600, groups),
      groups,
    );
    expect.soft(observation.pillStyle).toEqual(observation.stepPillStyle);
    expect.soft(observation.segmentColorsMatch).toBe(true);
    expect.soft(observation.iconsAreThinOutlines).toBe(true);
    expect(observation.pillBorderColor).toBe(observation.stepPillStyle["borderTopColor"]);
    expect(observation.pillBorderWidth).toBe(observation.stepPillStyle["borderTopWidth"]);
    expect(observation.pillOverflowX).toBe("hidden");
    expect(observation.starLeftOffset).toBeLessThanOrEqual(1);
    expect(observation.copyRightRadius).not.toBe("0px");
    expect(observation.terminalHaloDisplay).toBe("none");
    expect(observation.href).toBe(marketingCopy.githubUrl);
    expect(observation.copiedIconVisible).toBe(true);
    expect(observation.oldInstallBoxCount).toBe(0);
    expect(observation.ctaParagraphCount).toBe(1);
    expect(observation.splitPillCount).toBe(1);
    expect(observation.starText).toContain(marketingCopy.finalCallToAction.starOnGitHub);
    expect(observation.copyText).toContain(marketingCopy.finalCallToAction.copyInstall);
    expect(observation.copiedText).toBe(installCommandText);
    expect(observation.copyCount).toBe(1);
    expect(observation.copiedLabel).toBe(marketingCopy.installation.copiedStatus);
  });

  it("retraces the settled split-pill outline after its width changes", async () => {
    const groups = ["resizedTrace"] as const;
    const observation = guardFinaleMainSample(
      await commands.observeFinaleMainPage(inject("siteHeaderBrowserTestUrl"), 1600, groups),
      groups,
    );
    expect(observation.resizedTraceWidthDelta).toBeLessThanOrEqual(1);
    expect(observation.resizedViewBoxWidthDelta).toBeLessThanOrEqual(1);
    expect(observation.settledDashCleared).toBe(true);
  });

  it("keeps the phone split pill in one row and settles under reduced motion", async () => {
    const observation = await commands.observeFinaleReducedMotion(
      inject("siteHeaderBrowserTestUrl"),
    );
    expect(observation.phoneOneRow).toBe(true);
    expect(observation.phoneShortLabels).toBe(true);
    expect(observation.phoneOverflow).toBeLessThanOrEqual(0);
    expect(observation.reducedMotionState).toBe("settled");
    expect(observation.reducedMotionTimelineCreated).toBe(false);
    expect(observation.reducedMotionLogoOpacity).toBe("1");
  });

  it("settles on pointer skip and resize, and fits a 320px heading", async () => {
    const observation = await commands.observeFinaleSkipAndResize(
      inject("siteHeaderBrowserTestUrl"),
    );
    expect(observation.pointerSkipState).toBe("settled");
    expect(observation.resizeSettleState).toBe("settled");
    expect(observation.narrowTitleFontSize).toBeLessThan(36);
    expect(observation.narrowHeadingOverflow).toBeLessThanOrEqual(0);
  });

  it("rejects reads from unrequested finale main-page field groups", async () => {
    const groups = ["paint"] as const;
    const observation = guardFinaleMainSample(
      await commands.observeFinaleMainPage(inject("siteHeaderBrowserTestUrl"), 1600, groups),
      groups,
    );
    expect(() => {
      // @ts-expect-error A paint-only sample cannot expose playback state.
      return observation.eventCount;
    }).toThrow("Field eventCount belongs to unrequested group playback");
  });
  it("ends at the Star button after the lanes close below the final glass", async () => {
    const observations = await commands.verifyTopologyEnd(
      inject("siteHeaderBrowserTestUrl"),
      [390, 1280, 1920, 2000],
    );
    for (const observation of observations) {
      expect(
        Math.abs(observation.pillLeft - observation.lastGlassLeft),
        `${observation.width}px pill/glass`,
      ).toBeLessThanOrEqual(1);
      expect(
        Math.abs(observation.stageLeft - observation.lastGlassLeft),
        `${observation.width}px row/glass`,
      ).toBeLessThanOrEqual(1);
      expect(
        Math.abs(observation.noteLeft - observation.lastGlassLeft),
        `${observation.width}px note/glass`,
      ).toBeLessThanOrEqual(1);
      expect(
        observation.captionToFinaleGap,
        `${observation.width}px separation`,
      ).toBeGreaterThanOrEqual(Math.min(Math.max(observation.width * 0.24, 240), 400));
      for (const artwork of observation.artworkStates) {
        const label = `${artwork.width}px ${artwork.state}`;
        expect(
          Math.abs(artwork.artworkLeft - artwork.pillLeft),
          `${label} left`,
        ).toBeLessThanOrEqual(1);
        expect(
          Math.abs(artwork.artworkHeight / artwork.titleCapHeight - 1),
          `${label} height`,
        ).toBeLessThanOrEqual(0.1);
        expect(
          Math.abs(artwork.titleLeft - artwork.artworkRight - artwork.titleFontSize * 0.25),
          `${label} gap`,
        ).toBeLessThanOrEqual(2);
      }
      expect(
        Math.abs(observation.stageLeft - observation.pillLeft),
        `${observation.width}px icon`,
      ).toBeLessThanOrEqual(1);
      expect(
        Math.abs(observation.titleLeft - observation.stageRight - observation.titleFontSize * 0.25),
        `${observation.width}px title gap`,
      ).toBeLessThanOrEqual(1);
      expect(
        Math.abs(observation.noteLeft - observation.pillLeft),
        `${observation.width}px note`,
      ).toBeLessThanOrEqual(1);
      expect(
        Math.abs(observation.stageCenterY - observation.titleCenterY),
        `${observation.width}px row`,
      ).toBeLessThanOrEqual(2);
      expect(
        Math.abs(observation.stageHeight - observation.titleLineHeight),
        `${observation.width}px stage height`,
      ).toBeLessThanOrEqual(2);
      expect(observation.pathData.length, String(observation.width)).toBeGreaterThan(0);
      for (const path of observation.pathData) {
        expect(sharpCornerCount(path.d), `${observation.width}px ${path.kind}: ${path.d}`).toBe(0);
      }
      expect(observation.nodeRightX, String(observation.width)).toBeCloseTo(
        observation.pillLeft,
        0,
      );
      expect(observation.branchEndY, String(observation.width)).toBeCloseTo(
        observation.pillCenterY,
        0,
      );
      expect(observation.lowestRailY).toBeLessThanOrEqual(observation.pillCenterY + 0.01);
      expect(observation.terminalNodeCount).toBe(1);
      expect(observation.terminalRouteCount).toBe(1);
      expect(observation.branchViewportMaxFraction).toBeLessThan(0.75);
      expect(
        Math.abs(observation.branchStartX - observation.innermostLaneX),
        `${observation.width}px branch source`,
      ).toBeLessThanOrEqual(1);
      if (observation.laneCount > 0)
        expect(
          observation.mainlineEndY,
          `${observation.width}px trunk ends before finale branch`,
        ).toBeLessThan(observation.branchStartY);
      else
        expect(
          observation.mainlineEndY,
          `${observation.width}px sole trunk continues to finale`,
        ).toBeCloseTo(observation.branchStartY, 0);
      expect(observation.branchColumnSpan, String(observation.width)).toBeLessThanOrEqual(2);
      expect(observation.branchBendCount).toBe(1);
      expect(observation.bendDotCount, `${observation.width}px bend dot count`).toBe(1);
      expect(
        observation.bendDotOffset,
        `${observation.width}px bend dot centre`,
      ).toBeLessThanOrEqual(0.5);
      expect(observation.bendDotPlain, `${observation.width}px plain bend dot`).toBe(true);
      expect(observation.branchMonotonicX, `${observation.width}px final path moves right`).toBe(
        true,
      );
      expect(observation.mainlineBendCount).toBe(0);
      expect(observation.minimumTitleClearance).toBeGreaterThanOrEqual(12);
      expect(observation.ringRadius).toBe(6);
      expect(observation.coreRadius).toBe(2.5);
      expect(observation.haloRadius).toBe(7);
      expect(observation.ringStroke).toBe(observation.attachJoinStroke);
      expect(observation.coreFill).toBe("rgb(137, 180, 250)");
      expect(observation.branchStroke).toBe(observation.attachJoinStroke);
      const sideLaneCount = Math.max(0, observation.laneCount - 1);
      const expectedMerges = sideLaneCount === 0 ? 0 : 1 + Math.floor((sideLaneCount - 1) / 2);
      expect(observation.laneMergeYs).toHaveLength(expectedMerges);
      expect(observation.laneStopYs).toHaveLength(sideLaneCount - expectedMerges);
      expect(observation.duplicateRowDotCount).toBe(0);
      const trunkMergeY = Math.max(...observation.laneMergeYs);
      for (const stopY of observation.laneStopYs) {
        expect(stopY).toBeGreaterThan(observation.lastGlassBottomY);
        expect(stopY).toBeLessThan(trunkMergeY);
      }
      for (const mergeY of observation.laneMergeYs) {
        expect(mergeY).toBeGreaterThan(observation.lastGlassBottomY);
        expect(mergeY).toBeLessThan(observation.branchStartY);
      }
    }
  });
  it("ignores the retired finale route query", async () => {
    const defaultRoutes = await commands.verifyTopologyEnd(
      inject("siteHeaderBrowserTestUrl"),
      [390, 1280, 1920],
    );
    const queriedRoutes = await commands.verifyTopologyEnd(
      `${inject("siteHeaderBrowserTestUrl")}?finale=trunk`,
      [390, 1280, 1920],
    );
    for (const [index, defaultRoute] of defaultRoutes.entries()) {
      const queriedRoute = queriedRoutes[index];
      if (queriedRoute === undefined) throw new Error("Queried finale route missing");
      expect(queriedRoute.branchStartX).toBe(defaultRoute.branchStartX);
      expect(queriedRoute.branchStartY).toBe(defaultRoute.branchStartY);
      expect(queriedRoute.branchEndX).toBe(defaultRoute.branchEndX);
      expect(queriedRoute.branchPathData).toBe(defaultRoute.branchPathData);
      expect(queriedRoute.mainlinePathData).toBe(defaultRoute.mainlinePathData);
    }
  });
});
