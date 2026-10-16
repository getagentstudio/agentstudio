import {
	type BridgeCommWorkerPort,
	postPreparedBridgeCommWorkerMessage,
} from './bridge-comm-worker-entry.js';
import type { BridgeCommWorkerStore } from './bridge-comm-worker-store.js';
import {
	recordBridgeCommWorkerSelectedContentDroppedTelemetry,
	type BridgeCommWorkerSelectedContentDropReason,
	type BridgeCommWorkerTelemetryRecorder,
} from './bridge-comm-worker-telemetry.js';
import type { BridgeProductContentResponseStartControl } from './bridge-product-transport-contract.js';
import type {
	BridgeWorkerContentAvailabilityPatchPayload,
	BridgeWorkerReviewPierreRenderJobEvent,
	BridgeWorkerReviewContentRequestDescriptor,
	BridgeWorkerReviewPublicationIdentity,
	BridgeWorkerReviewRenderSemantics,
} from './bridge-worker-contracts.js';
import { assertBridgeWorkerReviewPublicationIdentityMatches } from './bridge-worker-pierre-publication-identity-contracts.js';
import type {
	BridgeWorkerDemandRank,
	BridgeWorkerPierreRenderBudget,
	BridgeWorkerPierreRenderJob,
} from './bridge-worker-pierre-render-job.js';
import type { BridgeWorkerRenderReceiptIdentity } from './bridge-worker-render-fulfillment.js';
import {
	type BridgeWorkerFetchedReviewContentResource,
	fetchBridgeWorkerReviewContentResource,
	internalBridgeWorkerReviewContentFetchResult,
	type BridgeWorkerReviewContentOpen,
	type BridgeWorkerReviewContentResourceFetch,
	type BridgeWorkerReviewContentResourceFetchResult,
} from './bridge-worker-review-content-fetch.js';
import {
	bridgeWorkerReviewRenderPatchesFromSlicePatchEvent,
	commitBridgeWorkerReviewContentReadyRenderPatch,
	createBridgeWorkerReviewContentRenderJobPreparation,
	prepareBridgeWorkerReviewRenderPatchEvent,
} from './bridge-worker-review-content-ready.js';
import { prepareBridgeWorkerReviewPierreRenderJobEventFromJob } from './bridge-worker-review-pierre-job-planner.js';
import type { PreparedBridgeWorkerStructuredMessage } from './bridge-worker-transfer-list.js';

export interface DispatchSelectedBridgeWorkerReviewContentReadyProps {
	readonly bridgeDemandRank: BridgeWorkerDemandRank;
	readonly budget: BridgeWorkerPierreRenderBudget;
	readonly contentRequestDescriptors: readonly BridgeWorkerReviewContentRequestDescriptor[];
	readonly epoch: number;
	readonly fetchReviewContentResource?: BridgeWorkerReviewContentResourceFetch;
	readonly itemId: string;
	readonly operationCorrelationId?: string | null;
	readonly onRenderPublished?: (receiptIdentity: BridgeWorkerRenderReceiptIdentity) => void;
	readonly openContent?: BridgeWorkerReviewContentOpen;
	readonly port: BridgeCommWorkerPort;
	readonly registerResponseStartControl?: (
		control: BridgeProductContentResponseStartControl,
	) => () => void;
	readonly renderSemantics: readonly BridgeWorkerReviewRenderSemantics[];
	readonly reviewPublicationIdentity: BridgeWorkerReviewPublicationIdentity;
	readonly sequence: number;
	readonly signal?: AbortSignal;
	readonly store: BridgeCommWorkerStore;
	readonly telemetryClient?: BridgeCommWorkerTelemetryRecorder;
	readonly workerDerivationEpoch: number;
}

export interface DispatchBridgeWorkerReviewContentReadyProps extends DispatchSelectedBridgeWorkerReviewContentReadyProps {
	readonly currentBridgeDemandRank?: () => BridgeWorkerDemandRank;
	readonly demandKey: string;
	readonly isDemandCurrent?: () => boolean;
	readonly recordSelectedContentDrops?: boolean;
}

