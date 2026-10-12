import type { Page } from 'playwright';

import { bridgeViewerProductOnlySelectors } from './product-only-real-router-contract.ts';
import { observeReviewPaintReceipt } from './product-only-real-router-review-paint-observation.ts';

export interface BridgeViewerReviewPaintElementSnapshot {
	readonly contentState: string | null;
	readonly paintedPublicationId: string | null;
	readonly paintedSourceCorrelations: string | null;
	readonly renderDispositionSettledOutcome: string | null;
	readonly renderDispositionSettledPublicationId: string | null;
}

export interface BridgeViewerReviewPaintFailureSnapshot {
	readonly actualScrollTop: number;
	readonly captureError: 'snapshot-unavailable' | null;
	readonly codeScroll: {
		readonly clientHeight: number;
		readonly scrollHeight: number;
		readonly scrollTop: number;
	};
	readonly header: BridgeViewerReviewPaintElementSnapshot | null;
	readonly headerRendered: boolean;
	readonly itemElement: BridgeViewerReviewPaintElementSnapshot | null;
	readonly itemInDom: boolean;
	readonly itemRect: {
		readonly bottom: number;
		readonly height: number;
		readonly left: number;
		readonly right: number;
		readonly top: number;
		readonly width: number;
	} | null;
	readonly requestedScrollTop: number;
	readonly viewportRelation: 'in-view' | 'partly-in-view' | 'out-of-view' | 'missing';
	readonly workerLastPublishedVisibleItemIds: readonly string[] | null;
}

export interface BridgeViewerReviewPaintLedgerEntry {
	readonly displayPath: string;
	readonly itemId: string;
	readonly actualScrollTop: number;
	readonly requestedScrollTop: number;
	readonly targetSnapshot: BridgeViewerReviewPaintFailureSnapshot;
	readonly failureSnapshot?: BridgeViewerReviewPaintFailureSnapshot;
	readonly publicationId: string | null;
	readonly reason: string | null;
	readonly status: 'failed' | 'painted' | 'targeted';
}

interface ReviewPaintViewportState {
	readonly codeScroll: {
		readonly clientHeight: number;
		readonly scrollHeight: number;
		readonly scrollTop: number;
	};
	readonly visibleItems: readonly {
		readonly displayPath?: string | null;
		readonly itemId: string;
	}[];
}

