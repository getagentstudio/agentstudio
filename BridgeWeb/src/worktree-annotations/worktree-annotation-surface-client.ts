import { encodeBridgeWorkerViewRecoveryRetryCommand } from '../core/comm-worker/bridge-comm-worker-protocol.js';
import type { BridgeMainViewRecoveryStatus } from '../core/comm-worker/bridge-main-render-snapshot-store.js';
import type { BridgePaneSurfaceClient } from '../core/comm-worker/bridge-pane-runtime.js';
import type { BridgeProductWorktreeAnnotationOperation } from '../core/comm-worker/bridge-product-call-contracts.js';
import type { BridgeProductAnnotationOutputContentDescriptor } from '../core/comm-worker/bridge-product-content-contracts.js';
import type { BridgeWorkerServerToMainMessage } from '../core/comm-worker/bridge-worker-contracts.js';
import type { BridgeTelemetryRecorder } from '../foundation/telemetry/bridge-telemetry-recorder.js';
import { recordWorktreeAnnotationLifecycleTelemetry } from './worktree-annotation-lifecycle-telemetry.js';
import {
	WorktreeAnnotationProjectionStore,
	type WorktreeAnnotationCatalogProjection,
	type WorktreeAnnotationCommandOutcome,
	type WorktreeAnnotationProjectionSnapshot,
} from './worktree-annotation-projection-store.js';
import {
	annotationContentSessionIdsMeetCurrentDemand,
	reviewAffectedItemIdsForInstalledChanges,
	reviewAnnotationPublicationIdentityForMainIdentity,
	reviewAnnotationPublicationIdentitiesMatch,
	type PendingReviewAnnotationApplicationCheckpoint,
	type ReviewAnnotationApplicationCheckpoint,
} from './worktree-annotation-review-application.js';

const noopUnsubscribe = (): void => {};
const maximumRetainedOrphanCorrelationCount = 128;
// Consecutive demand acquisitions sent before the client waits for the next worker
// convergence event. Bounds retries without a clock; every worker event re-admits one.
const maximumConsecutiveDemandAcquireAttempts = 3;
// The worker's deadline passed after dispatch: native may still commit, and a late
// receipt reconciles the comments. This copy must not claim the change failed.
export const worktreeAnnotationOutcomeUnknownMessage =
	'Still confirming this change. Comments update when it completes.';
export {
	emptyWorktreeAnnotationProjectionSnapshot,
	WorktreeAnnotationProjectionStore,
} from './worktree-annotation-projection-store.js';
export type {
	WorktreeAnnotationCatalogProjection,
	WorktreeAnnotationCommandConfirmedThreadProjection,
	WorktreeAnnotationCommandOutcome,
	WorktreeAnnotationInlineThreadProjection,
	WorktreeAnnotationMessageEntry,
	WorktreeAnnotationOutputHistorySummary,
	WorktreeAnnotationProjectionSnapshot,
	WorktreeAnnotationSessionSummary,
	WorktreeAnnotationThreadContext,
	WorktreeAnnotationThreadProjection,
} from './worktree-annotation-projection-store.js';

export interface WorktreeAnnotationOutputInspection {
	readonly descriptor: BridgeProductAnnotationOutputContentDescriptor;
	readonly exactBytes: Uint8Array;
}

export interface WorktreeAnnotationSurfaceClient {
	readonly acquireSession: (sessionId: string) => () => void;
	readonly acknowledgeReviewAnnotationApplication: (applicationId: number) => boolean;
	readonly dispose: () => void;
	readonly execute: (
		operation: BridgeProductWorktreeAnnotationOperation,
	) => Promise<WorktreeAnnotationCommandOutcome>;
	readonly getServerSnapshot: () => WorktreeAnnotationProjectionSnapshot;
	readonly getCatalogSnapshot: () => WorktreeAnnotationCatalogProjection;
	readonly getSnapshot: () => WorktreeAnnotationProjectionSnapshot;
	readonly getViewRecoveryStatus: () => BridgeMainViewRecoveryStatus | null;
	readonly inspectOutput: (attemptId: string) => Promise<WorktreeAnnotationOutputInspection>;
	readonly retryProjection: () => void;
	readonly retryViewRecovery: () => void;
	readonly subscribe: (listener: () => void) => () => void;
	readonly subscribeViewRecoveryStatus: (listener: () => void) => () => void;
	readonly waitForSnapshot: <TResult>(
		select: (snapshot: WorktreeAnnotationProjectionSnapshot) => TResult | null,
	) => Promise<TResult>;
}

