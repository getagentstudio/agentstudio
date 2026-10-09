import { describe, expect, test, vi } from 'vitest';

import type { BridgeCommWorkerReviewRuntimeSource } from './bridge-comm-worker-command-handler.js';
import { makeReviewPublicationIdentity } from './bridge-comm-worker-entry.test-support.js';
import { enqueueBridgeCommWorkerReviewSourceReset } from './bridge-comm-worker-review-source-reset.js';
import { makeWorkerReviewContentMetadata } from './bridge-comm-worker-runtime-protocol.test-support.js';
import { createBridgeCommWorkerStore } from './bridge-comm-worker-store.js';
import { createWorkerContentPreparationPump } from './bridge-worker-content-preparation-pump.js';
import { BridgeProductTestFactRecorder } from './test-fixtures/bridge-product-test-fact-recorder.js';

describe('Bridge comm worker Review source reset', () => {
	test.each([false, true])(
		'rebases a chunked reset onto a newer same-epoch metadata delta (held task: %s)',
		async (holdTask) => {
			// Arrange
			if (holdTask) vi.useFakeTimers();
			const scheduleTask = globalThis.setTimeout;
			let heldCallback: (() => void) | null = null;
			let holdNextTask = holdTask;
			const timerSpy = vi.spyOn(globalThis, 'setTimeout').mockImplementation((...arguments_) => {
				if (!holdNextTask) return scheduleTask(...arguments_);
				holdNextTask = false;
				heldCallback = arguments_[0];
				return scheduleTask((): void => {}, 0);
			});
			const drainFacts = new BridgeProductTestFactRecorder<number>();
			let drainCount = 0;
			const rows = Array.from({ length: 130 }, (_unused, index) => ({
				id: `item-${index + 1}`,
				index,
				parentId: null,
			}));
			let runtimeSource: {
				contentItems: BridgeCommWorkerReviewRuntimeSource['contentItems'][number][];
				contentRequestDescriptors: BridgeCommWorkerReviewRuntimeSource['contentRequestDescriptors'][number][];
				renderSemantics: BridgeCommWorkerReviewRuntimeSource['renderSemantics'][number][];
				reviewPublicationIdentity: BridgeCommWorkerReviewRuntimeSource['reviewPublicationIdentity'];
				rows: BridgeCommWorkerReviewRuntimeSource['rows'][number][];
			} = {
				contentItems: rows.map((row) => makeWorkerReviewContentMetadata({ itemId: row.id })),
				contentRequestDescriptors: [],
				renderSemantics: [],
				reviewPublicationIdentity: makeReviewPublicationIdentity(),
				rows: [...rows],
			};
			const store = createBridgeCommWorkerStore({ contentItems: [], rows: [], surface: 'review' });
			const pump = createWorkerContentPreparationPump({ maxSliceMs: 8, now: (): number => 0 });
			const ticket = enqueueBridgeCommWorkerReviewSourceReset({
				createSequence: (): number => 1,
				isCurrentResetEpoch: (): boolean => true,
				onResetComplete: (): void => {},
				pump,
				request: {
					affectedItemIds: rows.map((row) => row.id),
					cause: 'reviewMetadata',
					epoch: 1,
					readReviewRuntimeSource: (): BridgeCommWorkerReviewRuntimeSource => runtimeSource,
					store,
				},
				requestPreparationDrain: (): void => {
					drainFacts.record(++drainCount);
					pump.runUntilBudget();
				},
				scheduleDemandExecution: (): boolean => false,
				scheduleSelectedReviewContentReadyPreparation: (): void => {},
			});
			pump.runUntilBudget();
			const addedRow = { id: 'item-131', index: 130, parentId: null } as const;
			const addedContent = makeWorkerReviewContentMetadata({ itemId: addedRow.id });
			runtimeSource = {
				...runtimeSource,
				contentItems: [...runtimeSource.contentItems, addedContent],
				rows: [...runtimeSource.rows, addedRow],
			};
			store.actions.applyReviewSourceUpdateFact({
				contentItems: [addedContent],
				epoch: 1,
				resetComplete: false,
				rows: [addedRow],
			});

			// Act
			let resolvedBeforeOwner = false;
			const continuation = drainFacts
				.waitFor((drain): boolean => drain === 1)
				.then((): void => {
					resolvedBeforeOwner = drainCount === 0;
				});
			try {
				if (holdTask) {
					await vi.runOnlyPendingTimersAsync();
					const callback = heldCallback as (() => void) | null;
					if (callback === null) throw new Error('Expected a held reset continuation.');
					callback();
					await vi.runAllTimersAsync();
				}
				await continuation;
				await ticket.completion;

				// Assert
				expect(store.getState().rowById.has(addedRow.id)).toBe(true);
				expect(store.getState().contentMetadataByItemId.has(addedRow.id)).toBe(true);
				expect(resolvedBeforeOwner).toBe(false);
			} finally {
				timerSpy.mockRestore();
				vi.useRealTimers();
				drainFacts.close(new Error('Review reset observation closed.'));
			}
		},
	);
});