export async function collectReviewPaintLedger(props: {
	readonly expectedItemIds: readonly string[];
	readonly observeWait:
		| (<TValue>(promise: Promise<TValue>, label: string) => Promise<TValue>)
		| undefined;
	readonly page: Page;
	readonly readViewportState: () => Promise<ReviewPaintViewportState>;
	readonly scroll: (
		direction: 'backward' | 'forward',
		state: ReviewPaintViewportState,
	) => Promise<{ readonly requestedScrollTop: number }>;
	readonly selectedItemId: string | null;
}): Promise<readonly BridgeViewerReviewPaintLedgerEntry[]> {
	const ledger: BridgeViewerReviewPaintLedgerEntry[] = [];
	let state: ReviewPaintViewportState | null = null;
	let pendingItemId: string | null =
		props.expectedItemIds.find((itemId) => itemId !== props.selectedItemId) ?? null;
	const observe = async <TValue>(promise: Promise<TValue>, label: string): Promise<TValue> =>
		await (props.observeWait?.(promise, label) ?? promise);
	try {
		state = await observe(props.readViewportState(), 'Review paint initial viewport');
		const maximumScrollTop = (): number =>
			Math.max(0, (state?.codeScroll.scrollHeight ?? 0) - (state?.codeScroll.clientHeight ?? 0));
		for (
			let stepIndex = 0;
			state.codeScroll.scrollTop > 1 && stepIndex < props.expectedItemIds.length * 4;
			stepIndex += 1
		) {
			await observe(props.scroll('backward', state), 'Review paint return to top');
			state = await observe(props.readViewportState(), 'Review paint return viewport');
		}
		for (const itemId of props.expectedItemIds) {
			if (itemId === props.selectedItemId) continue;
			pendingItemId = itemId;
			let requestedScrollTop = state.codeScroll.scrollTop;
			const ledgerIndex = ledger.length;
			ledger.push({
				actualScrollTop: state.codeScroll.scrollTop,
				displayPath: itemId,
				itemId,
				publicationId: null,
				reason: null,
				requestedScrollTop,
				status: 'targeted',
				targetSnapshot: unavailableReviewPaintSnapshot(
					state.codeScroll.scrollTop,
					requestedScrollTop,
				),
			});
			let visibleItem = state.visibleItems.find((item) => item.itemId === itemId);
			for (
				let stepIndex = 0;
				visibleItem === undefined && state.codeScroll.scrollTop < maximumScrollTop() - 1;
				stepIndex += 1
			) {
				if (stepIndex >= props.expectedItemIds.length * 4) break;
				requestedScrollTop = (
					await observe(props.scroll('forward', state), `Review paint target ${itemId}`)
				).requestedScrollTop;
				state = await observe(props.readViewportState(), `Review paint target viewport ${itemId}`);
				visibleItem = state.visibleItems.find((item) => item.itemId === itemId);
			}
			const displayPath = visibleItem?.displayPath ?? itemId;
			const targetSnapshot = await observe(
				captureReviewPaintFailureSnapshot({
					actualScrollTop: state.codeScroll.scrollTop,
					itemId,
					page: props.page,
					requestedScrollTop,
				}),
				`Review paint target snapshot ${displayPath}`,
			);
			const targetedEntry: BridgeViewerReviewPaintLedgerEntry = {
				actualScrollTop: state.codeScroll.scrollTop,
				displayPath,
				itemId,
				publicationId: null,
				reason: null,
				requestedScrollTop,
				status: 'targeted',
				targetSnapshot,
			};
			ledger[ledgerIndex] = targetedEntry;
			if (visibleItem === undefined) {
				ledger[ledgerIndex] = {
					...targetedEntry,
					reason: 'item did not become visible during product scroll traversal',
					status: 'failed',
				};
				continue;
			}
			try {
				const painted = await waitForPaintedReviewItem({
					itemId,
					observeWait: props.observeWait,
					page: props.page,
					path: displayPath,
				});
				ledger[ledgerIndex] = {
					...targetedEntry,
					publicationId: painted.publicationId,
					status: 'painted',
				};
			} catch (error: unknown) {
				if (error instanceof Error && error.message.includes('BRIDGE_')) throw error;
				ledger[ledgerIndex] = {
					...targetedEntry,
					failureSnapshot: targetSnapshot,
					reason: error instanceof Error ? error.message : String(error),
					status: 'failed',
				};
			}
		}
		pendingItemId = null;
		while (state.codeScroll.scrollTop < maximumScrollTop() - 1) {
			await observe(props.scroll('forward', state), 'Review paint restore bottom');
			state = await observe(props.readViewportState(), 'Review paint restore viewport');
		}
		return ledger;
	} catch (error: unknown) {
		const snapshot =
			ledger.find((entry) => entry.itemId === pendingItemId)?.targetSnapshot ??
			ledger.at(-1)?.targetSnapshot ??
			unavailableReviewPaintSnapshot(state?.codeScroll.scrollTop ?? 0, 0);
		throw new BridgeViewerReviewPaintWaitFailure(
			error instanceof Error ? error : new Error(String(error)),
			snapshot,
			ledger,
			pendingItemId,
		);
	}
}

function unavailableReviewPaintSnapshot(
	actualScrollTop: number,
	requestedScrollTop: number,
): BridgeViewerReviewPaintFailureSnapshot {
	return {
		actualScrollTop,
		captureError: 'snapshot-unavailable',
		codeScroll: { clientHeight: 0, scrollHeight: 0, scrollTop: actualScrollTop },
		header: null,
		headerRendered: false,
		itemElement: null,
		itemInDom: false,
		itemRect: null,
		requestedScrollTop,
		viewportRelation: 'missing',
		workerLastPublishedVisibleItemIds: null,
	};
}

