import { createHash } from 'node:crypto';

import type {
	Browser,
	Page,
	Request as PlaywrightRequest,
	Response as PlaywrightResponse,
} from 'playwright';
import { chromium } from 'playwright';

import {
	bridgeViewerProductOnlySelectors,
	summarizeBridgeProductRequestBody,
	summarizeBridgeProductResponseBody,
	type BridgeViewerFileProductStateSnapshot,
	type BridgeViewerConsoleDiagnostic,
	type BridgeViewerFailedResponse,
	type BridgeViewerLegacyIntakeTranscriptEntry,
	type BridgeViewerLegacyRouteTranscriptEntry,
	type BridgeViewerMainWindowProductRequest,
	type BridgeViewerObservedWorker,
	type BridgeViewerProductFailureTransportSnapshot,
	type BridgeViewerProductOnlyJourneyFailureCheckpoint,
	type BridgeViewerProductOnlyJourneyProof,
	type BridgeViewerProductRouteTranscriptEntry,
	type BridgeViewerReviewProductStateSnapshot,
} from './product-only-real-router-contract.ts';
import {
	type BridgeViewerDocumentGenerations,
	installBridgeViewerDocumentGenerations,
} from './product-only-real-router-document-generations.ts';
import {
	bridgeViewerJourneyFailureCode,
	BridgeViewerProductOnlyJourneyFailure,
} from './product-only-real-router-failure.ts';
import {
	readPaintedFileMarkdown,
	selectFileProofPath,
	waitForFileProductTerminalState,
} from './product-only-real-router-file-proof.ts';
import { BridgeViewerLegacyMetadataCompletion } from './product-only-real-router-legacy-completion.ts';
import { BridgeViewerProductOpenSettlementCorrelator } from './product-only-real-router-operation-settlements.ts';
import { installBridgeViewerBrowserErrorCapture } from './product-only-real-router-page-error.ts';
import {
	BridgeViewerReloadJoinDiagnosticRecorder,
	type BridgeViewerReloadJoinResponses,
} from './product-only-real-router-reload-join-diagnostics.ts';
import { GenerationScopedResponseParsers } from './product-only-real-router-response-parsers.ts';
import {
	correlatedContentUnknownReadRefusal,
	integerValue,
	parseJSONOrNull,
	stringValue,
	unknownRecord,
} from './product-only-real-router-response-parsing.ts';
import {
	proveFreshReviewRoute,
	proveReviewTreeSelection,
	readFreshReviewFailureSnapshot,
	waitForReviewProductTerminalState,
} from './product-only-real-router-review-proof.ts';
import { waitForProductBrowserFrameSettlement } from './product-only-real-router-settlement.ts';

export {
	freshReviewInitialWindowRequiresTraversal,
	mountedHeaderOrderViolationForExpectedOrder,
	nextFreshReviewTraversalScrollTop,
} from './product-only-real-router-review-proof.ts';
export { bridgeViewerProductOnlyJourneyFailureFromError } from './product-only-real-router-failure.ts';

const productJourneyTimeoutMilliseconds = 120_000;
const productCompositionSettleTimeoutMilliseconds = 10_000;
const productJourneyOwnedDeadlineMilliseconds = 120_000;
const maximumCapturedConsoleErrors = 32;
const maximumCapturedConsoleErrorCharacters = 500;

interface MutableProductRouteTranscriptEntry {
	contentUnknownReadRefusalCorrelated?: boolean;
	contentKind: string | null;
	documentGeneration: number;
	httpStatus: number | null;
	method: string;
	ordinal: number;
	paneSessionId: string | null;
	path: string;
	requestKind: string | null;
	requestSettled: boolean;
	requestSequence: number | null;
	responseCode: string | null;
	responseKind: string | null;
	resultAcknowledged: boolean;
	settledResponseKind: string | null;
	streamKind: string | null;
	subscriptionKind: string | null;
	workerInstanceId: string | null;
}

interface MutableObservedWorker extends BridgeViewerObservedWorker {
	closed: boolean;
	closedBeforeJourneyCompletion: boolean;
}

interface MutableLegacyRouteTranscriptEntry {
	documentGeneration: number;
	finalWindow: boolean | null;
	frameKind: string | null;
	httpStatus: number | null;
	ordinal: number;
	path: string;
	sequence: number | null;
}

export interface BridgeViewerFileProofTargets {
	readonly codePath: string;
	readonly markdownPath: string;
	readonly markdownRenderedText?: string;
}

