import { describe, expect, test } from 'vitest';

import nullBranchPublication from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-review-contribution-null-branch.json' with { type: 'json' };
import { bridgeProductReviewBatchRecordSchema } from './bridge-product-review-batch-record-contracts.js';
import {
	BRIDGE_PRODUCT_REVIEW_COMPARISON_TARGET_MAXIMUM_ROWS,
	bridgeProductReviewComparisonOriginSchema,
	bridgeProductReviewComparisonTargetCatalogSchema,
	bridgeProductReviewComparisonTargetSchema,
} from './bridge-product-review-comparison-contracts.js';

describe('Bridge product review comparison contracts', () => {
	test('accepts the native contribution publication with a required null branch name', () => {
		expect(bridgeProductReviewBatchRecordSchema.parse(nullBranchPublication)).toEqual(
			nullBranchPublication,
		);
		const origin = nullBranchPublication.displayed.comparisonOrigin;
		expect(bridgeProductReviewComparisonOriginSchema.parse(origin)).toEqual(origin);
		expect(
			bridgeProductReviewComparisonOriginSchema.safeParse({
				...origin,
				reviewedSubjectBranchName: undefined,
			}).success,
		).toBe(false);
	});

	test('requires a comparison basis for every moving symbolic target', () => {
		const symbolicTargets = [
			{ basis: 'commonCommit', branchName: 'main', kind: 'localDefaultBranch' },
			{ basis: 'branchTip', branchName: 'main', kind: 'originDefaultBranch', remoteName: 'origin' },
			{ basis: 'commonCommit', kind: 'branch', name: 'feature/review' },
			{ basis: 'branchTip', kind: 'ref', name: 'refs/tags/v1.0.0' },
		] as const;

		for (const target of symbolicTargets) {
			expect(bridgeProductReviewComparisonTargetSchema.parse(target)).toEqual(target);
		}

		expect(
			bridgeProductReviewComparisonTargetSchema.safeParse({
				branchName: 'main',
				kind: 'localDefaultBranch',
			}).success,
		).toBe(false);
	});

	test('keeps exact commit targets direct and basis-free', () => {
		const target = {
			kind: 'commit',
			oid: '0123456789abcdef0123456789abcdef01234567',
		} as const;

		expect(bridgeProductReviewComparisonTargetSchema.parse(target)).toEqual(target);
		expect(
			bridgeProductReviewComparisonTargetSchema.safeParse({
				...target,
				basis: 'commonCommit',
			}).success,
		).toBe(false);
	});

	test('uses truthful effective-base origin vocabulary', () => {
		const commonCommitOrigin = {
			baseOID: 'common-commit-oid',
			baseRole: 'commonCommit',
			comparedRole: 'capturedWorkingTree',
			kind: 'contribution',
			resolvedTargetOID: 'resolved-target-oid',
			reviewedHeadOID: 'reviewed-head-oid',
			reviewedSubjectBranchName: null,
			symbolicTarget: {
				basis: 'commonCommit',
				kind: 'branch',
				name: 'integration',
			},
		} as const;
		const branchTipOrigin = {
			...commonCommitOrigin,
			baseOID: 'branch-tip-oid',
			baseRole: 'selectedTarget',
			reviewedSubjectBranchName: 'feature/review',
			symbolicTarget: { ...commonCommitOrigin.symbolicTarget, basis: 'branchTip' },
		} as const;

		expect(bridgeProductReviewComparisonOriginSchema.parse(commonCommitOrigin)).toEqual(
			commonCommitOrigin,
		);
		expect(bridgeProductReviewComparisonOriginSchema.parse(branchTipOrigin)).toEqual(
			branchTipOrigin,
		);
		expect(
			bridgeProductReviewComparisonOriginSchema.safeParse({
				...commonCommitOrigin,
				baseRole: 'contributionBase',
				contributionBaseOID: 'legacy-base-oid',
			}).success,
		).toBe(false);
		expect(
			bridgeProductReviewComparisonOriginSchema.safeParse({
				...branchTipOrigin,
				reviewedSubjectBranchName: '',
			}).success,
		).toBe(false);
	});

	test('enforces the comparison-target catalog row ceiling', () => {
		const branch = { branchName: 'main', kind: 'local', oid: 'a'.repeat(40) } as const;
		const catalog = {
			branches: Array.from(
				{ length: BRIDGE_PRODUCT_REVIEW_COMPARISON_TARGET_MAXIMUM_ROWS },
				() => branch,
			),
			capturedAtUnixMilliseconds: 2_000,
			currentTarget: null,
			cutoffUnixMilliseconds: 1_000,
			defaultTarget: null,
			isTruncated: false,
		};

		expect(bridgeProductReviewComparisonTargetCatalogSchema.safeParse(catalog).success).toBe(true);
		expect(
			bridgeProductReviewComparisonTargetCatalogSchema.safeParse({
				...catalog,
				branches: [...catalog.branches, branch],
			}).success,
		).toBe(false);
	});
});
