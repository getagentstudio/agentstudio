import { expect, test } from 'vitest';
import { z } from 'zod';

import nativeSessionCorpus from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-session-corpus.json' with { type: 'json' };
import {
	bridgeProductFileRefreshFailureSchema,
	bridgeProductMetadataFrameSchema,
} from './bridge-product-session-contracts.js';

test.each(['missingRoot', 'unreadableRoot'])(
	'accepts the exact retryable %s File root failure',
	(failureKind): void => {
		const failure = { failureKind, retryable: true };
		expect(bridgeProductFileRefreshFailureSchema.parse(failure)).toEqual(failure);
		expect(
			bridgeProductMetadataFrameSchema.parse({
				kind: 'pane.presentation',
				wireVersion: 2,
				metadataStreamId: 'metadata-root-failure',
				paneSessionId: 'pane-root-failure',
				workerInstanceId: 'worker-root-failure',
				streamSequence: 1,
				presentationRevision: 1,
				nativeActivity: 'foreground',
				refreshingLanes: [],
				operationCorrelationId: null,
				reviewComparison: null,
				fileRefreshFailure: failure,
			}),
		).toMatchObject({ fileRefreshFailure: failure });
		for (const invalidFailure of [
			{ ...failure, retryable: false },
			{ ...failure, message: 'unsafe text' },
			{ ...failure, path: '/private/root' },
			{ failureKind },
		]) {
			expect(bridgeProductFileRefreshFailureSchema.safeParse(invalidFailure).success).toBe(false);
		}
	},
);

test('keeps generic and permanent File failure dispositions unchanged', (): void => {
	for (const failure of [
		{ failureKind: 'fileSourceUnavailable', retryable: true },
		{ failureKind: 'fileRefreshFailed', retryable: false },
		{ failureKind: 'producerRejected', retryable: false },
	]) {
		expect(bridgeProductFileRefreshFailureSchema.parse(failure)).toEqual(failure);
		expect(
			bridgeProductFileRefreshFailureSchema.safeParse({ ...failure, retryable: !failure.retryable })
				.success,
		).toBe(false);
	}
});

test('decodes every native File root classification from the mirrored corpus', (): void => {
	const cases = z
		.object({
			fileRefreshFailureCases: z
				.array(
					z
						.object({
							rootAccessFailure: z.enum(['missingRoot', 'unreadable', 'refused']),
							failure: bridgeProductFileRefreshFailureSchema,
						})
						.strict(),
				)
				.length(3),
		})
		.parse(nativeSessionCorpus).fileRefreshFailureCases;
	expect(cases.map((entry) => entry.rootAccessFailure).sort()).toEqual([
		'missingRoot',
		'refused',
		'unreadable',
	]);
	for (const entry of cases) {
		expect(entry.failure).toEqual(
			entry.rootAccessFailure === 'missingRoot'
				? { failureKind: 'missingRoot', retryable: true }
				: entry.rootAccessFailure === 'unreadable'
					? { failureKind: 'unreadableRoot', retryable: true }
					: { failureKind: 'producerRejected', retryable: false },
		);
	}
});
