import { describe, expect, test } from 'vitest';

import { stampBridgeRenderDispositionSettlementEvidence } from './bridge-main-render-fulfillment-coordinator.js';
import {
	bindPublicationItemAsFinal,
	type BridgeMainRenderedItemReadback,
	type BridgeMainRenderPublicationItem,
	createCoordinatorHarness,
	expectedDisposition,
	makeFilePublication,
	makeReviewPublication,
	testRenderedElement,
} from './bridge-main-render-fulfillment-coordinator.test-support.js';
import type { BridgeWorkerRenderSourceCorrelation } from './bridge-worker-pierre-render-job.js';

function settlementEvidenceElement(
	attributes: Map<string, string>,
): Pick<Element, 'getAttribute' | 'setAttribute'> {
	return {
		getAttribute: (name: string): string | null => attributes.get(name) ?? null,
		setAttribute: (name: string, value: string): void => {
			attributes.set(name, value);
		},
	};
}

describe('Bridge main render fulfillment coordinator paint evidence', () => {
	test('stamps settlement only on painted elements for the exact publication', () => {
		const painted = new Map([['data-bridge-painted-publication-id', 'publication-a']]);
		const other = new Map([['data-bridge-painted-publication-id', 'publication-b']]);
		stampBridgeRenderDispositionSettlementEvidence({
			elements: [settlementEvidenceElement(painted), settlementEvidenceElement(other)],
			outcome: 'settled-failed',
			publicationId: 'publication-a',
		});

		expect(painted.get('data-bridge-render-disposition-settled-publication-id')).toBe(
			'publication-a',
		);
		expect(painted.get('data-bridge-render-disposition-settled-outcome')).toBe('settled-failed');
		expect(other.has('data-bridge-render-disposition-settled-publication-id')).toBe(false);
	});

	test('defers correlated readable-paint evidence without duplicating the terminal disposition', () => {
		// Arrange
		const harness = createCoordinatorHarness(110);
		const sourceCorrelation = {
			descriptorId: 'descriptor-review-readable-paint',
			itemId: 'review-readable-paint',
			observedSha256: 'b'.repeat(64),
			position: 'whole',
			requestId: 'content-request-review-readable-paint',
			role: 'head',
			sourceGeneration: 7,
			sourceIdentity: 'review-readable-paint-source',
		} satisfies BridgeWorkerRenderSourceCorrelation;
		const publication = makeReviewPublication({
			itemId: sourceCorrelation.itemId,
			publicationSequence: 3,
			sourceCorrelations: [sourceCorrelation],
		});
		const publicationItem = publication.job.payload.item;
		const renderedElementAttributes = new Map<string, string>();
		let readableContentMatchesItem = false;
		const readback = {
			readCurrentItem: (): BridgeMainRenderPublicationItem => publicationItem,
			readRenderedItem: () => ({
				element: testRenderedElement(true, renderedElementAttributes),
				item: publicationItem,
				readableContentMatchesItem,
			}),
		};
		harness.coordinator.acceptPublication(publication);
		bindPublicationItemAsFinal(harness.coordinator, publication);
		harness.coordinator.markPublicationQueued(publication);
		harness.coordinator.observePostRender({
			...readback,
			contextItem: publicationItem,
			itemId: publication.job.itemId,
			phase: 'mount',
		});

		// Act: the item is connected, but Pierre has not populated its readable body yet.
		harness.animationFrames.runActiveFrame(1);

		// Assert: product residency settles, but the readable-source proof does not stamp early.
		expect(harness.dispositions).toEqual([
			expectedDisposition(publication, 'queued', 110),
			expectedDisposition(publication, 'applied', 110),
			expectedDisposition(publication, 'painted', 110),
		]);
		expect(renderedElementAttributes.size).toBe(0);

		// Act: a fresh shell reports the exact retained item before Pierre's body rows settle.
		harness.coordinator.observePostRender({
			...readback,
			contextItem: publicationItem,
			itemId: publication.job.itemId,
			phase: 'update',
		});

		// Assert: retained evidence gets one paint-boundary recheck, without another receipt.
		expect(harness.animationFrames.activeFrameHandles()).toEqual([2]);
		expect(harness.dispositions).toHaveLength(3);
		harness.animationFrames.runActiveFrame(2);
		expect(harness.animationFrames.activeFrameHandles()).toEqual([3]);

		// Act: Pierre's body becomes readable before the next bounded paint check.
		readableContentMatchesItem = true;
		harness.setNowMilliseconds(120);
		harness.animationFrames.runActiveFrame(3);
		expect(harness.animationFrames.activeFrameHandles()).toEqual([]);

		// Assert: the boundary stamps retained lineage without another disposition.
		expect(harness.dispositions).toEqual([
			expectedDisposition(publication, 'queued', 110),
			expectedDisposition(publication, 'applied', 110),
			expectedDisposition(publication, 'painted', 110),
		]);
		expect(renderedElementAttributes.has('data-bridge-painted-source-correlations')).toBe(true);
	});

	test('stamps exact source correlation and publication identity on the connected rendered element only at the paint boundary', () => {
		// Arrange
		const harness = createCoordinatorHarness(130);
		const sourceCorrelation = {
			descriptorId: 'descriptor-live-review-head',
			itemId: 'review-live-element-source',
			observedSha256: 'c'.repeat(64),
			position: 'whole',
			requestId: 'content-request-live-review-head',
			role: 'head',
			sourceGeneration: 9,
			sourceIdentity: 'review-live-element-source-identity',
		} satisfies BridgeWorkerRenderSourceCorrelation;
		const publication = makeReviewPublication({
			itemId: sourceCorrelation.itemId,
			publicationSequence: 4,
			sourceCorrelations: [sourceCorrelation],
		});
		const publicationItem = publication.job.payload.item;
		const renderedElementAttributes = new Map<string, string>();
		const renderedElement = testRenderedElement(true, renderedElementAttributes);
		const readback = {
			readCurrentItem: (): BridgeMainRenderPublicationItem => publicationItem,
			readRenderedItem: (): BridgeMainRenderedItemReadback => ({
				element: renderedElement,
				item: publicationItem,
				readableContentMatchesItem: true,
			}),
		};
		harness.coordinator.acceptPublication(publication);
		bindPublicationItemAsFinal(harness.coordinator, publication);
		harness.coordinator.markPublicationQueued(publication);

		// Act
		harness.coordinator.observePostRender({
			...readback,
			contextItem: publicationItem,
			itemId: publication.job.itemId,
			phase: 'mount',
		});

		// Assert
		expect(renderedElementAttributes.has('data-bridge-painted-source-correlations')).toBe(false);
		expect(renderedElementAttributes.has('data-bridge-painted-publication-id')).toBe(false);
		expect(harness.dispositions).toEqual([
			expectedDisposition(publication, 'queued', 130),
			expectedDisposition(publication, 'applied', 130),
		]);

		// Act
		harness.setNowMilliseconds(140);
		harness.animationFrames.runActiveFrame(1);

		// Assert
		const encodedPaintedSourceCorrelations = renderedElementAttributes.get(
			'data-bridge-painted-source-correlations',
		);
		const paintedPublicationId = renderedElementAttributes.get(
			'data-bridge-painted-publication-id',
		);
		const expectedPaintedSourceCorrelation = {
			...sourceCorrelation,
			disposition: 'painted',
			pierreItemId: publication.job.payload.item.id,
			publicationId: publication.renderReceiptIdentity.publicationId,
			semanticItemId: publication.job.itemId,
			surface: 'review',
		};
		expect(encodedPaintedSourceCorrelations).toBeDefined();
		const decodedPaintedSourceCorrelations: unknown = JSON.parse(
			encodedPaintedSourceCorrelations ?? 'null',
		);
		expect(decodedPaintedSourceCorrelations).toEqual([expectedPaintedSourceCorrelation]);
		expect(paintedPublicationId).toBe(publication.renderReceiptIdentity.publicationId);
		stampBridgeRenderDispositionSettlementEvidence({
			elements: [settlementEvidenceElement(renderedElementAttributes)],
			outcome: 'settled-ok',
			publicationId: publication.renderReceiptIdentity.publicationId,
		});
		harness.coordinator.observePostRender({
			...readback,
			contextItem: publicationItem,
			itemId: publication.job.itemId,
			phase: 'update',
		});
		expect(renderedElementAttributes.get('data-bridge-render-disposition-settled-outcome')).toBe(
			'settled-ok',
		);
		expect(
			Array.isArray(decodedPaintedSourceCorrelations) &&
				decodedPaintedSourceCorrelations.every(
					(correlation) =>
						typeof correlation === 'object' &&
						correlation !== null &&
						'publicationId' in correlation &&
						correlation.publicationId === paintedPublicationId,
				),
		).toBe(true);
		expect(harness.dispositions).toEqual([
			expectedDisposition(publication, 'queued', 130),
			expectedDisposition(publication, 'applied', 130),
			expectedDisposition(publication, 'painted', 140),
		]);
	});

	test('keeps painted disposition and terminal cleanup fail-open when rendered element attribute stamping throws', () => {
		// Arrange
		const harness = createCoordinatorHarness(150);
		const sourceCorrelation = {
			descriptorId: 'descriptor-file-attribute-failure',
			itemId: 'file-attribute-failure',
			observedSha256: 'd'.repeat(64),
			position: 'whole',
			requestId: 'content-request-file-attribute-failure',
			role: 'file',
			sourceGeneration: 11,
			sourceIdentity: 'file-attribute-failure-identity',
		} satisfies BridgeWorkerRenderSourceCorrelation;
		const publication = makeFilePublication({
			itemId: sourceCorrelation.itemId,
			publicationSequence: 5,
			sourceCorrelations: [sourceCorrelation],
		});
		const publicationItem = publication.job.payload.item;
		const attemptedAttributeNames: string[] = [];
		const renderedElement = {
			...testRenderedElement(true),
			setAttribute: (qualifiedName: string): void => {
				attemptedAttributeNames.push(qualifiedName);
				throw new Error('Synthetic rendered-element attribute failure.');
			},
		} satisfies BridgeMainRenderedItemReadback['element'];
		const readback = {
			readCurrentItem: (): BridgeMainRenderPublicationItem => publicationItem,
			readRenderedItem: (): BridgeMainRenderedItemReadback => ({
				element: renderedElement,
				item: publicationItem,
				readableContentMatchesItem: true,
			}),
		};
		harness.coordinator.acceptPublication(publication);
		bindPublicationItemAsFinal(harness.coordinator, publication);
		harness.coordinator.markPublicationQueued(publication);
		harness.coordinator.observePostRender({
			...readback,
			contextItem: publicationItem,
			itemId: publication.job.itemId,
			phase: 'mount',
		});

		// Act
		harness.setNowMilliseconds(160);
		const runPaintBoundary = (): void => harness.animationFrames.runActiveFrame(1);

		// Assert
		expect(runPaintBoundary).not.toThrow();
		expect(attemptedAttributeNames.length).toBeGreaterThan(0);
		expect(harness.dispositions).toEqual([
			expectedDisposition(publication, 'queued', 150),
			expectedDisposition(publication, 'applied', 150),
			expectedDisposition(publication, 'painted', 160),
		]);
		expect(harness.coordinator.isBoundFinalItem(publicationItem)).toBe(true);
		expect(harness.animationFrames.activeFrameHandles()).toEqual([]);

		// Act: a stale browser callback after terminal cleanup cannot publish twice.
		harness.animationFrames.invokeHistoricalFrame(1);

		// Assert
		expect(harness.dispositions).toHaveLength(3);
	});

	test('restores settled painted lineage onto replacement elements without publishing another disposition', () => {
		// Arrange
		const harness = createCoordinatorHarness(170);
		const sourceCorrelation = {
			descriptorId: 'descriptor-review-pooled-replacement',
			itemId: 'review-pooled-replacement',
			observedSha256: 'e'.repeat(64),
			position: 'whole',
			requestId: 'content-request-review-pooled-replacement',
			role: 'head',
			sourceGeneration: 13,
			sourceIdentity: 'review-pooled-replacement-identity',
		} satisfies BridgeWorkerRenderSourceCorrelation;
		const publication = makeReviewPublication({
			itemId: sourceCorrelation.itemId,
			publicationSequence: 6,
			sourceCorrelations: [sourceCorrelation],
		});
		const publicationItem = publication.job.payload.item;
		const initialRenderedElementAttributes = new Map<string, string>();
		let renderedElement = testRenderedElement(true, initialRenderedElementAttributes);
		const readback = {
			readCurrentItem: (): BridgeMainRenderPublicationItem => publicationItem,
			readRenderedItem: (): BridgeMainRenderedItemReadback => ({
				element: renderedElement,
				item: publicationItem,
				readableContentMatchesItem: true,
			}),
		};
		harness.coordinator.acceptPublication(publication);
		bindPublicationItemAsFinal(harness.coordinator, publication);
		harness.coordinator.markPublicationQueued(publication);
		harness.coordinator.observePostRender({
			...readback,
			contextItem: publicationItem,
			itemId: publication.job.itemId,
			phase: 'mount',
		});
		harness.setNowMilliseconds(180);
		harness.animationFrames.runActiveFrame(1);
		const settledDispositions = [...harness.dispositions];
		expect(initialRenderedElementAttributes.size).toBe(2);

		// Act: Pierre may replace the HTMLElement while retaining the exact final item object.
		const postRenderReplacementAttributes = new Map<string, string>();
		renderedElement = testRenderedElement(true, postRenderReplacementAttributes);
		harness.coordinator.observePostRender({
			...readback,
			contextItem: publicationItem,
			itemId: publication.job.itemId,
			phase: 'update',
		});

		// Assert
		expect(postRenderReplacementAttributes).toEqual(initialRenderedElementAttributes);
		expect(harness.dispositions).toEqual(settledDispositions);
		expect(harness.animationFrames.activeFrameHandles()).toEqual([]);

		// Act: reconciliation must restore the same retained lineage independently.
		const reconciledReplacementAttributes = new Map<string, string>();
		renderedElement = testRenderedElement(true, reconciledReplacementAttributes);
		harness.coordinator.reconcilePublication({
			...readback,
			itemId: publication.job.itemId,
		});

		// Assert
		expect(reconciledReplacementAttributes).toEqual(initialRenderedElementAttributes);
		expect(harness.dispositions).toEqual(settledDispositions);
		expect(harness.animationFrames.activeFrameHandles()).toEqual([]);
	});

	test('clears stale painted lineage when an element is pooled for a different exact item', () => {
		// Arrange
		const harness = createCoordinatorHarness(190);
		const paintedSourceCorrelation = {
			descriptorId: 'descriptor-file-pooled-old',
			itemId: 'file-pooled-old',
			observedSha256: 'f'.repeat(64),
			position: 'whole',
			requestId: 'content-request-file-pooled-old',
			role: 'file',
			sourceGeneration: 15,
			sourceIdentity: 'file-pooled-old-identity',
		} satisfies BridgeWorkerRenderSourceCorrelation;
		const paintedPublication = makeFilePublication({
			itemId: paintedSourceCorrelation.itemId,
			publicationSequence: 7,
			sourceCorrelations: [paintedSourceCorrelation],
		});
		const paintedItem = paintedPublication.job.payload.item;
		const pooledElementAttributes = new Map<string, string>();
		const pooledElement = testRenderedElement(true, pooledElementAttributes);
		let currentItem: BridgeMainRenderPublicationItem = paintedItem;
		let renderedItem: BridgeMainRenderPublicationItem = paintedItem;
		const readback = {
			readCurrentItem: (): BridgeMainRenderPublicationItem => currentItem,
			readRenderedItem: (): BridgeMainRenderedItemReadback => ({
				element: pooledElement,
				item: renderedItem,
				readableContentMatchesItem: true,
			}),
		};
		harness.coordinator.acceptPublication(paintedPublication);
		bindPublicationItemAsFinal(harness.coordinator, paintedPublication);
		harness.coordinator.markPublicationQueued(paintedPublication);
		harness.coordinator.observePostRender({
			...readback,
			contextItem: paintedItem,
			itemId: paintedPublication.job.itemId,
			phase: 'mount',
		});
		harness.setNowMilliseconds(200);
		harness.animationFrames.runActiveFrame(1);
		expect(pooledElementAttributes.size).toBe(2);
		const unrelatedPublication = makeFilePublication({
			itemId: 'file-pooled-unrelated',
			publicationSequence: 8,
		});
		const unrelatedItem = unrelatedPublication.job.payload.item;
		currentItem = unrelatedItem;
		renderedItem = unrelatedItem;
		harness.coordinator.acceptPublication(unrelatedPublication);
		bindPublicationItemAsFinal(harness.coordinator, unrelatedPublication);
		harness.coordinator.markPublicationQueued(unrelatedPublication);

		// Act: Pierre reuses the old element before the unrelated publication reaches paint.
		harness.setNowMilliseconds(210);
		harness.coordinator.observePostRender({
			...readback,
			contextItem: unrelatedItem,
			itemId: unrelatedPublication.job.itemId,
			phase: 'mount',
		});

		// Assert
		expect(pooledElementAttributes.has('data-bridge-painted-source-correlations')).toBe(false);
		expect(pooledElementAttributes.has('data-bridge-painted-publication-id')).toBe(false);
		expect(harness.dispositions).toEqual([
			expectedDisposition(paintedPublication, 'queued', 190),
			expectedDisposition(paintedPublication, 'applied', 190),
			expectedDisposition(paintedPublication, 'painted', 200),
			expectedDisposition(unrelatedPublication, 'queued', 200),
			expectedDisposition(unrelatedPublication, 'applied', 210),
		]);
		expect(harness.animationFrames.activeFrameHandles()).toEqual([2]);
	});
});
