import { describe, expect, test } from 'vitest';

import fileCorpus from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-file-batch-row-corpus.json' with { type: 'json' };
import sessionCorpus from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-session-corpus.json' with { type: 'json' };
import { BridgeCommWorkerFileQueryProjection } from './bridge-comm-worker-file-query-projection.js';
import {
	applyFileViewRuntimeMutationToSource,
	createEmptyBridgeCommWorkerFileViewRuntimeSource,
} from './bridge-comm-worker-file-view-runtime-source.js';
import { bridgeProductBatchFrameSchema } from './bridge-product-batch-wire-contracts.js';
import { installBridgeProductFileBatch } from './bridge-product-file-batch-installer.js';
import { bridgeProductFileBatchRowSchema } from './bridge-product-file-batch-row-contracts.js';
import { bridgeProductFileMemberStatusRecordSchema } from './bridge-product-file-member-status-contracts.js';
import type { BridgeProductViewInstallation } from './bridge-product-view-batch-receiver.js';
import { bridgeWorkerFileDisplayPatchSchema } from './bridge-worker-contracts.js';

function fixtureInstallation(): BridgeProductViewInstallation {
	const beginValue = sessionCorpus.transportV2.batchFrames.find(
		(frame) =>
			frame.kind === 'subscription.batchBegin' && frame.subscriptionKind === 'file.metadata',
	);
	const begin = bridgeProductBatchFrameSchema.parse(beginValue);
	if (begin.kind !== 'subscription.batchBegin')
		throw new Error('File batch begin fixture missing.');
	return {
		certified: true,
		staleRecords: [],
		begin,
		domain: 'default',
		records: [
			...fileCorpus.rows.map(({ recordKey, row }) => ({
				key: recordKey,
				revision: 1,
				value: row,
			})),
			{
				key: 'member-status',
				revision: 1,
				value: fileCorpus.memberStatuses[0]?.record,
			},
		],
	};
}

