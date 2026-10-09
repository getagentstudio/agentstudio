import type {
	BridgeCommWorkerRenderFulfillmentLifecycleAdvance,
	CreateBridgeCommWorkerCommandHandlerProps,
} from './bridge-comm-worker-command-handler-contracts.js';
import {
	postPreparedBridgeCommWorkerMessage,
	type BridgeCommWorkerPort,
} from './bridge-comm-worker-entry.js';
import type { BridgeCommWorkerSelectedFileLifecycleTelemetry } from './bridge-comm-worker-operation-lifecycle.js';
import type { BridgeCommWorkerSelectedFileContentOperationController } from './bridge-comm-worker-selected-file-content-operation.js';
import { readSelectedContentDemandEpoch } from './bridge-comm-worker-selection-demand.js';
import type { BridgeCommWorkerStore } from './bridge-comm-worker-store.js';
import {
	bridgeWorkerFileRenderPatchesFromSlicePatchEvent,
	prepareBridgeWorkerFileRenderPatchEvent,
} from './bridge-worker-file-view-content-ready.js';

export function advanceBridgeCommWorkerFileRenderFulfillmentLifecycle(props: {
	readonly atMilliseconds: number;
	readonly onExhausted: CreateBridgeCommWorkerCommandHandlerProps['onFileVisibleRenderExhausted'];
	readonly scheduleSelectedPreparation: CreateBridgeCommWorkerCommandHandlerProps['scheduleSelectedFileViewContentReadyPreparation'];
	readonly store: BridgeCommWorkerStore;
}): BridgeCommWorkerRenderFulfillmentLifecycleAdvance {
	const state = props.store.getState();
	const registry = props.store.renderFulfillmentRegistry;
	registry.updateVisibleItemIds([
		...state.visibleIds,
		...(state.selectedId === null ? [] : [state.selectedId]),
	]);
	const expiredItemIds = registry.expireReceiptLeases(props.atMilliseconds);
	const queuedExpiry = registry.expireVisibleQueuedLeases(props.atMilliseconds);
	const exhaustedItemIds = [
		...queuedExpiry.exhaustedItemIds,
		...expiredItemIds.filter((itemId) => registry.getItemState(itemId)?.stage === 'failed'),
	];
	if (exhaustedItemIds.length > 0) props.onExhausted?.(exhaustedItemIds, props.store);
	const releasedItemIds = registry.releaseReadyRetries(props.atMilliseconds);
	const selectedDemandEpoch = readSelectedContentDemandEpoch(state);
	if (
		state.selectedId !== null &&
		selectedDemandEpoch !== null &&
		releasedItemIds.includes(state.selectedId)
	) {
		props.scheduleSelectedPreparation({
			epoch: selectedDemandEpoch,
			itemId: state.selectedId,
			store: props.store,
		});
	}
	return { nextWakeAtMilliseconds: registry.nextLifecycleWakeAtMilliseconds() };
}

export function retryBridgeCommWorkerExhaustedFileRender(props: {
	readonly scheduleSelectedPreparation: CreateBridgeCommWorkerCommandHandlerProps['scheduleSelectedFileViewContentReadyPreparation'];
	readonly store: BridgeCommWorkerStore;
}): void {
	const itemIds = props.store.renderFulfillmentRegistry.retryExhaustedPublications();
	const state = props.store.getState();
	const selectedDemandEpoch = readSelectedContentDemandEpoch(state);
	if (
		state.selectedId !== null &&
		selectedDemandEpoch !== null &&
		itemIds.includes(state.selectedId)
	) {
		props.scheduleSelectedPreparation({
			epoch: selectedDemandEpoch,
			itemId: state.selectedId,
			store: props.store,
		});
	}
}

export function settleBridgeCommWorkerExhaustedFileRender(props: {
	readonly controller: BridgeCommWorkerSelectedFileContentOperationController;
	readonly createSequence: () => number;
	readonly itemIds: readonly string[];
	readonly port: BridgeCommWorkerPort;
	readonly store: BridgeCommWorkerStore;
	readonly telemetry: BridgeCommWorkerSelectedFileLifecycleTelemetry;
}): boolean {
	const operation = props.controller.current;
	if (operation === null || !props.itemIds.includes(operation.itemId)) return false;
	const fulfillment = props.store.renderFulfillmentRegistry.getItemState(operation.itemId);
	if (
		fulfillment?.stage !== 'failed' ||
		fulfillment.closedAttempts.at(-1)?.attemptId !== operation.renderReceiptIdentity?.attemptId
	)
		return false;
	props.telemetry.disposition(operation, 'rejected');
	props.controller.settle(operation.generation);
	props.store.actions.applyContentTerminalAvailability({
		itemId: operation.itemId,
		reason: 'load_failed',
		sourceEpoch: operation.selectionEpoch,
		state: 'failed',
	});
	if (operation.workerDerivationEpoch !== null) {
		const sequence = props.createSequence();
		const patch = props.store.actions.takePendingSlicePatchEvent({
			epoch: operation.workerDerivationEpoch,
			sequence,
		});
		postPreparedBridgeCommWorkerMessage(
			props.port,
			prepareBridgeWorkerFileRenderPatchEvent({
				patches: bridgeWorkerFileRenderPatchesFromSlicePatchEvent(patch),
				publicationSequence: sequence,
				workerDerivationEpoch: operation.workerDerivationEpoch,
			}),
		);
	}
	return true;
}
