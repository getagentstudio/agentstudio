import { z } from 'zod';

import { bridgeWorkerAnnotationProjectionSnapshotSchema } from './bridge-comm-worker-annotation-projection-decoder.js';
import { createBridgeMetadataCatalogTransferSchema } from './bridge-metadata-catalog-transfer-contracts.js';
import { bridgeProductWorktreeAnnotationOperationSchema } from './bridge-product-call-contracts.js';
import {
	bridgeProductIdentifierSchema,
	bridgeProductNonnegativeSequenceSchema,
	bridgeProductSha256Schema,
} from './bridge-product-contract-primitives.js';
import { bridgeProductReviewPublicationIdSchema } from './bridge-product-review-primitives.js';
import {
	bridgeProductWorktreeAnnotationCatalogEntrySchema,
	bridgeProductWorktreeAnnotationDecodedCommandOutcomeSchema,
} from './bridge-product-worktree-annotation-contracts.js';
import {
	bridgeProductAnnotationOutputContentDescriptorSchema,
	bridgeProductWorktreeAnnotationOutputInspectRequestSchema,
} from './bridge-product-worktree-annotation-output-contracts.js';
import { bridgeWorkerReviewPublicationIdentitySchema } from './bridge-worker-review-publication-contracts.js';
import {
	bridgeWorkerInteractionSurfaceSchema,
	bridgeWorkerMainToServerBaseSchema,
	bridgeWorkerRequestIdSchema,
	bridgeWorkerServerToMainBaseSchema,
} from './bridge-worker-wire-base-contracts.js';

export const bridgeWorkerAnnotationCommandSchema = bridgeWorkerMainToServerBaseSchema
	.extend({
		command: z.literal('annotationCommand'),
		operation: bridgeProductWorktreeAnnotationOperationSchema,
		reviewPublicationIdentity: bridgeWorkerReviewPublicationIdentitySchema.optional(),
		surface: bridgeWorkerInteractionSurfaceSchema,
	})
	.strict()
	.superRefine((command, context): void => {
		if (command.surface === 'review' && command.reviewPublicationIdentity === undefined) {
			context.addIssue({
				code: 'custom',
				message: 'Review annotation command requires installed publication identity.',
				path: ['reviewPublicationIdentity'],
			});
		}
		if (command.surface === 'fileView' && command.reviewPublicationIdentity !== undefined) {
			context.addIssue({
				code: 'custom',
				message: 'File annotation command cannot carry Review publication identity.',
				path: ['reviewPublicationIdentity'],
			});
		}
	});

export const bridgeWorkerAnnotationOutputInspectCommandSchema = bridgeWorkerMainToServerBaseSchema
	.extend({
		attemptId: bridgeProductWorktreeAnnotationOutputInspectRequestSchema.shape.attemptId,
		command: z.literal('annotationOutputInspect'),
		surface: bridgeWorkerInteractionSurfaceSchema,
	})
	.strict();

export const bridgeWorkerAnnotationProjectionRetryCommandSchema = bridgeWorkerMainToServerBaseSchema
	.extend({
		command: z.literal('annotationProjectionRetry'),
		surface: bridgeWorkerInteractionSurfaceSchema,
	})
	.strict();

export const bridgeWorkerAnnotationCommandAcceptedEventSchema = bridgeWorkerServerToMainBaseSchema
	.extend({
		kind: z.literal('annotationCommandAccepted'),
		outcome: bridgeProductWorktreeAnnotationDecodedCommandOutcomeSchema.optional(),
		productRequestId: bridgeProductIdentifierSchema,
		requestId: bridgeWorkerRequestIdSchema,
		surface: bridgeWorkerInteractionSurfaceSchema,
	})
	.strict();

export const bridgeWorkerAnnotationProjectionConvergenceEventSchema =
	bridgeWorkerServerToMainBaseSchema
		.extend({
			kind: z.literal('annotationProjectionConvergence'),
			operationCorrelationId: bridgeProductSha256Schema.nullable(),
			state: z.discriminatedUnion('kind', [
				z.object({ catalogAuthorityRetired: z.boolean(), kind: z.literal('refreshing') }).strict(),
				z
					.object({
						catalogAuthorityRetired: z.boolean(),
						kind: z.literal('unavailable'),
						retryable: z.boolean(),
					})
					.strict(),
				z
					.object({
						contentSessionIds: z
							.array(bridgeProductReviewPublicationIdSchema)
							.max(128)
							.refine((sessionIds) => new Set(sessionIds).size === sessionIds.length, {
								message: 'Annotation content-session identities must be unique.',
							})
							.readonly(),
						kind: z.literal('ready'),
						stageAttempt: bridgeProductNonnegativeSequenceSchema,
						reviewPublicationIdentity: bridgeWorkerReviewPublicationIdentitySchema.optional(),
						snapshot: bridgeWorkerAnnotationProjectionSnapshotSchema,
					})
					.strict(),
			]),
			surface: bridgeWorkerInteractionSurfaceSchema,
		})
		.strict()
		.superRefine((event, context): void => {
			if (event.state.kind === 'ready' && event.operationCorrelationId === null) {
				context.addIssue({
					code: 'custom',
					message: 'Ready annotation projection requires lifecycle correlation.',
					path: ['operationCorrelationId'],
				});
			}
			if (
				event.state.kind === 'ready' &&
				event.surface === 'review' &&
				event.state.reviewPublicationIdentity === undefined
			) {
				context.addIssue({
					code: 'custom',
					message: 'Review annotation convergence requires exact publication identity.',
					path: ['state', 'reviewPublicationIdentity'],
				});
			}
			if (
				event.state.kind === 'ready' &&
				event.surface === 'fileView' &&
				event.state.reviewPublicationIdentity !== undefined
			) {
				context.addIssue({
					code: 'custom',
					message: 'File annotation convergence cannot carry Review publication identity.',
					path: ['state', 'reviewPublicationIdentity'],
				});
			}
		});

