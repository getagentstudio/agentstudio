import {
	bridgeProductCallRequestSchema,
	bridgeProductCallResultForMethod,
	bridgeProductSurfaceForCallKind,
	type BridgeProductCallKind,
	type BridgeProductCallRequest,
	type BridgeProductCallResult,
} from './bridge-product-call-contracts.js';
import { bridgeProductCallIsMutation } from './bridge-product-call-mutation-classification.js';
import {
	BridgeProductResponseSizeLimitError,
	BridgeProductRequestTransportError,
	postBridgeProductCommandBody,
} from './bridge-product-command-post.js';
import { BridgeProductControlAdmissionQueue } from './bridge-product-control-admission-queue.js';
import {
	postBridgeProductControlRequestWithExactRetry,
	postBridgeProductEscapeControlRequest,
} from './bridge-product-control-post.js';
import {
	bridgeProductAmbiguousControlReply,
	bridgeProductControlAttemptOutcome,
} from './bridge-product-control-reply-classification.js';
import { BridgeProductControlRequestError } from './bridge-product-control-request-error.js';
import { assertBridgeProductResponseCorrelation } from './bridge-product-control-response-correlation.js';
import {
	BridgeProductRequestDeadlineError,
	BridgeProductSessionSuspectError,
	postBridgeProductExactAdmissionWithRetry,
	withBridgeProductDeadline,
} from './bridge-product-control-retry.js';
import {
	defaultBridgeProductDeadlineClock,
	type BridgeProductDeadlineClock,
} from './bridge-product-deadline-clock.js';
import {
	bridgeProductOperationLateOutcomeAcknowledgementSchema,
	bridgeProductOperationObservationRequestSchema,
	bridgeProductOperationObservationResponseSchema,
	type BridgeProductOperationObservationResponse,
} from './bridge-product-operation-observation-wire-contracts.js';
import {
	bridgeProductAdmissionResponseSchema,
	bridgeProductOperationResultAcknowledgementSchema,
	bridgeProductOperationResultRequestSchema,
	bridgeProductOperationResultResponseSchema,
	type BridgeProductOperationAdmittedResponse,
} from './bridge-product-operation-wire-contracts.js';
import type { BridgeProductRequestExecutor } from './bridge-product-request-executor.js';
import { postBridgeProductResultAcknowledgement } from './bridge-product-result-acknowledgement.js';
import {
	assertBridgeProductResyncReconciliationMatchesRequest,
	bridgeProductControlRequestSchema,
	bridgeProductControlResponseSchema,
	encodeBridgeProductCapabilityHeader,
	type BridgeProductControlRequest,
	type BridgeProductControlResponse,
	type BridgeProductSessionBootstrap,
} from './bridge-product-session-contracts.js';
import { parseBridgeProductStrictJSON } from './bridge-product-strict-json.js';
import {
	viewResnapshotAdmission,
	viewScopeAdmission,
	type ViewResnapshotAdmissionProps,
	type ViewScopeAdmissionProps,
} from './bridge-product-view-control-admission.js';
import type {
	BridgeWorkerAckAttemptOutcome,
	BridgeWorkerControlAttemptOutcome,
	BridgeWorkerPriorControlRequest,
} from './bridge-worker-contracts.js';

export interface BridgeProductSessionAuthorityInstallInput {
	readonly bootstrap: BridgeProductSessionBootstrap;
	readonly productCapability: ArrayBuffer;
}

export interface BridgeProductSessionAuthority {
	readonly bootstrap: BridgeProductSessionBootstrap;
	readonly capabilityHeader: string;
	readonly open: Promise<void>;
}

export interface BridgeProductControlMuxProps {
	readonly authority: BridgeProductSessionAuthority;
	readonly createRequestId?: () => string;
	readonly deadlineClock?: BridgeProductDeadlineClock;
	readonly executeProductRequest: BridgeProductRequestExecutor;
	readonly onSessionSuspect?: (
		reason: 'admissionReplyExhausted' | 'resultAcknowledgementExhausted',
		ackAttemptOutcomes: readonly BridgeWorkerAckAttemptOutcome[],
		priorControlRequests: readonly BridgeWorkerPriorControlRequest[],
		droppedPriorControlRequestCount: number,
	) => void;
}

type BridgeProductControlResponseForKind<
	TResponseKind extends BridgeProductControlResponse['kind'],
> = Extract<BridgeProductControlResponse, { readonly kind: TResponseKind }>;

export type BridgeProductSubscriptionOpenAccepted =
	BridgeProductControlResponseForKind<'subscription.openAccepted'>;

export type BridgeProductSubscriptionCancelAccepted<TSubscriptionKind extends string> = Omit<
	BridgeProductControlResponseForKind<'subscription.cancelAccepted'>,
	'subscriptionKind'
> & {
	readonly subscriptionKind: TSubscriptionKind;
};

