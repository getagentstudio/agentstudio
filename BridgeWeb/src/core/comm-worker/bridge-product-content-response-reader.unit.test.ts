import { describe, expect, test } from 'vitest';

import {
	createBridgeProductDeferred,
	type BridgeProductDeferred,
} from './bridge-product-async-queue.js';
import type { BridgeProductContentFrameFor } from './bridge-product-content-contracts.js';
import {
	contentAcceptedControlBody,
	contentEndControlBody,
	contentRequest,
	encodeMinimalControlFrame,
	encodeMinimalDataFrame,
} from './bridge-product-content-frame-test-support.js';
import { BridgeProductContentResponseAdmission } from './bridge-product-content-response-admission.js';
import { readBridgeProductContentResponse } from './bridge-product-content-response-reader.js';
import { openBridgeProductContentStream } from './bridge-product-content-stream-opening.js';
import { BRIDGE_PRODUCT_MAXIMUM_CONTENT_FRAME_BYTES } from './bridge-product-contract-primitives.js';
import type { BridgeProductDeadlineClock } from './bridge-product-deadline-clock.js';
import {
	bridgeProductFrameAcknowledgementRequestSchema,
	type BridgeProductFrameAcknowledgementRequest,
} from './bridge-product-frame-acknowledgement-contracts.js';
import {
	BridgeProductFrameAcknowledgementFailure,
	sendBridgeProductFrameAcknowledgement,
} from './bridge-product-frame-acknowledgement.js';
import type { BridgeProductRequestExecutor } from './bridge-product-request-executor.js';
import { productSessionBootstrap } from './bridge-product-session-authority.test-support.js';
import type { BridgeProductContentStream } from './bridge-product-transport-contract.js';

describe('Bridge product content reader late credit replies', () => {
	test.each(['before terminal', 'after terminal'] as const)(
		'preserves verified content when a queued data ACK gets unknownRead %s',
		async (ordering) => {
			const harness = createLateCreditHarness();
			const terminal = expect(harness.content.terminal).resolves.toMatchObject({
				kind: 'complete',
			});
			await harness.queueLateDataAcknowledgement();
			if (ordering === 'before terminal') {
				harness.refuseLateDataAcknowledgement();
				await harness.lateAcknowledgementSettled.promise;
			}
			harness.finishBody();
			await terminal;
			await harness.readerCompleted.promise;
			if (ordering === 'after terminal') {
				harness.refuseLateDataAcknowledgement();
				await harness.lateAcknowledgementSettled.promise;
			}
			expect(
				harness.acknowledgements.map((request) => request.receivedThroughContentSequence),
			).toEqual([0, 1, 2]);
		},
	);

	test('unknownRead to a data ACK leaves a missing terminal under the finite-progress deadline', async () => {
		const harness = createLateCreditHarness();
		const terminal = harness.content.terminal.catch((error: unknown): unknown => error);
		await harness.queueLateDataAcknowledgement();
		harness.refuseLateDataAcknowledgement();
		await harness.lateAcknowledgementSettled.promise;
		harness.deliverFinalData();
		await expect(harness.frames.next()).resolves.toMatchObject({
			value: { header: { contentSequence: 3 } },
		});
		// Fetch, accepted, three data frames, then the held rest-of-body read.
		await harness.clock.waitForBodyDeadlineCount(6);
		harness.clock.expireBodyDeadline();
		expect(await terminal).toMatchObject({
			name: 'BridgeProductFiniteProgressDeadlineExpired',
			retryable: true,
		});
		await harness.readerCompleted.promise;
		expect(harness.cancelled).toBe(true);
		expect(harness.acknowledgements).toHaveLength(3);
	});

	test('unknownRead to a data ACK does not accept EOF without a terminal', async () => {
		const harness = createLateCreditHarness();
		const terminal = expect(harness.content.terminal).rejects.toThrow(
			'without a complete terminal lifecycle',
		);
		await harness.queueLateDataAcknowledgement();
		harness.refuseLateDataAcknowledgement();
		await harness.lateAcknowledgementSettled.promise;
		harness.closeBody();
		await terminal;
		await harness.readerCompleted.promise;
	});

	test('unknownRead to a data ACK does not bypass terminal digest verification', async () => {
		const harness = createLateCreditHarness();
		const terminal = expect(harness.content.terminal).rejects.toThrow('digest does not match');
		await harness.queueLateDataAcknowledgement();
		harness.refuseLateDataAcknowledgement();
		await harness.lateAcknowledgementSettled.promise;
		harness.finishBody('0'.repeat(64));
		await terminal;
		await harness.readerCompleted.promise;
	});

	test('a correlated unknownRead to ACK0 remains an authority-barrier failure', async () => {
		const harness = createLateCreditHarness(404);
		await expect(harness.content.terminal).rejects.toMatchObject({
			failureCode: 'unknown_read',
			status: 404,
		});
		await harness.readerCompleted.promise;
		expect(harness.cancelled).toBe(true);
		expect(
			harness.acknowledgements.map((request) => request.receivedThroughContentSequence),
		).toEqual([0]);
	});

	test.each(['rejected', 'mismatched', 'malformed'] as const)(
		'a %s data-credit refusal remains a read failure',
		async (refusalKind) => {
			const harness = createLateCreditHarness();
			const terminal = expect(harness.content.terminal).rejects.toMatchObject({
				failureCode: refusalKind === 'rejected' ? 'rejected_status' : 'ambiguous_refusal',
			});
			await harness.queueLateDataAcknowledgement();
			harness.refuseLateDataAcknowledgement(refusalKind);
			await terminal;
			await harness.readerCompleted.promise;
			expect(harness.cancelled).toBe(true);
			expect(
				harness.acknowledgements.map((request) => request.receivedThroughContentSequence),
			).toEqual(refusalKind === 'rejected' ? [0, 1, 2] : [0, 1, 2, 2, 2]);
		},
	);
});

