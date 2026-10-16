import { BridgeProductBoundedAsyncQueue } from './bridge-product-async-queue.js';
import type {
	BridgeProductResetReason,
	BridgeProductSurface,
} from './bridge-product-contract-primitives.js';
import type { BridgeProductMetadataApplicationProtocol } from './bridge-product-metadata-application-protocol.js';
import {
	BridgeProductControlRequestError,
	type BridgeProductSubscriptionOpenAccepted,
} from './bridge-product-session-authority.js';
import type {
	BridgeProductControlRequest,
	BridgeProductMetadataFrame,
	BridgeProductResyncReconciliationOutcome,
} from './bridge-product-session-contracts.js';
import { BridgeProductSubscriptionFrameFailure } from './bridge-product-subscription-frame-failure.js';

export class BridgeProductSubscriptionResetError extends Error {
	readonly reason: BridgeProductResetReason;

	constructor(reason: BridgeProductResetReason) {
		super(`Bridge product subscription reset: ${reason}.`);
		this.name = 'BridgeProductSubscriptionResetError';
		this.reason = reason;
	}
}

/**
 * Terminal for a subscription retired because its surface advanced to a newer
 * worker derivation epoch. Consumers that still need the data reopen; the
 * replacement admits at the new epoch.
 */
export class BridgeProductSubscriptionEpochRetiredError extends Error {
	readonly nextWorkerDerivationEpoch: number;
	readonly surface: BridgeProductSurface;

	constructor(props: {
		readonly nextWorkerDerivationEpoch: number;
		readonly surface: BridgeProductSurface;
	}) {
		super(
			`Bridge product ${props.surface} subscription retired for worker epoch ${props.nextWorkerDerivationEpoch}.`,
		);
		this.name = 'BridgeProductSubscriptionEpochRetiredError';
		this.nextWorkerDerivationEpoch = props.nextWorkerDerivationEpoch;
		this.surface = props.surface;
	}
}

export type BridgeProductSubscriptionFrame = Extract<
	BridgeProductMetadataFrame,
	{
		readonly kind:
			| 'subscription.accepted'
			| 'subscription.cancelled'
			| 'subscription.end'
			| 'subscription.reset';
	}
>;

export interface BridgeProductSubscriptionFrameSink {
	readonly subscriptionId: string;
	readonly surface: BridgeProductSurface;
	retireBeforeWorkerDerivationEpochAdvance(
		retirement: BridgeProductSubscriptionEpochRetiredError,
	): Promise<void>;
	acceptFrame(frame: BridgeProductSubscriptionFrame): void;
	fail(error: unknown): void;
	reconciliationClaim():
		| Extract<
				BridgeProductControlRequest,
				{ kind: 'workerSession.resync' }
		  >['activeSubscriptions'][number]
		| null;
	applyReconciliation(outcome: BridgeProductResyncReconciliationOutcome): Promise<void>;
}

export interface BridgeProductSubscriptionStateControlMux<
	TKind extends string,
	TOpen extends { readonly subscriptionKind: TKind },
> {
	cancelSubscription(props: {
		readonly subscriptionId: string;
		readonly subscriptionKind: TKind;
		readonly workerDerivationEpoch: number;
	}): Promise<unknown>;
	openSubscription(props: {
		readonly subscription: TOpen;
		readonly subscriptionId: string;
		readonly workerDerivationEpoch: number;
	}): Promise<BridgeProductSubscriptionOpenAccepted>;
}

export interface BridgeProductSubscriptionStateProps<
	TKind extends string,
	TOptions,
	TOpen extends { readonly subscriptionKind: TKind },
> {
	readonly controlMux: BridgeProductSubscriptionStateControlMux<TKind, TOpen>;
	readonly ensureMetadataStream: () => Promise<void>;
	readonly initialOptions: TOptions;
	/**
	 * `drainUntilNativeTerminal` is true when native may still send frames for this
	 * id: it was admitted and native has not ended it. The owner must keep routing
	 * those frames to a drain rather than treating them as unknown.
	 */
	readonly onTerminal: (
		subscriptionId: string,
		error?: unknown,
		drainUntilNativeTerminal?: boolean,
	) => void;
	readonly onOpened?: (
		subscriptionId: string,
		signal: AbortSignal,
		worktreeId: string | null,
	) => Promise<void>;
	readonly protocol: BridgeProductMetadataApplicationProtocol<TKind, TOptions, TOpen>;
	readonly readWorkerDerivationEpochAtAdmission: () => number;
	/**
	 * Waits while the surface retires older-epoch subscriptions, then runs `admit`
	 * with the surface epoch in the same synchronous turn as the final gate check,
	 * so no advance can slip between the check and the admitted request.
	 */
	readonly admitAtWorkerDerivationEpoch?: <TAdmission>(
		admit: (workerDerivationEpoch: number) => TAdmission,
	) => Promise<TAdmission>;
	readonly subscriptionId: string;
}

