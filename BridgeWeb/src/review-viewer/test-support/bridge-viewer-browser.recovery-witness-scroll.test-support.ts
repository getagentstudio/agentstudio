import { act } from 'react';

import type { BridgeMainRenderSnapshotStore } from '../../core/comm-worker/bridge-main-render-snapshot-store.js';
import {
	scrollBridgeReviewRecoveryWitnessTo,
	waitForBridgeReviewRecoveryDomState,
} from './bridge-review-recovery-dom-state.test-support.js';

export interface BridgeReviewRecoveryScrollScan {
	readonly blankPaintSampleCount: number;
	readonly convergenceSampleCount: number;
	readonly finalScrollHeight: number;
	readonly markerConvergenceSamples: readonly BridgeReviewRecoveryMarkerConvergenceSample[];
	readonly maximumAvailableScrollTop: number;
	readonly maximumScrollTop: number;
	readonly observedMarkers: ReadonlySet<string>;
	readonly sampleCount: number;
	readonly scrollTopSamples: readonly number[];
}

export interface BridgeReviewRecoveryMarkerConvergenceSample {
	readonly firstVisibleItemId: string | null;
	readonly finalVisibleItemId: string | null;
	readonly marker: string;
	readonly scrollHeight: number;
	readonly scrollTop: number;
	readonly targetItemId: string | null;
}

export async function advanceBridgeReviewRecoveryWitnessFrames(frameCount: number): Promise<void> {
	for (let frameIndex = 0; frameIndex < frameCount; frameIndex += 1) {
		// oxlint-disable-next-line no-await-in-loop -- Each frame is an observable render boundary.
		await act(async (): Promise<void> => {
			await new Promise<void>((resolve): void => {
				setTimeout(resolve, 0);
			});
			await new Promise<void>((resolve): void => {
				requestAnimationFrame((): void => resolve());
			});
			await Promise.resolve();
		});
	}
}

export function waitForHydratedReviewCodeViewItem(props: {
	readonly itemId: string;
	readonly renderStore: BridgeMainRenderSnapshotStore;
}): Promise<void> {
	return new Promise((resolve): void => {
		let unsubscribe: (() => void) | null = null;
		const resolveWhenHydrated = (): void => {
			const item = props.renderStore.getReviewCodeViewItemSnapshot(props.itemId);
			if (item?.bridgeMetadata.contentState !== 'hydrated') return;
			unsubscribe?.();
			resolve();
		};
		unsubscribe = props.renderStore.subscribeReviewCodeViewItem(props.itemId, resolveWhenHydrated);
		resolveWhenHydrated();
	});
}

