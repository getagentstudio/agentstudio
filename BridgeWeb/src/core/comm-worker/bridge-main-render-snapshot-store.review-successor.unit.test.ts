import { describe, expect, test } from 'vitest';

import { createBridgeMainRenderSnapshotStore } from './bridge-main-render-snapshot-store.js';
import {
	makeBridgeMainCodeViewItem,
	makeReviewDisplayPatchEvent,
} from './bridge-main-render-snapshot-store.test-support.js';

describe('Bridge main render snapshot store Review successor recovery', () => {
	test('clears a replacement marker when a Review successor omits the old item', () => {
		const store = createBridgeMainRenderSnapshotStore({
			onReviewPaintedCopyReleased: (): boolean => true,
		});
		const initialEvent = makeReviewDisplayPatchEvent();
		const initialSourcePatch = initialEvent.patches[0];
		const initialItemPatch = initialEvent.patches[1];
		const initialTreePatch = initialEvent.patches[2];
		if (
			initialSourcePatch?.slice !== 'reviewSource' ||
			initialSourcePatch.operation !== 'upsert' ||
			initialItemPatch?.slice !== 'reviewItem' ||
			initialItemPatch.operation !== 'batch' ||
			initialTreePatch?.slice !== 'reviewTree' ||
			initialTreePatch.operation !== 'batch'
		) {
			throw new Error('expected Review fixture source, item, and tree patches');
		}
		const initialPublicationIdentity = initialEvent.reviewPublicationIdentity;
		if (initialPublicationIdentity === null) {
			throw new Error('expected Review fixture publication identity');
		}
		const initialIdentity = {
			generation: initialPublicationIdentity.reviewGeneration,
			packageId: initialPublicationIdentity.packageId,
			publicationId: initialPublicationIdentity.publicationId,
			revision: initialPublicationIdentity.revision,
			sourceIdentity: initialPublicationIdentity.sourceIdentity,
		};
		const initialReadyEvent = {
			...initialEvent,
			patches: [
				{
					...initialSourcePatch,
					payload: { ...initialSourcePatch.payload, status: 'ready' as const },
				},
				initialItemPatch,
				initialTreePatch,
			],
		};

		expect(
			store.startReviewCandidate({
				disposition: { kind: 'replacement' },
				identity: initialIdentity,
			}),
		).toBe(true);
		expect(
			store.stageReviewCandidateDisplayEvent({
				event: initialReadyEvent,
				identity: initialIdentity,
			}),
		).toBe(true);
		expect(store.markReviewCandidateReady({ identity: initialIdentity, role: 'provisional' })).toBe(
			true,
		);
		expect(store.promoteReviewCandidate(initialIdentity)).toBe(true);

		const item = makeBridgeMainCodeViewItem('item-1');
		store.applySnapshotUpdate({
			codeViewItemPatches: [{ item, itemId: item.id, operation: 'upsert' }],
			workerPatches: [
				{
					itemId: item.id,
					operation: 'upsert',
					payload: { state: 'ready' },
					slice: 'contentAvailability',
				},
			],
		});
		store.setLocalSelection({ selectedItemId: item.id, source: 'user' });
		store.prepareForWorkerReplacement();
		expect(store.hasPendingReviewPaintRelease(item.id)).toBe(true);

		const successorIdentity = {
			...initialIdentity,
			publicationId: '00000000-0000-7000-8000-000000000002',
			revision: initialIdentity.revision + 1,
		};
		const successorEvent = {
			...initialReadyEvent,
			epoch: initialEvent.epoch + 1,
			projectionRevision: initialEvent.projectionRevision + 1,
			sequence: initialEvent.sequence + 1,
			reviewPublicationIdentity: {
				...initialPublicationIdentity,
				publicationId: successorIdentity.publicationId,
				revision: successorIdentity.revision,
			},
			patches: [
				{
					...initialSourcePatch,
					payload: {
						...initialSourcePatch.payload,
						metadataWindowIdentity: 'metadata-window-package-1-r12',
						revision: successorIdentity.revision,
						status: 'ready' as const,
					},
				},
				{ ...initialItemPatch, payload: { ...initialItemPatch.payload, items: [] } },
				{
					...initialTreePatch,
					payload: { ...initialTreePatch.payload, windows: [{ rows: [], startIndex: 0 }] },
				},
			],
		};

		expect(
			store.startReviewCandidate({
				disposition: { kind: 'replacement' },
				identity: successorIdentity,
			}),
		).toBe(true);
		expect(
			store.stageReviewCandidateDisplayEvent({
				event: successorEvent,
				identity: successorIdentity,
			}),
		).toBe(true);
		expect(
			store.markReviewCandidateReady({ identity: successorIdentity, role: 'provisional' }),
		).toBe(true);
		expect(store.promoteReviewCandidate(successorIdentity)).toBe(true);

		expect(store.getReviewCodeViewItemSnapshot(item.id)).toBeUndefined();
		expect(store.getReviewSelectionSnapshot()).toEqual({ selectedItemId: null, source: null });
		expect(store.hasPendingReviewPaintRelease(item.id)).toBe(false);
	});
});
