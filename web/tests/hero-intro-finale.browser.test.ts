import { expect, inject, it } from "vitest";
import { commands } from "vitest/browser";

import type {
  FinaleObservation,
  FinaleTimesObservation,
  FinaleSample,
  FinaleFieldGroup,
  FinaleFieldGroups,
  FinaleTime,
} from "./hero-intro-finale-browser-command";

declare module "vitest/browser" {
  interface BrowserCommands {
    observeHeroFinaleTimes<TGroup extends FinaleFieldGroup>(
      pageUrl: string,
      width: number,
      height: number,
      times: readonly FinaleTime[] | "all",
      groups: readonly TGroup[],
    ): Promise<FinaleTimesObservation<TGroup>>;
    observeHeroFinaleSettled(
      pageUrl: string,
      width: number,
      height: number,
    ): Promise<FinaleTimesObservation<FinaleFieldGroup>>;
    verifyHeroFinaleDirectSeek(
      pageUrl: string,
      width: number,
      height: number,
    ): Promise<Pick<FinaleObservation, "directSeekSpinnerVisible">>;
    verifyHeroFinaleConstrainedScroll(
      pageUrl: string,
      width: number,
      height: number,
    ): Promise<Pick<FinaleObservation, "scrollProbe">>;
    verifyHeroTranscriptWheel(
      pageUrl: string,
      width: number,
      height: number,
    ): Promise<Pick<FinaleObservation, "wheelScrolls">>;
    verifyHeroFinaleResizeSettle(
      pageUrl: string,
      width: number,
      height: number,
    ): Promise<
      Pick<
        FinaleObservation,
        | "resizeRailClip"
        | "resizeRailStyle"
        | "resizeSceneInlineStyles"
        | "resizeRailIntroMarkers"
        | "resizeRailResidualTransforms"
      >
    >;
    verifyHeroFinaleEscapeSkip(
      pageUrl: string,
      width: number,
      height: number,
    ): Promise<
      Pick<
        FinaleObservation,
        | "skipRailClip"
        | "skipFinaleOpacity"
        | "skipSceneInlineStyles"
        | "skipRailIntroMarkers"
        | "skipRailResidualTransforms"
      >
    >;
    verifyHeroFinaleReducedMotion(
      pageUrl: string,
      width: number,
      height: number,
    ): Promise<
      Pick<
        FinaleObservation,
        | "reducedRailClip"
        | "reducedFinaleOpacity"
        | "reducedRailIntroMarkers"
        | "reducedRailResidualTransforms"
      >
    >;
  }
}

const fieldGroups = {
  firstLine: "copy",
  secondLine: "copy",
  firstPayoff: "copy",
  secondPayoff: "copy",
  payoffOverflow: "copy",
  installOpacity: "claude",
  visibleDecodeLines: "claude",
  readyOpacity: "claude",
  claudeProgressOpacities: "claude",
  copyOpacity: "claude",
  claudeInputText: "claude",
  codexHeaderVisible: "claude",
  claudeSpinnerVisible: "claude",
  claudeRowLineCounts: "claude",
  wrappedClaudeRows: "claude",
  heroText: "claude",
  tokenCount: "tokens",
  tokenTextOverlaps: "tokens",
  tokenVisuals: "tokens",
  installBurstSourceXGap: "tokens",
  installBurstSourceYGap: "tokens",
  installBurstTargetXGap: "tokens",
  installBurstTargetYGap: "tokens",
  installTokenVerticalStrays: "tokens",
  installArrivalTokens: "tokens",
  tokenLayerViewportOffset: "tokens",
  codexTypedText: "codex",
  codexWorkingOpacity: "codex",
  codexInputText: "codex",
  codexHeaderText: "codex",
  codexFooterText: "codex",
  worktreeRowOpacities: "worktree",
  worktreeResultOpacity: "worktree",
  worktreeRowLineCounts: "worktree",
  worktreeTexts: "worktree",
  rowOpacity: "worktree",
  resultVisibleInPane: "worktree",
  offscreenRowPaintLeaks: "worktree",
  railClip: "rail",
  railRevealY: "rail",
  heroNodeY: "rail",
  introDotOpacities: "rail",
  introDotScales: "rail",
  introDotYs: "rail",
  introDotCenterDeltas: "rail",
  introDotTransformIdentities: "rail",
  introDotDebug: "rail",
  heroBranchDashOffset: "rail",
  forkDashOffsets: "rail",
  railBurstTargetDistance: "rail",
  installTransform: "layout",
  realCommandLines: "layout",
  transcriptClearances: "layout",
  transcriptScrollTops: "layout",
  transcriptOverflows: "layout",
  firstVisibleRowTopGaps: "layout",
  firstVisibleRowDebug: "layout",
  appTop: "layout",
  windowHeight: "layout",
  chapterNodeY: "layout",
} satisfies {
  readonly [TGroup in FinaleFieldGroup as keyof FinaleFieldGroups[TGroup]]: TGroup;
};

