import { describe, expect, test } from 'vitest';

import type { BridgeCommWorkerPort } from './bridge-comm-worker-entry.js';
import { enqueueSelectedBridgeWorkerFileViewContentReadyPreparation } from './bridge-comm-worker-file-view-preparation.js';
import type { BridgeCommWorkerFileViewContentRequest } from './bridge-comm-worker-file-view-runtime-mutation.js';
import {
	createBridgeCommWorkerStore,
	type BridgeCommWorkerStore,
} from './bridge-comm-worker-store.js';
import { createWorkerContentPreparationPump } from './bridge-worker-content-preparation-pump.js';
import type {
	BridgeWorkerFileViewContentMetadata,
	BridgeWorkerServerToMainMessage,
} from './bridge-worker-contracts.js';
import type { BridgeWorkerFileViewContentOpen } from './bridge-worker-file-view-content-fetch.js';

interface PostedBridgeWorkerPreparationMessage {
	readonly message: BridgeWorkerServerToMainMessage;
	readonly transferList: readonly Transferable[] | undefined;
}

describe('Bridge comm worker File View preparation', () => {
	test('enqueues selected File View content-ready dispatch as selected-ranked preparation work', async () => {
		let clockMs = 0;
		const executionOrder: string[] = [];
		const postedMessages: PostedBridgeWorkerPreparationMessage[] = [];
		const pump = createWorkerContentPreparationPump({
			maxSliceMs: 1,
			now: () => clockMs,
		});
		pump.enqueue({
			id: 'background-visible-file-view-item',
			rank: 'background',
			runSlice: () => {
				executionOrder.push('background');
				clockMs += 2;
				return { complete: false };
			},
		});
		const store = createSelectedFileViewPreparationStore();
		store.actions.applySelectedFact({ epoch: 7, itemId: 'file-1' });
		store.actions.takePendingSlicePatchEvent({ epoch: 7, sequence: 11 });

		const preparation = enqueueSelectedBridgeWorkerFileViewContentReadyPreparation({
			...makePreparationProps({
				contentRequests: [makeContentRequest('file body\n')],
				openContent: (descriptor) => {
					executionOrder.push('selected-open');
					return completedContentStream(descriptor, contentTextForDescriptor(descriptor));
				},
				postedMessages,
				pump,
				store,
			}),
		});

		expect(postedMessages).toEqual([]);
		const firstRun = pump.runUntilBudget();
		await flushBridgeWorkerPreparationContinuations();
		const secondRun = pump.runUntilBudget();
		await preparation.completion;

		expect(firstRun.completedIds).toEqual([]);
		expect(firstRun.yielded).toBe(true);
		expect(secondRun.completedIds).toEqual([preparation.workId]);
		expect(executionOrder).toEqual(['selected-open', 'background', 'background']);
		expect(postedMessages.map((postedMessage) => postedMessage.message.kind)).toEqual([
			'filePierreRenderJob',
			'fileRenderPatch',
		]);
	});

	test('drops stale deferred selected File View preparation before publishing content messages', async () => {
		const postedMessages: PostedBridgeWorkerPreparationMessage[] = [];
		const pump = createWorkerContentPreparationPump({
			maxSliceMs: 5,
			now: () => 0,
		});
		const deferredContent = createDeferredContentOpen('file body\n');
		let drainRequestCount = 0;
		const store = createBridgeCommWorkerStore({
			surface: 'file',
			contentItems: [
				makeWorkerFileViewContentMetadata('file-1'),
				makeWorkerFileViewContentMetadata('file-2'),
			],
			rows: [
				{ id: 'file-1', parentId: null, index: 0 },
				{ id: 'file-2', parentId: null, index: 1 },
			],
		});
		store.actions.applySelectedFact({ epoch: 7, itemId: 'file-1' });
		store.actions.takePendingSlicePatchEvent({ epoch: 7, sequence: 11 });

		const preparation = enqueueSelectedBridgeWorkerFileViewContentReadyPreparation({
			...makePreparationProps({
				contentRequests: [makeContentRequest('file body\n')],
				openContent: deferredContent.openContent,
				postedMessages,
				pump,
				requestPreparationDrain: () => {
					drainRequestCount += 1;
				},
				store,
			}),
		});

		const firstRun = pump.runUntilBudget();
		store.actions.applySelectedFact({ epoch: 8, itemId: 'file-2' });
		deferredContent.resolve();
		await flushBridgeWorkerPreparationContinuations();

		expect(firstRun.completedIds).toEqual([]);
		expect(drainRequestCount).toBe(1);
		expect(pump.getPendingWorkIds()).toEqual([preparation.workId]);

		const secondRun = pump.runUntilBudget();
		await preparation.completion;

		expect(secondRun.completedIds).toEqual([preparation.workId]);
		expect(postedMessages).toEqual([]);
	});

	test('passes File View product requests and open-content props through to publish a prepared job and ready patch', async () => {
		const postedMessages: PostedBridgeWorkerPreparationMessage[] = [];
		const openedDescriptorIds: string[] = [];
		const pump = createWorkerContentPreparationPump({
			maxSliceMs: 5,
			now: () => 0,
		});
		const store = createSelectedFileViewPreparationStore('file body\nsecond line\n');
		store.actions.applySelectedFact({ epoch: 7, itemId: 'file-1' });
		store.actions.takePendingSlicePatchEvent({ epoch: 7, sequence: 11 });

		const preparation = enqueueSelectedBridgeWorkerFileViewContentReadyPreparation({
			...makePreparationProps({
				bridgeDemandRank: { lane: 'selected', priority: 3 },
				budget: {
					className: 'interactive',
					maxBytes: 512 * 1024,
					maxWindowLines: 1,
				},
				contentRequests: [makeContentRequest('file body\nsecond line\n')],
				openContent: (descriptor) => {
					openedDescriptorIds.push(descriptor.descriptorId);
					return completedContentStream(descriptor, contentTextForDescriptor(descriptor));
				},
				postedMessages,
				pump,
				store,
			}),
		});

		pump.runUntilBudget();
		await flushBridgeWorkerPreparationContinuations();
		pump.runUntilBudget();
		await preparation.completion;

		expect(openedDescriptorIds).toEqual(['descriptor-file-1']);
		expect(postedMessages[0]?.message).toMatchObject({
			wireVersion: 1,
			direction: 'serverWorkerToMain',
			kind: 'filePierreRenderJob',
			publicationSequence: 12,
			surface: 'file',
			workerDerivationEpoch: 17,
			job: {
				itemId: 'file-1',
				renderKind: 'fileText',
				contentCacheKey: 'file-view:metadata-cache:file-1',
				bridgeDemandRank: { lane: 'selected', priority: 3 },
				window: { startLine: 1, endLine: 2, totalLineCount: 2 },
				budget: { className: 'interactive', maxBytes: 22, maxWindowLines: 2 },
				payload: {
					kind: 'codeViewFileItem',
					item: {
						id: 'file:file-1',
						file: {
							name: 'Sources/App/FileView.swift',
							contents: 'file body\nsecond line\n',
							cacheKey: 'file-view:metadata-cache:file-1',
							lang: 'swift',
						},
						bridgeMetadata: {
							itemId: 'file-1',
							displayPath: 'Sources/App/FileView.swift',
							contentState: 'hydrated',
							contentRoles: ['file'],
							cacheKey: 'file-view:metadata-cache:file-1',
							lineCount: 2,
						},
					},
				},
			},
		});
		expect(postedMessages[1]).toEqual({
			message: {
				wireVersion: 1,
				direction: 'serverWorkerToMain',
				kind: 'fileRenderPatch',
				publicationSequence: 12,
				surface: 'file',
				transferDescriptors: [],
				workerDerivationEpoch: 17,
				patches: [
					{
						slice: 'rowPaint',
						operation: 'upsert',
						itemId: 'file-1',
						payload: { contentCacheKey: 'file-view:metadata-cache:file-1' },
					},
					{
						slice: 'contentAvailability',
						operation: 'upsert',
						itemId: 'file-1',
						payload: { state: 'ready' },
					},
				],
			},
			transferList: [],
		});
	});

	test('publishes failed availability when selected File View content open fails', async () => {
		const postedMessages: PostedBridgeWorkerPreparationMessage[] = [];
		const pump = createWorkerContentPreparationPump({
			maxSliceMs: 5,
			now: () => 0,
		});
		const store = createSelectedFileViewPreparationStore();
		store.actions.applySelectedFact({ epoch: 7, itemId: 'file-1' });
		store.actions.takePendingSlicePatchEvent({ epoch: 7, sequence: 11 });

		const preparation = enqueueSelectedBridgeWorkerFileViewContentReadyPreparation({
			...makePreparationProps({
				contentRequests: [makeContentRequest('file body\n')],
				openContent: () => {
					throw new Error('network unavailable');
				},
				postedMessages,
				pump,
				store,
			}),
		});

		pump.runUntilBudget();
		await flushBridgeWorkerPreparationContinuations();
		const secondRun = pump.runUntilBudget();
		await preparation.completion;

		expect(secondRun.completedIds).toEqual([preparation.workId]);
		expect(postedMessages).toEqual([
			{
				message: {
					wireVersion: 1,
					direction: 'serverWorkerToMain',
					kind: 'fileRenderPatch',
					publicationSequence: 12,
					surface: 'file',
					transferDescriptors: [],
					workerDerivationEpoch: 17,
					patches: [
						{
							slice: 'contentAvailability',
							operation: 'upsert',
							itemId: 'file-1',
							payload: { reason: 'load_failed', state: 'failed' },
						},
					],
				},
				transferList: [],
			},
		]);
		expect(store.getState().availabilityByItemId.get('file-1')).toBe('failed');
	});

	test('clears stale ready paint when selected File View refresh content open fails', async () => {
		const postedMessages: PostedBridgeWorkerPreparationMessage[] = [];
		const pump = createWorkerContentPreparationPump({
			maxSliceMs: 5,
			now: () => 0,
		});
		const store = createSelectedFileViewPreparationStore();
		store.actions.applySelectedFact({ epoch: 7, itemId: 'file-1' });
		store.actions.applyContentReady({
			itemId: 'file-1',
			contentCacheKey: 'file-view:metadata-cache:file-1',
		});
		store.actions.takePendingSlicePatchEvent({ epoch: 7, sequence: 11 });

		const preparation = enqueueSelectedBridgeWorkerFileViewContentReadyPreparation({
			...makePreparationProps({
				contentRequests: [makeContentRequest('file body\n')],
				openContent: () => {
					throw new Error('network unavailable');
				},
				postedMessages,
				pump,
				store,
			}),
		});

		pump.runUntilBudget();
		await flushBridgeWorkerPreparationContinuations();
		pump.runUntilBudget();
		await preparation.completion;

		expect(postedMessages).toEqual([
			{
				message: {
					wireVersion: 1,
					direction: 'serverWorkerToMain',
					kind: 'fileRenderPatch',
					publicationSequence: 12,
					surface: 'file',
					transferDescriptors: [],
					workerDerivationEpoch: 17,
					patches: [
						{
							slice: 'contentAvailability',
							operation: 'upsert',
							itemId: 'file-1',
							payload: { reason: 'load_failed', state: 'failed' },
						},
					],
				},
				transferList: [],
			},
		]);
		expect(store.getState().availabilityByItemId.get('file-1')).toBe('failed');
		expect(store.getState().paintReadyByItemId.has('file-1')).toBe(true);
		expect(store.getState().byteCache.has('file-view:metadata-cache:file-1')).toBe(true);
	});

	test('skips enqueue when selected File View content is no longer current or demand eligible', async () => {
		const pump = createWorkerContentPreparationPump({
			maxSliceMs: 5,
			now: () => 0,
		});
		const store = createBridgeCommWorkerStore({
			surface: 'file',
			contentItems: [],
			rows: [{ id: 'file-without-metadata', parentId: null, index: 0 }],
		});
		store.actions.applySelectedFact({ epoch: 7, itemId: 'file-without-metadata' });
		store.actions.takePendingSlicePatchEvent({ epoch: 7, sequence: 11 });

		const preparation = enqueueSelectedBridgeWorkerFileViewContentReadyPreparation({
			...makePreparationProps({
				contentRequests: [],
				itemId: 'file-without-metadata',
				postedMessages: [],
				pump,
				store,
			}),
		});

		await preparation.completion;

		expect(preparation.enqueued).toBe(false);
		expect(pump.getPendingWorkIds()).toEqual([]);
	});
});

