// oxlint-disable unicorn/require-post-message-target-origin -- MessagePort postMessage does not accept a target origin.
import { afterEach, describe, expect, test, vi } from 'vitest';

import { bridgeTelemetryWorkerProducerMessageSchema } from '../telemetry-worker/bridge-telemetry-worker-contracts.js';
import {
	type BridgeCommWorkerPort,
	bootstrapBridgeCommWorkerEntry,
	type BridgeCommWorkerInstalledProductSession,
	registerBridgeCommWorkerEntry,
	registerInertBridgeCommWorkerPortProtocol,
} from './bridge-comm-worker-entry.js';
import {
	createEntryProductRequestRecorder,
	fileActiveViewerModeUpdate,
	makeCompletedReviewContentStream,
	makePaneWorkerInstall,
	makeReviewContentRuntimeSource,
	makeBootstrapRequest,
	readyHealth,
} from './bridge-comm-worker-entry.test-support.js';
import {
	encodeBridgeWorkerActiveViewerModeUpdateCommand,
	encodeBridgeWorkerMarkFileViewedCommand,
	encodeBridgeWorkerSelectCommand,
} from './bridge-comm-worker-protocol.js';
import {
	createIdleWorktreeAnnotationSubscription,
	createBridgeCommWorkerReviewProductTestSource,
	flushBridgeWorkerRuntimeContinuations,
} from './bridge-comm-worker-runtime-protocol.test-support.js';
import { executeAgentStudioBridgeProductRequest } from './bridge-product-agent-studio-request-executor.js';
import { bridgeProductBatchFrameSchema } from './bridge-product-batch-wire-contracts.js';
import { BRIDGE_PRODUCT_WIRE_VERSION } from './bridge-product-contract-primitives.js';
import type { BridgeProductMetadataApplicationProtocolIdentity } from './bridge-product-metadata-application-protocol.js';
import { bridgeProductControlRequestSchema } from './bridge-product-session-contracts.js';
import type { BridgeProductTransportSession } from './bridge-product-transport.js';
import { createTestMetadataReopenPort } from './bridge-product-view-reopen.test-support.js';
import {
	BRIDGE_WORKER_WIRE_VERSION,
	bridgeWorkerServerToMainWireMessageSchema,
	type BridgeWorkerServerToMainWireMessage,
	type BridgeWorkerServerToMainMessage,
	type BridgeWorkerViewRecoveryStatusEvent,
} from './bridge-worker-contracts.js';
import {
	metadataAccepted,
	subscriptionAccepted,
	TestProductServer,
} from './test-fixtures/bridge-product-transport-metadata.test-support.js';

interface PostedBridgeWorkerMessage {
	readonly message: BridgeWorkerServerToMainMessage;
	readonly transferList: readonly Transferable[] | undefined;
}

interface InstalledBridgeCommWorkerEntryHarness {
	readonly close: () => void;
	readonly globalPostedMessages: readonly PostedBridgeWorkerMessage[];
	readonly globalStarted: () => boolean;
	readonly publishViewRecoveryStatus: (
		status: Pick<BridgeWorkerViewRecoveryStatusEvent, 'status' | 'view'>,
	) => void;
	readonly productPort: BridgeWorkerMessagePortRecorder;
}

const activeInstalledEntryHarnesses = new Set<InstalledBridgeCommWorkerEntryHarness>();

