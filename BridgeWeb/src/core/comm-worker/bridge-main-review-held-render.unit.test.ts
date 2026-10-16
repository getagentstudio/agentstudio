import { describe, expect, test } from 'vitest';

import { createBridgeMainRenderFulfillmentCoordinator } from './bridge-main-render-fulfillment-coordinator.js';
import {
	ACTIVE,
	CANDIDATE,
	SUCCESSOR,
	candidateFailed,
	candidateReady,
	createHarness,
	installPublication,
	reviewDisplayEvent,
	reviewPierrePublication,
} from './bridge-main-review-publication-integration.test-support.js';
import type { BridgeWorkerReviewPierreRenderJobEvent } from './bridge-worker-contracts.js';
import { BridgeWorkerRenderFulfillmentRegistry } from './bridge-worker-render-fulfillment-registry.js';
import type { BridgeWorkerRenderDispositionReceipt } from './bridge-worker-render-fulfillment.js';

type HeldRenderHarness = ReturnType<typeof createHarness> & {
	readonly coordinator: ReturnType<typeof createBridgeMainRenderFulfillmentCoordinator>;
	readonly registry: BridgeWorkerRenderFulfillmentRegistry;
	readonly receipts: readonly BridgeWorkerRenderDispositionReceipt[];
	readonly renderSubmissions: readonly BridgeWorkerReviewPierreRenderJobEvent[];
	readonly publish: (sequence: number) => BridgeWorkerReviewPierreRenderJobEvent;
	readonly advance: (value: number) => void;
};

function createHeldHarness(): HeldRenderHarness {
	let nowMilliseconds = 0;
	const receipts: BridgeWorkerRenderDispositionReceipt[] = [];
	const renderSubmissions: BridgeWorkerReviewPierreRenderJobEvent[] = [];
	const registry = new BridgeWorkerRenderFulfillmentRegistry({
		context: {
			paneSessionId: 'pane-session-1',
			workerInstanceId: 'worker-instance-1',
			surface: 'review',
		},
		now: (): number => nowMilliseconds,
		receiptLeaseDurationMilliseconds: 100,
		retryBackoffMilliseconds: 5,
	});
	const coordinator = createBridgeMainRenderFulfillmentCoordinator({
		nowMilliseconds: (): number => nowMilliseconds,
		cancelAnimationFrame: (): void => {},
		requestAnimationFrame: (): number => {
			throw new Error('Held work must not schedule paint.');
		},
		sendDisposition: (receipt): void => {
			receipts.push(receipt);
			registry.applyDisposition(receipt);
		},
	});
	const harness = createHarness({ renderFulfillmentCoordinator: coordinator });
	const publish = (sequence: number): BridgeWorkerReviewPierreRenderJobEvent => {
		const event = reviewPierrePublication(CANDIDATE, 'item-b', sequence);
		const state = registry.beginPublication({
			job: event.job,
			publicationSequence: sequence,
			workerDerivationEpoch: CANDIDATE.reviewGeneration,
		});
		const publication = { ...event, renderReceiptIdentity: state.receiptIdentity };
		if (state.shouldPublish) {
			renderSubmissions.push(publication);
			harness.receive(publication);
		}
		return publication;
	};
	return {
		...harness,
		coordinator,
		publish,
		receipts,
		renderSubmissions,
		registry,
		advance: (value: number): void => {
			nowMilliseconds = value;
		},
	};
}

async function holdCandidate(harness: ReturnType<typeof createHeldHarness>): Promise<void> {
	await installPublication(harness, ACTIVE, 'item-a');
	harness.integration.setSemanticAttention({
		activeEditorStableFileIdentities: ['file-b'],
		stableFileIdentities: ['file-b'],
	});
	harness.startCandidate(CANDIDATE, 'promoted', ['file-b']);
	harness.receive(reviewDisplayEvent(CANDIDATE, 'item-b'));
	harness.publish(10);
	expect(harness.receipts).toEqual([]);
	expect(harness.registry.nextLifecycleWakeAtMilliseconds()).toBe(100);
	harness.receive(candidateReady(CANDIDATE, 'promoted', ['file-b']));
	await harness.integration.whenSettled();
	expect(harness.store.getReviewRefreshPresentation().candidate?.role).toBe('updateReady');
	expect(harness.receipts.map((receipt) => receipt.disposition)).toEqual(['held']);
}

