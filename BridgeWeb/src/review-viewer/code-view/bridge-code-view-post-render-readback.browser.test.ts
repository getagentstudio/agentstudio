import type { CodeViewHandle } from '@pierre/diffs/react';
import { describe, expect, test } from 'vitest';

import { createBridgeMainRenderFulfillmentCoordinator } from '../../core/comm-worker/bridge-main-render-fulfillment-coordinator.js';
import { makeReviewPublication } from '../../core/comm-worker/bridge-main-render-fulfillment-coordinator.test-support.js';
import type { BridgeWorkerRenderSourceCorrelation } from '../../core/comm-worker/bridge-worker-pierre-render-job.js';
import type { BridgeWorkerRenderDispositionReceipt } from '../../core/comm-worker/bridge-worker-render-fulfillment.js';
import { prepareBridgeCodeViewPublicationPresentationItem } from './bridge-code-view-publication-presentation.js';
import {
	bridgeCodeViewPresentationItemWithExactSource,
	bridgeCodeViewReanchorContentEquivalentPresentationItem,
	observeBridgeCodeViewRenderFulfillment,
} from './bridge-code-view-render-fulfillment.js';
import { bridgeCodeViewItemFromWorkerPreparedItem } from './bridge-code-view-worker-prepared-items.js';

describe('Bridge CodeView post-render readback', () => {
	test('preserves immediate presentation payload while inheriting reanchored exact lineage', () => {
		// Arrange
		const firstPublication = makeReviewPublication({
			itemId: 'reanchored-annotation-lineage',
			publicationSequence: 10,
		});
		const firstItem = bridgeCodeViewItemFromWorkerPreparedItem(firstPublication.job.payload.item);
		if (firstItem?.type !== 'diff') throw new Error('Expected a Review diff item.');
		const currentPresentationItem = bridgeCodeViewPresentationItemWithExactSource({
			presentationItem: { ...firstItem, annotations: [] },
			sourceItem: firstItem,
		});
		const successorPublication = makeReviewPublication({
			itemId: firstPublication.job.itemId,
			publicationSequence: 11,
		});
		const successorItem = bridgeCodeViewItemFromWorkerPreparedItem(
			successorPublication.job.payload.item,
		);
		if (successorItem?.type !== 'diff') throw new Error('Expected a successor Review diff item.');
		Object.assign(successorItem.bridgeMetadata, firstItem.bridgeMetadata);
		Object.assign(successorItem.fileDiff, firstItem.fileDiff);
		expect(
			bridgeCodeViewReanchorContentEquivalentPresentationItem({
				presentationItem: currentPresentationItem,
				sourceItem: successorItem,
			}),
		).toBe(true);

		// Act
		const annotateCurrentPresentation = (): unknown =>
			bridgeCodeViewPresentationItemWithExactSource({
				presentationItem: { ...currentPresentationItem, annotations: [] },
				sourceItem: currentPresentationItem,
			});

		// Assert
		expect(annotateCurrentPresentation).not.toThrow();
		expect(() =>
			bridgeCodeViewPresentationItemWithExactSource({
				presentationItem: {
					...currentPresentationItem,
					annotations: [],
					fileDiff: { ...currentPresentationItem.fileDiff },
				},
				sourceItem: currentPresentationItem,
			}),
		).toThrowError('Bridge CodeView presentation item changed its exact worker source payload.');
	});

	test('accepts a presentation-only annotation clone with the exact worker source payload', async () => {
		// Arrange
		const dispositions: BridgeWorkerRenderDispositionReceipt[] = [];
		const pendingAnimationFrames: FrameRequestCallback[] = [];
		const renderFulfillmentCoordinator = createBridgeMainRenderFulfillmentCoordinator({
			cancelAnimationFrame: (): void => {},
			nowMilliseconds: (): number => 1_000,
			requestAnimationFrame: (callback): number => {
				pendingAnimationFrames.push(callback);
				return 1;
			},
			sendDisposition: (receipt): void => {
				dispositions.push(receipt);
			},
		});
		const sourceCorrelation = {
			descriptorId: 'descriptor-direct-post-render-node',
			itemId: 'direct-post-render-node',
			observedSha256: 'a'.repeat(64),
			position: 'whole',
			requestId: 'request-direct-post-render-node',
			role: 'head',
			sourceGeneration: 1,
			sourceIdentity: 'source-direct-post-render-node',
		} satisfies BridgeWorkerRenderSourceCorrelation;
		const publication = makeReviewPublication({
			itemId: sourceCorrelation.itemId,
			publicationSequence: 1,
			sourceCorrelations: [sourceCorrelation],
		});
		const publicationItem = publication.job.payload.item;
		const exactItem = bridgeCodeViewItemFromWorkerPreparedItem(publicationItem);
		if (exactItem?.type !== 'diff') {
			throw new Error('Expected a main-readable Review diff item.');
		}
		Object.assign(exactItem.bridgeMetadata, { lineCount: 0 });
		Object.assign(exactItem.fileDiff, { additionLines: [], deletionLines: [] });
		expect(() =>
			bridgeCodeViewPresentationItemWithExactSource({
				presentationItem: { ...exactItem, fileDiff: { ...exactItem.fileDiff } },
				sourceItem: exactItem,
			}),
		).toThrowError('Bridge CodeView presentation item changed its exact worker source payload.');
		const presentationItem = bridgeCodeViewPresentationItemWithExactSource({
			presentationItem: {
				...exactItem,
				annotations: [],
				version: (exactItem.version ?? 0) + 1,
			},
			sourceItem: exactItem,
		});
		const renderedElement = document.createElement('div');
		document.body.append(renderedElement);
		renderFulfillmentCoordinator.acceptPublication(publication);
		renderFulfillmentCoordinator.bindPublicationItem({
			finalItem: exactItem,
			publicationItem,
			residency: 'replaced',
		});
		renderFulfillmentCoordinator.markPublicationQueued(publication);

		try {
			// Act
			observeBridgeCodeViewRenderFulfillment({
				contextItem: presentationItem,
				getCodeViewHandle: (): null => null,
				itemId: exactItem.id,
				phase: 'update',
				renderedElement,
				renderFulfillmentCoordinator,
				selectedCodeViewItem: exactItem,
				visibleCodeViewItems: undefined,
			});

			// Assert
			expect(dispositions.map((receipt) => receipt.disposition)).toEqual(['queued', 'applied']);
			expect(pendingAnimationFrames).toHaveLength(1);
			pendingAnimationFrames[0]?.(1_001);
			expect(dispositions.map((receipt) => receipt.disposition)).toEqual([
				'queued',
				'applied',
				'painted',
			]);
			expect(
				renderedElement.getAttribute('data-bridge-painted-source-correlations'),
			).not.toBeNull();
			await Promise.resolve();
			expect(dispositions).toHaveLength(3);
		} finally {
			renderedElement.remove();
			renderFulfillmentCoordinator.dispose();
		}
	});

	test('resolves a newly mounted Pierre clone before the visible-item snapshot catches up', () => {
		// Arrange
		const dispositions: BridgeWorkerRenderDispositionReceipt[] = [];
		const pendingAnimationFrames: FrameRequestCallback[] = [];
		const renderFulfillmentCoordinator = createBridgeMainRenderFulfillmentCoordinator({
			cancelAnimationFrame: (): void => {},
			nowMilliseconds: (): number => 1_500,
			requestAnimationFrame: (callback): number => {
				pendingAnimationFrames.push(callback);
				return 1;
			},
			sendDisposition: (receipt): void => {
				dispositions.push(receipt);
			},
		});
		const publication = makeReviewPublication({
			itemId: 'newly-mounted-presentation-clone',
			publicationSequence: 2,
		});
		const publicationItem = publication.job.payload.item;
		const exactItem = bridgeCodeViewItemFromWorkerPreparedItem(publicationItem);
		if (exactItem?.type !== 'diff') throw new Error('Expected a main-readable Review diff item.');
		Object.assign(exactItem.bridgeMetadata, { lineCount: 0 });
		Object.assign(exactItem.fileDiff, { additionLines: [], deletionLines: [] });
		const presentationClone = { ...exactItem, annotations: [] };
		const renderedElement = document.createElement('div');
		document.body.append(renderedElement);
		const codeViewHandle = {
			getInstance: () => ({
				getRenderedItems: () => [
					{
						element: renderedElement,
						id: presentationClone.id,
						item: presentationClone,
						type: presentationClone.type,
						version: presentationClone.version ?? 0,
					},
				],
			}),
			getItem: () => presentationClone,
		} as unknown as CodeViewHandle<undefined>;
		renderFulfillmentCoordinator.acceptPublication(publication);
		renderFulfillmentCoordinator.bindPublicationItem({
			finalItem: exactItem,
			publicationItem,
			residency: 'replaced',
		});
		renderFulfillmentCoordinator.markPublicationQueued(publication);

		try {
			// Act: Pierre reports B before the async visible-item projection includes B.
			observeBridgeCodeViewRenderFulfillment({
				contextItem: presentationClone,
				getCodeViewHandle: () => codeViewHandle,
				itemId: exactItem.id,
				phase: 'mount',
				renderedElement,
				renderFulfillmentCoordinator,
				selectedCodeViewItem: null,
				visibleCodeViewItems: [],
			});

			// Assert
			expect(dispositions.map((receipt) => receipt.disposition)).toEqual(['queued', 'applied']);
			expect(pendingAnimationFrames).toHaveLength(1);
			pendingAnimationFrames[0]?.(1_501);
			expect(dispositions.map((receipt) => receipt.disposition)).toEqual([
				'queued',
				'applied',
				'painted',
			]);
		} finally {
			renderedElement.remove();
			renderFulfillmentCoordinator.dispose();
		}
	});

	test('reanchors lineage when a new publication reuses a painted presentation item', () => {
		// Arrange
		const dispositions: BridgeWorkerRenderDispositionReceipt[] = [];
		const pendingAnimationFrames: FrameRequestCallback[] = [];
		const renderFulfillmentCoordinator = createBridgeMainRenderFulfillmentCoordinator({
			cancelAnimationFrame: (): void => {},
			nowMilliseconds: (): number => 1_000,
			requestAnimationFrame: (callback): number => {
				pendingAnimationFrames.push(callback);
				return 1;
			},
			sendDisposition: (receipt): void => {
				dispositions.push(receipt);
			},
		});
		const publicationSeed = makeReviewPublication({
			itemId: 'reused-presentation-item',
			publicationSequence: 2,
		});
		if (publicationSeed.job.payload.kind !== 'codeViewDiffItem') {
			throw new Error('Expected a Review diff publication payload.');
		}
		const exactItem = bridgeCodeViewItemFromWorkerPreparedItem(publicationSeed.job.payload.item);
		if (exactItem?.type !== 'diff') throw new Error('Expected a main-readable Review diff item.');
		Object.assign(exactItem.bridgeMetadata, { lineCount: 0 });
		Object.assign(exactItem.fileDiff, { additionLines: [], deletionLines: [] });
		const reusedPresentationItem = bridgeCodeViewPresentationItemWithExactSource({
			presentationItem: { ...exactItem, annotations: [] },
			sourceItem: exactItem,
		});
		const publication = {
			...publicationSeed,
			job: {
				...publicationSeed.job,
				payload: { ...publicationSeed.job.payload, item: reusedPresentationItem },
			},
		};
		renderFulfillmentCoordinator.acceptPublication(publication);
		const reboundPresentationItem = prepareBridgeCodeViewPublicationPresentationItem({
			currentItem: reusedPresentationItem,
			getCodeViewHandle: (): null => null,
			metadataItem: reusedPresentationItem,
			renderFulfillmentCoordinator,
		});
		const annotationClone = bridgeCodeViewPresentationItemWithExactSource({
			presentationItem: { ...reboundPresentationItem, annotations: [] },
			sourceItem: reboundPresentationItem,
		});
		const renderedElement = document.createElement('div');
		document.body.append(renderedElement);
		expect(reboundPresentationItem).toBe(reusedPresentationItem);
		expect(renderFulfillmentCoordinator.isBoundFinalItem(reboundPresentationItem)).toBe(true);
		renderFulfillmentCoordinator.markPublicationQueued(publication);

		try {
			// Act
			observeBridgeCodeViewRenderFulfillment({
				contextItem: annotationClone,
				getCodeViewHandle: (): null => null,
				itemId: annotationClone.id,
				phase: 'update',
				renderedElement,
				renderFulfillmentCoordinator,
				selectedCodeViewItem: annotationClone,
				visibleCodeViewItems: undefined,
			});

			// Assert
			expect(dispositions.map((receipt) => receipt.disposition)).toEqual(['queued', 'applied']);
			expect(pendingAnimationFrames).toHaveLength(1);
			pendingAnimationFrames[0]?.(1_001);
			expect(dispositions.map((receipt) => receipt.disposition)).toEqual([
				'queued',
				'applied',
				'painted',
			]);
		} finally {
			renderedElement.remove();
			renderFulfillmentCoordinator.dispose();
		}
	});

	test('reconciles authoritative visible lineage when callback context is no longer mapped', () => {
		// Arrange
		const dispositions: BridgeWorkerRenderDispositionReceipt[] = [];
		const pendingAnimationFrames: FrameRequestCallback[] = [];
		const renderFulfillmentCoordinator = createBridgeMainRenderFulfillmentCoordinator({
			cancelAnimationFrame: (): void => {},
			nowMilliseconds: (): number => 2_000,
			requestAnimationFrame: (callback): number => {
				pendingAnimationFrames.push(callback);
				return 1;
			},
			sendDisposition: (receipt): void => {
				dispositions.push(receipt);
			},
		});
		const publication = makeReviewPublication({
			itemId: 'fallback-visible-lineage',
			publicationSequence: 3,
		});
		const publicationItem = publication.job.payload.item;
		const exactItem = bridgeCodeViewItemFromWorkerPreparedItem(publicationItem);
		if (exactItem?.type !== 'diff') throw new Error('Expected a main-readable Review diff item.');
		Object.assign(exactItem.bridgeMetadata, { lineCount: 0 });
		Object.assign(exactItem.fileDiff, { additionLines: [], deletionLines: [] });
		const presentationItem = bridgeCodeViewPresentationItemWithExactSource({
			presentationItem: { ...exactItem, annotations: [] },
			sourceItem: exactItem,
		});
		const unmappedCallbackItem = { ...presentationItem, annotations: [] };
		const renderedElement = document.createElement('div');
		document.body.append(renderedElement);
		const codeViewHandle = {
			getInstance: () => ({
				getRenderedItems: () => [
					{
						element: renderedElement,
						id: unmappedCallbackItem.id,
						item: unmappedCallbackItem,
						type: unmappedCallbackItem.type,
						version: unmappedCallbackItem.version ?? 0,
					},
				],
			}),
			getItem: () => unmappedCallbackItem,
		} as unknown as CodeViewHandle<undefined>;
		renderFulfillmentCoordinator.acceptPublication(publication);
		renderFulfillmentCoordinator.bindPublicationItem({
			finalItem: exactItem,
			publicationItem,
			residency: 'replaced',
		});
		renderFulfillmentCoordinator.markPublicationQueued(publication);

		try {
			// Act
			observeBridgeCodeViewRenderFulfillment({
				contextItem: unmappedCallbackItem,
				getCodeViewHandle: () => codeViewHandle,
				itemId: unmappedCallbackItem.id,
				phase: 'update',
				renderedElement,
				renderFulfillmentCoordinator,
				selectedCodeViewItem: exactItem,
				visibleCodeViewItems: [exactItem],
			});

			// Assert
			expect(dispositions.map((receipt) => receipt.disposition)).toEqual(['queued', 'applied']);
			expect(pendingAnimationFrames).toHaveLength(1);
			pendingAnimationFrames[0]?.(2_001);
			expect(dispositions.map((receipt) => receipt.disposition)).toEqual([
				'queued',
				'applied',
				'painted',
			]);
		} finally {
			renderedElement.remove();
			renderFulfillmentCoordinator.dispose();
		}
	});

	test('reanchors a content-equal rendered presentation object to the retry publication', () => {
		// Arrange
		const dispositions: BridgeWorkerRenderDispositionReceipt[] = [];
		const pendingAnimationFrames: FrameRequestCallback[] = [];
		const renderFulfillmentCoordinator = createBridgeMainRenderFulfillmentCoordinator({
			cancelAnimationFrame: (): void => {},
			nowMilliseconds: (): number => 3_000,
			requestAnimationFrame: (callback): number => {
				pendingAnimationFrames.push(callback);
				return 1;
			},
			sendDisposition: (receipt): void => {
				dispositions.push(receipt);
			},
		});
		const sourceCorrelation = {
			descriptorId: 'descriptor-content-equal-retry-lineage',
			itemId: 'content-equal-retry-lineage',
			observedSha256: 'c'.repeat(64),
			position: 'whole',
			requestId: 'request-content-equal-retry-lineage',
			role: 'head',
			sourceGeneration: 1,
			sourceIdentity: 'source-content-equal-retry-lineage',
		} satisfies BridgeWorkerRenderSourceCorrelation;
		const priorPublication = makeReviewPublication({
			itemId: 'content-equal-retry-lineage',
			publicationSequence: 4,
			sourceCorrelations: [sourceCorrelation],
		});
		if (priorPublication.job.payload.kind !== 'codeViewDiffItem') {
			throw new Error('Expected a Review diff publication payload.');
		}
		const priorExactItem = bridgeCodeViewItemFromWorkerPreparedItem(
			priorPublication.job.payload.item,
		);
		if (priorExactItem?.type !== 'diff') {
			throw new Error('Expected a main-readable Review diff item.');
		}
		Object.assign(priorExactItem.bridgeMetadata, { lineCount: 0 });
		Object.assign(priorExactItem.fileDiff, { additionLines: [], deletionLines: [] });
		const renderedPresentationItem = {
			...priorExactItem,
			annotations: [],
			bridgeMetadata: { ...priorExactItem.bridgeMetadata },
			fileDiff: { ...priorExactItem.fileDiff },
		};
		const currentPresentationItem = bridgeCodeViewPresentationItemWithExactSource({
			presentationItem: { ...priorExactItem, annotations: [] },
			sourceItem: priorExactItem,
		});
		const currentHandlePresentationItem = {
			...currentPresentationItem,
			bridgeMetadata: { ...currentPresentationItem.bridgeMetadata },
			fileDiff: { ...currentPresentationItem.fileDiff },
		};
		const renderedElement = document.createElement('div');
		document.body.append(renderedElement);
		// Rendering can precede the coordinator's paint receipt; a retry in that window
		// takes the replaced path and may render once more. Establish the painted record
		// here to prove the zero-apply path after the receipt has settled.
		const paintedPublication = {
			...priorPublication,
			job: {
				...priorPublication.job,
				payload: { ...priorPublication.job.payload, item: currentPresentationItem },
			},
		};
		renderFulfillmentCoordinator.acceptPublication(paintedPublication);
		renderFulfillmentCoordinator.bindPublicationItem({
			finalItem: currentPresentationItem,
			publicationItem: currentPresentationItem,
			residency: 'reusedPainted',
		});
		renderFulfillmentCoordinator.markPublicationQueued(paintedPublication);
		renderFulfillmentCoordinator.reconcilePublication({
			itemId: currentPresentationItem.id,
			readCurrentItem: () => currentPresentationItem,
			readRenderedItem: () => ({
				element: renderedElement,
				item: currentPresentationItem,
				readableContentMatchesItem: true,
			}),
		});
		pendingAnimationFrames[0]?.(2_999);
		expect(renderFulfillmentCoordinator.isBoundFinalItem(currentPresentationItem)).toBe(true);
		dispositions.length = 0;
		pendingAnimationFrames.length = 0;
		const codeViewHandle = {
			getInstance: () => ({
				getRenderedItems: () => [
					{
						element: renderedElement,
						id: renderedPresentationItem.id,
						item: renderedPresentationItem,
						type: renderedPresentationItem.type,
						version: renderedPresentationItem.version ?? 0,
					},
				],
			}),
			getItem: () => currentHandlePresentationItem,
		} as unknown as CodeViewHandle<undefined>;
		const retryPublication = makeReviewPublication({
			itemId: priorExactItem.id,
			publicationSequence: 5,
			sourceCorrelations: [sourceCorrelation],
		});
		const retryItem = bridgeCodeViewItemFromWorkerPreparedItem(retryPublication.job.payload.item);
		if (retryItem?.type !== 'diff') {
			throw new Error('Expected a main-readable retry Review diff item.');
		}
		Object.assign(retryItem.bridgeMetadata, priorExactItem.bridgeMetadata);
		Object.assign(retryItem.fileDiff, priorExactItem.fileDiff);
		renderFulfillmentCoordinator.acceptPublication(retryPublication);

		try {
			// Act
			prepareBridgeCodeViewPublicationPresentationItem({
				currentItem: currentPresentationItem,
				getCodeViewHandle: () => codeViewHandle,
				metadataItem: retryItem,
				renderFulfillmentCoordinator,
			});
			renderFulfillmentCoordinator.markPublicationQueued(retryPublication);

			// Assert
			expect(dispositions.map((receipt) => receipt.disposition)).toEqual(['queued', 'applied']);
			expect(pendingAnimationFrames).toHaveLength(1);
			pendingAnimationFrames[0]?.(3_001);
			expect(dispositions.map((receipt) => receipt.disposition)).toEqual([
				'queued',
				'applied',
				'painted',
			]);
		} finally {
			renderedElement.remove();
			renderFulfillmentCoordinator.dispose();
		}
	});
});
