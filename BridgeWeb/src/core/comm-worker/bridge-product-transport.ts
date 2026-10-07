import { uuidv7 } from 'uuidv7';

import {
	createBridgeProductDeferred,
	type BridgeProductDeferred,
} from './bridge-product-async-queue.js';
import { installBridgeProductBatchDelivery } from './bridge-product-batch-delivery.js';
import {
	BridgeProductBatchFrameRouter,
	type BridgeProductBatchFrameSinks,
} from './bridge-product-batch-frame-router.js';
import type {
	BridgeProductCallKind,
	BridgeProductCallRequest,
	BridgeProductCallResult,
} from './bridge-product-call-contracts.js';
import { bridgeProductSurfaceForCallKind } from './bridge-product-call-contracts.js';
import {
	bridgeProductContentDescriptorSchema,
	bridgeProductContentRequestSchema,
	bridgeProductSurfaceForContentKind,
	type BridgeProductContentDescriptor,
	type BridgeProductContentKind,
	type BridgeProductContentRequestFor,
} from './bridge-product-content-contracts.js';
import { BridgeProductContentResponseAdmission } from './bridge-product-content-response-admission.js';
import { readBridgeProductContentResponse } from './bridge-product-content-response-reader.js';
import { openBridgeProductContentStream } from './bridge-product-content-stream-opening.js';
import { type BridgeProductSurface } from './bridge-product-contract-primitives.js';
import {
	defaultBridgeProductDeadlineClock,
	type BridgeProductDeadlineClock,
} from './bridge-product-deadline-clock.js';
import { awaitBridgeProductFiniteProgress } from './bridge-product-finite-progress-deadline.js';
import {
	bridgeProductFrameAcknowledgementRequestSchema,
	type BridgeProductFrameAcknowledgementRequest,
} from './bridge-product-frame-acknowledgement-contracts.js';
import { sendBridgeProductFrameAcknowledgement } from './bridge-product-frame-acknowledgement.js';
import type {
	BridgeProductMetadataApplicationProtocol,
	BridgeProductMetadataApplicationRegistry,
} from './bridge-product-metadata-application-protocol.js';
import {
	BridgeProductMetadataRouteFailure,
	bridgeProductMetadataRouteFailure,
	type BridgeProductMetadataRouteFailureCode,
} from './bridge-product-metadata-route-failure.js';
import { BridgeProductMetadataStreamDecoder } from './bridge-product-metadata-stream-decoder.js';
import {
	captureBridgeProductMetadataStreamHealth,
	createBridgeProductMetadataStreamHealthDiagnostics,
	isolatedBridgeProductMetadataStreamHealthSink,
	type BridgeProductMetadataStreamHealthSink,
	type BridgeProductMetadataStreamHealthDiagnostics,
	type BridgeProductMetadataStreamLifecycleObservation,
	type BridgeProductMetadataStreamFailureStage,
} from './bridge-product-metadata-stream-health-diagnostics.js';
import { BridgeProductReadAhead } from './bridge-product-read-ahead.js';
import { encodeBridgeProductRequestBody } from './bridge-product-request-body.js';
import type { BridgeProductRequestExecutor } from './bridge-product-request-executor.js';
import {
	BridgeProductControlRequestError,
	type BridgeProductControlMux,
	type BridgeProductSessionAuthority,
} from './bridge-product-session-authority.js';
import {
	bridgeProductMetadataStreamRequestSchema,
	type BridgeProductMetadataFrame,
	type BridgeProductMetadataStreamRequest,
} from './bridge-product-session-contracts.js';
import {
	BridgeProductSubscriptionFrameFailure,
	bridgeProductSubscriptionOperationFailureCode,
} from './bridge-product-subscription-frame-failure.js';
import {
	BridgeProductSubscriptionEpochRetiredError,
	BridgeProductSubscriptionState,
	type BridgeProductSubscriptionFrameSink,
} from './bridge-product-subscription-state.js';
import { BridgeProductSurfaceEpochAuthority } from './bridge-product-surface-epoch-authority.js';
import type {
	BridgeProductCallOptions,
	BridgeProductContentStream,
	BridgeProductTransport,
} from './bridge-product-transport-contract.js';
import {
	ignoreBridgeProductPanePresentationFrame,
	ignoreBridgeProductPaneSurfaceSelectionFrame,
} from './bridge-product-transport-default-sinks.js';
import type { ViewResnapshotAdmissionProps } from './bridge-product-view-control-admission.js';
import type { BridgeProductViewScopeRequest } from './bridge-product-view-control-wire-contracts.js';
import { bridgeProductInitialViewOpening } from './bridge-product-view-opening.js';
import type { BridgeProductViewReceiptAcknowledger } from './bridge-product-view-receipt-acknowledger.js';
import { BridgeProductViewScopeOwner } from './bridge-product-view-scope-owner.js';
import type { BridgeProductViewScopeSettlement } from './bridge-product-view-scope-owner.js';
import { bridgeWorkerViewRecoveryKindSchema } from './bridge-worker-view-recovery-contracts.js';

export type BridgeProductIdentifierPurpose =
	| 'content-request'
	| 'lease'
	| 'metadata-stream'
	| 'subscription';

type BridgeProductCallArguments = {
	[TCallKind in BridgeProductCallKind]: readonly [
		method: TCallKind,
		request: BridgeProductCallRequest<TCallKind>,
		options?: BridgeProductCallOptions,
	];
}[BridgeProductCallKind];

