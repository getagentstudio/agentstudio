import {
	type BridgeCommWorkerPort,
	postPreparedBridgeCommWorkerMessage,
} from './bridge-comm-worker-entry.js';
import type { BridgeCommWorkerFileViewContentRequest } from './bridge-comm-worker-file-view-runtime-mutation.js';
import type { BridgeCommWorkerStore } from './bridge-comm-worker-store.js';
import {
	isBridgeWorkerFileViewContentMetadata,
	type BridgeWorkerContentAvailabilityPatchPayload,
	type BridgeWorkerFileViewContentMetadata,
} from './bridge-worker-contracts.js';
import {
	type BridgeWorkerFetchedFileViewContentResource,
	fetchBridgeWorkerFileViewContentResource,
	type BridgeWorkerFileViewContentOpen,
} from './bridge-worker-file-view-content-fetch.js';
import {
	bridgeWorkerFileRenderPatchesFromSlicePatchEvent,
	commitBridgeWorkerFileViewContentReadyRenderPatch,
	planBridgeWorkerFileViewPierreRenderJob,
	prepareBridgeWorkerFileRenderPatchEvent,
	prepareBridgeWorkerFileViewContentRenderJobEventFromJob,
} from './bridge-worker-file-view-content-ready.js';
import type {
	BridgeWorkerDemandRank,
	BridgeWorkerPierreRenderBudget,
} from './bridge-worker-pierre-render-job.js';
import type { BeginBridgeWorkerRenderPublicationResult } from './bridge-worker-render-fulfillment-registry.js';

export type BridgeWorkerFileViewContentPreparationOutcome =
	| {
			readonly kind: 'paintedResidency';
	  }
	| {
			readonly kind: 'renderPublication';
			readonly publication: BeginBridgeWorkerRenderPublicationResult;
	  }
	| {
			readonly kind: 'terminal';
	  };

export interface DispatchSelectedBridgeWorkerFileViewContentReadyProps {
	readonly bridgeDemandRank: BridgeWorkerDemandRank;
	readonly budget: BridgeWorkerPierreRenderBudget;
	readonly contentRequests?: readonly BridgeCommWorkerFileViewContentRequest[];
	readonly contentRequestsByItemId?: ReadonlyMap<string, BridgeCommWorkerFileViewContentRequest>;
	readonly epoch: number;
	readonly itemId: string;
	readonly isPreparationCurrent?: () => boolean;
	readonly onPreparationOutcome?: (outcome: BridgeWorkerFileViewContentPreparationOutcome) => void;
	readonly openContent: BridgeWorkerFileViewContentOpen;
	readonly operationCorrelationId: string;
	readonly port: BridgeCommWorkerPort;
	readonly sequence: number;
	readonly signal?: AbortSignal;
	readonly store: BridgeCommWorkerStore;
	readonly workerDerivationEpoch: number;
}

export type BridgeWorkerFileViewContentReadyFetchResult =
	| {
			readonly status: 'ready';
			readonly metadata: BridgeWorkerFileViewContentMetadata;
			readonly resource: BridgeWorkerFetchedFileViewContentResource;
	  }
	| {
			readonly status: 'terminal';
			readonly reason: BridgeWorkerTerminalContentAvailabilityReason;
			readonly state: BridgeWorkerTerminalContentAvailabilityState;
	  }
	| {
			readonly status: 'stale';
	  }
	| {
			readonly status: 'pending';
	  };

type BridgeWorkerTerminalContentAvailabilityState = Extract<
	BridgeWorkerContentAvailabilityPatchPayload['state'],
	'failed' | 'unavailable'
>;
type BridgeWorkerTerminalContentAvailabilityReason = NonNullable<
	BridgeWorkerContentAvailabilityPatchPayload['reason']
>;

export async function dispatchSelectedBridgeWorkerFileViewContentReady(
	props: DispatchSelectedBridgeWorkerFileViewContentReadyProps,
): Promise<void> {
	const fetchResult = await fetchSelectedBridgeWorkerFileViewContentReadyResource(props);
	publishSelectedBridgeWorkerFileViewContentReadyFetchResult({ ...props, fetchResult });
}

export async function fetchSelectedBridgeWorkerFileViewContentReadyResource(
	props: DispatchSelectedBridgeWorkerFileViewContentReadyProps,
): Promise<BridgeWorkerFileViewContentReadyFetchResult> {
	if (!isSelectedFileViewContentReadyPreparationCurrent(props)) {
		return { status: 'stale' };
	}
	const metadata = selectedFileViewContentMetadata(props);
	if (metadata === null) {
		return { reason: 'content_unavailable', status: 'terminal', state: 'unavailable' };
	}
	const contentRequest =
		props.contentRequestsByItemId?.get(props.itemId) ??
		props.contentRequests?.find((candidate) => candidate.itemId === props.itemId) ??
		null;
	if (contentRequest === null) {
		return { status: 'pending' };
	}
	let resource: BridgeWorkerFetchedFileViewContentResource;
	try {
		resource = await fetchBridgeWorkerFileViewContentResource({
			contentRequest,
			openContent: props.openContent,
			operationCorrelationId: props.operationCorrelationId,
			...(props.signal === undefined ? {} : { signal: props.signal }),
		});
	} catch {
		if (
			props.signal?.aborted === true ||
			!isSelectedFileViewContentReadyPreparationCurrent(props)
		) {
			return { status: 'stale' };
		}
		return { reason: 'load_failed', status: 'terminal', state: 'failed' };
	}
	if (!isSelectedFileViewContentReadyPreparationCurrent(props)) {
		return { status: 'stale' };
	}
	return { status: 'ready', metadata, resource };
}

