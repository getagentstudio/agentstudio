import {
	recordBridgeReviewCandidateSourceDiagnostic,
	recordBridgeReviewDisplayPatchDiagnostic,
	type BridgeReviewDisplayPatchDiagnostic,
} from '../../foundation/diagnostics/bridge-review-selection-diagnostic.js';
import type { BridgeWorkerRuntimeRecoverySource } from '../../foundation/diagnostics/bridge-worker-replacement-reason.js';
import type { BridgeTelemetryRecorder } from '../../foundation/telemetry/bridge-telemetry-recorder.js';
import { prepareBridgeMainPierreItemForPresentation } from './bridge-main-pierre-item-adapter.js';
import type { BridgeMainRenderFulfillmentCoordinator } from './bridge-main-render-fulfillment-coordinator.js';
import type {
	BridgeMainRenderSnapshotStore,
	BridgeMainReviewPublicationIdentity,
} from './bridge-main-render-snapshot-store.js';
import {
	createBridgeMainReviewPresentationInstallationGate,
	type BridgeMainReviewInstallAdmissionResult,
	type BridgeMainReviewSemanticAttention,
} from './bridge-main-review-presentation-installation-gate.js';
import { recordBridgeReviewRefreshLifecycleTelemetry } from './bridge-review-refresh-lifecycle-telemetry.js';
import type {
	BridgeWorkerReviewPierreRenderJobEvent,
	BridgeWorkerReviewRenderPatchEvent,
	BridgeWorkerServerToMainMessage,
} from './bridge-worker-contracts.js';
import type { BridgeWorkerPierreCourier } from './bridge-worker-pierre-courier.js';
import type { BridgeWorkerRpcCommandInput } from './bridge-worker-rpc-client.js';
import type { BridgeWorkerRpcLifecycleSnapshot } from './bridge-worker-rpc-lifecycle-store.js';

export interface BridgeMainReviewPublicationClient {
	readonly requestWorkerReplacement: (source: BridgeWorkerRuntimeRecoverySource) => void;
	readonly lifecycle: {
		readonly getSnapshot: () => BridgeWorkerRpcLifecycleSnapshot;
		readonly subscribe: (listener: () => void) => () => void;
	};
	readonly send: (command: BridgeWorkerRpcCommandInput) => string;
}

export interface BridgeMainReviewPublicationIntegration {
	readonly applyNow: () => Promise<void>;
	readonly dispose: () => void;
	readonly handleMessage: (message: BridgeWorkerServerToMainMessage) => boolean;
	readonly setSemanticAttention: (attention: BridgeMainReviewSemanticAttention) => void;
	readonly start: () => void;
	readonly whenSettled: () => Promise<void>;
}

interface PublicationRoute {
	readonly identity: BridgeMainReviewPublicationIdentity;
	readonly kind: 'active' | 'candidate';
}

interface DeferredCandidatePierrePublication {
	readonly finalItem: BridgeWorkerReviewPierreRenderJobEvent['job']['payload']['item'];
	readonly message: BridgeWorkerReviewPierreRenderJobEvent;
	readonly publicationItem: BridgeWorkerReviewPierreRenderJobEvent['job']['payload']['item'];
	readonly residency: 'replaced' | 'reusedPainted';
}

interface PendingAdmission {
	readonly candidatePublicationId: string;
	readonly resolve: (result: BridgeMainReviewInstallAdmissionResult) => void;
}

interface PendingInstalledReceipt {
	readonly publicationId: string;
	readonly reject: (error: Error) => void;
	readonly resolve: () => void;
}

function noop(): void {}

