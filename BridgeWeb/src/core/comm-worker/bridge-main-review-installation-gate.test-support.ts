import type { BridgeWorkerRuntimeRecoverySource } from '../../foundation/diagnostics/bridge-worker-replacement-reason.js';
import type {
	BridgeMainReviewCandidateRole,
	BridgeMainReviewCandidateStore,
	BridgeMainReviewPublicationIdentity,
	BridgeMainReviewRefreshPresentation,
} from './bridge-main-review-candidate-bank.js';
import {
	type BridgeMainReviewInstallAdmissionRequest,
	type BridgeMainReviewInstallAdmissionResult,
	type BridgeMainReviewPresentationInstallationPort,
	type BridgeMainReviewSemanticAttention,
} from './bridge-main-review-presentation-installation-gate.js';
import type {
	BridgeWorkerReviewCandidateReadyEvent,
	BridgeWorkerReviewCandidateFailedEvent,
	BridgeWorkerReviewCandidateStartDisposition,
} from './bridge-worker-review-publication-contracts.js';

export class FakeCandidateStore implements BridgeMainReviewCandidateStore {
	presentation: BridgeMainReviewRefreshPresentation;
	readonly discards: string[] = [];
	readonly promotions: string[] = [];
	readonly roles: BridgeMainReviewCandidateRole[] = [];

	constructor(
		activeIdentity: BridgeMainReviewPublicationIdentity,
		candidateIdentity: BridgeMainReviewPublicationIdentity,
		startDisposition: BridgeWorkerReviewCandidateStartDisposition = sameSourceStart(
			{ kind: 'ordinary' },
			[],
		),
	) {
		this.presentation = candidatePresentation(activeIdentity, candidateIdentity, startDisposition);
	}

	getReviewRefreshPresentation = (): BridgeMainReviewRefreshPresentation => this.presentation;
	getReviewCandidateSourceDiagnostic = (): {
		readonly publicationId: string;
		readonly status: string | null;
	} | null =>
		this.presentation.candidate === null
			? null
			: { publicationId: this.presentation.candidate.identity.publicationId, status: 'ready' };
	subscribeReviewRefreshPresentation = (): (() => void) => (): void => {};
	subscribeReviewCandidateSource = (): (() => void) => (): void => {};
	setReviewCandidateCodeViewItem = (): boolean => false;
	startReviewCandidate = (): boolean => false;
	escalateReviewCandidatePresentation: BridgeMainReviewCandidateStore['escalateReviewCandidatePresentation'] =
		(props): boolean => {
			const candidate = this.presentation.candidate;
			if (candidate === null || !sameIdentity(candidate.identity, props.identity)) return false;
			this.presentation = {
				...this.presentation,
				candidate: { ...candidate, effectivePresentationClass: props.presentationClass },
			};
			return true;
		};
	failReviewCandidate = (props: {
		readonly identity: BridgeMainReviewPublicationIdentity;
		readonly retryable: boolean;
	}): boolean => {
		const candidate = this.presentation.candidate;
		if (
			candidate === null ||
			!sameIdentity(candidate.identity, props.identity) ||
			candidate.role === 'installing'
		)
			return false;
		const start = candidate.startDisposition;
		this.presentation = {
			...this.presentation,
			candidate: null,
			failure:
				start?.kind === 'sameSource' && candidate.effectivePresentationClass.kind === 'promoted'
					? {
							kind: 'promotedRefresh',
							affectedStableFileIdentities: start.affectedStableFileIdentities,
							identity: candidate.identity,
							presentationClass: candidate.effectivePresentationClass,
							retryable: props.retryable,
						}
					: null,
		};
		return true;
	};
	failReviewInstallation = (identity: BridgeMainReviewPublicationIdentity): boolean => {
		const candidate = this.presentation.candidate;
		if (
			candidate === null ||
			candidate.role !== 'installing' ||
			!sameIdentity(candidate.identity, identity)
		)
			return false;
		this.presentation = {
			...this.presentation,
			candidate: null,
			failure: {
				kind: 'installation',
				identity,
				retryable: true,
				presentationClass: candidate.effectivePresentationClass,
				affectedStableFileIdentities: candidate.affectedStableFileIdentities,
			},
		};
		return true;
	};
	clearReviewCandidateFailure = (): boolean => {
		if (this.presentation.failure === null || this.presentation.failure === undefined) return false;
		this.presentation = { ...this.presentation, failure: null };
		return true;
	};
	stageReviewCandidateDisplayEvent = (): boolean => false;
	applyReviewCandidateSnapshotUpdate = (): boolean => false;
	markReviewCandidateReady = (props: {
		readonly identity: BridgeMainReviewPublicationIdentity;
		readonly role: BridgeMainReviewCandidateRole;
	}): boolean => {
		if (!this.candidateIs(props.identity)) return false;
		const startDisposition = this.presentation.candidate?.startDisposition;
		if (startDisposition === undefined) return false;
		this.roles.push(props.role);
		this.presentation = {
			...this.presentation,
			candidate: {
				affectedStableFileIdentities:
					this.presentation.candidate?.affectedStableFileIdentities ?? [],
				effectivePresentationClass: this.presentation.candidate?.effectivePresentationClass ?? {
					kind: 'ordinary',
				},
				identity: props.identity,
				role: props.role,
				startDisposition,
			},
		};
		return true;
	};
	promoteReviewCandidate = (candidateIdentity: BridgeMainReviewPublicationIdentity): boolean => {
		if (!this.candidateIs(candidateIdentity)) return false;
		this.promotions.push(candidateIdentity.publicationId);
		this.presentation = { activeIdentity: candidateIdentity, candidate: null, failure: null };
		return true;
	};
	discardReviewCandidate = (candidateIdentity?: BridgeMainReviewPublicationIdentity): boolean => {
		const candidate = this.presentation.candidate;
		if (
			candidate === null ||
			(candidateIdentity !== undefined && !sameIdentity(candidate.identity, candidateIdentity))
		)
			return false;
		this.discards.push(candidate.identity.publicationId);
		this.presentation = { ...this.presentation, candidate: null };
		return true;
	};

