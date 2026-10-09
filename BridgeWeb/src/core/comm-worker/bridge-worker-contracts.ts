import { z } from 'zod';

import { bridgeDemandLaneSchema } from '../models/bridge-demand-models.js';
import { bridgeProductReviewComparisonTargetSchema } from './bridge-product-call-contracts.js';
import {
	bridgeProductIdentifierSchema,
	bridgeProductNonnegativeSequenceSchema,
	bridgeProductSurfaceSchema,
	type BridgeProductSurface,
} from './bridge-product-contract-primitives.js';
import {
	bridgeActiveViewerModeUpdateSchema,
	bridgeProductControlIntakeReadyParamsSchema,
} from './bridge-product-control-contracts.js';
import {
	bridgeWorkerAckAttemptOutcomeSchema,
	bridgeWorkerPriorControlRequestSchema,
} from './bridge-worker-ack-diagnostic-contracts.js';
export type {
	BridgeWorkerAckAttemptOutcome,
	BridgeWorkerControlAttemptOutcome,
	BridgeWorkerPriorControlRequest,
} from './bridge-worker-ack-diagnostic-contracts.js';
import { bridgeProductReviewFileChangeKindSchema } from './bridge-product-review-primitives.js';
import { bridgeProductNavigationCommandSchema } from './bridge-product-session-contracts.js';
import { bridgeProductSubscriptionFrameFailureCodes } from './bridge-product-subscription-frame-failure.js';
import {
	bridgeWorkerContentAvailabilityPatchPayloadSchema,
	bridgeWorkerRowPaintPatchPayloadSchema,
	bridgeWorkerSelectionPatchPayloadSchema,
	bridgeWorkerViewportPatchPayloadSchema,
} from './bridge-worker-content-contracts.js';
export {
	bridgeWorkerContentAvailabilityPatchPayloadSchema,
	bridgeWorkerFileViewContentMetadataSchema,
	bridgeWorkerReviewContentMetadataSchema,
	bridgeWorkerReviewContentRequestDescriptorSchema,
	bridgeWorkerReviewRenderSemanticsSchema,
	bridgeWorkerRowPaintPatchPayloadSchema,
	bridgeWorkerSelectionPatchPayloadSchema,
	bridgeWorkerViewportPatchPayloadSchema,
	isBridgeWorkerFileViewContentMetadata,
} from './bridge-worker-content-contracts.js';
export type {
	BridgeWorkerContentAvailabilityPatchPayload,
	BridgeWorkerContentMetadata,
	BridgeWorkerFileViewContentMetadata,
	BridgeWorkerReviewContentMetadata,
	BridgeWorkerReviewContentRequestDescriptor,
	BridgeWorkerReviewRenderSemantics,
	BridgeWorkerRowPaintPatchPayload,
	BridgeWorkerSelectionPatchPayload,
	BridgeWorkerViewportPatchPayload,
} from './bridge-worker-content-contracts.js';
import {
	bridgeWorkerAnnotationCatalogStagingEventSchema,
	bridgeWorkerAnnotationCommandAcceptedEventSchema,
	bridgeWorkerAnnotationCommandSchema,
	bridgeWorkerAnnotationOutputInspectCommandSchema,
	bridgeWorkerAnnotationOutputInspectionEventSchema,
	bridgeWorkerAnnotationProjectionConvergenceEventSchema,
	bridgeWorkerAnnotationProjectionRetryCommandSchema,
} from './bridge-worker-annotation-contracts.js';
import {
	BRIDGE_WORKER_FILE_DISPLAY_PATCH_LIMIT,
	bridgeWorkerFileDisplayPatchSchema,
} from './bridge-worker-file-display-patch-contracts.js';
import { bridgeWorkerFileQuerySchema } from './bridge-worker-file-query-contracts.js';
import { bridgeWorkerFileRefreshRetryCommandSchema } from './bridge-worker-file-refresh-contracts.js';
import { bridgeWorkerPanelChromePatchSchema } from './bridge-worker-panel-chrome-contracts.js';
import { validateBridgeWorkerPierreRenderPublicationIdentity } from './bridge-worker-pierre-publication-identity-contracts.js';
import {
	bridgeWorkerDemandRankSchema,
	bridgeWorkerPierreRenderBudgetSchema,
	bridgeWorkerPierreRenderJobSchema,
} from './bridge-worker-pierre-render-job.js';
import { bridgeWorkerRenderDispositionCommandSchema } from './bridge-worker-render-disposition-command-contract.js';
import { bridgeWorkerRenderReceiptIdentitySchema } from './bridge-worker-render-fulfillment.js';
import {
	bridgeWorkerReviewComparisonTargetsQueryCancelCommandSchema,
	bridgeWorkerReviewComparisonTargetsQueryCommandSchema,
	bridgeWorkerReviewComparisonTargetsQueryEventSchema,
} from './bridge-worker-review-comparison-target-query-contracts.js';
import {
	BRIDGE_WORKER_REVIEW_DISPLAY_PATCH_LIMIT,
	bridgeWorkerReviewDisplayPatchSchema,
} from './bridge-worker-review-display-patch-contracts.js';
import {
	bridgeWorkerReviewCandidateFailedEventSchema,
	bridgeWorkerReviewCandidateReadyEventSchema,
	bridgeWorkerReviewCandidateStartedEventSchema,
	bridgeWorkerReviewPublicationInstallAdmissionEventSchema,
	bridgeWorkerReviewPublicationInstallAdmitCommandSchema,
	bridgeWorkerReviewPublicationInstalledCommandSchema,
	bridgeWorkerReviewPublicationIdentitySchema,
} from './bridge-worker-review-publication-contracts.js';
import {
	bridgeWorkerViewRecoveryRetryCommandSchema,
	bridgeWorkerViewRecoveryStatusEventSchema,
} from './bridge-worker-view-recovery-contracts.js';
import {
	BRIDGE_WORKER_WIRE_VERSION,
	bridgeWorkerEpochSchema,
	bridgeWorkerInteractionSurfaceSchema,
	bridgeWorkerMainToServerBaseSchema,
	bridgeWorkerRequestIdSchema,
	bridgeWorkerSequenceSchema,
	bridgeWorkerServerToMainBaseSchema,
} from './bridge-worker-wire-base-contracts.js';
export {
	bridgeWorkerReviewComparisonTargetsQueryCancelCommandSchema,
	bridgeWorkerReviewComparisonTargetsQueryCommandSchema,
	bridgeWorkerReviewComparisonTargetsQueryEventSchema,
} from './bridge-worker-review-comparison-target-query-contracts.js';
export type {
	BridgeWorkerReviewComparisonTargetsQueryCancelCommand,
	BridgeWorkerReviewComparisonTargetsQueryCommand,
} from './bridge-worker-review-comparison-target-query-contracts.js';
export {
	BRIDGE_WORKER_REVIEW_AFFECTED_STABLE_FILE_IDENTITY_LIMIT,
	bridgeWorkerReviewCandidateFailedEventSchema,
	bridgeWorkerReviewCandidateReadyEventSchema,
	bridgeWorkerReviewCandidateStartDispositionSchema,
	bridgeWorkerReviewCandidateStartedEventSchema,
	bridgeWorkerReviewPreDeliveryPresentationClassSchema,
	bridgeWorkerReviewPublicationInstallAdmissionEventSchema,
	bridgeWorkerReviewPublicationInstallAdmitCommandSchema,
	bridgeWorkerReviewPublicationInstalledCommandSchema,
	bridgeWorkerReviewPublicationIdentitySchema,
} from './bridge-worker-review-publication-contracts.js';
export type {
	BridgeWorkerReviewCandidateFailedEvent,
	BridgeWorkerReviewCandidateReadyEvent,
	BridgeWorkerReviewCandidateStartDisposition,
	BridgeWorkerReviewCandidateStartedEvent,
	BridgeWorkerReviewPreDeliveryPresentationClass,
	BridgeWorkerReviewPublicationInstallAdmissionEvent,
	BridgeWorkerReviewPublicationInstallAdmitCommand,
	BridgeWorkerReviewPublicationInstalledCommand,
	BridgeWorkerReviewPublicationIdentity,
} from './bridge-worker-review-publication-contracts.js';

