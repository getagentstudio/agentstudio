// oxlint-disable unicorn/require-post-message-target-origin -- MessagePort messages have no target origin.
import { afterEach, describe, expect, test, vi } from 'vitest';
import { z } from 'zod';

import {
	installBridgePageHandshakeSession,
	type BridgePageHandshakeSession,
} from '../../bridge/bridge-page-handshake.js';
import type { BridgePaneCommWorkerSessionDiagnosticSnapshot } from '../../foundation/diagnostics/bridge-review-selection-diagnostic.js';
import pageConfigurationFixture from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-page-configuration.json' with { type: 'json' };
import { encodeBridgeWorkerViewRecoveryRetryCommand } from './bridge-comm-worker-protocol.js';
import { BridgePaneCommWorkerSession } from './bridge-pane-comm-worker-session.js';
import {
	makeNativeBootstrap,
	makeRuntimeBootstrapRequest,
	makeSelectCommand,
	RecordingPaneCommWorker,
	RecordingPaneCommWorkerClient,
	makeReadyHealth,
} from './bridge-pane-comm-worker-session.test-support.js';
import { createBridgeProductDeferred } from './bridge-product-async-queue.js';

const bootstrapRequestSchema = z
	.object({ reason: z.enum(['initial', 'workerReplacement']), requestId: z.string() })
	.strict();

afterEach(() => {
	vi.useRealTimers();
	vi.unstubAllGlobals();
});

