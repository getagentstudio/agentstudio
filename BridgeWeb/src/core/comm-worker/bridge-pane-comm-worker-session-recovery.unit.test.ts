import { describe, expect, test } from 'vitest';

import pageConfigurationFixture from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-page-configuration.json' with { type: 'json' };
import {
	registerBridgeCommWorkerEntry,
	type BridgeCommWorkerGlobalScope,
} from './bridge-comm-worker-entry.js';
import { BridgePaneCommWorkerSession } from './bridge-pane-comm-worker-session.js';
import {
	RecordingPaneCommWorker,
	RecordingPaneCommWorkerClient,
	makeNativeBootstrap,
	makeRuntimeBootstrapRequest,
} from './bridge-pane-comm-worker-session.test-support.js';
import { createBridgeProductDeferred } from './bridge-product-async-queue.js';
import { BRIDGE_PRODUCT_WIRE_VERSION } from './bridge-product-contract-primitives.js';
import type { BridgeProductDeadlineClock } from './bridge-product-deadline-clock.js';
import {
	bridgeProductOperationResultAcknowledgementSchema,
	bridgeProductOperationResultRequestSchema,
} from './bridge-product-operation-wire-contracts.js';
import type { BridgeProductRequestExecutor } from './bridge-product-request-executor.js';
import {
	bridgePaneCommWorkerInstallSchema,
	bridgeProductControlRequestSchema,
} from './bridge-product-session-contracts.js';

describe('Bridge pane comm worker lost-admission recovery', () => {
	test('a suspect worker is replaced and the next session opens successfully', async () => {
		const clock = new ManualDeadlineClock();
		const oldAttempts = [
			createBridgeProductDeferred<void>(),
			createBridgeProductDeferred<void>(),
			createBridgeProductDeferred<void>(),
		];
		const oldBodies: string[] = [];
		const oldExecutor: BridgeProductRequestExecutor = async (_route, requestInit) => {
			const body = encodedBody(requestInit);
			const request = bridgeProductControlRequestSchema.parse(JSON.parse(body));
			if (request.kind !== 'workerSession.open') {
				throw new Error('The old worker must not execute after its open reply was lost.');
			}
			oldBodies.push(body);
			const attempt = oldAttempts[oldBodies.length - 1];
			if (attempt === undefined) throw new Error('The admission replay exceeded its budget.');
			attempt.resolve();
			return await new Promise<Response>(() => {});
		};
		const successorRequests: string[] = [];
		const successorExecutor: BridgeProductRequestExecutor = async (_route, requestInit) => {
			const body = encodedBody(requestInit);
			const requestBody = JSON.parse(body) as unknown;
			const resultRequest = bridgeProductOperationResultRequestSchema.safeParse(requestBody);
			if (resultRequest.success) {
				successorRequests.push('result');
				return jsonResponse({
					failureCode: null,
					kind: 'operation.result',
					operationId: resultRequest.data.operationId,
					outcome: 'succeeded',
					result: {
						kind: 'workerSession.accepted',
						paneSessionId: 'pane-session-1',
						requestId: 'worker-session-open-1',
						requestSequence: 1,
						result: null,
						wireVersion: BRIDGE_PRODUCT_WIRE_VERSION,
						workerInstanceId: 'recovery-worker-2',
					},
				});
			}
			const acknowledgement =
				bridgeProductOperationResultAcknowledgementSchema.safeParse(requestBody);
			if (acknowledgement.success) {
				successorRequests.push('acknowledgement');
				return jsonResponse({ ...acknowledgement.data, kind: 'operation.resultAcknowledged' });
			}
			const admission = bridgeProductControlRequestSchema.parse(requestBody);
			if (admission.kind !== 'workerSession.open') {
				throw new Error('Unexpected successor command.');
			}
			successorRequests.push('admission');
			return jsonResponse({
				kind: 'operation.admitted',
				operationId: 'operation-successor-open',
				paneSessionId: admission.paneSessionId,
				requestId: admission.requestId,
				requestSequence: admission.requestSequence,
				waitKind: 'ordinary',
				wireVersion: admission.wireVersion,
				workerInstanceId: admission.workerInstanceId,
			});
		};
		const firstWorker = new RunningPaneCommWorker(oldExecutor, clock);
		const secondWorker = new RunningPaneCommWorker(successorExecutor, clock);
		const workers = [firstWorker, secondWorker];
		const replacementRequested = createBridgeProductDeferred<void>();
		const successorReady = createBridgeProductDeferred<void>();
		const replacementReasons: string[] = [];
		const client = new RecordingPaneCommWorkerClient();
		const session = new BridgePaneCommWorkerSession({
			bootstrapTimeoutMilliseconds: pageConfigurationFixture.workerBootstrapDeadlineMilliseconds,
			requestNativeBootstrap: (reason): void => {
				replacementReasons.push(reason);
				replacementRequested.resolve();
			},
			workerFactory: (): Worker => {
				const nextWorker = workers.shift();
				if (nextWorker === undefined) throw new Error('Unexpected third worker.');
				return nextWorker;
			},
		});
		const bootstrapRequest = makeRuntimeBootstrapRequest('recovery-bootstrap');
		const dispatcher = session.createDispatcher({
			bootstrapRequest,
			publishWorkerMessages: (messages): void => {
				client.publish(messages);
				if (
					messages.some(
						(message): boolean => message.kind === 'health' && message.status === 'ready',
					)
				) {
					successorReady.resolve();
				}
			},
		});
		try {
			session.installNativeBootstrap(makeNativeBootstrap('recovery-worker-1'));
			for (const attempt of oldAttempts) {
				// Each next request exists only after the previous admission deadline fires.
				// oxlint-disable-next-line no-await-in-loop
				await attempt.promise;
				expect(clock.fireNext()).toBe(true);
			}
			await replacementRequested.promise;
			expect(oldBodies).toHaveLength(3);
			expect(new Set(oldBodies).size).toBe(1);
			expect(replacementReasons).toEqual(['workerReplacement']);
			expect(firstWorker.terminateCount).toBe(1);

			session.installNativeBootstrap(makeNativeBootstrap('recovery-worker-2'));
			await successorReady.promise;
			expect(successorRequests).toEqual(['admission', 'result', 'acknowledgement']);
			expect(replacementReasons).toEqual(['workerReplacement']);
		} finally {
			dispatcher.dispose();
			session.dispose();
		}
	});
});

