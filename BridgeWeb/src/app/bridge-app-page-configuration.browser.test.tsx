import { afterEach, expect, test } from 'vitest';
import { cleanup, render } from 'vitest-browser-react';

import {
	createBridgePaneRuntime,
	type BridgePaneRuntime,
} from '../core/comm-worker/bridge-pane-runtime.js';
import { actUpdate, actWait } from './bridge-app-browser-test-actions.js';
import { BridgeAppProtocolRouter } from './bridge-app-protocol-router.js';
import type { BridgePaneReloadPort } from './bridge-pane-reload-port.js';

let runtime: BridgePaneRuntime | null = null;

afterEach(async (): Promise<void> => {
	await actWait(async (): Promise<void> => cleanup());
	runtime?.dispose();
	runtime = null;
});

test.each([undefined, { readyAcknowledgementDeadlineMilliseconds: -1 }])(
	'missing or invalid page configuration ends in pane failed start (%j)',
	async (pageConfiguration): Promise<void> => {
		const target = new EventTarget();
		let readyRequestCount = 0;
		let reloadRequestCount = 0;
		target.addEventListener('__bridge_ready', (): void => {
			readyRequestCount += 1;
		});
		target.addEventListener('__bridge_handshake_request', (): void => {
			target.dispatchEvent(
				new CustomEvent('__bridge_handshake', { detail: { pageConfiguration } }),
			);
		});
		const paneRuntime = createBridgePaneRuntime({
			sessionFactory: () => ({
				createDispatcher: () => ({ dispatch: (): void => {}, dispose: (): void => {} }),
				dispose: (): void => {},
				installNativeBootstrap: (): void => {},
				handleNativeBootstrapFailure: (): void => {},
				setNativeBootstrapRequester: (): void => {},
			}),
		});
		runtime = paneRuntime;
		const paneReloadPort = {
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
		const rendered = await actWait(async () =>
			render(
				<BridgeAppProtocolRouter
					target={target}
					paneRuntime={paneRuntime}
					paneReloadPort={paneReloadPort}
					codeViewWorkerPoolEnabled={false}
					protocol="review"
				/>,
			),
		);
		await expect.element(rendered.getByRole('alert')).toHaveTextContent("Bridge couldn't start.");
		expect(readyRequestCount).toBe(0);
		expect(
			document
				.querySelector('[data-bridge-region="pane-failure"]')
				?.getAttribute('data-presentation-state'),
		).toBe('failed');
		await actUpdate(async (): Promise<void> => {
			await rendered.getByRole('button', { name: 'Retry pane' }).click();
		});
		expect(reloadRequestCount).toBe(1);
	},
);

test.each([undefined, { readyAcknowledgementDeadlineMilliseconds: -1 }])(
	'default runtime reports missing or invalid document-start configuration as pane failed start (%j)',
	async (pageConfiguration): Promise<void> => {
		const replayWithoutConfiguration = (event: Event): void => {
			event.stopImmediatePropagation();
			document.dispatchEvent(
				new CustomEvent('__bridge_handshake', { detail: { pageConfiguration } }),
			);
		};
		document.addEventListener('__bridge_handshake_request', replayWithoutConfiguration, {
			capture: true,
		});
		try {
			const rendered = await actWait(async () =>
				render(<BridgeAppProtocolRouter codeViewWorkerPoolEnabled={false} protocol="review" />),
			);
			await expect.element(rendered.getByRole('alert')).toHaveTextContent("Bridge couldn't start.");
			expect(
				document
					.querySelector('[data-bridge-region="pane-failure"]')
					?.getAttribute('data-presentation-state'),
			).toBe('failed');
		} finally {
			document.removeEventListener('__bridge_handshake_request', replayWithoutConfiguration, {
				capture: true,
			});
		}
	},
);
