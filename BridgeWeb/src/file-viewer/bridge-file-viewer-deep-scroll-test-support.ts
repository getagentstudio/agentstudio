import { expect } from 'vitest';

import type { BridgeProductViewInstallation } from '../core/comm-worker/bridge-product-view-batch-receiver.js';
import { findBridgeViewerTreeScrollOwner } from '../review-viewer/test-support/bridge-viewer-browser-dom.js';
import { initializeBridgePierreWorkerPoolSingletonForTest } from '../review-viewer/workers/pierre/bridge-pierre-worker-pool.js';
import {
	makeBrowserFileBatch,
	makeBrowserFileDescriptorOutcome,
	makeBrowserFileRow,
	makeBrowserFileSourceIdentity,
	makeBrowserSequentialFileRows,
	type BrowserFileDescriptorOutcome,
} from './bridge-file-viewer-browser-test-batches.js';
import {
	countFileContentByte,
	fileContentSha256Hex,
	logicalFileContentLineCount,
} from './bridge-file-viewer-browser-test-fixtures.js';
import {
	actClick,
	actFrame,
	actUpdate,
	openFileState,
	renderedFilePath,
	selectedDisplayPath,
} from './bridge-file-viewer-browser-test-harness.js';

export const completeFileDeepScrollTreeRowCount = 3_420;

export const completeFileDeepScrollFixture = createCompleteFileDeepScrollFixture();

export interface DeepScrollSurfacePaintSnapshot {
	readonly clientRectCount: number;
	readonly height: number;
	readonly opacity: string;
	readonly visibility: string;
	readonly width: number;
}

export async function settleCompleteFilePierreWorkerPoolInitialization(
	workerFactory: () => Worker,
): Promise<void> {
	let managerState: string | null = null;
	await actUpdate(async (): Promise<void> => {
		managerState = (await initializeBridgePierreWorkerPoolSingletonForTest(workerFactory))
			.managerState;
	});
	expect(managerState).toBe('initialized');
	await waitForCompleteFilePierreWorkerPoolReady({ attempt: 0, requirePaintedPublication: false });
}

export async function waitForCompleteFileInitialPaintReady(): Promise<void> {
	await waitForCompleteFilePierreWorkerPoolReady({
		attempt: 0,
		previousPaintedPublicationId: null,
		requirePaintedPublication: true,
		stableFrameCount: 0,
	});
}

async function waitForCompleteFilePierreWorkerPoolReady(props: {
	readonly attempt: number;
	readonly previousPaintedPublicationId?: string | null;
	readonly requirePaintedPublication: boolean;
	readonly stableFrameCount?: number;
}): Promise<void> {
	const managerState = document.documentElement.dataset['bridgePierreWorkerPoolManagerState'];
	const busyWorkerCount = document.documentElement.dataset['bridgePierreWorkerPoolBusyWorkers'];
	const queuedTaskCount = document.documentElement.dataset['bridgePierreWorkerPoolQueuedTasks'];
	const activeTaskCount = document.documentElement.dataset['bridgePierreWorkerPoolActiveTasks'];
	const loadingStatus = document.querySelector('[data-testid="bridge-pierre-worker-pool-loading"]');
	const paintedPublication = document.querySelector(
		'diffs-container[data-bridge-painted-publication-id]',
	);
	const paintedPublicationId =
		paintedPublication?.getAttribute('data-bridge-painted-publication-id') ?? null;
	const renderedReadinessObserved =
		managerState === 'initialized' &&
		loadingStatus === null &&
		(!props.requirePaintedPublication || paintedPublicationId !== null);
	const stableFrameCount =
		renderedReadinessObserved &&
		(!props.requirePaintedPublication ||
			paintedPublicationId === props.previousPaintedPublicationId)
			? (props.stableFrameCount ?? 0) + 1
			: 0;
	if (renderedReadinessObserved && stableFrameCount >= 2) {
		return;
	}
	if (props.attempt >= 120) {
		throw new Error(
			`Complete File Pierre worker pool did not reach rendered readiness; manager=${managerState ?? 'missing'} busy=${busyWorkerCount ?? 'missing'} queued=${queuedTaskCount ?? 'missing'} active=${activeTaskCount ?? 'missing'} loading=${loadingStatus === null ? 'absent' : 'present'} paintedPublication=${paintedPublication === null ? 'missing' : 'present'}.`,
		);
	}
	await actFrame();
	await waitForCompleteFilePierreWorkerPoolReady({
		attempt: props.attempt + 1,
		previousPaintedPublicationId: paintedPublicationId,
		requirePaintedPublication: props.requirePaintedPublication,
		stableFrameCount,
	});
}

