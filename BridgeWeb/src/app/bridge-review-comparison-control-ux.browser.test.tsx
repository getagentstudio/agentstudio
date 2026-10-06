import { createRef, type ReactElement } from 'react';
import { describe, expect, test, vi } from 'vitest';
import { render } from 'vitest-browser-react';
import { page } from 'vitest/browser';

// oxlint-disable-next-line import/no-unassigned-import -- Browser Mode must load production CSS.
import './bridge-app.css';
import type { BridgeProductReviewComparisonTargetCatalog } from '../core/comm-worker/bridge-product-review-comparison-contracts.js';
import { makeBridgeReviewPackage } from '../foundation/review-package/bridge-review-package-test-support.js';
import type { BridgeReviewPackage } from '../foundation/review-package/bridge-review-package.js';
import { BridgeReviewComparisonBranchSelector } from './bridge-review-comparison-branch-selector.js';
import {
	BridgeReviewComparisonControlTestHost as BridgeReviewComparisonControl,
	performComparisonAction,
} from './bridge-review-comparison-control.browser.test-support.js';

type ReviewComparisonTargetCatalog = BridgeProductReviewComparisonTargetCatalog;

describe('BridgeReviewComparisonControl UX Browser Mode', () => {
	test('closes through the standard header action and restores trigger focus', async () => {
		const cancelTargetQuery = vi.fn();
		const rendered = await renderComparisonTargetPicker({ cancelTargetQuery });
		const trigger = rendered.getByTestId('bridge-review-comparison-trigger');
		await performComparisonAction(async (): Promise<void> => {
			await trigger.click();
		});
		const close = rendered.getByRole('button', { name: 'Close Compare', exact: true });
		expect(close.element().getBoundingClientRect().height).toBe(24);
		await performComparisonAction(async (): Promise<void> => {
			await close.click();
		});
		expect(cancelTargetQuery).toHaveBeenCalledTimes(1);
		await expect.element(trigger).toHaveFocus();
		await expect
			.element(rendered.getByTestId('bridge-review-comparison-content'))
			.not.toBeInTheDocument();
	});
	test('presents the current branch and one effective comparison commit as a compact hierarchy', async () => {
		// Arrange
		const symbolicTarget = {
			basis: 'commonCommit',
			kind: 'ref',
			name: 'origin/journey-integration',
		} as const;
		const baseReviewPackage = makeBridgeReviewPackage();
		const reviewPackage: BridgeReviewPackage = {
			...baseReviewPackage,
			comparisonOrigin: {
				baseOID: 'b'.repeat(40),
				baseRole: 'commonCommit',
				comparedRole: 'capturedWorkingTree',
				kind: 'contribution',
				resolvedTargetOID: `51d3e39cffa1${'0'.repeat(28)}`,
				reviewedHeadOID: 'h'.repeat(40),
				reviewedSubjectBranchName: null,
				symbolicTarget,
			},
			packageId: 'package-target-copy',
			revision: 5,
		};
		const rendered = await render(
			<BridgeReviewComparisonControl
				comparisonPresentation={{
					activeTarget: symbolicTarget,
					attempt: { reviewGeneration: 1, status: 'settled' },
					displayedSnapshot: {
						packageId: reviewPackage.packageId,
						reviewGeneration: reviewPackage.reviewGeneration,
						revision: reviewPackage.revision,
						status: 'current',
					},
					repositoryDefaultTarget: { branchName: 'journey-integration', remoteName: 'origin' },
				}}
				displayedReviewPackage={reviewPackage}
				onApplyTarget={vi.fn()}
			/>,
		);

		// Act
		await performComparisonAction(async (): Promise<void> => {
			await rendered.getByTestId('bridge-review-comparison-trigger').click();
		});

		// Assert
		await expect
			.element(rendered.getByRole('heading', { name: 'Current comparison' }))
			.toBeVisible();
		await expect
			.element(rendered.getByTestId('bridge-review-comparison-current-target'))
			.toHaveTextContent('origin/journey-integration');
		await expect.element(rendered.getByText('Default', { exact: true })).toBeVisible();
		await expect.element(rendered.getByText('Common commit @', { exact: true })).toBeVisible();
		await expect
			.element(rendered.getByTestId('bridge-review-comparison-effective-revision'))
			.toHaveTextContent('bbbbbbbbbbbb');
		const currentState = rendered.getByTestId('bridge-review-comparison-current-state');
		const currentTarget = rendered.getByTestId('bridge-review-comparison-current-target');
		const currentBasis = rendered.getByTestId('bridge-review-comparison-current-basis');
		expect(getComputedStyle(currentTarget.element()).fontSize).toBe('12px');
		expect(getComputedStyle(currentBasis.element()).fontSize).toBe('12px');
		expect(getComputedStyle(currentTarget.element()).fontWeight).toBe(
			getComputedStyle(currentBasis.element()).fontWeight,
		);
		expect(getComputedStyle(currentTarget.element()).color).toBe('rgb(234, 234, 234)');
		expect(getComputedStyle(currentBasis.element()).color).toBe('rgb(184, 188, 196)');
		expect(currentState.element().querySelector('button')).toBeNull();
		expect(
			currentState
				.element()
				.querySelector('[data-testid="bridge-review-comparison-basis-trigger"]'),
		).toBeNull();
		const selectionState = rendered.getByTestId('bridge-review-comparison-target-selection');
		const sectionDivider = rendered.getByTestId('bridge-review-comparison-section-divider');
		const currentStateBounds = currentState.element().getBoundingClientRect();
		const selectionStateBounds = selectionState.element().getBoundingClientRect();
		expect(currentState.element().getAttribute('data-slot')).toBe('card');
		expect(
			getComputedStyle(
				rendered.getByRole('heading', { name: 'Compare Worktree', exact: true }).element(),
			).fontSize,
		).toBe('14px');
		expect(
			getComputedStyle(
				rendered.getByRole('heading', { name: 'Current comparison', exact: true }).element(),
			).fontSize,
		).toBe('13px');
		const sectionTitle = rendered.getByRole('heading', { name: 'Current comparison', exact: true });
		expect(getComputedStyle(sectionTitle.element()).color).toBe('rgb(234, 234, 234)');
		expect(Number(getComputedStyle(sectionTitle.element()).fontWeight)).toBeGreaterThan(
			Number(getComputedStyle(currentTarget.element()).fontWeight),
		);
		expect(selectionState.element().closest('[data-slot="card"]')).not.toBeNull();
		expect(getComputedStyle(currentState.element()).backgroundColor).toBe('rgb(39, 44, 52)');
		expect(getComputedStyle(currentState.element()).borderTopWidth).toBe('1px');
		expect(sectionDivider.query()).toBeNull();
		expect(selectionStateBounds.top - currentStateBounds.bottom).toBe(17);
		const popupText =
			rendered.getByTestId('bridge-review-comparison-content').element().textContent ?? '';
		expect(popupText).toContain('Current comparison');
		expect(popupText).not.toContain('Review starts from');
		expect(popupText).not.toContain('Latest commit shared with');
		expect(popupText).not.toContain('Comparison refreshed');
		expect(popupText).not.toContain('Base branch');
		expect(popupText).not.toContain('Branch:');
		expect(popupText).not.toContain('Comparing from:');
		expect(popupText).not.toContain('origin/journey-integration @');
		const gitConceptIcons = [
			'current-branch',
			'effective-commit',
			'target-kind',
			'branch-basis',
		].map((concept) => rendered.getByTestId(`bridge-review-comparison-${concept}-icon`).element());
		expect(gitConceptIcons.every((icon) => icon instanceof SVGElement)).toBe(true);
		expect(gitConceptIcons.every((icon) => icon.getAttribute('aria-hidden') === 'true')).toBe(true);
		expect(gitConceptIcons.every((icon) => icon.getAttribute('width') === '14')).toBe(true);
		expect(new Set(gitConceptIcons.map((icon) => icon.getBoundingClientRect().width)).size).toBe(1);
		const triggerIcon = rendered.getByTestId('bridge-review-comparison-trigger-icon').element();
		expect(triggerIcon).toBeInstanceOf(SVGElement);
		expect(triggerIcon.getAttribute('aria-hidden')).toBe('true');
		expect(triggerIcon.getBoundingClientRect().width).toBeGreaterThan(0);
		await page.screenshot({
			element: rendered.getByTestId('bridge-review-comparison-content').element(),
			path: '../../../tmp/bridgeweb-comparison-drawer-title-hierarchy.png',
		});
	});

	test('selects branch basis before applying the selected branch', async () => {
		// Arrange
		const applyTarget = vi.fn();
		const symbolicTarget = {
			basis: 'commonCommit',
			kind: 'branch',
			name: 'journey-stack-base',
		} as const;
		const baseReviewPackage = makeBridgeReviewPackage();
		const reviewPackage: BridgeReviewPackage = {
			...baseReviewPackage,
			comparisonOrigin: {
				baseOID: 'a'.repeat(40),
				baseRole: 'commonCommit',
				comparedRole: 'capturedWorkingTree',
				kind: 'contribution',
				resolvedTargetOID: 'b'.repeat(40),
				reviewedHeadOID: 'c'.repeat(40),
				reviewedSubjectBranchName: null,
				symbolicTarget,
			},
			packageId: 'package-custom-branch',
			revision: 8,
		};
		const rendered = await render(
			<BridgeReviewComparisonControl
				comparisonPresentation={{
					activeTarget: symbolicTarget,
					attempt: { reviewGeneration: 1, status: 'settled' },
					displayedSnapshot: {
						packageId: reviewPackage.packageId,
						reviewGeneration: reviewPackage.reviewGeneration,
						revision: reviewPackage.revision,
						status: 'current',
					},
					repositoryDefaultTarget: null,
				}}
				displayedReviewPackage={reviewPackage}
				onApplyTarget={applyTarget}
				targetQueryState={{ catalog: targetCatalog(), message: null, status: 'ready' }}
			/>,
		);
		await performComparisonAction(async (): Promise<void> => {
			await rendered.getByTestId('bridge-review-comparison-trigger').click();
		});

		// Act: choosing the basis alone must not mutate the active comparison.
		await performComparisonAction(async (): Promise<void> => {
			await rendered.getByRole('button', { name: 'Branch tip' }).click();
		});
		expect(applyTarget).not.toHaveBeenCalled();

		// Act: changing target kinds must not discard the user's branch basis.
		await performComparisonAction(async (): Promise<void> => {
			await rendered.getByRole('button', { name: 'Commit', exact: true }).click();
		});
		await performComparisonAction(async (): Promise<void> => {
			await rendered.getByRole('button', { name: 'Branch', exact: true }).click();
		});
		await expect
			.element(rendered.getByRole('button', { name: 'Branch Tip', exact: true }))
			.toHaveAttribute('aria-pressed', 'true');

		// Act: the chosen basis is applied with the selected branch.
		await performComparisonAction(async (): Promise<void> => {
			await rendered.getByTestId('comparison-branch-origin-main').click();
		});

		// Assert
		expect(applyTarget).toHaveBeenCalledExactlyOnceWith({
			basis: 'branchTip',
			branchName: 'main',
			kind: 'originDefaultBranch',
			remoteName: 'origin',
		});
		await expect
			.element(rendered.getByTestId('bridge-review-comparison-trigger'))
			.toHaveTextContent('journey-stack-base');
		await expect
			.element(rendered.getByTestId('bridge-review-comparison-trigger'))
			.toHaveAttribute('aria-label', 'Compare to: origin/main · Updating');
		expect(
			rendered
				.getByTestId('bridge-review-comparison-trigger')
				.element()
				.textContent?.includes('Updating'),
		).toBe(false);
		expect(rendered.getByTestId('bridge-review-comparison-pending-icon').element()).toBeInstanceOf(
			SVGElement,
		);
	});

	test('shows an exact commit as one direct base without a basis selector', async () => {
		// Arrange
		const commitOID = 'd'.repeat(40);
		const baseReviewPackage = makeBridgeReviewPackage();
		const reviewPackage: BridgeReviewPackage = {
			...baseReviewPackage,
			comparisonOrigin: {
				baseOID: commitOID,
				baseRole: 'selectedTarget',
				comparedRole: 'capturedWorkingTree',
				kind: 'contribution',
				resolvedTargetOID: commitOID,
				reviewedHeadOID: 'e'.repeat(40),
				reviewedSubjectBranchName: null,
				symbolicTarget: { kind: 'commit', oid: commitOID },
			},
			packageId: 'package-exact-commit',
			revision: 9,
		};
		const rendered = await render(
			<BridgeReviewComparisonControl
				comparisonPresentation={{
					activeTarget: { kind: 'commit', oid: commitOID },
					attempt: { reviewGeneration: 1, status: 'settled' },
					displayedSnapshot: {
						packageId: reviewPackage.packageId,
						reviewGeneration: reviewPackage.reviewGeneration,
						revision: reviewPackage.revision,
						status: 'current',
					},
					repositoryDefaultTarget: null,
				}}
				displayedReviewPackage={reviewPackage}
				onApplyTarget={vi.fn()}
			/>,
		);

		// Act
		await performComparisonAction(async (): Promise<void> => {
			await rendered.getByTestId('bridge-review-comparison-trigger').click();
		});

		// Assert
		await expect
			.element(rendered.getByTestId('bridge-review-comparison-current-state'))
			.toHaveTextContent('Commit:dddddddddddd');
		await expect
			.element(rendered.getByTestId('bridge-review-comparison-effective-revision'))
			.toHaveTextContent('dddddddddddd');
		expect(
			document.querySelector('[data-testid="bridge-review-comparison-basis-trigger"]'),
		).toBeNull();
	});

	test('keeps stale predecessor target labeled during an unavailable request', async () => {
		// Arrange
		const baseReviewPackage = makeBridgeReviewPackage();
		const stalePackage: BridgeReviewPackage = {
			...baseReviewPackage,
			comparisonOrigin: {
				baseOID: 'a'.repeat(40),
				baseRole: 'commonCommit',
				comparedRole: 'capturedWorkingTree',
				kind: 'contribution',
				resolvedTargetOID: '1'.repeat(40),
				reviewedHeadOID: 'h'.repeat(40),
				reviewedSubjectBranchName: null,
				symbolicTarget: {
					basis: 'commonCommit',
					branchName: 'master',
					kind: 'localDefaultBranch',
				},
			},
			packageId: 'package-unavailable-predecessor',
			revision: 5,
		};
		const rendered = await render(
			<BridgeReviewComparisonControl
				comparisonPresentation={{
					activeTarget: { basis: 'commonCommit', kind: 'branch', name: 'release/next' },
					attempt: {
						failureKind: 'targetNotFound',
						retryable: true,
						status: 'unavailable',
					},
					displayedSnapshot: {
						packageId: stalePackage.packageId,
						reviewGeneration: stalePackage.reviewGeneration,
						revision: stalePackage.revision,
						status: 'stale',
					},
					repositoryDefaultTarget: null,
				}}
				displayedReviewPackage={stalePackage}
				onApplyTarget={vi.fn()}
			/>,
		);

		// Act
		await performComparisonAction(async (): Promise<void> => {
			await rendered.getByTestId('bridge-review-comparison-trigger').click();
		});

		// Assert
		await expect
			.element(rendered.getByTestId('bridge-review-comparison-trigger'))
			.toHaveTextContent('master · Stale');
		expect(rendered.getByText('Comparison unavailable').query()).toBeNull();
		expect(rendered.getByRole('button', { name: 'Retry' }).query()).toBeNull();
		await expect
			.element(rendered.getByTestId('bridge-review-comparison-current-target'))
			.toHaveTextContent('master');
	});

	test('focuses branch search when the comparison drawer opens', async () => {
		// Arrange
		const rendered = await renderComparisonTargetPicker();

		// Act
		await performComparisonAction(async (): Promise<void> => {
			await rendered.getByTestId('bridge-review-comparison-trigger').click();
		});

		// Assert
		await expect.element(rendered.getByRole('combobox', { name: 'Search branches' })).toHaveFocus();
	});

	test('keeps an open target picker and its query result during same-session refresh', async () => {
		// Arrange
		const cancelTargetQuery = vi.fn();
		const queryTargets = vi.fn();
		const comparisonControl = (disabled: boolean): ReactElement => (
			<BridgeReviewComparisonControl
				comparisonPresentation={{
					activeTarget: {
						basis: 'commonCommit',
						branchName: 'main',
						kind: 'localDefaultBranch',
					},
					attempt: { reviewGeneration: 1, status: disabled ? 'pending' : 'settled' },
					displayedSnapshot: { status: 'none' },
					repositoryDefaultTarget: { branchName: 'main', remoteName: 'origin' },
				}}
				disabled={disabled}
				displayedReviewPackage={null}
				onApplyTarget={vi.fn()}
				onCancelTargetQuery={cancelTargetQuery}
				onQueryTargets={queryTargets}
				targetQueryState={{ catalog: targetCatalog(), message: null, status: 'ready' }}
			/>
		);
		const rendered = await render(comparisonControl(false));
		await performComparisonAction(async (): Promise<void> => {
			await rendered.getByTestId('bridge-review-comparison-trigger').click();
		});

		// Act
		await rendered.rerender(comparisonControl(true));

		// Assert
		await expect.element(rendered.getByTestId('bridge-review-comparison-content')).toBeVisible();
		await expect.element(rendered.getByText('origin/main', { exact: true })).toBeVisible();
		expect(queryTargets).toHaveBeenCalledTimes(1);
		expect(cancelTargetQuery).not.toHaveBeenCalled();
	});

	test('presents branch search and choices inside one bounded selector surface', async () => {
		// Arrange
		const rendered = await renderComparisonTargetPicker();

		// Act
		await performComparisonAction(async (): Promise<void> => {
			await rendered.getByTestId('bridge-review-comparison-trigger').click();
		});

		// Assert
		const selectorSurface = rendered.getByTestId('bridge-review-comparison-branch-selector');
		await expect.element(selectorSurface).toBeVisible();
		expect(getComputedStyle(selectorSurface.element()).borderTopWidth).toBe('0px');
		const inputFrame = selectorSurface.element().querySelector('[data-slot="input-group"]');
		if (inputFrame === null) throw new Error('Expected the owned input-group frame.');
		expect(getComputedStyle(inputFrame).borderTopWidth).toBe('1px');
		const listViewport = rendered.getByTestId('bridge-review-comparison-branch-scroll').element();
		expect(listViewport.getAttribute('data-slot')).toBe('combobox-viewport');
		expect(getComputedStyle(listViewport).borderTopWidth).toBe('1px');
		expect(
			listViewport.getBoundingClientRect().top - inputFrame.getBoundingClientRect().bottom,
		).toBeGreaterThanOrEqual(8);
		expect(
			rendered
				.getByTestId('bridge-review-comparison-content')
				.element()
				.querySelector('[data-slot="toggle-group"]'),
		).not.toBeNull();
	});

	test('uses one compact standard layout for the comparison selectors', async () => {
		// Arrange
		const rendered = await renderComparisonTargetPicker();

		// Act
		await performComparisonAction(async (): Promise<void> => {
			await rendered.getByTestId('bridge-review-comparison-trigger').click();
		});

		// Assert
		const title = rendered.getByRole('heading', { name: 'Compare Worktree' });
		expect(getComputedStyle(title.element()).textTransform).toBe('none');
		expect(getComputedStyle(title.element()).fontSize).toBe('14px');
		const compareWithHeading = rendered.getByText('Compare with', { exact: true });
		await expect.element(compareWithHeading).toBeVisible();
		const targetKindSelector = rendered.getByRole('group', { name: 'Comparison target kind' });
		const branchBasisHeading = rendered.getByText('Using', { exact: true });
		const branchBasisSelector = rendered.getByRole('group', { name: 'Branch comparison basis' });
		await expect
			.element(rendered.getByRole('button', { name: 'Common', exact: true }))
			.toBeVisible();
		await expect
			.element(rendered.getByRole('button', { name: 'Branch Tip', exact: true }))
			.toBeVisible();
		const targetKindLayout = compareWithHeading.element().parentElement;
		const branchBasisLayout = branchBasisHeading.element().parentElement;
		expect(targetKindLayout).not.toBeNull();
		expect(branchBasisLayout).not.toBeNull();
		expect(targetKindSelector.element().parentElement?.dataset['slot']).toBe('field');
		expect(branchBasisSelector.element().parentElement?.dataset['slot']).toBe('field');
		const titleBounds = title.element().getBoundingClientRect();
		const compareWithBounds = compareWithHeading.element().getBoundingClientRect();
		const selectorBounds = targetKindSelector.element().getBoundingClientRect();
		const branchBasisHeadingBounds = branchBasisHeading.element().getBoundingClientRect();
		const branchBasisSelectorBounds = branchBasisSelector.element().getBoundingClientRect();
		expect(title.element().closest('[data-slot="drawer-header"]')).not.toBeNull();
		expect(
			getComputedStyle(rendered.getByTestId('bridge-review-comparison-target-selection').element())
				.rowGap,
		).toBe('8px');
		expect(compareWithBounds.top).toBeGreaterThan(titleBounds.bottom);
		expect(branchBasisHeadingBounds.left).toBe(compareWithBounds.left);
		expect(branchBasisSelectorBounds.left).toBe(selectorBounds.left);
		expect(selectorBounds.left).toBeGreaterThan(compareWithBounds.right);
		expect(branchBasisSelectorBounds.left).toBeGreaterThan(branchBasisHeadingBounds.right);
		expect(verticalCenter(selectorBounds)).toBe(verticalCenter(compareWithBounds));
		expect(verticalCenter(branchBasisSelectorBounds)).toBe(
			verticalCenter(branchBasisHeadingBounds),
		);
		expect(selectorBounds.width).toBe(branchBasisSelectorBounds.width);
		expect(Math.round(selectorBounds.height)).toBe(Math.round(branchBasisSelectorBounds.height));
		const toggleItems = [
			...targetKindSelector.element().querySelectorAll('button'),
			...branchBasisSelector.element().querySelectorAll('button'),
		];
		const toggleItemWidths = toggleItems.map((item) => item.getBoundingClientRect().width);
		expect(Math.max(...toggleItemWidths) - Math.min(...toggleItemWidths)).toBeLessThanOrEqual(1);
		expect(new Set(toggleItems.map((item) => getComputedStyle(item).fontSize))).toEqual(
			new Set(['11px']),
		);
		expectToggleGroupTrackToFitItems(targetKindSelector.element());
		expectToggleGroupTrackToFitItems(branchBasisSelector.element());
	});

	test('lets one Escape from branch search reach its parent picker', async () => {
		// Arrange
		const parentKeyDown = vi.fn();
		const rendered = await render(
			<div onKeyDown={parentKeyDown}>
				<BridgeReviewComparisonBranchSelector
					activeTarget={null}
					comparisonBasis="commonCommit"
					onComparisonBasisChange={vi.fn()}
					onRetry={vi.fn()}
					onSelectTarget={vi.fn()}
					searchInputRef={createRef<HTMLInputElement>()}
					targetQueryState={{ catalog: targetCatalog(), message: null, status: 'ready' }}
				/>
			</div>,
		);
		const branchSearch = rendered.getByRole('combobox', { name: 'Search branches' });
		branchSearch.element().focus();

		// Act
		await performComparisonAction(async (): Promise<void> => {
			branchSearch
				.element()
				.dispatchEvent(new KeyboardEvent('keydown', { bubbles: true, key: 'Escape' }));
			await Promise.resolve();
		});

		// Assert
		expect(parentKeyDown).toHaveBeenCalledExactlyOnceWith(
			expect.objectContaining({ key: 'Escape' }),
		);
	});

	test('uses the cool floating surface and shared compact toolbar trigger treatment', async () => {
		// Arrange
		const rendered = await renderComparisonTargetPicker();
		const trigger = rendered.getByTestId('bridge-review-comparison-trigger');
		expect(getComputedStyle(trigger.element()).fontSize).toBe('11px');
		expect(getComputedStyle(trigger.element()).lineHeight).toBe('14px');
		expect(getComputedStyle(trigger.element()).color).toBe('rgb(234, 234, 234)');

		// Act
		await performComparisonAction(async (): Promise<void> => {
			await trigger.click();
		});

		// Assert
		const content = rendered.getByTestId('bridge-review-comparison-content');
		expect(getComputedStyle(content.element()).backgroundColor).toBe('rgb(32, 36, 42)');
	});

	test('keeps the complete selected target readable in the closed toolbar control', async () => {
		// Arrange
		const targetBranchName = 'feature/review-comparison-target-with-a-realistic-long-name';
		const rendered = await renderComparisonTargetPicker({ targetBranchName });

		// Assert
		const trigger = rendered.getByTestId('bridge-review-comparison-trigger').element();
		const label = rendered.getByText(targetBranchName, { exact: true }).element();
		expect(trigger.getAttribute('aria-label')).toBe(`Compare to: ${targetBranchName}`);
		expect(rendered.getByTestId('bridge-review-comparison-trigger-icon').element()).toBeInstanceOf(
			SVGElement,
		);
		expect(label.scrollWidth).toBeLessThanOrEqual(label.clientWidth);
		expect(trigger.scrollWidth).toBeLessThanOrEqual(trigger.clientWidth);
	});

	test('remembers commit mode when the comparison drawer reopens', async () => {
		// Arrange
		const cancelTargetQuery = vi.fn();
		const queryTargets = vi.fn();
		const rendered = await renderComparisonTargetPicker({ cancelTargetQuery, queryTargets });
		const trigger = rendered.getByTestId('bridge-review-comparison-trigger');
		await performComparisonAction(async (): Promise<void> => {
			await trigger.click();
		});
		await performComparisonAction(async (): Promise<void> => {
			await rendered.getByRole('button', { exact: true, name: 'Commit' }).click();
		});
		expect(queryTargets).toHaveBeenCalledTimes(1);
		expect(cancelTargetQuery).not.toHaveBeenCalled();
		await performComparisonAction(async (): Promise<void> => {
			await trigger.click();
		});
		expect(cancelTargetQuery).toHaveBeenCalledTimes(1);

		// Act
		await performComparisonAction(async (): Promise<void> => {
			await trigger.click();
		});

		// Assert
		await expect
			.element(rendered.getByRole('button', { name: 'Commit', exact: true }))
			.toHaveAttribute('aria-pressed', 'true');
		await expect.element(rendered.getByRole('textbox', { name: 'Commit hash' })).toHaveFocus();
		expect(queryTargets).toHaveBeenCalledTimes(2);
	});

	test('focuses the active text field when the comparison target kind changes', async () => {
		// Arrange
		const rendered = await renderComparisonTargetPicker();
		await performComparisonAction(async (): Promise<void> => {
			await rendered.getByTestId('bridge-review-comparison-trigger').click();
		});

		// Act
		await performComparisonAction(async (): Promise<void> => {
			await rendered.getByRole('button', { exact: true, name: 'Commit' }).click();
		});

		// Assert
		await expect.element(rendered.getByRole('textbox', { name: 'Commit hash' })).toHaveFocus();

		// Act
		await performComparisonAction(async (): Promise<void> => {
			await rendered.getByRole('button', { exact: true, name: 'Branch' }).click();
		});

		// Assert
		await expect.element(rendered.getByRole('combobox', { name: 'Search branches' })).toHaveFocus();
	});

	test('uses the neutral themed action for an explicit commit comparison', async () => {
		// Arrange
		const rendered = await renderComparisonTargetPicker();
		await performComparisonAction(async (): Promise<void> => {
			await rendered.getByTestId('bridge-review-comparison-trigger').click();
		});
		await performComparisonAction(async (): Promise<void> => {
			await rendered.getByRole('button', { exact: true, name: 'Commit' }).click();
		});

		// Assert
		const compareButton = rendered.getByRole('button', { name: 'Compare to this commit' });
		expect(getComputedStyle(compareButton.element()).backgroundColor).toBe('rgb(52, 58, 68)');
	});
});

