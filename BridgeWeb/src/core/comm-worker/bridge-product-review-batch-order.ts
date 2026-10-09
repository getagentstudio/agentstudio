import type { BridgeProductReviewBatchRecord } from './bridge-product-review-batch-record-contracts.js';

type ReviewBatchItem = Extract<BridgeProductReviewBatchRecord, { readonly recordKind: 'item' }>;

export interface BridgeProductReviewBatchTreeRow {
	readonly depth: number;
	readonly id: string;
	readonly index: number;
	readonly isDirectory: boolean;
	readonly itemId: string | null;
	readonly parentId: string | null;
	readonly path: string;
}

export interface BridgeProductReviewBatchOrder {
	readonly orderedItems: readonly ReviewBatchItem[];
	readonly treeRows: readonly BridgeProductReviewBatchTreeRow[];
}

/** Derives the complete logical Review order before the application bank swaps. */
export async function deriveBridgeProductReviewBatchOrder(
	items: readonly ReviewBatchItem[],
): Promise<BridgeProductReviewBatchOrder> {
	const orderedItems = [...items].sort(
		(left, right) => left.sortKey - right.sortKey || compareIdentifiers(left.itemId, right.itemId),
	);
	const itemIds = new Set<string>();
	const directoryPaths = new Set<string>();
	for (const item of orderedItems) {
		if (itemIds.has(item.itemId)) throw new Error('Review batch contains a duplicate item id.');
		itemIds.add(item.itemId);
		const path = item.headPath ?? item.basePath ?? item.itemId;
		const segments = path.split('/');
		const expectedParent = segments.length > 1 ? segments.slice(0, -1).join('/') : null;
		if (item.parentPath !== expectedParent) {
			throw new Error('Review batch item parent differs from its display path.');
		}
		for (let depth = 1; depth < segments.length; depth += 1) {
			directoryPaths.add(segments.slice(0, depth).join('/'));
		}
	}
	const directoryIds = new Map(
		await Promise.all(
			[...directoryPaths].map(
				async (path): Promise<readonly [string, string]> => [
					path,
					`review-directory-${(await sha256Hex(path)).slice(0, 32)}`,
				],
			),
		),
	);
	const treeRows: BridgeProductReviewBatchTreeRow[] = [];
	const emittedDirectories = new Set<string>();
	for (const item of orderedItems) {
		const path = item.headPath ?? item.basePath ?? item.itemId;
		const segments = path.split('/');
		for (let depth = 1; depth < segments.length; depth += 1) {
			const directoryPath = segments.slice(0, depth).join('/');
			if (emittedDirectories.has(directoryPath)) continue;
			emittedDirectories.add(directoryPath);
			const parentPath = depth > 1 ? segments.slice(0, depth - 1).join('/') : null;
			const directoryId = directoryIds.get(directoryPath);
			if (directoryId === undefined) throw new Error('Review directory identity is missing.');
			treeRows.push({
				depth: depth - 1,
				id: directoryId,
				index: treeRows.length,
				isDirectory: true,
				itemId: null,
				parentId: parentPath === null ? null : (directoryIds.get(parentPath) ?? null),
				path: directoryPath,
			});
		}
		treeRows.push({
			depth: segments.length - 1,
			id: item.itemId,
			index: treeRows.length,
			isDirectory: false,
			itemId: item.itemId,
			parentId: item.parentPath === null ? null : (directoryIds.get(item.parentPath) ?? null),
			path,
		});
	}
	return { orderedItems, treeRows };
}

function compareIdentifiers(left: string, right: string): number {
	return left < right ? -1 : left > right ? 1 : 0;
}

async function sha256Hex(value: string): Promise<string> {
	const bytes = new TextEncoder().encode(value);
	const digest = new Uint8Array(await globalThis.crypto.subtle.digest('SHA-256', bytes));
	return [...digest].map((byte) => byte.toString(16).padStart(2, '0')).join('');
}