const contentTextByDescriptorId = new Map<string, string>();

interface DeferredContentOpen {
	readonly openContent: BridgeWorkerFileViewContentOpen;
	readonly resolve: () => void;
}

interface MakePreparationPropsOptions {
	readonly bridgeDemandRank?: { readonly lane: 'selected'; readonly priority: number };
	readonly budget?: {
		readonly className: 'interactive';
		readonly maxBytes: number;
		readonly maxWindowLines: number;
	};
	readonly contentRequests: readonly BridgeCommWorkerFileViewContentRequest[];
	readonly itemId?: string;
	readonly openContent?: BridgeWorkerFileViewContentOpen;
	readonly postedMessages: PostedBridgeWorkerPreparationMessage[];
	readonly pump: ReturnType<typeof createWorkerContentPreparationPump>;
	readonly requestPreparationDrain?: () => void;
	readonly store: BridgeCommWorkerStore;
}

function makePreparationProps(options: MakePreparationPropsOptions): {
	readonly bridgeDemandRank: { readonly lane: 'selected'; readonly priority: number };
	readonly budget: {
		readonly className: 'interactive';
		readonly maxBytes: number;
		readonly maxWindowLines: number;
	};
	readonly contentRequests: readonly BridgeCommWorkerFileViewContentRequest[];
	readonly epoch: number;
	readonly itemId: string;
	readonly openContent: BridgeWorkerFileViewContentOpen;
	readonly operationCorrelationId: string;
	readonly port: BridgeCommWorkerPort;
	readonly pump: ReturnType<typeof createWorkerContentPreparationPump>;
	readonly requestPreparationDrain?: () => void;
	readonly sequence: number;
	readonly store: BridgeCommWorkerStore;
	readonly workerDerivationEpoch: number;
} {
	return {
		bridgeDemandRank: options.bridgeDemandRank ?? { lane: 'selected', priority: 0 },
		budget: options.budget ?? {
			className: 'interactive',
			maxBytes: 512 * 1024,
			maxWindowLines: 50,
		},
		contentRequests: options.contentRequests,
		epoch: 7,
		itemId: options.itemId ?? 'file-1',
		openContent: options.openContent ?? unexpectedContentOpen,
		operationCorrelationId: 'a'.repeat(64),
		port: makePostedMessagePort(options.postedMessages),
		pump: options.pump,
		...(options.requestPreparationDrain === undefined
			? {}
			: { requestPreparationDrain: options.requestPreparationDrain }),
		sequence: 12,
		store: options.store,
		workerDerivationEpoch: 17,
	};
}

