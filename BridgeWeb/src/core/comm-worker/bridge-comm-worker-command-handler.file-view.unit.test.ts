import { describe, expect, test } from 'vitest';

import {
	createBridgeCommWorkerCommandHandler,
	type BridgeCommWorkerFileMetadataDemand,
} from './bridge-comm-worker-command-handler.js';
import type { BridgeCommWorkerFileViewContentRequest } from './bridge-comm-worker-file-view-runtime-mutation.js';
import {
	encodeBridgeWorkerSelectCommand,
	encodeBridgeWorkerViewportCommand,
} from './bridge-comm-worker-protocol.js';
import type { BridgeCommWorkerStore } from './bridge-comm-worker-store.js';
import type { BridgeWorkerFileViewContentMetadata } from './bridge-worker-contracts.js';

interface ScheduledSelectedFileViewPreparation {
	readonly epoch: number;
	readonly itemId: string;
	readonly store: BridgeCommWorkerStore;
}

describe('Bridge comm worker command handler File View selected refresh', () => {
	test('derives selected File metadata demand from worker-owned path indexes and rejects stale facts', () => {
		const demands: BridgeCommWorkerFileMetadataDemand[] = [];
		const handler = createBridgeCommWorkerCommandHandler({
			contentItems: [],
			rows: [],
			scheduleSelectedFileViewContentReadyPreparation: (): void => {},
			scheduleSelectedReviewContentReadyPreparation: (): void => {},
			updateFileMetadataDemand: (demand): void => {
				demands.push(demand);
			},
		});
		handler.applyFileViewRuntimeSource({
			epoch: 4,
			source: {
				contentItems: [],
				contentRequests: [],
				filePathsByItemId: new Map([
					['file-1', 'Sources/One.swift'],
					['file-2', 'Sources/Two.swift'],
				]),
				rows: [
					{ id: 'file-1', parentId: null, index: 0 },
					{ id: 'file-2', parentId: null, index: 1 },
				],
			},
		});
		demands.splice(0);

		handler.handleMessage(
			encodeBridgeWorkerSelectCommand({
				epoch: 5,
				requestId: 'select-worker-path-one',
				selectedItemId: 'file-1',
				selectedSource: 'user',
				surface: 'fileView',
			}),
		);
		handler.handleMessage(
			encodeBridgeWorkerSelectCommand({
				epoch: 6,
				requestId: 'select-worker-path-two',
				selectedItemId: 'file-2',
				selectedSource: 'user',
				surface: 'fileView',
			}),
		);
		handler.handleMessage(
			encodeBridgeWorkerSelectCommand({
				epoch: 5,
				requestId: 'select-stale-worker-path',
				selectedItemId: 'file-1',
				selectedSource: 'user',
				surface: 'fileView',
			}),
		);

		expect(demands).toEqual([
			{
				epoch: 5,
				nearbyPaths: [],
				selectedPath: 'Sources/One.swift',
				visiblePaths: [],
			},
			{
				epoch: 6,
				nearbyPaths: [],
				selectedPath: 'Sources/Two.swift',
				visiblePaths: [],
			},
		]);
	});

	test('derives bounded visible and nearby File metadata demand from viewport indexes', () => {
		const demands: BridgeCommWorkerFileMetadataDemand[] = [];
		const handler = createBridgeCommWorkerCommandHandler({
			contentItems: [],
			rows: [],
			scheduleSelectedFileViewContentReadyPreparation: (): void => {},
			scheduleSelectedReviewContentReadyPreparation: (): void => {},
			updateFileMetadataDemand: (demand): void => {
				demands.push(demand);
			},
		});
		const rows = Array.from({ length: 4 }, (_unused, index) => ({
			id: `file-${index}`,
			index,
			parentId: null,
		}));
		handler.applyFileViewRuntimeSource({
			epoch: 4,
			source: {
				contentItems: [],
				contentRequests: [],
				filePathsByItemId: new Map(rows.map((row) => [row.id, `Sources/File${row.index}.swift`])),
				rows,
			},
		});
		demands.splice(0);

		handler.handleMessage(
			encodeBridgeWorkerViewportCommand({
				epoch: 5,
				firstVisibleIndex: 1,
				lastVisibleIndex: 2,
				phase: 'settled',
				requestId: 'viewport-worker-paths',
				surface: 'fileView',
				visibleItemIds: ['file-1', 'file-2'],
			}),
		);

		expect(demands).toEqual([
			{
				epoch: 5,
				nearbyPaths: ['Sources/File0.swift', 'Sources/File3.swift'],
				selectedPath: null,
				visiblePaths: ['Sources/File1.swift', 'Sources/File2.swift'],
			},
		]);
	});

	test('replays pending selection with the latest accepted UI epoch when its path arrives', () => {
		const demands: BridgeCommWorkerFileMetadataDemand[] = [];
		const handler = createBridgeCommWorkerCommandHandler({
			contentItems: [],
			rows: [],
			scheduleSelectedFileViewContentReadyPreparation: (): void => {},
			scheduleSelectedReviewContentReadyPreparation: (): void => {},
			updateFileMetadataDemand: (demand): void => {
				demands.push(demand);
			},
		});
		handler.applyFileViewRuntimeSource({
			epoch: 1,
			source: { contentItems: [], contentRequests: [], rows: [] },
		});
		handler.handleMessage(
			encodeBridgeWorkerSelectCommand({
				epoch: 10,
				requestId: 'select-before-worker-path',
				selectedItemId: 'file-late',
				selectedSource: 'user',
				surface: 'fileView',
			}),
		);
		demands.splice(0);

		handler.applyFileViewRuntimeSource({
			epoch: 1,
			source: {
				contentItems: [],
				contentRequests: [],
				filePathsByItemId: new Map([['file-late', 'Sources/Late.swift']]),
				rows: [{ id: 'file-late', index: 4, parentId: null }],
			},
		});

		expect(demands).toEqual([
			{
				epoch: 10,
				nearbyPaths: [],
				selectedPath: 'Sources/Late.swift',
				visiblePaths: [],
			},
		]);
	});

	test('keeps a pre-metadata File selection pending through path and descriptor mutations', () => {
		const demands: BridgeCommWorkerFileMetadataDemand[] = [];
		const scheduledFileViewPreparations: ScheduledSelectedFileViewPreparation[] = [];
		const handler = createBridgeCommWorkerCommandHandler({
			contentItems: [],
			rows: [],
			scheduleSelectedFileViewContentReadyPreparation: (preparation): void => {
				scheduledFileViewPreparations.push(preparation);
			},
			scheduleSelectedReviewContentReadyPreparation: (): void => {},
			updateFileMetadataDemand: (demand): void => {
				demands.push(demand);
			},
		});
		handler.applyFileViewRuntimeMutation({
			epoch: 1,
			mutation: {
				contentRequestUpserts: [],
				contentUpserts: [],
				filePathUpserts: [],
				kind: 'reset',
				rowUpserts: [],
			},
		});

		const selectionMessages = handler.handleMessage(
			encodeBridgeWorkerSelectCommand({
				epoch: 10,
				requestId: 'select-before-file-metadata-mutations',
				selectedItemId: 'file-1',
				selectedSource: 'user',
				surface: 'fileView',
			}),
		);
		expect(selectionMessages[0]).toMatchObject({
			kind: 'slicePatch',
			patches: expect.arrayContaining([
				expect.objectContaining({
					itemId: 'file-1',
					payload: { state: 'loading' },
					slice: 'contentAvailability',
				}),
			]),
		});
		expect(scheduledFileViewPreparations).toHaveLength(1);
		expect(scheduledFileViewPreparations[0]?.epoch).toBe(10);
		expect(scheduledFileViewPreparations[0]?.itemId).toBe('file-1');

		handler.applyFileViewRuntimeMutation({
			epoch: 2,
			mutation: {
				contentRemovals: [],
				contentRequestRemovals: [],
				contentRequestUpserts: [],
				contentUpserts: [
					{
						...makeWorkerFileViewContentMetadata({ path: 'Sources/App/file-2.swift' }),
						itemId: 'file-2',
					},
				],
				filePathRemovals: [],
				filePathUpserts: [{ itemId: 'file-2', path: 'Sources/App/file-2.swift' }],
				kind: 'delta',
				rowRemovals: [],
				rowUpserts: [{ id: 'file-2', parentId: null, index: 1 }],
			},
		});
		expect(scheduledFileViewPreparations).toHaveLength(1);

		handler.applyFileViewRuntimeMutation({
			epoch: 2,
			mutation: {
				contentRemovals: [],
				contentRequestRemovals: [],
				contentRequestUpserts: [],
				contentUpserts: [],
				filePathRemovals: [],
				filePathUpserts: [{ itemId: 'file-1', path: 'Sources/App/file-1.swift' }],
				kind: 'delta',
				rowRemovals: [],
				rowUpserts: [{ id: 'file-1', parentId: null, index: 0 }],
			},
		});
		expect(demands.at(-1)).toEqual({
			epoch: 10,
			nearbyPaths: [],
			selectedPath: 'Sources/App/file-1.swift',
			visiblePaths: [],
		});
		expect(scheduledFileViewPreparations).toHaveLength(1);

		handler.applyFileViewRuntimeMutation({
			epoch: 2,
			mutation: {
				contentRemovals: [],
				contentRequestRemovals: [],
				contentRequestUpserts: [makeProductFileViewContentRequest(2)],
				contentUpserts: [makeWorkerFileViewContentMetadata()],
				filePathRemovals: [],
				filePathUpserts: [],
				kind: 'delta',
				rowRemovals: [],
				rowUpserts: [],
			},
		});
		expect(scheduledFileViewPreparations).toHaveLength(2);
		expect(scheduledFileViewPreparations[1]?.epoch).toBe(2);
		expect(scheduledFileViewPreparations[1]?.store.getState().demandByKey.get('file-1')).toBe(
			'selected:2',
		);
	});

	test('applies worker-owned product File source facts without a main command envelope', () => {
		// Arrange
		const scheduledFileViewPreparations: ScheduledSelectedFileViewPreparation[] = [];
		const handler = createBridgeCommWorkerCommandHandler({
			contentItems: [],
			createSequence: createSequenceFrom([401, 402, 403]),
			rows: [{ id: 'file-1', parentId: null, index: 0 }],
			scheduleSelectedFileViewContentReadyPreparation: (preparation): void => {
				scheduledFileViewPreparations.push(preparation);
			},
			scheduleSelectedReviewContentReadyPreparation: (): void => {},
		});
		handler.handleMessage(
			encodeBridgeWorkerSelectCommand({
				epoch: 6,
				requestId: 'request-select-product-file',
				selectedItemId: 'file-1',
				selectedSource: 'user',
				surface: 'fileView',
			}),
		);
		scheduledFileViewPreparations.splice(0);

		// Act
		const messages = handler.applyFileViewRuntimeSource({
			epoch: 7,
			source: {
				contentItems: [makeWorkerFileViewContentMetadata()],
				contentRequests: [makeProductFileViewContentRequest()],
				rows: [{ id: 'file-1', parentId: null, index: 0 }],
			},
		});

		// Assert
		expect(messages).toEqual([]);
		expect(scheduledFileViewPreparations).toHaveLength(1);
		expect(scheduledFileViewPreparations[0]?.epoch).toBe(7);
		expect(scheduledFileViewPreparations[0]?.itemId).toBe('file-1');
		expect(scheduledFileViewPreparations[0]?.store.getState().demandByKey.get('file-1')).toBe(
			'selected:7',
		);
	});

	test('schedules selected File View preparation when ready paint survives a metadata refresh', () => {
		const scenario = createReadySelectedFileViewScenario();

		const messages = scenario.handler.applyFileViewRuntimeSource({
			epoch: 7,
			source: {
				contentItems: [
					makeWorkerFileViewContentMetadata({
						payloadLineCount: 8,
					}),
				],
				contentRequests: [makeProductFileViewContentRequest(6)],
				rows: [{ id: 'file-1', parentId: null, index: 0 }],
			},
		});

		expect(messages).toEqual([]);
		expect(scenario.scheduledFileViewPreparations).toHaveLength(1);
		expect(scenario.scheduledFileViewPreparations[0]?.epoch).toBe(7);
		expect(scenario.scheduledFileViewPreparations[0]?.itemId).toBe('file-1');
		expect(scenario.readyStore.getState().availabilityByItemId.get('file-1')).toBe('ready');
	});

	test('schedules selected File View preparation when a ready descriptor refreshes', () => {
		const scenario = createReadySelectedFileViewScenario();

		const messages = scenario.handler.applyFileViewRuntimeSource({
			epoch: 8,
			source: {
				contentItems: [makeWorkerFileViewContentMetadata()],
				contentRequests: [makeProductFileViewContentRequest(8)],
				rows: [{ id: 'file-1', parentId: null, index: 0 }],
			},
		});

		expect(messages).toEqual([]);
		expect(scenario.scheduledFileViewPreparations).toHaveLength(1);
		expect(scenario.scheduledFileViewPreparations[0]?.epoch).toBe(8);
		expect(scenario.scheduledFileViewPreparations[0]?.itemId).toBe('file-1');
		expect(
			scenario.scheduledFileViewPreparations[0]?.store.getState().demandByKey.get('file-1'),
		).toBe('selected:8');
		expect(scenario.readyStore.getState().availabilityByItemId.get('file-1')).toBe('ready');
	});

	test('does not replace a loading selected File preparation when unrelated metadata arrives', () => {
		// Arrange
		const scheduledFileViewPreparations: ScheduledSelectedFileViewPreparation[] = [];
		const handler = createBridgeCommWorkerCommandHandler({
			contentItems: [],
			rows: [],
			scheduleSelectedReviewContentReadyPreparation: (): void => {},
			scheduleSelectedFileViewContentReadyPreparation: (
				preparation: ScheduledSelectedFileViewPreparation,
			): void => {
				scheduledFileViewPreparations.push(preparation);
			},
		});
		handler.applyFileViewRuntimeSource({
			epoch: 7,
			source: {
				contentItems: [makeWorkerFileViewContentMetadata()],
				contentRequests: [makeProductFileViewContentRequest()],
				rows: [{ id: 'file-1', parentId: null, index: 0 }],
			},
		});
		handler.handleMessage(
			encodeBridgeWorkerSelectCommand({
				requestId: 'request-select-file-loading-before-unrelated-metadata',
				epoch: 7,
				selectedItemId: 'file-1',
				selectedSource: 'user',
				surface: 'fileView',
			}),
		);
		const loadingStore = assertReadyStore(scheduledFileViewPreparations[0]?.store);
		expect(loadingStore.getState().availabilityByItemId.get('file-1')).toBe('loading');
		scheduledFileViewPreparations.splice(0, scheduledFileViewPreparations.length);

		// Act
		const messages = handler.applyFileViewRuntimeMutation({
			epoch: 8,
			mutation: {
				contentRemovals: [],
				contentRequestRemovals: [],
				contentRequestUpserts: [],
				contentUpserts: [],
				filePathRemovals: [],
				filePathUpserts: [{ itemId: 'file-2', path: 'Sources/App/file-2.swift' }],
				kind: 'delta',
				rowRemovals: [],
				rowUpserts: [{ id: 'file-2', parentId: null, index: 1 }],
			},
		});

		// Assert
		expect(messages).toEqual([]);
		expect(scheduledFileViewPreparations).toEqual([]);
		expect(loadingStore.getState().demandByKey.get('file-1')).toBe('selected:7');
		expect(loadingStore.getState().availabilityByItemId.get('file-1')).toBe('loading');
	});

	test('schedules selected File preparation when only its content request changes', () => {
		// Arrange
		const scheduledFileViewPreparations: ScheduledSelectedFileViewPreparation[] = [];
		const handler = createBridgeCommWorkerCommandHandler({
			contentItems: [],
			rows: [],
			scheduleSelectedReviewContentReadyPreparation: (): void => {},
			scheduleSelectedFileViewContentReadyPreparation: (
				preparation: ScheduledSelectedFileViewPreparation,
			): void => {
				scheduledFileViewPreparations.push(preparation);
			},
		});
		handler.applyFileViewRuntimeSource({
			epoch: 6,
			source: {
				contentItems: [makeWorkerFileViewContentMetadata()],
				contentRequests: [makeProductFileViewContentRequest(6)],
				rows: [{ id: 'file-1', parentId: null, index: 0 }],
			},
		});
		handler.handleMessage(
			encodeBridgeWorkerSelectCommand({
				requestId: 'request-select-file-before-request-only-mutation',
				epoch: 7,
				selectedItemId: 'file-1',
				selectedSource: 'user',
				surface: 'fileView',
			}),
		);
		const loadingStore = assertReadyStore(scheduledFileViewPreparations[0]?.store);
		expect(loadingStore.getState().availabilityByItemId.get('file-1')).toBe('loading');
		scheduledFileViewPreparations.splice(0, scheduledFileViewPreparations.length);

		// Act
		const messages = handler.applyFileViewRuntimeMutation({
			epoch: 8,
			mutation: {
				contentRemovals: [],
				contentRequestRemovals: [],
				contentRequestUpserts: [makeProductFileViewContentRequest(8)],
				contentUpserts: [],
				filePathRemovals: [],
				filePathUpserts: [],
				kind: 'delta',
				rowRemovals: [],
				rowUpserts: [],
			},
		});

		// Assert
		expect(messages).toEqual([]);
		expect(scheduledFileViewPreparations).toHaveLength(1);
		expect(scheduledFileViewPreparations[0]?.epoch).toBe(8);
		expect(scheduledFileViewPreparations[0]?.itemId).toBe('file-1');
		expect(loadingStore.getState().demandByKey.get('file-1')).toBe('selected:8');
		expect(loadingStore.getState().availabilityByItemId.get('file-1')).toBe('loading');
	});

	test('schedules selected File View preparation when a replacement descriptor repairs loading demand', () => {
		const scheduledFileViewPreparations: ScheduledSelectedFileViewPreparation[] = [];
		const handler = createBridgeCommWorkerCommandHandler({
			contentItems: [],
			rows: [],
			createSequence: createSequenceFrom([301, 302, 303, 304]),
			scheduleSelectedReviewContentReadyPreparation: (): void => {},
			scheduleSelectedFileViewContentReadyPreparation: (
				preparation: ScheduledSelectedFileViewPreparation,
			): void => {
				scheduledFileViewPreparations.push(preparation);
			},
		});
		handler.applyFileViewRuntimeSource({
			epoch: 6,
			source: {
				contentItems: [makeWorkerFileViewContentMetadata()],
				contentRequests: [makeProductFileViewContentRequest(6)],
				rows: [{ id: 'file-1', parentId: null, index: 0 }],
			},
		});
		handler.handleMessage(
			encodeBridgeWorkerSelectCommand({
				requestId: 'request-select-file-loading',
				epoch: 7,
				selectedItemId: 'file-1',
				selectedSource: 'user',
				surface: 'fileView',
			}),
		);
		scheduledFileViewPreparations.splice(0, scheduledFileViewPreparations.length);

		handler.applyFileViewRuntimeSource({
			epoch: 8,
			source: {
				contentItems: [makeWorkerFileViewContentMetadata()],
				contentRequests: [makeProductFileViewContentRequest(8)],
				rows: [{ id: 'file-1', parentId: null, index: 0 }],
			},
		});

		expect(scheduledFileViewPreparations).toHaveLength(1);
		expect(scheduledFileViewPreparations[0]?.epoch).toBe(8);
		expect(scheduledFileViewPreparations[0]?.itemId).toBe('file-1');
		expect(scheduledFileViewPreparations[0]?.store.getState().demandByKey.get('file-1')).toBe(
			'selected:8',
		);
	});
});

