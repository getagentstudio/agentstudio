import type {
	BridgeCommWorkerFileViewContentRequest,
	BridgeCommWorkerFileViewRuntimeMutation,
} from './bridge-comm-worker-file-view-runtime-mutation.js';
import type { BridgeCommWorkerRow } from './bridge-comm-worker-store.js';
import type { BridgeWorkerFileViewContentMetadata } from './bridge-worker-contracts.js';

export interface BridgeCommWorkerFileViewRuntimeSource {
	readonly contentItems: readonly BridgeWorkerFileViewContentMetadata[];
	readonly contentRequests: readonly BridgeCommWorkerFileViewContentRequest[];
	readonly contentRequestsByItemId?: ReadonlyMap<string, BridgeCommWorkerFileViewContentRequest>;
	readonly filePathsByItemId?: ReadonlyMap<string, string>;
	readonly rows: readonly BridgeCommWorkerRow[];
	readonly rowIndexByItemId?: ReadonlyMap<string, number>;
	readonly rowsByIndex?: ReadonlyMap<number, BridgeCommWorkerRow>;
}

export interface BridgeCommWorkerFileViewRuntimeMutationApplication {
	readonly nextSource: BridgeCommWorkerFileViewRuntimeSource;
	readonly selectedContentRequestChanged: boolean;
}

export function createEmptyBridgeCommWorkerFileViewRuntimeSource(): BridgeCommWorkerFileViewRuntimeSource {
	return {
		contentItems: [],
		contentRequests: [],
		contentRequestsByItemId: new Map(),
		filePathsByItemId: new Map(),
		rows: [],
		rowIndexByItemId: new Map(),
		rowsByIndex: new Map(),
	};
}

export function applyFileViewRuntimeMutationToSource(
	source: BridgeCommWorkerFileViewRuntimeSource,
	mutation: BridgeCommWorkerFileViewRuntimeMutation,
): BridgeCommWorkerFileViewRuntimeSource {
	const normalized = normalizeBridgeCommWorkerFileViewRuntimeSource(source);
	const contentRequestsByItemId = requiredMutableMap(normalized.contentRequestsByItemId);
	const filePathsByItemId = requiredMutableMap(normalized.filePathsByItemId);
	const rowIndexByItemId = requiredMutableMap(normalized.rowIndexByItemId);
	const rowsByIndex = requiredMutableMap(normalized.rowsByIndex);
	if (mutation.kind === 'reset') {
		contentRequestsByItemId.clear();
		filePathsByItemId.clear();
		rowIndexByItemId.clear();
		rowsByIndex.clear();
	} else {
		if (mutation.resetContent === true) contentRequestsByItemId.clear();
		for (const itemId of mutation.contentRequestRemovals) contentRequestsByItemId.delete(itemId);
		for (const itemId of mutation.filePathRemovals) filePathsByItemId.delete(itemId);
		for (const itemId of mutation.rowRemovals) {
			const index = rowIndexByItemId.get(itemId);
			if (index !== undefined) rowsByIndex.delete(index);
			rowIndexByItemId.delete(itemId);
		}
	}
	for (const request of mutation.contentRequestUpserts) {
		contentRequestsByItemId.set(request.itemId, request);
	}
	for (const path of mutation.filePathUpserts) filePathsByItemId.set(path.itemId, path.path);
	for (const row of mutation.rowUpserts) {
		const previousIndex = rowIndexByItemId.get(row.id);
		if (previousIndex !== undefined && previousIndex !== row.index)
			rowsByIndex.delete(previousIndex);
		const displacedRow = rowsByIndex.get(row.index);
		if (displacedRow !== undefined && displacedRow.id !== row.id) {
			rowIndexByItemId.delete(displacedRow.id);
		}
		rowsByIndex.set(row.index, row);
		rowIndexByItemId.set(row.id, row.index);
	}
	return normalized;
}

export function applyFileViewRuntimeMutationTrackingSelectedRequest(props: {
	readonly mutation: BridgeCommWorkerFileViewRuntimeMutation;
	readonly selectedId: string | null;
	readonly source: BridgeCommWorkerFileViewRuntimeSource;
}): BridgeCommWorkerFileViewRuntimeMutationApplication {
	const previousSelectedRequest =
		props.selectedId === null ? null : findFileViewContentRequest(props.source, props.selectedId);
	const nextSource = applyFileViewRuntimeMutationToSource(props.source, props.mutation);
	const nextSelectedRequest =
		props.selectedId === null ? null : findFileViewContentRequest(nextSource, props.selectedId);
	return {
		nextSource,
		selectedContentRequestChanged: !areFileViewContentRequestsEquivalent(
			previousSelectedRequest,
			nextSelectedRequest,
		),
	};
}

export function normalizeBridgeCommWorkerFileViewRuntimeSource(
	source: BridgeCommWorkerFileViewRuntimeSource,
): BridgeCommWorkerFileViewRuntimeSource {
	return {
		...source,
		contentRequestsByItemId:
			source.contentRequestsByItemId ??
			new Map(source.contentRequests.map((request) => [request.itemId, request])),
		filePathsByItemId: source.filePathsByItemId ?? new Map(),
		rowIndexByItemId:
			source.rowIndexByItemId ?? new Map(source.rows.map((row) => [row.id, row.index])),
		rowsByIndex: source.rowsByIndex ?? new Map(source.rows.map((row) => [row.index, row])),
	};
}

export function findFileViewContentRequest(
	source: BridgeCommWorkerFileViewRuntimeSource,
	itemId: string,
): BridgeCommWorkerFileViewContentRequest | null {
	return (
		source.contentRequestsByItemId?.get(itemId) ??
		source.contentRequests.find((request) => request.itemId === itemId) ??
		null
	);
}

export function areFileViewContentRequestsEquivalent(
	left: BridgeCommWorkerFileViewContentRequest | null,
	right: BridgeCommWorkerFileViewContentRequest | null,
): boolean {
	if (left === null || right === null) return left === right;
	return (
		left.itemId === right.itemId &&
		left.path === right.path &&
		left.language === right.language &&
		left.sizeBytes === right.sizeBytes &&
		left.contentDescriptor.descriptorId === right.contentDescriptor.descriptorId &&
		left.contentDescriptor.expectedSha256 === right.contentDescriptor.expectedSha256 &&
		left.contentDescriptor.source.sourceCursor === right.contentDescriptor.source.sourceCursor &&
		left.contentDescriptor.source.subscriptionGeneration ===
			right.contentDescriptor.source.subscriptionGeneration
	);
}

export function didSelectedFileViewContentRequestChange(props: {
	readonly nextFileViewRuntimeSource: BridgeCommWorkerFileViewRuntimeSource;
	readonly previousFileViewRuntimeSource: BridgeCommWorkerFileViewRuntimeSource;
	readonly selectedId: string | null;
}): boolean {
	if (props.selectedId === null) {
		return false;
	}
	return !areFileViewContentRequestsEquivalent(
		findFileViewContentRequest(props.previousFileViewRuntimeSource, props.selectedId),
		findFileViewContentRequest(props.nextFileViewRuntimeSource, props.selectedId),
	);
}

function requiredMutableMap<TKey, TValue>(
	map: ReadonlyMap<TKey, TValue> | undefined,
): Map<TKey, TValue> {
	if (!(map instanceof Map)) throw new Error('Bridge File runtime source map is unavailable.');
	return map;
}
