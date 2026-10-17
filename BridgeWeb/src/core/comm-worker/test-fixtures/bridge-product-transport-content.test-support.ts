import { vi } from 'vitest';

import { executeAgentStudioBridgeProductRequest } from '../bridge-product-agent-studio-request-executor.js';
import {
	bridgeProductContentIdentityFromDescriptor,
	bridgeProductContentRequestSchema,
	type BridgeProductContentRequest,
	type BridgeProductFileContentDescriptor,
} from '../bridge-product-content-contracts.js';
import {
	concatenateBytes,
	encodeMinimalControlFrame,
	encodeMinimalDataFrame,
} from '../bridge-product-content-frame-test-support.js';
import type { BridgeProductDeadlineClock } from '../bridge-product-deadline-clock.js';
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
	bridgeProductControlRequestSchema,
	bridgeProductMetadataFrameSchema,
	bridgeProductMetadataStreamRequestSchema,
	type BridgeProductControlRequest,
	type BridgeProductMetadataFrame,
	type BridgeProductMetadataStreamRequest,
} from '../bridge-product-session-contracts.js';
import {
	createBridgeProductTransport,
	type BridgeProductIdentifierPurpose,
} from '../bridge-product-transport.js';
import { BridgeProductTestFactRecorder } from './bridge-product-test-fact-recorder.js';

const abcSha256 = 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';

export function createContentTransportHarness(
	fileEpoch = 0,
	maximumConcurrentContentResponses?: number,
	frameAcknowledgementTimeoutMilliseconds?: number,
	deadlineClock?: BridgeProductDeadlineClock,
	viewCreditBytes?: number,
): {
	readonly server: TestContentProductServer;
	readonly transport: ReturnType<typeof createBridgeProductTransport>;
} {
	const authority: BridgeProductSessionAuthority = {
		bootstrap: {
			kind: 'productSession.bootstrap',
			paneSessionId: 'pane-session-1',
			policy: {
				contentAcknowledgementDeadlineMilliseconds:
					frameAcknowledgementTimeoutMilliseconds ?? 5_000,
				maximumContentBytes: 2 * 1024 * 1024,
				maximumMetadataFrameBytes: 256 * 1024,
				maximumQueuedStreamBytes: 4 * 1024 * 1024,
				admissionRetryCount: 2,
				contentProgressDeadlineMilliseconds: 5_000,
				viewBatchProgressDeadlineMilliseconds: 5_000,
				streamKeepaliveIntervalMilliseconds: 350,
				telemetryPreReadyBufferMaxBytes: 64 * 1024,
				telemetryPreReadyBufferMaxSamples: 128,
				workerSettlementDeadlineMilliseconds: 5_000,
				viewAcknowledgementDeadlineMilliseconds: 4_000,
				viewCreditBytes: viewCreditBytes ?? 524_288,
				viewCreditParts: 8,
				viewMaximumConsecutiveResnapshots: 3,
				viewMaximumDirtyKeys: 4_096,
				maximumQueuedStreamFrames: 64,
				maximumRequestBodyBytes: 128 * 1024,
				terminalFrameReserve: 1,
			},
			wireVersion: 2,
			workerInstanceId: 'worker-instance-1',
		},
		capabilityHeader: 'private-capability',
		open: Promise.resolve(),
	};
	const server = new TestContentProductServer();
	vi.stubGlobal('fetch', server.fetch);
	return {
		server,
		transport: createBridgeProductTransport({
			authority,
			controlMux: new BridgeProductControlMux({
				authority,
				createRequestId: sequenceIdentifier('control-request'),
				executeProductRequest: executeAgentStudioBridgeProductRequest,
			}),
			createIdentifier: purposeIdentifier(),
			executeProductRequest: executeAgentStudioBridgeProductRequest,
			initialWorkerDerivationEpochs: { file: fileEpoch, review: 0 },
			...(deadlineClock === undefined ? {} : { deadlineClock }),
			metadataApplicationRegistry: bridgeProductMetadataApplicationRegistry,
			...(maximumConcurrentContentResponses === undefined
				? {}
				: { maximumConcurrentContentResponses }),
		}),
	};
}

