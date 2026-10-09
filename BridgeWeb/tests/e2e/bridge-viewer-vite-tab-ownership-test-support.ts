import type { Page, Request, Response } from 'playwright';

import { runAllOwnedCleanupOperations } from '../../scripts/dev-server/bridge-development-server-process.ts';

interface TabOwnershipCleanupProps {
	readonly registerOnFinished: (cleanup: () => Promise<void>) => void;
	readonly stopServer: () => Promise<void>;
	readonly closeBrowser: () => Promise<void>;
	readonly disposeFixture: () => Promise<void>;
}

export interface TabOwnershipCleanup {
	readonly stop: () => Promise<void>;
}

export function createTabOwnershipCleanup(props: TabOwnershipCleanupProps): TabOwnershipCleanup {
	let cleanupPromise: Promise<void> | null = null;
	const stop = (): Promise<void> => {
		cleanupPromise ??= runAllOwnedCleanupOperations({
			operations: [
				{
					name: 'browser, Vite and Swift',
					run: async (): Promise<void> => {
						const results = await Promise.allSettled([
							Promise.resolve().then(props.stopServer),
							Promise.resolve().then(props.closeBrowser),
						]);
						const failures = results.filter((result) => result.status === 'rejected');
						if (failures.length > 0) {
							throw new AggregateError(
								failures.map((result): unknown => result.reason),
								'Tab ownership live-resource cleanup failed.',
							);
						}
					},
				},
				{ name: 'fixture', run: props.disposeFixture },
			],
		});
		return cleanupPromise;
	};
	props.registerOnFinished(stop);
	return { stop };
}

export interface TabOwnershipStepCheckpoint {
	readonly begin: (step: string) => void;
	readonly lastStep: () => string;
}

/** Recording an ingress event does not wait or infer that its operation completed. */
export function createTabOwnershipStepCheckpoint(props: {
	readonly topology: string;
	readonly record: (message: string) => void;
}): TabOwnershipStepCheckpoint {
	let lastStep = 'register runner cleanup';
	return {
		begin: (step: string): void => {
			lastStep = step;
			props.record(`TQ35 ${props.topology}: begin ${step}`);
		},
		lastStep: (): string => lastStep,
	};
}

interface TabOwnershipBootstrapRequest {
	readonly method: () => string;
	readonly url: () => string;
}

interface TabOwnershipBootstrapTransport<TRequest, TResponse> {
	readonly subscribeRequest: (listener: (request: TRequest) => void) => () => void;
	readonly subscribeResponse: (listener: (response: TResponse) => void) => () => void;
	readonly subscribeRequestFailure: (listener: (request: TRequest) => void) => () => void;
	readonly subscribeClose: (listener: () => void) => () => void;
}

export function tabOwnershipBootstrapTransportForPage(
	page: Page,
): TabOwnershipBootstrapTransport<Request, Response> {
	return {
		subscribeRequest: (listener): (() => void) => {
			page.on('request', listener);
			return (): void => {
				page.off('request', listener);
			};
		},
		subscribeResponse: (listener): (() => void) => {
			page.on('response', listener);
			return (): void => {
				page.off('response', listener);
			};
		},
		subscribeRequestFailure: (listener): (() => void) => {
			page.on('requestfailed', listener);
			return (): void => {
				page.off('requestfailed', listener);
			};
		},
		subscribeClose: (listener): (() => void) => {
			page.on('close', listener);
			return (): void => {
				page.off('close', listener);
			};
		},
	};
}

export interface TabOwnershipBootstrapHistory {
	readonly assertSingleBootstrapForDocument: (documentGeneration: number) => void;
	readonly dispose: () => void;
}

/** Page close ends the browser request history; it says nothing about native stream release. */
export function recordTabOwnershipBootstrapHistory<
	TRequest extends TabOwnershipBootstrapRequest,
