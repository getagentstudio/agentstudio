import {
	BridgeProductMetadataFrameDecoder,
	encodeBridgeProductMetadataFrame,
} from '../../src/core/comm-worker/bridge-product-metadata-frame-codec.js';
import {
	bridgeProductMetadataFrameSchema,
	type BridgeProductMetadataFrame,
} from '../../src/core/comm-worker/bridge-product-session-contracts.js';

type BatchBegin = Extract<BridgeProductMetadataFrame, { readonly kind: 'subscription.batchBegin' }>;
type BatchPart = Extract<BridgeProductMetadataFrame, { readonly kind: 'subscription.batchPart' }>;

export type BridgeSemanticBatchKind =
	| 'file.metadata'
	| 'review.metadata'
	| 'file.annotations'
	| 'review.annotations';

export type BridgeSemanticBatchFaultMode = 'drop' | 'duplicate' | 'reorder' | 'stall';

export interface BridgeSemanticBatchFaultPlan {
	readonly subscriptionKind: BridgeSemanticBatchKind;
	readonly mode: BridgeSemanticBatchFaultMode;
	readonly domain?: string;
	readonly partIndex?: number;
	readonly duplicateVariant?: 'exact' | 'conflicting';
}

export interface BridgeSemanticBatchFaultApplied {
	readonly batchId: string;
	readonly domain: string;
	readonly mode: BridgeSemanticBatchFaultMode;
	readonly subscriptionId: string;
	readonly subscriptionKind: BridgeSemanticBatchKind;
}

interface TargetBatch {
	readonly batchId: string;
	readonly domain: string;
	readonly subscriptionId: string;
}

