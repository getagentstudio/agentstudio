import { act, type ReactElement } from 'react';
import { expect, test, vi } from 'vitest';
import { render } from 'vitest-browser-react';
import { page } from 'vitest/browser';

// oxlint-disable-next-line import/no-unassigned-import -- Verify the production Review region shapes and chrome.
import './bridge-app.css';
import { createBridgeMainRenderSnapshotStore } from '../core/comm-worker/bridge-main-render-snapshot-store.js';
import { makeBridgeReviewPackage } from '../foundation/review-package/bridge-review-package-test-support.js';
import type { BridgeReviewPackage } from '../foundation/review-package/bridge-review-package.js';
import { createBridgeTelemetryRecorder } from '../foundation/telemetry/bridge-telemetry-recorder.js';
import {
	makeReviewSurfaceHarness,
	reviewDisplayEvent,
	settleRenderedReviewFrame,
} from './bridge-app-review-render-snapshot-controller.browser-harness.test-support.js';
import { BridgeReviewViewerMode } from './bridge-app-review-viewer-mode.js';
import { BridgeReviewViewerShellBoundary } from './bridge-app-review-viewer-shell-boundary.js';
import {
	BridgeReviewComparisonControlTestHost,
	performComparisonAction,
} from './bridge-review-comparison-control.browser.test-support.js';
import { BridgeReviewRefreshHeaderGroup } from './bridge-review-refresh-header-chrome.js';

test('certified empty Review exposes quiet W6 Empty in both centre and rail', async (): Promise<void> => {
	await render(
		<BridgeReviewViewerShellBoundary
			comparisonPaneState={{ kind: 'settled' }}
			isActive
			onRetryComparison={(): void => {}}
			presentationState={{ status: 'readyEmpty' }}
			viewerContextSwitcher={<span>Review</span>}
			viewerHeaderControls={null}
		/>,
	);
	for (const region of ['review-content', 'review-tree']) {
		expect(
			document
				.querySelector(`[data-bridge-region="${region}"]`)
				?.getAttribute('data-presentation-state'),
		).toBe('empty');
	}
	expect(document.querySelector('[data-slot="skeleton"]')).toBeNull();
	expect(document.body.innerText).not.toMatch(/loading|waiting|pending/i);
});

test('failure takes precedence over certified empty and stops every rail skeleton', async (): Promise<void> => {
	await render(
		<BridgeReviewViewerShellBoundary
			comparisonPaneState={{
				kind: 'failedInitial',
				failureKind: 'refreshUnavailable',
				requestedTargetLabel: 'main',
				retryTarget: null,
			}}
			isActive
			onRetryComparison={(): void => {}}
			presentationState={{ status: 'readyEmpty' }}
			viewerContextSwitcher={<span>Review</span>}
			viewerHeaderControls={null}
		/>,
	);
	for (const region of ['review-content', 'review-tree']) {
		expect(
			document
				.querySelector(`[data-bridge-region="${region}"]`)
				?.getAttribute('data-presentation-state'),
		).toBe('failed');
	}
	expect(document.querySelector('[data-slot="skeleton"]')).toBeNull();
	expect(document.querySelector('button')).toBeNull();
});

test('healthy-target refresh failure has no second failure message in the comparison popup', async (): Promise<void> => {
	const store = createBridgeMainRenderSnapshotStore();
	store.applyWorkerPatch({
		slice: 'panelChrome',
		operation: 'upsert',
		payload: {
			reviewComparison: {
				activeTarget: { kind: 'ref', name: 'main', basis: 'commonCommit' },
				attempt: { status: 'unavailable', failureKind: 'providerUnavailable', retryable: true },
				displayedSnapshot: { status: 'none' },
				repositoryDefaultTarget: null,
			},
		},
	});
	try {
		const rendered = await render(
			<BridgeReviewComparisonControlTestHost
				comparisonPresentation={store.getSnapshot().panelChromeSlice.reviewComparison}
				displayedReviewPackage={null}
				onApplyTarget={(): void => {}}
			/>,
		);
		await performComparisonAction(async (): Promise<void> => {
			await rendered.getByTestId('bridge-review-comparison-trigger').click();
		});
		expect(rendered.getByText('Update unavailable', { exact: true }).query()).toBeNull();
		expect(rendered.getByText('Comparison unavailable', { exact: true }).query()).toBeNull();
	} finally {
		store.dispose();
	}
});