export async function runBridgeViewerProductOnlyJourney(props: {
	readonly baseUrl: string;
	readonly expectedReviewItemIds: readonly string[];
	readonly fileProofTargets: BridgeViewerFileProofTargets;
}): Promise<BridgeViewerProductOnlyJourneyProof> {
	const browser = await chromium.launch({ channel: 'chrome', headless: true });
	const observedWorkers: MutableObservedWorker[] = [];
	const observedWorkerClosePromises: Promise<void>[] = [];
	let closedWorkerCount = 0;
	const consoleDiagnostics: BridgeViewerConsoleDiagnostic[] = [];
	const consoleErrors: string[] = [];
	const failedResponses: BridgeViewerFailedResponse[] = [];
	const page = await browser.newPage({
		deviceScaleFactor: 1,
		viewport: { height: 980, width: 1728 },
	});
	const ownedJourneyDeadline = createOwnedProductJourneyDeadline({ browser, page });
	let journeyCompleted = false;
	const documentGenerations = await installBridgeViewerDocumentGenerations(page);
	const routeObserver = new BridgeViewerRealRouterObserver(page, documentGenerations);
	page.on('worker', (worker): void => {
		const workerOrigin = documentGenerations.observedWorker(worker.url());
		const observedWorker = classifyObservedWorker(
			workerOrigin.scriptUrl,
			workerOrigin.documentGeneration,
		);
		observedWorkers.push(observedWorker);
		observedWorkerClosePromises.push(
			new Promise((resolve): void => {
				worker.once('close', (): void => {
					observedWorker.closed = true;
					observedWorker.closedBeforeJourneyCompletion = !journeyCompleted;
					closedWorkerCount += 1;
					resolve();
				});
			}),
		);
	});
	installBridgeViewerBrowserErrorCapture({
		consoleDiagnostics,
		consoleErrors,
		maximumCapturedConsoleErrorCharacters,
		maximumCapturedConsoleErrors,
		page,
	});
	page.on('response', (response): void => {
		if (response.status() < 400) return;
		const request = response.request();
		failedResponses.push({
			documentGeneration: documentGenerations.currentGeneration(),
			method: request.method(),
			path: new URL(response.url()).pathname,
			resourceType: request.resourceType(),
			status: response.status(),
		});
	});
	await installMainWindowProductRouteObserver(page);
	await installLegacyIntakeObserver(page);

	let journeyProof: Omit<BridgeViewerProductOnlyJourneyProof, 'browserCleanup'> | null = null;
	let journeyFailure: Omit<
		BridgeViewerProductOnlyJourneyFailureCheckpoint,
		'browserCleanup' | 'workers'
	> | null = null;
	let journeyFailureCause: unknown = null;
	try {
		const pageUrl = new URL('/', props.baseUrl);
		pageUrl.searchParams.set('fixture', 'worktree');
		pageUrl.searchParams.set('scenario', 'current-worktree');
		pageUrl.searchParams.set('workers', 'on');
		pageUrl.searchParams.set('viewer', 'review');
		await page.goto(pageUrl.toString(), {
			timeout: productJourneyTimeoutMilliseconds,
			waitUntil: 'domcontentloaded',
		});
		const reviewFreshRoute = await proveFreshReviewRoute({
			expectedItemIds: props.expectedReviewItemIds,
			page,
		});
		const reviewTreeSelection = await proveReviewTreeSelection({
			expectedItemIds: props.expectedReviewItemIds,
			page,
		});
		await page.locator(bridgeViewerProductOnlySelectors.activeFileContextButton).click({
			timeout: productJourneyTimeoutMilliseconds,
		});
		await waitForViewerMode(page, 'file');
		await selectFileProofPath({
			page,
			path: props.fileProofTargets.markdownPath,
			settleTimeoutMilliseconds: productCompositionSettleTimeoutMilliseconds,
		});
		const fileMarkdownAtReviewFirstSwitch = await readPaintedFileMarkdown({
			page,
			...(props.fileProofTargets.markdownRenderedText === undefined
				? {}
				: { expectedRenderedText: props.fileProofTargets.markdownRenderedText }),
			settleTimeoutMilliseconds: productCompositionSettleTimeoutMilliseconds,
		});
		await selectFileProofPath({
			page,
			path: props.fileProofTargets.codePath,
			settleTimeoutMilliseconds: productCompositionSettleTimeoutMilliseconds,
		});
		await waitForFileProductTerminalState({
			page,
			settleTimeoutMilliseconds: productCompositionSettleTimeoutMilliseconds,
		});
		const fileAfterReviewFirstSwitch = await readFileProductState(page);

		pageUrl.searchParams.set('viewer', 'file');
		const reloadJoinResponses = routeObserver.armReloadJoinWaiters();
		await page.goto(pageUrl.toString(), {
			timeout: productJourneyTimeoutMilliseconds,
			waitUntil: 'domcontentloaded',
		});
		await page.waitForSelector(bridgeViewerProductOnlySelectors.fileShell, {
			timeout: productJourneyTimeoutMilliseconds,
		});
		const [receiptResponse, fileOpenResponse, reviewOpenResponse] = await Promise.all([
			reloadJoinResponses.subscriptionReceipt,
			reloadJoinResponses.fileMetadataOpen,
			reloadJoinResponses.reviewMetadataOpen,
		]);
		if (
			receiptResponse.status() === 200 &&
			fileOpenResponse.status() === 200 &&
			reviewOpenResponse.status() === 200
		) {
			await selectFileProofPath({
				page,
				path: props.fileProofTargets.codePath,
				settleTimeoutMilliseconds: productCompositionSettleTimeoutMilliseconds,
			});
			await waitForFileProductTerminalState({
				page,
				settleTimeoutMilliseconds: productCompositionSettleTimeoutMilliseconds,
			});
		}
		const fileAfterFirstAcknowledgement = await readFileProductState(page);
		const journeyDocumentGenerationAtStart = documentGenerations.currentGeneration();

		await page.locator(bridgeViewerProductOnlySelectors.activeReviewContextButton).click({
			timeout: productJourneyTimeoutMilliseconds,
		});
		await waitForViewerMode(page, 'review');
		await waitForReviewProductTerminalState(page);
		const reviewAtCompletion = await readReviewProductState(page);

		await page.locator(bridgeViewerProductOnlySelectors.activeFileContextButton).click({
			timeout: productJourneyTimeoutMilliseconds,
		});
		await waitForViewerMode(page, 'file');
		await waitForFileProductTerminalState({
			page,
			settleTimeoutMilliseconds: productCompositionSettleTimeoutMilliseconds,
		});
		await routeObserver.waitForObservedLegacyMetadataCompletion();
		await routeObserver.waitForAllProductResponses();
		await routeObserver.flushResponseParsers();
		journeyCompleted = true;

		journeyProof = {
			browser: {
				headless: true,
				name: browser.browserType().name(),
				version: browser.version(),
			},
			consoleDiagnostics,
			consoleErrors,
			documentGeneration: {
				atJourneyCompletion: documentGenerations.currentGeneration(),
				atJourneyStart: journeyDocumentGenerationAtStart,
			},
			failedResponses,
			fileAfterReviewFirstSwitch,
			fileAfterFirstAcknowledgement,
			fileAtCompletion: await readFileProductState(page),
			fileMarkdownAtReviewFirstSwitch,
			legacyIntakeTranscript: await readLegacyIntakeTranscript(page),
			legacyRouteTranscript: routeObserver.legacyRouteTranscript(),
			mainWindowProductRouteTranscript: await readMainWindowProductRouteTranscript(page),
			observedPageUrl: page.url(),
			productRouteTranscript: routeObserver.productRouteTranscript(),
			reviewFreshRoute,
			reviewTreeSelection,
			reviewAtCompletion,
			selectors: bridgeViewerProductOnlySelectors,
			selectorSnapshot: await page.evaluate(
				(selectors) => ({
					activeFileContextButtonCount: document.querySelectorAll(selectors.activeFileContextButton)
						.length,
					activeReviewContextButtonCount: document.querySelectorAll(
						selectors.activeReviewContextButton,
					).length,
					fileCodeCanvasCount: document.querySelectorAll(selectors.fileCodeCanvas).length,
					fileShellCount: document.querySelectorAll(selectors.fileShell).length,
					reviewShellCount: document.querySelectorAll(selectors.reviewShell).length,
				}),
				bridgeViewerProductOnlySelectors,
			),
			workers: observedWorkers,
		};
	} catch (error: unknown) {
		journeyFailureCause = error;
		journeyFailure = await captureBridgeViewerProductOnlyJourneyFailure({
			browserDiagnostics: consoleDiagnostics,
			documentGeneration: documentGenerations.currentGeneration(),
			error,
			failedResponses,
			page,
			routeObserver,
		});
	} finally {
		await ownedJourneyDeadline.dispose();
		await page.close();
		await browser.close();
		try {
			await withBoundedTimeout(
				Promise.all(observedWorkerClosePromises),
				productCompositionSettleTimeoutMilliseconds,
				'observed worker closure',
			);
		} catch {}
	}
	const browserCleanup: BridgeViewerProductOnlyJourneyProof['browserCleanup'] = {
		browserConnectedAfterClose: browser.isConnected(),
		closedWorkerCount,
		observedWorkerCount: observedWorkers.length,
		pageClosed: page.isClosed(),
	};
	if (journeyFailure !== null) {
		routeObserver.emitReloadJoinFailureDiagnostics(observedWorkers);
		throw new BridgeViewerProductOnlyJourneyFailure({
			cause: journeyFailureCause,
			checkpoint: {
				...journeyFailure,
				browserCleanup,
				workers: observedWorkers.map(
					({ url: _url, ...worker }): Omit<BridgeViewerObservedWorker, 'url'> => ({ ...worker }),
				),
			},
		});
	}
	if (journeyProof === null) {
		throw new Error('Bridge Viewer product-only journey ended without a proof result.');
	}
	return {
		...journeyProof,
		browserCleanup,
		legacyRouteTranscript: routeObserver.legacyRouteTranscript(),
		productRouteTranscript: routeObserver.productRouteTranscript(),
	};
}