export { BRIDGE_WORKER_WIRE_VERSION } from './bridge-worker-wire-base-contracts.js';
export {
	bridgeWorkerViewRecoveryKindSchema,
	bridgeWorkerViewRecoveryRetryCommandSchema,
	bridgeWorkerViewRecoveryStatusEventSchema,
	bridgeWorkerViewRecoveryViewSchema,
} from './bridge-worker-view-recovery-contracts.js';
export type {
	BridgeWorkerViewRecoveryRetryCommand,
	BridgeWorkerViewRecoveryStatusEvent,
	BridgeWorkerViewRecoveryView,
} from './bridge-worker-view-recovery-contracts.js';
export {
	BRIDGE_WORKER_FILE_DISPLAY_PATCH_LIMIT,
	bridgeWorkerFileDisplayPatchSchema,
} from './bridge-worker-file-display-patch-contracts.js';
export type { BridgeWorkerFileDisplayPatch } from './bridge-worker-file-display-patch-contracts.js';
export {
	BRIDGE_WORKER_REVIEW_DISPLAY_PATCH_LIMIT,
	bridgeWorkerReviewDisplayPatchSchema,
} from './bridge-worker-review-display-patch-contracts.js';
export type {
	BridgeWorkerReviewDisplayItem,
	BridgeWorkerReviewDisplayPatch,
	BridgeWorkerReviewSourceDisplayPayload,
} from './bridge-worker-review-display-patch-contracts.js';
export type { BridgeWorkerPanelChromePatchPayload } from './bridge-worker-panel-chrome-contracts.js';
export {
	bridgeWorkerInteractionSurfaceSchema,
	bridgeWorkerTransferDescriptorSchema,
} from './bridge-worker-wire-base-contracts.js';
export type { BridgeWorkerTransferDescriptor } from './bridge-worker-wire-base-contracts.js';
export { bridgeWorkerAnnotationProjectionConvergenceEventSchema } from './bridge-worker-annotation-contracts.js';
export const bridgeWorkerSelectCommandSchema = bridgeWorkerMainToServerBaseSchema
	.extend({
		command: z.literal('select'),
		surface: bridgeWorkerInteractionSurfaceSchema,
		selectedItemId: z.string().min(1).nullable(),
		selectedSource: z.enum(['user', 'keyboard', 'programmatic']).nullable(),
	})
	.strict()
	.superRefine((command, context): void => {
		if ((command.selectedItemId === null) !== (command.selectedSource === null)) {
			context.addIssue({
				code: 'custom',
				message: 'Selection identity and source must both be present or both be null.',
			});
		}
	});

