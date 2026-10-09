import { bridgeRenderDispositionAdmissionPolicy } from '../demand/bridge-content-demand-policy.js';
import { readBridgeCommWorkerAbsoluteNowMilliseconds } from './bridge-comm-worker-clock.js';
import type { BridgeProductSurface } from './bridge-product-contract-primitives.js';
import type { BridgeWorkerPierreRenderJob } from './bridge-worker-pierre-render-job.js';
import {
	createBridgeWorkerRenderFulfillment,
	reduceBridgeWorkerRenderFulfillment,
	isBridgeWorkerRenderReceiptRejectionError,
	type BridgeWorkerRenderDispositionReceipt,
	type BridgeWorkerRenderFulfillmentState,
	type BridgeWorkerRenderReceiptIdentity,
	type BridgeWorkerPaintReleasedReceipt,
} from './bridge-worker-render-fulfillment.js';

export interface BridgeWorkerRenderFulfillmentRegistryContext {
	readonly paneSessionId: string;
	readonly surface: BridgeProductSurface;
	readonly workerInstanceId: string;
}

export type BridgeWorkerRenderFulfillmentIdentifierPurpose =
	| 'attempt'
	| 'publication'
	| 'submission';

export interface CreateBridgeWorkerRenderFulfillmentRegistryProps {
	readonly context: BridgeWorkerRenderFulfillmentRegistryContext;
	readonly createIdentifier?: (purpose: BridgeWorkerRenderFulfillmentIdentifierPurpose) => string;
	readonly now?: () => number;
	readonly receiptLeaseDurationMilliseconds: number;
	readonly retryBackoffMilliseconds: number;
}

export interface BeginBridgeWorkerRenderPublicationProps {
	readonly job: BridgeWorkerPierreRenderJob;
	readonly operationCorrelationId?: string | null;
	readonly publicationSequence: number;
	readonly workerDerivationEpoch: number;
}

export type BeginBridgeWorkerRenderPublicationResult = Readonly<
	| {
			receiptIdentity: BridgeWorkerRenderReceiptIdentity;
			shouldPublish: true;
			state: BridgeWorkerRenderFulfillmentState;
			status: 'published';
	  }
	| {
			receiptIdentity: BridgeWorkerRenderReceiptIdentity;
			shouldPublish: false;
			state: BridgeWorkerRenderFulfillmentState;
			status: 'duplicate' | 'retry_wait';
	  }
>;

export type ApplyBridgeWorkerRenderDispositionResult = Readonly<
	| {
			readonly state: BridgeWorkerRenderFulfillmentState;
			readonly status: 'accepted' | 'duplicate';
	  }
	| {
			readonly reason: string;
			readonly state: BridgeWorkerRenderFulfillmentState | null;
			readonly status: 'rejected';
	  }
>;

const bridgeWorkerRenderWindowKeyMaximumLength = 4096;

export class BridgeWorkerRenderFulfillmentRegistry {
	readonly #context: BridgeWorkerRenderFulfillmentRegistryContext;
	readonly #createIdentifier: (purpose: BridgeWorkerRenderFulfillmentIdentifierPurpose) => string;
	readonly #fulfillmentByItemId = new Map<string, BridgeWorkerRenderFulfillmentState>();
	readonly #sourceChurnDispositionByItemId = new Map<string, 'retain' | 'retire'>();
	readonly #sourceRevalidationItemIds = new Set<string>();
	readonly #visibleItemIds = new Set<string>();
	readonly #visibleQueuedLeaseByItemId = new Map<
		string,
		{ readonly attemptId: string; readonly expiresAtMilliseconds: number }
	>();
	readonly #deliveryProbeCountByItemId = new Map<string, number>();
	readonly #exhaustedItemIds = new Set<string>();
	readonly #now: () => number;
	readonly #receiptLeaseDurationMilliseconds: number;
	readonly #retryBackoffMilliseconds: number;

	constructor(props: CreateBridgeWorkerRenderFulfillmentRegistryProps) {
		assertBridgeWorkerRenderPositiveDuration(
			props.receiptLeaseDurationMilliseconds,
			'receipt lease duration',
		);
		assertBridgeWorkerRenderNonnegativeDuration(props.retryBackoffMilliseconds, 'retry backoff');
		this.#context = Object.freeze({ ...props.context });
		this.#createIdentifier =
			props.createIdentifier ??
			((purpose): string => `${purpose}-${globalThis.crypto.randomUUID()}`);
		this.#now = props.now ?? readBridgeCommWorkerAbsoluteNowMilliseconds;
		this.#receiptLeaseDurationMilliseconds = props.receiptLeaseDurationMilliseconds;
		this.#retryBackoffMilliseconds = props.retryBackoffMilliseconds;
	}

