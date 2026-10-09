import { afterEach, describe, expect, test } from 'vitest';
import { cleanup, render } from 'vitest-browser-react';

// oxlint-disable-next-line import/no-unassigned-import -- Browser Mode renders the real app chrome.
import './bridge-app.css';
import {
	createBridgePaneRuntime,
	type BridgePaneRuntime,
} from '../core/comm-worker/bridge-pane-runtime.js';
import type { BridgeWorkerMainToServerMessage } from '../core/comm-worker/bridge-worker-contracts.js';
import { BridgeProductTestFactRecorder } from '../core/comm-worker/test-fixtures/bridge-product-test-fact-recorder.js';
import {
	actWait,
	installControlledBridgeReadyHandshake,
} from './bridge-app-browser-test-actions.js';
import { BridgeAppProtocolRouter } from './bridge-app-protocol-router.js';

describe('BridgeApp ready-gated active mode', () => {
	let activePaneRuntime: BridgePaneRuntime | null = null;

	afterEach(async (): Promise<void> => {
		await actWait(async (): Promise<void> => cleanup());
		activePaneRuntime?.dispose();
		activePaneRuntime = null;
		document.body.replaceChildren();
	});

	test('forwards the initial Review activation after page readiness is acknowledged', async (context) => {
		// Arrange
		const paneCommands: BridgeWorkerMainToServerMessage[] = [];
		const commandFacts = new BridgeProductTestFactRecorder<BridgeWorkerMainToServerMessage>();
		let isRecording = true;
		const closeCommandObservation = (): void => {
			isRecording = false;
			commandFacts.close(new Error('Ready-gated command observation closed.'));
		};
		context.signal.addEventListener('abort', closeCommandObservation, { once: true });
		context.onTestFinished((): void => {
			context.signal.removeEventListener('abort', closeCommandObservation);
			closeCommandObservation();
		});
		const controlledHandshake = installControlledBridgeReadyHandshake();
		const paneRuntime = createRecordingBridgePaneRuntime(paneCommands, (command): void => {
			if (isRecording) commandFacts.record(command);
		});
		activePaneRuntime = paneRuntime;
		await actWait(async (): Promise<void> => {
			await render(
				<BridgeAppProtocolRouter
					codeViewWorkerPoolEnabled={false}
					fileViewerProps={{ autoOpenInitialFile: false }}
					paneRuntime={paneRuntime}
					protocol="review"
				/>,
			);
			await Promise.resolve();
		});
		const readyRequestId = await actWait(controlledHandshake.waitForReadyRequest);
		expect(readyRequestId).not.toBeNull();
		expect(activeViewerModeUpdates(paneCommands)).toHaveLength(0);

		// Act
		await actWait(async (): Promise<void> => {
			controlledHandshake.acknowledgeReady(readyRequestId);
			await Promise.resolve();
		});

		// Assert
		await actWait(() =>
			commandFacts.waitFor(
				(command): boolean =>
					command.command === 'activeViewerModeUpdate' && command.update.sequence === 1,
			),
		);
		expect(activeViewerModeUpdates(paneCommands)).toHaveLength(1);
		expect(activeViewerModeUpdates(paneCommands)[0]).toMatchObject({
			command: 'activeViewerModeUpdate',
			update: {
				activeSource: null,
				mode: 'review',
				nativeSelectionRequestId: null,
				sequence: 1,
			},
		});
		controlledHandshake.dispose();
	});

	test('forwards the initial File activation after page readiness is acknowledged', async (context) => {
		// Arrange
		const paneCommands: BridgeWorkerMainToServerMessage[] = [];
		const commandFacts = new BridgeProductTestFactRecorder<BridgeWorkerMainToServerMessage>();
		let isRecording = true;
		const closeCommandObservation = (): void => {
			isRecording = false;
			commandFacts.close(new Error('Ready-gated command observation closed.'));
		};
		context.signal.addEventListener('abort', closeCommandObservation, { once: true });
		context.onTestFinished((): void => {
			context.signal.removeEventListener('abort', closeCommandObservation);
			closeCommandObservation();
		});
		const controlledHandshake = installControlledBridgeReadyHandshake();
		const paneRuntime = createRecordingBridgePaneRuntime(paneCommands, (command): void => {
			if (isRecording) commandFacts.record(command);
		});
		activePaneRuntime = paneRuntime;
		await actWait(async (): Promise<void> => {
			await render(
				<BridgeAppProtocolRouter
					codeViewWorkerPoolEnabled={false}
					fileViewerProps={{ autoOpenInitialFile: false }}
					paneRuntime={paneRuntime}
					protocol="worktree-file"
				/>,
			);
			await Promise.resolve();
		});
		const readyRequestId = await actWait(controlledHandshake.waitForReadyRequest);
		expect(readyRequestId).not.toBeNull();
		expect(activeViewerModeUpdates(paneCommands)).toHaveLength(0);

		// Act
		await actWait(async (): Promise<void> => {
			controlledHandshake.acknowledgeReady(readyRequestId);
			await Promise.resolve();
		});

		// Assert
		await actWait(() =>
			commandFacts.waitFor(
				(command): boolean =>
					command.command === 'activeViewerModeUpdate' && command.update.sequence === 1,
			),
		);
		expect(activeViewerModeUpdates(paneCommands)).toHaveLength(1);
		expect(activeViewerModeUpdates(paneCommands)[0]).toMatchObject({
			command: 'activeViewerModeUpdate',
			update: {
				activeSource: null,
				mode: 'file',
				nativeSelectionRequestId: null,
				sequence: 1,
			},
		});
		controlledHandshake.dispose();
	});
});

function createRecordingBridgePaneRuntime(
	paneCommands: BridgeWorkerMainToServerMessage[],
	onCommand: (command: BridgeWorkerMainToServerMessage) => void,
): BridgePaneRuntime {
	return createBridgePaneRuntime({
		sessionFactory: () => ({
			createDispatcher: ({ publishWorkerMessages }) => ({
				dispatch: (command): void => {
					paneCommands.push(command);
					onCommand(command);
					publishWorkerMessages([
						{
							direction: 'serverWorkerToMain',
							kind: 'health',
							requestId: command.requestId,
							status: 'ready',
							transferDescriptors: [],
							wireVersion: 1,
						},
					]);
				},
				dispose: (): void => {},
			}),
			dispose: (): void => {},
			installNativeBootstrap: (): void => {},
			handleNativeBootstrapFailure: (): void => {},
			setNativeBootstrapRequester: (): void => {},
		}),
	});
}

function activeViewerModeUpdates(
	paneCommands: readonly BridgeWorkerMainToServerMessage[],
): readonly Extract<
	BridgeWorkerMainToServerMessage,
	{ readonly command: 'activeViewerModeUpdate' }
>[] {
	return paneCommands.filter(
		(
			command,
		): command is Extract<
			BridgeWorkerMainToServerMessage,
			{ readonly command: 'activeViewerModeUpdate' }
		> => command.command === 'activeViewerModeUpdate',
	);
}
