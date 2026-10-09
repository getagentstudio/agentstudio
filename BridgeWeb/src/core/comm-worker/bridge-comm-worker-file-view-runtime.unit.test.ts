import { describe, expect, test } from 'vitest';

import { bridgeWorkerPierreRenderPolicy } from '../demand/bridge-content-demand-policy.js';
import type { BridgeCommWorkerPort } from './bridge-comm-worker-entry.js';
import type { BridgeCommWorkerFileViewContentRequest } from './bridge-comm-worker-file-view-runtime-mutation.js';
import {
	dispatchSelectedBridgeWorkerFileViewContentReady,
	type BridgeWorkerFileViewContentPreparationOutcome,
} from './bridge-comm-worker-file-view-runtime.js';
import {
	createBridgeCommWorkerStore,
	type BridgeCommWorkerStore,
} from './bridge-comm-worker-store.js';
import type {
	BridgeWorkerFileViewContentMetadata,
	BridgeWorkerReviewContentMetadata,
	BridgeWorkerServerToMainMessage,
} from './bridge-worker-contracts.js';
import type { BridgeWorkerFileViewContentOpen } from './bridge-worker-file-view-content-fetch.js';
import { bridgeWorkerRenderDispositionReceiptSchema } from './bridge-worker-render-fulfillment.js';

interface PostedBridgeWorkerRuntimeMessage {
	readonly message: BridgeWorkerServerToMainMessage;
	readonly transferList: readonly Transferable[] | undefined;
}

