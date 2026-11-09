import { vi } from 'vitest';

import type { BridgeProductBatchFrame } from '../../src/core/comm-worker/bridge-product-batch-wire-contracts.js';
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
	type BridgeProductControlRequest,
} from '../../src/core/comm-worker/bridge-product-session-contracts.js';

export type FileRecoveryFaultMode =
	| 'missing-begin'
	| 'exhausted-replacements'
	| 'certified-reset'
	| 'wrong-acknowledgement';

/** Faults only the wire; the backend, batch receiver and control admission stay real. */
export class FileRecoveryWireFault {
	readonly #mode: FileRecoveryFaultMode;
	#beginToDrop: 'initialSnapshot' | 'nextScopedBatch' | null = 'initialSnapshot';
	#currentFileScope: Extract<
		BridgeProductControlRequest,
		{ kind: 'subscription.setScope' }
	> | null = null;
	#dropPartFromBatch: string | null = null;
	#maximumResnapshots: number | null = null;
	#requestCount = 0;
	#droppedBeginCount = 0;
	#correlationLogCount = 0;

	constructor(mode: FileRecoveryFaultMode) {
		this.#mode = mode;
		const realFetch = globalThis.fetch;
		vi.spyOn(globalThis, 'fetch').mockImplementation(async (input, init): Promise<Response> => {
			const url = new URL(input instanceof Request ? input.url : input);
			const body: unknown = typeof init?.body === 'string' ? JSON.parse(init.body) : undefined;
			const controlRequest = bridgeProductControlRequestSchema.safeParse(body);
			if (controlRequest.success && controlRequest.data.kind === 'subscription.setScope') {
				if (controlRequest.data.subscriptionKind === 'file.metadata') {
					this.#currentFileScope = controlRequest.data;
				}
				this.#recordCorrelation({
					event: 'setScope',
					handle: controlRequest.data.handle,
					incarnation: controlRequest.data.incarnation,
					scopeRevision: controlRequest.data.scopeRevision,
					subscriptionId: controlRequest.data.subscriptionId,
				});
			}
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
								const dropBegin =
									frame.kind === 'subscription.batchBegin' && this.#shouldDropBegin(frame);
								if (
									frame.kind === 'subscription.batchBegin' ||
									frame.kind === 'subscription.batchPart' ||
									frame.kind === 'subscription.batchComplete'
								) {
									this.#recordCorrelation({
										event: frame.kind,
										batchId: frame.batchId,
										handle: frame.handle,
										incarnation: frame.incarnation,
										scopeRevision: frame.scopeRevision,
										subscriptionId: frame.subscriptionId,
										willDropBegin: dropBegin,
										mode: frame.kind === 'subscription.batchBegin' ? frame.mode : undefined,
										snapshotCause:
											frame.kind === 'subscription.batchBegin' ? frame.snapshotCause : undefined,
									});
								}
								if (frame.kind === 'subscription.batchBegin') {
									if (dropBegin) {
										this.#beginToDrop = null;
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

	#recordCorrelation(
		correlation: Readonly<Record<string, string | number | boolean | undefined>>,
	): void {
		if (this.#correlationLogCount >= 64) return;
		this.#correlationLogCount += 1;
		process.stderr.write(`[file-recovery-correlation] ${JSON.stringify(correlation)}\n`);
	}

	#shouldDropBegin(
		frame: Extract<BridgeProductBatchFrame, { kind: 'subscription.batchBegin' }>,
	): boolean {
		const scope = this.#currentFileScope;
		if (scope === null || this.#beginToDrop === null) return false;
		// Startup change traffic can precede the initial snapshot on this same scope.
		// Fault the initial snapshot itself; explicit later cycles may fault a change.
		return (
			frame.subscriptionKind === 'file.metadata' &&
			frame.subscriptionId === scope.subscriptionId &&
			frame.domain === scope.domain &&
			frame.handle === scope.handle &&
			frame.incarnation === scope.incarnation &&
			frame.scopeRevision === scope.scopeRevision &&
			(this.#beginToDrop === 'nextScopedBatch' || frame.mode === 'snapshot')
		);
	}

	get requestCount(): number {
		return this.#requestCount;
	}
	get droppedBeginCount(): number {
		return this.#droppedBeginCount;
	}

	startNextRecoveryCycle(): void {
		this.#beginToDrop = 'nextScopedBatch';
	}
}
