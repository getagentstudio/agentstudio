import {
	recordBridgeReviewInstallationGateDiagnostic,
	recordBridgeReviewCandidateSourceDiagnostic,
	type BridgeReviewInstallationGateDiagnostic,
} from '../../foundation/diagnostics/bridge-review-selection-diagnostic.js';
import type { BridgeWorkerRuntimeRecoverySource } from '../../foundation/diagnostics/bridge-worker-replacement-reason.js';
import type {
	BridgeMainReviewEffectivePresentationClass,
	BridgeMainReviewCandidatePresentation,
	BridgeMainReviewCandidateStore,
	BridgeMainReviewPublicationIdentity,
} from './bridge-main-review-candidate-bank.js';
import type {
	BridgeWorkerReviewCandidateFailedEvent,
	BridgeWorkerReviewCandidateReadyEvent,
} from './bridge-worker-review-publication-contracts.js';

export interface BridgeMainReviewSemanticAttention {
	readonly activeEditorStableFileIdentities: readonly string[];
	readonly stableFileIdentities: readonly string[];
}

export interface BridgeMainReviewInstallAdmissionRequest {
	readonly candidatePublicationId: string;
	readonly expectedDisplayedPublicationId: string | null;
}

export interface BridgeMainReviewInstallAdmissionResult {
	readonly candidatePublicationId: string;
	readonly status: 'admitted' | 'rejected';
}

export interface BridgeMainReviewPresentationInstallationPort {
	readonly requestWorkerReplacement: (source: BridgeWorkerRuntimeRecoverySource) => void;
	readonly requestInstallAdmission: (
		request: BridgeMainReviewInstallAdmissionRequest,
	) => Promise<BridgeMainReviewInstallAdmissionResult>;
	readonly sendInstalledReceipt: (identity: BridgeMainReviewPublicationIdentity) => Promise<void>;
}

export interface BridgeMainReviewPresentationInstallationGate {
	readonly applyNow: () => Promise<void>;
	readonly close: () => void;
	readonly handleCandidateReady: (
		event: BridgeWorkerReviewCandidateReadyEvent,
		attention: BridgeMainReviewSemanticAttention,
	) => Promise<void>;
	readonly handleCandidateFailed: (
		event: BridgeWorkerReviewCandidateFailedEvent,
		attention: BridgeMainReviewSemanticAttention,
	) => void;
	readonly prepareForWorkerReplacement: () => void;
	readonly semanticAttentionChanged: (
		attention: BridgeMainReviewSemanticAttention,
	) => Promise<void>;
}

export type BridgeMainReviewRefreshLifecycleEvent =
	| (BridgeMainReviewRefreshCandidateTelemetryFacts & {
			readonly phase: 'candidateReady' | 'candidateHeld' | 'candidateSuperseded';
	  })
	| (BridgeMainReviewRefreshCandidateTelemetryFacts & {
			readonly phase: 'installRequested';
			readonly trigger: 'applyNow' | 'automatic';
	  })
	| (BridgeMainReviewRefreshCandidateTelemetryFacts & {
			readonly phase: 'installTerminal';
			readonly result: 'failure' | 'stale' | 'success';
			readonly resultReason: 'admissionFailed' | 'admissionRejected' | 'none' | 'promotionStale';
			readonly trigger: 'applyNow' | 'automatic';
	  })
	| (BridgeMainReviewRefreshCandidateTelemetryFacts & {
			readonly phase: 'receiptFailed';
	  })
	| (BridgeMainReviewRefreshCandidateTelemetryFacts & {
			readonly phase: 'candidateFailed';
			readonly retryable: boolean;
	  })
	| {
			readonly activeBankCount: 0 | 1;
			readonly candidateBankCount: 0 | 1;
			readonly phase: 'cleanup';
			readonly reason: 'close' | 'workerReplacement';
	  };

interface BridgeMainReviewRefreshCandidateTelemetryFacts {
	readonly affectedStableFileCount: number;
	readonly generation: number;
	readonly presentationClass: BridgeMainReviewEffectivePresentationClass;
}