export function publishSelectedBridgeWorkerFileViewContentReadyFetchResult(
	props: DispatchSelectedBridgeWorkerFileViewContentReadyProps & {
		readonly fetchResult: BridgeWorkerFileViewContentReadyFetchResult;
	},
): void {
	if (props.fetchResult.status === 'pending' || props.fetchResult.status === 'stale') {
		return;
	}
	if (props.fetchResult.status === 'terminal') {
		postSelectedFileViewContentTerminalAvailability({
			...props,
			reason: props.fetchResult.reason,
			state: props.fetchResult.state,
		});
		props.onPreparationOutcome?.({ kind: 'terminal' });
		return;
	}
	if (!isSelectedFileViewContentReadyPreparationCurrent(props)) {
		return;
	}
	const job = planBridgeWorkerFileViewPierreRenderJob({
		bridgeDemandRank: props.bridgeDemandRank,
		budget: props.budget,
		metadata: props.fetchResult.metadata,
		resource: props.fetchResult.resource,
	});
	if (job === null) {
		postSelectedFileViewContentTerminalAvailability({
			...props,
			reason: 'descriptor_rejected',
			state: 'unavailable',
		});
		props.onPreparationOutcome?.({ kind: 'terminal' });
		return;
	}
	if (!isSelectedFileViewContentReadyPreparationCurrent(props)) {
		return;
	}
	const publication = props.store.renderFulfillmentRegistry.beginPublication({
		job,
		operationCorrelationId: props.operationCorrelationId,
		publicationSequence: props.sequence,
		workerDerivationEpoch: props.workerDerivationEpoch,
	});
	props.onPreparationOutcome?.({ kind: 'renderPublication', publication });
	if (!publication.shouldPublish) {
		if (publication.state.stage === 'painted') {
			postSelectedFileViewContentPaintedResidency({
				...props,
				contentCacheKey: job.contentCacheKey,
			});
			props.onPreparationOutcome?.({ kind: 'paintedResidency' });
		}
		return;
	}
	const preparedJobEvent = prepareBridgeWorkerFileViewContentRenderJobEventFromJob({
		job,
		renderReceiptIdentity: publication.receiptIdentity,
	});

	postPreparedBridgeCommWorkerMessage(props.port, preparedJobEvent);
	const contentReadyCommit = commitBridgeWorkerFileViewContentReadyRenderPatch({
		preparedJobEvent,
		publicationSequence: props.sequence,
		store: props.store,
		workerDerivationEpoch: props.workerDerivationEpoch,
	});
	postPreparedBridgeCommWorkerMessage(props.port, contentReadyCommit.preparedMessage);
}

function postSelectedFileViewContentPaintedResidency(
	props: DispatchSelectedBridgeWorkerFileViewContentReadyProps & {
		readonly contentCacheKey: string;
	},
): void {
	if (!isSelectedFileViewContentReadyPreparationCurrent(props)) return;
	props.store.actions.applyContentReady({
		contentCacheKey: props.contentCacheKey,
		itemId: props.itemId,
	});
	const slicePatchEvent = props.store.actions.takePendingSlicePatchEvent({
		epoch: props.workerDerivationEpoch,
		sequence: props.sequence,
	});
	postPreparedBridgeCommWorkerMessage(
		props.port,
		prepareBridgeWorkerFileRenderPatchEvent({
			patches: bridgeWorkerFileRenderPatchesFromSlicePatchEvent(slicePatchEvent),
			publicationSequence: props.sequence,
			workerDerivationEpoch: props.workerDerivationEpoch,
		}),
	);
}

export function isSelectedFileViewContentReadyPreparationCurrent(
	props: Pick<
		DispatchSelectedBridgeWorkerFileViewContentReadyProps,
		'epoch' | 'isPreparationCurrent' | 'itemId' | 'store'
	>,
): boolean {
	const state = props.store.getState();
	return (
		state.selectedId === props.itemId &&
		state.demandByKey.get(props.itemId) === `selected:${props.epoch}` &&
		(props.isPreparationCurrent?.() ?? true)
	);
}

function postSelectedFileViewContentTerminalAvailability(
	props: DispatchSelectedBridgeWorkerFileViewContentReadyProps & {
		readonly reason: BridgeWorkerTerminalContentAvailabilityReason;
		readonly state: BridgeWorkerTerminalContentAvailabilityState;
	},
): void {
	if (!isSelectedFileViewContentReadyPreparationCurrent(props)) {
		return;
	}
	props.store.actions.applyContentTerminalAvailability({
		itemId: props.itemId,
		reason: props.reason,
		sourceEpoch: props.epoch,
		state: props.state,
	});
	const slicePatchEvent = props.store.actions.takePendingSlicePatchEvent({
		epoch: props.workerDerivationEpoch,
		sequence: props.sequence,
	});
	postPreparedBridgeCommWorkerMessage(
		props.port,
		prepareBridgeWorkerFileRenderPatchEvent({
			patches: bridgeWorkerFileRenderPatchesFromSlicePatchEvent(slicePatchEvent),
			publicationSequence: props.sequence,
			workerDerivationEpoch: props.workerDerivationEpoch,
		}),
	);
}

function selectedFileViewContentMetadata(
	props: Pick<DispatchSelectedBridgeWorkerFileViewContentReadyProps, 'itemId' | 'store'>,
): BridgeWorkerFileViewContentMetadata | null {
	const metadata = props.store.getState().contentMetadataByItemId.get(props.itemId) ?? null;
	return isBridgeWorkerFileViewContentMetadata(metadata) ? metadata : null;
}
