import { act, useCallback, useRef, useState, type ReactElement } from 'react';
import { afterEach, describe, expect, test } from 'vitest';
import { cleanup, render, type RenderResult } from 'vitest-browser-react';

import {
	useBridgeReviewSelectionController,
	type BridgeReviewSelectionSource,
} from '../../app/bridge-app-review-selection-controller.js';

// oxlint-disable-next-line import/no-unassigned-import -- Browser Mode must load production app CSS.
import '../../app/bridge-app.css';
import {
	BridgeReviewViewerShellBoundary,
	type BridgeReviewViewerPresentationState,
} from '../../app/bridge-app-review-viewer-shell-boundary.js';
import { createBridgeMainRenderFulfillmentCoordinator } from '../../core/comm-worker/bridge-main-render-fulfillment-coordinator.js';
import type { BridgeWorkerRenderSourceCorrelation } from '../../core/comm-worker/bridge-worker-pierre-render-job.js';
import { createBridgeReviewItemRegistry } from '../../foundation/review-package/bridge-review-item-registry.js';
import { makeBridgeReviewPackage } from '../../foundation/review-package/bridge-review-package-test-support.js';
import { createBridgeTelemetryRecorder } from '../../foundation/telemetry/bridge-telemetry-recorder.js';
import { buildBridgeReviewProjection } from '../navigation/review-projection.js';
import {
	dispatchReviewViewerShortcut,
	dispatchReviewViewerMenuKey,
	navigateReviewViewerMenuTo,
	highlightedReviewViewerMenuOption,
	highlightedReviewViewerMenuOptionLabel,
} from './bridge-review-filter-keyboard.test-support.js';
import {
	reviewNavigationCommand,
	ReviewNavigationControllerProbe,
} from './bridge-review-navigation-controller.browser.test-support.js';
import {
	advanceBridgeReviewRecoveryWitnessFrames,
	disposeBridgeReviewRecoveryWitnessHarnesses,
	makeBridgeReviewRecoveryWitnessFiles,
	renderBridgeReviewRecoveryWitness,
} from './bridge-viewer-browser.recovery-witness.test-support.js';
const readyPresentationRenderFulfillmentCoordinator = createBridgeMainRenderFulfillmentCoordinator({
	cancelAnimationFrame: (_frameHandle): void => {},
	nowMilliseconds: (): number => 0,
	requestAnimationFrame: (_callback): number => {
		throw new Error('Ready Review Browser fixture must not schedule paint validation.');
	},
	sendDisposition: (_receipt): void => {},
});
const disabledBridgeTelemetryRecorderRef = {
	current: createBridgeTelemetryRecorder(null),
} as const;

