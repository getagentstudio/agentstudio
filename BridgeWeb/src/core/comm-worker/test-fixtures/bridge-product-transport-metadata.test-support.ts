import { vi } from 'vitest';

import { executeAgentStudioBridgeProductRequest } from '../bridge-product-agent-studio-request-executor.js';
import { createBridgeProductDeferred } from '../bridge-product-async-queue.js';
import type { BridgeProductDeadlineClock } from '../bridge-product-deadline-clock.js';
import type { BridgeProductFileSourceIdentity } from '../bridge-product-file-contracts.js';
import {
	bridgeProductFrameAcknowledgementRequestSchema,
	type BridgeProductFrameAcknowledgementRequest,
} from '../bridge-product-frame-acknowledgement-contracts.js';
import { bridgeProductMetadataApplicationRegistry } from '../bridge-product-metadata-application-registry.js';
import { encodeBridgeProductMetadataFrame } from '../bridge-product-metadata-frame-codec.js';
import {
	bridgeProductOperationResultAcknowledgementSchema,
	bridgeProductOperationResultRequestSchema,
} from '../bridge-product-operation-wire-contracts.js';
import {
	BridgeProductControlMux,
	type BridgeProductSessionAuthority,
} from '../bridge-product-session-authority.js';
import {
	assertBridgeProductResyncReconciliationMatchesRequest,
	bridgeProductControlRequestSchema,
	bridgeProductControlResponseSchema,
	bridgeProductMetadataFrameSchema,
	bridgeProductMetadataStreamRequestSchema,
	type BridgeProductControlRequest,
	type BridgeProductMetadataFrame,
	type BridgeProductMetadataStreamRequest,
} from '../bridge-product-session-contracts.js';
import type { BridgeProductSubscriptionKind } from '../bridge-product-subscription-contracts.js';
import {
	createBridgeProductTransport,
	type BridgeProductIdentifierPurpose,
} from '../bridge-product-transport.js';
import { bridgeProductViewAcknowledgementRequestSchema } from '../bridge-product-view-control-wire-contracts.js';
import { BridgeProductTestFactRecorder } from './bridge-product-test-fact-recorder.js';

export interface TransportHarness {
	readonly server: TestProductServer;
	readonly transport: ReturnType<typeof createBridgeProductTransport>;
	readonly whenSubscriptionsEnded: () => Promise<void>;
}

const activeHarnesses = new Set<TransportHarness>();

export async function disposeTransportHarnesses(): Promise<void> {
	const harnesses = [...activeHarnesses];
	try {
		for (const harness of harnesses) harness.server.shutdown();
		await Promise.all(harnesses.map((harness) => harness.whenSubscriptionsEnded()));
	} finally {
		activeHarnesses.clear();
	}
}

