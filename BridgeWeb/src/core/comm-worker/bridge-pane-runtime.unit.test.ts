import { afterEach, beforeEach, describe, expect, test, vi } from 'vitest';

import pageConfigurationFixture from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-page-configuration.json' with { type: 'json' };
// oxlint-disable unicorn/require-post-message-target-origin -- MessagePort postMessage does not accept target origins.
import { createWorktreeAnnotationSurfaceClient } from '../../worktree-annotations/worktree-annotation-surface-client.js';
import {
	createBridgeMainRenderSnapshotStore,
	type BridgeMainRenderSnapshotStore,
} from './bridge-main-render-snapshot-store.js';
import type {
	BridgePaneCommWorkerDispatcher,
	BridgePaneCommWorkerNativeBootstrap,
} from './bridge-pane-comm-worker-session.js';
import type { BridgePaneSessionPort } from './bridge-pane-runtime.js';
import {
	BRIDGE_PRODUCT_CAPABILITY_BYTE_LENGTH,
	BRIDGE_PRODUCT_MAXIMUM_CONTENT_BYTES,
	BRIDGE_PRODUCT_MAXIMUM_METADATA_FRAME_BYTES,
	BRIDGE_PRODUCT_MAXIMUM_QUEUED_STREAM_BYTES,
	BRIDGE_PRODUCT_MAXIMUM_QUEUED_STREAM_FRAMES,
	BRIDGE_PRODUCT_MAXIMUM_REQUEST_BODY_BYTES,
	BRIDGE_PRODUCT_TERMINAL_FRAME_RESERVE,
	BRIDGE_PRODUCT_WIRE_VERSION,
} from './bridge-product-contract-primitives.js';
import { bridgePaneCommWorkerInstallSchema } from './bridge-product-session-contracts.js';
import type {
	BridgeWorkerFileDisplayPatchEvent,
	BridgeWorkerMainToServerMessage,
	BridgeWorkerReviewDisplayPatchEvent,
	BridgeWorkerServerToMainMessage,
} from './bridge-worker-contracts.js';
import type { BridgeWorkerRpcCommandInput } from './bridge-worker-rpc-client.js';
import {
	createBridgeWorkerRpcLifecycleStore,
	type BridgeWorkerRpcLifecycleStore,
} from './bridge-worker-rpc-lifecycle-store.js';

interface ExpectedBridgePaneRuntimeDiagnosticSnapshot {
	readonly nativeBootstrapInstallAcceptedCount: number;
	readonly nativeBootstrapInstallAttemptCount: number;
	readonly nativeBootstrapInstallRejectedCount: number;
}

interface RecordedPaneRuntimeWorkerPost {
	readonly message: unknown;
	readonly transferListLength: number;
}