export async function assertCompleteFilePositionSurvivesModeSwitch(props: {
	readonly codeScrollOwner: HTMLElement;
	readonly expectedSelectedPath: string;
	readonly treeScrollOwner: HTMLElement;
}): Promise<void> {
	const initialCodeScrollTop = props.codeScrollOwner.scrollTop;
	const initialTreeScrollTop = props.treeScrollOwner.scrollTop;
	const initialCodeScrollProgress = scrollProgress(props.codeScrollOwner);
	const initialTreeScrollProgress = scrollProgress(props.treeScrollOwner);
	const fileHost = await waitForDeepScrollRouteElement({
		attempt: 0,
		selector: '[data-testid="bridge-viewer-mode-host-file"]',
	});
	const appRoot = await waitForDeepScrollRouteElement({
		attempt: 0,
		selector: '[data-testid="bridge-app-root"]',
	});

	await actClick(requireActiveContextButton('review'));
	await actFrame();
	expect(appRoot.getAttribute('data-bridge-viewer-mode')).toBe('review');
	expect(fileHost.hidden).toBe(false);
	expect(fileHost.getAttribute('aria-hidden')).toBe('true');
	expect(fileHost.getAttribute('data-bridge-viewer-mode-active')).toBe('false');
	expect(fileHost.inert).toBe(true);
	expect(getComputedStyle(fileHost).visibility).toBe('hidden');
	expect(props.treeScrollOwner.isConnected).toBe(true);
	expect(props.codeScrollOwner.isConnected).toBe(true);

	await actClick(requireActiveContextButton('file'));
	await actFrame();
	await actFrame();

	expect(appRoot.getAttribute('data-bridge-viewer-mode')).toBe('file');
	expect(fileHost.hidden).toBe(false);
	expect(fileHost.getAttribute('aria-hidden')).toBe('false');
	expect(fileHost.getAttribute('data-bridge-viewer-mode-active')).toBe('true');
	expect(fileHost.inert).toBe(false);
	expect(getComputedStyle(fileHost).visibility).toBe('visible');
	expect(findBridgeViewerTreeScrollOwner()).toBe(props.treeScrollOwner);
	expect(document.querySelector('.bridge-code-view-scroll-owner')).toBe(props.codeScrollOwner);
	expect(initialTreeScrollTop).toBeGreaterThan(0);
	expect(initialCodeScrollTop).toBeGreaterThan(0);
	expect(props.treeScrollOwner.scrollTop).toBeGreaterThan(0);
	expect(props.codeScrollOwner.scrollTop).toBeGreaterThan(0);
	expect(Math.abs(scrollProgress(props.treeScrollOwner) - initialTreeScrollProgress)).toBeLessThan(
		0.05,
	);
	expect(Math.abs(scrollProgress(props.codeScrollOwner) - initialCodeScrollProgress)).toBeLessThan(
		0.05,
	);
	expect(selectedDisplayPath()).toBe(props.expectedSelectedPath);
	expect(renderedFilePath()).toBe(props.expectedSelectedPath);
}

function scrollProgress(scrollOwner: HTMLElement): number {
	return scrollOwner.scrollTop / Math.max(scrollOwner.scrollHeight - scrollOwner.clientHeight, 1);
}

export async function waitForDeepScrollRouteElement(props: {
	readonly attempt: number;
	readonly selector: string;
}): Promise<HTMLElement> {
	const element = document.querySelector(props.selector);
	if (element instanceof HTMLElement) return element;
	if (props.attempt >= 120) {
		throw new Error(`FILE_DEEP_SCROLL_HARNESS_INVALID: missing route element ${props.selector}.`);
	}
	await actFrame();
	return await waitForDeepScrollRouteElement({
		attempt: props.attempt + 1,
		selector: props.selector,
	});
}

function requireActiveContextButton(mode: 'file' | 'review'): HTMLElement {
	const button = document.querySelector(
		`[data-bridge-viewer-mode-active="true"] [data-testid="bridge-viewer-context-${mode}"]`,
	);
	if (!(button instanceof HTMLElement)) {
		throw new Error(`FILE_DEEP_SCROLL_CONTEXT_BUTTON_MISSING: mode=${mode}`);
	}
	return button;
}

export function makeCompleteFileDeepScrollDescriptor(props: {
	readonly contentHandle: string;
	readonly fileId: string;
	readonly path: string;
}): BrowserFileDescriptorOutcome {
	return makeBrowserFileDescriptorOutcome({
		declaredByteLength: completeFileDeepScrollFixture.byteCount,
		expectedSha256: completeFileDeepScrollFixture.sha256,
		descriptorId: props.contentHandle,
		endsWithNewline: false,
		fileId: props.fileId,
		lineCount: completeFileDeepScrollFixture.lineCount,
		path: props.path,
		source: makeBrowserFileSourceIdentity(),
	});
}