export function createTransportHarness(
	options: {
		readonly deadlineClock?: BridgeProductDeadlineClock;
		readonly fileEpoch?: number;
		readonly onSessionSuspect?: ConstructorParameters<
			typeof BridgeProductControlMux
		>[0]['onSessionSuspect'];
		readonly reviewEpoch?: number;
		readonly onViewRecoveryStatus?: Parameters<
			typeof createBridgeProductTransport
		>[0]['onViewRecoveryStatus'];
	} = {},
): TransportHarness {
	const authority: BridgeProductSessionAuthority = {
		bootstrap: {
			kind: 'productSession.bootstrap',
			paneSessionId: 'pane-session-1',
			policy: {
				maximumContentBytes: 2 * 1024 * 1024,
				maximumMetadataFrameBytes: 128 * 1024,
				maximumQueuedStreamBytes: 4 * 1024 * 1024,
				admissionRetryCount: 2,
				contentAcknowledgementDeadlineMilliseconds: 5_000,
				contentProgressDeadlineMilliseconds: 5_000,
				viewBatchProgressDeadlineMilliseconds: 5_000,
				streamKeepaliveIntervalMilliseconds: 350,
				telemetryPreReadyBufferMaxBytes: 64 * 1024,
				telemetryPreReadyBufferMaxSamples: 128,
				workerSettlementDeadlineMilliseconds: 5_000,
				viewAcknowledgementDeadlineMilliseconds: 4_000,
				viewCreditBytes: 524_288,
				viewCreditParts: 8,
				viewMaximumConsecutiveResnapshots: 3,
				viewMaximumDirtyKeys: 4_096,
				maximumQueuedStreamFrames: 64,
				maximumRequestBodyBytes: 256 * 1024,
				terminalFrameReserve: 1,
			},
			wireVersion: 2,
			workerInstanceId: 'worker-instance-1',
		},
		capabilityHeader: 'private-capability',
		open: Promise.resolve(),
	};
	const server = new TestProductServer();
	vi.stubGlobal('fetch', server.fetch);
	const controlMux = new BridgeProductControlMux({
		authority,
		createRequestId: sequenceIdentifier('control-request'),
		...(options.deadlineClock === undefined ? {} : { deadlineClock: options.deadlineClock }),
		executeProductRequest: executeAgentStudioBridgeProductRequest,
		...(options.onSessionSuspect === undefined
			? {}
			: { onSessionSuspect: options.onSessionSuspect }),
	});
	const subscriptionTerminals = new Set<Promise<void>>();
	const whenSubscriptionsEnded = async (): Promise<void> => {
		if (subscriptionTerminals.size === 0) return;
		await Promise.all(subscriptionTerminals);
		await whenSubscriptionsEnded();
	};
	const harness: TransportHarness = {
		server,
		whenSubscriptionsEnded,
		transport: createBridgeProductTransport({
			authority,
			controlMux,
			...(options.deadlineClock === undefined ? {} : { deadlineClock: options.deadlineClock }),
			createIdentifier: purposeIdentifier(),
			executeProductRequest: executeAgentStudioBridgeProductRequest,
			initialWorkerDerivationEpochs: {
				file: options.fileEpoch ?? 0,
				review: options.reviewEpoch ?? 0,
			},
			metadataApplicationRegistry: bridgeProductMetadataApplicationRegistry,
			...(options.onViewRecoveryStatus === undefined
				? {}
				: { onViewRecoveryStatus: options.onViewRecoveryStatus }),
		}),
	};
	const subscribe = harness.transport.subscribe.bind(harness.transport);
	harness.transport.subscribe = (protocol, options) => {
		const subscription = subscribe(protocol, options);
		// Application subscriptions carry terminal-only events; observation cannot steal a frame.
		const terminal = subscription.events[Symbol.asyncIterator]()
			.next()
			.then(
				(): void => {},
				(): void => {},
			)
			.finally((): void => {
				subscriptionTerminals.delete(terminal);
			});
		subscriptionTerminals.add(terminal);
		return subscription;
	};
	activeHarnesses.add(harness);
	return harness;
}