export interface BridgeViewerReviewPaintFailureEvidence {
	readonly paintLedger: readonly BridgeViewerReviewPaintLedgerEntry[];
	readonly pendingPaintItemId: string | null;
	readonly snapshot: BridgeViewerReviewPaintFailureSnapshot;
}

export type BridgeViewerReviewPaintViewportRelation =
	| 'in-view'
	| 'partly-in-view'
	| 'out-of-view'
	| 'missing';

export function bridgeViewerReviewPaintViewportRelation(props: {
	readonly clientHeight?: number;
	readonly itemRect: { readonly bottom: number; readonly top: number } | null;
	readonly scrollHeight?: number;
	readonly viewportRect: { readonly bottom: number; readonly top: number } | null;
}): BridgeViewerReviewPaintViewportRelation {
	if (props.itemRect === null || props.viewportRect === null) return 'missing';
	if (
		props.itemRect.bottom <= props.viewportRect.top ||
		props.itemRect.top >= props.viewportRect.bottom
	)
		return 'out-of-view';
	return props.itemRect.top >= props.viewportRect.top &&
		props.itemRect.bottom <= props.viewportRect.bottom
		? 'in-view'
		: 'partly-in-view';
}

export class BridgeViewerReviewPaintWaitFailure extends Error {
	readonly evidence: BridgeViewerReviewPaintFailureEvidence;
	readonly snapshot: BridgeViewerReviewPaintFailureSnapshot;

	constructor(
		cause: Error,
		snapshot: BridgeViewerReviewPaintFailureSnapshot,
		paintLedger: readonly BridgeViewerReviewPaintLedgerEntry[],
		pendingPaintItemId: string | null,
	) {
		super(cause.message, { cause });
		this.name = 'BridgeViewerReviewPaintWaitFailure';
		this.snapshot = snapshot;
		this.evidence = { paintLedger, pendingPaintItemId, snapshot };
	}
}

export function bridgeViewerReviewPaintFailureEvidenceFromError(
	error: unknown,
): BridgeViewerReviewPaintFailureEvidence | null {
	return error instanceof BridgeViewerReviewPaintWaitFailure ? error.evidence : null;
}