async function captureBridgeViewerProductOnlyJourneyFailure(props: {
	readonly browserDiagnostics: readonly BridgeViewerConsoleDiagnostic[];
	readonly documentGeneration: number;
	readonly error: unknown;
	readonly failedResponses: readonly BridgeViewerFailedResponse[];
	readonly page: Page;
	readonly routeObserver: BridgeViewerRealRouterObserver;
}): Promise<Omit<BridgeViewerProductOnlyJourneyFailureCheckpoint, 'browserCleanup' | 'workers'>> {
	try {
		await props.routeObserver.flushResponseParsers();
	} catch {}
	let review: BridgeViewerProductOnlyJourneyFailureCheckpoint['review'] = null;
	let captureStatus: BridgeViewerProductOnlyJourneyFailureCheckpoint['captureStatus'] =
		'unavailable';
	try {
		review = await readFreshReviewFailureSnapshot(props.page);
		captureStatus = 'captured';
	} catch {}
	return {
		browserDiagnostics: props.browserDiagnostics,
		captureStatus,
		documentGeneration: props.documentGeneration,
		failureCode: bridgeViewerJourneyFailureCode(props.error),
		failedResponses: props.failedResponses,
		review,
		transport: props.routeObserver.failureTransportSnapshot(),
	};
}