type LateDataRefusalKind = 'unknown' | 'rejected' | 'mismatched' | 'malformed';

interface LateCreditHarness {
	readonly acknowledgements: readonly BridgeProductFrameAcknowledgementRequest[];
	readonly cancelled: boolean;
	readonly clock: ControlledReaderDeadlineClock;
	readonly content: BridgeProductContentStream<'file.content'>;
	readonly frames: AsyncIterator<BridgeProductContentFrameFor<'file.content'>>;
	readonly lateAcknowledgementSettled: BridgeProductDeferred<void>;
	readonly readerCompleted: BridgeProductDeferred<void>;
	closeBody(): void;
	deliverFinalData(): void;
	finishBody(observedSha256?: string): void;
	queueLateDataAcknowledgement(): Promise<void>;
	refuseLateDataAcknowledgement(kind?: LateDataRefusalKind): void;
}

function createLateCreditHarness(openingStatus: number = 204): LateCreditHarness {
	const request = contentRequest();
	const bootstrap = productSessionBootstrap();
	const authority = {
		bootstrap: {
			...bootstrap,
			policy: {
				...bootstrap.policy,
				viewCreditBytes: BRIDGE_PRODUCT_MAXIMUM_CONTENT_FRAME_BYTES + 4,
			},
		},
		capabilityHeader: 'private-capability',
		open: Promise.resolve(),
	};
	const clock = new ControlledReaderDeadlineClock();
	const firstDataAcknowledgementReply = createBridgeProductDeferred<Response>();
	const lateAcknowledgementReply = createBridgeProductDeferred<Response>();
	const firstDataAcknowledgementStarted = createBridgeProductDeferred<void>();
	const lateAcknowledgementStarted =
		createBridgeProductDeferred<BridgeProductFrameAcknowledgementRequest>();
	const lateAcknowledgementSettled = createBridgeProductDeferred<void>();
	const readerCompleted = createBridgeProductDeferred<void>();
	const acknowledgements: BridgeProductFrameAcknowledgementRequest[] = [];
	let cancelled = false;
	let bodyController!: ReadableStreamDefaultController<Uint8Array>;
	const response = new Response(
		new ReadableStream<Uint8Array>({
			cancel: (): void => {
				cancelled = true;
			},
			start: (controller): void => {
				bodyController = controller;
				controller.enqueue(encodeMinimalControlFrame(0x01, 0, contentAcceptedControlBody()));
			},
		}),
	);
	const executeProductRequest: BridgeProductRequestExecutor = async (route, requestInit) => {
		if (route === 'content') return response;
		if (!(requestInit.body instanceof ArrayBuffer))
			throw new Error('Expected a binary ACK request.');
		const acknowledgement = bridgeProductFrameAcknowledgementRequestSchema.parse(
			JSON.parse(new TextDecoder().decode(requestInit.body)),
		);
		acknowledgements.push(acknowledgement);
		if (acknowledgement.receivedThroughContentSequence === 0) {
			if (openingStatus === 404) return unknownReadResponse(acknowledgement);
			return new Response(null, { status: openingStatus });
		}
		if (acknowledgement.receivedThroughContentSequence === 1) {
			firstDataAcknowledgementStarted.resolve();
			return await firstDataAcknowledgementReply.promise;
		}
		lateAcknowledgementStarted.resolve(acknowledgement);
		// Each ambiguous-reply retry needs a fresh response body.
		return (await lateAcknowledgementReply.promise).clone();
	};
	const content = openBridgeProductContentStream({
		abortSignal: new AbortController().signal,
		request,
		readResponse: async (opening): Promise<void> => {
			await readBridgeProductContentResponse({
				authority,
				clock,
				executeProductRequest,
				opening,
				responseAdmission: new BridgeProductContentResponseAdmission(),
				acknowledgeReceivedThrough: async (
					_request,
					receivedThroughContentSequence,
				): Promise<void> => {
					try {
						await sendBridgeProductFrameAcknowledgement({
							capabilityHeader: authority.capabilityHeader,
							deadlineClock: clock,
							executeProductRequest,
							request: {
								contentRequestId: request.contentRequestId,
								kind: 'content.acknowledge',
								leaseId: request.leaseId,
								paneSessionId: request.paneSessionId,
								receivedThroughContentSequence,
								wireVersion: request.wireVersion,
								workerInstanceId: request.workerInstanceId,
							},
							timeoutMilliseconds: 4_000,
						});
					} catch (error) {
						if (receivedThroughContentSequence === 2) {
							expect(error).toBeInstanceOf(BridgeProductFrameAcknowledgementFailure);
							lateAcknowledgementSettled.resolve();
						}
						throw error;
					}
				},
			});
			readerCompleted.resolve();
		},
	});
	const frames = content.frames[Symbol.asyncIterator]();
	const deliverFinalData = (): void => {
		bodyController.enqueue(encodeMinimalDataFrame(3, 2, Uint8Array.from([99])));
	};
	return {
		acknowledgements,
		clock,
		content,
		frames,
		lateAcknowledgementSettled,
		readerCompleted,
		deliverFinalData,
		get cancelled(): boolean {
			return cancelled;
		},
		queueLateDataAcknowledgement: async (): Promise<void> => {
			await expect(frames.next()).resolves.toMatchObject({
				value: { header: { kind: 'content.accepted' } },
			});
			bodyController.enqueue(encodeMinimalDataFrame(1, 0, Uint8Array.from([97])));
			await firstDataAcknowledgementStarted.promise;
			bodyController.enqueue(encodeMinimalDataFrame(2, 1, Uint8Array.from([98])));
			await frames.next();
			await expect(frames.next()).resolves.toMatchObject({
				value: { header: { contentSequence: 2 } },
			});
			firstDataAcknowledgementReply.resolve(new Response(null, { status: 204 }));
			await lateAcknowledgementStarted.promise;
		},
		refuseLateDataAcknowledgement: (kind: LateDataRefusalKind = 'unknown'): void => {
			const acknowledgement = acknowledgements.at(-1);
			if (acknowledgement === undefined) throw new Error('Expected a queued data ACK.');
			const refusal =
				kind === 'rejected'
					? new Response(null, { status: 409 })
					: kind === 'malformed'
						? new Response('{}', { status: 404 })
						: unknownReadResponse(
								kind === 'mismatched'
									? { ...acknowledgement, leaseId: 'foreign-lease' }
									: acknowledgement,
							);
			lateAcknowledgementReply.resolve(refusal);
		},
		finishBody: (observedSha256: string = contentEndControlBody().observedSha256): void => {
			// Final data arriving after native ended must not restart the credit drain.
			deliverFinalData();
			bodyController.enqueue(
				encodeMinimalControlFrame(0x03, 4, { ...contentEndControlBody(), observedSha256 }),
			);
			bodyController.close();
		},
		closeBody: (): void => bodyController.close(),
	};
}

