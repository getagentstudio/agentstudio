import { playwright } from "@vitest/browser-playwright";
import { defineConfig, type TestProjectInlineConfiguration } from "vitest/config";
import type { BrowserConfigOptions } from "vitest/node";

import { verifyChapterActivity } from "./tests/chapter-activity-browser-command.ts";
import { verifyChapterAnchorLanding } from "./tests/chapter-anchor-browser-command.ts";
import {
  verifyChapterAutoplayAtNaturalFraming,
  verifyChapterSceneClicks,
  verifyManualChapterClaim,
} from "./tests/chapter-autoplay-browser-command.ts";
import { verifyChapterScrollGeometry } from "./tests/chapter-scroll-geometry-browser-command.ts";
import {
  verifyChapterStepHop,
  verifyReducedMotionStepLine,
} from "./tests/chapter-step-hop-browser-command.ts";
import { verifyStepLineJoins } from "./tests/chapter-step-join-browser-command.ts";
import {
  verifyChapterStepRow,
  verifyChapterLayout,
  verifyChapterTitleAnchors,
  verifyCaptionTextLayout,
} from "./tests/chapter-surface-browser-command.ts";
import { verifyHeroEyebrowSettle } from "./tests/hero-eyebrow-settle-browser-command.ts";
import {
  verifyHeroIntroLayout,
  verifyHeroNoScriptWidth,
  verifyHeroIntroPlayback,
  verifyHeroIntroRefresh,
  verifyHeroIntroShift,
  verifyHeroScrollCue,
  verifyHeroPhoneMidIntro,
} from "./tests/hero-intro-browser-command.ts";
import { verifyHeroIntroFinale } from "./tests/hero-intro-finale-browser-command.ts";
import { verifyHeroWorkspace } from "./tests/hero-workspace-browser-command.ts";
import { verifyInstallCommandLayout } from "./tests/install-command-layout-browser-command.ts";
import { buildMediaCalloutForBrowserTest } from "./tests/media-callout-browser-command.ts";
import { verifyProofChapter, verifyProofClipMedia } from "./tests/proof-chapter-browser-command.ts";
import { verifyRailViewportBands } from "./tests/rail-band-browser-command.ts";
import { buildSceneBundlesForBrowserTest } from "./tests/scene-bundle-browser-command.ts";
import {
  verifyFooterEndRoom,
  verifySiteFooterResponsiveLayout,
} from "./tests/site-footer-browser-command.ts";
import { verifySiteHeaderScrollStability } from "./tests/site-header-browser-command.ts";
import { verifyFinaleBookend, verifyTopologyEnd } from "./tests/topology-end-browser-command.ts";
import { verifyTopologyNodeVocabulary } from "./tests/topology-node-vocabulary-browser-command.ts";
import { verifySkipToContent } from "./tests/website-access-browser-command.ts";
import {
  verifyDeferredProofVideo,
  verifyHeroProofImage,
  verifyCaptureDelivery,
} from "./tests/website-loading-browser-command.ts";
import { verifyWebsiteQualityLayout } from "./tests/website-quality-browser-command.ts";

export function selectChromeLaunchOptions(
  chromeBin: string | undefined,
): { readonly executablePath: string } | { readonly channel: "chrome" } {
  return chromeBin ? { executablePath: chromeBin } : { channel: "chrome" };
}

// A hang bound only fires on a real hang; it is set once per project and never raised for a failing test.
// Waits inside tests are judged by the page's own events and DOM conditions.
const webTestHangBoundMilliseconds = 120_000;

// Browser files whose work is CPU-bound: timeline seeking, layout measurement, bundle builds.
// When they shared a loaded host's CPU with each other they ran 4-40x slower (Sunclaw,
// 2026-10-07: the 1600px finale case took 126 s in the suite and 4.4 s alone), so they run
// after the parallel group, one file at a time. Their hang bound is unchanged.
export const cpuHeavyBrowserTestFiles = [
  "tests/hero-intro-finale.browser.test.ts",
  "tests/hero-intro.browser.test.ts",
  "tests/topology-end.browser.test.ts",
  "tests/media-callout.browser.test.ts",
  "tests/scene-bundles.browser.test.ts",
  "tests/motion-scenes.browser.test.ts",
] as const;

