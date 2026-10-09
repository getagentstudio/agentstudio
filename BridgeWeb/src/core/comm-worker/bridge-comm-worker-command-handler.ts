import {
	bridgeCommWorkerCommandUsesIntentEpochAdmission,
	bridgeCommWorkerIntentEpochDomain,
	rejectStaleOrReplayedBridgeWorkerCommand,
	type BridgeCommWorkerIntentEpochDomain,
} from './bridge-comm-worker-command-admission.js';
import type {
	BridgeCommWorkerCommandHandler,
	BridgeCommWorkerDemandExecutionScheduleRequest,
	BridgeCommWorkerReviewMetadataApplicationTransaction,
	BridgeCommWorkerRenderFulfillmentLifecycleAdvance,
	BridgeCommWorkerSelectedFileViewContentReadyPreparationRequest,
	BridgeCommWorkerSelectedReviewContentReadyPreparationRequest,
	CreateBridgeCommWorkerCommandHandlerProps,
} from './bridge-comm-worker-command-handler-contracts.js';
import {
	assertNeverBridgeWorkerCommand,
	buildBridgeWorkerUnimplementedHealthEvent,
	createBridgeWorkerSequenceCounter,
} from './bridge-comm-worker-command-support.js';
import {
	handleBridgeWorkerReviewInvalidateCommand,
	handleBridgeWorkerViewportCommand,
	isBridgeWorkerReviewContentMetadata,
	publishBridgeCommWorkerFileMetadataDemand,
} from './bridge-comm-worker-demand-command-handlers.js';
import {
	advanceBridgeCommWorkerFileRenderFulfillmentLifecycle,
	retryBridgeCommWorkerExhaustedFileRender,
} from './bridge-comm-worker-file-render-fulfillment-lifecycle.js';
import type { BridgeCommWorkerFileViewRuntimeMutation } from './bridge-comm-worker-file-view-runtime-mutation.js';
import {
	applyFileViewRuntimeMutationTrackingSelectedRequest,
	didSelectedFileViewContentRequestChange,
	normalizeBridgeCommWorkerFileViewRuntimeSource,
	type BridgeCommWorkerFileViewRuntimeSource,
} from './bridge-comm-worker-file-view-runtime-source.js';
import type { BridgeCommWorkerFileMetadataDemand } from './bridge-comm-worker-product-controller.js';
import { buildBridgeWorkerReadyHealthEvent } from './bridge-comm-worker-protocol.js';
import {
	applyBridgeWorkerRenderDispositionCommand,
	type BridgeWorkerRenderDispositionApplication,
} from './bridge-comm-worker-render-disposition-application.js';
import { handleBridgeCommWorkerReviewHoverCommand } from './bridge-comm-worker-review-hover-command.js';
import {
	applyBridgeCommWorkerReviewMetadataApplication,
	type BridgeCommWorkerReviewMetadataApplication,
} from './bridge-comm-worker-review-runtime-application.js';
import type { BridgeCommWorkerReviewRuntimeSource } from './bridge-comm-worker-review-source-diff.js';
import {
	isSelectedContentReadyPreparationCurrent,
	readSelectedContentDemandEpoch,
	scheduleSelectedFileViewContentReadyPreparationForCurrentDemand,
} from './bridge-comm-worker-selection-demand.js';
import {
	createBridgeCommWorkerStore,
	type BridgeCommWorkerStore,
} from './bridge-comm-worker-store.js';
import type { BridgeCommWorkerTelemetryRecorder } from './bridge-comm-worker-telemetry.js';
import {
	type BridgeWorkerFileDisplayResyncCommand,
	type BridgeWorkerFileQueryUpdateCommand,
	type BridgeWorkerMainToServerMessage,
	type BridgeWorkerReviewProjectionUpdateCommand,
	type BridgeWorkerRenderDispositionCommand,
	type BridgeWorkerSelectCommand,
	type BridgeWorkerServerToMainMessage,
} from './bridge-worker-contracts.js';
import {
	bridgeWorkerFileRenderPatchesFromSlicePatchEvent,
	prepareBridgeWorkerFileRenderPatchEvent,
} from './bridge-worker-file-view-content-ready.js';
import {
	BridgeWorkerRenderFulfillmentRegistry,
	type BridgeWorkerRenderFulfillmentRegistryContext,
} from './bridge-worker-render-fulfillment-registry.js';

export type { BridgeCommWorkerReviewRuntimeSource } from './bridge-comm-worker-review-source-diff.js';

export type { BridgeCommWorkerFileViewRuntimeSource } from './bridge-comm-worker-file-view-runtime-source.js';
export type { BridgeCommWorkerFileMetadataDemand } from './bridge-comm-worker-product-controller.js';

