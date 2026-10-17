import { describe, expect, test } from 'vitest';

import { registerTestBridgeCommWorkerRuntimePortProtocol as registerBridgeCommWorkerRuntimePortProtocol } from './bridge-comm-worker-runtime-protocol.fixture.test-support.js';
import {
	createRecordingBridgeCommWorkerPort,
	flushBridgeWorkerRuntimeContinuations,
} from './bridge-comm-worker-runtime-protocol.test-support.js';
import type { BridgeProductControlCommand } from './bridge-product-control-contracts.js';

describe('Bridge comm worker File refresh retry', () => {
	test('settles only after the typed product control succeeds', async () => {
		// Arrange
		const sentCommands: BridgeProductControlCommand[] = [];
		const { dispatch, postedMessages } = createRecordingBridgeCommWorkerPort();
		registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: {
				className: 'interactive',
				maxBytes: 512 * 1024,
				maxWindowLines: 50,
			},
			sendProductControl: async (command): Promise<void> => {
				sentCommands.push(command);
			},
		});

		// Act
		dispatch.message({
			command: 'fileRefreshRetry',
			direction: 'mainToServerWorker',
			epoch: 4,
			issuedAtMilliseconds: 1_775_000_000_000,
			kind: 'command',
			requestId: 'file-refresh-retry-1',
			transferDescriptors: [],
			wireVersion: 1,
		});
		await flushBridgeWorkerRuntimeContinuations();

		// Assert
		expect(sentCommands).toEqual([{ method: 'file.refresh.retry', params: {} }]);
		expect(postedMessages.map(({ message }) => message)).toContainEqual(
			expect.objectContaining({
				kind: 'health',
				requestId: 'file-refresh-retry-1',
				status: 'ready',
			}),
		);
	});
});
