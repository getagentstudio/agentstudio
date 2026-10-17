import type { CodeViewFileItem } from '@pierre/diffs';

import { bridgeCodeViewPresentationItemWithExactSource } from '../review-viewer/code-view/bridge-code-view-render-fulfillment.js';
import type { BridgeFileViewerSelectedCodeViewItem } from './bridge-file-viewer-code-view-items.js';

export type BridgeFileViewerPresentationItem = BridgeFileViewerSelectedCodeViewItem &
	CodeViewFileItem;

/** The mounted Pierre owner outlives transient render-store gaps. Keep its versions
 * without retaining source bodies for previously visited files. */
export class BridgeFileViewerPresentationVersions {
	private readonly lastVersionByItemId = new Map<string, number>();
	private readonly presentationBySourceItem = new WeakMap<
		BridgeFileViewerPresentationItem,
		{
			readonly inputVersion: number | undefined;
			readonly item: BridgeFileViewerPresentationItem;
		}
	>();

	preparePresentationItem(
		inputItem: BridgeFileViewerPresentationItem,
		sourceItem: BridgeFileViewerPresentationItem = inputItem,
	): BridgeFileViewerPresentationItem {
		const lastVersion = this.lastVersionByItemId.get(inputItem.id) ?? 0;
		const previousPresentation = this.presentationBySourceItem.get(sourceItem);
		if (
			previousPresentation !== undefined &&
			previousPresentation.inputVersion === inputItem.version &&
			previousPresentation.item.version === lastVersion
		) {
			return previousPresentation.item;
		}
		const nextVersion = Math.max(inputItem.version ?? 0, lastVersion + 1);
		if (!Number.isSafeInteger(nextVersion)) {
			throw new Error('File Pierre presentation version exhausted its safe integer range.');
		}
		const presentationItem =
			inputItem.version === nextVersion
				? inputItem
				: bridgeCodeViewPresentationItemWithExactSource({
						presentationItem: { ...inputItem, version: nextVersion },
						sourceItem: inputItem,
					});
		this.lastVersionByItemId.set(inputItem.id, nextVersion);
		this.presentationBySourceItem.set(sourceItem, {
			inputVersion: inputItem.version,
			item: presentationItem,
		});
		return presentationItem;
	}
}