function createReadySelectedFileViewScenario(): {
	readonly handler: ReturnType<typeof createBridgeCommWorkerCommandHandler>;
	readonly readyStore: BridgeCommWorkerStore;
	readonly scheduledFileViewPreparations: ScheduledSelectedFileViewPreparation[];
} {
	const scheduledFileViewPreparations: ScheduledSelectedFileViewPreparation[] = [];
	const handler = createBridgeCommWorkerCommandHandler({
		contentItems: [],
		rows: [],
		createSequence: createSequenceFrom([101, 102, 103, 104]),
		scheduleSelectedReviewContentReadyPreparation: (): void => {},
		scheduleSelectedFileViewContentReadyPreparation: (
			preparation: ScheduledSelectedFileViewPreparation,
		): void => {
			scheduledFileViewPreparations.push(preparation);
		},
	});
	handler.applyFileViewRuntimeSource({
		epoch: 6,
		source: {
			contentItems: [makeWorkerFileViewContentMetadata()],
			contentRequests: [makeProductFileViewContentRequest(6)],
			rows: [{ id: 'file-1', parentId: null, index: 0 }],
		},
	});
	handler.handleMessage(
		encodeBridgeWorkerSelectCommand({
			requestId: 'request-select-file-before-ready',
			epoch: 7,
			selectedItemId: 'file-1',
			selectedSource: 'user',
			surface: 'fileView',
		}),
	);
	const readyStore = assertReadyStore(scheduledFileViewPreparations[0]?.store);
	readyStore.actions.applyContentReady({
		itemId: 'file-1',
		contentCacheKey: 'file-view:sha256:file-1',
	});
	readyStore.actions.takePendingSlicePatchEvent({ epoch: 7, sequence: 201 });
	scheduledFileViewPreparations.splice(0, scheduledFileViewPreparations.length);
	return { handler, readyStore, scheduledFileViewPreparations };
}