interface PendingAnnotationCommand {
	readonly reject: (error: Error) => void;
	readonly resolve: (outcome: WorktreeAnnotationCommandOutcome) => void;
	productRequestId: string | null;
}

interface PendingAnnotationCommandSettlement {
	readonly reject: (error: Error) => void;
	readonly resolve: (outcome: WorktreeAnnotationCommandOutcome) => void;
}

// The worker registers a demanded session only on a committed `demand.acquire`, and a
// replacement worker starts with none. `committed` is demand this worker holds;
// `awaitingWorker` is demand to re-acquire on the next worker convergence event.
interface SessionDemandAcquisition {
	attemptId: number;
	consecutiveFailedAttempts: number;
	refreshesSourceOnReacquire: boolean;
	state: 'acquiring' | 'awaitingWorker' | 'committed';
}

interface PendingAnnotationOutputInspection {
	readonly reject: (error: Error) => void;
	readonly resolve: (inspection: WorktreeAnnotationOutputInspection) => void;
}

export function createWorktreeAnnotationSurfaceClient(
	surfaceClient: BridgePaneSurfaceClient,
	telemetryRecorder?: BridgeTelemetryRecorder,
): WorktreeAnnotationSurfaceClient {
	const pendingCommandsByWorkerRequestId = new Map<string, PendingAnnotationCommand>();
	const pendingOutputInspectionsByWorkerRequestId = new Map<
		string,
		PendingAnnotationOutputInspection
	>();
	const pendingWorkerRequestIdByProductRequestId = new Map<string, string>();
	const acceptedProductRequestIdByWorkerRequestId = new Map<string, string>();
	const outcomesByProductRequestId = new Map<string, WorktreeAnnotationCommandOutcome>();
	const degradedFailureByWorkerRequestId = new Map<string, Error>();
	const demandCountBySessionId = new Map<string, number>();
	const demandAcquisitionBySessionId = new Map<string, SessionDemandAcquisition>();
	let nextDemandAcquireAttemptId = 0;
	const rejectPendingSnapshotWaiters = new Set<(error: Error) => void>();
	let isDisposed = false;
	let observedSurfaceEpoch = currentSurfaceEpoch(surfaceClient);
	let nextSourceRefreshEpoch = 0;
	let nextViewRecoveryRetryRequestId = 0;
	let nextReviewAnnotationApplicationId = 0;
	let completedReviewAnnotationApplicationCheckpoint: ReviewAnnotationApplicationCheckpoint | null =
		null;
	let pendingReviewAnnotationApplicationCheckpoint: PendingReviewAnnotationApplicationCheckpoint | null =
		null;
	const projectionStore = new WorktreeAnnotationProjectionStore();
	const annotationSubscriptionKind =
		surfaceClient.surface === 'fileView' ? 'file.annotations' : 'review.annotations';

	const settleProductOutcome = (outcome: WorktreeAnnotationCommandOutcome): void => {
		projectionStore.recordCommandOutcome(outcome);
		if (outcome.status.kind === 'history') {
			if (outcome.sessionId === null) {
				projectionStore.replaceOutputHistory(outcome.status.summaries);
			} else {
				projectionStore.replaceOutputHistoryForSession(outcome.sessionId, outcome.status.summaries);
			}
		}
		retainBoundedOrphanCorrelation(outcomesByProductRequestId, outcome.requestId, outcome);
		const workerRequestId = pendingWorkerRequestIdByProductRequestId.get(outcome.requestId);
		if (workerRequestId === undefined) return;
		const pendingCommand = pendingCommandsByWorkerRequestId.get(workerRequestId);
		if (pendingCommand === undefined) return;
		pendingCommandsByWorkerRequestId.delete(workerRequestId);
		pendingWorkerRequestIdByProductRequestId.delete(outcome.requestId);
		outcomesByProductRequestId.delete(outcome.requestId);
		pendingCommand.resolve(outcome);
	};

	const acceptProductRequest = (workerRequestId: string, productRequestId: string): void => {
		const pendingCommand = pendingCommandsByWorkerRequestId.get(workerRequestId);
		if (pendingCommand === undefined) {
			retainBoundedOrphanCorrelation(
				acceptedProductRequestIdByWorkerRequestId,
				workerRequestId,
				productRequestId,
			);
			return;
		}
		pendingCommand.productRequestId = productRequestId;
		pendingWorkerRequestIdByProductRequestId.set(productRequestId, workerRequestId);
		const existingOutcome = outcomesByProductRequestId.get(productRequestId);
		if (existingOutcome !== undefined) settleProductOutcome(existingOutcome);
	};

	const failWorkerRequest = (workerRequestId: string, error: Error): void => {
		const pendingCommand = pendingCommandsByWorkerRequestId.get(workerRequestId);
		const pendingOutputInspection = pendingOutputInspectionsByWorkerRequestId.get(workerRequestId);
		if (pendingCommand === undefined && pendingOutputInspection === undefined) {
			retainBoundedOrphanCorrelation(degradedFailureByWorkerRequestId, workerRequestId, error);
			return;
		}
		if (pendingCommand !== undefined) {
			pendingCommandsByWorkerRequestId.delete(workerRequestId);
			if (pendingCommand.productRequestId !== null) {
				pendingWorkerRequestIdByProductRequestId.delete(pendingCommand.productRequestId);
			}
			pendingCommand.reject(error);
		}
		if (pendingOutputInspection !== undefined) {
			pendingOutputInspectionsByWorkerRequestId.delete(workerRequestId);
			pendingOutputInspection.reject(error);
		}
	};

	const unsubscribeMessages = surfaceClient.subscribeMessages(
		(message: BridgeWorkerServerToMainMessage): void => {
			if (isDisposed) return;
			if (message.kind === 'annotationCatalogStaging') {
				if (message.surface === surfaceClient.surface) {
					projectionStore.applyCatalogStaging(message);
				}
				return;
			}
			if (message.kind === 'annotationOutputInspection') {
				const pendingInspection = pendingOutputInspectionsByWorkerRequestId.get(message.requestId);
				if (pendingInspection === undefined) return;
				pendingOutputInspectionsByWorkerRequestId.delete(message.requestId);
				pendingInspection.resolve({
					descriptor: message.descriptor,
					exactBytes: new Uint8Array(message.exactBytes),
				});
				return;
			}
			if (message.kind === 'annotationCommandAccepted') {
				acceptProductRequest(message.requestId, message.productRequestId);
				if (message.outcome !== undefined) settleProductOutcome(message.outcome);
				return;
			}
			if (message.kind === 'annotationProjectionConvergence') {
				if (message.surface !== surfaceClient.surface) return;
				reacquireDemandAwaitingWorker();
				if (message.state.kind === 'ready') {
					if (message.operationCorrelationId !== null) {
						const expectedContentSessionIds = [...demandCountBySessionId.keys()];
						let reviewAnnotationApplication: {
							readonly affectedItemIds: readonly string[] | null;
							readonly applicationId: number;
						} | null = null;
						let nextPendingCheckpoint: PendingReviewAnnotationApplicationCheckpoint | null = null;
						if (surfaceClient.surface === 'review') {
							const readyIdentity = message.state.reviewPublicationIdentity;
							const activeIdentity =
								surfaceClient.renderStore.getReviewRefreshPresentation().activeIdentity;
							if (
								readyIdentity === undefined ||
								activeIdentity === null ||
								!reviewAnnotationPublicationIdentitiesMatch(readyIdentity, activeIdentity)
							) {
								return;
							}
							if (
								annotationContentSessionIdsMeetCurrentDemand(
									message.state.contentSessionIds,
									expectedContentSessionIds,
								)
							) {
								const targetCatalogCursor =
									surfaceClient.renderStore.getReviewCatalogSnapshot().changeCursor;
								nextReviewAnnotationApplicationId += 1;
								reviewAnnotationApplication = {
									affectedItemIds: reviewAffectedItemIdsForInstalledChanges({
										checkpoint: completedReviewAnnotationApplicationCheckpoint,
										currentIdentity: readyIdentity,
										renderStore: surfaceClient.renderStore,
										targetCatalogCursor,
									}),
									applicationId: nextReviewAnnotationApplicationId,
								};
								nextPendingCheckpoint = {
									applicationId: nextReviewAnnotationApplicationId,
									catalogCursor: targetCatalogCursor,
									identity: readyIdentity,
								};
							}
						} else if (message.state.reviewPublicationIdentity !== undefined) {
							return;
						}
						// Bracket main-owned work on one telemetry producer so backpressure
						// cannot deliver a terminal ahead of its start on another port.
						for (const phase of [
							'projection_store_started',
							'main_thread_install_started',
						] as const) {
							recordWorktreeAnnotationLifecycleTelemetry({
								operationCorrelationId: message.operationCorrelationId,
								phase,
								recorder: telemetryRecorder,
								result: 'started',
								sourceGeneration: message.state.snapshot.sourceGeneration,
								stageAttempt: message.state.stageAttempt,
								transport: 'local',
								viewer: surfaceClient.surface === 'fileView' ? 'file' : 'review',
							});
						}
						const projectionApplied = projectionStore.apply({
							contentSessionIds: message.state.contentSessionIds,
							expectedContentSessionIds,
							operationCorrelationId: message.operationCorrelationId,
							reviewAnnotationApplication,
							snapshot: message.state.snapshot,
						});
						if (projectionApplied && nextPendingCheckpoint !== null) {
							pendingReviewAnnotationApplicationCheckpoint = nextPendingCheckpoint;
						}
						for (const sessionId of message.state.contentSessionIds) {
							if (!demandCountBySessionId.has(sessionId)) continue;
							void execute({ kind: 'output.history', sessionId }).catch((): void => {});
						}
						recordWorktreeAnnotationLifecycleTelemetry({
							operationCorrelationId: message.operationCorrelationId,
							phase: 'projection_store_terminal',
							recorder: telemetryRecorder,
							result: 'success',
							sourceGeneration: message.state.snapshot.sourceGeneration,
							stageAttempt: message.state.stageAttempt,
							transport: 'local',
							viewer: surfaceClient.surface === 'fileView' ? 'file' : 'review',
						});
						recordWorktreeAnnotationLifecycleTelemetry({
							operationCorrelationId: message.operationCorrelationId,
							phase: 'main_thread_install_terminal',
							recorder: telemetryRecorder,
							result: 'success',
							sourceGeneration: message.state.snapshot.sourceGeneration,
							stageAttempt: message.state.stageAttempt,
							transport: 'local',
							viewer: surfaceClient.surface === 'fileView' ? 'file' : 'review',
						});
					}
				} else if (message.state.kind === 'refreshing') {
					if (message.state.catalogAuthorityRetired) {
						// A routine epoch replacement: comments stay visible as stale until the
						// replacement catalog arrives, instead of reading as unavailable.
						completedReviewAnnotationApplicationCheckpoint = null;
						pendingReviewAnnotationApplicationCheckpoint = null;
						projectionStore.prepareForWorkerReplacement();
					}
					projectionStore.markRefreshing();
				} else {
					if (message.state.catalogAuthorityRetired) {
						completedReviewAnnotationApplicationCheckpoint = null;
						pendingReviewAnnotationApplicationCheckpoint = null;
						projectionStore.prepareForWorkerReplacement();
					}
					projectionStore.markUnavailable(message.state.retryable);
				}
				return;
			}
			if (
				message.kind === 'health' &&
				message.status === 'degraded' &&
				message.requestId !== undefined
			) {
				failWorkerRequest(
					message.requestId,
					new Error(
						message.deliveryStatus === 'unknownAfterDispatch'
							? worktreeAnnotationOutcomeUnknownMessage
							: (message.message ?? 'Bridge annotation command failed.'),
					),
				);
			}
		},
	);

	// Settlement runs synchronously with the worker message that decides it, so demand
	// recovery reacts in the same turn as the outcome.
	const dispatchCommand = (
		operation: BridgeProductWorktreeAnnotationOperation,
		settlement: PendingAnnotationCommandSettlement,
	): void => {
		if (isDisposed) {
			settlement.reject(new Error('Annotation surface client is disposed.'));
			return;
		}
		let workerRequestId: string;
		try {
			workerRequestId =
				surfaceClient.surface === 'fileView'
					? surfaceClient.send({
							command: 'annotationCommand',
							epoch: currentSurfaceEpoch(surfaceClient),
							operation,
							surface: 'fileView',
						})
					: sendReviewAnnotationCommand(surfaceClient, operation);
		} catch (error) {
			settlement.reject(
				error instanceof Error ? error : new Error('Review annotation command admission failed.'),
			);
			return;
		}
		const pendingCommand: PendingAnnotationCommand = {
			productRequestId: null,
			reject: settlement.reject,
			resolve: settlement.resolve,
		};
		pendingCommandsByWorkerRequestId.set(workerRequestId, pendingCommand);
		const degradedFailure = degradedFailureByWorkerRequestId.get(workerRequestId);
		if (degradedFailure !== undefined) {
			degradedFailureByWorkerRequestId.delete(workerRequestId);
			failWorkerRequest(workerRequestId, degradedFailure);
			return;
		}
		const acceptedProductRequestId = acceptedProductRequestIdByWorkerRequestId.get(workerRequestId);
		if (acceptedProductRequestId !== undefined) {
			acceptedProductRequestIdByWorkerRequestId.delete(workerRequestId);
			acceptProductRequest(workerRequestId, acceptedProductRequestId);
		}
	};
	const execute = (
		operation: BridgeProductWorktreeAnnotationOperation,
	): Promise<WorktreeAnnotationCommandOutcome> =>
		new Promise<WorktreeAnnotationCommandOutcome>((resolve, reject): void => {
			dispatchCommand(operation, { reject, resolve });
		});
	const settleDemandAcquireAttempt = (
		sessionId: string,
		attemptId: number,
		didCommit: boolean,
	): void => {
		const acquisition = demandAcquisitionBySessionId.get(sessionId);
		if (isDisposed || acquisition?.attemptId !== attemptId) return;
		if (didCommit) {
			acquisition.state = 'committed';
			acquisition.consecutiveFailedAttempts = 0;
			return;
		}
		acquisition.consecutiveFailedAttempts += 1;
		if (acquisition.consecutiveFailedAttempts < maximumConsecutiveDemandAcquireAttempts) {
			sendDemandAcquire(sessionId);
			return;
		}
		acquisition.state = 'awaitingWorker';
	};
	const sendDemandAcquire = (sessionId: string): void => {
		const acquisition = demandAcquisitionBySessionId.get(sessionId);
		if (acquisition === undefined) return;
		nextDemandAcquireAttemptId += 1;
		const attemptId = nextDemandAcquireAttemptId;
		acquisition.attemptId = attemptId;
		acquisition.state = 'acquiring';
		dispatchCommand(
			{ kind: 'demand.acquire', sessionId },
			{
				reject: (): void => settleDemandAcquireAttempt(sessionId, attemptId, false),
				resolve: (outcome): void =>
					settleDemandAcquireAttempt(sessionId, attemptId, outcome.status.kind === 'committed'),
			},
		);
	};
	const reacquireDemandAwaitingWorker = (): void => {
		for (const [sessionId, acquisition] of demandAcquisitionBySessionId) {
			if (acquisition.state !== 'awaitingWorker') continue;
			const refreshesSource = acquisition.refreshesSourceOnReacquire;
			acquisition.refreshesSourceOnReacquire = false;
			sendDemandAcquire(sessionId);
			if (refreshesSource && demandAcquisitionBySessionId.has(sessionId)) {
				refreshDemandedSession(sessionId);
			}
		}
	};
	const retireDemandForWorkerReplacement = (): void => {
		for (const acquisition of demandAcquisitionBySessionId.values()) {
			// A fresh attempt id retires any in-flight attempt owned by the old worker.
			nextDemandAcquireAttemptId += 1;
			acquisition.attemptId = nextDemandAcquireAttemptId;
			acquisition.consecutiveFailedAttempts = 0;
			acquisition.refreshesSourceOnReacquire = true;
			acquisition.state = 'awaitingWorker';
		}
	};
	const inspectOutput = (attemptId: string): Promise<WorktreeAnnotationOutputInspection> => {
		if (isDisposed) return Promise.reject(new Error('Annotation surface client is disposed.'));
		const workerRequestId = surfaceClient.send({
			attemptId,
			command: 'annotationOutputInspect',
			epoch: currentSurfaceEpoch(surfaceClient),
			surface: surfaceClient.surface,
		});
		return new Promise<WorktreeAnnotationOutputInspection>((resolve, reject): void => {
			pendingOutputInspectionsByWorkerRequestId.set(workerRequestId, { reject, resolve });
			const degradedFailure = degradedFailureByWorkerRequestId.get(workerRequestId);
			if (degradedFailure === undefined) return;
			degradedFailureByWorkerRequestId.delete(workerRequestId);
			failWorkerRequest(workerRequestId, degradedFailure);
		});
	};
	const waitForSnapshot = <TResult>(
		select: (snapshot: WorktreeAnnotationProjectionSnapshot) => TResult | null,
	): Promise<TResult> => {
		if (isDisposed) return Promise.reject(new Error('Annotation surface client is disposed.'));
		const currentResult = select(projectionStore.getSnapshot());
		if (currentResult !== null) return Promise.resolve(currentResult);
		return new Promise<TResult>((resolve, reject): void => {
			let unsubscribe = noopUnsubscribe;
			const rejectWaiter = (error: Error): void => {
				unsubscribe();
				rejectPendingSnapshotWaiters.delete(rejectWaiter);
				reject(error);
			};
			rejectPendingSnapshotWaiters.add(rejectWaiter);
			unsubscribe = projectionStore.subscribe((): void => {
				const result = select(projectionStore.getSnapshot());
				if (result === null) return;
				unsubscribe();
				rejectPendingSnapshotWaiters.delete(rejectWaiter);
				resolve(result);
			});
		});
	};
	const refreshDemandedSession = (sessionId: string): void => {
		nextSourceRefreshEpoch += 1;
		void execute({
			kind: 'source.refresh',
			sessionId,
			sourceEpoch: nextSourceRefreshEpoch,
		}).catch((): void => {});
	};
	const discardPendingApplicationForRetiredReviewIdentity = (): void => {
		const pendingCheckpoint = pendingReviewAnnotationApplicationCheckpoint;
		if (
			pendingCheckpoint !== null &&
			!reviewAnnotationPublicationIdentitiesMatch(
				pendingCheckpoint.identity,
				surfaceClient.renderStore.getReviewRefreshPresentation().activeIdentity,
			)
		) {
			pendingReviewAnnotationApplicationCheckpoint = null;
			projectionStore.discardPendingReviewAnnotationApplication();
		}
	};
	const unsubscribeReviewPresentation =
		surfaceClient.surface === 'review'
			? surfaceClient.renderStore.subscribeReviewRefreshPresentation(
					discardPendingApplicationForRetiredReviewIdentity,
				)
			: noopUnsubscribe;
	const unsubscribeSourceEpoch = surfaceClient.renderStore.subscribe((): void => {
		const currentEpoch = currentSurfaceEpoch(surfaceClient);
		if (currentEpoch === observedSurfaceEpoch) return;
		observedSurfaceEpoch = currentEpoch;
		for (const sessionId of demandCountBySessionId.keys()) refreshDemandedSession(sessionId);
	});
	const unsubscribeWorkerReplacement =
		surfaceClient.subscribeWorkerReplacement?.((): void => {
			completedReviewAnnotationApplicationCheckpoint = null;
			pendingReviewAnnotationApplicationCheckpoint = null;
			projectionStore.prepareForWorkerReplacement();
			// The retiring worker still owns the port here; re-acquire once the replacement
			// reports its first projection convergence.
			retireDemandForWorkerReplacement();
		}) ?? noopUnsubscribe;

	return {
		acquireSession: (sessionId): (() => void) => {
			const currentDemandCount = demandCountBySessionId.get(sessionId) ?? 0;
			demandCountBySessionId.set(sessionId, currentDemandCount + 1);
			if (currentDemandCount === 0) {
				projectionStore.markSessionDemanded(sessionId);
				demandAcquisitionBySessionId.set(sessionId, {
					attemptId: 0,
					consecutiveFailedAttempts: 0,
					refreshesSourceOnReacquire: false,
					state: 'acquiring',
				});
				sendDemandAcquire(sessionId);
				refreshDemandedSession(sessionId);
				void execute({ kind: 'output.history', sessionId }).catch((): void => {});
			}
			let isReleased = false;
			return (): void => {
				if (isReleased || isDisposed) return;
				isReleased = true;
				const nextDemandCount = (demandCountBySessionId.get(sessionId) ?? 1) - 1;
				if (nextDemandCount > 0) {
					demandCountBySessionId.set(sessionId, nextDemandCount);
					return;
				}
				demandCountBySessionId.delete(sessionId);
				demandAcquisitionBySessionId.delete(sessionId);
				void execute({ kind: 'demand.release', sessionId }).catch((): void => {});
			};
		},
		acknowledgeReviewAnnotationApplication: (applicationId): boolean => {
			const pendingCheckpoint = pendingReviewAnnotationApplicationCheckpoint;
			if (
				pendingCheckpoint?.applicationId !== applicationId ||
				!projectionStore.acknowledgeReviewAnnotationApplication(applicationId)
			) {
				return false;
			}
			completedReviewAnnotationApplicationCheckpoint = {
				catalogCursor: pendingCheckpoint.catalogCursor,
				identity: pendingCheckpoint.identity,
			};
			pendingReviewAnnotationApplicationCheckpoint = null;
			return true;
		},
		dispose: (): void => {
			if (isDisposed) return;
			isDisposed = true;
			unsubscribeMessages();
			unsubscribeReviewPresentation();
			unsubscribeSourceEpoch();
			unsubscribeWorkerReplacement();
			const disposalError = new Error('Annotation surface client is disposed.');
			for (const pendingCommand of pendingCommandsByWorkerRequestId.values()) {
				pendingCommand.reject(disposalError);
			}
			pendingCommandsByWorkerRequestId.clear();
			for (const pendingInspection of pendingOutputInspectionsByWorkerRequestId.values()) {
				pendingInspection.reject(disposalError);
			}
			pendingOutputInspectionsByWorkerRequestId.clear();
			pendingWorkerRequestIdByProductRequestId.clear();
			outcomesByProductRequestId.clear();
			acceptedProductRequestIdByWorkerRequestId.clear();
			degradedFailureByWorkerRequestId.clear();
			for (const rejectWaiter of rejectPendingSnapshotWaiters) rejectWaiter(disposalError);
			rejectPendingSnapshotWaiters.clear();
			demandCountBySessionId.clear();
			demandAcquisitionBySessionId.clear();
		},
		execute,
		getCatalogSnapshot: projectionStore.getCatalogSnapshot,
		getServerSnapshot: projectionStore.getServerSnapshot,
		getSnapshot: projectionStore.getSnapshot,
		getViewRecoveryStatus: (): BridgeMainViewRecoveryStatus | null =>
			surfaceClient.renderStore.getViewRecoveryStatus(annotationSubscriptionKind),
		inspectOutput,
		retryProjection: (): void => {
			if (isDisposed) return;
			surfaceClient.send({
				command: 'annotationProjectionRetry',
				epoch: currentSurfaceEpoch(surfaceClient),
				surface: surfaceClient.surface,
			});
		},
		retryViewRecovery: (): void => {
			if (isDisposed) return;
			const recoveryStatus = surfaceClient.renderStore.getViewRecoveryStatus(
				annotationSubscriptionKind,
			);
			if (recoveryStatus?.status !== 'failedRetryable') return;
			surfaceClient.send(
				encodeBridgeWorkerViewRecoveryRetryCommand({
					epoch: currentSurfaceEpoch(surfaceClient),
					requestId: `annotation-view-recovery-retry-${++nextViewRecoveryRetryRequestId}`,
					view: recoveryStatus.view,
				}),
			);
		},
		subscribe: projectionStore.subscribe,
		subscribeViewRecoveryStatus: surfaceClient.renderStore.subscribeViewRecoveryStatus,
		waitForSnapshot,
	};
}