interface BridgeProductControlAdmissionIdentity {
	readonly paneSessionId: string;
	readonly requestId: string;
	readonly requestSequence: number;
	readonly wireVersion: BridgeProductSessionBootstrap['wireVersion'];
	readonly workerInstanceId: string;
}
interface BridgeProductControlAdmissionProps<TResult> {
	readonly acceptResponse: (
		response: BridgeProductControlResponse,
		request: BridgeProductControlRequest,
	) => TResult;
	readonly buildRequest: (
		identity: BridgeProductControlAdmissionIdentity,
	) => BridgeProductControlRequest;
	readonly requestErrorFallback?: (code: string) => string;
	readonly signal?: AbortSignal;
}

export interface BridgeProductLateOutcomeObservation {
	readonly actionResult: unknown;
	readonly evidence: Extract<
		BridgeProductOperationObservationResponse,
		{ kind: 'operation.lateOutcome' }
	>;
	readonly acknowledge: () => Promise<void>;
}

export { BridgeProductControlRequestError } from './bridge-product-control-request-error.js';

export { BridgeProductSessionSuspectError } from './bridge-product-control-retry.js';

export class BridgeProductControlMux {
	readonly deadlineClock: BridgeProductDeadlineClock;
	readonly #authority: BridgeProductSessionAuthority;
	readonly #createRequestId: () => string;
	readonly #executeProductRequest: BridgeProductRequestExecutor;
	readonly #onSessionSuspect:
		| ((
				reason: 'admissionReplyExhausted' | 'resultAcknowledgementExhausted',
				ackAttemptOutcomes: readonly BridgeWorkerAckAttemptOutcome[],
				priorControlRequests: readonly BridgeWorkerPriorControlRequest[],
				droppedPriorControlRequestCount: number,
		  ) => void)
		| undefined;
	#nextRequestSequence = 3;
	#didDeclareSessionSuspect = false;
	#hasAmbiguousControlExhaustion = false;
	readonly #admissionQueue = new BridgeProductControlAdmissionQueue();
	readonly #priorControlRequests: BridgeWorkerPriorControlRequest[] = [];
	#droppedPriorControlRequestCount = 0;
	readonly #pendingAcknowledgements = new Set<Promise<void>>();
	readonly #acknowledgementIdleWaiters: Array<() => void> = [];

	constructor(props: BridgeProductControlMuxProps) {
		this.deadlineClock = props.deadlineClock ?? defaultBridgeProductDeadlineClock;
		this.#authority = props.authority;
		this.#createRequestId = props.createRequestId ?? ((): string => crypto.randomUUID());
		this.#executeProductRequest = props.executeProductRequest;
		this.#onSessionSuspect = props.onSessionSuspect;
	}

	get diagnosticSnapshot(): {
		readonly pendingAdmissionCount: number;
		readonly pendingAcknowledgementCount: number;
	} {
		return {
			pendingAdmissionCount: this.#admissionQueue.pendingCount,
			pendingAcknowledgementCount: this.#pendingAcknowledgements.size,
		};
	}