describe('Bridge comm worker entry', () => {
	afterEach(() => {
		for (const harness of activeInstalledEntryHarnesses) {
			harness.close();
		}
		vi.restoreAllMocks();
		vi.useRealTimers();
	});

	test('preserves inert ready health replies on the one-argument post path', () => {
		const { dispatch, postedMessages, started } = createRecordingBridgeCommWorkerPort();
		registerInertBridgeCommWorkerPortProtocol(dispatch.port);

		dispatch.message({
			wireVersion: 1,
			direction: 'mainToServerWorker',
			kind: 'command',
			command: 'select',
			requestId: 'request-1',
			epoch: 0,
			transferDescriptors: [],
			surface: 'review',
			selectedItemId: 'item-1',
			selectedSource: 'user',
		});

		expect(started()).toBe(true);
		expect(postedMessages).toEqual([
			{
				message: readyHealth('request-1'),
				transferList: undefined,
			},
		]);
	});

	test('preserves inert degraded health replies for invalid messages', () => {
		const { dispatch, postedMessages } = createRecordingBridgeCommWorkerPort();
		registerInertBridgeCommWorkerPortProtocol(dispatch.port);

		dispatch.message({ kind: 'not-a-bridge-worker-message' });

		expect(postedMessages).toEqual([
			{
				message: {
					wireVersion: 1,
					direction: 'serverWorkerToMain',
					kind: 'health',
					status: 'degraded',
					message: 'Bridge comm worker received invalid message.',
					transferDescriptors: [],
				},
				transferList: undefined,
			},
		]);
	});

	test('degrades commands received before runtime bootstrap', async () => {
		const harness = createInstalledBridgeCommWorkerEntryHarness();

		harness.productPort.postMessage(
			encodeBridgeWorkerSelectCommand({
				requestId: 'request-before-bootstrap',
				epoch: 1,
				surface: 'review',
				selectedItemId: 'item-1',
				selectedSource: 'user',
			}),
		);
		const postedMessages = await harness.productPort.waitForCount(1);

		try {
			expect(harness.globalPostedMessages).toEqual([]);
			expect(postedMessages).toEqual([
				{
					wireVersion: 1,
					direction: 'serverWorkerToMain',
					kind: 'health',
					requestId: 'request-before-bootstrap',
					status: 'degraded',
					message: 'Bridge comm worker command received before bootstrap.',
					transferDescriptors: [],
				},
			]);
		} finally {
			harness.close();
		}
	});

	test('bootstraps the runtime protocol before accepting commands', async () => {
		const harness = createInstalledBridgeCommWorkerEntryHarness();

		harness.productPort.postMessage(makeBootstrapRequest('bootstrap-request-1'));
		await harness.productPort.waitForCount(1);
		harness.productPort.postMessage(fileActiveViewerModeUpdate('entry-bootstrap', 1));
		await harness.productPort.waitForCount(2);
		harness.productPort.postMessage(
			encodeBridgeWorkerSelectCommand({
				requestId: 'request-after-bootstrap',
				epoch: 2,
				surface: 'review',
				selectedItemId: 'item-1',
				selectedSource: 'user',
			}),
		);
		await harness.productPort.waitFor(
			(message) => message.kind === 'health' && message.requestId === 'request-after-bootstrap',
		);
		const postedMessages = harness.productPort.getSnapshotMessages();

		try {
			expect(harness.globalStarted()).toBe(true);
			expect(harness.globalPostedMessages).toEqual([]);
			expect(postedMessages).toEqual([
				readyHealth('bootstrap-request-1'),
				noFileSourceDisplay(1),
				readyHealth('request-file-mode-entry-bootstrap'),
				{
					wireVersion: 1,
					direction: 'serverWorkerToMain',
					kind: 'slicePatch',
					epoch: 2,
					sequence: 2,
					transferDescriptors: [],
					patches: [
						{
							slice: 'selection',
							operation: 'upsert',
							payload: {
								selectedItemId: 'item-1',
							},
						},
						{
							slice: 'contentAvailability',
							operation: 'upsert',
							itemId: 'item-1',
							payload: {
								state: 'unavailable',
							},
						},
					],
				},
				readyHealth('request-after-bootstrap'),
			]);
		} finally {
			harness.close();
		}
	});

	test('posts view recovery status on the installed product port', async () => {
		const harness = createInstalledBridgeCommWorkerEntryHarness();
		try {
			harness.publishViewRecoveryStatus({
				status: 'failedRetryable',
				view: { kind: 'file.metadata', subscriptionId: 'file-view-recovery-1' },
			});
			const postedMessages = await harness.productPort.waitForCount(1);

			expect(postedMessages).toEqual([
				{
					wireVersion: BRIDGE_WORKER_WIRE_VERSION,
					direction: 'serverWorkerToMain',
					transferDescriptors: [],
					kind: 'viewRecoveryStatus',
					view: { kind: 'file.metadata', subscriptionId: 'file-view-recovery-1' },
					status: 'failedRetryable',
				},
			]);
			expect(harness.globalPostedMessages).toEqual([]);
		} finally {
			harness.close();
		}
	});

	test('real worker entry publishes W2 budget exhaustion on the product port', async () => {
		const server = new TestProductServer();
		vi.spyOn(globalThis, 'fetch').mockImplementation(server.fetch);
		const globalPort = createRecordingBridgeCommWorkerPort();
		const productChannel = new MessageChannel();
		const productPort = new BridgeWorkerMessagePortRecorder(productChannel.port2);
		registerBridgeCommWorkerEntry(globalPort.dispatch.port, {
			executeProductRequest: executeAgentStudioBridgeProductRequest,
		});
		globalPort.dispatch.message(makePaneWorkerInstall(productChannel.port1));
		try {
			productPort.postMessage(makeBootstrapRequest('recovery-bootstrap'));
			await productPort.waitForCount(1);
			productPort.postMessage(fileActiveViewerModeUpdate('recovery', 1));
			const stream = await server.waitForMetadataStreamOpened();
			server.emitMetadata(metadataAccepted(stream, 0));
			const open = await server.waitForControlRequestWhere(
				(request) =>
					request.kind === 'subscription.open' &&
					request.subscription.subscriptionKind === 'file.metadata',
			);
			if (open.kind !== 'subscription.open') throw new Error('Expected File subscription opening.');
			expect(open.subscription.subscriptionKind).toBe('file.metadata');
			server.emitMetadata(
				subscriptionAccepted({
					epoch: open.workerDerivationEpoch,
					kind: 'file.metadata',
					request: stream,
					streamSequence: 1,
					subscriptionId: open.subscriptionId,
				}),
			);
			const scope = await server.waitForControlRequestWhere(
				(request) =>
					request.kind === 'subscription.setScope' &&
					request.subscriptionId === open.subscriptionId,
			);
			if (scope.kind !== 'subscription.setScope') throw new Error('Expected File scope.');
			expect(scope.subscriptionKind).toBe('file.metadata');
			const recoveryStatus = productPort.waitForViewRecoveryStatus('failedRetryable');
			for (let index = 0; index < 4; index += 1) {
				server.emitMetadata(
					bridgeProductBatchFrameSchema.parse({
						baseRevision: 0,
						batchId: `entry-recovery-${index}`,
						domain: scope.domain,
						handle: scope.handle,
						incarnation: scope.incarnation,
						kind: 'subscription.batchBegin',
						metadataStreamId: stream.metadataStreamId,
						mode: 'snapshot',
						snapshotCause: 'open',
						paneSessionId: stream.paneSessionId,
						partCount: 0,
						scope: scope.scope,
						scopeRevision: scope.scopeRevision,
						streamSequence: index + 2,
						subscriptionId: open.subscriptionId,
						subscriptionKind: 'file.metadata',
						targetRevision: 1,
						wireVersion: stream.wireVersion,
						workerInstanceId: stream.workerInstanceId,
					}),
				);
			}
			expect(await recoveryStatus).toMatchObject({
				status: 'failedRetryable',
				view: { kind: 'file.metadata', subscriptionId: open.subscriptionId },
			});
		} finally {
			server.shutdown();
			productPort.close();
			productChannel.port1.close();
		}
	});

	test('does not construct a comm-worker telemetry network fallback', async () => {
		const fetchSpy = vi.spyOn(globalThis, 'fetch');
		const harness = createInstalledBridgeCommWorkerEntryHarness();

		harness.productPort.postMessage(makeBootstrapRequest('bootstrap-request-telemetry'));
		await harness.productPort.waitForCount(1);
		harness.productPort.postMessage(
			encodeBridgeWorkerSelectCommand({
				requestId: 'request-after-telemetry-bootstrap',
				epoch: 2,
				issuedAtMilliseconds: 0,
				surface: 'review',
				selectedItemId: 'item-1',
				selectedSource: 'user',
			}),
		);
		await harness.productPort.waitForCount(3);

		try {
			expect(harness.globalPostedMessages).toEqual([]);
			expect(fetchSpy).not.toHaveBeenCalled();
		} finally {
			harness.close();
		}
	});

	test('drains required worker samples recorded before telemetry producer install', async () => {
		const globalPort = createRecordingBridgeCommWorkerPort();
		const productChannel = new MessageChannel();
		const productPort = new BridgeWorkerMessagePortRecorder(productChannel.port2);
		const telemetryChannel = new MessageChannel();
		const received: unknown[] = [];
		const barrierReceived = new Promise<void>((resolve): void => {
			telemetryChannel.port2.addEventListener('message', (event: MessageEvent<unknown>): void => {
				const message = bridgeTelemetryWorkerProducerMessageSchema.parse(event.data);
				received.push(message);
				if (message.type === 'producer.barrier.receipt') resolve();
			});
			telemetryChannel.port2.start();
		});
		bootstrapBridgeCommWorkerEntry(globalPort.dispatch.port, {
			installProductSession: (): BridgeCommWorkerInstalledProductSession => ({
				open: Promise.resolve(),
				productTransport: makeUnavailableFileProductTransport(),
			}),
		});
		try {
			globalPort.dispatch.message(makePaneWorkerInstall(productChannel.port1, 1));
			productPort.postMessage(makeBootstrapRequest('bootstrap-before-telemetry'));
			await productPort.waitForCount(1);
			productPort.postMessage(fileActiveViewerModeUpdate('mode-before-telemetry', 1));
			await productPort.waitForCount(2);
			globalPort.dispatch.message({
				type: 'bridgePaneCommWorker.telemetryProducer.install',
				enabledScopes: ['web'],
				preReadyRequiredSampleCapacity: 1,
				preReadyRequiredSampleMaxEncodedBytes: 64 * 1024,
				producerPort: telemetryChannel.port1,
			});
			telemetryChannel.port2.postMessage({
				type: 'producer.ready',
				generation: 1,
				initialSampleCredits: 128,
				initialControlCredits: 4,
			});
			telemetryChannel.port2.postMessage({
				type: 'producer.barrier.request',
				barrierId: 'pre-install-barrier',
				generation: 1,
			});
			await barrierReceived;
			expect(
				received.some(
					(message) =>
						typeof message === 'object' &&
						message !== null &&
						Reflect.get(message, 'type') === 'sample',
				),
			).toBe(true);
			expect(received).toContainEqual(
				expect.objectContaining({
					type: 'loss.summary',
					reason: 'queue_saturated',
					requiredCount: expect.any(Number),
				}),
			);
		} finally {
			productPort.close();
			productChannel.port1.close();
			telemetryChannel.port1.close();
			telemetryChannel.port2.close();
		}
	});

	test('production entry opens Review content through product transport without legacy fetchContent', async () => {
		const openedContentKinds: string[] = [];
		const reviewProductSource = createBridgeCommWorkerReviewProductTestSource();
		const productTransport: BridgeProductTransportSession = {
			...reviewProductSource.productTransport,
			openContent: (descriptor): never => {
				openedContentKinds.push(descriptor.contentKind);
				if (descriptor.contentKind !== 'review.content') {
					throw new Error(`Unexpected typed content kind ${descriptor.contentKind}.`);
				}
				return makeCompletedReviewContentStream(descriptor) as never;
			},
		};
		const harness = createInstalledBridgeCommWorkerEntryHarness(productTransport);

		try {
			// Act
			harness.productPort.postMessage(makeBootstrapRequest('review-content-bootstrap'));
			await harness.productPort.waitForCount(1);
			harness.productPort.postMessage(
				encodeBridgeWorkerActiveViewerModeUpdateCommand({
					epoch: 1,
					requestId: 'review-content-active-viewer-mode',
					update: {
						activeSource: null,
						mode: 'review',
						nativeSelectionRequestId: null,
						sequence: 1,
						sessionId: 'review-content-session',
					},
				}),
			);
			await harness.productPort.waitForCount(2);
			await flushBridgeWorkerRuntimeContinuations();
			reviewProductSource.publishSource(makeReviewContentRuntimeSource(), 6);
			await flushBridgeWorkerRuntimeContinuations();
			await harness.productPort.waitForCount(3);
			harness.productPort.postMessage(
				encodeBridgeWorkerSelectCommand({
					requestId: 'review-content-select',
					epoch: 7,
					surface: 'review',
					selectedItemId: 'item-1',
					selectedSource: 'user',
				}),
			);
			await harness.productPort.waitForCount(6);

			// Assert
			expect(openedContentKinds).toEqual(['review.content', 'review.content']);
		} finally {
			reviewProductSource.close();
			harness.close();
		}
	});

	test('carries mark-viewed through the installed capability-bound product session', async () => {
		// Arrange
		const productRequests = createEntryProductRequestRecorder();
		const fetchSpy = vi.spyOn(globalThis, 'fetch').mockImplementation(productRequests.respond);
		const globalPort = createRecordingBridgeCommWorkerPort();
		const productChannel = new MessageChannel();
		const productPort = new BridgeWorkerMessagePortRecorder(productChannel.port2);
		registerBridgeCommWorkerEntry(globalPort.dispatch.port, {
			executeProductRequest: executeAgentStudioBridgeProductRequest,
		});
		globalPort.dispatch.message(makePaneWorkerInstall(productChannel.port1));
		// Act
		productChannel.port2.postMessage(makeBootstrapRequest('product-chain-bootstrap'));
		await productPort.waitForCount(1);
		productChannel.port2.postMessage(fileActiveViewerModeUpdate('product-chain', 1));
		await productPort.waitForCount(2);
		productChannel.port2.postMessage(
			encodeBridgeWorkerMarkFileViewedCommand({
				epoch: 4,
				fileId: 'item-1',
				requestId: 'mark-viewed-product-chain',
			}),
		);
		const markViewedHealth = await productPort.waitFor(
			(message) => message.kind === 'health' && message.requestId === 'mark-viewed-product-chain',
		);
		// Assert
		expect(markViewedHealth).toMatchObject({
			kind: 'health',
			requestId: 'mark-viewed-product-chain',
			status: 'ready',
		});
		expect(fetchSpy).toHaveBeenCalledTimes(productRequests.observedBodies.length * 3 + 1);
		expect(productRequests.observedResultReads).toHaveLength(productRequests.observedBodies.length);
		expect(productRequests.observedResultAcknowledgements).toEqual(
			productRequests.observedResultReads,
		);
		expect(productRequests.observedMetadataStreamRequests).toEqual([
			expect.objectContaining({
				kind: 'metadataStream.open',
				resumeFromStreamSequence: null,
				wireVersion: BRIDGE_PRODUCT_WIRE_VERSION,
			}),
		]);
		expect(productRequests.observedBodies).toEqual([
			expect.objectContaining({ kind: 'workerSession.open', requestSequence: 1 }),
			expect.objectContaining({
				call: expect.objectContaining({ method: 'file.activeViewerMode.update' }),
				kind: 'product.call',
				requestSequence: expect.any(Number),
			}),
			expect.objectContaining({
				call: { method: 'file.source.current', request: {} },
				kind: 'product.call',
				requestSequence: expect.any(Number),
			}),
			expect.objectContaining({
				call: expect.objectContaining({ method: 'review.intake.ready' }),
				kind: 'product.call',
				requestSequence: expect.any(Number),
			}),
			expect.objectContaining({
				call: { method: 'review.markFileViewed', request: { itemId: 'item-1' } },
				kind: 'product.call',
				requestSequence: expect.any(Number),
			}),
		]);
		const controlSequences = productRequests.observedBodies.map(
			(body) => bridgeProductControlRequestSchema.parse(body).requestSequence,
		);
		expect(controlSequences).toEqual([...controlSequences].sort((left, right) => left - right));

		productPort.close();
		productChannel.port1.close();
	});

	test('replays commands that arrived before runtime bootstrap', async () => {
		const harness = createInstalledBridgeCommWorkerEntryHarness();

		harness.productPort.postMessage(fileActiveViewerModeUpdate('before-bootstrap', 1));
		await harness.productPort.waitForCount(1);
		harness.productPort.postMessage(
			encodeBridgeWorkerSelectCommand({
				requestId: 'request-before-bootstrap',
				epoch: 3,
				surface: 'review',
				selectedItemId: 'item-1',
				selectedSource: 'user',
			}),
		);
		await harness.productPort.waitForCount(2);
		harness.productPort.postMessage(makeBootstrapRequest('bootstrap-request-1'));
		await harness.productPort.waitFor(
			(message) =>
				message.kind === 'health' &&
				message.requestId === 'request-file-mode-before-bootstrap' &&
				message.status === 'ready',
		);
		const postedMessages = harness.productPort.getSnapshotMessages();

		try {
			expect(harness.globalPostedMessages).toEqual([]);
			expect(postedMessages).toEqual([
				{
					wireVersion: 1,
					direction: 'serverWorkerToMain',
					kind: 'health',
					requestId: 'request-file-mode-before-bootstrap',
					status: 'degraded',
					message: 'Bridge comm worker command received before bootstrap.',
					transferDescriptors: [],
				},
				{
					wireVersion: 1,
					direction: 'serverWorkerToMain',
					kind: 'health',
					requestId: 'request-before-bootstrap',
					status: 'degraded',
					message: 'Bridge comm worker command received before bootstrap.',
					transferDescriptors: [],
				},
				readyHealth('bootstrap-request-1'),
				{
					wireVersion: 1,
					direction: 'serverWorkerToMain',
					kind: 'slicePatch',
					epoch: 3,
					sequence: 1,
					transferDescriptors: [],
					patches: [
						{
							slice: 'selection',
							operation: 'upsert',
							payload: {
								selectedItemId: 'item-1',
							},
						},
						{
							slice: 'contentAvailability',
							operation: 'upsert',
							itemId: 'item-1',
							payload: {
								state: 'unavailable',
							},
						},
					],
				},
				readyHealth('request-before-bootstrap'),
				noFileSourceDisplay(2),
				readyHealth('request-file-mode-before-bootstrap'),
			]);
		} finally {
			harness.close();
		}
	});

	test('rejects duplicate bootstrap requests after runtime ownership is installed', async () => {
		const harness = createInstalledBridgeCommWorkerEntryHarness();

		harness.productPort.postMessage(makeBootstrapRequest('bootstrap-request-1'));
		await harness.productPort.waitForCount(1);
		harness.productPort.postMessage(fileActiveViewerModeUpdate('duplicate-bootstrap', 1));
		await harness.productPort.waitFor(
			(message) =>
				message.kind === 'health' && message.requestId === 'request-file-mode-duplicate-bootstrap',
		);
		harness.productPort.postMessage(makeBootstrapRequest('bootstrap-request-2'));
		await harness.productPort.waitFor(
			(message) => message.kind === 'health' && message.requestId === 'bootstrap-request-2',
		);
		const postedMessages = harness.productPort.getSnapshotMessages();

		try {
			expect(harness.globalPostedMessages).toEqual([]);
			expect(postedMessages).toEqual([
				readyHealth('bootstrap-request-1'),
				noFileSourceDisplay(1),
				readyHealth('request-file-mode-duplicate-bootstrap'),
				{
					wireVersion: 1,
					direction: 'serverWorkerToMain',
					kind: 'health',
					requestId: 'bootstrap-request-2',
					status: 'degraded',
					message: 'Bridge comm worker runtime was already bootstrapped.',
					transferDescriptors: [],
				},
			]);
		} finally {
			harness.close();
		}
	});
});

