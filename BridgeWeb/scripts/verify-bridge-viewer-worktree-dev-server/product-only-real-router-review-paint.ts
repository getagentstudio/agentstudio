import type { Page } from 'playwright';

import type {
	BridgeViewerReviewPaintElementSnapshot,
	BridgeViewerReviewPaintFailureSnapshot,
	BridgeViewerReviewPaintLedgerEntry,
} from './product-only-real-router-contract.ts';

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
	let state = await props.readViewportState();
	const maximumScrollTop = (): number =>
		Math.max(0, state.codeScroll.scrollHeight - state.codeScroll.clientHeight);
	for (
		let stepIndex = 0;
		state.codeScroll.scrollTop > 1 && stepIndex < props.expectedItemIds.length * 4;
		stepIndex += 1
	) {
		await props.scroll('backward', state);
		state = await props.readViewportState();
	}
	const ledger: BridgeViewerReviewPaintLedgerEntry[] = [];
	for (const itemId of props.expectedItemIds) {
		if (itemId === props.selectedItemId) continue;
		let requestedScrollTop = state.codeScroll.scrollTop;
		let visibleItem = state.visibleItems.find((item) => item.itemId === itemId);
		for (
			let stepIndex = 0;
			visibleItem === undefined && state.codeScroll.scrollTop < maximumScrollTop() - 1;
			stepIndex += 1
		) {
			if (stepIndex >= props.expectedItemIds.length * 4) break;
			requestedScrollTop = (await props.scroll('forward', state)).requestedScrollTop;
			state = await props.readViewportState();
			visibleItem = state.visibleItems.find((item) => item.itemId === itemId);
		}
		const displayPath = visibleItem?.displayPath ?? itemId;
		const targetSnapshot = await captureReviewPaintFailureSnapshot({
			actualScrollTop: state.codeScroll.scrollTop,
			itemId,
			page: props.page,
			requestedScrollTop,
		});
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
		ledger.push(targetedEntry);
		if (visibleItem === undefined) {
			ledger[ledger.length - 1] = {
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
			ledger[ledger.length - 1] = {
				...targetedEntry,
				publicationId: painted.publicationId,
				status: 'painted',
			};
		} catch (error: unknown) {
			const failureSnapshot = await captureReviewPaintFailureSnapshot({
				actualScrollTop: state.codeScroll.scrollTop,
				itemId,
				page: props.page,
				requestedScrollTop,
			});
			ledger[ledger.length - 1] = {
				...targetedEntry,
				failureSnapshot,
				reason: error instanceof Error ? error.message : String(error),
				status: 'failed',
			};
			if (error instanceof Error && error.message.includes('BRIDGE_')) {
				throw new BridgeViewerReviewPaintWaitFailure(error, failureSnapshot, ledger, itemId);
			}
		}
	}
	while (state.codeScroll.scrollTop < maximumScrollTop() - 1) {
		await props.scroll('forward', state);
		state = await props.readViewportState();
	}
	return ledger;
}

export interface BridgeViewerReviewPaintFailureEvidence {
	readonly paintLedger: readonly BridgeViewerReviewPaintLedgerEntry[];
	readonly pendingPaintItemId: string;
	readonly snapshot: BridgeViewerReviewPaintFailureSnapshot;
}

export class BridgeViewerReviewPaintWaitFailure extends Error {
	readonly evidence: BridgeViewerReviewPaintFailureEvidence;
	readonly snapshot: BridgeViewerReviewPaintFailureSnapshot;

	constructor(
		cause: Error,
		snapshot: BridgeViewerReviewPaintFailureSnapshot,
		paintLedger: readonly BridgeViewerReviewPaintLedgerEntry[],
		pendingPaintItemId: string,
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
			({ actualScrollTop, itemId, requestedScrollTop }): BridgeViewerReviewPaintFailureSnapshot => {
				const codeScrollOwner = document.querySelector(
					'[data-testid="bridge-review-code-view-scroll-owner"]',
				);
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
				const viewportRelation =
					!itemInDom || itemRect === null || codeScrollRect === null
						? 'missing'
						: itemRect.bottom <= codeScrollRect.top || itemRect.top >= codeScrollRect.bottom
							? 'out-of-view'
							: itemRect.top >= codeScrollRect.top && itemRect.bottom <= codeScrollRect.bottom
								? 'in-view'
								: 'partly-in-view';
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
	const snapshotPromise = props.page.waitForFunction(
		({ itemId }): { readonly publicationId: string } | false => {
			for (const host of queryAllInOpenShadowRoots(document, 'diffs-container')) {
				const marker = bridgeReviewHostElement(host, '[data-bridge-code-view-item-id]');
				if (marker?.getAttribute('data-bridge-code-view-item-id') !== itemId) continue;
				const publicationId = host.getAttribute('data-bridge-painted-publication-id');
				const correlations = host.getAttribute('data-bridge-painted-source-correlations');
				if (publicationId === null || correlations === null) continue;
				try {
					const parsed: unknown = JSON.parse(correlations);
					if (
						Array.isArray(parsed) &&
						parsed.some(
							(correlation): boolean =>
								typeof correlation === 'object' &&
								correlation !== null &&
								Reflect.get(correlation, 'semanticItemId') === itemId &&
								Reflect.get(correlation, 'publicationId') === publicationId,
						)
					) {
						return { publicationId };
					}
				} catch {}
			}
			return false;

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
		{ itemId: props.itemId },
	);
	const snapshotHandle = await (props.observeWait?.(
		snapshotPromise,
		`Review item paint ${props.path}`,
	) ?? snapshotPromise);
	const rawSnapshot: unknown = await snapshotHandle.jsonValue();
	const publicationId =
		typeof rawSnapshot === 'object' && rawSnapshot !== null
			? Reflect.get(rawSnapshot, 'publicationId')
			: null;
	if (typeof publicationId !== 'string' || publicationId.length === 0) {
		throw new Error(`Review item paint receipt missing for ${props.path}`);
	}
	return { publicationId };
}
