import { createRef, type ReactElement, type ReactNode } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { describe, expect, test } from 'vitest';

import {
	BridgeReviewRefreshHeaderGroup,
	bridgeReviewRegionRefreshHeaderPresentation,
} from '../../app/bridge-review-refresh-header-chrome.js';
import { BridgeViewerContentHeader } from '../../app/bridge-viewer-content-header.js';
import { BridgeViewerResizableRailLayout } from '../../app/bridge-viewer-resizable-rail-layout.js';
import { createBridgeMainRenderFulfillmentCoordinator } from '../../core/comm-worker/bridge-main-render-fulfillment-coordinator.js';
import {
	createBridgeReviewItemRegistry,
	readBridgeReviewItemRegistryDiagnostics,
	resetBridgeReviewItemRegistryDiagnosticsForTests,
	type BridgeReviewItemRegistry,
} from '../../foundation/review-package/bridge-review-item-registry.js';
import {
	makeBridgeReviewItem,
	makeBridgeReviewPackage,
} from '../../foundation/review-package/bridge-review-package-test-support.js';
import type { BridgeReviewPackage } from '../../foundation/review-package/bridge-review-package.js';
import { BridgeReviewFacetMenu } from '../chrome/bridge-review-facet-menu.js';
import { BridgeReviewProjectionMenu } from '../chrome/bridge-review-projection-menu.js';
import { materializeBridgeCodeViewLoadingItem } from '../code-view/bridge-code-view-materialization.js';
import type { ReviewContentDemandTelemetry } from '../content/review-content-demand-types.js';
import { buildBridgeReviewProjection } from '../navigation/review-projection.js';
import {
	renderReviewViewerShellPresentation,
	type ReviewViewerShellProps,
} from './review-viewer-shell.js';

const shellTestRenderFulfillmentCoordinator = createBridgeMainRenderFulfillmentCoordinator({
	cancelAnimationFrame: (_frameHandle): void => {},
	nowMilliseconds: (): number => 0,
	requestAnimationFrame: (_callback): number => {
		throw new Error('Review shell integration fixtures must not schedule paint validation.');
	},
	sendDisposition: (_receipt): void => {},
});

