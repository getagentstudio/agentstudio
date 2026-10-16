import { describe, expect, test } from 'vitest';

import { parseBridgeWorkerFileDisplayPatchEvent } from './bridge-worker-contract-parsers.js';
import {
	BRIDGE_WORKER_FILE_DISPLAY_PATCH_LIMIT,
	BRIDGE_WORKER_WIRE_VERSION,
	type BridgeWorkerFileDisplayPatchEvent,
	bridgeWorkerFileDisplayPatchEventSchema,
	bridgeWorkerServerToMainMessageSchema,
	bridgeWorkerSlicePatchEventSchema,
} from './bridge-worker-contracts.js';

const fileTreeRow = {
	changeStatus: 'modified',
	depth: 1,
	fileId: 'file-1',
	fileClass: 'source',
	isDirectory: false,
	lineCount: 12_000,
	name: 'File.swift',
	parentPath: 'Sources',
	path: 'Sources/File.swift',
	projectionIndex: 3,
	rowId: 'row-file-1',
	sizeBytes: 120_000,
} as const;

const fileItemPayload = {
	availability: { kind: 'available' },
	displayPath: 'Sources/File.swift',
	endsMidLine: false,
	endsWithNewline: true,
	extent: { kind: 'exactLineCount', lineCount: 12_000 },
	fileExtension: 'swift',
	language: 'swift',
	payloadByteCount: 100_000,
	payloadLineCount: 10_000,
	rowId: 'row-file-1',
	sizeBytes: 120_000,
	totalLineCount: 12_000,
	truncationKind: 'lineLimit',
} as const;

function makeFileDisplayPatchEvent(): BridgeWorkerFileDisplayPatchEvent {
	return {
		wireVersion: BRIDGE_WORKER_WIRE_VERSION,
		direction: 'serverWorkerToMain',
		transferDescriptors: [],
		kind: 'fileDisplayPatch',
		surface: 'fileView',
		epoch: 7,
		sequence: 11,
		projectionRevision: 5,
		patches: [
			{
				slice: 'fileTree',
				operation: 'reset',
				payload: { sourceGeneration: 7, sourceId: 'file-source-1' },
			},
			{ slice: 'fileTree', operation: 'clear' },
			{
				slice: 'fileTree',
				operation: 'batch',
				payload: {
					operations: [
						{ operation: 'upsert', row: fileTreeRow },
						{
							operation: 'remove',
							path: 'Sources/Old.swift',
							rowId: 'row-old',
						},
					],
				},
			},
			{
				slice: 'fileItem',
				operation: 'upsert',
				itemId: 'file-1',
				payload: fileItemPayload,
			},
			{ slice: 'fileItem', operation: 'delete', itemId: 'file-old' },
			{ slice: 'fileItem', operation: 'reset' },
			{
				slice: 'fileStatus',
				operation: 'upsert',
				payload: {
					state: 'ready',
					ahead: 1,
					behind: 0,
					branchName: 'main',
					staged: 2,
					unstaged: 3,
					untracked: 4,
				},
			},
			{ slice: 'fileStatus', operation: 'upsert', payload: { state: 'stale' } },
			{ slice: 'fileStatus', operation: 'reset' },
		],
	} as const;
}

