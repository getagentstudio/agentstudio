import type { ImageMetadata } from "astro";

// Relative imports (not the "@/" alias) keep this catalog loadable by the
// Vitest unit project, which has no alias configuration.
import commandBarPhoneImage from "../assets/captures/command-bar-phone-4x5.png";
import commandBarImage from "../assets/captures/command-bar.png";
import parallelAgentsImage from "../assets/captures/parallel-agents.png";
import parallelWorkPhoneImage from "../assets/captures/parallel-work-phone.png";
import reviewPhoneImage from "../assets/captures/review-phone.png";
import reviewImage from "../assets/captures/review.png";
import taskDrawerToolsPhoneImage from "../assets/captures/task-drawer-tools-phone.png";
import taskDrawerToolsImage from "../assets/captures/task-drawer-tools.png";
import { marketingCopy } from "../marketing-copy";
import type { SceneId } from "../motion-scenes/scene-contract";
import type { KitIconName } from "../recreation-kit/kit-icon-names";
import type { ChapterId, ChapterStepId } from "./chapter-ids";

export {
  chapterIds,
  chapterStepIds,
  isChapterStepId,
  type ChapterId,
  type ChapterStepId,
} from "./chapter-ids";

export type ChapterStage = {
  readonly kind: "scene";
  readonly sceneId: SceneId;
} & (
  | { readonly proofKind: "none" }
  | {
      readonly proofKind: "image";
      readonly proofImage: ImageMetadata;
      /** Purpose-made phone crop of the same capture, shown below the phone breakpoint. */
      readonly proofPhoneImage: ImageMetadata;
      readonly proofAlt: string;
    }
  | {
      readonly proofKind: "video";
      readonly proofVideo: string;
      readonly proofPoster: ImageMetadata;
      readonly proofLabel: string;
    }
);

export interface ChapterStep {
  readonly id: ChapterStepId;
  readonly captionIcon: KitIconName;
  readonly label: string;
  readonly description: string;
  readonly phoneDescription: string;
}

export interface ChapterTitle {
  readonly beforeAccent: string;
  readonly accent: string;
  readonly afterAccent: string;
}

export interface Chapter {
  readonly id: ChapterId;
  readonly title: ChapterTitle;
  readonly steps: readonly ChapterStep[];
  readonly stage: ChapterStage;
}

type FeatureDetailItem = (typeof marketingCopy.featureDetails.items)[number];

function readFeatureDetail<TFeatureDetailId extends FeatureDetailItem["id"]>(
  featureDetailId: TFeatureDetailId,
): Extract<FeatureDetailItem, { readonly id: TFeatureDetailId }> {
  const featureDetail = marketingCopy.featureDetails.items.find(
    (candidate): candidate is Extract<FeatureDetailItem, { readonly id: TFeatureDetailId }> =>
      candidate.id === featureDetailId,
  );
  if (featureDetail === undefined) {
    throw new Error(`Missing marketing feature detail "${featureDetailId}".`);
  }
  return featureDetail;
}

const navigationDetail = readFeatureDetail("navigation");
const taskToolsDetail = readFeatureDetail("task-tools");
const arrangementsDetail = readFeatureDetail("arrangements");
const { stories, chapters } = marketingCopy;

// Step copy reuses approved story and feature-detail strings. Feature details
// carry no phone-length variant, so those steps repeat their description.
export const chapterCatalog: readonly Chapter[] = [
  {
    id: "many-agents",
    title: chapters.manyAgents.title,
    steps: [
      {
        id: "parallel-agents",
        captionIcon: "stack",
        label: stories.parallelWork.label,
        description: stories.parallelWork.description,
        phoneDescription: stories.parallelWork.phoneDescription,
      },
      {
        id: "watch-folders",
        captionIcon: "folder",
        label: stories.watchFolders.label,
        description: stories.watchFolders.description,
        phoneDescription: stories.watchFolders.phoneDescription,
      },
      {
        id: "navigation",
        captionIcon: "search",
        label: `${navigationDetail.title.beforeAccent}${navigationDetail.title.accent}${navigationDetail.title.afterAccent}`,
        description: navigationDetail.summary,
        phoneDescription: navigationDetail.summary,
      },
    ],
    stage: {
      kind: "scene",
      sceneId: "chapter-many-agents",
      proofKind: "image",
      proofImage: parallelAgentsImage,
      proofPhoneImage: parallelWorkPhoneImage,
      proofAlt: stories.parallelWork.imageDescription,
    },
  },
  {
    id: "context-with-task",
    title: chapters.contextWithTask.title,
    steps: [
      {
        id: "task-drawers",
        captionIcon: "drawer",
        label: stories.paneDrawer.label,
        description: stories.paneDrawer.description,
        phoneDescription: stories.paneDrawer.phoneDescription,
      },
      {
        id: "git-context",
        captionIcon: "branch",
        label: stories.gitContext.label,
        description: stories.gitContext.description,
        phoneDescription: stories.gitContext.phoneDescription,
      },
      {
        id: "files",
        captionIcon: "files",
        label: stories.files.label,
        description: stories.files.description,
        phoneDescription: stories.files.phoneDescription,
      },
    ],
    stage: {
      kind: "scene",
      sceneId: "chapter-context-with-task",
      proofKind: "image",
      proofImage: taskDrawerToolsImage,
      proofPhoneImage: taskDrawerToolsPhoneImage,
      proofAlt: taskToolsDetail.imageDescription,
    },
  },
  {
    id: "find-and-focus",
    title: chapters.findAndFocus.title,
    steps: [
      {
        id: "quick-find",
        captionIcon: "search",
        label: stories.quickFind.label,
        description: stories.quickFind.description,
        phoneDescription: stories.quickFind.phoneDescription,
      },
      {
        id: "pane-zoom",
        captionIcon: "zoom",
        label: arrangementsDetail.paneZoomLabel,
        description: arrangementsDetail.detail,
        phoneDescription: arrangementsDetail.detail,
      },
    ],
    stage: {
      kind: "scene",
      sceneId: "chapter-find-and-focus",
      proofKind: "image",
      proofImage: commandBarImage,
      proofPhoneImage: commandBarPhoneImage,
      proofAlt: stories.quickFind.imageDescription,
    },
  },
  {
    id: "review",
    title: chapters.review.title,
    steps: [
      {
        id: "review-diff",
        captionIcon: "review",
        label: stories.review.label,
        description: stories.review.description,
        phoneDescription: stories.review.phoneDescription,
      },
      {
        id: "review-comment",
        captionIcon: "review",
        ...stories.reviewComment,
      },
    ],
    stage: {
      kind: "scene",
      sceneId: "chapter-review",
      proofKind: "image",
      proofImage: reviewImage,
      proofPhoneImage: reviewPhoneImage,
      proofAlt: stories.review.imageDescription,
    },
  },
  {
    id: "come-back",
    title: chapters.comeBack.title,
    steps: [
      {
        id: "quit-in-flight",
        captionIcon: "clock",
        ...stories.quitInFlight,
      },
      {
        id: "persistence",
        captionIcon: "clock",
        label: stories.persistence.label,
        description: stories.persistence.description,
        phoneDescription: stories.persistence.description,
      },
    ],
    stage: {
      kind: "scene",
      sceneId: "chapter-come-back",
      proofKind: "none",
    },
  },
];
