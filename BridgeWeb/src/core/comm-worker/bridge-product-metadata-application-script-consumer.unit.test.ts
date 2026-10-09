import { describe, expect, test } from 'vitest';

import { BridgeVerifierMetadataFrames } from '../../../scripts/verify-bridge-viewer-worktree-dev-server/product-file-session-metadata-frames.js';
import sessionCorpus from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-session-corpus.json' with { type: 'json' };

describe('Bridge verifier typed metadata application consumer', () => {
	test('rejects malformed and cross-kind batch data before the File predicate runs', async () => {
		const batchBegin = sessionCorpus.transportV2.batchFrames.find(
			(frame) => frame.kind === 'subscription.batchBegin',
		);
		if (batchBegin === undefined) throw new Error('Batch begin fixture missing.');
		for (const rawData of [
			{},
			{
				...batchBegin,
				scope: { kind: 'comment', sessionIds: [], worktreeId: 'worktree-1' },
				subscriptionKind: 'file.metadata',
			},
		]) {
			const body = new TextEncoder().encode(JSON.stringify(rawData));
			const frame = new Uint8Array(4 + body.byteLength);
			new DataView(frame.buffer).setUint32(0, body.byteLength, false);
			frame.set(body, 4);
			const stream = new ReadableStream<Uint8Array>({
				start(controller): void {
					controller.enqueue(frame);
					controller.close();
				},
			});
			let predicateInvocationCount = 0;
			let observationCount = 0;
			const consumer = new BridgeVerifierMetadataFrames(
				stream.getReader(),
				async (): Promise<void> => {
					observationCount += 1;
				},
				'file-subscription-1',
			);
			await expect(
				consumer.waitFor((): boolean => {
					predicateInvocationCount += 1;
					return true;
				}),
			).rejects.toThrow();
			expect(predicateInvocationCount).toBe(0);
			expect(observationCount).toBe(0);
		}
	});
});
