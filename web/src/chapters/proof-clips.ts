export const proofClipStepIds = ["proof-run", "proof-review", "proof-panes"] as const;

export type ProofClipStepId = (typeof proofClipStepIds)[number];

export interface ProofClip {
  readonly desktopVideo: string;
  readonly phoneVideo: string;
  readonly poster: string;
  readonly accessibleLabel: string;
}

export type ProofClipManifest = Readonly<Record<ProofClipStepId, ProofClip | null>>;

export type CompleteProofClips = Readonly<Record<ProofClipStepId, ProofClip>>;

export function hasCompleteProofClips(clips: ProofClipManifest): clips is CompleteProofClips {
  return proofClipStepIds.every((stepId) => clips[stepId] !== null && clips[stepId] !== undefined);
}

/** Media delivery fills these slots; incomplete footage must never render a glass. */
export const proofClips: ProofClipManifest = {
  "proof-run": null,
  "proof-review": null,
  "proof-panes": null,
};
