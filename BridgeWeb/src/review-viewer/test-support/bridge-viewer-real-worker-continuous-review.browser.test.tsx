import { act } from 'react';
import { afterEach, describe, expect, test } from 'vitest';
import { cleanup, render } from 'vitest-browser-react';

import { installBridgeReadyHandshake } from '../../app/bridge-app-browser-test-actions.js';

// oxlint-disable-next-line import/no-unassigned-import -- Browser Mode must load production app CSS.
import '../../app/bridge-app.css';
import { parseBridgeAppDevFixtureOptions } from '../../app/bridge-app-dev-fixture.js';
import {
	installBridgeAppDevProductSessionHost,
	type BridgeAppDevProductSessionHost,
} from '../../app/bridge-app-dev-product-session-host.js';
import { BridgeAppProtocolRouter } from '../../app/bridge-app-protocol-router.js';
import {
	createBridgePaneRuntime,
	type BridgePaneRuntime,
} from '../../core/comm-worker/bridge-pane-runtime.js';
import pageConfigurationFixture from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-page-configuration.json' with { type: 'json' };
import { ensureBridgeCodeViewThemeResolved } from '../code-view/bridge-code-view-theme.js';
import { createBridgePierrePortableBlobWorkerFactory } from '../workers/pierre/bridge-pierre-dev-worker-factory.js';
import { terminateBridgePierreWorkerPoolSingletonForTest } from '../workers/pierre/bridge-pierre-worker-pool.js';
import { createBridgeCommWorkerModuleWorker } from '../workers/shared-rpc/bridge-comm-worker-dev-factory.js';
import { visibleTextIncludingOpenShadowRoots } from './bridge-viewer-browser-visible-text.js';

const reviewProductFrameBudget = 600;
const reviewProductFinalMilestoneBudget = 32;

// oxlint-disable-next-line no-underscore-dangle -- Vite injects this test-only compile flag.
declare const __BRIDGE_REAL_VITE_PRODUCT_TEST__: boolean | undefined;

const realViteProductTestEnabled =
	typeof __BRIDGE_REAL_VITE_PRODUCT_TEST__ !== 'undefined' && __BRIDGE_REAL_VITE_PRODUCT_TEST__;
const realViteProductTest = realViteProductTestEnabled ? test : test.skip;

let activeHandshakeDisposer: (() => void) | null = null;
let activePaneRuntime: BridgePaneRuntime | null = null;
let activePierreWorkerFactory: ReturnType<
	typeof createBridgePierrePortableBlobWorkerFactory
> | null = null;
let activeProductSessionHost: BridgeAppDevProductSessionHost | null = null;

interface BridgeReviewRenderedHostRecord {
	readonly bottom: number;
	readonly contentState: string | null;
	readonly itemId: string;
	readonly paintedLineCount: number;
	readonly top: number;
}