/** Test-only faults keep data sequences contiguous; keepalives repeat the last forwarded sequence. */
export class BridgeSemanticBatchFaultTransformer {
	readonly #decoder = new BridgeProductMetadataFrameDecoder();
	readonly #onInputFrame: ((frame: BridgeProductMetadataFrame) => void) | undefined;
	readonly #onForwardedFrame: ((frame: BridgeProductMetadataFrame) => void) | undefined;
	#nextDownstreamSequence: number | null = null;
	#plan: BridgeSemanticBatchFaultPlan | null = null;
	#target: TargetBatch | null = null;
	#heldReorderPart: BatchPart | null = null;
	#heldStalledPart: BatchPart | null = null;
	#appliedFault: BridgeSemanticBatchFaultApplied | null = null;
	#appliedFaultWaiter: {
		readonly resolve: (fault: BridgeSemanticBatchFaultApplied) => void;
		readonly reject: (error: Error) => void;
	} | null = null;
	#closed = false;
	readonly #observedKinds = new Set<BridgeSemanticBatchKind>();

	get observedKinds(): readonly BridgeSemanticBatchKind[] {
		return [...this.#observedKinds];
	}

	constructor(
		onInputFrame?: (frame: BridgeProductMetadataFrame) => void,
		onForwardedFrame?: (frame: BridgeProductMetadataFrame) => void,
	) {
		this.#onInputFrame = onInputFrame;
		this.#onForwardedFrame = onForwardedFrame;
	}

	get lastForwardedStreamSequence(): number | null {
		return this.#nextDownstreamSequence === null ? null : this.#nextDownstreamSequence - 1;
	}

	arm(plan: BridgeSemanticBatchFaultPlan): void {
		if (this.#closed) throw new Error('The semantic metadata response is closed.');
		if (this.#plan !== null || this.#heldReorderPart !== null || this.#heldStalledPart !== null) {
			throw new Error('A semantic batch fault is already active.');
		}
		const partIndex = plan.partIndex ?? 0;
		if (!Number.isSafeInteger(partIndex) || partIndex < 0) {
			throw new Error('A semantic batch fault needs a nonnegative part index.');
		}
		if (plan.duplicateVariant !== undefined && plan.mode !== 'duplicate') {
			throw new Error('Only a duplicate fault accepts a duplicate variant.');
		}
		this.#plan = plan;
		this.#target = null;
		this.#appliedFault = null;
	}

	push(chunk: Uint8Array): readonly Uint8Array[] {
		const forwarded: Uint8Array[] = [];
		for (const frame of this.#decoder.push(chunk)) {
			this.#onInputFrame?.(frame);
			this.#forwardFrame(frame, forwarded);
		}
		return forwarded;
	}

	releaseStalledPart(): readonly Uint8Array[] {
		const heldPart = this.#heldStalledPart;
		if (heldPart === null) throw new Error('No stalled batch part is held.');
		this.#heldStalledPart = null;
		return [this.#encodeForwarded(heldPart)];
	}

	snapshotAppliedFault(): BridgeSemanticBatchFaultApplied | null {
		return this.#appliedFault;
	}

	waitForAppliedFault(): Promise<BridgeSemanticBatchFaultApplied> {
		if (this.#appliedFault !== null) return Promise.resolve(this.#appliedFault);
		if (this.#closed) return Promise.reject(new Error('The semantic metadata response is closed.'));
		if (this.#appliedFaultWaiter !== null) {
			throw new Error('A semantic batch fault waiter is already registered.');
		}
		return new Promise((resolve, reject): void => {
			this.#appliedFaultWaiter = { resolve, reject };
		});
	}

	close(): void {
		this.#closed = true;
		this.#appliedFaultWaiter?.reject(
			new Error('The semantic metadata response closed before the fault applied.'),
		);
		this.#appliedFaultWaiter = null;
	}

	finish(): void {
		this.#decoder.finish();
	}

	#forwardFrame(frame: BridgeProductMetadataFrame, forwarded: Uint8Array[]): void {
		if (frame.kind === 'subscription.batchBegin') this.#selectTarget(frame);
		if (frame.kind === 'subscription.batchPart' && this.#isTargetPart(frame)) {
			this.#forwardTargetPart(frame, forwarded);
			return;
		}
		if (frame.kind === 'subscription.batchComplete' && this.#isTargetBatch(frame)) {
			if (this.#heldReorderPart !== null) {
				forwarded.push(this.#encodeForwarded(this.#heldReorderPart));
				this.#heldReorderPart = null;
			}
			this.#target = null;
		}
		forwarded.push(this.#encodeForwarded(frame));
	}

	#selectTarget(begin: BatchBegin): void {
		if (isSemanticBatchKind(begin.subscriptionKind))
			this.#observedKinds.add(begin.subscriptionKind);
		const plan = this.#plan;
		if (plan === null || this.#target !== null) return;
		if (begin.subscriptionKind !== plan.subscriptionKind) return;
		if (plan.domain !== undefined && begin.domain !== plan.domain) return;
		const requiredPartCount = (plan.partIndex ?? 0) + (plan.mode === 'reorder' ? 2 : 1);
		if (begin.partCount < requiredPartCount) return;
		this.#target = {
			batchId: begin.batchId,
			domain: begin.domain,
			subscriptionId: begin.subscriptionId,
		};
	}

	#isTargetBatch(frame: { readonly batchId: string; readonly domain: string }): boolean {
		return this.#target?.batchId === frame.batchId && this.#target.domain === frame.domain;
	}

	#isTargetPart(frame: BatchPart): boolean {
		return this.#plan !== null && this.#isTargetBatch(frame);
	}

	#forwardTargetPart(frame: BatchPart, forwarded: Uint8Array[]): void {
		const plan = this.#plan;
		if (plan === null) throw new Error('Target batch lost its fault plan.');
		const chosenIndex = plan.partIndex ?? 0;
		if (plan.mode === 'reorder' && this.#heldReorderPart !== null) {
			if (frame.partIndex === chosenIndex + 1) {
				forwarded.push(this.#encodeForwarded(frame));
				forwarded.push(this.#encodeForwarded(this.#heldReorderPart));
				this.#heldReorderPart = null;
				this.#markApplied(plan);
				return;
			}
			forwarded.push(this.#encodeForwarded(frame));
			return;
		}
		if (frame.partIndex !== chosenIndex) {
			forwarded.push(this.#encodeForwarded(frame));
			return;
		}
		switch (plan.mode) {
			case 'drop':
				this.#markApplied(plan);
				return;
			case 'duplicate':
				forwarded.push(this.#encodeForwarded(frame));
				forwarded.push(
					this.#encodeForwarded(
						plan.duplicateVariant === 'conflicting' ? conflictingPart(frame) : frame,
					),
				);
				this.#markApplied(plan);
				return;
			case 'reorder':
				this.#heldReorderPart = frame;
				return;
			case 'stall':
				this.#heldStalledPart = frame;
				this.#markApplied(plan);
				return;
		}
	}

	#markApplied(plan: BridgeSemanticBatchFaultPlan): void {
		const target = this.#target;
		if (target === null) throw new Error('A semantic fault applied without a target batch.');
		this.#appliedFault = {
			batchId: target.batchId,
			domain: target.domain,
			mode: plan.mode,
			subscriptionId: target.subscriptionId,
			subscriptionKind: plan.subscriptionKind,
		};
		this.#plan = null;
		this.#target = null;
		this.#appliedFaultWaiter?.resolve(this.#appliedFault);
		this.#appliedFaultWaiter = null;
	}

	#encodeForwarded(frame: BridgeProductMetadataFrame): Uint8Array {
		const isKeepalive = frame.kind === 'stream.keepalive';
		const streamSequence = isKeepalive
			? this.#nextDownstreamSequence === null
				? frame.streamSequence
				: this.#nextDownstreamSequence - 1
			: (this.#nextDownstreamSequence ?? frame.streamSequence);
		if (!isKeepalive) this.#nextDownstreamSequence = streamSequence + 1;
		this.#onForwardedFrame?.(frame);
		return encodeBridgeProductMetadataFrame({ ...frame, streamSequence });
	}
}

function isSemanticBatchKind(kind: string): kind is BridgeSemanticBatchKind {
	return (
		kind === 'file.metadata' ||
		kind === 'review.metadata' ||
		kind === 'file.annotations' ||
		kind === 'review.annotations'
	);
}

function conflictingPart(part: BatchPart): BatchPart {
	const conflicted = bridgeProductMetadataFrameSchema.parse({
		...part,
		part: { ...part.part, key: `${part.part.key}.fault-proxy-conflict` },
	});
	if (conflicted.kind !== 'subscription.batchPart') {
		throw new Error('A conflicting duplicate must remain a batch part.');
	}
	return conflicted;
}