function unknownReadResponse(request: BridgeProductFrameAcknowledgementRequest): Response {
	return new Response(
		JSON.stringify({ ...request, kind: 'content.acknowledgementRefused', reason: 'unknownRead' }),
		{ status: 404 },
	);
}

class ControlledReaderDeadlineClock implements BridgeProductDeadlineClock {
	readonly #bodyDeadlines: Array<{ active: boolean; expire: () => void }> = [];
	readonly #bodyDeadlineWaiters: Array<{ count: number; resolve: () => void }> = [];

	schedule(delayMilliseconds: number, onDeadline: () => void): () => void {
		const deadline = { active: true, expire: onDeadline };
		if (delayMilliseconds === 5_000) {
			this.#bodyDeadlines.push(deadline);
			for (const waiter of this.#bodyDeadlineWaiters) {
				if (this.#bodyDeadlines.length >= waiter.count) waiter.resolve();
			}
		}
		return (): void => {
			deadline.active = false;
		};
	}

	waitForBodyDeadlineCount(count: number): Promise<void> {
		if (this.#bodyDeadlines.length >= count) return Promise.resolve();
		return new Promise((resolve): void => {
			this.#bodyDeadlineWaiters.push({ count, resolve });
		});
	}

	expireBodyDeadline(): void {
		const deadline = this.#bodyDeadlines.find((candidate) => candidate.active);
		if (deadline === undefined) throw new Error('Expected an armed rest-of-body deadline.');
		deadline.active = false;
		deadline.expire();
	}
}