const groupByField = new Map<string, FinaleFieldGroup>(Object.entries(fieldGroups));

function guardFinaleSample<TGroup extends FinaleFieldGroup>(
  sample: FinaleSample<TGroup>,
  groups: readonly TGroup[],
): FinaleSample<TGroup> {
  return new Proxy(sample, {
    get(target, field, receiver): unknown {
      if (typeof field !== "string") return Reflect.get(target, field, receiver);
      const group = groupByField.get(field);
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

function sampleAccessor<TGroup extends FinaleFieldGroup>(
  observation: FinaleTimesObservation<TGroup>,
  groups: readonly TGroup[],
): (time: FinaleTime) => FinaleSample<TGroup> {
  return (time: FinaleTime): FinaleSample<TGroup> => {
    const sample = observation.samples.find((item) => item.time === time);
    if (sample === undefined) throw new Error(`Missing ${time}s sample`);
    return guardFinaleSample(sample, groups);
  };
}

for (const [width, height] of [
  [1600, 1000],
  [390, 844],
] as const) {
  it(`reveals the two headline lines in order at ${width}px`, async () => {
    const groups = ["copy"] as const;
    const observation = await commands.observeHeroFinaleTimes(
      inject("siteHeaderBrowserTestUrl"),
      width,
      height,
      [0, 0.2, 0.3, 0.45, 0.8, 0.9],
      groups,
    );
    const at = sampleAccessor(observation, groups);
    expect(at(0).firstLine).toBe(0);
    expect(at(0.3).firstLine).toBeGreaterThan(0);
    expect(at(0.8).firstLine).toBe(1);
    expect(at(0.2).secondLine).toBe(0);
    expect(at(0.45).secondLine).toBeGreaterThan(0);
    expect(at(0.9).secondLine).toBe(1);
  });
  it(`runs the Claude turn from progress to the copy button and clears its input at ${width}px`, async () => {
    const groups = ["claude"] as const;
    const observation = await commands.observeHeroFinaleTimes(
      inject("siteHeaderBrowserTestUrl"),
      width,
      height,
      [4.5, 5.5, 6.8, 7.0, 7.2, 7.5, 8.2, 9.0, 11.0, "settled"],
      groups,
    );
    const at = sampleAccessor(observation, groups);
    expect(at(4.5).claudeProgressOpacities[0]).toBeGreaterThan(0);
    expect(at(5.5).claudeSpinnerVisible).toBe(true);
    expect(at(5.5).codexHeaderVisible).toBe(true);
    expect(at(6.8).readyOpacity).toBe(0);
    expect(at(7.2).readyOpacity).toBe(1);
    expect(at(7.2).installOpacity).toBe(0);
    expect(at(7.5).installOpacity).toBe(0);
    expect(at(8.2).installOpacity).toBeGreaterThan(0);
    expect(at(8.2).visibleDecodeLines).toBeGreaterThan(0);
    expect(at(9.0).visibleDecodeLines).toBe(0);
    expect(at(9.0).copyOpacity).toBe(1);
    for (const time of [7.0, 9.0, 11.0, "settled"] as const) {
      expect(at(time).claudeInputText, `${width}px Claude input after send at ${time}`).toBe("");
    }
  });
  it(`shows the spinner after a direct seek at ${width}px`, async () => {
    const observation = await commands.verifyHeroFinaleDirectSeek(
      inject("siteHeaderBrowserTestUrl"),
      width,
      height,
    );
    expect(observation.directSeekSpinnerVisible).toBe(true);
  });
  it(`flies the install token burst into the brew command without covering text at ${width}px`, async () => {
    const groups = ["tokens"] as const;
    const observation = await commands.observeHeroFinaleTimes(
      inject("siteHeaderBrowserTestUrl"),
      width,
      height,
      [
        7.22,
        7.5,
        7.56,
        7.96,
        ...[0.25, 0.5, 0.6, 0.7, 0.75, 0.8].map((fraction) =>
          Number((7.05 + fraction * 0.9).toFixed(3)),
        ),
        ...Array.from({ length: 21 }, (_, index) =>
          Number((7.05 + (0.6 + index * 0.02) * 0.9).toFixed(3)),
        ),
      ],
      groups,
    );
    const at = sampleAccessor(observation, groups);
    expect(at(7.22).tokenCount).toBeGreaterThan(0);
    expect(at(7.22).tokenTextOverlaps).toBe(0);
    expect(at(7.5).tokenCount).toBeGreaterThan(0);
    expect(at(7.5).installBurstSourceXGap).toBeGreaterThanOrEqual(0);
    expect(at(7.5).installBurstSourceXGap).toBeLessThanOrEqual(16);
    expect(at(7.5).installBurstSourceYGap).toBeLessThanOrEqual(4);
    expect(at(7.5).installBurstTargetXGap).toBeGreaterThanOrEqual(4);
    expect(at(7.5).installBurstTargetXGap).toBeLessThanOrEqual(24);
    expect(at(7.5).installBurstTargetYGap).toBeLessThanOrEqual(4);
    expect(at(7.5).tokenLayerViewportOffset).toBeLessThanOrEqual(1);
    expect(at(7.56).tokenCount).toBeGreaterThan(0);
    const installAt = (fraction: number): FinaleSample<"tokens"> =>
      at(Number((7.05 + fraction * 0.9).toFixed(3)));
    for (const fraction of [0.5, 0.6, 0.7, 0.8]) {
      expect(
        installAt(fraction).tokenCount,
        `${width}px tokens at ${fraction}`,
      ).toBeGreaterThanOrEqual(4);
      expect(installAt(fraction).tokenTextOverlaps).toBe(0);
    }
    const arrivalFractions = Array.from({ length: 21 }, (_, index) =>
      Number((0.6 + index * 0.02).toFixed(2)),
    );
    const arrivedIndexes = new Set<number>();
    for (const fraction of arrivalFractions) {
      const sample = installAt(fraction);
      const arrived = sample.installArrivalTokens.filter(
        (token) => token.opacity >= 0.5 && token.distance <= 28,
      );
      expect(arrived.length, `${width}px endpoint pile at ${fraction}`).toBeLessThanOrEqual(4);
      for (const token of arrived) arrivedIndexes.add(token.index);
      expect(sample.tokenTextOverlaps).toBe(0);
    }
    expect(arrivedIndexes.size, `${width}px tokens reaching brew`).toBe(11);
    expect(at(7.96).tokenCount).toBe(0);
    for (const fraction of [0.25, 0.5, 0.75]) {
      const offsets = [7.05];
      for (const start of offsets) {
        const sample = at(Number((start + fraction * 0.9).toFixed(3)));
        expect(sample.tokenCount, `${width}px burst ${start} at ${fraction}`).toBeGreaterThan(0);
        expect(sample.tokenTextOverlaps, `${width}px burst ${start} at ${fraction}`).toBe(0);
        if (start === 7.05)
          expect(
            sample.installTokenVerticalStrays,
            `${width}px install token location at ${fraction}`,
          ).toBe(0);
        if (fraction === 0.5)
          expect(
            Math.max(...sample.tokenVisuals.map((token) => token.opacity)),
            `${width}px burst ${start} peak opacity`,
          ).toBeGreaterThanOrEqual(0.85);
        expect(
          sample.tokenVisuals.every(
            (token) => token.fontSize >= 12 && token.fontSize <= 14 && token.weight === "600",
          ),
        ).toBe(true);
        expect(
          sample.tokenVisuals.every((token) =>
            ["#b4c6e4", "#d4bcad", "#bccfb9", "#c9bfd9", "#b5cdd8", "#d6cdb4"].includes(token.fill),
          ),
        ).toBe(true);
      }
    }
  });
  if (width >= 1024) {
    it(`types and runs the Codex worktree command at ${width}px`, async () => {
      const groups = ["codex", "tokens"] as const;
      const observation = await commands.observeHeroFinaleTimes(
        inject("siteHeaderBrowserTestUrl"),
        width,
        height,
        [7.0, 8.0, 8.82, 9.0, 9.02, 9.22, 9.245, 9.72, 10.3, 11.0, "settled"],
        groups,
      );
      const at = sampleAccessor(observation, groups);
      expect(at(8.82).tokenCount).toBe(0);
      expect(at(8.0).codexTypedText).toBe("");
      expect(at(9.22).codexTypedText).toBe("");
      expect(at(8.82).tokenCount).toBe(0);
      expect(at(8.82).tokenTextOverlaps).toBe(0);
      expect(at(9.02).tokenCount).toBe(0);
      expect(at(9.245).tokenCount).toBe(0);
      expect(at(9.72).codexTypedText.length).toBeGreaterThan(0);
      expect(at(9.72).codexTypedText.length).toBeLessThan("map the worktrees".length);
      expect(at(10.3).codexWorkingOpacity).toBeGreaterThan(0);
      expect(at("settled").codexWorkingOpacity).toBe(0);
      for (const time of [7.0, 9.0, 11.0, "settled"] as const) {
        if (width >= 1024)
          expect(at(time).codexInputText, `${width}px Codex input after send at ${time}`).toBe("");
      }
    });
  }
  it(`shows the worktree rows before the result at ${width}px`, async () => {
    const groups = ["worktree"] as const;
    const observation = await commands.observeHeroFinaleTimes(
      inject("siteHeaderBrowserTestUrl"),
      width,
      height,
      [11.0, 11.3, 11.4, 12.3, 12.8],
      groups,
    );
    const at = sampleAccessor(observation, groups);
    if (width >= 1024) {
      expect(at(11.4).worktreeRowOpacities[0]).toBeGreaterThan(0);
      expect(at(11.0).worktreeResultOpacity).toBe(0);
    }
    expect(at(11.3).worktreeRowOpacities.some((opacity) => opacity > 0)).toBe(true);
    expect(at(11.3).worktreeResultOpacity).toBe(0);
    expect(at(12.3).worktreeResultOpacity).toBe(0);
    expect(at(12.8).worktreeResultOpacity).toBeGreaterThan(0.9);
  });
  it(`draws the rail staircase and branch, then reveals the payoff at ${width}px`, async () => {
    const groups = ["rail", "tokens", "copy"] as const;
    const railBurstStart = width >= 1024 ? 12.35 : 12.65;
    const burstObservation = await commands.observeHeroFinaleTimes(
      inject("siteHeaderBrowserTestUrl"),
      width,
      height,
      [
        12.3,
        13.1,
        13.65,
        ...[0.25, 0.5, 0.75].map((fraction) =>
          Number((railBurstStart + fraction * 0.9).toFixed(3)),
        ),
      ],
      groups,
    );
    const timingPlan = burstObservation.staircase;
    const finalTimingHop = timingPlan.hops.at(-1);
    if (finalTimingHop === undefined) throw new Error("Rail final hop missing");
    const staircaseObservation = await commands.observeHeroFinaleTimes(
      inject("siteHeaderBrowserTestUrl"),
      width,
      height,
      [
        finalTimingHop.start,
        timingPlan.end,
        timingPlan.end + 0.1,
        ...timingPlan.hops.flatMap((hop, index) => {
          const popStart =
            index === 0 ? timingPlan.start : (timingPlan.hops[index - 1]?.arrival ?? hop.start);
          return [popStart + 0.06, popStart + 0.22];
        }),
        "settled",
      ],
      groups,
    );
    const observation = {
      staircase: timingPlan,
      samples: [...burstObservation.samples, ...staircaseObservation.samples],
    };
    const at = sampleAccessor(observation, groups);
    expect(at(13.1).tokenCount).toBeGreaterThan(0);
    expect(at(13.1).tokenTextOverlaps).toBe(0);
    expect(at(13.1).railBurstTargetDistance).toBeLessThanOrEqual(2);
    expect(at(12.3).railClip).toContain("100%");
    expect(at(13.65).railClip).not.toContain("100%");
    expect(at(12.3).firstPayoff).toBe(0);
    const { staircase } = observation;
    const railDrawStart = width >= 1024 ? 13.25 : 13.55;
    expect(staircase.start).toBeGreaterThanOrEqual(railDrawStart);
    expect(staircase.start - railDrawStart).toBeLessThanOrEqual(0.05);
    for (const fraction of [0.25, 0.5, 0.75]) {
      const offsets = [width >= 1024 ? 12.35 : 12.65];
      for (const start of offsets) {
        const sample = at(Number((start + fraction * 0.9).toFixed(3)));
        expect(sample.tokenCount, `${width}px burst ${start} at ${fraction}`).toBeGreaterThan(0);
        expect(sample.tokenTextOverlaps, `${width}px burst ${start} at ${fraction}`).toBe(0);
        if (fraction === 0.5)
          expect(
            Math.max(...sample.tokenVisuals.map((token) => token.opacity)),
            `${width}px burst ${start} peak opacity`,
          ).toBeGreaterThanOrEqual(0.85);
        expect(
          sample.tokenVisuals.every(
            (token) => token.fontSize >= 12 && token.fontSize <= 14 && token.weight === "600",
          ),
        ).toBe(true);
        expect(
          sample.tokenVisuals.every((token) =>
            ["#b4c6e4", "#d4bcad", "#bccfb9", "#c9bfd9", "#b5cdd8", "#d6cdb4"].includes(token.fill),
          ),
        ).toBe(true);
      }
    }
    expect(staircase.end - staircase.start).toBeLessThanOrEqual(1.600001);
    const nodeRows = [...new Set(at("settled").introDotYs)];
    for (const [rowIndex, rowY] of nodeRows.entries()) {
      const hop = staircase.hops[rowIndex];
      if (hop === undefined) throw new Error("Intro dot hop missing");
      const popStart =
        rowIndex === 0 ? staircase.start : (staircase.hops[rowIndex - 1]?.arrival ?? hop.start);
      const rowNodeIndexes = at("settled").introDotYs.flatMap((y, index) =>
        Math.abs(y - rowY) <= 0.5 ? [index] : [],
      );
      for (const sampleIndex of rowNodeIndexes) {
        expect(
          at(popStart + 0.06).introDotCenterDeltas[sampleIndex],
          `${width}px row ${rowIndex} mid-pop ${at(popStart + 0.06).introDotDebug[sampleIndex]}`,
        ).toBeLessThanOrEqual(0.5);
        expect(
          at(popStart + 0.22).introDotCenterDeltas[sampleIndex],
          `${width}px row ${rowIndex} after pop`,
        ).toBeLessThanOrEqual(0.5);
        expect(
          at(popStart + 0.22).introDotTransformIdentities[sampleIndex],
          `${width}px row ${rowIndex} cleared transform ${at(popStart + 0.22).introDotDebug[sampleIndex]}`,
        ).toBe(true);
      }
    }
    expect(at("settled").introDotCenterDeltas.every((distance) => distance <= 0.5)).toBe(true);
    expect(at("settled").introDotTransformIdentities.every(Boolean)).toBe(true);
    const finalHop = staircase.hops.at(-1);
    if (finalHop === undefined) throw new Error("Rail final hop missing");
    expect(at(finalHop.start).heroBranchDashOffset).toBeGreaterThan(0);
    expect(at(staircase.end).heroBranchDashOffset).toBeCloseTo(0, 1);
    expect(at(staircase.end + 0.1).firstPayoff).toBeGreaterThan(0);
    expect(at(staircase.end + 0.1).secondPayoff).toBeGreaterThan(0);
  });
  it(`settles with full payoff, a visible result and a clean rail at ${width}px`, async () => {
    const observation = await commands.observeHeroFinaleSettled(
      inject("siteHeaderBrowserTestUrl"),
      width,
      height,
    );
    const at = sampleAccessor(observation, [
      "copy",
      "claude",
      "tokens",
      "codex",
      "worktree",
      "rail",
      "layout",
    ]);
    expect(at("settled").firstPayoff).toBe(1);
    expect(at("settled").payoffOverflow).toBeLessThanOrEqual(0);
    expect(at("settled").worktreeResultOpacity).toBe(1);
    expect(at("settled").resultVisibleInPane).toBe(true);
    expect(at("settled").offscreenRowPaintLeaks).toBe(0);
    expect(at("settled").railClip).toBe("none");
    expect(at("settled").introDotOpacities.every((opacity) => opacity > 0.9)).toBe(true);
    expect(at("settled").rowOpacity.every((opacity) => opacity === 1)).toBe(true);
  });
  it(`keeps the worktree result visible in a constrained transcript at ${width}px`, async () => {
    const observation = await commands.verifyHeroFinaleConstrainedScroll(
      inject("siteHeaderBrowserTestUrl"),
      width,
      height,
    );
    expect(observation.scrollProbe.overflow).toBeGreaterThan(0);
    expect(observation.scrollProbe.scrollTop).toBeGreaterThan(0);
    expect(observation.scrollProbe.resultVisible).toBe(true);
  });
  it(`keeps window, image, rail and install command fixed on every sampled frame at ${width}px`, async () => {
    const groups = ["layout"] as const;
    const observation = await commands.observeHeroFinaleTimes(
      inject("siteHeaderBrowserTestUrl"),
      width,
      height,
      "all",
      groups,
    );
    const at = sampleAccessor(observation, groups);
    for (const time of [5.5, 10.7, "settled"] as const) {
      expect(
        at(time).transcriptClearances.every((clearance) => clearance >= 20),
        `${time}: pinned clearance`,
      ).toBe(true);
    }
    for (const rawSample of observation.samples) {
      const sample = guardFinaleSample(rawSample, groups);
      expect(
        sample.firstVisibleRowTopGaps.every((gap) => gap >= -0.5),
        `${sample.time}: complete first row ${sample.firstVisibleRowTopGaps.join(",")} ${sample.firstVisibleRowDebug.join(" | ")}`,
      ).toBe(true);
      expect(sample.installTransform, `${sample.time}: install transform`).toBe("none");
      expect(sample.realCommandLines, `${sample.time}: command text`).toEqual([
        "$ brew tap getagentstudio/agentstudio",
        "$ brew install --cask agent-studio",
      ]);
      expect(Math.abs(sample.appTop - at(0).appTop), `${sample.time}: app`).toBeLessThanOrEqual(
        0.5,
      );
      expect(
        Math.abs(sample.windowHeight - at(0).windowHeight),
        `${sample.time}: window`,
      ).toBeLessThanOrEqual(0.5);
      expect(
        Math.abs(sample.chapterNodeY - at(0).chapterNodeY),
        `${sample.time}: rail`,
      ).toBeLessThanOrEqual(0.5);
    }
  });
  it(`scrolls the page, not the transcript, on a visitor wheel at ${width}px`, async () => {
    const observation = await commands.verifyHeroTranscriptWheel(
      inject("siteHeaderBrowserTestUrl"),
      width,
      height,
    );
    expect(observation.wheelScrolls.map((scroll) => scroll.pane)).toEqual(
      width < 1024 ? ["claude"] : ["claude", "codex"],
    );
    for (const scroll of observation.wheelScrolls) {
      expect(scroll.transcriptAfter, `${width}px ${scroll.pane} visitor wheel`).toBe(
        scroll.transcriptBefore,
      );
      expect(scroll.pageAfter, `${width}px ${scroll.pane} wheel scrolls page`).toBeGreaterThan(
        scroll.pageBefore,
      );
    }
  });
  it(`settles once on resize with no leftover inline styles at ${width}px`, async () => {
    const observation = await commands.verifyHeroFinaleResizeSettle(
      inject("siteHeaderBrowserTestUrl"),
      width,
      height,
    );
    expect(observation.resizeRailClip).toBe("none");
    expect(observation.resizeRailStyle).not.toContain("clip-path");
    expect(observation.resizeSceneInlineStyles).toBe(0);
    expect(observation.resizeRailIntroMarkers).toBe(0);
    expect(observation.resizeRailResidualTransforms).toBe(0);
  });
  it(`skips to the settled hero on Escape at ${width}px`, async () => {
    const observation = await commands.verifyHeroFinaleEscapeSkip(
      inject("siteHeaderBrowserTestUrl"),
      width,
      height,
    );
    expect(observation.skipRailClip).toBe("none");
    expect(observation.skipSceneInlineStyles).toBe(0);
    expect(observation.skipRailIntroMarkers).toBe(0);
    expect(observation.skipRailResidualTransforms).toBe(0);
    expect(observation.skipFinaleOpacity.every((opacity) => opacity === 1)).toBe(true);
  });
  it(`shows the settled hero under reduced motion at ${width}px`, async () => {
    const observation = await commands.verifyHeroFinaleReducedMotion(
      inject("siteHeaderBrowserTestUrl"),
      width,
      height,
    );
    expect(observation.reducedRailClip).toBe("none");
    expect(observation.reducedRailIntroMarkers).toBe(0);
    expect(observation.reducedRailResidualTransforms).toBe(0);
    expect(observation.reducedFinaleOpacity.every((opacity) => opacity === 1)).toBe(true);
  });
}
it("keeps phone worktree rows on one line at approved narrow widths", async () => {
  for (const width of [360, 390, 414]) {
    const observation = await commands.observeHeroFinaleSettled(
      inject("siteHeaderBrowserTestUrl"),
      width,
      844,
    );
    const settled = sampleAccessor(observation, [
      "copy",
      "claude",
      "tokens",
      "codex",
      "worktree",
      "rail",
      "layout",
    ])("settled");
    expect(settled.worktreeRowLineCounts).toEqual([1, 1, 1]);
    expect(
      settled.claudeRowLineCounts.every((count) => count <= 1),
      `${width}px wrapped Claude rows: ${settled.wrappedClaudeRows.join(" | ")}`,
    ).toBe(true);
  }
});

it("keeps the hero Codex session in the Agent Studio workspace", async () => {
  const observation = await commands.observeHeroFinaleSettled(
    inject("siteHeaderBrowserTestUrl"),
    1600,
    1000,
  );
  const settled = sampleAccessor(observation, [
    "copy",
    "claude",
    "tokens",
    "codex",
    "worktree",
    "rail",
    "layout",
  ])("settled");
  expect(settled.heroText).not.toMatch(/tool-portal|fix\/lease-client/u);
  expect(settled.codexHeaderText).toContain("directory: ~/agent-studio");
  expect(settled.codexFooterText).toContain("main");
  expect(settled.worktreeTexts).toEqual([
    "└ ~/agent-studio  main",
    "└ ~/agent-studio.drawer  drawer-improvements",
    "└ ~/agent-studio.review  review-comments",
  ]);
});

it("clips scrolled transcript rows inside their panes", async () => {
  for (const [width, height] of [
    [1600, 1000],
    [390, 844],
  ] as const) {
    const observation = await commands.observeHeroFinaleSettled(
      inject("siteHeaderBrowserTestUrl"),
      width,
      height,
    );
    const settled = sampleAccessor(observation, [
      "copy",
      "claude",
      "tokens",
      "codex",
      "worktree",
      "rail",
      "layout",
    ])("settled");
    expect(settled.offscreenRowPaintLeaks, `${width}px`).toBe(0);
    expect(settled.resultVisibleInPane, `${width}px`).toBe(true);
  }
});

it("reaches stillness by the owner-adjusted 16.5s ceiling", async () => {
  const observation = await commands.observeHeroFinaleSettled(
    inject("siteHeaderBrowserTestUrl"),
    1600,
    1000,
  );
  expect(observation.staircase.end + 0.2).toBeLessThanOrEqual(16.5);
});

it("rejects reads from unrequested finale field groups", async () => {
  const observation = await commands.observeHeroFinaleTimes(
    inject("siteHeaderBrowserTestUrl"),
    1600,
    1000,
    [0],
    ["copy"],
  );
  const at = sampleAccessor(observation, ["copy"]);
  expect(() => {
    // @ts-expect-error The copy sample cannot expose a tokens field.
    return at(0).tokenCount;
  }).toThrow("Field tokenCount belongs to unrequested group tokens");
});
