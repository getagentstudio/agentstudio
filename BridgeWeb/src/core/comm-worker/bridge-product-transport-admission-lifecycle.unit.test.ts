import { afterEach, describe, expect, test, vi } from 'vitest';

import {
	createContentTransportHarness,
	fileContentDescriptor,
} from './test-fixtures/bridge-product-transport-content.test-support.js';

afterEach((): void => {
	vi.unstubAllGlobals();
});

describe('Bridge product content response admission lifecycle', () => {
	test('uses an explicit construction-supplied content response maximum', async () => {
		const harness = createContentTransportHarness(0, 4);
		harness.server.holdContentResponses = true;
		const abortControllers = Array.from({ length: 5 }, () => new AbortController());
		const contentStreams = abortControllers.map((abortController, index) =>
			harness.transport.openContent(
				fileContentDescriptor(`descriptor-explicit-admission-${index}`),
				abortController.signal,
			),
		);

		await harness.server.waitForContentRequestCount(4);
		await Promise.resolve();

		expect(harness.server.contentRequests).toHaveLength(4);
		for (const abortController of abortControllers) {
			abortController.abort(new DOMException('test cleanup', 'AbortError'));
		}
		await Promise.allSettled(contentStreams.map(({ terminal }) => terminal));
	});

	test('aborting a queued response waiter never invokes its content request executor', async () => {
		const harness = createContentTransportHarness(0, 1);
		harness.server.holdContentResponses = true;
		const activeAbortController = new AbortController();
		const queuedAbortController = new AbortController();
		const active = harness.transport.openContent(
			fileContentDescriptor('descriptor-queued-abort-active'),
			activeAbortController.signal,
		);
		const queued = harness.transport.openContent(
			fileContentDescriptor('descriptor-queued-abort-waiter'),
			queuedAbortController.signal,
		);
		await harness.server.waitForContentRequestInvocationCount(1);

		queuedAbortController.abort(new DOMException('cancel queued response', 'AbortError'));
		await expect(queued.terminal).rejects.toThrow();

		expect(harness.server.contentRequestInvocationCount).toBe(1);
		activeAbortController.abort(new DOMException('test cleanup', 'AbortError'));
		await expect(active.terminal).rejects.toThrow();
	});

	test('aborting an admitted request releases replacement capacity before fetch settlement', async () => {
		const harness = createContentTransportHarness(0, 1);
		harness.server.holdNextContentRequestBeforeResponse = true;
		const obsoleteAbortController = new AbortController();
		const replacementAbortController = new AbortController();
		const obsolete = harness.transport.openContent(
			fileContentDescriptor('descriptor-obsolete-before-response'),
			obsoleteAbortController.signal,
		);
		await harness.server.waitForContentRequestInvocationCount(1);
		const replacement = harness.transport.openContent(
			fileContentDescriptor('descriptor-replacement-after-abort'),
			replacementAbortController.signal,
		);

		let replacementStartedBeforeFetchSettlement = false;
		try {
			obsoleteAbortController.abort(new DOMException('superseded content request', 'AbortError'));
			await harness.server.waitForContentRequestInvocationCount(2);
			replacementStartedBeforeFetchSettlement = true;
		} finally {
			harness.server.releaseHeldContentRequestBeforeResponse();
			replacementAbortController.abort(new DOMException('test cleanup', 'AbortError'));
			await Promise.allSettled([obsolete.terminal, replacement.terminal]);
		}

		expect(replacementStartedBeforeFetchSettlement).toBe(true);
		expect(
			harness.server.frameAcknowledgements.filter(
				(acknowledgement) => acknowledgement.contentRequestId === obsolete.contentRequestId,
			),
		).toEqual([]);
	});

	test('releases exactly one admission after terminal EOF settlement', async () => {
		const harness = createContentTransportHarness(0, 1);
		const settled = harness.transport.openContent(
			fileContentDescriptor('descriptor-release-eof'),
			new AbortController().signal,
		);

		await expect(settled.terminal).resolves.toMatchObject({ kind: 'complete' });

		await expectExactlyOneReusableContentCapacity(harness);
	});

	test('releases exactly one admission after unexpected EOF', async () => {
		const harness = createContentTransportHarness(0, 1);
		harness.server.nextContentResponseKind = 'unexpected-eof';
		const failed = harness.transport.openContent(
			fileContentDescriptor('descriptor-release-unexpected-eof'),
			new AbortController().signal,
		);

		await expect(failed.terminal).rejects.toThrow();

		await expectExactlyOneReusableContentCapacity(harness);
	});

	test('releases exactly one admission after response read error', async () => {
		const harness = createContentTransportHarness(0, 1);
		harness.server.nextContentResponseKind = 'read-error';
		const failed = harness.transport.openContent(
			fileContentDescriptor('descriptor-release-read-error'),
			new AbortController().signal,
		);

		await expect(failed.terminal).rejects.toThrow('synthetic response read failure');

		await expectExactlyOneReusableContentCapacity(harness);
	});

	test('releases exactly one admission after request failure', async () => {
		const harness = createContentTransportHarness(0, 1);
		harness.server.nextContentRequestFailure = new Error('synthetic request failure');
		const failed = harness.transport.openContent(
			fileContentDescriptor('descriptor-release-request-failure'),
			new AbortController().signal,
		);

		await expect(failed.terminal).rejects.toThrow('synthetic request failure');

		await expectExactlyOneReusableContentCapacity(harness);
	});

	test('releases exactly one admission after response cancellation', async () => {
		const harness = createContentTransportHarness(0, 1);
		harness.server.holdContentResponses = true;
		const abortController = new AbortController();
		const cancelled = harness.transport.openContent(
			fileContentDescriptor('descriptor-release-cancel'),
			abortController.signal,
		);
		await harness.server.waitForContentRequestInvocationCount(1);

		abortController.abort(new DOMException('cancel active response', 'AbortError'));
		await expect(cancelled.terminal).rejects.toThrow();

		await expectExactlyOneReusableContentCapacity(harness);
	});
});

async function expectExactlyOneReusableContentCapacity(
	harness: ReturnType<typeof createContentTransportHarness>,
): Promise<void> {
	const invocationCountBeforeReuse = harness.server.contentRequestInvocationCount;
	harness.server.holdContentResponses = true;
	const firstAbortController = new AbortController();
	const secondAbortController = new AbortController();
	const first = harness.transport.openContent(
		fileContentDescriptor(`descriptor-reuse-first-${invocationCountBeforeReuse}`),
		firstAbortController.signal,
	);
	const second = harness.transport.openContent(
		fileContentDescriptor(`descriptor-reuse-second-${invocationCountBeforeReuse}`),
		secondAbortController.signal,
	);
	await harness.server.waitForContentRequestInvocationCount(invocationCountBeforeReuse + 1);
	await Promise.resolve();
	expect(harness.server.contentRequestInvocationCount).toBe(invocationCountBeforeReuse + 1);

	firstAbortController.abort(new DOMException('release first reuse admission', 'AbortError'));
	await expect(first.terminal).rejects.toThrow();
	await harness.server.waitForContentRequestInvocationCount(invocationCountBeforeReuse + 2);
	secondAbortController.abort(new DOMException('test cleanup', 'AbortError'));
	await expect(second.terminal).rejects.toThrow();
}