export const bridgeWorkerViewportCommandSchema = bridgeWorkerMainToServerBaseSchema
	.extend({
		command: z.literal('viewport'),
		surface: bridgeWorkerInteractionSurfaceSchema,
		visibleItemIds: z.array(z.string().min(1)).readonly(),
		firstVisibleIndex: z.number().int().nonnegative(),
		lastVisibleIndex: z.number().int().nonnegative(),
		phase: z.enum(['momentum', 'settled']),
	})
	.strict();

export const bridgeWorkerHoverCommandSchema = bridgeWorkerMainToServerBaseSchema
	.extend({
		command: z.literal('hover'),
		surface: bridgeWorkerInteractionSurfaceSchema,
		hoveredItemId: z.string().min(1).nullable(),
	})
	.strict();

export const bridgeWorkerMarkFileViewedCommandSchema = bridgeWorkerMainToServerBaseSchema
	.extend({
		command: z.literal('markFileViewed'),
		fileId: z.string().min(1),
	})
	.strict();

export const bridgeWorkerMetadataInterestRequestSchema = z
	.object({
		protocol: z.literal('review'),
		streamId: z.string().min(1).optional(),
		generation: z.number().int().nonnegative().optional(),
		itemIds: z.array(z.string().min(1)).readonly().optional(),
		paths: z.array(z.string().min(1)).readonly().optional(),
		lane: bridgeDemandLaneSchema,
		loaded_by: z.enum(['foreground', 'visible', 'nearby', 'speculative', 'idle']).optional(),
	})
	.strict();

export const bridgeWorkerMetadataInterestUpdateCommandSchema = bridgeWorkerMainToServerBaseSchema
	.extend({
		command: z.literal('metadataInterestUpdate'),
		request: bridgeWorkerMetadataInterestRequestSchema,
	})
	.strict();

const bridgeWorkerReviewIntakeReadyParamsSchema = bridgeProductControlIntakeReadyParamsSchema
	.extend({
		protocolId: z.literal('review'),
	})
	.strict();

export const bridgeWorkerReviewIntakeReadyCommandSchema = bridgeWorkerMainToServerBaseSchema
	.merge(bridgeWorkerReviewIntakeReadyParamsSchema)
	.extend({
		command: z.literal('reviewIntakeReady'),
	})
	.strict();

export const bridgeWorkerReviewComparisonUpdateCommandSchema = bridgeWorkerMainToServerBaseSchema
	.extend({
		command: z.literal('reviewComparisonUpdate'),
		target: bridgeProductReviewComparisonTargetSchema,
	})
	.strict();

export const bridgeWorkerActiveViewerModeUpdateCommandSchema = bridgeWorkerMainToServerBaseSchema
	.extend({
		command: z.literal('activeViewerModeUpdate'),
		update: bridgeActiveViewerModeUpdateSchema,
	})
	.strict();

export const bridgeWorkerModeCommandSchema = bridgeWorkerMainToServerBaseSchema
	.extend({
		command: z.literal('mode'),
		mode: z.enum(['review', 'fileView']),
	})
	.strict();

export const bridgeWorkerFileQueryUpdateCommandSchema = bridgeWorkerMainToServerBaseSchema
	.extend({
		command: z.literal('fileQueryUpdate'),
		query: bridgeWorkerFileQuerySchema,
	})
	.strict();

export const bridgeWorkerReviewProjectionQuerySchema = z
	.object({
		categoryFilter: z.enum([
			'all',
			'source',
			'test',
			'docs',
			'config',
			'generated',
			'vendor',
			'fixture',
			'unknown',
		]),
		gitStatusFilter: z.union([z.literal('all'), bridgeProductReviewFileChangeKindSchema]),
		showBinary: z.boolean(),
		showLarge: z.boolean(),
	})
	.strict();

export const bridgeWorkerReviewProjectionUpdateCommandSchema = bridgeWorkerMainToServerBaseSchema
	.extend({
		command: z.literal('reviewProjectionUpdate'),
		query: bridgeWorkerReviewProjectionQuerySchema,
	})
	.strict();

export const bridgeWorkerFileDisplayResyncReasonSchema = z.enum([
	'acknowledgementMismatch',
	'acknowledgementTimeout',
	'bufferOverflow',
	'initialMount',
	'protocolViolation',
]);

export const bridgeWorkerFileDisplayResyncCommandSchema = bridgeWorkerMainToServerBaseSchema
	.extend({
		command: z.literal('fileDisplayResync'),
		reason: bridgeWorkerFileDisplayResyncReasonSchema,
		transactionId: bridgeProductIdentifierSchema.nullable(),
	})
	.strict();

export const bridgeWorkerReviewInvalidateCommandSchema = bridgeWorkerMainToServerBaseSchema
	.extend({
		command: z.literal('reviewInvalidate'),
		scope: z.enum(['package', 'items', 'paths', 'treeWindow']),
		itemIds: z.array(z.string().min(1)).readonly(),
		pathHints: z.array(z.string().min(1)).readonly(),
		reason: z.enum(['sourceChanged', 'watchEvent', 'lineageReplaced', 'unknown']),
	})
	.strict();