	async waitForAcknowledgementsQuiescent(): Promise<void> {
		if (this.#pendingAcknowledgements.size === 0) return;
		await new Promise<void>((resolve) => this.#acknowledgementIdleWaiters.push(resolve));
	}

	#recordControlRequest(
		record: Omit<BridgeWorkerPriorControlRequest, 'attemptOutcomes'> & {
			readonly attemptOutcomes?: readonly BridgeWorkerControlAttemptOutcome[];
		},
	): void {
		if (this.#priorControlRequests.length === 16) {
			this.#priorControlRequests.shift();
			this.#droppedPriorControlRequestCount += 1;
		}
		this.#priorControlRequests.push({ ...record, attemptOutcomes: record.attemptOutcomes ?? [] });
	}

	#publishAdmissionSuspect(error: BridgeProductSessionSuspectError): void {
		if (this.#didDeclareSessionSuspect) {
			error.shouldNotify = false;
			return;
		}
		this.#didDeclareSessionSuspect = true;
		if (this.#onSessionSuspect === undefined) return;
		try {
			this.#onSessionSuspect(
				'admissionReplyExhausted',
				[],
				[...this.#priorControlRequests],
				this.#droppedPriorControlRequestCount,
			);
			error.shouldNotify = false;
		} catch {
			// The caller retains the suspect notification when the port has closed.
		}
	}

	call<TCallKind extends BridgeProductCallKind>(props: {
		readonly method: TCallKind;
		readonly request: BridgeProductCallRequest<TCallKind>;
		readonly signal?: AbortSignal;
		readonly workerDerivationEpoch: number;
	}): Promise<BridgeProductCallResult<TCallKind>> {
		return this.#admit({
			acceptResponse: (response): BridgeProductCallResult<TCallKind> => {
				if (response.kind !== 'call.completed') {
					throw new Error('Bridge product call did not return call.completed.');
				}
				if (response.call.method !== props.method) {
					throw new Error('Bridge product call result does not match its issued method.');
				}
				bridgeProductSurfaceForCallKind(props.method);
				return bridgeProductCallResultForMethod(props.method, response.call);
			},
			buildRequest: (identity): BridgeProductControlRequest =>
				bridgeProductControlRequestSchema.parse({
					...identity,
					call: bridgeProductCallRequestSchema.parse({
						method: props.method,
						request: props.request,
					}),
					kind: 'product.call',
					workerDerivationEpoch: props.workerDerivationEpoch,
				}),
			requestErrorFallback: (code): string => `Bridge product call was rejected with ${code}.`,
			...(props.signal === undefined ? {} : { signal: props.signal }),
		});
	}

	openSubscription<TSubscriptionOpen extends { readonly subscriptionKind: string }>(props: {
		readonly signal?: AbortSignal;
		readonly subscription: TSubscriptionOpen;
		readonly subscriptionId: string;
		readonly workerDerivationEpoch: number;
	}): Promise<BridgeProductSubscriptionOpenAccepted> {
		return this.#admit({
			acceptResponse: (response): BridgeProductSubscriptionOpenAccepted => {
				if (response.kind !== 'subscription.openAccepted') {
					throw new Error(
						'Bridge product subscription open did not return subscription.openAccepted.',
					);
				}
				if (
					response.subscriptionId !== props.subscriptionId ||
					response.subscriptionKind !== props.subscription.subscriptionKind
				) {
					throw new Error('Bridge product subscription open result does not match its request.');
				}
				return response;
			},
			buildRequest: (identity): BridgeProductControlRequest => {
				return bridgeProductControlRequestSchema.parse({
					...identity,
					kind: 'subscription.open',
					subscription: props.subscription,
					subscriptionId: props.subscriptionId,
					workerDerivationEpoch: props.workerDerivationEpoch,
				});
			},
			...(props.signal === undefined ? {} : { signal: props.signal }),
		});
	}

	setViewScope(
		props: ViewScopeAdmissionProps,
	): Promise<BridgeProductControlResponseForKind<'subscription.scopeAccepted'>> {
		return this.#admit(viewScopeAdmission(props));
	}

	resnapshotView(
		props: ViewResnapshotAdmissionProps,
	): Promise<BridgeProductControlResponseForKind<'subscription.resnapshotAccepted'>> {
		return this.#admit(viewResnapshotAdmission(props));
	}

	cancelSubscription<TSubscriptionKind extends string>(props: {
		readonly signal?: AbortSignal;
		readonly subscriptionId: string;
		readonly subscriptionKind: TSubscriptionKind;
		readonly workerDerivationEpoch: number;
	}): Promise<BridgeProductSubscriptionCancelAccepted<TSubscriptionKind>> {
		return this.#admitEscape({
			acceptResponse: (response): BridgeProductSubscriptionCancelAccepted<TSubscriptionKind> => {
				if (response.kind !== 'subscription.cancelAccepted') {
					throw new Error(
						'Bridge product subscription cancel did not return subscription.cancelAccepted.',
					);
				}
				if (
					response.subscriptionId !== props.subscriptionId ||
					response.subscriptionKind !== props.subscriptionKind
				) {
					throw new Error('Bridge product subscription cancel result does not match its request.');
				}
				return { ...response, subscriptionKind: props.subscriptionKind };
			},
			buildRequest: (identity): BridgeProductControlRequest => {
				return bridgeProductControlRequestSchema.parse({
					...identity,
					kind: 'subscription.cancel',
					subscriptionId: props.subscriptionId,
					subscriptionKind: props.subscriptionKind,
					workerDerivationEpoch: props.workerDerivationEpoch,
				});
			},
			...(props.signal === undefined ? {} : { signal: props.signal }),
		});
	}

	resync(props: {
		readonly readActiveSubscriptions: () => Extract<
			BridgeProductControlRequest,
			{ kind: 'workerSession.resync' }
		>['activeSubscriptions'];
		readonly readLastAcceptedStreamSequence: () => number;
	}): Promise<Extract<BridgeProductControlResponse, { kind: 'resync.accepted' }>> {
		return this.#admit({
			acceptResponse: (
				response,
				request,
			): Extract<BridgeProductControlResponse, { kind: 'resync.accepted' }> => {
				if (response.kind !== 'resync.accepted' || request.kind !== 'workerSession.resync') {
					throw new Error('Bridge product session resync did not return resync.accepted.');
				}
				if (response.nextExpectedRequestSequence !== request.requestSequence + 1) {
					throw new Error(
						'Bridge product session resync returned an unexpected next request sequence.',
					);
				}
				if (response.metadataStreamSequenceBarrier < request.lastAcceptedStreamSequence) {
					throw new Error(
						'Bridge product session resync metadata barrier precedes the claimed stream sequence.',
					);
				}
				assertBridgeProductResyncReconciliationMatchesRequest({ request, response });
				return response;
			},
			buildRequest: (identity): BridgeProductControlRequest =>
				bridgeProductControlRequestSchema.parse({
					...identity,
					activeSubscriptions: props.readActiveSubscriptions(),
					kind: 'workerSession.resync',
					lastAcceptedRequestSequence: identity.requestSequence - 1,
					lastAcceptedStreamSequence: props.readLastAcceptedStreamSequence(),
				}),
		});
	}

	#admit<TResult>(props: BridgeProductControlAdmissionProps<TResult>): Promise<TResult> {
		const admission = this.#admissionQueue.enqueue(
			async (): Promise<{
				readonly request: BridgeProductControlRequest;
				readonly response: BridgeProductOperationAdmittedResponse;
			}> => {
				props.signal?.throwIfAborted();
				await this.#authority.open;
				props.signal?.throwIfAborted();
				if (this.#hasAmbiguousControlExhaustion)
					throw new BridgeProductSessionSuspectError('admission');
				const request = props.buildRequest({
					paneSessionId: this.#authority.bootstrap.paneSessionId,
					requestId: this.#createRequestId(),
					requestSequence: this.#nextRequestSequence,
					wireVersion: this.#authority.bootstrap.wireVersion,
					workerInstanceId: this.#authority.bootstrap.workerInstanceId,
				});
				const attemptOutcomes: BridgeWorkerControlAttemptOutcome[] = [];
				let response: ReturnType<typeof bridgeProductAdmissionResponseSchema.parse>;
				try {
					response = await postBridgeProductControlRequestWithExactRetry({
						policy: this.#authority.bootstrap.policy,
						capabilityHeader: this.#authority.capabilityHeader,
						deadlineClock: this.deadlineClock,
						executeProductRequest: this.#executeProductRequest,
						request,
						recordAttemptFailure: (outcome): void => {
							attemptOutcomes.push(outcome);
						},
					});
				} catch (error: unknown) {
					if (error instanceof BridgeProductSessionSuspectError)
						this.#hasAmbiguousControlExhaustion = true;
					this.#recordControlRequest({
						kind: request.kind,
						requestSequence: request.requestSequence,
						outcome: 'ambiguous',
						attemptOutcomes,
					});
					throw error;
				}
				if (response.kind === 'request.error') {
					this.#recordControlRequest({
						kind: request.kind,
						requestSequence: request.requestSequence,
						outcome: 'refused',
						attemptOutcomes: [
							...attemptOutcomes,
							{ kind: 'nativeRefusal', refusalKind: response.code },
						],
					});
					// Admission rejection may leave the sequence unconsumed; only native knows its floor.
					this.#nextRequestSequence =
						response.nextExpectedRequestSequence ?? this.#nextRequestSequence;
					props.signal?.throwIfAborted();
					throw new BridgeProductControlRequestError({
						code: response.code,
						message:
							response.safeMessage ??
							props.requestErrorFallback?.(response.code) ??
							`Bridge product control request was rejected with ${response.code}.`,
						retryAfterMilliseconds: response.retryAfterMilliseconds,
						retryable: response.retryable,
					});
				}
				this.#recordControlRequest({
					kind: request.kind,
					requestSequence: request.requestSequence,
					outcome: 'ok',
					attemptOutcomes,
				});
				this.#nextRequestSequence += 1;
				return { request, response };
			},
		);
		return admission
			.then(({ request, response }): Promise<TResult> => {
				const nativeResult = (async (): Promise<TResult> => {
					const operationResult = await postBridgeProductOperationResult({
						bootstrap: this.#authority.bootstrap,
						capabilityHeader: this.#authority.capabilityHeader,
						deadlineClock: this.deadlineClock,
						executeProductRequest: this.#executeProductRequest,
						operationId: response.operationId,
						waitKind: response.waitKind,
					});
					try {
						props.signal?.throwIfAborted();
						if (operationResult.outcome !== 'succeeded') {
							throw new BridgeProductControlRequestError({
								code: operationResult.failureCode ?? 'internal',
								message: `Bridge product operation settled as ${operationResult.outcome}.`,
								outcome: operationResult.outcome,
								retryAfterMilliseconds: null,
								retryable: operationResult.outcome === 'outcomeUnknown',
								...(operationResult.outcome === 'outcomeUnknown' &&
								request.kind === 'product.call' &&
								bridgeProductCallIsMutation(request.call.method)
									? {
											observeLateOutcome: (): Promise<BridgeProductLateOutcomeObservation> =>
												this.#observeLateOutcome({
													operationId: response.operationId,
													request,
													acceptResponse: props.acceptResponse,
												}),
										}
									: {}),
							});
						}
						const finalResponse = bridgeProductControlResponseSchema.parse(operationResult.result);
						assertBridgeProductResponseCorrelation({ request, response: finalResponse });
						return props.acceptResponse(finalResponse, request);
					} finally {
						// The native result still frees its slot after the caller has cancelled.
						this.#scheduleResultAcknowledgement(response.operationId);
					}
				})();
				void nativeResult.catch((error: unknown): void => {
					// The caller owns live failures. After local cancellation, only the
					// background result consumer can surface a late suspect result.
					if (props.signal?.aborted && error instanceof BridgeProductSessionSuspectError)
						this.#publishAdmissionSuspect(error);
				});
				return settleAdmittedCallerOnAbort(nativeResult, props.signal);
			})
			.catch((error: unknown): never => {
				if (error instanceof BridgeProductSessionSuspectError) this.#publishAdmissionSuspect(error);
				throw error;
			});
	}

	#scheduleResultAcknowledgement(operationId: string): void {
		const ackAttemptOutcomes: BridgeWorkerAckAttemptOutcome[] = [];
		let priorControlRequests: readonly BridgeWorkerPriorControlRequest[] = [];
		let droppedPriorControlRequestCount = 0;
		const acknowledgement = this.#admissionQueue.enqueue(async (): Promise<void> => {
			if (this.#hasAmbiguousControlExhaustion) return;
			priorControlRequests = [...this.#priorControlRequests];
			droppedPriorControlRequestCount = this.#droppedPriorControlRequestCount;
			const request = bridgeProductOperationResultAcknowledgementSchema.parse({
				kind: 'operation.resultAcknowledgement',
				operationId,
				paneSessionId: this.#authority.bootstrap.paneSessionId,
				requestId: this.#createRequestId(),
				requestSequence: this.#nextRequestSequence,
				wireVersion: this.#authority.bootstrap.wireVersion,
				workerInstanceId: this.#authority.bootstrap.workerInstanceId,
			});
			const response = await postBridgeProductResultAcknowledgement({
				policy: this.#authority.bootstrap.policy,
				acknowledgement: request,
				capabilityHeader: this.#authority.capabilityHeader,
				deadlineClock: this.deadlineClock,
				executeProductRequest: this.#executeProductRequest,
				recordAttemptFailure: (outcome): void => {
					ackAttemptOutcomes.push(outcome);
				},
			});
			if (response.operationId !== operationId) {
				throw new BridgeProductRequestTransportError('Bridge product acknowledgement mismatched.');
			}
			this.#nextRequestSequence += 1;
		}, 'escape');
		this.#pendingAcknowledgements.add(acknowledgement);
		void acknowledgement
			.catch((): void => {
				if (this.#didDeclareSessionSuspect) return;
				this.#didDeclareSessionSuspect = true;
				try {
					this.#onSessionSuspect?.(
						'resultAcknowledgementExhausted',
						ackAttemptOutcomes,
						priorControlRequests,
						droppedPriorControlRequestCount,
					);
				} catch {
					// The old worker may already be fenced; the delivered outcome stays final.
				}
			})
			.finally((): void => {
				this.#pendingAcknowledgements.delete(acknowledgement);
				if (this.#pendingAcknowledgements.size !== 0) return;
				for (const resume of this.#acknowledgementIdleWaiters.splice(0)) resume();
			});
	}

	async #observeLateOutcome<TResult>(props: {
		readonly operationId: string;
		readonly request: BridgeProductControlRequest;
		readonly acceptResponse: (
			response: BridgeProductControlResponse,
			request: BridgeProductControlRequest,
		) => TResult;
	}): Promise<BridgeProductLateOutcomeObservation> {
		for (;;) {
			const observed = await postBridgeProductOperationObservation({
				bootstrap: this.#authority.bootstrap,
				capabilityHeader: this.#authority.capabilityHeader,
				deadlineClock: this.deadlineClock,
				executeProductRequest: this.#executeProductRequest,
				operationId: props.operationId,
				after: 1,
			});
			if (observed.kind === 'operation.stillUnknown') continue;
			let actionResult: TResult | null = null;
			if (observed.outcome === 'succeeded') {
				const response = bridgeProductControlResponseSchema.parse(observed.result);
				assertBridgeProductResponseCorrelation({ request: props.request, response });
				actionResult = props.acceptResponse(response, props.request);
			}
			return {
				actionResult,
				evidence: observed,
				acknowledge: (): Promise<void> =>
					this.#admissionQueue
						.enqueue(async (): Promise<void> => {
							if (this.#hasAmbiguousControlExhaustion)
								throw new BridgeProductSessionSuspectError('admission');
							const acknowledgement = bridgeProductOperationLateOutcomeAcknowledgementSchema.parse({
								kind: 'operation.lateOutcomeAcknowledgement',
								operationId: props.operationId,
								paneSessionId: this.#authority.bootstrap.paneSessionId,
								requestId: this.#createRequestId(),
								requestSequence: this.#nextRequestSequence,
								revision: observed.revision,
								wireVersion: this.#authority.bootstrap.wireVersion,
								workerInstanceId: this.#authority.bootstrap.workerInstanceId,
							});
							const attemptOutcomes: BridgeWorkerControlAttemptOutcome[] = [];
							try {
								await postBridgeProductExactAdmissionWithRetry({
									policy: this.#authority.bootstrap.policy,
									deadlineClock: this.deadlineClock,
									onAttemptFailure: (error): void => {
										attemptOutcomes.push(bridgeProductControlAttemptOutcome(error));
									},
									run: async (signal): Promise<void> => {
										let observedResponse: Response | null = null;
										try {
											await postBridgeProductCommandBody({
												body: acknowledgement,
												capabilityHeader: this.#authority.capabilityHeader,
												executeProductRequest: this.#executeProductRequest,
												observeResponse: (received): void => {
													observedResponse = received;
												},
												signal,
											});
										} catch (error: unknown) {
											throw bridgeProductAmbiguousControlReply({
												error,
												failureKind: 'transport',
												response: observedResponse,
												signal,
											});
										}
									},
								});
							} catch (error: unknown) {
								if (error instanceof BridgeProductSessionSuspectError)
									this.#hasAmbiguousControlExhaustion = true;
								this.#recordControlRequest({
									kind: acknowledgement.kind,
									requestSequence: acknowledgement.requestSequence,
									outcome:
										error instanceof BridgeProductRequestTransportError ||
										error instanceof BridgeProductRequestDeadlineError
											? 'ambiguous'
											: 'refused',
									attemptOutcomes,
								});
								throw error;
							}
							this.#recordControlRequest({
								kind: acknowledgement.kind,
								requestSequence: acknowledgement.requestSequence,
								outcome: 'ok',
								attemptOutcomes,
							});
							this.#nextRequestSequence += 1;
						}, 'escape')
						.catch((error: unknown): never => {
							if (error instanceof BridgeProductSessionSuspectError)
								this.#publishAdmissionSuspect(error);
							throw error;
						}),
			};
		}
	}

	#admitEscape<TResult>(props: BridgeProductControlAdmissionProps<TResult>): Promise<TResult> {
		return this.#admissionQueue
			.enqueue(async (): Promise<TResult> => {
				props.signal?.throwIfAborted();
				await this.#authority.open;
				props.signal?.throwIfAborted();
				if (this.#hasAmbiguousControlExhaustion)
					throw new BridgeProductSessionSuspectError('admission');
				const request = props.buildRequest({
					paneSessionId: this.#authority.bootstrap.paneSessionId,
					requestId: this.#createRequestId(),
					requestSequence: this.#nextRequestSequence,
					wireVersion: this.#authority.bootstrap.wireVersion,
					workerInstanceId: this.#authority.bootstrap.workerInstanceId,
				});
				const attemptOutcomes: BridgeWorkerControlAttemptOutcome[] = [];
				let response: BridgeProductControlResponse;
				try {
					response = await postBridgeProductEscapeControlRequest({
						policy: this.#authority.bootstrap.policy,
						capabilityHeader: this.#authority.capabilityHeader,
						deadlineClock: this.deadlineClock,
						executeProductRequest: this.#executeProductRequest,
						request,
						recordAttemptFailure: (outcome): void => {
							attemptOutcomes.push(outcome);
						},
					});
				} catch (error: unknown) {
					if (error instanceof BridgeProductSessionSuspectError)
						this.#hasAmbiguousControlExhaustion = true;
					this.#recordControlRequest({
						kind: request.kind,
						requestSequence: request.requestSequence,
						outcome: 'ambiguous',
						attemptOutcomes,
					});
					throw error;
				}
				if (response.kind === 'request.error') {
					this.#recordControlRequest({
						kind: request.kind,
						requestSequence: request.requestSequence,
						outcome: 'refused',
						attemptOutcomes: [
							...attemptOutcomes,
							{ kind: 'nativeRefusal', refusalKind: response.code },
						],
					});
					this.#nextRequestSequence =
						response.nextExpectedRequestSequence ?? this.#nextRequestSequence;
					props.signal?.throwIfAborted();
					throw new BridgeProductControlRequestError({
						code: response.code,
						message: response.safeMessage ?? `Bridge product escape control was rejected.`,
						retryAfterMilliseconds: response.retryAfterMilliseconds,
						retryable: response.retryable,
					});
				}
				this.#recordControlRequest({
					kind: request.kind,
					requestSequence: request.requestSequence,
					outcome: 'ok',
					attemptOutcomes,
				});
				this.#nextRequestSequence += 1;
				props.signal?.throwIfAborted();
				return props.acceptResponse(response, request);
			}, 'escape')
			.catch((error: unknown): never => {
				if (error instanceof BridgeProductSessionSuspectError) this.#publishAdmissionSuspect(error);
				throw error;
			});
	}
}

