import { z } from 'zod';

import {
	BRIDGE_PRODUCT_MAXIMUM_CONTROL_REQUEST_SEQUENCE,
	BRIDGE_PRODUCT_WIRE_VERSION,
	bridgeProductDemandLaneSchema,
	bridgeProductDisplayPathSchema,
	bridgeProductIdentifierSchema,
	bridgeProductNonnegativeSequenceSchema,
	bridgeProductPositiveSequenceSchema,
	bridgeProductUnicodeScalarUtf8ByteLength,
} from './bridge-product-contract-primitives.js';
import { bridgeProductMetadataApplicationKindSchema } from './bridge-product-metadata-application-protocol.js';

export const bridgeProductMaximumViewScopeItemCount = 10_000;
const bridgeProductMaximumViewScopeGroupCount = 64;

const bridgeProductReviewViewScopeItemIdSchema = z
	.string()
	.min(1)
	.superRefine((itemId, context) => {
		const itemIdByteLength = bridgeProductUnicodeScalarUtf8ByteLength(itemId);
		if (itemIdByteLength === null || itemIdByteLength > 128) {
			context.addIssue({
				code: 'custom',
				message: 'Review view item ids must fit the UTF-8 ceiling.',
			});
		}
	});

const bridgeProductReviewViewScopeInterestSchema = z
	.object({
		itemIds: z
			.array(bridgeProductReviewViewScopeItemIdSchema)
			.max(bridgeProductMaximumViewScopeItemCount)
			.readonly(),
		lane: bridgeProductDemandLaneSchema,
	})
	.strict();

const bridgeProductFileViewScopeInterestSchema = z
	.object({
		lane: bridgeProductDemandLaneSchema,
		paths: z
			.array(bridgeProductDisplayPathSchema)
			.max(bridgeProductMaximumViewScopeItemCount)
			.readonly(),
	})
	.strict();

const bridgeProductFileViewScopeFields = z
	.object({
		interests: z
			.array(bridgeProductFileViewScopeInterestSchema)
			.max(bridgeProductMaximumViewScopeGroupCount)
			.readonly(),
		pathScope: z
			.array(bridgeProductDisplayPathSchema)
			.max(bridgeProductMaximumViewScopeItemCount)
			.readonly(),
	})
	.strict()
	.superRefine((scope, context): void => {
		const paths = scope.interests.flatMap((interest) => interest.paths);
		if (
			new Set(paths).size !== paths.length ||
			new Set(scope.pathScope).size !== scope.pathScope.length
		) {
			context.addIssue({ code: 'custom', message: 'File view scope paths must be unique.' });
		}
	});

const bridgeProductReviewViewScopeFields = z
	.object({
		interests: z
			.array(bridgeProductReviewViewScopeInterestSchema)
			.max(bridgeProductMaximumViewScopeGroupCount)
			.readonly(),
	})
	.strict()
	.superRefine((scope, context): void => {
		const itemIds = scope.interests.flatMap((interest) => interest.itemIds);
		if (new Set(itemIds).size !== itemIds.length) {
			context.addIssue({ code: 'custom', message: 'Review view scope item ids must be unique.' });
		}
	});

const controlCorrelationShape = {
	paneSessionId: bridgeProductIdentifierSchema,
	requestId: bridgeProductIdentifierSchema,
	requestSequence: bridgeProductPositiveSequenceSchema.max(
		BRIDGE_PRODUCT_MAXIMUM_CONTROL_REQUEST_SEQUENCE,
	),
	wireVersion: z.literal(BRIDGE_PRODUCT_WIRE_VERSION),
	workerInstanceId: bridgeProductIdentifierSchema,
} as const;

const viewControlShape = {
	...controlCorrelationShape,
	domain: bridgeProductIdentifierSchema,
	handle: bridgeProductIdentifierSchema,
	incarnation: bridgeProductIdentifierSchema,
	scopeRevision: bridgeProductNonnegativeSequenceSchema,
	subscriptionId: bridgeProductIdentifierSchema,
	subscriptionKind: bridgeProductMetadataApplicationKindSchema,
} as const;

const fileChangeKindSchema = z.enum(['added', 'modified', 'renamed', 'deleted', 'copied']);
const fileChangeKindsSchema = z.array(fileChangeKindSchema).superRefine((kinds, context): void => {
	if (new Set(kinds).size !== kinds.length) {
		context.addIssue({ code: 'custom', message: 'File change kinds must be unique.' });
	}
});
const fileChangeFilterSchema = z.discriminatedUnion('kind', [
	z.object({ kind: z.literal('none') }).strict(),
	z
		.object({
			baseline: z.discriminatedUnion('kind', [
				z.object({ kind: z.literal('uncommitted') }).strict(),
				z.object({ kind: z.literal('originDefaultMergeBase') }).strict(),
			]),
			kind: z.literal('changes'),
			kinds: fileChangeKindsSchema,
		})
		.strict(),
]);

