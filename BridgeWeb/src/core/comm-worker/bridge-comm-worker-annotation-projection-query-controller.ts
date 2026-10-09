import { uuidv7 } from 'uuidv7';

import {
	recordWorktreeAnnotationLifecycleTelemetry,
	type WorktreeAnnotationLifecycleTelemetryRecorder,
} from '../../worktree-annotations/worktree-annotation-lifecycle-telemetry.js';
import { type BridgeCommWorkerAnnotationCatalog } from './bridge-comm-worker-annotation-catalog-applicator.js';
import {
	BridgeCommWorkerAnnotationProjectionDecoder,
	type BridgeWorkerAnnotationProjectionSnapshot,
} from './bridge-comm-worker-annotation-projection-decoder.js';
import {
	openAnnotationProjectionPage,
	validatePageContract,
} from './bridge-comm-worker-annotation-projection-page.js';
import { scheduleBridgeCommWorkerTaskBoundary } from './bridge-comm-worker-task-boundary.js';
import { BridgeIncrementalSha256 } from './bridge-incremental-sha256.js';
import {
	bridgeProductFileAnnotationMetadataApplicationProtocol,
	bridgeProductReviewAnnotationMetadataApplicationProtocol,
} from './bridge-product-metadata-application-registry.js';
import { BridgeProductControlRequestError } from './bridge-product-session-authority.js';
import { BridgeProductSubscriptionEpochRetiredError } from './bridge-product-subscription-state.js';
import type {
	BridgeProductContentStream,
	BridgeProductMetadataApplicationSubscription,
} from './bridge-product-transport-contract.js';
import {
	bridgeProductAnnotationProjectionQueryResultSchema,
	type BridgeProductAnnotationProjectionContentDescriptor,
	type BridgeProductAnnotationProjectionPageContract,
	type BridgeProductAnnotationProjectionQueryRequest,
	type BridgeProductAnnotationProjectionQueryResult,
	type BridgeProductReviewAnnotationPublicationIdentity,
} from './bridge-product-worktree-annotation-projection-query-contracts.js';

export type BridgeCommWorkerAnnotationSurface = 'file' | 'review';

type AnnotationMetadataProtocol =
	| typeof bridgeProductFileAnnotationMetadataApplicationProtocol
	| typeof bridgeProductReviewAnnotationMetadataApplicationProtocol;
type AnnotationMetadataSubscription =
	BridgeProductMetadataApplicationSubscription<AnnotationMetadataProtocol>;

export interface BridgeCommWorkerAnnotationProjectionDemand {
	readonly active: boolean;
	readonly reviewPublicationIdentity?: BridgeProductReviewAnnotationPublicationIdentity | null;
	readonly sessionIds: readonly string[];
	readonly sourceGeneration: number | null;
}

export interface BridgeCommWorkerAnnotationProjectionPublication {
	readonly operationCorrelationId: string | null;
	readonly state:
		| {
				readonly catalogAuthorityRetired: boolean;
				readonly error: unknown;
				readonly kind: 'unavailable';
		  }
		| {
				readonly contentSessionIds: readonly string[];
				readonly kind: 'ready';
				readonly stageAttempt: number;
				readonly reviewPublicationIdentity?:
					| BridgeProductReviewAnnotationPublicationIdentity
					| undefined;
				readonly snapshot: BridgeWorkerAnnotationProjectionSnapshot;
		  }
		| { readonly catalogAuthorityRetired: boolean; readonly kind: 'refreshing' };
	readonly surface: BridgeCommWorkerAnnotationSurface;
}

export interface BridgeCommWorkerAnnotationProjectionSourceAuthorityStalePublication {
	readonly currentSourceGeneration: number;
	readonly requestedSourceGeneration: number;
	readonly surface: BridgeCommWorkerAnnotationSurface;
}

interface CreateBridgeCommWorkerAnnotationProjectionQueryControllerProps {
	readonly onConvergence: (publication: BridgeCommWorkerAnnotationProjectionPublication) => void;
	readonly onSourceAuthorityStale: (
		publication: BridgeCommWorkerAnnotationProjectionSourceAuthorityStalePublication,
	) => void;
	readonly surface: BridgeCommWorkerAnnotationSurface;
	readonly telemetryClient?: WorktreeAnnotationLifecycleTelemetryRecorder | undefined;
	readonly transport: BridgeCommWorkerAnnotationProjectionTransport;
}