describe('Bridge Review real-product continuous hydration', () => {
	afterEach(async (): Promise<void> => {
		await cleanup();
		activeHandshakeDisposer?.();
		activeHandshakeDisposer = null;
		activeProductSessionHost?.dispose();
		activeProductSessionHost = null;
		activePaneRuntime?.dispose();
		activePaneRuntime = null;
		terminateBridgePierreWorkerPoolSingletonForTest();
		activePierreWorkerFactory?.revoke();
		activePierreWorkerFactory = null;
		await advanceReviewFrames(2);
		document.body.replaceChildren();
	});

	realViteProductTest(
		'publishes the full manifest expanded and hydrates from CodeView scrolling without tree clicks',
		async () => {
			// Arrange: use the same production carrier, pane worker, route, and source as the Vite app.
			await ensureBridgeCodeViewThemeResolved();
			activeHandshakeDisposer = installBridgeReadyHandshake().dispose;
			const navigationIntent = parseBridgeAppDevFixtureOptions(
				new URLSearchParams('fixture=worktree&viewer=review'),
			).navigationIntent;
			activeProductSessionHost = installBridgeAppDevProductSessionHost({ navigationIntent });
			activePierreWorkerFactory = createBridgePierrePortableBlobWorkerFactory();

			const rendered = await render(
				<BridgeAppProtocolRouter
					codeViewWorkerFactory={activePierreWorkerFactory.workerFactory}
					codeViewWorkerPoolEnabled
					paneRuntimeFactory={() => {
						activePaneRuntime ??= createBridgePaneRuntime({
							sessionProps: {
								bootstrapTimeoutMilliseconds:
									pageConfigurationFixture.workerBootstrapDeadlineMilliseconds,
								workerFactory: createBridgeCommWorkerModuleWorker,
							},
						});
						return activePaneRuntime;
					}}
				/>,
			);

			const shell = await waitForReviewElement({
				root: rendered.container,
				selector: '[data-testid="review-viewer-shell"]',
			});
			const codePanel = await waitForReviewElement({
				root: rendered.container,
				selector: '[data-testid="bridge-code-view-panel"]',
			});
			const metadataItemCount = positiveIntegerAttribute(shell, 'data-review-metadata-item-count');
			expect(metadataItemCount).toBeGreaterThan(1);
			expect(
				positiveIntegerAttribute(codePanel, 'data-code-view-item-count'),
				'REVIEW_REAL_PRODUCT_INITIAL_MANIFEST_RED: the first mounted CodeView must already contain the complete ordered manifest.',
			).toBe(metadataItemCount);

			const initialDisclosure = await waitForReviewDisclosureRows(rendered.container);
			for (const [directoryPath, expandedState] of Object.entries(initialDisclosure)) {
				expect(
					expandedState,
					`REVIEW_REAL_PRODUCT_INITIAL_DISCLOSURE_RED: ${directoryPath} was collapsed in the first complete tree frame.`,
				).toBe('true');
			}
			const selectedItemId = codePanel.getAttribute('data-selected-item-id');
			expect(selectedItemId).not.toBeNull();
			const orderedItemIds =
				activePaneRuntime?.surfaceClient('review').renderStore.getSnapshot().reviewItemIdsByIndex ??
				[];
			expect(orderedItemIds).toHaveLength(metadataItemCount);
			expect(orderedItemIds.every((itemId): itemId is string => itemId !== null)).toBe(true);
			const finalItemId = orderedItemIds.at(-1);
			expect(finalItemId).toBeTypeOf('string');
			const codeScrollOwner = await waitForReviewCodeScrollOwner(rendered.container);
			await waitForReviewScrollable(codeScrollOwner);
			const observedHeaderItemIds = new Set<string>();
			const observedHydratedItemIds = new Set<string>();
			captureReviewHeaderItemIds({
				observedItemIds: observedHeaderItemIds,
				root: rendered.container,
			});
			const initialVisibleHeaderItemIds = new Set(observedHeaderItemIds);
			expect(initialVisibleHeaderItemIds.size).toBeGreaterThan(1);
			captureHydratedReviewItemIds({
				observedItemIds: observedHydratedItemIds,
				root: rendered.container,
			});
			const initialHydratedItemIds = new Set(observedHydratedItemIds);
			await waitForGeometryVisibleReviewHydration({
				root: rendered.container,
				scrollOwner: codeScrollOwner,
			});
			captureHydratedReviewItemIds({
				observedItemIds: observedHydratedItemIds,
				root: rendered.container,
			});
			expect(
				geometryVisibleReviewHostRecords({
					root: rendered.container,
					scrollOwner: codeScrollOwner,
				}).some(
					(hostRecord): boolean =>
						hostRecord.itemId !== selectedItemId &&
						(hostRecord.contentState === 'hydrated' || hostRecord.contentState === 'windowed') &&
						hostRecord.paintedLineCount > 0,
				),
				'REVIEW_REAL_PRODUCT_INITIAL_NON_SELECTED_VISIBLE_BODY_RED',
			).toBe(true);

			// Act: traverse only the continuous CodeView. The tree receives no click or disclosure action.
			await traverseCompleteReviewCodeView({
				codeScrollOwner,
				finalItemId: finalItemId ?? '',
				observedHeaderItemIds,
				observedHydratedItemIds,
				root: rendered.container,
			});
			const bottomVisibleHeaderItemIds = new Set(
				geometryVisibleReviewHostRecords({
					root: rendered.container,
					scrollOwner: codeScrollOwner,
				}).map((hostRecord): string => hostRecord.itemId),
			);
			await waitForHydratedReviewItemFromCandidates({
				candidateItemIds: new Set(
					[...bottomVisibleHeaderItemIds].filter(
						(itemId): boolean => !initialVisibleHeaderItemIds.has(itemId),
					),
				),
				observedItemIds: observedHydratedItemIds,
				root: rendered.container,
			});
			await waitForAdditionalHydratedReviewItem({
				initialItemIds: initialHydratedItemIds,
				observedItemIds: observedHydratedItemIds,
				root: rendered.container,
			});

			// Assert: manifest identity and disclosure did not depend on tree interaction.
			expect(codePanel.getAttribute('data-code-view-item-count')).toBe(String(metadataItemCount));
			expect(codePanel.getAttribute('data-selected-item-id')).toBe(selectedItemId);
			expect(observedHeaderItemIds.has(finalItemId ?? '')).toBe(true);
			expect(observedHydratedItemIds.has(finalItemId ?? '')).toBe(true);
			expect(observedHeaderItemIds.size).toBeGreaterThan(initialVisibleHeaderItemIds.size);
			expect(observedHydratedItemIds.size).toBeGreaterThan(initialHydratedItemIds.size);
			expect(codeScrollOwner.scrollTop).toBeGreaterThan(codeScrollOwner.clientHeight);
			expect(reviewTreeDisclosureSnapshot(rendered.container)).toEqual(initialDisclosure);
			const finalVisibleText = visibleTextIncludingOpenShadowRoots(
				codePanel,
				codeScrollOwner.getBoundingClientRect(),
			).trim();
			expect(finalVisibleText.length).toBeGreaterThan(0);
		},
	);
});