function noFileSourceDisplay(sequence: number): BridgeWorkerServerToMainWireMessage {
	return {
		wireVersion: 1,
		direction: 'serverWorkerToMain',
		kind: 'fileDisplayPatch',
		epoch: 0,
		surface: 'fileView',
		sequence,
		projectionRevision: 1,
		transferDescriptors: [],
		patches: [{ operation: 'upsert', slice: 'fileStatus', payload: { state: 'noSource' } }],
	};
}

function createInstalledBridgeCommWorkerEntryHarness(
	productTransport: BridgeProductTransportSession = makeUnavailableFileProductTransport(),
): InstalledBridgeCommWorkerEntryHarness {
	const globalPort = createRecordingBridgeCommWorkerPort();
	const productChannel = new MessageChannel();
	const productPort = new BridgeWorkerMessagePortRecorder(productChannel.port2);
	let publishViewRecoveryStatus:
		| ((status: Pick<BridgeWorkerViewRecoveryStatusEvent, 'status' | 'view'>) => void)
		| undefined;
	let didClose = false;
	bootstrapBridgeCommWorkerEntry(globalPort.dispatch.port, {
		installProductSession: (input): BridgeCommWorkerInstalledProductSession => {
			const open = Promise.resolve();
			publishViewRecoveryStatus = input.publishViewRecoveryStatus;
			return {
				open,
				productTransport,
			};
		},
	});
	globalPort.dispatch.message(makePaneWorkerInstall(productChannel.port1));
	const harness: InstalledBridgeCommWorkerEntryHarness = {
		close: (): void => {
			if (didClose) {
				return;
			}
			didClose = true;
			productPort.close();
			productChannel.port1.close();
			activeInstalledEntryHarnesses.delete(harness);
		},
		globalPostedMessages: globalPort.postedMessages,
		globalStarted: globalPort.started,
		publishViewRecoveryStatus: (status): void => {
			if (publishViewRecoveryStatus === undefined) {
				throw new Error(
					'Expected the installed entry to provide a view recovery status publisher.',
				);
			}
			publishViewRecoveryStatus(status);
		},
		productPort,
	};
	if (publishViewRecoveryStatus === undefined) {
		harness.close();
		throw new Error('Expected the installed entry to provide a view recovery status publisher.');
	}
	activeInstalledEntryHarnesses.add(harness);
	return { ...harness, publishViewRecoveryStatus };
}