export async function scanBridgeReviewRecoveryWitnessDocument(props: {
	readonly markerItemIds?: readonly string[];
	readonly markers: readonly string[];
	readonly orderedItemIds?: readonly string[];
	readonly sampleCount: number;
	readonly scrollOwner: HTMLElement;
	readonly publishDemandedContent?: () => Promise<readonly string[]>;
	readonly scrollStrategy?: 'proportional' | 'viewportStep';
	readonly visibleItemIds?: () => readonly string[];
	readonly visibleCodeText: (scrollOwner: HTMLElement) => string;
}): Promise<BridgeReviewRecoveryScrollScan> {
	const observedMarkers = new Set<string>();
	let blankPaintSampleCount = 0;
	let observedMaximumAvailableScrollTop = 0;
	let maximumScrollTop = 0;
	const markerConvergenceSamples: BridgeReviewRecoveryMarkerConvergenceSample[] = [];
	const scrollTopSamples: number[] = [];
	const captureScrollSample = async (nextScrollTop: number): Promise<void> => {
		await scrollBridgeReviewRecoveryWitnessTo({
			scrollOwner: props.scrollOwner,
			scrollTop: nextScrollTop,
		});
		if (props.publishDemandedContent !== undefined) {
			await props.publishDemandedContent();
		}
		await waitForBridgeReviewRecoveryDomState({
			readState: (): boolean => visibleReviewHeadersAreHydrated(props.scrollOwner),
			isExpected: (hydrated): boolean => hydrated,
		});
		const maximumAvailableScrollTop = Math.max(
			0,
			props.scrollOwner.scrollHeight - props.scrollOwner.clientHeight,
		);
		observedMaximumAvailableScrollTop = Math.max(
			observedMaximumAvailableScrollTop,
			maximumAvailableScrollTop,
		);
		maximumScrollTop = Math.max(maximumScrollTop, props.scrollOwner.scrollTop);
		scrollTopSamples.push(props.scrollOwner.scrollTop);
		// Header adoption announces the hydrated render window. Sample the body separately so a
		// blank body still fails the witness rather than becoming the wait's success predicate.
		const renderedText = props.visibleCodeText(props.scrollOwner);
		if (renderedText.trim().length === 0) blankPaintSampleCount += 1;
		for (const marker of props.markers) {
			if (renderedText.includes(marker)) observedMarkers.add(marker);
		}
	};
	for (let sampleIndex = 0; sampleIndex < props.sampleCount; sampleIndex += 1) {
		const maximumAvailableScrollTop = Math.max(
			0,
			props.scrollOwner.scrollHeight - props.scrollOwner.clientHeight,
		);
		observedMaximumAvailableScrollTop = Math.max(
			observedMaximumAvailableScrollTop,
			maximumAvailableScrollTop,
		);
		const progress = props.sampleCount === 1 ? 1 : sampleIndex / (props.sampleCount - 1);
		const nextScrollTop =
			props.scrollStrategy === 'viewportStep'
				? sampleIndex === 0
					? 0
					: Math.min(
							maximumAvailableScrollTop,
							props.scrollOwner.scrollTop + Math.max(1, props.scrollOwner.clientHeight * 0.75),
						)
				: Math.round(maximumAvailableScrollTop * progress);
		// oxlint-disable-next-line no-await-in-loop -- Each scroll sample owns its React paint and demand turn.
		await captureScrollSample(nextScrollTop);
	}

	const fixedScanSampleCount = scrollTopSamples.length;
	const maximumConvergenceSamplesPerMarker = Math.max(8, Math.min(64, props.sampleCount));
	for (const [markerIndex, marker] of props.markers.entries()) {
		const isFinalMarker = markerIndex === props.markers.length - 1;
		if (observedMarkers.has(marker) && !isFinalMarker) {
			continue;
		}
		const markerProgress =
			props.markers.length === 1 ? 1 : markerIndex / (props.markers.length - 1);
		for (
			let convergenceSampleIndex = 0;
			convergenceSampleIndex < maximumConvergenceSamplesPerMarker;
			convergenceSampleIndex += 1
		) {
			const targetScrollTop = isFinalMarker
				? Math.max(0, props.scrollOwner.scrollHeight - props.scrollOwner.clientHeight)
				: markerConvergenceScrollTop({
						markerIndex,
						markerProgress,
						props,
					});
			// oxlint-disable-next-line no-await-in-loop -- Hydration can change document height after every target paint.
			await captureScrollSample(targetScrollTop);
			const visibleItemIds = props.visibleItemIds?.() ?? [];
			markerConvergenceSamples.push({
				firstVisibleItemId: visibleItemIds[0] ?? null,
				finalVisibleItemId: visibleItemIds.at(-1) ?? null,
				marker,
				scrollHeight: props.scrollOwner.scrollHeight,
				scrollTop: props.scrollOwner.scrollTop,
				targetItemId: props.markerItemIds?.[markerIndex] ?? null,
			});
			const currentScrollHeight = props.scrollOwner.scrollHeight;
			const settledTargetScrollTop = isFinalMarker
				? Math.max(0, currentScrollHeight - props.scrollOwner.clientHeight)
				: markerConvergenceScrollTop({
						markerIndex,
						markerProgress,
						props,
					});
			const targetIsStable = Math.abs(props.scrollOwner.scrollTop - settledTargetScrollTop) <= 1;
			if (observedMarkers.has(marker) && targetIsStable) {
				break;
			}
			const targetItemId = props.markerItemIds?.[markerIndex];
			if (
				!observedMarkers.has(marker) &&
				targetItemId !== undefined &&
				visibleItemIds.includes(targetItemId)
			) {
				// Rendered IDs include overscan. Hydration can grow the document after native
				// scrollend, so a mounted target does not mean its marker is in the viewport.
				// Observe either the marker or a new geometric destination, then drive that
				// destination in its own act turn instead of waiting at a stale scrollTop.
				// oxlint-disable-next-line no-await-in-loop -- Each marker awaits paint or an observed scroll destination.
				const markerState = await waitForBridgeReviewRecoveryDomState({
					readState: (): { readonly text: string; readonly nextScrollTop: number } => ({
						text: props.visibleCodeText(props.scrollOwner),
						nextScrollTop:
							bridgeReviewRecoveryMarkerLineScrollTop({
								itemId: targetItemId,
								marker,
								scrollOwner: props.scrollOwner,
							}) ??
							(isFinalMarker
								? Math.max(0, props.scrollOwner.scrollHeight - props.scrollOwner.clientHeight)
								: markerConvergenceScrollTop({ markerIndex, markerProgress, props })),
					}),
					isExpected: (state): boolean =>
						state.text.includes(marker) ||
						Math.abs(props.scrollOwner.scrollTop - state.nextScrollTop) > 1,
				});
				if (markerState.text.includes(marker)) {
					observedMarkers.add(marker);
					break;
				}
				// oxlint-disable-next-line no-await-in-loop -- Layout observation supplies the next actual scroll step.
				await captureScrollSample(markerState.nextScrollTop);
			}
		}
	}
	return {
		blankPaintSampleCount,
		convergenceSampleCount: scrollTopSamples.length - fixedScanSampleCount,
		finalScrollHeight: props.scrollOwner.scrollHeight,
		markerConvergenceSamples,
		maximumAvailableScrollTop: observedMaximumAvailableScrollTop,
		maximumScrollTop,
		observedMarkers,
		sampleCount: scrollTopSamples.length,
		scrollTopSamples,
	};
}

