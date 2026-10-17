import { describe, expect, test } from 'vitest';

import {
	createBridgeCommWorkerVisibleSourceChurnDedupeState,
	recordBridgeCommWorkerVisibleSourceChurn,
} from './bridge-comm-worker-review-demand-scheduling.js';

describe('Bridge comm worker Review demand source-churn dedupe', () => {
	test('retains only the affected item membership for the current revision', () => {
		let state = createBridgeCommWorkerVisibleSourceChurnDedupeState();

		for (let sourceChurnRevision = 1; sourceChurnRevision <= 256; sourceChurnRevision += 1) {
			const result = recordBridgeCommWorkerVisibleSourceChurn({
				affectedItemIds: ['item-1', 'item-2'],
				identity: { epoch: 7, sourceChurnRevision },
				state,
			});

			expect(result.accepted).toBe(true);
			expect(result.unmarkedAffectedItemIds).toEqual(['item-1', 'item-2']);
			expect(result.state.currentIdentity).toEqual({ epoch: 7, sourceChurnRevision });
			expect([...result.state.markedItemIds]).toEqual(['item-1', 'item-2']);
			state = result.state;
		}

		const sameRevisionResult = recordBridgeCommWorkerVisibleSourceChurn({
			affectedItemIds: ['item-1', 'item-2', 'item-3'],
			identity: { epoch: 7, sourceChurnRevision: 256 },
			state,
		});
		expect(sameRevisionResult.accepted).toBe(true);
		expect(sameRevisionResult.unmarkedAffectedItemIds).toEqual(['item-3']);
		expect([...sameRevisionResult.state.markedItemIds]).toEqual(['item-1', 'item-2', 'item-3']);

		const repeatedRevisionResult = recordBridgeCommWorkerVisibleSourceChurn({
			affectedItemIds: ['item-1', 'item-2', 'item-3'],
			identity: { epoch: 7, sourceChurnRevision: 256 },
			state: sameRevisionResult.state,
		});
		expect(repeatedRevisionResult.accepted).toBe(true);
		expect(repeatedRevisionResult.unmarkedAffectedItemIds).toEqual([]);
		expect(repeatedRevisionResult.state.markedItemIds.size).toBe(3);
	});

	test('orders reset epochs and projection revisions without letting stale work erase dedupe', () => {
		const resetResult = recordBridgeCommWorkerVisibleSourceChurn({
			affectedItemIds: ['item-reset'],
			identity: { epoch: 8, sourceChurnRevision: null },
			state: createBridgeCommWorkerVisibleSourceChurnDedupeState(),
		});
		const firstRevisionResult = recordBridgeCommWorkerVisibleSourceChurn({
			affectedItemIds: ['item-revision'],
			identity: { epoch: 8, sourceChurnRevision: 1 },
			state: resetResult.state,
		});
		expect(firstRevisionResult.accepted).toBe(true);
		expect(firstRevisionResult.unmarkedAffectedItemIds).toEqual(['item-revision']);
		expect([...firstRevisionResult.state.markedItemIds]).toEqual(['item-revision']);

		const staleEpochResult = recordBridgeCommWorkerVisibleSourceChurn({
			affectedItemIds: ['item-stale-epoch'],
			identity: { epoch: 7, sourceChurnRevision: 99 },
			state: firstRevisionResult.state,
		});
		expect(staleEpochResult.accepted).toBe(false);
		expect(staleEpochResult.unmarkedAffectedItemIds).toEqual([]);
		expect(staleEpochResult.state).toBe(firstRevisionResult.state);

		const staleResetResult = recordBridgeCommWorkerVisibleSourceChurn({
			affectedItemIds: ['item-stale-reset'],
			identity: { epoch: 8, sourceChurnRevision: null },
			state: firstRevisionResult.state,
		});
		expect(staleResetResult.accepted).toBe(false);
		expect(staleResetResult.state).toBe(firstRevisionResult.state);

		const nextRevisionResult = recordBridgeCommWorkerVisibleSourceChurn({
			affectedItemIds: ['item-next-revision'],
			identity: { epoch: 8, sourceChurnRevision: 2 },
			state: firstRevisionResult.state,
		});
		expect(nextRevisionResult.accepted).toBe(true);
		expect([...nextRevisionResult.state.markedItemIds]).toEqual(['item-next-revision']);

		const nextEpochResetResult = recordBridgeCommWorkerVisibleSourceChurn({
			affectedItemIds: ['item-next-reset'],
			identity: { epoch: 9, sourceChurnRevision: null },
			state: nextRevisionResult.state,
		});
		expect(nextEpochResetResult.accepted).toBe(true);
		expect([...nextEpochResetResult.state.markedItemIds]).toEqual(['item-next-reset']);
	});
});
