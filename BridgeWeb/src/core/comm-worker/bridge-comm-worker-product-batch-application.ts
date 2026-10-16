import type { BridgeCommWorkerAnnotationCatalog } from './bridge-comm-worker-annotation-catalog-applicator.js';
import {
	buildBridgeWorkerReviewCandidateFailedEvent,
	buildBridgeWorkerReviewCandidateReadyEvent,
	buildBridgeWorkerReviewCandidateStartedEvent,
} from './bridge-comm-worker-protocol.js';
import { bridgeCommWorkerReviewDisplayPatchesFromBatch } from './bridge-comm-worker-review-batch-display.js';
import {
	BridgeCommWorkerReviewBatchInstaller,
	type BridgeCommWorkerReviewBatchPresentation,
	verifyBridgeCommWorkerReviewBatch,
} from './bridge-comm-worker-review-batch-installer.js';
import type {
	BridgeCommWorkerReviewSuccessorReExposureFence,
	BridgeCommWorkerReviewSuccessorReExposureSettlement,
} from './bridge-comm-worker-review-publication-types.js';
import { reviewCandidateStartDispositionFromRefreshImpact } from './bridge-comm-worker-review-refresh-impact.js';
import {
	bridgeProductBatchDiagnostic,
	bridgeProductBatchDiagnosticHealthMessage,
	recordBridgeProductBatchDiagnostic,
} from './bridge-product-batch-diagnostics.js';
import type { BridgeProductBatchFrameSinks } from './bridge-product-batch-frame-router.js';
import type { BridgeProductBatchFrame } from './bridge-product-batch-wire-contracts.js';
import { installBridgeProductCommentBatch } from './bridge-product-comment-batch-installer.js';
import {
	installBridgeProductFileBatch,
	type BridgeProductInstalledFileView,
} from './bridge-product-file-batch-installer.js';
import type { BridgeProductViewInstallation } from './bridge-product-view-batch-receiver.js';
import type {
	BridgeWorkerReviewCandidateStartDisposition,
	BridgeWorkerReviewDisplayPatch,
	BridgeWorkerReviewPublicationIdentity,
	BridgeWorkerServerToMainMessage,
} from './bridge-worker-contracts.js';
import {
	compareReviewMetadataLineages,
	type ReviewMetadataLineage,
} from './bridge-worker-review-publication-lineage.js';

type BatchBegin = Extract<BridgeProductBatchFrame, { readonly kind: 'subscription.batchBegin' }>;

export interface BridgeCommWorkerProductBatchApplicationProps {
	readonly applyComment: (
		catalog: BridgeCommWorkerAnnotationCatalog,
		surface: 'file' | 'review',
	) => void;
	readonly applyFile: (
		view: BridgeProductInstalledFileView,
		begin: BatchBegin,
		certified: boolean,
	) => void;
	readonly applyReview: (
		presentation: BridgeCommWorkerReviewBatchPresentation,
		begin: BatchBegin,
		sourceEpoch: number,
		previous: BridgeCommWorkerReviewBatchPresentation | null,
	) => void;
	readonly createSequence: () => number;
	readonly publishReviewDisplay: (props: {
		readonly patches: readonly BridgeWorkerReviewDisplayPatch[];
		readonly reviewPublicationIdentity: BridgeWorkerReviewPublicationIdentity | null;
		readonly workerDerivationEpoch: number;
	}) => void;
	readonly publishMessage: (message: BridgeWorkerServerToMainMessage) => void;
	readonly requestResnapshot: (frame: BridgeProductBatchFrame) => void;
	readonly requestResnapshotLatest: (subscriptionId: string, domain: string) => void;
	readonly workerDerivationEpoch: (surface: 'file' | 'review') => number;
}