export interface CreateBridgeProductTransportProps {
	readonly authority: BridgeProductSessionAuthority;
	readonly controlMux: Pick<
		BridgeProductControlMux,
		| 'call'
		| 'cancelSubscription'
		| 'openSubscription'
		| 'resnapshotView'
		| 'resync'
		| 'setViewScope'
	>;
	readonly createIdentifier?: (purpose: BridgeProductIdentifierPurpose) => string;
	readonly executeProductRequest: BridgeProductRequestExecutor;
	readonly deadlineClock?: BridgeProductDeadlineClock;
	readonly initialWorkerDerivationEpochs?: Readonly<Partial<Record<BridgeProductSurface, number>>>;
	readonly maximumConcurrentContentResponses?: number;
	readonly metadataApplicationRegistry: BridgeProductMetadataApplicationRegistry;
	readonly onViewRecoveryStatus?: ConstructorParameters<
		typeof BridgeProductViewScopeOwner
	>[0]['onViewRecoveryStatus'];
}

type ViewRecoveryStatus = Parameters<
	NonNullable<CreateBridgeProductTransportProps['onViewRecoveryStatus']>
>[0];

export interface BridgeProductTransportSession extends BridgeProductTransport {
	readonly metadataReopenPolicy: Pick<
		BridgeProductSessionAuthority['bootstrap']['policy'],
		'viewMaximumConsecutiveResnapshots'
	>;
	reportMetadataReopenExhausted(kind: 'file.metadata' | 'review.metadata'): void;
	setViewScopeForSubscription?(props: {
		readonly scope: BridgeProductViewScopeRequest['scope'];
		readonly subscriptionId: string;
	}): Promise<BridgeProductViewScopeSettlement>;
	setBatchFrameSinks?(sinks: BridgeProductBatchFrameSinks): void;
	resnapshotView?(props: ViewResnapshotAdmissionProps): Promise<void>;
	resnapshotLatestView?(subscriptionId: string, domain: string): Promise<void>;
	retryView?(subscriptionId: string): Promise<void>;
	failReviewRender?(): void;
	failFileRender?(): void;
	/**
	 * Advances the surface to a new worker derivation epoch and returns it. Every
	 * subscription admitted on that surface at an older epoch ends for its consumer
	 * with `BridgeProductSubscriptionEpochRetiredError` and is released: its cancel
	 * is sent at its own epoch, because native refuses stale-epoch controls once its
	 * surface floor advances. Admissions and calls on the surface wait only for
	 * native's cancel acknowledgements, never for a frame. Content opens are not
	 * held; one at the new epoch may advance native's floor first, in which case
	 * native ends the older subscriptions itself with an `epoch_retired` reset.
	 */
	advanceWorkerDerivationEpoch(surface: BridgeProductSurface): number;
	metadataStreamDiagnostics?(): BridgeProductMetadataStreamHealthDiagnostics;
	setMetadataStreamHealthSink?(sink: BridgeProductMetadataStreamHealthSink): void;
	setPanePresentationFrameSink?(sink: (frame: BridgeProductPanePresentationFrame) => void): void;
	setPaneSurfaceSelectionFrameSink?(
		sink: (frame: BridgeProductPaneSurfaceSelectionFrame) => void,
	): void;
	workerDerivationEpoch(surface: BridgeProductSurface): number;
}

export type BridgeProductPanePresentationFrame = Extract<
	BridgeProductMetadataFrame,
	{ readonly kind: 'pane.presentation' }
>;

export type BridgeProductPaneSurfaceSelectionFrame = Extract<
	BridgeProductMetadataFrame,
	{ readonly kind: 'pane.surfaceSelectionRequested' }
>;

export type {
	BridgeProductMetadataStreamHealthDiagnostics,
	BridgeProductMetadataStreamFailureStage,
	BridgeProductMetadataStreamLifecycleState,
} from './bridge-product-metadata-stream-health-diagnostics.js';
export type { BridgeProductMetadataRouteFailureCode } from './bridge-product-metadata-route-failure.js';

export function createBridgeProductTransport(
	props: CreateBridgeProductTransportProps,
): BridgeProductTransportSession {
	return new BridgeProductTransportSessionImpl(props);
}

