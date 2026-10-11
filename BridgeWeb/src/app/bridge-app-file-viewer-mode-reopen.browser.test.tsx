import { createElement, type ComponentProps, type ReactElement } from 'react';
import { afterAll, afterEach, beforeEach, describe, expect, test, vi } from 'vitest';
import { cleanup, render } from 'vitest-browser-react';

// oxlint-disable-next-line import/no-unassigned-import -- Browser Mode renders need app CSS.
import './bridge-app.css';
import { createBridgePaneRuntime } from '../core/comm-worker/bridge-pane-runtime.js';
import type { BridgeProductCallResult } from '../core/comm-worker/bridge-product-call-contracts.js';
import type { BridgeProductSubscriptionOptions } from '../core/comm-worker/bridge-product-subscription-contracts.js';
import { BridgeProductTestFactRecorder } from '../core/comm-worker/test-fixtures/bridge-product-test-fact-recorder.js';
import type { BridgeFileViewerBrowserTestProductSession } from '../file-viewer/bridge-file-viewer-browser-test-app.js';
import { makeBrowserMetadataOnlyFileBatch } from '../file-viewer/bridge-file-viewer-browser-test-batches.js';
import { waitForBridgeFileViewerWorkerPublicationQueue } from '../file-viewer/bridge-file-viewer-browser-test-comm-worker.js';
import {
	createBridgeFileViewerBrowserTestPaneSessionFactory,
	installBridgeFileViewerNoopResizeObserver,
} from '../file-viewer/bridge-file-viewer-browser-test-harness.js';
import {
	actClick,
	actUpdate,
	actWait,
	installBridgeReadyHandshake,
} from './bridge-app-browser-test-actions.js';
import {
	awaitContextFocusHandoff,
	holdNextContextFocusHandoff,
	nextContextFocusHandoff,
	observeContextFocusIn,
} from './bridge-app-context-focus.browser.test-support.js';
import {
	observeBridgeAppDomUntilEqual,
	observeBridgeAppDomUntilTruthy,
} from './bridge-app-dom-observation.browser.test-support.js';
import { createFileShellResource } from './bridge-app-file-shell-resource.browser.test-support.js';
import { BridgeAppProtocolRouter } from './bridge-app-protocol-router.js';
import {
	awaitViewSettingsClose,
	hasPendingViewSettingsClose,
	joinViewSettingsCloseWithinAct,
	markViewSettingsOpening,
} from './bridge-app-view-settings-completion.browser.test-support.js';

// The existing shell-component seam preserves the production Suspense boundary.
vi.mock('../file-viewer/bridge-file-viewer-app.js', async (importOriginal) => {
	const original =
		await importOriginal<typeof import('../file-viewer/bridge-file-viewer-app.js')>();
	await import('../file-viewer/bridge-file-viewer-shell.js');
	return {
		...original,
		BridgeFileViewerApp: (
			props: ComponentProps<typeof original.BridgeFileViewerApp>,
		): ReactElement =>
			createElement(original.BridgeFileViewerAppImplementation, {
				...props,
				shellComponent: fileShellResource.component,
			}),
	};
});

vi.mock('../components/ui/popover.js', async (importOriginal) => {
	const original = await importOriginal<typeof import('../components/ui/popover.js')>();
	const support = await import('./bridge-app-view-settings-completion.browser.test-support.js');
	return support.withViewSettingsPopoverLifecycle(original);
});

const originalBridgeFileViewerModeResizeObserver = globalThis.ResizeObserver;
let lastReopenPhase = 'setup';
let fileShellResource = createFileShellResource();

function markReopenPhase(phase: string): void {
	lastReopenPhase = phase;
	console.info(`A7 phase: ${phase}`);
}