describe('Bridge pane runtime', () => {
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

	test('owns one pane session and lifecycle store with stable isolated surface clients', async () => {
		// Arrange
		const { createBridgePaneRuntime } = await loadBridgePaneRuntimeModule();
		let activeDispatcherCount = 0;
		const dispatcherDispose = vi.fn((): void => {
			activeDispatcherCount -= 1;
		});
		const dispatcherDispatch = vi.fn<(message: BridgeWorkerMainToServerMessage) => void>();
		const createDispatcher = vi.fn(
			(_props: {
				readonly publishWorkerMessages: (
					messages: readonly BridgeWorkerServerToMainMessage[],
				) => void;
			}): BridgePaneCommWorkerDispatcher => {
				activeDispatcherCount += 1;
				return { dispatch: dispatcherDispatch, dispose: dispatcherDispose };
			},
		);
		const installNativeBootstrap =
			vi.fn<(bootstrap: BridgePaneCommWorkerNativeBootstrap) => void>();
		const sessionDispose = vi.fn();
		const session: BridgePaneSessionPort = {
			createDispatcher,
			dispose: sessionDispose,
			installNativeBootstrap,
		};
		const sessionFactory = vi.fn((): BridgePaneSessionPort => session);
		const lifecycleStores: BridgeWorkerRpcLifecycleStore[] = [];
		const lifecycleStoreFactory = vi.fn((): BridgeWorkerRpcLifecycleStore => {
			const store = createBridgeWorkerRpcLifecycleStore();
			lifecycleStores.push(store);
			return store;
		});
		const renderStores: BridgeMainRenderSnapshotStore[] = [];
		const renderStoreFactory = vi.fn((): BridgeMainRenderSnapshotStore => {
			const store = createBridgeMainRenderSnapshotStore();
			renderStores.push(store);
			return store;
		});
		const runtime = createBridgePaneRuntime({
			lifecycleStoreFactory,
			renderStoreFactory,
			sessionFactory,
		});

		// Act
		const fileClientFirst = runtime.surfaceClient('fileView');
		const reviewClientFirst = runtime.surfaceClient('review');
		const fileClientSecond = runtime.surfaceClient('fileView');
		const reviewClientSecond = runtime.surfaceClient('review');

		// Assert
		expect(sessionFactory).toHaveBeenCalledOnce();
		expect(sessionFactory).toHaveBeenCalledWith();
		expect(createDispatcher).toHaveBeenCalledOnce();
		expect(activeDispatcherCount).toBe(1);
		expect(lifecycleStoreFactory).toHaveBeenCalledOnce();
		expect(renderStoreFactory).toHaveBeenCalledTimes(2);
		expect(runtime.lifecycleStore).toBe(lifecycleStores[0]);
		expect(fileClientFirst).toBe(fileClientSecond);
		expect(reviewClientFirst).toBe(reviewClientSecond);
		expect(fileClientFirst).not.toBe(reviewClientFirst);
		expect(fileClientFirst.renderStore).toBe(renderStores[0]);
		expect(reviewClientFirst.renderStore).toBe(renderStores[1]);
		expect(fileClientFirst.renderStore).not.toBe(reviewClientFirst.renderStore);
		expect(fileClientFirst.lifecycle).not.toBe(reviewClientFirst.lifecycle);
		expect(fileClientFirst).not.toHaveProperty('installNativeBootstrap');
		expect(fileClientFirst).not.toHaveProperty('productCapability');
		expect(fileClientFirst).not.toHaveProperty('bootstrap');
		expect(reviewClientFirst).not.toHaveProperty('installNativeBootstrap');
		expect(reviewClientFirst).not.toHaveProperty('productCapability');
		expect(reviewClientFirst).not.toHaveProperty('bootstrap');
		runtime.dispose();
	});

	test('accepts one native capability claim and tears down the pane exactly once', async () => {
		// Arrange
		const { createBridgePaneRuntime } = await loadBridgePaneRuntimeModule();
		let activeDispatcherCount = 0;
		const dispatcherDispose = vi.fn((): void => {
			activeDispatcherCount -= 1;
		});
		const sessionDispose = vi.fn();
		const installNativeBootstrap =
			vi.fn<(bootstrap: BridgePaneCommWorkerNativeBootstrap) => void>();
		const session: BridgePaneSessionPort = {
			createDispatcher: (): BridgePaneCommWorkerDispatcher => {
				activeDispatcherCount += 1;
				return { dispatch: vi.fn(), dispose: dispatcherDispose };
			},
			dispose: sessionDispose,
			installNativeBootstrap,
		};
		const runtime = createBridgePaneRuntime({
			sessionFactory: (): BridgePaneSessionPort => session,
		});
		const fileClient = runtime.surfaceClient('fileView');
		const firstBootstrap = makeNativeBootstrap('worker-instance-1');
		const secondBootstrap = makeNativeBootstrap('worker-instance-2');

		// Act
		runtime.installNativeBootstrap(firstBootstrap);
		let secondClaimError: unknown;
		try {
			runtime.installNativeBootstrap(secondBootstrap);
		} catch (error: unknown) {
			secondClaimError = error;
		}
		runtime.dispose();
		runtime.dispose();

		// Assert
		expect(installNativeBootstrap).toHaveBeenCalledOnce();
		expect(installNativeBootstrap).toHaveBeenCalledWith(firstBootstrap);
		expect(String(secondClaimError)).toMatch(/already|installed|claim/u);
		expect(secondBootstrap.productCapability.byteLength).toBe(
			BRIDGE_PRODUCT_CAPABILITY_BYTE_LENGTH,
		);
		expect(dispatcherDispose).toHaveBeenCalledOnce();
		expect(sessionDispose).toHaveBeenCalledOnce();
		expect(activeDispatcherCount).toBe(0);
		expect(() => fileClient.send(makeFileCommand())).toThrow(/disposed/u);
		expect(runtime.lifecycleStore.getSnapshot().requestsById).toEqual({});
	});

	test('accepts exactly one replacement bootstrap after the pane session requests it', async () => {
		// Arrange
		const { createBridgePaneRuntime } = await loadBridgePaneRuntimeModule();
		const workers = [new RecordingPaneRuntimeWorker(), new RecordingPaneRuntimeWorker()];
		const workerFactory = vi.fn((): Worker => {
			const worker = workers[workerFactory.mock.calls.length - 1];
			if (worker === undefined) throw new Error('unexpected worker factory call');
			return worker;
		});
		const runtime = createBridgePaneRuntime({
			sessionProps: {
				bootstrapTimeoutMilliseconds: pageConfigurationFixture.workerBootstrapDeadlineMilliseconds,
				workerFactory,
			},
		});
		const replacementReasons: string[] = [];
		runtime.setNativeBootstrapRequester((reason): void => {
			replacementReasons.push(reason);
		});
		const reviewClient = runtime.surfaceClient('review');
		const deliveredMessages: BridgeWorkerServerToMainMessage[] = [];
		const firstReady = createDeferredVoid();
		const replacementReady = createDeferredVoid();
		const unsubscribe = reviewClient.subscribeMessages((message): void => {
			deliveredMessages.push(message);
			if (message.kind !== 'health' || message.status !== 'ready') return;
			if (message.requestId === 'pane-runtime-bootstrap' && replacementReasons.length === 0) {
				firstReady.resolve();
			} else if (message.requestId === 'pane-runtime-bootstrap') {
				replacementReady.resolve();
			}
		});
		const firstBootstrap = makeNativeBootstrap('worker-instance-1');
		const arbitraryDuplicate = makeNativeBootstrap('worker-instance-arbitrary-duplicate');
		const replacementBootstrap = makeNativeBootstrap('worker-instance-2');
		const replacementDuplicate = makeNativeBootstrap('worker-instance-replacement-duplicate');
		let firstPortRecorder: PaneRuntimeMessagePortRecorder | null = null;
		let replacementPortRecorder: PaneRuntimeMessagePortRecorder | null = null;

		try {
			// Act: establish initial authority and reject an unsolicited duplicate.
			runtime.installNativeBootstrap(firstBootstrap);
			await flushPaneRuntimeMicrotasks();
			expect(() => runtime.installNativeBootstrap(arbitraryDuplicate)).toThrow(/already|claim/u);
			const firstInstall = bridgePaneCommWorkerInstallSchema.parse(
				workers[0]?.globalPosts[0]?.message,
			);
			firstPortRecorder = new PaneRuntimeMessagePortRecorder(firstInstall.productPort);
			await firstPortRecorder.waitForCount(1);
			firstInstall.productPort.postMessage(makePaneRuntimeReadyHealth('pane-runtime-bootstrap'));
			await firstReady.promise;

			// Act: fail the worker, queue one Review command, then install fresh authority.
			workers[0]?.dispatchEvent(new Event('error'));
			const queuedRequestId = reviewClient.send(makeReviewSelectCommandInput());
			runtime.installNativeBootstrap(replacementBootstrap);
			expect(() => runtime.installNativeBootstrap(replacementDuplicate)).toThrow(/already|claim/u);
			await flushPaneRuntimeMicrotasks();
			const replacementInstall = bridgePaneCommWorkerInstallSchema.parse(
				workers[1]?.globalPosts[0]?.message,
			);
			replacementPortRecorder = new PaneRuntimeMessagePortRecorder(replacementInstall.productPort);
			const messagesBeforeReady = await replacementPortRecorder.waitForCount(1);
			expect(messagesBeforeReady).toHaveLength(1);
			replacementInstall.productPort.postMessage(
				makePaneRuntimeReadyHealth('pane-runtime-bootstrap'),
			);
			await replacementReady.promise;
			const replacementMessages = await replacementPortRecorder.waitForCount(2);

			// Assert: replacement is single-use, the queued command posts once, and old traffic is inert.
			expect(replacementReasons).toEqual(['workerReplacement']);
			expect(workerFactory).toHaveBeenCalledTimes(2);
			expect(workers[0]?.terminateCount).toBe(1);
			expect(firstBootstrap.productCapability.byteLength).toBe(0);
			expect(arbitraryDuplicate.productCapability.byteLength).toBe(
				BRIDGE_PRODUCT_CAPABILITY_BYTE_LENGTH,
			);
			expect(replacementBootstrap.productCapability.byteLength).toBe(0);
			expect(replacementDuplicate.productCapability.byteLength).toBe(
				BRIDGE_PRODUCT_CAPABILITY_BYTE_LENGTH,
			);
			expect(
				replacementMessages.filter(
					(message): boolean =>
						typeof message === 'object' &&
						message !== null &&
						'requestId' in message &&
						message.requestId === queuedRequestId,
				),
			).toHaveLength(1);
			firstInstall.productPort.postMessage(makePaneRuntimeReadyHealth('late-old-worker'));
			await flushPaneRuntimeMicrotasks();
			expect(deliveredMessages).not.toContainEqual(
				expect.objectContaining({ requestId: 'late-old-worker' }),
			);
		} finally {
			firstPortRecorder?.close();
			replacementPortRecorder?.close();
			unsubscribe();
			runtime.dispose();
		}
	});

	test('re-anchors retained File freshness and replays current intent after replacement readiness', async () => {
		// Arrange
		const { createBridgePaneRuntime } = await loadBridgePaneRuntimeModule();
		const dispatchedMessages: BridgeWorkerMainToServerMessage[] = [];
		let publishWorkerMessages:
			| ((messages: readonly BridgeWorkerServerToMainMessage[]) => void)
			| undefined;
		let requestReplacement: ((reason: 'workerReplacement') => void) | undefined;
		const session: BridgePaneSessionPort = {
			createDispatcher: (props): BridgePaneCommWorkerDispatcher => {
				publishWorkerMessages = props.publishWorkerMessages;
				return {
					dispatch: (message): void => {
						dispatchedMessages.push(message);
					},
					dispose: vi.fn(),
				};
			},
			dispose: vi.fn(),
			installNativeBootstrap: vi.fn(),
			setNativeBootstrapRequester: (requester): void => {
				requestReplacement = requester;
			},
		};
		const runtime = createBridgePaneRuntime({
			sessionFactory: (): BridgePaneSessionPort => session,
		});
		const replacementRequests: string[] = [];
		runtime.setNativeBootstrapRequester((reason): void => {
			replacementRequests.push(reason);
		});
		runtime.installNativeBootstrap(makeNativeBootstrap('worker-instance-before-replacement'));
		const fileClient = runtime.surfaceClient('fileView');
		const reviewClient = runtime.surfaceClient('review');
		const annotationClient = createWorktreeAnnotationSurfaceClient(fileClient);
		fileClient.renderStore.applyFileDisplayPatchEvent(
			makeFileStatusPatchEvent({ epoch: 2, sequence: 2, state: 'stale' }),
		);
		reviewClient.renderStore.applyReviewDisplayPatchEvent(
			makeReviewSourceFailurePatchEvent({ epoch: 2, sequence: 2 }),
		);
		runtime.paneClient.send({
			command: 'activeViewerModeUpdate',
			epoch: 7,
			update: {
				activeSource: {
					generation: 2,
					protocol: 'worktree-file',
					streamId: 'file-stream-before-replacement',
				},
				mode: 'file',
				nativeSelectionRequestId: null,
				sequence: 1,
				sessionId: 'viewer-mode-session',
			},
		});
		fileClient.send(makeFileCommandInput());
		fileClient.send({
			command: 'select',
			epoch: 2,
			selectedItemId: 'file-item-before-replacement',
			selectedSource: 'user',
			surface: 'fileView',
		});
		reviewClient.send({
			command: 'select',
			epoch: 3,
			selectedItemId: 'review-item-before-replacement',
			selectedSource: 'user',
			surface: 'review',
		});
		const pendingInspection = annotationClient.inspectOutput(
			'00000000-0000-7000-8000-000000000001',
		);
		const pendingInspectionRequest = Object.values(
			fileClient.lifecycle.getSnapshot().requestsById,
		).find((request) => request.command === 'annotationOutputInspect');
		if (pendingInspectionRequest === undefined) {
			throw new Error('Expected a pending annotation output inspection request.');
		}
		const catalogStagingBase = {
			authority: {
				subscriptionId: 'file-annotation-subscription-before-replacement',
				workerDerivationEpoch: 2,
				worktreeId: 'worktree-1',
			},
			direction: 'serverWorkerToMain' as const,
			kind: 'annotationCatalogStaging' as const,
			operationCorrelationId: 'a'.repeat(64),
			surface: 'fileView' as const,
			transferDescriptors: [],
			wireVersion: 1 as const,
		};
		publishWorkerMessages?.([
			{
				...catalogStagingBase,
				transfer: {
					catalogRevision: 20,
					expectedEntryCount: 0,
					kind: 'catalog.begin',
					transferId: 'file-annotation-catalog-before-replacement',
				},
			},
			{
				...catalogStagingBase,
				transfer: {
					catalogRevision: 20,
					entryCount: 0,
					kind: 'catalog.commit',
					transferId: 'file-annotation-catalog-before-replacement',
					windowCount: 0,
				},
			},
		]);
		expect(annotationClient.getCatalogSnapshot().kind).toBe('current');
		dispatchedMessages.length = 0;

		// Act
		requestReplacement?.('workerReplacement');
		expect(annotationClient.getCatalogSnapshot().kind).toBe('stale');
		fileClient.send({
			command: 'select',
			epoch: 3,
			selectedItemId: 'file-item-during-replacement',
			selectedSource: 'user',
			surface: 'fileView',
		});
		runtime.installNativeBootstrap(makeNativeBootstrap('worker-instance-after-replacement'));
		publishWorkerMessages?.([makePaneRuntimeReadyHealth('pane-runtime-bootstrap')]);

		// Assert
		expect(replacementRequests).toEqual(['workerReplacement']);
		expect(
			fileClient.lifecycle.getSnapshot().requestsById[pendingInspectionRequest.requestId],
		).toMatchObject({ state: 'failed' });
		await expect(pendingInspection).rejects.toThrow(/worker.*replaced/iu);
		expect(fileClient.renderStore.getSnapshot().fileDisplayFreshness).toBeNull();
		expect(reviewClient.renderStore.getSnapshot().reviewDisplayFreshness).toBeNull();
		expect(dispatchedMessages.map((message) => message.command)).toEqual([
			'select',
			'activeViewerModeUpdate',
			'fileQueryUpdate',
			'select',
		]);
		expect(dispatchedMessages[0]).toMatchObject({
			selectedItemId: 'file-item-during-replacement',
			surface: 'fileView',
		});
		expect(dispatchedMessages[3]).toMatchObject({
			selectedItemId: 'review-item-before-replacement',
			surface: 'review',
		});
		fileClient.renderStore.applyFileDisplayPatchEvent(
			makeFileStatusPatchEvent({ epoch: 1, sequence: 1, state: 'stale' }),
		);
		reviewClient.renderStore.applyReviewDisplayPatchEvent(
			makeReviewSourceFailurePatchEvent({ epoch: 1, sequence: 1 }),
		);
		expect(fileClient.renderStore.getSnapshot().fileDisplayFreshness?.epoch).toBe(1);
		expect(reviewClient.renderStore.getSnapshot().reviewDisplayFreshness?.epoch).toBe(1);
		annotationClient.dispose();
		runtime.dispose();
	});

	test('records accepted and rejected native bootstrap install attempts without authority identity', async () => {
		// Arrange
		const { createBridgePaneRuntime } = await loadBridgePaneRuntimeModule();
		const installNativeBootstrap =
			vi.fn<(bootstrap: BridgePaneCommWorkerNativeBootstrap) => void>();
		const diagnosticSnapshots: ExpectedBridgePaneRuntimeDiagnosticSnapshot[] = [];
		const session: BridgePaneSessionPort = {
			createDispatcher: (): BridgePaneCommWorkerDispatcher => ({
				dispatch: vi.fn(),
				dispose: vi.fn(),
			}),
			dispose: vi.fn(),
			installNativeBootstrap,
		};
		const runtime = createBridgePaneRuntime({
			recordDiagnosticSnapshot: (snapshot: ExpectedBridgePaneRuntimeDiagnosticSnapshot): void => {
				diagnosticSnapshots.push(snapshot);
			},
			sessionFactory: (): BridgePaneSessionPort => session,
		});
		const acceptedBootstrap = makeNativeBootstrap('private-accepted-worker');
		const rejectedBootstrap = makeNativeBootstrap('private-rejected-worker');

		// Act
		runtime.installNativeBootstrap(acceptedBootstrap);
		expect(() => runtime.installNativeBootstrap(rejectedBootstrap)).toThrow(
			'Bridge pane runtime native capability claim was already installed.',
		);

		// Assert
		expect(installNativeBootstrap).toHaveBeenCalledOnce();
		expect(diagnosticSnapshots.at(-1)).toEqual({
			nativeBootstrapInstallAcceptedCount: 1,
			nativeBootstrapInstallAttemptCount: 2,
			nativeBootstrapInstallRejectedCount: 1,
		});
		expect(JSON.stringify(diagnosticSnapshots)).not.toContain('private-');
		runtime.dispose();
	});

	test('keeps diagnostic recording observational across runtime bootstrap, dispatch, replacement, and disposal', async () => {
		// Arrange
		const { createBridgePaneRuntime } = await loadBridgePaneRuntimeModule();
		const dispatcherDispatch = vi.fn<(message: BridgeWorkerMainToServerMessage) => void>();
		const dispatcherDispose = vi.fn();
		const installNativeBootstrap =
			vi.fn<(bootstrap: BridgePaneCommWorkerNativeBootstrap) => void>();
		const sessionDispose = vi.fn();
		let requestNativeBootstrap: ((reason: 'workerReplacement') => void) | undefined;
		const session: BridgePaneSessionPort = {
			createDispatcher: (): BridgePaneCommWorkerDispatcher => ({
				dispatch: dispatcherDispatch,
				dispose: dispatcherDispose,
			}),
			dispose: sessionDispose,
			installNativeBootstrap,
			setNativeBootstrapRequester: (requester): void => {
				requestNativeBootstrap = requester;
			},
		};
		let runtime: ReturnType<typeof createBridgePaneRuntime> | undefined;

		// Act / Assert: diagnostic failure cannot prevent runtime construction or product dispatch.
		expect((): void => {
			runtime = createBridgePaneRuntime({
				recordDiagnosticSnapshot: (): never => {
					throw new Error('diagnostic recorder failed');
				},
				sessionFactory: (): BridgePaneSessionPort => session,
			});
		}).not.toThrow();
		if (runtime === undefined) throw new Error('Bridge pane runtime was not constructed.');
		const firstBootstrap = makeNativeBootstrap('fail-open-worker-1');
		expect((): void => runtime?.installNativeBootstrap(firstBootstrap)).not.toThrow();
		runtime.surfaceClient('fileView').send(makeFileCommandInput());
		expect(dispatcherDispatch).toHaveBeenCalledOnce();

		// Act / Assert: a requested replacement still admits exactly one fresh bootstrap.
		const replacementRequester = vi.fn<(reason: 'workerReplacement') => void>();
		runtime.setNativeBootstrapRequester(replacementRequester);
		expect((): void => requestNativeBootstrap?.('workerReplacement')).not.toThrow();
		expect(replacementRequester).toHaveBeenCalledWith('workerReplacement');
		const replacementBootstrap = makeNativeBootstrap('fail-open-worker-2');
		expect((): void => runtime?.installNativeBootstrap(replacementBootstrap)).not.toThrow();
		expect(installNativeBootstrap).toHaveBeenCalledTimes(2);

		// Act / Assert: diagnostics remain unable to interrupt teardown.
		expect((): void => runtime?.dispose()).not.toThrow();
		expect(dispatcherDispose).toHaveBeenCalledOnce();
		expect(sessionDispose).toHaveBeenCalledOnce();
	});

	test('allows native capability installation to retry after the session rejects an attempt', async () => {
		// Arrange
		const { createBridgePaneRuntime } = await loadBridgePaneRuntimeModule();
		const firstBootstrap = makeNativeBootstrap('worker-instance-rejected');
		const replacementBootstrap = makeNativeBootstrap('worker-instance-replacement');
		const installNativeBootstrap = vi
			.fn<(bootstrap: BridgePaneCommWorkerNativeBootstrap) => void>()
			.mockImplementationOnce((): never => {
				throw new Error('native bootstrap rejected');
			});
		const session: BridgePaneSessionPort = {
			createDispatcher: (): BridgePaneCommWorkerDispatcher => ({
				dispatch: vi.fn(),
				dispose: vi.fn(),
			}),
			dispose: vi.fn(),
			installNativeBootstrap,
		};
		const runtime = createBridgePaneRuntime({
			sessionFactory: (): BridgePaneSessionPort => session,
		});

		// Act
		expect(() => runtime.installNativeBootstrap(firstBootstrap)).toThrow(
			'native bootstrap rejected',
		);
		const retryInstallation = (): void => runtime.installNativeBootstrap(replacementBootstrap);

		// Assert
		expect(retryInstallation).not.toThrow();
		expect(installNativeBootstrap).toHaveBeenCalledTimes(2);
		expect(installNativeBootstrap).toHaveBeenLastCalledWith(replacementBootstrap);
		runtime.dispose();
	});

	test('exposes one stable pane client for mode commands without granting surface authority', async () => {
		// Arrange
		const { createBridgePaneRuntime } = await loadBridgePaneRuntimeModule();
		const dispatch = vi.fn<(message: BridgeWorkerMainToServerMessage) => void>();
		const session: BridgePaneSessionPort = {
			createDispatcher: (): BridgePaneCommWorkerDispatcher => ({ dispatch, dispose: vi.fn() }),
			dispose: vi.fn(),
			installNativeBootstrap: vi.fn(),
		};
		const runtime = createBridgePaneRuntime({
			sessionFactory: (): BridgePaneSessionPort => session,
		});

		// Act / Assert
		expect(runtime).toMatchObject({ paneClient: expect.any(Object) });
		expect(runtime).toHaveProperty('paneClient.send', expect.any(Function));
		expect(runtime).not.toHaveProperty('paneClient.renderStore');
		expect(runtime).not.toHaveProperty('paneClient.installNativeBootstrap');
		expect(dispatch).not.toHaveBeenCalled();
		runtime.dispose();
	});

	test('routes File render-store resync through one stable File RPC client request', async () => {
		// Arrange
		const { createBridgePaneRuntime } = await loadBridgePaneRuntimeModule();
		const dispatchedMessages: BridgeWorkerMainToServerMessage[] = [];
		let publishWorkerMessages:
			| ((messages: readonly BridgeWorkerServerToMainMessage[]) => void)
			| undefined;
		const session: BridgePaneSessionPort = {
			createDispatcher: (props): BridgePaneCommWorkerDispatcher => {
				publishWorkerMessages = props.publishWorkerMessages;
				return {
					dispatch: (message): void => {
						dispatchedMessages.push(message);
					},
					dispose: vi.fn(),
				};
			},
			dispose: vi.fn(),
			installNativeBootstrap: vi.fn(),
		};
		const runtime = createBridgePaneRuntime({
			sessionFactory: (): BridgePaneSessionPort => session,
		});
		const fileClient = runtime.surfaceClient('fileView');
		fileClient.subscribeMessages((message): void => {
			if (message.kind === 'fileDisplayPatch') {
				fileClient.renderStore.applyFileDisplayPatchEvent(message);
			}
		});
		const queryPatch = makeFileQueryPatchEvent({
			epoch: 7,
			sequence: 11,
			transactionId: 'file-query-7',
		});

		// Act
		publishWorkerMessages?.([queryPatch]);
		fileClient.renderStore.completeFileQueryTransaction('wrong-query');
		fileClient.renderStore.completeFileQueryTransaction('wrong-query-again');

		// Assert
		expect(dispatchedMessages).toEqual([
			{
				command: 'fileDisplayResync',
				direction: 'mainToServerWorker',
				epoch: 7,
				kind: 'command',
				reason: 'acknowledgementMismatch',
				requestId: 'bridge-fileView-rpc-1',
				transactionId: 'file-query-7',
				transferDescriptors: [],
				wireVersion: 1,
			},
		]);
		runtime.dispose();
	});

	test('delivers each surface patch once without applying it and seals delivery on dispose', async () => {
		// Arrange
		const { createBridgePaneRuntime } = await loadBridgePaneRuntimeModule();
		let publishWorkerMessages:
			| ((messages: readonly BridgeWorkerServerToMainMessage[]) => void)
			| undefined;
		const session: BridgePaneSessionPort = {
			createDispatcher: (props): BridgePaneCommWorkerDispatcher => {
				publishWorkerMessages = props.publishWorkerMessages;
				return { dispatch: vi.fn(), dispose: vi.fn() };
			},
			dispose: vi.fn(),
			installNativeBootstrap: vi.fn(),
		};
		const runtime = createBridgePaneRuntime({
			sessionFactory: (): BridgePaneSessionPort => session,
		});
		const fileClient = runtime.surfaceClient('fileView');
		const deliveredMessages: BridgeWorkerServerToMainMessage[] = [];
		fileClient.subscribeMessages((message): void => {
			deliveredMessages.push(message);
		});
		const firstPatch = makeFileStatusPatchEvent({ epoch: 3, sequence: 21, state: 'stale' });
		const postDisposePatch = makeFileStatusPatchEvent({
			epoch: 4,
			sequence: 22,
			state: 'stale',
		});

		// Act / Assert: transport delivery is notification-only.
		publishWorkerMessages?.([firstPatch]);
		expect(deliveredMessages).toEqual([firstPatch]);
		expect(fileClient.renderStore.getSnapshot().fileStatusSlice).toBeNull();

		// Act / Assert: the surface controller is the single application owner.
		fileClient.renderStore.applyFileDisplayPatchEvent(firstPatch);
		expect(fileClient.renderStore.getSnapshot().fileStatusSlice).toEqual({ state: 'stale' });

		// Act / Assert: teardown seals subscriptions and retained state.
		runtime.dispose();
		publishWorkerMessages?.([postDisposePatch]);
		expect(deliveredMessages).toEqual([firstPatch]);
		expect(fileClient.renderStore.getSnapshot().fileStatusSlice).toBeNull();
	});

	test('teardown clears pending lifecycle listeners and retained display state', async () => {
		// Arrange
		const { createBridgePaneRuntime } = await loadBridgePaneRuntimeModule();
		const session: BridgePaneSessionPort = {
			createDispatcher: (): BridgePaneCommWorkerDispatcher => ({
				dispatch: vi.fn(),
				dispose: vi.fn(),
			}),
			dispose: vi.fn(),
			installNativeBootstrap: vi.fn(),
		};
		const runtime = createBridgePaneRuntime({
			sessionFactory: (): BridgePaneSessionPort => session,
		});
		const fileClient = runtime.surfaceClient('fileView');
		const lifecycleListener = vi.fn();
		fileClient.lifecycle.subscribe(lifecycleListener);
		fileClient.renderStore.setLocalSelection({
			selectedItemId: 'retained-file',
			source: 'user',
		});
		fileClient.send(makeFileCommandInput());
		lifecycleListener.mockClear();

		// Act
		runtime.dispose();
		runtime.lifecycleStore.startRequest({
			command: 'fileQueryUpdate',
			requestId: 'post-dispose-probe',
			surface: 'fileView',
		});

		// Assert
		expect(lifecycleListener).not.toHaveBeenCalled();
		expect(runtime.lifecycleStore.getSnapshot().requestsById).toEqual({});
		expect(fileClient.renderStore.getSnapshot().selectionSlice).toEqual({
			selectedItemId: null,
			source: null,
		});
	});
});

