import { describe, expect, test } from 'vitest';

import {
	encodeBridgeWorkerReviewComparisonTargetsQueryCancelCommand,
	encodeBridgeWorkerReviewComparisonTargetsQueryCommand,
} from './bridge-comm-worker-protocol.js';
import { registerBridgeCommWorkerRuntimePortProtocol } from './bridge-comm-worker-runtime-protocol.js';
import {
	createRecordingBridgeCommWorkerPort,
	flushBridgeWorkerRuntimeContinuations,
} from './bridge-comm-worker-runtime-protocol.test-support.js';

describe('Bridge comm worker comparison-target query runtime', () => {
	test('settles a rejected comparison-target query as failed for its request', async () => {
		// Arrange
		const { dispatch, postedMessages } = createRecordingBridgeCommWorkerPort();
		registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: { className: 'interactive', maxBytes: 512 * 1024, maxWindowLines: 50 },
			sendProductControl: async (command): Promise<void> => {
				if (command.method === 'review.comparisonTargets.query') throw new Error('query rejected');
			},
		});

		// Act
		dispatch.message(
			encodeBridgeWorkerReviewComparisonTargetsQueryCommand({
				epoch: 1,
				requestId: 'request-comparison-targets-rejected',
			}),
		);
		await flushBridgeWorkerRuntimeContinuations();

		// Assert
		expect(postedMessages.map(({ message }) => message)).toContainEqual(
			expect.objectContaining({
				kind: 'reviewComparisonTargetsQuery',
				requestId: 'request-comparison-targets-rejected',
				status: 'failed',
			}),
		);
	});

	test('cancels an active comparison-target query without publishing its late result', async () => {
		// Arrange
		const { dispatch, postedMessages } = createRecordingBridgeCommWorkerPort();
		let resolveQuery!: (result: unknown) => void;
		const queryResult = new Promise<unknown>((resolve): void => {
			resolveQuery = resolve;
		});
		registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: { className: 'interactive', maxBytes: 512 * 1024, maxWindowLines: 50 },
			sendProductControl: async (command): Promise<unknown> =>
				command.method === 'review.comparisonTargets.query' ? queryResult : null,
		});

		// Act
		dispatch.message(
			encodeBridgeWorkerReviewComparisonTargetsQueryCommand({
				epoch: 1,
				requestId: 'request-comparison-targets-query',
			}),
		);
		await flushBridgeWorkerRuntimeContinuations();
		dispatch.message(
			encodeBridgeWorkerReviewComparisonTargetsQueryCancelCommand({
				epoch: 2,
				queryRequestId: 'request-comparison-targets-query',
				requestId: 'request-comparison-targets-cancel',
			}),
		);
		resolveQuery({ descriptor: null });
		await flushBridgeWorkerRuntimeContinuations();

		// Assert
		expect(postedMessages.map(({ message }) => message)).toContainEqual(
			expect.objectContaining({
				kind: 'health',
				requestId: 'request-comparison-targets-cancel',
				status: 'ready',
			}),
		);
		expect(postedMessages.map(({ message }) => message)).not.toContainEqual(
			expect.objectContaining({
				kind: 'reviewComparisonTargetsQuery',
				requestId: 'request-comparison-targets-query',
			}),
		);
	});
});
