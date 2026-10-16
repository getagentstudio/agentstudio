import { act, type ReactElement } from 'react';
import { afterEach, describe, expect, test } from 'vitest';
import { cleanup, render } from 'vitest-browser-react';

// oxlint-disable-next-line import/no-unassigned-import -- Browser Mode must load production app CSS.
import '../../app/bridge-app.css';
import { settleRenderedReviewFrame } from '../../app/bridge-app-review-render-snapshot-controller.browser-harness.test-support.js';
import { BridgeReviewViewerShellBoundary } from '../../app/bridge-app-review-viewer-shell-boundary.js';
import type { BridgeReviewComparisonPaneState } from '../../app/bridge-review-comparison-pane-state.js';
import { createBridgeMainRenderFulfillmentCoordinator } from '../../core/comm-worker/bridge-main-render-fulfillment-coordinator.js';
import { createBridgeReviewItemRegistry } from '../../foundation/review-package/bridge-review-item-registry.js';
import { makeBridgeReviewPackage } from '../../foundation/review-package/bridge-review-package-test-support.js';
import { RecordingAnnotationBrowserSurface } from '../../worktree-annotations/worktree-annotation-browser-test-support.js';
import { WorktreeAnnotationSurfaceProvider } from '../../worktree-annotations/worktree-annotation-surface-provider.js';
import { buildBridgeReviewProjection } from '../navigation/review-projection.js';
import { ReviewViewerShell } from '../shell/review-viewer-shell.js';

const comparisonGeometryRenderFulfillmentCoordinator = createBridgeMainRenderFulfillmentCoordinator(
	{
		cancelAnimationFrame: (_frameHandle): void => {},
		nowMilliseconds: (): number => 0,
		requestAnimationFrame: (_callback): number => {
			throw new Error('Comparison geometry fixture must not schedule paint validation.');
		},
		sendDisposition: (_receipt): void => {},
	},
);