export type BridgeWorkerReviewContentReadyFetchResult =
	| {
			readonly outcomes: readonly BridgeWorkerReviewContentResourceFetchResult[];
			readonly status: 'ready';
			readonly resources: readonly BridgeWorkerFetchedReviewContentResource[];
			readonly semantics: BridgeWorkerReviewRenderSemantics;
	  }
	| {
			readonly outcomes: readonly BridgeWorkerReviewContentResourceFetchResult[];
			readonly status: 'terminal';
			readonly reason: BridgeWorkerTerminalContentAvailabilityReason;
			readonly state: BridgeWorkerTerminalContentAvailabilityState;
	  }
	| {
			readonly outcomes: readonly BridgeWorkerReviewContentResourceFetchResult[];
			readonly reason: BridgeCommWorkerSelectedContentDropReason;
			readonly status: 'stale';
	  }
	| {
			readonly outcomes: readonly BridgeWorkerReviewContentResourceFetchResult[];
			readonly status: 'retryWait';
	  };

export interface BridgeWorkerReviewContentReadyPublication {
	readonly runNextStage: () => BridgeWorkerReviewContentReadyPublicationStepResult;
}

export interface BridgeWorkerReviewContentReadyPublicationStepResult {
	readonly complete: boolean;
}

export async function dispatchSelectedBridgeWorkerReviewContentReady(
	props: DispatchSelectedBridgeWorkerReviewContentReadyProps,
): Promise<void> {
	await dispatchBridgeWorkerReviewContentReady({
		...props,
		demandKey: selectedReviewContentReadyDemandKey(props),
		recordSelectedContentDrops: true,
	});
}

export async function dispatchBridgeWorkerReviewContentReady(
	props: DispatchBridgeWorkerReviewContentReadyProps,
): Promise<void> {
	const fetchResult = await fetchBridgeWorkerReviewContentReadyResources(props);
	publishBridgeWorkerReviewContentReadyFetchResult({ ...props, fetchResult });
}

export async function fetchSelectedBridgeWorkerReviewContentReadyResources(
	props: DispatchSelectedBridgeWorkerReviewContentReadyProps,
): Promise<BridgeWorkerReviewContentReadyFetchResult> {
	return fetchBridgeWorkerReviewContentReadyResources({
		...props,
		demandKey: selectedReviewContentReadyDemandKey(props),
	});
}

export async function fetchBridgeWorkerReviewContentReadyResources(
	props: DispatchBridgeWorkerReviewContentReadyProps,
): Promise<BridgeWorkerReviewContentReadyFetchResult> {
	if (!isReviewContentReadyDemandCurrent(props)) {
		return { outcomes: [], reason: 'stale_before_fetch', status: 'stale' };
	}
	const semantics = props.renderSemantics.find((candidate) => candidate.itemId === props.itemId);
	if (semantics === undefined) {
		return {
			outcomes: [],
			reason: 'descriptor_missing',
			status: 'terminal',
			state: 'unavailable',
		};
	}
	const fetchReviewContentResource =
		props.fetchReviewContentResource ?? createBridgeWorkerReviewContentResourceFetch(props);
	const outcomes = await Promise.all(
		selectReviewContentRequestDescriptorsForSemantics({
			descriptors: props.contentRequestDescriptors,
			semantics,
		}).map(async (descriptor): Promise<BridgeWorkerReviewContentResourceFetchResult> => {
			try {
				return await fetchReviewContentResource(
					descriptor,
					props.signal,
					props.registerResponseStartControl,
				);
			} catch {
				return internalBridgeWorkerReviewContentFetchResult(descriptor);
			}
		}),
	);
	if (!isReviewContentReadyDemandCurrent(props)) {
		return { outcomes, reason: 'stale_after_fetch', status: 'stale' };
	}
	if (outcomes.some(({ disposition }) => disposition === 'discarded')) {
		return { outcomes, reason: 'stale_after_fetch', status: 'stale' };
	}
	if (outcomes.some(({ disposition }) => disposition === 'terminal')) {
		return { outcomes, reason: 'load_failed', status: 'terminal', state: 'failed' };
	}
	if (outcomes.some(({ disposition }) => disposition === 'retryWait')) {
		return { outcomes, status: 'retryWait' };
	}
	const resources = outcomes.filter(
		(
			outcome,
		): outcome is Extract<
			BridgeWorkerReviewContentResourceFetchResult,
			{ readonly disposition: 'ready' }
		> => outcome.disposition === 'ready',
	);
	return { outcomes, status: 'ready', resources, semantics };
}