	beginPublication(
		props: BeginBridgeWorkerRenderPublicationProps,
	): BeginBridgeWorkerRenderPublicationResult {
		const windowKey = bridgeWorkerRenderWindowKeyForJob(props.job);
		const operationCorrelationId = props.operationCorrelationId ?? null;
		let existingState = this.#fulfillmentByItemId.get(props.job.itemId) ?? null;
		if (existingState !== null && existingState.identity.windowKey !== windowKey) {
			this.#deliveryProbeCountByItemId.delete(props.job.itemId);
			this.#exhaustedItemIds.delete(props.job.itemId);
			this.#visibleQueuedLeaseByItemId.delete(props.job.itemId);
			this.#sourceChurnDispositionByItemId.delete(props.job.itemId);
		}
		if (
			existingState !== null &&
			existingState.identity.windowKey === windowKey &&
			existingState.operationCorrelationId === operationCorrelationId &&
			existingState.workerDerivationEpoch === props.workerDerivationEpoch
		) {
			if (existingState.stage === 'retry_wait') {
				existingState = this.#releaseRetryIfReady(existingState, this.#now());
			}
			if (
				existingState.stage === 'desired' &&
				this.#sourceRevalidationItemIds.delete(props.job.itemId)
			) {
				existingState = reduceBridgeWorkerRenderFulfillment(existingState, {
					kind: 'source.revalidationUnchanged',
				});
				this.#fulfillmentByItemId.set(props.job.itemId, existingState);
			}
			if (existingState.stage !== 'desired') {
				return Object.freeze({
					receiptIdentity: activeBridgeWorkerRenderReceiptIdentity(existingState),
					shouldPublish: false,
					state: existingState,
					status: existingState.stage === 'retry_wait' ? 'retry_wait' : 'duplicate',
				});
			}
		}
		this.#sourceRevalidationItemIds.delete(props.job.itemId);

		const publicationState =
			existingState === null ||
			existingState.identity.windowKey !== windowKey ||
			existingState.operationCorrelationId !== operationCorrelationId ||
			existingState.workerDerivationEpoch !== props.workerDerivationEpoch
				? createBridgeWorkerRenderFulfillment({
						...this.#context,
						identity: Object.freeze({ windowKey }),
						itemId: props.job.itemId,
						operationCorrelationId,
						publicationId: this.#createIdentifier('publication'),
						publicationSequence: props.publicationSequence,
						submissionId: this.#createIdentifier('submission'),
						workerDerivationEpoch: props.workerDerivationEpoch,
					})
				: existingState;
		const preparingState = reduceBridgeWorkerRenderFulfillment(publicationState, {
			kind: 'preparation.started',
		});
		const publishedAtMilliseconds = this.#now();
		const publishedState = reduceBridgeWorkerRenderFulfillment(preparingState, {
			attemptId: this.#createIdentifier('attempt'),
			kind: 'publication.started',
			publishedAtMilliseconds,
			receiptLeaseExpiresAtMilliseconds:
				publishedAtMilliseconds + this.#receiptLeaseDurationMilliseconds,
		});
		this.#fulfillmentByItemId.set(props.job.itemId, publishedState);
		return Object.freeze({
			receiptIdentity: activeBridgeWorkerRenderReceiptIdentity(publishedState),
			shouldPublish: true,
			state: publishedState,
			status: 'published',
		});
	}

