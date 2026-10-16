import { describe, expect, test } from 'vitest';

import { BridgeCommWorkerProductController } from './bridge-comm-worker-product-controller.js';
import type { BridgeProductControlCommand } from './bridge-product-control-contracts.js';
import type { BridgeProductTransportSession } from './bridge-product-transport.js';
import { createTestMetadataReopenPort } from './bridge-product-view-reopen.test-support.js';

describe('Bridge comm worker product command sender', () => {
	test('maps permanent commands to closed surface-derived product calls', async () => {
		// Arrange
		const calls: unknown[] = [];
		const productTransport = {
			...createTestMetadataReopenPort(),
			advanceWorkerDerivationEpoch: (): number => 1,
			call: async (...arguments_): Promise<null> => {
				calls.push(arguments_);
				return null;
			},
			openContent: (): never => {
				throw new Error('Unexpected content open.');
			},
			subscribe: (): never => {
				throw new Error('Unexpected subscription open.');
			},
			workerDerivationEpoch: (): number => 1,
		} satisfies BridgeProductTransportSession;
		const controller = new BridgeCommWorkerProductController({
			callCurrentFileSource: async () => ({
				reason: 'no-file-source-authority',
				status: 'unavailable',
			}),
			productTransport,
		});

		// Act
		await controller.sendProductControl({
			method: 'review.markFileViewed',
			params: { fileId: 'item-1' },
		});
		await controller.sendProductControl({
			method: 'review.comparison.update',
			params: {
				target: { basis: 'commonCommit', kind: 'localDefaultBranch', branchName: 'main' },
			},
		});
		await controller.sendProductControl({
			method: 'bridge.intakeReady',
			params: {
				protocolId: 'review',
				reason: 'sequence_gap',
				streamId: 'review-stream',
			},
		});
		await controller.sendProductControl({
			method: 'review.publication.install.admit',
			params: {
				candidatePublicationId: '00000000-0000-7000-8000-000000000012',
				expectedDisplayedPublicationId: '00000000-0000-7000-8000-000000000011',
			},
		});
		await controller.sendProductControl({
			method: 'review.publication.applied',
			params: { publicationId: '00000000-0000-7000-8000-000000000012' },
		});
		await controller.sendProductControl(activeModeCommand('review'));
		await controller.sendProductControl(activeModeCommand('file'));

		// Assert
		expect(calls).toEqual([
			['review.markFileViewed', { itemId: 'item-1' }],
			[
				'review.comparison.update',
				{ target: { basis: 'commonCommit', kind: 'localDefaultBranch', branchName: 'main' } },
			],
			['review.intake.ready', { reason: 'sequence_gap', streamId: 'review-stream' }],
			[
				'review.publication.install.admit',
				{
					candidatePublicationId: '00000000-0000-7000-8000-000000000012',
					expectedDisplayedPublicationId: '00000000-0000-7000-8000-000000000011',
				},
			],
			['review.publication.applied', { publicationId: '00000000-0000-7000-8000-000000000012' }],
			[
				'review.activeViewerMode.update',
				{
					activeSource: { generation: 3, streamId: 'review-stream' },
					nativeSelectionRequestId: 'native-selection-review',
					sequence: 9,
					sessionId: 'viewer-session',
				},
			],
			[
				'file.activeViewerMode.update',
				{
					activeSource: { generation: 3, streamId: 'file-stream' },
					nativeSelectionRequestId: 'native-selection-file',
					sequence: 9,
					sessionId: 'viewer-session',
				},
			],
		]);
	});

	test('rejects a cross-surface active source before product admission', async () => {
		// Arrange
		const calls: unknown[] = [];
		const productTransport = {
			...createTestMetadataReopenPort(),
			advanceWorkerDerivationEpoch: (): number => 1,
			call: async (...arguments_): Promise<null> => {
				calls.push(arguments_);
				return null;
			},
			openContent: (): never => {
				throw new Error('Unexpected content open.');
			},
			subscribe: (): never => {
				throw new Error('Unexpected subscription open.');
			},
			workerDerivationEpoch: (): number => 1,
		} satisfies BridgeProductTransportSession;
		const controller = new BridgeCommWorkerProductController({
			productTransport,
		});

		// Act / Assert
		await expect(
			controller.sendProductControl({
				...activeModeCommand('review'),
				params: {
					...activeModeCommand('review').params,
					activeSource: { generation: 3, protocol: 'worktree-file', streamId: 'wrong' },
				},
			}),
		).rejects.toThrow(/does not match.*surface/iu);
		expect(calls).toEqual([]);
	});
});

function activeModeCommand(
	mode: 'file' | 'review',
): Extract<BridgeProductControlCommand, { readonly method: 'bridge.activeViewerMode.update' }> {
	return {
		method: 'bridge.activeViewerMode.update',
		params: {
			activeSource: {
				generation: 3,
				protocol: mode === 'review' ? 'review' : 'worktree-file',
				streamId: mode === 'review' ? 'review-stream' : 'file-stream',
			},
			mode,
			nativeSelectionRequestId: `native-selection-${mode}`,
			sequence: 9,
			sessionId: 'viewer-session',
		},
	};
}