describe('Bridge Review production recovery Browser witnesses', () => {
	afterEach(async (): Promise<void> => {
		await cleanup();
		disposeBridgeReviewRecoveryWitnessHarnesses();
		await advanceBridgeReviewRecoveryWitnessFrames(2);
		document.body.replaceChildren();
	});

	test('mounts hierarchical Review navigation through Pierre Trees', async () => {
		// Arrange
		const files = makeBridgeReviewRecoveryWitnessFiles({
			count: 6,
			lineCount: 3,
			markerPrefix: 'HIERARCHY',
		});
		const harness = await renderBridgeReviewRecoveryWitness(files);
		await expect
			.element(harness.renderResult.getByTestId('bridge-review-fallback-frame'))
			.toBeVisible();

		// Act
		await harness.publishDisplay();
		await expect.element(harness.renderResult.getByTestId('review-viewer-shell')).toBeVisible();
		await advanceBridgeReviewRecoveryWitnessFrames(2);

		// Assert
		await expect
			.poll(() => harness.pierreTreeHost(), {
				message:
					'G0 REVIEW HIERARCHY MISSING: expected the production Review rail to mount hierarchical @pierre/trees instead of flat depth-only rows.',
			})
			.not.toBeNull();
		await expect.poll(() => harness.pierreTreePath('Sources')).not.toBeNull();
		await expect.poll(() => harness.pierreTreePath('Sources/RecoveryGroup01')).not.toBeNull();
		await expect.poll(() => harness.pierreTreePath(files[0]?.path ?? '')).not.toBeNull();
		expect(harness.expandedTreePaths().toSorted()).toEqual(expectedExpandedRecoveryTreePaths());
		for (const directoryPath of expectedExpandedRecoveryTreePaths()) {
			expect(harness.pierreTreePath(directoryPath)?.getAttribute('aria-expanded')).toBe('true');
		}
	});
	test('opens and updates recovered Review tree search synchronously', async () => {
		// Arrange
		const files = makeBridgeReviewRecoveryWitnessFiles({
			count: 6,
			lineCount: 3,
			markerPrefix: 'SEARCH',
		});
		const harness = await renderBridgeReviewRecoveryWitness(files);
		await harness.publishDisplay();
		await expect.element(harness.renderResult.getByTestId('review-viewer-shell')).toBeVisible();
		expect(document.querySelector('[data-testid="bridge-review-search-toggle"]')).not.toBeNull();

		await dispatchReviewViewerShortcut({ shiftKey: true });

		const activeSearchToggle = harness.renderResult.getByTestId('bridge-review-search-toggle');
		expect(activeSearchToggle.element().getAttribute('aria-pressed')).toBe('true');
		expect(activeSearchToggle.element().getAttribute('aria-label')).toBe('Search files');
		await expect
			.poll(() => harness.pierreSearchInput(), {
				message:
					'J1 REVIEW SEARCH INERT: expected the production search control to synchronously open and focus Pierre Trees search.',
			})
			.not.toBeNull();
		const searchInput = harness.pierreSearchInput();
		if (!(searchInput instanceof HTMLInputElement)) {
			throw new Error('J1 REVIEW SEARCH INPUT MISSING');
		}
		expect(document.activeElement).toBe(searchInput);

		await dispatchReviewViewerShortcut({ shiftKey: true });

		expect(document.querySelector('[data-testid="bridge-review-search-input"]')).toBeNull();
		expect(activeSearchToggle.element().getAttribute('aria-pressed')).toBe('false');
		expect(activeSearchToggle.element().getAttribute('aria-label')).toBe('Search files');

		await dispatchReviewViewerShortcut({ shiftKey: true });

		const reopenedSearchInput = harness.pierreSearchInput();
		if (!(reopenedSearchInput instanceof HTMLInputElement)) {
			throw new Error('J1 REVIEW REOPENED SEARCH INPUT MISSING');
		}
		const expectedMatch = files[4];
		if (expectedMatch === undefined) throw new Error('J1 REVIEW SEARCH FIXTURE MISSING');
		await act(async (): Promise<void> => {
			await harness.renderResult.getByTestId('bridge-review-search-input').fill('RecoveryFile005');
		});
		await advanceBridgeReviewRecoveryWitnessFrames(2);

		expect(reopenedSearchInput.value).toBe('RecoveryFile005');
		const searchField = requireReviewHTMLElement(
			document.querySelector('[data-bridge-viewer-search-field="true"]'),
		);
		const searchIcon = document.querySelector('[data-bridge-viewer-search-icon="true"]');
		if (!(searchIcon instanceof SVGElement))
			throw new Error('Expected the shared search icon SVG.');
		const regexButton = requireReviewHTMLElement(
			document.querySelector('[data-testid="bridge-review-regex-toggle"]'),
		);
		const clearButton = requireReviewHTMLElement(
			document.querySelector('[data-testid="bridge-review-search-clear"]'),
		);
		const fieldBox = searchField.getBoundingClientRect();
		const iconBox = searchIcon.getBoundingClientRect();
		const inputBox = reopenedSearchInput.getBoundingClientRect();
		const regexBox = regexButton.getBoundingClientRect();
		const clearBox = clearButton.getBoundingClientRect();
		const railToolbar = requireReviewHTMLElement(
			document.querySelector('[data-testid="bridge-review-rail-toolbar"]'),
		);
		const railTrailingControls = requireReviewHTMLElement(
			document.querySelector('[data-testid="bridge-review-rail-toolbar-trailing"]'),
		);
		expect(
			Math.abs(
				railToolbar.getBoundingClientRect().right -
					railTrailingControls.getBoundingClientRect().right -
					8,
			),
		).toBeLessThanOrEqual(1);
		expect(regexBox.right).toBeLessThan(clearBox.left);
		expect(Math.abs(fieldBox.right - clearBox.right - 6)).toBeLessThanOrEqual(1);
		expect(iconBox.left - fieldBox.left).toBeGreaterThanOrEqual(6);
		expect(inputBox.left - iconBox.right).toBeGreaterThanOrEqual(4);
		for (const controlBox of [iconBox, inputBox, regexBox, clearBox]) {
			expect(
				Math.abs(controlBox.y + controlBox.height / 2 - (fieldBox.y + fieldBox.height / 2)),
			).toBeLessThanOrEqual(1);
		}
		expect(mountedReviewTreePaths(harness.pierreTreeHost())).toEqual([
			'Sources',
			'Sources/RecoveryGroup02',
			expectedMatch.path,
		]);

		// Act
		await act(async (): Promise<void> => {
			await harness.renderResult.getByTestId('bridge-review-regex-toggle').click();
		});

		// Assert
		await expect
			.element(harness.renderResult.getByTestId('bridge-review-regex-toggle'))
			.toHaveAttribute('aria-pressed', 'true');
		const regexSearchInput = harness.pierreSearchInput();
		if (!(regexSearchInput instanceof HTMLInputElement)) {
			throw new Error('Review regex search input is missing after the source reset.');
		}

		// Act: apply a real regex that spans two directory branches.
		await act(async (): Promise<void> => {
			await harness.renderResult
				.getByTestId('bridge-review-search-input')
				.fill(String.raw`RecoveryFile00[24]\.swift$`);
		});
		await advanceBridgeReviewRecoveryWitnessFrames(2);

		// Assert: retain only matching files and the ancestors required to reach them.
		expect(harness.pierreSearchInput()?.value).toBe(String.raw`RecoveryFile00[24]\.swift$`);
		expect(mountedReviewTreePaths(harness.pierreTreeHost())).toEqual([
			'Sources',
			'Sources/RecoveryGroup01',
			'Sources/RecoveryGroup01/RecoveryFile002.swift',
			'Sources/RecoveryGroup02',
			'Sources/RecoveryGroup02/RecoveryFile004.swift',
		]);

		// Act: a valid regex with no matching file must render an empty tree.
		await act(async (): Promise<void> => {
			await harness.renderResult
				.getByTestId('bridge-review-search-input')
				.fill(String.raw`RecoveryFile999\.swift$`);
		});
		await advanceBridgeReviewRecoveryWitnessFrames(2);

		// Assert
		expect(mountedReviewTreePaths(harness.pierreTreeHost())).toEqual([]);

		await act(async (): Promise<void> => {
			await harness.renderResult
				.getByTestId('bridge-review-search-input')
				.fill(String.raw`RecoveryFile005\.swift$`);
		});
		await advanceBridgeReviewRecoveryWitnessFrames(2);
		const acceptedSearchPaths = [
			'Sources',
			'Sources/RecoveryGroup02',
			'Sources/RecoveryGroup02/RecoveryFile005.swift',
		];
		expect(mountedReviewTreePaths(harness.pierreTreeHost())).toEqual(acceptedSearchPaths);
		const invalidRegexSearchInput = harness.pierreSearchInput();
		if (!(invalidRegexSearchInput instanceof HTMLInputElement)) {
			throw new Error('Review regex search input is missing before invalid-regex proof.');
		}
		const selectedItemCommandCountBeforeInvalidSearch = harness.selectedItemCommandCount();
		const viewportCommandsBeforeInvalidSearch = harness.viewportCommandVisibleItemIds();

		// Act: invalid regex keeps the entered value but must retain the last accepted projection.
		await act(async (): Promise<void> => {
			await harness.renderResult.getByTestId('bridge-review-search-input').fill('[');
		});
		await advanceBridgeReviewRecoveryWitnessFrames(2);

		// Assert
		expect(mountedReviewTreePaths(harness.pierreTreeHost())).toEqual(acceptedSearchPaths);
		await expect
			.element(harness.renderResult.getByTestId('bridge-review-tree-search-status'))
			.toHaveTextContent('Invalid regex');
		expect(harness.selectedItemCommandCount()).toBe(selectedItemCommandCountBeforeInvalidSearch);
		expect(harness.viewportCommandVisibleItemIds()).toEqual(viewportCommandsBeforeInvalidSearch);

		// Act: Clear is the far-right reset for the same shared field.
		await act(async (): Promise<void> => {
			await harness.renderResult.getByTestId('bridge-review-search-clear').click();
		});
		await advanceBridgeReviewRecoveryWitnessFrames(2);

		// Assert: Clear resets the query without closing Search.
		await expect
			.element(harness.renderResult.getByTestId('bridge-review-search-input'))
			.toHaveValue('');
		expect(activeSearchToggle.element().getAttribute('aria-pressed')).toBe('true');
		expect(activeSearchToggle.element().getAttribute('aria-label')).toBe('Search files');
		expect(mountedReviewTreePaths(harness.pierreTreeHost())).toHaveLength(9);

		// Act: only the active toolbar toggle closes Search and clears its query.
		await act(async (): Promise<void> => {
			await harness.renderResult.getByTestId('bridge-review-search-input').fill('RecoveryFile005');
			await activeSearchToggle.click();
		});
		await advanceBridgeReviewRecoveryWitnessFrames(2);

		// Assert
		expect(document.querySelector('[data-testid="bridge-review-search-input"]')).toBeNull();
		expect(activeSearchToggle.element().getAttribute('aria-pressed')).toBe('false');
		expect(activeSearchToggle.element().getAttribute('aria-label')).toBe('Search files');
		await act(async (): Promise<void> => {
			await activeSearchToggle.click();
		});
		await expect
			.element(harness.renderResult.getByTestId('bridge-review-search-input'))
			.toHaveValue('');
	});
	test('Review facets replace visible rows with required ancestors and Clear restores the tree', async () => {
		// Arrange
		const files = makeBridgeReviewRecoveryWitnessFiles({
			count: 6,
			lineCount: 3,
			markerPrefix: 'FACETS',
		}).map((file, index) => {
			return Object.assign({}, file, {
				changeKind: index < 3 ? ('added' as const) : ('modified' as const),
				fileClass: index < 3 ? ('source' as const) : ('test' as const),
			});
		});
		const harness = await renderBridgeReviewRecoveryWitness(files);
		await harness.publishDisplay();
		await expect.poll(() => mountedReviewTreePaths(harness.pierreTreeHost())).toHaveLength(9);

		// Act: Command-Option-F opens the active Review Filters menu.
		await dispatchReviewViewerShortcut({ altKey: true });
		await expect
			.element(harness.renderResult.getByTestId('bridge-review-facet-popover'))
			.toBeVisible();
		await harness.setActive(false);
		expect(
			document.querySelector('[data-testid="bridge-review-facet-popover"][data-open]'),
		).toBeNull();
		await harness.setActive(true);
		await dispatchReviewViewerShortcut({ altKey: true });
		const reviewFacetPopover = requireReviewHTMLElement(
			document.querySelector('[data-testid="bridge-review-facet-popover"]'),
		);
		const reviewFacetTrigger = requireReviewHTMLElement(
			document.querySelector('[data-testid="bridge-review-facet-menu-control"]'),
		);
		await expect.poll(() => reviewFacetOptionContaining('Added')).not.toBeNull();
		const reviewFacetOption = requireReviewHTMLElement(reviewFacetOptionContaining('Added'));
		const reviewFacetClear = requireReviewHTMLElement(
			document.querySelector('[data-testid="bridge-review-facet-clear"]'),
		);
		expect(reviewFacetOption.offsetHeight).toBe(28);
		expect(reviewFacetClear.offsetHeight).toBe(28);
		expect(
			Math.abs(
				reviewFacetPopover.getBoundingClientRect().right -
					reviewFacetTrigger.getBoundingClientRect().right,
			),
		).toBeLessThanOrEqual(1);
		await dispatchReviewViewerShortcut({ altKey: true });
		expect(
			document.querySelector('[data-testid="bridge-review-facet-popover"][data-open]'),
		).toBeNull();
		await dispatchReviewViewerShortcut({ altKey: true });
		await dispatchReviewViewerMenuKey('Escape');
		expect(
			document.querySelector('[data-testid="bridge-review-facet-popover"][data-open]'),
		).toBeNull();
		await dispatchReviewViewerShortcut({ altKey: true });
		await expect.poll(() => document.activeElement?.getAttribute('role')).toBe('menu');
		await dispatchReviewViewerMenuKey('ArrowDown');
		await expect.poll(highlightedReviewViewerMenuOptionLabel).toBe('All statuses');
		await dispatchReviewViewerMenuKey('ArrowDown');
		await expect.poll(highlightedReviewViewerMenuOptionLabel).toBe('Added');
		await navigateReviewViewerMenuTo('Modified');
		const focusedModifiedOption = highlightedReviewViewerMenuOption();
		expect(focusedModifiedOption.textContent).toContain('Modified');
		expect(document.activeElement).toBe(focusedModifiedOption);
		await dispatchReviewViewerMenuKey('Enter');
		await expect.poll(() => focusedModifiedOption.getAttribute('aria-checked')).toBe('true');
		await advanceBridgeReviewRecoveryWitnessFrames(2);

		// Assert
		expect(mountedReviewTreePaths(harness.pierreTreeHost())).toEqual([
			'Sources',
			'Sources/RecoveryGroup02',
			'Sources/RecoveryGroup02/RecoveryFile004.swift',
			'Sources/RecoveryGroup02/RecoveryFile005.swift',
			'Sources/RecoveryGroup02/RecoveryFile006.swift',
		]);

		// Act: reset through the visible Clear action.
		await act(async (): Promise<void> => {
			await harness.renderResult.getByTestId('bridge-review-facet-clear').click();
		});
		await advanceBridgeReviewRecoveryWitnessFrames(2);

		// Assert
		expect(mountedReviewTreePaths(harness.pierreTreeHost())).toHaveLength(9);
	});
	test('reveals ancestors for explicit Review navigation without changing fresh disclosure', async () => {
		// Arrange
		const files = makeBridgeReviewRecoveryWitnessFiles({
			count: 6,
			lineCount: 3,
			markerPrefix: 'EXPLICIT_REVEAL',
		});
		const targetFile = files[4];
		if (targetFile === undefined) throw new Error('J1 REVIEW EXPLICIT REVEAL FIXTURE MISSING');
		const harness = await renderBridgeReviewRecoveryWitness(files, {
			navigationCommand: reviewNavigationCommand('explicit-reveal-command', targetFile.itemId),
		});

		// Act
		await harness.publishDisplay();
		await expect.poll(() => harness.selectedItemCommandCount()).toBe(1);

		// Assert
		await expect.poll(() => harness.pierreTreePath(targetFile.path)).not.toBeNull();
		const targetRow = harness.pierreTreePath(targetFile.path);
		expect(targetRow?.hasAttribute('data-item-selected')).toBe(true);
		expect(harness.expandedTreePaths().toSorted()).toEqual(expectedExpandedRecoveryTreePaths());
		expect(harness.pierreTreePath('Sources/RecoveryGroup01')?.getAttribute('aria-expanded')).toBe(
			'true',
		);
	});
	test('resets a fresh Review epoch fully expanded without replaying an old selection reveal', async () => {
		// Arrange
		const files = makeBridgeReviewRecoveryWitnessFiles({
			count: 6,
			lineCount: 3,
			markerPrefix: 'EPOCH_DISCLOSURE',
		});
		const targetFile = files[4];
		if (targetFile === undefined) throw new Error('Review epoch disclosure fixture is incomplete.');
		const harness = await renderBridgeReviewRecoveryWitness(files, {
			navigationCommand: reviewNavigationCommand('epoch-disclosure-command', targetFile.itemId),
		});
		await harness.publishDisplay();
		await expect.poll(() => harness.pierreTreePath(targetFile.path)).not.toBeNull();
		expect(harness.expandedTreePaths().toSorted()).toEqual(expectedExpandedRecoveryTreePaths());
		const initialSelectionScrollCount = harness.selectionScrollToPathSampleCount();

		// Act
		await harness.publishDisplayAtEpoch(2);

		// Assert
		expect(
			harness.expandedTreePaths().toSorted(),
			'Fresh Review epochs must not replay a stale selection-reveal request from the prior tree.',
		).toEqual(expectedExpandedRecoveryTreePaths());
		expect(harness.pierreTreePath('Sources')?.getAttribute('aria-expanded')).toBe('true');
		expect(harness.selectionScrollToPathSampleCount()).toBe(initialSelectionScrollCount);
	});
	test('does not replay an old selection reveal after a same-generation Review package replacement', async () => {
		// Arrange: Vite can replace package/source identity while retaining generation 1.
		const files = makeBridgeReviewRecoveryWitnessFiles({
			count: 6,
			lineCount: 3,
			markerPrefix: 'PACKAGE_DISCLOSURE',
		});
		const targetFile = files[4];
		if (targetFile === undefined)
			throw new Error('Review package disclosure fixture is incomplete.');
		const harness = await renderBridgeReviewRecoveryWitness(files, {
			navigationCommand: reviewNavigationCommand('package-disclosure-command', targetFile.itemId),
		});
		await harness.publishDisplay();
		await expect.poll(() => harness.pierreTreePath(targetFile.path)).not.toBeNull();
		expect(harness.expandedTreePaths().toSorted()).toEqual(expectedExpandedRecoveryTreePaths());
		const initialSelectionScrollCount = harness.selectionScrollToPathSampleCount();

		// Act: replace the package at the same worker generation without issuing new navigation.
		await harness.publishDisplayAtPackageIdentity('review-recovery-replacement-window');

		// Assert
		expect(
			harness.expandedTreePaths().toSorted(),
			'REVIEW_STALE_PACKAGE_REVEAL: a prior package reveal must not reselect an item after replacement.',
		).toEqual(expectedExpandedRecoveryTreePaths());
		expect(harness.pierreTreePath('Sources')?.getAttribute('aria-expanded')).toBe('true');
		expect(harness.selectionScrollToPathSampleCount()).toBe(initialSelectionScrollCount);
	});
	test('defers an inactive ready presentation and resets it after a fallback state', async () => {
		const readyPresentation = makeReadyReviewPresentationState('activation-review');
		const rendered = await renderInsideAct(
			<ReviewBoundaryActivationProbe readyPresentation={readyPresentation} />,
		);
		await expect
			.element(rendered.getByTestId('bridge-review-metadata-loading-shell'))
			.toBeVisible();

		await act(async (): Promise<void> => {
			await rendered.getByRole('button', { name: 'Show empty Review fallback' }).click();
		});

		await expect.element(rendered.getByTestId('bridge-review-empty-shell')).toBeVisible();

		// Act
		await act(async (): Promise<void> => {
			await rendered.getByRole('button', { name: 'Restore ready Review presentation' }).click();
		});

		// Assert
		await expect
			.element(rendered.getByTestId('bridge-review-metadata-loading-shell'))
			.toBeVisible();
	});
	test('keeps selection local-first and mark-viewed retries bounded across A to B to A', async () => {
		// Arrange
		const events: string[] = [];
		const rendered = await renderInsideAct(<ReviewSelectionControllerProbe events={events} />);

		// Act
		await act(async (): Promise<void> => {
			await rendered.getByRole('button', { name: 'Select unknown Review item' }).click();
		});

		// Assert
		expect(events).toEqual([]);

		// Act
		await act(async (): Promise<void> => {
			await rendered.getByRole('button', { name: 'Select Review item A' }).click();
		});
		await expect.poll(() => events.includes('mark:item-a:1')).toBe(true);

		// Assert
		expect(events.slice(0, 3)).toEqual(['local:item-a', 'intent:item-a:user', 'mark:item-a:1']);

		// Act
		await act(async (): Promise<void> => {
			await rendered.getByRole('button', { name: 'Select Review item A' }).click();
		});
		await expect.poll(() => events.includes('mark:item-a:2')).toBe(true);
		await act(async (): Promise<void> => {
			await rendered.getByRole('button', { name: 'Select Review item A' }).click();
			await Promise.resolve();
		});

		// Assert
		expect(events.filter((event) => event.startsWith('mark:item-a:'))).toHaveLength(2);

		// Act
		await act(async (): Promise<void> => {
			await rendered.getByRole('button', { name: 'Select Review item B' }).click();
		});
		await expect.poll(() => events.includes('mark:item-b:1')).toBe(true);
		await act(async (): Promise<void> => {
			await rendered.getByRole('button', { name: 'Select Review item A' }).click();
		});
		await expect.poll(() => events.includes('mark:item-a:3')).toBe(true);

		// Assert
		expect(events.filter((event) => event.startsWith('local:'))).toEqual([
			'local:item-a',
			'local:item-b',
			'local:item-a',
		]);
		expect(events.filter((event) => event.startsWith('intent:'))).toEqual([
			'intent:item-a:user',
			'intent:item-b:keyboard',
			'intent:item-a:user',
		]);
	});
	test('paints local Review selection before sending the typed worker intent', async () => {
		// Arrange
		const files = makeBridgeReviewRecoveryWitnessFiles({
			count: 3,
			lineCount: 3,
			markerPrefix: 'POST_PAINT',
		});
		const harness = await renderBridgeReviewRecoveryWitness(files);
		await harness.publishDisplay();
		await expect.poll(() => harness.selectedItemCommandCount()).toBe(1);
		await expect.poll(() => harness.markFileViewedCommandCount()).toBe(1);
		await expect.poll(() => harness.pierreTreePath('Sources/RecoveryGroup01')).not.toBeNull();
		const targetFile = files[1];
		if (targetFile === undefined) throw new Error('J1 REVIEW POST-PAINT FIXTURE MISSING');
		const targetRow = harness.pierreTreePath(targetFile.path);
		if (!(targetRow instanceof HTMLElement)) {
			throw new Error('J1 REVIEW POST-PAINT TARGET ROW MISSING');
		}
		const frameSamples: Array<{
			readonly selected: boolean;
			readonly selectCommandCount: number;
			readonly timestamp: number;
		}> = [];
		const requestAnimationFrameBeforeProof = globalThis.requestAnimationFrame;
		globalThis.requestAnimationFrame = (callback: FrameRequestCallback): number =>
			requestAnimationFrameBeforeProof((timestamp): void => {
				callback(timestamp);
				frameSamples.push({
					selected: targetRow.hasAttribute('data-item-selected'),
					selectCommandCount: harness.selectedItemCommandCount(),
					timestamp,
				});
			});

		try {
			// Act
			await act(async (): Promise<void> => {
				targetRow.click();
				await Promise.resolve();
			});

			// Assert: local Pierre selection is committed before any later-frame command.
			expect(targetRow.hasAttribute('data-item-selected')).toBe(true);
			await act(async (): Promise<void> => {
				await expect.poll(() => harness.selectedItemCommandCount()).toBe(2);
				await expect.poll(() => harness.markFileViewedCommandCount()).toBe(2);
			});
		} finally {
			globalThis.requestAnimationFrame = requestAnimationFrameBeforeProof;
		}

		// Assert: one selected frame precedes the distinct frame that publishes the intent.
		const selectedFrame = frameSamples.find(
			(sample): boolean => sample.selected && sample.selectCommandCount === 1,
		);
		expect(selectedFrame).toBeDefined();
		expect(
			frameSamples.some(
				(sample): boolean =>
					sample.selectCommandCount === 2 &&
					selectedFrame !== undefined &&
					sample.timestamp > selectedFrame.timestamp,
			),
		).toBe(true);
	});

	test('applies an explicit navigation command once without fallback overwriting it', async () => {
		// Arrange
		const events: string[] = [];
		const rendered = await renderInsideAct(<ReviewNavigationControllerProbe events={events} />);

		// Act
		await expect.poll(() => events.filter((event) => event.startsWith('select:')).length).toBe(1);

		// Assert
		expect(events).toEqual(['select:item-two:programmatic']);
		await expect
			.element(rendered.getByTestId('review-navigation-selection'))
			.toHaveTextContent('item-two');

		// Act
		await act(async (): Promise<void> => {
			await rendered.getByRole('button', { name: 'Advance Review catalog revision' }).click();
			await Promise.resolve();
		});

		// Assert
		expect(events.filter((event) => event.startsWith('select:'))).toHaveLength(1);

		// Act: a Filter projection excludes the current selection.
		await act(async (): Promise<void> => {
			await rendered.getByRole('button', { name: 'Filter selected Review item' }).click();
		});

		// Assert: selection clears without auto-selecting the remaining row.
		await expect.poll(() => events.includes('clear')).toBe(true);
		await expect
			.element(rendered.getByTestId('review-navigation-selection'))
			.toHaveTextContent('none');
		expect(events.filter((event) => event.startsWith('select:'))).toEqual([
			'select:item-two:programmatic',
		]);

		// Act
		await act(async (): Promise<void> => {
			await rendered.getByRole('button', { name: 'Navigate outside Review projection' }).click();
		});

		// Assert
		await expect.poll(() => events.includes('outside:item-missing')).toBe(true);
		expect(events.filter((event) => event.startsWith('select:'))).toEqual([
			'select:item-two:programmatic',
		]);
	});

	test('renders every ready Review item in one continuous Pierre CodeView', async () => {
		// Arrange
		const files = makeBridgeReviewRecoveryWitnessFiles({
			count: 3,
			lineCount: 3,
			markerPrefix: 'CONTINUOUS',
		});
		const harness = await renderBridgeReviewRecoveryWitness(files);
		await expect
			.element(harness.renderResult.getByTestId('bridge-review-fallback-frame'))
			.toBeVisible();

		// Act
		await harness.publishDisplay();
		await expect.poll(() => harness.selectedItemCommandCount()).toBe(1);
		await harness.publishCompleteContent();
		await expect
			.element(harness.renderResult.getByTestId('review-viewer-shell'))
			.toHaveAttribute('data-selected-content-state', 'ready');
		await advanceBridgeReviewRecoveryWitnessFrames(3);

		// Assert
		const renderedCodeText = harness.codeText();
		expect(renderedCodeText).toContain(files[0]?.contentMarker);
		expect(
			renderedCodeText,
			'G0 REVIEW CONTINUOUS DOCUMENT MISSING: expected one production Pierre CodeView to contain every ready Review item; selected-only rendering omitted middle/final content.',
		).toContain(files[1]?.contentMarker);
		expect(renderedCodeText).toContain(files[2]?.contentMarker);
	});

	test('stamps source correlation after ordinary Review publication reaches Pierre paint', async () => {
		// Arrange
		const fixtureFile = makeBridgeReviewRecoveryWitnessFiles({
			count: 1,
			lineCount: 3,
			markerPrefix: 'PAINT_CORRELATION',
		})[0];
		if (fixtureFile === undefined) throw new Error('Review paint-correlation fixture is missing.');
		const sourceCorrelation = {
			descriptorId: 'review-paint-correlation-descriptor',
			itemId: fixtureFile.itemId,
			observedSha256: 'a'.repeat(64),
			position: 'whole',
			requestId: 'review-paint-correlation-request',
			role: 'head',
			sourceGeneration: 1,
			sourceIdentity: 'review-paint-correlation-source',
		} satisfies BridgeWorkerRenderSourceCorrelation;
		const harness = await renderBridgeReviewRecoveryWitness([
			{ ...fixtureFile, sourceCorrelation },
		]);

		// Act
		await harness.publishDisplay();
		await harness.publishContentForItemIds([fixtureFile.itemId]);
		await expect.poll(() => harness.paintedSourceCorrelationElements()).toHaveLength(1);

		// Assert
		const [paintedElement] = harness.paintedSourceCorrelationElements();
		expect(paintedElement?.isConnected).toBe(true);
		const encodedSourceCorrelations = paintedElement?.getAttribute(
			'data-bridge-painted-source-correlations',
		);
		const paintedPublicationId = paintedElement?.getAttribute('data-bridge-painted-publication-id');
		expect(encodedSourceCorrelations).not.toBeNull();
		expect(paintedPublicationId).not.toBeNull();
		expect(
			paintedElement === undefined ? '' : harness.paintedSourceCorrelationText(paintedElement),
		).toContain(fixtureFile.contentMarker);
		const decodedSourceCorrelations: unknown = JSON.parse(encodedSourceCorrelations ?? 'null');
		expect(decodedSourceCorrelations).toEqual([
			{
				...sourceCorrelation,
				disposition: 'painted',
				pierreItemId: fixtureFile.itemId,
				publicationId: paintedPublicationId,
				semanticItemId: fixtureFile.itemId,
				surface: 'review',
			},
		]);
	});

	test('appends streamed Review metadata into continuous projection order without tree clicks', async () => {
		// Arrange
		const files = makeBridgeReviewRecoveryWitnessFiles({
			count: 3,
			lineCount: 3,
			markerPrefix: 'STREAMED_CONTINUOUS',
		});
		const harness = await renderBridgeReviewRecoveryWitness(files);
		await expect
			.element(harness.renderResult.getByTestId('bridge-review-fallback-frame'))
			.toBeVisible();

		// Act
		await harness.publishDisplayInTwoBatches(1);
		await expect.poll(() => harness.selectedItemCommandCount()).toBe(1);
		await expect.poll(() => harness.pierreTreePath('Sources/RecoveryGroup01')).not.toBeNull();
		expect(harness.pierreTreePath(files[0]?.path ?? '')).not.toBeNull();
		await harness.publishCompleteContent();
		await expect
			.element(harness.renderResult.getByTestId('review-viewer-shell'))
			.toHaveAttribute('data-selected-content-state', 'ready');
		await advanceBridgeReviewRecoveryWitnessFrames(4);

		// Assert
		const renderedCodeText = harness.codeText();
		for (const file of files) expect(renderedCodeText).toContain(file.contentMarker);
		expect(harness.selectedItemCommandCount()).toBe(1);
	});

	test('opens streamed directories while preserving an explicit manual collapse', async () => {
		// Arrange
		const files = makeBridgeReviewRecoveryWitnessFiles({
			count: 6,
			lineCount: 3,
			markerPrefix: 'STREAMED_DISCLOSURE',
		});
		const harness = await renderBridgeReviewRecoveryWitness(files);

		// Act
		await harness.publishDisplayPrefix(3);
		const firstGroupDirectory = harness.pierreTreePath('Sources/RecoveryGroup01');
		if (!(firstGroupDirectory instanceof HTMLElement)) {
			throw new Error('J1 REVIEW DISCLOSURE FIXTURE MISSING');
		}
		await act(async (): Promise<void> => {
			firstGroupDirectory.click();
			await Promise.resolve();
		});
		await advanceBridgeReviewRecoveryWitnessFrames(2);
		expect(firstGroupDirectory.getAttribute('aria-expanded')).toBe('false');

		await harness.publishDisplayAppendFrom(3);

		// Assert
		const sourceDirectory = harness.pierreTreePath('Sources');
		expect(
			sourceDirectory,
			'J1 REVIEW DISCLOSURE DRIFT: streamed sibling metadata must retain the explicit root directory instead of a stale flattened prefix.',
		).not.toBeNull();
		expect(sourceDirectory?.getAttribute('aria-expanded')).toBe('true');
		expect(harness.pierreTreePath('Sources/RecoveryGroup01')?.getAttribute('aria-expanded')).toBe(
			'false',
		);
		expect(harness.pierreTreePath(files[0]?.path ?? '')).toBeNull();
		expect(harness.pierreTreePath('Sources/RecoveryGroup02')?.getAttribute('aria-expanded')).toBe(
			'true',
		);
		expect(harness.pierreTreePath(files[5]?.path ?? '')).not.toBeNull();
	});
});

