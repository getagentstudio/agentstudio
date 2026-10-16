import { describe, expect, test } from 'vitest';

import {
	bindPublicationItemAsFinal,
	type BridgeMainRenderedItemReadback,
	type BridgeMainRenderPublicationItem,
	cloneReviewPublicationForRetry,
	cloneReviewPublicationItem,
	connectedReadback,
	createControlledAnimationFrames,
	createCoordinator,
	createCoordinatorHarness,
	expectedDisposition,
	makeFilePublication,
	makeReviewPublication,
	testRenderedElement,
} from './bridge-main-render-fulfillment-coordinator.test-support.js';
import type { BridgeWorkerRenderDispositionReceipt } from './bridge-worker-render-fulfillment.js';

describe('Bridge main render fulfillment coordinator', () => {
	test('defers the queued transition until the submitted publication is bound to its final presentation item', () => {
		// Arrange
		const harness = createCoordinatorHarness(10);
		const publication = makeReviewPublication({ itemId: 'review-item-1', publicationSequence: 1 });
		const publicationItem = publication.job.payload.item;
		const finalItem = {
			...publicationItem,
			version: (publicationItem.version ?? 0) + 1,
		};

		// Act
		harness.coordinator.acceptPublication(publication);
		harness.coordinator.acceptPublication(publication);

		// Assert
		expect(harness.dispositions).toEqual([]);

		// Act
		harness.coordinator.markPublicationQueued(publication);
		harness.coordinator.markPublicationQueued(publication);

		// Assert
		expect(harness.dispositions).toEqual([]);

		// Act
		harness.coordinator.bindPublicationItem({
			finalItem,
			publicationItem,
			residency: 'replaced',
		});

		// Assert
		expect(harness.dispositions).toEqual([expectedDisposition(publication, 'queued', 10)]);
		expect(harness.coordinator.isBoundFinalItem(finalItem)).toBe(true);
		expect(harness.animationFrames.activeFrameHandles()).toEqual([]);
	});

	test('applies one matching non-unmount post-render and paints only after matching connected frame-time readback', () => {
		// Arrange
		const harness = createCoordinatorHarness(100);
		const operationCorrelationId = 'a'.repeat(64);
		const publication = makeReviewPublication({
			itemId: 'review-item-2',
			operationCorrelationId,
			publicationSequence: 2,
		});
		const publicationItem = publication.job.payload.item;
		const currentItem: BridgeMainRenderPublicationItem | undefined = publicationItem;
		const renderedItem: BridgeMainRenderedItemReadback | null = {
			element: testRenderedElement(true),
			item: publicationItem,
			readableContentMatchesItem: true,
		};
		const readback = {
			readCurrentItem: (): BridgeMainRenderPublicationItem | undefined => currentItem,
			readRenderedItem: (): BridgeMainRenderedItemReadback | null => renderedItem,
		};
		harness.coordinator.acceptPublication(publication);
		bindPublicationItemAsFinal(harness.coordinator, publication);
		harness.coordinator.markPublicationQueued(publication);

		// Act
		harness.setNowMilliseconds(110);
		harness.coordinator.observePostRender({
			...readback,
			contextItem: publicationItem,
			itemId: publication.job.itemId,
			phase: 'mount',
		});
		harness.coordinator.observePostRender({
			...readback,
			contextItem: publicationItem,
			itemId: publication.job.itemId,
			phase: 'update',
		});
		harness.coordinator.reconcilePublication({
			...readback,
			itemId: publication.job.itemId,
		});

		// Assert
		expect(harness.dispositions).toEqual([
			expectedDisposition(publication, 'queued', 100),
			expectedDisposition(publication, 'applied', 110),
		]);
		expect(
			harness.dispositions.every(
				(disposition) => disposition.operationCorrelationId === operationCorrelationId,
			),
		).toBe(true);
		expect(harness.animationFrames.activeFrameHandles()).toEqual([1]);

		// Act
		harness.setNowMilliseconds(120);
		harness.animationFrames.runActiveFrame(1);

		// Assert
		expect(currentItem).toBe(publicationItem);
		expect(renderedItem?.item).toBe(publicationItem);
		expect(harness.dispositions).toEqual([
			expectedDisposition(publication, 'queued', 100),
			expectedDisposition(publication, 'applied', 110),
			expectedDisposition(publication, 'painted', 120),
		]);
		expect(harness.dispositions.at(-1)?.operationCorrelationId).toBe(operationCorrelationId);
		expect(harness.animationFrames.activeFrameHandles()).toEqual([]);
		expect(harness.coordinator.releasePaintedCopy(publication.job.itemId)).toBe(true);
		expect(harness.paintReleases).toEqual([
			{
				...publication.renderReceiptIdentity,
				kind: 'paint.released',
				receivedAtMilliseconds: 120,
			},
		]);
		expect(harness.coordinator.releasePaintedCopy(publication.job.itemId)).toBe(false);
	});

	test('retains exact post-render readback that arrives before queued delivery', () => {
		// Arrange
		const harness = createCoordinatorHarness(90);
		const publication = makeReviewPublication({
			itemId: 'review-post-render-before-queued',
			publicationSequence: 3,
		});
		const publicationItem = publication.job.payload.item;
		const readback = connectedReadback(publicationItem);
		harness.coordinator.acceptPublication(publication);
		bindPublicationItemAsFinal(harness.coordinator, publication);

		// Act: React may synchronously render the installed item before the courier returns queued.
		harness.setNowMilliseconds(100);
		harness.coordinator.observePostRender({
			...readback,
			contextItem: publicationItem,
			itemId: publication.job.itemId,
			phase: 'mount',
		});

		// Assert: applied cannot overtake queued.
		expect(harness.dispositions).toEqual([]);
		expect(harness.animationFrames.activeFrameHandles()).toEqual([]);

		// Act
		harness.setNowMilliseconds(110);
		harness.coordinator.markPublicationQueued(publication);

		// Assert: queued consumes the retained exact readback without requiring another Pierre callback.
		expect(harness.dispositions).toEqual([
			expectedDisposition(publication, 'queued', 110),
			expectedDisposition(publication, 'applied', 110),
		]);
		expect(harness.animationFrames.activeFrameHandles()).toEqual([1]);

		// Act
		harness.setNowMilliseconds(120);
		harness.animationFrames.runActiveFrame(1);

		// Assert
		expect(harness.dispositions).toEqual([
			expectedDisposition(publication, 'queued', 110),
			expectedDisposition(publication, 'applied', 110),
			expectedDisposition(publication, 'painted', 120),
		]);
	});

	test('does not apply a retained pre-queued readback that became stale', () => {
		// Arrange
		const harness = createCoordinatorHarness(130);
		const publication = makeReviewPublication({
			itemId: 'review-stale-post-render-before-queued',
			publicationSequence: 4,
		});
		const publicationItem = publication.job.payload.item;
		let currentItem: BridgeMainRenderPublicationItem | undefined = publicationItem;
		const readback = {
			readCurrentItem: (): BridgeMainRenderPublicationItem | undefined => currentItem,
			readRenderedItem: (): BridgeMainRenderedItemReadback => ({
				element: testRenderedElement(true),
				item: publicationItem,
				readableContentMatchesItem: true,
			}),
		};
		harness.coordinator.acceptPublication(publication);
		bindPublicationItemAsFinal(harness.coordinator, publication);
		harness.coordinator.observePostRender({
			...readback,
			contextItem: publicationItem,
			itemId: publication.job.itemId,
			phase: 'mount',
		});

		// Act: currentness changes before courier submission reports queued.
		currentItem = undefined;
		harness.setNowMilliseconds(140);
		harness.coordinator.markPublicationQueued(publication);

		// Assert
		expect(harness.dispositions).toEqual([expectedDisposition(publication, 'queued', 140)]);
		expect(harness.animationFrames.activeFrameHandles()).toEqual([]);
	});

	test('accepts exact connected readable reconciliation when Pierre commits no DOM update', () => {
		// Arrange
		const harness = createCoordinatorHarness(150);
		const publication = makeReviewPublication({
			itemId: 'review-exact-readable-reconciliation',
			publicationSequence: 5,
		});
		const publicationItem = publication.job.payload.item;
		harness.coordinator.acceptPublication(publication);
		bindPublicationItemAsFinal(harness.coordinator, publication);
		harness.coordinator.markPublicationQueued(publication);

		// Act: Pierre may retain content-correct connected DOM without a DOM-committing render callback.
		harness.setNowMilliseconds(160);
		harness.coordinator.reconcilePublication({
			...connectedReadback(publicationItem),
			itemId: publication.job.itemId,
		});

		// Assert
		expect(harness.dispositions).toEqual([
			expectedDisposition(publication, 'queued', 150),
			expectedDisposition(publication, 'applied', 160),
		]);
		expect(harness.animationFrames.activeFrameHandles()).toEqual([1]);

		// Act
		harness.setNowMilliseconds(170);
		harness.animationFrames.runActiveFrame(1);

		// Assert
		expect(harness.dispositions).toEqual([
			expectedDisposition(publication, 'queued', 150),
			expectedDisposition(publication, 'applied', 160),
			expectedDisposition(publication, 'painted', 170),
		]);
	});

	test('rejects disconnected, replaced-current, and mismatched-rendered frame readbacks as stale attempts', () => {
		for (const [caseIndex, staleReadbackKind] of [
			'disconnected',
			'replaced-current',
			'mismatched-rendered',
		].entries()) {
			// Arrange
			const publicationSequence = caseIndex + 10;
			const queuedAtMilliseconds = 200 + caseIndex * 100;
			const appliedAtMilliseconds = queuedAtMilliseconds + 10;
			const rejectedAtMilliseconds = queuedAtMilliseconds + 20;
			const harness = createCoordinatorHarness(queuedAtMilliseconds);
			const publication = makeReviewPublication({
				itemId: `review-stale-${staleReadbackKind}`,
				publicationSequence,
			});
			const replacementPublication = makeReviewPublication({
				itemId: publication.job.itemId,
				publicationSequence: publicationSequence + 100,
			});
			const publicationItem = publication.job.payload.item;
			const replacementItem = replacementPublication.job.payload.item;
			let currentItem: BridgeMainRenderPublicationItem | undefined = publicationItem;
			let renderedItem: BridgeMainRenderedItemReadback | null = {
				element: testRenderedElement(true),
				item: publicationItem,
				readableContentMatchesItem: true,
			};
			const readback = {
				readCurrentItem: (): BridgeMainRenderPublicationItem | undefined => currentItem,
				readRenderedItem: (): BridgeMainRenderedItemReadback | null => renderedItem,
			};
			harness.coordinator.acceptPublication(publication);
			bindPublicationItemAsFinal(harness.coordinator, publication);
			harness.coordinator.markPublicationQueued(publication);
			harness.setNowMilliseconds(appliedAtMilliseconds);
			harness.coordinator.observePostRender({
				...readback,
				contextItem: publicationItem,
				itemId: publication.job.itemId,
				phase: 'mount',
			});

			// Act
			switch (staleReadbackKind) {
				case 'disconnected':
					renderedItem = {
						element: testRenderedElement(false),
						item: publicationItem,
						readableContentMatchesItem: true,
					};
					break;
				case 'replaced-current':
					currentItem = replacementItem;
					break;
				case 'mismatched-rendered':
					renderedItem = {
						element: testRenderedElement(true),
						item: replacementItem,
						readableContentMatchesItem: true,
					};
					break;
			}
			harness.setNowMilliseconds(rejectedAtMilliseconds);
			harness.animationFrames.runActiveFrame(1);

			// Assert
			expect(harness.dispositions, staleReadbackKind).toEqual([
				expectedDisposition(publication, 'queued', queuedAtMilliseconds),
				expectedDisposition(publication, 'applied', appliedAtMilliseconds),
				expectedDisposition(publication, 'rejected', rejectedAtMilliseconds, 'stale_attempt'),
			]);
			expect(
				harness.dispositions.some((receipt) => receipt.disposition === 'painted'),
				staleReadbackKind,
			).toBe(false);

			// Act: browser callbacks may arrive again after cancellation or terminal settlement.
			harness.animationFrames.invokeHistoricalFrame(1);
			harness.animationFrames.invokeHistoricalFrame(1);
			harness.coordinator.observePostRender({
				...readback,
				contextItem: publicationItem,
				itemId: publication.job.itemId,
				phase: 'update',
			});
			harness.coordinator.reconcilePublication({
				...readback,
				itemId: publication.job.itemId,
			});

			// Assert
			expect(harness.dispositions, `${staleReadbackKind}:late-callback`).toHaveLength(3);
			expect(harness.animationFrames.activeFrameHandles()).toEqual([]);
		}
	});

	test('supersedes an applied receipt before queueing its same-item replacement and ignores old callbacks', () => {
		// Arrange
		const harness = createCoordinatorHarness(400);
		const oldPublication = makeReviewPublication({
			itemId: 'review-replaced-item',
			publicationSequence: 20,
		});
		const newPublication = makeReviewPublication({
			itemId: 'review-replaced-item',
			publicationSequence: 21,
		});
		const oldItem = oldPublication.job.payload.item;
		const newItem = newPublication.job.payload.item;
		const oldReadback = connectedReadback(oldItem);
		const newReadback = connectedReadback(newItem);
		harness.coordinator.acceptPublication(oldPublication);
		bindPublicationItemAsFinal(harness.coordinator, oldPublication);
		harness.coordinator.markPublicationQueued(oldPublication);
		harness.setNowMilliseconds(410);
		harness.coordinator.observePostRender({
			...oldReadback,
			contextItem: oldItem,
			itemId: oldPublication.job.itemId,
			phase: 'mount',
		});

		// Act
		harness.setNowMilliseconds(420);
		harness.coordinator.acceptPublication(newPublication);
		bindPublicationItemAsFinal(harness.coordinator, newPublication);
		harness.coordinator.markPublicationQueued(newPublication);

		// Assert
		expect(harness.dispositions).toEqual([
			expectedDisposition(oldPublication, 'queued', 400),
			expectedDisposition(oldPublication, 'applied', 410),
			expectedDisposition(oldPublication, 'superseded', 420, 'stale_submission'),
			expectedDisposition(newPublication, 'queued', 420),
		]);
		expect(harness.animationFrames.cancelledFrameHandles()).toEqual([1]);
		expect(harness.animationFrames.activeFrameHandles()).toEqual([]);

		// Act: neither the cancelled frame nor a late Pierre callback for the old item may settle new work.
		harness.animationFrames.invokeHistoricalFrame(1);
		harness.coordinator.observePostRender({
			...oldReadback,
			contextItem: oldItem,
			itemId: oldPublication.job.itemId,
			phase: 'update',
		});

		// Assert
		expect(harness.dispositions).toHaveLength(4);
		expect(harness.animationFrames.activeFrameHandles()).toEqual([]);

		// Act
		harness.setNowMilliseconds(430);
		harness.coordinator.observePostRender({
			...newReadback,
			contextItem: newItem,
			itemId: newPublication.job.itemId,
			phase: 'mount',
		});
		harness.setNowMilliseconds(440);
		harness.animationFrames.runActiveFrame(2);

		// Assert
		expect(harness.dispositions).toEqual([
			expectedDisposition(oldPublication, 'queued', 400),
			expectedDisposition(oldPublication, 'applied', 410),
			expectedDisposition(oldPublication, 'superseded', 420, 'stale_submission'),
			expectedDisposition(newPublication, 'queued', 420),
			expectedDisposition(newPublication, 'applied', 430),
			expectedDisposition(newPublication, 'painted', 440),
		]);
	});

	test('rejects unaccepted stale work and makes explicit supersession and disposal terminal exactly once', () => {
		// Arrange
		const harness = createCoordinatorHarness(500);
		const rejectedPublication = makeReviewPublication({
			itemId: 'review-unaccepted',
			publicationSequence: 30,
		});
		const explicitlySupersededPublication = makeReviewPublication({
			itemId: 'review-explicitly-superseded',
			publicationSequence: 31,
		});
		const appliedAtDisposePublication = makeReviewPublication({
			itemId: 'review-applied-at-dispose',
			publicationSequence: 32,
		});
		const queuedAtDisposePublication = makeReviewPublication({
			itemId: 'review-queued-at-dispose',
			publicationSequence: 33,
		});

		// Act
		harness.coordinator.rejectPublication(rejectedPublication, 'stale_attempt');
		harness.coordinator.acceptPublication(explicitlySupersededPublication);
		bindPublicationItemAsFinal(harness.coordinator, explicitlySupersededPublication);
		harness.coordinator.markPublicationQueued(explicitlySupersededPublication);
		harness.setNowMilliseconds(510);
		harness.coordinator.supersedeItem(
			explicitlySupersededPublication.job.itemId,
			'stale_submission',
		);
		harness.coordinator.acceptPublication(appliedAtDisposePublication);
		bindPublicationItemAsFinal(harness.coordinator, appliedAtDisposePublication);
		harness.coordinator.markPublicationQueued(appliedAtDisposePublication);
		harness.coordinator.acceptPublication(queuedAtDisposePublication);
		bindPublicationItemAsFinal(harness.coordinator, queuedAtDisposePublication);
		harness.coordinator.markPublicationQueued(queuedAtDisposePublication);
		harness.setNowMilliseconds(520);
		const appliedAtDisposeItem = appliedAtDisposePublication.job.payload.item;
		harness.coordinator.observePostRender({
			...connectedReadback(appliedAtDisposeItem),
			contextItem: appliedAtDisposeItem,
			itemId: appliedAtDisposePublication.job.itemId,
			phase: 'mount',
		});

		// Assert
		expect(harness.animationFrames.activeFrameHandles()).toEqual([1]);

		// Act
		harness.setNowMilliseconds(530);
		harness.coordinator.dispose();
		harness.coordinator.dispose();
		harness.animationFrames.invokeHistoricalFrame(1);

		// Assert
		expect(harness.dispositions).toEqual([
			expectedDisposition(rejectedPublication, 'rejected', 500, 'stale_attempt'),
			expectedDisposition(explicitlySupersededPublication, 'queued', 500),
			expectedDisposition(explicitlySupersededPublication, 'superseded', 510, 'stale_submission'),
			expectedDisposition(appliedAtDisposePublication, 'queued', 510),
			expectedDisposition(queuedAtDisposePublication, 'queued', 510),
			expectedDisposition(appliedAtDisposePublication, 'applied', 520),
			expectedDisposition(appliedAtDisposePublication, 'superseded', 530, 'stale_submission'),
			expectedDisposition(queuedAtDisposePublication, 'superseded', 530, 'stale_submission'),
		]);
		expect(harness.animationFrames.cancelledFrameHandles()).toEqual([1]);
		expect(harness.animationFrames.activeFrameHandles()).toEqual([]);
	});

	test('keeps same-item File and Review coordinators isolated by exact publication item identity', () => {
		// Arrange
		const dispositions: BridgeWorkerRenderDispositionReceipt[] = [];
		let nowMilliseconds = 600;
		const reviewAnimationFrames = createControlledAnimationFrames();
		const fileAnimationFrames = createControlledAnimationFrames();
		const reviewCoordinator = createCoordinator({
			animationFrames: reviewAnimationFrames,
			dispositions,
			nowMilliseconds: (): number => nowMilliseconds,
		});
		const fileCoordinator = createCoordinator({
			animationFrames: fileAnimationFrames,
			dispositions,
			nowMilliseconds: (): number => nowMilliseconds,
		});
		const reviewPublication = makeReviewPublication({
			itemId: 'shared-surface-item',
			publicationSequence: 40,
		});
		const filePublication = makeFilePublication({
			itemId: 'shared-surface-item',
			publicationSequence: 41,
		});
		const reviewItem = reviewPublication.job.payload.item;
		const fileItem = filePublication.job.payload.item;
		reviewCoordinator.acceptPublication(reviewPublication);
		bindPublicationItemAsFinal(reviewCoordinator, reviewPublication);
		reviewCoordinator.markPublicationQueued(reviewPublication);
		fileCoordinator.acceptPublication(filePublication);
		bindPublicationItemAsFinal(fileCoordinator, filePublication);
		fileCoordinator.markPublicationQueued(filePublication);

		// Act: the item id matches File, but the Pierre callback object belongs to Review.
		nowMilliseconds = 610;
		fileCoordinator.observePostRender({
			...connectedReadback(reviewItem),
			contextItem: reviewItem,
			itemId: filePublication.job.itemId,
			phase: 'mount',
		});

		// Assert
		expect(dispositions).toEqual([
			expectedDisposition(reviewPublication, 'queued', 600),
			expectedDisposition(filePublication, 'queued', 600),
		]);
		expect(fileAnimationFrames.activeFrameHandles()).toEqual([]);
		expect(reviewAnimationFrames.activeFrameHandles()).toEqual([]);

		// Act
		reviewCoordinator.observePostRender({
			...connectedReadback(reviewItem),
			contextItem: reviewItem,
			itemId: reviewPublication.job.itemId,
			phase: 'mount',
		});
		fileCoordinator.observePostRender({
			...connectedReadback(fileItem),
			contextItem: fileItem,
			itemId: filePublication.job.itemId,
			phase: 'update',
		});
		nowMilliseconds = 620;
		reviewAnimationFrames.runActiveFrame(1);
		fileAnimationFrames.runActiveFrame(1);

		// Assert
		expect(dispositions).toEqual([
			expectedDisposition(reviewPublication, 'queued', 600),
			expectedDisposition(filePublication, 'queued', 600),
			expectedDisposition(reviewPublication, 'applied', 610),
			expectedDisposition(filePublication, 'applied', 610),
			expectedDisposition(reviewPublication, 'painted', 620),
			expectedDisposition(filePublication, 'painted', 620),
		]);
		expect(
			dispositions
				.filter((receipt) => receipt.disposition === 'painted')
				.map((receipt) => ({
					attemptId: receipt.attemptId,
					surface: receipt.surface,
				})),
		).toEqual([
			{ attemptId: reviewPublication.renderReceiptIdentity.attemptId, surface: 'review' },
			{ attemptId: filePublication.renderReceiptIdentity.attemptId, surface: 'file' },
		]);
	});

	test('binds a changed publication only from its exact raw item, then rejects raw callbacks', () => {
		// Arrange
		const harness = createCoordinatorHarness(700);
		const publication = makeReviewPublication({
			itemId: 'review-main-adapted-item',
			publicationSequence: 50,
		});
		const publicationItem = publication.job.payload.item;
		const finalItem = {
			...publicationItem,
			collapsed: true,
			version: (publicationItem.version ?? 0) + 1,
		} satisfies BridgeMainRenderPublicationItem;
		const mismatchedPublicationItem = cloneReviewPublicationItem(publicationItem);
		const mismatchedFinalItem = {
			...mismatchedPublicationItem,
			collapsed: true,
			version: (mismatchedPublicationItem.version ?? 0) + 1,
		} satisfies BridgeMainRenderPublicationItem;
		harness.coordinator.acceptPublication(publication);
		harness.coordinator.markPublicationQueued(publication);

		// Assert: accepting the raw publication does not bind the adapted final item.
		expect(harness.coordinator.isBoundFinalItem(finalItem)).toBe(false);

		// Act: a structurally equal clone is not the exact pending raw publication object.
		harness.coordinator.bindPublicationItem({
			finalItem: mismatchedFinalItem,
			publicationItem: mismatchedPublicationItem,
			residency: 'replaced',
		});
		harness.coordinator.observePostRender({
			...connectedReadback(mismatchedFinalItem),
			contextItem: mismatchedFinalItem,
			itemId: publication.job.itemId,
			phase: 'update',
		});

		// Assert
		expect(harness.dispositions).toEqual([]);
		expect(harness.animationFrames.activeFrameHandles()).toEqual([]);

		// Act: bind with the exact pending raw publication object.
		harness.coordinator.bindPublicationItem({
			finalItem,
			publicationItem,
			residency: 'replaced',
		});

		// Assert: binding tracks only the exact final object, never the raw publication object.
		expect(harness.coordinator.isBoundFinalItem(publicationItem)).toBe(false);
		expect(harness.coordinator.isBoundFinalItem(finalItem)).toBe(true);
		expect(harness.dispositions).toEqual([expectedDisposition(publication, 'queued', 700)]);

		// Act: the worker publication object is no longer the exact item handed to Pierre.
		harness.setNowMilliseconds(710);
		harness.coordinator.observePostRender({
			...connectedReadback(publicationItem),
			contextItem: publicationItem,
			itemId: publication.job.itemId,
			phase: 'update',
		});

		// Assert
		expect(harness.dispositions).toEqual([expectedDisposition(publication, 'queued', 700)]);
		expect(harness.animationFrames.activeFrameHandles()).toEqual([]);

		// Act: only the exact final adapted object plus public readback can settle the attempt.
		harness.coordinator.observePostRender({
			...connectedReadback(finalItem),
			contextItem: finalItem,
			itemId: publication.job.itemId,
			phase: 'update',
		});

		// Assert
		expect(harness.dispositions).toEqual([
			expectedDisposition(publication, 'queued', 700),
			expectedDisposition(publication, 'applied', 710),
		]);
		expect(harness.animationFrames.activeFrameHandles()).toEqual([1]);

		// Act
		harness.setNowMilliseconds(720);
		harness.animationFrames.runActiveFrame(1);

		// Assert
		expect(harness.dispositions).toEqual([
			expectedDisposition(publication, 'queued', 700),
			expectedDisposition(publication, 'applied', 710),
			expectedDisposition(publication, 'painted', 720),
		]);
	});

	test('settles an equal-fingerprint retry from exact connected painted residency without another post-render callback', () => {
		// Arrange: prove one exact final item through the normal replaced-item path first.
		const harness = createCoordinatorHarness(800);
		const firstPublication = makeReviewPublication({
			itemId: 'review-reused-painted-item',
			publicationSequence: 60,
		});
		const firstPublicationItem = firstPublication.job.payload.item;
		const paintedFinalItem = {
			...firstPublicationItem,
			collapsed: true,
			version: (firstPublicationItem.version ?? 0) + 1,
		} satisfies BridgeMainRenderPublicationItem;
		harness.coordinator.acceptPublication(firstPublication);
		harness.coordinator.markPublicationQueued(firstPublication);
		harness.coordinator.bindPublicationItem({
			finalItem: paintedFinalItem,
			publicationItem: firstPublicationItem,
			residency: 'replaced',
		});
		harness.setNowMilliseconds(810);
		harness.coordinator.observePostRender({
			...connectedReadback(paintedFinalItem),
			contextItem: paintedFinalItem,
			itemId: firstPublication.job.itemId,
			phase: 'mount',
		});
		harness.setNowMilliseconds(820);
		harness.animationFrames.runActiveFrame(1);
		const retryPublication = cloneReviewPublicationForRetry(firstPublication);
		const retryPublicationItem = retryPublication.job.payload.item;
		expect(retryPublicationItem).not.toBe(firstPublicationItem);
		expect(retryPublication.renderReceiptIdentity).toEqual({
			...firstPublication.renderReceiptIdentity,
			attemptId: 'attempt-reused-painted-retry',
		});

		// Act: bind the fresh retry attempt to the exact already-painted final object.
		harness.setNowMilliseconds(830);
		harness.coordinator.acceptPublication(retryPublication);
		harness.coordinator.markPublicationQueued(retryPublication);
		harness.coordinator.bindPublicationItem({
			finalItem: paintedFinalItem,
			publicationItem: retryPublicationItem,
			residency: 'reusedPainted',
		});
		harness.setNowMilliseconds(840);
		harness.coordinator.reconcilePublication({
			...connectedReadback(paintedFinalItem),
			itemId: retryPublication.job.itemId,
		});

		// Assert: no synthetic onPostRender call is needed for equal connected residency.
		expect(harness.dispositions).toEqual([
			expectedDisposition(firstPublication, 'queued', 800),
			expectedDisposition(firstPublication, 'applied', 810),
			expectedDisposition(firstPublication, 'painted', 820),
			expectedDisposition(retryPublication, 'queued', 830),
			expectedDisposition(retryPublication, 'applied', 840),
		]);
		expect(harness.coordinator.isBoundFinalItem(paintedFinalItem)).toBe(true);
		expect(harness.animationFrames.activeFrameHandles()).toEqual([2]);

		// Act
		harness.setNowMilliseconds(850);
		harness.animationFrames.runActiveFrame(2);

		// Assert
		expect(harness.dispositions).toEqual([
			expectedDisposition(firstPublication, 'queued', 800),
			expectedDisposition(firstPublication, 'applied', 810),
			expectedDisposition(firstPublication, 'painted', 820),
			expectedDisposition(retryPublication, 'queued', 830),
			expectedDisposition(retryPublication, 'applied', 840),
			expectedDisposition(retryPublication, 'painted', 850),
		]);
	});
});