class BridgeProductTransportSessionImpl implements BridgeProductTransportSession {
	readonly #authority: BridgeProductSessionAuthority;
	readonly #contentResponseAdmission: BridgeProductContentResponseAdmission;
	readonly #controlMux: CreateBridgeProductTransportProps['controlMux'];
	readonly #createIdentifier: (purpose: BridgeProductIdentifierPurpose) => string;
	readonly #epochAuthority: BridgeProductSurfaceEpochAuthority;
	/**
	 * Ids the worker ended locally while native may still send their frames. They
	 * drain until native's terminal instead of failing the shared stream.
	 */
	readonly #drainingSubscriptionIds = new Set<string>();
	readonly #executeProductRequest: BridgeProductRequestExecutor;
	readonly #deadlineClock: BridgeProductDeadlineClock;
	readonly #metadataApplicationRegistry: BridgeProductMetadataApplicationRegistry;
	readonly #frameAcknowledgementTimeoutMilliseconds: number;
	#metadataStreamHealthSink: BridgeProductMetadataStreamHealthSink | null = null;
	#metadataResponseStatus: number | null = null;
	#metadataReady: BridgeProductDeferred<void> | null = null;
	#physicalMetadataReady: BridgeProductDeferred<void> | null = null;
	#metadataRecoveryInFlight = false;
	#lastRoutedStreamSequence: number | null = null;
	#metadataRecoveryAttemptedSinceProgress = false;
	#metadataStreamHealthDiagnostics = createBridgeProductMetadataStreamHealthDiagnostics();
	readonly #subscriptions = new Map<string, BridgeProductSubscriptionFrameSink>();
	readonly #batchFrameRouter: BridgeProductBatchFrameRouter;
	#viewReceiptAcknowledger: BridgeProductViewReceiptAcknowledger | null = null;
	readonly #viewScopeOwner: BridgeProductViewScopeOwner;
	readonly #onViewRecoveryStatus: CreateBridgeProductTransportProps['onViewRecoveryStatus'];
	readonly #viewRecoveryStatusByKind = new Map<string, ViewRecoveryStatus>();
	#panePresentationFrameSink: (frame: BridgeProductPanePresentationFrame) => void =
		ignoreBridgeProductPanePresentationFrame;
	#paneSurfaceSelectionFrameSink: (frame: BridgeProductPaneSurfaceSelectionFrame) => void =
		ignoreBridgeProductPaneSurfaceSelectionFrame;