// Built fresh for each project: Vitest records the derived project name on each browser
// instance, so a shared instance list would give both projects the same name.
function createBrowserTestRuntime(): BrowserConfigOptions {
  return {
    commands: {
      verifyProofChapter,
      verifyProofClipMedia,
      verifySkipToContent,
      verifyDeferredProofVideo,
      verifyHeroProofImage,
      verifyCaptureDelivery,
      verifyChapterActivity,
      buildMediaCalloutForBrowserTest,
      verifyStepLineJoins,
      buildSceneBundlesForBrowserTest,
      verifyRailViewportBands,
      verifyChapterAnchorLanding,
      verifyChapterAutoplayAtNaturalFraming,
      verifyChapterSceneClicks,
      verifyManualChapterClaim,
      verifyChapterScrollGeometry,
      verifyChapterStepHop,
      verifyReducedMotionStepLine,
      verifyHeroIntroLayout,
      verifyHeroNoScriptWidth,
      verifyHeroIntroPlayback,
      verifyHeroIntroRefresh,
      verifyHeroIntroShift,
      verifyHeroScrollCue,
      verifyHeroPhoneMidIntro,
      verifyHeroIntroFinale,
      verifyHeroEyebrowSettle,
      verifyHeroWorkspace,
      verifyInstallCommandLayout,
      verifyChapterStepRow,
      verifyCaptionTextLayout,
      verifyChapterLayout,
      verifyChapterTitleAnchors,
      verifySiteFooterResponsiveLayout,
      verifyFooterEndRoom,
      verifySiteHeaderScrollStability,
      verifyTopologyEnd,
      verifyFinaleBookend,
      verifyTopologyNodeVocabulary,
      verifyWebsiteQualityLayout,
    },
    enabled: true,
    provider: playwright({
      launchOptions: selectChromeLaunchOptions(process.env["CHROME_BIN"]),
    }),
    headless: true,
    instances: [{ browser: "chromium" }],
  };
}

interface BrowserTestProjectProps {
  readonly name: string;
  readonly include: readonly string[];
  readonly exclude: readonly string[];
  readonly groupOrder: number;
  readonly fileParallelism: boolean;
}

function createBrowserTestProject(props: BrowserTestProjectProps): TestProjectInlineConfiguration {
  return {
    // Pre-bundle GSAP up front so the first browser run does not discover it
    // mid-run and reload the test page.
    optimizeDeps: { include: ["gsap"] },
    test: {
      name: props.name,
      testTimeout: webTestHangBoundMilliseconds,
      include: [...props.include],
      exclude: [...props.exclude],
      fileParallelism: props.fileParallelism,
      sequence: { groupOrder: props.groupOrder },
      browser: createBrowserTestRuntime(),
    },
  };
}

export default defineConfig({
  test: {
    // One dev server for both browser projects: a project-level setup would start one per
    // project from the same website root.
    globalSetup: ["./tests/site-header-browser-global-setup.ts"],
    projects: [
      {
        test: {
          name: "unit",
          testTimeout: webTestHangBoundMilliseconds,
          include: ["tests/**/*.test.ts"],
          exclude: ["tests/**/*.browser.test.ts"],
        },
      },
      createBrowserTestProject({
        name: "browser",
        include: ["tests/**/*.browser.test.ts"],
        exclude: cpuHeavyBrowserTestFiles,
        groupOrder: 0,
        fileParallelism: true,
      }),
      createBrowserTestProject({
        name: "browser-heavy",
        include: cpuHeavyBrowserTestFiles,
        exclude: [],
        groupOrder: 1,
        fileParallelism: false,
      }),
    ],
  },
});