/** W4 hands one installed bank and its certification to the owning typed installer. */
export class BridgeCommWorkerProductBatchApplication {
	readonly #props: BridgeCommWorkerProductBatchApplicationProps;
	readonly #fileViewBySubscriptionId = new Map<string, BridgeProductInstalledFileView>();
	readonly #reviewInstallerBySubscriptionId = new Map<
		string,
		BridgeCommWorkerReviewBatchInstaller
	>();
	readonly #reviewSourceEpochBySubscriptionId = new Map<string, number>();
	#activeReviewPresentation: BridgeCommWorkerReviewBatchPresentation | null = null;
	#activeReviewReadyFacts: {
		readonly disposition: BridgeWorkerReviewCandidateStartDisposition;
		readonly identity: ReviewMetadataLineage;
	} | null = null;
	#lastSuccessorReExposureFence: BridgeCommWorkerReviewSuccessorReExposureFence | null = null;

	constructor(props: BridgeCommWorkerProductBatchApplicationProps) {
		this.#props = props;
	}

	handleMetadataFailure(workerDerivationEpoch: number): 'ignored' | 'noActive' | 'retainedActive' {
		if (workerDerivationEpoch !== this.#props.workerDerivationEpoch('review')) return 'ignored';
		const presentation = this.#activeReviewPresentation;
		const identity = presentation === null ? null : reviewLineage(presentation);
		if (presentation === null || identity === null) return 'noActive';
		this.#props.publishReviewDisplay({
			patches: staleReviewSourcePatch(presentation),
			reviewPublicationIdentity: reviewPublicationIdentity(identity),
			workerDerivationEpoch,
		});
		return 'retainedActive';
	}

	handleSuccessorReExposureSettlement(
		settlement: BridgeCommWorkerReviewSuccessorReExposureSettlement,
		workerDerivationEpoch: number | null,
	): boolean {
		const currentWorkerDerivationEpoch = this.#props.workerDerivationEpoch('review');
		const presentation = this.#activeReviewPresentation;
		const readyFacts = this.#activeReviewReadyFacts;
		if (
			workerDerivationEpoch === null ||
			workerDerivationEpoch !== currentWorkerDerivationEpoch ||
			presentation === null ||
			readyFacts === null
		) {
			return false;
		}
		if (settlement.kind === 'publicationApplied') {
			if (
				compareReviewMetadataLineages(
					readyFacts.identity,
					reviewMetadataLineageFromWorkerIdentity(settlement.identity),
				) !== 'newer'
			) {
				return false;
			}
			const previousFence = this.#lastSuccessorReExposureFence;
			if (
				previousFence !== null &&
				compareReviewMetadataLineages(previousFence.successor, readyFacts.identity) === 'same' &&
				(previousFence.kind === 'admissionRecovery' ||
					compareReviewMetadataLineages(
						previousFence.installed,
						reviewMetadataLineageFromWorkerIdentity(settlement.identity),
					) === 'same')
			) {
				return false;
			}
			this.#publishCurrentReviewCandidate(presentation, readyFacts, currentWorkerDerivationEpoch);
			this.#lastSuccessorReExposureFence = {
				admissionFailureRetryUsed: false,
				installed: reviewMetadataLineageFromWorkerIdentity(settlement.identity),
				kind: 'installedPair',
				successor: readyFacts.identity,
			};
			return true;
		}
		const activeMatchesCandidate =
			readyFacts.identity.publicationId === settlement.candidatePublicationId;
		if (settlement.kind === 'admissionRejected' && activeMatchesCandidate) return false;
		const previousFence = this.#lastSuccessorReExposureFence;
		if (
			settlement.kind === 'admissionFailed' &&
			previousFence?.successor.publicationId === readyFacts.identity.publicationId &&
			previousFence.admissionFailureRetryUsed
		) {
			return false;
		}
		this.#publishCurrentReviewCandidate(presentation, readyFacts, currentWorkerDerivationEpoch);
		this.#lastSuccessorReExposureFence = {
			admissionFailureRetryUsed: settlement.kind === 'admissionFailed' && activeMatchesCandidate,
			kind: 'admissionRecovery',
			successor: readyFacts.identity,
			triggerPublicationId: settlement.candidatePublicationId,
		};
		return true;
	}

	sinks(): BridgeProductBatchFrameSinks {
		return {
			diagnostic: (sample): void =>
				this.#props.publishMessage(bridgeProductBatchDiagnosticHealthMessage(sample)),
			verify: (installation): void => this.#verify(installation),
			install: (installation): Promise<void> | void => this.#install(installation),
			receipt: (): void => {},
			resnapshot: (frame): void => this.#props.requestResnapshot(frame),
			resnapshotLatest: (subscriptionId, domain): void =>
				this.#props.requestResnapshotLatest(subscriptionId, domain),
		};
	}

	#verify(installation: BridgeProductViewInstallation): void {
		const begin = installation.begin;
		switch (begin.subscriptionKind) {
			case 'file.metadata':
				installBridgeProductFileBatch(
					installation,
					this.#fileViewBySubscriptionId.get(begin.subscriptionId) ?? null,
				);
				return;
			case 'review.metadata':
				verifyBridgeCommWorkerReviewBatch(installation);
				return;
			case 'file.annotations':
			case 'review.annotations': {
				const surface = begin.subscriptionKind === 'file.annotations' ? 'file' : 'review';
				installBridgeProductCommentBatch(installation, {
					subscriptionId: begin.subscriptionId,
					workerDerivationEpoch: this.#props.workerDerivationEpoch(surface),
					worktreeId: commentWorktreeId(begin.scope),
				});
				return;
			}
		}
	}

	#install(installation: BridgeProductViewInstallation): Promise<void> | void {
		const begin = installation.begin;
		switch (begin.subscriptionKind) {
			case 'file.metadata': {
				const previous = this.#fileViewBySubscriptionId.get(begin.subscriptionId) ?? null;
				const candidate = installBridgeProductFileBatch(installation, previous);
				this.#props.applyFile(candidate, begin, installation.certified);
				this.#fileViewBySubscriptionId.set(begin.subscriptionId, candidate);
				return;
			}
			case 'review.metadata': {
				let installer = this.#reviewInstallerBySubscriptionId.get(begin.subscriptionId);
				if (installer === undefined) {
					installer = new BridgeCommWorkerReviewBatchInstaller({ handle: begin.handle });
					this.#reviewInstallerBySubscriptionId.set(begin.subscriptionId, installer);
				} else {
					installer.replaceHandle(begin.handle);
				}
				const previous = installer.presentation;
				const sourceEpoch =
					(this.#reviewSourceEpochBySubscriptionId.get(begin.subscriptionId) ?? 0) + 1;
				return installer
					.install({
						begin,
						records: installation.records,
						applyPresentation: (presentation): void => {
							const workerDerivationEpoch = this.#props.workerDerivationEpoch('review');
							const identity = reviewCandidateLineage(presentation);
							const readyFacts =
								identity === null
									? null
									: {
											disposition: reviewCandidateStartDispositionFromRefreshImpact({
												impact: presentation.publication.classifiedRefreshImpact,
												previous,
												successor: presentation,
											}),
											identity,
										};
							if (readyFacts !== null)
								this.#publishCandidateStarted(readyFacts, workerDerivationEpoch);
							try {
								this.#props.applyReview(presentation, begin, sourceEpoch, previous);
								this.#activeReviewPresentation = presentation;
								this.#activeReviewReadyFacts = readyFacts;
								this.#reviewSourceEpochBySubscriptionId.set(begin.subscriptionId, sourceEpoch);
								if (readyFacts !== null) {
									this.#lastSuccessorReExposureFence = null;
									this.#publishCandidateReady(readyFacts, workerDerivationEpoch);
								}
							} catch (error) {
								recordBridgeProductBatchDiagnostic(
									(sample): void =>
										this.#props.publishMessage(bridgeProductBatchDiagnosticHealthMessage(sample)),
									bridgeProductBatchDiagnostic({
										frame: begin,
										step: 'reviewPresentationApply',
										error,
									}),
								);
								if (readyFacts !== null)
									this.#publishCandidateFailed(readyFacts.identity, workerDerivationEpoch);
								throw error;
							}
						},
					})
					.then((): void => {});
			}
			case 'file.annotations':
			case 'review.annotations': {
				const surface = begin.subscriptionKind === 'file.annotations' ? 'file' : 'review';
				const worktreeId = commentWorktreeId(begin.scope);
				const catalog = installBridgeProductCommentBatch(installation, {
					subscriptionId: begin.subscriptionId,
					workerDerivationEpoch: this.#props.workerDerivationEpoch(surface),
					worktreeId,
				});
				this.#props.applyComment(catalog, surface);
				return;
			}
		}
	}

	#publishCurrentReviewCandidate(
		presentation: BridgeCommWorkerReviewBatchPresentation,
		readyFacts: {
			readonly disposition: BridgeWorkerReviewCandidateStartDisposition;
			readonly identity: ReviewMetadataLineage;
		},
		workerDerivationEpoch: number,
	): void {
		const currentIdentity = reviewLineage(presentation);
		if (
			currentIdentity === null ||
			compareReviewMetadataLineages(currentIdentity, readyFacts.identity) !== 'same'
		) {
			return;
		}
		this.#publishCandidateStarted(readyFacts, workerDerivationEpoch);
		this.#props.publishReviewDisplay({
			patches: bridgeCommWorkerReviewDisplayPatchesFromBatch(presentation),
			reviewPublicationIdentity: reviewPublicationIdentity(readyFacts.identity),
			workerDerivationEpoch,
		});
		this.#publishCandidateReady(readyFacts, workerDerivationEpoch);
	}

	#publishCandidateStarted(
		readyFacts: {
			readonly disposition: BridgeWorkerReviewCandidateStartDisposition;
			readonly identity: ReviewMetadataLineage;
		},
		workerDerivationEpoch: number,
	): void {
		this.#props.publishMessage(
			buildBridgeWorkerReviewCandidateStartedEvent({
				disposition: readyFacts.disposition,
				epoch: workerDerivationEpoch,
				packageId: readyFacts.identity.packageId,
				publicationId: readyFacts.identity.publicationId,
				reviewGeneration: readyFacts.identity.generation,
				revision: readyFacts.identity.revision,
				sequence: this.#props.createSequence(),
				sourceIdentity: readyFacts.identity.sourceIdentity,
			}),
		);
	}

	#publishCandidateReady(
		readyFacts: { readonly identity: ReviewMetadataLineage },
		workerDerivationEpoch: number,
	): void {
		this.#props.publishMessage(
			buildBridgeWorkerReviewCandidateReadyEvent({
				epoch: workerDerivationEpoch,
				packageId: readyFacts.identity.packageId,
				publicationId: readyFacts.identity.publicationId,
				reviewGeneration: readyFacts.identity.generation,
				revision: readyFacts.identity.revision,
				sequence: this.#props.createSequence(),
				sourceIdentity: readyFacts.identity.sourceIdentity,
			}),
		);
	}

	#publishCandidateFailed(identity: ReviewMetadataLineage, workerDerivationEpoch: number): void {
		this.#props.publishMessage(
			buildBridgeWorkerReviewCandidateFailedEvent({
				epoch: workerDerivationEpoch,
				packageId: identity.packageId,
				publicationId: identity.publicationId,
				retryable: true,
				reviewGeneration: identity.generation,
				revision: identity.revision,
				sequence: this.#props.createSequence(),
				sourceIdentity: identity.sourceIdentity,
			}),
		);
	}
}