export class TestProductServer {
	readonly #frameAcknowledgementFacts =
		new BridgeProductTestFactRecorder<BridgeProductFrameAcknowledgementRequest>();
	#closed = false;
	readonly #shutdownSignal = createBridgeProductDeferred<never>();
	readonly #metadataOpenWaiters: {
		readonly count: number;
		readonly resolve: (request: BridgeProductMetadataStreamRequest) => void;
		readonly reject: (error: Error) => void;
	}[] = [];
	readonly #controlRequestWaiters: {
		readonly kind: BridgeProductControlRequest['kind'];
		readonly count: number;
		readonly resolve: (request: BridgeProductControlRequest) => void;
		readonly reject: (error: Error) => void;
	}[] = [];
	readonly #matchingControlRequestWaiters: {
		readonly matches: (request: BridgeProductControlRequest) => boolean;
		readonly resolve: (request: BridgeProductControlRequest) => void;
		readonly reject: (error: Error) => void;
	}[] = [];

	constructor() {
		void this.#shutdownSignal.promise.catch((): void => {});
	}
	readonly controlRequests: BridgeProductControlRequest[] = [];
	readonly #operationResults = new Map<string, unknown>();
	readonly #operationIdByRequestId = new Map<string, string>();
	#nextOperationOrdinal = 1;
	readonly frameAcknowledgements: BridgeProductFrameAcknowledgementRequest[] = [];
	productCallHandler:
		| ((
				request: Extract<BridgeProductControlRequest, { kind: 'product.call' }>,
		  ) => Promise<Response> | Response)
		| null = null;
	metadataFetchCount = 0;
	metadataReaderCancelCount = 0;
	nextAcknowledgementStatus = 204;
	cancelHandler:
		| ((
				request: Extract<BridgeProductControlRequest, { kind: 'subscription.cancel' }>,
		  ) => Promise<Response> | Response)
		| null = null;
	nextAcknowledgementHandler:
		| ((request: BridgeProductFrameAcknowledgementRequest) => Response | Promise<Response>)
		| null = null;
	resyncHandler:
		| ((
				request: Extract<BridgeProductControlRequest, { kind: 'workerSession.resync' }>,
		  ) => Promise<Response> | Response)
		| null = null;
	resnapshotHandler:
		| ((
				request: Extract<BridgeProductControlRequest, { kind: 'subscription.resnapshot' }>,
		  ) => Promise<Response> | Response)
		| null = null;
	readonly requestRoutes: string[] = [];
	#heldOpen: (() => void) | null = null;
	#holdOpen = false;
	#metadataControllers: ReadableStreamDefaultController<Uint8Array>[] = [];
	readonly #metadataRequests: BridgeProductMetadataStreamRequest[] = [];

	readonly fetch = async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
		if (this.#closed) throw new Error('Test product server is closed.');
		const url = input instanceof Request ? input.url : input instanceof URL ? input.href : input;
		this.requestRoutes.push(url);
		if (url === 'agentstudio://rpc/stream') return this.#openMetadataStream(init);
		if (url === 'agentstudio://rpc/command') {
			const body = parseBody(init);
			return typeof body === 'object' &&
				body !== null &&
				'kind' in body &&
				body.kind === 'content.acknowledge'
				? await Promise.race([this.#acknowledgeFrame(body), this.#shutdownSignal.promise])
				: await Promise.race([this.#handleControl(body), this.#shutdownSignal.promise]);
		}
		return new Response(null, { status: 404 });
	};

	async #acknowledgeFrame(body: unknown): Promise<Response> {
		const request = bridgeProductFrameAcknowledgementRequestSchema.parse(body);
		this.frameAcknowledgements.push(request);
		this.#frameAcknowledgementFacts.record(request);
		const handler = this.nextAcknowledgementHandler;
		this.nextAcknowledgementHandler = null;
		if (handler !== null) return handler(request);
		const status = this.nextAcknowledgementStatus;
		this.nextAcknowledgementStatus = 204;
		return new Response(null, { status });
	}

	emitMetadata(frame: BridgeProductMetadataFrame): void {
		const controller = this.#metadataControllers.at(-1);
		if (controller === undefined) throw new Error('Metadata stream is not open.');
		controller.enqueue(encodeBridgeProductMetadataFrame(frame));
	}

	emitMetadataPrefix(frame: BridgeProductMetadataFrame): void {
		const controller = this.#metadataControllers.at(-1);
		if (controller === undefined) throw new Error('Metadata stream is not open.');
		controller.enqueue(encodeBridgeProductMetadataFrame(frame).subarray(0, 2));
	}

	failMetadataReader(error: Error): void {
		const controller = this.#metadataControllers.at(-1);
		if (controller === undefined) throw new Error('Metadata stream is not open.');
		controller.error(error);
	}

	endMetadataStream(): void {
		const controller = this.#metadataControllers.at(-1);
		if (controller === undefined) throw new Error('Metadata stream is not open.');
		controller.close();
	}

	holdNextSubscriptionOpen(): void {
		this.#holdOpen = true;
	}

	releaseHeldSubscriptionOpen(): void {
		const release = this.#heldOpen;
		this.#heldOpen = null;
		release?.();
	}

	requiredControlRequest<TKind extends BridgeProductControlRequest['kind']>(
		kind: TKind,
		index: number,
	): Extract<BridgeProductControlRequest, { kind: TKind }> {
		const request = this.controlRequests.filter(
			(candidate): candidate is Extract<BridgeProductControlRequest, { kind: TKind }> =>
				candidate.kind === kind,
		)[index];
		if (request === undefined) throw new Error(`Missing control request ${kind} at ${index}.`);
		return request;
	}

	requiredMetadataRequest(
		index = this.#metadataRequests.length - 1,
	): BridgeProductMetadataStreamRequest {
		const request = this.#metadataRequests[index];
		if (request === undefined) throw new Error(`Missing metadata request at ${index}.`);
		return request;
	}

	waitForControlKind(
		kind: BridgeProductControlRequest['kind'],
		count = 1,
	): Promise<BridgeProductControlRequest> {
		return this.waitForControlRequest(kind, count);
	}

	waitForFrameAcknowledgementCount(
		count: number,
	): Promise<BridgeProductFrameAcknowledgementRequest> {
		return this.#frameAcknowledgementFacts.waitFor((): boolean => true, count);
	}

	waitForMetadataStream(count = 1): Promise<BridgeProductMetadataStreamRequest> {
		return this.waitForMetadataStreamOpened(count);
	}

	waitForMetadataStreamOpened(count = 1): Promise<BridgeProductMetadataStreamRequest> {
		const existing = this.#metadataRequests[count - 1];
		if (existing !== undefined) return Promise.resolve(existing);
		if (this.#closed)
			return Promise.reject(new Error('Test metadata server shut down before stream opened.'));
		return new Promise((resolve, reject) => {
			this.#metadataOpenWaiters.push({ count, resolve, reject });
		});
	}

	waitForControlRequest(
		kind: BridgeProductControlRequest['kind'],
		count = 1,
	): Promise<BridgeProductControlRequest> {
		const existing = this.controlRequests.filter((request) => request.kind === kind)[count - 1];
		if (existing !== undefined) return Promise.resolve(existing);
		if (this.#closed)
			return Promise.reject(new Error('Test metadata server shut down before control arrived.'));
		return new Promise((resolve, reject) => {
			this.#controlRequestWaiters.push({ kind, count, resolve, reject });
		});
	}

	waitForControlRequestWhere(
		matches: (request: BridgeProductControlRequest) => boolean,
	): Promise<BridgeProductControlRequest> {
		const existing = this.controlRequests.find(matches);
		if (existing !== undefined) return Promise.resolve(existing);
		if (this.#closed)
			return Promise.reject(
				new Error('Test metadata server shut down before matching control arrived.'),
			);
		return new Promise((resolve, reject) => {
			this.#matchingControlRequestWaiters.push({ matches, resolve, reject });
		});
	}

	shutdown(): void {
		if (this.#closed) return;
		this.#closed = true;
		this.#frameAcknowledgementFacts.close(
			new Error('Test metadata server shut down before acknowledgement arrived.'),
		);
		for (const waiter of this.#metadataOpenWaiters.splice(0)) {
			waiter.reject(new Error('Test metadata server shut down before stream opened.'));
		}
		for (const waiter of this.#controlRequestWaiters.splice(0)) {
			waiter.reject(new Error('Test metadata server shut down before control arrived.'));
		}
		for (const waiter of this.#matchingControlRequestWaiters.splice(0)) {
			waiter.reject(new Error('Test metadata server shut down before matching control arrived.'));
		}
		this.#shutdownSignal.reject(new Error('Test product server is closed.'));
		this.releaseHeldSubscriptionOpen();
		for (const controller of this.#metadataControllers) {
			try {
				controller.close();
			} catch {
				// A deliberately failed physical stream is already terminal.
			}
		}
		this.#metadataControllers = [];
	}

	#openMetadataStream(init?: RequestInit): Response {
		this.metadataFetchCount += 1;
		const request = bridgeProductMetadataStreamRequestSchema.parse(parseBody(init));
		this.#metadataRequests.push(request);
		const response = new Response(
			new ReadableStream<Uint8Array>({
				cancel: (): void => {
					this.metadataReaderCancelCount += 1;
				},
				start: (controller): void => {
					this.#metadataControllers.push(controller);
				},
			}),
		);
		for (const waiter of this.#metadataOpenWaiters.filter(
			(candidate) => candidate.count <= this.#metadataRequests.length,
		)) {
			const observed = this.#metadataRequests[waiter.count - 1];
			if (observed !== undefined) waiter.resolve(observed);
		}
		this.#metadataOpenWaiters.splice(
			0,
			this.#metadataOpenWaiters.length,
			...this.#metadataOpenWaiters.filter(
				(candidate) => candidate.count > this.#metadataRequests.length,
			),
		);
		return response;
	}

	async #handleControl(body: unknown): Promise<Response> {
		if (typeof body === 'object' && body !== null && 'kind' in body) {
			if (body.kind === 'subscription.acknowledge') {
				const request = bridgeProductViewAcknowledgementRequestSchema.parse(body);
				return jsonResponse({ ...request, kind: 'subscription.acknowledged' });
			}
			if (body.kind === 'operation.result') {
				const request = bridgeProductOperationResultRequestSchema.parse(body);
				if (!this.#operationResults.has(request.operationId)) {
					throw new Error('Result requested for an unknown test operation.');
				}
				return jsonResponse({
					failureCode: null,
					kind: 'operation.result',
					operationId: request.operationId,
					outcome: 'succeeded',
					result: this.#operationResults.get(request.operationId),
				});
			}
			if (body.kind === 'operation.resultAcknowledgement') {
				const request = bridgeProductOperationResultAcknowledgementSchema.parse(body);
				this.#operationResults.delete(request.operationId);
				return jsonResponse({ ...request, kind: 'operation.resultAcknowledged' });
			}
		}
		const request = bridgeProductControlRequestSchema.parse(body);
		this.controlRequests.push(request);
		for (const waiter of this.#matchingControlRequestWaiters.filter((candidate) =>
			candidate.matches(request),
		)) {
			waiter.resolve(request);
		}
		this.#matchingControlRequestWaiters.splice(
			0,
			this.#matchingControlRequestWaiters.length,
			...this.#matchingControlRequestWaiters.filter((candidate) => !candidate.matches(request)),
		);
		for (const waiter of this.#controlRequestWaiters.filter(
			(candidate) => candidate.kind === request.kind,
		)) {
			const observed = this.controlRequests.filter((candidate) => candidate.kind === waiter.kind)[
				waiter.count - 1
			];
			if (observed !== undefined) waiter.resolve(observed);
		}
		this.#controlRequestWaiters.splice(
			0,
			this.#controlRequestWaiters.length,
			...this.#controlRequestWaiters.filter(
				(candidate) =>
					this.controlRequests.filter(
						(candidateRequest) => candidateRequest.kind === candidate.kind,
					).length < candidate.count,
			),
		);
		if (request.kind === 'subscription.open' && this.#holdOpen) {
			this.#holdOpen = false;
			await new Promise<void>((resolve): void => {
				this.#heldOpen = resolve;
			});
		}
		const existingOperationId = this.#operationIdByRequestId.get(request.requestId);
		if (existingOperationId !== undefined)
			return this.#admittedResponse(request, existingOperationId);
		const finalResponse = await this.#finalControlResponse(request);
		if (request.kind === 'subscription.cancel' || finalResponse.status >= 400) {
			return finalResponse;
		}
		const result: unknown = await finalResponse.clone().json();
		if (
			typeof result === 'object' &&
			result !== null &&
			'kind' in result &&
			result.kind === 'request.error'
		) {
			return finalResponse;
		}
		const operationId = `test-operation-${this.#nextOperationOrdinal++}`;
		this.#operationIdByRequestId.set(request.requestId, operationId);
		this.#operationResults.set(operationId, result);
		return this.#admittedResponse(request, operationId);
	}

	#admittedResponse(request: BridgeProductControlRequest, operationId: string): Response {
		return jsonResponse({
			kind: 'operation.admitted',
			operationId,
			paneSessionId: request.paneSessionId,
			requestId: request.requestId,
			requestSequence: request.requestSequence,
			waitKind: 'ordinary',
			wireVersion: request.wireVersion,
			workerInstanceId: request.workerInstanceId,
		});
	}

	async #finalControlResponse(request: BridgeProductControlRequest): Promise<Response> {
		const identity = {
			paneSessionId: request.paneSessionId,
			requestId: request.requestId,
			requestSequence: request.requestSequence,
			wireVersion: request.wireVersion,
			workerInstanceId: request.workerInstanceId,
		};
		switch (request.kind) {
			case 'workerSession.open':
				return jsonResponse({ ...identity, kind: 'workerSession.accepted', result: null });
			case 'product.call':
				if (this.productCallHandler !== null) return await this.productCallHandler(request);
				return jsonResponse({
					...identity,
					call: {
						method: request.call.method,
						result:
							request.call.method === 'file.source.current'
								? { source: fileSourceConfiguration(), status: 'available' }
								: null,
					},
					kind: 'call.completed',
				});
			case 'subscription.open':
				return jsonResponse({
					...identity,
					...(request.subscription.subscriptionKind === 'file.annotations' ||
					request.subscription.subscriptionKind === 'review.annotations'
						? { worktreeId: '00000000-0000-4000-8000-000000000002' }
						: {}),
					kind: 'subscription.openAccepted',
					subscriptionId: request.subscriptionId,
					subscriptionKind: request.subscription.subscriptionKind,
				});
			case 'subscription.cancel':
				if (this.cancelHandler !== null) return await this.cancelHandler(request);
				return jsonResponse({
					...identity,
					kind: 'subscription.cancelAccepted',
					subscriptionId: request.subscriptionId,
					subscriptionKind: request.subscriptionKind,
				});
			case 'subscription.setScope':
				return jsonResponse({
					...identity,
					domain: request.domain,
					handle: request.handle,
					incarnation: request.incarnation,
					kind: 'subscription.scopeAccepted',
					scopeRevision: request.scopeRevision,
					subscriptionId: request.subscriptionId,
					subscriptionKind: request.subscriptionKind,
				});
			case 'subscription.resnapshot':
				if (this.resnapshotHandler !== null) return await this.resnapshotHandler(request);
				return jsonResponse({
					...identity,
					domain: request.domain,
					handle: request.handle,
					incarnation: request.incarnation,
					kind: 'subscription.resnapshotAccepted',
					scopeRevision: request.scopeRevision,
					subscriptionId: request.subscriptionId,
					subscriptionKind: request.subscriptionKind,
				});
			case 'workerSession.resync':
				if (this.resyncHandler !== null) return await this.resyncHandler(request);
				return jsonResponse(validatedRetainedResyncResponse(request, identity));
		}
		return assertNeverControlRequest(request);
	}
}