export class BridgeProductSessionAuthorityStore {
	readonly #deadlineClock: BridgeProductDeadlineClock;
	readonly #executeProductRequest: BridgeProductRequestExecutor;
	#installedAuthority: BridgeProductSessionAuthority | null = null;

	constructor(
		executeProductRequest: BridgeProductRequestExecutor,
		deadlineClock: BridgeProductDeadlineClock = defaultBridgeProductDeadlineClock,
	) {
		this.#executeProductRequest = executeProductRequest;
		this.#deadlineClock = deadlineClock;
	}

	readonly install = (
		input: BridgeProductSessionAuthorityInstallInput,
	): BridgeProductSessionAuthority => {
		if (this.#installedAuthority !== null) {
			throw new Error('Bridge product session authority was already installed.');
		}
		const capabilityHeader = encodeBridgeProductCapabilityHeader(input.productCapability);
		new Uint8Array(input.productCapability).fill(0);
		const request = bridgeProductControlRequestSchema.parse({
			kind: 'workerSession.open',
			paneSessionId: input.bootstrap.paneSessionId,
			request: null,
			requestId: 'worker-session-open-1',
			requestSequence: 1,
			wireVersion: input.bootstrap.wireVersion,
			workerInstanceId: input.bootstrap.workerInstanceId,
		});
		const open = postBridgeProductControlRequestWithExactRetry({
			policy: input.bootstrap.policy,
			capabilityHeader,
			deadlineClock: this.#deadlineClock,
			executeProductRequest: this.#executeProductRequest,
			request,
		}).then(async (admission): Promise<void> => {
			assertBridgeProductResponseCorrelation({ request, response: admission });
			if (admission.kind !== 'operation.admitted') {
				throw new Error('Bridge product session open was refused.');
			}
			const operationResult = await postBridgeProductOperationResult({
				bootstrap: input.bootstrap,
				capabilityHeader,
				deadlineClock: this.#deadlineClock,
				executeProductRequest: this.#executeProductRequest,
				operationId: admission.operationId,
				waitKind: admission.waitKind,
			});
			if (operationResult.outcome !== 'succeeded') {
				throw new Error(`Bridge product session open settled as ${operationResult.outcome}.`);
			}
			const response = bridgeProductControlResponseSchema.parse(operationResult.result);
			assertBridgeProductResponseCorrelation({ request, response });
			if (response.kind !== 'workerSession.accepted') {
				throw new Error('Bridge product session open did not return workerSession.accepted.');
			}
			const acknowledgement = bridgeProductOperationResultAcknowledgementSchema.parse({
				kind: 'operation.resultAcknowledgement',
				operationId: admission.operationId,
				paneSessionId: input.bootstrap.paneSessionId,
				requestId: 'worker-session-open-result-ack-2',
				requestSequence: 2,
				wireVersion: input.bootstrap.wireVersion,
				workerInstanceId: input.bootstrap.workerInstanceId,
			});
			await postBridgeProductResultAcknowledgement({
				policy: input.bootstrap.policy,
				acknowledgement,
				capabilityHeader,
				deadlineClock: this.#deadlineClock,
				executeProductRequest: this.#executeProductRequest,
			});
		});
		void open.catch((): void => {});
		this.#installedAuthority = {
			bootstrap: input.bootstrap,
			capabilityHeader,
			open,
		};
		return this.#installedAuthority;
	};

	get installedAuthority(): BridgeProductSessionAuthority {
		if (this.#installedAuthority === null) {
			throw new Error('Bridge product session authority is not installed.');
		}
		return this.#installedAuthority;
	}
}