async function loadBridgePaneRuntimeModule(): Promise<typeof import('./bridge-pane-runtime.js')> {
	return await vi.importActual<typeof import('./bridge-pane-runtime.js')>(
		'./bridge-pane-runtime.js',
	);
}

function makeNativeBootstrap(workerInstanceId: string): BridgePaneCommWorkerNativeBootstrap {
	return {
		bootstrap: {
			kind: 'productSession.bootstrap',
			paneSessionId: 'pane-session-1',
			policy: {
				maximumContentBytes: BRIDGE_PRODUCT_MAXIMUM_CONTENT_BYTES,
				maximumMetadataFrameBytes: BRIDGE_PRODUCT_MAXIMUM_METADATA_FRAME_BYTES,
				maximumQueuedStreamBytes: BRIDGE_PRODUCT_MAXIMUM_QUEUED_STREAM_BYTES,
				admissionRetryCount: 2,
				contentAcknowledgementDeadlineMilliseconds: 5_000,
				contentProgressDeadlineMilliseconds: 5_000,
				viewBatchProgressDeadlineMilliseconds: 5_000,
				streamKeepaliveIntervalMilliseconds: 350,
				telemetryPreReadyBufferMaxBytes: 64 * 1024,
				telemetryPreReadyBufferMaxSamples: 128,
				workerSettlementDeadlineMilliseconds: 5_000,
				viewAcknowledgementDeadlineMilliseconds: 4_000,
				viewCreditBytes: 524_288,
				viewCreditParts: 8,
				viewMaximumConsecutiveResnapshots: 3,
				viewMaximumDirtyKeys: 4_096,
				maximumQueuedStreamFrames: BRIDGE_PRODUCT_MAXIMUM_QUEUED_STREAM_FRAMES,
				maximumRequestBodyBytes: BRIDGE_PRODUCT_MAXIMUM_REQUEST_BODY_BYTES,
				terminalFrameReserve: BRIDGE_PRODUCT_TERMINAL_FRAME_RESERVE,
			},
			wireVersion: BRIDGE_PRODUCT_WIRE_VERSION,
			workerInstanceId,
		},
		productCapability: new ArrayBuffer(BRIDGE_PRODUCT_CAPABILITY_BYTE_LENGTH),
	};
}