export type {
	BridgeCommWorkerCommandHandler,
	BridgeCommWorkerDemandExecutionScheduleRequest,
	BridgeCommWorkerReviewMetadataApplicationTransaction,
	BridgeCommWorkerReviewMetadataResetScheduleRequest,
	BridgeCommWorkerRenderFulfillmentLifecycleAdvance,
	BridgeCommWorkerSelectedFileViewContentReadyPreparationRequest,
	BridgeCommWorkerSelectedReviewContentReadyPreparationRequest,
	CreateBridgeCommWorkerCommandHandlerProps,
} from './bridge-comm-worker-command-handler-contracts.js';

const bridgeCommWorkerRecentRequestCapacityPerDomain = 4096;

export function createBridgeCommWorkerCommandHandler(
	props: CreateBridgeCommWorkerCommandHandlerProps,
): BridgeCommWorkerCommandHandler {
	const renderFulfillmentContext = props.renderFulfillmentContext ?? {
		paneSessionId: 'worker-local-unbound-pane',
		workerInstanceId: 'worker-local-unbound-instance',
	};
	const createRenderFulfillmentRegistry = (
		surface: BridgeWorkerRenderFulfillmentRegistryContext['surface'],
	): BridgeWorkerRenderFulfillmentRegistry =>
		new BridgeWorkerRenderFulfillmentRegistry({
			context: { ...renderFulfillmentContext, surface },
			...(props.createRenderIdentifier === undefined
				? {}
				: { createIdentifier: props.createRenderIdentifier }),
			...(props.renderFulfillmentNow === undefined && props.now === undefined
				? {}
				: { now: props.renderFulfillmentNow ?? props.now }),
			receiptLeaseDurationMilliseconds: props.renderReceiptLeaseDurationMilliseconds ?? 5000,
			retryBackoffMilliseconds: props.renderRetryBackoffMilliseconds ?? 25,
		});
	const reviewStore = createBridgeCommWorkerStore({
		contentItems: props.contentItems,
		...(props.now === undefined ? {} : { now: props.now }),
		renderFulfillmentRegistry: createRenderFulfillmentRegistry('review'),
		rows: props.rows,
		surface: 'review',
		...(props.telemetryClient === undefined ? {} : { telemetryClient: props.telemetryClient }),
	});
	const fileViewStore = createBridgeCommWorkerStore({
		contentItems: [],
		...(props.now === undefined ? {} : { now: props.now }),
		renderFulfillmentRegistry: createRenderFulfillmentRegistry('file'),
		rows: [],
		surface: 'file',
		...(props.telemetryClient === undefined ? {} : { telemetryClient: props.telemetryClient }),
	});
	const createSequence = props.createSequence ?? createBridgeWorkerSequenceCounter();
	const seenRequestIdsByIntentEpochDomain: Record<
		BridgeCommWorkerIntentEpochDomain,
		Set<string>
	> = {
		fileAnnotation: new Set<string>(),
		fileView: new Set<string>(),
		pane: new Set<string>(),
		review: new Set<string>(),
		reviewAnnotation: new Set<string>(),
	};
	let fileViewRuntimeSource: BridgeCommWorkerFileViewRuntimeSource = {
		contentItems: [],
		contentRequests: [],
		rows: [],
	};
	let reviewRuntimeSource: BridgeCommWorkerReviewRuntimeSource = {
		contentItems: props.contentItems,
		contentRequestDescriptors: props.contentRequestDescriptors ?? [],
		renderSemantics: props.renderSemantics ?? [],
		reviewPublicationIdentity: props.reviewPublicationIdentity ?? null,
		rows: props.rows,
	};
	const currentIntentEpochByDomain: Record<BridgeCommWorkerIntentEpochDomain, number> = {
		fileAnnotation: 0,
		fileView: 0,
		pane: 0,
		review: 0,
		reviewAnnotation: 0,
	};
	const pendingRenderRetryItemIds = new Set<string>();
	const reportReviewMetadataPostCommitFailure = (error: unknown): void => {
		try {
			props.onReviewMetadataPostCommitFailure?.(error);
		} catch {
			// Post-commit diagnostics cannot invalidate an already committed Review publication.
		}
	};
	const applyRenderDispositionCommand = (
		command: BridgeWorkerRenderDispositionCommand,
		store: BridgeCommWorkerStore,
	): BridgeWorkerRenderDispositionApplication => {
		if (props.applyRenderDisposition !== undefined) {
			return {
				messages: props.applyRenderDisposition({ command, store }),
				receiptResults: [],
			};
		}
		return applyBridgeWorkerRenderDispositionCommand({
			command,
			store,
			...(props.telemetryClient === undefined ? {} : { telemetryClient: props.telemetryClient }),
		});
	};
	const prepareReviewMetadataApplication = (
		application: BridgeCommWorkerReviewMetadataApplication,
	): BridgeCommWorkerReviewMetadataApplicationTransaction => {
		const previousRuntimeSource = reviewRuntimeSource;
		const storeRollbackSnapshot = reviewStore.captureRollbackSnapshot();
		const postCommitEffects: Array<() => void> = [];
		if (application.reset) {
			postCommitEffects.push((): void => {
				reviewStore.renderFulfillmentRegistry.retireRemovedItemsForSourceChurn(
					application.removedItemIds,
				);
				reviewStore.renderFulfillmentRegistry.requeuePublicationsForSourceChurn();
			});
		}
		let state: 'committed' | 'pending' | 'rolledBack' = 'pending';
		let postCommitEffectsRan = false;
		const rollback = (): void => {
			if (state !== 'pending') return;
			state = 'rolledBack';
			reviewRuntimeSource = previousRuntimeSource;
			reviewStore.restoreRollbackSnapshot(storeRollbackSnapshot);
			try {
				props.updateReviewRuntimeSource?.(previousRuntimeSource);
			} catch (error) {
				reportReviewMetadataPostCommitFailure(error);
			}
		};
		try {
			const messages = applyBridgeCommWorkerReviewMetadataApplication({
				application,
				createSequence,
				readRuntimeSource: (): BridgeCommWorkerReviewRuntimeSource => reviewRuntimeSource,
				...(props.scheduleDemandExecution === undefined
					? {}
					: {
							scheduleDemandExecution: (request): void => {
								postCommitEffects.push((): void => props.scheduleDemandExecution?.(request));
							},
						}),
				...(props.scheduleReviewMetadataReset === undefined
					? {}
					: {
							scheduleReset: (request): void => {
								postCommitEffects.push((): void => props.scheduleReviewMetadataReset?.(request));
							},
						}),
				scheduleSelectedPreparation: (request): void => {
					postCommitEffects.push((): void =>
						props.scheduleSelectedReviewContentReadyPreparation(request),
					);
				},
				store: reviewStore,
				updateRuntimeSource: (source): void => {
					reviewRuntimeSource = source;
					props.updateReviewRuntimeSource?.(source);
				},
			});
			postCommitEffects.push((): void => {
				if (pendingRenderRetryItemIds.size === 0) return;
				const reviewState = reviewStore.getState();
				const demandedItemIds = new Set([
					...reviewState.visibleIds,
					...(reviewState.selectedId === null ? [] : [reviewState.selectedId]),
				]);
				const itemIds = application.source.contentItems
					.map((item) => item.itemId)
					.filter((itemId) => pendingRenderRetryItemIds.has(itemId) && demandedItemIds.has(itemId));
				pendingRenderRetryItemIds.clear();
				if (itemIds.length === 0) return;
				props.scheduleDemandExecution?.({
					affectedItemIds: itemIds,
					cause: 'renderFulfillment',
					epoch: currentIntentEpochByDomain.review,
					forceExecutionItemIds: itemIds,
					store: reviewStore,
				});
			});
			return {
				commit: (): void => {
					if (state !== 'pending') return;
					state = 'committed';
				},
				messages,
				rollback,
				runPostCommitEffects: (): void => {
					if (state !== 'committed' || postCommitEffectsRan) return;
					postCommitEffectsRan = true;
					for (const effect of postCommitEffects) {
						try {
							effect();
						} catch (error) {
							reportReviewMetadataPostCommitFailure(error);
						}
					}
				},
			};
		} catch (error) {
			rollback();
			throw error;
		}
	};

	return {
		applyRenderDispositionCommand: (command) =>
			applyRenderDispositionCommand(
				command,
				command.receipts[0]?.surface === 'file' ? fileViewStore : reviewStore,
			),
		advanceFileRenderFulfillmentLifecycle: (
			atMilliseconds,
		): BridgeCommWorkerRenderFulfillmentLifecycleAdvance =>
			advanceBridgeCommWorkerFileRenderFulfillmentLifecycle({
				atMilliseconds,
				store: fileViewStore,
				onExhausted: props.onFileVisibleRenderExhausted,
				scheduleSelectedPreparation: props.scheduleSelectedFileViewContentReadyPreparation,
			}),
		advanceReviewRenderFulfillmentLifecycle: (
			atMilliseconds,
		): BridgeCommWorkerRenderFulfillmentLifecycleAdvance => {
			const expiredItemIds =
				reviewStore.renderFulfillmentRegistry.expireReceiptLeases(atMilliseconds);
			for (const itemId of expiredItemIds) props.releaseExpiredReviewPublication?.(itemId);
			const visibleQueuedExpiry =
				reviewStore.renderFulfillmentRegistry.expireVisibleQueuedLeases(atMilliseconds);
			const exhaustedItemIds = [
				...visibleQueuedExpiry.exhaustedItemIds,
				...expiredItemIds.filter(
					(itemId) =>
						reviewStore.renderFulfillmentRegistry.getItemState(itemId)?.stage === 'failed',
				),
			];
			if (exhaustedItemIds.length > 0) {
				props.onReviewVisibleRenderExhausted?.(exhaustedItemIds);
			}
			const releasedItemIds =
				reviewStore.renderFulfillmentRegistry.releaseReadyRetries(atMilliseconds);
			if (releasedItemIds.length > 0) {
				const releasedItemIdSet = new Set(releasedItemIds);
				const reviewState = reviewStore.getState();
				const selectedDemandEpoch = readSelectedContentDemandEpoch(reviewState);
				if (
					selectedDemandEpoch !== null &&
					reviewState.selectedId !== null &&
					releasedItemIdSet.has(reviewState.selectedId)
				) {
					props.scheduleSelectedReviewContentReadyPreparation({
						epoch: selectedDemandEpoch,
						itemId: reviewState.selectedId,
						store: reviewStore,
					});
				}
				props.scheduleDemandExecution?.({
					affectedItemIds: releasedItemIds,
					cause: 'renderFulfillment',
					epoch: currentIntentEpochByDomain.review,
					forceExecutionItemIds: releasedItemIds,
					store: reviewStore,
				});
			}
			return {
				nextWakeAtMilliseconds:
					reviewStore.renderFulfillmentRegistry.nextLifecycleWakeAtMilliseconds(),
			};
		},
		applyReviewMetadataApplication: (application) => {
			const transaction = prepareReviewMetadataApplication(application);
			transaction.commit();
			transaction.runPostCommitEffects();
			return transaction.messages;
		},
		prepareReviewMetadataApplication,
		applyFileViewRuntimeSource: ({ epoch, source }) =>
			applyBridgeCommWorkerFileViewRuntimeSource({
				createSequence,
				demandEpoch: currentIntentEpochByDomain.fileView,
				epoch,
				nextFileViewRuntimeSource: source,
				previousFileViewRuntimeSource: fileViewRuntimeSource,
				scheduleSelectedFileViewContentReadyPreparation:
					props.scheduleSelectedFileViewContentReadyPreparation,
				store: fileViewStore,
				...(props.updateFileMetadataDemand === undefined
					? {}
					: { updateFileMetadataDemand: props.updateFileMetadataDemand }),
				updateFileViewRuntimeSource: (nextSource): void => {
					fileViewRuntimeSource = normalizeBridgeCommWorkerFileViewRuntimeSource(nextSource);
					props.updateFileViewRuntimeSource?.(fileViewRuntimeSource);
				},
			}),
		applyFileViewRuntimeMutation: ({ epoch, mutation }) =>
			applyBridgeCommWorkerFileViewRuntimeMutation({
				createSequence,
				demandEpoch: currentIntentEpochByDomain.fileView,
				epoch,
				mutation,
				scheduleSelectedFileViewContentReadyPreparation:
					props.scheduleSelectedFileViewContentReadyPreparation,
				source: fileViewRuntimeSource,
				store: fileViewStore,
				...(props.updateFileMetadataDemand === undefined
					? {}
					: { updateFileMetadataDemand: props.updateFileMetadataDemand }),
				updateFileViewRuntimeSource: (nextSource): void => {
					fileViewRuntimeSource = nextSource;
					props.updateFileViewRuntimeSource?.(nextSource);
				},
			}),
		handleMessage: (message: BridgeWorkerMainToServerMessage) => {
			const intentEpochDomain = bridgeCommWorkerIntentEpochDomain(message);
			const currentIntentEpoch = currentIntentEpochByDomain[intentEpochDomain];
			const seenRequestIds = seenRequestIdsByIntentEpochDomain[intentEpochDomain];
			const commandStore =
				intentEpochDomain === 'fileView' || intentEpochDomain === 'fileAnnotation'
					? fileViewStore
					: reviewStore;
			if (bridgeCommWorkerCommandUsesIntentEpochAdmission(message)) {
				if (message.epoch > currentIntentEpoch) {
					seenRequestIds.clear();
				}
				const rejection = rejectStaleOrReplayedBridgeWorkerCommand({
					currentEpoch: currentIntentEpoch,
					message,
					seenRequestIds,
				});
				if (rejection !== null) {
					return [rejection];
				}
				seenRequestIds.add(message.requestId);
				if (seenRequestIds.size > bridgeCommWorkerRecentRequestCapacityPerDomain) {
					const oldestRequestId = seenRequestIds.values().next().value;
					if (oldestRequestId !== undefined) {
						seenRequestIds.delete(oldestRequestId);
					}
				}
				currentIntentEpochByDomain[intentEpochDomain] = Math.max(currentIntentEpoch, message.epoch);
			}
			return handleBridgeWorkerCommand({
				createSequence,
				message,
				scheduleSelectedReviewContentReadyPreparation:
					props.scheduleSelectedReviewContentReadyPreparation,
				scheduleSelectedFileViewContentReadyPreparation:
					props.scheduleSelectedFileViewContentReadyPreparation,
				fileViewRuntimeSource,
				...(props.scheduleDemandExecution === undefined
					? {}
					: { scheduleDemandExecution: props.scheduleDemandExecution }),
				store: commandStore,
				reviewRuntimeSource,
				updateFileViewRuntimeSource: (source: BridgeCommWorkerFileViewRuntimeSource): void => {
					fileViewRuntimeSource = source;
					props.updateFileViewRuntimeSource?.(source);
				},
				...(props.updateFileMetadataDemand === undefined
					? {}
					: { updateFileMetadataDemand: props.updateFileMetadataDemand }),
				...(props.updateFileDisplayQuery === undefined
					? {}
					: { updateFileDisplayQuery: props.updateFileDisplayQuery }),
				...(props.updateReviewDisplayProjection === undefined
					? {}
					: { updateReviewDisplayProjection: props.updateReviewDisplayProjection }),
				...(props.requestFileDisplayResync === undefined
					? {}
					: { requestFileDisplayResync: props.requestFileDisplayResync }),
				applyRenderDisposition: ({ command, store }) =>
					applyRenderDispositionCommand(command, store).messages,
				...(props.retryAnnotationProjection === undefined
					? {}
					: { retryAnnotationProjection: props.retryAnnotationProjection }),
				...(props.retryView === undefined
					? {}
					: {
							retryView: (view): void => {
								if (view.kind === 'review.metadata') {
									for (const itemId of reviewStore.renderFulfillmentRegistry.retryExhaustedPublications()) {
										pendingRenderRetryItemIds.add(itemId);
									}
								}
								props.retryView?.(view);
								if (view.kind === 'file.metadata')
									retryBridgeCommWorkerExhaustedFileRender({
										store: fileViewStore,
										scheduleSelectedPreparation:
											props.scheduleSelectedFileViewContentReadyPreparation,
									});
							},
						}),
				...(props.telemetryClient === undefined ? {} : { telemetryClient: props.telemetryClient }),
			});
		},
	};
}