function validatedRetainedResyncResponse(
	request: Extract<BridgeProductControlRequest, { kind: 'workerSession.resync' }>,
	identity: {
		readonly paneSessionId: string;
		readonly requestId: string;
		readonly requestSequence: number;
		readonly wireVersion: 2;
		readonly workerInstanceId: string;
	},
): ReturnType<typeof bridgeProductControlResponseSchema.parse> {
	const response = bridgeProductControlResponseSchema.parse({
		...identity,
		kind: 'resync.accepted',
		metadataStreamSequenceBarrier: request.lastAcceptedStreamSequence,
		nextExpectedRequestSequence: request.requestSequence + 1,
		reconciliation: request.activeSubscriptions.map((subscription) => ({
			disposition: 'retained',
			subscriptionId: subscription.subscriptionId,
			subscriptionKind: subscription.subscriptionKind,
			workerDerivationEpoch: subscription.workerDerivationEpoch,
		})),
	});
	assertBridgeProductResyncReconciliationMatchesRequest({ request, response });
	return response;
}

export function metadataAccepted(
	request: BridgeProductMetadataStreamRequest,
	streamSequence: number,
	resumeDisposition: 'resumed' | 'snapshot_required' = 'snapshot_required',
): BridgeProductMetadataFrame {
	return bridgeProductMetadataFrameSchema.parse({
		...metadataIdentity(request, streamSequence),
		kind: 'metadataStream.accepted',
		resumeDisposition,
	});
}

