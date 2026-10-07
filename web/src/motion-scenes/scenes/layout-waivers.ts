import type { SceneTimeline } from "../scene-contract";

interface LayoutWaiverSchedule {
  readonly timeline: SceneTimeline;
  readonly elements: readonly HTMLElement[];
  readonly attribute: "data-layout-allow-overlap" | "data-layout-allow-occlusion";
  readonly fromSeconds: number;
  readonly untilSeconds?: number;
}

/** Function properties render even when a host seek suppresses GSAP callbacks. */
export function scheduleLayoutWaiver(schedule: LayoutWaiverSchedule): void {
  for (const element of schedule.elements) {
    let waiverState = 0;
    const proxy = {
      waiver(value?: number): number {
        if (value !== undefined) {
          waiverState = value;
          if (value >= 0.5) {
            element.setAttribute(schedule.attribute, "");
          } else {
            element.removeAttribute(schedule.attribute);
          }
        }
        return waiverState;
      },
    };
    schedule.timeline.set(proxy, { waiver: 1 }, schedule.fromSeconds);
    if (schedule.untilSeconds !== undefined) {
      schedule.timeline.set(proxy, { waiver: 0 }, schedule.untilSeconds);
    }
  }
}
