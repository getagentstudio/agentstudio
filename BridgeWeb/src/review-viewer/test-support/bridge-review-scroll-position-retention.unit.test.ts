import { describe, expect, test } from 'vitest';

import {
	evaluateReviewScrollPositionRetention,
	type ReviewScrollPositionRetentionDiagnostic,
	type ReviewScrollPositionRetentionInput,
} from './bridge-review-scroll-position-retention.test-support.js';

const retainedPosition = {
	maximumScrollTopAfterReplacement: 1_000,
	rawScrollTopAfterReplacement: 600,
	rawScrollTopBeforeReplacement: 600,
	semanticAnchorAfterReplacement: { itemId: 'review-file-04', viewportOffsetPixels: -125 },
	semanticAnchorBeforeReplacement: { itemId: 'review-file-04', viewportOffsetPixels: -125 },
} satisfies ReviewScrollPositionRetentionInput;

interface ReviewPositionScenario {
	readonly expected: Partial<ReviewScrollPositionRetentionDiagnostic>;
	readonly input: ReviewScrollPositionRetentionInput;
	readonly name: string;
}

const positionScenarios = [
	{
		name: 'retains the raw coordinate even when surrounding geometry changes the anchor',
		input: {
			...retainedPosition,
			semanticAnchorAfterReplacement: { itemId: 'review-file-05', viewportOffsetPixels: -300 },
		},
		expected: {
			rawScrollCoordinateRetained: true,
			scrollClampedToNewMaximum: false,
			scrollPositionRetained: true,
			semanticViewportAnchorRetained: false,
		},
	},
	{
		name: 'allows a one-pixel raw coordinate difference',
		input: {
			...retainedPosition,
			rawScrollTopAfterReplacement: 601,
			semanticAnchorAfterReplacement: { itemId: 'review-file-05', viewportOffsetPixels: 0 },
		},
		expected: { rawScrollCoordinateRetained: true, scrollPositionRetained: true },
	},
	{
		name: 'retains the same item and viewport offset when its raw coordinate moves',
		input: { ...retainedPosition, rawScrollTopAfterReplacement: 400 },
		expected: {
			rawScrollCoordinateRetained: false,
			scrollClampedToNewMaximum: false,
			scrollPositionRetained: true,
			semanticViewportAnchorRetained: true,
		},
	},
	{
		name: 'allows a one-pixel semantic offset difference',
		input: {
			...retainedPosition,
			rawScrollTopAfterReplacement: 400,
			semanticAnchorAfterReplacement: { itemId: 'review-file-04', viewportOffsetPixels: -124 },
		},
		expected: { scrollPositionRetained: true, semanticViewportAnchorRetained: true },
	},
	{
		name: 'accepts the clamp after the observed maximum shrinks from 7729 to 5141',
		input: {
			...retainedPosition,
			maximumScrollTopAfterReplacement: 5_141,
			rawScrollTopBeforeReplacement: 5_565,
			rawScrollTopAfterReplacement: 5_141,
			semanticAnchorAfterReplacement: { itemId: 'review-file-05', viewportOffsetPixels: -300 },
		},
		expected: {
			rawScrollCoordinateRetained: false,
			scrollClampedToNewMaximum: true,
			scrollPositionRetained: true,
			semanticViewportAnchorRetained: false,
		},
	},
	{
		name: 'allows a clamp within one pixel of the new maximum',
		input: {
			...retainedPosition,
			maximumScrollTopAfterReplacement: 500,
			rawScrollTopAfterReplacement: 499,
			semanticAnchorAfterReplacement: { itemId: 'review-file-04', viewportOffsetPixels: 0 },
		},
		expected: { scrollClampedToNewMaximum: true, scrollPositionRetained: true },
	},
	{
		name: 'rejects a snap to the anchored file header without a clamp',
		input: {
			...retainedPosition,
			rawScrollTopAfterReplacement: 475,
			semanticAnchorAfterReplacement: { itemId: 'review-file-04', viewportOffsetPixels: 0 },
		},
		expected: {
			rawScrollCoordinateRetained: false,
			scrollClampedToNewMaximum: false,
			scrollPositionRetained: false,
			semanticViewportAnchorRetained: false,
		},
	},
	{
		name: 'rejects a neighbouring file even when the viewport offset is unchanged',
		input: {
			...retainedPosition,
			rawScrollTopAfterReplacement: 800,
			semanticAnchorAfterReplacement: { itemId: 'review-file-05', viewportOffsetPixels: -125 },
		},
		expected: { scrollPositionRetained: false, semanticViewportAnchorRetained: false },
	},
	{
		name: 'rejects a several-hundred-pixel shift within the same file without a clamp',
		input: {
			...retainedPosition,
			rawScrollTopAfterReplacement: 900,
			semanticAnchorAfterReplacement: { itemId: 'review-file-04', viewportOffsetPixels: -425 },
		},
		expected: { scrollPositionRetained: false },
	},
	{
		name: 'rejects a restore two pixels short of the new maximum',
		input: {
			...retainedPosition,
			maximumScrollTopAfterReplacement: 500,
			rawScrollTopAfterReplacement: 498,
			semanticAnchorAfterReplacement: { itemId: 'review-file-04', viewportOffsetPixels: 0 },
		},
		expected: { scrollClampedToNewMaximum: false, scrollPositionRetained: false },
	},
	{
		name: 'does not call a jump to the maximum a clamp when the old position still fits',
		input: {
			...retainedPosition,
			rawScrollTopAfterReplacement: 1_000,
			semanticAnchorAfterReplacement: { itemId: 'review-file-04', viewportOffsetPixels: 0 },
		},
		expected: { scrollClampedToNewMaximum: false, scrollPositionRetained: false },
	},
	{
		name: 'rejects a raw difference beyond one pixel and an offset difference beyond one pixel',
		input: {
			...retainedPosition,
			rawScrollTopAfterReplacement: 602,
			semanticAnchorAfterReplacement: { itemId: 'review-file-04', viewportOffsetPixels: -123 },
		},
		expected: {
			rawScrollCoordinateRetained: false,
			scrollPositionRetained: false,
			semanticViewportAnchorRetained: false,
		},
	},
	{
		name: 'rejects a reset to top even when the semantic anchor matches',
		input: { ...retainedPosition, rawScrollTopAfterReplacement: 0 },
		expected: { scrollPositionRetained: false, semanticViewportAnchorRetained: true },
	},
	{
		name: 'rejects a reset to top even when a shrunken document clamps to zero',
		input: {
			...retainedPosition,
			maximumScrollTopAfterReplacement: 0,
			rawScrollTopAfterReplacement: 0,
			semanticAnchorAfterReplacement: { itemId: 'review-file-00', viewportOffsetPixels: 0 },
		},
		expected: { scrollClampedToNewMaximum: true, scrollPositionRetained: false },
	},
] satisfies readonly ReviewPositionScenario[];

describe('Review scroll position retention', () => {
	test.each(positionScenarios)('$name', ({ input, expected }): void => {
		expect(evaluateReviewScrollPositionRetention(input)).toMatchObject(expected);
	});
});
