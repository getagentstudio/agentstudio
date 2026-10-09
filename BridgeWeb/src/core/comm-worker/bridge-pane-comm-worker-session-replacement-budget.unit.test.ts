// oxlint-disable unicorn/require-post-message-target-origin -- MessagePort postMessage does not accept a target origin.
import { describe, expect, test, vi } from 'vitest';

import type { BridgePaneCommWorkerSessionDiagnosticSnapshot } from '../../foundation/diagnostics/bridge-review-selection-diagnostic.js';
import pageConfigurationFixture from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-page-configuration.json' with { type: 'json' };
import { BridgePaneCommWorkerSession } from './bridge-pane-comm-worker-session.js';
import {
	RecordingPaneCommWorker,
	RecordingPaneCommWorkerClient,
	createDeferredVoid,
	flushMicrotasks,
	makeNativeBootstrap,
	makeReadyHealth,
	makeRuntimeBootstrapRequest,
	makeSelectCommand,
} from './bridge-pane-comm-worker-session.test-support.js';

type ExpectedBridgePaneCommWorkerSessionDiagnosticSnapshot =
	BridgePaneCommWorkerSessionDiagnosticSnapshot;

describe('Bridge pane comm worker replacement budget', () => {
	test('successful native bootstraps followed by worker creation failures exhaust one replacement budget', async () => {
		const snapshots: ExpectedBridgePaneCommWorkerSessionDiagnosticSnapshot[] = [];
		const nativeBootstrapRequests: string[] = [];
		const requestObserved = Array.from({ length: 5 }, () => createDeferredVoid());
		const failed = createDeferredVoid();
		const client = new RecordingPaneCommWorkerClient();
		const workerFactory = vi.fn((): Worker => {
			throw new Error('worker script failed to load');
		});
		const session = new BridgePaneCommWorkerSession({
			bootstrapTimeoutMilliseconds: pageConfigurationFixture.workerBootstrapDeadlineMilliseconds,
			recordDiagnosticSnapshot: (snapshot): void => {
				snapshots.push(snapshot);
				if (snapshot.state === 'failed') failed.resolve();
			},
			requestNativeBootstrap: (reason): void => {
				nativeBootstrapRequests.push(reason);
				requestObserved[nativeBootstrapRequests.length - 1]?.resolve();
			},
			workerFactory,
		});
		const dispatcher = session.createDispatcher({
			bootstrapRequest: makeRuntimeBootstrapRequest('factory-loop-bootstrap'),
			publishWorkerMessages: client.publish,
		});
		try {
			session.installNativeBootstrap(makeNativeBootstrap('factory-loop-initial'));
			await requestObserved[0]?.promise;
			dispatcher.dispatch(makeSelectCommand('factory-queued', 1, 'item-1', 'review'));
			for (let attempt = 1; attempt <= 3; attempt += 1) {
				session.installNativeBootstrap(makeNativeBootstrap(`factory-loop-${attempt}`));
				// oxlint-disable-next-line no-await-in-loop -- Each reply gates the next accepted bootstrap.
				await requestObserved[attempt]?.promise;
			}
			session.installNativeBootstrap(makeNativeBootstrap('factory-loop-4'));
			const outcome = await Promise.race([
				failed.promise.then((): string => 'failed'),
				requestObserved[4]?.promise.then((): string => 'requested-again'),
			]);
			expect(outcome).toBe('failed');
			expect(nativeBootstrapRequests).toHaveLength(4);
			expect(workerFactory).toHaveBeenCalledTimes(5);
			expect(snapshots.filter((snapshot) => snapshot.state === 'failed')).toHaveLength(1);
			expect(snapshots.at(-1)).toMatchObject({
				failureReason: 'bootstrapBudgetExhausted',
				queuedCommandCount: 0,
				state: 'failed',
			});
			dispatcher.dispatch(makeSelectCommand('factory-after-failure', 1, 'item-1', 'review'));
			expect(client.messages).toEqual([
				expect.objectContaining({ requestId: 'factory-queued', errorKind: 'workerUnavailable' }),
				expect.objectContaining({
					requestId: 'factory-after-failure',
					errorKind: 'workerUnavailable',
				}),
			]);
		} finally {
			dispatcher.dispose();
			session.dispose();
		}
	});

	test('successful native bootstraps followed by worker ready timeouts exhaust one replacement budget', async () => {
		vi.useFakeTimers();
		const snapshots: ExpectedBridgePaneCommWorkerSessionDiagnosticSnapshot[] = [];
		const nativeBootstrapRequests: string[] = [];
		const client = new RecordingPaneCommWorkerClient();
		const session = new BridgePaneCommWorkerSession({
			bootstrapTimeoutMilliseconds: 25,
			recordDiagnosticSnapshot: (snapshot): void => {
				snapshots.push(snapshot);
			},
			requestNativeBootstrap: (reason): void => {
				nativeBootstrapRequests.push(reason);
			},
			workerFactory: (): Worker => new RecordingPaneCommWorker(),
		});
		const dispatcher = session.createDispatcher({
			bootstrapRequest: makeRuntimeBootstrapRequest('ready-timeout-loop-bootstrap'),
			publishWorkerMessages: client.publish,
		});
		try {
			session.installNativeBootstrap(makeNativeBootstrap('ready-timeout-initial'));
			await flushMicrotasks();
			vi.advanceTimersByTime(25);
			dispatcher.dispatch(makeSelectCommand('timeout-queued', 1, 'item-1', 'review'));
			for (let attempt = 1; attempt <= 4; attempt += 1) {
				session.installNativeBootstrap(makeNativeBootstrap(`ready-timeout-${attempt}`));
				// oxlint-disable-next-line no-await-in-loop -- Worker installation must precede its clock advance.
				await flushMicrotasks();
				vi.advanceTimersByTime(25);
			}
			expect(nativeBootstrapRequests).toHaveLength(4);
			expect(snapshots.filter((snapshot) => snapshot.state === 'failed')).toHaveLength(1);
			expect(snapshots.at(-1)).toMatchObject({
				failureReason: 'bootstrapBudgetExhausted',
				queuedCommandCount: 0,
				state: 'failed',
			});
			dispatcher.dispatch(makeSelectCommand('timeout-after-failure', 1, 'item-1', 'review'));
			expect(client.messages).toEqual([
				expect.objectContaining({ requestId: 'timeout-queued', errorKind: 'workerUnavailable' }),
				expect.objectContaining({
					requestId: 'timeout-after-failure',
					errorKind: 'workerUnavailable',
				}),
			]);
		} finally {
			dispatcher.dispose();
			session.dispose();
			vi.useRealTimers();
		}
	});

	test('a predecessor ready message cannot renew an unready replacement worker', async () => {
		const NativeMessageChannel = MessageChannel;
		const capture: { predecessorMainPort: MessagePort | null } = { predecessorMainPort: null };
		let channelCount = 0;
		class CapturingMessageChannel extends NativeMessageChannel {
			constructor() {
				super();
				channelCount += 1;
				if (channelCount === 1) capture.predecessorMainPort = this.port2;
			}
		}
		vi.stubGlobal('MessageChannel', CapturingMessageChannel);
		const firstWorker = new RecordingPaneCommWorker();
		const workers = [firstWorker, new RecordingPaneCommWorker()];
		const snapshots: ExpectedBridgePaneCommWorkerSessionDiagnosticSnapshot[] = [];
		const client = new RecordingPaneCommWorkerClient();
		const session = new BridgePaneCommWorkerSession({
			bootstrapTimeoutMilliseconds: pageConfigurationFixture.workerBootstrapDeadlineMilliseconds,
			recordDiagnosticSnapshot: (snapshot): void => {
				snapshots.push(snapshot);
			},
			workerFactory: (): Worker => {
				const worker = workers.shift();
				if (worker === undefined) throw new Error('Unexpected third worker.');
				return worker;
			},
		});
		const runtimeBootstrap = makeRuntimeBootstrapRequest('stale-ready-bootstrap');
		const dispatcher = session.createDispatcher({
			bootstrapRequest: runtimeBootstrap,
			publishWorkerMessages: client.publish,
		});
		try {
			session.installNativeBootstrap(makeNativeBootstrap('stale-ready-first'));
			await flushMicrotasks();
			if (capture.predecessorMainPort === null)
				throw new Error('Expected first worker and captured Main port.');
			firstWorker.dispatchEvent(new Event('error'));
			session.installNativeBootstrap(makeNativeBootstrap('stale-ready-second'));
			await flushMicrotasks();
			dispatcher.dispatch(makeSelectCommand('queued-after-stale-ready', 1, 'item-1', 'review'));
			capture.predecessorMainPort.dispatchEvent(
				new MessageEvent('message', { data: makeReadyHealth(runtimeBootstrap.requestId) }),
			);
			expect(snapshots.at(-1)).toMatchObject({
				queuedCommandCount: 1,
				replacementRequestCount: 1,
				state: 'bootstrapping',
			});
			expect(client.messages).toEqual([]);
		} finally {
			dispatcher.dispose();
			session.dispose();
			vi.unstubAllGlobals();
		}
	});
});
