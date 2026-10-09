import { describe, expect, test } from 'vitest';

import {
	BridgeProductMetadataFrameDecoder,
	encodeBridgeProductMetadataFrame,
} from '../../src/core/comm-worker/bridge-product-metadata-frame-codec.js';
import {
	bridgeProductMetadataFrameSchema,
	type BridgeProductMetadataFrame,
} from '../../src/core/comm-worker/bridge-product-session-contracts.js';
import { BridgeProductViewBatchReceiver } from '../../src/core/comm-worker/bridge-product-view-batch-receiver.js';
import {
	BridgeSemanticBatchFaultTransformer,
	type BridgeSemanticBatchFaultMode,
	type BridgeSemanticBatchKind,
} from './bridge-viewer-vite-semantic-batch-fault.js';

const batchKinds = [
	'file.metadata',
	'review.metadata',
	'file.annotations',
	'review.annotations',
] as const;
const faultModes = ['drop', 'duplicate', 'reorder', 'stall'] as const;

describe('semantic metadata batch fault transform', () => {
	test.each(
		batchKinds.flatMap((subscriptionKind) =>
			faultModes.map((mode) => ({
				mode,
				subscriptionKind,
			})),
		),
	)(
		'keeps physical sequence contiguous for $subscriptionKind $mode',
		async ({ mode, subscriptionKind }) => {
			const transformer = new BridgeSemanticBatchFaultTransformer();
			transformer.arm({ mode, subscriptionKind });
			const faultApplied = transformer.waitForAppliedFault();
			const sourceFrames = makeThreePartBatch(subscriptionKind);
			const encoded = concatenateBytes(...sourceFrames.map(encodeBridgeProductMetadataFrame));
			const forwarded = [
				...transformer.push(encoded.subarray(0, 1)),
				...transformer.push(encoded.subarray(1, 9)),
				...transformer.push(encoded.subarray(9)),
			];
			const applied = await faultApplied;
			expect(applied).toMatchObject({ batchId: 'batch-1', mode, subscriptionKind });
			expect(transformer.snapshotAppliedFault()).toEqual(applied);
			if (mode === 'stall') forwarded.push(...transformer.releaseStalledPart());
			transformer.finish();
			const frames = decodeFrames(forwarded);
			expect(frames.map((frame) => frame.streamSequence)).toEqual(
				Array.from({ length: frames.length }, (_, index) => index + 1),
			);
			const partIndexes = frames.flatMap((frame) =>
				frame.kind === 'subscription.batchPart' ? [frame.partIndex] : [],
			);
			expect(partIndexes).toEqual(expectedPartIndexes(mode));
			expect(frames[0]?.kind).toBe('subscription.batchBegin');
			expect(frames.at(-1)?.kind).toBe(
				mode === 'stall' ? 'subscription.batchPart' : 'subscription.batchComplete',
			);
		},
	);

	test('keeps keepalive at the renumbered tail after dropping a part without consuming a sequence', () => {
		const transformer = new BridgeSemanticBatchFaultTransformer();
		transformer.arm({ mode: 'drop', subscriptionKind: 'file.metadata' });
		const sourceBatch = makeThreePartBatch('file.metadata', 40);
		const batchBegin = sourceBatch[0];
		const droppedPart = sourceBatch[1];
		if (
			batchBegin?.kind !== 'subscription.batchBegin' ||
			droppedPart?.kind !== 'subscription.batchPart'
		)
			throw new Error('Expected a File metadata batch begin and first part.');
		const keepalive = bridgeProductMetadataFrameSchema.parse({
			kind: 'stream.keepalive',
			metadataStreamId: batchBegin.metadataStreamId,
			paneSessionId: batchBegin.paneSessionId,
			streamSequence: droppedPart.streamSequence,
			wireVersion: batchBegin.wireVersion,
			workerInstanceId: batchBegin.workerInstanceId,
		});
		const sourceFrames = [batchBegin, droppedPart, keepalive, ...sourceBatch.slice(2)];
		const forwarded = decodeFrames(
			transformer.push(concatenateBytes(...sourceFrames.map(encodeBridgeProductMetadataFrame))),
		);
		transformer.finish();

		const forwardedKeepalive = forwarded.find((frame) => frame.kind === 'stream.keepalive');
		expect(forwardedKeepalive?.streamSequence).toBe(batchBegin.streamSequence);
		const partIndexes = forwarded.flatMap((frame) =>
			frame.kind === 'subscription.batchPart' ? [frame.partIndex] : [],
		);
		expect(partIndexes).toEqual([1, 2]);
		const keepaliveIndex = forwarded.findIndex((frame) => frame.kind === 'stream.keepalive');
		const nextDataFrame = forwarded[keepaliveIndex + 1];
		expect(nextDataFrame).toMatchObject({
			kind: 'subscription.batchPart',
			partIndex: 1,
			streamSequence: (forwardedKeepalive?.streamSequence ?? -1) + 1,
		});
		expect(forwarded.map((frame) => frame.streamSequence)).toEqual([40, 40, 41, 42, 43]);
	});

	test('a stalled part released after complete cannot install the incomplete batch', () => {
		const transformer = new BridgeSemanticBatchFaultTransformer();
		transformer.arm({ mode: 'stall', subscriptionKind: 'file.metadata' });
		const forwardedBeforeRelease = decodeFrames(
			transformer.push(
				concatenateBytes(
					...makeThreePartBatch('file.metadata').map(encodeBridgeProductMetadataFrame),
				),
			),
		);
		expect(forwardedBeforeRelease.at(-1)?.kind).toBe('subscription.batchComplete');
		const latePart = decodeFrames(transformer.releaseStalledPart());
		expect(latePart).toMatchObject([{ kind: 'subscription.batchPart', partIndex: 0 }]);
		const receiver = new BridgeProductViewBatchReceiver({
			handle: 'file.metadata-handle',
			scope: { changeFilter: { kind: 'none' }, interests: [], kind: 'file', pathScope: [] },
			scopeRevision: 1,
			subscriptionId: 'file.metadata-subscription',
			subscriptionKind: 'file.metadata',
		});
		receiver.admitDomain('default', 'file.metadata-incarnation');
		const acceptances = [...forwardedBeforeRelease, ...latePart].flatMap((frame) => {
			if (
				frame.kind !== 'subscription.batchBegin' &&
				frame.kind !== 'subscription.batchPart' &&
				frame.kind !== 'subscription.batchComplete'
			)
				return [];
			return [receiver.accept(frame)];
		});
		expect(acceptances.at(-2)).toEqual({
			kind: 'resnapshot',
			domain: 'default',
			rejection: 'incompleteBatch',
		});
		expect(acceptances.at(-1)?.kind).not.toBe('installed');
		expect(receiver.takeInstallations()).toEqual([]);
	});

	test('a conflicting duplicate changes only semantic part content', () => {
		const transformer = new BridgeSemanticBatchFaultTransformer();
		transformer.arm({
			duplicateVariant: 'conflicting',
			mode: 'duplicate',
			subscriptionKind: 'file.metadata',
		});
		const frames = decodeFrames(
			transformer.push(
				concatenateBytes(
					...makeThreePartBatch('file.metadata').map(encodeBridgeProductMetadataFrame),
				),
			),
		);
		const parts = frames.filter((frame) => frame.kind === 'subscription.batchPart');
		expect(parts[0]?.partIndex).toBe(0);
		expect(parts[1]?.partIndex).toBe(0);
		expect(parts[0]?.deliverySequence).toBe(parts[1]?.deliverySequence);
		expect(parts[0]?.part.key).not.toBe(parts[1]?.part.key);
		expect(frames.map((frame) => frame.streamSequence)).toEqual([1, 2, 3, 4, 5, 6]);
	});

	test('a non-target sibling batch passes through and one fault applies only once', () => {
		const transformer = new BridgeSemanticBatchFaultTransformer();
		transformer.arm({ mode: 'drop', subscriptionKind: 'file.metadata' });
		const siblingFrames = makeThreePartBatch('review.metadata', 1, 'sibling-batch');
		const targetFrames = makeThreePartBatch('file.metadata', 6, 'batch-1');
		const laterFrames = makeThreePartBatch('file.metadata', 11, 'batch-2');
		const frames = decodeFrames(
			transformer.push(
				concatenateBytes(
					...[...siblingFrames, ...targetFrames, ...laterFrames].map(
						encodeBridgeProductMetadataFrame,
					),
				),
			),
		);
		expect(
			frames.filter(
				(frame) => frame.kind === 'subscription.batchPart' && frame.batchId === 'sibling-batch',
			),
		).toHaveLength(3);
		expect(
			frames.filter(
				(frame) => frame.kind === 'subscription.batchPart' && frame.batchId === 'batch-1',
			),
		).toHaveLength(2);
		expect(
			frames.filter(
				(frame) => frame.kind === 'subscription.batchPart' && frame.batchId === 'batch-2',
			),
		).toHaveLength(3);
		expect(frames.map((frame) => frame.streamSequence)).toEqual(
			Array.from({ length: frames.length }, (_, index) => index + 1),
		);
	});

	test('rejects concurrent faults and release without a held part', () => {
		const transformer = new BridgeSemanticBatchFaultTransformer();
		expect(() => transformer.releaseStalledPart()).toThrow(/No stalled/);
		transformer.arm({ mode: 'stall', subscriptionKind: 'file.metadata' });
		expect(() => transformer.arm({ mode: 'drop', subscriptionKind: 'review.metadata' })).toThrow(
			/already active/,
		);
		expect(() =>
			transformer.arm({ mode: 'drop', partIndex: -1, subscriptionKind: 'review.metadata' }),
		).toThrow();
	});
});