export class TestContentProductServer {
	readonly #heldContentReadFacts = new BridgeProductTestFactRecorder<string>();
	readonly #contentRequestFacts = new BridgeProductTestFactRecorder<BridgeProductContentRequest>();
	readonly #contentInvocationFacts = new BridgeProductTestFactRecorder<number>();
	readonly #frameAcknowledgementFacts =
		new BridgeProductTestFactRecorder<BridgeProductFrameAcknowledgementRequest>();
	readonly #metadataOpeningFacts =
		new BridgeProductTestFactRecorder<BridgeProductMetadataStreamRequest>();
	readonly #controlRequestFacts = new BridgeProductTestFactRecorder<BridgeProductControlRequest>();
	readonly contentRequestHeaders: {
		readonly capability: string | null;
		readonly contentType: string | null;
	}[] = [];
	readonly contentRequests: BridgeProductContentRequest[] = [];
	contentRequestInvocationCount = 0;
	contentReaderCancelCount = 0;
	metadataReaderCancelCount = 0;
	readonly controlRequests: BridgeProductControlRequest[] = [];
	readonly #operationResults = new Map<string, unknown>();
	readonly #operationIdByRequestId = new Map<string, string>();
	#nextOperationOrdinal = 1;
	readonly frameAcknowledgements: BridgeProductFrameAcknowledgementRequest[] = [];
	unknownReadRefusalCount = 0;
	readonly #contentBodyAfterOpeningAcknowledgement = new Map<string, () => void>();
	readonly #contentTerminalAfterDataAcknowledgement = new Map<string, () => void>();
	holdContentResponses = false;
	gateContentBodyOnOpeningAcknowledgement = false;
	leaveContentOpenAfterData = false;
	leaveContentOpenAfterTerminal = false;
	splitContentDataFrames = false;
	gateContentTerminalOnDataAcknowledgement = false;
	holdNextContentRequestBeforeResponse = false;
	leaveContentOpenAfterAcceptance = false;
	nextContentRequestFailure: Error | null = null;
	nextContentResponseKind: 'ordinary' | 'read-error' | 'unexpected-eof' = 'ordinary';
	nextAcknowledgementStatus = 204;
	mismatchNextUnknownReadRefusal = false;
	malformNextUnknownReadRefusal = false;
	loseNextAcknowledgementReply = false;
	resyncFailure: Error | null = null;
	readonly requestRoutes: string[] = [];
	#heldAcknowledgement: Promise<void> | null = null;
	#heldContentRequestId: string | null = null;
	#heldContentSequence: number | null = null;
	#metadataController: ReadableStreamDefaultController<Uint8Array> | null = null;
	#metadataRequest: BridgeProductMetadataStreamRequest | null = null;
	#releaseHeldContentRequestBeforeResponse: (() => void) | null = null;
	#releaseHeldAcknowledgement: (() => void) | null = null;