async function waitForReviewElement(props: {
	readonly root: HTMLElement;
	readonly selector: string;
	readonly attempt?: number;
}): Promise<HTMLElement> {
	const attempt = props.attempt ?? 0;
	const element = props.root.querySelector(props.selector);
	if (element instanceof HTMLElement) return element;
	if (attempt >= reviewProductFrameBudget) {
		throw new Error(`REVIEW_REAL_PRODUCT_ELEMENT_TIMEOUT: selector=${props.selector}`);
	}
	await advanceReviewFrames(1);
	return await waitForReviewElement({ ...props, attempt: attempt + 1 });
}

async function waitForReviewDisclosureRows(
	container: HTMLElement,
	attempt = 0,
): Promise<Readonly<Record<string, string>>> {
	const disclosure = reviewTreeDisclosureSnapshot(container);
	if (Object.keys(disclosure).length > 0) return disclosure;
	if (attempt >= reviewProductFrameBudget) {
		throw new Error('REVIEW_REAL_PRODUCT_DISCLOSURE_ROWS_MISSING');
	}
	await advanceReviewFrames(1);
	return await waitForReviewDisclosureRows(container, attempt + 1);
}

async function waitForReviewCodeScrollOwner(
	container: HTMLElement,
	attempt = 0,
): Promise<HTMLElement> {
	const scrollOwner = container.querySelector('.bridge-code-view-scroll-owner');
	if (scrollOwner instanceof HTMLElement) return scrollOwner;
	if (attempt >= reviewProductFrameBudget) {
		throw new Error('REVIEW_REAL_PRODUCT_CODE_SCROLL_OWNER_MISSING');
	}
	await advanceReviewFrames(1);
	return await waitForReviewCodeScrollOwner(container, attempt + 1);
}