async function postBridgeProductOperationObservation(props: {
	readonly after: number;
	readonly bootstrap: BridgeProductSessionBootstrap;
	readonly capabilityHeader: string;
	readonly deadlineClock: BridgeProductDeadlineClock;
	readonly executeProductRequest: BridgeProductRequestExecutor;
	readonly operationId: string;
}): Promise<BridgeProductOperationObservationResponse> {
	const request = bridgeProductOperationObservationRequestSchema.parse({
		after: props.after,
		kind: 'operation.observe',
		operationId: props.operationId,
		paneSessionId: props.bootstrap.paneSessionId,
		wireVersion: props.bootstrap.wireVersion,
		workerInstanceId: props.bootstrap.workerInstanceId,
	});
	const response = await postBridgeProductOutcomeReadWithRetry({
		bootstrap: props.bootstrap,
		deadlineClock: props.deadlineClock,
		run: async (signal) => {
			try {
				const responseBytes = await postBridgeProductCommandBody({
					body: request,
					capabilityHeader: props.capabilityHeader,
					executeProductRequest: props.executeProductRequest,
					signal,
				});
				return bridgeProductOperationObservationResponseSchema.parse(
					parseBridgeProductStrictJSON(responseBytes),
				);
			} catch (error: unknown) {
				if (error instanceof BridgeProductResponseSizeLimitError) throw error;
				signal.throwIfAborted();
				throw new BridgeProductRequestTransportError('Bridge observation reply unreadable.');
			}
		},
	});
	if (response.operationId !== props.operationId) {
		throw new Error('Bridge product observation did not match its admitted operation.');
	}
	if (
		(response.kind === 'operation.stillUnknown' && response.revision !== props.after) ||
		(response.kind === 'operation.lateOutcome' && response.revision <= props.after)
	) {
		throw new Error('Bridge product observation returned an invalid evidence revision.');
	}
	return response;
}

