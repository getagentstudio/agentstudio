import { describe, expect, test } from 'vitest';

import {
	registerBridgeCommWorkerEntry,
	type BridgeCommWorkerGlobalScope,
} from './bridge-comm-worker-entry.js';
import { createBridgeProductDeferred } from './bridge-product-async-queue.js';
import {
	BRIDGE_PRODUCT_CAPABILITY_BYTE_LENGTH,
	BRIDGE_PRODUCT_MAXIMUM_CONTENT_BYTES,
	BRIDGE_PRODUCT_MAXIMUM_METADATA_FRAME_BYTES,
	BRIDGE_PRODUCT_MAXIMUM_QUEUED_STREAM_BYTES,
	BRIDGE_PRODUCT_MAXIMUM_QUEUED_STREAM_FRAMES,
	BRIDGE_PRODUCT_MAXIMUM_REQUEST_BODY_BYTES,
	BRIDGE_PRODUCT_TERMINAL_FRAME_RESERVE,
	BRIDGE_PRODUCT_WIRE_VERSION,
} from './bridge-product-contract-primitives.js';
import type { BridgeProductDeadlineClock } from './bridge-product-deadline-clock.js';
import type { BridgeProductRequestExecutor } from './bridge-product-request-executor.js';
import { bridgeProductControlRequestSchema } from './bridge-product-session-contracts.js';
import {
	bridgeWorkerServerToMainWireMessageSchema,
	type BridgeWorkerServerToMainWireMessage,
} from './bridge-worker-contracts.js';

describe('Bridge comm worker session-suspect request', () => {
	test('exhausted admission replay emits one typed replacement request', async () => {
		const clock = new ManualDeadlineClock();
		const attempts = [
			createBridgeProductDeferred<void>(),
			createBridgeProductDeferred<void>(),
			createBridgeProductDeferred<void>(),
		];
		const admissionBodies: string[] = [];
		const executeProductRequest: BridgeProductRequestExecutor = async (_route, requestInit) => {
			if (!(requestInit.body instanceof Uint8Array)) {
				throw new Error('Expected encoded command bytes.');
			}
			const body = new TextDecoder().decode(requestInit.body);
			const request = bridgeProductControlRequestSchema.parse(JSON.parse(body));
			if (request.kind !== 'workerSession.open') {
				throw new Error('An unopened worker cannot issue a result request.');
			}
			admissionBodies.push(body);
			const attempt = attempts[admissionBodies.length - 1];
			if (attempt === undefined) throw new Error('Admission exceeded its retry budget.');
			attempt.resolve();
			return await new Promise<Response>(() => {});
		};
		const events = new EventTarget();
		const globalScope: BridgeCommWorkerGlobalScope = {
			addEventListener: (_type, listener): void => {
				events.addEventListener('message', (event: Event): void => {
					if (event instanceof MessageEvent) listener(event);
				});
			},
			postMessage: (): void => {},
		};
		const channel = new MessageChannel();
		const suspectSeen = createBridgeProductDeferred<void>();
		const terminalHealthSeen = createBridgeProductDeferred<void>();
		const observed: BridgeWorkerServerToMainWireMessage[] = [];
		channel.port2.addEventListener('message', (event: MessageEvent<unknown>): void => {
			const message = bridgeWorkerServerToMainWireMessageSchema.parse(event.data);
			observed.push(message);
			if (message.kind === 'sessionSuspect') suspectSeen.resolve();
			if (message.kind === 'health' && message.status === 'degraded') terminalHealthSeen.resolve();
		});
		channel.port2.start();

		try {
			registerBridgeCommWorkerEntry(globalScope, { deadlineClock: clock, executeProductRequest });
			events.dispatchEvent(
				new MessageEvent('message', {
					data: {
						bootstrap: {
							kind: 'productSession.bootstrap',
							paneSessionId: 'pane-suspect',
							policy: {
								maximumContentBytes: BRIDGE_PRODUCT_MAXIMUM_CONTENT_BYTES,
								maximumMetadataFrameBytes: BRIDGE_PRODUCT_MAXIMUM_METADATA_FRAME_BYTES,
								maximumQueuedStreamBytes: BRIDGE_PRODUCT_MAXIMUM_QUEUED_STREAM_BYTES,
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
								maximumQueuedStreamFrames: BRIDGE_PRODUCT_MAXIMUM_QUEUED_STREAM_FRAMES,
								maximumRequestBodyBytes: BRIDGE_PRODUCT_MAXIMUM_REQUEST_BODY_BYTES,
								terminalFrameReserve: BRIDGE_PRODUCT_TERMINAL_FRAME_RESERVE,
							},
							wireVersion: BRIDGE_PRODUCT_WIRE_VERSION,
							workerInstanceId: 'worker-suspect',
						},
						kind: 'bridgePaneCommWorker.install',
						productCapability: new ArrayBuffer(BRIDGE_PRODUCT_CAPABILITY_BYTE_LENGTH),
						productPort: channel.port1,
					},
				}),
			);
			channel.port2.postMessage({
				method: 'bridgeCommWorker.bootstrap',
				requestId: 'suspect-bootstrap',
				runtime: {
					bridgeDemandRank: { lane: 'selected', priority: 0 },
					budget: { className: 'interactive', maxBytes: 512 * 1024, maxWindowLines: 400 },
				},
				schemaVersion: 1,
			});
			for (const attempt of attempts) {
				await attempt.promise;
				expect(clock.fireNext()).toBe(true);
			}
			await Promise.all([suspectSeen.promise, terminalHealthSeen.promise]);
			expect(admissionBodies).toHaveLength(3);
			expect(new Set(admissionBodies).size).toBe(1);
			expect(observed.filter((message) => message.kind === 'sessionSuspect')).toEqual([
				expect.objectContaining({
					paneSessionId: 'pane-suspect',
					reason: 'admissionReplyExhausted',
					workerInstanceId: 'worker-suspect',
				}),
			]);
		} finally {
			channel.port1.close();
			channel.port2.close();
		}
	});
});

class ManualDeadlineClock implements BridgeProductDeadlineClock {
	readonly #scheduled: Array<{ active: boolean; onDeadline: () => void }> = [];

	schedule(_delayMilliseconds: number, onDeadline: () => void): () => void {
		const deadline = { active: true, onDeadline };
		this.#scheduled.push(deadline);
		return (): void => {
			deadline.active = false;
		};
	}

	fireNext(): boolean {
		const deadline = this.#scheduled.find((candidate): boolean => candidate.active);
		if (deadline === undefined) return false;
		deadline.active = false;
		deadline.onDeadline();
		return true;
	}
}
