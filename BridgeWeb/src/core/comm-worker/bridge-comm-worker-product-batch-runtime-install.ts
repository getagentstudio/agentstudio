import type { BridgeCommWorkerAnnotationCatalog } from './bridge-comm-worker-annotation-catalog-applicator.js';
import type { BridgeCommWorkerReviewMetadataApplicationTransaction } from './bridge-comm-worker-command-handler-contracts.js';
import { applyBridgeCommWorkerFileBatchToRuntime } from './bridge-comm-worker-file-batch-runtime-application.js';
import { BridgeCommWorkerFileDisplayEventAuthority } from './bridge-comm-worker-file-display-event-authority.js';
import { BridgeCommWorkerFileQueryProjection } from './bridge-comm-worker-file-query-projection.js';
import type { BridgeCommWorkerFileViewRuntimeMutation } from './bridge-comm-worker-file-view-runtime-mutation.js';
import { BridgeCommWorkerProductBatchApplication } from './bridge-comm-worker-product-batch-application.js';
import { bridgeCommWorkerReviewDisplayPatchesFromBatch } from './bridge-comm-worker-review-batch-display.js';
import type { BridgeCommWorkerReviewBatchPresentation } from './bridge-comm-worker-review-batch-installer.js';
import { bridgeCommWorkerReviewRuntimeApplicationFromBatch } from './bridge-comm-worker-review-batch-runtime-application.js';
import type { BridgeCommWorkerReviewMetadataApplication } from './bridge-comm-worker-review-runtime-application.js';
import type { BridgeProductBatchFrame } from './bridge-product-batch-wire-contracts.js';
import type { BridgeProductInstalledFileView } from './bridge-product-file-batch-installer.js';
import type { BridgeProductTransportSession } from './bridge-product-transport.js';
import type {
	BridgeWorkerReviewDisplayPatch,
	BridgeWorkerServerToMainMessage,
} from './bridge-worker-contracts.js';

type BatchBegin = Extract<BridgeProductBatchFrame, { readonly kind: 'subscription.batchBegin' }>;

/** W4 composition: an installed bank carries its certification to its typed owner. */
export function installBridgeCommWorkerProductBatchRuntime(props: {
	readonly createSequence: () => number;
	readonly applyCommentCatalog: (
		catalog: BridgeCommWorkerAnnotationCatalog,
		surface: 'file' | 'review',
	) => void;
	readonly applyFileRuntimeMutation: (
		epoch: number,
		mutation: BridgeCommWorkerFileViewRuntimeMutation,
	) => readonly BridgeWorkerServerToMainMessage[];
	readonly prepareReviewRuntimeApplication: (
		application: BridgeCommWorkerReviewMetadataApplication,
	) => BridgeCommWorkerReviewMetadataApplicationTransaction;
	readonly beforeApplyFile: (view: BridgeProductInstalledFileView) => void;
	readonly didInstallFile: (
		view: BridgeProductInstalledFileView,
		begin: BatchBegin,
		certified: boolean,
	) => void;
	readonly didInstallReview: (
		presentation: BridgeCommWorkerReviewBatchPresentation,
		begin: BatchBegin,
	) => void;
	readonly fileDisplayAuthority: BridgeCommWorkerFileDisplayEventAuthority;
	readonly fileQueryProjection: BridgeCommWorkerFileQueryProjection;
	readonly productTransport: BridgeProductTransportSession;
	readonly publishMessage: (message: BridgeWorkerServerToMainMessage) => void;
	readonly publishReviewDisplay: (props: {
		readonly patches: readonly BridgeWorkerReviewDisplayPatch[];
		readonly reviewPublicationIdentity: BridgeCommWorkerReviewBatchPresentation['runtimeSource']['reviewPublicationIdentity'];
		readonly workerDerivationEpoch: number;
	}) => void;
	readonly reportResnapshotFailure: () => void;
	readonly reportReviewPostCommitFailure: () => void;
}): BridgeCommWorkerProductBatchApplication {
	const application = new BridgeCommWorkerProductBatchApplication({
		applyComment: (catalog: BridgeCommWorkerAnnotationCatalog, surface): void => {
			props.applyCommentCatalog(catalog, surface);
		},
		applyFile: (view, begin, certified): void => {
			const epoch = props.productTransport.workerDerivationEpoch('file');
			props.beforeApplyFile(view);
			applyBridgeCommWorkerFileBatchToRuntime({
				applyRuntimeMutation: (mutation) => props.applyFileRuntimeMutation(epoch, mutation),
				displayAuthority: props.fileDisplayAuthority,
				epoch,
				publishMessage: props.publishMessage,
				queryProjection: props.fileQueryProjection,
				view,
			});
			props.didInstallFile(view, begin, certified);
		},
		applyReview: (presentation, begin, sourceEpoch, previous): void => {
			const workerDerivationEpoch = props.productTransport.workerDerivationEpoch('review');
			const runtimeApplication = bridgeCommWorkerReviewRuntimeApplicationFromBatch({
				previous,
				presentation,
				sourceEpoch,
				workerDerivationEpoch,
			});
			const transaction = props.prepareReviewRuntimeApplication(runtimeApplication);
			try {
				props.publishReviewDisplay({
					patches: bridgeCommWorkerReviewDisplayPatchesFromBatch(presentation),
					reviewPublicationIdentity: presentation.runtimeSource.reviewPublicationIdentity,
					workerDerivationEpoch,
				});
				transaction.commit();
			} catch (error) {
				transaction.rollback();
				throw error;
			}
			try {
				transaction.runPostCommitEffects();
			} catch {
				props.reportReviewPostCommitFailure();
			}
			for (const message of transaction.messages) {
				try {
					props.publishMessage(message);
				} catch {
					props.reportReviewPostCommitFailure();
				}
			}
			props.didInstallReview(presentation, begin);
		},
		requestResnapshot: (frame): void => {
			const admission = props.productTransport.resnapshotView?.({
				domain: frame.domain,
				handle: frame.handle,
				incarnation: frame.incarnation,
				scopeRevision: frame.scopeRevision,
				subscriptionId: frame.subscriptionId,
				subscriptionKind: frame.subscriptionKind,
			});
			if (admission === undefined) {
				props.reportResnapshotFailure();
				return;
			}
			void admission.catch(props.reportResnapshotFailure);
		},
		requestResnapshotLatest: (subscriptionId, domain): void => {
			const admission = props.productTransport.resnapshotLatestView?.(subscriptionId, domain);
			if (admission === undefined) {
				props.reportResnapshotFailure();
				return;
			}
			void admission.catch(props.reportResnapshotFailure);
		},
		workerDerivationEpoch: (surface): number =>
			props.productTransport.workerDerivationEpoch(surface),
		createSequence: props.createSequence,
		publishMessage: props.publishMessage,
		publishReviewDisplay: props.publishReviewDisplay,
	});
	props.productTransport.setBatchFrameSinks?.(application.sinks());
	return application;
}