function makeUnavailableFileProductTransport(): BridgeProductTransportSession {
	const workerDerivationEpochs = { file: 0, review: 0 };
	return {
		...createTestMetadataReopenPort(),
		advanceWorkerDerivationEpoch: (surface): number => {
			workerDerivationEpochs[surface] += 1;
			return workerDerivationEpochs[surface];
		},
		call: async (...arguments_): Promise<never> => {
			const [method] = arguments_;
			if (
				method === 'file.activeViewerMode.update' ||
				method === 'review.activeViewerMode.update' ||
				method === 'review.intake.ready'
			) {
				return null as never;
			}
			if (method !== 'file.source.current') {
				throw new Error(`Unexpected product call in entry harness: ${method}.`);
			}
			return {
				reason: 'no-file-source-authority',
				status: 'unavailable',
			} as never;
		},
		openContent: (): never => {
			throw new Error('Entry harness cannot open content without a File source.');
		},
		// oxlint-disable-next-line typescript/no-unsafe-type-assertion -- The entry harness supports only annotation notification subscriptions.
		subscribe: ((protocol: BridgeProductMetadataApplicationProtocolIdentity): never => {
			const subscriptionKind = protocol.kind;
			if (subscriptionKind === 'file.annotations' || subscriptionKind === 'review.annotations') {
				// oxlint-disable-next-line typescript/no-unsafe-type-assertion -- The branch closes over the requested annotation subscription kind.
				return createIdleWorktreeAnnotationSubscription(protocol) as never;
			}
			throw new Error('Entry harness cannot subscribe without a File source.');
		}) as BridgeProductTransportSession['subscribe'],
		workerDerivationEpoch: (surface): number => workerDerivationEpochs[surface],
	};
}