interface ReadyCandidate {
	readonly affectedStableFileIdentities: readonly string[];
	readonly identity: BridgeMainReviewPublicationIdentity;
	readonly presentationClass: BridgeMainReviewEffectivePresentationClass;
}

export function createBridgeMainReviewPresentationInstallationGate(props: {
	readonly installationPort: BridgeMainReviewPresentationInstallationPort;
	readonly onLifecycleEvent?: (event: BridgeMainReviewRefreshLifecycleEvent) => void;
	readonly prepareActiveEditorsForInstallation: () => Promise<boolean>;
	readonly store: BridgeMainReviewCandidateStore;
}): BridgeMainReviewPresentationInstallationGate {
	let attentionFileIdentities = new Set<string>();
	let activeEditorFileIdentities = new Set<string>();
	let installationInFlightPublicationId: string | null = null;
	let isClosed = false;
	let lifecycleRevision = 0;
	let pendingInstalledReceiptCandidate: ReadyCandidate | null = null;
	let readyCandidate: ReadyCandidate | null = null;
	let awaitingSourceCandidate: ReadyCandidate | null = null;
	let unsubscribeCandidateSource: (() => void) | null = null;
	// Retained paint does not establish native display ownership for a replacement worker.
	let confirmedDisplayedPublicationId =
		props.store.getReviewRefreshPresentation().activeIdentity?.publicationId ?? null;
	let lastNativeAdmissionResult: BridgeMainReviewInstallAdmissionResult | null = null;
	const recordGateDecision = (
		decision: BridgeReviewInstallationGateDiagnostic['lastGateDecision'],
	): void => {
		const presentation = props.store.getReviewRefreshPresentation();
		recordBridgeReviewCandidateSourceDiagnostic(props.store.getReviewCandidateSourceDiagnostic());
		recordBridgeReviewInstallationGateDiagnostic({
			activeIdentity:
				presentation.activeIdentity === null
					? null
					: { publicationId: presentation.activeIdentity.publicationId },
			confirmedDisplayedPublicationId,
			pendingCandidate:
				presentation.candidate === null
					? null
					: {
							publicationId: presentation.candidate.identity.publicationId,
							role: presentation.candidate.role,
						},
			lastGateDecision: decision,
			lastNativeAdmissionResult,
		});
	};
	recordGateDecision({ kind: 'skipped', reason: 'candidateMissing' });
	const stopAwaitingCandidateSource = (): void => {
		unsubscribeCandidateSource?.();
		unsubscribeCandidateSource = null;
		awaitingSourceCandidate = null;
	};
	const observeCandidateSource = (): void => {
		const candidate = awaitingSourceCandidate;
		if (candidate === null) return;
		const source = props.store.getReviewCandidateSourceDiagnostic();
		if (source?.publicationId !== candidate.identity.publicationId) {
			stopAwaitingCandidateSource();
			if (readyCandidate === candidate) {
				readyCandidate = null;
				props.onLifecycleEvent?.({
					...candidateTelemetryFacts(candidate),
					phase: 'candidateSuperseded',
				});
			}
			return;
		}
		if (source.status === 'failed') {
			stopAwaitingCandidateSource();
			if (readyCandidate !== candidate) return;
			readyCandidate = null;
			if (props.store.failReviewCandidate({ identity: candidate.identity, retryable: true })) {
				props.onLifecycleEvent?.({
					...candidateTelemetryFacts(candidate),
					phase: 'candidateFailed',
					retryable: true,
				});
			}
			recordGateDecision({ kind: 'rejected', reason: 'candidateSourceFailed' });
			return;
		}
		if (source.status === 'ready') {
			stopAwaitingCandidateSource();
			void evaluateReadyCandidate();
		}
	};
	const awaitCandidateSource = (candidate: ReadyCandidate): void => {
		stopAwaitingCandidateSource();
		awaitingSourceCandidate = candidate;
		unsubscribeCandidateSource = props.store.subscribeReviewCandidateSource(observeCandidateSource);
		recordGateDecision({ kind: 'held', reason: 'candidateSourcePending' });
		observeCandidateSource();
	};

	const candidateMatchesStore = (candidate: ReadyCandidate): boolean => {
		const storedCandidate = props.store.getReviewRefreshPresentation().candidate;
		return (
			storedCandidate !== null && identitiesAreExact(storedCandidate.identity, candidate.identity)
		);
	};

	const candidateAffectsAttention = (candidate: ReadyCandidate): boolean => {
		if (
			candidate.presentationClass.kind === 'promoted' &&
			candidate.presentationClass.reason === 'unknown'
		) {
			return attentionFileIdentities.size > 0;
		}
		return candidate.affectedStableFileIdentities.some((fileIdentity): boolean =>
			attentionFileIdentities.has(fileIdentity),
		);
	};

	const candidateAffectsActiveEditor = (candidate: ReadyCandidate): boolean => {
		if (
			candidate.presentationClass.kind === 'promoted' &&
			candidate.presentationClass.reason === 'unknown'
		) {
			return activeEditorFileIdentities.size > 0;
		}
		return candidate.affectedStableFileIdentities.some((fileIdentity): boolean =>
			activeEditorFileIdentities.has(fileIdentity),
		);
	};

	const failureAffectsAttention = (): boolean => {
		const failure = props.store.getReviewRefreshPresentation().failure;
		if (failure === null) return false;
		if (failure.kind === 'installation') return true;
		if (failure.presentationClass.reason === 'unknown') return attentionFileIdentities.size > 0;
		return failure.affectedStableFileIdentities.some((fileIdentity): boolean =>
			attentionFileIdentities.has(fileIdentity),
		);
	};

	const clearUnfocusedFailure = (): void => {
		if (!failureAffectsAttention()) props.store.clearReviewCandidateFailure();
	};

	const installCandidate = async (
		candidate: ReadyCandidate,
		trigger: 'applyNow' | 'automatic',
	): Promise<void> => {
		const activeIdentity = props.store.getReviewRefreshPresentation().activeIdentity;
		const reinstallsRetainedPublication =
			confirmedDisplayedPublicationId === null &&
			activeIdentity !== null &&
			identitiesAreExact(activeIdentity, candidate.identity);
		if (
			isClosed ||
			installationInFlightPublicationId !== null ||
			pendingInstalledReceiptCandidate !== null ||
			(!reinstallsRetainedPublication && !candidateMatchesStore(candidate))
		) {
			recordGateDecision({
				kind: 'skipped',
				reason: isClosed
					? 'closed'
					: installationInFlightPublicationId !== null
						? 'installInFlight'
						: pendingInstalledReceiptCandidate !== null
							? 'receiptPending'
							: 'candidateMismatch',
			});
			return;
		}
		const requestLifecycleRevision = lifecycleRevision;
		installationInFlightPublicationId = candidate.identity.publicationId;
		let editorContinuityPrepared = true;
		if (!reinstallsRetainedPublication && candidateAffectsActiveEditor(candidate)) {
			try {
				editorContinuityPrepared = await props.prepareActiveEditorsForInstallation();
			} catch {
				editorContinuityPrepared = false;
			}
		}
		if (
			isClosed ||
			requestLifecycleRevision !== lifecycleRevision ||
			installationInFlightPublicationId !== candidate.identity.publicationId ||
			(!reinstallsRetainedPublication && !candidateMatchesStore(candidate))
		) {
			if (installationInFlightPublicationId === candidate.identity.publicationId) {
				installationInFlightPublicationId = null;
			}
			await evaluateReadyCandidate();
			return;
		}
		if (!editorContinuityPrepared) {
			installationInFlightPublicationId = null;
			if (candidate.presentationClass.kind === 'ordinary') {
				const activeAnchorPresentationClass = {
					kind: 'promoted',
					reason: 'activeAnchor',
				} as const;
				const escalatedCandidate: ReadyCandidate = {
					...candidate,
					presentationClass: activeAnchorPresentationClass,
				};
				if (
					props.store.escalateReviewCandidatePresentation({
						identity: candidate.identity,
						presentationClass: activeAnchorPresentationClass,
					}) &&
					props.store.markReviewCandidateReady({
						identity: candidate.identity,
						role: 'updateReady',
					})
				) {
					readyCandidate = escalatedCandidate;
					props.onLifecycleEvent?.({
						...candidateTelemetryFacts(escalatedCandidate),
						phase: 'candidateHeld',
					});
				}
				return;
			}
			if (props.store.failReviewCandidate({ identity: candidate.identity, retryable: true })) {
				readyCandidate = null;
				props.onLifecycleEvent?.({
					...candidateTelemetryFacts(candidate),
					phase: 'candidateFailed',
					retryable: true,
				});
			}
			return;
		}
		if (
			!reinstallsRetainedPublication &&
			!props.store.markReviewCandidateReady({
				identity: candidate.identity,
				role: 'installing',
			})
		) {
			installationInFlightPublicationId = null;
			return;
		}
		props.onLifecycleEvent?.({
			...candidateTelemetryFacts(candidate),
			phase: 'installRequested',
			trigger,
		});
		recordGateDecision({ kind: 'requested', reason: 'requestSubmitted' });
		let result: BridgeMainReviewInstallAdmissionResult;
		try {
			result = await props.installationPort.requestInstallAdmission({
				candidatePublicationId: candidate.identity.publicationId,
				expectedDisplayedPublicationId: confirmedDisplayedPublicationId,
			});
		} catch {
			const requestIsCurrent =
				requestLifecycleRevision === lifecycleRevision &&
				installationInFlightPublicationId === candidate.identity.publicationId;
			if (requestIsCurrent) {
				installationInFlightPublicationId = null;
				props.store.failReviewInstallation(candidate.identity);
				if (
					readyCandidate !== null &&
					identitiesAreExact(readyCandidate.identity, candidate.identity)
				) {
					readyCandidate = null;
				}
			}
			props.onLifecycleEvent?.({
				...candidateTelemetryFacts(candidate),
				phase: 'installTerminal',
				result: requestIsCurrent ? 'failure' : 'stale',
				resultReason: requestIsCurrent ? 'admissionFailed' : 'promotionStale',
				trigger,
			});
			recordGateDecision({ kind: 'rejected', reason: 'nativeAdmissionFailed' });
			return;
		}
		lastNativeAdmissionResult = result;
		if (
			isClosed ||
			requestLifecycleRevision !== lifecycleRevision ||
			installationInFlightPublicationId !== candidate.identity.publicationId
		) {
			props.onLifecycleEvent?.({
				...candidateTelemetryFacts(candidate),
				phase: 'installTerminal',
				result: 'stale',
				resultReason: 'promotionStale',
				trigger,
			});
			return;
		}
		installationInFlightPublicationId = null;
		if (
			result.candidatePublicationId !== candidate.identity.publicationId ||
			result.status === 'rejected'
		) {
			props.onLifecycleEvent?.({
				...candidateTelemetryFacts(candidate),
				phase: 'installTerminal',
				result: 'stale',
				resultReason: 'admissionRejected',
				trigger,
			});
			props.store.discardReviewCandidate(candidate.identity);
			if (
				readyCandidate !== null &&
				identitiesAreExact(readyCandidate.identity, candidate.identity)
			) {
				readyCandidate = null;
			}
			recordGateDecision({ kind: 'rejected', reason: 'nativeAdmissionRejected' });
			if (reinstallsRetainedPublication) await evaluateReadyCandidate();
			return;
		}
		if (!reinstallsRetainedPublication && !props.store.promoteReviewCandidate(candidate.identity)) {
			if (!candidateMatchesStore(candidate)) {
				stopAwaitingCandidateSource();
				if (
					readyCandidate !== null &&
					identitiesAreExact(readyCandidate.identity, candidate.identity)
				) {
					readyCandidate = null;
				}
				props.onLifecycleEvent?.({
					...candidateTelemetryFacts(candidate),
					phase: 'candidateSuperseded',
				});
			}
			props.onLifecycleEvent?.({
				...candidateTelemetryFacts(candidate),
				phase: 'installTerminal',
				result: 'stale',
				resultReason: 'promotionStale',
				trigger,
			});
			await evaluateReadyCandidate();
			return;
		}
		props.onLifecycleEvent?.({
			...candidateTelemetryFacts(candidate),
			phase: 'installTerminal',
			result: 'success',
			resultReason: 'none',
			trigger,
		});
		recordGateDecision({ kind: 'admitted', reason: 'nativeAdmissionAdmitted' });
		pendingInstalledReceiptCandidate = candidate;
		const receiptConfirmed = await sendPendingInstalledReceipt();
		if (
			!receiptConfirmed &&
			requestLifecycleRevision === lifecycleRevision &&
			pendingInstalledReceiptCandidate === candidate
		) {
			const retryConfirmed = await sendPendingInstalledReceipt();
			if (
				!retryConfirmed &&
				requestLifecycleRevision === lifecycleRevision &&
				pendingInstalledReceiptCandidate === candidate
			) {
				props.installationPort.requestWorkerReplacement('reviewInstalledReceiptFailed');
				return;
			}
		}
		if (!isClosed && requestLifecycleRevision === lifecycleRevision) {
			await evaluateReadyCandidate();
		}
	};

	const evaluateReadyCandidate = async (): Promise<void> => {
		const candidate = readyCandidate;
		if (candidate === null || !candidateMatchesStore(candidate)) return;
		const presentation = props.store.getReviewRefreshPresentation();
		if (
			presentation.activeIdentity !== null &&
			confirmedDisplayedPublicationId !== null &&
			candidate.presentationClass.kind === 'promoted' &&
			candidateAffectsAttention(candidate)
		) {
			const previousRole = props.store.getReviewRefreshPresentation().candidate?.role;
			const held = props.store.markReviewCandidateReady({
				identity: candidate.identity,
				role: 'updateReady',
			});
			if (held && previousRole !== 'updateReady') {
				props.onLifecycleEvent?.({
					...candidateTelemetryFacts(candidate),
					phase: 'candidateHeld',
				});
			}
			recordGateDecision({ kind: 'held', reason: 'attention' });
			return;
		}
		if (
			!props.store.markReviewCandidateReady({
				identity: candidate.identity,
				role: 'provisional',
			})
		) {
			const source = props.store.getReviewCandidateSourceDiagnostic();
			if (source?.publicationId === candidate.identity.publicationId && source.status !== 'ready') {
				awaitCandidateSource(candidate);
				return;
			}
			recordGateDecision({ kind: 'rejected', reason: 'provisionalMarkRejected' });
			return;
		}
		await installCandidate(candidate, 'automatic');
	};

	const sendPendingInstalledReceipt = async (): Promise<boolean> => {
		const candidate = pendingInstalledReceiptCandidate;
		if (candidate === null || isClosed) return false;
		const receiptLifecycleRevision = lifecycleRevision;
		try {
			await props.installationPort.sendInstalledReceipt(candidate.identity);
			if (
				isClosed ||
				receiptLifecycleRevision !== lifecycleRevision ||
				pendingInstalledReceiptCandidate !== candidate
			) {
				return false;
			}
			confirmedDisplayedPublicationId = candidate.identity.publicationId;
			pendingInstalledReceiptCandidate = null;
			return true;
		} catch {
			props.onLifecycleEvent?.({
				...candidateTelemetryFacts(candidate),
				phase: 'receiptFailed',
			});
			return false;
		}
	};

	return {
		applyNow: async (): Promise<void> => {
			const candidate = readyCandidate;
			if (candidate === null || !candidateMatchesStore(candidate)) return;
			await installCandidate(candidate, 'applyNow');
		},
		close: (): void => {
			if (isClosed) return;
			isClosed = true;
			stopAwaitingCandidateSource();
			lifecycleRevision += 1;
			installationInFlightPublicationId = null;
			pendingInstalledReceiptCandidate = null;
			readyCandidate = null;
			confirmedDisplayedPublicationId = null;
			props.store.discardReviewCandidate();
			props.store.clearReviewCandidateFailure();
			recordCleanupLifecycle(props, 'close');
		},
		handleCandidateReady: async (event, attention): Promise<void> => {
			if (isClosed) return;
			const nextAttentionFileIdentities = new Set(attention.stableFileIdentities);
			const nextActiveEditorFileIdentities = new Set(attention.activeEditorStableFileIdentities);
			const attentionChanged =
				!setsAreEqual(attentionFileIdentities, nextAttentionFileIdentities) ||
				!setsAreEqual(activeEditorFileIdentities, nextActiveEditorFileIdentities);
			attentionFileIdentities = nextAttentionFileIdentities;
			activeEditorFileIdentities = nextActiveEditorFileIdentities;
			const storedCandidate = props.store.getReviewRefreshPresentation().candidate;
			if (storedCandidate === null) {
				recordGateDecision({ kind: 'skipped', reason: 'candidateMissing' });
				const activeIdentity = props.store.getReviewRefreshPresentation().activeIdentity;
				if (
					confirmedDisplayedPublicationId === null &&
					activeIdentity !== null &&
					identitiesAreExact(activeIdentity, {
						generation: event.reviewGeneration,
						packageId: event.packageId,
						publicationId: event.publicationId,
						revision: event.revision,
						sourceIdentity: event.sourceIdentity,
					})
				) {
					await installCandidate(
						{
							affectedStableFileIdentities: [],
							identity: activeIdentity,
							presentationClass: { kind: 'ordinary' },
						},
						'automatic',
					);
				}
				return;
			}
			const candidate = readyCandidateFromEvent(event, storedCandidate);
			if (candidate === null) {
				recordGateDecision({ kind: 'skipped', reason: 'candidateMismatch' });
				return;
			}
			if (!candidateMatchesStore(candidate)) {
				recordGateDecision({ kind: 'skipped', reason: 'candidateMismatch' });
				return;
			}
			if (
				readyCandidate !== null &&
				readyCandidatesAreEquivalent(readyCandidate, candidate) &&
				!attentionChanged
			) {
				return;
			}
			if (readyCandidate !== null && !readyCandidatesAreEquivalent(readyCandidate, candidate)) {
				props.onLifecycleEvent?.({
					...candidateTelemetryFacts(readyCandidate),
					phase: 'candidateSuperseded',
				});
			}
			readyCandidate = candidate;
			props.onLifecycleEvent?.({
				...candidateTelemetryFacts(candidate),
				phase: 'candidateReady',
			});
			await evaluateReadyCandidate();
		},
		handleCandidateFailed: (event, attention): void => {
			if (isClosed) return;
			if (awaitingSourceCandidate?.identity.publicationId === event.publicationId) {
				stopAwaitingCandidateSource();
			}
			attentionFileIdentities = new Set(attention.stableFileIdentities);
			activeEditorFileIdentities = new Set(attention.activeEditorStableFileIdentities);
			const identity = {
				generation: event.reviewGeneration,
				packageId: event.packageId,
				publicationId: event.publicationId,
				revision: event.revision,
				sourceIdentity: event.sourceIdentity,
			};
			if (!props.store.failReviewCandidate({ identity, retryable: event.retryable })) {
				return;
			}
			if (readyCandidate !== null && identitiesAreExact(readyCandidate.identity, identity)) {
				readyCandidate = null;
			}
			const failure = props.store.getReviewRefreshPresentation().failure;
			if (failure !== null) {
				props.onLifecycleEvent?.({
					affectedStableFileCount: failure.affectedStableFileIdentities.length,
					generation: failure.identity.generation,
					phase: 'candidateFailed',
					presentationClass: failure.presentationClass,
					retryable: failure.retryable,
				});
			}
			clearUnfocusedFailure();
		},
		prepareForWorkerReplacement: (): void => {
			if (isClosed) return;
			stopAwaitingCandidateSource();
			lifecycleRevision += 1;
			installationInFlightPublicationId = null;
			pendingInstalledReceiptCandidate = null;
			readyCandidate = null;
			confirmedDisplayedPublicationId = null;
			props.store.discardReviewCandidate();
			props.store.clearReviewCandidateFailure();
			recordCleanupLifecycle(props, 'workerReplacement');
		},
		semanticAttentionChanged: async (attention): Promise<void> => {
			if (isClosed) return;
			const nextAttentionFileIdentities = new Set(attention.stableFileIdentities);
			const nextActiveEditorFileIdentities = new Set(attention.activeEditorStableFileIdentities);
			if (
				setsAreEqual(attentionFileIdentities, nextAttentionFileIdentities) &&
				setsAreEqual(activeEditorFileIdentities, nextActiveEditorFileIdentities)
			)
				return;
			attentionFileIdentities = nextAttentionFileIdentities;
			activeEditorFileIdentities = nextActiveEditorFileIdentities;
			clearUnfocusedFailure();
			await evaluateReadyCandidate();
		},
	};
}