	readonly fetch = async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
		const url = input instanceof Request ? input.url : input instanceof URL ? input.href : input;
		this.requestRoutes.push(url);
		if (url === 'agentstudio://rpc/content') {
			this.contentRequestInvocationCount += 1;
			this.#contentInvocationFacts.record(this.contentRequestInvocationCount);
			if (this.holdNextContentRequestBeforeResponse) {
				this.holdNextContentRequestBeforeResponse = false;
				await new Promise<void>((resolve): void => {
					this.#releaseHeldContentRequestBeforeResponse = resolve;
				});
			}
			const requestFailure = this.nextContentRequestFailure;
			this.nextContentRequestFailure = null;
			if (requestFailure !== null) throw requestFailure;
			return this.#openContent(init);
		}
		if (url === 'agentstudio://rpc/stream') return this.#openMetadataStream(init);
		if (url !== 'agentstudio://rpc/command') return new Response(null, { status: 404 });
		const body = parseBody(init);
		if (
			typeof body === 'object' &&
			body !== null &&
			'kind' in body &&
			body.kind === 'content.acknowledge'
		) {
			return await this.#acknowledgeFrame(body);
		}
		return await this.#handleControl(body);
	};

	emitMetadata(frame: BridgeProductMetadataFrame): void {
		if (this.#metadataController === null) throw new Error('Metadata stream is not open.');
		this.#metadataController.enqueue(encodeBridgeProductMetadataFrame(frame));
	}

	holdContentAcknowledgement(
		contentRequestId: string,
		receivedThroughContentSequence?: number,
	): void {
		this.#heldContentRequestId = contentRequestId;
		this.#heldContentSequence = receivedThroughContentSequence ?? null;
		this.#heldAcknowledgement = new Promise<void>((resolve): void => {
			this.#releaseHeldAcknowledgement = resolve;
		});
	}

	releaseHeldContentAcknowledgement(): void {
		const release = this.#releaseHeldAcknowledgement;
		if (release === null) throw new Error('No content acknowledgement is held.');
		this.#heldAcknowledgement = null;
		this.#heldContentRequestId = null;
		this.#heldContentSequence = null;
		this.#releaseHeldAcknowledgement = null;
		release();
	}

	releaseHeldContentRequestBeforeResponse(): void {
		const release = this.#releaseHeldContentRequestBeforeResponse;
		if (release === null) throw new Error('No content request is held before response.');
		this.#releaseHeldContentRequestBeforeResponse = null;
		release();
	}

	requiredMetadataRequest(): BridgeProductMetadataStreamRequest {
		if (this.#metadataRequest === null) throw new Error('Metadata request is not available.');
		return this.#metadataRequest;
	}

	waitForContentRequestCount(count: number): Promise<BridgeProductContentRequest> {
		return this.#contentRequestFacts.waitFor((): boolean => true, count);
	}

	waitForContentRequestInvocationCount(count: number): Promise<number> {
		return this.#contentInvocationFacts.waitFor((invocations): boolean => invocations >= count);
	}

	waitForHeldContentReadStarted(contentRequestId: string): Promise<string> {
		return this.#heldContentReadFacts.waitFor((observed): boolean => observed === contentRequestId);
	}

	waitForFrameAcknowledgementCount(
		count: number,
	): Promise<BridgeProductFrameAcknowledgementRequest> {
		return this.#frameAcknowledgementFacts.waitFor((): boolean => true, count);
	}

	waitForMetadataStream(): Promise<BridgeProductMetadataStreamRequest> {
		return this.#metadataOpeningFacts.waitFor();
	}

	waitForControlRequestWhere(
		matches: (request: BridgeProductControlRequest) => boolean,
	): Promise<BridgeProductControlRequest> {
		return this.#controlRequestFacts.waitFor(matches);
	}

	async #acknowledgeFrame(body: unknown): Promise<Response> {
		const request = bridgeProductFrameAcknowledgementRequestSchema.parse(body);
		this.frameAcknowledgements.push(request);
		this.#frameAcknowledgementFacts.record(request);
		if (
			request.contentRequestId === this.#heldContentRequestId &&
			(this.#heldContentSequence === null ||
				request.receivedThroughContentSequence === this.#heldContentSequence)
		) {
			if (this.#heldAcknowledgement === null) throw new Error('Held acknowledgement is missing.');
			await this.#heldAcknowledgement;
		}
		const status = this.nextAcknowledgementStatus;
		this.nextAcknowledgementStatus = 204;
		if (this.loseNextAcknowledgementReply) {
			this.loseNextAcknowledgementReply = false;
			throw new Error('Synthetic lost acknowledgement reply.');
		}
		if (status === 204 && request.receivedThroughContentSequence === 0) {
			this.#contentBodyAfterOpeningAcknowledgement.get(request.contentRequestId)?.();
			this.#contentBodyAfterOpeningAcknowledgement.delete(request.contentRequestId);
		}
		if (status === 204 && request.receivedThroughContentSequence > 0) {
			this.#contentTerminalAfterDataAcknowledgement.get(request.contentRequestId)?.();
			this.#contentTerminalAfterDataAcknowledgement.delete(request.contentRequestId);
		}
		if (status === 404) {
			this.unknownReadRefusalCount += 1;
			if (this.malformNextUnknownReadRefusal) {
				this.malformNextUnknownReadRefusal = false;
				return jsonResponse({ kind: 'content.acknowledgementRefused' }, 404);
			}
			const contentRequestId = this.mismatchNextUnknownReadRefusal
				? 'content-request-foreign'
				: request.contentRequestId;
			this.mismatchNextUnknownReadRefusal = false;
			return jsonResponse(
				{
					contentRequestId,
					kind: 'content.acknowledgementRefused',
					leaseId: request.leaseId,
					paneSessionId: request.paneSessionId,
					reason: 'unknownRead',
					receivedThroughContentSequence: request.receivedThroughContentSequence,
					wireVersion: request.wireVersion,
					workerInstanceId: request.workerInstanceId,
				},
				404,
			);
		}
		return new Response(null, { status });
	}

	async #handleControl(body: unknown): Promise<Response> {
		if (typeof body === 'object' && body !== null && 'kind' in body) {
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
		this.#controlRequestFacts.record(request);
		if (request.kind === 'workerSession.resync' && this.resyncFailure !== null) {
			throw this.resyncFailure;
		}
		const existingOperationId = this.#operationIdByRequestId.get(request.requestId);
		if (existingOperationId !== undefined)
			return this.#admittedResponse(request, existingOperationId);
		const identity = {
			paneSessionId: request.paneSessionId,
			requestId: request.requestId,
			requestSequence: request.requestSequence,
			wireVersion: request.wireVersion,
			workerInstanceId: request.workerInstanceId,
		};
		let result: object;
		if (request.kind === 'product.call') {
			result = {
				...identity,
				call: { method: request.call.method, result: null },
				kind: 'call.completed',
			};
		} else if (request.kind === 'subscription.open') {
			result = {
				...identity,
				kind: 'subscription.openAccepted',
				subscriptionId: request.subscriptionId,
				subscriptionKind: request.subscription.subscriptionKind,
			};
		} else if (request.kind === 'subscription.setScope') {
			result = {
				...identity,
				domain: request.domain,
				handle: request.handle,
				incarnation: request.incarnation,
				kind: 'subscription.scopeAccepted',
				scopeRevision: request.scopeRevision,
				subscriptionId: request.subscriptionId,
				subscriptionKind: request.subscriptionKind,
			};
		} else {
			throw new Error(`Unexpected control request ${request.kind}.`);
		}
		const operationId = `content-test-operation-${this.#nextOperationOrdinal++}`;
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

	#openContent(init?: RequestInit): Response {
		const headers = new Headers(init?.headers);
		this.contentRequestHeaders.push({
			capability: headers.get('X-AgentStudio-Bridge-Product-Capability'),
			contentType: headers.get('Content-Type'),
		});
		const request = bridgeProductContentRequestSchema.parse(parseBody(init));
		this.contentRequests.push(request);
		this.#contentRequestFacts.record(request);
		const responseKind = this.nextContentResponseKind;
		this.nextContentResponseKind = 'ordinary';
		if (responseKind === 'unexpected-eof') {
			return new Response(Uint8Array.from([]));
		}
		if (responseKind === 'read-error') {
			return new Response(
				new ReadableStream<Uint8Array>({
					start: (controller): void => {
						controller.error(new Error('synthetic response read failure'));
					},
				}),
			);
		}
		if (this.holdContentResponses) {
			const responseStream = new ReadableStream<Uint8Array>({
				pull: (): void => {
					if (responseStream.locked) this.#heldContentReadFacts.record(request.contentRequestId);
				},
				cancel: (): void => {
					this.contentReaderCancelCount += 1;
				},
			});
			return new Response(responseStream);
		}
		const acceptedBody = {
			contentRequestId: request.contentRequestId,
			declaredByteLength: 3,
			expectedSha256: abcSha256,
			identity: bridgeProductContentIdentityFromDescriptor(request.descriptor),
			leaseId: request.leaseId,
			maximumBytes: request.descriptor.maximumBytes,
			operationCorrelationId: request.operationCorrelationId,
			paneSessionId: request.paneSessionId,
			wireVersion: request.wireVersion,
			workerDerivationEpoch: request.workerDerivationEpoch,
			workerInstanceId: request.workerInstanceId,
		};
		if (this.leaveContentOpenAfterAcceptance) {
			return new Response(
				new ReadableStream<Uint8Array>({
					cancel: (): void => {
						this.contentReaderCancelCount += 1;
					},
					start: (controller): void => {
						controller.enqueue(encodeMinimalControlFrame(0x01, 0, acceptedBody));
					},
				}),
			);
		}
		if (this.gateContentBodyOnOpeningAcknowledgement) {
			return new Response(
				new ReadableStream<Uint8Array>({
					cancel: (): void => {
						this.contentReaderCancelCount += 1;
						this.#contentBodyAfterOpeningAcknowledgement.delete(request.contentRequestId);
						this.#contentTerminalAfterDataAcknowledgement.delete(request.contentRequestId);
					},
					start: (controller): void => {
						controller.enqueue(encodeMinimalControlFrame(0x01, 0, acceptedBody));
						this.#contentBodyAfterOpeningAcknowledgement.set(request.contentRequestId, (): void => {
							controller.enqueue(
								encodeMinimalDataFrame(
									1,
									0,
									this.splitContentDataFrames
										? Uint8Array.from([97])
										: Uint8Array.from([97, 98, 99]),
									request.operationCorrelationId,
								),
							);
							if (this.splitContentDataFrames) {
								controller.enqueue(
									encodeMinimalDataFrame(
										2,
										1,
										Uint8Array.from([98, 99]),
										request.operationCorrelationId,
									),
								);
							}
							const finishContent = (): void => {
								controller.enqueue(
									encodeMinimalControlFrame(0x03, this.splitContentDataFrames ? 3 : 2, {
										endOfSource: true,
										observedByteLength: 3,
										observedSha256: abcSha256,
										operationCorrelationId: request.operationCorrelationId,
									}),
								);
								if (!this.leaveContentOpenAfterTerminal) controller.close();
							};
							if (this.leaveContentOpenAfterData) return;
							if (this.gateContentTerminalOnDataAcknowledgement) {
								this.#contentTerminalAfterDataAcknowledgement.set(
									request.contentRequestId,
									finishContent,
								);
							} else finishContent();
						});
					},
				}),
			);
		}
		return new Response(
			Uint8Array.from(
				concatenateBytes(
					encodeMinimalControlFrame(0x01, 0, acceptedBody),
					encodeMinimalDataFrame(
						1,
						0,
						Uint8Array.from([97, 98, 99]),
						request.operationCorrelationId,
					),
					encodeMinimalControlFrame(0x03, 2, {
						endOfSource: true,
						observedByteLength: 3,
						observedSha256: abcSha256,
						operationCorrelationId: request.operationCorrelationId,
					}),
				),
			).buffer,
		);
	}

	#openMetadataStream(init?: RequestInit): Response {
		this.#metadataRequest = bridgeProductMetadataStreamRequestSchema.parse(parseBody(init));
		this.#metadataOpeningFacts.record(this.#metadataRequest);
		return new Response(
			new ReadableStream<Uint8Array>({
				cancel: (): void => {
					this.metadataReaderCancelCount += 1;
				},
				start: (controller): void => {
					this.#metadataController = controller;
				},
			}),
		);
	}
}

