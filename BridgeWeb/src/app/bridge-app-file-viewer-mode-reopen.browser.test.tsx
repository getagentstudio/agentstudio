import { afterAll, afterEach, beforeEach, describe, expect, test, vi } from 'vitest';
import { cleanup, render } from 'vitest-browser-react';

// oxlint-disable-next-line import/no-unassigned-import -- Browser Mode renders need app CSS.
import './bridge-app.css';
import { createBridgePaneRuntime } from '../core/comm-worker/bridge-pane-runtime.js';
import type { BridgeProductCallResult } from '../core/comm-worker/bridge-product-call-contracts.js';
import type { BridgeProductSubscriptionOptions } from '../core/comm-worker/bridge-product-subscription-contracts.js';
import type { BridgeFileViewerBrowserTestProductSession } from '../file-viewer/bridge-file-viewer-browser-test-app.js';
import { makeBrowserMetadataOnlyFileBatch } from '../file-viewer/bridge-file-viewer-browser-test-batches.js';
import {
	actFrame,
	createBridgeFileViewerBrowserTestPaneSessionFactory,
	installBridgeFileViewerNoopResizeObserver,
	settleBridgeFileViewerBrowserUpdates,
} from '../file-viewer/bridge-file-viewer-browser-test-harness.js';
import {
	actClick,
	actUpdate,
	actWait,
	installBridgeReadyHandshake,
	pollWithinActUntilEqual,
	pollWithinActUntilTruthy,
} from './bridge-app-browser-test-actions.js';
import { BridgeAppProtocolRouter } from './bridge-app-protocol-router.js';

const originalBridgeFileViewerModeResizeObserver = globalThis.ResizeObserver;

