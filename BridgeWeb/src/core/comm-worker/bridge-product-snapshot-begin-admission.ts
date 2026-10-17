import type { BridgeProductBatchFrameSinks } from './bridge-product-batch-frame-router.js';
import type { BridgeProductBatchFrame } from './bridge-product-batch-wire-contracts.js';
import type { BridgeProductViewScopeOwner } from './bridge-product-view-scope-owner.js';

/** Admission precedes W4 staging; observers still receive the current begin's cause. */
export function admitBridgeProductSnapshotBegin(props: {
	readonly frame: Extract<BridgeProductBatchFrame, { readonly kind: 'subscription.batchBegin' }>;
	readonly owner: Pick<BridgeProductViewScopeOwner, 'observeSnapshotBegin'>;
	readonly notify: BridgeProductBatchFrameSinks['snapshotBeginAccepted'];
}): boolean {
	const frame = props.frame;
	if (frame.snapshotCause === undefined) throw new Error('Snapshot cause is required.');
	const admitted = props.owner.observeSnapshotBegin({
		...frame,
		snapshotCause: frame.snapshotCause,
	});
	props.notify?.(frame);
	return admitted;
}
