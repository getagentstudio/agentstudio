import { afterEach, describe, expect, test, vi } from 'vitest';
import { cleanup, render } from 'vitest-browser-react';

// oxlint-disable-next-line import/no-unassigned-import -- Browser Mode renders the real app shell.
import './bridge-app.css';
import {
	createBridgePaneRuntime,
	type BridgePaneRuntime,
} from '../core/comm-worker/bridge-pane-runtime.js';
import {
	BRIDGE_WORKER_WIRE_VERSION,
	type BridgeWorkerServerToMainMessage,
} from '../core/comm-worker/bridge-worker-contracts.js';
import {
	actWait,
	installBridgeReadyHandshake,
	pollWithinActUntilEqual,
} from './bridge-app-browser-test-actions.js';
import { makeNativeSurfaceSelectionRequest } from './bridge-app-pane-runtime-control-test-support.js';
import { BridgeAppProtocolRouter } from './bridge-app-protocol-router.js';

const viewerActivationObservation = vi.hoisted(() => ({
	requests: [] as Array<{
		readonly activationSequence: number;
		readonly cause: string;
		readonly fromViewer: string;
		readonly viewer: string;
	}>,
}));

vi.mock('../foundation/telemetry/bridge-viewer-activation-telemetry.js', async (importOriginal) => {
	const actual =
		await importOriginal<
			typeof import('../foundation/telemetry/bridge-viewer-activation-telemetry.js')
		>();
	return {
		...actual,
		recordBridgeViewerActivationRequestedTelemetrySample: (props: {
			readonly activationSequence: number;
			readonly cause: string;
			readonly fromViewer: string;
			readonly viewer: string;
		}): void => {
			viewerActivationObservation.requests.push(props);
		},
	};
});

describe('BridgeApp viewer activation ingress', () => {
	let activeRuntime: BridgePaneRuntime | null = null;

	afterEach(async (): Promise<void> => {
		await actWait(async (): Promise<void> => cleanup());
		activeRuntime?.dispose();
		activeRuntime = null;
		viewerActivationObservation.requests = [];
		document.body.replaceChildren();
	});

	test('routes native surface selection through one viewer activation', async () => {
		// Arrange
		const handshake = installBridgeReadyHandshake();
		const runtimeFixture = makePaneRuntimeFixture();
		activeRuntime = runtimeFixture.runtime;
		await actWait(async (): Promise<void> => {
			await render(
				<BridgeAppProtocolRouter paneRuntime={runtimeFixture.runtime} protocol="review" />,
			);
			await runtimeFixture.workerPublicationInstalled;
		});
		const appRoot = requireAppRoot();

		// Act
		await actWait(async (): Promise<void> => {
			runtimeFixture.publish(
				makeNativeSurfaceSelectionRequest({
					bindingRevision: 1,
					nativeSelectionRequestId: 'native-file-activation',
					surface: 'file',
				}),
			);
			await Promise.resolve();
		});
		expect(
			await pollWithinActUntilEqual(() => appRoot.getAttribute('data-bridge-viewer-mode'), 'file'),
		).toBe('file');

		// Assert
		expectSingleFileActivation();
		handshake.dispose();
	});

	test('routes an incoming active-mode change through one viewer activation', async () => {
		// Arrange
		const handshake = installBridgeReadyHandshake();
		const runtimeFixture = makePaneRuntimeFixture();
		activeRuntime = runtimeFixture.runtime;
		const rendered = await actWait(async () => {
			const result = await render(
				<BridgeAppProtocolRouter paneRuntime={runtimeFixture.runtime} protocol="review" />,
			);
			await runtimeFixture.workerPublicationInstalled;
			return result;
		});
		const appRoot = requireAppRoot();

		// Act
		await actWait(async (): Promise<void> => {
			await rendered.rerender(
				<BridgeAppProtocolRouter paneRuntime={runtimeFixture.runtime} protocol="worktree-file" />,
			);
			await Promise.resolve();
		});
		expect(
			await pollWithinActUntilEqual(() => appRoot.getAttribute('data-bridge-viewer-mode'), 'file'),
		).toBe('file');

		// Assert
		expectSingleFileActivation();
		handshake.dispose();
	});
});

function makePaneRuntimeFixture(): {
	readonly publish: (message: BridgeWorkerServerToMainMessage) => void;
	readonly runtime: BridgePaneRuntime;
	// Settles when the mounted app's pane runtime installs its worker dispatcher,
	// the point from which the fixture can publish worker messages.
	readonly workerPublicationInstalled: Promise<void>;
} {
	let publishWorkerMessages:
		| ((messages: readonly BridgeWorkerServerToMainMessage[]) => void)
		| null = null;
	let resolveWorkerPublication: (() => void) | null = null;
	const workerPublicationInstalled = new Promise<void>((resolve): void => {
		resolveWorkerPublication = resolve;
	});
	const runtime = createBridgePaneRuntime({
		sessionFactory: () => ({
			createDispatcher: (props) => {
				publishWorkerMessages = props.publishWorkerMessages;
				resolveWorkerPublication?.();
				return {
					dispatch: (command): void => {
						props.publishWorkerMessages([
							{
								direction: 'serverWorkerToMain',
								kind: 'health',
								requestId: command.requestId,
								status: 'ready',
								transferDescriptors: [],
								wireVersion: BRIDGE_WORKER_WIRE_VERSION,
							},
						]);
					},
					dispose: (): void => {},
				};
			},
			dispose: (): void => {},
			installNativeBootstrap: (): void => {},
			handleNativeBootstrapFailure: (): void => {},
			setNativeBootstrapRequester: (): void => {},
		}),
	});
	return {
		publish: (message): void => {
			if (publishWorkerMessages === null) {
				throw new Error('Expected Bridge pane runtime message publication to be installed.');
			}
			publishWorkerMessages([message]);
		},
		runtime,
		workerPublicationInstalled,
	};
}

function requireAppRoot(): HTMLElement {
	const appRoot = document.querySelector('[data-testid="bridge-app-root"]');
	if (!(appRoot instanceof HTMLElement)) throw new Error('Expected Bridge app root.');
	return appRoot;
}

function expectSingleFileActivation(): void {
	expect(viewerActivationObservation.requests).toEqual([
		expect.objectContaining({
			activationSequence: 1,
			cause: 'native_request',
			fromViewer: 'review',
			viewer: 'file',
		}),
	]);
}
