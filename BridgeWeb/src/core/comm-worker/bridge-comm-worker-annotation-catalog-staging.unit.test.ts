import { describe, expect, test } from 'vitest';

import type { BridgeCommWorkerAnnotationCatalog } from './bridge-comm-worker-annotation-catalog-applicator.js';
import { bridgeCommWorkerAnnotationCatalogStagingEvents } from './bridge-comm-worker-annotation-runtime-events.js';
import { BRIDGE_PRODUCT_MAXIMUM_METADATA_FRAME_BYTES } from './bridge-product-contract-primitives.js';
import type { BridgeProductWorktreeAnnotationCatalogEntry } from './bridge-product-worktree-annotation-contracts.js';
import { bridgeWorkerServerToMainMessageSchema } from './bridge-worker-contracts.js';

describe('Bridge communication worker annotation catalog staging', () => {
	test('repacks one completed catalog into bounded existing-port messages', () => {
		const entries = Array.from({ length: 2_000 }, (_, index) => ({
			kind: 'session' as const,
			semanticRevision: index,
			sessionId: `01890abc-def0-7abc-8def-${index.toString(16).padStart(12, '0')}`,
		}));
		const catalog = catalogWithEntries(entries);

		const messages = bridgeCommWorkerAnnotationCatalogStagingEvents({
			catalog,
			surface: 'file',
		});

		expect(messages[0]?.transfer.kind).toBe('catalog.begin');
		expect(messages.at(-1)?.transfer.kind).toBe('catalog.commit');
		expect(
			messages.filter((message) => message.transfer.kind === 'catalog.window').length,
		).toBeGreaterThan(1);
		expect(
			messages.flatMap((message) =>
				message.transfer.kind === 'catalog.window' ? message.transfer.entries : [],
			),
		).toEqual(entries);
		for (const message of messages) {
			expect(bridgeWorkerServerToMainMessageSchema.parse(message)).toEqual(message);
			expect(new TextEncoder().encode(JSON.stringify(message)).byteLength).toBeLessThanOrEqual(
				BRIDGE_PRODUCT_MAXIMUM_METADATA_FRAME_BYTES,
			);
		}
	});

	test('rejects an operation ID on a view-batch catalog', () => {
		const catalog = catalogWithEntries([]);
		const viewBatch = bridgeCommWorkerAnnotationCatalogStagingEvents({
			catalog,
			surface: 'file',
		});
		expect(
			viewBatch.every(
				(message) => bridgeWorkerServerToMainMessageSchema.safeParse(message).success,
			),
		).toBe(true);
		expect(viewBatch[0]).not.toHaveProperty('operationCorrelationId');
		expect(
			bridgeWorkerServerToMainMessageSchema.safeParse({
				...viewBatch[0],
				operationCorrelationId: 'a'.repeat(64),
			}).success,
		).toBe(false);
	});
});

function catalogWithEntries(
	entries: readonly BridgeProductWorktreeAnnotationCatalogEntry[],
): BridgeCommWorkerAnnotationCatalog {
	const sessions = entries.filter(
		(entry): entry is Extract<BridgeProductWorktreeAnnotationCatalogEntry, { kind: 'session' }> =>
			entry.kind === 'session',
	);
	return {
		authority: {
			subscriptionId: 'annotation-subscription-1',
			workerDerivationEpoch: 1,
			worktreeId: 'worktree-1',
		},
		catalogRevision: 7,
		entries,
		messageIdsByThreadId: new Map(),
		messagesById: new Map(),
		orderedSessionIds: sessions.map((session) => session.sessionId),
		sessionsById: new Map(sessions.map((session) => [session.sessionId, session])),
		threadIdsBySessionId: new Map(),
		threadsById: new Map(),
		transferId: 'annotation-transfer-7',
	};
}
