import type { BridgeCommWorkerPanePresentationSnapshot } from './bridge-comm-worker-pane-presentation.js';
import {
	bridgeCommWorkerReviewComparisonMatchesSource,
	type BridgeCommWorkerReviewSourceIdentity,
} from './bridge-comm-worker-review-display-projection.js';
import {
	bridgeCommWorkerComparisonTelemetryFacts,
	recordBridgeCommWorkerPanePresentationTelemetry,
	type BridgeCommWorkerTelemetryRecorder,
} from './bridge-comm-worker-telemetry.js';
import {
	BRIDGE_WORKER_WIRE_VERSION,
	bridgeWorkerFileRenderPatchEventSchema,
	bridgeWorkerReviewRenderPatchEventSchema,
	type BridgeWorkerReviewPublicationIdentity,
	type BridgeWorkerServerToMainWireMessage,
} from './bridge-worker-contracts.js';

export interface BridgeCommWorkerUpdatingChromePublication {
	readonly projectedReviewComparison: BridgeCommWorkerPanePresentationSnapshot['reviewComparison'];
	readonly publicationIdentity: string;
}

export function publishBridgeCommWorkerUpdatingChrome(props: {
	readonly activeFileWorkerDerivationEpoch: number | null;
	readonly activeReviewSourceIdentity: BridgeCommWorkerReviewSourceIdentity | null;
	readonly activeReviewPublicationIdentity: BridgeWorkerReviewPublicationIdentity | null;
	readonly activeReviewWorkerDerivationEpoch: number | null;
	readonly activeViewerMode: 'file' | 'review' | null;
	readonly createSequence: () => number;
	readonly previousPublicationIdentity: string | undefined;
	readonly previousReviewComparison: BridgeCommWorkerPanePresentationSnapshot['reviewComparison'];
	readonly presentation: BridgeCommWorkerPanePresentationSnapshot;
	readonly publish: (message: BridgeWorkerServerToMainWireMessage) => void;
	readonly publishCertifiedNoSourceComparison: (
		comparison: NonNullable<BridgeCommWorkerPanePresentationSnapshot['reviewComparison']>,
	) => void;
	readonly surface: 'file' | 'review';
	readonly telemetryClient: BridgeCommWorkerTelemetryRecorder | undefined;
}): BridgeCommWorkerUpdatingChromePublication | null {
	// Certified absence precedes any package. Publish it through the existing
	// comparison display lane; every package-backed state keeps its lineage gate.
	const comparison = props.presentation.reviewComparison;
	if (
		props.surface === 'review' &&
		comparison?.attempt.status === 'noSource' &&
		props.activeReviewPublicationIdentity === null
	) {
		const publicationIdentity = JSON.stringify(['noSource', comparison]);
		if (props.previousPublicationIdentity === publicationIdentity) return null;
		props.publishCertifiedNoSourceComparison(comparison);
		return { projectedReviewComparison: comparison, publicationIdentity };
	}
	const workerDerivationEpoch =
		props.surface === 'file'
			? props.activeFileWorkerDerivationEpoch
			: props.activeReviewWorkerDerivationEpoch;
	if (workerDerivationEpoch === null) return null;
	if (props.surface === 'review' && props.activeReviewPublicationIdentity === null) return null;
	const refreshingLane = props.surface === 'file' ? 'file' : 'review';
	const isUpdating =
		props.surface === 'file' &&
		props.presentation.nativeActivity === 'foreground' &&
		props.activeViewerMode === props.surface &&
		props.presentation.refreshingLanes.includes(refreshingLane);
	const shouldWithholdReviewComparison =
		props.surface === 'review' &&
		!bridgeCommWorkerReviewComparisonMatchesSource(
			props.presentation.reviewComparison,
			props.activeReviewSourceIdentity,
		);
	const projectedReviewComparison =
		props.surface === 'review'
			? shouldWithholdReviewComparison
				? props.previousReviewComparison
				: props.presentation.reviewComparison
			: null;
	const fileRefreshFailure =
		props.surface === 'file' ? props.presentation.fileRefreshFailure : null;
	const publicationIdentity = JSON.stringify([
		workerDerivationEpoch,
		isUpdating ? 'updating' : 'idle',
		...(props.surface === 'file' ? [fileRefreshFailure] : []),
		projectedReviewComparison,
	]);
	if (props.previousPublicationIdentity === publicationIdentity) return null;
	const patch =
		isUpdating || fileRefreshFailure !== null || projectedReviewComparison !== null
			? {
					operation: 'upsert' as const,
					payload: {
						...(isUpdating
							? {
									isLoading: true,
									message: 'Updating files…',
								}
							: {}),
						...(props.surface === 'file'
							? {
									fileRefreshFailure,
									...(fileRefreshFailure === null ? {} : { message: 'Files unavailable' }),
								}
							: {}),
						...(props.surface === 'review' ? { reviewComparison: projectedReviewComparison } : {}),
					},
					slice: 'panelChrome' as const,
				}
			: { operation: 'reset' as const, slice: 'panelChrome' as const };
	const publicationSequence = props.createSequence();
	const commonEvent = {
		direction: 'serverWorkerToMain' as const,
		patches: [patch],
		publicationSequence,
		transferDescriptors: [],
		wireVersion: BRIDGE_WORKER_WIRE_VERSION,
		workerDerivationEpoch,
	};
	props.publish(
		props.surface === 'file'
			? bridgeWorkerFileRenderPatchEventSchema.parse({
					...commonEvent,
					kind: 'fileRenderPatch',
					surface: 'file',
				})
			: bridgeWorkerReviewRenderPatchEventSchema.parse({
					...commonEvent,
					kind: 'reviewRenderPatch',
					reviewPublicationIdentity: props.activeReviewPublicationIdentity,
					surface: 'review',
				}),
	);
	recordBridgeCommWorkerPanePresentationTelemetry({
		...bridgeCommWorkerComparisonTelemetryFacts(props.presentation),
		disposition: 'published',
		panelOperation: patch.operation,
		phase: 'panel_chrome_published',
		presentationRevision: props.presentation.presentationRevision,
		publicationSequence,
		refreshingReview: props.presentation.refreshingLanes.includes('review'),
		surface: props.surface,
		telemetryClient: props.telemetryClient,
		workerDerivationEpoch,
	});
	return { projectedReviewComparison, publicationIdentity };
}