export function createBridgeMainReviewPublicationIntegration(props: {
	readonly client: BridgeMainReviewPublicationClient;
	readonly nextCommandEpoch: () => number;
	readonly onActiveRenderPatchesApplied?: (
		message: BridgeWorkerReviewRenderPatchEvent,
		patches: BridgeWorkerReviewRenderPatchEvent['patches'],
	) => void;
	readonly pierreCourier: BridgeWorkerPierreCourier;
	readonly prepareActiveEditorsForInstallation: () => Promise<boolean>;
	readonly renderFulfillmentCoordinator: Pick<
		BridgeMainRenderFulfillmentCoordinator,
		| 'acceptPublication'
		| 'bindPublicationItem'
		| 'isBoundFinalItem'
		| 'holdPublication'
		| 'markPublicationQueued'
		| 'rejectPublication'
	>;
	readonly store: BridgeMainRenderSnapshotStore;
	readonly telemetryRecorderRef?: { readonly current: BridgeTelemetryRecorder } | undefined;
}): BridgeMainReviewPublicationIntegration {
	let currentAttention: BridgeMainReviewSemanticAttention = {
		activeEditorStableFileIdentities: [],
		stableFileIdentities: [],
	};
	let deferredCandidateIdentity: BridgeMainReviewPublicationIdentity | null = null;
	const deferredCandidatePierreByItemId = new Map<string, DeferredCandidatePierrePublication>();
	let admissionDispatchInProgress = false;
	let synchronousAdmissionResponse: Extract<
		BridgeWorkerServerToMainMessage,
		{ readonly kind: 'reviewPublicationInstallAdmission' }
	> | null = null;
	let isDisposed = false;
	let isStarted = false;
	const pendingAdmissionsByRequestId = new Map<string, PendingAdmission>();
	const pendingInstalledReceiptsByRequestId = new Map<string, PendingInstalledReceipt>();
	const publicationEpochById = new Map<string, number>();
	const tasks = new Set<Promise<void>>();

	const track = (task: Promise<void>): void => {
		const settledTask = task
			.catch((): void => {})
			.finally((): void => {
				tasks.delete(settledTask);
			});
		tasks.add(settledTask);
	};

	const prunePublicationEpochs = (): void => {
		const presentation = props.store.getReviewRefreshPresentation();
		const retainedPublicationIds = new Set(
			[
				presentation.activeIdentity?.publicationId,
				presentation.candidate?.identity.publicationId,
			].filter((publicationId): publicationId is string => publicationId !== undefined),
		);
		for (const publicationId of publicationEpochById.keys()) {
			if (!retainedPublicationIds.has(publicationId)) publicationEpochById.delete(publicationId);
		}
	};

	const publicationRoute = (
		publicationIdentity: {
			readonly packageId: string;
			readonly publicationId: string;
			readonly reviewGeneration: number;
			readonly revision: number;
			readonly sourceIdentity: string;
		},
		workerDerivationEpoch: number,
	): PublicationRoute | null => {
		if (publicationEpochById.get(publicationIdentity.publicationId) !== workerDerivationEpoch) {
			return null;
		}
		const presentation = props.store.getReviewRefreshPresentation();
		const identity = mainReviewPublicationIdentity(publicationIdentity);
		const candidateIdentity = presentation.candidate?.identity;
		if (candidateIdentity !== undefined && identitiesAreExact(candidateIdentity, identity)) {
			return { identity: candidateIdentity, kind: 'candidate' };
		}
		const activeIdentity = presentation.activeIdentity;
		if (activeIdentity !== null && identitiesAreExact(activeIdentity, identity)) {
			return { identity: activeIdentity, kind: 'active' };
		}
		return null;
	};

	const rejectDeferredCandidatePierre = (): void => {
		for (const publication of deferredCandidatePierreByItemId.values()) {
			props.renderFulfillmentCoordinator.rejectPublication(publication.message, 'stale_submission');
		}
		deferredCandidatePierreByItemId.clear();
		deferredCandidateIdentity = null;
	};

	const flushPromotedCandidatePierre = (): void => {
		const activeIdentity = props.store.getReviewRefreshPresentation().activeIdentity;
		if (
			activeIdentity === null ||
			deferredCandidateIdentity === null ||
			!identitiesAreExact(activeIdentity, deferredCandidateIdentity)
		) {
			return;
		}
		for (const publication of deferredCandidatePierreByItemId.values()) {
			if (
				props.renderFulfillmentCoordinator.acceptPublication(publication.message) === 'duplicate'
			) {
				continue;
			}
			props.renderFulfillmentCoordinator.bindPublicationItem({
				finalItem: publication.finalItem,
				publicationItem: publication.publicationItem,
				residency: publication.residency,
			});
			props.pierreCourier.submit(publication.message.job);
			props.renderFulfillmentCoordinator.markPublicationQueued(publication.message);
		}
		deferredCandidatePierreByItemId.clear();
		deferredCandidateIdentity = null;
	};

	const settleLifecycle = (): void => {
		const lifecycle = props.client.lifecycle.getSnapshot();
		for (const [requestId, pending] of pendingAdmissionsByRequestId) {
			const request = lifecycle.requestsById[requestId];
			if (request === undefined || request.state === 'pending' || request.state === 'acked') {
				continue;
			}
			pendingAdmissionsByRequestId.delete(requestId);
			pending.resolve({
				candidatePublicationId: pending.candidatePublicationId,
				status: 'rejected',
			});
		}
		for (const [requestId, pending] of pendingInstalledReceiptsByRequestId) {
			const request = lifecycle.requestsById[requestId];
			if (request === undefined || request.state === 'pending') continue;
			pendingInstalledReceiptsByRequestId.delete(requestId);
			if (request.state === 'acked') pending.resolve();
			else pending.reject(new Error('Bridge Review installed receipt was not acknowledged.'));
		}
	};

	const installationGate = createBridgeMainReviewPresentationInstallationGate({
		installationPort: {
			requestWorkerReplacement: props.client.requestWorkerReplacement,
			requestInstallAdmission: (request): Promise<BridgeMainReviewInstallAdmissionResult> => {
				if (!publicationEpochById.has(request.candidatePublicationId)) {
					return Promise.resolve({
						candidatePublicationId: request.candidatePublicationId,
						status: 'rejected',
					});
				}
				admissionDispatchInProgress = true;
				let requestId: string;
				try {
					requestId = props.client.send({
						candidatePublicationId: request.candidatePublicationId,
						command: 'reviewPublicationInstallAdmit',
						epoch: props.nextCommandEpoch(),
						expectedDisplayedPublicationId: request.expectedDisplayedPublicationId,
					});
				} catch (error: unknown) {
					synchronousAdmissionResponse = null;
					throw error;
				} finally {
					admissionDispatchInProgress = false;
				}
				return new Promise((resolve) => {
					const synchronousResponse = synchronousAdmissionResponse;
					synchronousAdmissionResponse = null;
					if (
						synchronousResponse?.requestId === requestId &&
						synchronousResponse.candidatePublicationId === request.candidatePublicationId
					) {
						resolve({
							candidatePublicationId: synchronousResponse.candidatePublicationId,
							status: synchronousResponse.status,
						});
						return;
					}
					pendingAdmissionsByRequestId.set(requestId, {
						candidatePublicationId: request.candidatePublicationId,
						resolve,
					});
					settleLifecycle();
				});
			},
			sendInstalledReceipt: (identity): Promise<void> => {
				const publicationId = identity.publicationId;
				if (!publicationEpochById.has(publicationId)) {
					return Promise.reject(new Error('Installed Review publication epoch is unavailable.'));
				}
				const requestId = props.client.send({
					command: 'reviewPublicationInstalled',
					epoch: props.nextCommandEpoch(),
					packageId: identity.packageId,
					publicationId,
					reviewGeneration: identity.generation,
					revision: identity.revision,
					sourceIdentity: identity.sourceIdentity,
				});
				return new Promise((resolve, reject) => {
					pendingInstalledReceiptsByRequestId.set(requestId, { publicationId, reject, resolve });
					settleLifecycle();
				});
			},
		},
		onLifecycleEvent: (event): void => {
			recordBridgeReviewRefreshLifecycleTelemetry({
				event,
				recorder: props.telemetryRecorderRef?.current,
			});
		},
		prepareActiveEditorsForInstallation: props.prepareActiveEditorsForInstallation,
		store: props.store,
	});

	let unsubscribeLifecycle = noop;
	let unsubscribePresentation = noop;
	let unsubscribeWorkerReplacement = noop;
	const handlePresentationChanged = (): void => {
		const presentation = props.store.getReviewRefreshPresentation();
		const candidateIdentity = presentation.candidate?.identity ?? null;
		if (
			deferredCandidateIdentity !== null &&
			(presentation.activeIdentity === null ||
				!identitiesAreExact(deferredCandidateIdentity, presentation.activeIdentity)) &&
			(candidateIdentity === null ||
				!identitiesAreExact(deferredCandidateIdentity, candidateIdentity))
		) {
			rejectDeferredCandidatePierre();
		}
		if (presentation.candidate?.role === 'updateReady') {
			for (const publication of deferredCandidatePierreByItemId.values()) {
				props.renderFulfillmentCoordinator.holdPublication(publication.message);
			}
		}
		flushPromotedCandidatePierre();
		prunePublicationEpochs();
	};

	const applyPierrePublication = (
		message: BridgeWorkerReviewPierreRenderJobEvent,
		route: PublicationRoute,
	): void => {
		if (route.kind === 'candidate') {
			const displaced = deferredCandidatePierreByItemId.get(message.job.itemId);
			if (
				displaced?.message.renderReceiptIdentity.attemptId ===
					message.renderReceiptIdentity.attemptId &&
				JSON.stringify(displaced.message.renderReceiptIdentity) ===
					JSON.stringify(message.renderReceiptIdentity)
			)
				return;
			if (displaced !== undefined)
				props.renderFulfillmentCoordinator.rejectPublication(displaced.message, 'stale_submission');
			const preparedItem = prepareBridgeMainPierreItemForPresentation({
				currentItem: undefined,
				presentationItem: message.job.payload.item,
			});
			if (
				!props.store.setReviewCandidateCodeViewItem({
					identity: route.identity,
					item: preparedItem.item,
					itemId: message.job.itemId,
				})
			) {
				props.renderFulfillmentCoordinator.rejectPublication(message, 'stale_submission');
				return;
			}
			if (
				deferredCandidateIdentity !== null &&
				!identitiesAreExact(deferredCandidateIdentity, route.identity)
			) {
				rejectDeferredCandidatePierre();
			}
			deferredCandidateIdentity = route.identity;
			deferredCandidatePierreByItemId.set(message.job.itemId, {
				finalItem: preparedItem.item,
				message,
				publicationItem: message.job.payload.item,
				residency: preparedItem.residency,
			});
			if (props.store.getReviewRefreshPresentation().candidate?.role === 'updateReady') {
				props.renderFulfillmentCoordinator.holdPublication(message);
			}
			return;
		}
		if (!props.store.reviewCatalogContainsItem(message.job.itemId)) {
			props.renderFulfillmentCoordinator.rejectPublication(message, 'stale_submission');
			return;
		}
		if (props.renderFulfillmentCoordinator.acceptPublication(message) === 'duplicate') return;
		const publicationItem = message.job.payload.item;
		const currentItem = props.store.getReviewCodeViewItemSnapshot(message.job.itemId);
		const preparedItem = prepareBridgeMainPierreItemForPresentation({
			currentItem,
			presentationItem: publicationItem,
			reuseCurrentItemWhenFingerprintMatches:
				currentItem !== undefined &&
				props.renderFulfillmentCoordinator.isBoundFinalItem(currentItem),
		});
		props.renderFulfillmentCoordinator.bindPublicationItem({
			finalItem: preparedItem.item,
			publicationItem,
			residency: preparedItem.residency,
		});
		props.store.setWorkerCodeViewItem({ item: preparedItem.item, itemId: message.job.itemId });
		props.pierreCourier.submit(message.job);
		props.renderFulfillmentCoordinator.markPublicationQueued(message);
	};

	const whenSettled = async (): Promise<void> => {
		if (tasks.size === 0) return;
		await Promise.all(tasks);
		await whenSettled();
	};

	return {
		applyNow: (): Promise<void> => installationGate.applyNow(),
		dispose: (): void => {
			if (isDisposed) return;
			isDisposed = true;
			unsubscribeLifecycle();
			unsubscribePresentation();
			unsubscribeWorkerReplacement();
			installationGate.close();
			rejectDeferredCandidatePierre();
			for (const pending of pendingAdmissionsByRequestId.values()) {
				pending.resolve({
					candidatePublicationId: pending.candidatePublicationId,
					status: 'rejected',
				});
			}
			for (const pending of pendingInstalledReceiptsByRequestId.values()) {
				pending.reject(new Error('Bridge Review publication integration closed.'));
			}
			pendingAdmissionsByRequestId.clear();
			pendingInstalledReceiptsByRequestId.clear();
			synchronousAdmissionResponse = null;
			publicationEpochById.clear();
		},
		handleMessage: (message): boolean => {
			if (isDisposed) return false;
			switch (message.kind) {
				case 'reviewCandidateStarted': {
					const identity = mainReviewPublicationIdentity(message);
					if (!props.store.startReviewCandidate({ disposition: message.disposition, identity })) {
						return true;
					}
					publicationEpochById.set(identity.publicationId, message.epoch);
					prunePublicationEpochs();
					return true;
				}
				case 'reviewDisplayPatch': {
					const publicationIdentity = message.reviewPublicationIdentity;
					const sourceStatus =
						message.patches.find((patch) => patch.slice === 'reviewSource')?.payload.status ?? null;
					const recordDisplayPatch = (
						stage: Pick<BridgeReviewDisplayPatchDiagnostic, 'stageOutcome' | 'reason'>,
					): void => {
						recordBridgeReviewDisplayPatchDiagnostic({
							publicationId: publicationIdentity?.publicationId ?? null,
							sourceStatus,
							targetCandidatePublicationId:
								props.store.getReviewRefreshPresentation().candidate?.identity.publicationId ??
								null,
							...stage,
						});
						recordBridgeReviewCandidateSourceDiagnostic(
							props.store.getReviewCandidateSourceDiagnostic(),
						);
					};
					if (publicationIdentity === null) {
						props.store.applyReviewDisplayPatchEvent(message);
						recordDisplayPatch({ stageOutcome: 'unscoped', reason: 'unscopedPublication' });
					} else {
						const identity = mainReviewPublicationIdentity(publicationIdentity);
						const activeIdentity = props.store.getReviewRefreshPresentation().activeIdentity;
						if (activeIdentity !== null && identitiesAreExact(activeIdentity, identity)) {
							props.store.applyReviewDisplayPatchEvent(message);
							recordDisplayPatch({ stageOutcome: 'active', reason: 'activePublication' });
							const activeEpoch = publicationEpochById.get(identity.publicationId);
							if (activeEpoch === undefined || message.epoch > activeEpoch) {
								publicationEpochById.set(identity.publicationId, message.epoch);
							}
							return true;
						}
						const candidateIdentity =
							props.store.getReviewRefreshPresentation().candidate?.identity;
						if (!props.store.stageReviewCandidateDisplayEvent({ event: message, identity })) {
							recordDisplayPatch({
								stageOutcome: 'refused',
								reason:
									candidateIdentity === undefined ||
									!identitiesAreExact(candidateIdentity, identity)
										? 'candidateIdentityMismatch'
										: 'staleDisplayEvent',
							});
							return true;
						}
						recordDisplayPatch({ stageOutcome: 'accepted', reason: 'stagedCandidate' });
						const previousCandidate = deferredCandidateIdentity;
						publicationEpochById.set(identity.publicationId, message.epoch);
						if (previousCandidate !== null && !identitiesAreExact(previousCandidate, identity)) {
							rejectDeferredCandidatePierre();
						}
						prunePublicationEpochs();
					}
					return true;
				}
				case 'reviewCandidateReady':
					if (publicationEpochById.get(message.publicationId) !== message.epoch) return true;
					track(installationGate.handleCandidateReady(message, currentAttention));
					return true;
				case 'reviewCandidateFailed':
					if (publicationEpochById.get(message.publicationId) !== message.epoch) return true;
					installationGate.handleCandidateFailed(message, currentAttention);
					return true;
				case 'reviewPublicationInstallAdmission': {
					const pending = pendingAdmissionsByRequestId.get(message.requestId);
					if (
						pending !== undefined &&
						pending.candidatePublicationId === message.candidatePublicationId
					) {
						pendingAdmissionsByRequestId.delete(message.requestId);
						pending.resolve({
							candidatePublicationId: message.candidatePublicationId,
							status: message.status,
						});
					} else if (admissionDispatchInProgress) synchronousAdmissionResponse = message;
					return true;
				}
				case 'reviewRenderPatch': {
					const route = publicationRoute(
						message.reviewPublicationIdentity,
						message.workerDerivationEpoch,
					);
					if (route === null) return true;
					if (route.kind === 'candidate') {
						props.store.applyReviewCandidateSnapshotUpdate({
							identity: route.identity,
							workerPatches: message.patches,
						});
						return true;
					}
					const memberPatches = message.patches.filter(
						(patch): boolean =>
							patch.slice === 'panelChrome' ||
							patch.operation === 'reset' ||
							props.store.reviewCatalogContainsItem(patch.itemId),
					);
					if (memberPatches.length > 0) {
						props.store.applySnapshotUpdate({ workerPatches: memberPatches });
						props.onActiveRenderPatchesApplied?.(message, memberPatches);
					}
					return true;
				}
				case 'reviewPierreRenderJob': {
					const route = publicationRoute(
						message.reviewPublicationIdentity,
						message.workerDerivationEpoch,
					);
					if (route === null) {
						props.renderFulfillmentCoordinator.rejectPublication(message, 'stale_submission');
						return true;
					}
					applyPierrePublication(message, route);
					return true;
				}
				case 'annotationCommandAccepted':
				case 'annotationCatalogStaging':
				case 'annotationOutputInspection':
				case 'annotationProjectionConvergence':
				case 'fileDisplayPatch':
				case 'filePierreRenderJob':
				case 'fileRenderPatch':
				case 'health':
				case 'viewRecoveryStatus':
				case 'nativeSurfaceSelectionRequest':
				case 'reviewComparisonTargetsQuery':
				case 'slicePatch':
				case 'subscription':
					return false;
			}
			return false;
		},
		setSemanticAttention: (attention): void => {
			currentAttention = attention;
			track(installationGate.semanticAttentionChanged(attention));
		},
		start: (): void => {
			if (isDisposed || isStarted) return;
			isStarted = true;
			unsubscribeLifecycle = props.client.lifecycle.subscribe(settleLifecycle);
			unsubscribePresentation =
				props.store.subscribeReviewRefreshPresentation(handlePresentationChanged);
			unsubscribeWorkerReplacement = props.store.subscribeWorkerReplacement((): void => {
				publicationEpochById.clear();
				rejectDeferredCandidatePierre();
				installationGate.prepareForWorkerReplacement();
			});
		},
		whenSettled,
	};
}

function mainReviewPublicationIdentity(identity: {
	readonly packageId: string;
	readonly publicationId: string;
	readonly reviewGeneration: number;
	readonly revision: number;
	readonly sourceIdentity: string;
}): BridgeMainReviewPublicationIdentity {
	return {
		generation: identity.reviewGeneration,
		packageId: identity.packageId,
		publicationId: identity.publicationId,
		revision: identity.revision,
		sourceIdentity: identity.sourceIdentity,
	};
}

function identitiesAreExact(
	left: BridgeMainReviewPublicationIdentity,
	right: BridgeMainReviewPublicationIdentity,
): boolean {
	return (
		left.generation === right.generation &&
		left.packageId === right.packageId &&
		left.publicationId === right.publicationId &&
		left.revision === right.revision &&
		left.sourceIdentity === right.sourceIdentity
	);
}
