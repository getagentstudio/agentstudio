import { describe, expect, test } from 'vitest';

import { createBridgeMainRenderSnapshotStore } from './bridge-main-render-snapshot-store.js';
import {
	BRIDGE_WORKER_WIRE_VERSION,
	bridgeWorkerReviewDisplayPatchEventSchema,
	type BridgeWorkerReviewDisplayPatch,
} from './bridge-worker-contracts.js';
import { bridgeWorkerReviewSourceContext } from './bridge-worker-review-display.test-support.js';

function sourcePatch(packageId: string): BridgeWorkerReviewDisplayPatch {
	return {
		operation: 'upsert',
		payload: {
			...bridgeWorkerReviewSourceContext(packageId),
			metadataSourceId: `source-${packageId}`,
			metadataWindowIdentity: `window-${packageId}`,
			packageId,
			reviewGeneration: 1,
			revision: 1,
			status: 'ready',
			summary: {
				additions: 1,
				deletions: 0,
				filesChanged: 1,
				hiddenFileCount: 0,
				visibleFileCount: 1,
			},
			totalItemCount: 1,
			totalTreeRowCount: 1,
		},
		slice: 'reviewSource',
	};
}

describe('Review empty-ready display replacement', () => {
	test('replaces A and its rows with an empty ready publication, then accepts B', () => {
		const store = createBridgeMainRenderSnapshotStore();
		const publish = (
			projectionRevision: number,
			patches: readonly BridgeWorkerReviewDisplayPatch[],
		): void => {
			store.applyReviewDisplayPatchEvent(
				bridgeWorkerReviewDisplayPatchEventSchema.parse({
					direction: 'serverWorkerToMain',
					epoch: 1,
					kind: 'reviewDisplayPatch',
					patches,
					projectionRevision,
					reviewPublicationIdentity: null,
					sequence: projectionRevision,
					surface: 'review',
					transferDescriptors: [],
					wireVersion: BRIDGE_WORKER_WIRE_VERSION,
				}),
			);
		};
		publish(1, [
			sourcePatch('package-a'),
			{
				operation: 'batch',
				payload: {
					reset: true,
					windows: [
						{
							rows: [
								{
									depth: 0,
									isDirectory: false,
									itemId: 'item-a',
									path: 'a.swift',
									rowId: 'item-a',
								},
							],
							startIndex: 0,
						},
					],
				},
				slice: 'reviewTree',
			},
		]);
		expect(store.getSnapshot().reviewTreeRowsByIndex).toHaveLength(1);

		publish(2, [
			{
				operation: 'replace',
				payload: { kind: 'readyEmpty', status: 'readyEmpty' },
				slice: 'reviewSource',
			},
			{ operation: 'reset', slice: 'reviewItem' },
			{ operation: 'reset', slice: 'reviewTree' },
		]);
		expect(store.getSnapshot().reviewSourceSlice).toEqual({
			kind: 'readyEmpty',
			status: 'readyEmpty',
		});
		expect(store.getSnapshot().reviewTreeRowsByIndex).toEqual([]);
		expect(store.getSnapshot().reviewItemIdsByIndex).toEqual([]);

		publish(3, [sourcePatch('package-b')]);
		expect(store.getSnapshot().reviewSourceSlice).toMatchObject({ packageId: 'package-b' });
		expect(store.getSnapshot().reviewTreeRowsByIndex).toEqual([]);
	});
});
