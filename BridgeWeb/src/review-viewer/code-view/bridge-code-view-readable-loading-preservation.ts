import type { CodeViewItem } from '@pierre/diffs';

import type {
	BridgeContentRole,
	BridgeReviewItemDescriptor,
} from '../../foundation/review-package/bridge-review-package.js';
import type { BridgeCodeViewItem } from './bridge-code-view-materialization.js';

export function shouldPreserveBridgeCodeViewReadableItemDuringLoading(props: {
	readonly existingItem: CodeViewItem | undefined;
	readonly itemDescriptor: BridgeReviewItemDescriptor;
	readonly loadingItem: BridgeCodeViewItem;
}): boolean {
	if (
		!isReadableBridgeCodeViewItem(props.existingItem) ||
		props.existingItem.id !== props.itemDescriptor.itemId ||
		props.existingItem.bridgeMetadata.itemId !== props.itemDescriptor.itemId ||
		props.existingItem.type !== props.loadingItem.type ||
		props.existingItem.bridgeMetadata.displayPath !== props.loadingItem.bridgeMetadata.displayPath
	) {
		return false;
	}

	const currentContentIdentity =
		props.existingItem.type === 'diff'
			? props.itemDescriptor.cacheKey
			: currentFileContentIdentity({
					contentRoles: props.existingItem.bridgeMetadata.contentRoles,
					itemDescriptor: props.itemDescriptor,
				});
	return (
		currentContentIdentity !== null &&
		materializedCacheKeyMatchesIdentity({
			cacheKey: props.existingItem.bridgeMetadata.cacheKey,
			contentIdentity: currentContentIdentity,
		})
	);
}

function isReadableBridgeCodeViewItem(item: CodeViewItem | undefined): item is BridgeCodeViewItem {
	if (!isBridgeCodeViewItem(item)) {
		return false;
	}
	return isReadableBridgeCodeViewContentState(item.bridgeMetadata.contentState);
}

export function isReadableBridgeCodeViewContentState(
	contentState: string | null | undefined,
): contentState is 'hydrated' | 'windowed' {
	return contentState === 'hydrated' || contentState === 'windowed';
}

function isBridgeCodeViewItem(item: CodeViewItem | undefined): item is BridgeCodeViewItem {
	return item !== undefined && 'bridgeMetadata' in item;
}

function currentFileContentIdentity(props: {
	readonly contentRoles: readonly BridgeContentRole[];
	readonly itemDescriptor: BridgeReviewItemDescriptor;
}): string | null {
	const [contentRole] = props.contentRoles;
	if (props.contentRoles.length !== 1 || contentRole === undefined) {
		return null;
	}
	const contentHandle = props.itemDescriptor.contentRoles[contentRole];
	return contentHandle?.cacheKey ?? null;
}

function materializedCacheKeyMatchesIdentity(props: {
	readonly cacheKey: string;
	readonly contentIdentity: string;
}): boolean {
	return (
		props.cacheKey === props.contentIdentity ||
		props.cacheKey.startsWith(`${props.contentIdentity}:window:`)
	);
}
