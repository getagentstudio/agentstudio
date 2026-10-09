import { describe, expect, test, vi } from 'vitest';

import { encodeBridgeWorkerViewRecoveryRetryCommand } from './bridge-comm-worker-protocol.js';
import { registerBridgeCommWorkerRuntimePortProtocol } from './bridge-comm-worker-runtime-protocol.js';
import {
	activateBridgeCommWorkerFileViewerMode,
	activateBridgeCommWorkerReviewViewerMode,
	createRecordingBridgeCommWorkerPort,
} from './bridge-comm-worker-runtime-protocol.test-support.js';
import { createBridgeMainRenderSnapshotStore } from './bridge-main-render-snapshot-store.js';
import { createBridgeProductDeferred } from './bridge-product-async-queue.js';
import { bridgeProductMetadataApplicationRegistry } from './bridge-product-metadata-application-registry.js';
import { BridgeProductControlMux } from './bridge-product-session-authority.js';
import { productSessionBootstrap } from './bridge-product-session-authority.test-support.js';
import { createBridgeProductTransport } from './bridge-product-transport.js';
import type { BridgeWorkerViewRecoveryStatusEvent } from './bridge-worker-view-recovery-contracts.js';
import {
	metadataAccepted,
	subscriptionAccepted,
	TestProductServer,
} from './test-fixtures/bridge-product-transport-metadata.test-support.js';

