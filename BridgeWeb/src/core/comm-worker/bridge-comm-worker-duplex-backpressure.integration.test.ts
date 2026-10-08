import { afterEach, describe, expect, test } from 'vitest';

import {
	encodeBridgeWorkerActiveViewerModeUpdateCommand,
	encodeBridgeWorkerRenderDispositionCommand,
	encodeBridgeWorkerSelectCommand,
} from './bridge-comm-worker-protocol.js';
import { registerBridgeCommWorkerRuntimePortProtocol } from './bridge-comm-worker-runtime-protocol.js';
import {
	createBridgeCommWorkerReviewProductTestSource,
	makeContentRequestDescriptor,
	makeRenderSemantics,
	makeWorkerReviewContentMetadata,
	openReviewContentFromDescriptorMap,
	type BridgeCommWorkerReviewProductTestSource,
	type FileMetadataSubscription,
} from './bridge-comm-worker-runtime-protocol.test-support.js';
import { createBridgeMainRenderDispositionAdmission } from './bridge-main-render-disposition-admission.js';
import {
	BridgeProductBoundedAsyncQueue,
	createBridgeProductDeferred,
} from './bridge-product-async-queue.js';
import type { BridgeProductBatchFrameSinks } from './bridge-product-batch-frame-router.js';
import type { BridgeProductTransportSession } from './bridge-product-transport.js';
import { bridgeProductWorktreeAnnotationDecodedCommandOutcomeSchema } from './bridge-product-worktree-annotation-contracts.js';
import type {
	BridgeWorkerFilePierreRenderJobEvent,
	BridgeWorkerMainToServerMessage,
	BridgeWorkerServerToMainMessage,
} from './bridge-worker-contracts.js';
import { bridgeWorkerServerToMainMessageSchema } from './bridge-worker-contracts.js';
import { bridgeWorkerRenderDispositionReceiptSchema } from './bridge-worker-render-fulfillment.js';
import { makeBridgeWorkerRenderReceiptIdentity } from './bridge-worker-render-fulfillment.test-support.js';
import {
	createBridgeWorkerRpcClient,
	type BridgeWorkerRpcClient,
} from './bridge-worker-rpc-client.js';
import { createBridgeWorkerRpcLifecycleStore } from './bridge-worker-rpc-lifecycle-store.js';
import {
	fileViewProductTestBudget,
	makeFileBatchInstallation,
	makeFileProductTestTransport,
} from './comm-runtime-protocol.file-product.test-support.js';

const openReviewProductSources = new Set<BridgeCommWorkerReviewProductTestSource>();
const openChannels = new Set<MessageChannel>();

afterEach((): void => {
	for (const source of openReviewProductSources) source.close();
	openReviewProductSources.clear();
	for (const channel of openChannels) {
		channel.port1.close();
		channel.port2.close();
	}
	openChannels.clear();
});