export function publishSelectedBridgeWorkerReviewContentReadyFetchResult(
	props: DispatchSelectedBridgeWorkerReviewContentReadyProps & {
		readonly fetchResult: BridgeWorkerReviewContentReadyFetchResult;
	},
): void {
	publishBridgeWorkerReviewContentReadyFetchResult({
		...props,
		demandKey: selectedReviewContentReadyDemandKey(props),
		recordSelectedContentDrops: true,
	});
}

export function publishBridgeWorkerReviewContentReadyFetchResult(
	props: DispatchBridgeWorkerReviewContentReadyProps & {
		readonly fetchResult: BridgeWorkerReviewContentReadyFetchResult;
	},
): void {
	const publication = createBridgeWorkerReviewContentReadyPublication(props);
	while (!publication.runNextStage().complete) {
		// Synchronous compatibility entry point. Production preparation uses one stage per pump slice.
	}
}

export function createBridgeWorkerReviewContentReadyPublication(
	props: DispatchBridgeWorkerReviewContentReadyProps & {
		readonly fetchResult: BridgeWorkerReviewContentReadyFetchResult;
	},
): BridgeWorkerReviewContentReadyPublication {
	let publicationStage: BridgeWorkerReviewContentReadyPublicationStage = 'classify';
	let plannedJob: BridgeWorkerPierreRenderJob | null = null;
	let renderJobPreparation: ReturnType<
		typeof createBridgeWorkerReviewContentRenderJobPreparation
	> | null = null;
	let terminalReason: BridgeWorkerTerminalContentAvailabilityReason | null = null;
	let terminalState: BridgeWorkerTerminalContentAvailabilityState | null = null;
	const completeBridgeWorkerReviewContentReadyPublication =
		(): BridgeWorkerReviewContentReadyPublicationStepResult => {
			publicationStage = 'complete';
			return { complete: true };
		};

	return {
		runNextStage: (): BridgeWorkerReviewContentReadyPublicationStepResult => {
			switch (publicationStage) {
				case 'classify': {
					if (props.fetchResult.status === 'stale') {
						recordSelectedReviewContentDropIfNeeded({
							dropReason: props.fetchResult.reason,
							recordSelectedContentDrops: props.recordSelectedContentDrops,
							telemetryClient: props.telemetryClient,
						});
						return completeBridgeWorkerReviewContentReadyPublication();
					}
					if (props.fetchResult.status === 'retryWait') {
						return completeBridgeWorkerReviewContentReadyPublication();
					}
					if (props.fetchResult.status === 'terminal') {
						terminalReason = props.fetchResult.reason;
						terminalState = props.fetchResult.state;
						publicationStage = 'commitTerminal';
						return { complete: false };
					}
					if (!isReviewContentReadyDemandCurrent(props)) {
						recordSelectedReviewContentDropIfNeeded({
							dropReason: 'stale_before_publish',
							recordSelectedContentDrops: props.recordSelectedContentDrops,
							telemetryClient: props.telemetryClient,
						});
						return completeBridgeWorkerReviewContentReadyPublication();
					}
					renderJobPreparation = createBridgeWorkerReviewContentRenderJobPreparation({
						bridgeDemandRank: props.bridgeDemandRank,
						...(props.currentBridgeDemandRank === undefined
							? {}
							: { currentBridgeDemandRank: props.currentBridgeDemandRank }),
						budget: props.budget,
						resources: props.fetchResult.resources,
						semantics: props.fetchResult.semantics,
					});
					publicationStage = 'prepareReady';
					return { complete: false };
				}
				case 'prepareReady': {
					if (renderJobPreparation === null) {
						throw new Error('Bridge worker Review render-job preparation is not initialized.');
					}
					const preparationResult = renderJobPreparation.runNextStage();
					if (preparationResult.status === 'pending') return { complete: false };
					plannedJob = preparationResult.job;
					if (plannedJob === null) {
						terminalReason = 'descriptor_rejected';
						terminalState = 'unavailable';
						publicationStage = 'commitTerminal';
						return { complete: false };
					}
					publicationStage = 'commitReady';
					return { complete: false };
				}
				case 'commitReady': {
					if (!isReviewContentReadyDemandCurrent(props)) {
						recordSelectedReviewContentDropIfNeeded({
							dropReason: 'stale_before_publish',
							recordSelectedContentDrops: props.recordSelectedContentDrops,
							telemetryClient: props.telemetryClient,
						});
						return completeBridgeWorkerReviewContentReadyPublication();
					}
					const job = requirePlannedBridgeWorkerReviewJob(plannedJob);
					const publication = props.store.renderFulfillmentRegistry.beginPublication({
						job,
						operationCorrelationId: props.operationCorrelationId ?? null,
						publicationSequence: props.sequence,
						workerDerivationEpoch: props.workerDerivationEpoch,
					});
					if (!publication.shouldPublish) {
						if (
							publication.status === 'duplicate' &&
							props.store.getState().availabilityByItemId.get(props.itemId) !== 'ready'
						) {
							publishReviewContentReadyForExistingPublication({
								...props,
								contentCacheKey: job.contentCacheKey,
							});
						}
						return completeBridgeWorkerReviewContentReadyPublication();
					}
					commitPreparedBridgeWorkerReviewContentReady({
						...props,
						preparedJobEvent: prepareBridgeWorkerReviewPierreRenderJobEventFromJob({
							job,
							renderReceiptIdentity: publication.receiptIdentity,
							reviewPublicationIdentity: props.reviewPublicationIdentity,
						}),
					});
					return completeBridgeWorkerReviewContentReadyPublication();
				}
				case 'commitTerminal':
					postReviewContentTerminalAvailability({
						...props,
						reason: requireBridgeWorkerTerminalReason(terminalReason),
						state: requireBridgeWorkerTerminalState(terminalState),
					});
					return completeBridgeWorkerReviewContentReadyPublication();
				case 'complete':
					return { complete: true };
				default:
					return assertNeverBridgeWorkerReviewContentReadyPublicationStage(publicationStage);
			}
		},
	};
}

