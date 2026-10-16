import { describe, expect, test } from 'vitest';

import {
	bridgeProductContentAcknowledgementRefusedSchema,
	bridgeProductFrameAcknowledgementRejectedStatusSchema,
	bridgeProductFrameAcknowledgementRequestSchema,
} from './bridge-product-frame-acknowledgement-contracts.js';

describe('Bridge product frame acknowledgement contracts', () => {
	test('accepts cumulative content credit and rejects retired frame observations', () => {
		const contentRequest = {
			contentRequestId: 'content-request-1',
			receivedThroughContentSequence: 0,
			kind: 'content.acknowledge',
			leaseId: 'lease-1',
			paneSessionId: 'pane-session-1',
			wireVersion: 2,
			workerInstanceId: 'worker-instance-1',
		} as const;

		expect(bridgeProductFrameAcknowledgementRequestSchema.parse(contentRequest)).toEqual(
			contentRequest,
		);
		expect(
			bridgeProductFrameAcknowledgementRequestSchema.safeParse({
				kind: 'stream.frameObserved',
				metadataStreamId: 'metadata-stream-1',
				paneSessionId: 'pane-session-1',
				streamSequence: 7,
				streamKind: 'metadata',
				wireVersion: 2,
				workerInstanceId: 'worker-instance-1',
			}).success,
		).toBe(false);
	});

	test('rejects cross-wired, unknown, and structurally invalid content credits', () => {
		const contentRequest = {
			contentRequestId: 'content-request-1',
			receivedThroughContentSequence: 0,
			kind: 'content.acknowledge',
			leaseId: 'lease-1',
			paneSessionId: 'pane-session-1',
			wireVersion: 2,
			workerInstanceId: 'worker-instance-1',
		} as const;

		for (const invalidRequest of [
			{ ...contentRequest, contentRequestId: '' },
			{ ...contentRequest, leaseId: 'lease/invalid' },
			{ ...contentRequest, paneSessionId: 'pane/invalid' },
			{ ...contentRequest, workerInstanceId: 'worker/invalid' },
			{ ...contentRequest, receivedThroughContentSequence: -1 },
			{ ...contentRequest, unknown: true },
			{
				...contentRequest,
				metadataStreamId: 'metadata-stream-1',
				streamSequence: 0,
			},
			{ ...contentRequest, kind: 'stream.frameIgnored' },
			{ ...contentRequest, streamKind: 'telemetry' },
			{ ...contentRequest, wireVersion: 1 },
		]) {
			expect(bridgeProductFrameAcknowledgementRequestSchema.safeParse(invalidRequest).success).toBe(
				false,
			);
		}
	});

	test('defines closed rejection statuses', () => {
		for (const rejectionStatus of [400, 401, 403, 404, 405, 409, 413, 415]) {
			expect(bridgeProductFrameAcknowledgementRejectedStatusSchema.parse(rejectionStatus)).toBe(
				rejectionStatus,
			);
		}
		for (const unsupportedStatus of [200, 201, 204, 418, 500]) {
			expect(
				bridgeProductFrameAcknowledgementRejectedStatusSchema.safeParse(unsupportedStatus).success,
			).toBe(false);
		}
	});

	test('requires an exact unknown-read refusal envelope', () => {
		const refusal = {
			contentRequestId: 'content-request-1',
			kind: 'content.acknowledgementRefused',
			leaseId: 'lease-1',
			paneSessionId: 'pane-session-1',
			reason: 'unknownRead',
			receivedThroughContentSequence: 1,
			wireVersion: 2,
			workerInstanceId: 'worker-instance-1',
		} as const;
		expect(bridgeProductContentAcknowledgementRefusedSchema.parse(refusal)).toEqual(refusal);
		for (const invalidRefusal of [
			{ ...refusal, reason: 'unknownContent' },
			{ ...refusal, receivedThroughContentSequence: -1 },
			{ ...refusal, unknown: true },
		]) {
			expect(
				bridgeProductContentAcknowledgementRefusedSchema.safeParse(invalidRefusal).success,
			).toBe(false);
		}
	});
});
