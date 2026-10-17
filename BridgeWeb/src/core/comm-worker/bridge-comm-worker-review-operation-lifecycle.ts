import type { BridgeCommWorkerPanePresentationAuthority } from './bridge-comm-worker-pane-presentation.js';
import {
	admitBridgeCommWorkerReviewDisplayPatches,
	bridgeCommWorkerReviewDisplayPatchEvent,
} from './bridge-comm-worker-review-display-projection.js';
import type { BridgeCommWorkerReviewSourceIdentity } from './bridge-comm-worker-review-display-projection.js';
import type { BridgeCommWorkerReviewQueryProjection } from './bridge-comm-worker-review-query-projection.js';
import type {
	BridgeCommWorkerReviewMetadataApplication,
	BridgeCommWorkerReviewRuntimeApplicationTransaction,
} from './bridge-comm-worker-review-runtime-application.js';
import {
	recordBridgeOperationLifecycleTelemetry,
	type BridgeOperationLifecycleTelemetryRecorder,
} from './bridge-operation-lifecycle-telemetry.js';
import type {
	BridgeWorkerReviewDisplayPatch,
	BridgeWorkerReviewPublicationIdentity,
	BridgeWorkerServerToMainMessage,
} from './bridge-worker-contracts.js';

export class BridgeCommWorkerReviewOperationLifecycleTelemetry {
	readonly #applicationAttemptByOperationId = new Map<string, number>();
	readonly #recorder: BridgeOperationLifecycleTelemetryRecorder | undefined;
	#currentOperationCorrelationId: string | null = null;

	constructor(recorder?: BridgeOperationLifecycleTelemetryRecorder) {
		this.#recorder = recorder;
	}

	get currentOperationCorrelationId(): string | null {
		return this.#currentOperationCorrelationId;
	}

	wrapApplication(
		application: BridgeCommWorkerReviewMetadataApplication,
		prepare: () => BridgeCommWorkerReviewRuntimeApplicationTransaction,
	): BridgeCommWorkerReviewRuntimeApplicationTransaction {
		const operationCorrelationId = application.operationCorrelationId ?? null;
		this.#currentOperationCorrelationId = operationCorrelationId;
		const stageAttempt = this.#nextAttempt(operationCorrelationId);
		this.#record(operationCorrelationId, 'worker_application_started', 'started', stageAttempt);
		let transaction: BridgeCommWorkerReviewRuntimeApplicationTransaction;
		try {
			transaction = prepare();
		} catch (error) {
			this.#record(operationCorrelationId, 'worker_application_terminal', 'failure', stageAttempt);
			throw error;
		}
		return {
			commit: transaction.commit,
			rollback: (): void => {
				transaction.rollback();
				this.#record(
					operationCorrelationId,
					'worker_application_terminal',
					'failure',
					stageAttempt,
				);
			},
			runPostCommitEffects: (): void => {
				transaction.runPostCommitEffects();
				this.#record(
					operationCorrelationId,
					'worker_application_terminal',
					'success',
					stageAttempt,
				);
			},
		};
	}

	publishPanel(operationCorrelationId: string | null | undefined, publish: () => void): void {
		const correlationId = operationCorrelationId ?? null;
		const stageAttempt =
			correlationId === null ? 0 : (this.#applicationAttemptByOperationId.get(correlationId) ?? 0);
		this.#record(correlationId, 'panel_chrome_publish_started', 'started', stageAttempt);
		try {
			publish();
			this.#record(correlationId, 'panel_chrome_publish_terminal', 'success', stageAttempt);
		} catch (error) {
			this.#record(correlationId, 'panel_chrome_publish_terminal', 'failure', stageAttempt);
			throw error;
		}
	}

	#nextAttempt(operationCorrelationId: string | null): number {
		if (operationCorrelationId === null) return 0;
		const attempt = (this.#applicationAttemptByOperationId.get(operationCorrelationId) ?? -1) + 1;
		this.#applicationAttemptByOperationId.set(operationCorrelationId, attempt);
		return attempt;
	}

	#record(
		operationCorrelationId: string | null,
		phase:
			| 'panel_chrome_publish_started'
			| 'panel_chrome_publish_terminal'
			| 'worker_application_started'
			| 'worker_application_terminal',
		result: 'failure' | 'started' | 'success',
		stageAttempt: number,
	): void {
		if (operationCorrelationId === null) return;
		recordBridgeOperationLifecycleTelemetry({
			operationCorrelationId,
			phase,
			recorder: this.#recorder,
			result,
			stageAttempt,
			viewer: 'review',
		});
	}
}

