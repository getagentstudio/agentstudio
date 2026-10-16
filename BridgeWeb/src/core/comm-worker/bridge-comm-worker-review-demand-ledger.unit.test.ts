import { describe, expect, test } from 'vitest';

import type { BridgeCommWorkerDemandMember } from './bridge-comm-worker-reconciler.js';
import { createBridgeCommWorkerReviewDemandLedger } from './bridge-comm-worker-review-demand-ledger.js';
import {
	bridgeWorkerRenderDispositionReceiptSchema,
	type BridgeWorkerRenderReceiptIdentity,
} from './bridge-worker-render-fulfillment.js';

describe('Bridge comm worker Review published-position ownership', () => {
	test('reports zero outstanding publications when a published preparation rejects', () => {
		// Arrange: a publication exists when its preparation completion rejects.
		const observedCounts: number[] = [];
		const ledger = createBridgeCommWorkerReviewDemandLedger({
			observeOutstandingPublications: (observation): void => {
				observedCounts.push(observation.currentCount);
			},
			start: () => ({ cancel: () => {}, updateRole: () => {} }),
		});
		const admission = ledger.reconcile([{ itemId: 'rejected-publication', role: 'visible' }])
			.active[0];
		if (admission === undefined) throw new Error('Expected a Review admission.');
		ledger.markPublished(
			admission.itemId,
			admission.attemptToken,
			renderReceiptIdentity(admission.itemId, admission.attemptToken),
		);
		ledger.setSuspended(true);

		// Act: the existing rejection path removes this exact owned position.
		expect(ledger.releaseRejected(admission.itemId, admission.attemptToken)).toBe(true);

		// Assert: operational evidence must agree with actual ledger ownership.
		expect(ledger.reconcile([]).active).toEqual([]);
		expect(observedCounts).toEqual([1, 0]);
	});

	test('keeps Review publication ownership fail-open when its observer throws', () => {
		const ledger = createBridgeCommWorkerReviewDemandLedger({
			observeOutstandingPublications: (): never => {
				throw new Error('observer unavailable');
			},
			start: () => ({ cancel: () => {}, updateRole: () => {} }),
		});
		const admission = ledger.reconcile([{ itemId: 'fail-open-review', role: 'visible' }]).active[0];
		if (admission === undefined) throw new Error('Expected Review admission.');
		const identity = renderReceiptIdentity(admission.itemId, admission.attemptToken);

		expect(ledger.markPublished(admission.itemId, admission.attemptToken, identity)).toBe(true);
		expect(ledger.release(admission.itemId, admission.attemptToken, 'resident')).toBe(true);
		expect(
			ledger.releasePublished(
				bridgeWorkerRenderDispositionReceiptSchema.parse({
					...identity,
					disposition: 'queued',
					kind: 'render.disposition',
					receivedAtMilliseconds: 1,
				}),
			),
		).toBe(true);
		expect(ledger.reconcile([]).active).toEqual([]);
	});

	test('observes bounded held-publication count, age, high-water mark, and response phase', () => {
		let nowMilliseconds = 10;
		const observations: Array<{
			readonly currentCount: number;
			readonly highWaterMark: number;
			readonly oldestAgeMilliseconds: number;
			readonly outcome: string;
			readonly phase: string;
		}> = [];
		const ledger = createBridgeCommWorkerReviewDemandLedger({
			now: (): number => nowMilliseconds,
			observeOutstandingPublications: (observation): void => {
				observations.push(observation);
			},
			start: () => ({ cancel: () => {}, updateRole: () => {} }),
		});
		const active = ledger.reconcile([
			{ itemId: 'observed-1', role: 'visible' },
			{ itemId: 'observed-2', role: 'visible' },
		]).active;
		const first = active[0];
		const second = active[1];
		if (first === undefined || second === undefined)
			throw new Error('Expected two Review positions.');
		ledger.markPublished(
			first.itemId,
			first.attemptToken,
			renderReceiptIdentity(first.itemId, first.attemptToken),
		);
		nowMilliseconds = 20;
		ledger.markPublished(
			second.itemId,
			second.attemptToken,
			renderReceiptIdentity(second.itemId, second.attemptToken),
		);
		nowMilliseconds = 30;
		ledger.releasePublished(
			bridgeWorkerRenderDispositionReceiptSchema.parse({
				...renderReceiptIdentity(first.itemId, first.attemptToken),
				disposition: 'queued',
				kind: 'render.disposition',
				receivedAtMilliseconds: 30,
			}),
		);

		expect(observations).toEqual([
			{
				currentCount: 1,
				highWaterMark: 1,
				oldestAgeMilliseconds: 0,
				outcome: 'published',
				phase: 'render_publication_outstanding_changed',
			},
			{
				currentCount: 2,
				highWaterMark: 2,
				oldestAgeMilliseconds: 10,
				outcome: 'published',
				phase: 'render_publication_outstanding_changed',
			},
			{
				currentCount: 2,
				highWaterMark: 2,
				oldestAgeMilliseconds: 20,
				outcome: 'queued',
				phase: 'render_disposition_response_posted_before_owner_effect',
			},
			{
				currentCount: 1,
				highWaterMark: 2,
				oldestAgeMilliseconds: 10,
				outcome: 'released',
				phase: 'render_publication_outstanding_changed',
			},
		]);
	});

	test('holds all twelve published positions until the first exact queued response effect', () => {
		const startedItemIds: string[] = [];
		const ledger = createTestLedger(startedItemIds);
		const membership = reviewMembership(13);
		const initial = ledger.reconcile(membership);

		for (const admission of initial.active) {
			const identity = renderReceiptIdentity(admission.itemId, admission.attemptToken);
			expect(ledger.markPublished(admission.itemId, admission.attemptToken, identity)).toBe(true);
			expect(ledger.release(admission.itemId, admission.attemptToken, 'resident')).toBe(true);
		}

		expect(startedItemIds).toHaveLength(12);
		expect(initial.wanted.map(({ itemId }) => itemId)).toEqual(['background-10']);
		const releasedAdmission = initial.active[3];
		if (releasedAdmission === undefined) throw new Error('Expected a dynamic Review admission.');
		const exactQueuedReceipt = bridgeWorkerRenderDispositionReceiptSchema.parse({
			...renderReceiptIdentity(releasedAdmission.itemId, releasedAdmission.attemptToken),
			disposition: 'queued',
			kind: 'render.disposition',
			receivedAtMilliseconds: 1,
		});

		expect(ledger.releasePublished(exactQueuedReceipt)).toBe(true);
		expect(startedItemIds).toHaveLength(13);
		expect(startedItemIds.at(-1)).toBe('background-10');
		expect(ledger.releasePublished(exactQueuedReceipt)).toBe(false);
	});

	test('publishes the final current active snapshot after an internal refill', () => {
		// Arrange
		const activeSnapshots: string[][] = [];
		const ledger = createBridgeCommWorkerReviewDemandLedger({
			onCurrentActiveDemandChanged: (activeDemand): void => {
				activeSnapshots.push(activeDemand.map(({ itemId }) => itemId));
			},
			start: () => ({ cancel: () => {}, updateRole: () => {} }),
		});
		const initial = ledger.reconcile(reviewMembership(13));
		const releasedAdmission = initial.active[3];
		if (releasedAdmission === undefined) throw new Error('Expected a dynamic Review admission.');

		// Act
		ledger.release(releasedAdmission.itemId, releasedAdmission.attemptToken, 'resident');

		// Assert
		expect(activeSnapshots.at(-1)).toContain('background-10');
		expect(activeSnapshots.at(-1)).toHaveLength(12);
	});

	test('releases an exact queued publication while 1,699-item Review demand is suspended', () => {
		// Arrange
		const observations: Array<{ readonly currentCount: number; readonly phase: string }> = [];
		const ledger = createBridgeCommWorkerReviewDemandLedger({
			observeOutstandingPublications: (observation): void => {
				observations.push({
					currentCount: observation.currentCount,
					phase: observation.phase,
				});
			},
			start: () => ({
				cancel: () => {},
				pause: () => {},
				resume: () => {},
				updateRole: () => {},
			}),
		});
		const initial = ledger.reconcile(reviewMembership(1_699));
		const publishedAdmission = initial.active[0];
		if (publishedAdmission === undefined) throw new Error('Expected a Review admission.');
		const identity = renderReceiptIdentity(
			publishedAdmission.itemId,
			publishedAdmission.attemptToken,
		);
		ledger.markPublished(publishedAdmission.itemId, publishedAdmission.attemptToken, identity);
		ledger.release(publishedAdmission.itemId, publishedAdmission.attemptToken, 'resident');
		ledger.setSuspended(true);

		// Act
		const released = ledger.releasePublished(
			bridgeWorkerRenderDispositionReceiptSchema.parse({
				...identity,
				disposition: 'queued',
				kind: 'render.disposition',
				receivedAtMilliseconds: 1,
			}),
		);

		// Assert
		expect(released).toBe(true);
		expect(ledger.reconcile(reviewMembership(1_699)).active).toHaveLength(11);
		expect(observations.slice(-2)).toEqual([
			{
				currentCount: 1,
				phase: 'render_disposition_response_posted_before_owner_effect',
			},
			{
				currentCount: 0,
				phase: 'render_publication_outstanding_changed',
			},
		]);
	});

	test('keeps an invalidated publication held and never revives its obsolete intent', () => {
		const startedItemIds: string[] = [];
		const ledger = createTestLedger(startedItemIds);
		const membership = reviewMembership(13);
		const initial = ledger.reconcile(membership);
		const publishedAdmission = initial.active[3];
		if (publishedAdmission === undefined) throw new Error('Expected a published Review admission.');
		const identity = renderReceiptIdentity(
			publishedAdmission.itemId,
			publishedAdmission.attemptToken,
		);
		ledger.markPublished(publishedAdmission.itemId, publishedAdmission.attemptToken, identity);
		ledger.release(publishedAdmission.itemId, publishedAdmission.attemptToken, 'resident');

		ledger.invalidate(publishedAdmission.itemId);
		const whileHeld = ledger.reconcile(
			membership.filter(({ itemId }) => itemId !== publishedAdmission.itemId),
		);

		expect(publishedAdmission.signal.aborted).toBe(false);
		expect(whileHeld.active.map(({ itemId }) => itemId)).toContain(publishedAdmission.itemId);
		expect(startedItemIds).toHaveLength(12);
		const terminalReceipt = bridgeWorkerRenderDispositionReceiptSchema.parse({
			...identity,
			disposition: 'superseded',
			kind: 'render.disposition',
			reason: 'stale_attempt',
			receivedAtMilliseconds: 1,
			retryAtMilliseconds: 1,
		});
		expect(ledger.releasePublished(terminalReceipt)).toBe(true);
		expect(startedItemIds.at(-1)).toBe('background-10');
		expect(startedItemIds.filter((itemId) => itemId === publishedAdmission.itemId)).toHaveLength(1);
	});

	test('ignores foreign identities and non-releasing lifecycle receipts', () => {
		const startedItemIds: string[] = [];
		const ledger = createTestLedger(startedItemIds);
		const initial = ledger.reconcile(reviewMembership(13));
		const publishedAdmission = initial.active[3];
		if (publishedAdmission === undefined) throw new Error('Expected a published Review admission.');
		const identity = renderReceiptIdentity(
			publishedAdmission.itemId,
			publishedAdmission.attemptToken,
		);
		ledger.markPublished(publishedAdmission.itemId, publishedAdmission.attemptToken, identity);
		ledger.release(publishedAdmission.itemId, publishedAdmission.attemptToken, 'resident');

		for (const receipt of [
			bridgeWorkerRenderDispositionReceiptSchema.parse({
				...identity,
				attemptId: 'foreign-attempt',
				disposition: 'queued',
				kind: 'render.disposition',
				receivedAtMilliseconds: 1,
			}),
			bridgeWorkerRenderDispositionReceiptSchema.parse({
				...identity,
				disposition: 'applied',
				kind: 'render.disposition',
				receivedAtMilliseconds: 1,
			}),
			bridgeWorkerRenderDispositionReceiptSchema.parse({
				...identity,
				disposition: 'painted',
				kind: 'render.disposition',
				receivedAtMilliseconds: 1,
			}),
		]) {
			expect(ledger.releasePublished(receipt)).toBe(false);
		}
		expect(startedItemIds).toHaveLength(12);
	});

	test('keeps twelve old-generation publications occupying their positions during churn', () => {
		const startedItemIds: string[] = [];
		const ledger = createTestLedger(startedItemIds);
		ledger.updateGeneration(1);
		const oldGeneration = ledger.reconcile(reviewMembership(12));
		for (const admission of oldGeneration.active) {
			ledger.markPublished(
				admission.itemId,
				admission.attemptToken,
				renderReceiptIdentity(admission.itemId, admission.attemptToken),
			);
			ledger.release(admission.itemId, admission.attemptToken, 'resident');
		}
		const oldReleasedAdmission = oldGeneration.active[3];
		if (oldReleasedAdmission === undefined) {
			throw new Error('Expected an old-generation published Review admission.');
		}

		ledger.updateGeneration(2);
		const newGenerationMembership = reviewMembership(13).map(
			(member): BridgeCommWorkerDemandMember => ({
				...member,
				itemId: `new-${member.itemId}`,
			}),
		);
		const held = ledger.reconcile(newGenerationMembership);

		expect(startedItemIds).toHaveLength(12);
		expect(held.active).toHaveLength(12);
		expect(held.wanted).toHaveLength(13);
		const exactOldQueuedReceipt = bridgeWorkerRenderDispositionReceiptSchema.parse({
			...renderReceiptIdentity(oldReleasedAdmission.itemId, oldReleasedAdmission.attemptToken),
			disposition: 'queued',
			kind: 'render.disposition',
			receivedAtMilliseconds: 1,
		});
		expect(ledger.releasePublished(exactOldQueuedReceipt)).toBe(true);
		expect(startedItemIds).toHaveLength(13);
		expect(startedItemIds.at(-1)).toBe('new-visible-1');
		expect(startedItemIds.filter((itemId) => itemId === oldReleasedAdmission.itemId)).toHaveLength(
			1,
		);
	});

	test('excludes retained old-generation publications from current active demand', () => {
		// Arrange
		const activeSnapshots: string[][] = [];
		const ledger = createBridgeCommWorkerReviewDemandLedger({
			onCurrentActiveDemandChanged: (activeDemand): void => {
				activeSnapshots.push(activeDemand.map(({ itemId }) => itemId));
			},
			start: () => ({ cancel: () => {}, updateRole: () => {} }),
		});
		ledger.updateGeneration(1);
		const firstGeneration = ledger.reconcile(reviewMembership(12));
		for (const admission of firstGeneration.active) {
			ledger.markPublished(
				admission.itemId,
				admission.attemptToken,
				renderReceiptIdentity(admission.itemId, admission.attemptToken),
			);
			ledger.release(admission.itemId, admission.attemptToken, 'resident');
		}

		// Act
		ledger.updateGeneration(2);

		// Assert: retiring generation 1 immediately withdraws its interest projection.
		expect(activeSnapshots.at(-1)).toEqual([]);

		// Act: generation 2 may reconcile only from its own fresh membership.
		ledger.reconcile(
			reviewMembership(13).map((member) => ({ ...member, itemId: `new-${member.itemId}` })),
		);

		// Assert
		expect(firstGeneration.active).toHaveLength(12);
		expect(activeSnapshots.at(-1)).toEqual([]);
	});

	test('starts same-item successor demand after the old generation receives queued', () => {
		// Arrange
		const startedItemIds: string[] = [];
		const ledger = createTestLedger(startedItemIds);
		const membership = [{ itemId: 'same-item', role: 'visible' }] as const;
		ledger.updateGeneration(1);
		const firstGeneration = ledger.reconcile(membership);
		const firstAdmission = firstGeneration.active[0];
		if (firstAdmission === undefined) throw new Error('Expected first-generation admission.');
		const firstIdentity = renderReceiptIdentity(firstAdmission.itemId, firstAdmission.attemptToken);
		ledger.markPublished(firstAdmission.itemId, firstAdmission.attemptToken, firstIdentity);
		ledger.release(firstAdmission.itemId, firstAdmission.attemptToken, 'resident');

		// Act
		ledger.updateGeneration(2);
		ledger.reconcile(membership);
		const released = ledger.releasePublished(
			bridgeWorkerRenderDispositionReceiptSchema.parse({
				...firstIdentity,
				disposition: 'queued',
				kind: 'render.disposition',
				receivedAtMilliseconds: 1,
			}),
		);

		// Assert
		expect(released).toBe(true);
		expect(startedItemIds).toEqual(['same-item', 'same-item']);
		expect(ledger.reconcile(membership).active[0]?.attemptToken).not.toBe(
			firstAdmission.attemptToken,
		);
	});

	test('releases a held same-item publication at its owned render lease expiry', () => {
		const startedItemIds: string[] = [];
		const ledger = createTestLedger(startedItemIds);
		const membership = [{ itemId: 'same-item', role: 'selected', selectedDemandEpoch: 7 }] as const;
		const first = ledger.reconcile(membership).active[0];
		if (first === undefined) throw new Error('Expected the first selected Review admission.');
		const identity = renderReceiptIdentity(first.itemId, first.attemptToken);
		expect(ledger.markPublished(first.itemId, first.attemptToken, identity)).toBe(true);
		expect(ledger.release(first.itemId, first.attemptToken, 'resident')).toBe(true);
		ledger.invalidate(first.itemId);
		ledger.reconcile(membership);
		expect(startedItemIds).toEqual(['same-item']);

		// The existing registry lease expired without any first main-thread disposition.
		expect(ledger.releaseExpiredPublication(first.itemId)).toBe(true);
		expect(ledger.releaseExpiredPublication(first.itemId)).toBe(false);
		const successor = ledger.reconcile(membership).active[0];
		expect(startedItemIds).toEqual(['same-item', 'same-item']);
		expect(successor?.attemptToken).not.toBe(first.attemptToken);
		expect(
			ledger.releasePublished(
				bridgeWorkerRenderDispositionReceiptSchema.parse({
					...identity,
					disposition: 'queued',
					kind: 'render.disposition',
					receivedAtMilliseconds: 106,
				}),
			),
		).toBe(false);
	});
});