interface HandleBridgeWorkerCommandProps {
	readonly createSequence: () => number;
	readonly message: BridgeWorkerMainToServerMessage;
	readonly scheduleSelectedReviewContentReadyPreparation: (
		request: BridgeCommWorkerSelectedReviewContentReadyPreparationRequest,
	) => void;
	readonly scheduleSelectedFileViewContentReadyPreparation: (
		request: BridgeCommWorkerSelectedFileViewContentReadyPreparationRequest,
	) => void;
	readonly scheduleDemandExecution?: (
		request: BridgeCommWorkerDemandExecutionScheduleRequest,
	) => void;
	readonly store: BridgeCommWorkerStore;
	readonly reviewRuntimeSource: BridgeCommWorkerReviewRuntimeSource;
	readonly fileViewRuntimeSource: BridgeCommWorkerFileViewRuntimeSource;
	readonly updateFileViewRuntimeSource: (source: BridgeCommWorkerFileViewRuntimeSource) => void;
	readonly updateFileMetadataDemand?: (demand: BridgeCommWorkerFileMetadataDemand) => void;
	readonly updateFileDisplayQuery?: (
		command: BridgeWorkerFileQueryUpdateCommand,
	) => readonly BridgeWorkerServerToMainMessage[];
	readonly updateReviewDisplayProjection?: (
		command: BridgeWorkerReviewProjectionUpdateCommand,
	) => readonly BridgeWorkerServerToMainMessage[];
	readonly requestFileDisplayResync?: (
		command: BridgeWorkerFileDisplayResyncCommand,
	) => readonly BridgeWorkerServerToMainMessage[];
	readonly retryAnnotationProjection?: (surface: 'file' | 'review') => void;
	readonly retryView?: CreateBridgeCommWorkerCommandHandlerProps['retryView'];
	readonly telemetryClient?: BridgeCommWorkerTelemetryRecorder;
	readonly applyRenderDisposition?: (props: {
		readonly command: BridgeWorkerRenderDispositionCommand;
		readonly store: BridgeCommWorkerStore;
	}) => readonly BridgeWorkerServerToMainMessage[];
}