export interface BridgeCommWorkerAnnotationProjectionTransport {
	readonly callProjection: (
		surface: BridgeCommWorkerAnnotationSurface,
		request: BridgeProductAnnotationProjectionQueryRequest,
		signal: AbortSignal,
	) => Promise<unknown>;
	readonly openContent: (
		descriptor: BridgeProductAnnotationProjectionContentDescriptor,
		signal: AbortSignal,
	) => BridgeProductContentStream<'annotation.projection'>;
	readonly subscribe: (
		surface: BridgeCommWorkerAnnotationSurface,
	) => AnnotationMetadataSubscription;
	readonly setScope: (props: {
		readonly sessionIds: readonly string[];
		readonly subscriptionId: string;
		readonly worktreeId: string;
	}) => Promise<void>;
}

interface AnnotationProjectionInvalidation {
	readonly operationCorrelationId: string;
	readonly queryKind: 'content' | 'control';
	readonly sessionIds: readonly string[];
	readonly sourceGeneration: number;
	readonly worktreeId: string;
}

export class BridgeCommWorkerAnnotationProjectionQueryController {
	readonly #onConvergence: CreateBridgeCommWorkerAnnotationProjectionQueryControllerProps['onConvergence'];
	readonly #onSourceAuthorityStale: CreateBridgeCommWorkerAnnotationProjectionQueryControllerProps['onSourceAuthorityStale'];
	readonly #surface: BridgeCommWorkerAnnotationSurface;
	readonly #transport: BridgeCommWorkerAnnotationProjectionTransport;
	readonly #telemetryClient: WorktreeAnnotationLifecycleTelemetryRecorder | undefined;
	#active = false;
	#installedCatalog: BridgeCommWorkerAnnotationCatalog | null = null;
	#automaticQueryRetryConsumed = false;
	#automaticSubscriptionReopenConsumed = false;
	#abortController: AbortController | null = null;
	#disposed = false;
	#invalidation: AnnotationProjectionInvalidation | null = null;
	#invalidationGeneration = 0;
	#lastAttemptedGeneration = 0;
	#queryLoop: Promise<void> | null = null;
	#reviewPublicationIdentity: BridgeProductReviewAnnotationPublicationIdentity | null = null;
	readonly #queryAttempts = new Set<Promise<void>>();
	readonly #scopeUpdates = new Set<Promise<void>>();
	#scheduledQueryStart: Promise<void> | null = null;
	#scheduledSubscriptionReopen: Promise<void> | null = null;
	#sessionIds: readonly string[] = [];
	#lastSubmittedScopeSignature: string | null = null;
	#sourceGeneration: number | null = null;
	#stageAttemptOperationCorrelationId: string | null = null;
	#nextStageAttempt = 0;
	#subscription: AnnotationMetadataSubscription | null = null;

	constructor(props: CreateBridgeCommWorkerAnnotationProjectionQueryControllerProps) {
		this.#onConvergence = props.onConvergence;
		this.#onSourceAuthorityStale = props.onSourceAuthorityStale;
		this.#surface = props.surface;
		this.#transport = props.transport;
		this.#telemetryClient = props.telemetryClient;
	}

	ensureSubscription(): void {
		if (this.#disposed || this.#subscription !== null) return;
		let subscription: AnnotationMetadataSubscription;
		try {
			subscription = this.#transport.subscribe(this.#surface);
		} catch (error) {
			this.#handleSubscriptionFailure(error);
			return;
		}
		this.#subscription = subscription;
		this.#submitCurrentCommentScope();
		void this.#consumeSubscription(subscription).catch((error: unknown): void => {
			if (this.#subscription !== subscription || this.#disposed) return;
			if (error instanceof BridgeProductSubscriptionEpochRetiredError) {
				this.#followRetiredSurfaceEpoch();
				return;
			}
			this.#handleSubscriptionFailure(error);
		});
	}

