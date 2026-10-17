import { expect, test } from 'vitest';

import {
	BridgeViewerProductOpenSettlementCorrelator,
	type ProductOpenSettlementEntry,
} from './product-only-real-router-operation-settlements.ts';

test('correlates a result and acknowledgement that arrive before both exact admission responses', () => {
	const correlator = new BridgeViewerProductOpenSettlementCorrelator();
	const first: ProductOpenSettlementEntry = {
		requestKind: 'subscription.open',
		resultAcknowledged: false,
		settledResponseKind: null,
	};
	const replay: ProductOpenSettlementEntry = {
		requestKind: 'subscription.open',
		resultAcknowledged: false,
		settledResponseKind: null,
	};
	correlator.observe(
		{ requestKind: 'operation.result', resultAcknowledged: false, settledResponseKind: null },
		{ kind: 'operation.result', operationId: 'operation-1' },
		{
			kind: 'operation.result',
			operationId: 'operation-1',
			outcome: 'succeeded',
			result: { kind: 'subscription.openAccepted' },
		},
	);
	correlator.observe(
		{
			requestKind: 'operation.resultAcknowledgement',
			resultAcknowledged: false,
			settledResponseKind: null,
		},
		{ kind: 'operation.resultAcknowledgement', operationId: 'operation-1' },
		{ kind: 'operation.resultAcknowledged', operationId: 'operation-1' },
	);
	for (const entry of [first, replay]) {
		correlator.observe(
			entry,
			{ kind: 'subscription.open' },
			{ kind: 'operation.admitted', operationId: 'operation-1' },
		);
	}
	expect(first).toEqual({
		requestKind: 'subscription.open',
		resultAcknowledged: true,
		settledResponseKind: 'subscription.openAccepted',
	});
	expect(replay).toEqual(first);
});

test('does not treat an unknown or unsuccessful result as an accepted open', () => {
	const correlator = new BridgeViewerProductOpenSettlementCorrelator();
	const entry: ProductOpenSettlementEntry = {
		requestKind: 'subscription.open',
		resultAcknowledged: false,
		settledResponseKind: null,
	};
	correlator.observe(
		entry,
		{ kind: 'subscription.open' },
		{ kind: 'operation.admitted', operationId: 'operation-2' },
	);
	correlator.observe(
		{ requestKind: 'operation.result', resultAcknowledged: false, settledResponseKind: null },
		{ kind: 'operation.result', operationId: 'operation-2' },
		{
			kind: 'operation.result',
			operationId: 'operation-2',
			outcome: 'failed',
			result: null,
		},
	);
	correlator.observe(
		{
			requestKind: 'operation.resultAcknowledgement',
			resultAcknowledged: false,
			settledResponseKind: null,
		},
		{ kind: 'operation.resultAcknowledgement', operationId: 'wrong-operation' },
		{ kind: 'operation.resultAcknowledged', operationId: 'operation-2' },
	);
	expect(entry).toEqual({
		requestKind: 'subscription.open',
		resultAcknowledged: false,
		settledResponseKind: null,
	});
});