async function waitForReviewScrollable(scrollOwner: HTMLElement, attempt = 0): Promise<void> {
	if (scrollOwner.scrollHeight > scrollOwner.clientHeight) return;
	if (attempt >= reviewProductFrameBudget) {
		throw new Error(
			`REVIEW_REAL_PRODUCT_MANIFEST_NOT_SCROLLABLE: height=${scrollOwner.scrollHeight}/${scrollOwner.clientHeight}`,
		);
	}
	await advanceReviewFrames(1);
	await waitForReviewScrollable(scrollOwner, attempt + 1);
}

async function waitForAdditionalHydratedReviewItem(props: {
	readonly initialItemIds: ReadonlySet<string>;
	readonly observedItemIds: Set<string>;
	readonly root: HTMLElement;
	readonly attempt?: number;
}): Promise<void> {
	captureHydratedReviewItemIds({ observedItemIds: props.observedItemIds, root: props.root });
	if ([...props.observedItemIds].some((itemId) => !props.initialItemIds.has(itemId))) return;
	const attempt = props.attempt ?? 0;
	if (attempt >= reviewProductFrameBudget) {
		throw new Error(
			`REVIEW_REAL_PRODUCT_PROGRESSIVE_HYDRATION_RED: initial=${JSON.stringify([...props.initialItemIds])} observed=${JSON.stringify([...props.observedItemIds])}`,
		);
	}
	await advanceReviewFrames(1);
	await waitForAdditionalHydratedReviewItem({ ...props, attempt: attempt + 1 });
}

async function waitForHydratedReviewItemFromCandidates(props: {
	readonly candidateItemIds: ReadonlySet<string>;
	readonly observedItemIds: Set<string>;
	readonly root: HTMLElement;
	readonly attempt?: number;
}): Promise<void> {
	captureHydratedReviewItemIds({ observedItemIds: props.observedItemIds, root: props.root });
	if ([...props.candidateItemIds].some((itemId): boolean => props.observedItemIds.has(itemId))) {
		return;
	}
	const attempt = props.attempt ?? 0;
	if (attempt >= reviewProductFrameBudget) {
		throw new Error(
			`REVIEW_REAL_PRODUCT_VISIBLE_HYDRATION_RED: ${JSON.stringify(
				reviewRealProductHydrationFailureTrace({
					candidateItemIds: props.candidateItemIds,
					hydratedItemIds: props.observedItemIds,
					root: props.root,
				}),
			)}`,
		);
	}
	await advanceReviewFrames(1);
	await waitForHydratedReviewItemFromCandidates({ ...props, attempt: attempt + 1 });
}

