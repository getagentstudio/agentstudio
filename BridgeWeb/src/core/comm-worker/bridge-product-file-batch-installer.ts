import type { BridgeCommWorkerFileViewRuntimeMutation } from './bridge-comm-worker-file-view-runtime-mutation.js';
import type { BridgeCommWorkerRow } from './bridge-comm-worker-store.js';
import type { BridgeProductFileContentDescriptor } from './bridge-product-content-contracts.js';
import {
	bridgeProductFileBatchRowSchema,
	type BridgeProductFileBatchRow,
} from './bridge-product-file-batch-row-contracts.js';
import {
	BRIDGE_PRODUCT_FILE_MEMBER_STATUS_KEY,
	bridgeProductFileMemberStatusRecordSchema,
	type BridgeProductFileMemberStatusRecord,
} from './bridge-product-file-member-status-contracts.js';
import type { BridgeProductViewInstallation } from './bridge-product-view-batch-receiver.js';
import {
	BRIDGE_WORKER_FILE_DISPLAY_PATCH_LIMIT,
	bridgeWorkerFileViewContentMetadataSchema,
	type BridgeWorkerFileDisplayPatch,
	type BridgeWorkerFileViewContentMetadata,
} from './bridge-worker-contracts.js';

type TreeBatchPatch = Extract<
	BridgeWorkerFileDisplayPatch,
	{ readonly operation: 'batch'; readonly slice: 'fileTree' }
>;
type DisplayTreeRow = Extract<
	TreeBatchPatch['payload']['operations'][number],
	{ readonly operation: 'upsert' }
>['row'];

export interface BridgeProductInstalledFileRecord {
	readonly key: string;
	readonly revision: number;
	readonly row: BridgeProductFileBatchRow;
}

export interface BridgeProductInstalledFileView {
	readonly contentItems: readonly BridgeWorkerFileViewContentMetadata[];
	readonly contentRequests: readonly BridgeProductInstalledFileContentRequest[];
	readonly currentRecords: readonly BridgeProductInstalledFileRecord[];
	readonly deletedGhosts: readonly BridgeProductInstalledFileRecord[];
	readonly displayPatches: readonly BridgeWorkerFileDisplayPatch[];
	readonly displayTreeRows: readonly DisplayTreeRow[];
	readonly filePathUpserts: readonly BridgeProductInstalledFilePath[];
	readonly memberStatus: BridgeProductFileMemberStatusRecord;
	readonly memberStatusRevision: number;
	readonly runtimeRows: readonly BridgeCommWorkerRow[];
	readonly runtimeMutation: BridgeCommWorkerFileViewRuntimeMutation | null;
}

export interface BridgeProductInstalledFileContentRequest {
	readonly contentDescriptor: BridgeProductFileContentDescriptor;
	readonly itemId: string;
	readonly language: string | null;
	readonly path: string;
	readonly sizeBytes: number;
}

export interface BridgeProductInstalledFilePath {
	readonly itemId: string;
	readonly path: string;
}

