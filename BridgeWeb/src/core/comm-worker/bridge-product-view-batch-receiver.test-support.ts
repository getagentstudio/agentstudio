import {
	bridgeProductBatchFrameSchema,
	type BridgeProductBatchFrame,
} from './bridge-product-batch-wire-contracts.js';
import type { BridgeProductDeadlineClock } from './bridge-product-deadline-clock.js';

export const identity = {
	batchId: 'batch-1',
	domain: 'default',
	handle: 'handle-1',
	incarnation: 'incarnation-1',
	metadataStreamId: 'stream-1',
	paneSessionId: 'pane-1',
	scopeRevision: 0,
	streamSequence: 1,
	subscriptionId: 'subscription-1',
	subscriptionKind: 'review.metadata',
	wireVersion: 2,
	workerInstanceId: 'worker-1',
} as const;

let nextFixtureStreamSequence = 0;

function fixtureStreamSequence(): number {
	nextFixtureStreamSequence += 1;
	return nextFixtureStreamSequence;
}

export function begin(props: {
	readonly batchId?: string;
	readonly base?: number;
	readonly domain?: string;
	readonly handle?: string;
	readonly incarnation?: string;
	readonly snapshotCause:
		| import('./bridge-product-batch-wire-contracts.js').BridgeProductSnapshotCause
		| undefined;
	readonly mode?: 'snapshot' | 'change' | 'coverage';
	readonly partCount: number;
	readonly requiresCollection?: number;
	readonly scope?: Readonly<Record<string, unknown>>;
	readonly scopeRevision?: number;
	readonly target: number;
}): BridgeProductBatchFrame {
	return bridgeProductBatchFrameSchema.parse({
		...identity,
		streamSequence: fixtureStreamSequence(),
		batchId: props.batchId ?? identity.batchId,
		baseRevision: props.base ?? 0,
		domain: props.domain ?? identity.domain,
		handle: props.handle ?? identity.handle,
		incarnation: props.incarnation ?? identity.incarnation,
		kind: 'subscription.batchBegin',
		mode: props.mode ?? 'snapshot',
		...(props.snapshotCause === undefined ? {} : { snapshotCause: props.snapshotCause }),
		partCount: props.partCount,
		publicationId: '00000000-0000-7000-8000-000000000011',
		...(props.requiresCollection === undefined
			? {}
			: { requiresCollection: props.requiresCollection }),
		scope: props.scope ?? { kind: 'review', interests: [] },
		scopeRevision: props.scopeRevision ?? 0,
		targetRevision: props.target,
	});
}

export function part(props: {
	readonly batchId?: string;
	readonly deliverySequence?: number;
	readonly domain?: string;
	readonly handle?: string;
	readonly incarnation?: string;
	readonly key: string;
	readonly partIndex?: number;
	readonly revision: number;
	readonly scopeRevision?: number;
	readonly value: string;
}): BridgeProductBatchFrame {
	return bridgeProductBatchFrameSchema.parse({
		...identity,
		streamSequence: fixtureStreamSequence(),
		batchId: props.batchId ?? identity.batchId,
		deliverySequence: props.deliverySequence ?? props.revision,
		domain: props.domain ?? identity.domain,
		handle: props.handle ?? identity.handle,
		incarnation: props.incarnation ?? identity.incarnation,
		kind: 'subscription.batchPart',
		part: { key: props.key, operation: 'put', revision: props.revision, value: props.value },
		partIndex: props.partIndex ?? 0,
		scopeRevision: props.scopeRevision ?? 0,
	});
}

export function deletion(props: {
	readonly batchId: string;
	readonly key: string;
	readonly revision: number;
}): BridgeProductBatchFrame {
	return bridgeProductBatchFrameSchema.parse({
		...identity,
		streamSequence: fixtureStreamSequence(),
		batchId: props.batchId,
		deliverySequence: props.revision,
		kind: 'subscription.batchPart',
		part: { key: props.key, operation: 'delete', revision: props.revision },
		partIndex: 0,
	});
}

export function complete(props: {
	readonly batchId?: string;
	readonly coveredScope?: Readonly<Record<string, unknown>>;
	readonly domain?: string;
	readonly handle?: string;
	readonly incarnation?: string;
	readonly scopeRevision?: number;
}): BridgeProductBatchFrame {
	return bridgeProductBatchFrameSchema.parse({
		...identity,
		streamSequence: fixtureStreamSequence(),
		batchId: props.batchId ?? identity.batchId,
		coveredScope: props.coveredScope ?? { kind: 'review', interests: [] },
		domain: props.domain ?? identity.domain,
		handle: props.handle ?? identity.handle,
		incarnation: props.incarnation ?? identity.incarnation,
		kind: 'subscription.batchComplete',
		scopeRevision: props.scopeRevision ?? 0,
	});
}

export class ControlledBatchDeadlineClock implements BridgeProductDeadlineClock {
	readonly deadlines: Array<{ active: boolean; fire: () => void }> = [];
	peakActiveDeadlineCount = 0;

	schedule(_delayMilliseconds: number, onDeadline: () => void): () => void {
		const deadline = {
			active: true,
			fire: (): void => {
				if (!deadline.active) throw new Error('Expected an armed batch deadline.');
				deadline.active = false;
				onDeadline();
			},
		};
		this.deadlines.push(deadline);
		this.peakActiveDeadlineCount = Math.max(
			this.peakActiveDeadlineCount,
			this.deadlines.filter((candidate) => candidate.active).length,
		);
		return (): void => {
			deadline.active = false;
		};
	}

	activeDeadline(): (typeof this.deadlines)[number] {
		const deadline = this.deadlines.find((entry) => entry.active);
		if (deadline === undefined) throw new Error('Expected an armed batch deadline.');
		return deadline;
	}
}