async function installMainWindowProductRouteObserver(page: Page): Promise<void> {
	await page.addInitScript((): void => {
		type ProofWindow = Window & {
			bridgeViewerMainWindowProductRouteTranscript?: BridgeViewerMainWindowProductRequest[];
		};
		const proofWindow = window as ProofWindow;
		proofWindow.bridgeViewerMainWindowProductRouteTranscript = [];
		const originalFetch = globalThis.fetch.bind(globalThis);
		globalThis.fetch = async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
			const request = input instanceof Request ? input : null;
			const requestUrl =
				input instanceof Request ? input.url : input instanceof URL ? input.href : input;
			recordProductRequest({
				method: init?.method ?? request?.method ?? 'GET',
				transport: 'fetch',
				url: requestUrl,
			});
			return await originalFetch(input, init);
		};

		// oxlint-disable-next-line typescript/unbound-method -- The wrapper invokes this saved method with the live XMLHttpRequest receiver below.
		const originalOpen = XMLHttpRequest.prototype.open;
		XMLHttpRequest.prototype.open = function (
			method: string,
			url: string | URL,
			async = true,
			username?: string | null,
			password?: string | null,
		): void {
			recordProductRequest({
				method,
				transport: 'xmlHttpRequest',
				url: url instanceof URL ? url.href : url,
			});
			Reflect.apply(originalOpen, this, [method, url, async, username, password]);
		};

		function recordProductRequest(props: {
			readonly method: string;
			readonly transport: BridgeViewerMainWindowProductRequest['transport'];
			readonly url: string;
		}): void {
			const url = new URL(props.url, location.href);
			if (!url.pathname.startsWith('/__bridge-product/')) return;
			proofWindow.bridgeViewerMainWindowProductRouteTranscript?.push({
				method: props.method.toUpperCase(),
				path: url.pathname,
				transport: props.transport,
			});
		}
	});
}

async function readMainWindowProductRouteTranscript(
	page: Page,
): Promise<readonly BridgeViewerMainWindowProductRequest[]> {
	return await page.evaluate((): readonly BridgeViewerMainWindowProductRequest[] => {
		type ProofWindow = Window & {
			bridgeViewerMainWindowProductRouteTranscript?: BridgeViewerMainWindowProductRequest[];
		};
		return (window as ProofWindow).bridgeViewerMainWindowProductRouteTranscript ?? [];
	});
}

export class BridgeViewerRealRouterObserver {
	readonly #documentGenerations: BridgeViewerDocumentGenerations;
	readonly #page: Page;
	readonly #legacyCompletion = new BridgeViewerLegacyMetadataCompletion();
	readonly #legacyEntries: MutableLegacyRouteTranscriptEntry[] = [];
	readonly #productEntries: MutableProductRouteTranscriptEntry[] = [];
	readonly #productEntryByRequest = new WeakMap<
		PlaywrightRequest,
		MutableProductRouteTranscriptEntry
	>();
	readonly #legacyEntryByRequest = new WeakMap<
		PlaywrightRequest,
		MutableLegacyRouteTranscriptEntry
	>();
	readonly #responseParsers = new GenerationScopedResponseParsers();
	readonly #openSettlements = new BridgeViewerProductOpenSettlementCorrelator();
	readonly #productResponseClosureWaiters = new Set<() => void>();
	readonly #unfinishedProductRequests = new Set<PlaywrightRequest>();
	readonly #reloadJoinDiagnostics = new BridgeViewerReloadJoinDiagnosticRecorder();
	#productActivityRevision = 0;
	#nextOrdinal = 1;