describe('Bridge comm worker duplex backpressure over an actual MessageChannel', () => {
	test('drains 66 dispositions as one, 64, and one with one batch in flight', async () => {
		// Arrange
		const channel = new MessageChannel();
		openChannels.add(channel);
		const collector = createMainPortCollector(channel.port2);
		registerBridgeCommWorkerRuntimePortProtocol(channel.port1, {
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: { className: 'interactive', maxBytes: 512 * 1024, maxWindowLines: 50 },
		});
		const lifecycleStore = createBridgeWorkerRpcLifecycleStore();
		let nextRequestSequence = 0;
		const rpcClient = createBridgeWorkerRpcClient({
			dispatch: (message): void => channel.port2.postMessage(message),
			lifecycleStore,
			requestIdFactory: (): string => `review-duplex-batch-${(nextRequestSequence += 1)}`,
			surface: 'review',
		});
		collector.addRpcClient(rpcClient);
		const dispatchedBatches: Array<{
			readonly receiptCount: number;
			readonly requestId: string;
		}> = [];
		const admission = createBridgeMainRenderDispositionAdmission({
			dispatchBatch: (receipts): string => {
				const requestId = rpcClient.send({
					command: 'renderDisposition',
					epoch: receipts[0]?.workerDerivationEpoch ?? 0,
					receipts,
				});
				dispatchedBatches.push({ receiptCount: receipts.length, requestId });
				return requestId;
			},
			lifecycleStore,
			requestWorkerReplacement: (): void => {
				throw new Error('Unexpected worker replacement in duplex batch proof.');
			},
			surface: 'review',
		});

		// Act
		for (let publicationSequence = 1; publicationSequence <= 66; publicationSequence += 1) {
			admission.enqueue(
				bridgeWorkerRenderDispositionReceiptSchema.parse({
					...makeBridgeWorkerRenderReceiptIdentity({
						itemId: `review-duplex-batch-item-${publicationSequence}`,
						publicationSequence,
						surface: 'review',
						workerDerivationEpoch: 1,
					}),
					disposition: 'queued',
					kind: 'render.disposition',
					receivedAtMilliseconds: publicationSequence,
				}),
			);
		}

		// Assert
		expect(dispatchedBatches.map(({ receiptCount }) => receiptCount)).toEqual([1]);
		expect(admission.snapshot()).toMatchObject({
			inFlightReceiptCount: 1,
			pendingReceiptCount: 65,
		});
		const firstRequestId = dispatchedBatches[0]?.requestId;
		if (firstRequestId === undefined) throw new Error('Expected the first disposition batch.');
		await collector.waitFor(
			(message) => message.kind === 'health' && message.requestId === firstRequestId,
		);
		expect(dispatchedBatches.map(({ receiptCount }) => receiptCount)).toEqual([1, 64]);
		expect(admission.snapshot()).toMatchObject({
			inFlightReceiptCount: 64,
			pendingReceiptCount: 1,
		});
		const secondRequestId = dispatchedBatches[1]?.requestId;
		if (secondRequestId === undefined) throw new Error('Expected the second disposition batch.');
		await collector.waitFor(
			(message) => message.kind === 'health' && message.requestId === secondRequestId,
		);
		expect(dispatchedBatches.map(({ receiptCount }) => receiptCount)).toEqual([1, 64, 1]);
		const thirdRequestId = dispatchedBatches[2]?.requestId;
		if (thirdRequestId === undefined) throw new Error('Expected the third disposition batch.');
		await collector.waitFor(
			(message) => message.kind === 'health' && message.requestId === thirdRequestId,
		);
		expect(admission.snapshot()).toMatchObject({
			inFlightReceiptCount: 0,
			pendingReceiptCount: 0,
			retainedReceiptCount: 0,
		});
		channel.port1.close();
		channel.port2.close();
	});

	test('orders urgent Review outcome and receipt response before publication thirteen', async () => {
		const channel = new MessageChannel();
		openChannels.add(channel);
		const collector = createMainPortCollector(channel.port2);
		const reviewProductSource = createBridgeCommWorkerReviewProductTestSource();
		openReviewProductSources.add(reviewProductSource);
		const productTransport = annotationCapableReviewProductTransport(
			reviewProductSource.productTransport,
		);
		registerBridgeCommWorkerRuntimePortProtocol(channel.port1, {
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: { className: 'interactive', maxBytes: 512 * 1024, maxWindowLines: 50 },
			openReviewContent: openReviewContentFromDescriptorMap,
			productTransport,
			renderFulfillmentContext: {
				paneSessionId: 'pane-session-duplex-review',
				workerInstanceId: 'worker-instance-duplex-review',
			},
		});
		await activateViewerMode(channel.port2, collector, 'review', 'duplex-review');
		const itemIds = Array.from({ length: 13 }, (_, index) => `review-duplex-${index + 1}`);
		reviewProductSource.publishSource(reviewSourceForItems(itemIds), 1);
		await collector.waitFor(
			(message) => message.kind === 'reviewDisplayPatch' || message.kind === 'reviewRenderPatch',
		);
		const viewportRequestId = 'request-duplex-review-viewport';
		channel.port2.postMessage({
			command: 'viewport',
			direction: 'mainToServerWorker',
			epoch: 1,
			firstVisibleIndex: 0,
			kind: 'command',
			lastVisibleIndex: itemIds.length - 1,
			phase: 'settled',
			requestId: viewportRequestId,
			surface: 'review',
			transferDescriptors: [],
			visibleItemIds: itemIds,
			wireVersion: 1,
		} satisfies BridgeWorkerMainToServerMessage);
		await collector.waitFor(
			(message) => message.kind === 'health' && message.requestId === viewportRequestId,
		);
		await collector.waitForCount((message) => message.kind === 'reviewPierreRenderJob', 12);
		const publications = collector.messages.flatMap((message) =>
			message.kind === 'reviewPierreRenderJob' ? [message] : [],
		);
		expect(publications).toHaveLength(12);
		const firstPublication = publications[0];
		if (firstPublication === undefined) throw new Error('Expected a Review publication.');

		const lifecycleStore = createBridgeWorkerRpcLifecycleStore();
		let nextRequestSequence = 0;
		const rpcClient = createBridgeWorkerRpcClient({
			dispatch: (message): void => channel.port2.postMessage(message),
			lifecycleStore,
			requestIdFactory: (): string => `review-duplex-rpc-${(nextRequestSequence += 1)}`,
			surface: 'review',
		});
		collector.addRpcClient(rpcClient);
		let receiptRequestId: string | null = null;
		const admission = createBridgeMainRenderDispositionAdmission({
			dispatchBatch: (receipts): string => {
				receiptRequestId = rpcClient.send({
					command: 'renderDisposition',
					epoch: receipts[0]?.workerDerivationEpoch ?? 0,
					receipts,
				});
				return receiptRequestId;
			},
			lifecycleStore,
			requestWorkerReplacement: (): void => {
				throw new Error('Unexpected worker replacement in duplex integration proof.');
			},
			surface: 'review',
		});
		const observationStartIndex = collector.messages.length;
		const sendUrgentDraftFlush = (): string =>
			rpcClient.send({
				command: 'annotationCommand',
				epoch: 1,
				operation: {
					body: 'urgent draft body',
					editToken: '00000000-0000-7000-8000-000000000071',
					expectedDraftRevision: 1,
					expectedMessageRevision: 2,
					kind: 'draft.flush',
					messageId: '00000000-0000-7000-8000-000000000072',
					sessionId: '00000000-0000-7000-8000-000000000073',
				},
				reviewPublicationIdentity: firstPublication.reviewPublicationIdentity,
				surface: 'review',
			});
		const annotationRequestId = sendUrgentDraftFlush();
		admission.enqueue(
			bridgeWorkerRenderDispositionReceiptSchema.parse({
				...firstPublication.renderReceiptIdentity,
				disposition: 'queued',
				kind: 'render.disposition',
				receivedAtMilliseconds: 0,
			}),
		);
		const annotationOutcome = await collector.waitForAfter(
			observationStartIndex,
			(message) =>
				message.kind === 'annotationCommandAccepted' && message.requestId === annotationRequestId,
		);
		const receiptResponse = await collector.waitForAfter(
			observationStartIndex,
			(message) => message.kind === 'health' && message.requestId === receiptRequestId,
		);
		const publicationThirteen = await collector.waitForAfter(
			observationStartIndex,
			(message) => message.kind === 'reviewPierreRenderJob' && message.job.itemId === itemIds[12],
		);

		if (annotationOutcome.message.kind !== 'annotationCommandAccepted') {
			throw new Error('Expected the urgent draft.flush accepted outcome.');
		}
		expect(annotationOutcome.message.outcome).toMatchObject({
			receipt: {
				kind: 'message',
				message: {
					draft: { body: 'urgent draft body', revision: 2 },
					messageId: '00000000-0000-7000-8000-000000000072',
					messageRevision: 3,
				},
			},
			status: { kind: 'committed' },
		});
		expect(annotationOutcome.index).toBeLessThan(receiptResponse.index);
		expect(annotationOutcome.index).toBeLessThan(publicationThirteen.index);
		expect(receiptResponse.index).toBeLessThan(publicationThirteen.index);
		expect(admission.snapshot().inFlightReceiptCount).toBe(0);
		channel.port1.close();
		channel.port2.close();
	});

	test('orders File painted response before waiting selection B publishes', async () => {
		const channel = new MessageChannel();
		openChannels.add(channel);
		const collector = createMainPortCollector(channel.port2);
		const events = new BridgeProductBoundedAsyncQueue<never>(1);
		const batchState: { sinks: BridgeProductBatchFrameSinks | null } = { sinks: null };
		const subscription: FileMetadataSubscription = {
			cancel: async (): Promise<void> => {},
			events,
			subscriptionId: 'file-subscription-duplex-backpressure',
			subscriptionKind: 'file.metadata',
		};
		registerBridgeCommWorkerRuntimePortProtocol(channel.port1, {
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: { className: 'interactive', maxBytes: 512 * 1024, maxWindowLines: 400 },
			fileViewBudget: fileViewProductTestBudget,
			productTransport: makeFileProductTestTransport({
				onBatchFrameSinks: (sinks): void => {
					batchState.sinks = sinks;
				},
				onDiscoverSource: (): void => {},
				onOpenDescriptor: (): void => {},
				subscription,
			}),
		});
		await activateViewerMode(channel.port2, collector, 'file', 'duplex-file');
		const batchSinks = batchState.sinks;
		if (batchSinks === null) throw new Error('Expected typed File batch sinks.');
		await batchSinks.install(makeFileBatchInstallation('open', subscription.subscriptionId));
		await collector.waitFor((message) => message.kind === 'fileDisplayPatch');

		const selectionARequestId = 'request-duplex-file-selection-a';
		channel.port2.postMessage(
			encodeBridgeWorkerSelectCommand({
				epoch: 1,
				requestId: selectionARequestId,
				selectedItemId: 'file-1',
				selectedSource: 'user',
				surface: 'fileView',
			}),
		);
		await collector.waitFor(
			(message) => message.kind === 'health' && message.requestId === selectionARequestId,
		);
		const publicationAMessage = await collector.waitFor(
			(message) => message.kind === 'filePierreRenderJob',
		);
		if (publicationAMessage.kind !== 'filePierreRenderJob') {
			throw new Error('Expected File publication A.');
		}
		const publicationA: BridgeWorkerFilePierreRenderJobEvent = publicationAMessage;
		const selectionBRequestId = 'request-duplex-file-selection-b';
		channel.port2.postMessage(
			encodeBridgeWorkerSelectCommand({
				epoch: 2,
				requestId: selectionBRequestId,
				selectedItemId: 'file-1',
				selectedSource: 'user',
				surface: 'fileView',
			}),
		);
		await collector.waitFor(
			(message) => message.kind === 'health' && message.requestId === selectionBRequestId,
		);

		for (const disposition of ['queued', 'applied'] as const) {
			const requestId = `request-duplex-file-a-${disposition}`;
			const startIndex = collector.messages.length;
			channel.port2.postMessage(
				encodeBridgeWorkerRenderDispositionCommand({
					epoch: publicationA.workerDerivationEpoch,
					receipts: [
						bridgeWorkerRenderDispositionReceiptSchema.parse({
							...publicationA.renderReceiptIdentity,
							disposition,
							kind: 'render.disposition',
							receivedAtMilliseconds: 0,
						}),
					],
					requestId,
				}),
			);
			const response = await collector.waitForAfter(
				startIndex,
				(message) => message.kind === 'health' && message.requestId === requestId,
			);
			expect(
				collector.messages
					.slice(startIndex, response.index)
					.some((message) => message.kind === 'filePierreRenderJob'),
			).toBe(false);
		}

		const paintedRequestId = 'request-duplex-file-a-painted';
		const paintedStartIndex = collector.messages.length;
		channel.port2.postMessage(
			encodeBridgeWorkerRenderDispositionCommand({
				epoch: publicationA.workerDerivationEpoch,
				receipts: [
					bridgeWorkerRenderDispositionReceiptSchema.parse({
						...publicationA.renderReceiptIdentity,
						disposition: 'painted',
						kind: 'render.disposition',
						receivedAtMilliseconds: 0,
					}),
				],
				requestId: paintedRequestId,
			}),
		);
		const paintedResponse = await collector.waitForAfter(
			paintedStartIndex,
			(message) => message.kind === 'health' && message.requestId === paintedRequestId,
		);
		const publicationB = await collector.waitForAfter(
			paintedStartIndex,
			(message) => message.kind === 'filePierreRenderJob',
		);

		expect(paintedResponse.index).toBeLessThan(publicationB.index);
		channel.port1.close();
		channel.port2.close();
	});
});

