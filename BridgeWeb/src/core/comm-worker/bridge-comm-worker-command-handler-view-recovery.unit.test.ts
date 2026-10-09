import { describe, expect, test } from 'vitest';

import { createBridgeCommWorkerCommandHandler } from './bridge-comm-worker-command-handler.js';
import {
	ignoreScheduledSelectedFileViewPreparation,
	ignoreScheduledSelectedReviewPreparation,
} from './bridge-comm-worker-command-handler.test-support.js';
import { encodeBridgeWorkerViewRecoveryRetryCommand } from './bridge-comm-worker-protocol.js';

describe('Bridge comm worker view recovery retry command', () => {
	test('routes a retry to the exact subscription view', () => {
		const retriedViews: Array<{ readonly kind: string; readonly subscriptionId: string }> = [];
		const handler = createBridgeCommWorkerCommandHandler({
			contentItems: [],
			rows: [],
			retryView: (view): void => {
				retriedViews.push(view);
			},
			scheduleSelectedReviewContentReadyPreparation: ignoreScheduledSelectedReviewPreparation,
			scheduleSelectedFileViewContentReadyPreparation: ignoreScheduledSelectedFileViewPreparation,
		});

		const messages = handler.handleMessage(
			encodeBridgeWorkerViewRecoveryRetryCommand({
				requestId: 'retry-file-view-1',
				epoch: 4,
				view: { kind: 'file.metadata', subscriptionId: 'file-view-1' },
			}),
		);

		expect(retriedViews).toEqual([{ kind: 'file.metadata', subscriptionId: 'file-view-1' }]);
		expect(messages).toEqual([
			{
				wireVersion: 1,
				direction: 'serverWorkerToMain',
				transferDescriptors: [],
				kind: 'health',
				requestId: 'retry-file-view-1',
				status: 'ready',
			},
		]);
	});
});
