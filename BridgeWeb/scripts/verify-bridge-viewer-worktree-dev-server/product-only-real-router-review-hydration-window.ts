import { errors, type Page } from 'playwright';
import { z } from 'zod';

import { bridgeViewerProductOnlySelectors } from './product-only-real-router-contract.ts';

export interface FreshReviewHydrationWindowSnapshot {
	readonly hydratedNonSelectedItemIds: readonly string[];
	readonly scrollTop: number;
	readonly visibleContentStates: readonly {
		readonly contentState: string | null;
		readonly itemId: string;
	}[];
	readonly visibleNonSelectedItemIds: readonly string[];
}

const visibleReviewItemSchema = z
	.object({
		contentState: z.string().nullable(),
		itemId: z.string().min(1),
		publicationId: z.string().nullable(),
		renderedLineCount: z.number().int().nonnegative(),
		sourceCorrelations: z.string().nullable(),
	})
	.strict();
const rawReviewWindowSchema = z
	.object({
		scrollTop: z.number().nonnegative(),
		visibleItems: z.array(visibleReviewItemSchema),
	})
	.strict();

type VisibleReviewItem = z.infer<typeof visibleReviewItemSchema>;

export function classifyFreshReviewHydrationWindow(props: {
	readonly excludedItemIds: readonly string[];
	readonly scrollTop: number;
	readonly selectedItemId: string | null;
	readonly visibleItems: readonly VisibleReviewItem[];
}): FreshReviewHydrationWindowSnapshot {
	const excludedItemIds = new Set(props.excludedItemIds);
	const candidates = props.visibleItems.filter(
		(item) => item.itemId !== props.selectedItemId && !excludedItemIds.has(item.itemId),
	);
	return {
		hydratedNonSelectedItemIds: candidates.filter(isPaintedReviewItem).map((item) => item.itemId),
		scrollTop: props.scrollTop,
		visibleContentStates: candidates.map(({ contentState, itemId }) => ({ contentState, itemId })),
		visibleNonSelectedItemIds: candidates.map((item) => item.itemId),
	};
}

function isPaintedReviewItem(item: VisibleReviewItem): boolean {
	if (item.renderedLineCount === 0 && item.publicationId === null) return false;
	if (item.publicationId === null || item.sourceCorrelations === null) return false;
	try {
		const correlations: unknown = JSON.parse(item.sourceCorrelations);
		return (
			Array.isArray(correlations) &&
			correlations.length > 0 &&
			correlations.every(
				(correlation): boolean =>
					typeof correlation === 'object' &&
					correlation !== null &&
					Reflect.get(correlation, 'itemId') === item.itemId &&
					Reflect.get(correlation, 'pierreItemId') === item.itemId &&
					Reflect.get(correlation, 'semanticItemId') === item.itemId &&
					Reflect.get(correlation, 'publicationId') === item.publicationId,
			)
		);
	} catch {
		return false;
	}
}

export function previousFreshReviewTraversalScrollTop(props: {
	readonly codeScroll: {
		readonly clientHeight: number;
		readonly scrollTop: number;
	};
}): number {
	const viewportAdvance = Math.max(1, props.codeScroll.clientHeight * 0.8);
	return Math.max(0, Math.floor(props.codeScroll.scrollTop - viewportAdvance));
}

export async function waitForFreshReviewHydrationWindowSnapshot(props: {
	readonly excludedItemIds: readonly string[];
	readonly page: Page;
	readonly selectedItemId: string | null;
	readonly timeoutMilliseconds: number;
}): Promise<FreshReviewHydrationWindowSnapshot | null> {
	try {
		const snapshotHandle = await props.page.waitForFunction(
			({ selectors }) => {
				const codePanel = document.querySelector(selectors.reviewCodePanel);
				const codeScrollOwner = document.querySelector(selectors.reviewCodeScrollOwner);
				if (!(codeScrollOwner instanceof HTMLElement)) return false;
				const codeScrollRect = codeScrollOwner.getBoundingClientRect();
				const visibleItems = queryAllInOpenShadowRoots(
					codePanel ?? document,
					'diffs-container',
				).flatMap((reviewItemHost) => {
					const marker = bridgeReviewHostElement(reviewItemHost, '[data-bridge-code-view-item-id]');
					const itemId = marker?.getAttribute('data-bridge-code-view-item-id');
					if (itemId === null || itemId === undefined) return [];
					const hostRect = reviewItemHost.getBoundingClientRect();
					if (hostRect.bottom <= codeScrollRect.top || hostRect.top >= codeScrollRect.bottom) {
						return [];
					}
					const contentState = bridgeReviewHostElement(
						reviewItemHost,
						'[data-bridge-code-view-content-state]',
					)?.getAttribute('data-bridge-code-view-content-state');
					const publicationId = reviewItemHost.getAttribute('data-bridge-painted-publication-id');
					const sourceCorrelations = reviewItemHost.getAttribute(
						'data-bridge-painted-source-correlations',
					);
					const renderedLineCount = queryAllInOpenShadowRoots(
						reviewItemHost,
						'[data-line][data-line-index]',
					).length;
					return [{ contentState, itemId, publicationId, renderedLineCount, sourceCorrelations }];
				});
				if (
					visibleItems.length === 0 ||
					visibleItems.some(
						(item) => item.contentState !== 'hydrated' && item.contentState !== 'windowed',
					)
				) {
					return false;
				}
				return { scrollTop: codeScrollOwner.scrollTop, visibleItems };

				function bridgeReviewHostElement(host: Element, selector: string): Element | null {
					return host.querySelector(selector) ?? host.shadowRoot?.querySelector(selector) ?? null;
				}

				function queryAllInOpenShadowRoots(
					root: Document | Element | ShadowRoot,
					selector: string,
				): Element[] {
					const matches = [...root.querySelectorAll(selector)];
					for (const descendant of root.querySelectorAll('*')) {
						if (descendant.shadowRoot === null) continue;
						matches.push(...queryAllInOpenShadowRoots(descendant.shadowRoot, selector));
					}
					return matches;
				}
			},
			{ selectors: bridgeViewerProductOnlySelectors },
			{ timeout: props.timeoutMilliseconds },
		);
		const rawSnapshot: unknown = await snapshotHandle.jsonValue();
		if (rawSnapshot === false) return null;
		const snapshot = rawReviewWindowSchema.parse(rawSnapshot);
		return classifyFreshReviewHydrationWindow({
			excludedItemIds: props.excludedItemIds,
			scrollTop: snapshot.scrollTop,
			selectedItemId: props.selectedItemId,
			visibleItems: snapshot.visibleItems,
		});
	} catch (error: unknown) {
		if (error instanceof errors.TimeoutError) return null;
		throw error;
	}
}