function createMainPortCollector(port: MessagePort): MainPortCollector {
	const messages: BridgeWorkerServerToMainMessage[] = [];
	const rpcClients = new Set<BridgeWorkerRpcClient>();
	const waiters = new Set<{
		readonly afterIndex: number;
		readonly deferred: ReturnType<typeof createBridgeProductDeferred<IndexedWorkerMessage>>;
		readonly predicate: (message: BridgeWorkerServerToMainMessage) => boolean;
	}>();
	port.addEventListener('message', (event): void => {
		const message = bridgeWorkerServerToMainMessageSchema.parse(event.data);
		messages.push(message);
		for (const rpcClient of rpcClients) rpcClient.receive(message);
		const index = messages.length - 1;
		for (const waiter of waiters) {
			if (index < waiter.afterIndex || !waiter.predicate(message)) continue;
			waiters.delete(waiter);
			waiter.deferred.resolve({ index, message });
		}
	});
	port.start();
	const waitForAfter = (
		afterIndex: number,
		predicate: (message: BridgeWorkerServerToMainMessage) => boolean,
	): Promise<IndexedWorkerMessage> => {
		for (let index = afterIndex; index < messages.length; index += 1) {
			const message = messages[index];
			if (message !== undefined && predicate(message)) return Promise.resolve({ index, message });
		}
		const deferred = createBridgeProductDeferred<IndexedWorkerMessage>();
		waiters.add({ afterIndex, deferred, predicate });
		return deferred.promise;
	};
	return {
		addRpcClient: (rpcClient): void => {
			rpcClients.add(rpcClient);
		},
		messages,
		waitFor: async (predicate) => (await waitForAfter(0, predicate)).message,
		waitForAfter,
		waitForCount: async (predicate, count): Promise<void> => {
			let observedCount = messages.filter(predicate).length;
			let nextIndex = messages.length;
			while (observedCount < count) {
				const observed = await waitForAfter(nextIndex, predicate);
				observedCount += 1;
				nextIndex = observed.index + 1;
			}
		},
	};
}

