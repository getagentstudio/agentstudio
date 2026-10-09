import { z } from 'zod';

import { bridgeProductReviewContentDigestSchema } from './bridge-product-content-contracts.js';
import {
	bridgeProductIdentifierSchema,
	bridgeProductNonnegativeSequenceSchema,
} from './bridge-product-contract-primitives.js';
import { bridgeProductReviewComparisonPresentationSchema } from './bridge-product-review-comparison-presentation-contracts.js';
import {
	BRIDGE_PRODUCT_MAXIMUM_REVIEW_METADATA_WINDOW_ENTRY_COUNT,
	bridgeProductReviewComparisonOriginSchema,
	bridgeProductReviewExtentFactSchema,
	bridgeProductReviewItemMetadataSchema,
	bridgeProductReviewQuerySchema,
	bridgeProductReviewSourceEndpointSchema,
	bridgeProductReviewTreeRowSchema,
} from './bridge-product-review-metadata-contracts.js';
import {
	bridgeProductReviewContentRoleSchema,
	bridgeProductReviewPackageSummarySchema,
} from './bridge-product-review-primitives.js';

export const BRIDGE_WORKER_REVIEW_DISPLAY_PATCH_LIMIT = 64;

const bridgeWorkerReviewSemanticIdentitySchema = z.string().min(1).max(4_096);

const bridgeWorkerReviewDisplayContentWindowIdentitySchema = z
	.object({
		semanticDocumentRevision: bridgeWorkerReviewSemanticIdentitySchema,
		windowKey: bridgeWorkerReviewSemanticIdentitySchema,
	})
	.strict();

const bridgeWorkerReviewDisplayContentFactSchema = z
	.object({
		contentDigest: bridgeProductReviewContentDigestSchema,
		role: bridgeProductReviewContentRoleSchema,
		semanticDocumentRevision: bridgeWorkerReviewSemanticIdentitySchema,
		windowIdentity: bridgeWorkerReviewDisplayContentWindowIdentitySchema.optional(),
	})
	.strict();

const bridgeWorkerReviewDisplayItemSchema = z
	.object({
		contentFacts: z.array(bridgeWorkerReviewDisplayContentFactSchema).max(4).readonly(),
		extentFacts: z.array(bridgeProductReviewExtentFactSchema).max(4).readonly(),
		metadata: bridgeProductReviewItemMetadataSchema,
		metadataWindowIdentity: bridgeWorkerReviewSemanticIdentitySchema,
	})
	.strict()
	.superRefine((item, context): void => {
		for (const [contentFactIndex, contentFact] of item.contentFacts.entries()) {
			if (!item.metadata.contentRoles.includes(contentFact.role)) {
				context.addIssue({
					code: 'custom',
					message: 'Review display content fact must match an item content role.',
					path: ['contentFacts', contentFactIndex, 'role'],
				});
			}
		}
		for (const [factIndex, fact] of item.extentFacts.entries()) {
			if (fact.itemId !== item.metadata.itemId) {
				context.addIssue({
					code: 'custom',
					message: 'Review display extent fact must match its item identity.',
					path: ['extentFacts', factIndex, 'itemId'],
				});
			}
		}
	});

const bridgeWorkerReviewSourceDisplayPayloadSchema = z
	.object({
		baseEndpoint: bridgeProductReviewSourceEndpointSchema.nullable(),
		comparisonOrigin: bridgeProductReviewComparisonOriginSchema.nullable(),
		headEndpoint: bridgeProductReviewSourceEndpointSchema.nullable(),
		metadataWindowIdentity: bridgeWorkerReviewSemanticIdentitySchema,
		metadataSourceId: bridgeProductIdentifierSchema,
		packageId: bridgeProductIdentifierSchema,
		query: bridgeProductReviewQuerySchema.nullable(),
		reviewGeneration: bridgeProductNonnegativeSequenceSchema,
		reviewedSubjectLabel: z.string().min(1).nullable(),
		revision: bridgeProductNonnegativeSequenceSchema,
		status: z.enum(['loading', 'ready', 'stale']),
		summary: bridgeProductReviewPackageSummarySchema.nullable(),
		totalItemCount: bridgeProductNonnegativeSequenceSchema.nullable(),
		totalTreeRowCount: bridgeProductNonnegativeSequenceSchema.nullable(),
	})
	.strict()
	.superRefine((payload, context): void => {
		if (
			payload.status === 'ready' &&
			(payload.baseEndpoint === null ||
				payload.headEndpoint === null ||
				payload.query === null ||
				payload.summary === null ||
				payload.totalItemCount === null ||
				payload.totalTreeRowCount === null)
		) {
			context.addIssue({
				code: 'custom',
				message: 'Ready Review display source requires complete display context and extents.',
				path: ['status'],
			});
		}
	});

const bridgeWorkerReviewSourceDisplayPatchSchema = z.discriminatedUnion('operation', [
	z
		.object({
			operation: z.literal('replace'),
			payload: z
				.object({ kind: z.literal('readyEmpty'), status: z.literal('readyEmpty') })
				.strict(),
			slice: z.literal('reviewSource'),
		})
		.strict(),
	z
		.object({
			operation: z.literal('upsert'),
			payload: bridgeWorkerReviewSourceDisplayPayloadSchema,
			slice: z.literal('reviewSource'),
		})
		.strict(),
	z
		.object({
			operation: z.literal('failed'),
			payload: z
				.object({
					error: z.literal('metadataUnavailable'),
					status: z.literal('failed'),
				})
				.strict(),
			slice: z.literal('reviewSource'),
		})
		.strict(),
]);