export const bridgeWorkerMainToServerCommandSchema = z.discriminatedUnion('command', [
	bridgeWorkerAnnotationCommandSchema,
	bridgeWorkerAnnotationOutputInspectCommandSchema,
	bridgeWorkerAnnotationProjectionRetryCommandSchema,
	bridgeWorkerSelectCommandSchema,
	bridgeWorkerViewportCommandSchema,
	bridgeWorkerHoverCommandSchema,
	bridgeWorkerMarkFileViewedCommandSchema,
	bridgeWorkerMetadataInterestUpdateCommandSchema,
	bridgeWorkerReviewIntakeReadyCommandSchema,
	bridgeWorkerReviewComparisonUpdateCommandSchema,
	bridgeWorkerReviewComparisonTargetsQueryCommandSchema,
	bridgeWorkerReviewComparisonTargetsQueryCancelCommandSchema,
	bridgeWorkerActiveViewerModeUpdateCommandSchema,
	bridgeWorkerModeCommandSchema,
	bridgeWorkerReviewInvalidateCommandSchema,
	bridgeWorkerReviewProjectionUpdateCommandSchema,
	bridgeWorkerReviewPublicationInstallAdmitCommandSchema,
	bridgeWorkerReviewPublicationInstalledCommandSchema,
	bridgeWorkerFileQueryUpdateCommandSchema,
	bridgeWorkerFileRefreshRetryCommandSchema,
	bridgeWorkerViewRecoveryRetryCommandSchema,
	bridgeWorkerFileDisplayResyncCommandSchema,
	bridgeWorkerRenderDispositionCommandSchema,
]);

export const bridgeWorkerMainToServerMessageSchema = bridgeWorkerMainToServerCommandSchema;

export type BridgeWorkerSelectCommand = z.infer<typeof bridgeWorkerSelectCommandSchema>;
export type BridgeWorkerViewportCommand = z.infer<typeof bridgeWorkerViewportCommandSchema>;
export type BridgeWorkerHoverCommand = z.infer<typeof bridgeWorkerHoverCommandSchema>;
export type BridgeWorkerMarkFileViewedCommand = z.infer<
	typeof bridgeWorkerMarkFileViewedCommandSchema
>;
export type BridgeWorkerMetadataInterestRequest = z.infer<
	typeof bridgeWorkerMetadataInterestRequestSchema
>;
export type BridgeWorkerMetadataInterestUpdateCommand = z.infer<
	typeof bridgeWorkerMetadataInterestUpdateCommandSchema
>;
export type BridgeWorkerReviewIntakeReadyCommand = z.infer<
	typeof bridgeWorkerReviewIntakeReadyCommandSchema
>;
export type BridgeWorkerReviewComparisonUpdateCommand = z.infer<
	typeof bridgeWorkerReviewComparisonUpdateCommandSchema
>;
export type BridgeWorkerActiveViewerModeUpdateCommand = z.infer<
	typeof bridgeWorkerActiveViewerModeUpdateCommandSchema
>;
export type BridgeWorkerModeCommand = z.infer<typeof bridgeWorkerModeCommandSchema>;
export type BridgeWorkerReviewInvalidateCommand = z.infer<
	typeof bridgeWorkerReviewInvalidateCommandSchema
>;
export type BridgeWorkerReviewProjectionQuery = z.infer<
	typeof bridgeWorkerReviewProjectionQuerySchema
>;
export type BridgeWorkerReviewProjectionUpdateCommand = z.infer<
	typeof bridgeWorkerReviewProjectionUpdateCommandSchema
>;
export type BridgeWorkerFileQueryUpdateCommand = z.infer<
	typeof bridgeWorkerFileQueryUpdateCommandSchema
>;
export type BridgeWorkerFileDisplayResyncReason = z.infer<
	typeof bridgeWorkerFileDisplayResyncReasonSchema
>;
export type BridgeWorkerFileDisplayResyncCommand = z.infer<
	typeof bridgeWorkerFileDisplayResyncCommandSchema
>;
export type BridgeWorkerRenderDispositionCommand = z.infer<
	typeof bridgeWorkerRenderDispositionCommandSchema
>;
export type BridgeWorkerMainToServerCommand = z.infer<typeof bridgeWorkerMainToServerCommandSchema>;
export type BridgeWorkerMainToServerMessage = BridgeWorkerMainToServerCommand;

export const bridgeCommWorkerBootstrapRequestSchema = z
	.object({
		schemaVersion: z.literal(BRIDGE_WORKER_WIRE_VERSION),
		method: z.literal('bridgeCommWorker.bootstrap'),
		requestId: bridgeWorkerRequestIdSchema,
		runtime: z
			.object({
				bridgeDemandRank: bridgeWorkerDemandRankSchema,
				budget: bridgeWorkerPierreRenderBudgetSchema,
				surfacePolicies: z
					.object({
						fileView: z
							.object({
								bridgeDemandRank: bridgeWorkerDemandRankSchema,
								budget: bridgeWorkerPierreRenderBudgetSchema,
							})
							.strict(),
						review: z
							.object({
								bridgeDemandRank: bridgeWorkerDemandRankSchema,
								budget: bridgeWorkerPierreRenderBudgetSchema,
							})
							.strict(),
					})
					.strict()
					.optional(),
				maxPreparationSliceMs: z.number().finite().positive().optional(),
			})
			.strict(),
	})
	.strict();