	/** W4 has certified and installed the Comment catalog for this surface. */
	acceptInstalledCatalog(catalog: BridgeCommWorkerAnnotationCatalog): boolean {
		if (this.#disposed) return false;
		if (
			this.#subscription !== null &&
			catalog.authority.subscriptionId !== this.#subscription.subscriptionId
		) {
			return false;
		}
		if (
			this.#subscription !== null &&
			this.#installedCatalog !== null &&
			catalog.authority.worktreeId !== this.#installedCatalog.authority.worktreeId
		) {
			this.#replaceSubscriptionForWorktree();
			return false;
		}
		const initialCatalog = this.#installedCatalog === null;
		this.#installedCatalog = catalog;
		this.#submitCurrentCommentScope(initialCatalog);
		this.#automaticQueryRetryConsumed = false;
		this.#automaticSubscriptionReopenConsumed = false;
		const operationCorrelationId = nextCommentProjectionCorrelation(catalog.transferId);
		this.#recordLifecycle(
			operationCorrelationId,
			'annotation_invalidation_received',
			'success',
			this.#sourceGeneration ?? 0,
		);
		this.#admitProjectionInvalidation({
			operationCorrelationId,
			queryKind: 'control',
			sessionIds: [],
			sourceGeneration: this.#sourceGeneration ?? 0,
			worktreeId: catalog.authority.worktreeId,
		});
		return true;
	}

	#replaceSubscriptionForWorktree(): void {
		const subscription = this.#subscription;
		this.#subscription = null;
		this.#installedCatalog = null;
		this.#lastSubmittedScopeSignature = null;
		this.#invalidation = null;
		this.#invalidationGeneration += 1;
		this.#abortController?.abort();
		this.#onConvergence({
			operationCorrelationId: null,
			state: { catalogAuthorityRetired: true, kind: 'refreshing' },
			surface: this.#surface,
		});
		if (subscription !== null) {
			void subscription.cancel().catch((error: unknown): void => {
				this.sourceUnavailable(error);
			});
		}
		this.ensureSubscription();
	}

	/** File placement follows the installed File version, even when its source generation is unchanged. */
	refreshPlacementForInstalledFileView(): void {
		if (
			this.#disposed ||
			this.#surface !== 'file' ||
			!this.#active ||
			this.#installedCatalog === null ||
			this.#sessionIds.length === 0 ||
			this.#sourceGeneration === null
		)
			return;
		const catalog = this.#installedCatalog;
		this.#admitProjectionInvalidation({
			operationCorrelationId: nextCommentProjectionCorrelation(catalog.transferId),
			queryKind: 'content',
			sessionIds: this.#sessionIds,
			sourceGeneration: this.#sourceGeneration,
			worktreeId: catalog.authority.worktreeId,
		});
	}

	setDemand(demand: BridgeCommWorkerAnnotationProjectionDemand): void {
		if (this.#disposed) return;
		const previousSessionIds = this.#sessionIds;
		const previousSessionSignature = JSON.stringify(this.#sessionIds);
		this.#sessionIds = [...new Set(demand.sessionIds)].toSorted();
		const sessionDemandChanged = JSON.stringify(this.#sessionIds) !== previousSessionSignature;
		const previousSessionIdSet = new Set(previousSessionIds);
		const newlyDemandedSessionIds = this.#sessionIds.filter(
			(sessionId) => !previousSessionIdSet.has(sessionId),
		);
		const previousSourceGeneration = this.#sourceGeneration;
		const previousReviewPublicationIdentity = JSON.stringify(this.#reviewPublicationIdentity);
		this.#sourceGeneration = demand.sourceGeneration;
		this.#reviewPublicationIdentity = demand.reviewPublicationIdentity ?? null;
		const reviewIdentityChanged =
			previousReviewPublicationIdentity !==
			JSON.stringify(demand.reviewPublicationIdentity ?? null);
		const nextActive =
			demand.active &&
			demand.sourceGeneration !== null &&
			(this.#surface === 'file' || (demand.reviewPublicationIdentity ?? null) !== null);
		const becameInactive = this.#active && !nextActive;
		const becameActive = !this.#active && nextActive;
		this.#active = nextActive;
		if (becameInactive) {
			this.#abortController?.abort();
			return;
		}
		const presentationAuthorityChanged =
			previousSourceGeneration !== demand.sourceGeneration || reviewIdentityChanged;
		if (nextActive && (becameActive || presentationAuthorityChanged)) {
			if (this.#invalidation?.queryKind === 'content') {
				this.#invalidation = { ...this.#invalidation, sessionIds: this.#sessionIds };
			}
			this.#automaticQueryRetryConsumed = false;
			this.#automaticSubscriptionReopenConsumed = false;
			this.#invalidationGeneration += 1;
			this.#abortController?.abort();
		}
		if (sessionDemandChanged) this.#submitCurrentCommentScope();
		if (nextActive && this.#subscription === null) this.ensureSubscription();
		const installedCatalog = this.#installedCatalog;
		const initialControlReadStillRunning =
			this.#invalidation?.queryKind === 'control' &&
			(this.#queryLoop !== null || this.#scheduledQueryStart !== null);
		const inFlightContentSessionIds =
			this.#invalidation?.queryKind === 'content' &&
			(this.#queryLoop !== null || this.#scheduledQueryStart !== null) &&
			this.#invalidation.sourceGeneration === this.#sourceGeneration &&
			this.#invalidation.worktreeId === installedCatalog?.authority.worktreeId
				? new Set(this.#invalidation.sessionIds)
				: new Set<string>();
		const sessionsNeedingContent = newlyDemandedSessionIds.filter(
			(sessionId) => !inFlightContentSessionIds.has(sessionId),
		);
		if (
			nextActive &&
			!becameActive &&
			!presentationAuthorityChanged &&
			!initialControlReadStillRunning &&
			this.#sourceGeneration !== null &&
			installedCatalog !== null &&
			this.#subscription?.subscriptionId === installedCatalog.authority.subscriptionId &&
			sessionsNeedingContent.length > 0
		) {
			// Admission cancels unfinished content work. Carry its surviving demand into the replacement.
			const replacementSessionIds = this.#sessionIds.filter(
				(sessionId) =>
					inFlightContentSessionIds.has(sessionId) || sessionsNeedingContent.includes(sessionId),
			);
			this.#admitProjectionInvalidation({
				operationCorrelationId: nextCommentProjectionCorrelation(installedCatalog.transferId),
				queryKind: 'content',
				sessionIds: replacementSessionIds,
				sourceGeneration: this.#sourceGeneration,
				worktreeId: installedCatalog.authority.worktreeId,
			});
		}
		if (becameActive || this.#invalidationGeneration > this.#lastAttemptedGeneration) {
			this.#scheduleQueryLoop();
		}
	}

	retry(): void {
		if (this.#disposed) return;
		this.#automaticQueryRetryConsumed = false;
		this.#automaticSubscriptionReopenConsumed = false;
		if (this.#active && this.#subscription === null) this.ensureSubscription();
		if (this.#invalidation === null) return;
		this.#invalidationGeneration += 1;
		this.#abortController?.abort();
		this.#scheduleQueryLoop();
	}

	sourceUnavailable(error: unknown): void {
		if (this.#disposed || !this.#active) return;
		this.#invalidationGeneration += 1;
		this.#lastAttemptedGeneration = this.#invalidationGeneration;
		this.#abortController?.abort();
		this.#onConvergence({
			operationCorrelationId: this.#invalidation?.operationCorrelationId ?? null,
			state: { catalogAuthorityRetired: false, error, kind: 'unavailable' },
			surface: this.#surface,
		});
	}

	async dispose(): Promise<void> {
		if (this.#disposed) return;
		this.#disposed = true;
		this.#installedCatalog = null;
		this.#lastSubmittedScopeSignature = null;
		this.#invalidationGeneration += 1;
		this.#abortController?.abort();
		const subscription = this.#subscription;
		this.#subscription = null;
		await Promise.allSettled([
			...(subscription === null ? [] : [subscription.cancel()]),
			...(this.#scheduledQueryStart === null ? [] : [this.#scheduledQueryStart]),
			...(this.#scheduledSubscriptionReopen === null ? [] : [this.#scheduledSubscriptionReopen]),
			...this.#queryAttempts,
			...this.#scopeUpdates,
		]);
	}

	async waitForIdle(): Promise<void> {
		await Promise.resolve();
		await Promise.resolve();
		while (
			this.#scheduledQueryStart !== null ||
			this.#scheduledSubscriptionReopen !== null ||
			this.#queryAttempts.size > 0 ||
			this.#scopeUpdates.size > 0
		) {
			if (this.#scheduledSubscriptionReopen !== null) {
				// eslint-disable-next-line no-await-in-loop -- Reopen is one bounded task boundary.
				await this.#scheduledSubscriptionReopen;
			}
			if (this.#scheduledQueryStart !== null) {
				// eslint-disable-next-line no-await-in-loop -- The scheduled start coalesces current notification facts.
				await this.#scheduledQueryStart;
			}
			// eslint-disable-next-line no-await-in-loop -- Replacement attempts may settle and schedule one newer attempt.
			await Promise.allSettled(this.#queryAttempts);
			// eslint-disable-next-line no-await-in-loop -- Latest-wins E4 scope admission settles independently of the content read.
			await Promise.allSettled(this.#scopeUpdates);
		}
	}

	#submitCurrentCommentScope(initialCatalog = false): void {
		const catalog = this.#installedCatalog;
		if (catalog === null || this.#subscription === null) return;
		const signature = JSON.stringify({
			sessionIds: this.#sessionIds,
			subscriptionId: catalog.authority.subscriptionId,
			worktreeId: catalog.authority.worktreeId,
		});
		if (signature === this.#lastSubmittedScopeSignature) return;
		if (initialCatalog && this.#sessionIds.length === 0) {
			// W2 admitted this empty scope before the first W4 snapshot.
			this.#lastSubmittedScopeSignature = signature;
			return;
		}
		this.#lastSubmittedScopeSignature = signature;
		const update = this.#transport
			.setScope({
				sessionIds: this.#sessionIds,
				subscriptionId: catalog.authority.subscriptionId,
				worktreeId: catalog.authority.worktreeId,
			})
			.catch((error: unknown): void => {
				if (this.#lastSubmittedScopeSignature !== signature) return;
				this.#lastSubmittedScopeSignature = null;
				this.sourceUnavailable(error);
			})
			.finally((): void => {
				this.#scopeUpdates.delete(update);
			});
		this.#scopeUpdates.add(update);
	}

	async #consumeSubscription(subscription: AnnotationMetadataSubscription): Promise<void> {
		for await (const _event of subscription.events) {
			throw new Error('Comment E3 carried a retired metadata data event.');
		}
		if (!this.#disposed && this.#subscription === subscription) {
			throw new Error('Annotation projection notification subscription ended unexpectedly.');
		}
	}

	#admitProjectionInvalidation(invalidation: AnnotationProjectionInvalidation): void {
		this.#invalidation = invalidation;
		this.#invalidationGeneration += 1;
		this.#abortController?.abort();
		this.#scheduleQueryLoop();
	}

	/**
	 * The surface advanced past this subscription's epoch. That is a routine
	 * refresh, not a failure: comments stay visible as refreshing while the
	 * replacement opens at the new epoch.
	 */
	#followRetiredSurfaceEpoch(): void {
		const operationCorrelationId = this.#invalidation?.operationCorrelationId ?? null;
		this.#subscription = null;
		this.#installedCatalog = null;
		this.#lastSubmittedScopeSignature = null;
		this.#invalidation = null;
		this.#invalidationGeneration += 1;
		this.#abortController?.abort();
		this.#onConvergence({
			operationCorrelationId,
			state: { catalogAuthorityRetired: true, kind: 'refreshing' },
			surface: this.#surface,
		});
		this.ensureSubscription();
	}

	#handleSubscriptionFailure(error: unknown): void {
		const operationCorrelationId = this.#invalidation?.operationCorrelationId ?? null;
		this.#subscription = null;
		this.#installedCatalog = null;
		this.#lastSubmittedScopeSignature = null;
		this.#invalidation = null;
		this.#invalidationGeneration += 1;
		this.#abortController?.abort();
		this.#onConvergence({
			operationCorrelationId,
			state: { catalogAuthorityRetired: true, error, kind: 'unavailable' },
			surface: this.#surface,
		});
		if (
			this.#disposed ||
			!this.#active ||
			this.#automaticSubscriptionReopenConsumed ||
			this.#scheduledSubscriptionReopen !== null
		) {
			return;
		}
		this.#automaticSubscriptionReopenConsumed = true;
		const scheduledReopen = scheduleBridgeCommWorkerTaskBoundary((): void => {
			if (this.#scheduledSubscriptionReopen !== scheduledReopen) return;
			this.#scheduledSubscriptionReopen = null;
			this.ensureSubscription();
		});
		this.#scheduledSubscriptionReopen = scheduledReopen;
	}

	#scheduleQueryLoop(): void {
		if (this.#scheduledQueryStart !== null) return;
		const scheduledStart = scheduleBridgeCommWorkerTaskBoundary((): void => {
			if (this.#scheduledQueryStart !== scheduledStart) return;
			this.#scheduledQueryStart = null;
			this.#startQueryAttempt();
		});
		this.#scheduledQueryStart = scheduledStart;
	}

	#startQueryAttempt(): void {
		if (
			!this.#active ||
			this.#disposed ||
			this.#invalidation === null ||
			this.#invalidationGeneration <= this.#lastAttemptedGeneration
		) {
			return;
		}
		const attemptGeneration = this.#invalidationGeneration;
		const invalidation = this.#invalidation;
		const sourceGeneration = this.#sourceGeneration;
		if (sourceGeneration === null) return;
		const reviewPublicationIdentity = this.#reviewPublicationIdentity;
		const stageAttempt = this.#claimStageAttempt(invalidation.operationCorrelationId);
		this.#lastAttemptedGeneration = attemptGeneration;
		this.#abortController?.abort();
		const abortController = new AbortController();
		this.#abortController = abortController;
		this.#onConvergence({
			operationCorrelationId: invalidation.operationCorrelationId,
			state: { catalogAuthorityRetired: false, kind: 'refreshing' },
			surface: this.#surface,
		});
		this.#recordLifecycle(
			invalidation.operationCorrelationId,
			'projection_convergence_started',
			'started',
			sourceGeneration,
			stageAttempt,
		);
		this.#recordLifecycle(
			invalidation.operationCorrelationId,
			'projection_query_started',
			'started',
			sourceGeneration,
			stageAttempt,
		);
		this.#recordLifecycle(
			invalidation.operationCorrelationId,
			'worker_application_started',
			'started',
			sourceGeneration,
			stageAttempt,
		);
		const queryLoop = this.#runQueryAttempt(
			attemptGeneration,
			invalidation,
			sourceGeneration,
			reviewPublicationIdentity,
			stageAttempt,
			abortController,
		).finally((): void => {
			this.#queryAttempts.delete(queryLoop);
			if (this.#queryLoop !== queryLoop) return;
			this.#queryLoop = null;
			if (this.#abortController === abortController) this.#abortController = null;
			if (
				this.#active &&
				!this.#disposed &&
				this.#invalidationGeneration > this.#lastAttemptedGeneration
			) {
				this.#scheduleQueryLoop();
			}
		});
		this.#queryLoop = queryLoop;
		this.#queryAttempts.add(queryLoop);
	}

	async #runQueryAttempt(
		attemptGeneration: number,
		invalidation: AnnotationProjectionInvalidation,
		sourceGeneration: number,
		reviewPublicationIdentity: BridgeProductReviewAnnotationPublicationIdentity | null,
		stageAttempt: number,
		abortController: AbortController,
	): Promise<void> {
		let terminalRecorded = false;
		try {
			const fetchResult = await this.#fetchSnapshot(
				invalidation,
				sourceGeneration,
				reviewPublicationIdentity,
				stageAttempt,
				abortController.signal,
			);
			if (
				this.#disposed ||
				!this.#active ||
				abortController.signal.aborted ||
				attemptGeneration !== this.#invalidationGeneration
			) {
				this.#recordAttemptTerminal(invalidation, sourceGeneration, stageAttempt, 'cancelled');
				terminalRecorded = true;
				return;
			}
			if (fetchResult.kind === 'source_stale') {
				this.#recordAttemptTerminal(invalidation, sourceGeneration, stageAttempt, 'stale');
				terminalRecorded = true;
				this.#onSourceAuthorityStale({
					currentSourceGeneration: fetchResult.currentSourceGeneration,
					requestedSourceGeneration: sourceGeneration,
					surface: this.#surface,
				});
				return;
			}
			this.#onConvergence({
				operationCorrelationId: invalidation.operationCorrelationId,
				state: {
					contentSessionIds: invalidation.sessionIds,
					kind: 'ready',
					stageAttempt,
					...(reviewPublicationIdentity === null ? {} : { reviewPublicationIdentity }),
					snapshot: fetchResult.snapshot,
				},
				surface: this.#surface,
			});
			this.#recordAttemptTerminal(invalidation, sourceGeneration, stageAttempt, 'success');
			terminalRecorded = true;
			this.#automaticQueryRetryConsumed = false;
			if (invalidation.queryKind === 'control') {
				if (this.#sessionIds.length > 0) {
					this.#invalidation = {
						...invalidation,
						queryKind: 'content',
						sessionIds: this.#sessionIds,
					};
					this.#invalidationGeneration += 1;
				}
			}
		} catch (error) {
			const result = abortController.signal.aborted ? 'cancelled' : 'failure';
			this.#recordAttemptTerminal(invalidation, sourceGeneration, stageAttempt, result);
			terminalRecorded = true;
			if (
				!this.#disposed &&
				this.#active &&
				!abortController.signal.aborted &&
				attemptGeneration === this.#invalidationGeneration
			) {
				if (isRetryableProjectionAttempt(error) && !this.#automaticQueryRetryConsumed) {
					this.#automaticQueryRetryConsumed = true;
					this.#invalidationGeneration += 1;
					return;
				}
				this.#onConvergence({
					operationCorrelationId: invalidation.operationCorrelationId,
					state: { catalogAuthorityRetired: false, error, kind: 'unavailable' },
					surface: this.#surface,
				});
			}
		} finally {
			if (!terminalRecorded) {
				this.#recordAttemptTerminal(invalidation, sourceGeneration, stageAttempt, 'cancelled');
			}
		}
	}

	async #fetchSnapshot(
		invalidation: AnnotationProjectionInvalidation,
		sourceGeneration: number,
		reviewPublicationIdentity: BridgeProductReviewAnnotationPublicationIdentity | null,
		stageAttempt: number,
		signal: AbortSignal,
	): Promise<
		| { readonly kind: 'content'; readonly snapshot: BridgeWorkerAnnotationProjectionSnapshot }
		| Extract<BridgeProductAnnotationProjectionQueryResult, { readonly kind: 'source_stale' }>
	> {
		const decoder = new BridgeCommWorkerAnnotationProjectionDecoder();
		this.#recordLifecycle(
			invalidation.operationCorrelationId,
			'content_transfer_started',
			'started',
			sourceGeneration,
			stageAttempt,
		);
		let cursor: string | null = null;
		let expectedPage: BridgeProductAnnotationProjectionPageContract | null = null;
		let previousPageOrdinal: number | null = null;
		let contentTransferResult: 'cancelled' | 'failure' | 'stale' | 'success' = 'failure';
		try {
			while (true) {
				// eslint-disable-next-line no-await-in-loop -- Continuation cursors are single-use and strictly ordered.
				const result = await this.#queryProjection({
					cursor,
					operationCorrelationId: invalidation.operationCorrelationId,
					reviewPublicationIdentity,
					sessionIds: [...invalidation.sessionIds],
					signal,
					sourceGeneration,
				});
				const parsedResult = bridgeProductAnnotationProjectionQueryResultSchema.parse(result);
				if (parsedResult.kind === 'source_stale') {
					contentTransferResult = 'stale';
					return parsedResult;
				}
				const descriptor = parsedResult.descriptor;
				validatePageContract({
					descriptor,
					expectedPage,
					previousPageOrdinal,
					requestedCursor: cursor,
					requestedOperationCorrelationId: invalidation.operationCorrelationId,
					requestedSourceGeneration: sourceGeneration,
					requestedSurface: this.#surface,
				});
				expectedPage ??= descriptor.page;
				previousPageOrdinal = descriptor.page.pageOrdinal;
				// eslint-disable-next-line no-await-in-loop -- Each claimed page must complete before its continuation query.
				const pageBytes = await openAnnotationProjectionPage({
					descriptor,
					openContent: this.#transport.openContent,
					signal,
				});
				decoder.acceptPage(pageBytes, descriptor.page.pageOrdinal);
				if (descriptor.page.isLastPage) break;
				cursor = descriptor.page.nextCursor;
			}
			contentTransferResult = 'success';
		} catch (error) {
			contentTransferResult = signal.aborted ? 'cancelled' : 'failure';
			throw error;
		} finally {
			this.#recordLifecycle(
				invalidation.operationCorrelationId,
				'content_transfer_terminal',
				contentTransferResult,
				sourceGeneration,
				stageAttempt,
			);
		}
		if (expectedPage === null) throw new Error('Annotation projection returned no pages.');
		try {
			this.#recordLifecycle(
				invalidation.operationCorrelationId,
				'projection_validation_started',
				'started',
				sourceGeneration,
				stageAttempt,
			);
			const decodedProjection = decoder.finish();
			const snapshot = decodedProjection.snapshot;
			if (
				!projectionMeetsInstalledCatalogCurrentness(
					this.#installedCatalog,
					snapshot,
					invalidation.sessionIds,
				)
			) {
				throw new Error(
					'Annotation rich projection did not meet current catalog session authority.',
				);
			}
			if (
				expectedPage.operationCorrelationId !== invalidation.operationCorrelationId ||
				snapshot.projectionRevision !== expectedPage.projectionRevision ||
				snapshot.sourceGeneration !== expectedPage.sourceGeneration ||
				snapshot.worktreeId !== invalidation.worktreeId ||
				snapshot.expectedSessionCount !== expectedPage.expectedSessionCount ||
				snapshot.expectedThreadCount !== expectedPage.expectedThreadCount ||
				snapshot.expectedMessageCount !== expectedPage.expectedMessageCount
			) {
				throw new Error('Annotation projection header does not match its page contract.');
			}
			if (decodedProjection.aggregateSha256 !== expectedPage.aggregateSha256) {
				throw new Error(
					'Annotation projection aggregate SHA-256 does not match its page contract.',
				);
			}
			this.#recordLifecycle(
				invalidation.operationCorrelationId,
				'projection_validation_terminal',
				'success',
				sourceGeneration,
				stageAttempt,
			);
			return { kind: 'content', snapshot };
		} catch (error) {
			this.#recordLifecycle(
				invalidation.operationCorrelationId,
				'projection_validation_terminal',
				'failure',
				sourceGeneration,
				stageAttempt,
			);
			throw error;
		}
	}

	#recordAttemptTerminal(
		invalidation: AnnotationProjectionInvalidation,
		sourceGeneration: number,
		stageAttempt: number,
		result: 'cancelled' | 'failure' | 'stale' | 'success',
	): void {
		this.#recordLifecycle(
			invalidation.operationCorrelationId,
			'projection_query_terminal',
			result,
			sourceGeneration,
			stageAttempt,
		);
		this.#recordLifecycle(
			invalidation.operationCorrelationId,
			'projection_convergence_terminal',
			result,
			sourceGeneration,
			stageAttempt,
		);
		this.#recordLifecycle(
			invalidation.operationCorrelationId,
			'worker_application_terminal',
			result,
			sourceGeneration,
			stageAttempt,
		);
	}

	#recordLifecycle(
		operationCorrelationId: string,
		phase: Parameters<typeof recordWorktreeAnnotationLifecycleTelemetry>[0]['phase'],
		result: Parameters<typeof recordWorktreeAnnotationLifecycleTelemetry>[0]['result'],
		sourceGeneration: number,
		stageAttempt = 0,
	): void {
		recordWorktreeAnnotationLifecycleTelemetry({
			operationCorrelationId,
			phase,
			recorder: this.#telemetryClient,
			result,
			sourceGeneration,
			stageAttempt,
			transport: 'worker',
			viewer: this.#surface,
		});
	}

	#claimStageAttempt(operationCorrelationId: string): number {
		if (this.#stageAttemptOperationCorrelationId !== operationCorrelationId) {
			this.#stageAttemptOperationCorrelationId = operationCorrelationId;
			this.#nextStageAttempt = 1;
			return 0;
		}
		const stageAttempt = this.#nextStageAttempt;
		this.#nextStageAttempt += 1;
		return stageAttempt;
	}

	#queryProjection(props: {
		readonly cursor: string | null;
		readonly operationCorrelationId: string;
		readonly reviewPublicationIdentity: BridgeProductReviewAnnotationPublicationIdentity | null;
		readonly sessionIds: string[];
		readonly signal: AbortSignal;
		readonly sourceGeneration: number;
	}): Promise<unknown> {
		const requestBase = {
			cursor: props.cursor,
			operationCorrelationId: props.operationCorrelationId,
			sessionIds: props.sessionIds,
			sourceGeneration: props.sourceGeneration,
		};
		if (this.#surface === 'file') {
			return this.#transport.callProjection(
				'file',
				{ ...requestBase, surface: 'file' },
				props.signal,
			);
		}
		if (props.reviewPublicationIdentity === null) {
			return Promise.reject(
				new Error('Review annotation projection has no installed publication identity.'),
			);
		}
		return this.#transport.callProjection(
			'review',
			{
				...requestBase,
				reviewPublicationIdentity: props.reviewPublicationIdentity,
				surface: 'review',
			},
			props.signal,
		);
	}
}

function isRetryableProjectionAttempt(error: unknown): boolean {
	return error instanceof BridgeProductControlRequestError && error.retryable;
}

function nextCommentProjectionCorrelation(transferId: string): string {
	const hasher = new BridgeIncrementalSha256();
	hasher.update(new TextEncoder().encode(`${transferId}:${uuidv7()}`));
	return hasher.digestHex();
}

function projectionMeetsInstalledCatalogCurrentness(
	catalog: BridgeCommWorkerAnnotationCatalog | null,
	snapshot: BridgeWorkerAnnotationProjectionSnapshot,
	requestedSessionIds: readonly string[],
): boolean {
	if (catalog === null || snapshot.worktreeId !== catalog.authority.worktreeId) return false;
	for (const requestedSessionId of requestedSessionIds) {
		const catalogSession = catalog.sessionsById.get(requestedSessionId);
		const projectedSession = snapshot.sessions.find(
			(candidate) => candidate.sessionId === requestedSessionId,
		);
		if (
			catalogSession === undefined ||
			projectedSession === undefined ||
			projectedSession.semanticRevision < catalogSession.semanticRevision
		) {
			return false;
		}
	}
	return true;
}