	applyDisposition(
		receipt: BridgeWorkerRenderDispositionReceipt,
	): ApplyBridgeWorkerRenderDispositionResult {
		const currentState = this.#fulfillmentByItemId.get(receipt.itemId) ?? null;
		if (currentState === null) {
			return Object.freeze({
				reason: 'Bridge render disposition has no matching worker publication.',
				state: null,
				status: 'rejected',
			});
		}
		let nextState: BridgeWorkerRenderFulfillmentState;
		try {
			nextState = reduceBridgeWorkerRenderFulfillment(currentState, receipt);
		} catch (error) {
			if (!isBridgeWorkerRenderReceiptRejectionError(error)) {
				throw error;
			}
			return Object.freeze({
				reason: bridgeWorkerRenderRegistryRejectionReason(error),
				state: currentState,
				status: 'rejected',
			});
		}
		if (nextState === currentState) {
			return Object.freeze({ state: currentState, status: 'duplicate' });
		}
		if (receipt.disposition === 'queued' && this.#visibleItemIds.has(receipt.itemId)) {
			this.#armVisibleQueuedLease(nextState);
		} else if (receipt.disposition !== 'queued') {
			this.#visibleQueuedLeaseByItemId.delete(receipt.itemId);
			if (receipt.disposition === 'painted') {
				this.#deliveryProbeCountByItemId.delete(receipt.itemId);
				this.#exhaustedItemIds.delete(receipt.itemId);
			}
		}
		const sourceChurnDisposition = this.#sourceChurnDispositionByItemId.get(receipt.itemId);
		this.#sourceChurnDispositionByItemId.delete(receipt.itemId);
		if (sourceChurnDisposition === 'retire') {
			this.#fulfillmentByItemId.delete(receipt.itemId);
			this.#sourceRevalidationItemIds.delete(receipt.itemId);
		} else {
			this.#fulfillmentByItemId.set(receipt.itemId, nextState);
		}
		return Object.freeze({ state: nextState, status: 'accepted' });
	}

	applyPaintRelease(
		receipt: BridgeWorkerPaintReleasedReceipt,
	): ApplyBridgeWorkerRenderDispositionResult {
		const currentState = this.#fulfillmentByItemId.get(receipt.itemId) ?? null;
		if (currentState === null) {
			return Object.freeze({ reason: 'stale_submission', state: null, status: 'rejected' });
		}
		if (
			currentState.submissionId !== receipt.submissionId ||
			currentState.publicationId !== receipt.publicationId ||
			currentState.workerDerivationEpoch !== receipt.workerDerivationEpoch ||
			(currentState.activeAttempt !== null &&
				currentState.activeAttempt.attemptId !== receipt.attemptId)
		) {
			return Object.freeze({ reason: 'stale_submission', state: currentState, status: 'rejected' });
		}
		if (currentState.stage !== 'painted') {
			return Object.freeze({ reason: 'already_terminal', state: currentState, status: 'rejected' });
		}
		if (currentState.paintedResidency?.attemptId !== receipt.attemptId) {
			return Object.freeze({ reason: 'stale_submission', state: currentState, status: 'rejected' });
		}
		let nextState: BridgeWorkerRenderFulfillmentState;
		try {
			nextState = reduceBridgeWorkerRenderFulfillment(currentState, receipt);
		} catch (error) {
			if (!isBridgeWorkerRenderReceiptRejectionError(error)) throw error;
			return Object.freeze({ reason: 'stale_submission', state: currentState, status: 'rejected' });
		}
		this.#sourceRevalidationItemIds.delete(receipt.itemId);
		this.#fulfillmentByItemId.set(receipt.itemId, nextState);
		return Object.freeze({ state: nextState, status: 'accepted' });
	}