const bridgeWorkerSelectionPatchSchema = z.discriminatedUnion('operation', [
	z
		.object({
			slice: z.literal('selection'),
			operation: z.literal('upsert'),
			payload: bridgeWorkerSelectionPatchPayloadSchema,
		})
		.strict(),
	z
		.object({
			slice: z.literal('selection'),
			operation: z.literal('reset'),
		})
		.strict(),
	z
		.object({
			slice: z.literal('selection'),
			operation: z.literal('delete'),
		})
		.strict(),
]);

const bridgeWorkerViewportPatchSchema = z.discriminatedUnion('operation', [
	z
		.object({
			slice: z.literal('viewport'),
			operation: z.literal('upsert'),
			payload: bridgeWorkerViewportPatchPayloadSchema,
		})
		.strict(),
	z
		.object({
			slice: z.literal('viewport'),
			operation: z.literal('reset'),
		})
		.strict(),
	z
		.object({
			slice: z.literal('viewport'),
			operation: z.literal('delete'),
		})
		.strict(),
]);

const bridgeWorkerRowPaintPatchSchema = z.discriminatedUnion('operation', [
	z
		.object({
			slice: z.literal('rowPaint'),
			operation: z.literal('upsert'),
			itemId: z.string().min(1),
			payload: bridgeWorkerRowPaintPatchPayloadSchema,
		})
		.strict(),
	z
		.object({
			slice: z.literal('rowPaint'),
			operation: z.literal('delete'),
			itemId: z.string().min(1),
		})
		.strict(),
	z
		.object({
			slice: z.literal('rowPaint'),
			operation: z.literal('reset'),
		})
		.strict(),
]);

const bridgeWorkerContentAvailabilityPatchSchema = z.discriminatedUnion('operation', [
	z
		.object({
			slice: z.literal('contentAvailability'),
			operation: z.literal('upsert'),
			itemId: z.string().min(1),
			payload: bridgeWorkerContentAvailabilityPatchPayloadSchema,
		})
		.strict(),
	z
		.object({
			slice: z.literal('contentAvailability'),
			operation: z.literal('delete'),
			itemId: z.string().min(1),
		})
		.strict(),
	z
		.object({
			slice: z.literal('contentAvailability'),
			operation: z.literal('reset'),
		})
		.strict(),
]);

export const bridgeWorkerSlicePatchSchema = z.discriminatedUnion('slice', [
	bridgeWorkerSelectionPatchSchema,
	bridgeWorkerViewportPatchSchema,
	bridgeWorkerRowPaintPatchSchema,
	bridgeWorkerContentAvailabilityPatchSchema,
	bridgeWorkerPanelChromePatchSchema,
]);

export type BridgeCommWorkerBootstrapRequest = z.infer<
	typeof bridgeCommWorkerBootstrapRequestSchema
>;
export type BridgeWorkerSlicePatch = z.infer<typeof bridgeWorkerSlicePatchSchema>;
export type BridgeWorkerSurfacePublicationEnvelope<
	TSurface extends BridgeProductSurface,
	TPublication extends Readonly<Record<string, unknown>>,
> = Readonly<{
	publicationSequence: number;
	surface: TSurface;
	workerDerivationEpoch: number;
}> &
	TPublication;

const bridgeWorkerSurfacePublicationEnvelopeShape = {
	publicationSequence: bridgeWorkerSequenceSchema,
	surface: bridgeProductSurfaceSchema,
	workerDerivationEpoch: bridgeWorkerEpochSchema,
} as const;

const bridgeWorkerProductMetadataStreamDiagnosticSchema = z
	.object({
		kind: z.literal('productMetadataStream'),
		lastSubscriptionTermination: z
			.object({
				subscriptionId: bridgeProductIdentifierSchema,
				outcome: z.enum(['terminal', 'failed']),
				reason: z
					.enum([
						'metadata_stream_error',
						'subscription_frame_rejected',
						'unknown_subscription',
						...bridgeProductSubscriptionFrameFailureCodes,
					])
					.nullable(),
			})
			.strict()
			.nullable(),
		routeFailureSubscriptionId: bridgeProductIdentifierSchema.nullable(),
		activeSubscriptionCount: z.number().int().nonnegative(),
		committedFrameCount: z.number().int().nonnegative(),
		decoderState: z.enum(['open', 'terminal', 'finished', 'poisoned']),
		expectedNextStreamSequence: z.number().int().nonnegative(),
		failureStage: z
			.enum([
				'acknowledgement',
				'authority',
				'decode',
				'fetch',
				'finish',
				'read',
				'route',
				'unexpectedEof',
			])
			.nullable(),
		failureCode: z
			.enum([
				'frame_length_invalid',
				'frame_length_exceeds_ceiling',
				'content_frame_tag_invalid',
				'content_control_body_length_invalid',
				'content_control_body_exceeds_ceiling',
				'frame_decode_invalid',
				'frame_payload_invalid',
				'truncated_frame',
				'stream_acceptance_required',
				'duplicate_stream_acceptance',
				'stream_identity_mismatch',
				'stream_sequence_mismatch',
				'post_terminal_frame',
			])
			.nullable(),
		identityMismatchField: z
			.enum(['metadataStreamId', 'paneSessionId', 'wireVersion', 'workerInstanceId'])
			.nullable(),
		lastChunkByteCount: z.number().int().nonnegative(),
		lastCommittedFrameKind: z.string().min(1).nullable(),
		lastRoutedFrameKind: z.string().min(1).nullable(),
		lifecycleState: z.enum(['failed', 'idle', 'opening', 'reading']),
		peakRetainedByteCount: z.number().int().nonnegative(),
		pushCount: z.number().int().nonnegative(),
		readFulfilledCount: z.number().int().nonnegative(),
		readPending: z.boolean(),
		readRequestCount: z.number().int().nonnegative(),
		receivedByteCount: z.number().int().nonnegative(),
		retainedByteCount: z.number().int().nonnegative(),
		routeFailureCode: z
			.enum([
				'metadata_stream_error',
				'subscription_frame_rejected',
				'unknown_subscription',
				...bridgeProductSubscriptionFrameFailureCodes,
			])
			.nullable(),
		routedFrameCount: z.number().int().nonnegative(),
		streamOpenCount: z.number().int().nonnegative(),
	})
	.strict();