interface IndexedWorkerMessage {
	readonly index: number;
	readonly message: BridgeWorkerServerToMainMessage;
}

interface MainPortCollector {
	readonly addRpcClient: (rpcClient: BridgeWorkerRpcClient) => void;
	readonly messages: BridgeWorkerServerToMainMessage[];
	readonly waitFor: (
		predicate: (message: BridgeWorkerServerToMainMessage) => boolean,
	) => Promise<BridgeWorkerServerToMainMessage>;
	readonly waitForAfter: (
		afterIndex: number,
		predicate: (message: BridgeWorkerServerToMainMessage) => boolean,
	) => Promise<IndexedWorkerMessage>;
	readonly waitForCount: (
		predicate: (message: BridgeWorkerServerToMainMessage) => boolean,
		count: number,
	) => Promise<void>;
}

async function activateViewerMode(
	mainPort: MessagePort,
	collector: MainPortCollector,
	mode: 'file' | 'review',
	requestLabel: string,
): Promise<void> {
	const requestId = `request-${requestLabel}-mode`;
	mainPort.postMessage(
		encodeBridgeWorkerActiveViewerModeUpdateCommand({
			epoch: 1,
			requestId,
			update: {
				activeSource: null,
				mode,
				nativeSelectionRequestId: null,
				sequence: 1,
				sessionId: `${requestLabel}-session`,
			},
		}),
	);
	await collector.waitFor(
		(message) => message.kind === 'health' && message.requestId === requestId,
	);
}

