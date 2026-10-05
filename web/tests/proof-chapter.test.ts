import { describe, expect, it } from "vitest";

import { chapterCatalog, getHomeChapters } from "../src/chapters/chapter-catalog";
import {
  proofClips,
  proofClipStepIds,
  type ProofClip,
  type ProofClipManifest,
} from "../src/chapters/proof-clips";
import { marketingCopy } from "../src/marketing-copy";

function fixtureClip(stepId: string): ProofClip {
  return {
    desktopVideo: `${stepId}-desktop.mp4`,
    phoneVideo: `${stepId}-phone.mp4`,
    poster: `${stepId}.jpg`,
    accessibleLabel: stepId,
  };
}
const completeClips = {
  "proof-run": fixtureClip("proof-run"),
  "proof-review": fixtureClip("proof-review"),
  "proof-panes": fixtureClip("proof-panes"),
} satisfies ProofClipManifest;

describe("Proof chapter footage admission", () => {
  it("places Proof first in the complete chapter inventory", () => {
    expect(chapterCatalog[0]?.id).toBe("proof");
    expect(chapterCatalog[0]?.steps.map((step) => step.id)).toEqual(proofClipStepIds);
  });

  it("preserves the exact owner-approved title and step copy", () => {
    expect(marketingCopy.chapters).toHaveProperty("proof.title", {
      beforeAccent: "See Agent Studio ",
      accent: "running",
      afterAccent: ".",
    });
    const proof = chapterCatalog.find((chapter) => chapter.id === "proof");
    expect(
      proof?.steps.map(({ label, description, phoneDescription }) => ({
        label,
        description,
        phoneDescription,
      })),
    ).toEqual([
      {
        label: "Agents side by side",
        description:
          "Two agents work in separate worktrees. A drawer shows one worktree's changes.",
        phoneDescription: "Two agents work in separate worktrees in one window.",
      },
      {
        label: "Review and comment",
        description: "Read an agent's changes and leave a comment on a line.",
        phoneDescription: "Comment on a line you review.",
      },
      {
        label: "Panes by activity",
        description: "Panes are grouped by recent activity, with the latest activity in Just Now.",
        phoneDescription: "Panes grouped by recent activity.",
      },
    ]);
  });

  it("keeps all production slots null and the shipped five chapters unchanged", () => {
    expect(Object.values(proofClips)).toEqual([null, null, null]);
    expect(getHomeChapters().map((chapter) => chapter.id)).toEqual([
      "many-agents",
      "context-with-task",
      "find-and-focus",
      "review",
      "come-back",
    ]);
  });

  it.each(proofClipStepIds)("omits the entire Proof glass when %s is absent", (stepId) => {
    const incompleteClips = { ...completeClips, [stepId]: null };
    expect(getHomeChapters(incompleteClips).some((chapter) => chapter.id === "proof")).toBe(false);
    expect(getHomeChapters(incompleteClips)).toEqual(getHomeChapters());
  });

  it("admits Proof before all existing chapters only with all three recordings", () => {
    const chapters = getHomeChapters(completeClips);
    expect(chapters.map((chapter) => chapter.id)).toEqual([
      "proof",
      "many-agents",
      "context-with-task",
      "find-and-focus",
      "review",
      "come-back",
    ]);
    expect(chapters[0]?.stage).toEqual({ kind: "clips", clips: completeClips });
    expect(chapters.slice(1)).toEqual(getHomeChapters());
  });
});