	constructor(page: Page, documentGenerations: BridgeViewerDocumentGenerations) {
		this.#documentGenerations = documentGenerations;
		this.#page = page;
		page.on('request', (request): void => this.#observeRequest(request));
		page.on('requestfailed', (request): void => this.#observeRequestSettled(request));
		page.on('requestfinished', (request): void => this.#observeRequestSettled(request));
		page.on('response', (response): void => this.#observeResponse(response));
	}

	productRouteTranscript(): readonly BridgeViewerProductRouteTranscriptEntry[] {
		return this.#productEntries.map((entry) => ({ ...entry }));
	}

	// Armed before the reload navigation: the waiters belong to the next page
	// generation, which begins when the main frame commits the new document.
	armReloadJoinWaiters(): BridgeViewerReloadJoinResponses {
		return this.#reloadJoinDiagnostics.arm({
			armOrdinal: this.#nextOrdinal,
			page: this.#page,
			requestDocumentGeneration: (request: PlaywrightRequest): number | null =>
				this.#productEntryByRequest.get(request)?.documentGeneration ?? null,
			targetDocumentGeneration: this.#documentGenerations.currentGeneration() + 1,
			timeoutMilliseconds: productJourneyTimeoutMilliseconds,
		});
	}

	emitReloadJoinFailureDiagnostics(workers: readonly MutableObservedWorker[]): void {
		this.#reloadJoinDiagnostics.emitFailure(this.#productEntries, workers);
	}

	failureTransportSnapshot(): BridgeViewerProductFailureTransportSnapshot {
		return {
			entries: this.#productEntries.map(
				({ paneSessionId: _paneSessionId, workerInstanceId: _workerInstanceId, ...entry }) => entry,
			),
			unfinishedRequestOrdinals: [...this.#unfinishedProductRequests]
				.flatMap((request): readonly number[] => {
					const ordinal = this.#productEntryByRequest.get(request)?.ordinal;
					return ordinal === undefined ? [] : [ordinal];
				})
				.toSorted((left, right): number => left - right),
			unresolvedWaiters: [
				...this.#reloadJoinDiagnostics.unresolvedWaiters(),
				...this.#legacyCompletion.unresolvedWaiters(),
				...(this.#productResponseClosureWaiters.size > 0
					? [
							{
								documentGeneration: this.#documentGenerations.currentGeneration(),
								name: 'product-response-quiescence' as const,
							},
						]
					: []),
			],
		};
	}

	legacyRouteTranscript(): readonly BridgeViewerLegacyRouteTranscriptEntry[] {
		return this.#legacyEntries.map(({ documentGeneration: _documentGeneration, ...entry }) => ({
			...entry,
		}));
	}

	async flushResponseParsers(): Promise<void> {
		await this.#responseParsers.flush(this.#documentGenerations.currentGeneration());
	}

	async waitForObservedLegacyMetadataCompletion(): Promise<void> {
		await this.#legacyCompletion.waitForGeneration(
			this.#documentGenerations.currentGeneration(),
			async (completion: Promise<void>): Promise<void> => {
				// A final window already received may still be parsing.
				await this.flushResponseParsers();
				await withBoundedTimeout(
					completion,
					productJourneyTimeoutMilliseconds,
					'legacy Review metadata completion',
				);
			},
		);
	}

	async waitForAllProductResponses(): Promise<void> {
		await withBoundedTimeout(
			this.#waitForStableProductRequestQuiescence(),
			productCompositionSettleTimeoutMilliseconds,
			'all issued product request responses',
		);
	}

	#observeRequest(request: PlaywrightRequest): void {
		const requestUrl = new URL(request.url());
		if (requestUrl.pathname.startsWith('/__bridge-product/')) {
			const requestBody = parseJSONOrNull(request.postData());
			const requestSummary = summarizeBridgeProductRequestBody(requestBody);
			const entry: MutableProductRouteTranscriptEntry = {
				...requestSummary,
				documentGeneration: this.#documentGenerations.requestGeneration(request),
				httpStatus: null,
				method: request.method(),
				ordinal: this.#nextOrdinal++,
				path: requestUrl.pathname,
				responseCode: null,
				responseKind: null,
				resultAcknowledged: false,
				settledResponseKind: null,
				requestSettled: false,
			};
			this.#productEntries.push(entry);
			this.#productEntryByRequest.set(request, entry);
			this.#productActivityRevision += 1;
			if (requestUrl.pathname !== '/__bridge-product/stream') {
				this.#unfinishedProductRequests.add(request);
			}
			return;
		}
		if (!requestUrl.pathname.startsWith('/__bridge-worktree/review-')) return;
		const entry: MutableLegacyRouteTranscriptEntry = {
			documentGeneration: this.#documentGenerations.requestGeneration(request),
			finalWindow: null,
			frameKind: null,
			httpStatus: null,
			ordinal: this.#nextOrdinal++,
			path: requestUrl.pathname,
			sequence: null,
		};
		this.#legacyEntries.push(entry);
		this.#legacyEntryByRequest.set(request, entry);
	}

	#observeResponse(response: PlaywrightResponse): void {
		const responseDocumentGeneration = this.#documentGenerations.currentGeneration();
		const productEntry = this.#productEntryByRequest.get(response.request());
		if (productEntry !== undefined) {
			productEntry.httpStatus = response.status();
			this.#reloadJoinDiagnostics.observeResponse(
				response,
				productEntry,
				responseDocumentGeneration,
			);
			this.#productActivityRevision += 1;
			this.#resolveProductResponseClosureWaitersIfQuiescent();
			if (productEntry.path === '/__bridge-product/command' && response.status() !== 204) {
				this.#responseParsers.track(
					this.#parseProductCommandResponse(response, productEntry),
					productEntry.documentGeneration,
				);
			}
			return;
		}
		const legacyEntry = this.#legacyEntryByRequest.get(response.request());
		if (legacyEntry === undefined) return;
		legacyEntry.httpStatus = response.status();
		if (legacyEntry.path === '/__bridge-worktree/review-metadata') {
			this.#legacyCompletion.observeMetadataResponse(legacyEntry.documentGeneration);
			this.#responseParsers.track(
				this.#parseLegacyMetadataResponse(response, legacyEntry),
				legacyEntry.documentGeneration,
			);
		}
	}

	#observeRequestSettled(request: PlaywrightRequest): void {
		const entry = this.#productEntryByRequest.get(request);
		if (entry !== undefined) entry.requestSettled = true;
		if (!this.#unfinishedProductRequests.delete(request)) return;
		this.#productActivityRevision += 1;
		this.#resolveProductResponseClosureWaitersIfQuiescent();
	}

	async #waitForStableProductRequestQuiescence(): Promise<void> {
		while (true) {
			// oxlint-disable-next-line eslint/no-await-in-loop -- Each pass waits for the current body set before checking for newly admitted product activity.
			await this.#waitForProductRequestQuiescence();
			const observedActivityRevision = this.#productActivityRevision;
			// oxlint-disable-next-line eslint/no-await-in-loop -- The browser-frame checkpoint must follow the body-completion barrier serially.
			await waitForProductBrowserFrameSettlement({
				page: this.#page,
				stage: 'product-request-quiescence',
				timeoutMilliseconds: productCompositionSettleTimeoutMilliseconds,
			});
			if (
				observedActivityRevision === this.#productActivityRevision &&
				this.#productRequestsAreQuiescent()
			) {
				return;
			}
		}
	}

	async #waitForProductRequestQuiescence(): Promise<void> {
		if (this.#productRequestsAreQuiescent()) return;
		let resolveClosure: (() => void) | null = null;
		const closure = new Promise<void>((resolve): void => {
			resolveClosure = resolve;
			this.#productResponseClosureWaiters.add(resolveClosure);
		});
		try {
			await closure;
		} finally {
			if (resolveClosure !== null) this.#productResponseClosureWaiters.delete(resolveClosure);
		}
	}

	#productRequestsAreQuiescent(): boolean {
		const activeDocumentGeneration = this.#documentGenerations.currentGeneration();
		return (
			![...this.#unfinishedProductRequests].some(
				(request): boolean =>
					this.#productEntryByRequest.get(request)?.documentGeneration === activeDocumentGeneration,
			) &&
			!this.#productEntries.some(
				(entry): boolean =>
					entry.documentGeneration === activeDocumentGeneration &&
					entry.path === '/__bridge-product/stream' &&
					entry.httpStatus === null,
			)
		);
	}

	#resolveProductResponseClosureWaitersIfQuiescent(): void {
		if (!this.#productRequestsAreQuiescent()) return;
		for (const resolveClosure of this.#productResponseClosureWaiters) resolveClosure();
		this.#productResponseClosureWaiters.clear();
	}

	async #parseProductCommandResponse(
		response: PlaywrightResponse,
		entry: MutableProductRouteTranscriptEntry,
	): Promise<void> {
		let body: unknown;
		if (entry.requestKind === 'content.acknowledge' && response.status() === 404) {
			const responseBytes = await response.body();
			body = parseJSONOrNull(new TextDecoder().decode(responseBytes));
			entry.contentUnknownReadRefusalCorrelated = correlatedContentUnknownReadRefusal(
				response.request().postData(),
				responseBytes,
			);
		} else {
			body = parseJSONOrNull(await response.text());
		}
		Object.assign(entry, summarizeBridgeProductResponseBody(body));
		this.#openSettlements.observe(entry, parseJSONOrNull(response.request().postData()), body);
	}

	async #parseLegacyMetadataResponse(
		response: PlaywrightResponse,
		entry: MutableLegacyRouteTranscriptEntry,
	): Promise<void> {
		const responseBody = unknownRecord(parseJSONOrNull(await response.text()));
		const protocolFrame = unknownRecord(responseBody?.['protocolFrame']);
		entry.frameKind = stringValue(protocolFrame?.['frameKind']);
		entry.sequence = integerValue(protocolFrame?.['sequence']);
		entry.finalWindow = responseBody?.['nextWindowCursor'] === null;
		if (entry.finalWindow) this.#legacyCompletion.observeFinalWindow(entry.documentGeneration);
	}
}

