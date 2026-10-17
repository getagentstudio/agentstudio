import { describe, expect, test } from 'vitest';

import { BridgeCommWorkerProductController } from './bridge-comm-worker-product-controller.js';
import {
	BridgeProductBoundedAsyncQueue,
	createBridgeProductDeferred,
} from './bridge-product-async-queue.js';
import type { BridgeProductControlCommand } from './bridge-product-control-contracts.js';
import type { BridgeProductTransportSession } from './bridge-product-transport.js';
import { createTestMetadataReopenPort } from './bridge-product-view-reopen.test-support.js';

describe('Bridge comm worker product controller active viewer mode', () => {
	test('does not start metadata for an older mode that completes after a newer mode', async () => {
		// Arrange
		const fileAdmission = createBridgeProductDeferred<unknown>();
		const reviewAdmission = createBridgeProductDeferred<unknown>();
		const admittedModes: Array<'file' | 'review'> = [];
		let fileDiscoveryCount = 0;
		let reviewSubscriptionCount = 0;
		const controller = new BridgeCommWorkerProductController({
			callCurrentFileSource: async () => {
				fileDiscoveryCount += 1;
				return { source: currentFileSourceConfiguration, status: 'available' };
			},
			onActiveViewerModeAdmitted: (mode): void => {
				admittedModes.push(mode);
			},
			productTransport: activeModeTransport(fileAdmission.promise, reviewAdmission.promise),
			subscribeFile: () => ({
				cancel: async (): Promise<void> => {},
				events: new BridgeProductBoundedAsyncQueue(1),
				subscriptionId: 'late-file-mode-subscription',
				subscriptionKind: 'file.metadata',
			}),
			subscribeReview: () => {
				reviewSubscriptionCount += 1;
				return {
					cancel: async (): Promise<void> => {},
					events: new BridgeProductBoundedAsyncQueue(1),
					subscriptionId: 'current-review-mode-subscription',
					subscriptionKind: 'review.metadata',
				};
			},
		});
		const fileControl = controller.sendProductControl(activeModeCommand('file', 1));
		const reviewControl = controller.sendProductControl(activeModeCommand('review', 2));

		// Act
		reviewAdmission.resolve(null);
		await reviewControl;
		fileAdmission.resolve(null);
		await fileControl;

		// Assert
		expect(admittedModes).toEqual(['review']);
		expect(reviewSubscriptionCount).toBe(1);
		expect(fileDiscoveryCount).toBe(0);
	});

	test('opens hidden Review metadata after its accepted mode control is superseded by File', async () => {
		const fileAdmission = createBridgeProductDeferred<unknown>();
		const reviewAdmission = createBridgeProductDeferred<unknown>();
		const admittedModes: Array<'file' | 'review'> = [];
		let reviewSubscriptionCount = 0;
		const controller = new BridgeCommWorkerProductController({
			callCurrentFileSource: async () => ({
				source: currentFileSourceConfiguration,
				status: 'available',
			}),
			onActiveViewerModeAdmitted: (mode): void => {
				admittedModes.push(mode);
			},
			productTransport: activeModeTransport(fileAdmission.promise, reviewAdmission.promise),
			subscribeFile: () => ({
				cancel: async (): Promise<void> => {},
				events: new BridgeProductBoundedAsyncQueue(1),
				subscriptionId: 'current-file-mode-subscription',
				subscriptionKind: 'file.metadata',
			}),
			subscribeReview: () => {
				reviewSubscriptionCount += 1;
				return {
					cancel: async (): Promise<void> => {},
					events: new BridgeProductBoundedAsyncQueue(1),
					subscriptionId: 'hidden-review-subscription',
					subscriptionKind: 'review.metadata',
				};
			},
		});
		const reviewControl = controller.sendProductControl(activeModeCommand('review', 1));
		const fileControl = controller.sendProductControl(activeModeCommand('file', 2));

		fileAdmission.resolve(null);
		await fileControl;
		reviewAdmission.resolve(null);
		await reviewControl;

		expect(admittedModes).toEqual(['file']);
		expect(reviewSubscriptionCount).toBe(1);
	});
});

function activeModeCommand(mode: 'file' | 'review', sequence: number): BridgeProductControlCommand {
	return {
		method: 'bridge.activeViewerMode.update' as const,
		params: {
			activeSource: null,
			mode,
			nativeSelectionRequestId: null,
			sequence,
			sessionId: 'viewer-mode-session',
		},
	};
}

function activeModeTransport(
	fileAdmission: Promise<unknown>,
	reviewAdmission: Promise<unknown>,
): BridgeProductTransportSession {
	return {
		...createTestMetadataReopenPort(),
		advanceWorkerDerivationEpoch: (): number => 0,
		call: (...arguments_): Promise<never> => {
			const [method] = arguments_;
			if (method === 'file.activeViewerMode.update') return fileAdmission as Promise<never>;
			if (method === 'review.activeViewerMode.update') return reviewAdmission as Promise<never>;
			throw new Error(`Unexpected product call: ${method}.`);
		},
		openContent: (): never => {
			throw new Error('Unexpected content request.');
		},
		subscribe: (): never => {
			throw new Error('Unexpected direct subscription.');
		},
		workerDerivationEpoch: (): number => 0,
	};
}

const currentFileSourceConfiguration = {
	cwdScope: null,
	freshness: 'live',
	includeStatuses: true,
	repoId: '00000000-0000-4000-8000-000000000001',
	rootPathToken: 'root-token-1',
	worktreeId: '00000000-0000-4000-8000-000000000002',
} as const;
