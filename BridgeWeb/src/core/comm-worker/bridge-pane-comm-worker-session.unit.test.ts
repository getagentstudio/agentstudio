// oxlint-disable unicorn/require-post-message-target-origin -- MessagePort postMessage does not accept a target origin.
import { describe, expect, test, vi } from 'vitest';

import type { BridgeWorkerReplacementReason } from '../../foundation/diagnostics/bridge-worker-replacement-reason.js';
import pageConfigurationFixture from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-page-configuration.json' with { type: 'json' };
import { bridgeWorkerPierreRenderPolicy } from '../demand/bridge-content-demand-policy.js';
import { encodeBridgeWorkerViewRecoveryRetryCommand } from './bridge-comm-worker-protocol.js';
import {
	BridgePaneCommWorkerSession,
	disposeBridgePaneCommWorkerSession,
	getBridgePaneCommWorkerSession,
	installBridgePaneCommWorkerSessionForHost,
} from './bridge-pane-comm-worker-session.js';
import {
	MessagePortRecorder,
	RecordingPaneCommWorker,
	RecordingPaneCommWorkerClient,
	createDeferredVoid,
	expectPaneSurfacePolicies,
	expectRecordedGlobalPost,
	flushMicrotasks,
	makeActiveViewerModeUpdateCommand,
	makeNativeBootstrap,
	makeReadyHealth,
	makeRuntimeBootstrapRequest,
	makeSelectCommand,
} from './bridge-pane-comm-worker-session.test-support.js';
import { BRIDGE_PRODUCT_CAPABILITY_BYTE_LENGTH } from './bridge-product-contract-primitives.js';
import { bridgePaneCommWorkerInstallSchema } from './bridge-product-session-contracts.js';
import {
	bridgeWorkerMainToServerMessageSchema,
	bridgeWorkerServerToMainMessageSchema,
} from './bridge-worker-contracts.js';

interface ExpectedBridgePaneCommWorkerSessionDiagnosticSnapshot {
	readonly failureReason: 'bootstrapBudgetExhausted' | null;
	readonly lastReplacementReason: BridgeWorkerReplacementReason | null;
	readonly latestFileModeDispatchDisposition:
		| 'dropped_detached'
		| 'queued_not_ready'
		| 'posted'
		| null;
	readonly latestFileSelectDispatchDisposition:
		| 'dropped_detached'
		| 'queued_not_ready'
		| 'posted'
		| null;
	readonly latestReviewSelectDispatchDisposition:
		| 'dropped_detached'
		| 'queued_not_ready'
		| 'posted'
		| null;
	readonly nativeBootstrapInstallCount: number;
	readonly queuedCommandCount: number;
	readonly replacementRequestCount: number;
	readonly state:
		| 'awaiting_bootstrap'
		| 'bootstrapping'
		| 'ready'
		| 'replacement_requested'
		| 'failed'
		| 'disposed';
}

