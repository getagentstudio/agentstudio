import { act, type ReactElement } from 'react';
import { expect, test } from 'vitest';
import { render } from 'vitest-browser-react';
import { page } from 'vitest/browser';
import { z } from 'zod';

// oxlint-disable-next-line import/no-unassigned-import -- Exercise the production failed-start shell.
import './bridge-app.css';
import { BridgePageConfigurationReadError } from '../bridge/bridge-page-configuration.js';
import { BridgeAppInitialComposition } from './bridge-app-initial-composition.js';
import {
	BridgePaneFailureMessage,
	BridgeRegionPresentation,
} from './bridge-region-presentation.js';
import { BridgeViewerRecoveryRetryButton } from './bridge-viewer-recovery-retry-button.js';
import { BridgeViewerRightRailShell } from './bridge-viewer-right-rail-shell.js';

test('mounted retained failed-start rail resolves the bootstrap catalog and posts the same page command', async (): Promise<void> => {
	const requests: unknown[] = [];
	const replayCatalog = (): void => {
		document.dispatchEvent(
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
	};
	const receiveCommand = (event: Event): void => {
		if ('detail' in event) requests.push(event.detail);
	};
	document.addEventListener('__bridge_handshake_request', replayCatalog);
	document.addEventListener('__bridge_page_command_request', receiveCommand);
	const failedStart = {
		kind: 'failed',
		retainsContent: true,
		failure: { kind: 'retryable', scope: 'pane', message: 'Pane bootstrap failed' },
	} as const;
	const surfaceRetry = (): never => {
		throw new Error('Failed start must use only the native page command.');
	};
	let rendered: Awaited<ReturnType<typeof render>> | null = null;
	try {
		rendered = await render(
			<div className="flex h-[600px] w-[960px]">
				<BridgeRegionPresentation region="review-content" shape="diff" state={failedStart}>
					<p>Last good diff remains readable</p>
				</BridgeRegionPresentation>
				<BridgeViewerRightRailShell
					layout="stack"
					testId="mounted-rail"
					toolbar={<span>Review</span>}
					toolbarBelow={
						<BridgePaneFailureMessage
							entries={[{ part: 'review', state: failedStart, retry: surfaceRetry }]}
							retryControl={(retry): ReactElement => (
								<BridgeViewerRecoveryRetryButton surface="pane" onClick={retry} />
							)}
						/>
					}
					bodyTestId="mounted-tree"
					body={
						<BridgeRegionPresentation region="review-tree" shape="tree" state={failedStart}>
							Installed tree
						</BridgeRegionPresentation>
					}
				/>
			</div>,
		);
		expect(
			rendered.getByRole('button', { name: 'Reload Bridge', exact: true }).query(),
		).not.toBeNull();
		expect(rendered.getByRole('button', { name: 'Retry', exact: true }).query()).toBeNull();
		expect(document.querySelector('[data-command-icon="arrow.clockwise"]')).not.toBeNull();
		expect(document.querySelectorAll('[data-testid="bridge-pane-failure-summary"]')).toHaveLength(
			1,
		);
		await expect.element(rendered.getByText('Last good diff remains readable')).toBeVisible();
		expect(
			rendered.getByTestId('bridge-pane-failure-summary').element().getBoundingClientRect().bottom,
		).toBeLessThanOrEqual(
			rendered.getByTestId('mounted-tree').element().getBoundingClientRect().top,
		);
		await act(async (): Promise<void> => {
			await rendered?.getByRole('button', { name: 'Reload Bridge', exact: true }).click();
		});
		expect(requests).toHaveLength(1);
		expect(
			z
				.object({ command: z.literal('reloadBridgeWebView'), requestId: z.uuidv7() })
				.strict()
				.parse(requests[0]).command,
		).toBe('reloadBridgeWebView');
		await act(async (): Promise<void> => {
			await page.screenshot({ path: '../../../tmp/g1-F-failed-start-rail.png' });
		});
	} finally {
		await act(async (): Promise<void> => {
			await rendered?.unmount();
		});
		document.removeEventListener('__bridge_handshake_request', replayCatalog);
		document.removeEventListener('__bridge_page_command_request', receiveCommand);
	}
});

test.each(['Reload Bridge', 'Fixture catalog label'])(
	'failed configuration projects catalog command %s and sends one pre-session run command',
	async (catalogLabel): Promise<void> => {
		const target = new EventTarget();
		const commandRequests: unknown[] = [];
		const catalogCommand = {
			command: 'reloadBridgeWebView',
			label: catalogLabel,
			helpText:
				'Reload the Bridge browser page and discard browser presentation state without refreshing worktree source data',
			icon: 'arrow.clockwise',
		};
		target.addEventListener('__bridge_handshake_request', (): void => {
			target.dispatchEvent(
				new CustomEvent('__bridge_handshake', { detail: { pageCommands: [catalogCommand] } }),
			);
		});
		target.addEventListener('__bridge_page_command_request', (event: Event): void => {
			if ('detail' in event) commandRequests.push(event.detail);
		});
		const rendered = await render(
			<BridgeAppInitialComposition
				target={target}
				viewerMode="file"
				paneRuntimeFactory={(): never => {
					throw new BridgePageConfigurationReadError();
				}}
				readyContent={(): ReactElement => <span>Unexpected runtime</span>}
			/>,
		);
		try {
			expect(document.body.textContent).toContain("Bridge couldn't start.");
			const reload = rendered.getByRole('button', { name: catalogLabel, exact: true });
			expect(reload.query()).not.toBeNull();
			expect(document.querySelectorAll('[data-testid="bridge-pane-failure-summary"]')).toHaveLength(
				1,
			);
			expect(document.querySelector('[data-command-icon="arrow.clockwise"]')).not.toBeNull();
			expect(rendered.getByRole('button', { name: 'Retry', exact: true }).query()).toBeNull();
			expect(commandRequests).toHaveLength(0);
			await reload.click();
			expect(commandRequests).toHaveLength(1);
			const commandRequest = z
				.object({ command: z.literal('reloadBridgeWebView'), requestId: z.uuidv7() })
				.strict()
				.parse(commandRequests[0]);
			expect(commandRequest.command).toBe('reloadBridgeWebView');
			if (catalogLabel === 'Reload Bridge') {
				await act(async (): Promise<void> => {
					await page.screenshot({ path: '../../../tmp/g1-F2-native-catalog-reload.png' });
				});
			}
		} finally {
			await act(async (): Promise<void> => {
				await rendered.unmount();
			});
		}
	},
);
