import type { ConsoleMessage, Page, Request, Response } from 'playwright';
import { expect } from 'vitest';

export interface ReviewComparisonBrowserObservation {
	readonly packageId: string;
	readonly reviewGeneration: number;
	readonly revision: number;
	readonly symbolicTargetLabel: string;
	readonly targetOID: string;
}

export interface BrowserRuntimeDiagnostics {
	readonly describe: () => Promise<string>;
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
				page.locator('body').textContent({ timeout: 2_000 }),
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
	readonly timeoutMilliseconds: number;
}): Promise<ReviewComparisonBrowserObservation> {
	const comparisonTrigger = props.page.getByTestId('bridge-review-comparison-trigger');
	await expect
		.poll(async (): Promise<string | null> => await comparisonTrigger.textContent(), {
			timeout: props.timeoutMilliseconds,
		})
		.toBe(props.expectedTargetLabel);
	let settledTargetOID = '';
	try {
		await expect
			.poll(
				async (): Promise<string | null> => {
					// Read the resolved target only from an open picker. A picker animating
					// closed after a selection still shows the previous target's state.
					const picker = await readReviewComparisonPickerState(props.page);
					if (picker.kind === 'closed') await comparisonTrigger.click();
					if (picker.kind !== 'open') return null;
					if (picker.resolvedTargetOID !== null) settledTargetOID = picker.resolvedTargetOID;
					return picker.resolvedTargetOID;
				},
				{ timeout: props.timeoutMilliseconds },
			)
			.toBe(props.expectedTargetOID);
	} catch (error: unknown) {
		const comparisonState = await props.page.evaluate(
			(): string | null =>
				document.querySelector('[data-testid="bridge-review-comparison-content"]')?.textContent ??
				null,
		);
		throw new Error(`Review comparison did not settle: ${comparisonState ?? '<missing>'}`, {
			cause: error,
		});
	}
	const reviewShell = props.page.getByTestId('review-viewer-shell');
	const packageId = await reviewShell.getAttribute('data-review-metadata-id');
	const reviewGeneration = Number(
		await reviewShell.getAttribute('data-review-metadata-generation'),
	);
	const revision = Number(await reviewShell.getAttribute('data-review-metadata-revision'));
	const symbolicTargetLabel = (await comparisonTrigger.textContent()) ?? '';
	if (packageId === null || packageId.length === 0) {
		throw new Error('Settled Review comparison is missing package identity.');
	}
	return {
		packageId,
		reviewGeneration,
		revision,
		symbolicTargetLabel,
		targetOID: settledTargetOID,
	};
}

type ReviewComparisonPickerState =
	| { readonly kind: 'closed' }
	| { readonly kind: 'closing' }
	| { readonly kind: 'open'; readonly resolvedTargetOID: string | null };

async function readReviewComparisonPickerState(page: Page): Promise<ReviewComparisonPickerState> {
	return await page.evaluate((): ReviewComparisonPickerState => {
		const content = document.querySelector('[data-testid="bridge-review-comparison-content"]');
		if (content === null) return { kind: 'closed' };
		if (content.closest('[data-ending-style]') !== null) return { kind: 'closing' };
		if (content.closest('[inert], [data-closed]') !== null) return { kind: 'closed' };
		return {
			kind: 'open',
			resolvedTargetOID:
				content
					.querySelector('[data-testid="bridge-review-comparison-current-state"]')
					?.getAttribute('data-resolved-target-oid') ?? null,
		};
	});
}

/** Opens the comparison picker if it is closed and waits until it is open, not animating. */
export async function openReviewComparisonPicker(props: {
	readonly page: Page;
	readonly timeoutMilliseconds: number;
}): Promise<void> {
	const comparisonTrigger = props.page.getByTestId('bridge-review-comparison-trigger');
	await expect
		.poll(
			async (): Promise<ReviewComparisonPickerState['kind']> => {
				const picker = await readReviewComparisonPickerState(props.page);
				if (picker.kind === 'closed') await comparisonTrigger.click();
				return picker.kind;
			},
			{ timeout: props.timeoutMilliseconds },
		)
		.toBe('open');
}

export async function waitForSettledReviewComparisonWithDiagnostics(props: {
	readonly diagnostics: BrowserRuntimeDiagnostics;
	readonly expectedTargetLabel: string;
	readonly expectedTargetOID: string;
	readonly failureContext: () => string;
	readonly page: Page;
	readonly timeoutMilliseconds: number;
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