function reviewRealProductHydrationFailureTrace(props: {
	readonly candidateItemIds: ReadonlySet<string>;
	readonly hydratedItemIds: ReadonlySet<string>;
	readonly root: HTMLElement;
}): unknown {
	const reviewStore = activePaneRuntime?.surfaceClient('review').renderStore;
	const snapshot = reviewStore?.getSnapshot();
	const codeViewPanel = props.root.querySelector('[data-testid="bridge-code-view-panel"]');
	const scrollOwner = props.root.querySelector('.bridge-code-view-scroll-owner');
	const viewportRequests = Object.values(
		activePaneRuntime?.lifecycleStore.getSnapshot().requestsById ?? {},
	).filter((request) => request.command === 'viewport' && request.surface === 'review');
	return {
		candidateStates: [...props.candidateItemIds].map((itemId) => ({
			availability: snapshot?.contentAvailabilityById[itemId]?.state ?? null,
			collapsed: snapshot?.codeViewItemsById[itemId]?.collapsed ?? null,
			contentCharacterCount:
				snapshot?.codeViewItemsById[itemId]?.type === 'file'
					? snapshot.codeViewItemsById[itemId].file.contents.length
					: null,
			displayPath:
				snapshot?.reviewItemById[itemId]?.metadata.headPath ??
				snapshot?.reviewItemById[itemId]?.metadata.basePath ??
				null,
			contentState: snapshot?.codeViewItemsById[itemId]?.bridgeMetadata.contentState ?? null,
			extentLineCount:
				snapshot?.reviewItemById[itemId]?.extentFacts.reduce(
					(lineCount, extentFact): number => lineCount + extentFact.lineCount,
					0,
				) ?? null,
			fileClass: snapshot?.reviewItemById[itemId]?.metadata.fileClass ?? null,
			hunkCount:
				snapshot?.codeViewItemsById[itemId]?.type === 'diff'
					? snapshot.codeViewItemsById[itemId].fileDiff.hunks.length
					: null,
			itemId,
			itemVersion: snapshot?.codeViewItemsById[itemId]?.version ?? null,
			preparedLineCount: snapshot?.codeViewItemsById[itemId]?.bridgeMetadata.lineCount ?? null,
			preparedType: snapshot?.codeViewItemsById[itemId]?.type ?? null,
			paintReady: snapshot?.rowPaintById[itemId]?.contentCacheKey ?? null,
			viewportMember: snapshot?.viewportSlice.visibleItemIds.includes(itemId) ?? false,
		})),
		hydratedItemIds: [...props.hydratedItemIds],
		latestViewportRequest: viewportRequests.at(-1) ?? null,
		paintedHosts: bridgeReviewRenderedHostRecords(props.root),
		selectionScroll: {
			didScroll: codeViewPanel?.getAttribute('data-selection-scroll-did-scroll') ?? null,
			itemId: codeViewPanel?.getAttribute('data-selection-scroll-item-id') ?? null,
			itemTop: codeViewPanel?.getAttribute('data-selection-scroll-item-top') ?? null,
			reason: codeViewPanel?.getAttribute('data-selection-scroll-reason') ?? null,
		},
		scroll:
			scrollOwner instanceof HTMLElement
				? {
						clientHeight: scrollOwner.clientHeight,
						scrollHeight: scrollOwner.scrollHeight,
						scrollTop: scrollOwner.scrollTop,
					}
				: null,
		viewportRequestCount: viewportRequests.length,
		viewportRequestStates: viewportRequests.reduce<Record<string, number>>(
			(counts, request): Record<string, number> => {
				counts[request.state] = (counts[request.state] ?? 0) + 1;
				return counts;
			},
			{},
		),
		workerViewportItemIds: snapshot?.viewportSlice.visibleItemIds ?? [],
	};
}

async function traverseCompleteReviewCodeView(props: {
	readonly codeScrollOwner: HTMLElement;
	readonly finalItemId: string;
	readonly observedHeaderItemIds: Set<string>;
	readonly observedHydratedItemIds: Set<string>;
	readonly root: HTMLElement;
}): Promise<void> {
	await scrollReviewCodeViewTo({
		...props,
		targetScrollTop: (): number =>
			Math.max(0, (props.codeScrollOwner.scrollHeight - props.codeScrollOwner.clientHeight) * 0.5),
	});
	for (let attemptIndex = 0; attemptIndex < reviewProductFinalMilestoneBudget; attemptIndex += 1) {
		// oxlint-disable-next-line no-await-in-loop -- Hydration can expand the final item, so each current bottom must settle before re-evaluating it.
		await scrollReviewCodeViewTo({
			...props,
			targetScrollTop: (): number =>
				Math.max(0, props.codeScrollOwner.scrollHeight - props.codeScrollOwner.clientHeight),
		});
		if (
			props.observedHeaderItemIds.has(props.finalItemId) &&
			props.observedHydratedItemIds.has(props.finalItemId)
		) {
			return;
		}
	}
	throw new Error(
		`REVIEW_REAL_PRODUCT_FINAL_MILESTONE_TIMEOUT: finalItemId=${props.finalItemId} observed=${props.observedHeaderItemIds.size} scroll=${props.codeScrollOwner.scrollTop}/${props.codeScrollOwner.scrollHeight}`,
	);
}