describe('Bridge comm worker File View runtime', () => {
	test('selected File View dispatch posts lineage-bound Pierre and render publications', async () => {
		const postedMessages: PostedBridgeWorkerRuntimeMessage[] = [];
		const openedDescriptorIds: string[] = [];
		const openedOperationCorrelationIds: string[] = [];
		const store = createSelectedFileViewRuntimeStore();
		store.actions.applySelectedFact({ epoch: 7, itemId: 'file-1' });
		store.actions.takePendingSlicePatchEvent({ epoch: 7, sequence: 11 });

		await dispatchSelectedBridgeWorkerFileViewContentReady({
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: {
				className: 'interactive',
				maxBytes: 512 * 1024,
				maxWindowLines: 50,
			},
			contentRequests: [makeContentRequest('file body\n')],
			epoch: 7,
			itemId: 'file-1',
			openContent: registeredContentOpen(openedDescriptorIds, openedOperationCorrelationIds),
			operationCorrelationId: 'a'.repeat(64),
			port: makePostedMessagePort(postedMessages),
			sequence: 12,
			store,
			workerDerivationEpoch: 17,
		});

		expect(openedDescriptorIds).toEqual(['descriptor-file-1']);
		expect(openedOperationCorrelationIds).toEqual(['a'.repeat(64)]);
		expect(postedMessages.map((postedMessage) => postedMessage.message.kind)).toEqual([
			'filePierreRenderJob',
			'fileRenderPatch',
		]);
		const renderPublication = postedMessages.find(
			(postedMessage) => postedMessage.message.kind === 'filePierreRenderJob',
		)?.message;
		expect(
			renderPublication?.kind === 'filePierreRenderJob'
				? renderPublication.renderReceiptIdentity.operationCorrelationId
				: null,
		).toBe('a'.repeat(64));
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
				payload: {
					kind: 'codeViewFileItem',
					item: {
						id: 'file:file-1',
						file: {
							name: 'Sources/App/FileView.swift',
							contents: 'file body\n',
							cacheKey: 'file-view:metadata-cache:file-1',
						},
						bridgeMetadata: {
							itemId: 'file-1',
							displayPath: 'Sources/App/FileView.swift',
							contentRoles: ['file'],
							contentState: 'hydrated',
							cacheKey: 'file-view:metadata-cache:file-1',
							lineCount: 1,
						},
					},
				},
			},
		});
		const pierreJobMessage = postedMessages[0]?.message;
		if (pierreJobMessage?.kind !== 'filePierreRenderJob') {
			throw new Error('Expected File View Pierre render job message first.');
		}
		expect(pierreJobMessage.renderReceiptIdentity).toMatchObject({
			itemId: 'file-1',
			publicationSequence: 12,
			surface: 'file',
			workerDerivationEpoch: 17,
		});
		expect(pierreJobMessage.transferDescriptors).toEqual([
			{
				messageKind: 'filePierreRenderJob',
				fieldPath: ['job', 'payload'],
				byteLength: pierreJobMessage.job.payloadByteLength,
				mode: 'clone',
			},
		]);
		expect(postedMessages[0]?.transferList).toEqual([]);
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

	test('publishes the complete selected File View source beyond the caller render window', async () => {
		const postedMessages: PostedBridgeWorkerRuntimeMessage[] = [];
		const longFileText = makeNumberedFileText(450);
		const longFileByteLength = new TextEncoder().encode(longFileText).byteLength;
		const store = createBridgeCommWorkerStore({
			surface: 'file',
			contentItems: [
				makeWorkerFileViewContentMetadata('file-1', {
					endsWithNewline: false,
					payloadLineCount: 450,
					sizeBytes: longFileByteLength,
				}),
			],
			rows: [{ id: 'file-1', parentId: null, index: 0 }],
		});
		store.actions.applySelectedFact({ epoch: 7, itemId: 'file-1' });
		store.actions.takePendingSlicePatchEvent({ epoch: 7, sequence: 11 });

		await dispatchSelectedBridgeWorkerFileViewContentReady({
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: bridgeWorkerPierreRenderPolicy.fileViewSelectedRenderBudget,
			contentRequests: [makeContentRequest(longFileText)],
			epoch: 7,
			itemId: 'file-1',
			openContent: registeredContentOpen(),
			operationCorrelationId: 'a'.repeat(64),
			port: makePostedMessagePort(postedMessages),
			sequence: 12,
			store,
			workerDerivationEpoch: 17,
		});

		expect(postedMessages.map((postedMessage) => postedMessage.message.kind).slice(0, 2)).toEqual([
			'filePierreRenderJob',
			'fileRenderPatch',
		]);
		const pierreJobMessage = postedMessages.find(
			(postedMessage) => postedMessage.message.kind === 'filePierreRenderJob',
		)?.message;
		if (pierreJobMessage?.kind !== 'filePierreRenderJob') {
			throw new Error('Expected selected long File View content to publish a Pierre job.');
		}
		expect(pierreJobMessage.job.window).toEqual({
			startLine: 1,
			endLine: 450,
			totalLineCount: 450,
		});
		expect(pierreJobMessage.job.budget).toEqual({
			className: 'interactive',
			maxBytes: longFileByteLength,
			maxWindowLines: 450,
		});
		expect(pierreJobMessage.job.windowLineCount).toBe(450);
		expect(pierreJobMessage.job.payload.kind).toBe('codeViewFileItem');
		if (pierreJobMessage.job.payload.kind !== 'codeViewFileItem') {
			throw new Error('Expected selected long File View content to publish a File View payload.');
		}
		const contents = pierreJobMessage.job.payload.item.file.contents;
		expect(contents).toContain('line-450');
		expect(pierreJobMessage.job.payload.item.bridgeMetadata).toMatchObject({
			contentState: 'hydrated',
			lineCount: 450,
		});
	});

	test('publishes selected File View content above the old 512 KiB ceiling as one complete item', async () => {
		const postedMessages: PostedBridgeWorkerRuntimeMessage[] = [];
		const denseFileText = makeDenseNumberedFileText({ lineCount: 6_000, linePayloadLength: 90 });
		const denseFileByteLength = new TextEncoder().encode(denseFileText).byteLength;
		expect(denseFileByteLength).toBeGreaterThan(512 * 1024);
		const store = createBridgeCommWorkerStore({
			surface: 'file',
			contentItems: [
				makeWorkerFileViewContentMetadata('file-1', {
					endsWithNewline: false,
					payloadLineCount: 6_000,
					sizeBytes: denseFileByteLength,
				}),
			],
			rows: [{ id: 'file-1', parentId: null, index: 0 }],
		});
		store.actions.applySelectedFact({ epoch: 7, itemId: 'file-1' });
		store.actions.takePendingSlicePatchEvent({ epoch: 7, sequence: 11 });

		await dispatchSelectedBridgeWorkerFileViewContentReady({
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: bridgeWorkerPierreRenderPolicy.fileViewSelectedRenderBudget,
			contentRequests: [makeContentRequest(denseFileText)],
			epoch: 7,
			itemId: 'file-1',
			openContent: registeredContentOpen(),
			operationCorrelationId: 'a'.repeat(64),
			port: makePostedMessagePort(postedMessages),
			sequence: 12,
			store,
			workerDerivationEpoch: 17,
		});

		const pierreJobMessage = postedMessages.find(
			(postedMessage) => postedMessage.message.kind === 'filePierreRenderJob',
		)?.message;
		if (pierreJobMessage?.kind !== 'filePierreRenderJob') {
			throw new Error('Expected selected dense File View content to publish a Pierre job.');
		}
		expect(pierreJobMessage.job.window).toEqual({
			startLine: 1,
			endLine: 6_000,
			totalLineCount: 6_000,
		});
		expect(pierreJobMessage.job.budget).toEqual({
			className: 'interactive',
			maxBytes: denseFileByteLength,
			maxWindowLines: 6_000,
		});
		expect(pierreJobMessage.job.payloadByteLength).toBeGreaterThan(512 * 1024);
		expect(pierreJobMessage.job.payload.kind).toBe('codeViewFileItem');
		if (pierreJobMessage.job.payload.kind !== 'codeViewFileItem') {
			throw new Error('Expected selected dense File View content to publish a File View payload.');
		}
		expect(pierreJobMessage.job.payload.item.file.contents).toBe(denseFileText);
		expect(pierreJobMessage.job.payload.item.bridgeMetadata).toMatchObject({
			contentState: 'hydrated',
			lineCount: 6_000,
		});
	});

	test('keeps selected File View content loading while its streamed descriptor is still pending', async () => {
		const postedMessages: PostedBridgeWorkerRuntimeMessage[] = [];
		let openCount = 0;
		const store = createSelectedFileViewRuntimeStore();
		store.actions.applySelectedFact({ epoch: 7, itemId: 'file-1' });
		store.actions.takePendingSlicePatchEvent({ epoch: 7, sequence: 11 });

		await dispatchSelectedBridgeWorkerFileViewContentReady({
			...makeDispatchProps({
				contentRequests: [],
				openContent: () => {
					openCount += 1;
					throw new Error('must not open');
				},
				postedMessages,
				store,
			}),
		});

		expect(openCount).toBe(0);
		expect(store.getState().availabilityByItemId.get('file-1')).toBe('loading');
		expect(postedMessages).toEqual([]);
	});

	test('publishes unavailable instead of opening content when selected metadata is not File View content', async () => {
		const postedMessages: PostedBridgeWorkerRuntimeMessage[] = [];
		let openCount = 0;
		const store = createBridgeCommWorkerStore({
			surface: 'file',
			contentItems: [makeWorkerReviewContentMetadata('file-1')],
			rows: [{ id: 'file-1', parentId: null, index: 0 }],
		});
		store.actions.applySelectedFact({ epoch: 7, itemId: 'file-1' });
		store.actions.takePendingSlicePatchEvent({ epoch: 7, sequence: 11 });

		await dispatchSelectedBridgeWorkerFileViewContentReady({
			...makeDispatchProps({
				contentRequests: [makeContentRequest('file body\n')],
				openContent: () => {
					openCount += 1;
					throw new Error('must not open');
				},
				postedMessages,
				store,
			}),
		});

		expect(openCount).toBe(0);
		expect(store.getState().availabilityByItemId.get('file-1')).toBe('unavailable');
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
							payload: { reason: 'content_unavailable', state: 'unavailable' },
						},
					],
				},
				transferList: [],
			},
		]);
	});

	test('publishes failed instead of leaving selected File View content loading when content open rejects', async () => {
		const postedMessages: PostedBridgeWorkerRuntimeMessage[] = [];
		const preparationOutcomes: BridgeWorkerFileViewContentPreparationOutcome[] = [];
		const store = createSelectedFileViewRuntimeStore();
		store.actions.applySelectedFact({ epoch: 7, itemId: 'file-1' });
		store.actions.takePendingSlicePatchEvent({ epoch: 7, sequence: 11 });

		await dispatchSelectedBridgeWorkerFileViewContentReady({
			...makeDispatchProps({
				contentRequests: [makeContentRequest('file body\n')],
				openContent: () => {
					throw new Error('simulated File View product content failure');
				},
				postedMessages,
				store,
			}),
			onPreparationOutcome: (outcome): void => {
				preparationOutcomes.push(outcome);
			},
		});

		expect(store.getState().availabilityByItemId.get('file-1')).toBe('failed');
		expect(postedMessages).toHaveLength(1);
		expect(postedMessages[0]).toMatchObject({
			message: {
				kind: 'fileRenderPatch',
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
		});
		expect(preparationOutcomes).toEqual([{ kind: 'terminal' }]);
	});

	test('reuses painted residency and settles a same-source reselection without another Pierre job', async () => {
		const firstPostedMessages: PostedBridgeWorkerRuntimeMessage[] = [];
		const store = createSelectedFileViewRuntimeStore();
		store.actions.applySelectedFact({ epoch: 7, itemId: 'file-1' });
		store.actions.takePendingSlicePatchEvent({ epoch: 7, sequence: 11 });
		await dispatchSelectedBridgeWorkerFileViewContentReady({
			...makeDispatchProps({
				contentRequests: [makeContentRequest('file body\n')],
				openContent: registeredContentOpen(),
				postedMessages: firstPostedMessages,
				store,
			}),
		});
		const firstJob = firstPostedMessages[0]?.message;
		if (firstJob?.kind !== 'filePierreRenderJob') {
			throw new Error('Expected the first selection to publish a Pierre render job.');
		}
		for (const disposition of ['queued', 'applied', 'painted'] as const) {
			const result = store.renderFulfillmentRegistry.applyDisposition(
				bridgeWorkerRenderDispositionReceiptSchema.parse({
					...firstJob.renderReceiptIdentity,
					disposition,
					kind: 'render.disposition',
					receivedAtMilliseconds: performance.now(),
				}),
			);
			expect(result.status).not.toBe('rejected');
		}

		store.actions.applySelectedFact({ epoch: 8, itemId: 'file-1' });
		store.actions.takePendingSlicePatchEvent({ epoch: 8, sequence: 13 });
		const secondPostedMessages: PostedBridgeWorkerRuntimeMessage[] = [];
		const preparationOutcomes: BridgeWorkerFileViewContentPreparationOutcome[] = [];
		await dispatchSelectedBridgeWorkerFileViewContentReady({
			...makeDispatchProps({
				contentRequests: [makeContentRequest('file body\n')],
				openContent: registeredContentOpen(),
				postedMessages: secondPostedMessages,
				store,
			}),
			epoch: 8,
			onPreparationOutcome: (outcome): void => {
				preparationOutcomes.push(outcome);
			},
			sequence: 14,
		});

		expect(secondPostedMessages.map(({ message }) => message.kind)).toEqual(['fileRenderPatch']);
		expect(secondPostedMessages[0]?.message).toMatchObject({
			kind: 'fileRenderPatch',
			patches: [
				{ itemId: 'file-1', payload: { contentCacheKey: 'file-view:metadata-cache:file-1' } },
				{ itemId: 'file-1', payload: { state: 'ready' } },
			],
		});
		expect(preparationOutcomes).toMatchObject([
			{ kind: 'renderPublication', publication: { shouldPublish: false, status: 'duplicate' } },
			{ kind: 'paintedResidency' },
		]);
		expect(store.getState().availabilityByItemId.get('file-1')).toBe('ready');
	});

	test('drops stale selected File View terminal dispatch before publishing content messages', async () => {
		const postedMessages: PostedBridgeWorkerRuntimeMessage[] = [];
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

		await dispatchSelectedBridgeWorkerFileViewContentReady({
			...makeDispatchProps({
				contentRequests: [makeContentRequest('file body\n')],
				openContent: () => {
					store.actions.applySelectedFact({ epoch: 8, itemId: 'file-2' });
					throw new Error('simulated stale File View product content failure');
				},
				postedMessages,
				store,
			}),
		});

		expect(postedMessages).toEqual([]);
		expect(store.getState().availabilityByItemId.get('file-1')).toBe('loading');
		expect(store.getState().availabilityByItemId.get('file-2')).toBe('loading');
	});

	test('drops a superseded descriptor attempt while selection and source epoch stay current', async () => {
		// Arrange
		const postedMessages: PostedBridgeWorkerRuntimeMessage[] = [];
		const store = createSelectedFileViewRuntimeStore();
		store.actions.applySelectedFact({ epoch: 7, itemId: 'file-1' });
		store.actions.takePendingSlicePatchEvent({ epoch: 7, sequence: 11 });
		let preparationCurrent = true;

		// Act
		await dispatchSelectedBridgeWorkerFileViewContentReady({
			...makeDispatchProps({
				contentRequests: [makeContentRequest('stale descriptor body\n')],
				openContent: (descriptor) => {
					preparationCurrent = false;
					return completedContentStream(descriptor, contentTextForDescriptor(descriptor));
				},
				postedMessages,
				store,
			}),
			isPreparationCurrent: () => preparationCurrent,
		});

		// Assert
		expect(postedMessages).toEqual([]);
		expect(store.getState().availabilityByItemId.get('file-1')).toBe('loading');
	});

	test('publishes unavailable when fetched File View content cannot plan a render job', async () => {
		const postedMessages: PostedBridgeWorkerRuntimeMessage[] = [];
		const store = createBridgeCommWorkerStore({
			surface: 'file',
			contentItems: [makeWorkerFileViewContentMetadata('file-1', { omitContentHash: true })],
			rows: [{ id: 'file-1', parentId: null, index: 0 }],
		});
		store.actions.applySelectedFact({ epoch: 7, itemId: 'file-1' });
		store.actions.takePendingSlicePatchEvent({ epoch: 7, sequence: 11 });

		await dispatchSelectedBridgeWorkerFileViewContentReady({
			...makeDispatchProps({
				contentRequests: [makeContentRequest('hashless content cannot become ready\n')],
				openContent: registeredContentOpen(),
				postedMessages,
				store,
			}),
		});

		expect(store.getState().availabilityByItemId.get('file-1')).toBe('unavailable');
		expect(postedMessages).toHaveLength(1);
		expect(postedMessages[0]).toMatchObject({
			message: {
				kind: 'fileRenderPatch',
				patches: [
					{
						slice: 'contentAvailability',
						operation: 'upsert',
						itemId: 'file-1',
						payload: { reason: 'descriptor_rejected', state: 'unavailable' },
					},
				],
			},
			transferList: [],
		});
	});

	test('drops stale selected File View dispatch before publishing content messages', async () => {
		const postedMessages: PostedBridgeWorkerRuntimeMessage[] = [];
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

		await dispatchSelectedBridgeWorkerFileViewContentReady({
			...makeDispatchProps({
				contentRequests: [makeContentRequest('file body\n')],
				openContent: (descriptor) => {
					store.actions.applySelectedFact({ epoch: 8, itemId: 'file-2' });
					return completedContentStream(descriptor, contentTextForDescriptor(descriptor));
				},
				postedMessages,
				store,
			}),
		});

		expect(postedMessages).toEqual([]);
	});
});

