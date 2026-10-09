import { afterEach, describe, expect, test, vi } from 'vitest';
import { cleanup, render } from 'vitest-browser-react';

// oxlint-disable-next-line import/no-unassigned-import -- Browser Mode renders the real app chrome.
import './bridge-app.css';
import type { BridgeMainRenderSnapshotStore } from '../core/comm-worker/bridge-main-render-snapshot-store.js';
import type {
	BridgePaneRuntime,
	BridgePaneSurfaceClient,
} from '../core/comm-worker/bridge-pane-runtime.js';
import {
	BRIDGE_WORKER_WIRE_VERSION,
	type BridgeWorkerServerToMainMessage,
} from '../core/comm-worker/bridge-worker-contracts.js';
import type { BridgeWorkerRpcCommandInput } from '../core/comm-worker/bridge-worker-rpc-client.js';
import {
	readBridgeReviewSelectionDiagnostic,
	resetBridgeReviewSelectionDiagnosticForTesting,
} from '../foundation/diagnostics/bridge-review-selection-diagnostic.js';
import {
	actClick,
	actWait,
	installBridgeReadyHandshake,
	pollWithinActUntilEqual,
	pollWithinActUntilTruthy,
} from './bridge-app-browser-test-actions.js';
import type { BridgeAppControlProbe } from './bridge-app-control.js';
import {
	dispatchBridgePageControl,
	dispatchBridgeViewerFilterShortcut,
	fileSearchInput,
	fileTreeRowForPath,
	makeNativeFileTargetSelectionRequest,
	makeNativeSurfaceSelectionRequest,
	requestNativeSurface,
	requireActiveContextButton,
	requireHTMLElement,
	reviewSearchInputWithin,
} from './bridge-app-pane-runtime-control-test-support.js';
import { runBridgeAppFileCornerSwitchJourney } from './bridge-app-pane-runtime-file-corner-test-support.js';
import {
	advanceAnimationFrame,
	assertSurfacePositionRetained,
	bridgePanePositionFileItemId,
	bridgePanePositionFilePath,
	bridgePanePositionReviewItemId,
	bridgePaneReplacementFileItemId,
	bridgePaneReplacementFilePath,
	establishSemanticSurfacePosition,
	exercisePendingFileTargetSupersession,
	installBridgePanePositionFixtures,
	replaceFilePositionFixtureWithTarget,
	waitForScrollableSurfaceOwners,
} from './bridge-app-pane-runtime-position-test-support.js';
import { BridgeAppProtocolRouter } from './bridge-app-protocol-router.js';

type PaneRuntimeCommandLedgerEntry =
	| {
			readonly command: BridgeWorkerRpcCommandInput;
			readonly owner: 'pane';
	  }
	| {
			readonly command: BridgeWorkerRpcCommandInput;
			readonly owner: 'surface';
			readonly surface: 'fileView' | 'review';
	  };

const paneRuntimeObservation = vi.hoisted(() => ({
	commandLedger: [] as PaneRuntimeCommandLedgerEntry[],
	createCount: 0,
	disposeCount: 0,
	paneCommands: [] as BridgeWorkerRpcCommandInput[],
	paneMessageListeners: [] as Array<(message: BridgeWorkerServerToMainMessage) => void>,
	renderStores: new Map<'fileView' | 'review', BridgeMainRenderSnapshotStore>(),
	surfaceCommands: [] as Array<{
		readonly command: BridgeWorkerRpcCommandInput;
		readonly surface: 'fileView' | 'review';
	}>,
	surfaceRequests: [] as Array<'fileView' | 'review'>,
}));

