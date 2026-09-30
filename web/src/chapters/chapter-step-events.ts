// The two DOM events that join a chapter's step tabs and its scene playback.
// Both travel on the chapter's glass surface: the scene reports the step its
// timeline has reached, and the tabs request a seek when a visitor picks a step.
// Receivers validate the step id; an unknown id is ignored.

/** Dispatched (bubbling) from a scene root when its timeline passes a step label. */
export const sceneStepReachedEventName = "agentstudio:scene-step-reached";

/** Dispatched on the chapter surface when a visitor selects a step. */
export const chapterStepRequestedEventName = "agentstudio:chapter-step-requested";
export const sceneStepTimingEventName = "agentstudio:scene-step-timing";

export interface SceneStepTimingDetail {
  readonly stepId: string;
  readonly dwellSeconds: number;
  readonly elapsedSeconds: number;
  readonly running: boolean;
  readonly manualPause: boolean;
}

export function createSceneStepTimingEvent(
  detail: SceneStepTimingDetail,
): CustomEvent<SceneStepTimingDetail> {
  return new CustomEvent<SceneStepTimingDetail>(sceneStepTimingEventName, {
    bubbles: true,
    detail,
  });
}

export function readSceneStepTiming(event: Event): SceneStepTimingDetail | undefined {
  if (!(event instanceof CustomEvent)) return undefined;
  const detail: unknown = event.detail;
  if (
    typeof detail !== "object" ||
    detail === null ||
    !("stepId" in detail) ||
    !("dwellSeconds" in detail) ||
    !("elapsedSeconds" in detail) ||
    !("running" in detail) ||
    !("manualPause" in detail)
  )
    return undefined;
  return typeof detail.stepId === "string" &&
    typeof detail.dwellSeconds === "number" &&
    typeof detail.elapsedSeconds === "number" &&
    typeof detail.running === "boolean" &&
    typeof detail.manualPause === "boolean"
    ? {
        stepId: detail.stepId,
        dwellSeconds: detail.dwellSeconds,
        elapsedSeconds: detail.elapsedSeconds,
        running: detail.running,
        manualPause: detail.manualPause,
      }
    : undefined;
}

export interface ChapterStepEventDetail {
  readonly stepId: string;
}

export function createChapterStepEvent(eventName: string, stepId: string): CustomEvent {
  return new CustomEvent<ChapterStepEventDetail>(eventName, { bubbles: true, detail: { stepId } });
}

export function readChapterStepEventStepId(event: Event): string | undefined {
  if (!(event instanceof CustomEvent)) {
    return undefined;
  }
  const detail: unknown = event.detail;
  if (typeof detail !== "object" || detail === null || !("stepId" in detail)) {
    return undefined;
  }
  return typeof detail.stepId === "string" ? detail.stepId : undefined;
}