function createDeferredContentOpen(text: string): DeferredContentOpen {
	let resolveTerminal: () => void = noopResolveDeferredContent;
	let descriptorId = 'descriptor-file-1';
	const terminal = new Promise<{
		readonly bytes: ArrayBuffer;
		readonly contentKind: 'file.content';
		readonly descriptorId: string;
		readonly endOfSource: boolean;
		readonly kind: 'complete';
		readonly observedByteLength: number;
		readonly observedSha256: string;
	}>((resolve) => {
		resolveTerminal = (): void => {
			resolve({
				bytes: new TextEncoder().encode(text).buffer,
				contentKind: 'file.content',
				descriptorId,
				endOfSource: true,
				kind: 'complete',
				observedByteLength: new TextEncoder().encode(text).byteLength,
				observedSha256: 'a'.repeat(64),
			});
		};
	});
	return {
		openContent: (descriptor) => {
			descriptorId = descriptor.descriptorId;
			return {
				contentKind: 'file.content',
				contentRequestId: 'content-request-deferred',
				frames: emptyContentFrames(),
				terminal,
			};
		},
		resolve: resolveTerminal,
	};
}

function createSelectedFileViewPreparationStore(text = 'file body\n'): BridgeCommWorkerStore {
	return createBridgeCommWorkerStore({
		surface: 'file',
		contentItems: [makeWorkerFileViewContentMetadata('file-1', text)],
		rows: [{ id: 'file-1', parentId: null, index: 0 }],
	});
}

