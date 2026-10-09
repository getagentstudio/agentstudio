import { createBridgeProductDeferred } from '../bridge-product-async-queue.js';
import {
	bridgeWorkerServerToMainMessageSchema,
	type BridgeWorkerServerToMainMessage,
} from '../bridge-worker-contracts.js';
import type {
	WindowedReviewBatchPart,
	WindowedReviewViewScopeRequest,
	WindowedReviewWorkerControlMessage,
	WindowedReviewWorkerControlReceipt,
} from './comm-runtime-protocol.review-windowed-publication.worker-test-fixture.js';

export class WindowedReviewWorkerHarness {
	readonly #controlPort: MessagePort;
	readonly #installed = harnessDeferred<void>();
	readonly #viewScopeReceived = harnessDeferred<void>();
	readonly #messageWaiters: Array<{
		readonly deferred: ReturnType<typeof harnessDeferred<BridgeWorkerServerToMainMessage>>;
		readonly predicate: (message: BridgeWorkerServerToMainMessage) => boolean;
	}> = [];
	readonly #processedByPartIndex = new Map<number, ReturnType<typeof harnessDeferred<void>>>();
	#failure: Error | null = null;
	#terminated = false;
	onViewScope: (request: WindowedReviewViewScopeRequest) => void = (): void => {};
	readonly observedMessages: BridgeWorkerServerToMainMessage[] = [];
	readonly worker: Worker;

	constructor() {
		this.worker = new Worker(
			new URL(
				'./comm-runtime-protocol.review-windowed-publication.worker-test-fixture.ts',
				import.meta.url,
			),
			{ type: 'module' },
		);
		const controlChannel = new MessageChannel();
		this.#controlPort = controlChannel.port2;
		this.worker.addEventListener('message', (event: MessageEvent<unknown>): void => {
			try {
				const message = bridgeWorkerServerToMainMessageSchema.parse(event.data);
				this.observedMessages.push(message);
				for (
					let waiterIndex = this.#messageWaiters.length - 1;
					waiterIndex >= 0;
					waiterIndex -= 1
				) {
					const waiter = this.#messageWaiters[waiterIndex];
					if (waiter === undefined || !waiter.predicate(message)) continue;
					this.#messageWaiters.splice(waiterIndex, 1);
					waiter.deferred.resolve(message);
				}
			} catch (error) {
				this.#fail(error);
			}
		});
		this.worker.addEventListener('error', (event: ErrorEvent): void => {
			this.#fail(new Error(event.message || 'Windowed Review worker failed.'));
		});
		this.worker.addEventListener('messageerror', (): void => {
			this.#fail(new Error('Windowed Review worker emitted an unreadable message.'));
		});
		this.#controlPort.addEventListener('message', (event: MessageEvent<unknown>): void => {
			if (!isWindowedReviewWorkerControlReceipt(event.data)) {
				this.#fail(new Error('Windowed Review worker emitted an invalid control receipt.'));
				return;
			}
			this.#acceptControlReceipt(event.data);
		});
		this.#controlPort.start();
		this.worker.postMessage(
			{
				controlPort: controlChannel.port1,
				kind: 'windowedReview.install',
			} satisfies WindowedReviewWorkerControlMessage,
			[controlChannel.port1],
		);
	}

	get installed(): Promise<void> {
		return this.#installed.promise;
	}

	publishBatchPart(part: WindowedReviewBatchPart): void {
		if (this.#failure !== null) throw this.#failure;
		if (this.#terminated) throw new Error('Windowed Review worker is terminated.');
		if (this.#processedByPartIndex.has(part.partIndex)) {
			throw new Error(`Review batch part ${part.partIndex} was already published.`);
		}
		this.#processedByPartIndex.set(part.partIndex, harnessDeferred<void>());
		this.#controlPort.postMessage({
			part,
			kind: 'windowedReview.batchPart.publish',
		} satisfies WindowedReviewWorkerControlMessage);
	}

	waitForViewScope(): Promise<void> {
		if (this.#failure !== null) return Promise.reject(this.#failure);
		return this.#viewScopeReceived.promise;
	}

	waitForMessage(
		predicate: (message: BridgeWorkerServerToMainMessage) => boolean,
	): Promise<BridgeWorkerServerToMainMessage> {
		if (this.#failure !== null) return Promise.reject(this.#failure);
		const existing = this.observedMessages.find(predicate);
		if (existing !== undefined) return Promise.resolve(existing);
		const deferred = harnessDeferred<BridgeWorkerServerToMainMessage>();
		this.#messageWaiters.push({ deferred, predicate });
		return deferred.promise;
	}

	waitUntilPartProcessed(partIndex: number): Promise<void> {
		if (this.#failure !== null) return Promise.reject(this.#failure);
		const processed = this.#processedByPartIndex.get(partIndex);
		if (processed === undefined) {
			throw new Error(`Review batch part ${partIndex} was not published.`);
		}
		return processed.promise;
	}

	terminate(): void {
		if (this.#terminated) return;
		this.#terminated = true;
		this.worker.terminate();
		this.#controlPort.close();
		this.#fail(new Error('Windowed Review worker test harness terminated.'));
	}

	#acceptControlReceipt(value: WindowedReviewWorkerControlReceipt): void {
		switch (value.kind) {
			case 'windowedReview.installed':
				this.#installed.resolve();
				return;
			case 'windowedReview.batchPart.processed': {
				const processed = this.#processedByPartIndex.get(value.partIndex);
				if (processed === undefined) {
					this.#fail(
						new Error(`Worker acknowledged unknown Review batch part ${value.partIndex}.`),
					);
					return;
				}
				processed.resolve();
				return;
			}
			case 'windowedReview.viewScope':
				this.onViewScope(value.request);
				this.#viewScopeReceived.resolve();
				return;
			case 'windowedReview.failed':
				this.#fail(new Error(value.message));
		}
	}

	#fail(error: unknown): void {
		const failure = error instanceof Error ? error : new Error(String(error));
		if (this.#failure !== null) return;
		this.#failure = failure;
		this.#installed.reject(failure);
		this.#viewScopeReceived.reject(failure);
		for (const waiter of this.#messageWaiters.splice(0, this.#messageWaiters.length)) {
			waiter.deferred.reject(failure);
		}
		for (const processed of this.#processedByPartIndex.values()) processed.reject(failure);
	}
}

function harnessDeferred<TValue>(): ReturnType<typeof createBridgeProductDeferred<TValue>> {
	const deferred = createBridgeProductDeferred<TValue>();
	void deferred.promise.catch((): void => {});
	return deferred;
}

function isWindowedReviewWorkerControlReceipt(
	value: unknown,
): value is WindowedReviewWorkerControlReceipt {
	if (typeof value !== 'object' || value === null || !('kind' in value)) return false;
	switch (value.kind) {
		case 'windowedReview.installed':
			return true;
		case 'windowedReview.batchPart.processed':
			return 'partIndex' in value && typeof value.partIndex === 'number';
		case 'windowedReview.viewScope':
			return 'request' in value;
		case 'windowedReview.failed':
			return 'message' in value && typeof value.message === 'string';
		default:
			return false;
	}
}
