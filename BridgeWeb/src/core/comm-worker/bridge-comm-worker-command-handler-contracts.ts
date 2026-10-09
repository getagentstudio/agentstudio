import type { BridgeCommWorkerFileViewRuntimeMutation } from './bridge-comm-worker-file-view-runtime-mutation.js';
import type { BridgeCommWorkerFileViewRuntimeSource } from './bridge-comm-worker-file-view-runtime-source.js';
import type { BridgeCommWorkerFileMetadataDemand } from './bridge-comm-worker-product-controller.js';
import type { BridgeWorkerRenderDispositionApplication } from './bridge-comm-worker-render-disposition-application.js';
import type { BridgeCommWorkerReviewMetadataApplication } from './bridge-comm-worker-review-runtime-application.js';
import type { BridgeCommWorkerReviewRuntimeSource } from './bridge-comm-worker-review-source-diff.js';
import type { BridgeCommWorkerRow, BridgeCommWorkerStore } from './bridge-comm-worker-store.js';
import type { BridgeCommWorkerTelemetryRecorder } from './bridge-comm-worker-telemetry.js';
import type {
	BridgeWorkerFileDisplayResyncCommand,
	BridgeWorkerFileQueryUpdateCommand,
	BridgeWorkerMainToServerMessage,
	BridgeWorkerReviewContentMetadata,
	BridgeWorkerReviewContentRequestDescriptor,
	BridgeWorkerReviewPublicationIdentity,
	BridgeWorkerReviewProjectionUpdateCommand,
	BridgeWorkerReviewRenderSemantics,
	BridgeWorkerRenderDispositionCommand,
	BridgeWorkerServerToMainMessage,
	BridgeWorkerViewRecoveryRetryCommand,
} from './bridge-worker-contracts.js';
import type {
	BridgeWorkerRenderFulfillmentIdentifierPurpose,
	BridgeWorkerRenderFulfillmentRegistryContext,
} from './bridge-worker-render-fulfillment-registry.js';

export interface CreateBridgeCommWorkerCommandHandlerProps {
	readonly contentItems: readonly BridgeWorkerReviewContentMetadata[];
	readonly contentRequestDescriptors?: readonly BridgeWorkerReviewContentRequestDescriptor[];
	readonly renderSemantics?: readonly BridgeWorkerReviewRenderSemantics[];
	readonly reviewPublicationIdentity?: BridgeWorkerReviewPublicationIdentity | null;
	readonly rows: readonly BridgeCommWorkerRow[];
	readonly createSequence?: () => number;
	readonly createRenderIdentifier?: (
		purpose: BridgeWorkerRenderFulfillmentIdentifierPurpose,
	) => string;
	readonly now?: () => number;
	readonly onReviewMetadataPostCommitFailure?: (error: unknown) => void;
	readonly onReviewVisibleRenderExhausted?: (itemIds: readonly string[]) => void;
	readonly onFileVisibleRenderExhausted?: (
		itemIds: readonly string[],
		store: BridgeCommWorkerStore,
	) => void;
	readonly renderFulfillmentContext?: Omit<BridgeWorkerRenderFulfillmentRegistryContext, 'surface'>;
	readonly renderFulfillmentNow?: () => number;
	readonly renderReceiptLeaseDurationMilliseconds?: number;
	readonly renderRetryBackoffMilliseconds?: number;
	readonly releaseExpiredReviewPublication?: (itemId: string) => void;
	readonly retryAnnotationProjection?: (surface: 'file' | 'review') => void;
	readonly retryView?: (view: BridgeWorkerViewRecoveryRetryCommand['view']) => void;
	readonly scheduleDemandExecution?: (
		request: BridgeCommWorkerDemandExecutionScheduleRequest,
	) => void;
	readonly scheduleReviewMetadataReset?: (
		request: BridgeCommWorkerReviewMetadataResetScheduleRequest,
	) => void;
	readonly scheduleSelectedReviewContentReadyPreparation: (
		request: BridgeCommWorkerSelectedReviewContentReadyPreparationRequest,
	) => void;
	readonly scheduleSelectedFileViewContentReadyPreparation: (
		request: BridgeCommWorkerSelectedFileViewContentReadyPreparationRequest,
	) => void;
	readonly telemetryClient?: BridgeCommWorkerTelemetryRecorder;
	readonly updateReviewRuntimeSource?: (source: BridgeCommWorkerReviewRuntimeSource) => void;
	readonly updateFileViewRuntimeSource?: (source: BridgeCommWorkerFileViewRuntimeSource) => void;
	readonly updateFileMetadataDemand?: (demand: BridgeCommWorkerFileMetadataDemand) => void;
	readonly updateFileDisplayQuery?: (
		command: BridgeWorkerFileQueryUpdateCommand,
	) => readonly BridgeWorkerServerToMainMessage[];
	readonly updateReviewDisplayProjection?: (
		command: BridgeWorkerReviewProjectionUpdateCommand,
	) => readonly BridgeWorkerServerToMainMessage[];
	readonly requestFileDisplayResync?: (
		command: BridgeWorkerFileDisplayResyncCommand,
	) => readonly BridgeWorkerServerToMainMessage[];
	readonly applyRenderDisposition?: (props: {
		readonly command: BridgeWorkerRenderDispositionCommand;
		readonly store: BridgeCommWorkerStore;
	}) => readonly BridgeWorkerServerToMainMessage[];
}