describe('Bridge product File batch installer', () => {
	test('an unchanged same-source bank leaves runtime and display publications in place', () => {
		const installation = fixtureInstallation();
		const first = installBridgeProductFileBatch(installation);
		const second = installBridgeProductFileBatch(installation, first);
		expect(second.runtimeMutation).toBeNull();
		expect(second.displayPatches).toEqual([]);
	});

	test('a new descriptor in the same source is a targeted delta', () => {
		const installation = fixtureInstallation();
		const first = installBridgeProductFileBatch(installation);
		const file = bridgeProductFileBatchRowSchema.parse(fileCorpus.rows[0]?.row);
		const outcome = file.descriptorOutcome;
		if (outcome?.availability.availabilityKind !== 'available')
			throw new Error('Expected an available File descriptor fixture.');
		const descriptor = {
			...outcome.availability.contentDescriptor,
			descriptorId: 'file-descriptor-2',
		};
		const changedRow = {
			...file,
			descriptorOutcome: {
				...outcome,
				availability: { availabilityKind: 'available', contentDescriptor: descriptor },
			},
			readDescriptor: descriptor,
		};
		const second = installBridgeProductFileBatch(
			{
				...installation,
				records: installation.records.map((record) =>
					record.key === fileCorpus.rows[0]?.recordKey
						? { ...record, revision: 2, value: changedRow }
						: record,
				),
			},
			first,
		);
		expect(second.runtimeMutation?.kind).toBe('delta');
		if (second.runtimeMutation?.kind !== 'delta')
			throw new Error('Expected a targeted File runtime delta.');
		expect(second.runtimeMutation.contentUpserts.map((item) => item.itemId)).toEqual([file.fileId]);
		expect(second.runtimeMutation.contentRequestUpserts.map((item) => item.itemId)).toEqual([
			file.fileId,
		]);
		expect(second.runtimeMutation.rowUpserts).toEqual([]);
		expect(second.displayPatches.map((patch) => patch.slice)).toEqual(['fileItem']);
	});

	test('removing a File row in the same source removes its content and tree entry', () => {
		const installation = fixtureInstallation();
		const first = installBridgeProductFileBatch(installation);
		const file = bridgeProductFileBatchRowSchema.parse(fileCorpus.rows[0]?.row);
		const second = installBridgeProductFileBatch(
			{
				...installation,
				records: installation.records.filter(
					(record) => record.key !== fileCorpus.rows[0]?.recordKey,
				),
			},
			first,
		);
		expect(second.runtimeMutation?.kind).toBe('delta');
		if (second.runtimeMutation?.kind !== 'delta')
			throw new Error('Expected a targeted File removal delta.');
		expect(second.runtimeMutation.rowRemovals).toEqual([file.fileId]);
		expect(second.runtimeMutation.contentRemovals).toEqual([file.fileId]);
		expect(second.runtimeMutation.contentRequestRemovals).toEqual([file.fileId]);
		expect(second.displayPatches).toContainEqual({
			itemId: file.fileId,
			operation: 'delete',
			slice: 'fileItem',
		});
		expect(second.displayPatches.some((patch) => patch.operation === 'reset')).toBe(false);
		const queryProjection = new BridgeCommWorkerFileQueryProjection();
		queryProjection.applyDisplayPatches(first.displayPatches);
		queryProjection.applyDisplayPatches(second.displayPatches);
		const displayedPaths = queryProjection
			.snapshotDisplayPatches()
			.flatMap((patch) =>
				patch.slice === 'fileTree' && patch.operation === 'batch'
					? patch.payload.operations.flatMap((operation) =>
							operation.operation === 'upsert' ? [operation.row.path] : [],
						)
					: [],
			);
		expect(displayedPaths).not.toContain(file.displayKey);
		if (first.runtimeMutation === null) throw new Error('Expected an initial File reset.');
		const firstSource = applyFileViewRuntimeMutationToSource(
			createEmptyBridgeCommWorkerFileViewRuntimeSource(),
			first.runtimeMutation,
		);
		const secondSource = applyFileViewRuntimeMutationToSource(firstSource, second.runtimeMutation);
		expect(secondSource.contentItems.map((item) => item.itemId)).not.toContain(file.fileId);
	});

	test('a complete replacement repairs child parent identity when its directory changes', () => {
		const installation = fixtureInstallation();
		const first = installBridgeProductFileBatch(installation);
		const directoryRecord = installation.records.find(
			(record) => record.key === fileCorpus.rows[1]?.recordKey,
		);
		if (directoryRecord === undefined) throw new Error('Directory fixture missing.');
		const directory = bridgeProductFileBatchRowSchema.parse(directoryRecord.value);
		const second = installBridgeProductFileBatch(
			{
				...installation,
				records: installation.records.map((record) =>
					record.key === directoryRecord.key
						? { ...record, revision: 2, value: { ...directory, rowId: 'replacement-directory' } }
						: record,
				),
			},
			first,
		);
		expect(second.runtimeRows).toContainEqual({
			id: 'file-1',
			index: 1,
			parentId: 'replacement-directory',
		});
		expect(second.runtimeMutation).toMatchObject({
			kind: 'delta',
			rowRemovals: [directory.rowId],
			rowUpserts: expect.arrayContaining([
				{ id: 'replacement-directory', index: 0, parentId: null },
				{ id: 'file-1', index: 1, parentId: 'replacement-directory' },
			]),
		});
	});

	test('preserves current File tree facts and derives the same row and runtime identities', () => {
		const installation = fixtureInstallation();
		const installed = installBridgeProductFileBatch(installation);
		const file = bridgeProductFileBatchRowSchema.parse(fileCorpus.rows[0]?.row);
		const directory = bridgeProductFileBatchRowSchema.parse(fileCorpus.rows[1]?.row);
		if (directory.fileClass !== null) throw new Error('Directory fixture carries a file class.');
		expect(installed.displayTreeRows.map((row) => row.path)).toEqual(['src', 'src/a.ts']);
		expect(installed.runtimeRows).toEqual([
			{ id: directory.rowId, index: 0, parentId: null },
			{ id: file.fileId, index: 1, parentId: directory.rowId },
		]);
		expect(installed.contentItems.map((item) => item.itemId)).toEqual([file.fileId]);
		expect(installed.contentRequests.map((item) => item.itemId)).toEqual([file.fileId]);
		expect(installed.filePathUpserts).toEqual([{ itemId: file.fileId, path: file.displayKey }]);
		expect(installed.runtimeMutation).toEqual({
			kind: 'reset',
			contentRequestUpserts: installed.contentRequests,
			contentUpserts: installed.contentItems,
			filePathUpserts: installed.filePathUpserts,
			rowUpserts: installed.runtimeRows,
		});
		expect(installed.displayPatches).toContainEqual({
			operation: 'batch',
			payload: {
				operations: installed.displayTreeRows.map((row) => ({ operation: 'upsert', row })),
			},
			slice: 'fileTree',
		});
		expect(installed.displayPatches).toContainEqual({
			operation: 'upsert',
			payload: {
				ahead: installed.memberStatus.ahead,
				behind: installed.memberStatus.behind,
				branchName: installed.memberStatus.branchName,
				staged: installed.memberStatus.staged,
				state: 'ready',
				unstaged: installed.memberStatus.unstaged,
				untracked: installed.memberStatus.untracked,
			},
			slice: 'fileStatus',
		});
		expect(installed.displayPatches).toContainEqual(
			expect.objectContaining({
				itemId: file.fileId,
				operation: 'upsert',
				slice: 'fileItem',
			}),
		);
		for (const patch of installed.displayPatches) {
			expect(bridgeWorkerFileDisplayPatchSchema.safeParse(patch).success).toBe(true);
		}
		expect(installed.currentRecords[0]?.row.descriptorOutcome).toEqual(file.descriptorOutcome);
		expect(installed.memberStatus.status).toBe('ready');
		expect(installed.memberStatus.branchName).toBe('main');
		expect(installed.memberStatus.source.subscriptionGeneration).toBe(11);
		expect(installed.deletedGhosts).toHaveLength(1);
		for (const row of installed.displayTreeRows) {
			expect(
				bridgeWorkerFileDisplayPatchSchema.safeParse({
					operation: 'batch',
					payload: { operations: [{ operation: 'upsert', row }] },
					slice: 'fileTree',
				}).success,
			).toBe(true);
		}
	});

	test('an empty certified File tree still installs its member status', () => {
		const installation = fixtureInstallation();
		const status = installation.records.find((record) => record.key === 'member-status');
		if (status === undefined) throw new Error('Member-status fixture missing.');
		const installed = installBridgeProductFileBatch({ ...installation, records: [status] });
		expect(installed.displayTreeRows).toEqual([]);
		expect(
			installed.displayPatches.some(
				(patch) => patch.slice === 'fileTree' && patch.operation === 'batch',
			),
		).toBe(false);
		expect(installed.displayPatches.at(-1)?.operation).toBe('replacementCommit');
		expect(installed.memberStatus.status).toBe('ready');
		expect(installed.memberStatus.staged).toBe(3);
	});

	test('a stale member keeps last-good facts while marking the display not current', () => {
		const installation = fixtureInstallation();
		const status = installation.records.find((record) => record.key === 'member-status');
		if (status === undefined) throw new Error('File member-status fixture missing.');
		const statusValue = bridgeProductFileMemberStatusRecordSchema.parse(status.value);
		const installed = installBridgeProductFileBatch({
			...installation,
			records: installation.records.map((record) =>
				record.key === 'member-status'
					? { ...record, value: { ...statusValue, status: 'stale' } }
					: record,
			),
		});
		expect(installed.memberStatus.branchName).toBe('main');
		expect(installed.memberStatus.status).toBe('stale');
		expect(installed.displayPatches).toContainEqual({
			operation: 'upsert',
			payload: { state: 'stale' },
			slice: 'fileStatus',
		});
	});

	test('derives parent-before-child tree order from sibling sort keys', () => {
		const installation = fixtureInstallation();
		const sourceDirectory = bridgeProductFileBatchRowSchema.parse(fileCorpus.rows[1]?.row);
		const sourceFile = bridgeProductFileBatchRowSchema.parse(fileCorpus.rows[0]?.row);
		const docsDirectory = {
			...sourceDirectory,
			displayKey: 'docs',
			name: 'docs',
			rowId: 'docs-directory-row',
			sortKey: 'docs',
		};
		const docsFile = {
			...sourceFile,
			descriptorOutcome: null,
			displayKey: 'docs/readme.md',
			fileId: 'docs-file',
			name: 'readme.md',
			parentDisplayKey: 'docs',
			readDescriptor: null,
			rowId: 'docs-file-row',
			sortKey: 'readme.md',
		};
		const installed = installBridgeProductFileBatch({
			...installation,
			records: [
				...installation.records,
				{ key: '/workspace/docs', revision: 1, value: docsDirectory },
				{ key: '/workspace/docs/readme.md', revision: 1, value: docsFile },
			],
		});
		expect(installed.displayTreeRows.map((row) => row.path)).toEqual([
			'docs',
			'docs/readme.md',
			'src',
			'src/a.ts',
		]);
	});

	test('rejects ambiguous display locations before publishing a tree model', () => {
		const installation = fixtureInstallation();
		const duplicate = installation.records[0];
		if (duplicate === undefined) throw new Error('File row fixture missing.');
		expect(() =>
			installBridgeProductFileBatch({
				...installation,
				records: [...installation.records, { ...duplicate, key: '/another-document' }],
			}),
		).toThrow(/same display key/);
	});
});