function makeFileCommand(): BridgeWorkerMainToServerMessage {
	return {
		command: 'fileQueryUpdate',
		direction: 'mainToServerWorker',
		epoch: 1,
		kind: 'command',
		query: { filterMode: 'all', searchMode: 'text', searchText: '' },
		requestId: 'file-request-1',
		transferDescriptors: [],
		wireVersion: 1,
	};
}

function makeFileCommandInput(): BridgeWorkerRpcCommandInput {
	return {
		command: 'fileQueryUpdate',
		epoch: 1,
		query: { filterMode: 'all', searchMode: 'text', searchText: '' },
	};
}

function makeReviewSelectCommandInput(): BridgeWorkerRpcCommandInput {
	return {
		command: 'select',
		epoch: 1,
		selectedItemId: 'review-item-1',
		selectedSource: 'user',
		surface: 'review',
	};
}

function makePaneRuntimeReadyHealth(requestId: string): BridgeWorkerServerToMainMessage {
	return {
		direction: 'serverWorkerToMain',
		kind: 'health',
		requestId,
		status: 'ready',
		transferDescriptors: [],
		wireVersion: 1,
	};
}

class RecordingPaneRuntimeWorker extends EventTarget implements Worker {
	onmessage: ((this: Worker, event: MessageEvent) => void) | null = null;
	onmessageerror: ((this: Worker, event: MessageEvent) => void) | null = null;
	onerror: ((this: AbstractWorker, event: ErrorEvent) => void) | null = null;
	readonly globalPosts: RecordedPaneRuntimeWorkerPost[] = [];
	terminateCount = 0;

