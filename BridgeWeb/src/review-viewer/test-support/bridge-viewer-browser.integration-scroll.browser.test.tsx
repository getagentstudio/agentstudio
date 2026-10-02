import { act } from 'react';
import { afterEach, describe, expect, test } from 'vitest';
import { cleanup } from 'vitest-browser-react';

// oxlint-disable-next-line import/no-unassigned-import -- Browser Mode must load production app CSS.
import '../../app/bridge-app.css';
import {
	scrollBridgeReviewRecoveryWitnessTo,
	waitForBridgeReviewRecoveryDomState,
} from './bridge-review-recovery-dom-state.test-support.js';
import {
	disposeBridgeReviewRecoveryWitnessHarnesses,
	makeBridgeReviewRecoveryWitnessFiles,
	renderBridgeReviewRecoveryWitness,
	scanBridgeReviewRecoveryWitnessDocument,
} from './bridge-viewer-browser.recovery-witness.test-support.js';

describe('Bridge Review sustained deep-scroll Browser witness', () => {
	afterEach(async (): Promise<void> => {
		await act(async (): Promise<void> => {
			await cleanup();
			disposeBridgeReviewRecoveryWitnessHarnesses();
		});
		document.body.replaceChildren();
	});

	test('keeps one continuous Review document painted through deep scrolling', async () => {
		// Arrange
		const files = makeBridgeReviewRecoveryWitnessFiles({
			count: 27,
			lineCount: 64,
			markerPrefix: 'DEEP_SCROLL',
		});
		const earlyFile = files[0];
		const middleFile = files[Math.floor(files.length / 2)];
		const finalFile = files.at(-1);
		if (earlyFile === undefined || middleFile === undefined || finalFile === undefined) {
			throw new Error('Deep-scroll Review recovery witness requires traversal markers.');
		}
		const harness = await renderBridgeReviewRecoveryWitness(files);
		await expect
			.element(harness.renderResult.getByTestId('bridge-review-fallback-frame'))
			.toBeVisible();

		// Act
		await harness.publishDisplay();
		await waitForBridgeReviewRecoveryDomState({
			readState: harness.selectedItemCommandCount,
			isExpected: (count): boolean => count === 1,
		});
		await expect
			.element(harness.renderResult.getByTestId('bridge-code-view-panel'))
			.toHaveAttribute('data-code-view-item-count', String(files.length));
		await waitForBridgeReviewRecoveryDomState({
			readState: harness.codeScrollOwner,
			isExpected: (owner): boolean => owner !== null,
		});
		const scrollOwner = harness.codeScrollOwner();
		if (scrollOwner === null) throw new Error('Production Review CodeView has no scroll owner.');
		const scrollTopBeforeHydration = scrollOwner.scrollTop;
		await harness.publishCompleteContent();
		await expect
			.element(harness.renderResult.getByTestId('review-viewer-shell'))
			.toHaveAttribute('data-selected-content-state', 'ready');
		await waitForBridgeReviewRecoveryDomState({
			readState: (): string => harness.visibleCodeText(scrollOwner),
			isExpected: (text): boolean =>
				scrollOwner.scrollHeight > scrollOwner.clientHeight &&
				text.includes(earlyFile.contentMarker),
		});
		const initialVisibleText = harness.visibleCodeText(scrollOwner);
		if (!initialVisibleText.includes(earlyFile.contentMarker)) {
			const codePanel = harness.renderResult.container.querySelector(
				'[data-testid="bridge-code-view-panel"]',
			);
			throw new Error(
				`initial hydration anchor diagnostic=${JSON.stringify({
					selectedInitialItemIndex: codePanel?.getAttribute('data-selected-initial-item-index'),
					selectedInitialItemIsFirst: codePanel?.getAttribute(
						'data-selected-initial-item-is-first',
					),
					selectedItemId: codePanel?.getAttribute('data-selected-item-id'),
					selectionScrollDidScroll: codePanel?.getAttribute('data-selection-scroll-did-scroll'),
					selectionScrollItemTop: codePanel?.getAttribute('data-selection-scroll-item-top'),
					selectionScrollReason: codePanel?.getAttribute('data-selection-scroll-reason'),
					scrollTopAfterHydration: scrollOwner.scrollTop,
					scrollTopBeforeHydration,
					visibleTextPrefix: initialVisibleText.slice(0, 240),
				})}`,
			);
		}
		const scan = await scanBridgeReviewRecoveryWitnessDocument({
			markerItemIds: [earlyFile.itemId, middleFile.itemId, finalFile.itemId],
			markers: [earlyFile.contentMarker, middleFile.contentMarker, finalFile.contentMarker],
			orderedItemIds: files.map((file): string => file.itemId),
			sampleCount: 25,
			scrollOwner,
			visibleItemIds: (): readonly string[] => {
				const viewportBounds = scrollOwner.getBoundingClientRect();
				return harness
					.paintedCodeViewItems()
					.filter(
						(paintedItem): boolean =>
							paintedItem.bottom > viewportBounds.top && paintedItem.top < viewportBounds.bottom,
					)
					.map((paintedItem): string => paintedItem.itemId);
			},
			visibleCodeText: harness.visibleCodeText,
		});

		// Assert
		const scanDiagnostic = {
			blankPaintSampleCount: scan.blankPaintSampleCount,
			didObserveFinal: scan.observedMarkers.has(finalFile.contentMarker),
			didObserveMiddle: scan.observedMarkers.has(middleFile.contentMarker),
			markerConvergenceSamples: scan.markerConvergenceSamples,
			maximumScrollTop: scan.maximumScrollTop,
		};
		expect(
			scan.maximumScrollTop > 0 &&
				scan.blankPaintSampleCount === 0 &&
				scan.observedMarkers.has(middleFile.contentMarker) &&
				scan.observedMarkers.has(finalFile.contentMarker),
			`G0 REVIEW DEEP SCROLL MISSING: expected sustained scrolling to reach final Review source while the continuous Pierre CodeView stayed painted; diagnostic=${JSON.stringify(scanDiagnostic)}`,
		).toBe(true);
		expect(scan.sampleCount - scan.convergenceSampleCount).toBe(25);
	});

	test('republishes the retained Review window when the viewer becomes active again', async () => {
		// Arrange: settle one metadata-only Review window with a selected header and at least one
		// visible nonselected header. No body content has been published yet.
		const files = makeBridgeReviewRecoveryWitnessFiles({
			count: 48,
			lineCount: 8,
			markerPrefix: 'REACTIVATED_VISIBLE_HYDRATION',
		});
		const harness = await renderBridgeReviewRecoveryWitness(files);
		await harness.publishDisplay();
		await waitForBridgeReviewRecoveryDomState({
			readState: harness.selectedItemCommandCount,
			isExpected: (count): boolean => count === 1,
		});
		await waitForBridgeReviewRecoveryDomState({
			readState: harness.renderedCodeViewItemIds,
			isExpected: (itemIds): boolean => itemIds.length > 1,
		});
		await waitForBridgeReviewRecoveryDomState({
			readState: harness.viewportCommandVisibleItemIds,
			isExpected: (windows): boolean => windows.some((itemIds): boolean => itemIds.length > 0),
		});
		const codePanel = harness.renderResult.container.querySelector(
			'[data-testid="bridge-code-view-panel"]',
		);
		const selectedItemId = codePanel?.getAttribute('data-selected-item-id') ?? null;
		const scrollOwner = harness.codeScrollOwner();
		if (selectedItemId === null || scrollOwner === null) {
			throw new Error('Review reactivation witness requires selected and scroll-owner state.');
		}
		const selectedItemCommandCountBeforeTransition = harness.selectedItemCommandCount();
		const scrollTopBeforeTransition = scrollOwner.scrollTop;
		const viewportCommandCountBeforeTransition = harness.viewportCommandVisibleItemIds().length;

		// Act: only hide and show the already-mounted Review. Do not scroll, select, or replace metadata.
		await harness.setActive(false);
		const viewportCommandsAfterHide = harness.viewportCommandVisibleItemIds();
		expect(viewportCommandsAfterHide.slice(viewportCommandCountBeforeTransition)).toEqual([[]]);
		await harness.setActive(true);
		await waitForBridgeReviewRecoveryDomState({
			readState: harness.viewportCommandVisibleItemIds,
			isExpected: (windows): boolean => windows.length > viewportCommandsAfterHide.length,
		});

		// Assert: activation republishes the retained Pierre window after the exact inactive clear.
		const transitionViewportCommands = harness
			.viewportCommandVisibleItemIds()
			.slice(viewportCommandCountBeforeTransition);
		const activationVisibleItemIds = transitionViewportCommands[1] ?? [];
		const renderedItemIdsAfterActivation = [...new Set(harness.renderedCodeViewItemIds())];
		const visibleNonselectedItemId = renderedItemIdsAfterActivation.find(
			(itemId): boolean => itemId !== selectedItemId && activationVisibleItemIds.includes(itemId),
		);
		const transitionTrace = {
			activationVisibleItemIds,
			renderedItemIdsAfterActivation,
			selectedItemId,
			transitionViewportCommands,
		};
		expect(transitionViewportCommands, JSON.stringify(transitionTrace)).toHaveLength(2);
		expect(transitionViewportCommands[0], JSON.stringify(transitionTrace)).toEqual([]);
		expect(activationVisibleItemIds.length, JSON.stringify(transitionTrace)).toBeGreaterThan(0);
		expect(
			renderedItemIdsAfterActivation.every((itemId): boolean =>
				activationVisibleItemIds.includes(itemId),
			),
			JSON.stringify(transitionTrace),
		).toBe(true);
		expect(visibleNonselectedItemId, JSON.stringify(transitionTrace)).toBeDefined();
		expect(harness.selectedItemCommandCount()).toBe(selectedItemCommandCountBeforeTransition);
		expect(scrollOwner.scrollTop).toBe(scrollTopBeforeTransition);
		expect(codePanel?.getAttribute('data-code-view-item-count')).toBe(String(files.length));

		const publishedItemIds = await harness.publishDemandedContent();
		expect(publishedItemIds).toContain(visibleNonselectedItemId);
		const visibleNonselectedPaint = harness
			.paintedCodeViewItems()
			.find((paintedItem) => paintedItem.itemId === visibleNonselectedItemId);
		expect(
			visibleNonselectedPaint?.paintedLineCount,
			JSON.stringify(transitionTrace),
		).toBeGreaterThan(0);
	});

	test('retains Review selection disclosure and scroll across an inactive generation replacement', async () => {
		// Arrange: mount the production Review shell, Pierre tree, and continuous CodeView over one
		// stable worker-facing client/store identity.
		const files = makeBridgeReviewRecoveryWitnessFiles({
			count: 18,
			lineCount: 48,
			markerPrefix: 'HIDDEN_GENERATION_POSITION',
		});
		const selectedFile = files[4];
		if (selectedFile === undefined) {
			throw new Error('Hidden-generation Review fixture requires a selected item.');
		}
		const harness = await renderBridgeReviewRecoveryWitness(files);
		await harness.publishDisplay();
		await harness.publishCompleteContent();
		await waitForBridgeReviewRecoveryDomState({
			readState: harness.selectedItemCommandCount,
			isExpected: (count): boolean => count === 1,
		});
		await waitForBridgeReviewRecoveryDomState({
			readState: harness.codeScrollOwner,
			isExpected: (owner): boolean => owner !== null,
		});

		const selectedTreeRow = await harness.scrollTreePathIntoView(selectedFile.path);
		await act(async (): Promise<void> => {
			selectedTreeRow.click();
			await Promise.resolve();
		});
		await waitForBridgeReviewRecoveryDomState({
			readState: (): string | null | undefined =>
				harness.renderResult.container
					.querySelector('[data-testid="bridge-code-view-panel"]')
					?.getAttribute('data-selected-item-id'),
			isExpected: (itemId): boolean => itemId === selectedFile.itemId,
		});

		const collapsedDirectoryPath = 'Sources/RecoveryGroup01';
		const collapsedDirectory = await harness.scrollTreePathIntoView(collapsedDirectoryPath);
		await act(async (): Promise<void> => {
			collapsedDirectory.click();
			await Promise.resolve();
		});
		await waitForBridgeReviewRecoveryDomState({
			readState: (): string | null | undefined =>
				harness.pierreTreePath(collapsedDirectoryPath)?.getAttribute('aria-expanded'),
			isExpected: (expanded): boolean => expanded === 'false',
		});

		const scrollOwnerBeforeReplacement = harness.codeScrollOwner();
		const treeHostBeforeReplacement = harness.pierreTreeHost();
		if (scrollOwnerBeforeReplacement === null || treeHostBeforeReplacement === null) {
			throw new Error('Hidden-generation Review fixture requires mounted Pierre surfaces.');
		}
		await waitForBridgeReviewRecoveryDomState({
			readState: (): boolean =>
				scrollOwnerBeforeReplacement.scrollHeight > scrollOwnerBeforeReplacement.clientHeight,
			isExpected: (scrollable): boolean => scrollable,
		});
		await act(async (): Promise<void> => {
			scrollOwnerBeforeReplacement.dispatchEvent(
				new WheelEvent('wheel', {
					bubbles: true,
					deltaY: scrollOwnerBeforeReplacement.clientHeight,
				}),
			);
		});
		await scrollBridgeReviewRecoveryWitnessTo({
			scrollOwner: scrollOwnerBeforeReplacement,
			scrollTop: Math.floor(
				(scrollOwnerBeforeReplacement.scrollHeight - scrollOwnerBeforeReplacement.clientHeight) *
					0.72,
			),
		});
		const metadataRevisionBeforeReplacement = Number(
			harness.renderResult.container
				.querySelector('[data-testid="review-viewer-shell"]')
				?.getAttribute('data-review-metadata-revision'),
		);
		if (
			!Number.isInteger(metadataRevisionBeforeReplacement) ||
			metadataRevisionBeforeReplacement < 1
		) {
			throw new Error('Hidden-generation Review fixture has no accepted metadata revision.');
		}
		const positionBeforeReplacement = await waitForSettledReviewPosition({
			expectedItemCount: files.length,
			expectedMetadataRevision: metadataRevisionBeforeReplacement,
			expectedSelectedItemId: selectedFile.itemId,
			harness,
			scrollOwner: scrollOwnerBeforeReplacement,
		});
		const {
			maximumScrollTop: maximumScrollTopBeforeReplacement,
			rawScrollTop: rawScrollTopBeforeReplacement,
			semanticAnchor: semanticAnchorBeforeReplacement,
		} = positionBeforeReplacement;
		expect(rawScrollTopBeforeReplacement).toBeGreaterThan(0);

		// Act: loaded-hidden is represented at this browser seam by inactive Review. The same client
		// and store accept a new authoritative generation while body work remains out of scope.
		await harness.setActive(false);
		await harness.publishDisplayAtEpoch(2);

		// Observe the inactive state before returning. The final assertion reports every lost position
		// together so a fallback failure cannot hide subsequent tree or CodeView losses.
		const inactiveFallbackWasShown =
			harness.renderResult.container.querySelector(
				'[data-testid="bridge-review-projection-pending-shell"]',
			) !== null;
		const treeRemainedMountedWhileInactive = treeHostBeforeReplacement.isConnected;
		const codeViewRemainedMountedWhileInactive = scrollOwnerBeforeReplacement.isConnected;

		await harness.setActive(true);
		await expect.element(harness.renderResult.getByTestId('review-viewer-shell')).toBeVisible();
		const scrollOwnerAfterReplacement = harness.codeScrollOwner();
		if (scrollOwnerAfterReplacement === null) {
			throw new Error('Hidden-generation Review replacement lost its CodeView scroll owner.');
		}
		const positionAfterReplacement = await waitForSettledReviewPosition({
			expectedItemCount: files.length,
			expectedMetadataRevision: metadataRevisionBeforeReplacement + 1,
			expectedSelectedItemId: selectedFile.itemId,
			harness,
			scrollOwner: scrollOwnerAfterReplacement,
		});

		// Assert: no fallback/remount occurred and selection, explicit disclosure, and the same
		// virtualized scroll region survived the generation replacement.
		const selectedItemIdAfterReplacement =
			harness.renderResult.container
				.querySelector('[data-testid="bridge-code-view-panel"]')
				?.getAttribute('data-selected-item-id') ?? null;
		const disclosureAfterReplacement = harness
			.pierreTreePath(collapsedDirectoryPath)
			?.getAttribute('aria-expanded');
		const codePanelAfterReplacement = harness.renderResult.container.querySelector(
			'[data-testid="bridge-code-view-panel"]',
		);
		const {
			maximumScrollTop: maximumScrollTopAfterReplacement,
			rawScrollTop: rawScrollTopAfterReplacement,
			semanticAnchor: semanticAnchorAfterReplacement,
		} = positionAfterReplacement;
		const semanticAnchorRankBeforeReplacement = files.findIndex(
			(file): boolean => file.itemId === semanticAnchorBeforeReplacement.itemId,
		);
		const semanticAnchorRankAfterReplacement = files.findIndex(
			(file): boolean => file.itemId === semanticAnchorAfterReplacement.itemId,
		);
		const rawScrollCoordinateRetained =
			Math.abs(rawScrollTopAfterReplacement - rawScrollTopBeforeReplacement) <= 1;
		const semanticViewportAnchorRetained =
			semanticAnchorAfterReplacement.itemId === semanticAnchorBeforeReplacement.itemId &&
			Math.abs(
				semanticAnchorAfterReplacement.viewportOffsetPixels -
					semanticAnchorBeforeReplacement.viewportOffsetPixels,
			) <= 1;
		const retentionDiagnostic = {
			codeViewRemainedMountedWhileInactive,
			codeViewRetainedIdentity: scrollOwnerAfterReplacement === scrollOwnerBeforeReplacement,
			disclosureAfterReplacement: disclosureAfterReplacement ?? null,
			inactiveFallbackWasShown,
			maximumScrollTopAfterReplacement,
			maximumScrollTopBeforeReplacement,
			rawScrollTopAfterReplacement,
			rawScrollTopBeforeReplacement,
			selectedItemIdAfterReplacement,
			selectionScrollDidScroll:
				codePanelAfterReplacement?.getAttribute('data-selection-scroll-did-scroll') ?? null,
			selectionScrollReason:
				codePanelAfterReplacement?.getAttribute('data-selection-scroll-reason') ?? null,
			semanticAnchorAfterReplacement,
			semanticAnchorBeforeReplacement,
			treeRemainedMountedWhileInactive,
			treeRetainedIdentity: harness.pierreTreeHost() === treeHostBeforeReplacement,
		};
		expect(
			{
				codeViewRemainedMountedWhileInactive,
				codeViewRetainedIdentity: retentionDiagnostic.codeViewRetainedIdentity,
				disclosureRetained: disclosureAfterReplacement === 'false',
				inactiveFallbackWasShown,
				scrollPositionRetained:
					rawScrollTopAfterReplacement > 0 &&
					(rawScrollCoordinateRetained || semanticViewportAnchorRetained),
				selectedItemRetained: selectedItemIdAfterReplacement === selectedFile.itemId,
				semanticScrollRegionRetained:
					semanticAnchorRankBeforeReplacement >= 0 &&
					semanticAnchorRankAfterReplacement >= 0 &&
					Math.abs(semanticAnchorRankAfterReplacement - semanticAnchorRankBeforeReplacement) <= 1,
				treeRemainedMountedWhileInactive,
				treeRetainedIdentity: retentionDiagnostic.treeRetainedIdentity,
			},
			`R68 REVIEW POSITION LOST: inactive generation replacement must preserve the mounted Review presentation and its independent position; diagnostic=${JSON.stringify(retentionDiagnostic)}`,
		).toEqual({
			codeViewRemainedMountedWhileInactive: true,
			codeViewRetainedIdentity: true,
			disclosureRetained: true,
			inactiveFallbackWasShown: false,
			scrollPositionRetained: true,
			selectedItemRetained: true,
			semanticScrollRegionRetained: true,
			treeRemainedMountedWhileInactive: true,
			treeRetainedIdentity: true,
		});
	});
});