class RunningPaneCommWorker extends RecordingPaneCommWorker {
	readonly #scopeEvents = new EventTarget();
	#installedPort: MessagePort | null = null;

	constructor(
		executeProductRequest: BridgeProductRequestExecutor,
		deadlineClock: BridgeProductDeadlineClock,
	) {
		super();
		const scope: BridgeCommWorkerGlobalScope = {
			addEventListener: (_type, listener): void => {
				this.#scopeEvents.addEventListener('message', (event): void => {
					if (event instanceof MessageEvent) listener(event);
				});
			},
			postMessage: (message): void => {
				this.dispatchEvent(new MessageEvent('message', { data: message }));
			},
		};
		registerBridgeCommWorkerEntry(scope, { deadlineClock, executeProductRequest });
	}

	override postMessage(message: unknown, transferList: Transferable[]): void;
	override postMessage(message: unknown, options?: StructuredSerializeOptions): void;
	override postMessage(
		message: unknown,
		transferListOrOptions: Transferable[] | StructuredSerializeOptions = [],
	): void {
		if (Array.isArray(transferListOrOptions)) {
			super.postMessage(message, transferListOrOptions);
		} else {
			super.postMessage(message, transferListOrOptions);
		}
		const delivered = this.globalPosts.at(-1)?.message;
		const parsedInstall = bridgePaneCommWorkerInstallSchema.safeParse(delivered);
		if (parsedInstall.success) {
			this.#installedPort = parsedInstall.data.productPort;
		}
		this.#scopeEvents.dispatchEvent(new MessageEvent('message', { data: delivered }));
	}

	override terminate(): void {
		this.#installedPort?.close();
		super.terminate();
	}
}

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

function encodedBody(requestInit: RequestInit): string {
	if (!(requestInit.body instanceof Uint8Array)) throw new Error('Expected encoded command bytes.');
	return new TextDecoder().decode(requestInit.body);
}

function jsonResponse(body: object): Response {
	return new Response(JSON.stringify(body), {
		headers: { 'Content-Type': 'application/json' },
		status: 200,
	});
}
