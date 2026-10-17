import { z } from 'zod';

import { bridgeProductReviewContentSourceDescriptorSchema } from './bridge-product-content-contracts.js';
import {
	bridgeProductDisplayPathSchema,
	bridgeProductIdentifierSchema,
	bridgeProductNonnegativeSequenceSchema,
	bridgeProductPositiveSequenceSchema,
	bridgeProductSafeMessageSchema,
} from './bridge-product-contract-primitives.js';
import { bridgeProductReviewComparisonOriginSchema } from './bridge-product-review-comparison-contracts.js';
import { bridgeProductReviewComparisonPresentationSchema } from './bridge-product-review-comparison-presentation-contracts.js';
import {
	bridgeProductReviewItemMetadataSchema,
	bridgeProductReviewQuerySchema,
	bridgeProductReviewRefreshImpactSchema,
	bridgeProductReviewSourceEndpointSchema,
} from './bridge-product-review-metadata-contracts.js';
import {
	bridgeProductReviewPackageSummarySchema,
	bridgeProductReviewPublicationIdSchema,
} from './bridge-product-review-primitives.js';

const reviewContentRoleValueSchema = z.discriminatedUnion('state', [
	z
		.object({
			state: z.literal('available'),
			source: bridgeProductReviewContentSourceDescriptorSchema,
		})
		.strict(),
	z.object({ state: z.literal('unavailable') }).strict(),
	z.object({ state: z.literal('absent') }).strict(),
]);

const reviewRoleValuesSchema = z
	.object({
		base: reviewContentRoleValueSchema,
		diff: reviewContentRoleValueSchema,
		file: reviewContentRoleValueSchema,
		head: reviewContentRoleValueSchema,
	})
	.strict();

const reviewRoleExtentsSchema = z
	.object({
		base: bridgeProductNonnegativeSequenceSchema.nullable(),
		diff: bridgeProductNonnegativeSequenceSchema.nullable(),
		file: bridgeProductNonnegativeSequenceSchema.nullable(),
		head: bridgeProductNonnegativeSequenceSchema.nullable(),
	})
	.strict();

const reviewBatchItemSchema = bridgeProductReviewItemMetadataSchema
	.omit({ contentDescriptorIdsByRole: true, contentRoles: true })
	.safeExtend({
		contentByRole: reviewRoleValuesSchema,
		extentByRole: reviewRoleExtentsSchema,
		parentPath: bridgeProductDisplayPathSchema.nullable(),
		recordKind: z.literal('item'),
		sortKey: bridgeProductNonnegativeSequenceSchema,
	})
	.superRefine((item, context): void => {
		for (const role of ['base', 'diff', 'file', 'head'] as const) {
			const content = item.contentByRole[role];
			if (content.state !== 'available') continue;
			if (content.source.itemId !== item.itemId || content.source.role !== role) {
				context.addIssue({
					code: 'custom',
					message: 'Review content source must match its item and role.',
					path: ['contentByRole', role],
				});
			}
		}
	});

const reviewDisplayedPublicationSchema = z
	.object({
		baseEndpoint: bridgeProductReviewSourceEndpointSchema,
		comparisonOrigin: bridgeProductReviewComparisonOriginSchema.nullable(),
		generation: bridgeProductNonnegativeSequenceSchema,
		headEndpoint: bridgeProductReviewSourceEndpointSchema,
		packageId: bridgeProductIdentifierSchema,
		publicationId: bridgeProductReviewPublicationIdSchema,
		query: bridgeProductReviewQuerySchema,
		reviewComparison: bridgeProductReviewComparisonPresentationSchema.nullable(),
		reviewedSubjectLabel: bridgeProductSafeMessageSchema.nullable(),
		revision: bridgeProductNonnegativeSequenceSchema,
		summary: bridgeProductReviewPackageSummarySchema,
	})
	.strict();

const reviewDesiredPublicationSchema = z
	.object({
		reviewComparison: bridgeProductReviewComparisonPresentationSchema.nullable(),
		status: z.enum(['ready', 'updating', 'failedRetryable', 'failedPermanent']),
	})
	.strict();

const reviewBatchPublicationSchema = z
	.object({
		classifiedRefreshImpact: bridgeProductReviewRefreshImpactSchema.nullable(),
		desired: reviewDesiredPublicationSchema,
		displayed: reviewDisplayedPublicationSchema.nullable(),
		publicationId: bridgeProductReviewPublicationIdSchema,
		recordKind: z.literal('publication'),
		revision: bridgeProductPositiveSequenceSchema,
	})
	.strict();

export const bridgeProductReviewBatchRecordSchema = z.discriminatedUnion('recordKind', [
	reviewBatchItemSchema,
	reviewBatchPublicationSchema,
]);

export type BridgeProductReviewBatchRecord = z.infer<typeof bridgeProductReviewBatchRecordSchema>;