describe('Bridge file viewer mode re-open on switch', () => {
	beforeEach(async () => {
		installBridgeFileViewerNoopResizeObserver();
		await actUpdate(async (): Promise<void> => {
			await Promise.all([
				import('../file-viewer/bridge-file-viewer-shell.js'),
				import('../review-viewer/shell/review-viewer-shell.js'),
			]);
		});
	});

	afterAll(() => {
		Object.assign(globalThis, { ResizeObserver: originalBridgeFileViewerModeResizeObserver });
	});

	afterEach(async () => {
		if (document.querySelector('[data-testid="bridge-file-viewer-shell"]') !== null) {
			await settleBridgeFileViewerBrowserUpdates();
		}
		await actUpdate(cleanup);
		document.body.replaceChildren();
		document.documentElement.removeAttribute('data-bridge-app-protocol');
	});

	test('reuses the pane-owned File source warmed by a Review-first route', async () => {
		let sourceDiscoveryCount = 0;
		let metadataSubscriptionOpenCount = 0;
		const productSession: BridgeFileViewerBrowserTestProductSession = {
			currentSource: (): BridgeProductCallResult<'file.source.current'> => {
				sourceDiscoveryCount += 1;
				return availableFileSource();
			},
			initialFileBatch: makeBrowserMetadataOnlyFileBatch('open'),
			onMetadataSubscriptionOpen: (
				_options: BridgeProductSubscriptionOptions<'file.metadata'>,
			): void => {
				metadataSubscriptionOpenCount += 1;
			},
		};
		const handshake = installBridgeReadyHandshake();

		await renderFileProductApp('review', productSession);
		expect(await pollWithinActUntilEqual(() => sourceDiscoveryCount, 1)).toBe(1);
		expect(await pollWithinActUntilEqual(() => metadataSubscriptionOpenCount, 1)).toBe(1);

		await clickContext('file');
		expect(await pollWithinActUntilEqual(activeViewerMode, 'file')).toBe('file');
		await settleBridgeFileViewerBrowserUpdates();
		const contextSwitcher = document.querySelector<HTMLElement>(
			'[data-testid="bridge-viewer-context-switcher"]',
		);
		expect(contextSwitcher).not.toBeNull();
		expect(
			contextSwitcher?.closest('[data-testid="bridge-file-viewer-rail-toolbar-leading"]'),
		).not.toBeNull();
		expect(
			contextSwitcher?.closest('[data-testid="bridge-viewer-content-topbar-controls"]'),
		).toBeNull();
		expect(sourceDiscoveryCount).toBe(1);
		expect(metadataSubscriptionOpenCount).toBe(1);
		handshake.dispose();
	});

	test('hands context-switcher focus to the newly visible retained surface', async () => {
		// Arrange
		const handshake = installBridgeReadyHandshake();
		await renderFileProductApp('worktree-file', {
			currentSource: availableFileSource,
			initialFileBatch: makeBrowserMetadataOnlyFileBatch('open'),
		});
		expect(await pollWithinActUntilEqual(activeViewerMode, 'file')).toBe('file');
		const outgoingReviewButton = activeContextButton('file', 'review');
		await actUpdate((): void => outgoingReviewButton.focus());
		expect(document.activeElement).toBe(outgoingReviewButton);

		// Act
		await actClick(outgoingReviewButton);
		// useBridgeViewerContextFocusHandoff queues focus on the incoming toggle in rAF.
		await actFrame();
		expect(await pollWithinActUntilEqual(activeViewerMode, 'review')).toBe('review');

		// Assert
		const incomingReviewButton = activeContextButton('review', 'review');
		const focusWasHandedOff = await pollWithinActUntilEqual(
			() => document.activeElement === incomingReviewButton,
			true,
		);
		if (!focusWasHandedOff) {
			throw new Error(
				`Expected focus on incoming Review control; actual=${document.activeElement?.outerHTML ?? 'none'}`,
			);
		}
		expect(
			document
				.querySelector<HTMLElement>('[data-bridge-viewer-mode-host="file"]')
				?.contains(document.activeElement),
		).toBe(false);
		handshake.dispose();
	});

	test('settles a held context focus handoff before the mode-switch step completes', async () => {
		// Arrange: hold only the production handoff, leaving other owners' frames real.
		const handshake = installBridgeReadyHandshake();
		await renderFileProductApp('worktree-file', {
			currentSource: availableFileSource,
			initialFileBatch: makeBrowserMetadataOnlyFileBatch('open'),
		});
		await settleBridgeFileViewerBrowserUpdates();
		let heldFocusHandoff: FrameRequestCallback | undefined;
		let focusHandoffReleasedByStep = false;
		const requestFrame = window.requestAnimationFrame.bind(window);
		const heldFrameId = requestFrame((): void => {});
		window.cancelAnimationFrame(heldFrameId);
		const frameSpy = vi
			.spyOn(window, 'requestAnimationFrame')
			.mockImplementation((callback: FrameRequestCallback): number => {
				if (callback.toString().includes('focusActiveBridgeViewerContextControl')) {
					heldFocusHandoff = callback;
					return heldFrameId;
				}
				// The step's actFrame awaits this existing owner's frame completion.
				if (
					heldFocusHandoff !== undefined &&
					new Error().stack?.includes('waitForBridgeViewerAnimationFrame') === true
				) {
					const handoff = heldFocusHandoff;
					heldFocusHandoff = undefined;
					return requestFrame((timestamp: number): void => {
						handoff(timestamp);
						focusHandoffReleasedByStep = true;
						callback(timestamp);
					});
				}
				return requestFrame(callback);
			});
		try {
			// Act: removing the step's causal frame leaves this callback held.
			await clickContext('review');
			// Release any unsettled callback outside act: the red must trip the real guard.
			// This branch also drains the owned callback before a failed assertion returns.
			heldFocusHandoff?.(0);

			// Assert
			expect(focusHandoffReleasedByStep).toBe(true);
			expect(activeViewerMode()).toBe('review');
			expect(document.activeElement).toBe(activeContextButton('review', 'review'));
		} finally {
			frameSpy.mockRestore();
			handshake.dispose();
		}
	});

	test('reuses a live healthy stream — no re-open spam on healthy re-activations', async () => {
		let sourceDiscoveryCount = 0;
		let metadataSubscriptionOpenCount = 0;
		const productSession: BridgeFileViewerBrowserTestProductSession = {
			currentSource: (): BridgeProductCallResult<'file.source.current'> => {
				sourceDiscoveryCount += 1;
				return availableFileSource();
			},
			initialFileBatch: makeBrowserMetadataOnlyFileBatch('open'),
			onMetadataSubscriptionOpen: (): void => {
				metadataSubscriptionOpenCount += 1;
			},
		};
		const handshake = installBridgeReadyHandshake();

		await renderFileProductApp('worktree-file', productSession);
		expect(await pollWithinActUntilEqual(() => sourceDiscoveryCount, 1)).toBe(1);
		expect(await pollWithinActUntilEqual(() => metadataSubscriptionOpenCount, 1)).toBe(1);

		await clickContext('review');
		expect(await pollWithinActUntilEqual(activeViewerMode, 'review')).toBe('review');
		await settleViewerFrames();
		await clickContext('file');
		expect(await pollWithinActUntilEqual(activeViewerMode, 'file')).toBe('file');
		await settleBridgeFileViewerBrowserUpdates();
		await settleViewerFrames();
		expect(sourceDiscoveryCount).toBe(1);
		expect(metadataSubscriptionOpenCount).toBe(1);
		handshake.dispose();
	});

	test('keeps Files and Review view settings separate across surface switches', async () => {
		let sourceDiscoveryCount = 0;
		let metadataSubscriptionOpenCount = 0;
		const handshake = installBridgeReadyHandshake();
		await renderFileProductApp(
			'worktree-file',
			{
				currentSource: (): BridgeProductCallResult<'file.source.current'> => {
					sourceDiscoveryCount += 1;
					return availableFileSource();
				},
				initialFileBatch: makeBrowserMetadataOnlyFileBatch('open'),
				onMetadataSubscriptionOpen: (): void => {
					metadataSubscriptionOpenCount += 1;
				},
			},
			true,
		);
		expect(await pollWithinActUntilEqual(activeViewerMode, 'file')).toBe('file');
		expect(
			await pollWithinActUntilTruthy(
				() => activeFileShell()?.getAttribute('data-selected-display-path') ?? null,
			),
		).not.toBeNull();
		const initialFileIdentity = fileIdentitySnapshot();

		await openViewSettings('file');
		await actClick(viewSettingsRow('file', 'Word wrap'));
		expect(viewSettingsRow('file', 'Word wrap').getAttribute('aria-checked')).toBe('false');
		expect(fileIdentitySnapshot()).toEqual(initialFileIdentity);
		expect(sourceDiscoveryCount).toBe(1);
		expect(metadataSubscriptionOpenCount).toBe(1);

		await clickContext('review');
		expect(await pollWithinActUntilEqual(activeViewerMode, 'review')).toBe('review');
		await waitForViewSettingsClosed('file');
		await openViewSettings('review');
		expect(viewSettingsRow('review', 'Word wrap').getAttribute('aria-checked')).toBe('true');
		await actClick(viewSettingsRow('review', 'Line numbers'));
		expect(viewSettingsRow('review', 'Line numbers').getAttribute('aria-checked')).toBe('false');

		await clickContext('file');
		expect(await pollWithinActUntilEqual(activeViewerMode, 'file')).toBe('file');
		await waitForViewSettingsClosed('review');
		await openViewSettings('file');
		expect(viewSettingsRow('file', 'Word wrap').getAttribute('aria-checked')).toBe('false');
		expect(viewSettingsRow('file', 'Line numbers').getAttribute('aria-checked')).toBe('true');

		await clickContext('review');
		expect(await pollWithinActUntilEqual(activeViewerMode, 'review')).toBe('review');
		await waitForViewSettingsClosed('file');
		await openViewSettings('review');
		expect(viewSettingsRow('review', 'Word wrap').getAttribute('aria-checked')).toBe('true');
		expect(viewSettingsRow('review', 'Line numbers').getAttribute('aria-checked')).toBe('false');
		await closeViewSettings('review');
		handshake.dispose();
	});
});

