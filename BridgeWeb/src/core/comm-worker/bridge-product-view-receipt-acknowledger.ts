import { postBridgeProductCommandBody } from './bridge-product-command-post.js';
import {
	defaultBridgeProductDeadlineClock,
	type BridgeProductDeadlineClock,
} from './bridge-product-deadline-clock.js';
import type { BridgeProductRequestExecutor } from './bridge-product-request-executor.js';
import type { BridgeProductSessionAuthority } from './bridge-product-session-authority.js';
import { parseBridgeProductStrictJSON } from './bridge-product-strict-json.js';
import {
	bridgeProductViewAcknowledgedResponseSchema,
	bridgeProductViewAcknowledgementRequestSchema,
	type BridgeProductViewAcknowledgementRequest,
} from './bridge-product-view-control-wire-contracts.js';

/** W4 returns credits on receipt, with one exact-replay ACK in flight per stream. */
export class BridgeProductViewReceiptAcknowledger {
	readonly #authority: BridgeProductSessionAuthority;
	readonly #deadlineClock: BridgeProductDeadlineClock;
	readonly #executeProductRequest: BridgeProductRequestExecutor;
	readonly #onExhausted: (request: BridgeProductViewAcknowledgementRequest) => void;
	readonly #pendingByView = new Map<string, BridgeProductViewAcknowledgementRequest>();
	readonly #idleWaiters: Array<() => void> = [];
	#active: Promise<void> | null = null;
	#activeAbortController: AbortController | null = null;
	#activeRequest: BridgeProductViewAcknowledgementRequest | null = null;
	#closed = false;

	constructor(props: {
		readonly authority: BridgeProductSessionAuthority;
		readonly deadlineClock?: BridgeProductDeadlineClock;
		readonly executeProductRequest: BridgeProductRequestExecutor;
		readonly onExhausted: (request: BridgeProductViewAcknowledgementRequest) => void;
	}) {
		this.#authority = props.authority;
		this.#deadlineClock = props.deadlineClock ?? defaultBridgeProductDeadlineClock;
		this.#executeProductRequest = props.executeProductRequest;
		this.#onExhausted = props.onExhausted;
	}

	received(props: {
		readonly domain: string;
		readonly handle: string;
		readonly incarnation: string;
		readonly receivedThroughDeliverySequence: number;
		readonly subscriptionId: string;
	}): void {
		if (this.#closed) return;
		const request = bridgeProductViewAcknowledgementRequestSchema.parse({
			...props,
			kind: 'subscription.acknowledge',
			paneSessionId: this.#authority.bootstrap.paneSessionId,
			wireVersion: this.#authority.bootstrap.wireVersion,
			workerInstanceId: this.#authority.bootstrap.workerInstanceId,
		});
		const viewKey = receiptViewKey(request);
		const pending = this.#pendingByView.get(viewKey);
		if (
			pending !== undefined &&
			pending.receivedThroughDeliverySequence >= request.receivedThroughDeliverySequence
		)
			return;
		this.#pendingByView.set(viewKey, request);
		this.#beginDrain();
	}

	retireSubscription(subscriptionId: string): void {
		for (const [viewKey, request] of this.#pendingByView) {
			if (request.subscriptionId === subscriptionId) this.#pendingByView.delete(viewKey);
		}
		if (this.#activeRequest?.subscriptionId === subscriptionId)
			this.#activeAbortController?.abort();
	}

	close(): void {
		this.#closed = true;
		this.#pendingByView.clear();
		this.#activeAbortController?.abort();
	}

	async waitForIdle(): Promise<void> {
		if (this.#active === null && this.#pendingByView.size === 0) return;
		await new Promise<void>((resolve) => this.#idleWaiters.push(resolve));
	}

	#beginDrain(): void {
		if (this.#active !== null || this.#closed) return;
		const drain = this.#drain();
		this.#active = drain;
		void drain.finally((): void => {
			this.#active = null;
			if (this.#pendingByView.size > 0 && !this.#closed) {
				this.#beginDrain();
				return;
			}
			const waiters = this.#idleWaiters.splice(0);
			for (const waiter of waiters) waiter();
		});
	}

	async #drain(): Promise<void> {
		while (!this.#closed && this.#pendingByView.size > 0) {
			const next = this.#pendingByView.entries().next().value;
			if (next === undefined) return;
			const [viewKey, request] = next;
			const acknowledged = await this.#sendExactWithRetry(request);
			if (!acknowledged) {
				const retired = !this.#pendingByView.has(viewKey);
				// Every pending credit for this view belongs to the unconfirmed bank.
				// Its resnapshot must start with a fresh receipt baseline.
				this.#pendingByView.delete(viewKey);
				if (!this.#closed && !retired) this.#onExhausted(request);
			} else if (this.#pendingByView.get(viewKey) === request) {
				this.#pendingByView.delete(viewKey);
			}
		}
	}

	async #sendExactWithRetry(request: BridgeProductViewAcknowledgementRequest): Promise<boolean> {
		for (
			let attempt = 0;
			attempt <= this.#authority.bootstrap.policy.admissionRetryCount;
			attempt += 1
		) {
			if (this.#closed || !this.#pendingByView.has(receiptViewKey(request))) return false;
			const controller = new AbortController();
			this.#activeAbortController = controller;
			this.#activeRequest = request;
			let cancelDeadline = (): void => {};
			let removeAbortListener = (): void => {};
			const deadline = new Promise<never>((_, reject): void => {
				const onAbort = (): void =>
					reject(new Error('Bridge product view acknowledgement retired.'));
				controller.signal.addEventListener('abort', onAbort, { once: true });
				removeAbortListener = (): void => controller.signal.removeEventListener('abort', onAbort);
				cancelDeadline = this.#deadlineClock.schedule(
					this.#authority.bootstrap.policy.viewAcknowledgementDeadlineMilliseconds,
					(): void => {
						controller.abort();
						reject(new Error('Bridge product view acknowledgement deadline elapsed.'));
					},
				);
			});
			try {
				const bytes = await Promise.race([
					postBridgeProductCommandBody({
						body: request,
						capabilityHeader: this.#authority.capabilityHeader,
						executeProductRequest: this.#executeProductRequest,
						signal: controller.signal,
					}),
					deadline,
				]);
				const response = bridgeProductViewAcknowledgedResponseSchema.parse(
					parseBridgeProductStrictJSON(bytes),
				);
				if (!matchesAcknowledgement(request, response)) return false;
				return true;
			} catch {
				// A missing reply is ambiguous: replay the exact request, not another credit.
			} finally {
				cancelDeadline();
				removeAbortListener();
				if (this.#activeAbortController === controller) {
					this.#activeAbortController = null;
					this.#activeRequest = null;
				}
			}
		}
		return false;
	}
}

function receiptViewKey(request: BridgeProductViewAcknowledgementRequest): string {
	return JSON.stringify([
		request.subscriptionId,
		request.domain,
		request.incarnation,
		request.handle,
	]);
}

function matchesAcknowledgement(
	request: BridgeProductViewAcknowledgementRequest,
	response: ReturnType<typeof bridgeProductViewAcknowledgedResponseSchema.parse>,
): boolean {
	return (
		request.domain === response.domain &&
		request.handle === response.handle &&
		request.incarnation === response.incarnation &&
		request.paneSessionId === response.paneSessionId &&
		request.receivedThroughDeliverySequence === response.receivedThroughDeliverySequence &&
		request.subscriptionId === response.subscriptionId &&
		request.wireVersion === response.wireVersion &&
		request.workerInstanceId === response.workerInstanceId
	);
}
