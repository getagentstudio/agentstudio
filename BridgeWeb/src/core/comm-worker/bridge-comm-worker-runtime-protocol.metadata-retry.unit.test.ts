import { describe, expect, test, vi } from 'vitest';

import {
	encodeBridgeWorkerViewRecoveryRetryCommand,
	encodeBridgeWorkerActiveViewerModeUpdateCommand,
} from './bridge-comm-worker-protocol.js';
import { registerBridgeCommWorkerRuntimePortProtocol } from './bridge-comm-worker-runtime-protocol.js';
import {
	makeReviewProductTransport,
	type ReviewMetadataSubscription,
} from './bridge-comm-worker-runtime-protocol.review-product-transport.test-support.js';
import {
	activateBridgeCommWorkerFileViewerMode,
	activateBridgeCommWorkerReviewViewerMode,
	createRecordingBridgeCommWorkerPort,
	type FileMetadataSubscription,
} from './bridge-comm-worker-runtime-protocol.test-support.js';
import {
	BridgeProductBoundedAsyncQueue,
	createBridgeProductDeferred,
} from './bridge-product-async-queue.js';
import { makeFileProductTestTransport } from './comm-runtime-protocol.file-product.test-support.js';

describe('Bridge runtime surface metadata Retry', () => {
	test.each(['file', 'review'] as const)(
		'%s Comment Retry restores the source join and reopens the notification E3',
		async (surface) => {
			const sourceEvents = new BridgeProductBoundedAsyncQueue<never>(1);
			const annotationEvents = new BridgeProductBoundedAsyncQueue<never>(1);
			let annotationOpenCount = 0;
			const annotationReopened = createBridgeProductDeferred<void>();
			const { dispatch, waitForMessage } = createRecordingBridgeCommWorkerPort();
			const transport =
				surface === 'file'
					? makeFileProductTestTransport({
							onDiscoverSource: (): void => {},
							onOpenDescriptor: (): void => {},
							subscription: {
								events: sourceEvents,
								subscriptionId: 'file-comment-source',
								subscriptionKind: 'file.metadata',
								cancel: async (): Promise<void> => sourceEvents.close(true),
							},
						})
					: makeReviewProductTransport({
							reviewSubscription: {
								events: sourceEvents,
								subscriptionId: 'review-comment-source',
								subscriptionKind: 'review.metadata',
								cancel: async (): Promise<void> => sourceEvents.close(true),
							},
							subscribedKinds: [],
						});
			const originalSubscribe = transport.subscribe.bind(transport);
			transport.subscribe = (protocol, options): never => {
				if (protocol.kind === `${surface}.annotations`) {
					annotationOpenCount += 1;
					if (annotationOpenCount === 1) throw new Error('initial Comment E3 unavailable');
					annotationReopened.resolve();
					// oxlint-disable-next-line typescript/no-unsafe-type-assertion -- The protocol-narrowed external fixture returns that exact Comment lifecycle.
					return {
						events: annotationEvents,
						subscriptionId: `${surface}-comment-retry`,
						subscriptionKind: protocol.kind,
						cancel: async (): Promise<void> => annotationEvents.close(true),
					} as never;
				}
				// oxlint-disable-next-line typescript/no-unsafe-type-assertion -- Preserve the generic external fixture's exact subscription result.
				return originalSubscribe(protocol, options) as never;
			};
			const retryView = vi.fn(async (): Promise<void> => {});
			transport.retryView = retryView;
			const subscriptions = vi.spyOn(transport, 'subscribe');
			registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
				bridgeDemandRank: { lane: 'selected', priority: 0 },
				budget: { className: 'interactive', maxBytes: 524_288, maxWindowLines: 400 },
				productTransport: transport,
			});
			try {
				dispatch.message(
					encodeBridgeWorkerActiveViewerModeUpdateCommand({
						epoch: 1,
						requestId: `request-${surface}-mode-comment-retry`,
						update: {
							activeSource:
								surface === 'file'
									? { protocol: 'worktree-file', generation: 3, streamId: 'file-comment-source' }
									: null,
							mode: surface,
							nativeSelectionRequestId: null,
							sequence: 1,
							sessionId: `${surface}-comment-session`,
						},
					}),
				);
				await waitForMessage(
					(message) =>
						message.kind === 'health' &&
						message.requestId === `request-${surface}-mode-comment-retry`,
				);
				dispatch.message(
					encodeBridgeWorkerViewRecoveryRetryCommand({
						epoch: 2,
						requestId: `${surface}-comment-retry-command`,
						view: {
							kind: surface === 'file' ? 'file.annotations' : 'review.annotations',
							subscriptionId: 'retired-comment-e3',
						},
					}),
				);
				await waitForMessage(
					(message) =>
						message.kind === 'health' && message.requestId === `${surface}-comment-retry-command`,
				);
				expect(retryView).toHaveBeenCalledWith('retired-comment-e3');
				await annotationReopened.promise;
				expect(
					subscriptions.mock.calls.some(([protocol]) => protocol.kind === `${surface}.metadata`),
				).toBe(true);
				expect(annotationOpenCount).toBe(2);
			} finally {
				await Promise.all(
					subscriptions.mock.results.map(async (result): Promise<void> => {
						if (result.type === 'return') await result.value.cancel();
					}),
				);
				sourceEvents.close(true);
				annotationEvents.close(true);
			}
		},
	);

	test.each([false, true])(
		'Review Retry reopens only a retired E3 (retired: %s)',
		async (retired) => {
			const events = [
				new BridgeProductBoundedAsyncQueue<never>(1),
				new BridgeProductBoundedAsyncQueue<never>(1),
			];
			let subscriptionCount = 0;
			const { dispatch, waitForMessage } = createRecordingBridgeCommWorkerPort();
			const transport = makeReviewProductTransport({
				get reviewSubscription(): ReviewMetadataSubscription {
					const queue = events[subscriptionCount++];
					if (queue === undefined) throw new Error('Unexpected Review reopen.');
					return {
						cancel: async (): Promise<void> => queue.close(true),
						events: queue,
						subscriptionId: `review-retry-${subscriptionCount}`,
						subscriptionKind: 'review.metadata',
					};
				},
				subscribedKinds: [],
			});
			const retryView = vi.fn(async (): Promise<void> => {});
			transport.retryView = retryView;
			const subscriptions = vi.spyOn(transport, 'subscribe');
			registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
				bridgeDemandRank: { lane: 'selected', priority: 0 },
				budget: { className: 'interactive', maxBytes: 524_288, maxWindowLines: 400 },
				productTransport: transport,
			});
			try {
				activateBridgeCommWorkerReviewViewerMode(dispatch, 'metadata-retry');
				await waitForMessage(
					(message) =>
						message.kind === 'health' && message.requestId === 'request-review-mode-metadata-retry',
				);
				expect(subscriptionCount).toBe(1);
				if (retired) {
					events[0]?.fail(new Error('physical metadata recovery exhausted'), true);
					await waitForMessage(
						(message) =>
							message.kind === 'reviewDisplayPatch' &&
							message.patches.some(
								(patch) => patch.slice === 'reviewSource' && patch.operation === 'failed',
							),
					);
				}
				dispatch.message(
					encodeBridgeWorkerViewRecoveryRetryCommand({
						epoch: 2,
						requestId: 'review-retry-command',
						view: { kind: 'review.metadata', subscriptionId: 'review-retry-1' },
					}),
				);
				await waitForMessage(
					(message) => message.kind === 'health' && message.requestId === 'review-retry-command',
				);
				expect(subscriptionCount).toBe(retired ? 2 : 1);
				expect(retryView).toHaveBeenCalledWith('review-retry-1');
			} finally {
				await Promise.all(
					subscriptions.mock.results.map(async (result): Promise<void> => {
						if (result.type === 'return') await result.value.cancel();
					}),
				);
				for (const queue of events) queue.close(true);
			}
		},
	);

	test.each([false, true])(
		'File Retry restores source and reopens only a retired E3 (retired: %s)',
		async (retired) => {
			const events = [
				new BridgeProductBoundedAsyncQueue<never>(1),
				new BridgeProductBoundedAsyncQueue<never>(1),
			];
			let subscriptionCount = 0;
			let discoveryCount = 0;
			const initialOpened = createBridgeProductDeferred<void>();
			const replacementOpened = createBridgeProductDeferred<void>();
			const { dispatch, waitForMessage } = createRecordingBridgeCommWorkerPort();
			const transport = makeFileProductTestTransport({
				onDiscoverSource: (): void => {
					discoveryCount += 1;
				},
				onOpenDescriptor: (): void => {},
				get subscription(): FileMetadataSubscription {
					const queue = events[subscriptionCount++];
					if (queue === undefined) throw new Error('Unexpected File reopen.');
					initialOpened.resolve();
					if (subscriptionCount === 2) replacementOpened.resolve();
					return {
						cancel: async (): Promise<void> => queue.close(true),
						events: queue,
						subscriptionId: `file-retry-${subscriptionCount}`,
						subscriptionKind: 'file.metadata',
					};
				},
			});
			const retryView = vi.fn(async (): Promise<void> => {});
			transport.retryView = retryView;
			const subscriptions = vi.spyOn(transport, 'subscribe');
			registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
				bridgeDemandRank: { lane: 'selected', priority: 0 },
				budget: { className: 'interactive', maxBytes: 524_288, maxWindowLines: 400 },
				productTransport: transport,
			});
			try {
				activateBridgeCommWorkerFileViewerMode(dispatch, 'metadata-retry');
				await initialOpened.promise;
				if (retired) {
					events[0]?.fail(new Error('physical metadata recovery exhausted'), true);
					await waitForMessage(
						(message) =>
							message.kind === 'fileDisplayPatch' &&
							message.patches.some(
								(patch) =>
									patch.slice === 'fileStatus' &&
									patch.operation === 'upsert' &&
									patch.payload.state === 'failed',
							),
					);
				}
				dispatch.message(
					encodeBridgeWorkerViewRecoveryRetryCommand({
						epoch: 2,
						requestId: 'file-retry-command',
						view: { kind: 'file.metadata', subscriptionId: 'file-retry-1' },
					}),
				);
				await waitForMessage(
					(message) => message.kind === 'health' && message.requestId === 'file-retry-command',
				);
				expect(discoveryCount).toBe(retired ? 2 : 1);
				if (retired) {
					await replacementOpened.promise;
				}
				expect(subscriptionCount).toBe(retired ? 2 : 1);
				expect(retryView).toHaveBeenCalledWith('file-retry-1');
			} finally {
				await Promise.all(
					subscriptions.mock.results.map(async (result): Promise<void> => {
						if (result.type === 'return') await result.value.cancel();
					}),
				);
				for (const queue of events) queue.close(true);
			}
		},
	);
});