describe('Page bootstrap finite progress through the real handshake and worker session', () => {
	test.each(['exhausted', 'recovered'] as const)(
		'a typed initial failure enters the existing replacement budget (%s)',
		async (outcome) => {
			const target = new EventTarget();
			const requests: z.infer<typeof bootstrapRequestSchema>[] = [];
			const snapshots: BridgePaneCommWorkerSessionDiagnosticSnapshot[] = [];
			const client = new RecordingPaneCommWorkerClient();
			const recoveredPort = createBridgeProductDeferred<MessagePort>();
			const NativeMessageChannel = MessageChannel;
			class RecordingChannel extends NativeMessageChannel {
				constructor() {
					super();
					recoveredPort.resolve(this.port2);
				}
			}
			vi.stubGlobal('MessageChannel', RecordingChannel);
			const session = new BridgePaneCommWorkerSession({
				bootstrapTimeoutMilliseconds: pageConfigurationFixture.workerBootstrapDeadlineMilliseconds,
				workerFactory: (): Worker => new RecordingPaneCommWorker(),
				recordDiagnosticSnapshot: (snapshot): void => {
					snapshots.push(snapshot);
				},
			});
			const dispatcher = session.createDispatcher({
				bootstrapRequest: makeRuntimeBootstrapRequest('initial-failure-budget'),
				publishWorkerMessages: client.publish,
			});
			target.addEventListener('__bridge_product_session_bootstrap_request', (event): void => {
				if (!('detail' in event)) throw new Error('Missing bootstrap request detail.');
				requests.push(bootstrapRequestSchema.parse(event.detail));
			});
			const handshake = installBridgePageHandshakeSession(target, {
				onProductSessionBootstrap: (bootstrap): void => session.installNativeBootstrap(bootstrap),
				onProductSessionBootstrapFailure: (): void => session.handleNativeBootstrapFailure(),
			});
			session.setNativeBootstrapRequester((): void => handshake.requestProductSessionReplacement());
			try {
				dispatcher.dispatch(
					makeSelectCommand('queued-before-first-capability', 1, 'item-1', 'review'),
				);
				const refuseLatestRequest = (): void => {
					const request = requests.at(-1);
					if (request === undefined) throw new Error('Missing admitted request.');
					target.dispatchEvent(
						new CustomEvent('__bridge_product_session_bootstrap', {
							detail: { requestId: request.requestId, failure: { reason: 'activation_failed' } },
						}),
					);
				};
				refuseLatestRequest();
				expect(snapshots.at(-1)).toMatchObject({
					state: 'replacement_requested',
					replacementRequestCount: 1,
				});
				if (outcome === 'recovered') {
					const request = requests.at(-1);
					if (request === undefined)
						throw new Error('Expected bounded native replacement request.');
					deliverBootstrap(target, request.requestId, 'recovered-first-capability');
					const mainPort = await recoveredPort.promise;
					mainPort.dispatchEvent(
						new MessageEvent('message', { data: makeReadyHealth('initial-failure-budget') }),
					);
					expect(snapshots.at(-1)).toMatchObject({
						state: 'ready',
						queuedCommandCount: 0,
						replacementRequestCount: 1,
						nativeBootstrapInstallCount: 1,
					});
					expect(requests).toHaveLength(2);
					expect(
						client.messages.filter(
							(message) =>
								message.kind === 'health' && message.requestId === 'queued-before-first-capability',
						),
					).toHaveLength(0);
					return;
				}
				for (let attempt = 0; attempt < 4; attempt += 1) refuseLatestRequest();
				expect(requests.filter((request) => request.reason === 'workerReplacement')).toHaveLength(
					4,
				);
				expect(snapshots.at(-1)).toMatchObject({
					state: 'failed',
					failureReason: 'bootstrapBudgetExhausted',
					queuedCommandCount: 0,
				});
				expect(
					client.messages.filter(
						(message) =>
							message.kind === 'health' && message.requestId === 'queued-before-first-capability',
					),
				).toEqual([expect.objectContaining({ errorKind: 'workerUnavailable' })]);
				refuseLatestRequest();
				expect(requests.filter((request) => request.reason === 'workerReplacement')).toHaveLength(
					4,
				);
				expect(snapshots.at(-1)?.state).toBe('failed');
				expect(
					client.messages.filter(
						(message) =>
							message.kind === 'health' && message.requestId === 'queued-before-first-capability',
					),
				).toHaveLength(1);
			} finally {
				dispatcher.dispose();
				session.dispose();
				handshake.uninstall();
			}
		},
	);

	test.each(['success', 'failure'] as const)(
		'a stale native %s cannot complete the next attempt after a lost-reply deadline',
		async (staleReply) => {
			vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout'] });
			const target = new EventTarget();
			const requests: z.infer<typeof bootstrapRequestSchema>[] = [];
			const snapshots: BridgePaneCommWorkerSessionDiagnosticSnapshot[] = [];
			const client = new RecordingPaneCommWorkerClient();
			const workerCreated = createBridgeProductDeferred<RecordingPaneCommWorker>();
			const recoveredPort = createBridgeProductDeferred<MessagePort>();
			let expectsRecoveredWorker = false;
			const NativeMessageChannel = MessageChannel;
			class RecordingChannel extends NativeMessageChannel {
				constructor() {
					super();
					if (expectsRecoveredWorker) recoveredPort.resolve(this.port2);
				}
			}
			vi.stubGlobal('MessageChannel', RecordingChannel);
			let handshake: BridgePageHandshakeSession | null = null;
			const session = new BridgePaneCommWorkerSession({
				bootstrapTimeoutMilliseconds: pageConfigurationFixture.workerBootstrapDeadlineMilliseconds,
				requestNativeBootstrap: (): void => {
					handshake?.requestProductSessionReplacement();
				},
				recordDiagnosticSnapshot: (snapshot): void => {
					snapshots.push(snapshot);
				},
				workerFactory: (): Worker => {
					const worker = new RecordingPaneCommWorker();
					workerCreated.resolve(worker);
					return worker;
				},
			});
			const dispatcher = session.createDispatcher({
				bootstrapRequest: makeRuntimeBootstrapRequest('lost-native-bootstrap'),
				publishWorkerMessages: client.publish,
			});
			target.addEventListener('__bridge_product_session_bootstrap_request', (event): void => {
				if (!('detail' in event)) throw new Error('Missing bootstrap request detail.');
				const request = bootstrapRequestSchema.parse(event.detail);
				requests.push(request);
				if (request.reason === 'initial')
					deliverBootstrap(target, request.requestId, 'initial-worker');
			});
			handshake = installBridgePageHandshakeSession(target, {
				onProductSessionBootstrap: (bootstrap): void => session.installNativeBootstrap(bootstrap),
				onProductSessionBootstrapFailure: (): void => session.handleNativeBootstrapFailure(),
			});
			try {
				const worker = await workerCreated.promise;
				// Force the already-started page session into its existing replacement path.
				session.requestWorkerReplacement({ kind: 'workerError' });
				dispatcher.dispatch(makeSelectCommand('queued-during-native-wait', 1, 'item-1', 'review'));
				await vi.advanceTimersByTimeAsync(5_000);
				const staleRequest = requests.find((request) => request.reason === 'workerReplacement');
				if (staleRequest === undefined) throw new Error('Expected timed-out native request.');
				if (staleReply === 'success')
					deliverBootstrap(target, staleRequest.requestId, 'expired-worker');
				else
					target.dispatchEvent(
						new CustomEvent('__bridge_product_session_bootstrap', {
							detail: { requestId: staleRequest.requestId, failure: { reason: 'delivery_failed' } },
						}),
					);
				expect(snapshots.at(-1)).toMatchObject({
					state: 'replacement_requested',
					nativeBootstrapInstallCount: 1,
					replacementRequestCount: 2,
				});
				for (let attempt = 0; attempt < 3; attempt += 1) {
					// eslint-disable-next-line no-await-in-loop -- Advance the subject's existing four replacement deadlines, not a correctness wait.
					await vi.advanceTimersByTimeAsync(5_000);
				}
				expect(snapshots.at(-1)).toMatchObject({
					state: 'failed',
					failureReason: 'bootstrapBudgetExhausted',
					queuedCommandCount: 0,
				});
				expect(requests.filter((request) => request.reason === 'workerReplacement')).toHaveLength(
					4,
				);
				expect(
					client.messages.filter(
						(message) =>
							message.kind === 'health' && message.requestId === 'queued-during-native-wait',
					),
				).toEqual([expect.objectContaining({ errorKind: 'workerUnavailable' })]);
				dispatcher.dispatch(
					encodeBridgeWorkerViewRecoveryRetryCommand({
						epoch: 2,
						requestId: 'retry-native-wait',
						view: { kind: 'review.metadata', subscriptionId: 'retry-view' },
					}),
				);
				expect(requests.filter((request) => request.reason === 'workerReplacement')).toHaveLength(
					5,
				);
				expect(snapshots.at(-1)?.state).toBe('replacement_requested');
				const retryRequest = requests.at(-1);
				if (retryRequest === undefined) throw new Error('Expected user Retry request.');
				expectsRecoveredWorker = true;
				deliverBootstrap(target, retryRequest.requestId, 'recovered-worker');
				const mainPort = await recoveredPort.promise;
				mainPort.dispatchEvent(
					new MessageEvent('message', { data: makeReadyHealth('lost-native-bootstrap') }),
				);
				expect(snapshots.at(-1)).toMatchObject({ state: 'ready', queuedCommandCount: 0 });
				expect(
					client.messages.filter(
						(message) =>
							message.kind === 'health' && message.requestId === 'queued-during-native-wait',
					),
				).toHaveLength(1);
				expect(worker.terminateCount).toBeLessThanOrEqual(1);
			} finally {
				dispatcher.dispose();
				session.dispose();
				handshake.uninstall();
			}
		},
	);

	test.each(['fetch', 'text'] as const)(
		'an asset %s that never settles reaches failed/Retry before Worker construction',
		async (heldPhase) => {
			vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout'] });
			const target = new EventTarget();
			const client = new RecordingPaneCommWorkerClient();
			const snapshots: BridgePaneCommWorkerSessionDiagnosticSnapshot[] = [];
			const fetchReplies: Array<ReturnType<typeof createBridgeProductDeferred<Response>>> = [];
			const bodyReplies: Array<ReturnType<typeof createBridgeProductDeferred<string>>> = [];
			const fetchStarted = createBridgeProductDeferred<void>();
			vi.stubGlobal(
				'fetch',
				vi.fn((): Promise<Response> => {
					fetchStarted.resolve();
					if (heldPhase === 'fetch') {
						const reply = createBridgeProductDeferred<Response>();
						fetchReplies.push(reply);
						return reply.promise;
					}
					const reply = createBridgeProductDeferred<string>();
					bodyReplies.push(reply);
					const response = new Response('');
					vi.spyOn(response, 'text').mockImplementation(() => reply.promise);
					return Promise.resolve(response);
				}),
			);
			const lateWorkers: RecordingPaneCommWorker[] = [];
			const lateWorkersTerminated = createBridgeProductDeferred<void>();
			class RecordedLateWorker extends RecordingPaneCommWorker {
				constructor() {
					super();
					lateWorkers.push(this);
				}
				override terminate(): void {
					super.terminate();
					if (
						lateWorkers.length === bootstrapCount &&
						lateWorkers.every((worker) => worker.terminateCount === 1)
					)
						lateWorkersTerminated.resolve();
				}
			}
			vi.stubGlobal('Worker', RecordedLateWorker);
			let handshake: BridgePageHandshakeSession | null = null;
			const session = new BridgePaneCommWorkerSession({
				bootstrapTimeoutMilliseconds: pageConfigurationFixture.workerBootstrapDeadlineMilliseconds,
				requestNativeBootstrap: (): void => {
					handshake?.requestProductSessionReplacement();
				},
				recordDiagnosticSnapshot: (snapshot): void => {
					snapshots.push(snapshot);
				},
				createObjectURL: (): string => 'blob:test-bootstrap-worker',
				revokeObjectURL: (): void => {},
			});
			const dispatcher = session.createDispatcher({
				bootstrapRequest: makeRuntimeBootstrapRequest('held-asset-bootstrap'),
				publishWorkerMessages: client.publish,
			});
			let bootstrapCount = 0;
			target.addEventListener('__bridge_product_session_bootstrap_request', (event): void => {
				if (!('detail' in event)) throw new Error('Missing bootstrap request detail.');
				const request = bootstrapRequestSchema.parse(event.detail);
				deliverBootstrap(target, request.requestId, `asset-worker-${++bootstrapCount}`);
			});
			handshake = installBridgePageHandshakeSession(target, {
				onProductSessionBootstrap: (bootstrap): void => session.installNativeBootstrap(bootstrap),
				onProductSessionBootstrapFailure: (): void => session.handleNativeBootstrapFailure(),
			});
			try {
				await fetchStarted.promise;
				dispatcher.dispatch(makeSelectCommand('queued-during-asset-wait', 1, 'item-1', 'review'));
				for (let attempt = 0; attempt < 5; attempt += 1) {
					// eslint-disable-next-line no-await-in-loop -- Initial construction plus the existing four replacement attempts are time-as-subject.
					await vi.advanceTimersByTimeAsync(5_000);
				}
				expect(snapshots.at(-1)).toMatchObject({
					state: 'failed',
					failureReason: 'bootstrapBudgetExhausted',
					queuedCommandCount: 0,
				});
				expect(bootstrapCount).toBe(5);
				expect(lateWorkers).toHaveLength(0);
				expect(
					client.messages.filter(
						(message) =>
							message.kind === 'health' && message.requestId === 'queued-during-asset-wait',
					),
				).toEqual([expect.objectContaining({ errorKind: 'workerUnavailable' })]);
			} finally {
				dispatcher.dispose();
				session.dispose();
				handshake.uninstall();
				for (const reply of fetchReplies) reply.resolve(new Response('self.onmessage = () => {};'));
				for (const reply of bodyReplies) reply.resolve('self.onmessage = () => {};');
				await lateWorkersTerminated.promise;
				expect(lateWorkers).toHaveLength(bootstrapCount);
				expect(lateWorkers.every((worker) => worker.terminateCount === 1)).toBe(true);
			}
		},
	);
});

function deliverBootstrap(target: EventTarget, requestId: string, workerInstanceId: string): void {
	target.dispatchEvent(
		new CustomEvent('__bridge_product_session_bootstrap', {
			detail: { ...makeNativeBootstrap(workerInstanceId), requestId },
		}),
	);
}
