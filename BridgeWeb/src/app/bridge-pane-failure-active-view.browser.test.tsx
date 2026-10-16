import { act, useState, type ReactElement } from 'react';
import { expect, test, vi } from 'vitest';
import { render } from 'vitest-browser-react';

// oxlint-disable-next-line import/no-unassigned-import -- Production viewer composition.
import './bridge-app.css';
import { BridgeFileViewerAppImplementation } from '../file-viewer/bridge-file-viewer-app.js';
import { BridgeFileViewerSurfaceClientProvider } from '../file-viewer/bridge-file-viewer-render-snapshot-controller.js';
import { BridgeFileViewerShell } from '../file-viewer/bridge-file-viewer-shell.js';
import { createBridgeTelemetryRecorder } from '../foundation/telemetry/bridge-telemetry-recorder.js';
import { WorktreeAnnotationSurfaceProvider } from '../worktree-annotations/worktree-annotation-surface-provider.js';
import {
	makeFileSurfaceHarness,
	makeReviewSurfaceHarness,
	settleRenderedReviewFrame,
} from './bridge-app-review-render-snapshot-controller.browser-harness.test-support.js';
import { BridgeReviewViewerMode } from './bridge-app-review-viewer-mode.js';
import { BridgeViewerContextSwitcher } from './bridge-viewer-content-header.js';

test('an inactive File failure appears only after switching to Files, whose existing controller retries it', async (): Promise<void> => {
	const fileHarness = makeFileSurfaceHarness();
	const reviewHarness = makeReviewSurfaceHarness();
	const rendered = await render(
		<ActiveViewFixture fileHarness={fileHarness} reviewHarness={reviewHarness} />,
	);
	await act(async (): Promise<void> => {
		fileHarness.fileViewClient.renderStore.applyViewRecoveryStatusEvent({
			direction: 'serverWorkerToMain',
			kind: 'viewRecoveryStatus',
			status: 'failedRetryable',
			view: { kind: 'file.metadata', subscriptionId: 'failed-file-view' },
			transferDescriptors: [],
			wireVersion: 1,
		});
		await settleRenderedReviewFrame();
	});
	expect(document.querySelector('[data-testid="bridge-pane-failure-summary"]')).toBeNull();
	expect(document.body.innerText).not.toContain("Files couldn't load.");
	await act(async (): Promise<void> => {
		await rendered
			.getByTestId('active-review')
			.getByRole('button', { name: 'Files', exact: true })
			.click();
		await settleRenderedReviewFrame();
	});
	await expect.element(rendered.getByText("Files couldn't load.", { exact: true })).toBeVisible();
	expect(document.querySelectorAll('[data-testid="bridge-pane-failure-summary"]')).toHaveLength(1);
	expect(document.querySelectorAll('[data-bridge-region="file-tree"] button')).toHaveLength(0);
	const send = vi.mocked(fileHarness.fileViewClient.send);
	const beforeRetry = send.mock.calls.length;
	await act(async (): Promise<void> => {
		await rendered.getByRole('button', { name: 'Retry', exact: true }).click();
		await settleRenderedReviewFrame();
	});
	expect(send.mock.calls.slice(beforeRetry).map(([command]) => command.command)).toEqual([
		'viewRecoveryRetry',
		'fileRefreshRetry',
	]);
	await act(async (): Promise<void> => {
		await rendered.unmount();
	});
	fileHarness.fileViewClient.renderStore.dispose();
	reviewHarness.reviewClient.renderStore.dispose();
});

test('opening the comparison chooser never duplicates the pane failure message or Retry', async (): Promise<void> => {
	const harness = makeReviewSurfaceHarness();
	harness.reviewClient.renderStore.applyWorkerPatch({
		slice: 'panelChrome',
		operation: 'upsert',
		payload: {
			reviewComparison: {
				activeTarget: { kind: 'ref', name: 'main', basis: 'commonCommit' },
				attempt: { status: 'unavailable', failureKind: 'refreshUnavailable', retryable: true },
				displayedSnapshot: { status: 'none' },
				repositoryDefaultTarget: null,
			},
		},
	});
	const rendered = await render(
		<div className="h-[600px] w-[960px]">
			<BridgeReviewViewerMode
				isActive
				isNavigationCommandStillEligible={(): boolean => true}
				onActiveSourceChange={vi.fn()}
				onNavigationSourceChange={vi.fn()}
				reviewClient={harness.reviewClient}
				telemetryRecorderRef={{ current: createBridgeTelemetryRecorder(null) }}
				viewerContextSwitcher={<span>Review</span>}
			/>
		</div>,
	);
	await act(async (): Promise<void> => {
		await rendered.getByTestId('bridge-review-comparison-trigger').click();
		await settleRenderedReviewFrame();
	});
	expect(rendered.getByRole('button', { name: 'Retry', exact: true }).all()).toHaveLength(1);
	expect(document.querySelectorAll('[data-testid="bridge-pane-failure-summary"]')).toHaveLength(1);
	expect(
		rendered.getByTestId('bridge-review-comparison-content').element().textContent,
	).not.toContain('unavailable');
	await act(async (): Promise<void> => {
		await rendered.unmount();
	});
	harness.reviewClient.renderStore.dispose();
});

function ActiveViewFixture(props: {
	readonly fileHarness: ReturnType<typeof makeFileSurfaceHarness>;
	readonly reviewHarness: ReturnType<typeof makeReviewSurfaceHarness>;
}): ReactElement {
	const [mode, setMode] = useState<'file' | 'review'>('review');
	const contextSwitcher = <BridgeViewerContextSwitcher mode={mode} onModeChange={setMode} />;
	return (
		<div className="h-[600px] w-[960px]">
			<div hidden={mode !== 'file'} className="h-full" data-testid="active-file">
				<BridgeFileViewerSurfaceClientProvider surfaceClient={props.fileHarness.fileViewClient}>
					<WorktreeAnnotationSurfaceProvider surfaceClient={props.fileHarness.fileViewClient}>
						<BridgeFileViewerAppImplementation
							shellComponent={BridgeFileViewerShell}
							isActive={mode === 'file'}
							codeViewWorkerPoolEnabled={false}
							viewerContextSwitcher={contextSwitcher}
						/>
					</WorktreeAnnotationSurfaceProvider>
				</BridgeFileViewerSurfaceClientProvider>
			</div>
			<div hidden={mode !== 'review'} className="h-full" data-testid="active-review">
				<BridgeReviewViewerMode
					isActive={mode === 'review'}
					isNavigationCommandStillEligible={(): boolean => true}
					onActiveSourceChange={vi.fn()}
					onNavigationSourceChange={vi.fn()}
					reviewClient={props.reviewHarness.reviewClient}
					telemetryRecorderRef={{ current: createBridgeTelemetryRecorder(null) }}
					viewerContextSwitcher={contextSwitcher}
				/>
			</div>
		</div>
	);
}