async function scrollReviewCodeViewTo(props: {
	readonly codeScrollOwner: HTMLElement;
	readonly observedHeaderItemIds: Set<string>;
	readonly observedHydratedItemIds: Set<string>;
	readonly root: HTMLElement;
	readonly targetScrollTop: () => number;
}): Promise<void> {
	const nextScrollTop = props.targetScrollTop();
	await act(async (): Promise<void> => {
		props.codeScrollOwner.dispatchEvent(
			new WheelEvent('wheel', {
				bubbles: true,
				deltaY: Math.max(1, nextScrollTop - props.codeScrollOwner.scrollTop),
			}),
		);
		props.codeScrollOwner.scrollTop = Math.floor(nextScrollTop);
		props.codeScrollOwner.dispatchEvent(new Event('scroll', { bubbles: true }));
		await waitForReviewFrames(2);
	});
	await waitForGeometryVisibleReviewHydration({
		root: props.root,
		scrollOwner: props.codeScrollOwner,
	});
	captureReviewHeaderItemIds({
		observedItemIds: props.observedHeaderItemIds,
		root: props.root,
	});
	captureHydratedReviewItemIds({
		observedItemIds: props.observedHydratedItemIds,
		root: props.root,
	});
}

async function waitForGeometryVisibleReviewHydration(props: {
	readonly attempt?: number;
	readonly root: HTMLElement;
	readonly scrollOwner: HTMLElement;
}): Promise<void> {
	const visibleHosts = geometryVisibleReviewHostRecords(props);
	const snapshot = activePaneRuntime?.surfaceClient('review').renderStore.getSnapshot();
	const unresolvedItemIds = visibleHosts
		.filter((hostRecord): boolean => {
			const availability = snapshot?.contentAvailabilityById[hostRecord.itemId]?.state ?? null;
			if (availability === 'failed' || availability === 'unavailable') return false;
			return !(
				(hostRecord.contentState === 'hydrated' || hostRecord.contentState === 'windowed') &&
				hostRecord.paintedLineCount > 0
			);
		})
		.map((hostRecord): string => hostRecord.itemId);
	if (visibleHosts.length > 0 && unresolvedItemIds.length === 0) return;
	const attempt = props.attempt ?? 0;
	if (attempt >= reviewProductFrameBudget) {
		throw new Error(
			`REVIEW_REAL_PRODUCT_VISIBLE_BODY_RED: ${JSON.stringify(
				reviewRealProductHydrationFailureTrace({
					candidateItemIds: new Set(visibleHosts.map((hostRecord): string => hostRecord.itemId)),
					hydratedItemIds: new Set(),
					root: props.root,
				}),
			)}`,
		);
	}
	await advanceReviewFrames(1);
	await waitForGeometryVisibleReviewHydration({ ...props, attempt: attempt + 1 });
}

function captureReviewHeaderItemIds(props: {
	readonly observedItemIds: Set<string>;
	readonly root: HTMLElement;
}): void {
	for (const hostRecord of bridgeReviewRenderedHostRecords(props.root)) {
		props.observedItemIds.add(hostRecord.itemId);
	}
}

function captureHydratedReviewItemIds(props: {
	readonly observedItemIds: Set<string>;
	readonly root: HTMLElement;
}): void {
	for (const hostRecord of bridgeReviewRenderedHostRecords(props.root)) {
		if (
			(hostRecord.contentState === 'hydrated' || hostRecord.contentState === 'windowed') &&
			hostRecord.paintedLineCount > 0
		) {
			props.observedItemIds.add(hostRecord.itemId);
		}
	}
}

