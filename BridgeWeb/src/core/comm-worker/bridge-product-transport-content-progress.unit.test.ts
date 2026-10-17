import { describe, expect, test } from 'vitest';

import { BRIDGE_PRODUCT_MAXIMUM_CONTENT_FRAME_BYTES } from './bridge-product-contract-primitives.js';
import type { BridgeProductDeadlineClock } from './bridge-product-deadline-clock.js';
import { awaitBridgeProductFiniteProgress } from './bridge-product-finite-progress-deadline.js';
import {
	createContentTransportHarness,
	fileContentDescriptor,
} from './test-fixtures/bridge-product-transport-content.test-support.js';

class ControlledContentDeadlineClock implements BridgeProductDeadlineClock {
	readonly deadlines: Array<{ active: boolean; delayMilliseconds: number; fire: () => void }> = [];

	schedule(delayMilliseconds: number, onDeadline: () => void): () => void {
		const deadline = {
			active: true,
			delayMilliseconds,
			fire: (): void => {
				if (!deadline.active) throw new Error('Cannot fire a cleared content deadline.');
				deadline.active = false;
				onDeadline();
			},
		};
		this.deadlines.push(deadline);
		return (): void => {
			deadline.active = false;
		};
	}

	activeDeadline(): (typeof this.deadlines)[number] {
		const active = this.deadlines.find((deadline) => deadline.active);
		if (active === undefined) throw new Error('Expected an armed content deadline.');
		return active;
	}
}

describe('Bridge product finite content progress', () => {
	test('uses the delivered session policy for a held content acknowledgement deadline', async () => {
		const clock = new ControlledContentDeadlineClock();
		const harness = createContentTransportHarness(0, undefined, 71, clock);
		harness.server.leaveContentOpenAfterAcceptance = true;
		harness.server.holdContentAcknowledgement('content-request-1');
		const abortController = new AbortController();
		const content = harness.transport.openContent(
			fileContentDescriptor('policy-bound-ack'),
			abortController.signal,
		);
		try {
			await harness.server.waitForFrameAcknowledgementCount(1);
			expect(
				clock.deadlines.some(
					(deadline): boolean => deadline.active && deadline.delayMilliseconds === 71,
				),
			).toBe(true);
		} finally {
			abortController.abort(new DOMException('test cleanup', 'AbortError'));
			harness.server.releaseHeldContentAcknowledgement();
			await content.terminal.catch((): void => {});
		}
	});
	test('arms the deadline before starting the fetch', async () => {
		const clock = new ControlledContentDeadlineClock();
		const result = await awaitBridgeProductFiniteProgress({
			abortRead: (): void => {},
			clock,
			delayMilliseconds: 5_000,
			pending: (): Promise<string> => {
				expect(clock.activeDeadline().delayMilliseconds).toBe(5_000);
				return Promise.resolve('response');
			},
		});
		expect(result).toBe('response');
		expect(clock.deadlines[0]?.active).toBe(false);
	});

	test('pre-response expiry settles only the held content read', async () => {
		const clock = new ControlledContentDeadlineClock();
		const harness = createContentTransportHarness(0, undefined, 100, clock);
		harness.server.holdNextContentRequestBeforeResponse = true;
		const content = harness.transport.openContent(
			fileContentDescriptor('held-before-response'),
			new AbortController().signal,
		);
		await harness.server.waitForContentRequestInvocationCount(1);
		expect(clock.activeDeadline().delayMilliseconds).toBe(5_000);
		clock.activeDeadline().fire();
		await expect(content.terminal).rejects.toMatchObject({
			name: 'BridgeProductFiniteProgressDeadlineExpired',
			retryable: true,
		});
		harness.server.releaseHeldContentRequestBeforeResponse();
	});

	test('partial verified body progress rearms and a later stall expires', async () => {
		const clock = new ControlledContentDeadlineClock();
		const harness = createContentTransportHarness(0, undefined, 100, clock);
		harness.server.leaveContentOpenAfterAcceptance = true;
		const content = harness.transport.openContent(
			fileContentDescriptor('held-after-accepted'),
			new AbortController().signal,
		);
		await harness.server.waitForFrameAcknowledgementCount(1);
		const contentDeadlines = clock.deadlines.filter(
			(deadline) => deadline.delayMilliseconds === 5_000,
		);
		expect(contentDeadlines.length).toBeGreaterThanOrEqual(2);
		expect(contentDeadlines[0]?.active).toBe(false);
		const rearmedDeadline = contentDeadlines.at(-1);
		expect(rearmedDeadline?.active).toBe(true);
		rearmedDeadline?.fire();
		await expect(content.terminal).rejects.toMatchObject({
			name: 'BridgeProductFiniteProgressDeadlineExpired',
			retryable: true,
		});
		expect(harness.server.contentReaderCancelCount).toBe(1);
	});

	test('a stalled data-credit reply leaves body progress under the finite deadline', async () => {
		const clock = new ControlledContentDeadlineClock();
		const harness = createContentTransportHarness(
			0,
			undefined,
			10_000,
			clock,
			BRIDGE_PRODUCT_MAXIMUM_CONTENT_FRAME_BYTES + 4,
		);
		harness.server.gateContentBodyOnOpeningAcknowledgement = true;
		harness.server.leaveContentOpenAfterData = true;
		harness.server.holdContentAcknowledgement('content-request-1', 1);
		const content = harness.transport.openContent(
			fileContentDescriptor('held-data-credit'),
			new AbortController().signal,
		);

		await harness.server.waitForFrameAcknowledgementCount(2);
		expect(
			harness.server.frameAcknowledgements.map(
				(acknowledgement) => acknowledgement.receivedThroughContentSequence,
			),
		).toEqual([0, 1]);
		const bodyDeadline = clock.deadlines.findLast(
			(deadline) => deadline.delayMilliseconds === 5_000,
		);
		expect(bodyDeadline?.active).toBe(true);
		bodyDeadline?.fire();
		await expect(content.terminal).rejects.toMatchObject({
			name: 'BridgeProductFiniteProgressDeadlineExpired',
		});
		harness.server.releaseHeldContentAcknowledgement();
	});
});