describe('Main Review held render ownership', () => {
	test.each(['attentionRelease', 'applyNow'] as const)(
		'a deliberate hold is dormant until %s resumes the exact attempt once',
		async (exit) => {
			const harness = createHeldHarness();
			try {
				await holdCandidate(harness);
				const heldIdentity = harness.receipts[0];
				const submissionCountAtHold = harness.renderSubmissions.length;
				harness.registry.updateVisibleItemIds(['item-b']);
				for (const now of [100, 1_000, 10_000]) {
					harness.advance(now);
					expect(harness.registry.expireReceiptLeases()).toEqual([]);
					expect(harness.registry.expireVisibleQueuedLeases()).toEqual({
						exhaustedItemIds: [],
						retryableItemIds: [],
					});
					expect(harness.registry.releaseReadyRetries()).toEqual([]);
					expect(harness.registry.nextLifecycleWakeAtMilliseconds()).toBeNull();
					harness.publish(10);
					expect(harness.receipts).toHaveLength(1);
					expect(harness.renderSubmissions.slice(submissionCountAtHold)).toEqual([]);
				}
				expect(harness.courierJobs).toEqual([]);
				let applied: Promise<void> | undefined;
				if (exit === 'applyNow') applied = harness.integration.applyNow();
				else
					harness.integration.setSemanticAttention({
						activeEditorStableFileIdentities: [],
						stableFileIdentities: [],
					});
				const admission = await harness.nextCommand('reviewPublicationInstallAdmit');
				harness.admit(admission, CANDIDATE, 'admitted');
				const installed = await harness.nextCommand('reviewPublicationInstalled');
				harness.ack(installed);
				await applied;
				await harness.integration.whenSettled();
				expect(harness.courierJobs).toHaveLength(1);
				expect(harness.receipts.map((receipt) => receipt.disposition)).toEqual(['held', 'queued']);
				expect(harness.receipts[1]?.attemptId).toBe(heldIdentity?.attemptId);
			} finally {
				harness.dispose();
				harness.coordinator.dispose();
			}
		},
	);

	test.each(['failure', 'replacement', 'discard', 'close', 'workerReplacement'] as const)(
		'%s retires every held attempt',
		async (exit) => {
			const harness = createHeldHarness();
			try {
				await holdCandidate(harness);
				if (exit === 'failure') harness.receive(candidateFailed(CANDIDATE, true));
				else if (exit === 'replacement') harness.startCandidate(SUCCESSOR, 'promoted', ['file-c']);
				else if (exit === 'discard') harness.store.discardReviewCandidate();
				else if (exit === 'workerReplacement') harness.store.prepareForWorkerReplacement();
				else harness.integration.dispose();
				await harness.integration.whenSettled();
				expect(harness.receipts.map((receipt) => receipt.disposition)).toEqual([
					'held',
					'rejected',
				]);
				expect(harness.registry.getItemState('item-b')?.stage).not.toBe('held');
				expect(harness.courierJobs).toEqual([]);
			} finally {
				harness.dispose();
				harness.coordinator.dispose();
			}
		},
	);

	test('same-item same-publication duplicate is inert and an overwrite retires the displaced held attempt', async () => {
		const harness = createHeldHarness();
		try {
			await holdCandidate(harness);
			const held = harness.publish(10);
			expect(harness.receipts.map((receipt) => receipt.disposition)).toEqual(['held']);
			harness.receive(held);
			expect(harness.receipts.map((receipt) => receipt.disposition)).toEqual(['held']);
			harness.registry.resetPublications();
			harness.publish(12);
			expect(harness.receipts.map((receipt) => receipt.disposition)).toEqual([
				'held',
				'rejected',
				'held',
			]);
			expect(harness.registry.nextLifecycleWakeAtMilliseconds()).toBeNull();
		} finally {
			harness.dispose();
			harness.coordinator.dispose();
		}
	});
});