/** A certified W4 bank becomes one File tree model before any DOM work is queued. */
export function installBridgeProductFileBatch(
	installation: BridgeProductViewInstallation,
	previous: BridgeProductInstalledFileView | null = null,
): BridgeProductInstalledFileView {
	if (installation.begin.subscriptionKind !== 'file.metadata') {
		throw new Error('A File installer requires a File batch.');
	}
	const memberStatuses = installation.records.filter(
		(record) => record.key === BRIDGE_PRODUCT_FILE_MEMBER_STATUS_KEY,
	);
	if (memberStatuses.length !== 1) {
		throw new Error('A File domain requires exactly one member-status record.');
	}
	const memberStatusRecord = memberStatuses[0];
	if (memberStatusRecord === undefined) throw new Error('File member-status record missing.');
	const memberStatus = bridgeProductFileMemberStatusRecordSchema.parse(memberStatusRecord.value);
	const currentRecords = installation.records
		.filter((record) => record.key !== BRIDGE_PRODUCT_FILE_MEMBER_STATUS_KEY)
		.map(
			(record): BridgeProductInstalledFileRecord => ({
				key: record.key,
				revision: record.revision,
				row: bridgeProductFileBatchRowSchema.parse(record.value),
			}),
		);
	const currentKeys = new Set(currentRecords.map((record) => record.key));
	const currentDisplayKeys = new Set(currentRecords.map((record) => record.row.displayKey));
	const staleRows = installation.staleRecords
		.filter(
			(record) =>
				record.key !== BRIDGE_PRODUCT_FILE_MEMBER_STATUS_KEY && !currentKeys.has(record.key),
		)
		.flatMap((record): readonly BridgeProductInstalledFileRecord[] => {
			const row = bridgeProductFileBatchRowSchema.parse(record.value);
			if (currentDisplayKeys.has(row.displayKey)) return [];
			return [
				{
					key: record.key,
					revision: record.revision,
					row: { ...row, descriptorOutcome: null, readDescriptor: null },
				},
			];
		});
	const activeRecords = [...currentRecords, ...staleRows].filter(
		(record) => record.row.kind !== 'deleted',
	);
	const orderedRecords = orderFileRecords(activeRecords);
	const descriptorOutcomes = currentRecords.flatMap(({ row }) =>
		row.descriptorOutcome === null ? [] : [row.descriptorOutcome],
	);
	const runtimeIdByDisplayKey = new Map(
		orderedRecords.map((record) => [record.row.displayKey, runtimeRowId(record.row)]),
	);
	const contentItems = descriptorOutcomes.map(contentMetadataFromOutcome);
	const contentRequests = descriptorOutcomes.flatMap(contentRequestFromOutcome);
	const filePathUpserts = orderedRecords.flatMap(({ row }) =>
		row.fileId === null ? [] : [{ itemId: row.fileId, path: row.displayKey }],
	);
	const runtimeRows = orderedRecords.map(
		({ row }, index): BridgeCommWorkerRow => ({
			id: runtimeRowId(row),
			index,
			parentId:
				row.parentDisplayKey === null
					? null
					: (runtimeIdByDisplayKey.get(row.parentDisplayKey) ?? null),
		}),
	);
	const displayTreeRows = orderedRecords.map(
		({ row }, projectionIndex): DisplayTreeRow => ({
			changeStatus: row.changeStatus,
			depth: row.depth,
			fileClass: row.fileClass,
			fileId: row.fileId,
			isDirectory: row.kind === 'directory',
			lineCount: row.lineCount,
			name: row.name,
			parentPath: row.parentDisplayKey,
			path: row.displayKey,
			projectionIndex,
			rowId: row.rowId,
			sizeBytes: row.sizeBytes,
		}),
	);
	const next: BridgeProductInstalledFileView = {
		contentItems,
		contentRequests,
		currentRecords,
		deletedGhosts: currentRecords.filter((record) => record.row.kind === 'deleted'),
		displayPatches: displayPatchesForFileBatch(memberStatus, displayTreeRows, descriptorOutcomes),
		displayTreeRows,
		filePathUpserts,
		memberStatus,
		memberStatusRevision: memberStatusRecord.revision,
		runtimeRows,
		runtimeMutation: {
			kind: 'reset',
			contentRequestUpserts: contentRequests,
			contentUpserts: contentItems,
			filePathUpserts,
			rowUpserts: runtimeRows,
		},
	};
	if (previous === null || !sameFileFact(previous.memberStatus.source, memberStatus.source)) {
		return next;
	}
	return {
		...next,
		displayPatches: changedFileDisplayPatches(previous, next),
		runtimeMutation: changedFileRuntimeMutation(previous, next),
	};
}

