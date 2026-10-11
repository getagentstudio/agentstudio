import type { Page } from 'playwright';

import {
	summarizeInteractionSamples,
	type ReviewStartupLoadTimingProof,
	type WorktreeStartupLoadTimingProof,
} from '../verify-bridge-viewer-worktree-review-proof.ts';
import { worktreeDevServerUrl, worktreeReviewDevServerUrl } from './config.ts';
import {
	waitForAnyWorktreeSelectedPathTiming,
	waitForWorktreeFirstVisibleContentWindow,
	waitForWorktreeMetadataMilliseconds,
	waitForWorktreeOpenFileReadyMilliseconds,
	waitForWorktreeSourceAcceptedMilliseconds,
} from './performance-click-waits.ts';
import { waitForAnyReviewSelectedContentState } from './review-tree-click.ts';
import { observeWorktreeFileContentRouteTiming } from './startup-route-timing.ts';

export interface WorktreeStartupTimingSample {
	readonly contentReadyMilliseconds: number;
	readonly contentRequestStartedMilliseconds: number;
	readonly contentResponseStartedMilliseconds: number;
	readonly firstVisibleContentWindowMilliseconds: number;
	readonly handshakeWorkerMilliseconds: number;
	readonly metadataMilliseconds: number;
	readonly pageApplicationMilliseconds: number;
	readonly selectedPathMilliseconds: number;
	readonly shellMountedMilliseconds: number;
	readonly sourceAcceptedMilliseconds: number;
}

export interface ReviewStartupTimingSample {
	readonly handshakeWorkerMilliseconds: number;
	readonly metadataMilliseconds: number;
	readonly pageApplicationMilliseconds: number;
	readonly selectedContentReadyMilliseconds: number;
}

export async function collectWorktreeStartupLoadTimingProof(props: {
	readonly page: Page;
}): Promise<WorktreeStartupLoadTimingProof> {
	const sample = await collectWorktreeStartupTimingSample(props.page);
	return {
		pageLoadToHandshakeWorker: summarizeInteractionSamples([sample.handshakeWorkerMilliseconds]),
		pageLoadToPageApplication: summarizeInteractionSamples([sample.pageApplicationMilliseconds]),
		pageLoadToContentReady: summarizeInteractionSamples([sample.contentReadyMilliseconds]),
		pageLoadToContentRequestStarted: summarizeInteractionSamples([
			sample.contentRequestStartedMilliseconds,
		]),
		pageLoadToContentResponseStarted: summarizeInteractionSamples([
			sample.contentResponseStartedMilliseconds,
		]),
		pageLoadToFirstVisibleContentWindow: summarizeInteractionSamples([
			sample.firstVisibleContentWindowMilliseconds,
		]),
		pageLoadToMetadata: summarizeInteractionSamples([sample.metadataMilliseconds]),
		pageLoadToSelectedPath: summarizeInteractionSamples([sample.selectedPathMilliseconds]),
		pageLoadToShellMounted: summarizeInteractionSamples([sample.shellMountedMilliseconds]),
		pageLoadToSourceAccepted: summarizeInteractionSamples([sample.sourceAcceptedMilliseconds]),
	};
}

export async function collectReviewStartupLoadTimingProof(props: {
	readonly page: Page;
}): Promise<ReviewStartupLoadTimingProof> {
	const sample = await collectReviewStartupTimingSample(props.page);
	return {
		pageLoadToHandshakeWorker: summarizeInteractionSamples([sample.handshakeWorkerMilliseconds]),
		pageLoadToPageApplication: summarizeInteractionSamples([sample.pageApplicationMilliseconds]),
		pageLoadToMetadata: summarizeInteractionSamples([sample.metadataMilliseconds]),
		pageLoadToSelectedContentReady: summarizeInteractionSamples([
			sample.selectedContentReadyMilliseconds,
		]),
	};
}