describe('Bridge pane comm worker session', () => {
	test('accepts exactly one host-owned shared session', () => {
		const session = new BridgePaneCommWorkerSession({
			bootstrapTimeoutMilliseconds: pageConfigurationFixture.workerBootstrapDeadlineMilliseconds,
			workerFactory: (): Worker => new RecordingPaneCommWorker(),
		});

		try {
			installBridgePaneCommWorkerSessionForHost(session);

			expect(getBridgePaneCommWorkerSession()).toBe(session);
			expect(() =>
				installBridgePaneCommWorkerSessionForHost(
					new BridgePaneCommWorkerSession({
						bootstrapTimeoutMilliseconds:
							pageConfigurationFixture.workerBootstrapDeadlineMilliseconds,
						workerFactory: (): Worker => new RecordingPaneCommWorker(),
					}),
				),
			).toThrow('Bridge pane comm worker session host was already installed.');
		} finally {
			disposeBridgePaneCommWorkerSession();
		}
	});

	test('owns one transferred worker across two clients and terminates it only with the session', async () => {
		const worker = new RecordingPaneCommWorker();
		const workerFactory = vi.fn((): Worker => worker);
		let nowMilliseconds = 100;
		const session = new BridgePaneCommWorkerSession({
			bootstrapTimeoutMilliseconds: pageConfigurationFixture.workerBootstrapDeadlineMilliseconds,
			now: (): number => nowMilliseconds++,
			workerFactory,
		});
		const firstClient = new RecordingPaneCommWorkerClient();
		const secondClient = new RecordingPaneCommWorkerClient();
		const runtimeBootstrap = makeRuntimeBootstrapRequest('pane-runtime-bootstrap-1');
		const firstDispatcher = session.createDispatcher({
			bootstrapRequest: runtimeBootstrap,
			publishWorkerMessages: firstClient.publish,
		});
		const secondDispatcher = session.createDispatcher({
			bootstrapRequest: makeRuntimeBootstrapRequest('pane-runtime-bootstrap-2'),
			publishWorkerMessages: secondClient.publish,
		});
		const nativeBootstrap = makeNativeBootstrap();
		let workerPortRecorder: MessagePortRecorder | null = null;

		try {
			session.installNativeBootstrap(nativeBootstrap);
			firstDispatcher.dispatch(makeSelectCommand('first-client-command', 1, 'item-1', 'review'));
			secondDispatcher.dispatch(makeSelectCommand('second-client-command', 2, 'item-2', 'review'));
			await flushMicrotasks();

			expect(workerFactory).toHaveBeenCalledOnce();
			expect(worker.globalPosts).toHaveLength(1);
			const globalPost = expectRecordedGlobalPost(worker.globalPosts[0]);
			expect(globalPost.transferListLength).toBe(2);
			expect(globalPost.transferredCapability).toBe(true);
			expect(globalPost.transferredPort).toBe(true);
			expect(nativeBootstrap.productCapability.byteLength).toBe(0);
			const install = bridgePaneCommWorkerInstallSchema.parse(globalPost.message);
			expect(install.bootstrap).toEqual(nativeBootstrap.bootstrap);
			expect(install.productCapability.byteLength).toBe(BRIDGE_PRODUCT_CAPABILITY_BYTE_LENGTH);

			workerPortRecorder = new MessagePortRecorder(install.productPort);
			const bootstrapMessages = await workerPortRecorder.waitForCount(1);
			expect(bootstrapMessages).toEqual([
				{
					...runtimeBootstrap,
					runtime: {
						...runtimeBootstrap.runtime,
						surfacePolicies: {
							fileView: {
								bridgeDemandRank: { lane: 'selected', priority: 0 },
								budget: bridgeWorkerPierreRenderPolicy.fileViewSelectedRenderBudget,
							},
							review: {
								bridgeDemandRank: { lane: 'selected', priority: 0 },
								budget: bridgeWorkerPierreRenderPolicy.reviewInteractiveRenderBudget,
							},
						},
					},
				},
			]);
			expect(worker.globalPosts).toHaveLength(1);

			const firstClientReady = firstClient.waitForCount(1);
			const secondClientReady = secondClient.waitForCount(1);
			install.productPort.postMessage(makeReadyHealth(runtimeBootstrap.requestId));
			await Promise.all([firstClientReady, secondClientReady]);
			const workerPortMessages = await workerPortRecorder.waitForCount(3);
			const ordinaryCommands = workerPortMessages
				.slice(1)
				.map((message) => bridgeWorkerMainToServerMessageSchema.parse(message));
			expect(ordinaryCommands).toEqual([
				expect.objectContaining({
					requestId: 'first-client-command',
					issuedAtMilliseconds: 100,
				}),
				expect.objectContaining({
					requestId: 'second-client-command',
					issuedAtMilliseconds: 101,
				}),
			]);
			expect(worker.globalPosts).toHaveLength(1);

			firstClient.clear();
			secondClient.clear();
			const firstClientReplies = firstClient.waitForCount(2);
			const secondClientReplies = secondClient.waitForCount(2);
			const firstReply = makeReadyHealth('first-client-command');
			const secondReply = makeReadyHealth('second-client-command');
			install.productPort.postMessage(firstReply);
			install.productPort.postMessage(secondReply);
			expect(await firstClientReplies).toEqual([firstReply, secondReply]);
			expect(await secondClientReplies).toEqual([firstReply, secondReply]);

			firstClient.clear();
			secondClient.clear();
			firstDispatcher.dispose();
			expect(worker.terminateCount).toBe(0);
			firstDispatcher.dispatch(makeSelectCommand('disposed-client-command', 3, 'item-3', 'review'));
			secondDispatcher.dispatch(
				makeSelectCommand('remaining-client-command', 4, 'item-4', 'review'),
			);
			const postDisposeMessages = await workerPortRecorder.waitForCount(4);
			expect(
				postDisposeMessages
					.slice(3)
					.map((message) => bridgeWorkerMainToServerMessageSchema.parse(message).requestId),
			).toEqual(['remaining-client-command']);

			const remainingClientReply = makeReadyHealth('remaining-client-command');
			const remainingClientReplies = secondClient.waitForCount(1);
			install.productPort.postMessage(remainingClientReply);
			expect(await remainingClientReplies).toEqual([remainingClientReply]);
			expect(firstClient.messages).toEqual([]);

			session.dispose();
			await flushMicrotasks();
			expect(worker.terminateCount).toBe(1);
		} finally {
			workerPortRecorder?.close();
			firstDispatcher.dispose();
			secondDispatcher.dispose();
			session.dispose();
		}
	});

	test('forwards strict File display patches through the authoritative server parser', async () => {
		const worker = new RecordingPaneCommWorker();
		const session = new BridgePaneCommWorkerSession({
			bootstrapTimeoutMilliseconds: pageConfigurationFixture.workerBootstrapDeadlineMilliseconds,
			workerFactory: (): Worker => worker,
		});
		const client = new RecordingPaneCommWorkerClient();
		const runtimeBootstrap = makeRuntimeBootstrapRequest('file-display-bootstrap');
		const dispatcher = session.createDispatcher({
			bootstrapRequest: runtimeBootstrap,
			publishWorkerMessages: client.publish,
		});

		try {
			session.installNativeBootstrap(makeNativeBootstrap());
			await flushMicrotasks();
			const install = bridgePaneCommWorkerInstallSchema.parse(worker.globalPosts[0]?.message);
			const recorder = new MessagePortRecorder(install.productPort);
			await recorder.waitForCount(1);
			install.productPort.postMessage(makeReadyHealth(runtimeBootstrap.requestId));
			await client.waitForCount(1);
			client.clear();

			const fileDisplayEvent = bridgeWorkerServerToMainMessageSchema.parse({
				wireVersion: 1,
				direction: 'serverWorkerToMain',
				transferDescriptors: [],
				kind: 'fileDisplayPatch',
				surface: 'fileView',
				epoch: 4,
				sequence: 9,
				projectionRevision: 3,
				patches: [
					{
						slice: 'fileStatus',
						operation: 'upsert',
						payload: { state: 'stale' },
					},
				],
			});
			install.productPort.postMessage(fileDisplayEvent);

			expect(await client.waitForCount(1)).toEqual([fileDisplayEvent]);
			recorder.close();
		} finally {
			dispatcher.dispose();
			session.dispose();
		}
	});

	test('reports scrub-safe File mode and selection dispatch across worker replacement', async () => {
		// Arrange
		const workers = [new RecordingPaneCommWorker(), new RecordingPaneCommWorker()];
		const workerFactory = vi.fn((): Worker => {
			const worker = workers[workerFactory.mock.calls.length - 1];
			if (worker === undefined) throw new Error('unexpected worker factory call');
			return worker;
		});
		const diagnosticSnapshots: ExpectedBridgePaneCommWorkerSessionDiagnosticSnapshot[] = [];
		const session = new BridgePaneCommWorkerSession({
			bootstrapTimeoutMilliseconds: pageConfigurationFixture.workerBootstrapDeadlineMilliseconds,
			recordDiagnosticSnapshot: (
				snapshot: ExpectedBridgePaneCommWorkerSessionDiagnosticSnapshot,
			): void => {
				diagnosticSnapshots.push(snapshot);
			},
			workerFactory,
		});
		const runtimeBootstrap = makeRuntimeBootstrapRequest('diagnostic-runtime-bootstrap');
		const client = new RecordingPaneCommWorkerClient();
		const dispatcher = session.createDispatcher({
			bootstrapRequest: runtimeBootstrap,
			publishWorkerMessages: client.publish,
		});
		let firstPortRecorder: MessagePortRecorder | null = null;
		let secondPortRecorder: MessagePortRecorder | null = null;

		try {
			expect(diagnosticSnapshots).toContainEqual(
				expect.objectContaining({
					nativeBootstrapInstallCount: 0,
					queuedCommandCount: 0,
					replacementRequestCount: 0,
					state: 'awaiting_bootstrap',
				}),
			);

			// Act: establish the first ready worker, then force replacement.
			session.installNativeBootstrap(makeNativeBootstrap('diagnostic-worker-1'));
			await flushMicrotasks();
			expect(diagnosticSnapshots).toContainEqual(
				expect.objectContaining({
					nativeBootstrapInstallCount: 1,
					queuedCommandCount: 0,
					replacementRequestCount: 0,
					state: 'bootstrapping',
				}),
			);
			const firstInstall = bridgePaneCommWorkerInstallSchema.parse(
				workers[0]?.globalPosts[0]?.message,
			);
			firstPortRecorder = new MessagePortRecorder(firstInstall.productPort);
			await firstPortRecorder.waitForCount(1);
			firstInstall.productPort.postMessage(makeReadyHealth(runtimeBootstrap.requestId));
			await client.waitForCount(1);
			client.clear();
			dispatcher.dispatch(makeActiveViewerModeUpdateCommand('private-file-mode-posted', 1));
			dispatcher.dispatch(
				makeSelectCommand('private-file-select-posted', 2, 'private-item', 'fileView'),
			);
			expect(diagnosticSnapshots).toContainEqual(
				expect.objectContaining({
					latestFileModeDispatchDisposition: 'posted',
					latestFileSelectDispatchDisposition: 'posted',
					nativeBootstrapInstallCount: 1,
					queuedCommandCount: 0,
					replacementRequestCount: 0,
					state: 'ready',
				}),
			);
			workers[0]?.dispatchEvent(new Event('error'));
			dispatcher.dispatch(makeActiveViewerModeUpdateCommand('private-file-mode-queued', 3));
			dispatcher.dispatch(
				makeSelectCommand('private-file-select-queued', 4, 'private-item', 'fileView'),
			);
			dispatcher.dispatch(
				makeSelectCommand('private-queued-review-select', 5, 'private-item', 'review'),
			);

			// Assert: the select is queued against replacement state without retaining identity.
			expect(diagnosticSnapshots).toContainEqual(
				expect.objectContaining({
					latestFileModeDispatchDisposition: 'queued_not_ready',
					latestFileSelectDispatchDisposition: 'queued_not_ready',
					latestReviewSelectDispatchDisposition: 'queued_not_ready',
					nativeBootstrapInstallCount: 1,
					queuedCommandCount: 3,
					replacementRequestCount: 1,
					lastReplacementReason: { kind: 'workerError' },
					state: 'replacement_requested',
				}),
			);

			// Act: install fresh authority and make the replacement worker ready.
			session.installNativeBootstrap(makeNativeBootstrap('diagnostic-worker-2'));
			await flushMicrotasks();
			const secondInstall = bridgePaneCommWorkerInstallSchema.parse(
				workers[1]?.globalPosts[0]?.message,
			);
			secondPortRecorder = new MessagePortRecorder(secondInstall.productPort);
			await secondPortRecorder.waitForCount(1);
			secondInstall.productPort.postMessage(makeReadyHealth(runtimeBootstrap.requestId));
			await client.waitForCount(1);
			await secondPortRecorder.waitForCount(4);

			// Assert: queued dispatch advances to posted only after replacement readiness.
			expect(diagnosticSnapshots).toContainEqual(
				expect.objectContaining({
					latestFileModeDispatchDisposition: 'posted',
					latestFileSelectDispatchDisposition: 'posted',
					latestReviewSelectDispatchDisposition: 'posted',
					nativeBootstrapInstallCount: 2,
					queuedCommandCount: 0,
					replacementRequestCount: 1,
					state: 'ready',
				}),
			);

			// Act / Assert: a detached client reports a drop, and disposal remains observable.
			dispatcher.dispose();
			dispatcher.dispatch(makeActiveViewerModeUpdateCommand('private-file-mode-detached', 6));
			dispatcher.dispatch(
				makeSelectCommand('private-file-select-detached', 7, 'private-item', 'fileView'),
			);
			dispatcher.dispatch(
				makeSelectCommand('private-detached-review-select', 8, 'private-item', 'review'),
			);
			expect(diagnosticSnapshots.at(-1)).toEqual(
				expect.objectContaining({
					latestFileModeDispatchDisposition: 'dropped_detached',
					latestFileSelectDispatchDisposition: 'dropped_detached',
					latestReviewSelectDispatchDisposition: 'dropped_detached',
					queuedCommandCount: 0,
					state: 'ready',
				}),
			);
			expect(JSON.stringify(diagnosticSnapshots)).not.toContain('private-');
			session.dispose();
			expect(diagnosticSnapshots.at(-1)).toEqual(expect.objectContaining({ state: 'disposed' }));
		} finally {
			firstPortRecorder?.close();
			secondPortRecorder?.close();
			dispatcher.dispose();
			session.dispose();
		}
	});

	test('keeps diagnostic recording observational across session bootstrap, dispatch, replacement, and disposal', async () => {
		// Arrange
		const workers = [new RecordingPaneCommWorker(), new RecordingPaneCommWorker()];
		const workerFactory = vi.fn((): Worker => {
			const worker = workers[workerFactory.mock.calls.length - 1];
			if (worker === undefined) throw new Error('unexpected worker factory call');
			return worker;
		});
		const replacementReasons: string[] = [];
		let session: BridgePaneCommWorkerSession | undefined;

		// Act / Assert: diagnostic failure cannot prevent session construction.
		expect((): void => {
			session = new BridgePaneCommWorkerSession({
				bootstrapTimeoutMilliseconds: pageConfigurationFixture.workerBootstrapDeadlineMilliseconds,
				recordDiagnosticSnapshot: (): never => {
					throw new Error('diagnostic recorder failed');
				},
				requestNativeBootstrap: (reason): void => {
					replacementReasons.push(reason);
				},
				workerFactory,
			});
		}).not.toThrow();
		if (session === undefined)
			throw new Error('Bridge pane comm worker session was not constructed.');
		const runtimeBootstrap = makeRuntimeBootstrapRequest('fail-open-runtime-bootstrap');
		const client = new RecordingPaneCommWorkerClient();
		const dispatcher = session.createDispatcher({
			bootstrapRequest: runtimeBootstrap,
			publishWorkerMessages: client.publish,
		});
		let firstPortRecorder: MessagePortRecorder | null = null;

		try {
			// Act / Assert: bootstrap and queued dispatch continue through diagnostic failure.
			expect((): void =>
				dispatcher.dispatch(
					makeSelectCommand('fail-open-queued-select', 1, 'private-item', 'review'),
				),
			).not.toThrow();
			expect((): void =>
				session?.installNativeBootstrap(makeNativeBootstrap('fail-open-worker-1')),
			).not.toThrow();
			await flushMicrotasks();
			const firstInstall = bridgePaneCommWorkerInstallSchema.parse(
				workers[0]?.globalPosts[0]?.message,
			);
			firstPortRecorder = new MessagePortRecorder(firstInstall.productPort);
			await firstPortRecorder.waitForCount(1);
			firstInstall.productPort.postMessage(makeReadyHealth(runtimeBootstrap.requestId));
			await client.waitForCount(1);
			const readyMessages = await firstPortRecorder.waitForCount(2);
			expect(bridgeWorkerMainToServerMessageSchema.parse(readyMessages[1]).requestId).toBe(
				'fail-open-queued-select',
			);

			// Act / Assert: replacement request and fresh authority survive diagnostic failure.
			expect((): void => {
				workers[0]?.dispatchEvent(new Event('error'));
			}).not.toThrow();
			expect(replacementReasons).toEqual(['workerReplacement']);
			expect((): void =>
				session?.installNativeBootstrap(makeNativeBootstrap('fail-open-worker-2')),
			).not.toThrow();
			await flushMicrotasks();
			expect(workers[1]?.globalPosts).toHaveLength(1);

			// Act / Assert: disposal remains a product lifecycle operation, never a diagnostic one.
			expect((): void => session?.dispose()).not.toThrow();
			expect(workers[1]?.terminateCount).toBe(1);
		} finally {
			firstPortRecorder?.close();
			dispatcher.dispose();
			session.dispose();
		}
	});

	test.each(['error', 'messageerror'] as const)(
		'restarts after %s only when native installs fresh authority',
		async (failureEventName) => {
			const workers = [new RecordingPaneCommWorker(), new RecordingPaneCommWorker()];
			const workerFactory = vi.fn((): Worker => {
				const worker = workers[workerFactory.mock.calls.length - 1];
				if (worker === undefined) {
					throw new Error('unexpected worker factory call');
				}
				return worker;
			});
			const restartReasons: string[] = [];
			const replacementFacts: BridgeWorkerReplacementReason[] = [];
			const session = new BridgePaneCommWorkerSession({
				bootstrapTimeoutMilliseconds: pageConfigurationFixture.workerBootstrapDeadlineMilliseconds,
				recordDiagnosticSnapshot: (snapshot): void => {
					if (
						snapshot.state === 'replacement_requested' &&
						snapshot.lastReplacementReason !== null
					) {
						replacementFacts.push(snapshot.lastReplacementReason);
					}
				},
				requestNativeBootstrap: (reason): void => {
					restartReasons.push(reason);
				},
				workerFactory,
			});
			const client = new RecordingPaneCommWorkerClient();
			const runtimeBootstrap = makeRuntimeBootstrapRequest('restart-runtime-bootstrap');
			const dispatcher = session.createDispatcher({
				bootstrapRequest: runtimeBootstrap,
				publishWorkerMessages: client.publish,
			});
			const firstBootstrap = makeNativeBootstrap('worker-instance-1');
			session.installNativeBootstrap(firstBootstrap);
			await flushMicrotasks();
			const firstInstall = bridgePaneCommWorkerInstallSchema.parse(
				workers[0]?.globalPosts[0]?.message,
			);
			const firstPortRecorder = new MessagePortRecorder(firstInstall.productPort);
			await firstPortRecorder.waitForCount(1);
			firstInstall.productPort.postMessage(makeReadyHealth(runtimeBootstrap.requestId));
			await client.waitForCount(1);
			client.clear();

			workers[0]?.dispatchEvent(new Event(failureEventName));
			dispatcher.dispatch(makeSelectCommand('queued-during-restart', 1, 'item-1', 'review'));
			const secondBootstrap = makeNativeBootstrap('worker-instance-2');
			session.installNativeBootstrap(secondBootstrap);
			await flushMicrotasks();

			expect(restartReasons).toEqual(['workerReplacement']);
			expect(replacementFacts[0]).toEqual({
				kind: failureEventName === 'error' ? 'workerError' : 'messageError',
			});
			expect(workers[0]?.terminateCount).toBe(1);
			expect(workers[1]?.globalPosts).toHaveLength(1);
			expect(secondBootstrap.productCapability.byteLength).toBe(0);
			const secondInstall = bridgePaneCommWorkerInstallSchema.parse(
				workers[1]?.globalPosts[0]?.message,
			);
			const secondPortRecorder = new MessagePortRecorder(secondInstall.productPort);
			const secondMessagesBeforeReady = await secondPortRecorder.waitForCount(1);
			expect(secondMessagesBeforeReady).toEqual([
				expect.objectContaining({
					requestId: runtimeBootstrap.requestId,
					runtime: expect.objectContaining({
						surfacePolicies: expectPaneSurfacePolicies(),
					}),
				}),
			]);
			secondInstall.productPort.postMessage(makeReadyHealth(runtimeBootstrap.requestId));
			const secondMessages = await secondPortRecorder.waitForCount(2);
			expect(bridgeWorkerMainToServerMessageSchema.parse(secondMessages[1]).requestId).toBe(
				'queued-during-restart',
			);

			firstInstall.productPort.postMessage(makeReadyHealth('late-old-worker'));
			await flushMicrotasks();
			expect(client.messages).not.toContainEqual(
				expect.objectContaining({ requestId: 'late-old-worker' }),
			);

			firstPortRecorder.close();
			secondPortRecorder.close();
			dispatcher.dispose();
			session.dispose();
		},
	);

	test('prepares runtime replacement state before retiring the failed worker', async () => {
		const worker = new RecordingPaneCommWorker();
		const session = new BridgePaneCommWorkerSession({
			bootstrapTimeoutMilliseconds: pageConfigurationFixture.workerBootstrapDeadlineMilliseconds,
			workerFactory: (): Worker => worker,
		});
		const prepareWorkerReplacement = vi.fn((): void => {
			expect(worker.terminateCount).toBe(0);
		});
		session.setWorkerReplacementPreparer(prepareWorkerReplacement);
		const dispatcher = session.createDispatcher({
			bootstrapRequest: makeRuntimeBootstrapRequest('replacement-order-bootstrap'),
			publishWorkerMessages: (): void => {},
		});
		try {
			session.installNativeBootstrap(makeNativeBootstrap('replacement-order-worker'));
			await flushMicrotasks();
			worker.dispatchEvent(new Event('error'));

			expect(prepareWorkerReplacement).toHaveBeenCalledOnce();
			expect(worker.terminateCount).toBe(1);
		} finally {
			dispatcher.dispose();
			session.dispose();
		}
	});

	test('initial bootstrap failures exhaust the bounded budget and end in failed start', () => {
		const snapshots: ExpectedBridgePaneCommWorkerSessionDiagnosticSnapshot[] = [];
		const nativeBootstrapRequests: string[] = [];
		const workerFactory = vi.fn<() => Worker>(() => new RecordingPaneCommWorker());
		const client = new RecordingPaneCommWorkerClient();
		const session = new BridgePaneCommWorkerSession({
			bootstrapTimeoutMilliseconds: pageConfigurationFixture.workerBootstrapDeadlineMilliseconds,
			workerFactory,
			recordDiagnosticSnapshot: (snapshot): void => {
				snapshots.push(snapshot);
			},
			requestNativeBootstrap: (reason): void => {
				nativeBootstrapRequests.push(reason);
			},
		});
		const dispatcher = session.createDispatcher({
			bootstrapRequest: makeRuntimeBootstrapRequest('initial-failed-start'),
			publishWorkerMessages: client.publish,
		});
		try {
			dispatcher.dispatch(makeSelectCommand('before-initial-failure', 1, 'item-1', 'review'));
			session.handleNativeBootstrapFailure();
			expect(nativeBootstrapRequests).toEqual(['workerReplacement']);
			for (let failureReply = 0; failureReply < 4; failureReply += 1)
				session.handleNativeBootstrapFailure();
			expect(nativeBootstrapRequests).toHaveLength(4);
			expect(snapshots.at(-1)).toMatchObject({
				state: 'failed',
				failureReason: 'bootstrapBudgetExhausted',
				nativeBootstrapInstallCount: 0,
				queuedCommandCount: 0,
			});
			expect(workerFactory).not.toHaveBeenCalled();
			expect(client.messages).toContainEqual(
				expect.objectContaining({
					requestId: 'before-initial-failure',
					errorKind: 'workerUnavailable',
				}),
			);
			session.handleNativeBootstrapFailure();
			expect(nativeBootstrapRequests).toHaveLength(4);
			expect(snapshots.at(-1)?.state).toBe('failed');
		} finally {
			dispatcher.dispose();
			session.dispose();
		}
	});

	test('re-requests native bootstrap after a failure reply within a bounded budget per replacement', async () => {
		// Arrange
		const firstWorker = new RecordingPaneCommWorker();
		const secondWorker = new RecordingPaneCommWorker();
		const workerFactory = vi
			.fn<() => Worker>()
			.mockReturnValueOnce(firstWorker)
			.mockReturnValueOnce(secondWorker);
		const nativeBootstrapRequests: string[] = [];
		const session = new BridgePaneCommWorkerSession({
			bootstrapTimeoutMilliseconds: pageConfigurationFixture.workerBootstrapDeadlineMilliseconds,
			requestNativeBootstrap: (reason): void => {
				nativeBootstrapRequests.push(reason);
			},
			workerFactory,
		});
		const dispatcher = session.createDispatcher({
			bootstrapRequest: makeRuntimeBootstrapRequest('bounded-rerequest-bootstrap'),
			publishWorkerMessages: (): void => {},
		});
		try {
			session.installNativeBootstrap(makeNativeBootstrap('bounded-first-worker'));
			await flushMicrotasks();
			firstWorker.dispatchEvent(new Event('error'));
			expect(nativeBootstrapRequests).toEqual(['workerReplacement']);

			// Act: native answers every replacement request with a typed failure.
			for (let reply = 0; reply < 4; reply += 1) session.handleNativeBootstrapFailure();

			// Assert: three re-requests, then the session stops asking.
			expect(nativeBootstrapRequests).toHaveLength(4);

			// A user Retry admits one fresh replacement with a fresh budget.
			dispatcher.dispatch(
				encodeBridgeWorkerViewRecoveryRetryCommand({
					epoch: 1,
					requestId: 'retry-after-budget',
					view: { kind: 'review.metadata', subscriptionId: 'review-subscription' },
				}),
			);
			session.installNativeBootstrap(makeNativeBootstrap('bounded-second-worker'));
			await flushMicrotasks();
			secondWorker.dispatchEvent(new Event('error'));
			session.handleNativeBootstrapFailure();

			// Assert
			expect(nativeBootstrapRequests).toHaveLength(7);
		} finally {
			dispatcher.dispose();
			session.dispose();
		}
	});

	test('exhausted replacement bootstrap failures settle and drain queued work', () => {
		const snapshots: ExpectedBridgePaneCommWorkerSessionDiagnosticSnapshot[] = [];
		const nativeBootstrapRequests: string[] = [];
		const client = new RecordingPaneCommWorkerClient();
		const session = new BridgePaneCommWorkerSession({
			bootstrapTimeoutMilliseconds: pageConfigurationFixture.workerBootstrapDeadlineMilliseconds,
			recordDiagnosticSnapshot: (snapshot): void => {
				snapshots.push(snapshot);
			},
			requestNativeBootstrap: (reason): void => {
				nativeBootstrapRequests.push(reason);
			},
			workerFactory: (): Worker => new RecordingPaneCommWorker(),
		});
		const dispatcher = session.createDispatcher({
			bootstrapRequest: makeRuntimeBootstrapRequest('exhausted-replacement-bootstrap'),
			publishWorkerMessages: client.publish,
		});
		try {
			session.requestWorkerReplacement({ kind: 'workerError' });
			dispatcher.dispatch(makeSelectCommand('queued-before-exhaustion', 1, 'item-1', 'review'));
			for (let reply = 0; reply < 4; reply += 1) session.handleNativeBootstrapFailure();
			dispatcher.dispatch(makeSelectCommand('after-exhaustion', 1, 'item-1', 'review'));

			expect(nativeBootstrapRequests).toHaveLength(4);
			expect(snapshots.at(-1)).toMatchObject({
				failureReason: 'bootstrapBudgetExhausted',
				state: 'failed',
				queuedCommandCount: 0,
			});
			expect(client.messages).toEqual([
				expect.objectContaining({
					requestId: 'queued-before-exhaustion',
					errorKind: 'workerUnavailable',
				}),
				expect.objectContaining({ requestId: 'after-exhaustion', errorKind: 'workerUnavailable' }),
			]);
		} finally {
			dispatcher.dispose();
			session.dispose();
		}
	});

	test('a user Retry gets one fresh budget and exhaustion returns to failed without a loop', () => {
		const snapshots: ExpectedBridgePaneCommWorkerSessionDiagnosticSnapshot[] = [];
		const nativeBootstrapRequests: string[] = [];
		const client = new RecordingPaneCommWorkerClient();
		const session = new BridgePaneCommWorkerSession({
			bootstrapTimeoutMilliseconds: pageConfigurationFixture.workerBootstrapDeadlineMilliseconds,
			recordDiagnosticSnapshot: (snapshot): void => {
				snapshots.push(snapshot);
			},
			requestNativeBootstrap: (reason): void => {
				nativeBootstrapRequests.push(reason);
			},
			workerFactory: (): Worker => new RecordingPaneCommWorker(),
		});
		const dispatcher = session.createDispatcher({
			bootstrapRequest: makeRuntimeBootstrapRequest('retry-budget-bootstrap'),
			publishWorkerMessages: client.publish,
		});
		try {
			session.requestWorkerReplacement({ kind: 'workerError' });
			for (let reply = 0; reply < 4; reply += 1) session.handleNativeBootstrapFailure();
			dispatcher.dispatch(
				encodeBridgeWorkerViewRecoveryRetryCommand({
					epoch: 1,
					requestId: 'retry-budget-command',
					view: { kind: 'file.metadata', subscriptionId: 'file-subscription' },
				}),
			);
			expect(nativeBootstrapRequests).toHaveLength(5);
			expect(snapshots.at(-1)).toMatchObject({ state: 'replacement_requested' });
			expect(client.messages).toContainEqual(
				expect.objectContaining({
					requestId: 'retry-budget-command',
					status: 'ready',
				}),
			);
			for (let reply = 0; reply < 4; reply += 1) session.handleNativeBootstrapFailure();
			expect(nativeBootstrapRequests).toHaveLength(8);
			expect(snapshots.at(-1)).toMatchObject({
				state: 'failed',
				failureReason: 'bootstrapBudgetExhausted',
				queuedCommandCount: 0,
			});
			session.handleNativeBootstrapFailure();
			session.requestWorkerReplacement({ kind: 'workerError' });
			expect(nativeBootstrapRequests).toHaveLength(8);
		} finally {
			dispatcher.dispose();
			session.dispose();
		}
	});

	test('requests one replacement when worker bootstrap readiness times out', async () => {
		vi.useFakeTimers();
		const worker = new RecordingPaneCommWorker();
		const restartReasons: string[] = [];
		const replacementFacts: BridgeWorkerReplacementReason[] = [];
		const session = new BridgePaneCommWorkerSession({
			recordDiagnosticSnapshot: (snapshot): void => {
				if (snapshot.state === 'replacement_requested' && snapshot.lastReplacementReason !== null) {
					replacementFacts.push(snapshot.lastReplacementReason);
				}
			},
			bootstrapTimeoutMilliseconds: 25,
			requestNativeBootstrap: (reason): void => {
				restartReasons.push(reason);
			},
			workerFactory: (): Worker => worker,
		});
		const dispatcher = session.createDispatcher({
			bootstrapRequest: makeRuntimeBootstrapRequest('timed-bootstrap'),
			publishWorkerMessages: (): void => {},
		});

		try {
			session.installNativeBootstrap(makeNativeBootstrap());
			await flushMicrotasks();
			vi.advanceTimersByTime(25);

			expect(worker.terminateCount).toBe(1);
			expect(restartReasons).toEqual(['workerReplacement']);
			expect(replacementFacts[0]).toEqual({ kind: 'bootstrapTimeout' });
		} finally {
			dispatcher.dispose();
			session.dispose();
			vi.useRealTimers();
		}
	});

	test('requests fresh authority and preserves queued commands when worker creation fails', async () => {
		const replacementWorker = new RecordingPaneCommWorker();
		const workerFactory = vi
			.fn<() => Promise<Worker> | Worker>()
			.mockRejectedValueOnce(new Error('worker creation failed'))
			.mockReturnValueOnce(replacementWorker);
		const restartReasons: string[] = [];
		const replacementRequest = createDeferredVoid();
		const session = new BridgePaneCommWorkerSession({
			bootstrapTimeoutMilliseconds: pageConfigurationFixture.workerBootstrapDeadlineMilliseconds,
			requestNativeBootstrap: (reason): void => {
				restartReasons.push(reason);
				replacementRequest.resolve();
			},
			workerFactory,
		});
		const runtimeBootstrap = makeRuntimeBootstrapRequest('factory-rejection-bootstrap');
		const dispatcher = session.createDispatcher({
			bootstrapRequest: runtimeBootstrap,
			publishWorkerMessages: (): void => {},
		});

		try {
			session.installNativeBootstrap(makeNativeBootstrap('failed-worker-instance'));
			dispatcher.dispatch(
				makeSelectCommand('queued-after-factory-rejection', 1, 'item-1', 'review'),
			);
			await replacementRequest.promise;

			expect(workerFactory).toHaveBeenCalledOnce();
			expect(restartReasons).toEqual(['workerReplacement']);

			const replacementBootstrap = makeNativeBootstrap('replacement-worker-instance');
			session.installNativeBootstrap(replacementBootstrap);
			await flushMicrotasks();
			const replacementInstall = bridgePaneCommWorkerInstallSchema.parse(
				replacementWorker.globalPosts[0]?.message,
			);
			const replacementPortRecorder = new MessagePortRecorder(replacementInstall.productPort);
			const replacementMessagesBeforeReady = await replacementPortRecorder.waitForCount(1);
			expect(replacementMessagesBeforeReady).toEqual([
				expect.objectContaining({
					requestId: runtimeBootstrap.requestId,
					runtime: expect.objectContaining({
						surfacePolicies: expectPaneSurfacePolicies(),
					}),
				}),
			]);

			replacementInstall.productPort.postMessage(makeReadyHealth(runtimeBootstrap.requestId));
			const replacementMessages = await replacementPortRecorder.waitForCount(2);
			expect(bridgeWorkerMainToServerMessageSchema.parse(replacementMessages[1]).requestId).toBe(
				'queued-after-factory-rejection',
			);
			replacementPortRecorder.close();
		} finally {
			dispatcher.dispose();
			session.dispose();
		}
	});
});