	replaceCandidate(
		candidateIdentity: BridgeMainReviewPublicationIdentity,
		startDisposition: BridgeWorkerReviewCandidateStartDisposition = sameSourceStart(
			{ kind: 'ordinary' },
			[],
		),
	): boolean {
		if (this.presentation.candidate?.role === 'installing') return false;
		this.presentation = candidatePresentation(
			this.presentation.activeIdentity,
			candidateIdentity,
			startDisposition,
		);
		return true;
	}

	private candidateIs(identityToMatch: BridgeMainReviewPublicationIdentity): boolean {
		const candidate = this.presentation.candidate;
		return candidate !== null && sameIdentity(candidate.identity, identityToMatch);
	}
}

export class ImmediateInstallationPort implements BridgeMainReviewPresentationInstallationPort {
	replacementRequestCount = 0;
	replacementSource: BridgeWorkerRuntimeRecoverySource | null = null;
	requestWorkerReplacement = (source: BridgeWorkerRuntimeRecoverySource): void => {
		this.replacementRequestCount += 1;
		this.replacementSource = source;
	};
	readonly receiptAttempts: string[] = [];
	readonly receipts: string[] = [];
	readonly requests: BridgeMainReviewInstallAdmissionRequest[] = [];
	private readonly admissionStatuses: Array<'admitted' | 'rejected'>;
	private remainingReceiptFailures: number;

	constructor(statuses: readonly ('admitted' | 'rejected')[], receiptFailures = 0) {
		this.admissionStatuses = [...statuses];
		this.remainingReceiptFailures = receiptFailures;
	}

	requestInstallAdmission = async (
		request: BridgeMainReviewInstallAdmissionRequest,
	): Promise<BridgeMainReviewInstallAdmissionResult> => {
		this.requests.push(request);
		return {
			candidatePublicationId: request.candidatePublicationId,
			status: this.admissionStatuses.shift() ?? 'rejected',
		};
	};

	sendInstalledReceipt = async (
		installedIdentity: BridgeMainReviewPublicationIdentity,
	): Promise<void> => {
		const publicationId = installedIdentity.publicationId;
		this.receiptAttempts.push(publicationId);
		if (this.remainingReceiptFailures > 0) {
			this.remainingReceiptFailures -= 1;
			throw new Error('injected receipt failure');
		}
		this.receipts.push(publicationId);
	};
}

export class DeferredInstallationPort implements BridgeMainReviewPresentationInstallationPort {
	requestWorkerReplacement = vi.fn<() => void>();
	readonly receipts: string[] = [];
	private readonly pendingRequests: DeferredAdmission[] = [];
	private readonly requestWaiters: Array<(request: DeferredAdmission) => void> = [];

	requestInstallAdmission = (
		request: BridgeMainReviewInstallAdmissionRequest,
	): Promise<BridgeMainReviewInstallAdmissionResult> => {
		const deferred = new DeferredAdmission(request);
		const waiter = this.requestWaiters.shift();
		if (waiter === undefined) this.pendingRequests.push(deferred);
		else waiter(deferred);
		return deferred.promise;
	};

