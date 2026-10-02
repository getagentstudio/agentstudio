import { expect, test } from 'vitest';
import { render } from 'vitest-browser-react';
import { page } from 'vitest/browser';

import type { BridgePaneReloadPort } from './bridge-pane-reload-port.js';

// oxlint-disable-next-line import/no-unassigned-import -- Exercise the production style system.
import './bridge-app.css';
import {
	projectBridgeRegionPresentation,
	type BridgeRegionPresentationInput,
} from './bridge-region-presentation-state.js';
import { BridgeRegionPresentation } from './bridge-region-presentation.js';
import { BridgeViewerRecoveryRetryButton } from './bridge-viewer-recovery-retry-button.js';

const settledInput = {
	demandedIdentity: 'file-a',
	read: { kind: 'complete', identity: 'file-a', hasContent: true },
	surface: { kind: 'current' },
} satisfies BridgeRegionPresentationInput;

test('a settled sibling stays readable while newly selected content loads', async () => {
	const rendered = await render(
		<>
			<BridgeRegionPresentation
				region="tree"
				shape="tree"
				state={projectBridgeRegionPresentation(settledInput)}
			>
				Installed rows
			</BridgeRegionPresentation>
			<BridgeRegionPresentation
				region="content"
				shape="code"
				state={projectBridgeRegionPresentation({ ...settledInput, demandedIdentity: 'file-b' })}
			>
				Old file bytes
			</BridgeRegionPresentation>
		</>,
	);
	await expect.element(rendered.getByText('Installed rows')).toBeVisible();
	expect(document.querySelector('[data-bridge-region="tree"] [data-slot="skeleton"]')).toBeNull();
	expect(
		document.querySelector('[data-bridge-region="content"] [data-slot="skeleton"]'),
	).not.toBeNull();
	expect(document.body.textContent).not.toContain('Old file bytes');
});

test('no selection and certified empty have different quiet copy; partial coverage is never Empty', async () => {
	await render(
		<>
			<BridgeRegionPresentation
				region="selection"
				shape="code"
				state={projectBridgeRegionPresentation({ ...settledInput, demandedIdentity: null })}
				emptyCopy={{ noSelection: 'Select a file', certified: 'No files' }}
			/>
			<BridgeRegionPresentation
				region="empty"
				shape="tree"
				state={projectBridgeRegionPresentation({
					...settledInput,
					read: { kind: 'complete', identity: 'file-a', hasContent: false },
				})}
				emptyCopy={{ noSelection: 'Select a file', certified: 'No files' }}
			/>
			<BridgeRegionPresentation
				region="partial"
				shape="tree"
				state={projectBridgeRegionPresentation({
					...settledInput,
					read: { kind: 'partial', identity: 'file-a', hasContent: false },
				})}
			/>
		</>,
	);
	expect(document.querySelector('[data-bridge-region="selection"]')?.textContent).toBe(
		'Select a file',
	);
	expect(document.querySelector('[data-bridge-region="empty"]')?.textContent).toBe('No files');
	expect(
		document
			.querySelector('[data-bridge-region="partial"]')
			?.getAttribute('data-presentation-state'),
	).toBe('loading');
});

test('permanent failure overrides ready empty, states the correction, and has no Retry', async () => {
	await render(
		<BridgeRegionPresentation
			failureSummary
			region="permanent"
			shape="tree"
			state={projectBridgeRegionPresentation({
				...settledInput,
				read: { kind: 'complete', identity: 'file-a', hasContent: false },
				surface: {
					kind: 'failed',
					failure: {
						kind: 'permanent',
						scope: 'surface',
						message: 'Root unavailable',
						correctiveAction: 'Choose an accessible worktree.',
					},
				},
			})}
			retry={<BridgeViewerRecoveryRetryButton surface="file" onClick={() => undefined} />}
		/>,
	);
	expect(document.querySelector('[role="alert"]')?.textContent).toContain(
		'Choose an accessible worktree.',
	);
	expect(document.querySelector('button')).toBeNull();
	expect(document.querySelector('[data-slot="skeleton"]')).toBeNull();
});