describe('review viewer shell', () => {
	test('does not rebuild package registry facts when only selection changes', () => {
		const reviewPackage = appendedReviewPackageForShell();
		const presentationRegistry = createBridgeReviewItemRegistry({ reviewPackage });

		renderReviewViewerShellForTest({
			presentationRegistry,
			reviewPackage,
			projection: projectionForPackage(reviewPackage),
			selectedItemId: 'item-source',
			onSelectItem: () => undefined,
			selectedContentText: null,
		});
		resetBridgeReviewItemRegistryDiagnosticsForTests();

		renderReviewViewerShellForTest({
			presentationRegistry,
			reviewPackage,
			projection: projectionForPackage(reviewPackage),
			selectedItemId: 'item-added',
			onSelectItem: () => undefined,
			selectedContentText: null,
		});

		expect(readBridgeReviewItemRegistryDiagnostics()).toMatchObject({
			cacheHitCount: 0,
			fullBuildCount: 0,
		});
	});

	test('consumes one supplied registry across repeated renders of an appended package batch', () => {
		const reviewPackage = makeBridgeReviewPackage();
		const appendedReviewPackage = appendedReviewPackageForShell(reviewPackage);
		const presentationRegistry = createBridgeReviewItemRegistry({
			reviewPackage: appendedReviewPackage,
		});

		resetBridgeReviewItemRegistryDiagnosticsForTests();
		renderReviewViewerShellForTest({
			presentationRegistry,
			reviewPackage: appendedReviewPackage,
			projection: projectionForPackage(appendedReviewPackage),
			selectedItemId: 'item-source',
			onSelectItem: () => undefined,
			selectedContentText: null,
		});
		renderReviewViewerShellForTest({
			presentationRegistry,
			reviewPackage: appendedReviewPackage,
			projection: projectionForPackage(appendedReviewPackage),
			selectedItemId: 'item-added',
			onSelectItem: () => undefined,
			selectedContentText: null,
		});
		renderReviewViewerShellForTest({
			presentationRegistry,
			reviewPackage: appendedReviewPackage,
			projection: projectionForPackage(appendedReviewPackage),
			selectedItemId: 'item-source',
			onSelectItem: () => undefined,
			selectedContentText: null,
		});

		expect(readBridgeReviewItemRegistryDiagnostics()).toMatchObject({
			cacheHitCount: 0,
			fullBuildCount: 0,
		});
	});

	test('renders compact rail controls and visible item list without footer stats', () => {
		const basePackage = makeBridgeReviewPackage();
		const reviewPackage = {
			...basePackage,
			query: {
				...basePackage.query,
				pathScope: ['Sources/App/**'],
			},
			baseEndpoint: {
				...basePackage.baseEndpoint,
				kind: 'promptCheckpoint' as const,
				label: 'Prompt checkpoint',
			},
			filterState: {
				...basePackage.filterState,
				includedFileClasses: ['source' as const],
				changeKinds: ['modified' as const],
			},
		};
		const element = renderReviewViewerShellForTest({
			reviewPackage,
			projection: projectionForPackage(reviewPackage),
			selectedItemId: 'item-source',
			onSelectItem: () => undefined,
			selectedContentText: 'selected file text',
		});

		expect(element.type).toBe('main');
		expect(element).toMatchObject({
			props: {
				'data-testid': 'review-viewer-shell',
			},
		});
		const shell = requireTestElement(element);
		const text = collectText(element);

		expect(findElementByTestId(shell, 'bridge-review-top-header')).toBeNull();
		expect(findElementByTestId(shell, 'bridge-review-rail-stats')).toBeNull();
		expect(text).toContain('Sources/App/View.swift');
	});

	test('renders tree refinement controls while projection controls remain parent-owned', () => {
		const reviewPackage = makeBridgeReviewPackage();
		const element = renderReviewViewerShellForTest({
			reviewPackage,
			projection: projectionForPackage(reviewPackage),
			selectedItemId: 'item-source',
			onSelectItem: () => undefined,
			selectedContentText: null,
		});

		const text = collectText(element);
		expect(findElementByComponent(element, BridgeReviewProjectionMenu)).toBeNull();
		expect(findElementByComponent(element, BridgeReviewFacetMenu)).not.toBeNull();
		expect(text).toContain('Search files');
		expect(findElementByTestId(element, 'bridge-review-top-header')).toBeNull();
	});

	test('renders contribution subject without generic endpoint comparison vocabulary', () => {
		const basePackage = makeBridgeReviewPackage();
		const reviewPackage = {
			...basePackage,
			comparisonOrigin: {
				baseOID: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
				baseRole: 'commonCommit' as const,
				comparedRole: 'capturedWorkingTree' as const,
				kind: 'contribution' as const,
				resolvedTargetOID: 'mmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmm',
				reviewedHeadOID: 'hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh',
				reviewedSubjectBranchName: null,
				symbolicTarget: {
					basis: 'commonCommit' as const,
					branchName: 'master',
					kind: 'localDefaultBranch' as const,
				},
			},
			query: {
				...basePackage.query,
				baseEndpointId: 'baseline-local-default',
				headEndpointId: 'working-tree',
			},
			baseEndpoint: {
				...basePackage.baseEndpoint,
				endpointId: 'baseline-local-default',
				kind: 'gitRef' as const,
				label: 'main',
				providerIdentity: 'main',
			},
			headEndpoint: {
				...basePackage.headEndpoint,
				endpointId: 'working-tree',
				kind: 'workingTree' as const,
				label: 'Working tree',
				providerIdentity: 'working-tree:worktree-1',
			},
			reviewedSubjectLabel: 'feature/annotations',
		};
		const element = renderReviewViewerShellForTest({
			reviewPackage,
			projection: projectionForPackage(reviewPackage),
			selectedItemId: 'item-source',
			onSelectItem: () => undefined,
			selectedContentText: null,
		});

		const contentHeader = findElementByComponent(element, BridgeViewerContentHeader);
		expect(contentHeader?.props.title).toBe('feature/annotations changes / Sources/App/View.swift');
		expect(contentHeader?.props.title).not.toBe(basePackage.query.queryId);
		expect(contentHeader?.props.title).not.toContain(' vs ');
	});

	test.each([
		{ name: 'active in-flight', isActive: true, surface: { kind: 'updating' }, label: 'Updating…' },
		{
			name: 'active held',
			isActive: true,
			surface: { kind: 'updating', rest: 'held' },
			label: 'Update ready',
		},
		{ name: 'hidden', isActive: false, surface: { kind: 'updating', rest: 'hidden' }, label: null },
		{ name: 'settled', isActive: true, surface: { kind: 'current' }, label: null },
	] as const)('passes exactly one parent-owned W6 indicator for $name', (scenario): void => {
		const reviewPackage = makeBridgeReviewPackage();
		const controls = (
			<BridgeReviewRefreshHeaderGroup
				onApplyNow={(): void => {}}
				onRetry={(): void => {}}
				presentation={bridgeReviewRegionRefreshHeaderPresentation({
					isActive: scenario.isActive,
					surface: scenario.surface,
				})}
			/>
		);
		const element = renderReviewViewerShellForTest({
			onSelectItem: (): void => {},
			projection: projectionForPackage(reviewPackage),
			reviewPackage,
			selectedContentText: null,
			selectedItemId: 'item-source',
			isActive: scenario.isActive,
			regionSurfaceStatus: scenario.surface,
			viewerHeaderControls: controls,
			panelChromeSlice: { isLoading: true, message: 'Updating files…' },
		});
		const header = findElementByComponent(element, BridgeViewerContentHeader);
		expect(header).not.toBeNull();
		expect(header?.props.controls).toBe(controls);
		expect(controls.type).toBe(BridgeReviewRefreshHeaderGroup);
		expect(header?.props.statusText).toBeNull();
		expect(findElementByTestId(element, 'bridge-review-refresh-status-row')).toBeNull();
		const markup = renderToStaticMarkup(header?.props.controls);
		expect(markup.match(/role="status"/gu) ?? []).toHaveLength(scenario.label === null ? 0 : 1);
		if (scenario.label !== null) expect(markup).toContain(`aria-label="${scenario.label}"`);
		if (
			scenario.surface.kind === 'updating' &&
			'rest' in scenario.surface &&
			scenario.surface.rest === 'held'
		) {
			expect(markup.match(/>Apply now</gu) ?? []).toHaveLength(1);
		}
		expect(markup).not.toContain('lucide-loader-circle');
		expect(markup).not.toContain('Updating files…');
	});

	test('keeps parent-owned projection controls out of rail chrome', () => {
		const reviewPackage = makeBridgeReviewPackage();
		const element = requireTestElement(
			renderReviewViewerShellForTest({
				reviewPackage,
				projection: projectionForPackage(reviewPackage),
				selectedItemId: 'item-source',
				onSelectItem: () => undefined,
				selectedContentText: null,
			}),
		);

		const projectionScope = findElementByTestId(element, 'bridge-review-projection-scope');
		const projectionMenu = findElementByComponent(element, BridgeReviewProjectionMenu);
		const facetMenu = findElementByComponent(element, BridgeReviewFacetMenu);

		expect(findElementByTestId(element, 'bridge-review-top-header')).toBeNull();
		expect(projectionScope).toBeNull();
		expect(projectionMenu).toBeNull();
		expect(facetMenu).not.toBeNull();
		expect(findElementByTestId(element, 'bridge-review-rail-stats')).toBeNull();
	});

	test('renders review mode as a compact segmented control instead of a filter menu', () => {
		const element = requireTestElement(
			BridgeReviewProjectionMenu({
				projectionMode: { kind: 'normalReview' },
			}),
		);

		const segmentedControl = findElementByTestId(element, 'bridge-review-mode-segmented-control');
		const modeButtons = findElementsByTestId(element, 'bridge-review-mode-segment');

		expect(segmentedControl?.props.role).toBe('radiogroup');
		expect(segmentedControl?.props['aria-label']).toBe('Review mode');
		expect(modeButtons).toHaveLength(3);
		expect(modeButtons.map((button) => button.props['aria-checked'])).toEqual([
			'true',
			'false',
			'false',
		]);
		expect(modeButtons.map((button) => button.props.disabled)).toEqual([false, true, true]);
		expect(findElementByTestId(element, 'bridge-review-projection-menu')).toBeNull();
	});

	test('renders custom review controls without native select widgets', () => {
		const reviewPackage = makeBridgeReviewPackage();
		const element = requireTestElement(
			renderReviewViewerShellForTest({
				reviewPackage,
				projection: projectionForPackage(reviewPackage),
				selectedItemId: 'item-source',
				onSelectItem: () => undefined,
				selectedContentText: null,
			}),
		);

		expect(findElementsByType(element, 'select')).toEqual([]);
		expect(findElementByTestId(element, 'bridge-review-facet-menu')).not.toBeNull();
		expect(findElementByTestId(element, 'bridge-review-search-control-slot')).not.toBeNull();
	});

	test('groups right rail controls as compact sidebar toolbar chrome', () => {
		const reviewPackage = makeBridgeReviewPackage();
		const element = requireTestElement(
			renderReviewViewerShellForTest({
				reviewPackage,
				projection: projectionForPackage(reviewPackage),
				selectedItemId: 'item-source',
				onSelectItem: () => undefined,
				selectedContentText: null,
				viewerContextSwitcher: <div data-testid="bridge-viewer-context-switcher" />,
			}),
		);

		const toolbar = findElementByTestId(element, 'bridge-review-rail-toolbar');
		const leadingGroup = findElementByTestId(element, 'bridge-review-rail-toolbar-leading');
		const trailingGroup = findElementByTestId(element, 'bridge-review-rail-toolbar-trailing');
		const fileTreeButton = findElementByTestId(element, 'bridge-review-rail-files-view');
		const commentsButton = findElementByTestId(element, 'bridge-review-rail-comments-view');
		const leadingControlOrder = directChildControlNames(leadingGroup);
		const trailingControlOrder = directChildControlNames(trailingGroup);

		expect(toolbar?.type).toBe('div');
		expect(classNameForElement(toolbar)).toContain('justify-between');
		expect(classNameForElement(toolbar)).toContain('h-8');
		expect(toolbar?.props['data-bridge-shared-rail-toolbar']).toBe('true');
		expect(classNameForElement(leadingGroup)).toContain('gap-1');
		expect(classNameForElement(trailingGroup)).toContain('gap-1');
		expect(leadingControlOrder).toEqual(['bridge-viewer-context-switcher']);
		expect(trailingControlOrder).toEqual([
			'bridge-review-facet-menu',
			'bridge-review-search-control-slot',
		]);
		expect(fileTreeButton).toBeNull();
		expect(commentsButton).toBeNull();
	});

	test('uses the dark right-sidebar review layout', () => {
		const reviewPackage = makeBridgeReviewPackage();
		const element = requireTestElement(
			renderReviewViewerShellForTest({
				reviewPackage,
				projection: projectionForPackage(reviewPackage),
				selectedItemId: 'item-source',
				onSelectItem: () => undefined,
				selectedContentText: null,
			}),
		);

		expect(element.props['data-sidebar-position']).toBe('right');
		expect(classNameForElement(element)).toContain('bg-background');

		const canvas = findElementByTestId(element, 'bridge-review-canvas');
		const sidebar = findElementByTestId(element, 'bridge-review-sidebar');

		expect(canvas?.type).toBe('section');
		expect(classNameForElement(canvas)).toContain('bg-background');
		expect(classNameForElement(canvas)).toContain('h-full');
		expect(classNameForElement(canvas)).toContain('min-h-0');
		expect(sidebar?.type).toBe('aside');
		expect(classNameForElement(sidebar)).toContain('order-last');
		// The shared resize separator owns the boundary; the rail must not double it.
		expect(classNameForElement(sidebar)).not.toContain('border-l');
		expect(classNameForElement(sidebar)).toContain('bg-surface');
	});

	test('keeps CodeView and right rail scrolling owned by separate containers', () => {
		const reviewPackage = makeBridgeReviewPackage();
		const element = requireTestElement(
			renderReviewViewerShellForTest({
				reviewPackage,
				projection: projectionForPackage(reviewPackage),
				selectedItemId: 'item-source',
				onSelectItem: () => undefined,
				selectedContentText: null,
			}),
		);
		const shell = findElementByTestId(element, 'review-viewer-shell');
		const codeScroll = findElementByTestId(element, 'bridge-review-code-scroll');
		const railScroll = findElementByTestId(element, 'bridge-review-rail-scroll');
		const railTreeSlot = findElementByTestId(element, 'bridge-review-rail-tree-slot');

		expect(classNameForElement(shell)).toContain('overflow-hidden');
		expect(codeScroll?.type).toBe('section');
		expect(railScroll?.type).toBe('div');
		expect(railTreeSlot?.type).toBe('nav');
		expect(classNameForElement(codeScroll)).toContain('overflow-hidden');
		expect(classNameForElement(codeScroll)).not.toContain('bridge-scrollbar');
		expect(classNameForElement(railScroll)).toContain('overflow-hidden');
		expect(classNameForElement(codeScroll)).toContain('min-h-0');
		expect(classNameForElement(railScroll)).toContain('min-h-0');
		expect(classNameForElement(railTreeSlot)).toContain('h-full');
		expect(classNameForElement(railTreeSlot)).toContain('min-h-0');
	});

	test('routes review tree content through the resizable right rail slot contract', () => {
		const reviewPackage = makeBridgeReviewPackage();
		const element = requireTestElement(
			renderReviewViewerShellForTest({
				reviewPackage,
				projection: projectionForPackage(reviewPackage),
				selectedItemId: 'item-source',
				onSelectItem: () => undefined,
				selectedContentText: null,
			}),
		);
		const resizableLayout = findElementByComponent(element, BridgeViewerResizableRailLayout);
		const rail = resizableLayout?.props.rail;
		const sidebar = findElementByTestId(rail, 'bridge-review-sidebar');
		const railScroll = findElementByTestId(rail, 'bridge-review-rail-scroll');
		const railTreeSlot = findElementByTestId(rail, 'bridge-review-rail-tree-slot');
		const railText = collectText(rail);

		expect(resizableLayout?.props.contentTestId).toBe('bridge-review-content-panel');
		expect(resizableLayout?.props.railTestId).toBe('bridge-review-resizable-rail');
		expect(resizableLayout?.props.handleTestId).toBe('bridge-review-rail-resize-handle');
		expect(sidebar).not.toBeNull();
		expect(railScroll).not.toBeNull();
		expect(railTreeSlot).not.toBeNull();
		expect(railText).toContain('Sources/App/View.swift');
		expect(railText).toContain('Search files');
		expect(classNameForElement(sidebar)).toContain('h-full');
		expect(classNameForElement(railScroll)).toContain('flex-1');
	});

	test('exposes selected identity and content readiness from the shell', () => {
		const reviewPackage = makeBridgeReviewPackage();
		const selectedItem = reviewPackage.itemsById['item-source'];
		if (selectedItem === undefined) {
			throw new Error('expected selected fixture item');
		}
		const element = requireTestElement(
			renderReviewViewerShellForTest({
				reviewPackage,
				projection: projectionForPackage(reviewPackage),
				selectedItemId: 'item-source',
				onSelectItem: () => undefined,
				selectedContentText: null,
				selectedCodeViewItem: materializeBridgeCodeViewLoadingItem(selectedItem),
			}),
		);
		const shell = findElementByTestId(element, 'review-viewer-shell');

		expect(shell?.props['data-selected-display-path']).toBe('Sources/App/View.swift');
		expect(shell?.props['data-selected-content-state']).toBe('ready');
	});

	test('publishes zero-valued visible demand counts for browser verifier pressure proof', () => {
		const reviewPackage = makeBridgeReviewPackage();
		const element = requireTestElement(
			renderReviewViewerShellForTest({
				reviewPackage,
				projection: projectionForPackage(reviewPackage),
				selectedItemId: 'item-source',
				onSelectItem: () => undefined,
				lastVisibleDemandTelemetry: {
					itemId: 'item-source',
					packageId: reviewPackage.packageId,
					reviewGeneration: reviewPackage.reviewGeneration,
					revision: reviewPackage.revision,
					interest: 'visible',
					byteBudgetSource: 'review-content-demand',
					configuredExecutorMaxConcurrentLoads: 8,
					configuredExecutorMaxInFlightBytes: 8_388_608,
					intentCount: 1,
					foregroundIntentCount: 0,
					activeIntentCount: 0,
					visibleIntentCount: 1,
					nearbyIntentCount: 0,
					speculativeIntentCount: 0,
					idleIntentCount: 0,
					executorInFlightCountBefore: 0,
					executorInFlightCountAfterDispatch: 1,
					executorInFlightCountAfter: 0,
					executorInFlightBytesBefore: 0,
					executorInFlightBytesAfterDispatch: 1024,
					executorInFlightBytesAfter: 0,
					executorQueuedLoadCountBefore: 0,
					executorQueuedLoadCountAfterDispatch: 0,
					executorQueuedLoadCountAfter: 0,
					executorQueuedBytesBefore: 0,
					executorQueuedBytesAfterDispatch: 0,
					executorQueuedBytesAfter: 0,
					durationMilliseconds: 12,
					laneUpgradeCount: 0,
					maxExecutorInFlightCount: 1,
					maxExecutorQueuedLoadCount: 0,
					admittedBytes: 0,
					admittedBytesByLane: emptyDemandLaneByteCounts(),
					deferredCount: 1,
					deferredEstimatedBytesByLane: {
						...emptyDemandLaneByteCounts(),
						visible: 1024,
					},
					droppedEstimatedBytesByLane: emptyDemandLaneByteCounts(),
					droppedIntentCount: 0,
					failedCount: 0,
					loadedCount: 0,
					staleDropCount: 0,
				} satisfies ReviewContentDemandTelemetry,
			}),
		);
		const shell = findElementByTestId(element, 'review-viewer-shell');

		expect(shell?.props['data-review-visible-demand-foreground-intent-count']).toBe(0);
		expect(shell?.props['data-review-visible-demand-visible-intent-count']).toBe(1);
		expect(shell?.props['data-review-visible-demand-interest']).toBe('visible');
		expect(shell?.props['data-review-visible-demand-item-id']).toBe('item-source');
		expect(shell?.props['data-review-visible-demand-package-id']).toBe(reviewPackage.packageId);
		expect(shell?.props['data-review-visible-demand-package-generation']).toBe(
			reviewPackage.reviewGeneration,
		);
		expect(shell?.props['data-review-visible-demand-package-revision']).toBe(
			reviewPackage.revision,
		);
		expect(shell?.props['data-review-visible-demand-duration-ms']).toBe(12);
		expect(shell?.props['data-review-metadata-id']).toBe(reviewPackage.packageId);
		expect(shell?.props['data-review-metadata-generation']).toBe(reviewPackage.reviewGeneration);
		expect(shell?.props['data-review-metadata-revision']).toBe(reviewPackage.revision);
		expect(shell?.props['data-review-base-endpoint-id']).toBe(reviewPackage.query.baseEndpointId);
		expect(shell?.props['data-review-base-endpoint-kind']).toBe(reviewPackage.baseEndpoint.kind);
		expect(shell?.props['data-review-base-provider-identity']).toBe(
			reviewPackage.baseEndpoint.providerIdentity,
		);
		expect(shell?.props['data-review-head-endpoint-id']).toBe(reviewPackage.query.headEndpointId);
		expect(shell?.props['data-review-head-endpoint-kind']).toBe(reviewPackage.headEndpoint.kind);
		expect(shell?.props['data-review-head-provider-identity']).toBe(
			reviewPackage.headEndpoint.providerIdentity,
		);
	});

	test('publishes the active canvas branch for native startup diagnostics', () => {
		const reviewPackage = makeBridgeReviewPackage();
		const codeElement = requireTestElement(
			renderReviewViewerShellForTest({
				reviewPackage,
				projection: projectionForPackage(reviewPackage),
				selectedItemId: 'item-source',
				onSelectItem: () => undefined,
				selectedContentText: null,
			}),
		);
		const unavailableElement = requireTestElement(
			renderReviewViewerShellForTest({
				reviewPackage,
				projection: projectionForPackage(reviewPackage),
				selectedItemId: 'item-source',
				onSelectItem: () => undefined,
				selectedContentText: null,
				selectedContentUnavailablePath: 'Sources/App/View.swift',
			}),
		);

		expect(
			findElementByTestId(codeElement, 'review-viewer-shell')?.props['data-review-canvas-branch'],
		).toBe('code');
		expect(
			findElementByTestId(unavailableElement, 'review-viewer-shell')?.props[
				'data-review-canvas-branch'
			],
		).toBe('unavailable');
	});

	test('renders only items matching folder file-class and change-kind filter state', () => {
		const basePackage = makeBridgeReviewPackage();
		const sourceItem = basePackage.itemsById['item-source'];
		if (sourceItem === undefined) {
			throw new Error('expected source item');
		}
		const hiddenDocsItem = {
			...sourceItem,
			itemId: 'item-docs',
			basePath: 'docs/architecture/old.md',
			headPath: 'docs/architecture/old.md',
			changeKind: 'added' as const,
			fileClass: 'docs' as const,
			extension: 'md',
		};
		const reviewPackage = {
			...basePackage,
			orderedItemIds: ['item-source', 'item-docs'],
			itemsById: {
				'item-source': sourceItem,
				'item-docs': hiddenDocsItem,
			},
			query: {
				...basePackage.query,
				pathScope: ['Sources/**'],
			},
			filterState: {
				...basePackage.filterState,
				includedFileClasses: ['source' as const],
				changeKinds: ['modified' as const],
			},
		};

		const element = renderReviewViewerShellForTest({
			reviewPackage,
			projection: projectionForPackage(reviewPackage),
			selectedItemId: 'item-source',
			onSelectItem: () => undefined,
			selectedContentText: null,
		});

		const text = collectText(element);
		expect(text).toContain('Sources/App/View.swift');
		expect(text).not.toContain('docs/architecture/old.md');
		expect(findElementByTestId(element, 'bridge-review-top-header')).toBeNull();
	});
});

