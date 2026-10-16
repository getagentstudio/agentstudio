import { expect, test } from 'vitest';

import { resolveSelectedReviewContentAvailability } from './bridge-app-review-render-snapshot-controller.js';

test('selected Review ready content has a bounded state when its CodeView copy is absent', () => {
	expect(
		resolveSelectedReviewContentAvailability({
			hasCodeViewItem: false,
			paintReleasePending: false,
			rawAvailability: { state: 'ready' },
		}),
	).toEqual({ state: 'failed' });
	expect(
		resolveSelectedReviewContentAvailability({
			hasCodeViewItem: false,
			paintReleasePending: true,
			rawAvailability: { state: 'ready' },
		}),
	).toEqual({ state: 'loading' });
	expect(
		resolveSelectedReviewContentAvailability({
			hasCodeViewItem: true,
			paintReleasePending: false,
			rawAvailability: { state: 'ready' },
		}),
	).toEqual({ state: 'ready' });
});