async function renderFileProductApp(
	protocol: 'review' | 'worktree-file',
	productSession: BridgeFileViewerBrowserTestProductSession,
	autoOpenInitialFile = false,
): Promise<Awaited<ReturnType<typeof render>>> {
	const paneSessionFactory = createBridgeFileViewerBrowserTestPaneSessionFactory({
		productSessionRef: { current: productSession },
	});
	return await render(
		<BridgeAppProtocolRouter
			codeViewWorkerPoolEnabled={false}
			fileViewerProps={{ autoOpenInitialFile }}
			paneRuntimeFactory={() => createBridgePaneRuntime({ sessionFactory: paneSessionFactory })}
			protocol={protocol}
		/>,
	);
}

function activeFileShell(): HTMLElement | null {
	return document.querySelector<HTMLElement>(
		'[data-bridge-viewer-mode-active="true"] [data-testid="bridge-file-viewer-shell"]',
	);
}

function fileIdentitySnapshot(): Readonly<Record<string, string | null>> {
	const shell = activeFileShell();
	if (shell === null) throw new Error('Missing active Files shell');
	return {
		generation: shell.getAttribute('data-file-display-generation'),
		selectedPath: shell.getAttribute('data-selected-display-path'),
		sourceId: shell.getAttribute('data-file-display-source-id'),
	};
}

