import {
	createServer,
	request as requestHTTP,
	type IncomingMessage,
	type ServerResponse,
} from 'node:http';
import type { Socket } from 'node:net';

import { BRIDGE_PRODUCT_MAXIMUM_REQUEST_BODY_BYTES } from '../../src/core/comm-worker/bridge-product-contract-primitives.js';
import type { BridgeProductMetadataFrame } from '../../src/core/comm-worker/bridge-product-session-contracts.js';
import {
	bridgeProductViewAcknowledgementRequestSchema,
	type BridgeProductViewAcknowledgementRequest,
} from '../../src/core/comm-worker/bridge-product-view-control-wire-contracts.js';
import { BridgeFileRenewalWireObserver } from './bridge-viewer-vite-file-renewal-observer.ts';
import {
	BridgeSemanticBatchFaultTransformer,
	type BridgeSemanticBatchFaultApplied,
	type BridgeSemanticBatchFaultPlan,
	type BridgeSemanticBatchKind,
} from './bridge-viewer-vite-semantic-batch-fault.ts';

interface SemanticMetadataResponse {
	readonly transformer: BridgeSemanticBatchFaultTransformer;
	readonly write: (encodedFrames: readonly Uint8Array[]) => void;
}

export interface BridgeLostViewAcknowledgement {
	readonly domain: string;
	readonly exactReplayObserved: true;
	readonly receivedThroughDeliverySequence: number;
	readonly subscriptionId: string;
}

interface BridgeSemanticMetadataClosure {
	readonly cause: string;
	readonly lastForwardedStreamSequence: number | null;
	readonly observedKinds: readonly BridgeSemanticBatchKind[];
	readonly responseId: number;
}

export interface BridgeStreamFaultProxy {
	readonly origin: string;
	readonly disconnectMetadata: () => number;
	readonly armSemanticBatchFault: (
		plan: BridgeSemanticBatchFaultPlan,
	) => Promise<BridgeSemanticBatchFaultApplied>;
	readonly releaseStalledBatchPart: () => void;
	readonly waitForBatchComplete: (batchId: string) => Promise<void>;
	readonly loseNextViewAcknowledgement: (
		subscriptionId: string,
	) => Promise<BridgeLostViewAcknowledgement>;
	readonly snapshot: () => {
		readonly activeMetadataResponses: number;
		readonly metadataRequestCount: number;
		readonly metadataByteCount: number;
		readonly fileRenewal: readonly ReturnType<BridgeFileRenewalWireObserver['snapshot']>[];
		readonly semanticFaultsApplied: readonly BridgeSemanticBatchFaultApplied[];
		readonly semanticKindsByResponse: readonly (readonly BridgeSemanticBatchKind[])[];
		readonly lostViewAcknowledgements: readonly BridgeLostViewAcknowledgement[];
		readonly semanticMetadataClosures: readonly BridgeSemanticMetadataClosure[];
	};
	readonly stop: () => Promise<void>;
}