interface SettledReviewPositionReceipt {
	readonly maximumScrollTop: number;
	readonly rawScrollTop: number;
	readonly semanticAnchor: {
		readonly itemId: string;
		readonly viewportOffsetPixels: number;
	};
}

async function waitForSettledReviewPosition(props: {
	readonly expectedItemCount: number;
	readonly expectedMetadataRevision: number;
	readonly expectedSelectedItemId: string;
	readonly harness: Awaited<ReturnType<typeof renderBridgeReviewRecoveryWitness>>;
	readonly scrollOwner: HTMLElement;
}): Promise<SettledReviewPositionReceipt> {
	const observedPosition = await waitForBridgeReviewRecoveryDomState({
		readState: (): SettledReviewPositionReceipt | null => {
			const reviewShell = props.harness.renderResult.container.querySelector(
				'[data-testid="review-viewer-shell"]',
			);
			const codePanel = props.harness.renderResult.container.querySelector(
				'[data-testid="bridge-code-view-panel"]',
			);
			const semanticAnchor = firstVisibleReviewAnchor(props.harness, props.scrollOwner);
			if (
				reviewShell?.getAttribute('data-review-metadata-revision') !==
					String(props.expectedMetadataRevision) ||
				codePanel?.getAttribute('data-code-view-item-count') !== String(props.expectedItemCount) ||
				codePanel?.getAttribute('data-selected-item-id') !== props.expectedSelectedItemId ||
				semanticAnchor === null ||
				(props.harness
					.paintedCodeViewItems()
					.find((item): boolean => item.itemId === semanticAnchor.itemId)?.paintedLineCount ??
					0) === 0
			)
				return null;
			return {
				maximumScrollTop: Math.max(
					props.scrollOwner.scrollHeight - props.scrollOwner.clientHeight,
					1,
				),
				rawScrollTop: props.scrollOwner.scrollTop,
				semanticAnchor,
			};
		},
		isExpected: (position): boolean => position !== null,
	});
	if (observedPosition === null)
		throw new Error('Expected exact Review revision, manifest, and painted anchor.');
	return observedPosition;
}

function firstVisibleReviewAnchor(
	harness: Awaited<ReturnType<typeof renderBridgeReviewRecoveryWitness>>,
	scrollOwner: HTMLElement,
): { readonly itemId: string; readonly viewportOffsetPixels: number } | null {
	const viewportBounds = scrollOwner.getBoundingClientRect();
	const firstVisibleItem = harness
		.paintedCodeViewItems()
		.filter(
			(paintedItem): boolean =>
				paintedItem.bottom > viewportBounds.top && paintedItem.top < viewportBounds.bottom,
		)
		.toSorted((left, right): number => left.top - right.top)[0];
	return firstVisibleItem === undefined
		? null
		: {
				itemId: firstVisibleItem.itemId,
				viewportOffsetPixels: firstVisibleItem.top - viewportBounds.top,
			};
}