function renderReviewViewerShellForTest(
	props: Omit<
		ReviewViewerShellProps,
		| 'panelChromeSlice'
		| 'comparisonPaneState'
		| 'onRetryComparison'
		| 'facetMenuOpen'
		| 'onFacetMenuOpenChange'
		| 'presentationPositionKey'
		| 'presentationRegistry'
		| 'renderFulfillmentCoordinator'
	> & {
		readonly panelChromeSlice?: ReviewViewerShellProps['panelChromeSlice'];
		readonly comparisonPaneState?: ReviewViewerShellProps['comparisonPaneState'];
		readonly onRetryComparison?: ReviewViewerShellProps['onRetryComparison'];
		readonly presentationPositionKey?: string;
		readonly presentationRegistry?: BridgeReviewItemRegistry;
	},
): ReactElement {
	const presentationRegistry =
		props.presentationRegistry ??
		createBridgeReviewItemRegistry({ reviewPackage: props.reviewPackage });
	return renderReviewViewerShellPresentation({
		props: {
			...props,
			facetMenuOpen: false,
			comparisonPaneState: props.comparisonPaneState ?? { kind: 'settled' },
			onRetryComparison: props.onRetryComparison ?? ((): void => {}),
			onFacetMenuOpenChange: (): void => {},
			panelChromeSlice: props.panelChromeSlice ?? {},
			presentationPositionKey: props.presentationPositionKey ?? 'review-shell-test-position',
			presentationRegistry,
			renderFulfillmentCoordinator: shellTestRenderFulfillmentCoordinator,
		},
		searchTriggerRef: createRef<HTMLButtonElement>(),
		surfaceRootRef: createRef<HTMLElement>(),
	});
}

