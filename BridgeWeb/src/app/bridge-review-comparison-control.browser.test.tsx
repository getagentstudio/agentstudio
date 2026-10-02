import type { ReactElement } from 'react';
import { describe, expect, test, vi } from 'vitest';
import { render } from 'vitest-browser-react';
import { userEvent } from 'vitest/browser';

// oxlint-disable-next-line import/no-unassigned-import -- Browser Mode must load production CSS.
import './bridge-app.css';
import type { BridgeMainPanelChromeSlice } from '../core/comm-worker/bridge-main-review-comparison-presentation.js';
import type { BridgeProductReviewComparisonTargetCatalog } from '../core/comm-worker/bridge-product-review-comparison-contracts.js';
import { makeBridgeReviewPackage } from '../foundation/review-package/bridge-review-package-test-support.js';
import type { BridgeReviewPackage } from '../foundation/review-package/bridge-review-package.js';
import {
	BridgeReviewComparisonControlTestHost as BridgeReviewComparisonControl,
	performComparisonAction,
} from './bridge-review-comparison-control.browser.test-support.js';

describe('BridgeReviewComparisonControl Browser Mode', () => {
	test('shows the current base branch and effective comparison commit', async () => {
		// Arrange
		const reviewPackage = contributionPackage({
			baseOID: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
			packageId: 'package-current',
			resolvedTargetOID: 'mmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmm',
			revision: 3,
		});
		const rendered = await render(
			<BridgeReviewComparisonControl
				comparisonPresentation={comparisonPresentation({
					displayedSnapshot: {
						packageId: reviewPackage.packageId,
						reviewGeneration: reviewPackage.reviewGeneration,
						revision: reviewPackage.revision,
						status: 'current',
					},
				})}
				displayedReviewPackage={reviewPackage}
				onApplyTarget={vi.fn()}
			/>,
		);

		// Act
		await performComparisonAction(async (): Promise<void> => {
			await rendered.getByTestId('bridge-review-comparison-trigger').click();
			await Promise.resolve();
		});

		// Assert
		const content = rendered.getByTestId('bridge-review-comparison-content');
		await expect.element(content).toBeVisible();
		await expect
			.element(rendered.getByTestId('bridge-review-comparison-current-target'))
			.toHaveTextContent('master');
		await expect
			.element(rendered.getByTestId('bridge-review-comparison-effective-revision'))
			.toHaveTextContent('bbbbbbbbbbbb');
		expect(
			content.element().querySelector('[data-testid="bridge-review-comparison-target-revision"]'),
		).toBeNull();
		expect(content.element().textContent).not.toMatch(
			/Review starts from|Contribution|three-dot|merge base/u,
		);
	});

	test('describes the default base branch and effective common commit', async () => {
		// Arrange
		const reviewPackage = contributionPackage({
			baseOID: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
			packageId: 'package-default-relationship',
			resolvedTargetOID: 'mmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmm',
			revision: 4,
			symbolicTarget: {
				basis: 'commonCommit',
				branchName: 'main',
				kind: 'originDefaultBranch',
				remoteName: 'origin',
			},
		});
		const rendered = await render(
			<BridgeReviewComparisonControl
				comparisonPresentation={comparisonPresentation({
					activeTarget: {
						basis: 'commonCommit',
						branchName: 'main',
						kind: 'originDefaultBranch',
						remoteName: 'origin',
					},
					displayedSnapshot: {
						packageId: reviewPackage.packageId,
						reviewGeneration: reviewPackage.reviewGeneration,
						revision: reviewPackage.revision,
						status: 'current',
					},
					repositoryDefaultTarget: { branchName: 'main', remoteName: 'origin' },
				})}
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
			.element(rendered.getByTestId('bridge-review-comparison-current-target'))
			.toHaveTextContent('origin/main');
		await expect
			.element(rendered.getByTestId('bridge-review-comparison-effective-revision'))
			.toHaveTextContent('bbbbbbbbbbbb');
		await expect.element(rendered.getByText('Default', { exact: true })).toBeVisible();
	});

	test('shows a branch-tip revision only once in the current-state block', async () => {
		// Arrange
		const branchTipOID = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
		const reviewPackage = contributionPackage({
			baseOID: branchTipOID,
			baseRole: 'selectedTarget',
			packageId: 'package-branch-tip',
			resolvedTargetOID: branchTipOID,
			revision: 5,
			symbolicTarget: {
				basis: 'branchTip',
				branchName: 'main',
				kind: 'originDefaultBranch',
				remoteName: 'origin',
			},
		});
		const rendered = await render(
			<BridgeReviewComparisonControl
				comparisonPresentation={currentPresentationForPackage(reviewPackage)}
				displayedReviewPackage={reviewPackage}
				onApplyTarget={vi.fn()}
			/>,
		);

		// Act
		await performComparisonAction(async (): Promise<void> => {
			await rendered.getByTestId('bridge-review-comparison-trigger').click();
		});

		// Assert
		const currentState = rendered.getByTestId('bridge-review-comparison-current-state');
		await expect.element(currentState).toHaveTextContent('Branch tip @');
		await expect
			.element(rendered.getByTestId('bridge-review-comparison-effective-revision'))
			.toHaveTextContent('bbbbbbbbbbbb');
		expect(
			currentState
				.element()
				.querySelector('[data-testid="bridge-review-comparison-target-revision"]'),
		).toBeNull();
		expect(currentState.element().querySelectorAll('code')).toHaveLength(1);
	});

	test('shows a common-commit revision only once when it equals the target revision', async () => {
		// Arrange
		const sharedOID = 'cccccccccccccccccccccccccccccccccccccccc';
		const reviewPackage = contributionPackage({
			baseOID: sharedOID,
			baseRole: 'commonCommit',
			packageId: 'package-common-commit-equals-target',
			resolvedTargetOID: sharedOID,
			revision: 6,
			symbolicTarget: {
				basis: 'commonCommit',
				kind: 'branch',
				name: 'main',
			},
		});
		const rendered = await render(
			<BridgeReviewComparisonControl
				comparisonPresentation={currentPresentationForPackage(reviewPackage)}
				displayedReviewPackage={reviewPackage}
				onApplyTarget={vi.fn()}
			/>,
		);

		// Act
		await performComparisonAction(async (): Promise<void> => {
			await rendered.getByTestId('bridge-review-comparison-trigger').click();
		});

		// Assert
		const currentState = rendered.getByTestId('bridge-review-comparison-current-state');
		await expect.element(currentState).toHaveTextContent('Common commit @');
		expect(
			currentState
				.element()
				.querySelector('[data-testid="bridge-review-comparison-target-revision"]'),
		).toBeNull();
		expect(currentState.element().querySelectorAll('code')).toHaveLength(1);
	});

	test('does not label the local default branch when the repository default is remote-tracking', async () => {
		// Arrange
		const reviewPackage = contributionPackage({
			baseOID: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
			packageId: 'package-local-default-not-remote-default',
			resolvedTargetOID: 'mmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmm',
			revision: 5,
			symbolicTarget: {
				basis: 'commonCommit',
				branchName: 'main',
				kind: 'localDefaultBranch',
			},
		});
		const rendered = await render(
			<BridgeReviewComparisonControl
				comparisonPresentation={comparisonPresentation({
					displayedSnapshot: {
						packageId: reviewPackage.packageId,
						reviewGeneration: reviewPackage.reviewGeneration,
						revision: reviewPackage.revision,
						status: 'current',
					},
					repositoryDefaultTarget: { branchName: 'main', remoteName: 'origin' },
				})}
				displayedReviewPackage={reviewPackage}
				onApplyTarget={vi.fn()}
			/>,
		);

		// Act
		await performComparisonAction(async (): Promise<void> => {
			await rendered.getByTestId('bridge-review-comparison-trigger').click();
		});

		// Assert
		const currentState = rendered.getByTestId('bridge-review-comparison-current-state');
		expect(currentState.element().textContent).not.toContain('Default');
	});

	test('explains when a comparison target must be chosen', async () => {
		// Arrange
		const rendered = await render(
			<BridgeReviewComparisonControl
				comparisonPresentation={comparisonPresentation({
					activeTarget: null,
					attempt: { status: 'selectionRequired' },
					displayedSnapshot: { status: 'none' },
				})}
				displayedReviewPackage={null}
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
			.toHaveTextContent('Choose target');
		await expect.element(rendered.getByText('Choose a comparison target')).toBeVisible();
		await expect
			.element(rendered.getByText('Select a branch or Git reference before reviewing changes.'))
			.toBeVisible();
	});

	test('keeps requested target and stale predecessor facts distinct while pending', async () => {
		// Arrange
		const stalePackage = contributionPackage({
			baseOID: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
			packageId: 'package-stale',
			resolvedTargetOID: '1111111111111111111111111111111111111111',
			revision: 4,
		});
		const rendered = await render(
			<BridgeReviewComparisonControl
				comparisonPresentation={comparisonPresentation({
					activeTarget: {
						basis: 'commonCommit',
						kind: 'ref',
						name: 'feature/new-target',
					},
					attempt: { reviewGeneration: 2, status: 'pending' },
					displayedSnapshot: {
						packageId: stalePackage.packageId,
						reviewGeneration: stalePackage.reviewGeneration,
						revision: stalePackage.revision,
						status: 'stale',
					},
				})}
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
			.toHaveTextContent('master');
		expect(
			rendered
				.getByTestId('bridge-review-comparison-trigger')
				.element()
				.textContent?.includes('Updating'),
		).toBe(false);
		await expect
			.element(rendered.getByRole('heading', { name: 'Previous comparison' }))
			.toBeVisible();
		expect(rendered.getByText('Updating comparison').query()).toBeNull();
		await expect
			.element(rendered.getByTestId('bridge-review-comparison-content'))
			.not.toHaveTextContent(
				'Showing the previous comparison while the requested target is prepared.',
			);
		await expect
			.element(rendered.getByTestId('bridge-review-comparison-current-target'))
			.toHaveTextContent('master');
		await expect
			.element(rendered.getByTestId('bridge-review-comparison-effective-revision'))
			.toHaveTextContent('aaaaaaaaaaaa');
	});

	test('keeps E2 failure recovery out of the chooser and with the pane summary', async () => {
		// Arrange
		const activeTarget = { basis: 'commonCommit', kind: 'branch', name: 'release/next' } as const;
		const applyTarget = vi.fn();
		const cancelTargetQuery = vi.fn();
		const rendered = await render(
			<BridgeReviewComparisonControl
				comparisonPresentation={comparisonPresentation({
					activeTarget,
					attempt: {
						failureKind: 'targetNotFound',
						retryable: true,
						status: 'unavailable',
					},
					displayedSnapshot: { status: 'none' },
				})}
				displayedReviewPackage={null}
				onApplyTarget={applyTarget}
				onCancelTargetQuery={cancelTargetQuery}
				targetQueryState={{ catalog: targetCatalog(), message: null, status: 'ready' }}
			/>,
		);

		// Act
		await performComparisonAction(async (): Promise<void> => {
			await rendered.getByTestId('bridge-review-comparison-trigger').click();
		});

		// Assert
		expect(rendered.getByText('Comparison unavailable').query()).toBeNull();
		expect(rendered.getByRole('button', { name: 'Retry' }).query()).toBeNull();
		expect(applyTarget).not.toHaveBeenCalled();
		expect(cancelTargetQuery).not.toHaveBeenCalled();
	});

	test('shows searchable default, local, and remote-tracking branch choices', async () => {
		// Arrange
		const applyTarget = vi.fn();
		const rendered = await render(
			<BridgeReviewComparisonControl
				comparisonPresentation={comparisonPresentation({
					activeTarget: {
						basis: 'commonCommit',
						branchName: 'main',
						kind: 'originDefaultBranch',
						remoteName: 'origin',
					},
					displayedSnapshot: { status: 'none' },
				})}
				displayedReviewPackage={null}
				onApplyTarget={applyTarget}
				targetQueryState={{ catalog: targetCatalog(), message: null, status: 'ready' }}
			/>,
		);
		await performComparisonAction(async (): Promise<void> => {
			await rendered.getByTestId('bridge-review-comparison-trigger').click();
		});

		// Assert
		await expect
			.element(rendered.getByTestId('bridge-review-comparison-trigger'))
			.toHaveTextContent('origin/main');
		await expect.element(rendered.getByText('Compare Worktree')).toBeVisible();
		await expect
			.element(rendered.getByRole('button', { name: 'Branch', exact: true }))
			.toHaveAttribute('aria-pressed', 'true');
		await expect
			.element(rendered.getByRole('button', { name: 'Commit', exact: true }))
			.toBeVisible();
		await expect
			.element(rendered.getByTestId('comparison-branch-origin-main'))
			.toHaveTextContent(/origin\/main.*Default.*Remote-tracking.*bbbbbbbbbbbb/u);
		await expect
			.element(rendered.getByTestId('comparison-branch-main'))
			.toHaveTextContent(/main.*Local.*aaaaaaaaaaaa/u);
		await expect.element(rendered.getByText('b'.repeat(40), { exact: true })).toBeInTheDocument();

		// Act
		await performComparisonAction(async (): Promise<void> => {
			await rendered.getByRole('combobox', { name: 'Search branches' }).fill('feature');
		});

		// Assert
		await expect.element(rendered.getByTestId('comparison-branch-feature-stack')).toBeVisible();
		expect(document.querySelector('[data-testid="comparison-branch-main"]')).toBeNull();
		expect(document.querySelector('[data-testid="comparison-branch-origin-main"]')).toBeNull();
	});

	test('keeps a 2,000-row catalog bounded while keyboard-selecting beyond the first window', async () => {
		// Arrange
		const applyTarget = vi.fn();
		const branches = Array.from({ length: 2_000 }, (_, index) => ({
			branchName: `branch-${index}`,
			kind: 'local' as const,
			oid: index.toString(16).padStart(40, '0'),
		}));
		const filteredBranches = branches.filter((branch) => branch.branchName.includes('branch-19'));
		const deepKeyboardBranch = filteredBranches[49];
		if (deepKeyboardBranch === undefined)
			throw new Error('Expected a deep filtered branch fixture.');
		const rendered = await render(
			<BridgeReviewComparisonControl
				comparisonPresentation={comparisonPresentation({ displayedSnapshot: { status: 'none' } })}
				displayedReviewPackage={null}
				onApplyTarget={applyTarget}
				targetQueryState={{
					catalog: targetCatalog({ branches }),
					message: null,
					status: 'ready',
				}}
			/>,
		);

		// Act
		await performComparisonAction(async (): Promise<void> => {
			await rendered.getByTestId('bridge-review-comparison-trigger').click();
		});

		// Assert
		const mountedRows = document.querySelectorAll('[data-slot="combobox-item"]');
		expect(mountedRows.length).toBeLessThanOrEqual(40);
		expect(mountedRows.length).toBeGreaterThan(0);
		const firstRow = rendered.getByTestId('comparison-branch-branch-0');
		await expect.element(firstRow).toHaveAttribute('aria-setsize', '2000');
		await expect.element(firstRow).toHaveAttribute('aria-posinset', '1');

		// Act
		await performComparisonAction(async (): Promise<void> => {
			await rendered.getByRole('combobox', { name: 'Search branches' }).fill('branch-19');
		});

		// Assert
		const filteredNonFirstRow = rendered.getByTestId('comparison-branch-branch-190');
		await expect.element(filteredNonFirstRow).toHaveAttribute('aria-setsize', '111');
		await expect.element(filteredNonFirstRow).toHaveAttribute('aria-posinset', '2');

		// Act: keyboard navigation must drive the virtualizer beyond its first mounted window.
		await performComparisonAction(async (): Promise<void> => {
			await userEvent.keyboard(Array.from({ length: 50 }, () => '{ArrowDown}').join(''));
		});

		// Assert
		const deepKeyboardRow = rendered.getByTestId(
			`comparison-branch-${deepKeyboardBranch.branchName}`,
		);
		await expect.element(deepKeyboardRow).toHaveAttribute('data-highlighted');
		expect(
			rendered.getByTestId('bridge-review-comparison-branch-scroll').element().scrollTop,
		).toBeGreaterThan(0);

		// Act
		await performComparisonAction(async (): Promise<void> => {
			await userEvent.keyboard('{Enter}');
		});

		// Assert
		expect(applyTarget).toHaveBeenCalledExactlyOnceWith({
			basis: 'commonCommit',
			kind: 'branch',
			name: deepKeyboardBranch.branchName,
		});
	});

	test('mouse-selects a deep row after scrolling a 2,000-row virtualized catalog', async () => {
		// Arrange
		const applyTarget = vi.fn();
		const branches = Array.from({ length: 2_000 }, (_, index) => ({
			branchName: `branch-${index}`,
			kind: 'local' as const,
			oid: index.toString(16).padStart(40, '0'),
		}));
		const rendered = await render(
			<BridgeReviewComparisonControl
				comparisonPresentation={comparisonPresentation({ displayedSnapshot: { status: 'none' } })}
				displayedReviewPackage={null}
				onApplyTarget={applyTarget}
				targetQueryState={{
					catalog: targetCatalog({ branches }),
					message: null,
					status: 'ready',
				}}
			/>,
		);
		await performComparisonAction(async (): Promise<void> => {
			await rendered.getByTestId('bridge-review-comparison-trigger').click();
		});
		const scrollElement = rendered.getByTestId('bridge-review-comparison-branch-scroll').element();

		// Act
		await performComparisonAction(async (): Promise<void> => {
			scrollElement.scrollTop = scrollElement.scrollHeight;
			scrollElement.dispatchEvent(new Event('scroll'));
			await new Promise<void>((resolve) => requestAnimationFrame(() => resolve()));
		});

		// Assert
		const lastRow = rendered.getByTestId('comparison-branch-branch-1999');
		await expect.element(lastRow).toHaveAttribute('aria-posinset', '2000');
		expect(document.querySelectorAll('[data-slot="combobox-item"]').length).toBeLessThanOrEqual(40);

		// Act
		await performComparisonAction(async (): Promise<void> => {
			await lastRow.click();
		});

		// Assert
		expect(applyTarget).toHaveBeenCalledExactlyOnceWith({
			basis: 'commonCommit',
			kind: 'branch',
			name: 'branch-1999',
		});
	});

	test('uses the concise recent-window footer beside ready branch results', async () => {
		// Arrange
		const rendered = await render(
			<BridgeReviewComparisonControl
				comparisonPresentation={comparisonPresentation({ displayedSnapshot: { status: 'none' } })}
				displayedReviewPackage={null}
				onApplyTarget={vi.fn()}
				targetQueryState={{
					catalog: targetCatalog({ isTruncated: true }),
					message: null,
					status: 'ready',
				}}
			/>,
		);

		// Act
		await performComparisonAction(async (): Promise<void> => {
			await rendered.getByTestId('bridge-review-comparison-trigger').click();
		});

		// Assert
		const explanation = rendered.getByTestId('bridge-review-comparison-catalog-explanation');
		await expect.element(explanation).toHaveTextContent('Showing branches from the last 30 days.');
		expect(explanation.element().textContent).toBe('Showing branches from the last 30 days.');
	});

	test('shows shadcn skeleton rows until the virtualized branch catalog is ready', async () => {
		// Arrange
		const comparisonControl = (status: 'loading' | 'ready'): ReactElement => (
			<BridgeReviewComparisonControl
				comparisonPresentation={comparisonPresentation({ displayedSnapshot: { status: 'none' } })}
				displayedReviewPackage={null}
				onApplyTarget={vi.fn()}
				targetQueryState={
					status === 'loading'
						? { catalog: null, message: null, status }
						: { catalog: targetCatalog(), message: null, status }
				}
			/>
		);
		const rendered = await render(comparisonControl('loading'));

		// Act
		await performComparisonAction(async (): Promise<void> => {
			await rendered.getByTestId('bridge-review-comparison-trigger').click();
		});

		// Assert
		const loadingViewport = rendered.getByTestId('bridge-review-comparison-branch-skeleton');
		await expect.element(loadingViewport).toBeVisible();
		expect(loadingViewport.element().querySelectorAll('[data-slot="skeleton"]')).toHaveLength(4);
		expect(
			document.querySelector('[data-testid="bridge-review-comparison-branch-scroll"]'),
		).toBeNull();
		expect(document.body.textContent).not.toContain('Loading branch choices…');

		// Act
		await rendered.rerender(comparisonControl('ready'));

		// Assert
		await expect
			.element(rendered.getByTestId('bridge-review-comparison-branch-scroll'))
			.toBeVisible();
		expect(
			document.querySelector('[data-testid="bridge-review-comparison-branch-skeleton"]'),
		).toBeNull();
	});

	test('preserves an empty catalog while explaining the recent-window boundary', async () => {
		// Arrange
		const rendered = await render(
			<BridgeReviewComparisonControl
				comparisonPresentation={comparisonPresentation({ displayedSnapshot: { status: 'none' } })}
				displayedReviewPackage={null}
				onApplyTarget={vi.fn()}
				targetQueryState={{
					catalog: targetCatalog({ branches: [] }),
					message: 'No branch choices are available from the last 30 days.',
					status: 'empty',
				}}
			/>,
		);

		// Act
		await performComparisonAction(async (): Promise<void> => {
			await rendered.getByTestId('bridge-review-comparison-trigger').click();
		});

		// Assert
		await expect
			.element(rendered.getByText('No branch choices are available from the last 30 days.'))
			.toBeVisible();
		await expect
			.element(rendered.getByTestId('bridge-review-comparison-catalog-explanation'))
			.toHaveTextContent('Showing branches from the last 30 days.');
	});

	test('uses the owned button primitive to retry a failed branch query', async () => {
		// Arrange
		const queryTargets = vi.fn();
		const rendered = await render(
			<BridgeReviewComparisonControl
				comparisonPresentation={comparisonPresentation({ displayedSnapshot: { status: 'none' } })}
				displayedReviewPackage={null}
				onApplyTarget={vi.fn()}
				onQueryTargets={queryTargets}
				targetQueryState={{ catalog: null, message: 'Branch query failed.', status: 'failed' }}
			/>,
		);

		// Act
		await performComparisonAction(async (): Promise<void> => {
			await rendered.getByTestId('bridge-review-comparison-trigger').click();
		});

		// Assert
		const failureAlert = rendered.getByRole('alert');
		await expect.element(failureAlert).toHaveTextContent('Branch query failed.');
		expect(failureAlert.element().querySelector('svg[aria-hidden="true"]')).not.toBeNull();
		expect(rendered.getByRole('combobox', { name: 'Search branches' }).query()).toBeNull();
		expect(rendered.getByTestId('bridge-review-comparison-catalog-explanation').query()).toBeNull();
		const retryButton = rendered.getByRole('button', { name: 'Retry' });
		expect(retryButton.element().getAttribute('data-slot')).toBe('button');
		expect(retryButton.element().querySelector('svg[aria-hidden="true"]')).not.toBeNull();
		await performComparisonAction(async (): Promise<void> => {
			await retryButton.click();
		});
		expect(queryTargets).toHaveBeenCalledTimes(2);
	});

	test.each([
		{
			expectedTarget: {
				basis: 'commonCommit',
				branchName: 'main',
				kind: 'originDefaultBranch',
				remoteName: 'origin',
			},
			expectedAccessibleLabel: 'Compare to: origin/main · Updating',
			rowTestId: 'comparison-branch-origin-main',
		},
		{
			expectedTarget: { basis: 'commonCommit', kind: 'branch', name: 'main' },
			expectedAccessibleLabel: 'Compare to: main · Updating',
			rowTestId: 'comparison-branch-main',
		},
		{
			expectedTarget: {
				basis: 'commonCommit',
				branchName: 'release',
				kind: 'originDefaultBranch',
				remoteName: 'upstream',
			},
			expectedAccessibleLabel: 'Compare to: upstream/release · Updating',
			rowTestId: 'comparison-branch-upstream-release',
		},
	])('applies $rowTestId immediately', async (scenario) => {
		// Arrange
		const applyTarget = vi.fn();
		const cancelTargetQuery = vi.fn();
		const rendered = await render(
			<BridgeReviewComparisonControl
				comparisonPresentation={comparisonPresentation({
					displayedSnapshot: { status: 'none' },
				})}
				displayedReviewPackage={null}
				onApplyTarget={applyTarget}
				onCancelTargetQuery={cancelTargetQuery}
				targetQueryState={{ catalog: targetCatalog(), message: null, status: 'ready' }}
			/>,
		);

		// Act
		await performComparisonAction(async (): Promise<void> => {
			await rendered.getByTestId('bridge-review-comparison-trigger').click();
		});
		await performComparisonAction(async (): Promise<void> => {
			await rendered.getByTestId(scenario.rowTestId).click();
		});

		// Assert
		expect(applyTarget).toHaveBeenCalledExactlyOnceWith(scenario.expectedTarget);
		expect(cancelTargetQuery).toHaveBeenCalledExactlyOnceWith();
		const trigger = rendered.getByTestId('bridge-review-comparison-trigger');
		await expect.element(trigger).toHaveTextContent('master');
		await expect.element(trigger).toHaveAttribute('aria-label', scenario.expectedAccessibleLabel);
		expect(trigger.element().textContent?.includes('Updating')).toBe(false);
		expect(trigger.element()).toBeDisabled();
		expect(
			trigger.element().querySelector('[data-testid="bridge-review-comparison-pending-icon"]'),
		).not.toBeNull();
		expect(
			trigger.element().querySelector('[data-testid="bridge-review-comparison-trigger-icon"]'),
		).toBeNull();
	});

	test('accepts only a full hexadecimal commit OID', async () => {
		// Arrange
		const applyTarget = vi.fn();
		const cancelTargetQuery = vi.fn();
		const rendered = await render(
			<BridgeReviewComparisonControl
				comparisonPresentation={comparisonPresentation({
					displayedSnapshot: { status: 'none' },
				})}
				displayedReviewPackage={null}
				onApplyTarget={applyTarget}
				onCancelTargetQuery={cancelTargetQuery}
			/>,
		);
		await performComparisonAction(async (): Promise<void> => {
			await rendered.getByTestId('bridge-review-comparison-trigger').click();
		});
		await performComparisonAction(async (): Promise<void> => {
			await rendered.getByRole('button', { name: 'Commit', exact: true }).click();
		});
		const commitInput = rendered.getByRole('textbox', { name: 'Commit hash' });

		// Act
		await performComparisonAction(async (): Promise<void> => {
			await commitInput.fill('abc123');
			await rendered.getByRole('button', { name: 'Compare to this commit' }).click();
		});

		// Assert
		await expect
			.element(rendered.getByRole('alert'))
			.toHaveTextContent('Enter a full 40- or 64-character hexadecimal commit hash.');
		expect(applyTarget).not.toHaveBeenCalled();

		// Act
		const fullOID = 'c'.repeat(40);
		await performComparisonAction(async (): Promise<void> => {
			await commitInput.fill(fullOID);
			await rendered.getByRole('button', { name: 'Compare to this commit' }).click();
		});

		// Assert
		expect(applyTarget).toHaveBeenCalledExactlyOnceWith({ kind: 'commit', oid: fullOID });
		expect(cancelTargetQuery).toHaveBeenCalledExactlyOnceWith();
	});

	test('keeps the rendered predecessor labeled with its own target until the successor package arrives', async () => {
		// Arrange
		const predecessor = contributionPackage({
			baseOID: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
			packageId: 'package-delivery-predecessor',
			resolvedTargetOID: '1111111111111111111111111111111111111111',
			revision: 24,
		});
		const successorTarget = {
			basis: 'commonCommit',
			kind: 'ref',
			name: 'feature/new-target',
		} as const;
		const successor = contributionPackage({
			baseOID: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
			packageId: 'package-delivery-successor',
			resolvedTargetOID: '2222222222222222222222222222222222222222',
			revision: 25,
			symbolicTarget: successorTarget,
		});
		const successorPresentation = comparisonPresentation({
			activeTarget: successorTarget,
			displayedSnapshot: {
				packageId: successor.packageId,
				reviewGeneration: successor.reviewGeneration,
				revision: successor.revision,
				status: 'current',
			},
		});
		const rendered = await render(
			<BridgeReviewComparisonControl
				comparisonPresentation={currentPresentationForPackage(predecessor)}
				displayedReviewPackage={predecessor}
				onApplyTarget={vi.fn()}
			/>,
		);

		// Act — presentation can settle the successor before its package frame arrives.
		await rendered.rerender(
			<BridgeReviewComparisonControl
				comparisonPresentation={successorPresentation}
				displayedReviewPackage={predecessor}
				onApplyTarget={vi.fn()}
			/>,
		);

		// Assert — closed chrome retains the installed target while its accessible status names the request.
		await expect
			.element(rendered.getByTestId('bridge-review-comparison-trigger'))
			.toHaveTextContent('master');
		await expect
			.element(rendered.getByTestId('bridge-review-comparison-trigger'))
			.toHaveAttribute('aria-label', 'Compare to: feature/new-target · Updating');
		expect(
			rendered
				.getByTestId('bridge-review-comparison-trigger')
				.element()
				.textContent?.includes('Updating'),
		).toBe(false);
		await performComparisonAction(async (): Promise<void> => {
			await rendered.getByTestId('bridge-review-comparison-trigger').click();
		});
		await expect
			.element(rendered.getByRole('heading', { name: 'Previous comparison' }))
			.toBeVisible();
		expect(rendered.getByText('Updating comparison').query()).toBeNull();
		await expect
			.element(rendered.getByTestId('bridge-review-comparison-current-target'))
			.toHaveTextContent('master');
		await expect
			.element(rendered.getByTestId('bridge-review-comparison-effective-revision'))
			.toHaveTextContent('aaaaaaaaaaaa');

		// Act — the package frame catches up with the settled presentation.
		await rendered.rerender(
			<BridgeReviewComparisonControl
				comparisonPresentation={successorPresentation}
				displayedReviewPackage={successor}
				onApplyTarget={vi.fn()}
			/>,
		);

		// Assert
		await expect
			.element(rendered.getByTestId('bridge-review-comparison-trigger'))
			.toHaveTextContent('feature/new-target');
		await expect
			.element(rendered.getByTestId('bridge-review-comparison-current-target'))
			.toHaveTextContent('feature/new-target');
		await expect
			.element(rendered.getByTestId('bridge-review-comparison-effective-revision'))
			.toHaveTextContent('bbbbbbbbbbbb');
		expect(
			rendered
				.getByTestId('bridge-review-comparison-current-state')
				.element()
				.querySelector('[data-testid="bridge-review-comparison-target-revision"]'),
		).toBeNull();
	});
});

function comparisonPresentation(props: {
	readonly activeTarget?: NonNullable<
		BridgeMainPanelChromeSlice['reviewComparison']
	>['activeTarget'];
	readonly attempt?: NonNullable<BridgeMainPanelChromeSlice['reviewComparison']>['attempt'];
	readonly displayedSnapshot: NonNullable<
		BridgeMainPanelChromeSlice['reviewComparison']
	>['displayedSnapshot'];
	readonly repositoryDefaultTarget?: NonNullable<
		NonNullable<BridgeMainPanelChromeSlice['reviewComparison']>
	>['repositoryDefaultTarget'];
}): NonNullable<BridgeMainPanelChromeSlice['reviewComparison']> {
	return {
		activeTarget:
			props.activeTarget === undefined
				? { basis: 'commonCommit', branchName: 'master', kind: 'localDefaultBranch' }
				: props.activeTarget,
		attempt: props.attempt ?? { reviewGeneration: 1, status: 'settled' },
		displayedSnapshot: props.displayedSnapshot,
		repositoryDefaultTarget: props.repositoryDefaultTarget ?? null,
	};
}

function targetCatalog(
	props: {
		readonly branches?: BridgeProductReviewComparisonTargetCatalog['branches'];
		readonly isTruncated?: boolean;
	} = {},
): BridgeProductReviewComparisonTargetCatalog {
	return {
		capturedAtUnixMilliseconds: 1_700_000_000_000,
		cutoffUnixMilliseconds: 1_699_000_000_000,
		branches: props.branches ?? [
			{ branchName: 'main', kind: 'local', oid: 'a'.repeat(40) },
			{ branchName: 'feature/stack', kind: 'local', oid: 'f'.repeat(40) },
			{
				branchName: 'main',
				kind: 'remoteTracking',
				oid: 'b'.repeat(40),
				remoteName: 'origin',
			},
			{
				branchName: 'release',
				kind: 'remoteTracking',
				oid: 'd'.repeat(40),
				remoteName: 'upstream',
			},
		],
		defaultTarget: {
			branchName: 'main',
			kind: 'remoteTracking',
			oid: 'b'.repeat(40),
			remoteName: 'origin',
		},
		currentTarget: null,
		isTruncated: props.isTruncated ?? false,
	};
}

function currentPresentationForPackage(
	reviewPackage: BridgeReviewPackage,
): NonNullable<BridgeMainPanelChromeSlice['reviewComparison']> {
	return comparisonPresentation({
		displayedSnapshot: {
			packageId: reviewPackage.packageId,
			reviewGeneration: reviewPackage.reviewGeneration,
			revision: reviewPackage.revision,
			status: 'current',
		},
	});
}

function contributionPackage(props: {
	readonly baseOID: string;
	readonly baseRole?: 'commonCommit' | 'selectedTarget';
	readonly packageId: string;
	readonly resolvedTargetOID: string;
	readonly revision: number;
	readonly symbolicTarget?: NonNullable<BridgeReviewPackage['comparisonOrigin']>['symbolicTarget'];
}): BridgeReviewPackage {
	return {
		...makeBridgeReviewPackage(),
		comparisonOrigin: {
			baseOID: props.baseOID,
			baseRole: props.baseRole ?? 'commonCommit',
			comparedRole: 'capturedWorkingTree',
			kind: 'contribution',
			resolvedTargetOID: props.resolvedTargetOID,
			reviewedHeadOID: 'hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh',
			symbolicTarget: props.symbolicTarget ?? {
				basis: 'commonCommit',
				branchName: 'master',
				kind: 'localDefaultBranch',
			},
		},
		packageId: props.packageId,
		reviewedSubjectLabel: 'feature/annotations',
		revision: props.revision,
	};
}