interface OwnedProductJourneyDeadline {
	readonly dispose: () => Promise<void>;
}

function createOwnedProductJourneyDeadline(props: {
	readonly browser: Browser;
	readonly page: Page;
}): OwnedProductJourneyDeadline {
	let deadlineCleanup: Promise<void> | null = null;
	const deadlineReason = 'BRIDGE_PRODUCT_JOURNEY_DEADLINE_EXCEEDED';
	const timeout = setTimeout((): void => {
		deadlineCleanup = closeOwnedProductJourneyBrowser({
			browser: props.browser,
			page: props.page,
			reason: deadlineReason,
		});
	}, productJourneyOwnedDeadlineMilliseconds);
	return {
		dispose: async (): Promise<void> => {
			clearTimeout(timeout);
			await deadlineCleanup;
		},
	};
}

async function closeOwnedProductJourneyBrowser(props: {
	readonly browser: Browser;
	readonly page: Page;
	readonly reason: string;
}): Promise<void> {
	await Promise.allSettled([
		props.page.close({ reason: props.reason }),
		props.browser.close({ reason: props.reason }),
	]);
}

async function installLegacyIntakeObserver(page: Page): Promise<void> {
	await page.addInitScript((): void => {
		type ProofWindow = Window & {
			bridgeViewerProductOnlyLegacyIntakeTranscript?: BridgeViewerLegacyIntakeTranscriptEntry[];
		};
		const proofWindow = window as ProofWindow;
		proofWindow.bridgeViewerProductOnlyLegacyIntakeTranscript = [];
		document.addEventListener('__bridge_intake_json', (event): void => {
			const detail = event instanceof CustomEvent ? unknownRecordInPage(event.detail) : null;
			const envelope = parseJSONRecordInPage(detail?.['json']);
			const payload = unknownRecordInPage(envelope?.['payload']);
			proofWindow.bridgeViewerProductOnlyLegacyIntakeTranscript?.push({
				frameKind: stringValueInPage(payload?.['frameKind']),
				generation: integerValueInPage(envelope?.['generation']),
				kind: stringValueInPage(envelope?.['kind']),
				sequence: integerValueInPage(envelope?.['sequence']),
				streamId: stringValueInPage(envelope?.['streamId']),
			});
		});

		function parseJSONRecordInPage(value: unknown): Readonly<Record<string, unknown>> | null {
			if (typeof value !== 'string') return null;
			try {
				return unknownRecordInPage(JSON.parse(value) as unknown);
			} catch {
				return null;
			}
		}

		// oxlint-disable-next-line unicorn/consistent-function-scoping -- Init scripts serialize their closure.
		function unknownRecordInPage(value: unknown): Readonly<Record<string, unknown>> | null {
			return isUnknownRecordInPage(value) ? value : null;
		}

		// oxlint-disable-next-line unicorn/consistent-function-scoping -- Init scripts serialize their closure.
		function isUnknownRecordInPage(value: unknown): value is Readonly<Record<string, unknown>> {
			return typeof value === 'object' && value !== null && !Array.isArray(value);
		}

		// oxlint-disable-next-line unicorn/consistent-function-scoping -- Init scripts serialize their closure.
		function stringValueInPage(value: unknown): string | null {
			return typeof value === 'string' ? value : null;
		}

		// oxlint-disable-next-line unicorn/consistent-function-scoping -- Init scripts serialize their closure.
		function integerValueInPage(value: unknown): number | null {
			return typeof value === 'number' && Number.isSafeInteger(value) ? value : null;
		}
	});
}