function assertReadyStore(store: BridgeCommWorkerStore | undefined): BridgeCommWorkerStore {
	if (store === undefined) {
		throw new Error('Expected selected File View preparation store.');
	}
	return store;
}

function createSequenceFrom(sequences: readonly number[]): () => number {
	let index = 0;
	return (): number => {
		const sequence = sequences[index];
		if (sequence === undefined) {
			throw new Error('test sequence exhausted');
		}
		index += 1;
		return sequence;
	};
}

function makeWorkerFileViewContentMetadata(
	props: { readonly path?: string; readonly payloadLineCount?: number } = {},
): BridgeWorkerFileViewContentMetadata {
	const payloadLineCount = props.payloadLineCount ?? 7;
	return {
		metadataKind: 'fileView',
		itemId: 'file-1',
		path: props.path ?? 'Sources/App/file-1.swift',
		language: 'swift',
		cacheKey: 'file-view:sha256:file-1',
		sizeBytes: 128,
		descriptorId: 'descriptor-file-1',
		contentHash: 'sha256:file-1',
		encoding: 'utf-8',
		endsMidLine: false,
		endsWithNewline: true,
		virtualizedExtentKind: 'exactLineCount',
		payloadByteCount: 128,
		payloadLineCount,
		totalLineCount: payloadLineCount,
		truncationKind: 'none',
		isBinary: false,
		canFetchContent: true,
	};
}

function makeProductFileViewContentRequest(
	subscriptionGeneration = 3,
): BridgeCommWorkerFileViewContentRequest {
	return {
		contentDescriptor: {
			contentKind: 'file.content',
			declaredByteLength: 128,
			descriptorId: 'descriptor-file-1',
			encoding: 'utf-8',
			expectedSha256: 'a'.repeat(64),
			fileId: 'file-1',
			maximumBytes: 2 * 1024 * 1024,
			source: {
				repoId: '00000000-0000-4000-8000-000000000001',
				rootRevisionToken: 'root-revision-1',
				sourceCursor: `source-cursor-${subscriptionGeneration}`,
				sourceId: 'file-source-1',
				subscriptionGeneration,
				worktreeId: '00000000-0000-4000-8000-000000000002',
			},
			window: {
				kind: 'prefix',
				maximumBytes: 2 * 1024 * 1024,
				maximumLines: 10_000,
				startByte: 0,
			},
		},
		itemId: 'file-1',
		language: 'swift',
		path: 'Sources/App/file-1.swift',
		sizeBytes: 128,
	};
}