export const bridgeProductViewScopeSchema = z.discriminatedUnion('kind', [
	bridgeProductFileViewScopeFields.extend({
		changeFilter: fileChangeFilterSchema,
		kind: z.literal('file'),
		prefix: bridgeProductDisplayPathSchema.optional(),
	}),
	bridgeProductReviewViewScopeFields.extend({
		kind: z.literal('review'),
		prefix: bridgeProductDisplayPathSchema.optional(),
	}),
	z
		.object({
			kind: z.literal('comment'),
			sessionIds: z.array(bridgeProductIdentifierSchema).max(128).readonly(),
			worktreeId: bridgeProductIdentifierSchema,
		})
		.strict()
		.refine((scope) => new Set(scope.sessionIds).size === scope.sessionIds.length, {
			message: 'Comment scope session ids must be unique.',
		}),
]);

export const bridgeProductViewScopeRequestSchema = z
	.object({
		...viewControlShape,
		kind: z.literal('subscription.setScope'),
		scope: bridgeProductViewScopeSchema,
	})
	.strict()
	.superRefine((request, context): void => {
		const expectedKind =
			request.subscriptionKind === 'file.metadata'
				? 'file'
				: request.subscriptionKind === 'review.metadata'
					? 'review'
					: 'comment';
		if (request.scope.kind !== expectedKind) {
			context.addIssue({
				code: 'custom',
				message: 'View scope kind differs from subscription kind.',
			});
		}
	});

export const bridgeProductViewResnapshotRequestSchema = z
	.object({
		...viewControlShape,
		kind: z.literal('subscription.resnapshot'),
	})
	.strict();

export const bridgeProductViewAcknowledgementRequestSchema = z
	.object({
		domain: bridgeProductIdentifierSchema,
		handle: bridgeProductIdentifierSchema,
		incarnation: bridgeProductIdentifierSchema,
		kind: z.literal('subscription.acknowledge'),
		paneSessionId: bridgeProductIdentifierSchema,
		receivedThroughDeliverySequence: bridgeProductPositiveSequenceSchema,
		subscriptionId: bridgeProductIdentifierSchema,
		wireVersion: z.literal(BRIDGE_PRODUCT_WIRE_VERSION),
		workerInstanceId: bridgeProductIdentifierSchema,
	})
	.strict();

/** E4 settlement confirms admission of the desired view operation. The batch
 * completion remains the separate install barrier. */
export const bridgeProductViewAcceptedResponseSchema = z.discriminatedUnion('kind', [
	z.object({ ...viewControlShape, kind: z.literal('subscription.scopeAccepted') }).strict(),
	z.object({ ...viewControlShape, kind: z.literal('subscription.resnapshotAccepted') }).strict(),
]);

/** The escape reply mirrors the cumulative credit position for exact replay. */
export const bridgeProductViewAcknowledgedResponseSchema = z
	.object({
		domain: bridgeProductIdentifierSchema,
		handle: bridgeProductIdentifierSchema,
		incarnation: bridgeProductIdentifierSchema,
		kind: z.literal('subscription.acknowledged'),
		paneSessionId: bridgeProductIdentifierSchema,
		receivedThroughDeliverySequence: bridgeProductPositiveSequenceSchema,
		subscriptionId: bridgeProductIdentifierSchema,
		wireVersion: z.literal(BRIDGE_PRODUCT_WIRE_VERSION),
		workerInstanceId: bridgeProductIdentifierSchema,
	})
	.strict();

export type BridgeProductViewScopeRequest = z.infer<typeof bridgeProductViewScopeRequestSchema>;
export type BridgeProductViewResnapshotRequest = z.infer<
	typeof bridgeProductViewResnapshotRequestSchema
>;
export type BridgeProductViewAcknowledgementRequest = z.infer<
	typeof bridgeProductViewAcknowledgementRequestSchema
>;
export type BridgeProductViewAcceptedResponse = z.infer<
	typeof bridgeProductViewAcceptedResponseSchema
>;
export type BridgeProductViewAcknowledgedResponse = z.infer<
	typeof bridgeProductViewAcknowledgedResponseSchema
>;
