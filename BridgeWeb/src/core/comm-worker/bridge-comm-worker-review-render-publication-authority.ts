import type { BridgeCommWorkerPanePresentationSnapshot } from './bridge-comm-worker-pane-presentation.js';
import type { BridgeCommWorkerReviewSourceIdentity } from './bridge-comm-worker-review-display-projection.js';
import type { BridgeCommWorkerReviewDisplayLifecyclePublisher } from './bridge-comm-worker-review-operation-lifecycle.js';
import type { BridgeCommWorkerTelemetryRecorder } from './bridge-comm-worker-telemetry.js';
import { publishBridgeCommWorkerUpdatingChrome } from './bridge-comm-worker-updating-chrome.js';
import type {
	BridgeWorkerReviewPublicationIdentity,
	BridgeWorkerServerToMainWireMessage,
} from './bridge-worker-contracts.js';

export interface BridgeCommWorkerReviewRenderPublicationAuthority {
	readonly publishUpdatingChrome: (presentation: BridgeCommWorkerPanePresentationSnapshot) => void;
	readonly recordReviewComparison: (
		reviewComparison: BridgeCommWorkerPanePresentationSnapshot['reviewComparison'],
		workerDerivationEpoch: number,
		isUpdatingReview: boolean,
	) => void;
	readonly recordReviewPublicationIdentity: (
		identity: BridgeWorkerReviewPublicationIdentity | null | undefined,
	) => void;
	readonly recordReviewSourceIdentity: (identity: BridgeCommWorkerReviewSourceIdentity) => void;
}

export function createBridgeCommWorkerReviewRenderPublicationAuthority(props: {
	readonly activeFileWorkerDerivationEpoch: () => number | null;
	readonly activeReviewWorkerDerivationEpoch: () => number | null;
	readonly activeViewerMode: () => 'file' | 'review' | null;
	readonly createSequence: () => number;
	readonly currentReviewWorkerDerivationEpoch: () => number | null;
	readonly readReviewDisplayPublisher: () => Pick<
		BridgeCommWorkerReviewDisplayLifecyclePublisher,
		'post'
	>;
	readonly publish: (message: BridgeWorkerServerToMainWireMessage) => void;
	readonly telemetryClient: BridgeCommWorkerTelemetryRecorder | undefined;
}): BridgeCommWorkerReviewRenderPublicationAuthority {
	let activeReviewPublicationIdentity: BridgeWorkerReviewPublicationIdentity | null = null;
	let activeReviewSourceIdentity: BridgeCommWorkerReviewSourceIdentity | null = null;
	let publishedReviewComparison: BridgeCommWorkerPanePresentationSnapshot['reviewComparison'] =
		null;
	const publishedIdentityBySurface = new Map<'file' | 'review', string>();

	return {
		publishUpdatingChrome: (presentation): void => {
			for (const surface of ['file', 'review'] as const) {
				const publication = publishBridgeCommWorkerUpdatingChrome({
					activeFileWorkerDerivationEpoch: props.activeFileWorkerDerivationEpoch(),
					activeReviewPublicationIdentity,
					activeReviewSourceIdentity,
					activeReviewWorkerDerivationEpoch: props.activeReviewWorkerDerivationEpoch(),
					activeViewerMode: props.activeViewerMode(),
					createSequence: props.createSequence,
					previousPublicationIdentity: publishedIdentityBySurface.get(surface),
					previousReviewComparison: publishedReviewComparison,
					presentation,
					publish: props.publish,
					publishCertifiedNoSourceComparison: (comparison): void => {
						const workerDerivationEpoch = props.currentReviewWorkerDerivationEpoch();
						if (workerDerivationEpoch === null)
							throw new Error(
								'Certified pane comparison requires the current product transport epoch.',
							);
						props.readReviewDisplayPublisher().post({
							patches: [{ operation: 'replace', slice: 'reviewComparison', payload: comparison }],
							reviewPublicationIdentity: null,
							workerDerivationEpoch,
						});
					},
					surface,
					telemetryClient: props.telemetryClient,
				});
				if (publication === null) continue;
				publishedIdentityBySurface.set(surface, publication.publicationIdentity);
				if (surface === 'review') {
					publishedReviewComparison = publication.projectedReviewComparison;
				}
			}
		},
		recordReviewComparison: (reviewComparison, workerDerivationEpoch, isUpdatingReview): void => {
			publishedReviewComparison = reviewComparison;
			publishedIdentityBySurface.set(
				'review',
				JSON.stringify([
					workerDerivationEpoch,
					isUpdatingReview ? 'updating' : 'idle',
					reviewComparison,
				]),
			);
		},
		recordReviewPublicationIdentity: (identity): void => {
			if (identity !== null && identity !== undefined) activeReviewPublicationIdentity = identity;
		},
		recordReviewSourceIdentity: (identity): void => {
			activeReviewSourceIdentity = identity;
		},
	};
}