async function readLegacyIntakeTranscript(
	page: Page,
): Promise<readonly BridgeViewerLegacyIntakeTranscriptEntry[]> {
	return await page.evaluate((): readonly BridgeViewerLegacyIntakeTranscriptEntry[] => {
		type ProofWindow = Window & {
			bridgeViewerProductOnlyLegacyIntakeTranscript?: BridgeViewerLegacyIntakeTranscriptEntry[];
		};
		return (window as ProofWindow).bridgeViewerProductOnlyLegacyIntakeTranscript ?? [];
	});
}

async function readFileProductState(page: Page): Promise<BridgeViewerFileProductStateSnapshot> {
	const state = await page.evaluate((selectors) => {
		const shells = document.querySelectorAll(selectors.fileShell);
		const shell = shells.item(0);
		const codeCanvas = document.querySelector(selectors.fileCodeCanvas);
		const bodyPreview = codeCanvas?.getAttribute('data-worktree-open-file-body-preview') ?? null;
		return {
			bodyPreview,
			codeCanvasVisible: isVisibleInPage(codeCanvas),
			displayStatus: shell?.getAttribute('data-file-display-status') ?? null,
			metadataFileRowCount: Number(
				shell?.getAttribute('data-worktree-metadata-file-row-count') ?? '0',
			),
			metadataTreeRowCount: Number(
				shell?.getAttribute('data-worktree-metadata-tree-row-count') ?? '0',
			),
			renderedDisplayPath: codeCanvas?.getAttribute('data-worktree-rendered-file-path') ?? null,
			selectedContentState: shell?.getAttribute('data-worktree-open-file-state') ?? null,
			selectedDisplayPath: shell?.getAttribute('data-worktree-open-file-path') ?? null,
			shellCount: shells.length,
		};

		// oxlint-disable-next-line unicorn/consistent-function-scoping -- Playwright serializes this browser callback without outer helpers.
		function isVisibleInPage(element: Element | null): boolean {
			if (!(element instanceof HTMLElement) || element.closest('[hidden]') !== null) return false;
			const style = getComputedStyle(element);
			return (
				style.display !== 'none' &&
				style.visibility !== 'hidden' &&
				element.getClientRects().length > 0
			);
		}
	}, bridgeViewerProductOnlySelectors);
	const { bodyPreview, ...snapshot } = state;
	return {
		...snapshot,
		bodyPreviewCharacterCount: bodyPreview?.length ?? 0,
		bodyPreviewSha256: sha256OrNull(bodyPreview),
	};
}

