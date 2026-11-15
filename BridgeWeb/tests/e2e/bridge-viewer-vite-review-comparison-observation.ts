import type { ConsoleMessage, Page, Request, Response } from 'playwright';
import { z } from 'zod';

import { reviewWaitTerminalOwner } from './bridge-viewer-vite-review-owner-wait.ts';
import { waitForOwnerOrRetirement } from './bridge-viewer-vite-selected-content-wait.ts';

const reviewComparisonBrowserObservationSchema = z
	.object({
		packageId: z.string().min(1),
		reviewGeneration: z.number().int().nonnegative(),
		revision: z.number().int().nonnegative(),
		symbolicTargetLabel: z.string().min(1),
		targetOID: z.string().min(1),
	})
	.strict();
export type ReviewComparisonBrowserObservation = Readonly<
	z.infer<typeof reviewComparisonBrowserObservationSchema>
>;

export interface BrowserRuntimeDiagnostics {
	readonly describe: () => Promise<string>;
	readonly readRetained: () => string;
}

export function observeBrowserRuntimeDiagnostics(page: Page): BrowserRuntimeDiagnostics {
	const consoleErrors: string[] = [];
	const failedRequests: string[] = [];
	const pageErrors: string[] = [];
	const productResponses: string[] = [];
	const productRequestPaths: string[] = [];
	const responseBodyReads: Promise<void>[] = [];
	page.on('console', (message: ConsoleMessage): void => {
		if (message.type() === 'error') consoleErrors.push(message.text());
	});
	page.on('pageerror', (error: Error): void => {
		pageErrors.push(error.stack ?? error.message);
	});
	page.on('requestfailed', (request: Request): void => {
		failedRequests.push(
			`${request.method()} ${request.url()}: ${request.failure()?.errorText ?? 'unknown'} request=${request.postData()?.slice(0, 1_000) ?? ''}`,
		);
	});
	page.on('request', (request: Request): void => {
		const path = new URL(request.url()).pathname;
		if (path.startsWith('/__bridge-product/')) productRequestPaths.push(path);
	});
	page.on('response', (response: Response): void => {
		const path = new URL(response.url()).pathname;
		if (!path.startsWith('/__bridge-product/')) return;
		const requestBody = response.request().postData()?.slice(0, 1_000) ?? '';
		const responseIndex =
			productResponses.push(
				`${response.status()} ${response.request().method()} ${path} request=${requestBody}`,
			) - 1;
		if (response.status() < 400) return;
		responseBodyReads.push(
			response
				.text()
				.then((body): void => {
					productResponses[responseIndex] += ` body=${body.slice(0, 2_000)}`;
				})
				.catch((error: unknown): void => {
					productResponses[responseIndex] += ` bodyError=${String(error)}`;
				}),
		);
	});
	return {
		readRetained: (): string =>
			JSON.stringify({
				consoleErrors,
				failedRequests,
				pageErrors,
				productResponses,
				productRequestPaths,
			}),
		describe: async (): Promise<string> => {
			const responseBodyRead = await readBrowserDiagnosticWithinDeadline(
				Promise.allSettled(responseBodyReads),
			);
			const productBootstrapResponses = productResponses
				.filter((response): boolean => response.includes(' /__bridge-product/bootstrap '))
				.slice(-4)
				.map((response): string => response.slice(0, 3_000));
			const productErrorResponses = productResponses
				.filter((response): boolean => /^[45]\d\d /u.test(response))
				.slice(-8)
				.map((response): string => response.slice(0, 3_000));
			const reviewComparisonRead = await readBrowserDiagnosticWithinDeadline(
				page.evaluate(() => {
					const reviewShell = document.querySelector('[data-testid="review-viewer-shell"]');
					const refreshHeaderGroup = document.querySelector(
						'[data-testid="bridge-review-refresh-header-group"]',
					);
					const refreshHeaderSizer = document.querySelector(
						'[data-testid="bridge-review-refresh-header-slot"] > [aria-hidden="true"]',
					);
					return {
						refreshHeader: {
							groupPresent: refreshHeaderGroup !== null,
							groupText: refreshHeaderGroup?.textContent?.trim() ?? null,
							groupVisibility:
								refreshHeaderGroup === null
									? null
									: getComputedStyle(refreshHeaderGroup).visibility,
							groupBounds:
								refreshHeaderGroup === null
									? null
									: {
											width: refreshHeaderGroup.getBoundingClientRect().width,
											height: refreshHeaderGroup.getBoundingClientRect().height,
										},
							sizerPresent: refreshHeaderSizer !== null,
							sizerText: refreshHeaderSizer?.textContent?.trim() ?? null,
							sizerVisibility:
								refreshHeaderSizer === null
									? null
									: getComputedStyle(refreshHeaderSizer).visibility,
						},
						comparisonStatus:
							document.querySelector('[data-testid="bridge-viewer-content-status"]')?.textContent ??
							null,
						comparisonTrigger:
							document.querySelector('[data-testid="bridge-review-comparison-trigger"]')
								?.textContent ?? null,
						packageId: reviewShell?.getAttribute('data-review-metadata-id') ?? null,
						resolvedTargetOID:
							document
								.querySelector('[data-testid="bridge-review-comparison-current-state"]')
								?.getAttribute('data-resolved-target-oid') ?? null,
						reviewGeneration: reviewShell?.getAttribute('data-review-metadata-generation') ?? null,
						revision: reviewShell?.getAttribute('data-review-metadata-revision') ?? null,
						updateReadyCount: [...document.querySelectorAll('*')].filter(
							(element): boolean => element.textContent?.trim() === 'Update ready',
						).length,
					};
				}),
			);
			const bodyTextRead = await readBrowserDiagnosticWithinDeadline(
				page.locator('body').textContent(),
			);
			return JSON.stringify({
				bodyText:
					bodyTextRead.status === 'fulfilled'
						? (bodyTextRead.value?.slice(0, 2_000) ?? null)
						: null,
				diagnosticReadStatus: {
					bodyText: bodyTextRead.status,
					responseBodies: responseBodyRead.status,
					reviewComparison: reviewComparisonRead.status,
				},
				consoleErrorCount: consoleErrors.length,
				consoleErrors: consoleErrors.slice(-8),
				failedRequestCount: failedRequests.length,
				failedRequests: failedRequests.slice(-8),
				pageErrorCount: pageErrors.length,
				pageErrors: pageErrors.slice(-8),
				productRequestCount: productRequestPaths.length,
				productRequestPaths: productRequestPaths.slice(-16),
				productBootstrapResponses,
				productErrorResponses,
				productResponseCount: productResponses.length,
				productResponses: productResponses
					.slice(-8)
					.map((response): string => response.slice(0, 1_500)),
				reviewComparison:
					reviewComparisonRead.status === 'fulfilled' ? reviewComparisonRead.value : null,
				url: page.url(),
			});
		},
	};
}