test.each(['held', 'hidden'] as const)(
	'%s rest is quiet Updating over readable content',
	async (rest) => {
		await render(
			<BridgeRegionPresentation
				region="rest"
				shape="diff"
				state={projectBridgeRegionPresentation({
					...settledInput,
					surface: { kind: 'updating', rest },
				})}
			>
				Last good diff
			</BridgeRegionPresentation>,
		);
		expect(document.querySelector('[data-bridge-region="rest"]')?.textContent).toContain(
			'Last good diff',
		);
		expect(
			document
				.querySelector('[data-bridge-region="rest"]')
				?.getAttribute('data-presentation-state'),
		).toBe('updating');
		expect(
			document.querySelector('[data-slot="skeleton"], [data-busy="true"], .animate-spin'),
		).toBeNull();
	},
);

test('failed pane start keeps retained content readable and marked stale', async () => {
	let reloadRequestCount = 0;
	const paneReloadPort = {
		command: 'reloadBridgeWebView',
		display: {
			accessibleName: 'Retry',
			label: 'Retry',
			helpText: 'Native command display stand-in',
			icon: null,
		},
		requestPaneReload: (): void => {
			reloadRequestCount += 1;
		},
	} satisfies BridgePaneReloadPort;
	const rendered = await render(
		<BridgeRegionPresentation
			failureSummary
			region="retained"
			shape="code"
			state={projectBridgeRegionPresentation({
				...settledInput,
				surface: {
					kind: 'failed',
					failure: { kind: 'retryable', scope: 'pane', message: 'Bridge failed to start' },
				},
			})}
			paneReloadPort={paneReloadPort}
		>
			Retained code
		</BridgeRegionPresentation>,
	);
	await expect.element(rendered.getByText('Retained code')).toBeVisible();
	await expect.element(rendered.getByRole('button', { name: 'Retry' })).toBeVisible();
	await rendered.getByRole('button', { name: 'Retry' }).click();
	expect(reloadRequestCount).toBe(1);
	expect(
		document.querySelector('[data-bridge-region="retained"]')?.getAttribute('data-content-current'),
	).toBe('false');
	expect(document.querySelector('[data-slot="skeleton"]')).toBeNull();
	expect(document.body.textContent).not.toMatch(/loading|waiting|pending/i);
});

test('pane failure uses only the supplied native command projection and reload port stand-in', async () => {
	let reloadRequestCount = 0;
	const port = {
		command: 'reloadBridgeWebView',
		display: {
			accessibleName: 'Retry pane',
			label: 'Retry pane',
			helpText: 'Native command display stand-in',
			icon: null,
		},
		requestPaneReload: (): void => {
			reloadRequestCount += 1;
		},
	} satisfies BridgePaneReloadPort;
	const rendered = await render(
		<BridgeRegionPresentation
			failureSummary
			region="pane-stand-in"
			shape="code"
			paneReloadPort={port}
			state={projectBridgeRegionPresentation({
				...settledInput,
				surface: {
					kind: 'failed',
					failure: { kind: 'retryable', scope: 'pane', message: 'Bridge failed to start' },
				},
			})}
		>
			Retained document
		</BridgeRegionPresentation>,
	);
	await rendered.getByRole('button', { name: port.display.accessibleName }).click();
	expect(reloadRequestCount).toBe(1);
	await expect.element(rendered.getByText('Retained document')).toBeVisible();
	await page.screenshot({ path: '../../../tmp/g1-w6-pane-reload-stand-in.png' });
});

test.each([false, true])(
	'an unwired pane failure has no actionable control in its %s presentation',
	async (failureSummary): Promise<void> => {
		const rendered = await render(
			<BridgeRegionPresentation
				region="unwired-pane"
				shape="code"
				failureSummary={failureSummary}
				state={projectBridgeRegionPresentation({
					...settledInput,
					surface: {
						kind: 'failed',
						failure: { kind: 'retryable', scope: 'pane', message: 'Bridge failed to start' },
					},
				})}
				retry={
					<BridgeViewerRecoveryRetryButton
						surface="file"
						onClick={(): void => {
							throw new Error('A File Retry cannot reload a pane.');
						}}
					/>
				}
			>
				Retained pane content
			</BridgeRegionPresentation>,
		);
		await expect.element(rendered.getByText('Retained pane content')).toBeVisible();
		expect(document.querySelector('[data-bridge-region="unwired-pane"] button')).toBeNull();
		expect(document.querySelector('[data-slot="skeleton"], .animate-spin')).toBeNull();
	},
);