function expectToggleGroupTrackToFitItems(toggleGroup: Element): void {
	const subpixelRoundingTolerance = 0.01;
	const toggleItems = toggleGroup.querySelectorAll('button');
	const firstToggleItem = toggleItems.item(0);
	const lastToggleItem = toggleItems.item(toggleItems.length - 1);
	expect(toggleItems.length).toBeGreaterThan(0);
	const trackBounds = toggleGroup.getBoundingClientRect();
	const leadingInset = firstToggleItem.getBoundingClientRect().left - trackBounds.left;
	const trailingInset = trackBounds.right - lastToggleItem.getBoundingClientRect().right;
	expect(leadingInset).toBeGreaterThanOrEqual(-subpixelRoundingTolerance);
	expect(leadingInset).toBeLessThanOrEqual(3);
	expect(trailingInset).toBeGreaterThanOrEqual(-subpixelRoundingTolerance);
	expect(trailingInset).toBeLessThanOrEqual(3);
}

function verticalCenter(bounds: DOMRect): number {
	return Math.round(bounds.top + bounds.height / 2);
}

async function renderComparisonTargetPicker(callbacks?: {
	readonly cancelTargetQuery?: () => void;
	readonly queryTargets?: () => void;
	readonly targetBranchName?: string;
}): ReturnType<typeof render> {
	const cancelTargetQuery = callbacks?.cancelTargetQuery ?? vi.fn();
	const queryTargets = callbacks?.queryTargets ?? vi.fn();
	const targetBranchName = callbacks?.targetBranchName ?? 'main';
	return render(
		<BridgeReviewComparisonControl
			comparisonPresentation={{
				activeTarget: {
					basis: 'commonCommit',
					branchName: targetBranchName,
					kind: 'localDefaultBranch',
				},
				attempt: { reviewGeneration: 1, status: 'settled' },
				displayedSnapshot: { status: 'none' },
				repositoryDefaultTarget: { branchName: 'main', remoteName: 'origin' },
			}}
			displayedReviewPackage={null}
			onApplyTarget={vi.fn()}
			onCancelTargetQuery={cancelTargetQuery}
			onQueryTargets={queryTargets}
			targetQueryState={{ catalog: targetCatalog(), message: null, status: 'ready' }}
		/>,
	);
}

function targetCatalog(): ReviewComparisonTargetCatalog {
	return {
		capturedAtUnixMilliseconds: 1_700_000_000_000,
		cutoffUnixMilliseconds: 1_699_000_000_000,
		branches: [
			{ branchName: 'main', kind: 'local', oid: 'a'.repeat(40) },
			{
				branchName: 'main',
				kind: 'remoteTracking',
				oid: 'b'.repeat(40),
				remoteName: 'origin',
			},
		],
		defaultTarget: {
			branchName: 'main',
			kind: 'remoteTracking',
			oid: 'b'.repeat(40),
			remoteName: 'origin',
		},
		currentTarget: null,
		isTruncated: false,
	};
}
