import type { CodeViewFileItem } from '@pierre/diffs';

import type { BridgeWorkerCodeViewFileItem } from '../core/comm-worker/bridge-worker-pierre-render-job.js';
import type { BridgeFileViewerOpenState } from './bridge-file-viewer-display-model.js';

export type BridgeFileViewerCodePanelState = BridgeFileViewerOpenState;
export type BridgeFileViewerSelectedCodeViewItem = BridgeWorkerCodeViewFileItem;

export function bridgeFileViewerCodeViewItemsForPanelState(props: {
	readonly openFileState: BridgeFileViewerCodePanelState;
	readonly selectedCodeViewItem: BridgeFileViewerSelectedCodeViewItem | null;
	readonly lastCompleteCodeViewItem?: BridgeFileViewerSelectedCodeViewItem | null;
}): readonly (BridgeFileViewerSelectedCodeViewItem & CodeViewFileItem)[] {
	if (props.selectedCodeViewItem !== null && isExactPierreFileItem(props.selectedCodeViewItem)) {
		return [props.selectedCodeViewItem];
	}
	const retainedItem = props.lastCompleteCodeViewItem;
	const demandedFile = props.openFileState;
	if (
		props.selectedCodeViewItem === null &&
		(demandedFile.status === 'loading' || demandedFile.status === 'stale') &&
		retainedItem != null &&
		retainedItem.bridgeMetadata.itemId === demandedFile.fileId &&
		retainedItem.bridgeMetadata.displayPath === demandedFile.path &&
		isExactPierreFileItem(retainedItem)
	) {
		return [retainedItem];
	}
	return [];
}

function isExactPierreFileItem(
	item: BridgeFileViewerSelectedCodeViewItem,
): item is BridgeFileViewerSelectedCodeViewItem & CodeViewFileItem {
	return (
		optionalFieldIsAbsentOrDefined(item, 'collapsed') &&
		optionalFieldIsAbsentOrDefined(item, 'version') &&
		optionalFieldIsAbsentOrDefined(item.file, 'cacheKey') &&
		optionalFieldIsAbsentOrDefined(item.file, 'header') &&
		optionalFieldIsAbsentOrDefined(item.file, 'lang')
	);
}

function optionalFieldIsAbsentOrDefined<
	TRecord extends Readonly<Record<string, unknown>>,
	TKey extends keyof TRecord,
>(record: TRecord, key: TKey): boolean {
	return record[key] !== undefined || !Object.hasOwn(record, key);
}