function reviewFacetOptionContaining(text: string): HTMLElement {
	const option = [
		...document.querySelectorAll<HTMLElement>('[data-testid="bridge-review-facet-option"]'),
	].find((candidate): boolean => candidate.textContent?.includes(text) ?? false);
	if (option === undefined) throw new Error(`Expected Review facet option containing ${text}.`);
	return option;
}

function requireReviewHTMLElement(element: Element | null): HTMLElement {
	if (!(element instanceof HTMLElement)) throw new Error('Expected a real Review browser element.');
	return element;
}

function mountedReviewTreePaths(treeHost: HTMLElement | null): readonly string[] {
	if (treeHost?.shadowRoot === null || treeHost?.shadowRoot === undefined) return [];
	return [...treeHost.shadowRoot.querySelectorAll<HTMLElement>('[data-item-path]')]
		.map((row): string => row.dataset['itemPath']?.replace(/\/$/u, '') ?? '')
		.filter((path): boolean => path.length > 0)
		.filter((path, index, paths): boolean => paths.indexOf(path) === index)
		.toSorted();
}

function expectedExpandedRecoveryTreePaths(): readonly string[] {
	return ['Sources', 'Sources/RecoveryGroup01', 'Sources/RecoveryGroup02'];
}

function ReviewBoundaryActivationProbe(props: {
	readonly readyPresentation: BridgeReviewViewerPresentationState;
}): ReactElement {
	const [presentationState, setPresentationState] = useState<BridgeReviewViewerPresentationState>(
		props.readyPresentation,
	);
	return (
		<>
			<button onClick={(): void => setPresentationState({ status: 'noTarget' })} type="button">
				Show empty Review fallback
			</button>
			<button onClick={(): void => setPresentationState(props.readyPresentation)} type="button">
				Restore ready Review presentation
			</button>
			<BridgeReviewViewerShellBoundary
				comparisonPaneState={{ kind: 'settled' }}
				isActive={false}
				onRetryComparison={(): void => {}}
				presentationState={presentationState}
				viewerContextSwitcher={<div>Context switcher</div>}
				viewerHeaderControls={<div>Review controls</div>}
			/>
		</>
	);
}

