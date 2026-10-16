import type { Page } from 'playwright';

import {
	summarizeInteractionSamples,
	type ReviewStartupLoadTimingProof,
	type WorktreeStartupLoadTimingProof,
} from '../verify-bridge-viewer-worktree-review-proof.ts';
import { observeVerifierStartupStep } from './browser-session.ts';
import { worktreeDevServerUrl, worktreeReviewDevServerUrl } from './config.ts';
import { observeBridgeStartupDOMFact, type BridgeStartupDOMFact } from './startup-dom-facts.ts';
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
	});
	await observeVerifierStartupStep(
		'File DOM content loaded',
		page.goto(worktreeDevServerUrl, { waitUntil: 'domcontentloaded' }),
	).value();
	const pageApplicationMilliseconds = Math.max(0, performance.now() - pageLoadStartedAt);
	await waitForStartupFact(page, { kind: 'file.shell' });
	const shellMountedMilliseconds = Math.max(0, performance.now() - pageLoadStartedAt);
	const handshakeWorkerMilliseconds = await waitForBridgeHandshakeWorkerMilliseconds({
		page,
		pageLoadStartedAtEpochMilliseconds,
	});
	await waitForStartupFact(page, { kind: 'file.source' });
	const sourceAcceptedMilliseconds = Math.max(0, performance.now() - pageLoadStartedAt);
	await waitForStartupFact(page, { kind: 'file.metadata' });
	const metadataMilliseconds = Math.max(0, performance.now() - pageLoadStartedAt);
	await waitForStartupFact(page, { kind: 'file.selection' });
	const selectedPathMilliseconds = Math.max(0, performance.now() - pageLoadStartedAt);
	const path = await page.evaluate(
		(): string =>
			document
				.querySelector('[data-testid="bridge-file-viewer-shell"]')
				?.getAttribute('data-selected-display-path') ?? '',
	);
	if (path.length === 0) throw new Error('Expected a non-empty selected File startup path.');
	const [contentRequestStartedMilliseconds, contentResponseStartedMilliseconds] = await Promise.all(
		[
			contentRouteTiming.requestStartedMilliseconds.value(),
			contentRouteTiming.responseStartedMilliseconds.value(),
		],
	);
	await waitForStartupFact(page, { kind: 'file.content', path });
	const contentReadyMilliseconds = Math.max(0, performance.now() - pageLoadStartedAt);
	await waitForStartupFact(page, { kind: 'file.visibleContent', path });
	return {
		contentReadyMilliseconds,
		contentRequestStartedMilliseconds,
		contentResponseStartedMilliseconds,
		firstVisibleContentWindowMilliseconds: Math.max(0, performance.now() - pageLoadStartedAt),
		handshakeWorkerMilliseconds,
		metadataMilliseconds,
		pageApplicationMilliseconds,
		selectedPathMilliseconds,
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
	await observeVerifierStartupStep(
		'Review DOM content loaded',
		page.goto(worktreeReviewDevServerUrl, { waitUntil: 'domcontentloaded' }),
	).value();
	const pageApplicationMilliseconds = Math.max(0, performance.now() - pageLoadStartedAt);
	await waitForStartupFact(page, { kind: 'review.shell' });
	const handshakeWorkerMilliseconds = await waitForBridgeHandshakeWorkerMilliseconds({
		page,
		pageLoadStartedAtEpochMilliseconds,
	});
	await waitForStartupFact(page, { kind: 'review.metadata' });
	const metadataMilliseconds = Math.max(0, performance.now() - pageLoadStartedAt);
	await waitForStartupFact(page, { kind: 'review.content' });
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
	await waitForStartupFact(props.page, { kind: 'handshake' });
	const readyEpochMilliseconds = await props.page.evaluate(
		(): number => window.bridgeCompleteJourneyHandshakeReadyEpochMilliseconds ?? Number.NaN,
	);
	if (!Number.isFinite(readyEpochMilliseconds)) {
		throw new Error('Expected the Bridge handshake/worker-ready verifier timestamp.');
	}
	return Math.max(0, readyEpochMilliseconds - props.pageLoadStartedAtEpochMilliseconds);
}

async function waitForStartupFact(page: Page, fact: BridgeStartupDOMFact): Promise<void> {
	await observeVerifierStartupStep(
		`startup ${fact.kind}${'path' in fact ? ` ${fact.path}` : ''}`,
		page.evaluate(observeBridgeStartupDOMFact, fact),
	).value();
}
