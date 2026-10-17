import type { Browser, Page } from 'playwright';

export interface OwnedProductJourneyDeadline {
	readonly dispose: () => Promise<void>;
	readonly waitFor: <TValue>(promise: Promise<TValue>, label: string) => Promise<TValue>;
}

export function createOwnedProductJourneyDeadline(props: {
	readonly signal: AbortSignal;
	readonly observeWait?: <TValue>(promise: Promise<TValue>, label: string) => Promise<TValue>;
	readonly browser: Pick<Browser, 'close'>;
	readonly page: Pick<Page, 'close'>;
	readonly onDeadline?: (reason: Error) => void;
}): OwnedProductJourneyDeadline {
	let deadlineCleanup: Promise<void> | null = null;
	const deadlineReason = 'BRIDGE_PRODUCT_JOURNEY_DEADLINE_EXCEEDED';
	let expired = false;
	const waiters = new Map<(error: Error) => void, string>();
	const abort = (): void => {
		expired = true;
		props.onDeadline?.(new Error(deadlineReason));
		for (const [reject, label] of waiters)
			reject(new Error(`${deadlineReason}: awaiting ${label}`));
		waiters.clear();
		deadlineCleanup = closeOwnedProductJourneyBrowser({
			browser: props.browser,
			page: props.page,
			reason: deadlineReason,
		});
	};
	props.signal.addEventListener('abort', abort, { once: true });
	if (props.signal.aborted) abort();
	return {
		waitFor: <TValue>(input: Promise<TValue>, label: string): Promise<TValue> => {
			const promise = props.observeWait?.(input, label) ?? input;
			if (expired) {
				void promise.catch((): void => {});
				return Promise.reject(new Error(`${deadlineReason}: awaiting ${label}`));
			}
			return new Promise<TValue>((resolve, reject): void => {
				waiters.set(reject, label);
				void promise.then(resolve, reject).finally((): void => {
					waiters.delete(reject);
				});
			});
		},
		dispose: async (): Promise<void> => {
			props.signal.removeEventListener('abort', abort);
			await deadlineCleanup;
		},
	};
}

async function closeOwnedProductJourneyBrowser(props: {
	readonly browser: Pick<Browser, 'close'>;
	readonly page: Pick<Page, 'close'>;
	readonly reason: string;
}): Promise<void> {
	await Promise.allSettled([
		props.page.close({ reason: props.reason }),
		props.browser.close({ reason: props.reason }),
	]);
}