function ReviewSelectionControllerProbe(props: { readonly events: string[] }): ReactElement {
	const [selectedItemId, setSelectedItemId] = useState<string | null>(null);
	const markAttemptsByItemIdRef = useRef<Record<string, number>>({});
	const commitLocalSelection = useCallback(
		(itemId: string): void => {
			props.events.push(`local:${itemId}`);
			setSelectedItemId(itemId);
		},
		[props.events],
	);
	const emitSelectIntent = useCallback(
		(itemId: string, selectedSource: BridgeReviewSelectionSource): void => {
			props.events.push(`intent:${itemId}:${selectedSource}`);
		},
		[props.events],
	);
	const markFileViewed = useCallback(
		(itemId: string): boolean => {
			const nextAttempt = (markAttemptsByItemIdRef.current[itemId] ?? 0) + 1;
			markAttemptsByItemIdRef.current[itemId] = nextAttempt;
			props.events.push(`mark:${itemId}:${nextAttempt}`);
			return itemId !== 'item-a' || nextAttempt !== 1;
		},
		[props.events],
	);
	const controller = useBridgeReviewSelectionController({
		commitLocalSelection,
		emitSelectIntent,
		hasReviewItem: (itemId): boolean => itemId === 'item-a' || itemId === 'item-b',
		isActive: true,
		markFileViewed,
		selectedItemId,
		telemetryRecorderRef: disabledBridgeTelemetryRecorderRef,
	});
	return (
		<>
			<button onClick={(): void => void controller.selectReviewItem('item-a')} type="button">
				Select Review item A
			</button>
			<button
				onClick={(): void => void controller.selectReviewItem('item-b', 'keyboard')}
				type="button"
			>
				Select Review item B
			</button>
			<button onClick={(): void => void controller.selectReviewItem('item-missing')} type="button">
				Select unknown Review item
			</button>
		</>
	);
}