export function subscriptionAccepted(props: {
	readonly epoch: number;
	readonly kind: BridgeProductSubscriptionKind;
	readonly request: BridgeProductMetadataStreamRequest;
	readonly streamSequence: number;
	readonly subscriptionId: string;
}): BridgeProductMetadataFrame {
	return bridgeProductMetadataFrameSchema.parse({
		...metadataIdentity(props.request, props.streamSequence),
		kind: 'subscription.accepted',
		subscriptionId: props.subscriptionId,
		subscriptionKind: props.kind,
		subscriptionSequence: 0,
		workerDerivationEpoch: props.epoch,
	});
}

export function subscriptionCancelled(props: {
	readonly epoch: number;
	readonly kind?: BridgeProductSubscriptionKind;
	readonly request: BridgeProductMetadataStreamRequest;
	readonly streamSequence: number;
	readonly subscriptionId: string;
	readonly subscriptionSequence?: number;
}): BridgeProductMetadataFrame {
	return bridgeProductMetadataFrameSchema.parse({
		...metadataIdentity(props.request, props.streamSequence),
		kind: 'subscription.cancelled',
		subscriptionId: props.subscriptionId,
		subscriptionKind: props.kind ?? 'review.metadata',
		subscriptionSequence: props.subscriptionSequence ?? 1,
		workerDerivationEpoch: props.epoch,
	});
}