type BrowserDiagnosticRead<TValue> =
	| { readonly status: 'fulfilled'; readonly value: TValue }
	| { readonly status: 'failed' | 'timed_out' };

export async function readBrowserDiagnosticWithinDeadline<TValue>(
	operation: Promise<TValue>,
): Promise<BrowserDiagnosticRead<TValue>> {
	let timeout: ReturnType<typeof setTimeout> | undefined;
	try {
		return await Promise.race([
			operation.then(
				(value): BrowserDiagnosticRead<TValue> => ({ status: 'fulfilled', value }),
				(): BrowserDiagnosticRead<TValue> => ({ status: 'failed' }),
			),
			new Promise<BrowserDiagnosticRead<TValue>>((resolve): void => {
				timeout = setTimeout((): void => resolve({ status: 'timed_out' }), 2_000);
			}),
		]);
	} finally {
		if (timeout !== undefined) clearTimeout(timeout);
	}
}

export async function waitForSettledReviewComparison(props: {
	readonly expectedTargetLabel: string;
	readonly expectedTargetOID: string;
	readonly page: Page;
}): Promise<ReviewComparisonBrowserObservation> {
	return reviewComparisonBrowserObservationSchema.parse(
		await waitForReviewComparisonOwner({
			page: props.page,
			goal: {
				kind: 'comparison',
				expectedTargetLabel: props.expectedTargetLabel,
				expectedTargetOID: props.expectedTargetOID,
			},
		}),
	);
}