function makeWorkerFileViewContentMetadata(
	itemId: string,
	text = 'file body\n',
): BridgeWorkerFileViewContentMetadata {
	const payloadByteCount = new TextEncoder().encode(text).byteLength;
	const payloadLineCount = exactTextLineCount(text);
	return {
		metadataKind: 'fileView',
		itemId,
		path: 'Sources/App/FileView.swift',
		language: 'swift',
		cacheKey: `file-view:metadata-cache:${itemId}`,
		sizeBytes: payloadByteCount,
		descriptorId: `descriptor-${itemId}`,
		contentHash: 'a'.repeat(64),
		encoding: 'utf-8',
		endsMidLine: false,
		endsWithNewline: text.endsWith('\n'),
		virtualizedExtentKind: 'exactLineCount',
		payloadByteCount,
		payloadLineCount,
		totalLineCount: payloadLineCount,
		truncationKind: 'none',
		isBinary: false,
		canFetchContent: true,
	};
}

function makeContentRequest(
	text: string,
	itemId = 'file-1',
): BridgeCommWorkerFileViewContentRequest {
	const descriptorId = `descriptor-${itemId}`;
	const encodedBytes = new TextEncoder().encode(text);
	const payloadLineCount = exactTextLineCount(text);
	const request: BridgeCommWorkerFileViewContentRequest = {
		contentDescriptor: {
			contentKind: 'file.content',
			declaredByteLength: encodedBytes.byteLength,
			descriptorId,
			encoding: 'utf-8',
			expectedSha256: 'a'.repeat(64),
			fileId: itemId,
			maximumBytes: encodedBytes.byteLength,
			source: {
				repoId: '00000000-0000-4000-8000-000000000001',
				rootRevisionToken: `root-revision-${itemId}`,
				sourceCursor: `cursor-${itemId}`,
				sourceId: `source-${itemId}`,
				subscriptionGeneration: 7,
				worktreeId: '00000000-0000-4000-8000-000000000002',
			},
			window: {
				kind: 'prefix',
				maximumBytes: encodedBytes.byteLength,
				maximumLines: payloadLineCount,
				startByte: 0,
			},
		},
		itemId,
		path: 'Sources/App/FileView.swift',
		language: 'swift',
		sizeBytes: encodedBytes.byteLength,
	};
	contentTextByDescriptorId.set(descriptorId, text);
	return request;
}