export const bridgeWorkerAnnotationCatalogStagingEventSchema = bridgeWorkerServerToMainBaseSchema
	.extend({
		authority: z
			.object({
				subscriptionId: bridgeProductIdentifierSchema,
				workerDerivationEpoch: bridgeProductNonnegativeSequenceSchema,
				worktreeId: bridgeProductIdentifierSchema,
			})
			.strict(),
		kind: z.literal('annotationCatalogStaging'),
		surface: bridgeWorkerInteractionSurfaceSchema,
		transfer: createBridgeMetadataCatalogTransferSchema(
			bridgeProductWorktreeAnnotationCatalogEntrySchema,
		),
	})
	.strict()
	.superRefine((event, context): void => {
		if (event.transferDescriptors.length === 0) return;
		context.addIssue({
			code: 'custom',
			message:
				'Annotation catalog staging uses structured-clone data without transfer descriptors.',
			path: ['transferDescriptors'],
		});
	});

const bridgeWorkerArrayBufferSchema = z.custom<ArrayBuffer>(
	(value): value is ArrayBuffer => value instanceof ArrayBuffer,
	'Annotation output exact bytes must be an ArrayBuffer.',
);

export const bridgeWorkerAnnotationOutputInspectionEventSchema = bridgeWorkerServerToMainBaseSchema
	.extend({
		descriptor: bridgeProductAnnotationOutputContentDescriptorSchema,
		exactBytes: bridgeWorkerArrayBufferSchema,
		kind: z.literal('annotationOutputInspection'),
		requestId: bridgeWorkerRequestIdSchema,
		surface: bridgeWorkerInteractionSurfaceSchema,
	})
	.strict()
	.superRefine((event, context): void => {
		const expectedProductSurface = event.surface === 'fileView' ? 'file' : 'review';
		if (event.descriptor.surface !== expectedProductSurface) {
			context.addIssue({
				code: 'custom',
				message: 'Annotation output inspection descriptor must match its worker surface.',
				path: ['descriptor', 'surface'],
			});
		}
		if (event.exactBytes.byteLength !== event.descriptor.declaredByteLength) {
			context.addIssue({
				code: 'custom',
				message: 'Annotation output inspection bytes must match the descriptor length.',
				path: ['exactBytes'],
			});
		}
		const transferDescriptor = event.transferDescriptors[0];
		if (
			event.transferDescriptors.length !== 1 ||
			transferDescriptor?.messageKind !== event.kind ||
			transferDescriptor.mode !== 'transfer' ||
			transferDescriptor.byteLength !== event.exactBytes.byteLength ||
			transferDescriptor.fieldPath.length !== 1 ||
			transferDescriptor.fieldPath[0] !== 'exactBytes'
		) {
			context.addIssue({
				code: 'custom',
				message: 'Annotation output inspection must transfer only its declared exact bytes.',
				path: ['transferDescriptors'],
			});
		}
	});

export type BridgeWorkerAnnotationCommand = z.infer<typeof bridgeWorkerAnnotationCommandSchema>;
export type BridgeWorkerAnnotationOutputInspectCommand = z.infer<
	typeof bridgeWorkerAnnotationOutputInspectCommandSchema
>;
export type BridgeWorkerAnnotationProjectionRetryCommand = z.infer<
	typeof bridgeWorkerAnnotationProjectionRetryCommandSchema
>;
export type BridgeWorkerAnnotationOutputInspectionEvent = z.infer<
	typeof bridgeWorkerAnnotationOutputInspectionEventSchema
>;
export type BridgeWorkerAnnotationCommandAcceptedEvent = z.infer<
	typeof bridgeWorkerAnnotationCommandAcceptedEventSchema
>;
export type BridgeWorkerAnnotationProjectionConvergenceEvent = z.infer<
	typeof bridgeWorkerAnnotationProjectionConvergenceEventSchema
>;
export type BridgeWorkerAnnotationCatalogStagingEvent = z.infer<
	typeof bridgeWorkerAnnotationCatalogStagingEventSchema
>;