export function metadataAccepted(
	request: BridgeProductMetadataStreamRequest,
): BridgeProductMetadataFrame {
	return bridgeProductMetadataFrameSchema.parse({
		kind: 'metadataStream.accepted',
		metadataStreamId: request.metadataStreamId,
		paneSessionId: request.paneSessionId,
		resumeDisposition: 'snapshot_required',
		streamSequence: 0,
		wireVersion: request.wireVersion,
		workerInstanceId: request.workerInstanceId,
	});
}

export function fileContentDescriptor(descriptorId: string): BridgeProductFileContentDescriptor {
	return {
		contentKind: 'file.content',
		declaredByteLength: 3,
		descriptorId,
		encoding: 'utf-8',
		expectedSha256: abcSha256,
		fileId: `file-${descriptorId}`,
		maximumBytes: 3,
		source: {
			repoId: '00000000-0000-4000-8000-000000000001',
			rootRevisionToken: null,
			sourceCursor: 'source-cursor-1',
			sourceId: 'source-1',
			subscriptionGeneration: 1,
			worktreeId: '00000000-0000-4000-8000-000000000002',
		},
		window: { kind: 'prefix', maximumBytes: 3, maximumLines: 10_000, startByte: 0 },
	} as const;
}

function parseBody(init?: RequestInit): unknown {
	const body = init?.body;
	if (body instanceof ArrayBuffer) return JSON.parse(new TextDecoder().decode(body)) as unknown;
	if (ArrayBuffer.isView(body)) return JSON.parse(new TextDecoder().decode(body)) as unknown;
	throw new Error('Expected a binary request body.');
}

function jsonResponse(value: unknown, status = 200): Response {
	return new Response(JSON.stringify(value), {
		headers: { 'Content-Type': 'application/json' },
		status,
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
