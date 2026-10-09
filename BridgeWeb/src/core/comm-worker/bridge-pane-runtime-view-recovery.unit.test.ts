import { afterEach, beforeEach, describe, expect, test, vi } from 'vitest';

import type { BridgePaneCommWorkerDispatcher } from './bridge-pane-comm-worker-session.js';
import type { BridgePaneSessionPort } from './bridge-pane-runtime.js';
import type { BridgeWorkerServerToMainMessage } from './bridge-worker-contracts.js';

describe('Bridge pane runtime view recovery', () => {
	beforeEach((): void => {
		vi.stubGlobal('cancelAnimationFrame', vi.fn());
		vi.stubGlobal(
			'requestAnimationFrame',
			vi.fn((): number => 1),
		);
	});

	afterEach((): void => {
		vi.unstubAllGlobals();
	});

	test('routes recovery status into only the matching per-surface view state', async () => {
		const { createBridgePaneRuntime } = await loadBridgePaneRuntimeModule();
		let publishWorkerMessages:
			| ((messages: readonly BridgeWorkerServerToMainMessage[]) => void)
			| undefined;
		const session: BridgePaneSessionPort = {
			createDispatcher: (dispatcherProps): BridgePaneCommWorkerDispatcher => {
				publishWorkerMessages = dispatcherProps.publishWorkerMessages;
				return { dispatch: (): void => {}, dispose: (): void => {} };
			},
			dispose: (): void => {},
			installNativeBootstrap: (): void => {},
		};
		const runtime = createBridgePaneRuntime({
			sessionFactory: (): BridgePaneSessionPort => session,
		});
		try {
			const fileClient = runtime.surfaceClient('fileView');
			const reviewClient = runtime.surfaceClient('review');
			const fileMessages: BridgeWorkerServerToMainMessage[] = [];
			const reviewMessages: BridgeWorkerServerToMainMessage[] = [];
			fileClient.subscribeMessages((message): void => {
				fileMessages.push(message);
			});
			reviewClient.subscribeMessages((message): void => {
				reviewMessages.push(message);
			});

			const fileEvent = {
				wireVersion: 1,
				direction: 'serverWorkerToMain',
				transferDescriptors: [],
				kind: 'viewRecoveryStatus',
				view: { kind: 'file.metadata', subscriptionId: 'file-view-1' },
				status: 'failedRetryable',
			} satisfies BridgeWorkerServerToMainMessage;
			const reviewEvent = {
				...fileEvent,
				view: { kind: 'review.annotations', subscriptionId: 'review-comments-1' },
				status: 'recovering',
			} satisfies BridgeWorkerServerToMainMessage;

			publishWorkerMessages?.([fileEvent, reviewEvent]);

			expect(fileClient.renderStore.getViewRecoveryStatus('file.metadata')).toEqual({
				view: fileEvent.view,
				status: fileEvent.status,
			});
			expect(fileClient.renderStore.getViewRecoveryStatus('review.annotations')).toBeNull();
			expect(reviewClient.renderStore.getViewRecoveryStatus('review.annotations')).toEqual({
				view: reviewEvent.view,
				status: reviewEvent.status,
			});
			expect(fileMessages).toEqual([fileEvent]);
			expect(reviewMessages).toEqual([reviewEvent]);
		} finally {
			runtime.dispose();
		}
	});

	test('worker bootstrap exhaustion fails every recorded view until a successor is ready', async () => {
		const { createBridgePaneRuntime } = await loadBridgePaneRuntimeModule();
		let publishWorkerMessages:
			| ((messages: readonly BridgeWorkerServerToMainMessage[]) => void)
			| undefined;
		let reportExhaustion: (() => void) | undefined;
		const session: BridgePaneSessionPort = {
			createDispatcher: (dispatcherProps): BridgePaneCommWorkerDispatcher => {
				publishWorkerMessages = dispatcherProps.publishWorkerMessages;
				return { dispatch: (): void => {}, dispose: (): void => {} };
			},
			dispose: (): void => {},
			installNativeBootstrap: (): void => {},
			setReplacementBootstrapExhaustionHandler: (callback): void => {
				reportExhaustion = callback;
			},
		};
		const runtime = createBridgePaneRuntime({
			sessionFactory: (): BridgePaneSessionPort => session,
		});
		try {
			const fileStore = runtime.surfaceClient('fileView').renderStore;
			const reviewStore = runtime.surfaceClient('review').renderStore;
			const views = [
				{ kind: 'file.metadata', subscriptionId: 'file-metadata-1' },
				{ kind: 'file.annotations', subscriptionId: 'file-comments-1' },
				{ kind: 'review.metadata', subscriptionId: 'review-metadata-1' },
				{ kind: 'review.annotations', subscriptionId: 'review-comments-1' },
			] as const;
			for (const view of views) {
				publishWorkerMessages?.([
					{
						direction: 'serverWorkerToMain',
						kind: 'viewRecoveryStatus',
						status: 'ready',
						transferDescriptors: [],
						view,
						wireVersion: 1,
					},
				]);
			}
			reportExhaustion?.();
			for (const view of views) {
				const store = view.kind.startsWith('file.') ? fileStore : reviewStore;
				expect(store.getViewRecoveryStatus(view.kind)?.status).toBe('failedRetryable');
			}
			publishWorkerMessages?.([
				{
					direction: 'serverWorkerToMain',
					kind: 'health',
					requestId: 'pane-runtime-bootstrap',
					status: 'ready',
					transferDescriptors: [],
					wireVersion: 1,
				},
			]);
			for (const view of views) {
				const store = view.kind.startsWith('file.') ? fileStore : reviewStore;
				expect(store.getViewRecoveryStatus(view.kind)?.status).toBe('ready');
			}
		} finally {
			runtime.dispose();
		}
	});
});

async function loadBridgePaneRuntimeModule(): Promise<typeof import('./bridge-pane-runtime.js')> {
	return await vi.importActual<typeof import('./bridge-pane-runtime.js')>(
		'./bridge-pane-runtime.js',
	);
}
