import { describe, expect, test } from 'vitest';

import {
	bindPublicationItemAsFinal,
	createCoordinatorHarness,
	makeReviewPublication,
} from '../../core/comm-worker/bridge-main-render-fulfillment-coordinator.test-support.js';
import { prepareBridgeCodeViewPublicationPresentationItem } from './bridge-code-view-publication-presentation.js';
import { bridgeCodeViewPresentationItemWithExactSource } from './bridge-code-view-render-fulfillment.js';
import { bridgeCodeViewItemFromWorkerPreparedItem } from './bridge-code-view-worker-prepared-items.js';
import { reviewPierreAnnotationForComposer } from './worktree-annotation-pierre-adapter.js';

describe('Bridge CodeView publication presentation', () => {
	test('retains a newer live annotation presentation when already-bound metadata is reapplied', () => {
		// Arrange
		const harness = createCoordinatorHarness(1_000);
		const publication = makeReviewPublication({
			itemId: 'annotation-presentation-reapply',
			publicationSequence: 1,
		});
		if (publication.job.payload.kind !== 'codeViewDiffItem') {
			throw new Error('Expected a Review diff publication payload.');
		}
		const metadataItem = bridgeCodeViewItemFromWorkerPreparedItem(publication.job.payload.item);
		if (metadataItem?.type !== 'diff') throw new Error('Expected a Review diff item.');
		const composerPresentation = reviewPierreAnnotationForComposer({
			editToken: 'edit-annotation-presentation-reapply',
			itemType: 'diff',
			range: { end: 1, side: 'additions', start: 1 },
		});
		if (composerPresentation === null) throw new Error('Expected a Review composer annotation.');
		const liveComposerAnnotation: NonNullable<(typeof metadataItem)['annotations']>[number] = {
			lineNumber: composerPresentation.lineNumber,
			side: composerPresentation.side,
		};
		Object.assign(liveComposerAnnotation, { metadata: composerPresentation.metadata });
		const liveAnnotations: NonNullable<(typeof metadataItem)['annotations']> = [
			liveComposerAnnotation,
		];
		const livePresentationItem = bridgeCodeViewPresentationItemWithExactSource({
			presentationItem: {
				...metadataItem,
				annotations: liveAnnotations,
				version: 2,
			},
			sourceItem: metadataItem,
		});
		const boundPublication = {
			...publication,
			job: {
				...publication.job,
				payload: { ...publication.job.payload, item: metadataItem },
			},
		};
		harness.coordinator.acceptPublication(boundPublication);
		bindPublicationItemAsFinal(harness.coordinator, boundPublication);
		expect(harness.coordinator.isBoundFinalItem(metadataItem)).toBe(true);

		try {
			// Act
			const presentedItem = prepareBridgeCodeViewPublicationPresentationItem({
				currentItem: livePresentationItem,
				getCodeViewHandle: () => null,
				metadataItem,
				renderFulfillmentCoordinator: harness.coordinator,
			});
			if (presentedItem.type !== 'diff') throw new Error('Expected a presented Review diff item.');

			// Assert
			expect(presentedItem).toBe(livePresentationItem);
			expect(presentedItem.version).toBe(2);
			expect(presentedItem.annotations).toBe(liveAnnotations);
			expect(presentedItem.bridgeMetadata).toBe(metadataItem.bridgeMetadata);
			expect(presentedItem.fileDiff).toBe(metadataItem.fileDiff);
			expect(() =>
				bridgeCodeViewPresentationItemWithExactSource({
					presentationItem: { ...presentedItem, annotations: liveAnnotations },
					sourceItem: metadataItem,
				}),
			).not.toThrow();
		} finally {
			harness.coordinator.dispose();
		}
	});

	test('advances beyond the live version when already-bound metadata replaces changed content', () => {
		// Arrange
		const harness = createCoordinatorHarness(2_000);
		const priorPublication = makeReviewPublication({
			itemId: 'authoritative-content-replacement',
			publicationSequence: 4,
		});
		if (priorPublication.job.payload.kind !== 'codeViewDiffItem') {
			throw new Error('Expected a prior Review diff publication payload.');
		}
		const priorSourceItem = bridgeCodeViewItemFromWorkerPreparedItem(
			priorPublication.job.payload.item,
		);
		if (priorSourceItem?.type !== 'diff') throw new Error('Expected a prior Review diff item.');
		const livePresentationItem = bridgeCodeViewPresentationItemWithExactSource({
			presentationItem: { ...priorSourceItem, annotations: [], collapsed: true, version: 4 },
			sourceItem: priorSourceItem,
		});
		const replacementPublication = makeReviewPublication({
			itemId: priorSourceItem.id,
			publicationSequence: 1,
		});
		if (replacementPublication.job.payload.kind !== 'codeViewDiffItem') {
			throw new Error('Expected a replacement Review diff publication payload.');
		}
		const replacementMetadataItem = bridgeCodeViewItemFromWorkerPreparedItem(
			replacementPublication.job.payload.item,
		);
		if (replacementMetadataItem?.type !== 'diff') {
			throw new Error('Expected a replacement Review diff item.');
		}
		const boundReplacementPublication = {
			...replacementPublication,
			job: {
				...replacementPublication.job,
				payload: { ...replacementPublication.job.payload, item: replacementMetadataItem },
			},
		};
		harness.coordinator.acceptPublication(boundReplacementPublication);
		bindPublicationItemAsFinal(harness.coordinator, boundReplacementPublication);
		expect(harness.coordinator.isBoundFinalItem(replacementMetadataItem)).toBe(true);

		try {
			// Act
			const presentedItem = prepareBridgeCodeViewPublicationPresentationItem({
				currentItem: livePresentationItem,
				getCodeViewHandle: () => null,
				metadataItem: replacementMetadataItem,
				renderFulfillmentCoordinator: harness.coordinator,
			});
			if (presentedItem.type !== 'diff') throw new Error('Expected a presented Review diff item.');

			// Assert
			expect(presentedItem.version).toBe(5);
			expect(presentedItem.version).toBeGreaterThan(livePresentationItem.version ?? 0);
			expect(presentedItem.collapsed).toBe(true);
			expect(presentedItem.bridgeMetadata).toBe(replacementMetadataItem.bridgeMetadata);
			expect(presentedItem.fileDiff).toBe(replacementMetadataItem.fileDiff);
			expect(presentedItem.fileDiff).not.toBe(livePresentationItem.fileDiff);
			expect(presentedItem.fileDiff.additionLines).toEqual(['export const revision = 1;']);
			expect(() =>
				bridgeCodeViewPresentationItemWithExactSource({
					presentationItem: { ...presentedItem },
					sourceItem: replacementMetadataItem,
				}),
			).not.toThrow();
		} finally {
			harness.coordinator.dispose();
		}
	});

	test('advances the applied version for an equivalent new publication after the prior source is invalidated', () => {
		// Arrange: CodeView still holds the old painted item while main has bound a new source.
		const harness = createCoordinatorHarness(3_000);
		const oldPublication = makeReviewPublication({
			itemId: 'equivalent-source-replacement',
			publicationSequence: 1,
		});
		if (oldPublication.job.payload.kind !== 'codeViewDiffItem') {
			throw new Error('Expected a Review diff publication payload.');
		}
		const oldSource = bridgeCodeViewItemFromWorkerPreparedItem(oldPublication.job.payload.item);
		if (oldSource?.type !== 'diff') throw new Error('Expected the old Review diff item.');
		const currentAppliedItem = bridgeCodeViewPresentationItemWithExactSource({
			presentationItem: { ...oldSource, annotations: [], collapsed: true, version: 4 },
			sourceItem: oldSource,
		});
		const newSource = {
			...oldSource,
			bridgeMetadata: { ...oldSource.bridgeMetadata },
			fileDiff: { ...oldSource.fileDiff },
		};
		const newPublication = makeReviewPublication({
			itemId: oldSource.id,
			publicationSequence: 2,
		});
		if (newPublication.job.payload.kind !== 'codeViewDiffItem') {
			throw new Error('Expected a new Review diff publication payload.');
		}
		const boundNewPublication = {
			...newPublication,
			job: {
				...newPublication.job,
				payload: { ...newPublication.job.payload, item: newSource },
			},
		};
		harness.coordinator.acceptPublication(boundNewPublication);
		bindPublicationItemAsFinal(harness.coordinator, boundNewPublication);
		try {
			// Act
			const preparedItem = prepareBridgeCodeViewPublicationPresentationItem({
				currentItem: currentAppliedItem,
				getCodeViewHandle: () => null,
				metadataItem: newSource,
				renderFulfillmentCoordinator: harness.coordinator,
			});

			// Assert: a prior-source record cannot make a new queued publication a no-op.
			expect(preparedItem).not.toBe(currentAppliedItem);
			expect(preparedItem.version).toBe(5);
			expect(preparedItem.collapsed).toBe(true);
			expect(preparedItem.annotations).toBe(currentAppliedItem.annotations);
		} finally {
			harness.coordinator.dispose();
		}
	});
});