const bridgeWorkerHealthDiagnosticSchema = z.discriminatedUnion('kind', [
	bridgeWorkerProductMetadataStreamDiagnosticSchema,
]);

export const bridgeWorkerHealthEventSchema = bridgeWorkerServerToMainBaseSchema
	.extend({
		kind: z.literal('health'),
		requestId: bridgeWorkerRequestIdSchema.optional(),
		status: z.enum(['ready', 'degraded']),
		deliveryStatus: z.enum(['unknownAfterDispatch']).optional(),
		errorKind: z
			.enum(['transport', 'requestRefused', 'invalidResult', 'unexpected', 'workerUnavailable'])
			.optional(),
		diagnostic: bridgeWorkerHealthDiagnosticSchema.optional(),
		message: z.string().min(1).optional(),
	})
	.strict();

export const bridgeWorkerSessionSuspectEventSchema = bridgeWorkerServerToMainBaseSchema
	.extend({
		ackAttemptOutcomes: z.array(bridgeWorkerAckAttemptOutcomeSchema).max(64).readonly(),
		droppedPriorControlRequestCount: z.number().int().nonnegative(),
		kind: z.literal('sessionSuspect'),
		paneSessionId: bridgeProductIdentifierSchema,
		priorControlRequests: z.array(bridgeWorkerPriorControlRequestSchema).max(16).readonly(),
		reason: z.enum([
			'admissionReplyExhausted',
			'resultAcknowledgementExhausted',
			'resultDeadlineExhausted',
		]),
		workerInstanceId: bridgeProductIdentifierSchema,
	})
	.strict();

export const bridgeWorkerSlicePatchEventSchema = bridgeWorkerServerToMainBaseSchema
	.extend({
		kind: z.literal('slicePatch'),
		epoch: bridgeWorkerEpochSchema,
		sequence: bridgeWorkerSequenceSchema,
		patches: z.array(bridgeWorkerSlicePatchSchema).readonly(),
	})
	.strict();

export const bridgeWorkerFileDisplayPatchEventSchema = bridgeWorkerServerToMainBaseSchema
	.extend({
		kind: z.literal('fileDisplayPatch'),
		surface: z.literal('fileView'),
		epoch: bridgeWorkerEpochSchema,
		sequence: bridgeWorkerSequenceSchema,
		projectionRevision: bridgeProductNonnegativeSequenceSchema,
		queryTransaction: z
			.discriminatedUnion('phase', [
				z
					.object({
						batchCount: z.number().int().positive(),
						batchIndex: z.number().int().nonnegative(),
						phase: z.literal('batch'),
						transactionId: bridgeProductIdentifierSchema,
					})
					.strict(),
				z
					.object({
						phase: z.literal('abort'),
						transactionId: bridgeProductIdentifierSchema,
					})
					.strict(),
			])
			.optional(),
		patches: z
			.array(bridgeWorkerFileDisplayPatchSchema)
			.max(BRIDGE_WORKER_FILE_DISPLAY_PATCH_LIMIT)
			.readonly(),
	})
	.strict()
	.superRefine((event, context): void => {
		if (
			event.queryTransaction?.phase === 'batch' &&
			event.queryTransaction.batchIndex >= event.queryTransaction.batchCount
		) {
			context.addIssue({
				code: 'custom',
				message: 'File query transaction batch index must be within its declared batch count.',
				path: ['queryTransaction', 'batchIndex'],
			});
		}
		const isAbort = event.queryTransaction?.phase === 'abort';
		if (isAbort !== (event.patches.length === 0)) {
			context.addIssue({
				code: 'custom',
				message: 'Only File query abort events may carry an empty patch list.',
				path: ['patches'],
			});
		}
	});

const bridgeWorkerFileQueryOutcomeSchema = z.discriminatedUnion('kind', [
	z.object({ kind: z.literal('unchanged') }).strict(),
	z.object({ kind: z.literal('superseded') }).strict(),
	z
		.object({
			kind: z.literal('projected'),
			transactionId: bridgeProductIdentifierSchema,
		})
		.strict(),
]);

export const bridgeWorkerFileQueryOutcomeEventSchema = bridgeWorkerServerToMainBaseSchema
	.extend({
		kind: z.literal('fileQueryOutcome'),
		outcome: bridgeWorkerFileQueryOutcomeSchema,
		requestId: bridgeWorkerRequestIdSchema,
	})
	.strict();