export async function collectWorktreeStartupTimingSample(
	page: Page,
	onTimingStarted?: (startedAt: number) => void,
): Promise<WorktreeStartupTimingSample> {
	const pageLoadStartedAt = performance.now();
	onTimingStarted?.(pageLoadStartedAt);
	const pageLoadStartedAtEpochMilliseconds = Date.now();
	const contentRouteTiming = observeWorktreeFileContentRouteTiming({
		page,
		startedAt: pageLoadStartedAt,
		timeoutMilliseconds: 20_000,
	});
	await page.goto(worktreeDevServerUrl, { waitUntil: 'domcontentloaded', timeout: 30_000 });
	const pageApplicationMilliseconds = Math.max(0, performance.now() - pageLoadStartedAt);
	await page.waitForSelector('[data-testid="bridge-file-viewer-shell"]', { timeout: 30_000 });
	const shellMountedMilliseconds = Math.max(0, performance.now() - pageLoadStartedAt);
	const handshakeWorkerMilliseconds = await waitForBridgeHandshakeWorkerMilliseconds({
		page,
		pageLoadStartedAtEpochMilliseconds,
	});
	const sourceAcceptedMilliseconds = await waitForWorktreeSourceAcceptedMilliseconds({
		page,
		startedAt: pageLoadStartedAt,
		timeoutMilliseconds: 20_000,
	});
	const metadataMilliseconds = await waitForWorktreeMetadataMilliseconds({
		page,
		startedAt: pageLoadStartedAt,
		timeoutMilliseconds: 20_000,
	});
	const selectedPathTiming = await waitForAnyWorktreeSelectedPathTiming({
		page,
		startedAt: pageLoadStartedAt,
		timeoutMilliseconds: 20_000,
	});
	const [contentRequestStartedMilliseconds, contentResponseStartedMilliseconds] = await Promise.all(
		[
			contentRouteTiming.requestStartedMilliseconds.value(),
			contentRouteTiming.responseStartedMilliseconds.value(),
		],
	);
	const contentReadyMilliseconds = await waitForWorktreeOpenFileReadyMilliseconds({
		page,
		path: selectedPathTiming.path,
		startedAt: pageLoadStartedAt,
		timeoutMilliseconds: 20_000,
	});
	await waitForWorktreeFirstVisibleContentWindow({
		page,
		path: selectedPathTiming.path,
		timeoutMilliseconds: 20_000,
	});
	return {
		contentReadyMilliseconds,
		contentRequestStartedMilliseconds,
		contentResponseStartedMilliseconds,
		firstVisibleContentWindowMilliseconds: Math.max(0, performance.now() - pageLoadStartedAt),
		handshakeWorkerMilliseconds,
		metadataMilliseconds,
		pageApplicationMilliseconds,
		selectedPathMilliseconds: selectedPathTiming.selectedPathMilliseconds,
		shellMountedMilliseconds,
		sourceAcceptedMilliseconds,
	};
}

export async function collectReviewStartupTimingSample(
	page: Page,
	onTimingStarted?: (startedAt: number) => void,
): Promise<ReviewStartupTimingSample> {
	const pageLoadStartedAt = performance.now();
	onTimingStarted?.(pageLoadStartedAt);
	const pageLoadStartedAtEpochMilliseconds = Date.now();
	await page.goto(worktreeReviewDevServerUrl, {
		waitUntil: 'domcontentloaded',
		timeout: 30_000,
	});
	const pageApplicationMilliseconds = Math.max(0, performance.now() - pageLoadStartedAt);
	await page.waitForSelector('[data-testid="review-viewer-shell"]', { timeout: 30_000 });
	const handshakeWorkerMilliseconds = await waitForBridgeHandshakeWorkerMilliseconds({
		page,
		pageLoadStartedAtEpochMilliseconds,
	});
	await page.waitForFunction(
		(): boolean => {
			const shell = document.querySelector('[data-testid="review-viewer-shell"]');
			return Number(shell?.getAttribute('data-review-metadata-item-count') ?? '0') > 0;
		},
		undefined,
		{ timeout: 30_000 },
	);
	const metadataMilliseconds = Math.max(0, performance.now() - pageLoadStartedAt);
	await waitForAnyReviewSelectedContentState({ page, state: 'ready' });
	return {
		handshakeWorkerMilliseconds,
		metadataMilliseconds,
		pageApplicationMilliseconds,
		selectedContentReadyMilliseconds: Math.max(0, performance.now() - pageLoadStartedAt),
	};
}

async function waitForBridgeHandshakeWorkerMilliseconds(props: {
	readonly page: Page;
	readonly pageLoadStartedAtEpochMilliseconds: number;
}): Promise<number> {
	await props.page.waitForFunction(
		(): boolean => Number.isFinite(window.bridgeCompleteJourneyHandshakeReadyEpochMilliseconds),
		undefined,
		{ timeout: 30_000 },
	);
	const readyEpochMilliseconds = await props.page.evaluate(
		(): number => window.bridgeCompleteJourneyHandshakeReadyEpochMilliseconds ?? Number.NaN,
	);
	if (!Number.isFinite(readyEpochMilliseconds)) {
		throw new Error('Expected the Bridge handshake/worker-ready verifier timestamp.');
	}
	return Math.max(0, readyEpochMilliseconds - props.pageLoadStartedAtEpochMilliseconds);
}
