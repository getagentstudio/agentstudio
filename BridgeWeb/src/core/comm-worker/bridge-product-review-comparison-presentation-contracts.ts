import { z } from 'zod';

import {
	bridgeProductIdentifierSchema,
	bridgeProductNonnegativeSequenceSchema,
} from './bridge-product-contract-primitives.js';
import { bridgeProductReviewComparisonTargetSchema } from './bridge-product-review-comparison-contracts.js';

const bridgeProductReviewComparisonAttemptSchema = z.discriminatedUnion('status', [
	z.object({ status: z.literal('noSource') }).strict(),
	z.object({ status: z.literal('selectionRequired') }).strict(),
	z
		.object({
			reviewGeneration: bridgeProductNonnegativeSequenceSchema,
			status: z.literal('pending'),
		})
		.strict(),
	z
		.object({
			reviewGeneration: bridgeProductNonnegativeSequenceSchema,
			status: z.literal('settled'),
		})
		.strict(),
	z
		.object({
			failureKind: z.string().min(1),
			retryable: z.boolean(),
			status: z.literal('unavailable'),
		})
		.strict(),
]);

const bridgeProductReviewDisplayedSnapshotSchema = z.discriminatedUnion('status', [
	z.object({ status: z.literal('none') }).strict(),
	z
		.object({
			packageId: bridgeProductIdentifierSchema,
			reviewGeneration: bridgeProductNonnegativeSequenceSchema,
			revision: bridgeProductNonnegativeSequenceSchema,
			status: z.literal('current'),
		})
		.strict(),
	z
		.object({
			packageId: bridgeProductIdentifierSchema,
			reviewGeneration: bridgeProductNonnegativeSequenceSchema,
			revision: bridgeProductNonnegativeSequenceSchema,
			status: z.literal('stale'),
		})
		.strict(),
]);

export const bridgeProductReviewComparisonPresentationSchema = z
	.object({
		activeTarget: bridgeProductReviewComparisonTargetSchema.nullable(),
		attempt: bridgeProductReviewComparisonAttemptSchema,
		displayedSnapshot: bridgeProductReviewDisplayedSnapshotSchema,
		repositoryDefaultTarget: z
			.object({ branchName: z.string().min(1), remoteName: z.string().min(1) })
			.strict()
			.nullable(),
	})
	.strict();

export type BridgeProductReviewComparisonPresentation = z.infer<
	typeof bridgeProductReviewComparisonPresentationSchema
>;