	updateVisibleItemIds(itemIds: readonly string[]): void {
		this.#visibleItemIds.clear();
		for (const itemId of itemIds) this.#visibleItemIds.add(itemId);
		for (const itemId of this.#visibleQueuedLeaseByItemId.keys()) {
			if (!this.#visibleItemIds.has(itemId)) this.#visibleQueuedLeaseByItemId.delete(itemId);
		}
		for (const itemId of this.#visibleItemIds) {
			const state = this.#fulfillmentByItemId.get(itemId);
			if (state?.stage === 'queued' && !this.#visibleQueuedLeaseByItemId.has(itemId)) {
				this.#armVisibleQueuedLease(state);
			}
		}
	}

	expireVisibleQueuedLeases(atMilliseconds: number = this.#now()): {
		readonly exhaustedItemIds: readonly string[];
		readonly retryableItemIds: readonly string[];
	} {
		const exhaustedItemIds: string[] = [];
		const retryableItemIds: string[] = [];
		for (const [itemId, lease] of this.#visibleQueuedLeaseByItemId) {
			if (atMilliseconds < lease.expiresAtMilliseconds) continue;
			this.#visibleQueuedLeaseByItemId.delete(itemId);
			const state = this.#fulfillmentByItemId.get(itemId);
			if (state?.stage !== 'queued' || state.activeAttempt?.attemptId !== lease.attemptId) {
				continue;
			}
			if (
				(this.#deliveryProbeCountByItemId.get(itemId) ?? 0) >=
				bridgeRenderDispositionAdmissionPolicy.maximumUnknownDeliveryProbeCount
			) {
				this.#exhaustPublication(state, atMilliseconds);
				exhaustedItemIds.push(itemId);
				continue;
			}
			this.#deliveryProbeCountByItemId.set(
				itemId,
				(this.#deliveryProbeCountByItemId.get(itemId) ?? 0) + 1,
			);
			this.#fulfillmentByItemId.set(
				itemId,
				reduceBridgeWorkerRenderFulfillment(state, {
					...activeBridgeWorkerRenderReceiptIdentity(state),
					atMilliseconds,
					kind: 'receiptLease.expired',
					retryAtMilliseconds: atMilliseconds + this.#retryBackoffMilliseconds,
				}),
			);
			retryableItemIds.push(itemId);
		}
		return { exhaustedItemIds, retryableItemIds };
	}

	expireReceiptLeases(atMilliseconds: number = this.#now()): readonly string[] {
		const expiredItemIds: string[] = [];
		for (const [itemId, currentState] of this.#fulfillmentByItemId) {
			const activeAttempt = currentState.activeAttempt;
			if (
				activeAttempt === null ||
				activeAttempt.highestDisposition !== null ||
				atMilliseconds < activeAttempt.receiptLeaseExpiresAtMilliseconds
			) {
				continue;
			}
			const sourceChurnDisposition = this.#sourceChurnDispositionByItemId.get(itemId);
			this.#sourceChurnDispositionByItemId.delete(itemId);
			if (sourceChurnDisposition === 'retire') {
				this.#sourceRevalidationItemIds.delete(itemId);
				this.#fulfillmentByItemId.delete(itemId);
				expiredItemIds.push(itemId);
				continue;
			}
			if (
				(this.#deliveryProbeCountByItemId.get(itemId) ?? 0) >=
				bridgeRenderDispositionAdmissionPolicy.maximumUnknownDeliveryProbeCount
			) {
				this.#exhaustPublication(currentState, atMilliseconds);
				expiredItemIds.push(itemId);
				continue;
			}
			this.#deliveryProbeCountByItemId.set(
				itemId,
				(this.#deliveryProbeCountByItemId.get(itemId) ?? 0) + 1,
			);
			const nextState = reduceBridgeWorkerRenderFulfillment(currentState, {
				...activeBridgeWorkerRenderReceiptIdentity(currentState),
				atMilliseconds,
				kind: 'receiptLease.expired',
				retryAtMilliseconds: atMilliseconds + this.#retryBackoffMilliseconds,
			});
			this.#fulfillmentByItemId.set(itemId, nextState);
			expiredItemIds.push(itemId);
		}
		return Object.freeze(expiredItemIds);
	}

	releaseReadyRetries(atMilliseconds: number = this.#now()): readonly string[] {
		const releasedItemIds: string[] = [];
		for (const [itemId, currentState] of this.#fulfillmentByItemId) {
			const nextState = this.#releaseRetryIfReady(currentState, atMilliseconds);
			if (nextState === currentState) continue;
			this.#fulfillmentByItemId.set(itemId, nextState);
			releasedItemIds.push(itemId);
		}
		return Object.freeze(releasedItemIds);
	}

	requeuePublicationsForSourceChurn(atMilliseconds: number = this.#now()): readonly string[] {
		const requeuedItemIds: string[] = [];
		for (const [itemId, currentState] of this.#fulfillmentByItemId) {
			this.#visibleQueuedLeaseByItemId.delete(itemId);
			if (currentState.stage === 'held' || currentState.stage === 'failed') continue;
			if (currentState.stage === 'painted') {
				this.#sourceChurnDispositionByItemId.delete(itemId);
				const desiredState = reduceBridgeWorkerRenderFulfillment(currentState, {
					kind: 'source.revalidationRequested',
				});
				this.#fulfillmentByItemId.set(itemId, desiredState);
				this.#sourceRevalidationItemIds.add(itemId);
				requeuedItemIds.push(itemId);
				continue;
			}
			if (
				currentState.activeAttempt === null ||
				currentState.activeAttempt.highestDisposition === null
			) {
				if (currentState.activeAttempt?.highestDisposition === null) {
					if (this.#sourceChurnDispositionByItemId.get(itemId) !== 'retire') {
						this.#sourceChurnDispositionByItemId.set(itemId, 'retain');
					}
				}
				continue;
			}
			this.#sourceChurnDispositionByItemId.delete(itemId);
			this.#sourceRevalidationItemIds.delete(itemId);
			const retryState = reduceBridgeWorkerRenderFulfillment(currentState, {
				...activeBridgeWorkerRenderReceiptIdentity(currentState),
				disposition: 'superseded',
				kind: 'render.disposition',
				reason: 'stale_attempt',
				receivedAtMilliseconds: atMilliseconds,
				retryAtMilliseconds: atMilliseconds,
			});
			const desiredState = reduceBridgeWorkerRenderFulfillment(retryState, {
				atMilliseconds,
				kind: 'retry.ready',
			});
			this.#fulfillmentByItemId.set(itemId, desiredState);
			requeuedItemIds.push(itemId);
		}
		return Object.freeze(requeuedItemIds);
	}

	retireRemovedItemsForSourceChurn(itemIds: readonly string[]): void {
		for (const itemId of itemIds) {
			this.#visibleQueuedLeaseByItemId.delete(itemId);
			this.#deliveryProbeCountByItemId.delete(itemId);
			this.#exhaustedItemIds.delete(itemId);
			const currentState = this.#fulfillmentByItemId.get(itemId);
			if (currentState?.activeAttempt?.highestDisposition === null) {
				this.#sourceChurnDispositionByItemId.set(itemId, 'retire');
				continue;
			}
			this.#sourceChurnDispositionByItemId.delete(itemId);
			this.#sourceRevalidationItemIds.delete(itemId);
			this.#fulfillmentByItemId.delete(itemId);
		}
	}

	nextLifecycleWakeAtMilliseconds(): number | null {
		let nextWakeAtMilliseconds: number | null = null;
		for (const currentState of this.#fulfillmentByItemId.values()) {
			const candidateWakeAtMilliseconds =
				currentState.stage === 'retry_wait'
					? currentState.retryAtMilliseconds
					: currentState.activeAttempt?.highestDisposition === null
						? currentState.activeAttempt.receiptLeaseExpiresAtMilliseconds
						: null;
			if (
				candidateWakeAtMilliseconds !== null &&
				candidateWakeAtMilliseconds !== undefined &&
				(nextWakeAtMilliseconds === null || candidateWakeAtMilliseconds < nextWakeAtMilliseconds)
			) {
				nextWakeAtMilliseconds = candidateWakeAtMilliseconds;
			}
		}
		for (const lease of this.#visibleQueuedLeaseByItemId.values()) {
			if (nextWakeAtMilliseconds === null || lease.expiresAtMilliseconds < nextWakeAtMilliseconds) {
				nextWakeAtMilliseconds = lease.expiresAtMilliseconds;
			}
		}
		return nextWakeAtMilliseconds;
	}

	getItemState(itemId: string): BridgeWorkerRenderFulfillmentState | null {
		return this.#fulfillmentByItemId.get(itemId) ?? null;
	}

	retryExhaustedPublications(): readonly string[] {
		const itemIds = [...this.#exhaustedItemIds];
		for (const itemId of itemIds) {
			this.#fulfillmentByItemId.delete(itemId);
			this.#sourceChurnDispositionByItemId.delete(itemId);
			this.#sourceRevalidationItemIds.delete(itemId);
			this.#visibleQueuedLeaseByItemId.delete(itemId);
			this.#deliveryProbeCountByItemId.delete(itemId);
		}
		this.#exhaustedItemIds.clear();
		return itemIds;
	}

	resetPublications(): void {
		this.#fulfillmentByItemId.clear();
		this.#sourceChurnDispositionByItemId.clear();
		this.#sourceRevalidationItemIds.clear();
		this.#visibleQueuedLeaseByItemId.clear();
		this.#deliveryProbeCountByItemId.clear();
		this.#exhaustedItemIds.clear();
	}

	#exhaustPublication(state: BridgeWorkerRenderFulfillmentState, atMilliseconds: number): void {
		const retryState = reduceBridgeWorkerRenderFulfillment(state, {
			...activeBridgeWorkerRenderReceiptIdentity(state),
			atMilliseconds,
			kind: 'receiptLease.expired',
			retryAtMilliseconds: atMilliseconds,
		});
		this.#fulfillmentByItemId.set(
			state.itemId,
			reduceBridgeWorkerRenderFulfillment(retryState, { kind: 'delivery.exhausted' }),
		);
		this.#exhaustedItemIds.add(state.itemId);
	}

	#armVisibleQueuedLease(state: BridgeWorkerRenderFulfillmentState): void {
		if (
			state.stage !== 'queued' ||
			state.activeAttempt === null ||
			this.#exhaustedItemIds.has(state.itemId)
		) {
			return;
		}
		this.#visibleQueuedLeaseByItemId.set(state.itemId, {
			attemptId: state.activeAttempt.attemptId,
			expiresAtMilliseconds: this.#now() + this.#receiptLeaseDurationMilliseconds,
		});
	}

	#releaseRetryIfReady(
		state: BridgeWorkerRenderFulfillmentState,
		atMilliseconds: number,
	): BridgeWorkerRenderFulfillmentState {
		if (
			state.stage !== 'retry_wait' ||
			state.retryAtMilliseconds === null ||
			atMilliseconds < state.retryAtMilliseconds
		) {
			return state;
		}
		const nextState = reduceBridgeWorkerRenderFulfillment(state, {
			atMilliseconds,
			kind: 'retry.ready',
		});
		this.#fulfillmentByItemId.set(state.itemId, nextState);
		return nextState;
	}
}