function createTestLedger(
	startedItemIds: string[],
): ReturnType<typeof createBridgeCommWorkerReviewDemandLedger> {
	return createBridgeCommWorkerReviewDemandLedger({
		start: (admission) => {
			startedItemIds.push(admission.itemId);
			return { cancel: () => {}, updateRole: () => {} };
		},
	});
}

function reviewMembership(count: number): readonly BridgeCommWorkerDemandMember[] {
	return [
		{ itemId: 'visible-1', role: 'visible' },
		{ itemId: 'visible-2', role: 'visible' },
		{ itemId: 'visible-3', role: 'visible' },
		...Array.from(
			{ length: count - 3 },
			(_, index): BridgeCommWorkerDemandMember => ({
				itemId: `background-${index + 1}`,
				role: 'background',
			}),
		),
	];
}

function renderReceiptIdentity(
	itemId: string,
	attemptToken: number,
): BridgeWorkerRenderReceiptIdentity {
	return {
		attemptId: `attempt-${attemptToken}`,
		itemId,
		operationCorrelationId: null,
		paneSessionId: 'pane-session',
		publicationId: `publication-${attemptToken}`,
		publicationSequence: attemptToken,
		submissionId: `submission-${attemptToken}`,
		surface: 'review' as const,
		windowKey: `window-${attemptToken}`,
		workerDerivationEpoch: 1,
		workerInstanceId: 'worker-instance',
	};
}