	constructor(props: CreateBridgeProductTransportProps) {
		this.#authority = props.authority;
		this.#controlMux = props.controlMux;
		this.#createIdentifier =
			props.createIdentifier ?? ((purpose): string => `${purpose}-${uuidv7()}`);
		this.#deadlineClock = props.deadlineClock ?? defaultBridgeProductDeadlineClock;
		this.#onViewRecoveryStatus = props.onViewRecoveryStatus;
		this.#viewScopeOwner = new BridgeProductViewScopeOwner({
			controlMux: props.controlMux,
			createIdentifier: (): string => this.#createIdentifier('subscription'),
			deadlineClock: this.#deadlineClock,
			maximumConsecutiveResnapshots:
				props.authority.bootstrap.policy.viewMaximumConsecutiveResnapshots,
			progressDeadlineMilliseconds:
				props.authority.bootstrap.policy.viewBatchProgressDeadlineMilliseconds,
			onViewRecoveryStatus: (status): void => this.#publishViewRecoveryStatus(status),
		});
		this.#executeProductRequest = props.executeProductRequest;
		this.#batchFrameRouter = new BridgeProductBatchFrameRouter({
			deadlineClock: this.#deadlineClock,
			progressDeadlineMilliseconds:
				props.authority.bootstrap.policy.viewBatchProgressDeadlineMilliseconds,
		});
		this.#metadataApplicationRegistry = props.metadataApplicationRegistry;
		this.#frameAcknowledgementTimeoutMilliseconds =
			props.authority.bootstrap.policy.contentAcknowledgementDeadlineMilliseconds;
		if (
			!Number.isSafeInteger(this.#frameAcknowledgementTimeoutMilliseconds) ||
			this.#frameAcknowledgementTimeoutMilliseconds <= 0
		) {
			throw new Error('Bridge frame acknowledgement timeout must be a positive safe integer.');
		}
		this.#contentResponseAdmission = new BridgeProductContentResponseAdmission(
			props.maximumConcurrentContentResponses,
		);
		this.#epochAuthority = new BridgeProductSurfaceEpochAuthority(
			props.initialWorkerDerivationEpochs,
		);
	}

	advanceWorkerDerivationEpoch(surface: BridgeProductSurface): number {
		return this.#epochAuthority.advance(surface, (nextEpoch): readonly Promise<void>[] => {
			const retirement = new BridgeProductSubscriptionEpochRetiredError({
				nextWorkerDerivationEpoch: nextEpoch,
				surface,
			});
			return [...this.#subscriptions.values()]
				.filter((subscription): boolean => subscription.surface === surface)
				.map(
					(subscription): Promise<void> =>
						subscription.retireBeforeWorkerDerivationEpochAdvance(retirement),
				);
		});
	}

	metadataStreamDiagnostics(): BridgeProductMetadataStreamHealthDiagnostics {
		return Object.freeze({
			...this.#metadataStreamHealthDiagnostics,
			activeSubscriptionCount: this.#subscriptions.size,
		});
	}

	setMetadataStreamHealthSink(sink: BridgeProductMetadataStreamHealthSink): void {
		this.#metadataStreamHealthSink = isolatedBridgeProductMetadataStreamHealthSink(sink);
	}

	#publishMetadataStreamTransition(
		transition: BridgeProductMetadataStreamLifecycleObservation['transition'],
	): void {
		this.#metadataStreamHealthSink?.({
			transition,
			responseStatus: this.#metadataResponseStatus,
			diagnostics: this.metadataStreamDiagnostics(),
		});
	}

	setPanePresentationFrameSink(sink: (frame: BridgeProductPanePresentationFrame) => void): void {
		this.#panePresentationFrameSink = sink;
	}

	setBatchFrameSinks(sinks: BridgeProductBatchFrameSinks): void {
		this.#viewReceiptAcknowledger?.close();
		this.#viewReceiptAcknowledger = installBridgeProductBatchDelivery({
			authority: this.#authority,
			deadlineClock: this.#deadlineClock,
			executeProductRequest: this.#executeProductRequest,
			router: this.#batchFrameRouter,
			sinks: {
				...sinks,
				subscriptionRetired: (subscriptionId): void => {
					this.#viewReceiptAcknowledger?.retireSubscription(subscriptionId);
					sinks.subscriptionRetired?.(subscriptionId);
				},
				install: async (installation): Promise<void> => {
					await sinks.install(installation);
					if (installation.begin.mode !== 'snapshot') return;
					this.#viewScopeOwner.recordCertifiedInstall(installation.begin);
					this.#metadataRecoveryAttemptedSinceProgress = false;
					sinks.certifiedInstallCompleted?.(installation.begin);
				},
				replacementSnapshot: (frame): void => {
					this.#viewScopeOwner.observeReplacementSnapshot(frame);
					sinks.replacementSnapshot?.(frame);
				},
			},
		});
	}

	resnapshotView(props: ViewResnapshotAdmissionProps): Promise<void> {
		return this.#viewScopeOwner.requestResnapshot(props);
	}

	resnapshotLatestView(subscriptionId: string, domain: string): Promise<void> {
		return this.#viewScopeOwner.resnapshot(subscriptionId, domain);
	}

	retryView(subscriptionId: string): Promise<void> {
		if (this.#viewScopeOwner.recoveryState(subscriptionId) === null) {
			const previous = [...this.#viewRecoveryStatusByKind.values()].find(
				(status) => status.view.subscriptionId === subscriptionId,
			);
			if (previous !== undefined) {
				// The E3 ended, but its surface still owns a user-visible recovery attempt.
				this.#publishViewRecoveryStatus({ ...previous, status: 'recovering' });
			}
			return Promise.resolve();
		}
		return this.#viewScopeOwner.retryView(subscriptionId);
	}

	get metadataReopenPolicy(): BridgeProductTransportSession['metadataReopenPolicy'] {
		return this.#authority.bootstrap.policy;
	}

	reportMetadataReopenExhausted(kind: 'file.metadata' | 'review.metadata'): void {
		const previous = this.#viewRecoveryStatusByKind.get(kind);
		if (previous !== undefined)
			this.#publishViewRecoveryStatus({ ...previous, status: 'failedRetryable' });
	}

	#publishViewRecoveryStatus(status: ViewRecoveryStatus): void {
		this.#viewRecoveryStatusByKind.set(status.view.kind, status);
		this.#onViewRecoveryStatus?.(status);
	}

	failReviewRender(): void {
		this.#viewScopeOwner.failViewsOfKind('review.metadata');
	}

	failFileRender(): void {
		this.#viewScopeOwner.failViewsOfKind('file.metadata');
	}

	async setViewScopeForSubscription(props: {
		readonly scope: BridgeProductViewScopeRequest['scope'];
		readonly subscriptionId: string;
	}): Promise<BridgeProductViewScopeSettlement> {
		const settlement = await this.#viewScopeOwner.setScope(props);
		if (settlement.kind === 'accepted') {
			this.#batchFrameRouter.acceptScope({
				scope: props.scope,
				scopeRevision: settlement.scopeRevision,
				subscriptionId: props.subscriptionId,
			});
		}
		return settlement;
	}

	setPaneSurfaceSelectionFrameSink(
		sink: (frame: BridgeProductPaneSurfaceSelectionFrame) => void,
	): void {
		this.#paneSurfaceSelectionFrameSink = sink;
	}

	workerDerivationEpoch(surface: BridgeProductSurface): number {
		return this.#epochAuthority.current(surface);
	}

	async call<TCallArguments extends BridgeProductCallArguments>(
		...arguments_: TCallArguments
	): Promise<BridgeProductCallResult<TCallArguments[0]>> {
		const [method, request, options] = arguments_;
		const surface = bridgeProductSurfaceForCallKind(method);
		return await this.#epochAuthority.admitAt(
			surface,
			(workerDerivationEpoch): Promise<BridgeProductCallResult<TCallArguments[0]>> =>
				this.#controlMux.call({
					method,
					request,
					...(options?.signal === undefined ? {} : { signal: options.signal }),
					workerDerivationEpoch,
				}),
		);
	}

	openContent<TContentKind extends BridgeProductContentKind>(
		descriptor: BridgeProductContentDescriptor<TContentKind>,
		abortSignal: AbortSignal,
		operationCorrelationId?: string | null,
	): BridgeProductContentStream<TContentKind>;
	openContent(
		descriptor: BridgeProductContentDescriptor<BridgeProductContentKind>,
		abortSignal: AbortSignal,
		operationCorrelationId: string | null = null,
	): BridgeProductContentStream<BridgeProductContentKind> {
		const parsedDescriptor = bridgeProductContentDescriptorSchema.parse(descriptor);
		const contentRequestId = this.#createIdentifier('content-request');
		const request = bridgeProductContentRequestSchema.parse({
			contentKind: parsedDescriptor.contentKind,
			contentRequestId,
			descriptor: parsedDescriptor,
			kind: 'content.open',
			leaseId: this.#createIdentifier('lease'),
			operationCorrelationId,
			paneSessionId: this.#authority.bootstrap.paneSessionId,
			wireVersion: this.#authority.bootstrap.wireVersion,
			workerDerivationEpoch: this.workerDerivationEpoch(
				bridgeProductSurfaceForContentKind(parsedDescriptor.contentKind, parsedDescriptor),
			),
			workerInstanceId: this.#authority.bootstrap.workerInstanceId,
		});
		return this.#openValidatedContent(request, abortSignal);
	}

	subscribe<TKind extends string, TOptions, TOpen extends { readonly subscriptionKind: TKind }>(
		protocol: BridgeProductMetadataApplicationProtocol<TKind, TOptions, TOpen>,
		options: TOptions,
	): {
		readonly events: AsyncIterable<never>;
		readonly subscriptionId: string;
		readonly subscriptionKind: TKind;
		cancel(): Promise<void>;
	} {
		this.#metadataApplicationRegistry.requireProtocol(protocol);
		const state = this.#createSubscriptionState(protocol, options);
		this.#subscriptions.set(state.subscriptionId, state);
		const recoveryKind = bridgeWorkerViewRecoveryKindSchema.safeParse(protocol.kind);
		if (recoveryKind.success) {
			this.#viewScopeOwner.allocatePendingRegistration(state.subscriptionId);
			const previous = this.#viewRecoveryStatusByKind.get(protocol.kind);
			const allocated: ViewRecoveryStatus = {
				status: 'recovering',
				view: { kind: recoveryKind.data, subscriptionId: state.subscriptionId },
			};
			// Keep a first E3 actionable on failure without changing initial-load UI.
			this.#viewRecoveryStatusByKind.set(protocol.kind, allocated);
			if (previous !== undefined && previous.status !== 'ready')
				this.#publishViewRecoveryStatus(allocated);
		}
		state.start();
		return state.publicSubscription;
	}

	#createSubscriptionState<
		TKind extends string,
		TOptions,
		TOpen extends { readonly subscriptionKind: TKind },
	>(
		protocol: BridgeProductMetadataApplicationProtocol<TKind, TOptions, TOpen>,
		options: TOptions,
	): BridgeProductSubscriptionState<TKind, TOptions, TOpen> {
		const onOpened = bridgeProductInitialViewOpening(this.#viewScopeOwner, protocol.kind);
		return new BridgeProductSubscriptionState<TKind, TOptions, TOpen>({
			controlMux: this.#controlMux,
			ensureMetadataStream: (): Promise<void> => this.#ensureMetadataStream(),
			initialOptions: options,
			...(onOpened === undefined ? {} : { onOpened }),
			onTerminal: (subscriptionId, error, drainUntilNativeTerminal): void => {
				const recovery = this.#viewRecoveryStatusByKind.get(protocol.kind);
				if (
					error !== undefined &&
					recovery?.status === 'recovering' &&
					recovery.view.subscriptionId === subscriptionId
				) {
					// A first open or user reopen can fail before W2 registration.
					this.#publishViewRecoveryStatus({ ...recovery, status: 'failedRetryable' });
				}
				this.#viewScopeOwner.retire(subscriptionId);
				if (
					error !== undefined &&
					this.#metadataStreamHealthDiagnostics.lifecycleState === 'reading' &&
					this.#metadataStreamHealthDiagnostics.routeFailureCode === null
				) {
					this.#metadataStreamHealthDiagnostics = {
						...this.#metadataStreamHealthDiagnostics,
						routeFailureCode:
							error instanceof BridgeProductControlRequestError
								? `subscription_control_${error.code}`
								: bridgeProductSubscriptionOperationFailureCode(error),
					};
				}
				this.#subscriptions.delete(subscriptionId);
				this.#batchFrameRouter.retireSubscription(subscriptionId);
				if (drainUntilNativeTerminal === true) this.#drainingSubscriptionIds.add(subscriptionId);
				if (this.#metadataStreamHealthDiagnostics.lifecycleState === 'reading') {
					this.#metadataStreamHealthDiagnostics = {
						...this.#metadataStreamHealthDiagnostics,
						lastSubscriptionTermination: {
							subscriptionId,
							outcome: error === undefined ? 'terminal' : 'failed',
							reason: this.#metadataStreamHealthDiagnostics.routeFailureCode,
						},
					};
				}
			},
			protocol,
			readWorkerDerivationEpochAtAdmission: (): number =>
				this.workerDerivationEpoch(protocol.surface),
			admitAtWorkerDerivationEpoch: <TAdmission>(
				admit: (workerDerivationEpoch: number) => TAdmission,
			): Promise<TAdmission> => this.#epochAuthority.admitAt(protocol.surface, admit),
			subscriptionId: this.#createIdentifier('subscription'),
		});
	}

	#ensureMetadataStream(): Promise<void> {
		if (this.#metadataReady !== null) {
			return this.#metadataReady.promise;
		}
		return this.#openMetadataStream(null);
	}

	#openMetadataStream(resumeFromStreamSequence: number | null): Promise<void> {
		const request = bridgeProductMetadataStreamRequestSchema.parse({
			kind: 'metadataStream.open',
			metadataStreamId: this.#createIdentifier('metadata-stream'),
			paneSessionId: this.#authority.bootstrap.paneSessionId,
			resumeFromStreamSequence,
			wireVersion: this.#authority.bootstrap.wireVersion,
			workerInstanceId: this.#authority.bootstrap.workerInstanceId,
		});
		const ready = createBridgeProductDeferred<void>();
		this.#physicalMetadataReady = ready;
		if (this.#metadataReady === null) this.#metadataReady = ready;
		const readTask = this.#readMetadataStream(request);
		void readTask.catch((error: unknown): void => {
			if (this.#physicalMetadataReady !== ready) return;
			this.#physicalMetadataReady = null;
			if (!this.#metadataRecoveryInFlight) {
				this.#metadataReady = null;
			}
			ready.reject(error);
			if (
				!this.#metadataRecoveryInFlight &&
				this.#lastRoutedStreamSequence !== null &&
				(this.#metadataStreamHealthDiagnostics.failureStage === 'read' ||
					this.#metadataStreamHealthDiagnostics.failureStage === 'unexpectedEof' ||
					(this.#metadataStreamHealthDiagnostics.failureStage === 'finish' &&
						this.#metadataStreamHealthDiagnostics.failureCode === 'truncated_frame')) &&
				this.#subscriptions.size > 0 &&
				!this.#metadataRecoveryAttemptedSinceProgress
			) {
				void this.#recoverMetadataStream().catch((recoveryError: unknown): void => {
					this.#poisonMetadataSession(recoveryError);
				});
				return;
			}
			this.#poisonMetadataSession(error);
		});
		return ready.promise;
	}

	async #recoverMetadataStream(): Promise<void> {
		const lastRoutedStreamSequence = this.#lastRoutedStreamSequence;
		if (lastRoutedStreamSequence === null) {
			throw new Error('Metadata reconciliation requires a received stream cursor.');
		}
		this.#publishMetadataStreamTransition('restartScheduled');
		this.#metadataRecoveryInFlight = true;
		const recoveryReady = createBridgeProductDeferred<void>();
		void recoveryReady.promise.catch((): void => {});
		this.#metadataRecoveryAttemptedSinceProgress = true;
		this.#metadataReady = recoveryReady;
		try {
			const response = await this.#controlMux.resync({
				readActiveSubscriptions: () =>
					[...this.#subscriptions.values()].flatMap((subscription) => {
						const claim = subscription.reconciliationClaim();
						return claim === null ? [] : [claim];
					}),
				readLastAcceptedStreamSequence: () => lastRoutedStreamSequence,
			});
			// Native reconciled every claimed id and revoked the rest; the replacement
			// stream carries no frames for ids ended locally on the old one.
			this.#drainingSubscriptionIds.clear();
			await Promise.all(
				response.reconciliation.map(async (outcome): Promise<void> => {
					const subscription = this.#subscriptions.get(outcome.subscriptionId);
					if (subscription !== undefined) await subscription.applyReconciliation(outcome);
				}),
			);
			await this.#openMetadataStream(response.metadataStreamSequenceBarrier);
			const retainedSubscriptionIds = new Set(
				response.reconciliation.flatMap((outcome) =>
					outcome.disposition === 'retained' ? [outcome.subscriptionId] : [],
				),
			);
			await Promise.all(
				[...retainedSubscriptionIds].map(async (subscriptionId): Promise<void> => {
					try {
						await this.#viewScopeOwner.resnapshot(subscriptionId);
					} catch (error) {
						if (
							!(error instanceof BridgeProductControlRequestError) ||
							error.code !== 'unknown_subscription'
						)
							throw error;
						const subscription = this.#subscriptions.get(subscriptionId);
						if (subscription === undefined) return;
						const claim = subscription.reconciliationClaim();
						if (claim === null) return;
						// Native has definitively lost this ID. The existing per-surface reset
						// recovery opens a new E3 or publishes Retry when its budget is spent.
						await subscription.applyReconciliation({
							disposition: 'reopenRequired',
							reason: 'native_missing',
							requiredWorkerDerivationEpoch: claim.workerDerivationEpoch,
							subscriptionId: claim.subscriptionId,
							subscriptionKind: claim.subscriptionKind,
						});
					}
				}),
			);
			recoveryReady.resolve();
		} catch (error) {
			recoveryReady.reject(error);
			if (this.#metadataReady === recoveryReady) this.#metadataReady = null;
			throw error;
		} finally {
			this.#metadataRecoveryInFlight = false;
		}
	}

	async #readMetadataStream(request: BridgeProductMetadataStreamRequest): Promise<void> {
		this.#metadataStreamHealthDiagnostics = {
			...this.#metadataStreamHealthDiagnostics,
			failureStage: null,
			lifecycleState: 'opening',
		};
		try {
			await this.#authority.open;
		} catch (error) {
			this.#recordMetadataStreamFailure('authority');
			throw error;
		}
		this.#metadataResponseStatus = null;
		this.#publishMetadataStreamTransition('fetchStarted');
		let response: Response;
		const readAbortController = new AbortController();
		let activeReader: ReadableStreamDefaultReader<Uint8Array> | null = null;
		const abortRead = (): void => {
			readAbortController.abort();
			void activeReader?.cancel().catch((): void => {});
		};
		try {
			response = await awaitBridgeProductFiniteProgress({
				abortRead,
				clock: this.#deadlineClock,
				delayMilliseconds: this.#authority.bootstrap.policy.contentProgressDeadlineMilliseconds,
				pending: () =>
					this.#executeProductRequest('stream', {
						body: encodeBridgeProductRequestBody(request),
						headers: {
							'Content-Type': 'application/json',
							'X-AgentStudio-Bridge-Product-Capability': this.#authority.capabilityHeader,
						},
						method: 'POST',
						signal: readAbortController.signal,
					}),
			});
		} catch (error) {
			this.#recordMetadataStreamFailure('fetch');
			throw error;
		}
		this.#metadataResponseStatus = response.status;
		if (!response.ok || response.body === null) {
			this.#publishMetadataStreamTransition('responseReceived');
			this.#recordMetadataStreamFailure('fetch');
			throw new Error(`Bridge product metadata stream failed with status ${response.status}.`);
		}
		this.#metadataStreamHealthDiagnostics = {
			...this.#metadataStreamHealthDiagnostics,
			lifecycleState: 'reading',
			streamOpenCount: this.#metadataStreamHealthDiagnostics.streamOpenCount + 1,
		};
		const reader = response.body.getReader();
		activeReader = reader;
		const readAhead = new BridgeProductReadAhead(reader);
		const decoder = new BridgeProductMetadataStreamDecoder(request);
		let responsePublished = false;
		let firstBytePublished = false;
		try {
			while (true) {
				this.#metadataStreamHealthDiagnostics = {
					...this.#metadataStreamHealthDiagnostics,
					readPending: true,
					readRequestCount: this.#metadataStreamHealthDiagnostics.readRequestCount + 1,
				};
				if (!responsePublished) {
					responsePublished = true;
					this.#publishMetadataStreamTransition('responseReceived');
				}
				let chunk: ReadableStreamReadResult<Uint8Array>;
				try {
					// eslint-disable-next-line no-await-in-loop -- Stream chunks are ordered.
					chunk = await awaitBridgeProductFiniteProgress({
						abortRead,
						clock: this.#deadlineClock,
						delayMilliseconds: this.#authority.bootstrap.policy.contentProgressDeadlineMilliseconds,
						pending: () => readAhead.next(),
					});
				} catch (error) {
					this.#recordMetadataStreamFailure('read');
					throw error;
				}
				this.#metadataStreamHealthDiagnostics = {
					...this.#metadataStreamHealthDiagnostics,
					readFulfilledCount: this.#metadataStreamHealthDiagnostics.readFulfilledCount + 1,
					readPending: false,
				};
				if (chunk.done) {
					try {
						decoder.finish();
					} catch (error) {
						this.#captureMetadataStreamDiagnostics(decoder, 0, false);
						this.#recordMetadataStreamFailure('finish');
						throw error;
					}
					this.#captureMetadataStreamDiagnostics(decoder, 0, false);
					this.#recordMetadataStreamFailure('unexpectedEof');
					throw new Error('Bridge product metadata stream ended unexpectedly.');
				}
				let frames: readonly BridgeProductMetadataFrame[];
				try {
					frames = decoder.push(chunk.value);
				} catch (error) {
					this.#recordMetadataStreamFailure('decode');
					throw error;
				} finally {
					this.#captureMetadataStreamDiagnostics(decoder, chunk.value.byteLength);
					if (!firstBytePublished && chunk.value.byteLength > 0) {
						firstBytePublished = true;
						this.#publishMetadataStreamTransition('firstByteRead');
					}
				}
				this.#metadataStreamHealthDiagnostics = {
					...this.#metadataStreamHealthDiagnostics,
					committedFrameCount:
						this.#metadataStreamHealthDiagnostics.committedFrameCount + frames.length,
					lastCommittedFrameKind:
						frames.at(-1)?.kind ?? this.#metadataStreamHealthDiagnostics.lastCommittedFrameKind,
				};
				for (const frame of frames) {
					try {
						this.#routeMetadataFrame(frame);
					} catch (error) {
						const routeFailure = bridgeProductMetadataRouteFailure(error);
						if (
							'subscriptionId' in frame &&
							this.#metadataStreamHealthDiagnostics.routeFailureSubscriptionId === null
						) {
							this.#metadataStreamHealthDiagnostics = {
								...this.#metadataStreamHealthDiagnostics,
								routeFailureSubscriptionId: frame.subscriptionId,
							};
						}
						this.#recordMetadataStreamFailure('route', routeFailure.routeFailureCode);
						throw routeFailure;
					}
					this.#metadataStreamHealthDiagnostics = {
						...this.#metadataStreamHealthDiagnostics,
						lastRoutedFrameKind: frame.kind,
						routeFailureSubscriptionId: frame.kind.startsWith('subscription.batch')
							? null
							: this.#metadataStreamHealthDiagnostics.routeFailureSubscriptionId,
						routeFailureCode: frame.kind.startsWith('subscription.batch')
							? null
							: this.#metadataStreamHealthDiagnostics.routeFailureCode,
						routedFrameCount: this.#metadataStreamHealthDiagnostics.routedFrameCount + 1,
					};
					this.#lastRoutedStreamSequence = frame.streamSequence;
					if (frame.kind === 'metadataStream.accepted')
						this.#publishMetadataStreamTransition('acceptedRouted');
				}
			}
		} catch (error) {
			await reader.cancel(error).catch((): void => {});
			throw error;
		} finally {
			reader.releaseLock();
		}
	}

	async #acknowledgeContentReceipt<TContentKind extends BridgeProductContentKind>(
		request: BridgeProductContentRequestFor<TContentKind>,
		receivedThroughContentSequence: number,
	): Promise<void> {
		const acknowledgement = bridgeProductFrameAcknowledgementRequestSchema.parse({
			contentRequestId: request.contentRequestId,
			receivedThroughContentSequence,
			kind: 'content.acknowledge',
			leaseId: request.leaseId,
			paneSessionId: request.paneSessionId,
			wireVersion: request.wireVersion,
			workerInstanceId: request.workerInstanceId,
		});
		await this.#sendFrameAcknowledgement(acknowledgement);
	}

	async #sendFrameAcknowledgement(
		request: BridgeProductFrameAcknowledgementRequest,
	): Promise<void> {
		await sendBridgeProductFrameAcknowledgement({
			deadlineClock: this.#deadlineClock,
			capabilityHeader: this.#authority.capabilityHeader,
			executeProductRequest: this.#executeProductRequest,
			request,
			timeoutMilliseconds: this.#frameAcknowledgementTimeoutMilliseconds,
		});
	}

	#recordMetadataStreamFailure(
		failureStage: BridgeProductMetadataStreamFailureStage,
		routeFailureCode: BridgeProductMetadataRouteFailureCode | null = null,
	): void {
		this.#metadataStreamHealthDiagnostics = {
			...this.#metadataStreamHealthDiagnostics,
			failureStage,
			lifecycleState: 'failed',
			readPending: false,
			routeFailureCode: this.#metadataStreamHealthDiagnostics.routeFailureCode ?? routeFailureCode,
		};
		this.#publishMetadataStreamTransition('failed');
	}

	#captureMetadataStreamDiagnostics(
		decoder: BridgeProductMetadataStreamDecoder,
		chunkByteCount: number,
		recordPush = true,
	): void {
		this.#metadataStreamHealthDiagnostics = captureBridgeProductMetadataStreamHealth({
			current: this.#metadataStreamHealthDiagnostics,
			decoder: decoder.diagnostics,
			chunkByteCount,
			recordPush,
		});
	}

	#routeMetadataFrame(frame: BridgeProductMetadataFrame): void {
		switch (frame.kind) {
			case 'stream.keepalive':
				return;
			case 'metadataStream.accepted':
				this.#physicalMetadataReady?.resolve();
				return;
			case 'pane.presentation':
				this.#panePresentationFrameSink(frame);
				return;
			case 'pane.surfaceSelectionRequested':
				this.#paneSurfaceSelectionFrameSink(frame);
				return;
			case 'metadataStream.error':
				throw new BridgeProductMetadataRouteFailure(
					'metadata_stream_error',
					frame.safeMessage ?? `Bridge product metadata stream failed: ${frame.code}.`,
				);
			case 'content.cancelled':
				return;
			case 'subscription.batchBegin':
			case 'subscription.batchPart':
			case 'subscription.batchComplete':
				if (!this.#subscriptions.has(frame.subscriptionId)) {
					if (this.#drainingSubscriptionIds.has(frame.subscriptionId)) return;
					throw new BridgeProductMetadataRouteFailure(
						'unknown_subscription',
						'Bridge product batch references an unknown subscription.',
					);
				}
				this.#batchFrameRouter.accept(frame);
				return;
			case 'subscription.accepted':
			case 'subscription.cancelled':
			case 'subscription.end':
			case 'subscription.reset': {
				const subscription = this.#subscriptions.get(frame.subscriptionId);
				if (subscription === undefined) {
					if (this.#drainingSubscriptionIds.has(frame.subscriptionId)) {
						if (
							frame.kind === 'subscription.cancelled' ||
							frame.kind === 'subscription.end' ||
							frame.kind === 'subscription.reset'
						) {
							this.#drainingSubscriptionIds.delete(frame.subscriptionId);
						}
						return;
					}
					throw new BridgeProductMetadataRouteFailure(
						'unknown_subscription',
						'Bridge product metadata frame references an unknown subscription.',
					);
				}
				try {
					subscription.acceptFrame(frame);
				} catch (error) {
					throw new BridgeProductMetadataRouteFailure(
						error instanceof BridgeProductSubscriptionFrameFailure
							? error.routeFailureCode
							: 'subscription_frame_rejected',
						error instanceof Error
							? error.message
							: 'Bridge product subscription rejected a metadata frame.',
					);
				}
				if (
					frame.kind === 'subscription.cancelled' ||
					frame.kind === 'subscription.end' ||
					frame.kind === 'subscription.reset'
				)
					this.#batchFrameRouter.retireSubscription(frame.subscriptionId);
				return;
			}
		}
	}

	#poisonMetadataSession(error: unknown): void {
		// EOF can race a resync's scope settlements. A resolved readiness promise
		// for that ended physical stream must not admit a user reopen onto it.
		this.#metadataReady = null;
		for (const kind of [
			'file.metadata',
			'review.metadata',
			'file.annotations',
			'review.annotations',
		] as const) {
			this.#viewScopeOwner.failViewsOfKind(kind);
		}
		for (const subscription of this.#subscriptions.values()) {
			subscription.fail(error);
		}
		this.#subscriptions.clear();
		this.#drainingSubscriptionIds.clear();
		this.#batchFrameRouter.clear();
	}

	#openValidatedContent<TContentKind extends BridgeProductContentKind>(
		request: BridgeProductContentRequestFor<TContentKind>,
		abortSignal: AbortSignal,
	): BridgeProductContentStream<TContentKind> {
		return openBridgeProductContentStream({
			abortSignal,
			readResponse: (opening) =>
				readBridgeProductContentResponse({
					acknowledgeReceivedThrough: (contentRequest, receivedThroughContentSequence) =>
						this.#acknowledgeContentReceipt(contentRequest, receivedThroughContentSequence),
					authority: this.#authority,
					clock: this.#deadlineClock,
					executeProductRequest: this.#executeProductRequest,
					opening,
					responseAdmission: this.#contentResponseAdmission,
				}),
			request,
		});
	}
}
