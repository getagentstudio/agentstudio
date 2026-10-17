import { describe, expect, test } from 'vitest';

import { bridgeProductDevBootstrapRequestSchema } from './bridge-product-dev-bootstrap.js';
import { bridgeProductNavigationCommandSchema } from './bridge-product-session-contracts.js';

const maximumMultibytePath = 'é'.repeat(2_048);
const oversizedMultibytePath = `${maximumMultibytePath}a`;
const invalidUnicodePath = '\ud800';

const fileCommand = {
	bindingRevision: 5,
	commandId: 'navigation-file-display-path',
	commandKind: 'activateTarget',
	source: {
		sourceId: 'accepted-file-source',
		sourceKind: 'file',
		subscriptionGeneration: 9,
	},
	surface: 'file',
	target: { path: maximumMultibytePath, targetKind: 'file', version: 'current' },
} as const;

const reviewCommand = {
	bindingRevision: 6,
	commandId: 'navigation-review-display-path',
	commandKind: 'activateTarget',
	source: {
		generation: 11,
		metadataSourceId: 'accepted-review-source',
		packageId: 'accepted-review-package',
		sourceKind: 'review',
	},
	surface: 'review',
	target: {
		path: maximumMultibytePath,
		reviewItemId: 'review-item-7',
		targetKind: 'review',
		version: 'head',
	},
} as const;

const devFileIntent = {
	commandId: 'dev:worktree:file:display-path',
	commandKind: 'activateTarget',
	surface: 'file',
	target: fileCommand.target,
} as const;

const devReviewIntent = {
	commandId: 'dev:worktree:review:display-path',
	commandKind: 'activateTarget',
	surface: 'review',
	target: reviewCommand.target,
} as const;

describe('Bridge product navigation display paths', () => {
	test('accepts a 4,096-byte multibyte path at shared and Vite bootstrap ingress', () => {
		expect(new TextEncoder().encode(maximumMultibytePath)).toHaveLength(4_096);
		expect(bridgeProductNavigationCommandSchema.safeParse(fileCommand).success).toBe(true);
		expect(bridgeProductNavigationCommandSchema.safeParse(reviewCommand).success).toBe(true);
		expect(devBootstrapAccepts(devFileIntent)).toBe(true);
		expect(devBootstrapAccepts(devReviewIntent)).toBe(true);
	});

	test('rejects oversized and invalid-Unicode paths at shared and Vite bootstrap ingress', () => {
		expect(new TextEncoder().encode(oversizedMultibytePath)).toHaveLength(4_097);
		for (const invalidPath of [oversizedMultibytePath, invalidUnicodePath]) {
			expect(
				bridgeProductNavigationCommandSchema.safeParse({
					...fileCommand,
					target: { ...fileCommand.target, path: invalidPath },
				}).success,
			).toBe(false);
			expect(
				bridgeProductNavigationCommandSchema.safeParse({
					...reviewCommand,
					target: { ...reviewCommand.target, path: invalidPath },
				}).success,
			).toBe(false);
			expect(
				devBootstrapAccepts({
					...devFileIntent,
					target: { ...devFileIntent.target, path: invalidPath },
				}),
			).toBe(false);
			expect(
				devBootstrapAccepts({
					...devReviewIntent,
					target: { ...devReviewIntent.target, path: invalidPath },
				}),
			).toBe(false);
		}
	});
});

function devBootstrapAccepts(navigationIntent: unknown): boolean {
	return bridgeProductDevBootstrapRequestSchema.safeParse({
		navigationIntent,
		reason: 'initial',
		tabId: 'tab-display-path-test',
	}).success;
}
