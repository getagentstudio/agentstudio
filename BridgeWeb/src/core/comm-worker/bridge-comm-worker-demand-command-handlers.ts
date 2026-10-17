import type {
	BridgeCommWorkerDemandExecutionScheduleRequest,
	BridgeCommWorkerSelectedReviewContentReadyPreparationRequest,
} from './bridge-comm-worker-command-handler-contracts.js';
import type { BridgeCommWorkerFileViewRuntimeSource } from './bridge-comm-worker-file-view-runtime-source.js';
import type { BridgeCommWorkerFileMetadataDemand } from './bridge-comm-worker-product-controller.js';
import { buildBridgeWorkerReadyHealthEvent } from './bridge-comm-worker-protocol.js';
import type {
	BridgeCommWorkerRow,
	BridgeCommWorkerStore,
	BridgeCommWorkerViewportRange,
} from './bridge-comm-worker-store.js';
import type {
	BridgeWorkerFileViewContentMetadata,
	BridgeWorkerReviewContentMetadata,
	BridgeWorkerReviewInvalidateCommand,
	BridgeWorkerServerToMainMessage,
	BridgeWorkerViewportCommand,
} from './bridge-worker-contracts.js';

interface HandleBridgeWorkerReviewInvalidateCommandProps {
	readonly createSequence: () => number;
	readonly message: BridgeWorkerReviewInvalidateCommand;
	readonly scheduleSelectedReviewContentReadyPreparation: (
		request: BridgeCommWorkerSelectedReviewContentReadyPreparationRequest,
	) => void;
	readonly scheduleDemandExecution?: (
		request: BridgeCommWorkerDemandExecutionScheduleRequest,
	) => void;
	readonly store: BridgeCommWorkerStore;
}

export function handleBridgeWorkerReviewInvalidateCommand(
	props: HandleBridgeWorkerReviewInvalidateCommandProps,
): readonly BridgeWorkerServerToMainMessage[] {
	props.store.actions.applyReviewInvalidationFact({
		epoch: props.message.epoch,
		itemIds: props.message.itemIds,
		pathHints: props.message.pathHints,
		reason: props.message.reason,
		scope: props.message.scope,
	});
	const slicePatch = props.store.actions.takePendingSlicePatchEvent({
		epoch: props.message.epoch,
		sequence: props.createSequence(),
	});
	const selectedId = props.store.getState().selectedId;
	if (
		selectedId !== null &&
		props.store.getState().demandByKey.get(selectedId) === `selected:${props.message.epoch}` &&
		isBridgeWorkerReviewContentMetadata(
			props.store.getState().contentMetadataByItemId.get(selectedId) ?? null,
		)
	) {
		props.scheduleSelectedReviewContentReadyPreparation({
			epoch: props.message.epoch,
			itemId: selectedId,
			store: props.store,
		});
	}
	const affectedItemIds = resolveReviewInvalidationAffectedItemIds({
		message: props.message,
		store: props.store,
	});
	props.scheduleDemandExecution?.({
		...(affectedItemIds === undefined ? {} : { affectedItemIds }),
		cause: 'reviewInvalidate',
		epoch: props.message.epoch,
		store: props.store,
	});
	return [
		...(slicePatch === null ? [] : [slicePatch]),
		buildBridgeWorkerReadyHealthEvent(props.message.requestId),
	];
}

export function isBridgeWorkerReviewContentMetadata(
	metadata: BridgeWorkerReviewContentMetadata | BridgeWorkerFileViewContentMetadata | null,
): metadata is BridgeWorkerReviewContentMetadata {
	return metadata !== null && 'availableContentRoles' in metadata;
}

interface HandleBridgeWorkerViewportCommandProps {
	readonly createSequence: () => number;
	readonly fileViewRuntimeSource: BridgeCommWorkerFileViewRuntimeSource;
	readonly message: BridgeWorkerViewportCommand;
	readonly scheduleDemandExecution?: (
		request: BridgeCommWorkerDemandExecutionScheduleRequest,
	) => void;
	readonly store: BridgeCommWorkerStore;
	readonly updateFileMetadataDemand?: (demand: BridgeCommWorkerFileMetadataDemand) => void;
}