export class BridgeProductSubscriptionState<
	TKind extends string,
	TOptions,
	TOpen extends { readonly subscriptionKind: TKind },
> implements BridgeProductSubscriptionFrameSink {
	#accepted = false;
	/**
	 * Set once a release (consumer cancel or epoch retirement) is requested. From then
	 * on nothing waits on this subscription's frames, no interests are sent, and
	 * native's remaining frames drain silently until its terminal.
	 */
	#released = false;
	/** Why the release was requested; operations it cut short settle with this. */
	#releaseReason: Error | null = null;
	/** Native ended this subscription (terminal frame or reconciliation). */
	#nativeTerminalObserved = false;
	/** Native refused the open, so it never held this subscription. */
	#openRefusedByNative = false;
	readonly #admitAtWorkerDerivationEpoch: <TAdmission>(
		admit: (workerDerivationEpoch: number) => TAdmission,
	) => Promise<TAdmission>;
	readonly #controlMux: BridgeProductSubscriptionStateProps<TKind, TOptions, TOpen>['controlMux'];
	readonly #ensureMetadataStream: () => Promise<void>;
	readonly #eventQueue = new BridgeProductBoundedAsyncQueue<never>(1);
	#expectedSubscriptionSequence = 0;
	readonly #initialOptions: TOptions;
	readonly #onTerminal: BridgeProductSubscriptionStateProps<TKind, TOptions, TOpen>['onTerminal'];
	readonly #onOpened:
		| ((subscriptionId: string, signal: AbortSignal, worktreeId: string | null) => Promise<void>)
		| undefined;
	readonly #initialScopeAbortController = new AbortController();
	readonly #protocol: BridgeProductMetadataApplicationProtocol<TKind, TOptions, TOpen>;
	readonly #readWorkerDerivationEpochAtAdmission: () => number;
	readonly subscriptionId: string;
	#terminal = false;
	#admittedWorkerDerivationEpoch: number | null = null;

	constructor(props: BridgeProductSubscriptionStateProps<TKind, TOptions, TOpen>) {
		this.#controlMux = props.controlMux;
		this.#ensureMetadataStream = props.ensureMetadataStream;
		this.#initialOptions = props.initialOptions;
		this.#onTerminal = props.onTerminal;
		this.#onOpened = props.onOpened;
		this.#protocol = props.protocol;
		this.#readWorkerDerivationEpochAtAdmission = props.readWorkerDerivationEpochAtAdmission;
		this.#admitAtWorkerDerivationEpoch =
			props.admitAtWorkerDerivationEpoch ??
			(async <TAdmission>(
				admit: (workerDerivationEpoch: number) => TAdmission,
			): Promise<TAdmission> => admit(props.readWorkerDerivationEpochAtAdmission()));
		this.subscriptionId = props.subscriptionId;
	}

	get publicSubscription(): {
		readonly events: AsyncIterable<never>;
		readonly subscriptionId: string;
		readonly subscriptionKind: TKind;
		cancel(): Promise<void>;
	} {
		return {
			cancel: (): Promise<void> => this.cancel(),
			events: this.#eventQueue,
			subscriptionId: this.subscriptionId,
			subscriptionKind: this.#protocol.kind,
		};
	}

	/** Settles once the initial open has finished: opened, released, or failed. */
	start(): Promise<void> {
		return this.#initialize().catch((error: unknown): void => {
			this.fail(error);
		});
	}

	get surface(): BridgeProductSurface {
		return this.#protocol.surface;
	}

	/**
	 * Retires local state before the surface advances. An admitted open queues its
	 * native cancel escape before the next epoch is published, but the advance
	 * never waits for the escape reply. An unadmitted open remains eligible at the
	 * new epoch.
	 */
	retireBeforeWorkerDerivationEpochAdvance(
		retirement: BridgeProductSubscriptionEpochRetiredError,
	): Promise<void> {
		const admittedEpoch = this.#admittedWorkerDerivationEpoch;
		if (
			this.#terminal ||
			admittedEpoch === null ||
			admittedEpoch >= retirement.nextWorkerDerivationEpoch
		) {
			return Promise.resolve();
		}
		this.#queueRelease(retirement);
		return Promise.resolve();
	}

	/**
	 * Local cancellation settles immediately. The native escape is queued after
	 * any already queued open admission, independently of its result.
	 */
	cancel(): Promise<void> {
		this.#queueRelease(new Error('Bridge product subscription was cancelled.'));
		return Promise.resolve();
	}

	acceptFrame(frame: BridgeProductSubscriptionFrame): void {
		if (this.#terminal && this.#released) return;
		if (this.#terminal) {
			throw new BridgeProductSubscriptionFrameFailure(
				'subscription_post_terminal',
				'Bridge product subscription received a post-terminal frame.',
			);
		}
		if (
			frame.subscriptionId !== this.subscriptionId ||
			frame.subscriptionKind !== this.#protocol.kind ||
			frame.workerDerivationEpoch !== this.#admittedWorkerDerivationEpoch
		) {
			throw new BridgeProductSubscriptionFrameFailure(
				'subscription_identity_mismatch',
				'Bridge product subscription frame identity does not match its admission.',
			);
		}
		if (frame.subscriptionSequence !== this.#expectedSubscriptionSequence) {
			throw new BridgeProductSubscriptionFrameFailure(
				'subscription_sequence_mismatch',
				'Bridge product subscription sequence is not contiguous.',
			);
		}
		if (!this.#accepted) {
			if (frame.kind !== 'subscription.accepted' || frame.subscriptionSequence !== 0) {
				throw new BridgeProductSubscriptionFrameFailure(
					'subscription_acceptance_required',
					'Bridge product subscription requires accepted sequence zero.',
				);
			}
			this.#accepted = true;
			this.#expectedSubscriptionSequence = 1;
			return;
		}
		if (frame.kind === 'subscription.accepted') {
			throw new BridgeProductSubscriptionFrameFailure(
				'subscription_duplicate_acceptance',
				'Bridge product subscription cannot accept twice.',
			);
		}
		this.#expectedSubscriptionSequence += 1;
		this.#acceptPostAdmissionFrame(frame);
	}

	fail(error: unknown): void {
		if (this.#terminal) return;
		this.#terminal = true;
		// An operation cut short by this subscription's own release ends it cleanly:
		// the consumer already has its terminal and native's frames still drain.
		const endedByRelease = error === this.#releaseReason;
		if (endedByRelease && !(error instanceof BridgeProductSubscriptionEpochRetiredError)) {
			this.#eventQueue.close(true);
		} else {
			this.#eventQueue.fail(error, true);
		}
		this.#onTerminal(
			this.subscriptionId,
			endedByRelease ? undefined : error,
			this.#nativeMayStillServe(),
		);
	}

	reconciliationClaim():
		| Extract<
				BridgeProductControlRequest,
				{ kind: 'workerSession.resync' }
		  >['activeSubscriptions'][number]
		| null {
		if (this.#terminal || this.#admittedWorkerDerivationEpoch === null) {
			return null;
		}
		return {
			subscriptionId: this.subscriptionId,
			subscriptionKind: this.#protocol.kind,
			// Ask native whether the old ID can serve the current surface. Its
			// reconciliation may require a new ID; never retag admitted frames.
			workerDerivationEpoch: this.#readWorkerDerivationEpochAtAdmission(),
		};
	}

	async applyReconciliation(outcome: BridgeProductResyncReconciliationOutcome): Promise<void> {
		if (
			outcome.subscriptionId !== this.subscriptionId ||
			outcome.subscriptionKind !== this.#protocol.kind
		) {
			throw new Error('Bridge product reconciliation references the wrong subscription.');
		}
		if (this.#released) {
			this.#retire();
			return;
		}
		switch (outcome.disposition) {
			case 'retained':
				return;
			case 'cancelled':
				this.#retire();
				return;
			case 'reopenRequired':
				if (
					(outcome.reason === 'epoch_advanced' || outcome.reason === 'native_missing') &&
					this.#admittedWorkerDerivationEpoch !== null &&
					outcome.requiredWorkerDerivationEpoch > this.#admittedWorkerDerivationEpoch
				) {
					// Native's surface floor passed this subscription's epoch.
					this.#retireForSurfaceEpoch(outcome.requiredWorkerDerivationEpoch);
					return;
				}
				this.#nativeTerminalObserved = true;
				this.fail(new BridgeProductSubscriptionResetError('snapshot_required'));
				return;
		}
	}

	#acceptPostAdmissionFrame(
		frame: Exclude<BridgeProductSubscriptionFrame, { readonly kind: 'subscription.accepted' }>,
	): void {
		switch (frame.kind) {
			case 'subscription.cancelled':
			case 'subscription.end':
				this.#retire();
				return;
			case 'subscription.reset':
				if (frame.reason === 'epoch_retired') {
					// Native's surface floor passed this subscription's epoch before the
					// worker's own release ran; the worker already serves a newer one.
					this.#retireForSurfaceEpoch(this.#readWorkerDerivationEpochAtAdmission());
					return;
				}
				this.#nativeTerminalObserved = true;
				this.fail(new BridgeProductSubscriptionResetError(frame.reason));
				return;
		}
	}

	async #initialize(): Promise<void> {
		await this.#ensureMetadataStream();
		if (this.#released) return;
		const initialOptions = this.#protocol.optionsSchema.parse(this.#initialOptions);
		const subscription = this.#protocol.openSchema.parse(
			this.#protocol.initialOpen(initialOptions),
		);
		// Admission records the epoch and queues the open control in one synchronous
		// turn, so a later surface advance always sees this admission and sequences
		// its release after the open.
		let openAccepted: BridgeProductSubscriptionOpenAccepted;
		try {
			openAccepted = await this.#admitAtWorkerDerivationEpoch((workerDerivationEpoch) => {
				if (this.#released) throw this.#releaseReason;
				this.#admittedWorkerDerivationEpoch = workerDerivationEpoch;
				return this.#controlMux.openSubscription({
					subscription,
					subscriptionId: this.subscriptionId,
					workerDerivationEpoch,
				});
			});
		} catch (error) {
			if (error instanceof BridgeProductControlRequestError) this.#openRefusedByNative = true;
			throw error;
		}
		// A subscription that ended while its open was in flight must not open a view.
		if (this.#released || this.#terminal) return;
		if (this.#onOpened !== undefined) {
			await this.#onOpened(
				this.subscriptionId,
				this.#initialScopeAbortController.signal,
				'worktreeId' in openAccepted ? openAccepted.worktreeId : null,
			);
		}
	}

	/** Locally retires at once, while the single native escape runs in the background. */
	#queueRelease(reason: Error): void {
		if (this.#released) return;
		this.#markReleased(reason);
		if (this.#nativeMayStillServe()) {
			void this.#releaseNativeSubscription().catch((): void => {});
		}
		this.fail(reason);
	}

	#markReleased(reason: Error): void {
		if (this.#released) return;
		this.#released = true;
		this.#releaseReason = reason;
		this.#initialScopeAbortController.abort(reason);
	}

	/**
	 * Sends the cancel control. A native refusal is not a failure of this
	 * subscription: native either refused a stale epoch after its surface floor
	 * advanced (it then ends the subscription itself with an `epoch_retired`
	 * reset) or had already ended it with a terminal frame still in flight. Either
	 * way the subscription stays released and drains until that terminal.
	 */
	async #releaseNativeSubscription(): Promise<void> {
		try {
			await this.#controlMux.cancelSubscription({
				subscriptionId: this.subscriptionId,
				subscriptionKind: this.#protocol.kind,
				workerDerivationEpoch: this.#requiredAdmittedWorkerDerivationEpoch(),
			});
		} catch (error) {
			if (error instanceof BridgeProductControlRequestError) return;
			throw error;
		}
	}

	/** Native may still send frames: admitted, and native has not ended it. */
	#nativeMayStillServe(): boolean {
		return (
			this.#admittedWorkerDerivationEpoch !== null &&
			!this.#nativeTerminalObserved &&
			!this.#openRefusedByNative
		);
	}

	/** Native ended this subscription because its surface moved past its epoch. */
	#retireForSurfaceEpoch(nextWorkerDerivationEpoch: number): void {
		const retirement = new BridgeProductSubscriptionEpochRetiredError({
			nextWorkerDerivationEpoch,
			surface: this.#protocol.surface,
		});
		this.#eventQueue.fail(retirement, true);
		this.#retire(retirement);
	}

	/** Native ended this subscription. */
	#retire(_waiterError: unknown = new Error('Bridge product subscription terminated.')): void {
		if (this.#terminal) return;
		this.#nativeTerminalObserved = true;
		this.#terminal = true;
		this.#eventQueue.close(true);
		this.#onTerminal(this.subscriptionId);
	}

	#requiredAdmittedWorkerDerivationEpoch(): number {
		if (this.#admittedWorkerDerivationEpoch === null) {
			throw new Error('Bridge product subscription operation preceded its admission epoch.');
		}
		return this.#admittedWorkerDerivationEpoch;
	}
}