function reviewLineage(
	presentation: BridgeCommWorkerReviewBatchPresentation,
): ReviewMetadataLineage | null {
	const identity = presentation.runtimeSource.reviewPublicationIdentity;
	if (identity === null) return null;
	return {
		generation: identity.reviewGeneration,
		packageId: identity.packageId,
		publicationId: identity.publicationId,
		revision: identity.revision,
		sourceIdentity: identity.sourceIdentity,
	};
}

function reviewCandidateLineage(
	presentation: BridgeCommWorkerReviewBatchPresentation,
): ReviewMetadataLineage | null {
	if (
		presentation.publication.desired.status !== 'ready' ||
		presentation.publication.displayed === null ||
		presentation.publication.publicationId !== presentation.publication.displayed.publicationId
	) {
		return null;
	}
	return reviewLineage(presentation);
}

function reviewPublicationIdentity(
	identity: ReviewMetadataLineage,
): BridgeWorkerReviewPublicationIdentity {
	return {
		packageId: identity.packageId,
		publicationId: identity.publicationId,
		reviewGeneration: identity.generation,
		revision: identity.revision,
		sourceIdentity: identity.sourceIdentity,
	};
}

function reviewMetadataLineageFromWorkerIdentity(
	identity: BridgeWorkerReviewPublicationIdentity,
): ReviewMetadataLineage {
	return {
		generation: identity.reviewGeneration,
		packageId: identity.packageId,
		publicationId: identity.publicationId,
		revision: identity.revision,
		sourceIdentity: identity.sourceIdentity,
	};
}

function staleReviewSourcePatch(
	presentation: BridgeCommWorkerReviewBatchPresentation,
): readonly BridgeWorkerReviewDisplayPatch[] {
	return bridgeCommWorkerReviewDisplayPatchesFromBatch(presentation).flatMap((patch) => {
		if (patch.slice !== 'reviewSource' || patch.operation !== 'upsert') return [];
		return [{ ...patch, payload: { ...patch.payload, status: 'stale' as const } }];
	});
}

function commentWorktreeId(scope: BatchBegin['scope']): string {
	if (
		typeof scope !== 'object' ||
		scope === null ||
		Array.isArray(scope) ||
		scope.kind !== 'comment' ||
		typeof scope['worktreeId'] !== 'string'
	) {
		throw new Error('Comment batch scope must identify its admitted worktree.');
	}
	return scope['worktreeId'];
}
