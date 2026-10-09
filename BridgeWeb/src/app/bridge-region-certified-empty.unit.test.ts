import { expect, test } from 'vitest';

import { projectBridgeRegionPresentation } from './bridge-region-presentation-state.js';

test('a held successor to a certified empty read is Updating over the last complete read', (): void => {
	expect(
		projectBridgeRegionPresentation({
			demandedIdentity: 'review',
			read: { kind: 'complete', identity: 'review', hasContent: false },
			surface: { kind: 'updating', rest: 'held' },
		}),
	).toEqual({ kind: 'updating', rest: 'held' });
});

test('failure preserves a last complete empty read while marking it stale', (): void => {
	expect(
		projectBridgeRegionPresentation({
			demandedIdentity: 'review',
			read: { kind: 'complete', identity: 'review', hasContent: false },
			surface: {
				kind: 'failed',
				failure: { kind: 'retryable', scope: 'surface', message: 'Update unavailable' },
			},
		}),
	).toMatchObject({ kind: 'failed', retainsContent: true });
});