describe('Bridge Review comparison shell Browser Mode', () => {
	afterEach(async (): Promise<void> => {
		await cleanup();
	});

	test('preserves the ordinary fallback canvas layout without a comparison banner', async () => {
		const rendered = await render(
			<BridgeReviewViewerShellBoundary
				comparisonPaneState={{ kind: 'settled' }}
				isActive
				onRetryComparison={(): void => {}}
				presentationState={{ status: 'noTarget' }}
				viewerContextSwitcher={<div>Files and Review</div>}
				viewerHeaderControls={<div>Review controls</div>}
			/>,
		);

		await expect.element(rendered.getByTestId('bridge-review-empty-shell')).toBeVisible();
		const fallbackCanvas = rendered.getByTestId('bridge-review-fallback-canvas').element();
		const contextPanelViewport = fallbackCanvas.closest(
			'[data-testid="bridge-review-context-panel-viewport"]',
		);
		expect(contextPanelViewport).not.toBeNull();
		expect(contextPanelViewport?.parentElement?.className).toContain(
			'grid-rows-[auto_minmax(0,1fr)]',
		);
	});

	test('renders an installed empty-ready Review while initial comparison still reports loading', async () => {
		const rendered = await render(
			<BridgeReviewViewerShellBoundary
				comparisonPaneState={{ kind: 'loadingInitial', requestedTargetLabel: 'clean worktree' }}
				isActive
				onRetryComparison={(): void => {}}
				presentationState={{ status: 'readyEmpty' }}
				viewerContextSwitcher={<div>Files and Review</div>}
				viewerHeaderControls={<div>Review controls</div>}
			/>,
		);
		await act(async (): Promise<void> => {
			await settleRenderedReviewFrame();
		});
		await expect.element(rendered.getByTestId('bridge-review-empty-canvas')).toBeVisible();
		await expect.element(rendered.getByText('Nothing to review')).toBeVisible();
		expect(rendered.getByText('Waiting for review metadata').query()).toBeNull();
		expect(rendered.getByTestId('bridge-review-metadata-loading-shell').query()).toBeNull();
		expect(
			rendered
				.getByTestId('bridge-review-sidebar')
				.element()
				.querySelectorAll('[data-slot="skeleton"]'),
		).toHaveLength(0);
	});

	test('keeps initial comparison loading inside the content pane while navigation remains available', async () => {
		const rendered = await render(
			<div className="h-[600px] w-[720px]">
				<BridgeReviewViewerShellBoundary
					comparisonPaneState={{
						kind: 'loadingInitial',
						requestedTargetLabel: 'feature/new-target',
					}}
					isActive
					onRetryComparison={(): void => {}}
					presentationState={{ status: 'metadataLoading' }}
					viewerContextSwitcher={<button type="button">Files and Review</button>}
					viewerHeaderControls={<div>Review controls</div>}
				/>
			</div>,
		);

		expect(
			document
				.querySelector('[data-bridge-region="review-content"]')
				?.getAttribute('data-presentation-state'),
		).toBe('loading');
		expect(
			document
				.querySelector('[data-bridge-region="review-tree"]')
				?.getAttribute('data-presentation-state'),
		).toBe('loading');
		expect(rendered.getByTestId('bridge-review-comparison-loading-spinner').query()).toBeNull();
		expect(rendered.getByTestId('bridge-review-comparison-status-region').query()).toBeNull();
		expect(rendered.getByRole('progressbar').query()).toBeNull();
		await expect
			.element(rendered.getByTestId('bridge-review-metadata-loading-shell'))
			.toBeVisible();
		const contextSwitcher = rendered.getByRole('button', { name: 'Files and Review' }).element();
		expect(
			contextSwitcher.closest('[data-testid="bridge-review-rail-toolbar-leading"]'),
		).not.toBeNull();
		expect(
			contextSwitcher.closest('[data-testid="bridge-viewer-content-topbar-controls"]'),
		).toBeNull();
		const contentHeader = rendered.getByTestId('bridge-viewer-content-topbar').element();
		const comparisonViewport = rendered
			.getByTestId('bridge-review-context-panel-viewport')
			.element();
		expect(comparisonViewport.getBoundingClientRect().top).toBe(
			contentHeader.getBoundingClientRect().bottom,
		);
		const fallbackContentFrame = rendered.getByTestId('bridge-review-content-panel').element();
		expect(fallbackContentFrame.getBoundingClientRect().height).toBeGreaterThan(400);
		expect(
			Math.abs(
				comparisonViewport.getBoundingClientRect().bottom -
					fallbackContentFrame.getBoundingClientRect().bottom,
			),
		).toBeLessThanOrEqual(1);
	});

	test('keeps the loaded Review viewport full height across comparison status transitions', async () => {
		const reviewPackage = {
			...makeBridgeReviewPackage(),
			itemsById: {},
			orderedItemIds: [],
		};
		const presentationRegistry = createBridgeReviewItemRegistry({ reviewPackage });
		const projection = buildBridgeReviewProjection({
			reviewPackage,
			request: { facets: [], mode: { kind: 'normalReview' } },
		});
		const annotationSurface = new RecordingAnnotationBrowserSurface('review');
		const reviewShell = (comparisonPaneState: BridgeReviewComparisonPaneState): ReactElement => (
			<WorktreeAnnotationSurfaceProvider surfaceClient={annotationSurface.client}>
				<div className="h-[600px] w-[720px]">
					<ReviewViewerShell
						comparisonPaneState={comparisonPaneState}
						facetMenuOpen={false}
						isActive
						onFacetMenuOpenChange={(): void => {}}
						onRetryComparison={(): void => {}}
						onSelectItem={(): void => {}}
						panelChromeSlice={{}}
						presentationPositionKey="comparison-geometry"
						presentationRegistry={presentationRegistry}
						projection={projection}
						renderFulfillmentCoordinator={comparisonGeometryRenderFulfillmentCoordinator}
						reviewPackage={reviewPackage}
						selectedItemId={null}
					/>
				</div>
			</WorktreeAnnotationSurfaceProvider>
		);
		const rendered = await render(reviewShell({ kind: 'settled' }));
		await expect.element(rendered.getByTestId('review-viewer-shell')).toBeVisible();
		const settledGeometry = loadedReviewViewportGeometry(rendered);
		expect(settledGeometry.contentFrameHeight).toBeGreaterThan(400);
		expectLoadedReviewViewportFillsContentFrame(settledGeometry);

		await rendered.rerender(
			reviewShell({
				displayedTargetLabel: 'origin/main',
				kind: 'loadingPrevious',
				requestedTargetLabel: 'feature/new-target',
			}),
		);
		expect(
			document
				.querySelector('[data-bridge-region="review-content"]')
				?.getAttribute('data-presentation-state'),
		).toBe('updating');
		expect(document.querySelector('.animate-spin')).toBeNull();
		const loadingGeometry = loadedReviewViewportGeometry(rendered);
		expectLoadedReviewViewportFillsContentFrame(loadingGeometry);
		expect(Math.abs(loadingGeometry.viewportTop - settledGeometry.viewportTop)).toBeLessThanOrEqual(
			1,
		);

		await rendered.rerender(
			reviewShell({
				displayedTargetLabel: 'origin/main',
				kind: 'failedPrevious',
				failureKind: 'targetNotFound',
				requestedTargetLabel: 'feature/new-target',
				retryTarget: null,
			}),
		);
		await expect
			.element(rendered.getByTestId('bridge-pane-failure-summary').getByRole('alert'))
			.toBeVisible();
		const failedGeometry = loadedReviewViewportGeometry(rendered);
		expectLoadedReviewViewportFillsContentFrame(failedGeometry);

		await rendered.rerender(reviewShell({ kind: 'settled' }));
		const exitingStatusRegion = rendered
			.getByTestId('bridge-review-comparison-status-region')
			.query();
		if (exitingStatusRegion !== null) {
			await act(async (): Promise<void> => {
				exitingStatusRegion.dispatchEvent(new AnimationEvent('animationend', { bubbles: true }));
			});
		}
		const finalSettledGeometry = loadedReviewViewportGeometry(rendered);
		expectLoadedReviewViewportFillsContentFrame(finalSettledGeometry);
	});
});

function expectLoadedReviewViewportFillsContentFrame(geometry: {
	readonly contentFrameBottom: number;
	readonly viewportBottom: number;
}): void {
	expect(Math.abs(geometry.viewportBottom - geometry.contentFrameBottom)).toBeLessThanOrEqual(1);
}

function loadedReviewViewportGeometry(rendered: Awaited<ReturnType<typeof render>>): {
	readonly contentFrameBottom: number;
	readonly contentFrameHeight: number;
	readonly viewportBottom: number;
	readonly viewportTop: number;
} {
	const contentFrameBounds = rendered
		.getByTestId('bridge-review-code-scroll')
		.element()
		.getBoundingClientRect();
	const viewportBounds = rendered
		.getByTestId('bridge-review-context-panel-viewport')
		.element()
		.getBoundingClientRect();
	return {
		contentFrameBottom: contentFrameBounds.bottom,
		contentFrameHeight: contentFrameBounds.height,
		viewportBottom: viewportBounds.bottom,
		viewportTop: viewportBounds.top,
	};
}
