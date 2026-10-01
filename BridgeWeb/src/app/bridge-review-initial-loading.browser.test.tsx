import { act, type ReactElement } from 'react';
import { expect, test, vi } from 'vitest';
import { render } from 'vitest-browser-react';
import { page } from 'vitest/browser';

import { makeBridgeMainCodeViewItem } from '../core/comm-worker/bridge-main-render-snapshot-store.test-support.js';

// oxlint-disable-next-line import/no-unassigned-import -- Exercise the production Review layout and skeletons.
import './bridge-app.css';
import { createBridgeTelemetryRecorder } from '../foundation/telemetry/bridge-telemetry-recorder.js';
import {
	makeReviewSurfaceHarness,
	reviewDisplayEvent,
	settleRenderedReviewFrame,
} from './bridge-app-review-render-snapshot-controller.browser-harness.test-support.js';
import { BridgeReviewViewerMode } from './bridge-app-review-viewer-mode.js';

test('cold Review waits for its first source with skeletons instead of no-target copy', async (): Promise<void> => {
	const harness = makeReviewSurfaceHarness();
	const rendered = await render(reviewMode(harness));
	for (const region of ['review-content', 'review-tree']) {
		const element = document.querySelector(`[data-bridge-region="${region}"]`);
		expect(element?.getAttribute('data-presentation-state')).toBe('loading');
		expect(element?.querySelector('[data-slot="skeleton"]')).not.toBeNull();
		expect(
			element?.querySelector('[data-skeleton-shape]')?.getAttribute('data-skeleton-shape'),
		).toBe(region === 'review-content' ? 'diff' : 'tree');
	}
	expect(document.body.textContent).not.toContain('Choose a comparison target');
	await page.screenshot({ path: '../../../tmp/g1-L-cold-review-loading.png' });

	await act(async (): Promise<void> => {
		harness.publish(
			reviewDisplayEvent({
				itemId: 'cold-review-item',
				path: 'First.swift',
				projectionRevision: 1,
				sequence: 1,
				startIndex: 0,
				totalItemCount: 1,
			}),
		);
		await import('../review-viewer/shell/review-viewer-shell.js');
		await settleRenderedReviewFrame();
		const contentItem = makeBridgeMainCodeViewItem('cold-review-item');
		if (contentItem.type !== 'file') throw new Error('Cold source fixture requires a file body.');
		harness.reviewClient.renderStore.applySnapshotUpdate({
			codeViewItemPatches: [
				{
					operation: 'upsert',
					itemId: contentItem.id,
					item: {
						...contentItem,
						file: {
							name: 'First.swift',
							contents: 'let firstSourceArrived = true;\n',
							lang: 'swift',
						},
						bridgeMetadata: { ...contentItem.bridgeMetadata, displayPath: 'First.swift' },
					},
				},
			],
			workerPatches: [
				{
					slice: 'contentAvailability',
					operation: 'upsert',
					itemId: contentItem.id,
					payload: { state: 'ready' },
				},
			],
		});
		await settleRenderedReviewFrame();
	});
	await expect.element(rendered.getByTestId('bridge-review-canvas')).toBeVisible();
	await expect
		.element(
			rendered.getByTestId('bridge-code-view-panel').getByText('First.swift', { exact: true }),
		)
		.toBeVisible();
	expect(
		document
			.querySelector('[data-bridge-region="review-tree"]')
			?.getAttribute('data-presentation-state'),
	).toBe('content');
	expect(document.body.textContent).not.toContain('Choose a comparison target');
	await page.screenshot({ path: '../../../tmp/g1-L-review-source-arrived.png' });
});

test('native selectionRequired certifies the no-target line', async (): Promise<void> => {
	const harness = makeReviewSurfaceHarness();
	harness.reviewClient.renderStore.applyWorkerPatch({
		slice: 'panelChrome',
		operation: 'upsert',
		payload: {
			reviewComparison: {
				activeTarget: null,
				attempt: { status: 'selectionRequired' },
				displayedSnapshot: { status: 'none' },
				repositoryDefaultTarget: null,
			},
		},
	});
	const rendered = await render(reviewMode(harness));
	await expect
		.element(rendered.getByText('Choose a comparison target', { exact: true }).first())
		.toBeVisible();
	for (const region of ['review-content', 'review-tree'])
		expect(
			document.querySelector(`[data-bridge-region="${region}"]`)?.getAttribute('data-empty-reason'),
		).toBe('noSelection');
	expect(document.querySelector('[data-slot="skeleton"]')).toBeNull();
	await page.screenshot({ path: '../../../tmp/g1-L-certified-no-target.png' });
});

function reviewMode(harness: ReturnType<typeof makeReviewSurfaceHarness>): ReactElement {
	return (
		<div className="h-[600px] w-[960px]">
			<BridgeReviewViewerMode
				codeViewWorkerPoolEnabled={false}
				isActive
				isNavigationCommandStillEligible={(): boolean => true}
				onActiveSourceChange={vi.fn()}
				onNavigationSourceChange={vi.fn()}
				reviewClient={harness.reviewClient}
				telemetryRecorderRef={{ current: createBridgeTelemetryRecorder(null) }}
				viewerContextSwitcher={<span>Review</span>}
			/>
		</div>
	);
}