function appendedReviewPackageForShell(
	reviewPackage: BridgeReviewPackage = makeBridgeReviewPackage(),
): BridgeReviewPackage {
	const addedItem = makeBridgeReviewItem({
		itemId: 'item-added',
		path: 'Sources/App/NewPanel.swift',
	});
	return {
		...reviewPackage,
		revision: reviewPackage.revision + 1,
		orderedItemIds: [...reviewPackage.orderedItemIds, addedItem.itemId],
		itemsById: {
			...reviewPackage.itemsById,
			[addedItem.itemId]: addedItem,
		},
		summary: {
			...reviewPackage.summary,
			filesChanged: reviewPackage.summary.filesChanged + 1,
			visibleFileCount: reviewPackage.summary.visibleFileCount + 1,
		},
	};
}

function collectText(node: ReactNode): string {
	return collectTextFragments(node).join(' ').replaceAll(/\s+/g, ' ').trim();
}

function collectTextFragments(node: ReactNode): readonly string[] {
	if (typeof node === 'string' || typeof node === 'number') {
		return [String(node)];
	}
	if (Array.isArray(node)) {
		return node.flatMap((child: ReactNode): readonly string[] => collectTextFragments(child));
	}
	if (isReactElement(node)) {
		return collectTextFragments(traversalChildrenForElement(node));
	}
	return [];
}

