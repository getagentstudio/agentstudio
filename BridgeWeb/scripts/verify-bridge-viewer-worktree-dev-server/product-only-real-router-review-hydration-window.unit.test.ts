import { expect, test } from 'vitest';

import { classifyFreshReviewHydrationWindow } from './product-only-real-router-review-hydration-window.ts';

test('an intersecting unpainted item remains visible and fails hydrated coverage', () => {
	const snapshot = classifyFreshReviewHydrationWindow({
		excludedItemIds: [],
		selectedItemId: null,
		scrollTop: 7580,
		visibleItems: [
			{
				contentState: 'windowed',
				itemId: 'visible-unpainted',
				publicationId: null,
				renderedLineCount: 0,
				sourceCorrelations: null,
			},
		],
	});

	expect(snapshot.visibleNonSelectedItemIds).toEqual(['visible-unpainted']);
	expect(snapshot.hydratedNonSelectedItemIds).toEqual([]);
	expect(snapshot.visibleContentStates).toEqual([
		{ contentState: 'windowed', itemId: 'visible-unpainted' },
	]);
});
