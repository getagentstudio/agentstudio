import { expect } from 'vitest';

import {
	bridgeProductBatchFrameSchema,
	type BridgeProductBatchFrame,
} from './bridge-product-batch-wire-contracts.js';
import {
	BridgeProductMetadataFrameDecoder,
	encodeBridgeProductMetadataFrame,
} from './bridge-product-metadata-frame-codec.js';

type BatchBegin = Extract<BridgeProductBatchFrame, { readonly kind: 'subscription.batchBegin' }>;
type BatchPart = Extract<BridgeProductBatchFrame, { readonly kind: 'subscription.batchPart' }>;
export type ViewScope = BatchBegin['scope'];
export type DataKind = BatchBegin['subscriptionKind'];

interface BeginProps {
	readonly batchId: string;
	readonly baseRevision?: number;
	readonly targetRevision: number;
	readonly partCount: number;
	readonly snapshotCause:
		| import('./bridge-product-batch-wire-contracts.js').BridgeProductSnapshotCause
		| undefined;
	readonly mode?: BatchBegin['mode'];
	readonly scope?: ViewScope;
	readonly scopeRevision?: number;
}

interface PartProps {
	readonly batchId: string;
	readonly deliverySequence: number;
	readonly partIndex?: number;
	readonly scopeRevision?: number;
	readonly part: BatchPart['part'];
}

export class ViewContractWireFixture {
	readonly kind: DataKind;
	readonly handle = 'contract-handle';
	readonly incarnation = 'contract-incarnation';
	readonly domain = 'default';
	readonly subscriptionId = 'contract-subscription';
	readonly scope: ViewScope;
	readonly expandedScope: ViewScope;
	readonly #decoder = new BridgeProductMetadataFrameDecoder();
	#sequence = 0;

	constructor(kind: DataKind) {
		this.kind = kind;
		this.scope = viewScope(kind, false);
		this.expandedScope = viewScope(kind, true);
	}

	begin(props: BeginProps): BridgeProductBatchFrame {
		return bridgeProductBatchFrameSchema.parse({
			...this.#identity(props.batchId, props.scopeRevision),
			kind: 'subscription.batchBegin',
			baseRevision: props.baseRevision ?? 0,
			targetRevision: props.targetRevision,
			mode: props.mode ?? 'snapshot',
			...(props.snapshotCause === undefined ? {} : { snapshotCause: props.snapshotCause }),
			partCount: props.partCount,
			scope: props.scope ?? this.scope,
			...(this.kind === 'review.metadata'
				? { publicationId: '00000000-0000-7000-8000-000000000011' }
				: {}),
		});
	}
	part(props: PartProps): BridgeProductBatchFrame {
		return bridgeProductBatchFrameSchema.parse({
			...this.#identity(props.batchId, props.scopeRevision),
			kind: 'subscription.batchPart',
			partIndex: props.partIndex ?? 0,
			deliverySequence: props.deliverySequence,
			part: props.part,
		});
	}
	complete(
		batchId: string,
		coveredScope: ViewScope = this.scope,
		scopeRevision = 0,
	): BridgeProductBatchFrame {
		return bridgeProductBatchFrameSchema.parse({
			...this.#identity(batchId, scopeRevision),
			kind: 'subscription.batchComplete',
			coveredScope,
		});
	}
	roundTrip(frame: BridgeProductBatchFrame): BridgeProductBatchFrame {
		const bytes = encodeBridgeProductMetadataFrame(frame);
		expect(this.#decoder.push(bytes.subarray(0, 2))).toEqual([]);
		expect(this.#decoder.push(bytes.subarray(2, bytes.byteLength - 1))).toEqual([]);
		const frames = this.#decoder.push(bytes.subarray(bytes.byteLength - 1));
		expect(frames).toHaveLength(1);
		return bridgeProductBatchFrameSchema.parse(frames[0]);
	}
	finish(): void {
		this.#decoder.finish();
	}
	#identity(batchId: string, scopeRevision = 0): Readonly<Record<string, unknown>> {
		return {
			batchId,
			domain: this.domain,
			handle: this.handle,
			incarnation: this.incarnation,
			metadataStreamId: 'contract-stream',
			paneSessionId: 'contract-pane',
			scopeRevision,
			streamSequence: ++this.#sequence,
			subscriptionId: this.subscriptionId,
			subscriptionKind: this.kind,
			wireVersion: 2,
			workerInstanceId: 'contract-worker',
		};
	}
}

function viewScope(kind: DataKind, expanded: boolean): ViewScope {
	if (kind === 'file.metadata')
		return {
			changeFilter: { kind: 'none' },
			interests: [
				{ lane: 'visible', paths: expanded ? ['src/a', 'src/b', 'docs/new'] : ['src/a', 'src/b'] },
			],
			kind: 'file',
			pathScope: [],
			...(expanded ? {} : { prefix: 'src/' }),
		};
	if (kind === 'review.metadata')
		return {
			interests: [
				{
					lane: 'visible',
					itemIds: expanded ? ['src/a', 'src/b', 'docs/new'] : ['src/a', 'src/b'],
				},
			],
			kind: 'review',
			...(expanded ? {} : { prefix: 'src/' }),
		};
	return {
		kind: 'comment',
		sessionIds: expanded ? ['src', 'docs'] : ['src'],
		worktreeId: 'contract-worktree',
	};
}

export function scopeCoversKey(scope: ViewScope, key: string): boolean {
	return scope.kind === 'comment'
		? scope.sessionIds.includes(key.split('/')[0] ?? '')
		: scope.prefix === undefined || key.startsWith(scope.prefix);
}