function traversalChildrenForElement(
	element: ReactElement<TestElementProps>,
): readonly ReactNode[] {
	const children = Array.isArray(element.props.children)
		? element.props.children
		: [element.props.children];
	if (element.type === BridgeViewerResizableRailLayout) {
		return [...children, element.props.content, element.props.rail];
	}
	return children;
}

interface TestElementProps {
	readonly 'aria-busy'?: string;
	readonly 'aria-checked'?: string;
	readonly 'aria-label'?: string;
	readonly ariaPressed?: boolean;
	readonly children?: ReactNode;
	readonly className?: string;
	readonly content?: ReactNode;
	readonly controls?: ReactNode;
	readonly contentTestId?: string;
	readonly 'data-bridge-shared-rail-toolbar'?: string;
	readonly 'data-bridge-segmented-control'?: string;
	readonly 'data-review-visible-demand-foreground-intent-count'?: number;
	readonly 'data-review-visible-demand-interest'?: string;
	readonly 'data-review-visible-demand-item-id'?: string;
	readonly 'data-review-visible-demand-package-id'?: string;
	readonly 'data-review-visible-demand-package-generation'?: number;
	readonly 'data-review-visible-demand-package-revision'?: number;
	readonly 'data-review-visible-demand-duration-ms'?: number;
	readonly 'data-review-visible-demand-visible-intent-count'?: number;
	readonly 'data-review-metadata-id'?: string;
	readonly 'data-review-metadata-generation'?: number;
	readonly 'data-review-metadata-revision'?: number;
	readonly 'data-review-base-endpoint-id'?: string;
	readonly 'data-review-base-endpoint-kind'?: string;
	readonly 'data-review-base-provider-identity'?: string;
	readonly 'data-review-head-endpoint-id'?: string;
	readonly 'data-review-head-endpoint-kind'?: string;
	readonly 'data-review-head-provider-identity'?: string;
	readonly 'data-review-selection-commit-duration-ms'?: number;
	readonly 'data-review-canvas-branch'?: string;
	readonly 'data-selected-content-state'?: string;
	readonly 'data-selected-display-path'?: string;
	readonly 'data-sidebar-position'?: string;
	readonly 'data-testid'?: string;
	readonly disabled?: boolean;
	readonly handleTestId?: string;
	readonly inert?: boolean;
	readonly onClick?: () => void;
	readonly onValueChange?: () => void;
	readonly rail?: ReactNode;
	readonly railTestId?: string;
	readonly reason?: string;
	readonly role?: string;
	readonly statusText?: string | null;
	readonly title?: string;
}