function sendReviewAnnotationCommand(
	surfaceClient: BridgePaneSurfaceClient,
	operation: BridgeProductWorktreeAnnotationOperation,
): string {
	const activeIdentity = surfaceClient.renderStore.getReviewRefreshPresentation().activeIdentity;
	if (activeIdentity === null) {
		throw new Error('Review annotation command has no installed publication identity.');
	}
	const reviewPublicationIdentity =
		reviewAnnotationPublicationIdentityForMainIdentity(activeIdentity);
	return surfaceClient.send({
		command: 'annotationCommand',
		epoch: currentSurfaceEpoch(surfaceClient),
		operation,
		reviewPublicationIdentity,
		surface: 'review',
	});
}

function retainBoundedOrphanCorrelation<TKey, TValue>(
	map: Map<TKey, TValue>,
	key: TKey,
	value: TValue,
): void {
	map.set(key, value);
	if (map.size <= maximumRetainedOrphanCorrelationCount) return;
	const oldestKey = map.keys().next().value;
	if (oldestKey !== undefined) map.delete(oldestKey);
}

function currentSurfaceEpoch(surfaceClient: BridgePaneSurfaceClient): number {
	const renderSnapshot = surfaceClient.renderStore.getSnapshot();
	return surfaceClient.surface === 'fileView'
		? (renderSnapshot.fileDisplayFreshness?.epoch ?? 0)
		: (renderSnapshot.reviewDisplayFreshness?.epoch ?? 0);
}