vi.mock('../core/comm-worker/bridge-pane-runtime.js', async (importOriginal) => {
	const actual =
		await importOriginal<typeof import('../core/comm-worker/bridge-pane-runtime.js')>();
	const { createBridgeMainRenderSnapshotStore } =
		await import('../core/comm-worker/bridge-main-render-snapshot-store.js');
	const { createBridgeMainRenderFulfillmentCoordinator } =
		await import('../core/comm-worker/bridge-main-render-fulfillment-coordinator.js');
	const { createBridgeWorkerRpcLifecycleStore } =
		await import('../core/comm-worker/bridge-worker-rpc-lifecycle-store.js');
	return {
		...actual,
		createBridgePaneRuntime: (): BridgePaneRuntime => {
			paneRuntimeObservation.createCount += 1;
			const lifecycleStore = createBridgeWorkerRpcLifecycleStore();
			const surfaceMessageListeners = new Map<
				'fileView' | 'review',
				Array<(message: BridgeWorkerServerToMainMessage) => void>
			>();
			let surfaceRequestSequence = 0;
			const surfaceClients = new Map(
				(['fileView', 'review'] as const).map((surface) => {
					const renderStore = createBridgeMainRenderSnapshotStore();
					const messageListeners: Array<(message: BridgeWorkerServerToMainMessage) => void> = [];
					const renderFulfillmentCoordinator = createBridgeMainRenderFulfillmentCoordinator({
						sendDisposition: (): void => {},
					});
					paneRuntimeObservation.renderStores.set(surface, renderStore);
					surfaceMessageListeners.set(surface, messageListeners);
					return [
						surface,
						{
							requestWorkerReplacement:
								vi.fn<BridgePaneSurfaceClient['requestWorkerReplacement']>(),
							lifecycle: {
								getServerSnapshot: lifecycleStore.getServerSnapshot,
								getSnapshot: lifecycleStore.getSnapshot,
								subscribe: lifecycleStore.subscribe,
							},
							renderFulfillmentCoordinator,
							renderStore,
							send: (command: BridgeWorkerRpcCommandInput): string => {
								paneRuntimeObservation.surfaceCommands.push({ command, surface });
								paneRuntimeObservation.commandLedger.push({ command, owner: 'surface', surface });
								surfaceRequestSequence += 1;
								return `surface-command-${surface}-${surfaceRequestSequence}`;
							},
							subscribeMessages: (
								listener: (message: BridgeWorkerServerToMainMessage) => void,
							): (() => void) => {
								messageListeners.push(listener);
								return (): void => {
									const listenerIndex = messageListeners.indexOf(listener);
									if (listenerIndex >= 0) messageListeners.splice(listenerIndex, 1);
								};
							},
							surface,
						},
					] as const;
				}),
			);
			return {
				dispose: (): void => {
					paneRuntimeObservation.disposeCount += 1;
					for (const surfaceClient of surfaceClients.values()) {
						surfaceClient.renderFulfillmentCoordinator.dispose();
						surfaceClient.renderStore.dispose();
					}
					lifecycleStore.dispose();
					surfaceMessageListeners.clear();
				},
				installMainTelemetryRecorder: vi.fn(),
				installNativeBootstrap: vi.fn(),
				installTelemetryProducer: vi.fn(),
				lifecycleStore,
				paneClient: {
					lifecycle: {
						getServerSnapshot: lifecycleStore.getServerSnapshot,
						getSnapshot: lifecycleStore.getSnapshot,
						subscribe: lifecycleStore.subscribe,
					},
					send: (command: BridgeWorkerRpcCommandInput): string => {
						paneRuntimeObservation.paneCommands.push(command);
						paneRuntimeObservation.commandLedger.push({ command, owner: 'pane' });
						const requestId = `pane-command-${paneRuntimeObservation.paneCommands.length}`;
						for (const listener of paneRuntimeObservation.paneMessageListeners) {
							listener({
								direction: 'serverWorkerToMain',
								kind: 'health',
								requestId,
								status: 'ready',
								transferDescriptors: [],
								wireVersion: BRIDGE_WORKER_WIRE_VERSION,
							});
						}
						return requestId;
					},
					subscribeMessages: (
						listener: (message: BridgeWorkerServerToMainMessage) => void,
					): (() => void) => {
						paneRuntimeObservation.paneMessageListeners.push(listener);
						return (): void => {
							const listenerIndex = paneRuntimeObservation.paneMessageListeners.indexOf(listener);
							if (listenerIndex >= 0) {
								paneRuntimeObservation.paneMessageListeners.splice(listenerIndex, 1);
							}
						};
					},
				},
				handleNativeBootstrapFailure: vi.fn(),
				setNativeBootstrapRequester: vi.fn(),
				setPaneFailedStartHandler: vi.fn<BridgePaneRuntime['setPaneFailedStartHandler']>(),
				surfaceClient: (surface: 'fileView' | 'review'): BridgePaneSurfaceClient => {
					paneRuntimeObservation.surfaceRequests.push(surface);
					const client = surfaceClients.get(surface);
					if (client === undefined) throw new Error(`Missing fixture surface: ${surface}`);
					return client;
				},
			} satisfies BridgePaneRuntime;
		},
	};
});

