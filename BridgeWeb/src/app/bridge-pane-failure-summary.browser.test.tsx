import { act, type ReactElement } from 'react';
import { expect, test, vi } from 'vitest';
import { render } from 'vitest-browser-react';
import { page } from 'vitest/browser';

// oxlint-disable-next-line import/no-unassigned-import -- Production layout proof.
import './bridge-app.css';
import { readNativeBridgePaneReloadPort } from './bridge-native-pane-reload-port.js';
import type { BridgePaneFailureEntry } from './bridge-pane-failure-summary.js';
import {
	BridgePaneFailureMessage,
	BridgeRegionPresentation,
} from './bridge-region-presentation.js';
import { BridgeViewerRecoveryRetryButton } from './bridge-viewer-recovery-retry-button.js';
import { BridgeViewerResizableRailLayout } from './bridge-viewer-resizable-rail-layout.js';
import { BridgeViewerRightRailShell } from './bridge-viewer-right-rail-shell.js';

const cases = [
	{
		name: 'review-update',
		part: 'review',
		retainsContent: true,
		copy: "Review couldn't update. Showing the last version.",
	},
	{ name: 'review-load', part: 'review', retainsContent: false, copy: "Review couldn't load." },
	{ name: 'comments', part: 'comments', retainsContent: false, copy: "Comments couldn't load." },
	{
		name: 'several',
		part: 'review',
		retainsContent: true,
		copy: "Review and comments couldn't update.",
	},
	{ name: 'file-read', part: 'file', retainsContent: false, copy: "Couldn't open First.swift." },
	{ name: 'failed-start', part: 'review', retainsContent: true, copy: "Bridge couldn't start." },
] as const;

for (const railShown of [true, false]) {
	test.each(cases)(
		'$name has one pane summary and no region controls (rail ' + String(railShown) + ')',
		async (scenario): Promise<void> => {
			const retry = vi.fn();
			const commentsRetry = vi.fn();
			const reload = vi.fn();
			const nativeTarget = new EventTarget();
			nativeTarget.addEventListener('__bridge_handshake_request', (): void => {
				nativeTarget.dispatchEvent(
					new CustomEvent('__bridge_handshake', {
						detail: {
							pageCommands: [
								{
									command: 'reloadBridgeWebView',
									label: 'Reload Bridge',
									helpText: 'Reload the Bridge browser page',
									icon: 'arrow.clockwise',
								},
							],
						},
					}),
				);
			});
			nativeTarget.addEventListener('__bridge_page_command_request', (event: Event): void => {
				if ('detail' in event) reload(event.detail);
			});
			const reloadPort = readNativeBridgePaneReloadPort(nativeTarget);
			if (reloadPort === undefined)
				throw new Error('Expected native bootstrap page command catalog.');
			const entry: BridgePaneFailureEntry = {
				part: scenario.part,
				fileName: scenario.name === 'file-read' ? 'Sources/First.swift' : null,
				retry,
				state: {
					kind: 'failed',
					retainsContent: scenario.retainsContent,
					failure: {
						kind: 'retryable',
						scope:
							scenario.name === 'failed-start'
								? 'pane'
								: scenario.name === 'file-read'
									? 'read'
									: 'surface',
						message: 'Old region failure copy',
					},
				},
			};
			const commentsEntry: BridgePaneFailureEntry = {
				...entry,
				part: 'comments',
				retry: commentsRetry,
			};
			const entries = scenario.name === 'several' ? [entry, commentsEntry] : [entry];
			const summary = (
				<BridgePaneFailureMessage
					entries={entries}
					retryControl={(onClick): ReactElement => (
						<BridgeViewerRecoveryRetryButton surface="review" onClick={onClick} />
					)}
					paneReloadPort={reloadPort}
				/>
			);
			const content = (
				<section className="flex h-full min-h-0 flex-col">
					<BridgeRegionPresentation
						region="review-content"
						shape="diff"
						state={entry.state}
						retry={<BridgeViewerRecoveryRetryButton surface="review" onClick={retry} />}
					>
						<div className="p-3">Last good diff</div>
					</BridgeRegionPresentation>
				</section>
			);
			const rendered = await render(
				<div className="flex h-[600px] w-[960px]">
					{
						<BridgeViewerResizableRailLayout
							railVisible={railShown}
							failureSummary={summary}
							autosaveId="failure-summary-proof"
							content={content}
							contentTestId="content"
							handleTestId="handle"
							railTestId="rail"
							rail={
								<BridgeViewerRightRailShell
									layout="stack"
									testId="sidebar"
									toolbar={<div className="p-2">Review</div>}
									toolbarBelow={summary}
									bodyTestId="tree"
									body={
										<BridgeRegionPresentation region="review-tree" shape="tree" state={entry.state}>
											Installed tree
										</BridgeRegionPresentation>
									}
								/>
							}
						/>
					}
				</div>,
			);
			expect(document.querySelectorAll('[data-testid="bridge-pane-failure-summary"]')).toHaveLength(
				1,
			);
			expect(document.querySelectorAll('[role="alert"]')).toHaveLength(1);
			expect(
				document.querySelectorAll(
					'[data-bridge-region]:not([data-bridge-region="pane-failure"]) [role="alert"], [data-bridge-region]:not([data-bridge-region="pane-failure"]) button',
				),
			).toHaveLength(0);
			await expect.element(rendered.getByText(scenario.copy, { exact: true })).toBeVisible();
			expect(document.querySelectorAll('button')).toHaveLength(1);
			if (railShown) {
				const failureRect = rendered
					.getByTestId('bridge-pane-failure-summary')
					.element()
					.getBoundingClientRect();
				const treeRect = rendered.getByTestId('tree').element().getBoundingClientRect();
				expect(failureRect.bottom).toBeLessThanOrEqual(treeRect.top);
				expect(failureRect.left).toBeGreaterThan(
					rendered.getByTestId('content').element().getBoundingClientRect().left,
				);
			}
			await act(async (): Promise<void> => {
				await rendered
					.getByRole('button', {
						name: scenario.name === 'failed-start' ? 'Reload Bridge' : 'Retry',
						exact: true,
					})
					.click();
			});
			if (scenario.name === 'failed-start') {
				expect(rendered.getByRole('button', { name: 'Retry', exact: true }).query()).toBeNull();
				expect(document.querySelector('[data-command-icon="arrow.clockwise"]')).not.toBeNull();
				expect(reload).toHaveBeenCalledWith(
					expect.objectContaining({ command: 'reloadBridgeWebView' }),
				);
			}
			expect(reload).toHaveBeenCalledTimes(scenario.name === 'failed-start' ? 1 : 0);
			expect(retry).toHaveBeenCalledTimes(scenario.name === 'failed-start' ? 0 : 1);
			expect(commentsRetry).toHaveBeenCalledTimes(scenario.name === 'several' ? 1 : 0);
			await act(async (): Promise<void> => {
				await page.screenshot({
					path: `../../../tmp/g1-F-${scenario.name}-${railShown ? 'rail' : 'content'}.png`,
				});
				await rendered.unmount();
			});
		},
	);
}