/** Opens the comparison picker if it is closed and waits until it is open, not animating. */
export async function openReviewComparisonPicker(props: { readonly page: Page }): Promise<void> {
	z.null().parse(
		await waitForReviewComparisonOwner({ page: props.page, goal: { kind: 'picker' } }),
	);
}

type ReviewComparisonWaitGoal =
	| { readonly kind: 'picker' }
	| {
			readonly kind: 'comparison';
			readonly expectedTargetLabel: string;
			readonly expectedTargetOID: string;
	  };

/** DOM/worker notifications decide readiness; a missing trigger never starts a locator wait. */
async function waitForReviewComparisonOwner(props: {
	readonly page: Page;
	readonly goal: ReviewComparisonWaitGoal;
}): Promise<unknown> {
	const label =
		props.goal.kind === 'picker'
			? 'open Review comparison picker'
			: `Review comparison ${props.goal.expectedTargetLabel} at ${props.goal.expectedTargetOID}`;
	const input = JSON.stringify(props.goal);
	let observation: unknown;
	let retainedState = '<no comparison state observed>';
	const observeState = (message: ConsoleMessage): void => {
		if (!message.text().startsWith('REVIEW_COMPARISON_WAIT ')) return;
		retainedState = message.text();
	};
	props.page.on('console', observeState);
	try {
		await waitForOwnerOrRetirement({
			label,
			subscribeRetirement: (retire): (() => void) => {
				const closed = (): void => retire('page-closed');
				const crashed = (): void => retire('page-crashed');
				props.page.on('close', closed);
				props.page.on('crash', crashed);
				if (props.page.isClosed()) closed();
				return (): void => {
					props.page.off('close', closed);
					props.page.off('crash', crashed);
				};
			},
			run: async (): Promise<void> => {
				// Keep the native import in the page realm, as in the selected-content owner wait.
				observation = await props.page.evaluate(`(async () => {
				const input = ${input};
				const label = ${JSON.stringify(label)};
				const terminalOwner = (${reviewWaitTerminalOwner.toString()});
				let diagnostics = null;
				if (location.protocol === 'http:' || location.protocol === 'https:') {
					diagnostics = await import(new URL('/src/foundation/diagnostics/bridge-review-selection-diagnostic.ts', location.href).href);
				}
				let workerSessionState = window.__bridgeReviewSelectionDiagnostic?.sessionState ?? null;
				return await new Promise((resolve, reject) => {
					let unsubscribeWorker = () => {};
					let ended = false;
					let requestedOpen = false;
					let requestedTrigger = null;
					let previousState = '';
					const finish = (error, value = null) => {
						if (ended) return;
						ended = true;
						observer.disconnect(); unsubscribeWorker();
						window.removeEventListener('pagehide', retired);
						window.removeEventListener('error', failed);
						window.removeEventListener('unhandledrejection', failed);
						if (error === null) resolve(value); else reject(error);
					};
					const retired = () => finish(new Error(label + ' ended: document-retired'));
					const failed = event => finish(new Error(label + ' ended: ' + event.type, { cause: event.error ?? event.reason }));
					const inspect = () => {
						if (ended) return;
						try {
							const diagnosticTrigger = document.querySelector('[data-testid="bridge-review-comparison-trigger"]');
							const diagnosticContent = document.querySelector('[data-testid="bridge-review-comparison-content"]');
							const state = JSON.stringify({ label, workerSessionState, triggerTag: diagnosticTrigger?.tagName, triggerText: diagnosticTrigger?.textContent, disabled: diagnosticTrigger?.getAttribute('disabled'), busy: diagnosticTrigger?.getAttribute('aria-busy'), visible: diagnosticTrigger?.checkVisibility(), content: diagnosticContent !== null, closing: diagnosticContent !== null && diagnosticContent.closest('[data-ending-style]') !== null, inert: diagnosticContent !== null && diagnosticContent.closest('[inert], [data-closed]') !== null, targetOID: diagnosticContent?.querySelector('[data-testid="bridge-review-comparison-current-state"]')?.getAttribute('data-resolved-target-oid'), packageId: document.querySelector('[data-testid="review-viewer-shell"]')?.getAttribute('data-review-metadata-id') });
							if (state !== previousState) { previousState = state; console.debug('REVIEW_COMPARISON_WAIT ' + state); }
							const owner = terminalOwner({ inactiveSession: document.querySelector('[data-testid="bridge-dev-session-inactive"]') !== null, workerSessionState });
							if (owner !== null) { finish(new Error(label + ' ended: ' + owner)); return; }
							const trigger = document.querySelector('[data-testid="bridge-review-comparison-trigger"]');
							const triggerLabel = trigger?.textContent ?? null;
							const shell = document.querySelector('[data-testid="review-viewer-shell"]');
							const packageId = shell?.getAttribute('data-review-metadata-id') ?? null;
							if (!(trigger instanceof HTMLButtonElement) || trigger.disabled || trigger.getAttribute('aria-busy') === 'true' || !trigger.checkVisibility()) return;
							if (input.kind === 'comparison' && triggerLabel !== input.expectedTargetLabel) return;
							if (input.kind === 'comparison' && (packageId === null || packageId.length === 0)) return;
							if (requestedTrigger !== trigger) { requestedTrigger = trigger; requestedOpen = false; }
							const content = document.querySelector('[data-testid="bridge-review-comparison-content"]');
							// Closing content belongs to the previous target and must not certify the new one.
							if (content !== null && content.closest('[data-ending-style]') !== null) return;
							const open = content !== null && content.closest('[inert], [data-closed]') === null;
							if (!open) {
								if (!requestedOpen) { requestedOpen = true; trigger.click(); }
								return;
							}
							if (input.kind === 'picker') { finish(null); return; }
							const targetOID = content.querySelector('[data-testid="bridge-review-comparison-current-state"]')?.getAttribute('data-resolved-target-oid') ?? null;
							if (targetOID !== input.expectedTargetOID) return;
							finish(null, { packageId, reviewGeneration: Number(shell.getAttribute('data-review-metadata-generation')), revision: Number(shell.getAttribute('data-review-metadata-revision')), symbolicTargetLabel: triggerLabel, targetOID });
						} catch (error) { finish(error); }
					};
					const observer = new MutationObserver(inspect);
					observer.observe(document, { attributes: true, childList: true, subtree: true });
					window.addEventListener('pagehide', retired, { once: true });
					window.addEventListener('error', failed);
					window.addEventListener('unhandledrejection', failed);
					if (diagnostics !== null) unsubscribeWorker = diagnostics.observeBridgePaneCommWorkerSessionDiagnosticSnapshots(snapshot => { workerSessionState = snapshot.state; inspect(); });
					inspect();
				});
			})()`);
			},
		});
	} catch (error: unknown) {
		throw new Error(`${label} did not complete; ${retainedState}`, { cause: error });
	} finally {
		props.page.off('console', observeState);
	}
	return observation;
}

export async function waitForSettledReviewComparisonWithDiagnostics(props: {
	readonly diagnostics: BrowserRuntimeDiagnostics;
	readonly expectedTargetLabel: string;
	readonly expectedTargetOID: string;
	readonly failureContext: () => string;
	readonly page: Page;
}): Promise<ReviewComparisonBrowserObservation> {
	try {
		return await waitForSettledReviewComparison(props);
	} catch (error: unknown) {
		throw new Error(
			`Restarted Review comparison did not load: ${await props.diagnostics.describe()} ${props.failureContext()}`,
			{ cause: error },
		);
	}
}