function handleBridgeWorkerCommand(
	props: HandleBridgeWorkerCommandProps,
): readonly BridgeWorkerServerToMainMessage[] {
	switch (props.message.command) {
		case 'select':
			return handleBridgeWorkerSelectCommand({
				createSequence: props.createSequence,
				message: props.message,
				reviewRuntimeSource: props.reviewRuntimeSource,
				fileViewRuntimeSource: props.fileViewRuntimeSource,
				scheduleSelectedReviewContentReadyPreparation:
					props.scheduleSelectedReviewContentReadyPreparation,
				scheduleSelectedFileViewContentReadyPreparation:
					props.scheduleSelectedFileViewContentReadyPreparation,
				store: props.store,
				...(props.updateFileMetadataDemand === undefined
					? {}
					: { updateFileMetadataDemand: props.updateFileMetadataDemand }),
			});
		case 'viewport':
			return handleBridgeWorkerViewportCommand({
				createSequence: props.createSequence,
				message: props.message,
				fileViewRuntimeSource: props.fileViewRuntimeSource,
				...(props.scheduleDemandExecution === undefined
					? {}
					: { scheduleDemandExecution: props.scheduleDemandExecution }),
				store: props.store,
				...(props.updateFileMetadataDemand === undefined
					? {}
					: { updateFileMetadataDemand: props.updateFileMetadataDemand }),
			});
		case 'reviewInvalidate':
			return handleBridgeWorkerReviewInvalidateCommand({
				createSequence: props.createSequence,
				message: props.message,
				scheduleSelectedReviewContentReadyPreparation:
					props.scheduleSelectedReviewContentReadyPreparation,
				...(props.scheduleDemandExecution === undefined
					? {}
					: { scheduleDemandExecution: props.scheduleDemandExecution }),
				store: props.store,
			});
		case 'fileQueryUpdate':
			return (
				props.updateFileDisplayQuery?.(props.message) ?? [
					buildBridgeWorkerUnimplementedHealthEvent(props.message),
				]
			);
		case 'reviewProjectionUpdate':
			if (props.updateReviewDisplayProjection === undefined) {
				return [buildBridgeWorkerUnimplementedHealthEvent(props.message)];
			}
			return appendBridgeWorkerReadyAcknowledgement({
				messages: props.updateReviewDisplayProjection(props.message),
				requestId: props.message.requestId,
			});
		case 'fileDisplayResync':
			return (
				props.requestFileDisplayResync?.(props.message) ?? [
					buildBridgeWorkerUnimplementedHealthEvent(props.message),
				]
			);
		case 'renderDisposition':
			return (
				props.applyRenderDisposition?.({ command: props.message, store: props.store }) ??
				applyBridgeWorkerRenderDispositionCommand({
					command: props.message,
					store: props.store,
					...(props.telemetryClient === undefined
						? {}
						: { telemetryClient: props.telemetryClient }),
				}).messages
			);
		case 'hover':
			return handleBridgeCommWorkerReviewHoverCommand({
				message: props.message,
				store: props.store,
				...(props.scheduleDemandExecution === undefined
					? {}
					: { scheduleDemandExecution: props.scheduleDemandExecution }),
			});
		case 'annotationOutputInspect':
			return [];
		case 'annotationProjectionRetry':
			props.retryAnnotationProjection?.(props.message.surface === 'fileView' ? 'file' : 'review');
			return [buildBridgeWorkerReadyHealthEvent(props.message.requestId)];
		case 'viewRecoveryRetry':
			props.retryView?.(props.message.view);
			return [buildBridgeWorkerReadyHealthEvent(props.message.requestId)];
		case 'markFileViewed':
		case 'fileRefreshRetry':
		case 'annotationCommand':
		case 'metadataInterestUpdate':
		case 'reviewIntakeReady':
		case 'reviewComparisonUpdate':
		case 'reviewComparisonTargetsQuery':
		case 'reviewComparisonTargetsQueryCancel':
		case 'reviewPublicationInstallAdmit':
		case 'reviewPublicationInstalled':
		case 'activeViewerModeUpdate':
			return [buildBridgeWorkerReadyHealthEvent(props.message.requestId)];
		case 'mode':
			return [buildBridgeWorkerUnimplementedHealthEvent(props.message)];
		default:
			return assertNeverBridgeWorkerCommand(props.message);
	}
}