export function bridgeWorkerRenderWindowKeyForJob(job: BridgeWorkerPierreRenderJob): string {
	const windowKey = JSON.stringify([
		'bridge-render-window-v1',
		job.itemId,
		job.renderKind,
		job.contentCacheKey,
		job.contentHash,
		job.window.startLine,
		job.window.endLine,
		job.window.totalLineCount,
	]);
	if (windowKey.length > bridgeWorkerRenderWindowKeyMaximumLength) {
		throw new Error('Bridge render semantic window identity exceeds its bounded wire shape.');
	}
	return windowKey;
}

function activeBridgeWorkerRenderReceiptIdentity(
	state: BridgeWorkerRenderFulfillmentState,
): BridgeWorkerRenderReceiptIdentity {
	if (state.activeAttempt !== null) {
		return Object.freeze({
			attemptId: state.activeAttempt.attemptId,
			itemId: state.itemId,
			operationCorrelationId: state.operationCorrelationId,
			paneSessionId: state.paneSessionId,
			publicationId: state.publicationId,
			publicationSequence: state.publicationSequence,
			submissionId: state.submissionId,
			surface: state.surface,
			windowKey: state.identity.windowKey,
			workerDerivationEpoch: state.workerDerivationEpoch,
			workerInstanceId: state.workerInstanceId,
		});
	}
	if (state.paintedResidency !== null) {
		return state.paintedResidency;
	}
	const latestClosedAttempt = state.closedAttempts.at(-1);
	if (latestClosedAttempt !== undefined) {
		return Object.freeze({
			attemptId: latestClosedAttempt.attemptId,
			itemId: state.itemId,
			operationCorrelationId: state.operationCorrelationId,
			paneSessionId: state.paneSessionId,
			publicationId: state.publicationId,
			publicationSequence: state.publicationSequence,
			submissionId: state.submissionId,
			surface: state.surface,
			windowKey: state.identity.windowKey,
			workerDerivationEpoch: state.workerDerivationEpoch,
			workerInstanceId: state.workerInstanceId,
		});
	}
	throw new Error('Bridge render fulfillment has no receipt-bearing attempt.');
}

function assertBridgeWorkerRenderPositiveDuration(value: number, name: string): void {
	if (!Number.isFinite(value) || value <= 0) {
		throw new Error(`Bridge render ${name} must be finite and positive.`);
	}
}

function assertBridgeWorkerRenderNonnegativeDuration(value: number, name: string): void {
	if (!Number.isFinite(value) || value < 0) {
		throw new Error(`Bridge render ${name} must be finite and nonnegative.`);
	}
}

function bridgeWorkerRenderRegistryRejectionReason(error: unknown): string {
	return error instanceof Error ? error.message : 'Bridge render disposition was rejected.';
}
