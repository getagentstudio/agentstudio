import { afterEach, describe, expect, test, vi } from 'vitest';

import { BRIDGE_PRODUCT_MAXIMUM_CONCURRENT_CONTENT_RESPONSES } from './bridge-product-content-response-admission.js';
import { BRIDGE_PRODUCT_MAXIMUM_CONTENT_FRAME_BYTES } from './bridge-product-contract-primitives.js';
import { bridgeProductReviewMetadataApplicationProtocol } from './bridge-product-metadata-application-registry.js';
import {
	createContentTransportHarness,
	fileContentDescriptor,
	metadataAccepted,
} from './test-fixtures/bridge-product-transport-content.test-support.js';

afterEach(() => {
	vi.unstubAllGlobals();
});

describe('Bridge product content transport', () => {
	const oneFrameCreditBytes = BRIDGE_PRODUCT_MAXIMUM_CONTENT_FRAME_BYTES + 4;
	test('opens concurrent content outside the control sequence', async () => {
		const harness = createContentTransportHarness(3);
		const first = harness.transport.openContent(
			fileContentDescriptor('descriptor-1'),
			new AbortController().signal,
		);
		const second = harness.transport.openContent(
			fileContentDescriptor('descriptor-2'),
			new AbortController().signal,
		);

		const terminals = await Promise.all([first.terminal, second.terminal]);
		await harness.transport.call('review.markFileViewed', { itemId: 'review-item-1' });

		expect(terminals.map((terminal) => terminal.kind)).toEqual(['complete', 'complete']);
		expect(harness.server.contentRequestHeaders).toEqual([
			{ capability: 'private-capability', contentType: 'application/json' },
			{ capability: 'private-capability', contentType: 'application/json' },
		]);
		expect(harness.server.contentRequests.map((request) => request.workerDerivationEpoch)).toEqual([
			3, 3,
		]);
		expect(harness.server.controlRequests).toHaveLength(1);
		expect(harness.server.controlRequests[0]?.requestSequence).toBe(3);
	});

	test('acknowledges cumulative content receipt with its exact response identity', async () => {
		const harness = createContentTransportHarness(3);
		const content = harness.transport.openContent(
			fileContentDescriptor('descriptor-observed'),
			new AbortController().signal,
		);

		await expect(content.terminal).resolves.toMatchObject({ kind: 'complete' });

		const request = harness.server.contentRequests[0];
		if (request === undefined) throw new Error('Expected one product content request.');
		expect(harness.server.frameAcknowledgements).toEqual(
			[0].map((receivedThroughContentSequence) => ({
				contentRequestId: request.contentRequestId,
				receivedThroughContentSequence,
				kind: 'content.acknowledge',
				leaseId: request.leaseId,
				paneSessionId: request.paneSessionId,
				wireVersion: request.wireVersion,
				workerInstanceId: request.workerInstanceId,
			})),
		);
		expect(harness.server.requestRoutes).toEqual([
			'agentstudio://rpc/content',
			'agentstudio://rpc/command',
		]);
	});

	test('does not send a data ACK for a one-chunk final window', async () => {
		const harness = createContentTransportHarness();
		harness.server.gateContentBodyOnOpeningAcknowledgement = true;
		const content = harness.transport.openContent(
			fileContentDescriptor('descriptor-final-window'),
			new AbortController().signal,
		);

		await expect(content.terminal).resolves.toMatchObject({ kind: 'complete' });
		expect(
			harness.server.frameAcknowledgements.map(
				(acknowledgement) => acknowledgement.receivedThroughContentSequence,
			),
		).toEqual([0]);
		expect(harness.server.unknownReadRefusalCount).toBe(0);
	});

	test('returns cumulative data credit only when the next native reservation would block', async () => {
		const harness = createContentTransportHarness(
			0,
			undefined,
			undefined,
			undefined,
			oneFrameCreditBytes + 80,
		);
		harness.server.gateContentBodyOnOpeningAcknowledgement = true;
		harness.server.splitContentDataFrames = true;
		harness.server.gateContentTerminalOnDataAcknowledgement = true;
		const content = harness.transport.openContent(
			fileContentDescriptor('descriptor-two-part-credit-boundary'),
			new AbortController().signal,
		);

		await expect(content.terminal).resolves.toMatchObject({ kind: 'complete' });
		expect(
			harness.server.frameAcknowledgements.map(
				(acknowledgement) => acknowledgement.receivedThroughContentSequence,
			),
		).toEqual([0, 2]);
		expect(harness.server.unknownReadRefusalCount).toBe(0);
	});

	test('fails only the response whose observation is rejected', async () => {
		const harness = createContentTransportHarness();
		harness.server.leaveContentOpenAfterAcceptance = true;
		harness.server.nextAcknowledgementStatus = 409;
		const content = harness.transport.openContent(
			fileContentDescriptor('descriptor-rejected-observation'),
			new AbortController().signal,
		);
		const frameIterator = content.frames[Symbol.asyncIterator]();
		const terminalFailure = expect(content.terminal).rejects.toMatchObject({
			failureCode: 'rejected_status',
			name: 'BridgeProductFrameAcknowledgementFailure',
			status: 409,
		});

		await expect(frameIterator.next()).resolves.toMatchObject({
			done: false,
			value: { header: { contentSequence: 0, kind: 'content.accepted' } },
		});
		await terminalFailure;
		await expect(frameIterator.next()).rejects.toMatchObject({ status: 409 });
		expect(harness.server.contentReaderCancelCount).toBe(1);
		expect(harness.server.frameAcknowledgements).toHaveLength(1);
	});

	test('treats correlated unknown-read refusal during an active read as a read-local failure', async () => {
		const harness = createContentTransportHarness();
		harness.server.leaveContentOpenAfterAcceptance = true;
		harness.server.nextAcknowledgementStatus = 404;
		const content = harness.transport.openContent(
			fileContentDescriptor('descriptor-active-unknown-read'),
			new AbortController().signal,
		);

		await expect(content.terminal).rejects.toMatchObject({
			failureCode: 'unknown_read',
			status: 404,
		});
		expect(harness.server.frameAcknowledgements).toHaveLength(1);
	});

	test.each(['mismatched', 'malformed'] as const)(
		'replays the exact credit after a %s unknown-read refusal',
		async (refusalKind) => {
			const harness = createContentTransportHarness();
			harness.server.gateContentBodyOnOpeningAcknowledgement = true;
			harness.server.nextAcknowledgementStatus = 404;
			if (refusalKind === 'mismatched') harness.server.mismatchNextUnknownReadRefusal = true;
			else harness.server.malformNextUnknownReadRefusal = true;
			const content = harness.transport.openContent(
				fileContentDescriptor(`descriptor-${refusalKind}-unknown-read`),
				new AbortController().signal,
			);

			await expect(content.terminal).resolves.toMatchObject({ kind: 'complete' });
			expect(
				harness.server.frameAcknowledgements.map(
					(acknowledgement) => acknowledgement.receivedThroughContentSequence,
				),
			).toEqual([0, 0]);
		},
	);

	test('ignores a correlated unknown-read refusal for a data ACK after terminal', async () => {
		const harness = createContentTransportHarness(
			0,
			undefined,
			undefined,
			undefined,
			oneFrameCreditBytes,
		);
		harness.server.gateContentBodyOnOpeningAcknowledgement = true;
		harness.server.holdContentAcknowledgement('content-request-1', 1);
		const content = harness.transport.openContent(
			fileContentDescriptor('descriptor-late-unknown-read'),
			new AbortController().signal,
		);

		await expect(content.terminal).resolves.toMatchObject({ kind: 'complete' });
		harness.server.nextAcknowledgementStatus = 404;
		harness.server.releaseHeldContentAcknowledgement();
		expect(
			harness.server.frameAcknowledgements.map(
				(acknowledgement) => acknowledgement.receivedThroughContentSequence,
			),
		).toEqual([0, 1]);
	});

	test('replays the exact cumulative acknowledgement after a lost reply', async () => {
		const harness = createContentTransportHarness();
		harness.server.gateContentBodyOnOpeningAcknowledgement = true;
		harness.server.loseNextAcknowledgementReply = true;
		const content = harness.transport.openContent(
			fileContentDescriptor('descriptor-lost-acknowledgement'),
			new AbortController().signal,
		);

		await expect(content.terminal).resolves.toMatchObject({ kind: 'complete' });
		expect(
			harness.server.frameAcknowledgements.map(
				(acknowledgement) => acknowledgement.receivedThroughContentSequence,
			),
		).toEqual([0, 0]);
	});

	test('replays the exact cumulative acknowledgement after a proxy 502', async () => {
		const harness = createContentTransportHarness();
		harness.server.gateContentBodyOnOpeningAcknowledgement = true;
		harness.server.nextAcknowledgementStatus = 502;
		const content = harness.transport.openContent(
			fileContentDescriptor('descriptor-proxy-lost-acknowledgement'),
			new AbortController().signal,
		);

		await expect(content.terminal).resolves.toMatchObject({ kind: 'complete' });
		expect(
			harness.server.frameAcknowledgements.map(
				(acknowledgement) => acknowledgement.receivedThroughContentSequence,
			),
		).toEqual([0, 0]);
	});

	test('completes on a verified terminal without acknowledging it or waiting for a data ACK', async () => {
		const harness = createContentTransportHarness(
			0,
			undefined,
			undefined,
			undefined,
			oneFrameCreditBytes,
		);
		harness.server.gateContentBodyOnOpeningAcknowledgement = true;
		harness.server.leaveContentOpenAfterTerminal = true;
		harness.server.holdContentAcknowledgement('content-request-1', 1);
		const content = harness.transport.openContent(
			fileContentDescriptor('descriptor-coalesced-acknowledgement'),
			new AbortController().signal,
		);
		const frameIterator = content.frames[Symbol.asyncIterator]();
		for (let sequence = 0; sequence <= 2; sequence += 1) {
			// eslint-disable-next-line no-await-in-loop -- The three received frames establish one high-water.
			await expect(frameIterator.next()).resolves.toMatchObject({
				done: false,
				value: { header: { contentSequence: sequence } },
			});
		}
		try {
			await expect(content.terminal).resolves.toMatchObject({ kind: 'complete' });
			expect(
				harness.server.frameAcknowledgements.map(
					(acknowledgement) => acknowledgement.receivedThroughContentSequence,
				),
			).toEqual([0, 1]);
			expect(harness.server.contentReaderCancelCount).toBe(1);
		} finally {
			harness.server.releaseHeldContentAcknowledgement();
		}
	});

	test('keeps verified content frames readable after terminal settlement', async () => {
		const harness = createContentTransportHarness();
		const content = harness.transport.openContent(
			fileContentDescriptor('descriptor-read-after-terminal'),
			new AbortController().signal,
		);

		await expect(content.terminal).resolves.toMatchObject({ kind: 'complete' });
		const receivedKinds: string[] = [];
		for await (const frame of content.frames) receivedKinds.push(frame.header.kind);
		expect(receivedKinds).toEqual(['content.accepted', 'content.data', 'content.end']);
	});

	test('paces content independently from other content, metadata, and control', async () => {
		const harness = createContentTransportHarness();
		harness.server.leaveContentOpenAfterAcceptance = true;
		harness.server.holdContentAcknowledgement('content-request-1');
		const firstAbortController = new AbortController();
		const first = harness.transport.openContent(
			fileContentDescriptor('descriptor-held-observation'),
			firstAbortController.signal,
		);
		let didFirstSettle = false;
		void first.terminal.then(
			(): void => {
				didFirstSettle = true;
			},
			(): void => {},
		);
		await harness.server.waitForFrameAcknowledgementCount(1);
		harness.server.leaveContentOpenAfterAcceptance = false;

		const second = harness.transport.openContent(
			fileContentDescriptor('descriptor-independent-observation'),
			new AbortController().signal,
		);
		await expect(second.terminal).resolves.toMatchObject({ kind: 'complete' });
		harness.transport.subscribe(bridgeProductReviewMetadataApplicationProtocol, {});
		await harness.server.waitForMetadataStream();
		harness.server.emitMetadata(metadataAccepted(harness.server.requiredMetadataRequest()));
		await harness.server.waitForControlRequestWhere(
			(request): boolean => request.kind === 'subscription.open',
		);
		expect(harness.transport.metadataStreamDiagnostics?.().routedFrameCount).toBe(1);
		await expect(
			harness.transport.call('review.markFileViewed', { itemId: 'review-item-independent' }),
		).resolves.toBeNull();

		expect(didFirstSettle).toBe(false);
		expect(
			harness.server.frameAcknowledgements.filter(
				(acknowledgement) => acknowledgement.contentRequestId === second.contentRequestId,
			),
		).toHaveLength(1);

		harness.server.releaseHeldContentAcknowledgement();
		firstAbortController.abort(new DOMException('test cleanup', 'AbortError'));
		await expect(first.terminal).rejects.toThrow();
	});

	test('reserves request capacity for observations while content remains open', async () => {
		const harness = createContentTransportHarness();
		harness.server.holdContentResponses = true;
		const abortControllers = Array.from({ length: 13 }, () => new AbortController());
		const contentStreams = abortControllers.map((abortController, index) =>
			harness.transport.openContent(
				fileContentDescriptor(`descriptor-admission-${index}`),
				abortController.signal,
			),
		);

		await harness.server.waitForContentRequestCount(
			BRIDGE_PRODUCT_MAXIMUM_CONCURRENT_CONTENT_RESPONSES,
		);
		await Promise.resolve();
		expect(harness.server.contentRequests).toHaveLength(
			BRIDGE_PRODUCT_MAXIMUM_CONCURRENT_CONTENT_RESPONSES,
		);
		const waitingContentStream = contentStreams[12];
		expect(waitingContentStream?.responseStartControl).toBeDefined();
		waitingContentStream?.responseStartControl?.pauseBeforeStart();

		abortControllers[0]?.abort(new DOMException('release active admission', 'AbortError'));
		await expect(contentStreams[0]?.terminal).rejects.toThrow();
		expect(BRIDGE_PRODUCT_MAXIMUM_CONCURRENT_CONTENT_RESPONSES).toBe(12);
		await Promise.resolve();
		expect(harness.server.contentRequests).toHaveLength(12);

		waitingContentStream?.responseStartControl?.resumeBeforeStart();
		await harness.server.waitForContentRequestCount(13);
		expect(harness.server.contentRequests).toHaveLength(13);
		for (const abortController of abortControllers.slice(1)) {
			abortController.abort(new DOMException('test cleanup', 'AbortError'));
		}
		await Promise.allSettled(
			contentStreams.slice(1).map((contentStream) => contentStream.terminal),
		);
	});

	test('aborting a paused response waiter never starts its content request', async () => {
		const harness = createContentTransportHarness();
		harness.server.holdContentResponses = true;
		const abortControllers = Array.from({ length: 13 }, () => new AbortController());
		const contentStreams = abortControllers.map((abortController, index) =>
			harness.transport.openContent(
				fileContentDescriptor(`descriptor-paused-abort-${index}`),
				abortController.signal,
			),
		);
		await harness.server.waitForContentRequestCount(
			BRIDGE_PRODUCT_MAXIMUM_CONCURRENT_CONTENT_RESPONSES,
		);
		const waitingContentStream = contentStreams[12];
		if (waitingContentStream === undefined) throw new Error('Expected one waiting content stream.');
		waitingContentStream.responseStartControl?.pauseBeforeStart();
		abortControllers[0]?.abort(new DOMException('release active admission', 'AbortError'));
		await expect(contentStreams[0]?.terminal).rejects.toThrow();

		abortControllers[12]?.abort(new DOMException('cancel paused response', 'AbortError'));
		waitingContentStream.responseStartControl?.resumeBeforeStart();
		await expect(waitingContentStream.terminal).rejects.toThrow();
		expect(harness.server.contentRequests).toHaveLength(
			BRIDGE_PRODUCT_MAXIMUM_CONCURRENT_CONTENT_RESPONSES,
		);

		for (const abortController of abortControllers.slice(1, 12)) {
			abortController.abort(new DOMException('test cleanup', 'AbortError'));
		}
		await Promise.allSettled(contentStreams.slice(1, 12).map(({ terminal }) => terminal));
	});

	test('cancels the content response reader when its signal aborts', async () => {
		const harness = createContentTransportHarness();
		harness.server.holdContentResponses = true;
		const abortController = new AbortController();
		const content = harness.transport.openContent(
			fileContentDescriptor('descriptor-abort'),
			abortController.signal,
		);
		await harness.server.waitForContentRequestCount(1);
		await harness.server.waitForHeldContentReadStarted(content.contentRequestId);

		abortController.abort(new DOMException('cancelled', 'AbortError'));

		await expect(content.terminal).rejects.toThrow();
		expect(harness.server.contentReaderCancelCount).toBe(1);
	});
});
