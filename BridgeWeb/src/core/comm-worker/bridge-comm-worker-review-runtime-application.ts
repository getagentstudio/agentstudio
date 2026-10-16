import { isReviewRuntimeSourceExecutableForItem } from './bridge-comm-worker-review-source-diff.js';
import type { BridgeCommWorkerReviewRuntimeSource } from './bridge-comm-worker-review-source-diff.js';
import type {
	BridgeCommWorkerReviewRowMutation,
	BridgeCommWorkerStore,
} from './bridge-comm-worker-store.js';
import type { BridgeWorkerServerToMainMessage } from './bridge-worker-contracts.js';

export interface BridgeCommWorkerReviewRuntimeApplicationTransaction {
	readonly commit: () => void;
	readonly rollback: () => void;
	readonly runPostCommitEffects: () => void;
}

export interface BridgeCommWorkerReviewMetadataApplication {
	readonly affectedItemIds: readonly string[];
	readonly affectedRowIds: readonly string[];
	readonly operationCorrelationId?: string | null;
	readonly completeContentItemIds?: readonly string[];
	readonly completeRowIds?: readonly string[];
	readonly projectionRevision: number;
	readonly removedItemIds: readonly string[];
	readonly reset: boolean;
	readonly rowMutation: BridgeCommWorkerReviewRowMutation;
	readonly source: BridgeCommWorkerReviewRuntimeSource;
	readonly sourceEpoch: number;
	readonly workerDerivationEpoch: number;
}

export function applyBridgeCommWorkerReviewMetadataApplication(props: {
	readonly application: BridgeCommWorkerReviewMetadataApplication;
	readonly createSequence: () => number;
	readonly readRuntimeSource: () => BridgeCommWorkerReviewRuntimeSource;
	readonly scheduleDemandExecution?: (request: {
		readonly affectedItemIds: readonly string[];
		readonly cause: 'reviewMetadata';
		readonly epoch: number;
		readonly sourceChurnRevision?: number;
		readonly store: BridgeCommWorkerStore;
	}) => void;
	readonly scheduleReset?: (request: {
		readonly affectedItemIds: readonly string[];
		readonly cause: 'reviewMetadata';
		readonly epoch: number;
		readonly readReviewRuntimeSource: () => BridgeCommWorkerReviewRuntimeSource;
		readonly store: BridgeCommWorkerStore;
	}) => void;
	readonly scheduleSelectedPreparation: (request: {
		readonly epoch: number;
		readonly itemId: string;
		readonly store: BridgeCommWorkerStore;
	}) => void;
	readonly store: BridgeCommWorkerStore;
	readonly updateRuntimeSource: (source: BridgeCommWorkerReviewRuntimeSource) => void;
}): readonly BridgeWorkerServerToMainMessage[] {
	const { application } = props;
	props.updateRuntimeSource(application.source);
	applyUnavailableReviewMetadataTerminals({
		affectedItemIds: application.affectedItemIds,
		epoch: application.sourceEpoch,
		source: application.source,
		store: props.store,
	});
	if (application.reset) {
		props.store.actions.applyReviewSourceUpdateFact({
			...(application.completeContentItemIds === undefined
				? {}
				: { completeContentItemIds: application.completeContentItemIds }),
			...(application.completeRowIds === undefined
				? {}
				: { completeRowIds: application.completeRowIds }),
			contentItems: application.source.contentItems,
			epoch: application.sourceEpoch,
			removedContentItemIds: application.removedItemIds,
			resetComplete: true,
			rows: application.source.rows,
		});
		props.scheduleReset?.({
			affectedItemIds: application.affectedItemIds,
			cause: 'reviewMetadata',
			epoch: application.sourceEpoch,
			readReviewRuntimeSource: props.readRuntimeSource,
			store: props.store,
		});
		const resetPatch = props.store.actions.takePendingSlicePatchEvent({
			epoch: application.sourceEpoch,
			sequence: props.createSequence(),
		});
		return resetPatch === null ? [] : [resetPatch];
	}
	const affectedItemIds = new Set(application.affectedItemIds);
	props.store.actions.applyReviewSourceUpdateFact({
		...(application.completeContentItemIds === undefined
			? {}
			: { completeContentItemIds: application.completeContentItemIds }),
		...(application.completeRowIds === undefined
			? {}
			: { completeRowIds: application.completeRowIds }),
		contentItems: application.source.contentItems.filter((item) =>
			affectedItemIds.has(item.itemId),
		),
		epoch: application.sourceEpoch,
		removedContentItemIds: application.removedItemIds,
		resetComplete: false,
		rows: application.completeRowIds === undefined ? [] : application.source.rows,
	});
	if (application.completeRowIds === undefined) {
		props.store.actions.applyReviewRowMutationFact({
			epoch: application.sourceEpoch,
			mutation: application.rowMutation,
		});
	}
	const selectedId = props.store.getState().selectedId;
	if (
		selectedId !== null &&
		affectedItemIds.has(selectedId) &&
		isReviewRuntimeSourceExecutableForItem(application.source, selectedId)
	) {
		const selectedDemand = props.store.actions.applySelectedSourceChurnFact({
			itemId: selectedId,
		});
		if (selectedDemand.selectedDemandEpoch !== null) {
			props.scheduleSelectedPreparation({
				epoch: selectedDemand.selectedDemandEpoch,
				itemId: selectedId,
				store: props.store,
			});
		}
	}
	if (application.affectedItemIds.length > 0) {
		props.scheduleDemandExecution?.({
			affectedItemIds: application.affectedItemIds,
			cause: 'reviewMetadata',
			epoch: application.sourceEpoch,
			sourceChurnRevision: application.projectionRevision,
			store: props.store,
		});
	}
	const slicePatch = props.store.actions.takePendingSlicePatchEvent({
		epoch: application.sourceEpoch,
		sequence: props.createSequence(),
	});
	return slicePatch === null ? [] : [slicePatch];
}

function applyUnavailableReviewMetadataTerminals(props: {
	readonly affectedItemIds: readonly string[];
	readonly epoch: number;
	readonly source: BridgeCommWorkerReviewRuntimeSource;
	readonly store: BridgeCommWorkerStore;
}): void {
	const state = props.store.getState();
	const visibleItemIds = new Set(state.visibleIds);
	const terminalItemIds = props.affectedItemIds.filter(
		(itemId) =>
			!isReviewRuntimeSourceExecutableForItem(props.source, itemId) &&
			(state.paintReadyByItemId.has(itemId) ||
				state.selectedId === itemId ||
				visibleItemIds.has(itemId)),
	);
	if (terminalItemIds.length === 0) return;

	props.store.actions.applyReviewInvalidationFact({
		epoch: props.epoch,
		itemIds: terminalItemIds,
		pathHints: [],
		reason: 'sourceChanged',
		scope: 'items',
	});
	for (const itemId of terminalItemIds) {
		props.store.actions.applyContentTerminalAvailability({
			itemId,
			reason: 'source_reset',
			sourceEpoch: props.epoch,
			state: 'unavailable',
		});
	}
}