function changedFileRuntimeMutation(
	previous: BridgeProductInstalledFileView,
	next: BridgeProductInstalledFileView,
): BridgeCommWorkerFileViewRuntimeMutation | null {
	const previousRows = new Map(previous.runtimeRows.map((row) => [row.id, row]));
	const nextRows = new Map(next.runtimeRows.map((row) => [row.id, row]));
	const previousContent = new Map(previous.contentItems.map((item) => [item.itemId, item]));
	const nextContent = new Map(next.contentItems.map((item) => [item.itemId, item]));
	const previousRequests = new Map(previous.contentRequests.map((item) => [item.itemId, item]));
	const nextRequests = new Map(next.contentRequests.map((item) => [item.itemId, item]));
	const previousPaths = new Map(previous.filePathUpserts.map((item) => [item.itemId, item]));
	const nextPaths = new Map(next.filePathUpserts.map((item) => [item.itemId, item]));
	const mutation: Extract<BridgeCommWorkerFileViewRuntimeMutation, { readonly kind: 'delta' }> = {
		kind: 'delta',
		contentRemovals: [...previousContent.keys()].filter((id) => !nextContent.has(id)),
		contentRequestRemovals: [...previousRequests.keys()].filter((id) => !nextRequests.has(id)),
		contentRequestUpserts: next.contentRequests.filter(
			(item) => !sameFileFact(previousRequests.get(item.itemId), item),
		),
		contentUpserts: next.contentItems.filter(
			(item) => !sameFileFact(previousContent.get(item.itemId), item),
		),
		filePathRemovals: [...previousPaths.keys()].filter((id) => !nextPaths.has(id)),
		filePathUpserts: next.filePathUpserts.filter(
			(item) => !sameFileFact(previousPaths.get(item.itemId), item),
		),
		rowRemovals: [...previousRows.keys()].filter((id) => !nextRows.has(id)),
		rowUpserts: next.runtimeRows.filter((row) => !sameFileFact(previousRows.get(row.id), row)),
	};
	return Object.values(mutation).some((value) => Array.isArray(value) && value.length > 0)
		? mutation
		: null;
}

function changedFileDisplayPatches(
	previous: BridgeProductInstalledFileView,
	next: BridgeProductInstalledFileView,
): readonly BridgeWorkerFileDisplayPatch[] {
	const previousRows = new Map(previous.displayTreeRows.map((row) => [row.rowId, row]));
	const nextRows = new Map(next.displayTreeRows.map((row) => [row.rowId, row]));
	const operations: Extract<
		BridgeWorkerFileDisplayPatch,
		{ readonly operation: 'batch'; readonly slice: 'fileTree' }
	>['payload']['operations'][number][] = [];
	for (const row of previous.displayTreeRows) {
		const successor = nextRows.get(row.rowId);
		if (successor === undefined || successor.path !== row.path) {
			operations.push({ operation: 'remove', path: row.path, rowId: row.rowId });
		}
	}
	for (const row of next.displayTreeRows) {
		if (!sameFileFact(previousRows.get(row.rowId), row)) {
			operations.push({ operation: 'upsert', row });
		}
	}
	const patches: BridgeWorkerFileDisplayPatch[] = [];
	for (let index = 0; index < operations.length; index += BRIDGE_WORKER_FILE_DISPLAY_PATCH_LIMIT) {
		patches.push({
			operation: 'batch',
			payload: {
				operations: operations.slice(index, index + BRIDGE_WORKER_FILE_DISPLAY_PATCH_LIMIT),
			},
			slice: 'fileTree',
		});
	}
	const previousOutcomes = fileOutcomesById(previous);
	const nextOutcomes = fileOutcomesById(next);
	for (const itemId of previousOutcomes.keys()) {
		if (!nextOutcomes.has(itemId)) patches.push({ itemId, operation: 'delete', slice: 'fileItem' });
	}
	for (const [itemId, outcome] of nextOutcomes) {
		if (!sameFileFact(previousOutcomes.get(itemId), outcome)) {
			patches.push(fileItemPatchFromOutcome(outcome));
		}
	}
	if (!sameFileFact(previous.memberStatus, next.memberStatus)) {
		const statusPatch = next.displayPatches.find(
			(patch) => patch.slice === 'fileStatus' && patch.operation === 'upsert',
		);
		if (statusPatch !== undefined) patches.push(statusPatch);
	}
	return patches;
}

