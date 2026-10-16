import { describe, expect, test } from 'vitest';

import type { BridgeViewerProductOnlyJourneyFailureCheckpoint } from './product-only-real-router-contract.ts';
import { BridgeViewerProductOnlyJourneyFailure } from './product-only-real-router-failure.ts';

describe('Bridge Viewer product-only journey failure diagnostics', () => {
	test('includes unresolved waiters with their generation, browser diagnostics and failed-response count in the thrown message', () => {
		const checkpoint = {
			browserCleanup: {
				browserConnectedAfterClose: false,
				closedWorkerCount: 0,
				observedWorkerCount: 0,
				pageClosed: true,
			},
			browserDiagnostics: [
				{
					columnNumber: null,
					lineNumber: null,
					path: null,
					text: 'ReferenceError: startup failed',
					type: 'error',
				},
			],
			captureStatus: 'unavailable',
			documentGeneration: 1,
			failedResponses: [
				{
					documentGeneration: 1,
					method: 'GET',
					path: '/src/app.tsx',
					resourceType: 'script',
					status: 500,
				},
			],
			failureCode: 'UNCLASSIFIED_JOURNEY_FAILURE',
			review: null,
			transport: {
				entries: [],
				unfinishedRequestOrdinals: [],
				unresolvedWaiters: [
					{ documentGeneration: 2, name: 'subscription-receipt' },
					{ documentGeneration: 2, name: 'product-response-quiescence' },
				],
			},
			workers: [],
		} satisfies BridgeViewerProductOnlyJourneyFailureCheckpoint;

		const failure = new BridgeViewerProductOnlyJourneyFailure({
			cause: new Error('review shell unavailable'),
			checkpoint,
		});

		expect(failure.message).toContain(
			'browserDiagnostics=error:page:ReferenceError: startup failed',
		);
		expect(failure.message).toContain('failedResponses=1');
		expect(failure.message).toContain(
			'unresolved=subscription-receipt:g2,product-response-quiescence:g2 unsettled=none',
		);
	});
});