	sendInstalledReceipt = async (
		installedIdentity: BridgeMainReviewPublicationIdentity,
	): Promise<void> => {
		this.receipts.push(installedIdentity.publicationId);
	};

	nextRequest(): Promise<DeferredAdmission> {
		const pending = this.pendingRequests.shift();
		if (pending !== undefined) return Promise.resolve(pending);
		return new Promise((resolve) => this.requestWaiters.push(resolve));
	}
}

export class DeferredAdmission {
	readonly promise: Promise<BridgeMainReviewInstallAdmissionResult>;
	private rejectPromise!: (error: Error) => void;
	private resolvePromise!: (result: BridgeMainReviewInstallAdmissionResult) => void;

	constructor(readonly request: BridgeMainReviewInstallAdmissionRequest) {
		this.promise = new Promise((resolve, reject) => {
			this.rejectPromise = reject;
			this.resolvePromise = resolve;
		});
	}

	reject(): void {
		this.rejectPromise(new Error('injected admission failure'));
	}

	resolve(status: 'admitted' | 'rejected'): void {
		this.resolvePromise({ candidatePublicationId: this.request.candidatePublicationId, status });
	}
}

export function identity(generation: number, suffix: string): BridgeMainReviewPublicationIdentity {
	return {
		generation,
		packageId: `package-${generation}`,
		publicationId: `00000000-0000-7000-8000-${suffix.padStart(12, '0')}`,
		revision: 1,
		sourceIdentity: 'same-source',
	};
}

export function candidateReady(
	candidateIdentity: BridgeMainReviewPublicationIdentity,
	_presentationClass: 'ordinary' | 'promoted',
	_affectedStableFileIdentities: readonly string[],
): BridgeWorkerReviewCandidateReadyEvent {
	return {
		direction: 'serverWorkerToMain',
		epoch: candidateIdentity.generation,
		kind: 'reviewCandidateReady',
		packageId: candidateIdentity.packageId,
		publicationId: candidateIdentity.publicationId,
		reviewGeneration: candidateIdentity.generation,
		revision: candidateIdentity.revision,
		sequence: candidateIdentity.generation,
		sourceIdentity: candidateIdentity.sourceIdentity,
		surface: 'review',
		transferDescriptors: [],
		wireVersion: 1,
	};
}

export function candidateFailed(
	candidateIdentity: BridgeMainReviewPublicationIdentity,
	retryable: boolean,
): BridgeWorkerReviewCandidateFailedEvent {
	return {
		direction: 'serverWorkerToMain',
		epoch: candidateIdentity.generation,
		kind: 'reviewCandidateFailed',
		packageId: candidateIdentity.packageId,
		publicationId: candidateIdentity.publicationId,
		retryable,
		reviewGeneration: candidateIdentity.generation,
		revision: candidateIdentity.revision,
		sequence: candidateIdentity.generation,
		sourceIdentity: candidateIdentity.sourceIdentity,
		surface: 'review',
		transferDescriptors: [],
		wireVersion: 1,
	};
}

export function attention(
	stableFileIdentities: readonly string[],
	activeEditorStableFileIdentities: readonly string[] = [],
): BridgeMainReviewSemanticAttention {
	return { activeEditorStableFileIdentities, stableFileIdentities };
}

export function candidatePresentation(
	activeIdentity: BridgeMainReviewPublicationIdentity | null,
	candidateIdentity: BridgeMainReviewPublicationIdentity,
	startDisposition: BridgeWorkerReviewCandidateStartDisposition,
): BridgeMainReviewRefreshPresentation {
	return {
		activeIdentity,
		candidate: {
			affectedStableFileIdentities:
				startDisposition.kind === 'sameSource' ? startDisposition.affectedStableFileIdentities : [],
			effectivePresentationClass:
				startDisposition.kind === 'sameSource'
					? startDisposition.presentationClass
					: { kind: 'ordinary' },
			identity: candidateIdentity,
			role: 'provisional',
			startDisposition,
		},
		failure: null,
	};
}

export function sameSourceStart(
	presentationClass:
		| { readonly kind: 'ordinary' }
		| {
				readonly kind: 'promoted';
				readonly reason: 'commits' | 'files' | 'lines' | 'unknown';
		  },
	affectedStableFileIdentities: readonly string[],
): BridgeWorkerReviewCandidateStartDisposition {
	return { affectedStableFileIdentities, kind: 'sameSource', presentationClass };
}

export function sameIdentity(
	left: BridgeMainReviewPublicationIdentity,
	right: BridgeMainReviewPublicationIdentity,
): boolean {
	return JSON.stringify(left) === JSON.stringify(right);
}
import { vi } from 'vitest';