function exactTextLineCount(text: string): number {
	if (text.length === 0) return 0;
	const newlineCount = text.split('\n').length - 1;
	return text.endsWith('\n') ? newlineCount : newlineCount + 1;
}

function contentTextForDescriptor(descriptor: { readonly descriptorId: string }): string {
	const text = contentTextByDescriptorId.get(descriptor.descriptorId);
	if (text === undefined)
		throw new Error(`Unexpected File View descriptor ${descriptor.descriptorId}.`);
	return text;
}

function completedContentStream(
	descriptor: { readonly descriptorId: string },
	text: string,
): ReturnType<BridgeWorkerFileViewContentOpen> {
	return {
		contentKind: 'file.content',
		contentRequestId: `content-request-${descriptor.descriptorId}`,
		frames: emptyContentFrames(),
		terminal: Promise.resolve({
			bytes: new TextEncoder().encode(text).buffer,
			contentKind: 'file.content',
			descriptorId: descriptor.descriptorId,
			endOfSource: true,
			kind: 'complete',
			observedByteLength: new TextEncoder().encode(text).byteLength,
			observedSha256: 'a'.repeat(64),
		}),
	};
}

async function* emptyContentFrames(): AsyncIterable<never> {}

function unexpectedContentOpen(): never {
	throw new Error('File View content must not open for this test.');
}

async function flushBridgeWorkerPreparationContinuations(): Promise<void> {
	await Array.from({ length: 50 }).reduce<Promise<void>>(
		(previousFlush) => previousFlush.then(() => Promise.resolve()),
		Promise.resolve(),
	);
}

function makePostedMessagePort(
	postedMessages: PostedBridgeWorkerPreparationMessage[],
): BridgeCommWorkerPort {
	return {
		postMessage: (
			message: BridgeWorkerServerToMainMessage,
			transferList?: Transferable[],
		): void => {
			postedMessages.push({ message, transferList });
		},
		addEventListener: (): void => {},
	};
}

function noopResolveDeferredContent(): void {}