>(props: {
	readonly transport: Pick<
		TabOwnershipBootstrapTransport<TRequest, unknown>,
		'subscribeRequest' | 'subscribeClose'
	>;
	readonly requestGeneration: (request: TRequest) => number;
	readonly signal: AbortSignal;
}): TabOwnershipBootstrapHistory {
	const requestedDocumentGenerations: number[] = [];
	let pageClosed = false;
	const unsubscribe: (() => void)[] = [];
	const dispose = (): void => {
		for (const release of unsubscribe.splice(0)) release();
		props.signal.removeEventListener('abort', dispose);
	};
	if (!props.signal.aborted) {
		unsubscribe.push(
			props.transport.subscribeRequest((request: TRequest): void => {
				if (
					request.method() === 'POST' &&
					new URL(request.url()).pathname === '/__bridge-product/bootstrap'
				) {
					requestedDocumentGenerations.push(props.requestGeneration(request));
				}
			}),
			props.transport.subscribeClose((): void => {
				pageClosed = true;
				dispose();
			}),
		);
		props.signal.addEventListener('abort', dispose, { once: true });
	}
	return {
		assertSingleBootstrapForDocument: (documentGeneration: number): void => {
			if (!pageClosed) throw new Error('TQ35 first-tab bootstrap history has not closed.');
			if (requestedDocumentGenerations.length === 0) {
				throw new Error('TQ35 first-tab initial bootstrap request was not observed.');
			}
			if (requestedDocumentGenerations.length > 1) {
				throw new Error(
					`TQ35 first tab re-bootstrapped; closed request document generations: ${JSON.stringify(requestedDocumentGenerations)}.`,
				);
			}
			if (requestedDocumentGenerations[0] !== documentGeneration) {
				throw new Error(
					`TQ35 first-tab bootstrap belonged to document ${requestedDocumentGenerations[0]}, expected ${documentGeneration}.`,
				);
			}
		},
		dispose,
	};
}

/** Accept only the bootstrap issued by the expected new document, never a stale notice. */
export function observeTabOwnershipBootstrap<
	TRequest extends TabOwnershipBootstrapRequest,
	TResponse extends { readonly request: () => TRequest },
>(props: {
	readonly transport: TabOwnershipBootstrapTransport<TRequest, TResponse>;
	readonly requestGeneration: (request: TRequest) => number;
	readonly expectedDocumentGeneration: number;
	readonly signal: AbortSignal;
}): Promise<TResponse> {
	return new Promise<TResponse>((resolve, reject): void => {
		let finished = false;
		const unsubscribe: (() => void)[] = [];
		const matches = (request: TRequest): boolean =>
			request.method() === 'POST' &&
			new URL(request.url()).pathname === '/__bridge-product/bootstrap' &&
			props.requestGeneration(request) === props.expectedDocumentGeneration;
		const settle = (
			outcome: { readonly response: TResponse } | { readonly error: unknown },
		): void => {
			if (finished) return;
			finished = true;
			for (const release of unsubscribe) release();
			props.signal.removeEventListener('abort', onAbort);
			if ('response' in outcome) resolve(outcome.response);
			else reject(outcome.error);
		};
		const onResponse = (response: TResponse): void => {
			if (matches(response.request())) settle({ response });
		};
		const onRequestFailed = (request: TRequest): void => {
			if (matches(request)) {
				settle({ error: new Error('TQ35 new-document bootstrap transport failed.') });
			}
		};
		const onClose = (): void =>
			settle({ error: new Error('TQ35 page closed before new-document bootstrap response.') });
		const onAbort = (): void =>
			settle({ error: props.signal.reason ?? new Error('TQ35 bootstrap observation aborted.') });
		if (props.signal.aborted) {
			onAbort();
			return;
		}
		unsubscribe.push(
			props.transport.subscribeResponse(onResponse),
			props.transport.subscribeRequestFailure(onRequestFailed),
			props.transport.subscribeClose(onClose),
		);
		props.signal.addEventListener('abort', onAbort, { once: true });
	});
}
