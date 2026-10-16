import { describe, expect, test } from 'vitest';

import { encodeBridgeProductMetadataFrame } from '../../src/core/comm-worker/bridge-product-metadata-frame-codec.js';
import {
	bridgeProductMetadataFrameSchema,
	type BridgeProductMetadataFrame,
} from '../../src/core/comm-worker/bridge-product-session-contracts.js';
import sessionCorpus from '../../src/test-fixtures/bridge-contract-fixtures/valid/bridge-product-session-corpus.json' with { type: 'json' };
import { BridgeVerifierMetadataFrames } from './product-file-session-metadata-frames.js';

const currentSubscriptionId = 'file-subscription-current';
const unexpectedAdditionalReadMessage =
	'controlled reader observed an additional read after terminal';

describe('Bridge verifier product File metadata frames', () => {
	test('observes every sealed batch part before returning its complete frame', async () => {
		const batchFrames = sessionCorpus.transportV2.batchFrames.map((frame) =>
			bridgeProductMetadataFrameSchema.parse(frame),
		);
		const observedFrames: BridgeProductMetadataFrame[] = [];
		const reader = readerThatFailsAfter(...batchFrames);
		const frames = new BridgeVerifierMetadataFrames(
			reader,
			async (frame): Promise<void> => {
				observedFrames.push(frame);
			},
			currentSubscriptionId,
		);

		try {
			const complete = await frames.waitFor((frame) => frame.kind === 'subscription.batchComplete');
			expect(complete.kind).toBe('subscription.batchComplete');
			expect(observedFrames).toEqual(batchFrames);
		} finally {
			await reader.cancel().catch((): void => {});
		}
	});

	test.each(['subscription.reset', 'subscription.end', 'subscription.cancelled'] as const)(
		'rejects unexpected %s for the current File subscription',
		async (terminalKind) => {
			const terminal = subscriptionTerminalFrame(terminalKind, currentSubscriptionId, 1);
			const observedFrames: BridgeProductMetadataFrame[] = [];
			const reader = readerThatFailsAfter(terminal);
			const frames = new BridgeVerifierMetadataFrames(
				reader,
				async (frame): Promise<void> => {
					observedFrames.push(frame);
				},
				currentSubscriptionId,
			);

			try {
				await expect(
					frames.waitFor((frame) => frame.kind === 'subscription.batchComplete'),
				).rejects.toThrow(new RegExp(`current File metadata subscription.*${terminalKind}`, 'iu'));
				expect(observedFrames).toEqual([terminal]);
			} finally {
				await reader.cancel().catch((): void => {});
			}
		},
	);

	test('rejects metadataStream.error without reading beyond its terminal frame', async () => {
		const terminal = metadataStreamErrorFrame(1);
		const observedFrames: BridgeProductMetadataFrame[] = [];
		const reader = readerThatFailsAfter(terminal);
		const frames = new BridgeVerifierMetadataFrames(
			reader,
			async (frame): Promise<void> => {
				observedFrames.push(frame);
			},
			currentSubscriptionId,
		);

		try {
			await expect(
				frames.waitFor((frame) => frame.kind === 'subscription.batchComplete'),
			).rejects.toThrow(/metadata stream.*internal/iu);
			expect(observedFrames).toEqual([terminal]);
		} finally {
			await reader.cancel().catch((): void => {});
		}
	});

	test('returns an explicitly awaited cancellation for the current subscription', async () => {
		const cancellation = subscriptionTerminalFrame(
			'subscription.cancelled',
			currentSubscriptionId,
			1,
		);
		const observedFrames: BridgeProductMetadataFrame[] = [];
		const reader = finiteReader(cancellation);
		const frames = new BridgeVerifierMetadataFrames(
			reader,
			async (frame): Promise<void> => {
				observedFrames.push(frame);
			},
			currentSubscriptionId,
		);

		try {
			const matched = await frames.waitFor(
				(frame) =>
					frame.kind === 'subscription.cancelled' && frame.subscriptionId === currentSubscriptionId,
			);

			expect(matched).toEqual(cancellation);
			expect(observedFrames).toEqual([cancellation]);
		} finally {
			await reader.cancel().catch((): void => {});
		}
	});

	test('ignores another subscription terminal while preserving observation order', async () => {
		const unrelatedTerminal = subscriptionTerminalFrame(
			'subscription.end',
			'file-subscription-unrelated',
			1,
		);
		const currentCancellation = subscriptionTerminalFrame(
			'subscription.cancelled',
			currentSubscriptionId,
			2,
		);
		const observedFrames: BridgeProductMetadataFrame[] = [];
		const reader = finiteReader(unrelatedTerminal, currentCancellation);
		const frames = new BridgeVerifierMetadataFrames(
			reader,
			async (frame): Promise<void> => {
				observedFrames.push(frame);
			},
			currentSubscriptionId,
		);

		try {
			const matched = await frames.waitFor(
				(frame) =>
					frame.kind === 'subscription.cancelled' && frame.subscriptionId === currentSubscriptionId,
			);

			expect(matched).toEqual(currentCancellation);
			expect(observedFrames).toEqual([unrelatedTerminal, currentCancellation]);
		} finally {
			await reader.cancel().catch((): void => {});
		}
	});

	test('does not let a later matching cancellation bypass an earlier current reset', async () => {
		const currentReset = subscriptionTerminalFrame('subscription.reset', currentSubscriptionId, 1);
		const currentCancellation = subscriptionTerminalFrame(
			'subscription.cancelled',
			currentSubscriptionId,
			2,
		);
		const observedFrames: BridgeProductMetadataFrame[] = [];
		const reader = finiteReader(currentReset, currentCancellation);
		const frames = new BridgeVerifierMetadataFrames(
			reader,
			async (frame): Promise<void> => {
				observedFrames.push(frame);
			},
			currentSubscriptionId,
		);

		try {
			await expect(
				frames.waitFor(
					(frame) =>
						frame.kind === 'subscription.cancelled' &&
						frame.subscriptionId === currentSubscriptionId,
				),
			).rejects.toThrow(/current File metadata subscription.*subscription.reset/iu);
			expect(observedFrames).toEqual([currentReset, currentCancellation]);
		} finally {
			await reader.cancel().catch((): void => {});
		}
	});
});