export function makeCompleteFileDeepScrollBatch(
	descriptor: BrowserFileDescriptorOutcome,
): BridgeProductViewInstallation {
	const rows = makeBrowserSequentialFileRows({ count: completeFileDeepScrollTreeRowCount });
	return makeBrowserFileBatch({
		snapshotCause: 'open',
		rows: [
			makeBrowserFileRow({
				path: descriptor.path,
				fileId: descriptor.fileId,
				descriptorOutcome: descriptor,
			}),
			...rows.slice(1),
		],
		source: descriptor.source,
	});
}

export async function assertCompleteFileDeepScrollSourceOracle(): Promise<void> {
	expect(completeFileDeepScrollFixture.bytes.byteLength).toBe(
		completeFileDeepScrollFixture.byteCount,
	);
	expect(completeFileDeepScrollFixture.bytes.byteLength).toBeGreaterThan(2 * 1024 * 1024);
	expect(logicalFileContentLineCount(completeFileDeepScrollFixture.bytes)).toBe(
		completeFileDeepScrollFixture.lineCount,
	);
	expect(countFileContentByte(completeFileDeepScrollFixture.bytes, 0x0d)).toBe(10_000);
	expect(countFileContentByte(completeFileDeepScrollFixture.bytes, 0x0a)).toBe(10_000);
	expect(
		completeFileDeepScrollFixture.text.endsWith(completeFileDeepScrollFixture.finalSourceText),
	).toBe(true);
	expect(
		completeFileDeepScrollFixture.text.split(completeFileDeepScrollFixture.finalSourceText),
	).toHaveLength(2);
	expect(completeFileDeepScrollFixture.text.endsWith('\n')).toBe(false);
	expect(await fileContentSha256Hex(completeFileDeepScrollFixture.bytes)).toBe(
		completeFileDeepScrollFixture.sha256,
	);
}

export function makeCorruptedCompleteFileDeepScrollContent(): {
	readonly bytes: Uint8Array<ArrayBuffer>;
	readonly text: string;
} {
	const bytes = completeFileDeepScrollFixture.bytes.slice();
	for (let index = Math.floor(bytes.byteLength / 2); index < bytes.byteLength; index += 1) {
		if (bytes[index] !== 0x78) continue;
		bytes[index] = 0x79;
		return { bytes, text: new TextDecoder('utf-8', { fatal: true }).decode(bytes) };
	}
	throw new Error('Complete File corruption fixture contains no middle filler byte.');
}

export async function waitForCompleteFileDeepScrollTerminalState(
	attempt = 0,
): Promise<'failed' | 'ready' | 'unavailable'> {
	const state = openFileState();
	if (state === 'failed' || state === 'ready' || state === 'unavailable') return state;
	if (attempt >= 120) {
		throw new Error(`Complete File digest witness did not terminate; state=${state}.`);
	}
	await actFrame();
	return waitForCompleteFileDeepScrollTerminalState(attempt + 1);
}

function createCompleteFileDeepScrollFixture(): {
	readonly byteCount: number;
	readonly bytes: Uint8Array<ArrayBuffer>;
	readonly finalSourceText: string;
	readonly firstSourceText: string;
	readonly lineCount: number;
	readonly sha256: string;
	readonly text: string;
} {
	const byteCount = 2_097_217;
	const lineCount = 10_001;
	const finalSourceText = 'line-10001: __BRIDGE_FILE_COMPLETE_FINAL_CANARY_8B3F27D1__ λ😀';
	const regularCRLFLineByteCount = 209;
	const boundaryLineByteCount = 2 * 1024 * 1024 - (lineCount - 2) * regularCRLFLineByteCount;
	const lines = Array.from({ length: lineCount - 2 }, (_value, lineOffset) =>
		makeExactCompleteFileCRLFLine({
			prefix: `line-${String(lineOffset + 1).padStart(5, '0')}: λ😀 `,
			totalByteCount: regularCRLFLineByteCount,
		}),
	);
	lines.push(
		makeExactCompleteFileCRLFLine({
			prefix: 'line-10000: boundary λ😀 ',
			totalByteCount: boundaryLineByteCount,
		}),
	);
	const text = `${lines.join('')}${finalSourceText}`;
	return {
		byteCount,
		bytes: new TextEncoder().encode(text),
		finalSourceText,
		firstSourceText: 'line-00001: λ😀',
		lineCount,
		sha256: 'c15344b0a2aabc7a0f63ddda2d79d604bce142de7228fc3f36162db775a6cbda',
		text,
	};
}

function makeExactCompleteFileCRLFLine(props: {
	readonly prefix: string;
	readonly totalByteCount: number;
}): string {
	const prefixByteCount = new TextEncoder().encode(props.prefix).byteLength;
	const fillerByteCount = props.totalByteCount - prefixByteCount - 2;
	if (!Number.isSafeInteger(fillerByteCount) || fillerByteCount < 0) {
		throw new Error('Complete File source line cannot satisfy its exact byte contract.');
	}
	return `${props.prefix}${'x'.repeat(fillerByteCount)}\r\n`;
}
