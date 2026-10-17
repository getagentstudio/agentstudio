import { act } from 'react';
import { expect, test, vi } from 'vitest';
import { render } from 'vitest-browser-react';
import { page } from 'vitest/browser';

// oxlint-disable-next-line import/no-unassigned-import -- Exercise the production File rail and W6 summary.
import './bridge-app.css';
import { bridgeProductFileRefreshFailureSchema } from '../core/comm-worker/bridge-product-session-contracts.js';
import { BridgeFileViewerAppImplementation } from '../file-viewer/bridge-file-viewer-app.js';
import { BridgeFileViewerSurfaceClientProvider } from '../file-viewer/bridge-file-viewer-render-snapshot-controller.js';
import { BridgeFileViewerShell } from '../file-viewer/bridge-file-viewer-shell.js';
import { WorktreeAnnotationSurfaceProvider } from '../worktree-annotations/worktree-annotation-surface-provider.js';
import { makeFileSurfaceHarness } from './bridge-app-review-render-snapshot-controller.browser-harness.test-support.js';

const rootFailureCases = [
	{
		failureKind: 'missingRoot',
		retryable: true,
		copy: "Files couldn't load. The worktree folder is missing.",
	},
	{
		failureKind: 'unreadableRoot',
		retryable: true,
		copy: "Files couldn't load. The worktree folder can't be read.",
	},
	{ failureKind: 'fileSourceUnavailable', retryable: true, copy: "Files couldn't load." },
	{ failureKind: 'fileRefreshFailed', retryable: false, copy: "Files couldn't load." },
	{ failureKind: 'producerRejected', retryable: false, copy: "Files couldn't load." },
] as const;

for (const failedView of [false, true]) {
	test.each(rootFailureCases)(
		'$failureKind uses one File rail message and its own recovery (failed view ' +
			String(failedView) +
			')',
		async (scenario): Promise<void> => {
			const harness = makeFileSurfaceHarness();
			if (failedView)
				harness.fileViewClient.renderStore.applyViewRecoveryStatusEvent({
					direction: 'serverWorkerToMain',
					kind: 'viewRecoveryStatus',
					status: 'failedRetryable',
					view: { kind: 'file.metadata', subscriptionId: 'failed-root-view' },
					transferDescriptors: [],
					wireVersion: 1,
				});
			harness.fileViewClient.renderStore.applyWorkerPatch({
				slice: 'panelChrome',
				operation: 'upsert',
				payload: {
					fileRefreshFailure: bridgeProductFileRefreshFailureSchema.parse({
						failureKind: scenario.failureKind,
						retryable: scenario.retryable,
					}),
				},
			});
			const rendered = await render(
				<div className="h-[600px] w-[960px]">
					<BridgeFileViewerSurfaceClientProvider surfaceClient={harness.fileViewClient}>
						<WorktreeAnnotationSurfaceProvider surfaceClient={harness.fileViewClient}>
							<BridgeFileViewerAppImplementation
								shellComponent={BridgeFileViewerShell}
								isActive
								codeViewWorkerPoolEnabled={false}
								viewerContextSwitcher={<span>Files</span>}
							/>
						</WorktreeAnnotationSurfaceProvider>
					</BridgeFileViewerSurfaceClientProvider>
				</div>,
			);
			try {
				const summary = rendered.getByTestId('bridge-pane-failure-summary');
				expect(
					document.querySelectorAll('[data-testid="bridge-pane-failure-summary"]'),
				).toHaveLength(1);
				expect(summary.element().textContent).toContain(scenario.copy);
				await expect.element(summary).toBeVisible();
				expect(document.querySelectorAll('[role="alert"]')).toHaveLength(1);
				const tree = document.querySelector('[data-bridge-region="file-tree"]');
				if (!(tree instanceof HTMLElement))
					throw new Error('Expected the production File tree region.');
				expect(summary.element().getBoundingClientRect().bottom).toBeLessThanOrEqual(
					tree.getBoundingClientRect().top,
				);
				expect(
					document.querySelectorAll(
						'[data-bridge-region]:not([data-bridge-region="pane-failure"]) [role="alert"], [data-bridge-region]:not([data-bridge-region="pane-failure"]) button',
					),
				).toHaveLength(0);
				const retry = rendered.getByRole('button', { name: 'Retry', exact: true });
				const send = vi.mocked(harness.fileViewClient.send);
				const beforeRetry = send.mock.calls.length;
				if (scenario.retryable) {
					expect(retry.all()).toHaveLength(1);
					await act(async (): Promise<void> => {
						await retry.click();
					});
					expect(send.mock.calls.slice(beforeRetry).map(([command]) => command.command)).toEqual(
						failedView ? ['viewRecoveryRetry', 'fileRefreshRetry'] : ['fileRefreshRetry'],
					);
				} else {
					expect(retry.query()).toBeNull();
					await expect
						.element(summary)
						.toHaveTextContent('Correct the source failure, then reopen this worktree.');
					expect(send.mock.calls).toHaveLength(beforeRetry);
				}
				if (
					!failedView &&
					(scenario.failureKind === 'missingRoot' || scenario.failureKind === 'unreadableRoot')
				) {
					await act(async (): Promise<void> => {
						await page.screenshot({
							path: `../../../tmp/g1-file-root-${scenario.failureKind}-rail.png`,
						});
					});
				}
			} finally {
				await act(async (): Promise<void> => {
					await rendered.unmount();
				});
				harness.fileViewClient.renderStore.dispose();
			}
		},
	);
}
