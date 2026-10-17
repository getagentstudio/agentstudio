import type { BridgeProductReviewComparisonPresentation } from './bridge-product-review-comparison-presentation-contracts.js';
import type {
	BridgeWorkerReviewCandidateStartDisposition,
	BridgeWorkerReviewPublicationIdentity,
} from './bridge-worker-contracts.js';
import type { ReviewMetadataLineage } from './bridge-worker-review-publication-lineage.js';

export type BridgeCommWorkerReviewSuccessorReExposureFence =
	| {
			readonly admissionFailureRetryUsed: boolean;
			readonly installed: ReviewMetadataLineage;
			readonly kind: 'installedPair';
			readonly successor: ReviewMetadataLineage;
	  }
	| {
			readonly admissionFailureRetryUsed: boolean;
			readonly kind: 'admissionRecovery';
			readonly successor: ReviewMetadataLineage;
			readonly triggerPublicationId: string;
	  };

export type BridgeCommWorkerReviewSuccessorReExposureSettlement =
	| { readonly candidatePublicationId: string; readonly kind: 'admissionFailed' }
	| { readonly candidatePublicationId: string; readonly kind: 'admissionRejected' }
	| {
			readonly identity: BridgeWorkerReviewPublicationIdentity;
			readonly kind: 'publicationApplied';
	  };

export interface BridgeCommWorkerReviewCandidateReadyFacts {
	readonly disposition: BridgeWorkerReviewCandidateStartDisposition;
	readonly identity: ReviewMetadataLineage;
}

export interface BridgeCommWorkerReviewCandidateStartedPublication extends BridgeCommWorkerReviewCandidateReadyFacts {
	readonly workerDerivationEpoch: number;
}

export interface BridgeCommWorkerReviewCandidateFailedPublication {
	readonly identity: ReviewMetadataLineage;
	readonly retryable: boolean;
	readonly workerDerivationEpoch: number;
}

export interface BridgeCommWorkerReviewCandidateReadyPublication extends BridgeCommWorkerReviewCandidateReadyFacts {
	readonly workerDerivationEpoch: number;
}

export interface BridgeCommWorkerReviewComparisonCommit {
	readonly presentationRevision: number;
	readonly reviewComparison: BridgeProductReviewComparisonPresentation | null;
}