function subscriptionTerminalFrame(
	kind: 'subscription.cancelled' | 'subscription.end' | 'subscription.reset',
	subscriptionId: string,
	streamSequence: number,
): BridgeProductMetadataFrame {
	return bridgeProductMetadataFrameSchema.parse({
		kind,
		metadataStreamId: 'metadata-stream-file-terminal',
		paneSessionId: 'pane-session-file-terminal',
		streamSequence,
		subscriptionId,
		subscriptionKind: 'file.metadata',
		subscriptionSequence: streamSequence,
		wireVersion: 2,
		workerDerivationEpoch: 0,
		workerInstanceId: 'worker-instance-file-terminal',
		...(kind === 'subscription.reset' ? { reason: 'snapshot_required' } : {}),
	});
}

function metadataStreamErrorFrame(streamSequence: number): BridgeProductMetadataFrame {
	return bridgeProductMetadataFrameSchema.parse({
		code: 'internal',
		kind: 'metadataStream.error',
		metadataStreamId: 'metadata-stream-file-terminal',
		paneSessionId: 'pane-session-file-terminal',
		retryable: false,
		safeMessage: null,
		streamSequence,
		wireVersion: 2,
		workerInstanceId: 'worker-instance-file-terminal',
	});
}

function readerThatFailsAfter(
	...frames: readonly BridgeProductMetadataFrame[]
): ReadableStreamDefaultReader<Uint8Array> {
	let readIndex = 0;
	return new ReadableStream<Uint8Array>(
		{
			pull(controller): void {
				if (readIndex === 0) {
					readIndex += 1;
					controller.enqueue(encodedFrames(frames));
					return;
				}
				controller.error(new Error(unexpectedAdditionalReadMessage));
			},
		},
		{ highWaterMark: 0 },
	).getReader();
}

function finiteReader(
	...frames: readonly BridgeProductMetadataFrame[]
): ReadableStreamDefaultReader<Uint8Array> {
	return new ReadableStream<Uint8Array>(
		{
			pull(controller): void {
				controller.enqueue(encodedFrames(frames));
				controller.close();
			},
		},
		{ highWaterMark: 0 },
	).getReader();
}

function encodedFrames(frames: readonly BridgeProductMetadataFrame[]): Uint8Array {
	const encoded = frames.map(encodeBridgeProductMetadataFrame);
	const byteLength = encoded.reduce((total, frame) => total + frame.byteLength, 0);
	const bytes = new Uint8Array(byteLength);
	let offset = 0;
	for (const frame of encoded) {
		bytes.set(frame, offset);
		offset += frame.byteLength;
	}
	return bytes;
}
