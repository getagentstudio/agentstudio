import type { ConsoleMessage, Page, Route } from 'playwright';

import { createBridgeProductDeferred } from '../../src/core/comm-worker/bridge-product-async-queue.js';
import {
	bridgeProductAdmissionResponseSchema,
	bridgeProductOperationResultAcknowledgementSchema,
	bridgeProductOperationResultAcknowledgedResponseSchema,
	bridgeProductOperationResultRequestSchema,
	bridgeProductOperationResultResponseSchema,
} from '../../src/core/comm-worker/bridge-product-operation-wire-contracts.js';
import { bridgeProductControlRequestSchema } from '../../src/core/comm-worker/bridge-product-session-contracts.js';
import type {
	BridgeProductViewResnapshotRequest,
	BridgeProductViewScopeRequest,
} from '../../src/core/comm-worker/bridge-product-view-control-wire-contracts.js';

/** Faults an old result after real native admission of a newer scope; native execution is not held. */
export async function installSupersededResnapshotFault(
	page: Page,
	signal: AbortSignal,
): Promise<{
	readonly arm: () => void;
	readonly held: Promise<BridgeProductViewResnapshotRequest>;
	readonly newerScope: Promise<number>;
	readonly consumed: Promise<void>;
	readonly release: () => void;
	readonly failedViews: () => readonly string[];
	readonly dispose: () => Promise<void>;
}> {
	const held = createBridgeProductDeferred<BridgeProductViewResnapshotRequest>();
	const newerScope = createBridgeProductDeferred<number>();
	const consumed = createBridgeProductDeferred<void>();
	const release = createBridgeProductDeferred<void>();
	const failure = createBridgeProductDeferred<never>();
	void held.promise.catch((): void => {});
	void newerScope.promise.catch((): void => {});
	void consumed.promise.catch((): void => {});
	void failure.promise.catch((): void => {});
	let armed = false;
	let older: {
		readonly operationId: string;
		readonly request: BridgeProductViewResnapshotRequest;
	} | null = null;
	const scopes = new Map<string, BridgeProductViewScopeRequest>();
	const pending = new Set<Promise<void>>();
	const failedViews: string[] = [];
	const failurePrefix = '__superseded_resnapshot_view_failed:';
	const observeFailure = (message: ConsoleMessage): void => {
		if (!message.text().startsWith(failurePrefix)) return;
		failedViews.push(message.text().slice(failurePrefix.length));
		failure.reject(new Error(`Metadata view failed during held resnapshot: ${message.text()}`));
	};
	page.on('console', observeFailure);
	await page.addInitScript((prefix: string): void => {
		const OriginalMessageChannel = window.MessageChannel;
		window.MessageChannel = class extends OriginalMessageChannel {
			constructor() {
				super();
				for (const port of [this.port1, this.port2]) {
					port.addEventListener('message', (event: MessageEvent<unknown>): void => {
						const message = event.data;
						if (typeof message !== 'object' || message === null) return;
						if (
							Object.getOwnPropertyDescriptor(message, 'kind')?.value !== 'viewRecoveryStatus' ||
							Object.getOwnPropertyDescriptor(message, 'status')?.value !== 'failedRetryable'
						)
							return;
						console.debug(
							prefix + JSON.stringify(Object.getOwnPropertyDescriptor(message, 'view')?.value),
						);
					});
				}
			}
		};
	}, failurePrefix);
	const retire = (): void => {
		release.resolve();
		failure.reject(
			new Error('Superseded resnapshot proof retired before its held result/newer scope'),
		);
	};
	page.once('close', retire);
	page.once('crash', retire);
	signal.addEventListener('abort', retire, { once: true });
	if (signal.aborted) retire();
	const intercept = async (route: Route): Promise<void> => {
		const body: unknown = route.request().postDataJSON();
		const acknowledgement = bridgeProductOperationResultAcknowledgementSchema.safeParse(body);
		if (acknowledgement.success && acknowledgement.data.operationId === older?.operationId) {
			const response = await route.fetch({ timeout: 0 });
			try {
				const accepted = bridgeProductOperationResultAcknowledgedResponseSchema.parse(
					await response.json(),
				);
				if (accepted.operationId !== acknowledgement.data.operationId)
					throw new Error('Old resnapshot result acknowledgement identity mismatch');
				await route.fulfill({ response });
				consumed.resolve();
			} finally {
				await response.dispose();
			}
			return;
		}
		const resultRequest = bridgeProductOperationResultRequestSchema.safeParse(body);
		if (resultRequest.success) {
			const target = older;
			const scope = scopes.get(resultRequest.data.operationId);
			if (target?.operationId !== resultRequest.data.operationId && scope === undefined) {
				await route.continue();
				return;
			}
			const response = await route.fetch({ timeout: 0 });
			try {
				const result = bridgeProductOperationResultResponseSchema.parse(await response.json());
				if (result.outcome !== 'succeeded')
					throw new Error(`Native fixture operation failed: ${result.outcome}`);
				if (target?.operationId === resultRequest.data.operationId) {
					held.resolve(target.request);
					await release.promise;
					const refused = bridgeProductOperationResultResponseSchema.parse({
						...result,
						failureCode: 'superseded',
						outcome: 'refused',
						result: null,
					});
					await route.fulfill({
						status: 200,
						contentType: 'application/json',
						body: JSON.stringify(refused),
					});
				} else {
					await route.fulfill({ response });
					if (scope !== undefined) newerScope.resolve(scope.scopeRevision);
				}
			} finally {
				await response.dispose();
			}
			return;
		}
		const request = bridgeProductControlRequestSchema.safeParse(body);
		if (!request.success) {
			await route.continue();
			return;
		}
		const control = request.data;
		const hold =
			armed &&
			older === null &&
			control.kind === 'subscription.resnapshot' &&
			control.subscriptionKind === 'file.metadata';
		const replace =
			older !== null &&
			control.kind === 'subscription.setScope' &&
			control.subscriptionId === older.request.subscriptionId &&
			control.scopeRevision > older.request.scopeRevision;
		if (!hold && !replace) {
			await route.continue();
			return;
		}
		const response = await route.fetch({ timeout: 0 });
		try {
			const admission = bridgeProductAdmissionResponseSchema.parse(await response.json());
			if (admission.kind !== 'operation.admitted')
				throw new Error('Native refused the fault fixture admission');
			if (hold && control.kind === 'subscription.resnapshot')
				older = { operationId: admission.operationId, request: control };
			if (replace && control.kind === 'subscription.setScope')
				scopes.set(admission.operationId, control);
			await route.fulfill({ response });
		} finally {
			await response.dispose();
		}
	};
	const handler = (route: Route): Promise<void> => {
		const operation = intercept(route).catch(async (error: unknown): Promise<void> => {
			failure.reject(error);
			await route.abort('failed').catch((): void => {});
		});
		pending.add(operation);
		void operation.finally((): void => {
			pending.delete(operation);
		});
		return operation;
	};
	await page.route('**/__bridge-product/command', handler);
	const heldResult = Promise.race([held.promise, failure.promise]);
	const newerResult = Promise.race([newerScope.promise, failure.promise]);
	const consumedResult = Promise.race([consumed.promise, failure.promise]);
	void heldResult.catch((): void => {});
	void newerResult.catch((): void => {});
	void consumedResult.catch((): void => {});
	return {
		arm: (): void => {
			armed = true;
		},
		held: heldResult,
		newerScope: newerResult,
		consumed: consumedResult,
		release: (): void => release.resolve(),
		failedViews: (): readonly string[] => [...failedViews],
		dispose: async (): Promise<void> => {
			retire();
			await Promise.all(pending);
			if (!page.isClosed()) await page.unroute('**/__bridge-product/command', handler);
			page.off('close', retire);
			page.off('crash', retire);
			page.off('console', observeFailure);
			signal.removeEventListener('abort', retire);
		},
	};
}