function availableFileSource(): BridgeProductCallResult<'file.source.current'> {
	return {
		status: 'available',
		source: {
			cwdScope: null,
			freshness: 'live',
			includeStatuses: true,
			repoId: '00000000-0000-4000-8000-000000000001',
			rootPathToken: 'browser-test-root',
			worktreeId: '00000000-0000-4000-8000-000000000002',
		},
	};
}

function activeViewerMode(): string | null {
	return (
		document
			.querySelector('[data-testid="bridge-app-root"]')
			?.getAttribute('data-bridge-viewer-mode') ?? null
	);
}

function activeContextButton(
	activeSurface: 'file' | 'review',
	targetSurface: 'file' | 'review',
): HTMLElement {
	const button = document.querySelector<HTMLElement>(
		`[data-bridge-viewer-mode-host="${activeSurface}"][data-bridge-viewer-mode-active="true"] [data-bridge-viewer-context-target="${targetSurface}"]`,
	);
	if (button === null) {
		throw new Error(`Missing active ${activeSurface} context button for ${targetSurface}.`);
	}
	return button;
}

async function clickContext(context: 'file' | 'review'): Promise<void> {
	const button = document.querySelector<HTMLElement>(
		`[data-testid="bridge-viewer-context-${context}"]`,
	);
	if (button === null) {
		throw new Error(`Missing bridge-viewer-context-${context} button`);
	}
	await actClick(button);
	// useBridgeViewerContextFocusHandoff queues focus on the incoming toggle in rAF.
	await actFrame();
}

async function openViewSettings(surface: 'file' | 'review'): Promise<void> {
	const trigger = activeViewSettingsTrigger(surface);
	await actClick(trigger);
	expect(
		await pollWithinActUntilEqual(
			() =>
				document.querySelector(`[data-testid="bridge-${surface}-view-settings-content"]`) !== null,
			true,
		),
	).toBe(true);
	await actWait(async (): Promise<void> => {
		const content = document.querySelector<HTMLElement>(
			`[data-testid="bridge-${surface}-view-settings-content"]`,
		);
		if (content === null) return;
		await Promise.all(
			content.getAnimations().map(async (animation): Promise<void> => {
				try {
					await animation.finished;
				} catch {
					// A surface switch can cancel the menu transition it supersedes.
				}
			}),
		);
	});
}

async function closeViewSettings(surface: 'file' | 'review'): Promise<void> {
	await actClick(activeViewSettingsTrigger(surface));
	await waitForViewSettingsClosed(surface);
}

async function waitForViewSettingsClosed(surface: 'file' | 'review'): Promise<void> {
	expect(
		await pollWithinActUntilEqual(
			() =>
				document.querySelector(`[data-testid="bridge-${surface}-view-settings-content"]`) === null,
			true,
		),
	).toBe(true);
	await settleViewerFrames();
}

function activeViewSettingsTrigger(surface: 'file' | 'review'): HTMLElement {
	const trigger = document.querySelector<HTMLElement>(
		`[data-bridge-viewer-mode-active="true"] [data-testid="bridge-${surface}-view-settings-trigger"]`,
	);
	if (trigger === null) throw new Error(`Missing active ${surface} View Settings trigger`);
	return trigger;
}

function viewSettingsRow(surface: 'file' | 'review', label: string): HTMLElement {
	const content = document.querySelector<HTMLElement>(
		`[data-testid="bridge-${surface}-view-settings-content"]`,
	);
	if (content === null) throw new Error(`Missing ${surface} View Settings content`);
	const row = [...content.querySelectorAll<HTMLElement>('[role="switch"]')].find(
		(candidate): boolean => candidate.getAttribute('aria-label') === label,
	);
	if (row === undefined) throw new Error(`Missing View Settings row: ${label}`);
	return row;
}

async function settleViewerFrames(): Promise<void> {
	await actWait(
		() =>
			new Promise<void>((resolve): void => {
				requestAnimationFrame((): void => {
					requestAnimationFrame((): void => resolve());
				});
			}),
	);
}