function bridgeReviewRenderedHostRecords(
	root: HTMLElement,
): readonly BridgeReviewRenderedHostRecord[] {
	return queryAllInOpenShadowRoots(root, 'diffs-container').flatMap(
		(host): readonly BridgeReviewRenderedHostRecord[] => {
			const itemMarker = bridgeReviewHostElement(host, '[data-bridge-code-view-item-id]');
			const itemId = itemMarker?.getAttribute('data-bridge-code-view-item-id') ?? null;
			if (itemId === null) return [];
			const bounds = host.getBoundingClientRect();
			const contentStateElement = bridgeReviewHostElement(
				host,
				'[data-bridge-code-view-content-state]',
			);
			return [
				{
					bottom: bounds.bottom,
					contentState:
						contentStateElement?.getAttribute('data-bridge-code-view-content-state') ?? null,
					itemId,
					paintedLineCount: host.shadowRoot?.querySelectorAll('[data-line-index]').length ?? 0,
					top: bounds.top,
				},
			];
		},
	);
}

function geometryVisibleReviewHostRecords(props: {
	readonly root: HTMLElement;
	readonly scrollOwner: HTMLElement;
}): readonly BridgeReviewRenderedHostRecord[] {
	const viewportBounds = props.scrollOwner.getBoundingClientRect();
	return bridgeReviewRenderedHostRecords(props.root).filter(
		(hostRecord): boolean =>
			hostRecord.bottom > viewportBounds.top && hostRecord.top < viewportBounds.bottom,
	);
}

function bridgeReviewHostElement(host: Element, selector: string): Element | null {
	return host.querySelector(selector) ?? host.shadowRoot?.querySelector(selector) ?? null;
}

function reviewTreeDisclosureSnapshot(container: HTMLElement): Readonly<Record<string, string>> {
	const treeHost = container.querySelector(
		'[data-testid="bridge-review-trees-panel"] file-tree-container',
	);
	if (!(treeHost instanceof HTMLElement) || treeHost.shadowRoot === null) return {};
	return Object.fromEntries(
		[...treeHost.shadowRoot.querySelectorAll('[data-item-path][aria-expanded]')].map((row) => [
			row.getAttribute('data-item-path') ?? '',
			row.getAttribute('aria-expanded') ?? '',
		]),
	);
}

function queryAllInOpenShadowRoots(
	root: Element | ShadowRoot,
	selector: string,
): readonly Element[] {
	const matches = [...root.querySelectorAll(selector)];
	for (const descendant of root.querySelectorAll('*')) {
		if (descendant.shadowRoot === null) continue;
		matches.push(...queryAllInOpenShadowRoots(descendant.shadowRoot, selector));
	}
	return matches;
}

function positiveIntegerAttribute(element: HTMLElement, attributeName: string): number {
	const rawValue = element.getAttribute(attributeName);
	const value = rawValue === null ? Number.NaN : Number.parseInt(rawValue, 10);
	if (!Number.isInteger(value) || value <= 0) {
		throw new Error(`REVIEW_REAL_PRODUCT_INVALID_COUNT: ${attributeName}=${rawValue ?? 'missing'}`);
	}
	return value;
}

async function waitForReviewFrames(frameCount: number): Promise<void> {
	for (let frameIndex = 0; frameIndex < frameCount; frameIndex += 1) {
		// oxlint-disable-next-line no-await-in-loop -- Each frame is an observable product commit boundary.
		await new Promise<void>((resolve): void => {
			requestAnimationFrame((): void => resolve());
		});
		// oxlint-disable-next-line no-await-in-loop -- Flush the microtask scheduled by this frame before observing the next.
		await Promise.resolve();
	}
}

async function advanceReviewFrames(frameCount: number): Promise<void> {
	for (let frameIndex = 0; frameIndex < frameCount; frameIndex += 1) {
		// oxlint-disable-next-line no-await-in-loop -- Each act-wrapped frame settles one product commit boundary.
		await act(async (): Promise<void> => {
			await waitForReviewFrames(1);
		});
	}
}