function fileOutcomesById(
	view: BridgeProductInstalledFileView,
): ReadonlyMap<string, NonNullable<BridgeProductFileBatchRow['descriptorOutcome']>> {
	return new Map(
		view.currentRecords.flatMap(({ row }) =>
			row.descriptorOutcome === null
				? []
				: [[row.descriptorOutcome.fileId, row.descriptorOutcome] as const],
		),
	);
}

function sameFileFact(left: unknown, right: unknown): boolean {
	return JSON.stringify(left) === JSON.stringify(right);
}

function displayPatchesForFileBatch(
	memberStatus: BridgeProductFileMemberStatusRecord,
	treeRows: readonly DisplayTreeRow[],
	descriptorOutcomes: readonly NonNullable<BridgeProductFileBatchRow['descriptorOutcome']>[],
): readonly BridgeWorkerFileDisplayPatch[] {
	const sourceIdentity = {
		sourceGeneration: memberStatus.source.subscriptionGeneration,
		sourceId: memberStatus.source.sourceId,
	};
	const patches: BridgeWorkerFileDisplayPatch[] = [
		{ operation: 'reset', payload: sourceIdentity, slice: 'fileTree' },
		{ operation: 'reset', slice: 'fileItem' },
		{ operation: 'reset', slice: 'fileStatus' },
	];
	for (let index = 0; index < treeRows.length; index += BRIDGE_WORKER_FILE_DISPLAY_PATCH_LIMIT) {
		patches.push({
			operation: 'batch',
			payload: {
				operations: treeRows
					.slice(index, index + BRIDGE_WORKER_FILE_DISPLAY_PATCH_LIMIT)
					.map((row) => ({ operation: 'upsert' as const, row })),
			},
			slice: 'fileTree',
		});
	}
	for (const outcome of descriptorOutcomes) patches.push(fileItemPatchFromOutcome(outcome));
	patches.push(
		memberStatus.status === 'ready'
			? {
					operation: 'upsert',
					payload: {
						ahead: memberStatus.ahead,
						behind: memberStatus.behind,
						branchName: memberStatus.branchName,
						staged: memberStatus.staged,
						state: 'ready',
						unstaged: memberStatus.unstaged,
						untracked: memberStatus.untracked,
					},
					slice: 'fileStatus',
				}
			: { operation: 'upsert', payload: { state: memberStatus.status }, slice: 'fileStatus' },
		{ operation: 'replacementCommit', payload: sourceIdentity, slice: 'fileTree' },
	);
	return patches;
}

function fileItemPatchFromOutcome(
	outcome: NonNullable<BridgeProductFileBatchRow['descriptorOutcome']>,
): BridgeWorkerFileDisplayPatch {
	const availability =
		outcome.availability.availabilityKind === 'available'
			? ({ kind: 'available' } as const)
			: outcome.availability.availabilityKind === 'binary'
				? ({ kind: 'binary' } as const)
				: ({ kind: 'unavailable', reason: outcome.availability.reason } as const);
	const extent =
		outcome.virtualizedExtentKind === 'unavailable'
			? ({ kind: 'unavailable' } as const)
			: outcome.virtualizedExtentKind === 'previewBounded'
				? ({ kind: 'previewBounded' } as const)
				: outcome.totalLineCount === null
					? null
					: ({ kind: 'exactLineCount', lineCount: outcome.totalLineCount } as const);
	if (extent === null) throw new Error('File batch outcome has no exact display line count.');
	return {
		itemId: outcome.fileId,
		operation: 'upsert',
		payload: {
			availability,
			displayPath: outcome.path,
			endsMidLine: outcome.endsMidLine,
			endsWithNewline: outcome.endsWithNewline,
			extent,
			fileExtension: outcome.fileExtension,
			language: outcome.language,
			payloadByteCount: outcome.payloadByteCount,
			payloadLineCount: outcome.payloadLineCount,
			rowId: outcome.rowId,
			sizeBytes: outcome.sizeBytes,
			totalLineCount: outcome.totalLineCount,
			truncationKind: outcome.truncationKind,
		},
		slice: 'fileItem',
	};
}