type BridgeCommWorkerReviewComparisonCallback = (
	reviewComparison: Exclude<
		ReturnType<typeof admitBridgeCommWorkerReviewDisplayPatches>['reviewComparison'],
		undefined
	>,
	workerDerivationEpoch: number,
	isUpdatingReview: boolean,
) => void;

export class BridgeCommWorkerReviewDisplayLifecyclePublisher {
	readonly #createSequence: () => number;
	readonly #lifecycle: BridgeCommWorkerReviewOperationLifecycleTelemetry;
	readonly #onReviewComparison: BridgeCommWorkerReviewComparisonCallback;
	readonly #onSourceIdentity: (sourceIdentity: BridgeCommWorkerReviewSourceIdentity) => void;
	readonly #panePresentationAuthority: BridgeCommWorkerPanePresentationAuthority;
	readonly #postMessage: (message: BridgeWorkerServerToMainMessage) => void;
	readonly #queryProjection: BridgeCommWorkerReviewQueryProjection;
	readonly #readActiveViewerMode: () => 'file' | 'review' | null;
	#projectionRevision = 0;

	constructor(props: {
		readonly createSequence: () => number;
		readonly lifecycle: BridgeCommWorkerReviewOperationLifecycleTelemetry;
		readonly onReviewComparison: BridgeCommWorkerReviewComparisonCallback;
		readonly onSourceIdentity: (sourceIdentity: BridgeCommWorkerReviewSourceIdentity) => void;
		readonly panePresentationAuthority: BridgeCommWorkerPanePresentationAuthority;
		readonly postMessage: (message: BridgeWorkerServerToMainMessage) => void;
		readonly queryProjection: BridgeCommWorkerReviewQueryProjection;
		readonly readActiveViewerMode: () => 'file' | 'review' | null;
	}) {
		this.#createSequence = props.createSequence;
		this.#lifecycle = props.lifecycle;
		this.#onReviewComparison = props.onReviewComparison;
		this.#onSourceIdentity = props.onSourceIdentity;
		this.#panePresentationAuthority = props.panePresentationAuthority;
		this.#postMessage = props.postMessage;
		this.#queryProjection = props.queryProjection;
		this.#readActiveViewerMode = props.readActiveViewerMode;
	}

	publish(publication: {
		readonly comparisonCommit?:
			| Parameters<typeof admitBridgeCommWorkerReviewDisplayPatches>[0]['comparisonCommit']
			| undefined;
		readonly operationCorrelationId?: string | null;
		readonly patches: readonly BridgeWorkerReviewDisplayPatch[];
		readonly reviewPublicationIdentity?: BridgeWorkerReviewPublicationIdentity | null;
		readonly workerDerivationEpoch: number;
	}): void {
		const admitted = admitBridgeCommWorkerReviewDisplayPatches({
			...(publication.comparisonCommit === undefined
				? {}
				: { comparisonCommit: publication.comparisonCommit }),
			panePresentationAuthority: this.#panePresentationAuthority,
			patches: publication.patches,
		});
		const patches = this.#queryProjection.applyDisplayPatches(admitted.patches);
		if (patches.length === 0) return;
		this.#lifecycle.publishPanel(publication.operationCorrelationId, (): void => {
			this.post({
				patches,
				...(publication.reviewPublicationIdentity === undefined
					? {}
					: { reviewPublicationIdentity: publication.reviewPublicationIdentity }),
				workerDerivationEpoch: publication.workerDerivationEpoch,
			});
		});
		if (admitted.sourceIdentity !== null) this.#onSourceIdentity(admitted.sourceIdentity);
		if (admitted.reviewComparison === undefined) return;
		const presentation = this.#panePresentationAuthority.snapshot;
		this.#onReviewComparison(
			admitted.reviewComparison,
			publication.workerDerivationEpoch,
			presentation.nativeActivity === 'foreground' &&
				this.#readActiveViewerMode() === 'review' &&
				presentation.refreshingLanes.includes('review'),
		);
	}

	post(publication: {
		readonly patches: readonly BridgeWorkerReviewDisplayPatch[];
		readonly reviewPublicationIdentity?: BridgeWorkerReviewPublicationIdentity | null;
		readonly workerDerivationEpoch: number;
	}): void {
		this.#projectionRevision += 1;
		this.#postMessage(
			bridgeCommWorkerReviewDisplayPatchEvent({
				patches: publication.patches,
				projectionRevision: this.#projectionRevision,
				reviewPublicationIdentity: publication.reviewPublicationIdentity ?? null,
				sequence: this.#createSequence(),
				workerDerivationEpoch: publication.workerDerivationEpoch,
			}),
		);
	}
}