async function captureReviewPaintFailureSnapshot(props: {
	readonly actualScrollTop: number;
	readonly itemId: string;
	readonly page: Page;
	readonly requestedScrollTop: number;
}): Promise<BridgeViewerReviewPaintFailureSnapshot> {
	try {
		return await props.page.evaluate(
			({
				actualScrollTop,
				itemId,
				requestedScrollTop,
				scrollSelector,
			}): BridgeViewerReviewPaintFailureSnapshot => {
				const codeScrollOwner = document.querySelector(scrollSelector);
				const codeScroll =
					codeScrollOwner instanceof HTMLElement
						? {
								clientHeight: codeScrollOwner.clientHeight,
								scrollHeight: codeScrollOwner.scrollHeight,
								scrollTop: codeScrollOwner.scrollTop,
							}
						: { clientHeight: 0, scrollHeight: 0, scrollTop: actualScrollTop };
				const codeScrollRect = codeScrollOwner?.getBoundingClientRect() ?? null;
				const itemHost = queryAllInOpenShadowRoots(document, 'diffs-container').find(
					(host): boolean =>
						bridgeReviewHostElement(host, '[data-bridge-code-view-item-id]')?.getAttribute(
							'data-bridge-code-view-item-id',
						) === itemId,
				);
				const itemRect = itemHost?.getBoundingClientRect() ?? null;
				const itemElement = itemHost === undefined ? null : elementSnapshot(itemHost);
				const header =
					itemHost === undefined
						? null
						: bridgeReviewHostElement(itemHost, '[data-testid="bridge-code-view-header-metadata"]');
				const headerRect = header?.getBoundingClientRect() ?? null;
				const headerRendered =
					header !== null && headerRect !== null && headerRect.width > 0 && headerRect.height > 0;
				const itemInDom = itemHost !== undefined;
				const viewportRelation = !itemInDom
					? 'missing'
					: bridgeViewerReviewPaintViewportRelation({
							itemRect,
							viewportRect: codeScrollRect,
						});
				return {
					actualScrollTop,
					captureError: null,
					codeScroll,
					header: header === null ? null : elementSnapshot(header),
					headerRendered,
					itemElement,
					itemInDom,
					itemRect:
						itemRect === null
							? null
							: {
									bottom: itemRect.bottom,
									height: itemRect.height,
									left: itemRect.left,
									right: itemRect.right,
									top: itemRect.top,
									width: itemRect.width,
								},
					requestedScrollTop,
					viewportRelation,
					workerLastPublishedVisibleItemIds: null,
				};

				function elementSnapshot(element: Element): BridgeViewerReviewPaintElementSnapshot {
					return {
						contentState: element.getAttribute('data-bridge-code-view-content-state'),
						paintedPublicationId: element.getAttribute('data-bridge-painted-publication-id'),
						paintedSourceCorrelations: element.getAttribute(
							'data-bridge-painted-source-correlations',
						),
						renderDispositionSettledOutcome: element.getAttribute(
							'data-bridge-render-disposition-settled-outcome',
						),
						renderDispositionSettledPublicationId: element.getAttribute(
							'data-bridge-render-disposition-settled-publication-id',
						),
					};
				}

				function bridgeViewerReviewPaintViewportRelation(props: {
					itemRect: { bottom: number; top: number } | null;
					viewportRect: { bottom: number; top: number } | null;
				}): BridgeViewerReviewPaintViewportRelation {
					if (props.itemRect === null || props.viewportRect === null) return 'missing';
					if (
						props.itemRect.bottom <= props.viewportRect.top ||
						props.itemRect.top >= props.viewportRect.bottom
					)
						return 'out-of-view';
					return props.itemRect.top >= props.viewportRect.top &&
						props.itemRect.bottom <= props.viewportRect.bottom
						? 'in-view'
						: 'partly-in-view';
				}

				function bridgeReviewHostElement(host: Element, selector: string): Element | null {
					return host.querySelector(selector) ?? host.shadowRoot?.querySelector(selector) ?? null;
				}

				function queryAllInOpenShadowRoots(
					root: Document | Element | ShadowRoot,
					selector: string,
				): Element[] {
					const matches = [...root.querySelectorAll(selector)];
					for (const descendant of root.querySelectorAll('*')) {
						if (descendant.shadowRoot !== null)
							matches.push(...queryAllInOpenShadowRoots(descendant.shadowRoot, selector));
					}
					return matches;
				}
			},
			{
				actualScrollTop: props.actualScrollTop,
				itemId: props.itemId,
				requestedScrollTop: props.requestedScrollTop,
				scrollSelector: bridgeViewerProductOnlySelectors.reviewCodeScrollOwner,
			},
		);
	} catch {
		return {
			actualScrollTop: props.actualScrollTop,
			captureError: 'snapshot-unavailable',
			codeScroll: {
				clientHeight: 0,
				scrollHeight: 0,
				scrollTop: props.actualScrollTop,
			},
			header: null,
			headerRendered: false,
			itemElement: null,
			itemInDom: false,
			itemRect: null,
			requestedScrollTop: props.requestedScrollTop,
			viewportRelation: 'missing',
			workerLastPublishedVisibleItemIds: null,
		};
	}
}

async function waitForPaintedReviewItem(props: {
	readonly itemId: string;
	readonly observeWait:
		| (<TValue>(promise: Promise<TValue>, label: string) => Promise<TValue>)
		| undefined;
	readonly page: Page;
	readonly path: string;
}): Promise<{ readonly publicationId: string }> {
	const snapshotPromise = props.page.evaluate(observeReviewPaintReceipt, { itemId: props.itemId });
	try {
		return await (props.observeWait?.(snapshotPromise, `Review item paint ${props.path}`) ??
			snapshotPromise);
	} finally {
		// Resolve disconnects in-page; owner failure cancels before another item starts.
		// A closed context has already retired its observer and event listeners.
		await props.page
			.evaluate((itemId): void => {
				window.dispatchEvent(new CustomEvent('__bridge_review_paint_cancel', { detail: itemId }));
			}, props.itemId)
			.catch((): void => {});
	}
}