function appendBridgeWorkerReadyAcknowledgement(props: {
	readonly messages: readonly BridgeWorkerServerToMainMessage[];
	readonly requestId: string;
}): readonly BridgeWorkerServerToMainMessage[] {
	const alreadySettled = props.messages.some(
		(message): boolean =>
			(message.kind === 'health' || message.kind === 'subscription') &&
			message.requestId === props.requestId,
	);
	return alreadySettled
		? props.messages
		: [...props.messages, buildBridgeWorkerReadyHealthEvent(props.requestId)];
}

function applyBridgeCommWorkerFileViewRuntimeSource(props: {
	readonly createSequence: () => number;
	readonly demandEpoch: number;
	readonly epoch: number;
	readonly nextFileViewRuntimeSource: BridgeCommWorkerFileViewRuntimeSource;
	readonly previousFileViewRuntimeSource: BridgeCommWorkerFileViewRuntimeSource;
	readonly scheduleSelectedFileViewContentReadyPreparation: (
		request: BridgeCommWorkerSelectedFileViewContentReadyPreparationRequest,
	) => void;
	readonly store: BridgeCommWorkerStore;
	readonly updateFileViewRuntimeSource: (source: BridgeCommWorkerFileViewRuntimeSource) => void;
	readonly updateFileMetadataDemand?: (demand: BridgeCommWorkerFileMetadataDemand) => void;
}): readonly BridgeWorkerServerToMainMessage[] {
	const selectedContentRequestChanged = didSelectedFileViewContentRequestChange({
		nextFileViewRuntimeSource: props.nextFileViewRuntimeSource,
		previousFileViewRuntimeSource: props.previousFileViewRuntimeSource,
		selectedId: props.store.getState().selectedId,
	});
	const sourceUpdateResult = props.store.actions.applyFileViewSourceUpdateFact({
		contentItems: props.nextFileViewRuntimeSource.contentItems,
		epoch: props.epoch,
		rows: props.nextFileViewRuntimeSource.rows,
		selectedContentRequestChanged,
	});
	props.updateFileViewRuntimeSource(props.nextFileViewRuntimeSource);
	publishBridgeCommWorkerFileMetadataDemand({
		epoch: props.demandEpoch,
		fileViewRuntimeSource: props.nextFileViewRuntimeSource,
		store: props.store,
		...(props.updateFileMetadataDemand === undefined
			? {}
			: { updateFileMetadataDemand: props.updateFileMetadataDemand }),
	});
	const fileRenderPatch = takePendingFileSourceReconciliationRenderPatch({
		createSequence: props.createSequence,
		epoch: props.epoch,
		store: props.store,
	});
	scheduleSelectedFileViewContentReadyPreparationForCurrentDemand({
		epoch: props.epoch,
		schedulePreparation: props.scheduleSelectedFileViewContentReadyPreparation,
		selectedContentMetadataChanged:
			sourceUpdateResult.selectedFileViewContentMetadataChanged === true,
		selectedContentRequestChanged,
		store: props.store,
	});
	return fileRenderPatch === null ? [] : [fileRenderPatch];
}

