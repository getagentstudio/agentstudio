import { playwright } from "@vitest/browser-playwright";
import { defineConfig } from "vitest/config";

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
  verifySingleStepChapter,
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

export default defineConfig({
  test: {
    projects: [
      {
        test: {
          name: "unit",
          testTimeout: webTestHangBoundMilliseconds,
          include: ["tests/**/*.test.ts"],
          exclude: ["tests/**/*.browser.test.ts"],
        },
      },
      {
        // Pre-bundle GSAP up front so the first browser run does not discover it
        // mid-run and reload the test page.
        optimizeDeps: { include: ["gsap"] },
        test: {
          name: "browser",
          testTimeout: webTestHangBoundMilliseconds,
          include: ["tests/**/*.browser.test.ts"],
          browser: {
            commands: {
              verifySkipToContent,
              verifyDeferredProofVideo,
              verifyHeroProofImage,
              verifyCaptureDelivery,
              verifyChapterActivity,
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
              verifySingleStepChapter,
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
          },
          globalSetup: ["./tests/site-header-browser-global-setup.ts"],
        },
      },
    ],
  },
});