export function handleBridgeWorkerViewportCommand(
	props: HandleBridgeWorkerViewportCommandProps,
): readonly BridgeWorkerServerToMainMessage[] {
	props.store.actions.applyViewportFact({
		firstVisibleIndex: props.message.firstVisibleIndex,
		lastVisibleIndex: props.message.lastVisibleIndex,
		visibleItemIds: props.message.visibleItemIds,
	});
	if (props.message.surface === 'review') {
		props.store.renderFulfillmentRegistry.updateVisibleItemIds(props.message.visibleItemIds);
	}
	if (props.message.surface === 'fileView') {
		publishBridgeCommWorkerFileMetadataDemand({
			epoch: props.message.epoch,
			fileViewRuntimeSource: props.fileViewRuntimeSource,
			store: props.store,
			...(props.updateFileMetadataDemand === undefined
				? {}
				: { updateFileMetadataDemand: props.updateFileMetadataDemand }),
		});
	}
	const slicePatch = props.store.actions.takePendingSlicePatchEvent({
		epoch: props.message.epoch,
		sequence: props.createSequence(),
	});
	if (props.message.surface === 'review') {
		props.scheduleDemandExecution?.({
			cause: 'viewport',
			epoch: props.message.epoch,
			store: props.store,
		});
	}
	return [
		...(slicePatch === null ? [] : [slicePatch]),
		buildBridgeWorkerReadyHealthEvent(props.message.requestId),
	];
}

export function publishBridgeCommWorkerFileMetadataDemand(props: {
	readonly epoch: number;
	readonly fileViewRuntimeSource: BridgeCommWorkerFileViewRuntimeSource;
	readonly store: BridgeCommWorkerStore;
	readonly updateFileMetadataDemand?: (demand: BridgeCommWorkerFileMetadataDemand) => void;
}): void {
	if (props.updateFileMetadataDemand === undefined) return;
	const state = props.store.getState();
	if (state.selectedId === null && state.viewportRange === null) return;
	const filePathsByItemId = props.fileViewRuntimeSource.filePathsByItemId ?? new Map();
	const selectedPath =
		state.selectedId === null ? null : (filePathsByItemId.get(state.selectedId) ?? null);
	const visiblePaths = state.visibleIds.flatMap((itemId): readonly string[] => {
		const path = filePathsByItemId.get(itemId);
		return path === undefined ? [] : [path];
	});
	const nearbyPaths = bridgeCommWorkerNearbyFilePaths({
		filePathsByItemId,
		rows: props.fileViewRuntimeSource.rows,
		...(props.fileViewRuntimeSource.rowsByIndex === undefined
			? {}
			: { rowsByIndex: props.fileViewRuntimeSource.rowsByIndex }),
		viewportRange: state.viewportRange,
	});
	props.updateFileMetadataDemand({
		epoch: props.epoch,
		nearbyPaths,
		selectedPath,
		visiblePaths,
	});
}

function bridgeCommWorkerNearbyFilePaths(props: {
	readonly filePathsByItemId: ReadonlyMap<string, string>;
	readonly rows: readonly BridgeCommWorkerRow[];
	readonly rowsByIndex?: ReadonlyMap<number, BridgeCommWorkerRow>;
	readonly viewportRange: BridgeCommWorkerViewportRange | null;
}): readonly string[] {
	const viewportRange = props.viewportRange;
	if (viewportRange === null) return [];
	const nearbyLowerIndex = Math.max(0, viewportRange.firstVisibleIndex - 1);
	const nearbyUpperIndex = viewportRange.lastVisibleIndex + 1;
	if (props.rowsByIndex !== undefined) {
		const paths: string[] = [];
		for (let index = nearbyLowerIndex; index <= nearbyUpperIndex; index += 1) {
			if (index >= viewportRange.firstVisibleIndex && index <= viewportRange.lastVisibleIndex) {
				continue;
			}
			const row = props.rowsByIndex.get(index);
			const path = row === undefined ? undefined : props.filePathsByItemId.get(row.id);
			if (path !== undefined) paths.push(path);
		}
		return paths;
	}
	return props.rows.flatMap((row): readonly string[] => {
		if (
			row.index < nearbyLowerIndex ||
			row.index > nearbyUpperIndex ||
			(row.index >= viewportRange.firstVisibleIndex && row.index <= viewportRange.lastVisibleIndex)
		) {
			return [];
		}
		const path = props.filePathsByItemId.get(row.id);
		return path === undefined ? [] : [path];
	});
}

function resolveReviewInvalidationAffectedItemIds(props: {
	readonly message: BridgeWorkerReviewInvalidateCommand;
	readonly store: BridgeCommWorkerStore;
}): readonly string[] | undefined {
	if (props.message.scope === 'package' || props.message.scope === 'treeWindow') {
		return undefined;
	}
	const itemIds = new Set(props.message.itemIds);
	for (const itemId of findReviewItemIdsByPathHints({
		pathHints: props.message.pathHints,
		store: props.store,
	})) {
		itemIds.add(itemId);
	}
	return Array.from(itemIds);
}

function findReviewItemIdsByPathHints(props: {
	readonly pathHints: readonly string[];
	readonly store: BridgeCommWorkerStore;
}): readonly string[] {
	const pathHints = new Set(props.pathHints);
	return Array.from(props.store.getState().contentMetadataByItemId.values())
		.filter(
			(metadata): metadata is BridgeWorkerReviewContentMetadata =>
				isBridgeWorkerReviewContentMetadata(metadata) && pathHints.has(metadata.path),
		)
		.map((metadata) => metadata.itemId);
}