function applyBridgeCommWorkerFileViewRuntimeMutation(props: {
	readonly createSequence: () => number;
	readonly demandEpoch: number;
	readonly epoch: number;
	readonly mutation: BridgeCommWorkerFileViewRuntimeMutation;
	readonly scheduleSelectedFileViewContentReadyPreparation: (
		request: BridgeCommWorkerSelectedFileViewContentReadyPreparationRequest,
	) => void;
	readonly source: BridgeCommWorkerFileViewRuntimeSource;
	readonly store: BridgeCommWorkerStore;
	readonly updateFileViewRuntimeSource: (source: BridgeCommWorkerFileViewRuntimeSource) => void;
	readonly updateFileMetadataDemand?: (demand: BridgeCommWorkerFileMetadataDemand) => void;
}): readonly BridgeWorkerServerToMainMessage[] {
	if (props.mutation.kind === 'reset') {
		props.store.renderFulfillmentRegistry.resetPublications();
	}
	const { nextSource, selectedContentRequestChanged } =
		applyFileViewRuntimeMutationTrackingSelectedRequest({
			mutation: props.mutation,
			selectedId: props.store.getState().selectedId,
			source: props.source,
		});
	const sourceUpdateResult = props.store.actions.applyFileViewSourceMutationFact({
		epoch: props.epoch,
		mutation: props.mutation,
		selectedContentRequestChanged,
	});
	props.updateFileViewRuntimeSource(nextSource);
	publishBridgeCommWorkerFileMetadataDemand({
		epoch: props.demandEpoch,
		fileViewRuntimeSource: nextSource,
		store: props.store,
		...(props.updateFileMetadataDemand === undefined
			? {}
			: { updateFileMetadataDemand: props.updateFileMetadataDemand }),
	});
	const fileRenderPatch = takePendingFileSourceReconciliationRenderPatch({
		createSequence: props.createSequence,
		epoch: props.epoch,
		store: props.store,
	});
	scheduleSelectedFileViewContentReadyPreparationForCurrentDemand({
		epoch: props.epoch,
		schedulePreparation: props.scheduleSelectedFileViewContentReadyPreparation,
		selectedContentMetadataChanged:
			sourceUpdateResult.selectedFileViewContentMetadataChanged === true,
		selectedContentRequestChanged,
		store: props.store,
	});
	return fileRenderPatch === null ? [] : [fileRenderPatch];
}