// oxlint-disable unicorn/require-post-message-target-origin -- MessagePort postMessage does not accept a target origin.
class BridgeWorkerMessagePortRecorder {
	readonly #messages: BridgeWorkerServerToMainWireMessage[] = [];
	readonly #port: MessagePort;
	readonly #messageWaiters: Array<{
		readonly matches: (message: BridgeWorkerServerToMainWireMessage) => boolean;
		readonly resolve: (message: BridgeWorkerServerToMainWireMessage) => void;
	}> = [];
	readonly #waiters: Array<{
		readonly count: number;
		readonly resolve: (messages: readonly BridgeWorkerServerToMainWireMessage[]) => void;
	}> = [];

	constructor(port: MessagePort) {
		this.#port = port;
		this.#port.addEventListener('message', (event: MessageEvent<unknown>): void => {
			const message = bridgeWorkerServerToMainWireMessageSchema.parse(event.data);
			this.#messages.push(message);
			for (const waiter of this.#messageWaiters.filter((candidate) => candidate.matches(message))) {
				waiter.resolve(message);
			}
			this.#messageWaiters.splice(
				0,
				this.#messageWaiters.length,
				...this.#messageWaiters.filter((candidate) => !candidate.matches(message)),
			);
			this.#resolveWaiters();
		});
		this.#port.start();
	}

	postMessage(message: unknown): void {
		this.#port.postMessage(message);
	}

	getSnapshotMessages(): readonly BridgeWorkerServerToMainWireMessage[] {
		return [...this.#messages];
	}

	waitForCount(count: number): Promise<readonly BridgeWorkerServerToMainWireMessage[]> {
		if (this.#messages.length >= count) return Promise.resolve([...this.#messages]);
		return new Promise((resolve): void => {
			this.#waiters.push({ count, resolve });
		});
	}

	waitFor(
		matches: (message: BridgeWorkerServerToMainWireMessage) => boolean,
	): Promise<BridgeWorkerServerToMainWireMessage> {
		const existing = this.#messages.find(matches);
		if (existing !== undefined) return Promise.resolve(existing);
		return new Promise((resolve): void => {
			this.#messageWaiters.push({ matches, resolve });
		});
	}

	waitForViewRecoveryStatus(
		status: BridgeWorkerViewRecoveryStatusEvent['status'],
	): Promise<BridgeWorkerViewRecoveryStatusEvent> {
		const matches = (message: BridgeWorkerServerToMainWireMessage): boolean =>
			message.kind === 'viewRecoveryStatus' && message.status === status;
		const existing = this.#messages.find(matches);
		if (existing?.kind === 'viewRecoveryStatus') return Promise.resolve(existing);
		return new Promise((resolve): void => {
			this.#messageWaiters.push({
				matches,
				resolve: (message): void => {
					if (message.kind === 'viewRecoveryStatus') resolve(message);
				},
			});
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

function createRecordingBridgeCommWorkerPort(): {
	readonly dispatch: {
		readonly message: (data: unknown) => void;
		readonly port: BridgeCommWorkerPort;
	};
	readonly postedMessages: PostedBridgeWorkerMessage[];
	readonly started: () => boolean;
} {
	const postedMessages: PostedBridgeWorkerMessage[] = [];
	const eventTarget = new EventTarget();
	let didStart = false;
	return {
		dispatch: {
			message: (data: unknown): void => {
				eventTarget.dispatchEvent(new MessageEvent('message', { data }));
			},
			port: {
				postMessage: (
					message: BridgeWorkerServerToMainMessage,
					transferList?: Transferable[],
				): void => {
					postedMessages.push({ message, transferList });
				},
				addEventListener: (
					type: 'message',
					nextListener: (event: MessageEvent<unknown>) => void,
				): void => {
					expect(type).toBe('message');
					eventTarget.addEventListener(type, (event: Event): void => {
						if (event instanceof MessageEvent) {
							nextListener(event);
						}
					});
				},
				dispatchEvent: (event: Event): boolean => eventTarget.dispatchEvent(event),
				start: (): void => {
					didStart = true;
				},
			},
		},
		postedMessages,
		started: (): boolean => didStart,
	};
}