describe('BridgeApp pane runtime hard cut', () => {
	afterEach(async () => {
		await actWait(async (): Promise<void> => {
			await cleanup();
			await new Promise<void>((resolve) => window.setTimeout(resolve, 0));
		});
		vi.restoreAllMocks();
		paneRuntimeObservation.commandLedger = [];
		paneRuntimeObservation.createCount = 0;
		paneRuntimeObservation.disposeCount = 0;
		paneRuntimeObservation.paneCommands = [];
		paneRuntimeObservation.paneMessageListeners = [];
		paneRuntimeObservation.renderStores.clear();
		paneRuntimeObservation.surfaceCommands = [];
		paneRuntimeObservation.surfaceRequests = [];
		resetBridgeReviewSelectionDiagnosticForTesting();
		document.body.replaceChildren();
	});

	test('keeps one pane-owned runtime and stable surface clients across File to Review to File', async () => {
		// Arrange
		await actWait(async (): Promise<void> => {
			await render(<BridgeAppProtocolRouter protocol="worktree-file" />);
			await new Promise<void>((resolve) => window.setTimeout(resolve, 0));
		});
		const appRoot = requireHTMLElement(document.querySelector('[data-testid="bridge-app-root"]'));
		expect(
			await pollWithinActUntilTruthy(() =>
				document.querySelector('[data-testid="bridge-file-viewer-shell"]'),
			),
		).not.toBeNull();
		await actWait(
			() => new Promise<void>((resolve) => window.requestAnimationFrame(() => resolve())),
		);

		// Act
		await actClick(requireActiveContextButton('review'));
		expect(
			await pollWithinActUntilEqual(
				() => appRoot.getAttribute('data-bridge-viewer-mode'),
				'review',
			),
		).toBe('review');
		await actWait(() => Promise.resolve());
		await actClick(requireActiveContextButton('file'));
		expect(
			await pollWithinActUntilEqual(() => appRoot.getAttribute('data-bridge-viewer-mode'), 'file'),
		).toBe('file');
		await actWait(
			() => new Promise<void>((resolve) => window.requestAnimationFrame(() => resolve())),
		);

		// Assert
		expect(paneRuntimeObservation.createCount).toBe(1);
		expect(paneRuntimeObservation.surfaceRequests).toEqual(
			expect.arrayContaining(['fileView', 'review']),
		);
		expect(paneRuntimeObservation.disposeCount).toBe(0);
	});

	test('dismisses the Files filter menu before its retained host becomes inactive', async () => {
		// Arrange
		await actWait(async (): Promise<void> => {
			await render(<BridgeAppProtocolRouter protocol="worktree-file" />);
			await new Promise<void>((resolve) => window.setTimeout(resolve, 0));
		});
		const appRoot = requireHTMLElement(document.querySelector('[data-testid="bridge-app-root"]'));
		expect(
			await pollWithinActUntilTruthy(() =>
				document.querySelector('[data-testid="bridge-file-viewer-shell"]'),
			),
		).not.toBeNull();

		// Act: open Files Filters, then retain Files under an inactive host.
		await dispatchBridgeViewerFilterShortcut();
		expect(
			document.querySelector('[data-testid="worktree-file-filter-menu-popover"][data-open]'),
		).not.toBeNull();
		await actClick(requireActiveContextButton('review'));
		expect(
			await pollWithinActUntilEqual(
				() => appRoot.getAttribute('data-bridge-viewer-mode'),
				'review',
			),
		).toBe('review');

		// Assert
		expect(
			document.querySelector('[data-testid="worktree-file-filter-menu-popover"][data-open]'),
		).toBeNull();
	});

	test('forwards one local File activation before the selected File row', async () => {
		// Arrange
		const handshake = installBridgeReadyHandshake();
		await actWait(async (): Promise<void> => {
			await render(
				<BridgeAppProtocolRouter
					codeViewWorkerPoolEnabled={false}
					fileViewerProps={{ autoOpenInitialFile: false }}
					protocol="review"
				/>,
			);
			await Promise.resolve();
		});
		await actWait(async (): Promise<void> => {
			installBridgePanePositionFixtures({
				fileRenderStore: requireRenderStore('fileView'),
				reviewRenderStore: requireRenderStore('review'),
			});
			await Promise.resolve();
		});
		const appRoot = requireHTMLElement(document.querySelector('[data-testid="bridge-app-root"]'));
		const reviewHost = requireHTMLElement(
			document.querySelector('[data-testid="bridge-viewer-mode-host-review"]'),
		);
		const reviewCodePanel = requireHTMLElement(
			await pollWithinActUntilTruthy(() =>
				reviewHost.querySelector('[data-testid="bridge-code-view-panel"]'),
			),
		);
		expect(
			await pollWithinActUntilEqual(
				() => reviewCodePanel.getAttribute('data-code-view-item-count'),
				'80',
			),
		).toBe('80');
		expect(reviewCodePanel.getAttribute('data-selected-item-id')).toBe(
			bridgePanePositionReviewItemId,
		);
		const activationLedgerStartIndex = paneRuntimeObservation.commandLedger.length;

		// Act
		await actClick(requireActiveContextButton('file'));
		expect(
			await pollWithinActUntilEqual(() => appRoot.getAttribute('data-bridge-viewer-mode'), 'file'),
		).toBe('file');
		const fileRow = requireHTMLElement(
			await pollWithinActUntilTruthy(() => fileTreeRowForPath(bridgePanePositionFilePath)),
		);
		await actClick(fileRow);
		const fileSelectCommand = await pollWithinActUntilTruthy(() =>
			paneRuntimeObservation.surfaceCommands.find(
				({ command, surface }): boolean =>
					surface === 'fileView' &&
					command.command === 'select' &&
					command.selectedItemId === 'position-file-001',
			),
		);

		// Assert
		const activationLedger = paneRuntimeObservation.commandLedger.slice(activationLedgerStartIndex);
		const fileSelectLedgerIndex = activationLedger.findIndex(
			(entry): boolean =>
				entry.owner === 'surface' &&
				entry.surface === 'fileView' &&
				entry.command.command === 'select' &&
				entry.command.selectedItemId === 'position-file-001',
		);
		expect(fileSelectLedgerIndex).toBeGreaterThan(-1);
		const fileActivationUpdatesBeforeSelect = activationLedger
			.slice(0, fileSelectLedgerIndex)
			.filter(
				(entry): boolean =>
					entry.owner === 'pane' &&
					entry.command.command === 'activeViewerModeUpdate' &&
					entry.command.update.mode === 'file' &&
					entry.command.update.activeSource === null &&
					entry.command.update.nativeSelectionRequestId === null,
			);
		expect(fileActivationUpdatesBeforeSelect).toHaveLength(1);
		expect(fileSelectCommand).toMatchObject({
			command: {
				command: 'select',
				selectedItemId: 'position-file-001',
				selectedSource: 'user',
				surface: 'fileView',
			},
			surface: 'fileView',
		});
		expect(readBridgeReviewSelectionDiagnostic()).toMatchObject({
			fileModeSendAttemptCount: 2,
			fileModeSendSynchronousFailureCount: 0,
			pageReadyState: 'ready',
		});
		handshake.dispose();
	});

	test('holds an exact File target until its matching source arrives and then applies it', async () => {
		// Arrange
		const handshake = installBridgeReadyHandshake();
		await actWait(async (): Promise<void> => {
			await render(
				<BridgeAppProtocolRouter
					codeViewWorkerPoolEnabled={false}
					fileViewerProps={{ autoOpenInitialFile: false }}
					protocol="review"
				/>,
			);
			await Promise.resolve();
		});
		const appRoot = requireHTMLElement(document.querySelector('[data-testid="bridge-app-root"]'));
		const navigationCommandId = 'native-file-target-pending-source';

		// Act: the worker delivers the exact target before File has accepted a source tuple.
		await publishNativeFileTargetSelectionRequest({
			bindingRevision: 1,
			commandId: navigationCommandId,
			path: bridgePanePositionFilePath,
			sourceId: 'position-file-source',
			subscriptionGeneration: 1,
		});

		// Assert: admission remains pending and neither the surface owner nor receipt moves early.
		expect(appRoot.getAttribute('data-bridge-viewer-mode')).toBe('review');
		expect(
			paneRuntimeObservation.surfaceCommands.some(
				({ command, surface }): boolean =>
					surface === 'fileView' && command.command === 'select' && command.selectedItemId !== null,
			),
		).toBe(false);
		expect(activeViewerModeUpdateForNativeRequest(navigationCommandId)).toBeUndefined();

		// Act: the real File render-store projection publishes the matching source tuple.
		await actWait(async (): Promise<void> => {
			installBridgePanePositionFixtures({
				fileRenderStore: requireRenderStore('fileView'),
				reviewRenderStore: requireRenderStore('review'),
			});
			await Promise.resolve();
		});

		// Assert: BridgeApp admits the command, activates File, and the File owner applies it.
		expect(
			await pollWithinActUntilEqual(() => appRoot.getAttribute('data-bridge-viewer-mode'), 'file'),
		).toBe('file');
		expect(
			await pollWithinActUntilTruthy(() =>
				paneRuntimeObservation.surfaceCommands.find(
					({ command, surface }): boolean =>
						surface === 'fileView' &&
						command.command === 'select' &&
						command.selectedItemId === bridgePanePositionFileItemId &&
						command.selectedSource === 'programmatic',
				),
			),
		).toMatchObject({
			command: {
				command: 'select',
				selectedItemId: bridgePanePositionFileItemId,
				selectedSource: 'programmatic',
			},
			surface: 'fileView',
		});
		expect(
			await pollWithinActUntilTruthy(() =>
				activeViewerModeUpdateForNativeRequest(navigationCommandId),
			),
		).toMatchObject({
			command: 'activeViewerModeUpdate',
			update: {
				activeSource: {
					generation: 1,
					protocol: 'worktree-file',
					streamId: 'position-file-source',
				},
				mode: 'file',
				nativeSelectionRequestId: navigationCommandId,
			},
		});
		handshake.dispose();
	});

	test('revokes an admitted exact File target before a replacement source can apply it', async () => {
		// Arrange
		const handshake = installBridgeReadyHandshake();
		await actWait(async (): Promise<void> => {
			await render(
				<BridgeAppProtocolRouter
					codeViewWorkerPoolEnabled={false}
					fileViewerProps={{ autoOpenInitialFile: false }}
					protocol="review"
				/>,
			);
			await Promise.resolve();
		});
		await actWait(async (): Promise<void> => {
			installBridgePanePositionFixtures({
				fileRenderStore: requireRenderStore('fileView'),
				reviewRenderStore: requireRenderStore('review'),
			});
			await Promise.resolve();
		});
		const appRoot = requireHTMLElement(document.querySelector('[data-testid="bridge-app-root"]'));
		await requestNativeSurface({
			activeViewerModeUpdateForNativeRequest,
			appRoot,
			bindingRevision: 1,
			nativeSelectionRequestId: 'native-file-context-before-rejected-source',
			publishNativeSurfaceSelectionRequest,
			surface: 'file',
		});
		const admittedCommandId = 'native-file-target-admitted-source';

		// Act: admit an exact command against source A while its target is absent.
		await publishNativeFileTargetSelectionRequest({
			bindingRevision: 2,
			commandId: admittedCommandId,
			path: bridgePaneReplacementFilePath,
			sourceId: 'position-file-source',
			subscriptionGeneration: 1,
		});
		expect(
			paneRuntimeObservation.surfaceCommands.some(
				({ command, surface }): boolean =>
					surface === 'fileView' &&
					command.command === 'select' &&
					command.selectedItemId === bridgePaneReplacementFileItemId,
			),
		).toBe(false);

		// Act: source B replaces A and introduces the same target path in one projection commit.
		await actWait(async (): Promise<void> => {
			replaceFilePositionFixtureWithTarget(requireRenderStore('fileView'));
			await Promise.resolve();
		});

		// Act: surface-only navigation away and back must not restore the revoked target.
		await requestNativeSurface({
			activeViewerModeUpdateForNativeRequest,
			appRoot,
			bindingRevision: 3,
			nativeSelectionRequestId: 'native-review-context-after-file-rotation',
			publishNativeSurfaceSelectionRequest,
			surface: 'review',
		});
		await requestNativeSurface({
			activeViewerModeUpdateForNativeRequest,
			appRoot,
			bindingRevision: 4,
			nativeSelectionRequestId: 'native-file-context-after-file-rotation',
			publishNativeSurfaceSelectionRequest,
			surface: 'file',
		});

		// Assert: the source-A command never mutates source B, including through later restoration.
		expect(
			paneRuntimeObservation.surfaceCommands.some(
				({ command, surface }): boolean =>
					surface === 'fileView' &&
					command.command === 'select' &&
					command.selectedItemId === bridgePaneReplacementFileItemId,
			),
		).toBe(false);
		handshake.dispose();
	});

	test('revokes an unresolved File target when a newer binding waits for another source', async () => {
		// Arrange
		await actWait(async (): Promise<void> => {
			await render(<BridgeAppProtocolRouter protocol="review" />);
			await Promise.resolve();
		});

		// Act
		const result = await exercisePendingFileTargetSupersession({
			fileRenderStore: requireRenderStore('fileView'),
			hasSelectedReplacementTarget: (): boolean =>
				paneRuntimeObservation.surfaceCommands.some(
					({ command, surface }): boolean =>
						surface === 'fileView' &&
						command.command === 'select' &&
						command.selectedItemId === bridgePaneReplacementFileItemId,
				),
			publishTarget: publishNativeFileTargetSelectionRequest,
			reviewRenderStore: requireRenderStore('review'),
		});

		// Assert
		expect(result.beforeSupersession).toBe(false);
		expect(result.afterSupersession).toBe(false);
	});

	test('retains real File and Review tree and code positions across native surface requests', async () => {
		// Arrange
		const handshake = installBridgeReadyHandshake();
		await actWait(async (): Promise<void> => {
			await render(
				<div style={{ height: '860px', overflow: 'hidden', width: '1440px' }}>
					<BridgeAppProtocolRouter
						codeViewWorkerPoolEnabled={false}
						fileViewerProps={{ autoOpenInitialFile: true }}
						protocol="worktree-file"
					/>
				</div>,
			);
			await Promise.resolve();
		});
		const appRoot = requireHTMLElement(document.querySelector('[data-testid="bridge-app-root"]'));
		const retainedFileHost = requireHTMLElement(
			document.querySelector('[data-testid="bridge-viewer-mode-host-file"]'),
		);
		const retainedReviewHost = requireHTMLElement(
			document.querySelector('[data-testid="bridge-viewer-mode-host-review"]'),
		);
		await actWait(async (): Promise<void> => {
			installBridgePanePositionFixtures({
				fileRenderStore: requireRenderStore('fileView'),
				reviewRenderStore: requireRenderStore('review'),
			});
			await Promise.resolve();
		});

		// Act
		await requestNativeSurface({
			activeViewerModeUpdateForNativeRequest,
			appRoot,
			nativeSelectionRequestId: 'native-selection-file-initial',
			bindingRevision: 1,
			publishNativeSurfaceSelectionRequest,
			surface: 'file',
		});
		const fileOwners = await waitForScrollableSurfaceOwners({
			host: retainedFileHost,
			surface: 'file',
		});
		expect(
			retainedFileHost
				.querySelector('[data-testid="bridge-file-viewer-code-canvas"]')
				?.getAttribute('data-worktree-rendered-item-id'),
		).toBe('position-file-001');
		expect(
			retainedFileHost
				.querySelector('[data-testid="bridge-file-viewer-code-canvas"]')
				?.getAttribute('data-worktree-open-file-path'),
		).toBe(bridgePanePositionFilePath);
		const filePosition = await establishSemanticSurfacePosition(fileOwners);

		await requestNativeSurface({
			activeViewerModeUpdateForNativeRequest,
			appRoot,
			nativeSelectionRequestId: 'native-selection-review',
			bindingRevision: 2,
			publishNativeSurfaceSelectionRequest,
			surface: 'review',
		});
		const reviewOwners = await waitForScrollableSurfaceOwners({
			host: retainedReviewHost,
			surface: 'review',
		});
		expect(
			Number(
				retainedReviewHost
					.querySelector('[data-testid="bridge-code-view-panel"]')
					?.getAttribute('data-code-view-item-count'),
			),
		).toBeGreaterThan(1);
		const reviewPosition = await establishSemanticSurfacePosition(reviewOwners);

		await requestNativeSurface({
			activeViewerModeUpdateForNativeRequest,
			appRoot,
			nativeSelectionRequestId: 'native-selection-file',
			bindingRevision: 3,
			publishNativeSurfaceSelectionRequest,
			surface: 'file',
		});

		// Assert
		await assertSurfacePositionRetained({
			expected: filePosition,
			owners: fileOwners,
			surface: 'file',
		});

		// Act: reactivate Review once so its retained positions are proven while visible.
		await requestNativeSurface({
			activeViewerModeUpdateForNativeRequest,
			appRoot,
			nativeSelectionRequestId: 'native-selection-review-return',
			bindingRevision: 4,
			publishNativeSurfaceSelectionRequest,
			surface: 'review',
		});

		// Assert
		await assertSurfacePositionRetained({
			expected: reviewPosition,
			owners: reviewOwners,
			surface: 'review',
		});
		await requestNativeSurface({
			activeViewerModeUpdateForNativeRequest,
			appRoot,
			nativeSelectionRequestId: 'native-selection-file-final',
			bindingRevision: 5,
			publishNativeSurfaceSelectionRequest,
			surface: 'file',
		});
		await assertSurfacePositionRetained({
			expected: filePosition,
			owners: fileOwners,
			surface: 'file',
		});
		expect(document.querySelector('[data-testid="bridge-viewer-mode-host-file"]')).toBe(
			retainedFileHost,
		);
		expect(document.querySelector('[data-testid="bridge-viewer-mode-host-review"]')).toBe(
			retainedReviewHost,
		);
		expect(fileOwners.treeScrollOwner.isConnected).toBe(true);
		expect(fileOwners.codeScrollOwner.isConnected).toBe(true);
		expect(reviewOwners.treeScrollOwner.isConnected).toBe(true);
		expect(reviewOwners.codeScrollOwner.isConnected).toBe(true);
		expect(paneRuntimeObservation.createCount).toBe(1);
		expect(paneRuntimeObservation.disposeCount).toBe(0);
		handshake.dispose();
	});

	test('opens a Review file-corner command in Files without remounting either surface', async () => {
		await runBridgeAppFileCornerSwitchJourney({
			activeViewerModeUpdateForNativeRequest,
			installPositionFixtures: (): void => {
				installBridgePanePositionFixtures({
					fileRenderStore: requireRenderStore('fileView'),
					reviewRenderStore: requireRenderStore('review'),
				});
			},
			publishNativeSurfaceSelectionRequest,
			runtimeCreateCount: (): number => paneRuntimeObservation.createCount,
			runtimeDisposeCount: (): number => paneRuntimeObservation.disposeCount,
		});
	});

	test('routes strict native page controls into the active Review and File owners', async () => {
		// Arrange
		await actWait(async (): Promise<void> => {
			await render(
				<BridgeAppProtocolRouter
					codeViewWorkerPoolEnabled={false}
					fileViewerProps={{ autoOpenInitialFile: false }}
					protocol="review"
				/>,
			);
			await Promise.resolve();
		});
		await actWait(async (): Promise<void> => {
			installBridgePanePositionFixtures({
				fileRenderStore: requireRenderStore('fileView'),
				reviewRenderStore: requireRenderStore('review'),
			});
			await Promise.resolve();
		});
		const appRoot = requireHTMLElement(document.querySelector('[data-testid="bridge-app-root"]'));
		const reviewHost = requireHTMLElement(
			document.querySelector('[data-testid="bridge-viewer-mode-host-review"]'),
		);
		const reviewCodePanel = requireHTMLElement(
			await pollWithinActUntilTruthy(() =>
				reviewHost.querySelector('[data-testid="bridge-code-view-panel"]'),
			),
		);
		const initialCollapseButton = requireHTMLElement(
			await pollWithinActUntilTruthy(() =>
				reviewHost.querySelector(
					`[data-testid="bridge-code-view-header-collapse-button"][data-bridge-code-view-item-id="${bridgePanePositionReviewItemId}"]`,
				),
			),
		);
		const probes: Array<BridgeAppControlProbe | undefined> = [];

		// Act: drive Review through the exact page events emitted by Swift IPC.
		probes.push(
			await dispatchBridgePageControl({
				itemId: bridgePanePositionReviewItemId,
				method: 'bridge.diff.collapseFile',
			}),
		);
		expect.soft(initialCollapseButton.getAttribute('aria-expanded')).toBe('false');
		probes.push(
			await dispatchBridgePageControl({
				itemId: bridgePanePositionReviewItemId,
				method: 'bridge.diff.expandFile',
			}),
		);
		expect.soft(initialCollapseButton.getAttribute('aria-expanded')).toBe('true');
		const selectedReviewItemId = 'position-review-080';
		probes.push(
			await dispatchBridgePageControl({
				itemId: selectedReviewItemId,
				method: 'bridge.diff.scrollToFile',
			}),
		);
		probes.push(
			await dispatchBridgePageControl({
				method: 'bridge.fileTree.search',
				searchMode: { kind: 'text' },
				searchText: 'PositionReview080',
			}),
		);
		const rejectedFilesFilterOnReview = await dispatchBridgePageControl({
			method: 'bridge.fileTree.setFilter',
			filter: { surface: 'files', categoryFilter: 'docs' },
		});
		const acceptedReviewFilter = await dispatchBridgePageControl({
			method: 'bridge.fileTree.setFilter',
			filter: {
				surface: 'review',
				categoryFilter: 'source',
				gitStatusFilter: 'modified',
				showBinary: true,
				showLarge: true,
			},
		});
		const reviewSearchValueAfterCommand = reviewSearchInputWithin(reviewHost)?.value;

		// Act: switch through production chrome, then route File reveal and search.
		await actClick(requireActiveContextButton('file'));
		expect(
			await pollWithinActUntilEqual(() => appRoot.getAttribute('data-bridge-viewer-mode'), 'file'),
		).toBe('file');
		probes.push(
			await dispatchBridgePageControl({
				method: 'bridge.fileTree.revealPath',
				path: bridgePanePositionFilePath,
			}),
		);
		probes.push(
			await dispatchBridgePageControl({
				method: 'bridge.fileTree.search',
				searchMode: { kind: 'text' },
				searchText: 'PositionFile080',
			}),
		);
		const rejectedReviewFilterOnFiles = await dispatchBridgePageControl({
			method: 'bridge.fileTree.setFilter',
			filter: {
				surface: 'review',
				categoryFilter: 'all',
				gitStatusFilter: 'all',
				showBinary: false,
				showLarge: false,
			},
		});
		const acceptedFilesFilter = await dispatchBridgePageControl({
			method: 'bridge.fileTree.setFilter',
			filter: { surface: 'files', categoryFilter: 'source' },
		});
		const fileShell = requireHTMLElement(
			document.querySelector('[data-testid="bridge-file-viewer-shell"]'),
		);
		const selectedFilePathBeforeInvalidCommand = fileShell.getAttribute(
			'data-selected-display-path',
		);
		const rejectedProbe = await dispatchBridgePageControl({
			method: 'bridge.fileTree.search',
			searchMode: { kind: 'text' },
			searchText: 42,
		});
		await actClick(requireActiveContextButton('review'));
		expect(
			await pollWithinActUntilEqual(
				() => appRoot.getAttribute('data-bridge-viewer-mode'),
				'review',
			),
		).toBe('review');
		const reviewSearchInputAfterReturn = reviewSearchInputWithin(reviewHost);
		const reviewSearchValueAfterReturn = reviewSearchInputAfterReturn?.value;
		await actClick(
			requireHTMLElement(reviewHost.querySelector('[data-testid="bridge-review-search-clear"]')),
		);
		await advanceAnimationFrame();
		const reviewSearchInputAfterExplicitClear = reviewSearchInputWithin(reviewHost);

		// Assert: probes and current production state move together; invalid input is inert.
		expect.soft(probes).toMatchObject([
			{
				itemId: bridgePanePositionReviewItemId,
				method: 'bridge.diff.collapseFile',
				status: 'accepted',
			},
			{
				itemId: bridgePanePositionReviewItemId,
				method: 'bridge.diff.expandFile',
				status: 'accepted',
			},
			{ itemId: selectedReviewItemId, method: 'bridge.diff.scrollToFile', status: 'accepted' },
			{ method: 'bridge.fileTree.search', status: 'accepted', treeSearchText: 'PositionReview080' },
			{
				method: 'bridge.fileTree.revealPath',
				path: bridgePanePositionFilePath,
				status: 'accepted',
			},
			{ method: 'bridge.fileTree.search', status: 'accepted', treeSearchText: 'PositionFile080' },
		]);
		expect.soft(reviewCodePanel.getAttribute('data-selected-item-id')).toBe(selectedReviewItemId);
		expect.soft(reviewSearchValueAfterCommand).toBe('PositionReview080');
		expect.soft(rejectedFilesFilterOnReview).toMatchObject({
			method: 'bridge.fileTree.setFilter',
			status: 'rejected',
			filterSurface: 'review',
			categoryFilter: 'all',
			gitStatusFilter: 'all',
			showBinary: false,
			showLarge: false,
		});
		expect.soft(acceptedReviewFilter).toMatchObject({
			method: 'bridge.fileTree.setFilter',
			status: 'accepted',
			filterSurface: 'review',
			categoryFilter: 'source',
			gitStatusFilter: 'modified',
			showBinary: true,
			showLarge: true,
		});
		expect.soft(reviewSearchValueAfterReturn).toBe('PositionReview080');
		expect.soft(reviewSearchInputAfterExplicitClear?.value).toBe('');
		expect
			.soft(
				reviewHost
					.querySelector('[data-testid="bridge-review-search-toggle"]')
					?.getAttribute('aria-pressed'),
			)
			.toBe('true');
		expect
			.soft(fileShell.getAttribute('data-selected-display-path'))
			.toBe(bridgePanePositionFilePath);
		expect
			.soft(fileShell.getAttribute('data-worktree-open-file-path'))
			.toBe(bridgePanePositionFilePath);
		expect.soft(fileSearchInput()?.value).toBe('PositionFile080');
		expect.soft(rejectedReviewFilterOnFiles).toMatchObject({
			method: 'bridge.fileTree.setFilter',
			status: 'rejected',
			filterSurface: 'files',
			categoryFilter: 'all',
		});
		expect.soft(acceptedFilesFilter).toMatchObject({
			method: 'bridge.fileTree.setFilter',
			status: 'accepted',
			filterSurface: 'files',
			categoryFilter: 'source',
		});
		expect.soft(rejectedProbe).toMatchObject({
			method: 'bridge.fileTree.search',
			status: 'rejected',
		});
		expect(fileShell.getAttribute('data-selected-display-path')).toBe(
			selectedFilePathBeforeInvalidCommand,
		);
	});
});

