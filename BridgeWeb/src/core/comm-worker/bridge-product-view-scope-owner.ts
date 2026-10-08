import {
	createBridgeProductDeferred,
	type BridgeProductDeferred,
} from './bridge-product-async-queue.js';
import type { BridgeProductSnapshotCause } from './bridge-product-batch-wire-contracts.js';
import type { BridgeProductDeadlineClock } from './bridge-product-deadline-clock.js';
import type { BridgeProductControlMux } from './bridge-product-session-authority.js';
import type { ViewResnapshotAdmissionProps } from './bridge-product-view-control-admission.js';
import type { BridgeProductViewScopeRequest } from './bridge-product-view-control-wire-contracts.js';
import type { BridgeWorkerViewRecoveryStatusEvent } from './bridge-worker-contracts.js';
import { bridgeWorkerViewRecoveryKindSchema } from './bridge-worker-view-recovery-contracts.js';

type ViewScope = BridgeProductViewScopeRequest['scope'];
type ViewKind = BridgeWorkerViewRecoveryStatusEvent['view']['kind'];
type ViewRegistrationOutcome = 'registered' | 'retired';

interface DesiredView {
	consecutiveResnapshots: number;
	readonly handle: string;
	readonly incarnation: string;
	resnapshotInFlight: Promise<void> | null;
	resnapshotRequested: boolean;
	awaitingBegin: boolean;
	clearReplacementBeginDeadline: (() => void) | null;
	replacementBeginDeadlineGeneration: number;
	readonly subscriptionId: string;
	readonly subscriptionKind: ViewKind;
	currentAdmission: AbortController | null;
	scopeRevision: number;
	desiredScope: ViewScope;
	recoveryStatus: BridgeWorkerViewRecoveryStatusEvent['status'] | null;
}

type ViewIdentity = Pick<
	ViewResnapshotAdmissionProps,
	'handle' | 'incarnation' | 'scopeRevision' | 'subscriptionId'
>;

export interface BridgeProductViewRecoveryState {
	readonly consecutiveResnapshots: number;
	readonly status: BridgeWorkerViewRecoveryStatusEvent['status'];
}

export type BridgeProductViewScopeSettlement =
	| { readonly kind: 'accepted'; readonly scopeRevision: number }
	| { readonly kind: 'cancelled' };

/** W2 owns the latest desired scope; W4 owns the separate install barrier. */
export class BridgeProductViewScopeOwner {
	readonly #controlMux: Pick<BridgeProductControlMux, 'resnapshotView' | 'setViewScope'>;
	readonly #createIdentifier: () => string;
	readonly #deadlineClock: BridgeProductDeadlineClock;
	readonly #maximumConsecutiveResnapshots: number;
	readonly #progressDeadlineMilliseconds: number;
	readonly #onViewRecoveryStatus:
		| ((status: Pick<BridgeWorkerViewRecoveryStatusEvent, 'status' | 'view'>) => void)
		| undefined;
	readonly #views = new Map<string, DesiredView>();
	readonly #pendingRegistrations = new Map<
		string,
		BridgeProductDeferred<ViewRegistrationOutcome>
	>();

	constructor(props: {
		readonly controlMux: Pick<BridgeProductControlMux, 'resnapshotView' | 'setViewScope'>;
		readonly createIdentifier: () => string;
		readonly deadlineClock: BridgeProductDeadlineClock;
		readonly maximumConsecutiveResnapshots: number;
		readonly onViewRecoveryStatus?: (
			status: Pick<BridgeWorkerViewRecoveryStatusEvent, 'status' | 'view'>,
		) => void;
		readonly progressDeadlineMilliseconds: number;
	}) {
		this.#controlMux = props.controlMux;
		this.#createIdentifier = props.createIdentifier;
		this.#deadlineClock = props.deadlineClock;
		this.#onViewRecoveryStatus = props.onViewRecoveryStatus;
		if (
			!Number.isSafeInteger(props.maximumConsecutiveResnapshots) ||
			props.maximumConsecutiveResnapshots <= 0
		) {
			throw new Error('View resnapshot budget must be a positive safe integer.');
		}
		this.#maximumConsecutiveResnapshots = props.maximumConsecutiveResnapshots;
		if (
			!Number.isSafeInteger(props.progressDeadlineMilliseconds) ||
			props.progressDeadlineMilliseconds <= 0
		) {
			throw new Error('Replacement begin progress deadline must be a positive safe integer.');
		}
		this.#progressDeadlineMilliseconds = props.progressDeadlineMilliseconds;
	}