describe('First metadata opening through real transport and surface Retry composition', () => {
	test.each([
		{ surface: 'file', outcome: 'failed' },
		{ surface: 'review', outcome: 'failed' },
		{ surface: 'file', outcome: 'healthy' },
		{ surface: 'review', outcome: 'healthy' },
	] as const)(
		'$surface first-ever $outcome opening preserves initial UI status and actionable failure Retry',
		async ({ surface, outcome }) => {
			const server = new TestProductServer();
			const firstStreamReply = createBridgeProductDeferred<Response>();
			const firstStreamStarted = createBridgeProductDeferred<void>();
			let streamAttemptCount = 0;
			let initialStreamInit: RequestInit | null = null;
			const authority = {
				bootstrap: productSessionBootstrap(),
				capabilityHeader: 'private-capability',
				open: Promise.resolve(),
			};
			const deadlineClock = { schedule: (): (() => void) => (): void => {} };
			const executeProductRequest = (
				route: 'command' | 'content' | 'stream',
				init: RequestInit,
			): Promise<Response> => {
				if (route === 'stream' && ++streamAttemptCount === 1) {
					initialStreamInit = init;
					firstStreamStarted.resolve();
					return firstStreamReply.promise;
				}
				return server.fetch(`agentstudio://rpc/${route}`, init);
			};
			const statuses: Array<Pick<BridgeWorkerViewRecoveryStatusEvent, 'status' | 'view'>> = [];
			const renderStore = createBridgeMainRenderSnapshotStore();
			const transport = createBridgeProductTransport({
				authority,
				deadlineClock,
				executeProductRequest,
				controlMux: new BridgeProductControlMux({
					authority,
					deadlineClock,
					executeProductRequest,
				}),
				metadataApplicationRegistry: bridgeProductMetadataApplicationRegistry,
				onViewRecoveryStatus: (status): void => {
					statuses.push(status);
					renderStore.applyViewRecoveryStatusEvent({
						...status,
						direction: 'serverWorkerToMain',
						kind: 'viewRecoveryStatus',
						transferDescriptors: [],
						wireVersion: 1,
					});
				},
			});
			const subscriptions = vi.spyOn(transport, 'subscribe');
			const { dispatch, waitForMessage } = createRecordingBridgeCommWorkerPort();
			registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
				bridgeDemandRank: { lane: 'selected', priority: 0 },
				budget: { className: 'interactive', maxBytes: 524_288, maxWindowLines: 400 },
				productTransport: transport,
			});
			try {
				await firstStreamStarted.promise;
				if (surface === 'file') activateBridgeCommWorkerFileViewerMode(dispatch, 'initial-failure');
				else activateBridgeCommWorkerReviewViewerMode(dispatch, 'initial-failure');
				await waitForMessage(
					(message) =>
						message.kind === 'health' &&
						message.requestId === `request-${surface}-mode-initial-failure`,
				);
				const initial = subscriptions.mock.results.find(
					(result, index) =>
						result.type === 'return' &&
						subscriptions.mock.calls[index]?.[0].kind === `${surface}.metadata`,
				);
				if (initial?.type !== 'return')
					throw new Error('Expected the first surface E3 before its stream reply.');
				const initialId = initial.value.subscriptionId;
				if (outcome === 'healthy') {
					// Initial loading has no recovery warning/status before W2 registration.
					expect(renderStore.getViewRecoveryStatus(`${surface}.metadata`)).toBeNull();
					if (initialStreamInit === null) throw new Error('Expected initial stream request.');
					firstStreamReply.resolve(
						await server.fetch('agentstudio://rpc/stream', initialStreamInit),
					);
					const stream = await server.waitForMetadataStreamOpened();
					server.emitMetadata(metadataAccepted(stream, 0));
					const healthyOpen = await server.waitForControlRequestWhere(
						(request) =>
							request.kind === 'subscription.open' && request.subscriptionId === initialId,
					);
					if (healthyOpen.kind !== 'subscription.open')
						throw new Error('Expected initial surface open.');
					server.emitMetadata(
						subscriptionAccepted({
							epoch: healthyOpen.workerDerivationEpoch,
							kind: surface === 'file' ? 'file.metadata' : 'review.metadata',
							request: stream,
							streamSequence: 1,
							subscriptionId: initialId,
						}),
					);
					await server.waitForControlRequestWhere(
						(request) =>
							request.kind === 'subscription.setScope' && request.subscriptionId === initialId,
					);
					expect(renderStore.getViewRecoveryStatus(`${surface}.metadata`)).toEqual({
						status: 'recovering',
						view: { kind: `${surface}.metadata`, subscriptionId: initialId },
					});
					expect(statuses.filter((status) => status.view.kind === `${surface}.metadata`)).toEqual([
						{
							status: 'recovering',
							view: { kind: `${surface}.metadata`, subscriptionId: initialId },
						},
					]);
					return;
				}
				firstStreamReply.reject(new Error('first-ever metadata stream request refused'));
				await waitForMessage((message) =>
					surface === 'review'
						? message.kind === 'reviewDisplayPatch' &&
							message.patches.some(
								(patch) => patch.slice === 'reviewSource' && patch.operation === 'failed',
							)
						: message.kind === 'health' &&
							message.message === 'Bridge File metadata subscription failed.',
				);
				const failed = statuses.findLast((status) => status.view.kind === `${surface}.metadata`);
				expect(failed).toMatchObject({
					status: 'failedRetryable',
					view: { subscriptionId: initialId },
				});
				if (failed === undefined) throw new Error('First E3 has no usable Retry identity.');
				dispatch.message(
					encodeBridgeWorkerViewRecoveryRetryCommand({
						epoch: 2,
						requestId: 'retry-first-metadata-open',
						view: failed.view,
					}),
				);
				const freshStream = await server.waitForMetadataStreamOpened();
				server.emitMetadata(metadataAccepted(freshStream, 0));
				const freshOpen = await server.waitForControlRequestWhere(
					(request) =>
						request.kind === 'subscription.open' &&
						request.subscription.subscriptionKind === `${surface}.metadata` &&
						request.subscriptionId !== initialId,
				);
				if (freshOpen.kind !== 'subscription.open')
					throw new Error('Expected fresh surface subscription admission.');
				server.emitMetadata(
					subscriptionAccepted({
						epoch: freshOpen.workerDerivationEpoch,
						kind: surface === 'file' ? 'file.metadata' : 'review.metadata',
						request: freshStream,
						streamSequence: 1,
						subscriptionId: freshOpen.subscriptionId,
					}),
				);
				await server.waitForControlRequestWhere(
					(request) =>
						request.kind === 'subscription.setScope' &&
						request.subscriptionId === freshOpen.subscriptionId,
				);
				expect(
					statuses.findLast((status) => status.view.kind === `${surface}.metadata`),
				).toMatchObject({
					status: 'recovering',
					view: { subscriptionId: freshOpen.subscriptionId },
				});
				expect(freshOpen.subscriptionId).not.toBe(initialId);
			} finally {
				renderStore.dispose();
				firstStreamReply.reject(new Error('test cleanup'));
				server.shutdown();
				await Promise.allSettled(
					subscriptions.mock.results.flatMap((result) =>
						result.type === 'return' ? [result.value.cancel()] : [],
					),
				);
			}
		},
	);
});
