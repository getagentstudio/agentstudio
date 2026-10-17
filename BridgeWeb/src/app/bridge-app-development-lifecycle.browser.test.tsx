import { StrictMode } from 'react';
import { afterEach, describe, expect, test, vi } from 'vitest';
import { cleanup, render } from 'vitest-browser-react';

// oxlint-disable-next-line import/no-unassigned-import -- Browser Mode renders the real app chrome.
import './bridge-app.css';
import { createBridgePaneRuntime } from '../core/comm-worker/bridge-pane-runtime.js';
import { actWait } from './bridge-app-browser-test-actions.js';
import { BridgeAppProtocolRouter } from './bridge-app-protocol-router.js';

describe('BridgeApp development lifecycle', () => {
	afterEach(async (): Promise<void> => {
		await actWait(async (): Promise<void> => cleanup());
		document.body.replaceChildren();
	});

	test('keeps a page-owned pane runtime alive through React effect replay', async () => {
		// Arrange
		const pageOwnedPaneRuntime = createNoopBridgePaneRuntime();
		const disposePaneRuntime = vi.spyOn(pageOwnedPaneRuntime, 'dispose');

		// Act: StrictMode replays effects while preserving component state, matching Fast Refresh cleanup.
		await actWait(async (): Promise<void> => {
			await render(
				<StrictMode>
					<BridgeAppProtocolRouter paneRuntime={pageOwnedPaneRuntime} protocol="review" />
				</StrictMode>,
			);
			await Promise.resolve();
		});

		// Assert
		expect(disposePaneRuntime).not.toHaveBeenCalled();
		await actWait(async (): Promise<void> => cleanup());
		expect(disposePaneRuntime).not.toHaveBeenCalled();
		pageOwnedPaneRuntime.dispose();
		expect(disposePaneRuntime).toHaveBeenCalledOnce();
	});
});

function createNoopBridgePaneRuntime(): ReturnType<typeof createBridgePaneRuntime> {
	return createBridgePaneRuntime({
		sessionFactory: () => ({
			createDispatcher: () => ({
				dispatch: (): void => {},
				dispose: (): void => {},
			}),
			dispose: (): void => {},
			setNativeBootstrapRequester: (): void => {},
			installNativeBootstrap: (): void => {},
		}),
	});
}
