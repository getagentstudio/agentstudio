import { z } from 'zod';

export const BRIDGE_PRODUCT_REVIEW_COMPARISON_TARGET_MAXIMUM_ROWS = 2_000;

export const bridgeProductReviewComparisonBasisSchema = z.enum(['commonCommit', 'branchTip']);
export const bridgeProductReviewComparisonBaseRoleSchema = z.enum([
	'commonCommit',
	'selectedTarget',
]);

export const bridgeProductReviewComparisonTargetSchema = z.discriminatedUnion('kind', [
	z
		.object({
			basis: bridgeProductReviewComparisonBasisSchema,
			branchName: z.string().min(1),
			kind: z.literal('localDefaultBranch'),
		})
		.strict(),
	z
		.object({
			basis: bridgeProductReviewComparisonBasisSchema,
			branchName: z.string().min(1),
			kind: z.literal('originDefaultBranch'),
			remoteName: z.string().min(1),
		})
		.strict(),
	z
		.object({
			basis: bridgeProductReviewComparisonBasisSchema,
			kind: z.literal('branch'),
			name: z.string().min(1),
		})
		.strict(),
	z
		.object({
			kind: z.literal('commit'),
			oid: z.string().regex(/^(?:[0-9a-f]{40}|[0-9a-f]{64})$/iu),
		})
		.strict(),
	z
		.object({
			basis: bridgeProductReviewComparisonBasisSchema,
			kind: z.literal('ref'),
			name: z.string().min(1),
		})
		.strict(),
]);

export const bridgeProductReviewComparisonOriginSchema = z
	.object({
		baseOID: z.string().min(1),
		baseRole: bridgeProductReviewComparisonBaseRoleSchema,
		comparedRole: z.literal('capturedWorkingTree'),
		kind: z.literal('contribution'),
		resolvedTargetOID: z.string().min(1),
		reviewedHeadOID: z.string().min(1),
		reviewedSubjectBranchName: z.string().min(1).nullable(),
		symbolicTarget: bridgeProductReviewComparisonTargetSchema,
	})
	.strict();

export const bridgeProductReviewComparisonBranchTargetSchema = z.discriminatedUnion('kind', [
	z
		.object({
			branchName: z.string().min(1),
			kind: z.literal('local'),
			oid: z.string().regex(/^(?:[0-9a-f]{40}|[0-9a-f]{64})$/iu),
		})
		.strict(),
	z
		.object({
			branchName: z.string().min(1),
			kind: z.literal('remoteTracking'),
			oid: z.string().regex(/^(?:[0-9a-f]{40}|[0-9a-f]{64})$/iu),
			remoteName: z.string().min(1),
		})
		.strict(),
]);

export const bridgeProductReviewComparisonTargetCatalogSchema = z
	.object({
		branches: z
			.array(bridgeProductReviewComparisonBranchTargetSchema)
			.max(BRIDGE_PRODUCT_REVIEW_COMPARISON_TARGET_MAXIMUM_ROWS),
		capturedAtUnixMilliseconds: z.number().int().nonnegative(),
		cutoffUnixMilliseconds: z.number().int().nonnegative(),
		currentTarget: bridgeProductReviewComparisonBranchTargetSchema.nullable(),
		defaultTarget: bridgeProductReviewComparisonBranchTargetSchema.nullable(),
		isTruncated: z.boolean(),
	})
	.strict();

export type BridgeProductReviewComparisonBranchTarget = z.infer<
	typeof bridgeProductReviewComparisonBranchTargetSchema
>;
export type BridgeProductReviewComparisonTargetCatalog = z.infer<
	typeof bridgeProductReviewComparisonTargetCatalogSchema
>;