function publishReviewContentReadyForExistingPublication(
	props: DispatchBridgeWorkerReviewContentReadyProps & { readonly contentCacheKey: string },
): void {
	props.store.actions.applyContentReady({
		contentCacheKey: props.contentCacheKey,
		itemId: props.itemId,
	});
	const slicePatch = props.store.actions.takePendingSlicePatchEvent({
		epoch: props.workerDerivationEpoch,
		sequence: props.sequence,
	});
	postPreparedBridgeCommWorkerMessage(
		props.port,
		prepareBridgeWorkerReviewRenderPatchEvent({
			patches: bridgeWorkerReviewRenderPatchesFromSlicePatchEvent(slicePatch),
			publicationSequence: props.sequence,
			reviewPublicationIdentity: props.reviewPublicationIdentity,
			workerDerivationEpoch: props.workerDerivationEpoch,
		}),
	);
}

type BridgeWorkerReviewContentReadyPublicationStage =
	| 'classify'
	| 'prepareReady'
	| 'commitReady'
	| 'commitTerminal'
	| 'complete';

function assertNeverBridgeWorkerReviewContentReadyPublicationStage(publicationStage: never): never {
	throw new Error(
		`Unsupported Bridge worker Review content-ready publication stage: ${String(publicationStage)}`,
	);
}