describe('Bridge file viewer mode re-open on switch', () => {
	beforeEach(async (context) => {
		fileShellResource = createFileShellResource();
		lastReopenPhase = 'setup';
		context.onTestFinished((): void => {
			if (context.signal.aborted || context.task.result?.state === 'fail')
				console.info(`A7 reopen failed/aborted at ${lastReopenPhase}.`);
		});
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
		await actWait(async (): Promise<void> => {
			fileShellResource.release();
			if (fileShellResource.hasStarted()) await fileShellResource.completed();
		});
		await actWait(waitForBridgeFileViewerWorkerPublicationQueue);
		await actUpdate(cleanup);
		document.body.replaceChildren();
		document.documentElement.removeAttribute('data-bridge-app-protocol');
	});

	test('joins a held File shell Suspense resolution before the Review-first switch returns', async () => {
		fileShellResource = createFileShellResource(true);
		const handshake = installBridgeReadyHandshake();
		let switching: Promise<void> | undefined;
		try {
			await renderFileProductApp('review', {
				currentSource: availableFileSource,
				initialFileBatch: makeBrowserMetadataOnlyFileBatch('open'),
			});
			switching = clickContext('file');
			await fileShellResource.started;
			expect(document.querySelector('[data-testid="bridge-file-viewer-shell"]')).toBeNull();
			const outcome = await Promise.race([
				switching.then((): 'returned' => 'returned'),
				fileShellResource.awaited.then((): 'owner-awaited' => 'owner-awaited'),
			]);
			expect(outcome, 'File switching must join its suspended shell loader.').toBe('owner-awaited');
			fileShellResource.release();
			await switching;
			expect(document.querySelector('[data-testid="bridge-file-viewer-shell"]')).not.toBeNull();
		} finally {
			await actWait(async (): Promise<void> => {
				fileShellResource.release();
				if (fileShellResource.hasStarted()) await fileShellResource.completed();
				await switching;
			});
			handshake.dispose();
		}
	});

	test('reuses the pane-owned File source warmed by a Review-first route', async () => {
		const warmupFacts = new BridgeProductTestFactRecorder<'sourceRead' | 'metadataSubscribed'>();
		let sourceDiscoveryCount = 0;
		let metadataSubscriptionOpenCount = 0;
		const productSession: BridgeFileViewerBrowserTestProductSession = {
			currentSource: (): BridgeProductCallResult<'file.source.current'> => {
				sourceDiscoveryCount += 1;
				warmupFacts.record('sourceRead');
				return availableFileSource();
			},
			initialFileBatch: makeBrowserMetadataOnlyFileBatch('open'),
			onMetadataSubscriptionOpen: (
				_options: BridgeProductSubscriptionOptions<'file.metadata'>,
			): void => {
				metadataSubscriptionOpenCount += 1;
				warmupFacts.record('metadataSubscribed');
			},
		};
		const handshake = installBridgeReadyHandshake();

		await renderFileProductApp('review', productSession);
		await actWait(() => warmupFacts.waitFor((fact): boolean => fact === 'sourceRead'));
		expect(sourceDiscoveryCount).toBe(1);
		await actWait(() => warmupFacts.waitFor((fact): boolean => fact === 'metadataSubscribed'));
		expect(metadataSubscriptionOpenCount).toBe(1);

		await clickContext('file');
		expect(await observeBridgeAppDomUntilEqual(activeViewerMode, 'file')).toBe('file');
		await awaitDisplayedFileSource();
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
		expect(await observeBridgeAppDomUntilEqual(activeViewerMode, 'file')).toBe('file');
		const outgoingReviewButton = activeContextButton('file', 'review');
		await actUpdate((): void => outgoingReviewButton.focus());
		expect(document.activeElement).toBe(outgoingReviewButton);

		// Act
		await clickContext('review', true);

		// Assert
		const incomingReviewButton = activeContextButton('review', 'review');
		expect(document.activeElement).toBe(incomingReviewButton);
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
		await awaitDisplayedFileSource();
		try {
			await clickContext('review', true);
			expect(activeViewerMode()).toBe('review');
			expect(document.activeElement).toBe(activeContextButton('review', 'review'));
		} finally {
			handshake.dispose();
		}
	});

	test('reuses a live healthy stream — no re-open spam on healthy re-activations', async () => {
		const warmupFacts = new BridgeProductTestFactRecorder<'sourceRead' | 'metadataSubscribed'>();
		let sourceDiscoveryCount = 0;
		let metadataSubscriptionOpenCount = 0;
		const productSession: BridgeFileViewerBrowserTestProductSession = {
			currentSource: (): BridgeProductCallResult<'file.source.current'> => {
				sourceDiscoveryCount += 1;
				warmupFacts.record('sourceRead');
				return availableFileSource();
			},
			initialFileBatch: makeBrowserMetadataOnlyFileBatch('open'),
			onMetadataSubscriptionOpen: (): void => {
				metadataSubscriptionOpenCount += 1;
				warmupFacts.record('metadataSubscribed');
			},
		};
		const handshake = installBridgeReadyHandshake();

		await renderFileProductApp('worktree-file', productSession);
		await actWait(() => warmupFacts.waitFor((fact): boolean => fact === 'sourceRead'));
		expect(sourceDiscoveryCount).toBe(1);
		await actWait(() => warmupFacts.waitFor((fact): boolean => fact === 'metadataSubscribed'));
		expect(metadataSubscriptionOpenCount).toBe(1);

		await clickContext('review');
		expect(await observeBridgeAppDomUntilEqual(activeViewerMode, 'review')).toBe('review');
		await clickContext('file');
		expect(await observeBridgeAppDomUntilEqual(activeViewerMode, 'file')).toBe('file');
		await awaitDisplayedFileSource();
		expect(sourceDiscoveryCount).toBe(1);
		expect(metadataSubscriptionOpenCount).toBe(1);
		handshake.dispose();
	});

	test('keeps Files and Review view settings separate across surface switches', async () => {
		const warmupFacts = new BridgeProductTestFactRecorder<'sourceRead' | 'metadataSubscribed'>();
		let sourceDiscoveryCount = 0;
		let metadataSubscriptionOpenCount = 0;
		const handshake = installBridgeReadyHandshake();
		await renderFileProductApp(
			'worktree-file',
			{
				currentSource: (): BridgeProductCallResult<'file.source.current'> => {
					sourceDiscoveryCount += 1;
					warmupFacts.record('sourceRead');
					return availableFileSource();
				},
				initialFileBatch: makeBrowserMetadataOnlyFileBatch('open'),
				onMetadataSubscriptionOpen: (): void => {
					metadataSubscriptionOpenCount += 1;
					warmupFacts.record('metadataSubscribed');
				},
			},
			true,
		);
		expect(await observeBridgeAppDomUntilEqual(activeViewerMode, 'file')).toBe('file');
		expect(
			await observeBridgeAppDomUntilTruthy(
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
		expect(await observeBridgeAppDomUntilEqual(activeViewerMode, 'review')).toBe('review');
		await waitForViewSettingsClosed('file');
		await openViewSettings('review');
		expect(viewSettingsRow('review', 'Word wrap').getAttribute('aria-checked')).toBe('true');
		await actClick(viewSettingsRow('review', 'Line numbers'));
		expect(viewSettingsRow('review', 'Line numbers').getAttribute('aria-checked')).toBe('false');

		await clickContext('file');
		expect(await observeBridgeAppDomUntilEqual(activeViewerMode, 'file')).toBe('file');
		await waitForViewSettingsClosed('review');
		await openViewSettings('file');
		expect(viewSettingsRow('file', 'Word wrap').getAttribute('aria-checked')).toBe('false');
		expect(viewSettingsRow('file', 'Line numbers').getAttribute('aria-checked')).toBe('true');

		await clickContext('review');
		expect(await observeBridgeAppDomUntilEqual(activeViewerMode, 'review')).toBe('review');
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
	const rendered = await render(
		<BridgeAppProtocolRouter
			codeViewWorkerPoolEnabled={false}
			fileViewerProps={{ autoOpenInitialFile }}
			paneRuntimeFactory={() => createBridgePaneRuntime({ sessionFactory: paneSessionFactory })}
			protocol={protocol}
		/>,
	);
	if (protocol === 'worktree-file') await actWait(fileShellResource.completed);
	return rendered;
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

async function clickContext(context: 'file' | 'review', waitForFocus = false): Promise<void> {
	const button = document.querySelector<HTMLElement>(
		`[data-testid="bridge-viewer-context-${context}"]`,
	);
	if (button === null) {
		throw new Error(`Missing bridge-viewer-context-${context} button`);
	}
	const outgoingSurface = activeViewerMode();
	const focusHandoff = nextContextFocusHandoff();
	const focusObservation = waitForFocus
		? observeContextFocusIn(
				(target): boolean =>
					target instanceof HTMLElement &&
					target.getAttribute('data-testid') === `bridge-viewer-context-${context}`,
			)
		: null;
	const heldFocus = holdNextContextFocusHandoff();
	markReopenPhase(`context ${context}: click`);
	try {
		await actClick(button);
		if (context === 'file') await actWait(fileShellResource.completed);
		await observeBridgeAppDomUntilEqual(activeViewerMode, context);
		markReopenPhase(`context ${context}: native focus and outgoing close`);
		await actWait(async (): Promise<void> => {
			await heldFocus.arrived;
			heldFocus.release();
			focusObservation?.inspect();
			await Promise.all([
				awaitContextFocusHandoff(focusHandoff),
				focusObservation?.arrived ?? Promise.resolve(),
				(outgoingSurface === 'file' || outgoingSurface === 'review') &&
				hasPendingViewSettingsClose(outgoingSurface)
					? awaitViewSettingsClose(outgoingSurface)
					: Promise.resolve(),
			]);
		});
	} finally {
		focusObservation?.close();
	}
	await observeBridgeAppDomUntilEqual(activeViewerMode, context);
}

async function openViewSettings(surface: 'file' | 'review'): Promise<void> {
	markReopenPhase(`${surface} view settings: open`);
	markViewSettingsOpening(surface);
	const trigger = activeViewSettingsTrigger(surface);
	await actClick(trigger);
	expect(
		await observeBridgeAppDomUntilEqual(
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
				markReopenPhase(`${surface} view settings: native animations`);
				const finished = animation.finished;
				animation.finish();
				try {
					await finished;
				} catch {
					// A surface switch can cancel the menu transition it supersedes.
				}
			}),
		);
	});
}

async function closeViewSettings(surface: 'file' | 'review'): Promise<void> {
	markReopenPhase(`${surface} view settings: close`);
	await actClick(activeViewSettingsTrigger(surface));
	await waitForViewSettingsClosed(surface);
}

async function waitForViewSettingsClosed(surface: 'file' | 'review'): Promise<void> {
	await joinViewSettingsCloseWithinAct(surface);
	expect(
		await observeBridgeAppDomUntilEqual(
			() =>
				document.querySelector(`[data-testid="bridge-${surface}-view-settings-content"]`) === null,
			true,
		),
	).toBe(true);
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

async function awaitDisplayedFileSource(): Promise<void> {
	await actWait(waitForBridgeFileViewerWorkerPublicationQueue);
	const shell = await observeBridgeAppDomUntilTruthy(() =>
		document.querySelector<HTMLElement>('[data-testid="bridge-file-viewer-shell"]'),
	);
	await observeBridgeAppDomUntilTruthy(
		() => shell?.getAttribute('data-file-display-source-id') ?? null,
	);
}