test.each(['mixed', 'permanent'] as const)(
	'%s failures retain corrective actions and retry only retryable parts',
	async (kind): Promise<void> => {
		const retryReview = vi.fn();
		const retryComments = vi.fn();
		const entries: readonly BridgePaneFailureEntry[] = [
			{
				part: 'review',
				retry: retryReview,
				state: {
					kind: 'failed',
					retainsContent: true,
					failure:
						kind === 'mixed'
							? { kind: 'retryable', scope: 'surface', message: 'Review update failed' }
							: {
									kind: 'permanent',
									scope: 'surface',
									message: 'Review update failed',
									correctiveAction: 'Choose an accessible comparison target.',
								},
				},
			},
			{
				part: 'comments',
				retry: retryComments,
				state: {
					kind: 'failed',
					retainsContent: false,
					failure: {
						kind: 'permanent',
						scope: 'surface',
						message: 'Comments failed',
						correctiveAction: 'Restore Comments history.',
					},
				},
			},
		];
		const rendered = await render(
			<BridgePaneFailureMessage
				entries={entries}
				retryControl={(onClick): ReactElement => (
					<BridgeViewerRecoveryRetryButton surface="pane" onClick={onClick} />
				)}
			/>,
		);
		await expect
			.element(rendered.getByRole('alert'))
			.toHaveTextContent("Review and comments couldn't update.");
		await expect
			.element(rendered.getByRole('alert'))
			.toHaveTextContent('Restore Comments history.');
		if (kind === 'mixed') {
			await act(async (): Promise<void> => {
				await rendered.getByRole('button', { name: 'Retry', exact: true }).click();
			});
			expect(retryReview).toHaveBeenCalledOnce();
		} else {
			await expect
				.element(rendered.getByRole('alert'))
				.toHaveTextContent('Choose an accessible comparison target.');
			expect(rendered.getByRole('button', { name: 'Retry', exact: true }).query()).toBeNull();
			expect(retryReview).not.toHaveBeenCalled();
		}
		expect(retryComments).not.toHaveBeenCalled();
	},
);
