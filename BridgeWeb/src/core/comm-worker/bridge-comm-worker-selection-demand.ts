import type {
	BridgeCommWorkerStore,
	BridgeCommWorkerStoreState,
} from './bridge-comm-worker-store.js';
import { isBridgeWorkerFileViewContentMetadata } from './bridge-worker-contracts.js';

export function scheduleSelectedFileViewContentReadyPreparationForCurrentDemand(props: {
	readonly epoch: number;
	readonly schedulePreparation: (request: {
		readonly epoch: number;
		readonly itemId: string;
		readonly store: BridgeCommWorkerStore;
	}) => void;
	readonly selectedContentMetadataChanged: boolean;
	readonly selectedContentRequestChanged: boolean;
	readonly store: BridgeCommWorkerStore;
}): void {
	const selectedId = props.store.getState().selectedId;
	if (
		selectedId === null ||
		!isSelectedContentReadyPreparationCurrent({
			epoch: props.epoch,
			itemId: selectedId,
			store: props.store,
		})
	) {
		return;
	}
	const metadata = props.store.getState().contentMetadataByItemId.get(selectedId) ?? null;
	if (!isBridgeWorkerFileViewContentMetadata(metadata)) return;
	if (!props.selectedContentMetadataChanged && !props.selectedContentRequestChanged) return;
	const availability = props.store.getState().availabilityByItemId.get(selectedId);
	if (availability !== 'loading' && availability !== 'stale' && availability !== 'ready') return;
	props.schedulePreparation({ epoch: props.epoch, itemId: selectedId, store: props.store });
}

export function isSelectedContentReadyPreparationCurrent(props: {
	readonly epoch: number;
	readonly itemId: string;
	readonly store: BridgeCommWorkerStore;
}): boolean {
	const state = props.store.getState();
	return (
		state.selectedId === props.itemId &&
		state.demandByKey.get(props.itemId) === `selected:${props.epoch}`
	);
}

export function readSelectedContentDemandEpoch(state: BridgeCommWorkerStoreState): number | null {
	if (!state.selectedDemandEnabled || state.selectedId === null) return null;
	const selectedDemandKey = state.demandByKey.get(state.selectedId);
	const selectedDemandEpochMatch = /^selected:(\d+)$/u.exec(selectedDemandKey ?? '');
	return selectedDemandEpochMatch === null ? null : Number(selectedDemandEpochMatch[1]);
}