function makeThreePartBatch(
	subscriptionKind: BridgeSemanticBatchKind,
	firstStreamSequence = 1,
	batchId = 'batch-1',
): readonly BridgeProductMetadataFrame[] {
	const scope =
		subscriptionKind === 'file.metadata'
			? { changeFilter: { kind: 'none' }, interests: [], kind: 'file', pathScope: [] }
			: subscriptionKind === 'review.metadata'
				? { interests: [], kind: 'review' }
				: { kind: 'comment', sessionIds: [], worktreeId: 'worktree-1' };
	const identity = {
		batchId,
		domain: 'default',
		handle: `${subscriptionKind}-handle`,
		incarnation: `${subscriptionKind}-incarnation`,
		metadataStreamId: 'metadata-stream-1',
		paneSessionId: 'pane-session-1',
		scopeRevision: 1,
		subscriptionId: `${subscriptionKind}-subscription`,
		subscriptionKind,
		wireVersion: 2,
		workerInstanceId: 'worker-instance-1',
	};
	return [
		bridgeProductMetadataFrameSchema.parse({
			...identity,
			baseRevision: 0,
			kind: 'subscription.batchBegin',
			mode: 'snapshot',
			snapshotCause: 'open',
			partCount: 3,
			...(subscriptionKind === 'review.metadata'
				? { publicationId: '00000000-0000-7000-8000-000000000011' }
				: {}),
			scope,
			streamSequence: firstStreamSequence,
			targetRevision: 1,
		}),
		...[0, 1, 2].map((partIndex) =>
			bridgeProductMetadataFrameSchema.parse({
				...identity,
				deliverySequence: partIndex + 1,
				kind: 'subscription.batchPart',
				part: { key: `path/${partIndex}`, operation: 'put', revision: 1, value: { partIndex } },
				partIndex,
				streamSequence: firstStreamSequence + partIndex + 1,
			}),
		),
		bridgeProductMetadataFrameSchema.parse({
			...identity,
			coveredScope: scope,
			kind: 'subscription.batchComplete',
			streamSequence: firstStreamSequence + 4,
		}),
	];
}

function expectedPartIndexes(mode: BridgeSemanticBatchFaultMode): readonly number[] {
	switch (mode) {
		case 'drop':
			return [1, 2];
		case 'duplicate':
			return [0, 0, 1, 2];
		case 'reorder':
			return [1, 0, 2];
		case 'stall':
			return [1, 2, 0];
	}
}

function concatenateBytes(...chunks: readonly Uint8Array[]): Uint8Array {
	const joined = new Uint8Array(chunks.reduce((total, chunk) => total + chunk.byteLength, 0));
	let offset = 0;
	for (const chunk of chunks) {
		joined.set(chunk, offset);
		offset += chunk.byteLength;
	}
	return joined;
}

function decodeFrames(chunks: readonly Uint8Array[]): readonly BridgeProductMetadataFrame[] {
	const decoder = new BridgeProductMetadataFrameDecoder();
	const frames = chunks.flatMap((chunk) => decoder.push(chunk));
	decoder.finish();
	return frames;
}
