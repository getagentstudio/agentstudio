import { expect, it } from 'vitest';

import {
	bridgeProductBatchFrameSchema,
	type BridgeProductBatchFrame,
} from './bridge-product-batch-wire-contracts.js';
import { BridgeProductViewBatchReceiver } from './bridge-product-view-batch-receiver.js';

it('a dropped File change part retains the certificate cursor and requires a full resnapshot', () => {
	const scope = {
		kind: 'file',
		changeFilter: { kind: 'none' },
		interests: [],
		pathScope: [],
	} satisfies Extract<
		BridgeProductBatchFrame,
		{ readonly kind: 'subscription.batchBegin' }
	>['scope'];
	const receiver = new BridgeProductViewBatchReceiver({
		handle: 'file-handle',
		scope,
		scopeRevision: 1,
		subscriptionId: 'file-view',
		subscriptionKind: 'file.metadata',
	});
	receiver.admitDomain('default', 'file-incarnation');
	let streamSequence = 0;
	function frame(fields: Readonly<Record<string, unknown>>): BridgeProductBatchFrame {
		streamSequence += 1;
		return bridgeProductBatchFrameSchema.parse({
			wireVersion: 2,
			paneSessionId: 'pane',
			workerInstanceId: 'worker',
			metadataStreamId: 'stream',
			streamSequence,
			subscriptionId: 'file-view',
			subscriptionKind: 'file.metadata',
			domain: 'default',
			handle: 'file-handle',
			incarnation: 'file-incarnation',
			scopeRevision: 1,
			...fields,
		});
	}
	receiver.accept(
		frame({
			kind: 'subscription.batchBegin',
			batchId: 'certificate',
			mode: 'snapshot',
			snapshotCause: 'open',
			baseRevision: 0,
			targetRevision: 1,
			partCount: 1,
			scope,
		}),
	);
	receiver.accept(
		frame({
			kind: 'subscription.batchPart',
			batchId: 'certificate',
			deliverySequence: 1,
			partIndex: 0,
			part: { operation: 'put', key: '/root/a', revision: 1, value: 'old' },
		}),
	);
	expect(
		receiver.accept(
			frame({
				kind: 'subscription.batchComplete',
				batchId: 'certificate',
				coveredScope: scope,
			}),
		).kind,
	).toBe('installed');
	receiver.accept(
		frame({
			kind: 'subscription.batchBegin',
			batchId: 'change-with-loss',
			mode: 'change',
			baseRevision: 1,
			targetRevision: 2,
			partCount: 2,
			scope,
		}),
	);
	// The first part is lost; the second cannot commit the atomic change bank.
	receiver.accept(
		frame({
			kind: 'subscription.batchPart',
			batchId: 'change-with-loss',
			deliverySequence: 3,
			partIndex: 1,
			part: { operation: 'put', key: '/root/b', revision: 2, value: 'new' },
		}),
	);
	expect(
		receiver.accept(
			frame({
				kind: 'subscription.batchComplete',
				batchId: 'change-with-loss',
				coveredScope: scope,
			}),
		).kind,
	).toBe('resnapshot');
	expect(receiver.cursor('default')).toBe(1);
	expect(receiver.records('default')).toEqual([{ key: '/root/a', revision: 1, value: 'old' }]);
	expect(
		receiver.accept(
			frame({
				kind: 'subscription.batchBegin',
				batchId: 'successor-change',
				mode: 'change',
				baseRevision: 2,
				targetRevision: 3,
				partCount: 0,
				scope,
			}),
		).kind,
	).toBe('resnapshot');
	receiver.accept(
		frame({
			kind: 'subscription.batchBegin',
			batchId: 'recovery',
			mode: 'snapshot',
			snapshotCause: 'open',
			baseRevision: 0,
			targetRevision: 3,
			partCount: 1,
			scope,
		}),
	);
	receiver.accept(
		frame({
			kind: 'subscription.batchPart',
			batchId: 'recovery',
			deliverySequence: 4,
			partIndex: 0,
			part: { operation: 'put', key: '/root/b', revision: 3, value: 'latest' },
		}),
	);
	expect(
		receiver.accept(
			frame({
				kind: 'subscription.batchComplete',
				batchId: 'recovery',
				coveredScope: scope,
			}),
		).kind,
	).toBe('installed');
	expect(receiver.cursor('default')).toBe(3);
	expect(receiver.records('default')).toEqual([{ key: '/root/b', revision: 3, value: 'latest' }]);
});
