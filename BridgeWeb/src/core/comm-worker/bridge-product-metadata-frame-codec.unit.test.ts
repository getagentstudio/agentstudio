import { describe, expect, test } from 'vitest';

import invalidProductSessionCorpus from '../../test-fixtures/bridge-contract-fixtures/invalid/bridge-product-session-corpus.json' with { type: 'json' };
import validProductSessionCorpus from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-session-corpus.json' with { type: 'json' };
import { BRIDGE_PRODUCT_MAXIMUM_METADATA_FRAME_BYTES } from './bridge-product-contract-primitives.js';
import {
	BridgeProductMetadataFrameDecoder,
	encodeBridgeProductMetadataFrame,
} from './bridge-product-metadata-frame-codec.js';
import { bridgeProductMetadataFrameSchema } from './bridge-product-session-contracts.js';

describe('Bridge product metadata frame decoder', () => {
	test('rejects a configured ceiling above the locked logical-frame maximum', () => {
		expect(
			() => new BridgeProductMetadataFrameDecoder(BRIDGE_PRODUCT_MAXIMUM_METADATA_FRAME_BYTES + 1),
		).toThrow(/frame ceiling/iu);
	});

	test('admits only the length prefix from a hostile multi-megabyte chunk', () => {
		const hostileTailByteCount = 8 * 1024 * 1024;
		const hostileChunk = new Uint8Array(4 + hostileTailByteCount);
		new DataView(hostileChunk.buffer).setUint32(
			0,
			BRIDGE_PRODUCT_MAXIMUM_METADATA_FRAME_BYTES + 1,
			false,
		);
		hostileChunk.fill(0xa5, 4);
		const decoder = new BridgeProductMetadataFrameDecoder();

		expect(() => decoder.push(hostileChunk)).toThrow(/length/iu);
		expect(decoder.diagnostics).toEqual({
			consumedByteCount: 4,
			copiedByteCount: 4,
			discardedTailByteCount: hostileChunk.byteLength - 4,
			emittedFrameCount: 0,
			failureCode: 'frame_length_exceeds_ceiling',
			peakRetainedByteCount: 4,
			receivedByteCount: hostileChunk.byteLength,
			retainedByteCount: 0,
			state: 'poisoned',
		});
	});

	test('decodes fragmented and concatenated frames with bounded owned storage', () => {
		const frame = bridgeProductMetadataFrameSchema.parse(
			validProductSessionCorpus.metadataFrames[0],
		);
		const encodedFrame = encodeBridgeProductMetadataFrame(frame);
		const concatenatedFrames = concatenateBytes(encodedFrame, encodedFrame);
		const concatenatedDecoder = new BridgeProductMetadataFrameDecoder();

		expect(concatenatedDecoder.push(concatenatedFrames)).toEqual([frame, frame]);
		concatenatedDecoder.finish();
		expect(concatenatedDecoder.diagnostics.emittedFrameCount).toBe(2);
		expect(concatenatedDecoder.diagnostics.peakRetainedByteCount).toBe(encodedFrame.byteLength);

		const fragmentedDecoder = new BridgeProductMetadataFrameDecoder();
		let decodedFrames = 0;
		for (let offset = 0; offset < encodedFrame.byteLength; offset += 1) {
			decodedFrames += fragmentedDecoder.push(encodedFrame.subarray(offset, offset + 1)).length;
		}
		fragmentedDecoder.finish();

		expect(decodedFrames).toBe(1);
		expect(fragmentedDecoder.diagnostics).toMatchObject({
			consumedByteCount: encodedFrame.byteLength,
			copiedByteCount: encodedFrame.byteLength,
			discardedTailByteCount: 0,
			emittedFrameCount: 1,
			failureCode: null,
			peakRetainedByteCount: encodedFrame.byteLength,
			receivedByteCount: encodedFrame.byteLength,
			retainedByteCount: 0,
			state: 'finished',
		});
		const finishedDiagnostics = fragmentedDecoder.diagnostics;
		fragmentedDecoder.finish();
		expect(Object.isFrozen(finishedDiagnostics)).toBe(true);
		expect(fragmentedDecoder.diagnostics).toEqual(finishedDiagnostics);
		expect(() => fragmentedDecoder.push(encodedFrame)).toThrow(/finished/iu);
		expect(fragmentedDecoder.diagnostics).toEqual(finishedDiagnostics);
	});

	test('round-trips the pane presentation corpus through the framed metadata codec', () => {
		const frames = validProductSessionCorpus.metadataFrames
			.filter((frame) => frame.kind === 'pane.presentation')
			.map((frame) => bridgeProductMetadataFrameSchema.parse(frame));
		const wireBytes = concatenateBytes(...frames.map(encodeBridgeProductMetadataFrame));
		const decoder = new BridgeProductMetadataFrameDecoder();

		expect(decoder.push(wireBytes)).toEqual(frames);
		decoder.finish();
		expect(frames).toHaveLength(4);
		expect(frames.every((frame) => !('workerEpoch' in frame))).toBe(true);
		expect(frames.every((frame) => !('workerDerivationEpoch' in frame))).toBe(true);
		expect(decoder.diagnostics).toMatchObject({
			emittedFrameCount: 4,
			failureCode: null,
			state: 'finished',
		});
	});

	test('round-trips strict File and Review Comment view batches through the framed metadata codec', () => {
		const emptyBegin = validProductSessionCorpus.transportV2.batchFrames.find(
			(frame) => frame.kind === 'subscription.batchBegin' && frame.partCount === 0,
		);
		const emptyComplete = validProductSessionCorpus.transportV2.batchFrames.find(
			(frame) =>
				frame.kind === 'subscription.batchComplete' && frame.batchId === emptyBegin?.batchId,
		);
		if (emptyBegin === undefined || emptyComplete === undefined)
			throw new Error('Empty batch fixture missing.');
		const frames = (['file.annotations', 'review.annotations'] as const).flatMap(
			(subscriptionKind, index) => {
				const scope = { kind: 'comment', sessionIds: [], worktreeId: 'worktree-1' } as const;
				const subscriptionId = `${subscriptionKind}-subscription`;
				const batchId = `${subscriptionKind}-batch`;
				return [
					bridgeProductMetadataFrameSchema.parse({
						...emptyBegin,
						batchId,
						baseRevision: 0,
						handle: `${subscriptionKind}-handle`,
						incarnation: `${subscriptionKind}-incarnation`,
						mode: 'snapshot',
						snapshotCause: 'open',
						publicationId: undefined,
						scope,
						streamSequence: index * 2 + 1,
						subscriptionId,
						subscriptionKind,
						targetRevision: 1,
					}),
					bridgeProductMetadataFrameSchema.parse({
						...emptyComplete,
						batchId,
						coveredScope: scope,
						handle: `${subscriptionKind}-handle`,
						incarnation: `${subscriptionKind}-incarnation`,
						streamSequence: index * 2 + 2,
						subscriptionId,
						subscriptionKind,
					}),
				];
			},
		);
		const decoder = new BridgeProductMetadataFrameDecoder();
		expect(decoder.push(concatenateBytes(...frames.map(encodeBridgeProductMetadataFrame)))).toEqual(
			frames,
		);
		decoder.finish();
		expect(decoder.diagnostics).toMatchObject({
			emittedFrameCount: 4,
			failureCode: null,
			state: 'finished',
		});
		for (const frame of frames) {
			if (frame.kind !== 'subscription.batchBegin') continue;
			expect(
				bridgeProductMetadataFrameSchema.safeParse({
					...frame,
					scope: { kind: 'comment', sessionIds: [] },
				}).success,
			).toBe(false);
		}
	});

	test('rejects the hostile pane presentation corpus through the framed metadata codec', () => {
		const hostileCases = invalidProductSessionCorpus.cases.filter((hostileCase) =>
			hostileCase.name.startsWith('pane presentation'),
		);

		expect(hostileCases).toHaveLength(7);
		for (const hostileCase of hostileCases) {
			const decoder = new BridgeProductMetadataFrameDecoder();

			expect(
				() => decoder.push(encodeRawMetadataFrame(JSON.stringify(hostileCase.value))),
				hostileCase.name,
			).toThrow(/closed contract/iu);
			expect(decoder.diagnostics).toMatchObject({
				emittedFrameCount: 0,
				failureCode: 'frame_decode_invalid',
				state: 'poisoned',
			});
		}
	});

	test('interleaves independent Review and File lifecycle epochs on one physical stream', () => {
		const accepted = validProductSessionCorpus.metadataFrames.filter(
			(frame) => frame.kind === 'subscription.accepted',
		);
		const review = accepted.find((frame) => frame.subscriptionKind === 'review.metadata');
		const fileEpochTwo = accepted.find(
			(frame) => frame.subscriptionKind === 'file.metadata' && frame.workerDerivationEpoch === 2,
		);
		const fileEpochThree = accepted.find(
			(frame) => frame.subscriptionKind === 'file.metadata' && frame.workerDerivationEpoch === 3,
		);
		const fileEnd = validProductSessionCorpus.metadataFrames.find(
			(frame) => frame.kind === 'subscription.end' && frame.subscriptionKind === 'file.metadata',
		);
		if (
			review === undefined ||
			fileEpochTwo === undefined ||
			fileEpochThree === undefined ||
			fileEnd === undefined
		) {
			throw new Error('Independent epoch fixtures missing.');
		}
		const frames = [review, fileEpochTwo, fileEpochThree, fileEnd].map((frame, index) =>
			bridgeProductMetadataFrameSchema.parse({ ...frame, streamSequence: index + 1 }),
		);
		const decoder = new BridgeProductMetadataFrameDecoder();
		expect(decoder.push(concatenateBytes(...frames.map(encodeBridgeProductMetadataFrame)))).toEqual(
			frames,
		);
		decoder.finish();
		expect(frames.map((frame) => frame.streamSequence)).toEqual([1, 2, 3, 4]);
		expect(
			frames.map((frame) =>
				'workerDerivationEpoch' in frame ? frame.workerDerivationEpoch : null,
			),
		).toEqual([7, 2, 3, 2]);
		expect(frames.every((frame) => !('surface' in frame))).toBe(true);
	});

	test('poisons atomically on a bad tail and clears truncated storage at finish', () => {
		const frame = bridgeProductMetadataFrameSchema.parse(
			validProductSessionCorpus.metadataFrames[0],
		);
		const encodedFrame = encodeBridgeProductMetadataFrame(frame);
		const hostileTail = new Uint8Array(4 + 8 * 1024 * 1024);
		new DataView(hostileTail.buffer).setUint32(
			0,
			BRIDGE_PRODUCT_MAXIMUM_METADATA_FRAME_BYTES + 1,
			false,
		);
		const atomicChunk = concatenateBytes(encodedFrame, hostileTail);
		const atomicDecoder = new BridgeProductMetadataFrameDecoder();

		expect(() => atomicDecoder.push(atomicChunk)).toThrow(/length/iu);
		expect(atomicDecoder.diagnostics).toMatchObject({
			discardedTailByteCount: hostileTail.byteLength - 4,
			emittedFrameCount: 0,
			failureCode: 'frame_length_exceeds_ceiling',
			retainedByteCount: 0,
			state: 'poisoned',
		});

		const truncatedDecoder = new BridgeProductMetadataFrameDecoder();
		expect(truncatedDecoder.push(encodedFrame.subarray(0, encodedFrame.byteLength - 1))).toEqual(
			[],
		);
		expect(() => truncatedDecoder.finish()).toThrow(/truncated/iu);
		expect(truncatedDecoder.diagnostics).toMatchObject({
			discardedTailByteCount: encodedFrame.byteLength - 1,
			failureCode: 'truncated_frame',
			retainedByteCount: 0,
			state: 'poisoned',
		});
		expect(() => truncatedDecoder.push(encodedFrame)).toThrow(/poisoned/iu);
	});

	test('owns staged bytes across caller mutation and detachment', () => {
		const frame = bridgeProductMetadataFrameSchema.parse(
			validProductSessionCorpus.metadataFrames[0],
		);
		const encodedFrame = encodeBridgeProductMetadataFrame(frame);
		const stagedBytes = encodedFrame.slice(0, encodedFrame.byteLength - 1);
		const finalByte = encodedFrame.slice(-1);
		const decoder = new BridgeProductMetadataFrameDecoder();

		expect(decoder.push(stagedBytes)).toEqual([]);
		stagedBytes.fill(0xff);
		structuredClone(stagedBytes, { transfer: [stagedBytes.buffer] });
		expect(decoder.push(finalByte)).toEqual([frame]);
		decoder.finish();

		expect(stagedBytes.byteLength).toBe(0);
	});

	test('rejects duplicate discriminant and worker derivation epoch members before schema decoding', () => {
		const frame = {
			cursor: null,
			interestRevision: 0,
			interestSha256: '1a71797cab8ed23c72233b7706b166a33049e4e87dfbc55b9e252f9c1843eca6',
			kind: 'subscription.accepted',
			metadataStreamId: 'metadata-stream-1',
			paneSessionId: 'pane-session-1',
			sourceGeneration: 7,
			streamSequence: 1,
			subscriptionId: 'review-subscription-1',
			subscriptionKind: 'review.metadata',
			subscriptionSequence: 0,
			wireVersion: 2,
			workerDerivationEpoch: 7,
			workerInstanceId: 'worker-instance-1',
		} as const;
		const canonicalJSON = JSON.stringify(frame);
		const duplicateBodies = [
			canonicalJSON.replace(
				'"kind":"subscription.accepted"',
				'"kind":"subscription.end","kind":"subscription.accepted"',
			),
			canonicalJSON.replace(
				'"workerDerivationEpoch":7',
				'"workerDerivationEpoch":999,"workerDerivationEpoch":7',
			),
			canonicalJSON.replace(
				'"kind":"subscription.accepted"',
				'"kind":"subscription.end","\\u006bind":"subscription.accepted"',
			),
		];

		for (const duplicateBody of duplicateBodies) {
			const decoder = new BridgeProductMetadataFrameDecoder();
			expect(() => decoder.push(encodeRawMetadataFrame(duplicateBody))).toThrow(/invalid|strict/iu);
			expect(decoder.diagnostics).toMatchObject({
				emittedFrameCount: 0,
				failureCode: 'frame_decode_invalid',
				retainedByteCount: 0,
				state: 'poisoned',
			});
		}
	});
});

function encodeRawMetadataFrame(rawJSON: string): Uint8Array<ArrayBuffer> {
	const body = new TextEncoder().encode(rawJSON);
	const frame = new Uint8Array(4 + body.byteLength);
	new DataView(frame.buffer).setUint32(0, body.byteLength, false);
	frame.set(body, 4);
	return frame;
}

function concatenateBytes(...parts: readonly Uint8Array[]): Uint8Array<ArrayBuffer> {
	const result = new Uint8Array(parts.reduce((total, part) => total + part.byteLength, 0));
	let offset = 0;
	for (const part of parts) {
		result.set(part, offset);
		offset += part.byteLength;
	}
	return result;
}