function commitPreparedBridgeWorkerReviewContentReady(
	props: DispatchBridgeWorkerReviewContentReadyProps & {
		readonly preparedJobEvent: PreparedBridgeWorkerStructuredMessage<BridgeWorkerReviewPierreRenderJobEvent>;
	},
): void {
	assertBridgeWorkerReviewPublicationIdentityMatches(
		props.reviewPublicationIdentity,
		props.preparedJobEvent.message.reviewPublicationIdentity,
	);
	postPreparedBridgeCommWorkerMessage(props.port, props.preparedJobEvent);
	const contentReadyCommit = commitBridgeWorkerReviewContentReadyRenderPatch({
		preparedJobEvent: props.preparedJobEvent,
		store: props.store,
	});
	postPreparedBridgeCommWorkerMessage(props.port, contentReadyCommit.preparedMessage);
	props.onRenderPublished?.(props.preparedJobEvent.message.renderReceiptIdentity);
}

function requirePlannedBridgeWorkerReviewJob(
	plannedJob: BridgeWorkerPierreRenderJob | null,
): BridgeWorkerPierreRenderJob {
	if (plannedJob === null) {
		throw new Error('Bridge worker Review planned job is unavailable.');
	}
	return plannedJob;
}

function requireBridgeWorkerTerminalReason(
	reason: BridgeWorkerTerminalContentAvailabilityReason | null,
): BridgeWorkerTerminalContentAvailabilityReason {
	if (reason === null) throw new Error('Bridge worker Review terminal reason is unavailable.');
	return reason;
}

function requireBridgeWorkerTerminalState(
	state: BridgeWorkerTerminalContentAvailabilityState | null,
): BridgeWorkerTerminalContentAvailabilityState {
	if (state === null) throw new Error('Bridge worker Review terminal state is unavailable.');
	return state;
}

function recordSelectedReviewContentDropIfNeeded(props: {
	readonly dropReason: BridgeCommWorkerSelectedContentDropReason;
	readonly recordSelectedContentDrops: boolean | undefined;
	readonly telemetryClient: BridgeCommWorkerTelemetryRecorder | undefined;
}): void {
	if (props.recordSelectedContentDrops !== true) {
		return;
	}
	recordBridgeCommWorkerSelectedContentDroppedTelemetry({
		dropReason: props.dropReason,
		...(props.telemetryClient === undefined ? {} : { telemetryClient: props.telemetryClient }),
	});
}

type BridgeWorkerTerminalContentAvailabilityState = Extract<
	BridgeWorkerContentAvailabilityPatchPayload['state'],
	'failed' | 'unavailable'
>;
type BridgeWorkerTerminalContentAvailabilityReason = NonNullable<
	BridgeWorkerContentAvailabilityPatchPayload['reason']
>;

type BridgeWorkerReviewContentRole = BridgeWorkerReviewContentRequestDescriptor['role'];
type BridgeWorkerReviewContentRoleGroup = readonly BridgeWorkerReviewContentRole[];

function postReviewContentTerminalAvailability(
	props: DispatchBridgeWorkerReviewContentReadyProps & {
		readonly reason: BridgeWorkerTerminalContentAvailabilityReason;
		readonly state: BridgeWorkerTerminalContentAvailabilityState;
	},
): void {
	if (!isReviewContentReadyDemandCurrent(props)) {
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
		prepareBridgeWorkerReviewRenderPatchEvent({
			patches: bridgeWorkerReviewRenderPatchesFromSlicePatchEvent(slicePatchEvent),
			publicationSequence: props.sequence,
			reviewPublicationIdentity: props.reviewPublicationIdentity,
			workerDerivationEpoch: props.workerDerivationEpoch,
		}),
	);
}

export function isSelectedReviewContentReadyPreparationCurrent(
	props: Pick<DispatchSelectedBridgeWorkerReviewContentReadyProps, 'epoch' | 'itemId' | 'store'>,
): boolean {
	return isReviewContentReadyDemandCurrent({
		...props,
		demandKey: selectedReviewContentReadyDemandKey(props),
	});
}

export function isReviewContentReadyDemandCurrent(
	props: Pick<
		DispatchBridgeWorkerReviewContentReadyProps,
		'demandKey' | 'isDemandCurrent' | 'itemId' | 'signal' | 'store'
	>,
): boolean {
	const state = props.store.getState();
	return (
		props.signal?.aborted !== true &&
		state.demandByKey.get(props.itemId) === props.demandKey &&
		(props.isDemandCurrent?.() ?? true)
	);
}