describe('Bridge worker File display patch contract', () => {
	test('parses every closed File display patch variant through a surfaced worker envelope', () => {
		const event = makeFileDisplayPatchEvent();

		expect(parseBridgeWorkerFileDisplayPatchEvent(event)).toEqual(event);
		expect(bridgeWorkerFileDisplayPatchEventSchema.parse(event)).toEqual(event);
		expect(bridgeWorkerServerToMainMessageSchema.parse(event)).toEqual(event);
		expect(BRIDGE_WORKER_FILE_DISPLAY_PATCH_LIMIT).toBe(256);
	});

	test('keeps generic Review slice patches valid without admitting File display slices', () => {
		const reviewSlicePatch = {
			wireVersion: BRIDGE_WORKER_WIRE_VERSION,
			direction: 'serverWorkerToMain',
			transferDescriptors: [],
			kind: 'slicePatch',
			epoch: 7,
			sequence: 12,
			patches: [
				{
					slice: 'rowPaint',
					operation: 'upsert',
					itemId: 'review-item-1',
					payload: { label: 'Sources/Review.swift' },
				},
			],
		};

		expect(bridgeWorkerSlicePatchEventSchema.parse(reviewSlicePatch)).toEqual(reviewSlicePatch);
		expect(
			bridgeWorkerSlicePatchEventSchema.safeParse({
				...reviewSlicePatch,
				patches: makeFileDisplayPatchEvent().patches,
			}).success,
		).toBe(false);
	});

	test('rejects missing or cross-wired File surfaces and unknown patch variants', () => {
		const event = makeFileDisplayPatchEvent();
		const { fileClass: _fileClass, ...rowWithoutFileClass } = fileTreeRow;
		for (const [index, invalidEvent] of [
			{ ...event, surface: undefined },
			{ ...event, surface: 'review' },
			{ ...event, kind: 'slicePatch' },
			{ ...event, patches: [{ slice: 'fileUnknown', operation: 'reset' }] },
			{
				...event,
				patches: [{ slice: 'fileStatus', operation: 'delete' }],
			},
			{
				...event,
				patches: [{ slice: 'fileTree', operation: 'clear', payload: {} }],
			},
			{
				...event,
				patches: [
					{
						slice: 'fileTree',
						operation: 'batch',
						payload: {
							operations: [{ operation: 'upsert', row: rowWithoutFileClass }],
						},
					},
				],
			},
			{
				...event,
				patches: [
					{
						slice: 'fileTree',
						operation: 'batch',
						payload: {
							operations: [{ operation: 'upsert', row: { ...fileTreeRow, fileClass: 'alien' } }],
						},
					},
				],
			},
			{
				...event,
				patches: [
					{
						slice: 'fileItem',
						operation: 'upsert',
						itemId: 'file-1',
						payload: {
							...fileItemPayload,
							extent: { kind: 'estimatedHeight', heightPixels: 240 },
						},
					},
				],
			},
			{
				...event,
				patches: [
					{
						slice: 'fileItem',
						operation: 'upsert',
						itemId: 'file-1',
						payload: {
							...fileItemPayload,
							availability: { kind: 'unavailable', reason: 'too_large' },
							endsWithNewline: false,
							extent: { kind: 'unavailable' },
							payloadByteCount: 0,
							payloadLineCount: 0,
							totalLineCount: null,
							truncationKind: 'none',
						},
					},
				],
			},
		].entries()) {
			expect(
				bridgeWorkerFileDisplayPatchEventSchema.safeParse(invalidEvent).success,
				`invalid case ${index}`,
			).toBe(false);
		}
	});

	test('caps File display event and tree batches at 256 operations', () => {
		const event = makeFileDisplayPatchEvent();
		const resetPatches = Array.from(
			{ length: BRIDGE_WORKER_FILE_DISPLAY_PATCH_LIMIT },
			() => ({ slice: 'fileItem', operation: 'reset' }) as const,
		);
		const treeOperations = Array.from(
			{ length: BRIDGE_WORKER_FILE_DISPLAY_PATCH_LIMIT },
			(_, index) => ({
				operation: 'remove' as const,
				path: `Sources/Old-${index}.swift`,
				rowId: `row-old-${index}`,
			}),
		);

		expect(
			bridgeWorkerFileDisplayPatchEventSchema.safeParse({ ...event, patches: resetPatches })
				.success,
		).toBe(true);
		expect(
			bridgeWorkerFileDisplayPatchEventSchema.safeParse({
				...event,
				patches: [...resetPatches, { slice: 'fileItem', operation: 'reset' }],
			}).success,
		).toBe(false);
		expect(
			bridgeWorkerFileDisplayPatchEventSchema.safeParse({
				...event,
				patches: [
					{
						slice: 'fileTree',
						operation: 'batch',
						payload: { operations: treeOperations },
					},
				],
			}).success,
		).toBe(true);
		expect(
			bridgeWorkerFileDisplayPatchEventSchema.safeParse({
				...event,
				patches: [
					{
						slice: 'fileTree',
						operation: 'batch',
						payload: {
							operations: [
								...treeOperations,
								{
									operation: 'remove',
									path: 'Sources/Overflow.swift',
									rowId: 'row-overflow',
								},
							],
						},
					},
				],
			}).success,
		).toBe(false);
	});

	test('rejects product descriptors, hashes, leases, and cursors from File display payloads', () => {
		const event = makeFileDisplayPatchEvent();
		for (const forbiddenPayload of [
			{ contentDescriptor: { contentKind: 'file.content' } },
			{ descriptorId: 'descriptor-file-1' },
			{ expectedSha256: 'a'.repeat(64) },
			{ leaseId: 'lease-file-1' },
			{ sourceCursor: 'cursor-file-1' },
		]) {
			expect(
				bridgeWorkerFileDisplayPatchEventSchema.safeParse({
					...event,
					patches: [
						{
							slice: 'fileItem',
							operation: 'upsert',
							itemId: 'file-1',
							payload: { ...fileItemPayload, ...forbiddenPayload },
						},
					],
				}).success,
			).toBe(false);
		}
	});
});