export function requestErrorResponse(
	request: BridgeProductControlRequest,
	code: 'internal' | 'invalid_request' | 'resync_required',
	status = 200,
): Response {
	return new Response(
		JSON.stringify({
			code,
			kind: 'request.error',
			nextExpectedRequestSequence: request.requestSequence + 1,
			paneSessionId: request.paneSessionId,
			requestId: request.requestId,
			requestSequence: request.requestSequence,
			retryAfterMilliseconds: null,
			retryable: false,
			safeMessage: null,
			wireVersion: request.wireVersion,
			workerInstanceId: request.workerInstanceId,
		}),
		{ headers: { 'Content-Type': 'application/json' }, status },
	);
}

export function subscriptionReset(props: {
	readonly epoch: number;
	readonly kind: BridgeProductSubscriptionKind;
	readonly reason: 'stale_source';
	readonly request: BridgeProductMetadataStreamRequest;
	readonly streamSequence: number;
	readonly subscriptionId: string;
	readonly subscriptionSequence: number;
}): BridgeProductMetadataFrame {
	return bridgeProductMetadataFrameSchema.parse({
		...metadataIdentity(props.request, props.streamSequence),
		kind: 'subscription.reset',
		reason: props.reason,
		subscriptionId: props.subscriptionId,
		subscriptionKind: props.kind,
		subscriptionSequence: props.subscriptionSequence,
		workerDerivationEpoch: props.epoch,
	});
}

