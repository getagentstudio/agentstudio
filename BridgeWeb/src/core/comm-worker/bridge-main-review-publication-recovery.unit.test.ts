import { describe, expect, test, vi } from 'vitest';

import {
	ACTIVE,
	CANDIDATE,
	SUCCESSOR,
	candidateReady,
	createHarness,
	installPublication,
	mainIdentity,
	reviewDisplayEvent,
} from './bridge-main-review-publication-integration.test-support.js';

describe('Bridge Review installed receipt recovery', () => {
	test.each([1, 7])(
		're-establishes retained publication after replacing worker epoch %i',
		async (previousWorkerEpoch) => {
			// Arrange — Main displayed A, but neither installed receipt reached native.
			const harness = createHarness();
			try {
				harness.receive({ ...reviewDisplayEvent(ACTIVE, 'item-a'), epoch: previousWorkerEpoch });
				harness.receive({ ...candidateReady(ACTIVE, 'ordinary', []), epoch: previousWorkerEpoch });
				const admission = await harness.nextCommand('reviewPublicationInstallAdmit');
				harness.admit(admission, ACTIVE, 'admitted');
				const installed = await harness.nextCommand('reviewPublicationInstalled');
				harness.fail(installed);
				await harness.waitForPendingCommand('reviewPublicationInstalled');
				expect(harness.pendingCommandCount('reviewPublicationInstalled')).toBe(1);
				harness.fail(await harness.nextCommand('reviewPublicationInstalled'));
				await harness.integration.whenSettled();
				expect(harness.requestWorkerReplacement).toHaveBeenCalledOnce();

				// Act — the replacement worker replays exactly A, not a newer source revision.
				harness.store.prepareForWorkerReplacement();
				expect(harness.store.getReviewRefreshPresentation().activeIdentity).toEqual(
					mainIdentity(ACTIVE),
				);
				harness.receive(reviewDisplayEvent(ACTIVE, 'item-a'));
				harness.receive(candidateReady(ACTIVE, 'ordinary', []));

				// Assert — retained paint is not evidence of installation by the new worker.
				await harness.waitForPendingCommand('reviewPublicationInstallAdmit');
				expect(harness.pendingCommandCount('reviewPublicationInstallAdmit')).toBe(1);
				const replayAdmission = await harness.nextCommand('reviewPublicationInstallAdmit');
				expect(replayAdmission).toMatchObject({
					candidatePublicationId: ACTIVE.publicationId,
					expectedDisplayedPublicationId: null,
				});
				harness.admit(replayAdmission, ACTIVE, 'admitted');
				const replayInstalled = await harness.nextCommand('reviewPublicationInstalled');
				expect(replayInstalled).toMatchObject({ publicationId: ACTIVE.publicationId });
				harness.ack(replayInstalled);
				await harness.integration.whenSettled();
				expect(harness.store.getReviewRefreshPresentation().activeIdentity).toEqual(
					mainIdentity(ACTIVE),
				);
				harness.receive(candidateReady(ACTIVE, 'ordinary', []));
				await harness.integration.whenSettled();
				expect(
					harness.commandKinds.filter((kind) => kind === 'reviewPublicationInstallAdmit'),
				).toHaveLength(2);
				await installPublication(harness, CANDIDATE, 'item-b');
				expect(harness.store.getReviewRefreshPresentation().activeIdentity).toEqual(
					mainIdentity(CANDIDATE),
				);
			} finally {
				harness.dispose();
			}
		},
	);

	test('admits a newer first replacement publication without claiming a confirmed predecessor', async () => {
		// Arrange — retained A is still visible while a replacement worker starts.
		const harness = createHarness();
		try {
			await installPublication(harness, ACTIVE, 'item-a');
			harness.store.prepareForWorkerReplacement();

			// Act — the source already advanced to B before the replacement's first delivery.
			harness.receive(reviewDisplayEvent(CANDIDATE, 'item-b'));
			harness.receive(candidateReady(CANDIDATE, 'ordinary', []));
			const admission = await harness.nextCommand('reviewPublicationInstallAdmit');

			// Assert — establish fresh-worker delivery, then resume exact predecessor fencing.
			expect(admission).toMatchObject({
				candidatePublicationId: CANDIDATE.publicationId,
				expectedDisplayedPublicationId: null,
			});
			harness.admit(admission, CANDIDATE, 'admitted');
			harness.ack(await harness.nextCommand('reviewPublicationInstalled'));
			await harness.integration.whenSettled();
			harness.receive(reviewDisplayEvent(SUCCESSOR, 'item-c'));
			harness.receive(candidateReady(SUCCESSOR, 'ordinary', []));
			const successorAdmission = await harness.nextCommand('reviewPublicationInstallAdmit');
			expect(successorAdmission).toMatchObject({
				expectedDisplayedPublicationId: CANDIDATE.publicationId,
			});
			harness.admit(successorAdmission, SUCCESSOR, 'admitted');
			harness.ack(await harness.nextCommand('reviewPublicationInstalled'));
			await harness.integration.whenSettled();
			expect(harness.store.getReviewRefreshPresentation().activeIdentity).toEqual(
				mainIdentity(SUCCESSOR),
			);
		} finally {
			harness.dispose();
		}
	});

	test('retries the exact installed publication without repeating promotion or admission', async () => {
		// Arrange
		const harness = createHarness();
		try {
			await installPublication(harness, ACTIVE, 'item-a');
			harness.receive(reviewDisplayEvent(CANDIDATE, 'item-b'));
			harness.receive(candidateReady(CANDIDATE, 'ordinary', []));
			const admission = await harness.nextCommand('reviewPublicationInstallAdmit');
			harness.admit(admission, CANDIDATE, 'admitted');
			const installed = await harness.nextCommand('reviewPublicationInstalled');

			// Act
			harness.fail(installed);
			await harness.waitForPendingCommand('reviewPublicationInstalled');
			expect(harness.pendingCommandCount('reviewPublicationInstalled')).toBe(1);
			const retry = await harness.nextCommand('reviewPublicationInstalled');
			expect(retry).toMatchObject({ publicationId: CANDIDATE.publicationId });
			expect(retry.requestId).not.toBe(installed.requestId);
			harness.ack(retry);
			await harness.integration.whenSettled();

			// Assert
			expect(harness.store.getReviewRefreshPresentation().activeIdentity).toEqual(
				mainIdentity(CANDIDATE),
			);
			expect(
				harness.commandKinds.filter((kind) => kind === 'reviewPublicationInstallAdmit'),
			).toHaveLength(2);
			expect(harness.requestWorkerReplacement).not.toHaveBeenCalled();
		} finally {
			harness.dispose();
		}
	});

	test('delegates persistent receipt failure to the existing worker lifecycle', async () => {
		// Arrange
		const harness = createHarness();
		try {
			await installPublication(harness, ACTIVE, 'item-a');
			harness.receive(reviewDisplayEvent(CANDIDATE, 'item-b'));
			harness.receive(candidateReady(CANDIDATE, 'ordinary', []));
			const admission = await harness.nextCommand('reviewPublicationInstallAdmit');
			harness.admit(admission, CANDIDATE, 'admitted');
			const installed = await harness.nextCommand('reviewPublicationInstalled');

			// Act
			harness.fail(installed);
			await harness.waitForPendingCommand('reviewPublicationInstalled');
			expect(harness.pendingCommandCount('reviewPublicationInstalled')).toBe(1);
			const retry = await harness.nextCommand('reviewPublicationInstalled');
			harness.fail(retry);
			await harness.integration.whenSettled();

			// Assert
			expect(harness.requestWorkerReplacement).toHaveBeenCalledOnce();
			expect(harness.pendingCommandCount('reviewPublicationInstalled')).toBe(0);
			expect(harness.store.getReviewRefreshPresentation().activeIdentity).toEqual(
				mainIdentity(CANDIDATE),
			);
		} finally {
			harness.dispose();
		}
	});

	test('does not request successor admission until the installed predecessor receipt settles', async () => {
		// Arrange
		const harness = createHarness();
		try {
			await installPublication(harness, ACTIVE, 'item-a');
			harness.receive(reviewDisplayEvent(CANDIDATE, 'item-b'));
			harness.receive(candidateReady(CANDIDATE, 'ordinary', []));
			const admission = await harness.nextCommand('reviewPublicationInstallAdmit');
			harness.admit(admission, CANDIDATE, 'admitted');
			const installed = await harness.nextCommand('reviewPublicationInstalled');

			// Act / Assert — C may be ready, but native has not yet confirmed displayed B.
			const noSuccessorAdmission = harness.expectNoCommandUntilAck(
				'reviewPublicationInstallAdmit',
				installed.requestId,
			);
			void noSuccessorAdmission.catch((): void => {});
			harness.receive(reviewDisplayEvent(SUCCESSOR, 'item-c'));
			harness.receive(candidateReady(SUCCESSOR, 'ordinary', []));
			expect(harness.pendingCommandCount('reviewPublicationInstallAdmit')).toBe(0);
			harness.ack(installed);
			await noSuccessorAdmission;
			await harness.waitForPendingCommand('reviewPublicationInstallAdmit');
			expect(harness.pendingCommandCount('reviewPublicationInstallAdmit')).toBe(1);
			const successorAdmission = await harness.nextCommand('reviewPublicationInstallAdmit');
			expect(successorAdmission).toMatchObject({
				expectedDisplayedPublicationId: CANDIDATE.publicationId,
			});
			harness.admit(successorAdmission, SUCCESSOR, 'admitted');
			const successorInstalled = await harness.nextCommand('reviewPublicationInstalled');
			harness.ack(successorInstalled);
			await harness.integration.whenSettled();
			expect(harness.store.getReviewRefreshPresentation().activeIdentity).toEqual(
				mainIdentity(SUCCESSOR),
			);
		} finally {
			harness.dispose();
		}
	});
});

test('rejects a withheld publication dispatch fact even when the count claims a queued command', async () => {
	const harness = createHarness();
	try {
		vi.spyOn(harness, 'pendingCommandCount').mockReturnValue(1);
		const pending = harness.waitForPendingCommand('reviewPublicationInstalled');
		harness.dispose();
		await expect(pending).rejects.toThrow(
			'Awaiting Review publication queued reviewPublicationInstalled: Review publication harness disposed',
		);
	} finally {
		harness.dispose();
	}
});
