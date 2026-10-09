import { z } from 'zod';

import {
	BRIDGE_PRODUCT_WIRE_VERSION,
	bridgeProductDisplayPathSchema,
	bridgeProductIdentifierSchema,
	bridgeProductNonnegativeSequenceSchema,
	bridgeProductPositiveSequenceSchema,
} from './bridge-product-contract-primitives.js';
import { bridgeProductMetadataApplicationKindSchema } from './bridge-product-metadata-application-protocol.js';
import { bridgeProductReviewPublicationIdSchema } from './bridge-product-review-primitives.js';
import { bridgeProductViewScopeSchema } from './bridge-product-view-control-wire-contracts.js';

const batchIdentityShape = {
	batchId: bridgeProductIdentifierSchema,
	domain: bridgeProductIdentifierSchema,
	handle: bridgeProductIdentifierSchema,
	incarnation: bridgeProductIdentifierSchema,
	metadataStreamId: bridgeProductIdentifierSchema,
	paneSessionId: bridgeProductIdentifierSchema,
	scopeRevision: bridgeProductNonnegativeSequenceSchema,
	streamSequence: bridgeProductPositiveSequenceSchema,
	subscriptionId: bridgeProductIdentifierSchema,
	subscriptionKind: bridgeProductMetadataApplicationKindSchema,
	wireVersion: z.literal(BRIDGE_PRODUCT_WIRE_VERSION),
	workerInstanceId: bridgeProductIdentifierSchema,
} as const;

const presentValueSchema = z.custom<unknown>((value): boolean => value !== undefined);

export const bridgeProductBatchModeSchema = z.enum(['snapshot', 'change', 'coverage']);
export const bridgeProductSnapshotCauseSchema = z.enum([
	'open',
	'requested',
	'recovery',
	'newerInput',
]);
export type BridgeProductSnapshotCause = z.infer<typeof bridgeProductSnapshotCauseSchema>;

export const bridgeProductBatchPartSchema = z.discriminatedUnion('operation', [
	z
		.object({
			key: bridgeProductDisplayPathSchema,
			operation: z.literal('put'),
			revision: bridgeProductPositiveSequenceSchema,
			value: presentValueSchema,
		})
		.strict(),
	z
		.object({
			key: bridgeProductDisplayPathSchema,
			operation: z.literal('delete'),
			revision: bridgeProductPositiveSequenceSchema,
		})
		.strict(),
	z.object({ key: bridgeProductDisplayPathSchema, operation: z.literal('evict') }).strict(),
]);

const bridgeProductBatchBeginFrameSchema = z
	.object({
		...batchIdentityShape,
		baseRevision: bridgeProductNonnegativeSequenceSchema,
		kind: z.literal('subscription.batchBegin'),
		mode: bridgeProductBatchModeSchema,
		snapshotCause: bridgeProductSnapshotCauseSchema.optional(),
		partCount: bridgeProductNonnegativeSequenceSchema,
		publicationId: bridgeProductReviewPublicationIdSchema.optional(),
		requiresCollection: bridgeProductNonnegativeSequenceSchema.optional(),
		scope: bridgeProductViewScopeSchema,
		targetRevision: bridgeProductNonnegativeSequenceSchema,
	})
	.strict()
	.superRefine((frame, context): void => {
		if ((frame.mode === 'snapshot') !== (frame.snapshotCause !== undefined)) {
			context.addIssue({
				code: 'custom',
				path: ['snapshotCause'],
				message: 'Only snapshots require a snapshot cause.',
			});
		}
		if (frame.targetRevision < frame.baseRevision) {
			context.addIssue({ code: 'custom', message: 'Batch target revision precedes its base.' });
		}
		if (frame.subscriptionKind === 'review.metadata' && frame.publicationId === undefined) {
			context.addIssue({ code: 'custom', message: 'Review batch requires publicationId.' });
		}
		if (frame.subscriptionKind !== 'review.metadata' && frame.publicationId !== undefined) {
			context.addIssue({ code: 'custom', message: 'Only Review batches name a publication.' });
		}
	});

const bridgeProductBatchPartFrameSchema = z
	.object({
		...batchIdentityShape,
		deliverySequence: bridgeProductPositiveSequenceSchema,
		kind: z.literal('subscription.batchPart'),
		part: bridgeProductBatchPartSchema,
		partIndex: bridgeProductNonnegativeSequenceSchema,
	})
	.strict();

const bridgeProductBatchCompleteFrameSchema = z
	.object({
		...batchIdentityShape,
		coveredScope: bridgeProductViewScopeSchema,
		kind: z.literal('subscription.batchComplete'),
	})
	.strict();

export const bridgeProductBatchFrameSchema = z.discriminatedUnion('kind', [
	bridgeProductBatchBeginFrameSchema,
	bridgeProductBatchPartFrameSchema,
	bridgeProductBatchCompleteFrameSchema,
]);

export type BridgeProductBatchFrame = z.infer<typeof bridgeProductBatchFrameSchema>;