test('an empty Review rests held without a spinner, then keeps its last complete read through failure', async (): Promise<void> => {
	let applyCount = 0;
	let retryCount = 0;
	const host = (failed: boolean): ReactElement => (
		<div className="h-[600px] w-[720px]">
			<BridgeReviewViewerShellBoundary
				comparisonPaneState={{ kind: 'settled' }}
				isActive
				presentationState={{ status: 'readyEmpty' }}
				regionSurfaceStatus={
					failed
						? {
								kind: 'failed',
								failure: { kind: 'retryable', scope: 'surface', message: 'Update unavailable' },
							}
						: { kind: 'updating', rest: 'held' }
				}
				onRetryComparison={(): void => {}}
				onRetryMetadata={(): void => {
					retryCount += 1;
				}}
				viewerContextSwitcher={<span>Review</span>}
				viewerHeaderControls={
					failed ? null : (
						<BridgeReviewRefreshHeaderGroup
							presentation={{ action: 'applyNow', statusText: 'Update ready' }}
							onApplyNow={(): void => {
								applyCount += 1;
							}}
							onRetry={(): void => {}}
						/>
					)
				}
			/>
		</div>
	);
	const rendered = await render(host(false));
	for (const region of ['review-content', 'review-tree'])
		expect(
			document
				.querySelector(`[data-bridge-region="${region}"]`)
				?.getAttribute('data-presentation-state'),
		).toBe('updating');
	await expect.element(rendered.getByText('Nothing to review', { exact: true })).toBeVisible();
	expect(document.querySelectorAll('[role="status"]')).toHaveLength(1);
	expect(document.querySelector('.animate-spin')).toBeNull();
	await act(async (): Promise<void> => {
		await rendered.getByRole('button', { name: 'Apply now', exact: true }).click();
	});
	expect(applyCount).toBe(1);
	await act(async (): Promise<void> => {
		await rendered.rerender(host(true));
	});
	await expect.element(rendered.getByText('Nothing to review', { exact: true })).toBeVisible();
	expect(document.querySelectorAll('[role="alert"]')).toHaveLength(1);
	expect(document.querySelectorAll('[data-bridge-region="review-tree"] button')).toHaveLength(0);
	await act(async (): Promise<void> => {
		await rendered.getByRole('button', { name: 'Retry', exact: true }).click();
	});
	expect(retryCount).toBe(1);
	await page.screenshot({ path: '../../../tmp/g1-review-empty-retained-failure.png' });
});

test('a permanently unavailable selected read leaves the Review tree settled and offers no Retry', async (): Promise<void> => {
	const harness = makeReviewSurfaceHarness();
	const rendered = await render(
		<div className="h-[600px] w-[720px]">
			<BridgeReviewViewerMode
				codeViewWorkerPoolEnabled={false}
				isActive
				isNavigationCommandStillEligible={(): boolean => true}
				onActiveSourceChange={vi.fn()}
				onNavigationSourceChange={vi.fn()}
				reviewClient={harness.reviewClient}
				telemetryRecorderRef={{ current: createBridgeTelemetryRecorder(null) }}
				viewerContextSwitcher={<div />}
			/>
		</div>,
	);
	await act(async (): Promise<void> => {
		harness.publish(
			reviewDisplayEvent({
				itemId: 'permanent-read-item',
				path: 'Sources/Unavailable.swift',
				projectionRevision: 1,
				sequence: 1,
				startIndex: 0,
				totalItemCount: 1,
			}),
		);
		await import('../review-viewer/shell/review-viewer-shell.js');
		await settleRenderedReviewFrame();
		harness.reviewClient.renderStore.setLocalSelection({
			selectedItemId: 'permanent-read-item',
			source: 'user',
		});
		harness.reviewClient.renderStore.applyWorkerPatch({
			slice: 'contentAvailability',
			operation: 'upsert',
			itemId: 'permanent-read-item',
			payload: { state: 'unavailable', reason: 'content_unavailable' },
		});
	});
	await expect
		.element(rendered.getByRole('alert'))
		.toHaveTextContent("Couldn't open Unavailable.swift.");
	await expect
		.element(rendered.getByRole('alert'))
		.toHaveTextContent('Open this file in an external editor.');
	expect(rendered.getByRole('button', { name: 'Retry', exact: true }).query()).toBeNull();
	expect(
		document
			.querySelector('[data-bridge-region="review-tree"]')
			?.getAttribute('data-presentation-state'),
	).toBe('content');
	expect(
		document
			.querySelector('[data-bridge-region="review-content"]')
			?.getAttribute('data-presentation-state'),
	).toBe('failed');
});

test('a failed refresh keeps its healthy comparison labelled stale', async (): Promise<void> => {
	const reviewPackage = {
		...makeBridgeReviewPackage(),
		comparisonOrigin: {
			kind: 'contribution',
			baseOID: 'a'.repeat(40),
			baseRole: 'commonCommit',
			comparedRole: 'capturedWorkingTree',
			resolvedTargetOID: 'b'.repeat(40),
			reviewedHeadOID: 'c'.repeat(40),
			symbolicTarget: { basis: 'commonCommit', branchName: 'master', kind: 'localDefaultBranch' },
		},
	} satisfies BridgeReviewPackage;
	const rendered = await render(
		<BridgeReviewComparisonControlTestHost
			comparisonPresentation={{
				activeTarget: { basis: 'commonCommit', branchName: 'master', kind: 'localDefaultBranch' },
				repositoryDefaultTarget: null,
				attempt: { status: 'unavailable', failureKind: 'refreshUnavailable', retryable: true },
				displayedSnapshot: {
					packageId: reviewPackage.packageId,
					reviewGeneration: reviewPackage.reviewGeneration,
					revision: reviewPackage.revision,
					status: 'stale',
				},
			}}
			displayedReviewPackage={reviewPackage}
			onApplyTarget={vi.fn()}
		/>,
	);
	await expect
		.element(rendered.getByTestId('bridge-review-comparison-trigger'))
		.toHaveAttribute('aria-label', 'Compare to: master · Stale');
	await performComparisonAction(async (): Promise<void> => {
		await rendered.getByTestId('bridge-review-comparison-trigger').click();
	});
	expect(rendered.getByText('Update unavailable', { exact: true }).query()).toBeNull();
});