function candidateTelemetryFacts(
	candidate: ReadyCandidate,
): BridgeMainReviewRefreshCandidateTelemetryFacts {
	return {
		affectedStableFileCount: candidate.affectedStableFileIdentities.length,
		generation: candidate.identity.generation,
		presentationClass: candidate.presentationClass,
	};
}

function recordCleanupLifecycle(
	props: {
		readonly onLifecycleEvent?: (event: BridgeMainReviewRefreshLifecycleEvent) => void;
		readonly store: BridgeMainReviewCandidateStore;
	},
	reason: 'close' | 'workerReplacement',
): void {
	const presentation = props.store.getReviewRefreshPresentation();
	props.onLifecycleEvent?.({
		activeBankCount: presentation.activeIdentity === null ? 0 : 1,
		candidateBankCount: presentation.candidate === null ? 0 : 1,
		phase: 'cleanup',
		reason,
	});
}

function readyCandidateFromEvent(
	event: BridgeWorkerReviewCandidateReadyEvent,
	storedCandidate: BridgeMainReviewCandidatePresentation,
): ReadyCandidate | null {
	const identity = {
		generation: event.reviewGeneration,
		packageId: event.packageId,
		publicationId: event.publicationId,
		revision: event.revision,
		sourceIdentity: event.sourceIdentity,
	};
	if (!identitiesAreExact(identity, storedCandidate.identity)) return null;
	const disposition = storedCandidate.startDisposition;
	return {
		affectedStableFileIdentities:
			disposition.kind === 'sameSource' ? disposition.affectedStableFileIdentities : [],
		identity,
		presentationClass: storedCandidate.effectivePresentationClass,
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

function readyCandidatesAreEquivalent(left: ReadyCandidate, right: ReadyCandidate): boolean {
	return (
		identitiesAreExact(left.identity, right.identity) &&
		left.presentationClass.kind === right.presentationClass.kind &&
		(left.presentationClass.kind === 'ordinary' ||
			(right.presentationClass.kind === 'promoted' &&
				left.presentationClass.reason === right.presentationClass.reason)) &&
		arraysAreEqual(left.affectedStableFileIdentities, right.affectedStableFileIdentities)
	);
}

function setsAreEqual(left: ReadonlySet<string>, right: ReadonlySet<string>): boolean {
	return left.size === right.size && [...left].every((value): boolean => right.has(value));
}

function arraysAreEqual(left: readonly string[], right: readonly string[]): boolean {
	return (
		left.length === right.length && left.every((value, index): boolean => value === right[index])
	);
}