async function readReviewProductState(page: Page): Promise<BridgeViewerReviewProductStateSnapshot> {
	const state = await page.evaluate((selectors) => {
		const shells = document.querySelectorAll(selectors.reviewShell);
		const shell = shells.item(0);
		const codePanel = document.querySelector(selectors.reviewCodePanel);
		const selectedContentCacheKeys =
			codePanel?.getAttribute('data-selected-content-cache-keys') ?? null;
		return {
			codePanelVisible: isVisibleInPage(codePanel),
			metadataItemCount: Number(shell?.getAttribute('data-review-metadata-item-count') ?? '0'),
			metadataTreeRowCount: Number(
				shell?.getAttribute('data-review-metadata-tree-row-count') ?? '0',
			),
			selectedContentCacheKeyCount: Number(
				codePanel?.getAttribute('data-selected-content-cache-key-count') ?? '0',
			),
			selectedContentCacheKeys,
			selectedContentCharacterCount: Number(
				codePanel?.getAttribute('data-selected-content-character-count') ?? '0',
			),
			selectedContentLineCount: Number(
				codePanel?.getAttribute('data-selected-content-line-count') ?? '0',
			),
			selectedContentState: shell?.getAttribute('data-selected-content-state') ?? null,
			selectedDisplayPath: shell?.getAttribute('data-selected-display-path') ?? null,
			shellCount: shells.length,
			unavailableTextVisible: (shell?.textContent ?? '').includes('Content unavailable'),
		};

		// oxlint-disable-next-line unicorn/consistent-function-scoping -- Playwright serializes this browser callback without outer helpers.
		function isVisibleInPage(element: Element | null): boolean {
			if (!(element instanceof HTMLElement) || element.closest('[hidden]') !== null) return false;
			const style = getComputedStyle(element);
			return (
				style.display !== 'none' &&
				style.visibility !== 'hidden' &&
				element.getClientRects().length > 0
			);
		}
	}, bridgeViewerProductOnlySelectors);
	const { selectedContentCacheKeys, ...snapshot } = state;
	return {
		...snapshot,
		selectedContentCacheKeysSha256: sha256OrNull(selectedContentCacheKeys),
	};
}

async function waitForViewerMode(page: Page, mode: 'file' | 'review'): Promise<void> {
	await page.waitForFunction(
		({ expectedMode, selector }): boolean =>
			document.querySelector(selector)?.getAttribute('data-bridge-viewer-mode') === expectedMode,
		{ expectedMode: mode, selector: bridgeViewerProductOnlySelectors.appRoot },
		{ timeout: productJourneyTimeoutMilliseconds },
	);
}

function sha256OrNull(value: string | null): string | null {
	return value === null || value.length === 0
		? null
		: createHash('sha256').update(value).digest('hex');
}

function classifyObservedWorker(url: string, documentGeneration: number): MutableObservedWorker {
	const lifecycle = {
		closed: false,
		closedBeforeJourneyCompletion: false,
		documentGeneration,
	};
	if (url.includes('/src/core/comm-worker/bridge-comm-worker-vite-entry.ts')) {
		return { ...lifecycle, kind: 'comm-worker', url: safeWorkerUrl(url) };
	}
	if (url.startsWith('blob:')) {
		return { ...lifecycle, kind: 'portable-blob-worker', url: 'blob:<opaque>' };
	}
	return { ...lifecycle, kind: 'module-worker', url: safeWorkerUrl(url) };
}

function safeWorkerUrl(url: string): string {
	const parsedUrl = new URL(url);
	return `${parsedUrl.pathname}${parsedUrl.search}`;
}

async function withBoundedTimeout<TValue>(
	promise: Promise<TValue>,
	timeoutMilliseconds: number,
	label: string,
): Promise<TValue> {
	let timeout: ReturnType<typeof setTimeout> | null = null;
	try {
		return await Promise.race([
			promise,
			new Promise<TValue>((_resolve, reject): void => {
				timeout = setTimeout(
					(): void => reject(new Error(`Timed out waiting for ${label}`)),
					timeoutMilliseconds,
				);
			}),
		]);
	} finally {
		if (timeout !== null) clearTimeout(timeout);
	}
}
