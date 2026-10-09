import { act } from 'react';
import { describe, expect, test, vi } from 'vitest';
import { render } from 'vitest-browser-react';

// oxlint-disable-next-line import/no-unassigned-import -- Browser Mode must load production app CSS.
import './bridge-app.css';
import { BridgeReviewViewerShellBoundary } from './bridge-app-review-viewer-shell-boundary.js';
import { BridgeReviewComparisonStatusBanner } from './bridge-review-comparison-status-banner.js';

describe('BridgeReviewComparisonStatusBanner', () => {
	test('announces pending comparison accessibly without presenting a visible layout row', async () => {
		const rendered = await render(
			<BridgeReviewComparisonStatusBanner
				onRetry={vi.fn()}
				state={{
					displayedTargetLabel: 'origin/main',
					kind: 'loadingPrevious',
					requestedTargetLabel: 'feature/new-target',
				}}
			/>,
		);

		await expect
			.element(rendered.getByRole('status'))
			.toHaveTextContent('Loading comparison with feature/new-target');
		expect(rendered.getByTestId('bridge-review-comparison-loading-spinner').query()).toBeNull();
		expect(rendered.getByRole('progressbar').query()).toBeNull();
		expect(rendered.getByTestId('bridge-review-comparison-status-region').query()).toBeNull();
		expect(getComputedStyle(rendered.getByRole('status').element()).position).toBe('absolute');
		expect(rendered.getByRole('button', { name: 'Retry' }).query()).toBeNull();
	});

	test('removes the accessible loading status when the comparison settles', async () => {
		const rendered = await render(
			<BridgeReviewComparisonStatusBanner
				onRetry={vi.fn()}
				state={{
					displayedTargetLabel: 'origin/main',
					kind: 'loadingPrevious',
					requestedTargetLabel: 'feature/new-target',
				}}
			/>,
		);

		await rendered.rerender(
			<BridgeReviewComparisonStatusBanner onRetry={vi.fn()} state={{ kind: 'settled' }} />,
		);

		expect(rendered.getByRole('status').query()).toBeNull();
		expect(rendered.getByTestId('bridge-review-comparison-status-region').query()).toBeNull();
	});

	test('moves comparison failure and Retry into the pane summary above the tree', async () => {
		const retryTarget = {
			basis: 'commonCommit' as const,
			kind: 'ref' as const,
			name: 'feature/new-target',
		};
		const onRetry = vi.fn();
		const state = {
			displayedTargetLabel: 'origin/main',
			kind: 'failedPrevious',
			failureKind: 'targetNotFound',
			requestedTargetLabel: 'feature/new-target',
			retryTarget,
		} as const;
		const rendered = await render(
			<BridgeReviewViewerShellBoundary
				comparisonPaneState={state}
				isActive
				onRetryComparison={onRetry}
				presentationState={{ status: 'metadataFailed', error: null }}
				viewerContextSwitcher={null}
				viewerHeaderControls={null}
			/>,
		);
		await expect.element(rendered.getByRole('alert')).toHaveTextContent("Review couldn't load.");
		expect(rendered.getByTestId('bridge-review-comparison-status-region').query()).toBeNull();
		expect(document.querySelectorAll('[role="alert"]')).toHaveLength(1);
		expect(
			rendered
				.getByTestId('bridge-review-sidebar')
				.element()
				.contains(rendered.getByRole('alert').element()),
		).toBe(true);
		await act(async (): Promise<void> => {
			await rendered.getByRole('button', { name: 'Retry' }).click();
		});
		expect(onRetry).toHaveBeenCalledExactlyOnceWith(retryTarget);
	});
});