export function fileSourceConfiguration(): {
	readonly cwdScope: string | null;
	readonly freshness: 'live';
	readonly includeStatuses: boolean;
	readonly repoId: string;
	readonly rootPathToken: string;
	readonly worktreeId: string;
} {
	return {
		cwdScope: null,
		freshness: 'live',
		includeStatuses: true,
		repoId: '00000000-0000-4000-8000-000000000001',
		rootPathToken: 'root-token-1',
		worktreeId: '00000000-0000-4000-8000-000000000002',
	} as const;
}

export function fileSourceIdentity(sourceGeneration = 1): BridgeProductFileSourceIdentity {
	return {
		repoId: '00000000-0000-4000-8000-000000000001',
		rootRevisionToken: null,
		sourceCursor: `source-cursor-${sourceGeneration}`,
		sourceId: `source-${sourceGeneration}`,
		subscriptionGeneration: sourceGeneration,
		worktreeId: '00000000-0000-4000-8000-000000000002',
	} as const;
}

function metadataIdentity(
	request: BridgeProductMetadataStreamRequest,
	streamSequence: number,
): {
	readonly metadataStreamId: string;
	readonly paneSessionId: string;
	readonly streamSequence: number;
	readonly wireVersion: 2;
	readonly workerInstanceId: string;
} {
	return {
		metadataStreamId: request.metadataStreamId,
		paneSessionId: request.paneSessionId,
		streamSequence,
		wireVersion: request.wireVersion,
		workerInstanceId: request.workerInstanceId,
	};
}

function parseBody(init?: RequestInit): unknown {
	const body = init?.body;
	if (body instanceof ArrayBuffer) {
		return JSON.parse(new TextDecoder().decode(body)) as unknown;
	}
	if (ArrayBuffer.isView(body)) {
		return JSON.parse(new TextDecoder().decode(body)) as unknown;
	}
	throw new Error('Expected a binary request body.');
}

function jsonResponse(value: unknown): Response {
	return new Response(JSON.stringify(value), {
		headers: { 'Content-Type': 'application/json' },
		status: 200,
	});
}

function purposeIdentifier(): (purpose: BridgeProductIdentifierPurpose) => string {
	const sequenceByPurpose = new Map<BridgeProductIdentifierPurpose, number>();
	return (purpose): string => {
		const sequence = (sequenceByPurpose.get(purpose) ?? 0) + 1;
		sequenceByPurpose.set(purpose, sequence);
		return `${purpose}-${sequence}`;
	};
}

function sequenceIdentifier(prefix: string): () => string {
	let sequence = 0;
	return (): string => `${prefix}-${(sequence += 1)}`;
}

function assertNeverControlRequest(request: never): never {
	throw new Error(`Unhandled control request: ${JSON.stringify(request)}`);
}