const contentTextByDescriptorId = new Map<string, string>();

type DispatchSelectedFileViewRuntimeProps = Parameters<
	typeof dispatchSelectedBridgeWorkerFileViewContentReady
>[0];

interface MakeDispatchPropsOptions {
	readonly contentRequests: readonly BridgeCommWorkerFileViewContentRequest[];
	readonly openContent: BridgeWorkerFileViewContentOpen;
	readonly postedMessages: PostedBridgeWorkerRuntimeMessage[];
	readonly store: BridgeCommWorkerStore;
}

function makeDispatchProps(
	options: MakeDispatchPropsOptions,
): DispatchSelectedFileViewRuntimeProps {
	return {
		bridgeDemandRank: { lane: 'selected', priority: 0 },
		budget: {
			className: 'interactive',
			maxBytes: 512 * 1024,
			maxWindowLines: 50,
		},
		contentRequests: options.contentRequests,
		epoch: 7,
		itemId: 'file-1',
		openContent: options.openContent,
		operationCorrelationId: 'a'.repeat(64),
		port: makePostedMessagePort(options.postedMessages),
		sequence: 12,
		store: options.store,
		workerDerivationEpoch: 17,
	};
}

function makePostedMessagePort(
	postedMessages: PostedBridgeWorkerRuntimeMessage[],
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

function createSelectedFileViewRuntimeStore(): BridgeCommWorkerStore {
	return createBridgeCommWorkerStore({
		surface: 'file',
		contentItems: [makeWorkerFileViewContentMetadata('file-1')],
		rows: [{ id: 'file-1', parentId: null, index: 0 }],
	});
}

function makeWorkerFileViewContentMetadata(
	itemId: string,
	props: {
		readonly endsWithNewline?: boolean;
		readonly omitContentHash?: boolean;
		readonly payloadLineCount?: number;
		readonly sizeBytes?: number;
	} = {},
): BridgeWorkerFileViewContentMetadata {
	return {
		metadataKind: 'fileView',
		itemId,
		path: 'Sources/App/FileView.swift',
		language: 'swift',
		cacheKey: `file-view:metadata-cache:${itemId}`,
		sizeBytes: props.sizeBytes ?? 10,
		descriptorId: `descriptor-${itemId}`,
		...(props.omitContentHash === true ? {} : { contentHash: 'a'.repeat(64) }),
		encoding: 'utf-8',
		endsMidLine: false,
		endsWithNewline: props.endsWithNewline ?? true,
		virtualizedExtentKind: 'exactLineCount',
		payloadByteCount: props.sizeBytes ?? 10,
		payloadLineCount: props.payloadLineCount ?? 1,
		totalLineCount: props.payloadLineCount ?? 1,
		truncationKind: 'none',
		isBinary: false,
		canFetchContent: true,
	};
}

function makeWorkerReviewContentMetadata(itemId: string): BridgeWorkerReviewContentMetadata {
	return {
		itemId,
		path: 'Sources/App/FileView.swift',
		language: 'swift',
		cacheKey: `review:metadata-cache:${itemId}`,
		sizeBytes: 128,
		availableContentRoles: ['head'],
		contentLineCountsByRole: {
			base: null,
			head: 1,
			diff: null,
		},
	};
}

function makeContentRequest(text: string): BridgeCommWorkerFileViewContentRequest {
	const encodedBytes = new TextEncoder().encode(text);
	const request: BridgeCommWorkerFileViewContentRequest = {
		contentDescriptor: {
			contentKind: 'file.content',
			declaredByteLength: encodedBytes.byteLength,
			descriptorId: 'descriptor-file-1',
			encoding: 'utf-8',
			expectedSha256: 'a'.repeat(64),
			fileId: 'file-1',
			maximumBytes: encodedBytes.byteLength,
			source: {
				repoId: '00000000-0000-4000-8000-000000000001',
				rootRevisionToken: 'root-revision-file-1',
				sourceCursor: 'cursor-file-1',
				sourceId: 'source-file-1',
				subscriptionGeneration: 7,
				worktreeId: '00000000-0000-4000-8000-000000000002',
			},
			window: {
				kind: 'prefix',
				maximumBytes: encodedBytes.byteLength,
				maximumLines: exactTextLineCount(text),
				startByte: 0,
			},
		},
		itemId: 'file-1',
		path: 'Sources/App/FileView.swift',
		language: 'swift',
		sizeBytes: encodedBytes.byteLength,
	};
	contentTextByDescriptorId.set(request.contentDescriptor.descriptorId, text);
	return request;
}

function exactTextLineCount(text: string): number {
	if (text.length === 0) return 0;
	const newlineCount = text.split('\n').length - 1;
	return text.endsWith('\n') ? newlineCount : newlineCount + 1;
}

function registeredContentOpen(
	openedDescriptorIds: string[] = [],
	openedOperationCorrelationIds: string[] = [],
): BridgeWorkerFileViewContentOpen {
	return (descriptor, _abortSignal, operationCorrelationId) => {
		openedDescriptorIds.push(descriptor.descriptorId);
		openedOperationCorrelationIds.push(operationCorrelationId);
		return completedContentStream(descriptor, contentTextForDescriptor(descriptor));
	};
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

function makeNumberedFileText(lineCount: number): string {
	return Array.from(
		{ length: lineCount },
		(_, lineIndex): string => `line-${String(lineIndex + 1).padStart(3, '0')}`,
	).join('\n');
}

function makeDenseNumberedFileText(props: {
	readonly lineCount: number;
	readonly linePayloadLength: number;
}): string {
	const payload = 'x'.repeat(props.linePayloadLength);
	return Array.from(
		{ length: props.lineCount },
		(_, lineIndex): string => `line-${String(lineIndex + 1).padStart(6, '0')} ${payload}`,
	).join('\n');
}