function reviewSourceForItems(itemIds: readonly string[]): {
	readonly contentItems: ReturnType<typeof makeWorkerReviewContentMetadata>[];
	readonly contentRequestDescriptors: ReturnType<typeof makeContentRequestDescriptor>[];
	readonly renderSemantics: ReturnType<typeof makeRenderSemantics>[];
	readonly rows: Array<{ readonly id: string; readonly index: number; readonly parentId: null }>;
} {
	return {
		contentItems: itemIds.map((itemId) => makeWorkerReviewContentMetadata({ itemId })),
		contentRequestDescriptors: itemIds.flatMap((itemId) => [
			makeContentRequestDescriptor({ itemId, role: 'base', text: `${itemId} base\n` }),
			makeContentRequestDescriptor({ itemId, role: 'head', text: `${itemId} head\n` }),
		]),
		renderSemantics: itemIds.map((itemId) => makeRenderSemantics({ itemId })),
		rows: itemIds.map((itemId, index) => ({ id: itemId, index, parentId: null })),
	};
}

function annotationCapableReviewProductTransport(
	base: BridgeProductTransportSession,
): BridgeProductTransportSession {
	// Validate the fake at the same decoded contract boundary as a real call,
	// before an invalid response can turn the ordering witness into a timeout.
	const outcome = bridgeProductWorktreeAnnotationDecodedCommandOutcomeSchema.parse({
		receipt: {
			kind: 'message',
			context: {
				diffSide: 'additions',
				endLine: 1,
				path: 'src/review.ts',
				resolution: 'open',
				scope: 'located',
				sourceIdentity: 'review-source-duplex',
				sourceRole: 'review_head',
				startLine: 1,
				threadId: '00000000-0000-7000-8000-000000000074',
			},
			message: {
				attentionState: 'not_applicable',
				authorKind: 'human',
				createdAt: 1_700_000_000_000,
				draft: {
					activeEditToken: '00000000-0000-7000-8000-000000000071',
					body: 'urgent draft body',
					revision: 2,
				},
				handled: false,
				messageId: '00000000-0000-7000-8000-000000000072',
				messageRevision: 3,
				ordinal: 0,
				savedBody: null,
				savedRevision: null,
				sessionId: '00000000-0000-7000-8000-000000000073',
				sessionRevision: 4,
				status: 'editable',
				threadId: '00000000-0000-7000-8000-000000000074',
				threadRevision: 5,
			},
		},
		requestId: 'review-annotation-product-request',
		sessionId: '00000000-0000-7000-8000-000000000073',
		status: { kind: 'committed' },
		surface: 'review',
	});
	return {
		...base,
		// oxlint-disable-next-line typescript/no-unsafe-type-assertion -- This integration transport overrides one exact production call and delegates every other typed call.
		call: (async (method: string, ...arguments_: unknown[]): Promise<unknown> => {
			if (method === 'review.annotations.command') {
				return { kind: 'completed', outcome };
			}
			return await (base.call as (...callArguments: unknown[]) => Promise<unknown>)(
				method,
				...arguments_,
			);
		}) as BridgeProductTransportSession['call'],
	};
}
