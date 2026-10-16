import type {
	BridgeCommWorkerPanePresentationAuthority,
	BridgeCommWorkerPanePresentationSnapshot,
} from './bridge-comm-worker-pane-presentation.js';
import type { BridgeCommWorkerReviewComparisonCommit } from './bridge-comm-worker-review-publication-types.js';
import {
	BRIDGE_WORKER_WIRE_VERSION,
	bridgeWorkerReviewDisplayPatchEventSchema,
	type BridgeWorkerReviewDisplayPatch,
	type BridgeWorkerReviewDisplayPatchEvent,
	type BridgeWorkerReviewPublicationIdentity,
	type BridgeWorkerReviewSourceDisplayPayload,
} from './bridge-worker-contracts.js';

export interface BridgeCommWorkerReviewSourceIdentity {
	readonly packageId: string;
	readonly reviewGeneration: number;
	readonly revision: number;
}

export interface BridgeCommWorkerAdmittedReviewDisplayPatches {
	readonly patches: readonly BridgeWorkerReviewDisplayPatch[];
	readonly reviewComparison?:
		| BridgeCommWorkerPanePresentationSnapshot['reviewComparison']
		| undefined;
	readonly sourceIdentity: BridgeCommWorkerReviewSourceIdentity | null;
}

export function bridgeCommWorkerReviewDisplayPatchEvent(props: {
	readonly patches: readonly BridgeWorkerReviewDisplayPatch[];
	readonly projectionRevision: number;
	readonly reviewPublicationIdentity: BridgeWorkerReviewPublicationIdentity | null;
	readonly sequence: number;
	readonly workerDerivationEpoch: number;
}): BridgeWorkerReviewDisplayPatchEvent {
	return bridgeWorkerReviewDisplayPatchEventSchema.parse({
		direction: 'serverWorkerToMain',
		epoch: props.workerDerivationEpoch,
		kind: 'reviewDisplayPatch',
		patches: props.patches,
		projectionRevision: props.projectionRevision,
		reviewPublicationIdentity: props.reviewPublicationIdentity,
		sequence: props.sequence,
		surface: 'review',
		transferDescriptors: [],
		wireVersion: BRIDGE_WORKER_WIRE_VERSION,
	});
}

export function admitBridgeCommWorkerReviewDisplayPatches(props: {
	readonly comparisonCommit?: BridgeCommWorkerReviewComparisonCommit | undefined;
	readonly panePresentationAuthority: BridgeCommWorkerPanePresentationAuthority;
	readonly patches: readonly BridgeWorkerReviewDisplayPatch[];
}): BridgeCommWorkerAdmittedReviewDisplayPatches {
	const sourceIdentity = reviewSourceIdentityFromPatches(props.patches);
	if (props.comparisonCommit === undefined) return { patches: props.patches, sourceIdentity };
	const disposition = props.panePresentationAuthority.reconcileReviewComparison(
		props.comparisonCommit.presentationRevision,
		props.comparisonCommit.reviewComparison,
	);
	const reviewComparison = props.panePresentationAuthority.snapshot.reviewComparison;
	const comparisonMatchesSource = bridgeCommWorkerReviewComparisonMatchesSource(
		reviewComparison,
		sourceIdentity,
	);
	if (disposition === 'stale' && !comparisonMatchesSource) {
		return {
			patches: props.patches.filter((patch): boolean => patch.slice !== 'reviewComparison'),
			sourceIdentity,
		};
	}
	if (!comparisonMatchesSource) {
		throw new Error('Bridge Review comparison commit does not match its displayed Review source.');
	}
	return {
		patches: props.patches.map((patch) =>
			patch.slice === 'reviewComparison' ? { ...patch, payload: reviewComparison } : patch,
		),
		reviewComparison,
		sourceIdentity,
	};
}

export function bridgeCommWorkerReviewComparisonMatchesSource(
	reviewComparison: BridgeCommWorkerPanePresentationSnapshot['reviewComparison'],
	sourceIdentity: BridgeCommWorkerReviewSourceIdentity | null,
): boolean {
	const displayedSnapshot = reviewComparison?.displayedSnapshot;
	if (displayedSnapshot?.status !== 'current') return true;
	return (
		sourceIdentity !== null &&
		displayedSnapshot.packageId === sourceIdentity.packageId &&
		displayedSnapshot.reviewGeneration === sourceIdentity.reviewGeneration &&
		displayedSnapshot.revision === sourceIdentity.revision
	);
}

function reviewSourceIdentityFromPatches(
	patches: readonly BridgeWorkerReviewDisplayPatch[],
): BridgeCommWorkerReviewSourceIdentity | null {
	const sourcePatch = patches.find(
		(
			patch,
		): patch is Extract<
			BridgeWorkerReviewDisplayPatch,
			{ readonly operation: 'upsert'; readonly slice: 'reviewSource' }
		> => patch.slice === 'reviewSource' && patch.operation === 'upsert',
	);
	if (sourcePatch === undefined) return null;
	const payload: BridgeWorkerReviewSourceDisplayPayload = sourcePatch.payload;
	return {
		packageId: payload.packageId,
		reviewGeneration: payload.reviewGeneration,
		revision: payload.revision,
	};
}