async function postBridgeProductOperationResult(props: {
	readonly bootstrap: BridgeProductSessionBootstrap;
	readonly capabilityHeader: string;
	readonly deadlineClock: BridgeProductDeadlineClock;
	readonly executeProductRequest: BridgeProductRequestExecutor;
	readonly operationId: string;
	readonly signal?: AbortSignal;
	readonly waitKind: BridgeProductOperationAdmittedResponse['waitKind'];
}): Promise<ReturnType<typeof bridgeProductOperationResultResponseSchema.parse>> {
	const request = bridgeProductOperationResultRequestSchema.parse({
		kind: 'operation.result',
		operationId: props.operationId,
		paneSessionId: props.bootstrap.paneSessionId,
		wireVersion: props.bootstrap.wireVersion,
		workerInstanceId: props.bootstrap.workerInstanceId,
	});
	const result = await postBridgeProductOutcomeReadWithRetry({
		bootstrap: props.bootstrap,
		deadlineClock: props.deadlineClock,
		...(props.signal === undefined ? {} : { signal: props.signal }),
		waitKind: props.waitKind,
		run: async (signal) => {
			try {
				const responseBytes = await postBridgeProductCommandBody({
					body: request,
					capabilityHeader: props.capabilityHeader,
					executeProductRequest: props.executeProductRequest,
					signal,
				});
				return bridgeProductOperationResultResponseSchema.parse(
					parseBridgeProductStrictJSON(responseBytes),
				);
			} catch (error: unknown) {
				if (error instanceof BridgeProductResponseSizeLimitError) throw error;
				signal.throwIfAborted();
				throw new BridgeProductRequestTransportError('Bridge product result reply was unreadable.');
			}
		},
	});
	if (result.operationId !== props.operationId) {
		throw new Error('Bridge product operation result did not match its admission.');
	}
	return result;
}