function emptyDemandLaneByteCounts(): Record<
	'foreground' | 'active' | 'visible' | 'nearby' | 'speculative' | 'idle',
	number
> {
	return {
		foreground: 0,
		active: 0,
		visible: 0,
		nearby: 0,
		speculative: 0,
		idle: 0,
	};
}

function isReactElement(node: ReactNode): node is ReactElement<TestElementProps> {
	return typeof node === 'object' && node !== null && 'props' in node;
}

function requireTestElement(node: ReactNode): ReactElement<TestElementProps> {
	if (!isReactElement(node)) {
		throw new Error('expected React element');
	}
	return node;
}

function findElementByTestId(
	node: ReactNode,
	testId: string,
): ReactElement<TestElementProps> | null {
	if (Array.isArray(node)) {
		for (const child of node) {
			const match = findElementByTestId(child, testId);
			if (match !== null) {
				return match;
			}
		}
		return null;
	}
	if (!isReactElement(node)) {
		return null;
	}
	if (node.props['data-testid'] === testId) {
		return node;
	}
	return findElementByTestId(traversalChildrenForElement(node), testId);
}

function findElementsByTestId(
	node: ReactNode,
	testId: string,
): readonly ReactElement<TestElementProps>[] {
	if (Array.isArray(node)) {
		return node.flatMap((child: ReactNode): readonly ReactElement<TestElementProps>[] =>
			findElementsByTestId(child, testId),
		);
	}
	if (!isReactElement(node)) {
		return [];
	}
	return [
		...(node.props['data-testid'] === testId ? [node] : []),
		...findElementsByTestId(traversalChildrenForElement(node), testId),
	];
}

