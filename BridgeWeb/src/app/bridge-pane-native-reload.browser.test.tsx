import { act, type ReactElement } from 'react';
import { expect, test } from 'vitest';
import { render } from 'vitest-browser-react';
import { page } from 'vitest/browser';
import { z } from 'zod';

// oxlint-disable-next-line import/no-unassigned-import -- Exercise the production failed-start shell.
import './bridge-app.css';
import { BridgePageConfigurationReadError } from '../bridge/bridge-page-configuration.js';
import { BridgeAppInitialComposition } from './bridge-app-initial-composition.js';

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
