import { vi } from 'vitest';

import {
	BRIDGE_PRODUCT_DEV_BOOTSTRAP_ROUTE,
	decodeBridgeProductDevBootstrapDelivery,
} from '../../src/core/comm-worker/bridge-product-dev-bootstrap.js';
import {
	BridgeProductMetadataFrameDecoder,
	encodeBridgeProductMetadataFrame,
} from '../../src/core/comm-worker/bridge-product-metadata-frame-codec.js';
import {
	bridgeProductOperationResultRequestSchema,
	bridgeProductOperationResultResponseSchema,
} from '../../src/core/comm-worker/bridge-product-operation-wire-contracts.js';
import {
	bridgeProductControlRequestSchema,
	bridgeProductControlResponseSchema,
} from '../../src/core/comm-worker/bridge-product-session-contracts.js';

export type FileRecoveryFaultMode =
	| 'missing-begin'
	| 'exhausted-replacements'
	| 'certified-reset'
	| 'wrong-acknowledgement';

/** Faults only the wire; the backend, batch receiver and control admission stay real. */
export class FileRecoveryWireFault {
	readonly #mode: FileRecoveryFaultMode;
	#dropNextBegin = true;
	#dropPartFromBatch: string | null = null;
	#maximumResnapshots: number | null = null;
	#requestCount = 0;
	#droppedBeginCount = 0;

	constructor(mode: FileRecoveryFaultMode) {
		this.#mode = mode;
		const realFetch = globalThis.fetch;
		vi.spyOn(globalThis, 'fetch').mockImplementation(async (input, init): Promise<Response> => {
			const url = new URL(input instanceof Request ? input.url : input);
			const body: unknown = typeof init?.body === 'string' ? JSON.parse(init.body) : undefined;
			const controlRequest = bridgeProductControlRequestSchema.safeParse(body);
			if (controlRequest.success && controlRequest.data.kind === 'subscription.resnapshot') {
				this.#requestCount += 1;
				// A broken verifier must produce a finite red, rather than recover forever.
				if (this.#mode === 'exhausted-replacements' && this.#requestCount > this.maximumResnapshots)
					throw new Error('Wire fault observed a request beyond the advertised recovery maximum.');
			}
			const response = await realFetch(input, init);
			if (url.pathname === BRIDGE_PRODUCT_DEV_BOOTSTRAP_ROUTE) {
				const delivery = decodeBridgeProductDevBootstrapDelivery(
					await response.clone().arrayBuffer(),
				);
				this.#maximumResnapshots = delivery.bootstrap.policy.viewMaximumConsecutiveResnapshots;
				new Uint8Array(delivery.productCapability).fill(0);
			}
			if (
				this.#mode === 'wrong-acknowledgement' &&
				bridgeProductOperationResultRequestSchema.safeParse(body).success
			) {
				const result = bridgeProductOperationResultResponseSchema.parse(
					await response.clone().json(),
				);
				if (result.outcome === 'succeeded') {
					const control = bridgeProductControlResponseSchema.parse(result.result);
					if (control.kind === 'subscription.resnapshotAccepted')
						return new Response(
							JSON.stringify({
								...result,
								result: { ...control, handle: `${control.handle}-wrong` },
							}),
							{ status: response.status, headers: response.headers },
						);
				}
			}
			if (url.pathname !== '/__bridge-product/stream' || response.body === null) return response;
			const decoder = new BridgeProductMetadataFrameDecoder();
			return new Response(
				response.body.pipeThrough(
					new TransformStream<Uint8Array, Uint8Array>({
						transform: (chunk, controller): void => {
							for (const frame of decoder.push(chunk)) {
								if (frame.kind === 'subscription.batchBegin') {
									if (this.#dropNextBegin) {
										this.#dropNextBegin = false;
										this.#droppedBeginCount += 1;
										continue;
									}
									if (
										frame.mode === 'snapshot' &&
										(this.#mode === 'exhausted-replacements' ||
											(this.#mode === 'certified-reset' &&
												this.#requestCount % this.maximumResnapshots !== 0))
									)
										this.#dropPartFromBatch = frame.batchId;
								}
								if (
									frame.kind === 'subscription.batchPart' &&
									frame.batchId === this.#dropPartFromBatch
								) {
									this.#dropPartFromBatch = null;
									continue;
								}
								controller.enqueue(encodeBridgeProductMetadataFrame(frame));
							}
						},
						flush(): void {
							decoder.finish();
						},
					}),
				),
				{ status: response.status, headers: response.headers },
			);
		});
	}

	get maximumResnapshots(): number {
		if (this.#maximumResnapshots === null)
			throw new Error('Bootstrap recovery policy was not observed.');
		return this.#maximumResnapshots;
	}

	get requestCount(): number {
		return this.#requestCount;
	}
	get droppedBeginCount(): number {
		return this.#droppedBeginCount;
	}

	startNextRecoveryCycle(): void {
		this.#dropNextBegin = true;
	}
}