function makeReadyReviewPresentationState(
	presentationKey: string,
): BridgeReviewViewerPresentationState {
	const reviewPackage = makeBridgeReviewPackage();
	return {
		presentationKey,
		shellProps: {
			comparisonPaneState: { kind: 'settled' },
			facetMenuOpen: false,
			onRetryComparison: (): void => {},
			onFacetMenuOpenChange: (): void => {},
			onSelectItem: (): void => {},
			panelChromeSlice: {},
			presentationPositionKey: `browser-review-position:${presentationKey}`,
			presentationRegistry: createBridgeReviewItemRegistry({ reviewPackage }),
			projection: buildBridgeReviewProjection({
				reviewPackage,
				request: { facets: [], mode: { kind: 'normalReview' } },
			}),
			renderFulfillmentCoordinator: readyPresentationRenderFulfillmentCoordinator,
			reviewPackage,
			selectedItemId: null,
		},
		status: 'ready',
	};
}

async function renderInsideAct(element: ReactElement): Promise<RenderResult> {
	let rendered: RenderResult | null = null;
	await act(async (): Promise<void> => {
		rendered = await render(element);
		await Promise.resolve();
	});
	return requireRenderResult(rendered);
}

function requireRenderResult(rendered: RenderResult | null): RenderResult {
	if (rendered === null) throw new Error('Expected Browser render result.');
	return rendered;
}