const bridgeWorkerReviewTreeSpliceDisplaySchema = z
	.object({
		deleteCount: bridgeProductNonnegativeSequenceSchema.max(
			BRIDGE_PRODUCT_MAXIMUM_REVIEW_METADATA_WINDOW_ENTRY_COUNT,
		),
		rows: z
			.array(bridgeProductReviewTreeRowSchema)
			.max(BRIDGE_PRODUCT_MAXIMUM_REVIEW_METADATA_WINDOW_ENTRY_COUNT)
			.readonly(),
		startIndex: bridgeProductNonnegativeSequenceSchema,
	})
	.strict();

const bridgeWorkerReviewDisplayMutationOperationSchema = z.discriminatedUnion('operationKind', [
	z
		.object({
			items: z
				.array(bridgeWorkerReviewDisplayItemSchema)
				.max(BRIDGE_PRODUCT_MAXIMUM_REVIEW_METADATA_WINDOW_ENTRY_COUNT)
				.readonly(),
			operationKind: z.literal('upsertItems'),
		})
		.strict(),
	z
		.object({
			itemIds: z
				.array(bridgeProductIdentifierSchema)
				.max(BRIDGE_PRODUCT_MAXIMUM_REVIEW_METADATA_WINDOW_ENTRY_COUNT)
				.readonly(),
			operationKind: z.literal('removeItems'),
		})
		.strict(),
	z
		.object({
			itemIds: z
				.array(bridgeProductIdentifierSchema)
				.max(BRIDGE_PRODUCT_MAXIMUM_REVIEW_METADATA_WINDOW_ENTRY_COUNT)
				.readonly(),
			operationKind: z.literal('replaceItemOrder'),
		})
		.strict(),
	z
		.object({
			...bridgeWorkerReviewTreeSpliceDisplaySchema.shape,
			operationKind: z.literal('spliceTreeRows'),
		})
		.strict(),
]);

const bridgeWorkerReviewItemDisplayPatchSchema = z.discriminatedUnion('operation', [
	z.object({ operation: z.literal('reset'), slice: z.literal('reviewItem') }).strict(),
	z
		.object({
			operation: z.literal('batch'),
			payload: z
				.object({
					items: z
						.array(bridgeWorkerReviewDisplayItemSchema)
						.max(BRIDGE_PRODUCT_MAXIMUM_REVIEW_METADATA_WINDOW_ENTRY_COUNT)
						.readonly(),
					operations: z
						.array(bridgeWorkerReviewDisplayMutationOperationSchema)
						.max(BRIDGE_PRODUCT_MAXIMUM_REVIEW_METADATA_WINDOW_ENTRY_COUNT)
						.readonly(),
					reset: z.boolean(),
					startIndex: bridgeProductNonnegativeSequenceSchema.nullable(),
				})
				.strict(),
			slice: z.literal('reviewItem'),
		})
		.strict(),
]);

const bridgeWorkerReviewTreeWindowDisplaySchema = z
	.object({
		rows: z
			.array(bridgeProductReviewTreeRowSchema)
			.max(BRIDGE_PRODUCT_MAXIMUM_REVIEW_METADATA_WINDOW_ENTRY_COUNT)
			.readonly(),
		startIndex: bridgeProductNonnegativeSequenceSchema,
	})
	.strict();

const bridgeWorkerReviewTreeDisplayPatchSchema = z.discriminatedUnion('operation', [
	z.object({ operation: z.literal('reset'), slice: z.literal('reviewTree') }).strict(),
	z
		.object({
			operation: z.literal('batch'),
			payload: z
				.object({
					reset: z.boolean(),
					windows: z
						.array(bridgeWorkerReviewTreeWindowDisplaySchema)
						.max(BRIDGE_PRODUCT_MAXIMUM_REVIEW_METADATA_WINDOW_ENTRY_COUNT)
						.readonly(),
				})
				.strict(),
			slice: z.literal('reviewTree'),
		})
		.strict(),
]);

const bridgeWorkerReviewComparisonDisplayPatchSchema = z
	.object({
		operation: z.literal('replace'),
		payload: bridgeProductReviewComparisonPresentationSchema.nullable(),
		slice: z.literal('reviewComparison'),
	})
	.strict();

export const bridgeWorkerReviewDisplayPatchSchema = z.discriminatedUnion('slice', [
	bridgeWorkerReviewComparisonDisplayPatchSchema,
	bridgeWorkerReviewSourceDisplayPatchSchema,
	bridgeWorkerReviewItemDisplayPatchSchema,
	bridgeWorkerReviewTreeDisplayPatchSchema,
]);

export type BridgeWorkerReviewDisplayItem = z.infer<typeof bridgeWorkerReviewDisplayItemSchema>;
export type BridgeWorkerReviewSourceDisplayPayload = z.infer<
	typeof bridgeWorkerReviewSourceDisplayPayloadSchema
>;
export type BridgeWorkerReviewDisplayPatch = z.infer<typeof bridgeWorkerReviewDisplayPatchSchema>;
