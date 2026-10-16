import { act } from 'react';
import { afterEach, beforeEach, describe, expect, test, vi } from 'vitest';
import { render } from 'vitest-browser-react';
import { page } from 'vitest/browser';

// oxlint-disable-next-line import/no-unassigned-import -- Browser Mode loads the production app CSS.
import './bridge-app.css';
import { installBridgeFileViewerNoopResizeObserver } from '../file-viewer/bridge-file-viewer-browser-test-harness.js';
import { createBridgeTelemetryRecorder } from '../foundation/telemetry/bridge-telemetry-recorder.js';
import {
	makeReviewSurfaceHarness,
	hierarchicalReviewDisplayEvent,
	settleRenderedReviewFrame,
} from './bridge-app-review-render-snapshot-controller.browser-harness.test-support.js';
import { BridgeReviewViewerMode } from './bridge-app-review-viewer-mode.js';

const originalResizeObserver = globalThis.ResizeObserver;
beforeEach((): void => installBridgeFileViewerNoopResizeObserver());
afterEach((): void => {
	globalThis.ResizeObserver = originalResizeObserver;
});

describe('Review installation failure Retry in the real viewer composition', () => {
	test('a W4-ready surface sends only view Retry and keeps failure and last-good rows until INST succeeds', async () => {
		const harness = makeReviewSurfaceHarness();
		const rendered = await render(
			<div className="h-[600px] w-[720px]">
				<BridgeReviewViewerMode
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
			harness.publish(hierarchicalReviewDisplayEvent());
			await import('../review-viewer/shell/review-viewer-shell.js');
			await settleRenderedReviewFrame();
		});
		await expect.element(rendered.getByTestId('review-viewer-shell')).toBeVisible();
		const store = harness.reviewClient.renderStore;
		const active = store.getReviewRefreshPresentation().activeIdentity;
		if (active === null) throw new Error('Last-good Review must be installed.');
		const lastGoodPath = store.getReviewTreeRowAtIndex(0)?.path;
		const failed = {
			...active,
			publicationId: '00000000-0000-7000-8000-000000000099',
			revision: active.revision + 1,
		};
		await act(async (): Promise<void> => {
			expect(
				store.startReviewCandidate({ disposition: { kind: 'replacement' }, identity: failed }),
			).toBe(true);
			expect(store.markReviewCandidateReady({ identity: failed, role: 'installing' })).toBe(true);
			expect(store.failReviewInstallation(failed)).toBe(true);
			store.applyViewRecoveryStatusEvent({
				direction: 'serverWorkerToMain',
				kind: 'viewRecoveryStatus',
				status: 'ready',
				view: { kind: 'review.metadata', subscriptionId: 'ready-review-e3' },
				transferDescriptors: [],
				wireVersion: 1,
			});
			await settleRenderedReviewFrame();
		});
		await expect
			.element(rendered.getByRole('button', { name: 'Retry', exact: true }))
			.toBeVisible();
		const commandCount = harness.sentCommands.length;
		await act(async (): Promise<void> => {
			await rendered.getByRole('button', { name: 'Retry', exact: true }).click();
		});
		expect(
			harness.sentCommands
				.slice(commandCount)
				.filter((command) => command.command === 'viewRecoveryRetry'),
		).toHaveLength(1);
		expect(
			harness.sentCommands
				.slice(commandCount)
				.some((command) => command.command === 'reviewComparisonUpdate'),
		).toBe(false);
		expect(store.getReviewRefreshPresentation().failure).toMatchObject({
			kind: 'installation',
			identity: failed,
		});
		expect(store.getReviewTreeRowAtIndex(0)?.path).toBe(lastGoodPath);
		await act(async (): Promise<void> => {
			await settleRenderedReviewFrame();
			await page.screenshot({ path: '../../../tmp/C14-installation-failure-viewer.png' });
			await rendered.unmount();
		});
	});
});