function visibleReviewHeadersAreHydrated(scrollOwner: HTMLElement): boolean {
	const viewportBounds = scrollOwner.getBoundingClientRect();
	const visibleHosts = queryElementsIncludingOpenShadowRoots(scrollOwner, 'diffs-container').filter(
		(host): boolean => {
			const bounds = host.getBoundingClientRect();
			return bounds.bottom > viewportBounds.top && bounds.top < viewportBounds.bottom;
		},
	);
	return (
		visibleHosts.length > 0 &&
		visibleHosts.every((host): boolean =>
			queryElementsIncludingOpenShadowRoots(host, '[data-bridge-code-view-content-state]').some(
				(header): boolean =>
					header.getAttribute('data-bridge-code-view-content-state') === 'hydrated',
			),
		)
	);
}

function bridgeReviewRecoveryMarkerLineScrollTop(props: {
	readonly itemId: string;
	readonly marker: string;
	readonly scrollOwner: HTMLElement;
}): number | null {
	const codePanel = props.scrollOwner.closest('[data-testid="bridge-code-view-panel"]');
	if (codePanel === null) return null;
	const targetHost = queryElementsIncludingOpenShadowRoots(codePanel, 'diffs-container').find(
		(host): boolean =>
			host
				.querySelector('[data-bridge-code-view-item-id]')
				?.getAttribute('data-bridge-code-view-item-id') === props.itemId,
	);
	const markerLine = [
		...(targetHost?.shadowRoot?.querySelectorAll('[data-line-index]') ?? []),
	].find((line): boolean => (line.textContent ?? '').includes(props.marker));
	if (markerLine === undefined) return null;
	const viewportBounds = props.scrollOwner.getBoundingClientRect();
	const markerBounds = markerLine.getBoundingClientRect();
	const centeredScrollTop =
		props.scrollOwner.scrollTop +
		markerBounds.top -
		viewportBounds.top -
		(props.scrollOwner.clientHeight - markerBounds.height) / 2;
	return Math.round(
		Math.max(
			0,
			Math.min(props.scrollOwner.scrollHeight - props.scrollOwner.clientHeight, centeredScrollTop),
		),
	);
}

function queryElementsIncludingOpenShadowRoots(
	root: Element | ShadowRoot,
	selector: string,
): Element[] {
	const matches = [...root.querySelectorAll(selector)];
	for (const descendant of root.querySelectorAll('*')) {
		if (descendant.shadowRoot !== null) {
			matches.push(...queryElementsIncludingOpenShadowRoots(descendant.shadowRoot, selector));
		}
	}
	return matches;
}

function markerConvergenceScrollTop(props: {
	readonly markerIndex: number;
	readonly markerProgress: number;
	readonly props: Parameters<typeof scanBridgeReviewRecoveryWitnessDocument>[0];
}): number {
	const maximumScrollTop = Math.max(
		0,
		props.props.scrollOwner.scrollHeight - props.props.scrollOwner.clientHeight,
	);
	const orderedItemIds = props.props.orderedItemIds;
	const markerItemId = props.props.markerItemIds?.[props.markerIndex];
	const visibleItemIds = props.props.visibleItemIds?.() ?? [];
	if (orderedItemIds === undefined || markerItemId === undefined || visibleItemIds.length === 0) {
		return Math.round(maximumScrollTop * props.markerProgress);
	}
	const targetItemIndex = orderedItemIds.indexOf(markerItemId);
	const visibleItemIndexes = visibleItemIds
		.map((itemId): number => orderedItemIds.indexOf(itemId))
		.filter((itemIndex): boolean => itemIndex >= 0)
		.toSorted((left, right): number => left - right);
	if (targetItemIndex < 0 || visibleItemIndexes.length === 0) {
		return Math.round(maximumScrollTop * props.markerProgress);
	}
	const firstVisibleItemIndex = visibleItemIndexes[0] ?? targetItemIndex;
	const finalVisibleItemIndex = visibleItemIndexes.at(-1) ?? targetItemIndex;
	if (targetItemIndex >= firstVisibleItemIndex && targetItemIndex <= finalVisibleItemIndex) {
		if (targetItemIndex === finalVisibleItemIndex && targetItemIndex !== firstVisibleItemIndex) {
			return Math.round(
				Math.min(
					maximumScrollTop,
					props.props.scrollOwner.scrollTop + props.props.scrollOwner.clientHeight * 0.5,
				),
			);
		}
		return props.props.scrollOwner.scrollTop;
	}
	const middleVisibleItemIndex =
		visibleItemIndexes[Math.floor(visibleItemIndexes.length / 2)] ?? targetItemIndex;
	const averageItemHeight = props.props.scrollOwner.scrollHeight / orderedItemIds.length;
	const estimatedCorrection = (targetItemIndex - middleVisibleItemIndex) * averageItemHeight * 0.75;
	return Math.round(
		Math.max(
			0,
			Math.min(maximumScrollTop, props.props.scrollOwner.scrollTop + estimatedCorrection),
		),
	);
}