export interface BridgeCommWorkerDemandExecutionScheduleRequest {
	readonly cause:
		| 'hover'
		| 'renderFulfillment'
		| 'reviewInvalidate'
		| 'reviewMetadata'
		| 'viewport';
	readonly affectedItemIds?: readonly string[];
	readonly epoch: number;
	readonly forceExecutionItemIds?: readonly string[];
	readonly sourceChurnRevision?: number;
	readonly store: BridgeCommWorkerStore;
}

export interface BridgeCommWorkerReviewMetadataResetScheduleRequest {
	readonly affectedItemIds: readonly string[];
	readonly cause: 'reviewMetadata';
	readonly epoch: number;
	readonly readReviewRuntimeSource: () => BridgeCommWorkerReviewRuntimeSource;
	readonly store: BridgeCommWorkerStore;
}

export interface BridgeCommWorkerSelectedReviewContentReadyPreparationRequest {
	readonly epoch: number;
	readonly itemId: string;
	readonly store: BridgeCommWorkerStore;
}

export interface BridgeCommWorkerSelectedFileViewContentReadyPreparationRequest {
	readonly epoch: number;
	readonly itemId: string;
	readonly store: BridgeCommWorkerStore;
}

export interface BridgeCommWorkerCommandHandler {
	readonly applyRenderDispositionCommand: (
		command: BridgeWorkerRenderDispositionCommand,
	) => BridgeWorkerRenderDispositionApplication;
	readonly advanceFileRenderFulfillmentLifecycle: (
		atMilliseconds: number,
	) => BridgeCommWorkerRenderFulfillmentLifecycleAdvance;
	readonly advanceReviewRenderFulfillmentLifecycle: (
		atMilliseconds: number,
	) => BridgeCommWorkerRenderFulfillmentLifecycleAdvance;
	readonly applyReviewMetadataApplication: (
		application: BridgeCommWorkerReviewMetadataApplication,
	) => readonly BridgeWorkerServerToMainMessage[];
	readonly prepareReviewMetadataApplication: (
		application: BridgeCommWorkerReviewMetadataApplication,
	) => BridgeCommWorkerReviewMetadataApplicationTransaction;
	readonly applyFileViewRuntimeSource: (props: {
		readonly epoch: number;
		readonly source: BridgeCommWorkerFileViewRuntimeSource;
	}) => readonly BridgeWorkerServerToMainMessage[];
	readonly applyFileViewRuntimeMutation: (props: {
		readonly epoch: number;
		readonly mutation: BridgeCommWorkerFileViewRuntimeMutation;
	}) => readonly BridgeWorkerServerToMainMessage[];
	readonly handleMessage: (
		message: BridgeWorkerMainToServerMessage,
	) => readonly BridgeWorkerServerToMainMessage[];
}

export interface BridgeCommWorkerRenderFulfillmentLifecycleAdvance {
	readonly nextWakeAtMilliseconds: number | null;
}

export interface BridgeCommWorkerReviewMetadataApplicationTransaction {
	readonly commit: () => void;
	readonly messages: readonly BridgeWorkerServerToMainMessage[];
	readonly rollback: () => void;
	readonly runPostCommitEffects: () => void;
}