function contentMetadataFromOutcome(
	outcome: NonNullable<BridgeProductFileBatchRow['descriptorOutcome']>,
): BridgeWorkerFileViewContentMetadata {
	const contentDescriptor =
		outcome.availability.availabilityKind === 'available'
			? outcome.availability.contentDescriptor
			: null;
	const descriptorId =
		contentDescriptor?.descriptorId ?? `unavailable:${outcome.source.sourceId}:${outcome.fileId}`;
	const contentHash = contentDescriptor?.expectedSha256 ?? null;
	return bridgeWorkerFileViewContentMetadataSchema.parse({
		cacheKey: `file-content:${descriptorId}:${contentHash ?? 'unknown'}`,
		canFetchContent: contentDescriptor !== null,
		...(contentHash === null ? {} : { contentHash }),
		descriptorId,
		encoding: outcome.encoding,
		endsMidLine: outcome.endsMidLine,
		endsWithNewline: outcome.endsWithNewline,
		isBinary: outcome.availability.availabilityKind === 'binary',
		itemId: outcome.fileId,
		language: outcome.language,
		metadataKind: 'fileView',
		path: outcome.path,
		payloadByteCount: outcome.payloadByteCount,
		payloadLineCount: outcome.payloadLineCount,
		sizeBytes: outcome.sizeBytes,
		totalLineCount: outcome.totalLineCount,
		truncationKind: outcome.truncationKind,
		virtualizedExtentKind: outcome.virtualizedExtentKind,
	});
}

function contentRequestFromOutcome(
	outcome: NonNullable<BridgeProductFileBatchRow['descriptorOutcome']>,
): readonly BridgeProductInstalledFileContentRequest[] {
	if (outcome.availability.availabilityKind !== 'available') return [];
	return [
		{
			contentDescriptor: outcome.availability.contentDescriptor,
			itemId: outcome.fileId,
			language: outcome.language,
			path: outcome.path,
			sizeBytes: outcome.sizeBytes,
		},
	];
}

function orderFileRecords(
	records: readonly BridgeProductInstalledFileRecord[],
): readonly BridgeProductInstalledFileRecord[] {
	const byDisplayKey = new Map<string, BridgeProductInstalledFileRecord>();
	for (const record of records) {
		if (byDisplayKey.has(record.row.displayKey)) {
			throw new Error('One File batch cannot install two rows at the same display key.');
		}
		byDisplayKey.set(record.row.displayKey, record);
	}
	const childrenByParent = new Map<string | null, BridgeProductInstalledFileRecord[]>();
	for (const record of records) {
		const parent = record.row.parentDisplayKey;
		if (parent !== null && !byDisplayKey.has(parent)) {
			throw new Error('A File row requires its parent in the certified bank.');
		}
		const children = childrenByParent.get(parent) ?? [];
		children.push(record);
		childrenByParent.set(parent, children);
	}
	for (const children of childrenByParent.values()) children.sort(compareFileRows);
	const ordered: BridgeProductInstalledFileRecord[] = [];
	const pending = [...(childrenByParent.get(null) ?? [])].reverse();
	while (pending.length > 0) {
		const record = pending.pop();
		if (record === undefined) continue;
		ordered.push(record);
		pending.push(...[...(childrenByParent.get(record.row.displayKey) ?? [])].reverse());
	}
	if (ordered.length !== records.length) throw new Error('File tree parentage contains a cycle.');
	return ordered;
}

function compareFileRows(
	left: BridgeProductInstalledFileRecord,
	right: BridgeProductInstalledFileRecord,
): number {
	const sortOrder = compareCodeUnits(left.row.sortKey, right.row.sortKey);
	return sortOrder === 0 ? compareCodeUnits(left.key, right.key) : sortOrder;
}

function compareCodeUnits(left: string, right: string): number {
	return left < right ? -1 : left > right ? 1 : 0;
}

function runtimeRowId(row: BridgeProductFileBatchRow): string {
	return row.fileId ?? row.rowId;
}
