import type { BridgeCommWorkerDemandMember } from './bridge-comm-worker-reconciler.js';
import {
	bridgeProductMaximumViewScopeItemCount,
	type BridgeProductViewScopeRequest,
} from './bridge-product-view-control-wire-contracts.js';
type FileMetadataInterest = Extract<
	BridgeProductViewScopeRequest['scope'],
	{ kind: 'file' }
>['interests'][number];
type FileMetadataInterestLane = FileMetadataInterest['lane'];
type ReviewMetadataInterest = Extract<
	BridgeProductViewScopeRequest['scope'],
	{ kind: 'review' }
>['interests'][number];
type ReviewMetadataInterestLane = ReviewMetadataInterest['lane'];
const fileMetadataInterestLanePriority: readonly FileMetadataInterestLane[] = [
	'foreground',
	'visible',
	'nearby',
	'active',
	'speculative',
	'idle',
];

const reviewMetadataInterestLanePriority: readonly ReviewMetadataInterestLane[] = [
	'foreground',
	'visible',
	'nearby',
	'active',
	'speculative',
	'idle',
];

export function reviewMetadataInterestLaneForDemandRole(
	role: BridgeCommWorkerDemandMember['role'],
): ReviewMetadataInterestLane {
	switch (role) {
		case 'selected':
			return 'foreground';
		case 'visible':
		case 'nearby':
		case 'speculative':
			return role;
		case 'background':
			return 'idle';
	}
}

export function reviewMetadataInterestsInPriorityOrder(
	itemIdsByLane: ReadonlyMap<ReviewMetadataInterestLane, readonly string[]>,
): readonly ReviewMetadataInterest[] {
	const claimedItemIds = new Set<string>();
	const interests: ReviewMetadataInterest[] = [];
	for (const lane of reviewMetadataInterestLanePriority) {
		const remainingItemCount = bridgeProductMaximumViewScopeItemCount - claimedItemIds.size;
		if (remainingItemCount <= 0) break;
		const itemIds: string[] = [];
		for (const itemId of itemIdsByLane.get(lane) ?? []) {
			if (claimedItemIds.has(itemId)) continue;
			claimedItemIds.add(itemId);
			itemIds.push(itemId);
			if (itemIds.length === remainingItemCount) break;
		}
		if (itemIds.length > 0) interests.push({ itemIds, lane });
	}
	return interests;
}

export function fileMetadataInterestsInPriorityOrder(
	pathsByLane: ReadonlyMap<FileMetadataInterestLane, readonly string[]>,
): readonly FileMetadataInterest[] {
	const claimedPaths = new Set<string>();
	const interests: FileMetadataInterest[] = [];
	for (const lane of fileMetadataInterestLanePriority) {
		const remainingPathCount = bridgeProductMaximumViewScopeItemCount - claimedPaths.size;
		if (remainingPathCount <= 0) break;
		const paths: string[] = [];
		for (const path of pathsByLane.get(lane) ?? []) {
			if (claimedPaths.has(path)) continue;
			claimedPaths.add(path);
			paths.push(path);
			if (paths.length === remainingPathCount) break;
		}
		if (paths.length > 0) interests.push({ lane, paths });
	}
	return interests;
}