export const bridgeWorkerReviewDisplayPatchEventSchema = bridgeWorkerServerToMainBaseSchema
	.extend({
		kind: z.literal('reviewDisplayPatch'),
		surface: z.literal('review'),
		epoch: bridgeWorkerEpochSchema,
		sequence: bridgeWorkerSequenceSchema,
		projectionRevision: bridgeProductNonnegativeSequenceSchema,
		reviewPublicationIdentity: bridgeWorkerReviewPublicationIdentitySchema.nullable(),
		patches: z
			.array(bridgeWorkerReviewDisplayPatchSchema)
			.min(1)
			.max(BRIDGE_WORKER_REVIEW_DISPLAY_PATCH_LIMIT)
			.readonly(),
	})
	.strict()
	.superRefine((event, context): void => {
		if (event.transferDescriptors.length > 0) {
			context.addIssue({
				code: 'custom',
				message: 'Review display patches must not declare transferable payloads.',
				path: ['transferDescriptors'],
			});
		}
	});

export const bridgeWorkerFileRenderPatchSchema = z.discriminatedUnion('slice', [
	bridgeWorkerRowPaintPatchSchema,
	bridgeWorkerContentAvailabilityPatchSchema,
	bridgeWorkerPanelChromePatchSchema,
]);

export const bridgeWorkerReviewRenderPatchSchema = z.discriminatedUnion('slice', [
	bridgeWorkerRowPaintPatchSchema,
	bridgeWorkerContentAvailabilityPatchSchema,
	bridgeWorkerPanelChromePatchSchema,
]);

export const bridgeWorkerFileRenderPatchEventSchema = bridgeWorkerServerToMainBaseSchema
	.extend({
		...bridgeWorkerSurfacePublicationEnvelopeShape,
		kind: z.literal('fileRenderPatch'),
		patches: z
			.array(bridgeWorkerFileRenderPatchSchema)
			.min(1)
			.max(BRIDGE_WORKER_FILE_DISPLAY_PATCH_LIMIT)
			.readonly(),
		surface: z.literal('file'),
	})
	.strict();

export const bridgeWorkerReviewRenderPatchEventSchema = bridgeWorkerServerToMainBaseSchema
	.extend({
		...bridgeWorkerSurfacePublicationEnvelopeShape,
		kind: z.literal('reviewRenderPatch'),
		reviewPublicationIdentity: bridgeWorkerReviewPublicationIdentitySchema,
		patches: z
			.array(bridgeWorkerReviewRenderPatchSchema)
			.min(1)
			.max(BRIDGE_WORKER_REVIEW_DISPLAY_PATCH_LIMIT)
			.readonly(),
		surface: z.literal('review'),
	})
	.strict();

export const bridgeWorkerSubscriptionEventSchema = bridgeWorkerServerToMainBaseSchema
	.extend({
		kind: z.literal('subscription'),
		requestId: bridgeWorkerRequestIdSchema,
		subscription: z.enum(['reviewContent', 'fileViewContent', 'telemetry']),
		status: z.enum(['subscribed', 'unsubscribed', 'rejected']),
	})
	.strict();

export const bridgeWorkerNativeSurfaceSelectionRequestSchema = bridgeWorkerServerToMainBaseSchema
	.extend({
		kind: z.literal('nativeSurfaceSelectionRequest'),
		metadataStreamId: bridgeProductIdentifierSchema,
		navigationCommand: bridgeProductNavigationCommandSchema,
		paneSessionId: bridgeProductIdentifierSchema,
		workerInstanceId: bridgeProductIdentifierSchema,
	})
	.strict();

export const bridgeWorkerReviewPierreRenderJobEventSchema = bridgeWorkerServerToMainBaseSchema
	.extend({
		...bridgeWorkerSurfacePublicationEnvelopeShape,
		job: bridgeWorkerPierreRenderJobSchema,
		kind: z.literal('reviewPierreRenderJob'),
		renderReceiptIdentity: bridgeWorkerRenderReceiptIdentitySchema,
		reviewPublicationIdentity: bridgeWorkerReviewPublicationIdentitySchema,
		surface: z.literal('review'),
	})
	.strict()
	.superRefine(validateBridgeWorkerPierreRenderPublicationIdentity);

export const bridgeWorkerFilePierreRenderJobEventSchema = bridgeWorkerServerToMainBaseSchema
	.extend({
		...bridgeWorkerSurfacePublicationEnvelopeShape,
		job: bridgeWorkerPierreRenderJobSchema,
		kind: z.literal('filePierreRenderJob'),
		renderReceiptIdentity: bridgeWorkerRenderReceiptIdentitySchema,
		surface: z.literal('file'),
	})
	.strict()
	.superRefine((event, context): void => {
		if (event.job.renderKind !== 'fileText' || event.job.payload.kind !== 'codeViewFileItem') {
			context.addIssue({
				code: 'custom',
				message: 'File Pierre publications require a fileText CodeView File job.',
				path: ['job'],
			});
		}
		validateBridgeWorkerPierreRenderPublicationIdentity(event, context);
	});