function takePendingFileSourceReconciliationRenderPatch(props: {
	readonly createSequence: () => number;
	readonly epoch: number;
	readonly store: BridgeCommWorkerStore;
}): BridgeWorkerServerToMainMessage | null {
	const publicationSequence = props.createSequence();
	const slicePatch = props.store.actions.takePendingSlicePatchEvent({
		epoch: props.epoch,
		sequence: publicationSequence,
	});
	if (slicePatch === null) {
		return null;
	}
	return prepareBridgeWorkerFileRenderPatchEvent({
		patches: bridgeWorkerFileRenderPatchesFromSlicePatchEvent(slicePatch),
		publicationSequence,
		workerDerivationEpoch: props.epoch,
	}).message;
}

interface HandleBridgeWorkerSelectCommandProps {
	readonly createSequence: () => number;
	readonly message: BridgeWorkerSelectCommand;
	readonly fileViewRuntimeSource: BridgeCommWorkerFileViewRuntimeSource;
	readonly reviewRuntimeSource: BridgeCommWorkerReviewRuntimeSource;
	readonly scheduleSelectedReviewContentReadyPreparation: (
		request: BridgeCommWorkerSelectedReviewContentReadyPreparationRequest,
	) => void;
	readonly scheduleSelectedFileViewContentReadyPreparation: (
		request: BridgeCommWorkerSelectedFileViewContentReadyPreparationRequest,
	) => void;
	readonly store: BridgeCommWorkerStore;
	readonly updateFileMetadataDemand?: (demand: BridgeCommWorkerFileMetadataDemand) => void;
}