async function postBridgeProductOutcomeReadWithRetry<TResult>(props: {
	readonly bootstrap: BridgeProductSessionBootstrap;
	readonly deadlineClock: BridgeProductDeadlineClock;
	readonly run: (signal: AbortSignal) => Promise<TResult>;
	readonly signal?: AbortSignal;
	readonly waitKind?: BridgeProductOperationAdmittedResponse['waitKind'];
}): Promise<TResult> {
	for (let attempt = 0; attempt <= props.bootstrap.policy.admissionRetryCount; attempt += 1) {
		try {
			return props.waitKind === 'human'
				? await props.run(props.signal ?? new AbortController().signal)
				: await withBridgeProductDeadline({
						clock: props.deadlineClock,
						delayMilliseconds: props.bootstrap.policy.workerSettlementDeadlineMilliseconds,
						run: props.run,
						...(props.signal === undefined ? {} : { signal: props.signal }),
					});
		} catch (error: unknown) {
			props.signal?.throwIfAborted();
			if (error instanceof BridgeProductRequestDeadlineError) continue;
			if (error instanceof BridgeProductRequestTransportError) continue;
			throw error;
		}
	}
	throw new BridgeProductSessionSuspectError('result');
}

function settleAdmittedCallerOnAbort<TResult>(
	nativeResult: Promise<TResult>,
	signal: AbortSignal | undefined,
): Promise<TResult> {
	if (signal === undefined) return nativeResult;
	return new Promise<TResult>((resolve, reject): void => {
		const abortCaller = (): void => {
			signal.removeEventListener('abort', abortCaller);
			reject(signal.reason ?? new DOMException('Operation cancelled.', 'AbortError'));
		};
		void nativeResult.then(
			(value): void => {
				signal.removeEventListener('abort', abortCaller);
				resolve(value);
			},
			(error: unknown): void => {
				signal.removeEventListener('abort', abortCaller);
				reject(error);
			},
		);
		if (signal.aborted) abortCaller();
		else signal.addEventListener('abort', abortCaller, { once: true });
	});
}