export const bridgeWorkerServerToMainMessageSchema = z.discriminatedUnion('kind', [
	bridgeWorkerAnnotationCatalogStagingEventSchema,
	bridgeWorkerAnnotationCommandAcceptedEventSchema,
	bridgeWorkerAnnotationOutputInspectionEventSchema,
	bridgeWorkerAnnotationProjectionConvergenceEventSchema,
	bridgeWorkerHealthEventSchema,
	bridgeWorkerViewRecoveryStatusEventSchema,
	bridgeWorkerSlicePatchEventSchema,
	bridgeWorkerFileDisplayPatchEventSchema,
	bridgeWorkerReviewDisplayPatchEventSchema,
	bridgeWorkerFileRenderPatchEventSchema,
	bridgeWorkerReviewRenderPatchEventSchema,
	bridgeWorkerSubscriptionEventSchema,
	bridgeWorkerReviewComparisonTargetsQueryEventSchema,
	bridgeWorkerNativeSurfaceSelectionRequestSchema,
	bridgeWorkerReviewCandidateFailedEventSchema,
	bridgeWorkerReviewCandidateReadyEventSchema,
	bridgeWorkerReviewCandidateStartedEventSchema,
	bridgeWorkerReviewPublicationInstallAdmissionEventSchema,
	bridgeWorkerReviewPierreRenderJobEventSchema,
	bridgeWorkerFilePierreRenderJobEventSchema,
]);

export const bridgeWorkerServerToMainWireMessageSchema = z.discriminatedUnion('kind', [
	bridgeWorkerAnnotationCatalogStagingEventSchema,
	bridgeWorkerAnnotationCommandAcceptedEventSchema,
	bridgeWorkerAnnotationOutputInspectionEventSchema,
	bridgeWorkerAnnotationProjectionConvergenceEventSchema,
	bridgeWorkerHealthEventSchema,
	bridgeWorkerSessionSuspectEventSchema,
	bridgeWorkerViewRecoveryStatusEventSchema,
	bridgeWorkerSlicePatchEventSchema,
	bridgeWorkerFileDisplayPatchEventSchema,
	bridgeWorkerFileQueryOutcomeEventSchema,
	bridgeWorkerReviewDisplayPatchEventSchema,
	bridgeWorkerFileRenderPatchEventSchema,
	bridgeWorkerReviewRenderPatchEventSchema,
	bridgeWorkerSubscriptionEventSchema,
	bridgeWorkerReviewComparisonTargetsQueryEventSchema,
	bridgeWorkerNativeSurfaceSelectionRequestSchema,
	bridgeWorkerReviewCandidateFailedEventSchema,
	bridgeWorkerReviewCandidateReadyEventSchema,
	bridgeWorkerReviewCandidateStartedEventSchema,
	bridgeWorkerReviewPublicationInstallAdmissionEventSchema,
	bridgeWorkerReviewPierreRenderJobEventSchema,
	bridgeWorkerFilePierreRenderJobEventSchema,
]);

export type BridgeWorkerHealthEvent = z.infer<typeof bridgeWorkerHealthEventSchema>;
export type BridgeWorkerSessionSuspectEvent = z.infer<typeof bridgeWorkerSessionSuspectEventSchema>;
export type BridgeWorkerSlicePatchEvent = z.infer<typeof bridgeWorkerSlicePatchEventSchema>;
export type BridgeWorkerFileDisplayPatchEvent = z.infer<
	typeof bridgeWorkerFileDisplayPatchEventSchema
>;
export type BridgeWorkerFileQueryOutcomeEvent = z.infer<
	typeof bridgeWorkerFileQueryOutcomeEventSchema
>;
export type BridgeWorkerReviewDisplayPatchEvent = z.infer<
	typeof bridgeWorkerReviewDisplayPatchEventSchema
>;
export type BridgeWorkerFileRenderPatch = z.infer<typeof bridgeWorkerFileRenderPatchSchema>;
type BridgeWorkerFileRenderPatchEventValue = z.infer<typeof bridgeWorkerFileRenderPatchEventSchema>;
export type BridgeWorkerFileRenderPatchEvent = BridgeWorkerSurfacePublicationEnvelope<
	'file',
	BridgeWorkerFileRenderPatchEventValue
>;
export type BridgeWorkerReviewRenderPatch = z.infer<typeof bridgeWorkerReviewRenderPatchSchema>;
type BridgeWorkerReviewRenderPatchEventValue = z.infer<
	typeof bridgeWorkerReviewRenderPatchEventSchema
>;
export type BridgeWorkerReviewRenderPatchEvent = BridgeWorkerSurfacePublicationEnvelope<
	'review',
	BridgeWorkerReviewRenderPatchEventValue
>;
export type BridgeWorkerSubscriptionEvent = z.infer<typeof bridgeWorkerSubscriptionEventSchema>;
export type BridgeWorkerNativeSurfaceSelectionRequest = z.infer<
	typeof bridgeWorkerNativeSurfaceSelectionRequestSchema
>;
type BridgeWorkerReviewPierreRenderJobEventValue = z.infer<
	typeof bridgeWorkerReviewPierreRenderJobEventSchema
>;
export type BridgeWorkerReviewPierreRenderJobEvent = BridgeWorkerSurfacePublicationEnvelope<
	'review',
	BridgeWorkerReviewPierreRenderJobEventValue
>;
type BridgeWorkerFilePierreRenderJobEventValue = z.infer<
	typeof bridgeWorkerFilePierreRenderJobEventSchema
>;
export type BridgeWorkerFilePierreRenderJobEvent = BridgeWorkerSurfacePublicationEnvelope<
	'file',
	BridgeWorkerFilePierreRenderJobEventValue
>;
export type BridgeWorkerServerToMainMessage = z.infer<typeof bridgeWorkerServerToMainMessageSchema>;
export type BridgeWorkerServerToMainWireMessage = z.infer<
	typeof bridgeWorkerServerToMainWireMessageSchema
>;