function requireRenderStore(surface: 'fileView' | 'review'): BridgeMainRenderSnapshotStore {
	const renderStore = paneRuntimeObservation.renderStores.get(surface);
	if (renderStore === undefined) {
		throw new Error(`Expected the pane runtime ${surface} render store.`);
	}
	return renderStore;
}

async function publishNativeSurfaceSelectionRequest(props: {
	readonly bindingRevision: number;
	readonly nativeSelectionRequestId: string;
	readonly surface: 'file' | 'review';
}): Promise<void> {
	const request = makeNativeSurfaceSelectionRequest(props);
	await actWait(async (): Promise<void> => {
		for (const listener of paneRuntimeObservation.paneMessageListeners) listener(request);
		await Promise.resolve();
	});
}

async function publishNativeFileTargetSelectionRequest(props: {
	readonly bindingRevision: number;
	readonly commandId: string;
	readonly path: string;
	readonly sourceId: string;
	readonly subscriptionGeneration: number;
}): Promise<void> {
	const request = makeNativeFileTargetSelectionRequest(props);
	await actWait(async (): Promise<void> => {
		for (const listener of paneRuntimeObservation.paneMessageListeners) listener(request);
		await Promise.resolve();
	});
}

function activeViewerModeUpdateForNativeRequest(
	nativeSelectionRequestId: string,
): BridgeWorkerRpcCommandInput | undefined {
	return paneRuntimeObservation.paneCommands.findLast(
		(command): boolean =>
			command.command === 'activeViewerModeUpdate' &&
			command.update.nativeSelectionRequestId === nativeSelectionRequestId,
	);
}