	postMessage(message: unknown, transferList: Transferable[]): void;
	postMessage(message: unknown, options?: StructuredSerializeOptions): void;
	postMessage(
		message: unknown,
		transferListOrOptions: Transferable[] | StructuredSerializeOptions = [],
	): void {
		const transferList = Array.isArray(transferListOrOptions)
			? transferListOrOptions
			: (transferListOrOptions.transfer ?? []);
		this.globalPosts.push({
			message: structuredClone(message, { transfer: transferList }),
			transferListLength: transferList.length,
		});
	}

	terminate(): void {
		this.terminateCount += 1;
	}
}

class PaneRuntimeMessagePortRecorder {
	readonly #messages: unknown[] = [];
	readonly #port: MessagePort;
	readonly #waiters: Array<{
		readonly count: number;
		readonly resolve: (messages: readonly unknown[]) => void;
	}> = [];

	constructor(port: MessagePort) {
		this.#port = port;
		port.addEventListener('message', (event: MessageEvent<unknown>): void => {
			this.#messages.push(event.data);
			this.#resolveWaiters();
		});
		port.start();
	}

	waitForCount(count: number): Promise<readonly unknown[]> {
		if (this.#messages.length >= count) return Promise.resolve([...this.#messages]);
		return new Promise((resolve) => {
			this.#waiters.push({ count, resolve });
		});
	}

	close(): void {
		this.#port.close();
	}

	#resolveWaiters(): void {
		for (let index = this.#waiters.length - 1; index >= 0; index -= 1) {
			const waiter = this.#waiters[index];
			if (waiter !== undefined && this.#messages.length >= waiter.count) {
				this.#waiters.splice(index, 1);
				waiter.resolve([...this.#messages]);
			}
		}
	}
}

async function flushPaneRuntimeMicrotasks(): Promise<void> {
	await Promise.resolve();
	await Promise.resolve();
	await Promise.resolve();
}

function createDeferredVoid(): { readonly promise: Promise<void>; readonly resolve: () => void } {
	let resolvePromise: (() => void) | null = null;
	const promise = new Promise<void>((resolve): void => {
		resolvePromise = resolve;
	});
	return {
		promise,
		resolve: (): void => {
			if (resolvePromise === null) throw new Error('deferred resolver was not initialized');
			resolvePromise();
		},
	};
}

function makeFileQueryPatchEvent(props: {
	readonly epoch: number;
	readonly sequence: number;
	readonly transactionId: string;
}): BridgeWorkerFileDisplayPatchEvent {
	return {
		direction: 'serverWorkerToMain',
		epoch: props.epoch,
		kind: 'fileDisplayPatch',
		patches: [
			{
				operation: 'upsert',
				payload: {
					filterMode: 'all',
					projectedRowCount: 0,
					searchError: null,
					searchMode: 'text',
					searchText: '',
					totalRowCount: 0,
				},
				slice: 'fileQuery',
			},
		],
		projectionRevision: props.sequence,
		queryTransaction: {
			batchCount: 1,
			batchIndex: 0,
			phase: 'batch',
			transactionId: props.transactionId,
		},
		sequence: props.sequence,
		surface: 'fileView',
		transferDescriptors: [],
		wireVersion: 1,
	};
}

function makeFileStatusPatchEvent(props: {
	readonly epoch: number;
	readonly sequence: number;
	readonly state: 'stale';
}): BridgeWorkerFileDisplayPatchEvent {
	return {
		direction: 'serverWorkerToMain',
		epoch: props.epoch,
		kind: 'fileDisplayPatch',
		patches: [
			{
				operation: 'upsert',
				payload: { state: props.state },
				slice: 'fileStatus',
			},
		],
		projectionRevision: props.sequence,
		sequence: props.sequence,
		surface: 'fileView',
		transferDescriptors: [],
		wireVersion: 1,
	};
}

function makeReviewSourceFailurePatchEvent(props: {
	readonly epoch: number;
	readonly sequence: number;
}): BridgeWorkerReviewDisplayPatchEvent {
	return {
		direction: 'serverWorkerToMain',
		epoch: props.epoch,
		kind: 'reviewDisplayPatch',
		reviewPublicationIdentity: null,
		patches: [
			{
				operation: 'failed',
				payload: { error: 'metadataUnavailable', status: 'failed' },
				slice: 'reviewSource',
			},
		],
		projectionRevision: props.sequence,
		sequence: props.sequence,
		surface: 'review',
		transferDescriptors: [],
		wireVersion: 1,
	};
}