export function canRenderBridgeWorkerReviewContentForSemantics(props: {
	readonly descriptors: readonly BridgeWorkerReviewContentRequestDescriptor[];
	readonly semantics: BridgeWorkerReviewRenderSemantics;
}): boolean {
	return selectReviewContentRequestDescriptorsForSemantics(props).length > 0;
}

function selectedReviewContentReadyDemandKey(
	props: Pick<DispatchSelectedBridgeWorkerReviewContentReadyProps, 'epoch'>,
): string {
	return `selected:${props.epoch}`;
}

function createBridgeWorkerReviewContentResourceFetch(
	props: Pick<DispatchBridgeWorkerReviewContentReadyProps, 'openContent'>,
): BridgeWorkerReviewContentResourceFetch {
	return (
		descriptor: BridgeWorkerReviewContentRequestDescriptor,
		signal?: AbortSignal,
		registerResponseStartControl?: (
			control: BridgeProductContentResponseStartControl,
		) => () => void,
	) => {
		return fetchBridgeWorkerReviewContentResource({
			descriptor,
			openContent:
				props.openContent ??
				(() => {
					throw new Error('Bridge worker Review content transport is unavailable.');
				}),
			...(registerResponseStartControl === undefined ? {} : { registerResponseStartControl }),
			...(signal === undefined ? {} : { signal }),
		});
	};
}

function selectReviewContentRequestDescriptorsForSemantics(props: {
	readonly descriptors: readonly BridgeWorkerReviewContentRequestDescriptor[];
	readonly semantics: BridgeWorkerReviewRenderSemantics;
}): readonly BridgeWorkerReviewContentRequestDescriptor[] {
	const descriptorsByRole = new Map(
		props.descriptors
			.filter((descriptor) => descriptor.itemId === props.semantics.itemId)
			.map((descriptor) => [descriptor.role, descriptor] as const),
	);
	if (requiresTwoSidedDiffDescriptors(props.semantics)) {
		const baseDescriptor = descriptorsByRole.get('base') ?? null;
		const headDescriptor = descriptorsByRole.get('head') ?? null;
		return baseDescriptor === null || headDescriptor === null
			? []
			: [baseDescriptor, headDescriptor];
	}
	return contentRoleGroupsForSemantics(props.semantics).flatMap((roleGroup) => {
		const descriptor = firstDescriptorForRoleGroup(descriptorsByRole, roleGroup);
		return descriptor === null ? [] : [descriptor];
	});
}

function requiresTwoSidedDiffDescriptors(semantics: BridgeWorkerReviewRenderSemantics): boolean {
	switch (semantics.changeKind) {
		case 'modified':
		case 'renamed':
		case 'copied':
			return semantics.itemKind === 'diff';
		case 'added':
		case 'deleted':
			return false;
	}
	const exhaustiveChangeKind: never = semantics.changeKind;
	void exhaustiveChangeKind;
	throw new Error('Unhandled Bridge worker review change kind.');
}

function firstDescriptorForRoleGroup(
	descriptorsByRole: ReadonlyMap<
		BridgeWorkerReviewContentRole,
		BridgeWorkerReviewContentRequestDescriptor
	>,
	roleGroup: BridgeWorkerReviewContentRoleGroup,
): BridgeWorkerReviewContentRequestDescriptor | null {
	for (const role of roleGroup) {
		const descriptor = descriptorsByRole.get(role);
		if (descriptor !== undefined) {
			return descriptor;
		}
	}
	return null;
}

function contentRoleGroupsForSemantics(
	semantics: BridgeWorkerReviewRenderSemantics,
): readonly BridgeWorkerReviewContentRoleGroup[] {
	switch (semantics.changeKind) {
		case 'added':
			return [['head', 'file']];
		case 'deleted':
			return [['base', 'diff']];
		case 'modified':
		case 'renamed':
		case 'copied':
			return semantics.itemKind === 'diff'
				? [['base'], ['head']]
				: [['head', 'file', 'diff', 'base']];
	}
	const exhaustiveChangeKind: never = semantics.changeKind;
	void exhaustiveChangeKind;
	throw new Error('Unhandled Bridge worker review change kind.');
}