function findElementsByType(
	node: ReactNode,
	type: string,
): readonly ReactElement<TestElementProps>[] {
	if (Array.isArray(node)) {
		return node.flatMap((child: ReactNode): readonly ReactElement<TestElementProps>[] =>
			findElementsByType(child, type),
		);
	}
	if (!isReactElement(node)) {
		return [];
	}
	return [
		...(node.type === type ? [node] : []),
		...findElementsByType(traversalChildrenForElement(node), type),
	];
}

function findElementByComponent(
	node: ReactNode,
	component: ReactElement['type'],
): ReactElement<TestElementProps> | null {
	if (Array.isArray(node)) {
		for (const child of node) {
			const match = findElementByComponent(child, component);
			if (match !== null) {
				return match;
			}
		}
		return null;
	}
	if (!isReactElement(node)) {
		return null;
	}
	if (node.type === component) {
		return node;
	}
	return findElementByComponent(traversalChildrenForElement(node), component);
}

function classNameForElement(element: ReactElement<TestElementProps> | null): string {
	return element?.props.className ?? '';
}

function directChildControlNames(
	element: ReactElement<TestElementProps> | null,
): readonly (string | undefined)[] {
	if (element === null) {
		return [];
	}
	const children = Array.isArray(element.props.children)
		? element.props.children
		: [element.props.children];
	return children
		.filter(isReactElement)
		.map((child: ReactElement<TestElementProps>): string | undefined => {
			if (child.type === BridgeReviewProjectionMenu) {
				return 'BridgeReviewProjectionMenu';
			}
			return child.props['data-testid'];
		});
}

function projectionForPackage(
	reviewPackage: BridgeReviewPackage,
): ReturnType<typeof buildBridgeReviewProjection> {
	return buildBridgeReviewProjection({
		reviewPackage,
		request: { mode: { kind: 'normalReview' }, facets: [] },
	});
}