	/** Only a subscription allocated by this transport may wait for registration. */
	allocatePendingRegistration(subscriptionId: string): void {
		if (this.#views.has(subscriptionId) || this.#pendingRegistrations.has(subscriptionId)) {
			throw new Error('A metadata view is already allocated for this subscription.');
		}
		this.#pendingRegistrations.set(
			subscriptionId,
			createBridgeProductDeferred<ViewRegistrationOutcome>(),
		);
	}

	register(props: {
		readonly scope: ViewScope;
		readonly subscriptionId: string;
		readonly subscriptionKind: string;
	}): void {
		if (this.#views.has(props.subscriptionId)) {
			throw new Error('A metadata view is already registered for this subscription.');
		}
		const subscriptionKind = bridgeWorkerViewRecoveryKindSchema.parse(props.subscriptionKind);
		this.#views.set(props.subscriptionId, {
			consecutiveResnapshots: 0,
			currentAdmission: null,
			desiredScope: props.scope,
			recoveryStatus: null,
			handle: this.#createIdentifier(),
			incarnation: this.#createIdentifier(),
			resnapshotInFlight: null,
			resnapshotRequested: false,
			awaitingBegin: false,
			clearReplacementBeginDeadline: null,
			replacementBeginDeadlineGeneration: 0,
			scopeRevision: 0,
			subscriptionId: props.subscriptionId,
			subscriptionKind,
		});
		const view = this.#views.get(props.subscriptionId);
		if (view !== undefined) this.#emitRecoveryStatus(view, 'recovering');
		this.#settlePendingRegistration(props.subscriptionId, 'registered');
	}

	async setScope(props: {
		readonly scope: ViewScope;
		readonly signal?: AbortSignal;
		readonly subscriptionId: string;
	}): Promise<BridgeProductViewScopeSettlement> {
		const pendingRegistration = this.#pendingRegistrations.get(props.subscriptionId);
		if (pendingRegistration !== undefined && (await pendingRegistration.promise) === 'retired') {
			throw new Error('Metadata view scope has no registered E3.');
		}
		const view = this.#views.get(props.subscriptionId);
		if (view === undefined) throw new Error('Metadata view scope has no registered E3.');
		if (!scopeMatchesKind(view.subscriptionKind, props.scope.kind)) {
			throw new Error('Metadata view scope differs from its registered kind.');
		}
		const commentView =
			view.subscriptionKind === 'file.annotations' ||
			view.subscriptionKind === 'review.annotations';
		const requiresBatchBegin =
			!commentView || view.scopeRevision === 0 || view.awaitingBegin || view.resnapshotRequested;
		view.currentAdmission?.abort();
		view.scopeRevision += 1;
		view.desiredScope = props.scope;
		view.resnapshotInFlight = null;
		view.resnapshotRequested = false;
		this.#clearReplacementBeginDeadline(view);
		view.awaitingBegin = requiresBatchBegin;
		if (requiresBatchBegin) this.#emitRecoveryStatus(view, 'recovering');
		const scopeRevision = view.scopeRevision;
		const admission = new AbortController();
		view.currentAdmission = admission;
		const abortAdmission = (): void => admission.abort(props.signal?.reason);
		props.signal?.addEventListener('abort', abortAdmission, { once: true });
		if (props.signal?.aborted === true) abortAdmission();
		try {
			await this.#controlMux.setViewScope({
				domain: 'default',
				handle: view.handle,
				incarnation: view.incarnation,
				scope: props.scope,
				scopeRevision,
				signal: admission.signal,
				subscriptionId: view.subscriptionId,
				subscriptionKind: view.subscriptionKind,
			});
			if (view.scopeRevision !== scopeRevision) return { kind: 'cancelled' };
			if (admission.signal.aborted) {
				view.awaitingBegin = false;
				return { kind: 'cancelled' };
			}
			if (view.awaitingBegin) this.#armReplacementBeginDeadline(view, 'default');
			return { kind: 'accepted', scopeRevision };
		} catch (error) {
			if (admission.signal.aborted) {
				if (view.scopeRevision === scopeRevision) view.awaitingBegin = false;
				return { kind: 'cancelled' };
			}
			if (view.scopeRevision === scopeRevision) view.awaitingBegin = false;
			throw error;
		} finally {
			props.signal?.removeEventListener('abort', abortAdmission);
			if (view.currentAdmission === admission) view.currentAdmission = null;
		}
	}

	async resnapshot(subscriptionId: string, domain = 'default'): Promise<void> {
		const view = this.#views.get(subscriptionId);
		if (view === undefined) return;
		await this.requestResnapshot({
			domain,
			handle: view.handle,
			incarnation: view.incarnation,
			scopeRevision: view.scopeRevision,
			subscriptionId: view.subscriptionId,
			subscriptionKind: view.subscriptionKind,
		});
	}

	requestResnapshot(request: ViewResnapshotAdmissionProps): Promise<void> {
		const view = this.#matchingView(request);
		if (view === undefined) return Promise.resolve();
		if (view.consecutiveResnapshots >= this.#maximumConsecutiveResnapshots) {
			this.#clearReplacementBeginDeadline(view);
			view.awaitingBegin = false;
			this.#emitRecoveryStatus(view, 'failedRetryable');
			return Promise.resolve();
		}
		if (view.resnapshotInFlight !== null) return view.resnapshotInFlight;
		if (view.resnapshotRequested) return Promise.resolve();
		view.consecutiveResnapshots += 1;
		view.resnapshotRequested = true;
		view.awaitingBegin = false;
		this.#clearReplacementBeginDeadline(view);
		this.#emitRecoveryStatus(view, 'recovering');
		try {
			const admission = this.#controlMux.resnapshotView(request);
			const inFlight = admission.then(
				(): void => {
					if (view.resnapshotInFlight === inFlight) {
						view.resnapshotInFlight = null;
						if (view.resnapshotRequested) {
							view.awaitingBegin = true;
							this.#armReplacementBeginDeadline(view, request.domain);
						}
					}
				},
				(error: unknown): never => {
					if (view.resnapshotInFlight === inFlight) {
						view.resnapshotInFlight = null;
						view.resnapshotRequested = false;
						this.#clearReplacementBeginDeadline(view);
					}
					throw error;
				},
			);
			view.resnapshotInFlight = inFlight;
			return inFlight;
		} catch (error) {
			view.resnapshotRequested = false;
			this.#clearReplacementBeginDeadline(view);
			return Promise.reject(error);
		}
	}

	observeSnapshotBegin(
		identity: ViewIdentity & { readonly snapshotCause: BridgeProductSnapshotCause },
	): boolean {
		const view = this.#matchingView(identity);
		if (view === undefined) return true;
		const cause = identity.snapshotCause;
		const failed = view.recoveryStatus === 'failedRetryable';
		if (failed && (cause === 'recovery' || cause === 'requested')) return false;
		if (cause === 'newerInput') return true;
		this.#clearReplacementBeginDeadline(view);
		view.awaitingBegin = false;
		if (cause === 'recovery' && !view.resnapshotRequested) {
			if (view.consecutiveResnapshots >= this.#maximumConsecutiveResnapshots) {
				this.#emitRecoveryStatus(view, 'failedRetryable');
				return false;
			}
			view.consecutiveResnapshots += 1;
		}
		if (cause === 'open' || cause === 'requested' || view.resnapshotRequested) {
			view.resnapshotRequested = false;
		}
		this.#emitRecoveryStatus(view, 'recovering', cause === 'open');
		return true;
	}

	recordCertifiedInstall(identity: ViewIdentity): void {
		const candidate = this.#views.get(identity.subscriptionId);
		const view =
			candidate?.handle === identity.handle && candidate.incarnation === identity.incarnation
				? candidate
				: undefined;
		if (view === undefined) return;
		if (identity.scopeRevision >= view.scopeRevision) {
			this.#clearReplacementBeginDeadline(view);
			view.awaitingBegin = false;
		}
		view.consecutiveResnapshots = 0;
		view.resnapshotRequested = false;
		this.#emitRecoveryStatus(view, 'ready');
	}

	recoveryState(subscriptionId: string): BridgeProductViewRecoveryState | null {
		const view = this.#views.get(subscriptionId);
		if (view === undefined) return null;
		return {
			consecutiveResnapshots: view.consecutiveResnapshots,
			status: view.recoveryStatus ?? 'ready',
		};
	}

	failViewsOfKind(kind: ViewKind): void {
		for (const view of this.#views.values()) {
			if (view.subscriptionKind !== kind) continue;
			this.#clearReplacementBeginDeadline(view);
			view.awaitingBegin = false;
			view.consecutiveResnapshots = this.#maximumConsecutiveResnapshots;
			view.resnapshotRequested = false;
			this.#emitRecoveryStatus(view, 'failedRetryable');
		}
	}

	async retryView(subscriptionId: string): Promise<void> {
		const view = this.#views.get(subscriptionId);
		if (view === undefined) return;
		await view.resnapshotInFlight?.catch((): void => {});
		if (this.#views.get(subscriptionId) !== view) return;
		this.#clearReplacementBeginDeadline(view);
		view.awaitingBegin = false;
		view.consecutiveResnapshots = 0;
		view.resnapshotRequested = false;
		this.#emitRecoveryStatus(view, 'recovering', true);
		await this.resnapshot(subscriptionId);
	}

	#armReplacementBeginDeadline(view: DesiredView, domain: string): void {
		this.#clearReplacementBeginDeadline(view);
		const generation = view.replacementBeginDeadlineGeneration;
		view.clearReplacementBeginDeadline = this.#deadlineClock.schedule(
			this.#progressDeadlineMilliseconds,
			(): void => {
				if (
					this.#views.get(view.subscriptionId) !== view ||
					view.replacementBeginDeadlineGeneration !== generation ||
					!view.awaitingBegin
				)
					return;
				this.#clearReplacementBeginDeadline(view);
				view.awaitingBegin = false;
				view.resnapshotRequested = false;
				void this.resnapshot(view.subscriptionId, domain).catch((): void => {});
			},
		);
	}

	#clearReplacementBeginDeadline(view: DesiredView): void {
		view.replacementBeginDeadlineGeneration += 1;
		view.clearReplacementBeginDeadline?.();
		view.clearReplacementBeginDeadline = null;
	}

	#emitRecoveryStatus(
		view: DesiredView,
		status: BridgeWorkerViewRecoveryStatusEvent['status'],
		allowFailedRestart = false,
	): void {
		if (view.recoveryStatus === 'failedRetryable' && status === 'recovering' && !allowFailedRestart)
			return;
		if (view.recoveryStatus === status) return;
		view.recoveryStatus = status;
		this.#onViewRecoveryStatus?.({
			status,
			view: { kind: view.subscriptionKind, subscriptionId: view.subscriptionId },
		});
	}

	#matchingView(identity: ViewIdentity): DesiredView | undefined {
		const view = this.#views.get(identity.subscriptionId);
		return view?.handle === identity.handle &&
			view.incarnation === identity.incarnation &&
			view.scopeRevision === identity.scopeRevision
			? view
			: undefined;
	}

	retire(subscriptionId: string): void {
		const view = this.#views.get(subscriptionId);
		view?.currentAdmission?.abort();
		if (view !== undefined) this.#clearReplacementBeginDeadline(view);
		this.#views.delete(subscriptionId);
		// Released waiters observe retirement and fail, even if the same id registers later.
		this.#settlePendingRegistration(subscriptionId, 'retired');
	}

	#settlePendingRegistration(subscriptionId: string, outcome: ViewRegistrationOutcome): void {
		const pendingRegistration = this.#pendingRegistrations.get(subscriptionId);
		this.#pendingRegistrations.delete(subscriptionId);
		pendingRegistration?.resolve(outcome);
	}
}

function scopeMatchesKind(subscriptionKind: ViewKind, scopeKind: ViewScope['kind']): boolean {
	return (
		(subscriptionKind === 'file.metadata' && scopeKind === 'file') ||
		(subscriptionKind === 'review.metadata' && scopeKind === 'review') ||
		((subscriptionKind === 'file.annotations' || subscriptionKind === 'review.annotations') &&
			scopeKind === 'comment')
	);
}