function handleBridgeWorkerSelectCommand(
	props: HandleBridgeWorkerSelectCommandProps,
): readonly BridgeWorkerServerToMainMessage[] {
	if (props.message.selectedItemId === null) {
		props.store.actions.clearSelectedFact({ epoch: props.message.epoch });
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
		return [
			...(slicePatch === null ? [] : [slicePatch]),
			buildBridgeWorkerReadyHealthEvent(props.message.requestId),
		];
	}
	if (props.message.surface === 'review') {
		applySelectedReviewRuntimeSourceItemIfNeeded({
			epoch: props.message.epoch,
			itemId: props.message.selectedItemId,
			reviewRuntimeSource: props.reviewRuntimeSource,
			store: props.store,
		});
	}
	props.store.actions.applySelectedFact({
		epoch: props.message.epoch,
		itemId: props.message.selectedItemId,
	});
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
	scheduleSelectedContentReadyPreparationForSelection(props);
	return [
		...(slicePatch === null ? [] : [slicePatch]),
		buildBridgeWorkerReadyHealthEvent(props.message.requestId),
	];
}

function applySelectedReviewRuntimeSourceItemIfNeeded(props: {
	readonly epoch: number;
	readonly itemId: string;
	readonly reviewRuntimeSource: BridgeCommWorkerReviewRuntimeSource;
	readonly store: BridgeCommWorkerStore;
}): void {
	const contentItem =
		props.reviewRuntimeSource.contentItems.find((candidate) => candidate.itemId === props.itemId) ??
		null;
	const row =
		props.reviewRuntimeSource.rows.find((candidate) => candidate.id === props.itemId) ?? null;
	if (contentItem === null || row === null) {
		return;
	}
	props.store.actions.applyReviewSourceUpdateFact({
		contentItems: [contentItem],
		epoch: props.epoch,
		resetComplete: false,
		rows: [row],
	});
}

function scheduleSelectedContentReadyPreparationForSelection(
	props: Pick<
		HandleBridgeWorkerSelectCommandProps,
		| 'message'
		| 'scheduleSelectedFileViewContentReadyPreparation'
		| 'scheduleSelectedReviewContentReadyPreparation'
		| 'store'
	>,
): void {
	const selectedItemId = props.message.selectedItemId;
	if (selectedItemId === null) return;
	if (props.message.surface === 'fileView') {
		const selectedState = props.store.getState();
		if (
			selectedState.selectedId === selectedItemId &&
			selectedState.selectedEpoch === props.message.epoch
		) {
			props.scheduleSelectedFileViewContentReadyPreparation({
				epoch: props.message.epoch,
				itemId: selectedItemId,
				store: props.store,
			});
		}
		return;
	}
	if (
		!isSelectedContentReadyPreparationCurrent({
			epoch: props.message.epoch,
			itemId: selectedItemId,
			store: props.store,
		})
	) {
		return;
	}
	const metadata = props.store.getState().contentMetadataByItemId.get(selectedItemId) ?? null;
	if (props.message.surface === 'review' && isBridgeWorkerReviewContentMetadata(metadata)) {
		props.scheduleSelectedReviewContentReadyPreparation({
			epoch: props.message.epoch,
			itemId: selectedItemId,
			store: props.store,
		});
	}
}