// Test-only wire seam. The default disconnect path forwards real Vite/Swift bytes unchanged.
// Opt-in semantic mode re-encodes metadata frames and renumbers their physical stream sequence.
// Neither path implements reconnect or changes production protocol behavior.
export async function startBridgeStreamFaultProxy(
	upstreamOrigin: string,
	options: {
		readonly semanticBatchFaults?: boolean;
		readonly onMetadataFrame?: (frame: BridgeProductMetadataFrame) => void;
	} = {},
): Promise<BridgeStreamFaultProxy> {
	const connections = new Set<Socket>();
	const metadataResponses = new Set<ServerResponse>();
	const semanticResponses = new Set<SemanticMetadataResponse>();
	const semanticFaultsApplied: BridgeSemanticBatchFaultApplied[] = [];
	let stalledResponse: SemanticMetadataResponse | null = null;
	let pendingAckLoss: {
		readonly subscriptionId: string;
		readonly resolve: (observation: BridgeLostViewAcknowledgement) => void;
		readonly reject: (error: Error) => void;
	} | null = null;
	let lostAckRequestBytes: Buffer | null = null;
	let lostAckIdentity: Omit<BridgeLostViewAcknowledgement, 'exactReplayObserved'> | null = null;
	const lostViewAcknowledgements: BridgeLostViewAcknowledgement[] = [];
	const semanticMetadataClosures: BridgeSemanticMetadataClosure[] = [];
	const forwardedBatchCompletes = new Set<string>();
	const batchCompleteWaiters = new Map<string, () => void>();
	let metadataRequestCount = 0;
	let metadataByteCount = 0;
	const fileRenewalObservers: BridgeFileRenewalWireObserver[] = [];
	const server = createServer((incomingRequest, outgoingResponse): void => {
		const destination = new URL(incomingRequest.url ?? '/', upstreamOrigin);
		const isMetadata = destination.pathname === '/__bridge-product/stream';
		const captureCommand =
			options.semanticBatchFaults === true &&
			destination.pathname === '/__bridge-product/command' &&
			(pendingAckLoss !== null || lostAckRequestBytes !== null);
		let loseAckResponse = false;
		let exactAckReplay = false;
		const transformMetadata = isMetadata && options.semanticBatchFaults === true;
		if (isMetadata) metadataRequestCount += 1;
		const responseId = metadataRequestCount;
		let closureCause: string | null = null;
		let diagnosticTransformer: BridgeSemanticBatchFaultTransformer | null = null;
		const recordClosureCause = (cause: string): void => {
			closureCause ??= cause;
		};
		const requestHeaders = { ...incomingRequest.headers, host: destination.host };
		if (transformMetadata) requestHeaders['accept-encoding'] = 'identity';
		const upstreamRequest = requestHTTP(
			destination,
			{
				method: incomingRequest.method,
				headers: requestHeaders,
			},
			(upstreamResponse): void => {
				if (loseAckResponse) {
					upstreamResponse.resume();
					upstreamResponse.once('end', (): void => {
						outgoingResponse.destroy();
					});
					return;
				}
				if (exactAckReplay) {
					upstreamResponse.once('end', (): void => {
						const identity = lostAckIdentity;
						const pendingLoss = pendingAckLoss;
						if (identity === null || pendingLoss === null) return;
						const observation = { ...identity, exactReplayObserved: true } as const;
						lostViewAcknowledgements.push(observation);
						lostAckIdentity = null;
						lostAckRequestBytes = null;
						pendingAckLoss = null;
						pendingLoss.resolve(observation);
					});
				}
				const responseHeaders = { ...upstreamResponse.headers };
				if (transformMetadata) {
					delete responseHeaders['content-length'];
					delete responseHeaders['transfer-encoding'];
				}
				outgoingResponse.writeHead(upstreamResponse.statusCode ?? 502, responseHeaders);
				outgoingResponse.flushHeaders();
				if (isMetadata) {
					const observer = new BridgeFileRenewalWireObserver();
					fileRenewalObservers.push(observer);
					metadataResponses.add(outgoingResponse);
					const semanticResponse: SemanticMetadataResponse | null = transformMetadata
						? {
								transformer: new BridgeSemanticBatchFaultTransformer(
									options.onMetadataFrame,
									(frame): void => {
										if (frame.kind !== 'subscription.batchComplete') return;
										forwardedBatchCompletes.add(frame.batchId);
										batchCompleteWaiters.get(frame.batchId)?.();
										batchCompleteWaiters.delete(frame.batchId);
									},
								),
								write: (encodedFrames): void => {
									for (const frame of encodedFrames) {
										if (!outgoingResponse.write(frame)) upstreamResponse.pause();
									}
								},
							}
						: null;
					diagnosticTransformer = semanticResponse?.transformer ?? null;
					if (semanticResponse !== null) {
						semanticResponses.add(semanticResponse);
						outgoingResponse.on('drain', (): void => {
							upstreamResponse.resume();
						});
					}
					upstreamResponse.on('data', (chunk: Buffer): void => {
						metadataByteCount += chunk.byteLength;
						observer.observe(chunk);
						if (semanticResponse === null) return;
						try {
							semanticResponse.write(semanticResponse.transformer.push(chunk));
							const applied = semanticResponse.transformer.snapshotAppliedFault();
							if (applied !== null && semanticFaultsApplied.at(-1) !== applied) {
								semanticFaultsApplied.push(applied);
								if (applied.mode === 'stall') stalledResponse = semanticResponse;
							}
						} catch (error) {
							recordClosureCause(`transform exception: ${String(error)}`);
							outgoingResponse.destroy(error instanceof Error ? error : undefined);
						}
					});
					if (semanticResponse !== null) {
						upstreamResponse.once('end', (): void => {
							recordClosureCause('upstream end');
							try {
								semanticResponse.transformer.finish();
								outgoingResponse.end();
							} catch (error) {
								recordClosureCause(`decoder finish failure: ${String(error)}`);
								outgoingResponse.destroy(error instanceof Error ? error : undefined);
							}
						});
					}
					outgoingResponse.once('close', (): void => {
						recordClosureCause('downstream close');
						if (semanticResponse !== null) {
							semanticMetadataClosures.push({
								cause: closureCause ?? 'unknown',
								lastForwardedStreamSequence:
									semanticResponse.transformer.lastForwardedStreamSequence,
								observedKinds: semanticResponse.transformer.observedKinds,
								responseId,
							});
							semanticResponse.transformer.close();
							semanticResponses.delete(semanticResponse);
						}
					});
				}
				upstreamResponse.on('error', (error): void => {
					recordClosureCause(`upstream error: ${String(error)}`);
					outgoingResponse.destroy();
				});
				outgoingResponse.once('close', (): void => {
					upstreamResponse.destroy();
				});
				if (!transformMetadata) upstreamResponse.pipe(outgoingResponse);
			},
		);
		upstreamRequest.on('error', (error): void => {
			recordClosureCause(`upstream request error: ${String(error)}`);
			outgoingResponse.destroy();
		});
		incomingRequest.once('aborted', (): void => {
			recordClosureCause('downstream request aborted');
			upstreamRequest.destroy();
		});
		outgoingResponse.once('close', (): void => {
			if (isMetadata && diagnosticTransformer === null) {
				semanticMetadataClosures.push({
					cause: closureCause ?? 'downstream close before response',
					lastForwardedStreamSequence: null,
					observedKinds: [],
					responseId,
				});
			}
			metadataResponses.delete(outgoingResponse);
			upstreamRequest.destroy();
		});
		if (captureCommand) {
			void readBoundedCommandBody(incomingRequest)
				.then((body): void => {
					const acknowledgement = parseViewAcknowledgement(body);
					if (
						acknowledgement !== null &&
						pendingAckLoss !== null &&
						acknowledgement.subscriptionId === pendingAckLoss.subscriptionId
					) {
						if (lostAckRequestBytes === null) {
							loseAckResponse = true;
							lostAckRequestBytes = body;
							lostAckIdentity = {
								domain: acknowledgement.domain,
								receivedThroughDeliverySequence: acknowledgement.receivedThroughDeliverySequence,
								subscriptionId: acknowledgement.subscriptionId,
							};
						} else if (body.equals(lostAckRequestBytes)) {
							exactAckReplay = true;
						}
					}
					upstreamRequest.end(body);
				})
				.catch((error: unknown): void => {
					upstreamRequest.destroy(error instanceof Error ? error : undefined);
					outgoingResponse.destroy(error instanceof Error ? error : undefined);
				});
		} else {
			incomingRequest.pipe(upstreamRequest);
		}
	});
	server.on('connection', (socket): void => {
		connections.add(socket);
		socket.once('close', (): void => {
			connections.delete(socket);
		});
	});
	await new Promise<void>((resolve, reject): void => {
		server.once('error', reject);
		server.listen(0, '127.0.0.1', resolve);
	});
	const address = server.address();
	if (address === null || typeof address === 'string')
		throw new Error('Fault proxy has no TCP address.');
	return {
		origin: `http://127.0.0.1:${address.port}`,
		waitForBatchComplete: (batchId): Promise<void> => {
			if (forwardedBatchCompletes.has(batchId)) return Promise.resolve();
			return new Promise((resolve): void => {
				batchCompleteWaiters.set(batchId, resolve);
			});
		},
		disconnectMetadata: (): number => {
			const count = metadataResponses.size;
			for (const response of metadataResponses) response.destroy();
			return count;
		},
		armSemanticBatchFault: (plan): Promise<BridgeSemanticBatchFaultApplied> => {
			if (options.semanticBatchFaults !== true) {
				throw new Error('Semantic faults require a semantic fault proxy.');
			}
			const candidates = [...semanticResponses].filter((response) =>
				response.transformer.observedKinds.includes(plan.subscriptionKind),
			);
			if (candidates.length !== 1) {
				throw new Error(
					`Expected one live metadata response for ${plan.subscriptionKind}, found ${candidates.length}.`,
				);
			}
			const target = candidates[0];
			if (target === undefined) throw new Error('Semantic metadata response was not selected.');
			target.transformer.arm(plan);
			const applied = target.transformer.waitForAppliedFault();
			void applied.catch((): void => {});
			return applied;
		},
		releaseStalledBatchPart: (): void => {
			const response = stalledResponse;
			if (response === null || !semanticResponses.has(response)) {
				throw new Error('No live stalled metadata response is available.');
			}
			response.write(response.transformer.releaseStalledPart());
			stalledResponse = null;
		},
		loseNextViewAcknowledgement: (
			subscriptionId: string,
		): Promise<BridgeLostViewAcknowledgement> => {
			if (options.semanticBatchFaults !== true || pendingAckLoss !== null) {
				throw new Error('A semantic proxy with no active ACK loss is required.');
			}
			const recovered = new Promise<BridgeLostViewAcknowledgement>((resolve, reject): void => {
				pendingAckLoss = { reject, resolve, subscriptionId };
			});
			void recovered.catch((): void => {});
			return recovered;
		},
		snapshot: () => ({
			activeMetadataResponses: metadataResponses.size,
			metadataRequestCount,
			metadataByteCount,
			fileRenewal: fileRenewalObservers.map((observer) => observer.snapshot()),
			semanticFaultsApplied: [...semanticFaultsApplied],
			semanticKindsByResponse: [...semanticResponses].map(
				(response) => response.transformer.observedKinds,
			),
			lostViewAcknowledgements: [...lostViewAcknowledgements],
			semanticMetadataClosures: [...semanticMetadataClosures],
		}),
		stop: async (): Promise<void> => {
			for (const response of semanticResponses) response.transformer.close();
			pendingAckLoss?.reject(new Error('Fault proxy stopped before the view ACK replay settled.'));
			pendingAckLoss = null;
			await new Promise<void>((resolve, reject): void => {
				server.close((error): void => (error === undefined ? resolve() : reject(error)));
				for (const socket of connections) socket.destroy();
			});
		},
	};
}

async function readBoundedCommandBody(request: IncomingMessage): Promise<Buffer> {
	const chunks: Buffer[] = [];
	let byteCount = 0;
	for await (const chunk of request) {
		const chunkValue: unknown = chunk;
		if (!(chunkValue instanceof Uint8Array)) {
			throw new Error('Fault proxy received a non-byte command chunk.');
		}
		const bytes = Buffer.from(chunkValue);
		byteCount += bytes.byteLength;
		if (byteCount > BRIDGE_PRODUCT_MAXIMUM_REQUEST_BODY_BYTES) {
			throw new Error('Fault proxy command body exceeds the product request ceiling.');
		}
		chunks.push(bytes);
	}
	return Buffer.concat(chunks, byteCount);
}

function parseViewAcknowledgement(body: Buffer): BridgeProductViewAcknowledgementRequest | null {
	let decoded: unknown;
	try {
		decoded = JSON.parse(body.toString('utf8'));
	} catch {
		return null;
	}
	const acknowledgement = bridgeProductViewAcknowledgementRequestSchema.safeParse(decoded);
	return acknowledgement.success ? acknowledgement.data : null;
}
