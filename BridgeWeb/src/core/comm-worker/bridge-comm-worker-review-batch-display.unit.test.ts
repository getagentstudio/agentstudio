import { describe, expect, test } from 'vitest';

import recordCorpus from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-review-batch-record-corpus.json' with { type: 'json' };
import sessionCorpus from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-session-corpus.json' with { type: 'json' };
import { bridgeCommWorkerReviewDisplayPatchesFromBatch } from './bridge-comm-worker-review-batch-display.js';
import {
	BridgeCommWorkerReviewBatchInstaller,
	type BridgeCommWorkerReviewBatchPresentation,
} from './bridge-comm-worker-review-batch-installer.js';
import { bridgeCommWorkerReviewRuntimeApplicationFromBatch } from './bridge-comm-worker-review-batch-runtime-application.js';
import { bridgeProductBatchFrameSchema } from './bridge-product-batch-wire-contracts.js';
import { bridgeProductReviewBatchRecordSchema } from './bridge-product-review-batch-record-contracts.js';

async function installedPresentation(
	recordIndexes: readonly number[],
): Promise<BridgeCommWorkerReviewBatchPresentation> {
	const records = recordIndexes.map((index) => {
		const fixture = recordCorpus.records[index];
		if (fixture === undefined) throw new Error('Review record fixture missing.');
		const value = bridgeProductReviewBatchRecordSchema.parse(fixture.record);
		return {
			key: fixture.recordKey,
			revision: value.recordKind === 'publication' ? value.revision : 1,
			value,
		};
	});
	const publication = records.find((record) => record.value.recordKind === 'publication')?.value;
	if (publication?.recordKind !== 'publication') throw new Error('Review publication missing.');
	const begin = bridgeProductBatchFrameSchema.parse({
		...sessionCorpus.transportV2.batchFrames[0],
		publicationId: publication.publicationId,
		targetRevision: publication.revision,
	});
	if (begin.kind !== 'subscription.batchBegin') throw new Error('Review begin missing.');
	const installer = new BridgeCommWorkerReviewBatchInstaller({ handle: begin.handle });
	await installer.install({ begin, records });
	if (installer.presentation === null) throw new Error('Review installation missing.');
	return installer.presentation;
}

describe('certified Review batch display projection', () => {
	test('does not settle a null package as an identityless empty publication', async () => {
		const presentation = await installedPresentation([1]);
		const patches = bridgeCommWorkerReviewDisplayPatchesFromBatch(presentation);
		expect(patches.find((patch) => patch.slice === 'reviewSource')).toBeUndefined();
		expect(patches.filter((patch) => patch.slice === 'reviewItem')).toMatchObject([
			{ payload: { items: [], reset: true } },
		]);
		expect(patches.filter((patch) => patch.slice === 'reviewTree')).toMatchObject([
			{ payload: { reset: true, windows: [{ rows: [] }] } },
		]);
	});

	test('keeps a failed desired comparison distinct from its readable displayed source', async () => {
		const presentation = await installedPresentation([0, 2]);
		const patches = bridgeCommWorkerReviewDisplayPatchesFromBatch(presentation);
		expect(patches.find((patch) => patch.slice === 'reviewSource')).toMatchObject({
			operation: 'upsert',
			payload: { packageId: 'review-package-1', status: 'stale' },
		});
		expect(patches.find((patch) => patch.slice === 'reviewItem')).toMatchObject({
			payload: { items: [{ metadata: { itemId: 'review-item-1' } }], reset: true },
		});
	});

	test('a same-handle empty publication removes the previous runtime item without a source reset', async () => {
		const previous = await installedPresentation([0, 2]);
		const presentation = await installedPresentation([1]);
		const application = bridgeCommWorkerReviewRuntimeApplicationFromBatch({
			previous,
			presentation,
			sourceEpoch: 2,
			workerDerivationEpoch: 4,
		});
		expect(application.reset).toBe(false);
		expect(application.source.rows).toEqual([]);
		expect(application.removedItemIds).toEqual(['review-item-1']);
		expect(application.sourceEpoch).toBe(2);
	});

	test('identical reseal leaves selected content unaffected while content and semantics changes do not', async () => {
		const previous = await installedPresentation([0, 2]);
		const identical = bridgeCommWorkerReviewRuntimeApplicationFromBatch({
			previous,
			presentation: previous,
			sourceEpoch: 2,
			workerDerivationEpoch: 4,
		});
		expect(identical.affectedItemIds).toEqual([]);
		expect(identical.completeContentItemIds).toEqual(['review-item-1']);

		const contentChanged = {
			...previous,
			runtimeSource: {
				...previous.runtimeSource,
				contentItems: previous.runtimeSource.contentItems.map((item) => ({
					...item,
					cacheKey: `${item.cacheKey}:changed`,
				})),
			},
		};
		expect(
			bridgeCommWorkerReviewRuntimeApplicationFromBatch({
				previous,
				presentation: contentChanged,
				sourceEpoch: 2,
				workerDerivationEpoch: 4,
			}).affectedItemIds,
		).toEqual(['review-item-1']);

		const semanticsChanged = {
			...previous,
			runtimeSource: {
				...previous.runtimeSource,
				renderSemantics: previous.runtimeSource.renderSemantics.map((item) => ({
					...item,
					language: 'typescript',
				})),
			},
		};
		expect(
			bridgeCommWorkerReviewRuntimeApplicationFromBatch({
				previous,
				presentation: semanticsChanged,
				sourceEpoch: 2,
				workerDerivationEpoch: 4,
			}).affectedItemIds,
		).toEqual(['review-item-1']);
	});
});
