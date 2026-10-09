import { bridgeCommWorkerReviewRuntimeSourceFromBatch } from './bridge-comm-worker-review-batch-runtime-source.js';
import type { BridgeCommWorkerReviewRuntimeSource } from './bridge-comm-worker-review-source-diff.js';
import type { BridgeProductBatchFrame } from './bridge-product-batch-wire-contracts.js';
import {
	deriveBridgeProductReviewBatchOrder,
	type BridgeProductReviewBatchTreeRow,
} from './bridge-product-review-batch-order.js';
import {
	bridgeProductReviewBatchRecordSchema,
	type BridgeProductReviewBatchRecord,
} from './bridge-product-review-batch-record-contracts.js';
import type { BridgeProductViewInstallation } from './bridge-product-view-batch-receiver.js';

type ReviewBatchBegin = Extract<
	BridgeProductBatchFrame,
	{ readonly kind: 'subscription.batchBegin' }
>;
type ReviewBatchItem = Extract<BridgeProductReviewBatchRecord, { readonly recordKind: 'item' }>;
type ReviewBatchPublication = Extract<
	BridgeProductReviewBatchRecord,
	{ readonly recordKind: 'publication' }
>;

export interface BridgeCommWorkerReviewBatchPresentation {
	readonly orderedItems: readonly ReviewBatchItem[];
	readonly publication: ReviewBatchPublication;
	readonly runtimeSource: BridgeCommWorkerReviewRuntimeSource;
	readonly targetRevision: number;
	readonly treeRows: readonly BridgeProductReviewBatchTreeRow[];
}

interface InstalledRecord {
	readonly key: string;
	readonly revision: number;
	readonly value: unknown;
}

/** Review's application owner: W4 certifies the bank, then this owner derives and swaps it. */
export class BridgeCommWorkerReviewBatchInstaller {
	#handle: string;
	readonly #deriveOrder: typeof deriveBridgeProductReviewBatchOrder;
	#installEpoch = 0;
	#presentation: BridgeCommWorkerReviewBatchPresentation | null = null;

	constructor(props: {
		readonly handle: string;
		readonly deriveOrder?: typeof deriveBridgeProductReviewBatchOrder;
	}) {
		this.#handle = props.handle;
		this.#deriveOrder = props.deriveOrder ?? deriveBridgeProductReviewBatchOrder;
	}

	get presentation(): BridgeCommWorkerReviewBatchPresentation | null {
		return this.#presentation;
	}

	replaceHandle(handle: string): void {
		this.#installEpoch += 1;
		this.#handle = handle;
		// The old bank remains readable while the successor snapshot is staged.
	}

	/** Run at batch begin, before W4 accepts a retired publication's change. */
	acceptsBegin(begin: ReviewBatchBegin): boolean {
		if (begin.handle !== this.#handle || begin.subscriptionKind !== 'review.metadata') return false;
		if (begin.publicationId === undefined) return false;
		return (
			begin.mode === 'snapshot' ||
			this.#presentation?.publication.publicationId === begin.publicationId
		);
	}

	async install(props: {
		readonly begin: ReviewBatchBegin;
		readonly records: readonly InstalledRecord[];
		readonly applyPresentation?: (presentation: BridgeCommWorkerReviewBatchPresentation) => void;
	}): Promise<'installed' | 'ignored'> {
		const { begin } = props;
		if (!this.acceptsBegin(begin)) return 'ignored';
		const installEpoch = ++this.#installEpoch;
		const { items, publication } = verifyBridgeCommWorkerReviewBatch(props);
		const order = await this.#deriveOrder(items);
		if (installEpoch !== this.#installEpoch || begin.handle !== this.#handle) return 'ignored';
		const candidate = {
			orderedItems: order.orderedItems,
			publication,
			targetRevision: begin.targetRevision,
			treeRows: order.treeRows,
		};
		const presentation = {
			...candidate,
			runtimeSource: bridgeCommWorkerReviewRuntimeSourceFromBatch(candidate),
		};
		props.applyPresentation?.(presentation);
		this.#presentation = presentation;
		return 'installed';
	}
}

/** The Review payload verdict W4 needs before it commits its raw bank. */
export function verifyBridgeCommWorkerReviewBatch(
	installation: Pick<BridgeProductViewInstallation, 'begin' | 'records'>,
): {
	readonly items: readonly ReviewBatchItem[];
	readonly publication: ReviewBatchPublication;
} {
	const { begin } = installation;
	let publication: ReviewBatchPublication | null = null;
	let publicationWireRevision = 0;
	const items: ReviewBatchItem[] = [];
	const itemIds = new Set<string>();
	for (const installed of installation.records) {
		const record = bridgeProductReviewBatchRecordSchema.parse(installed.value);
		if (record.recordKind === 'publication') {
			if (installed.key !== 'publication' || publication !== null) {
				throw new Error('Review batch has an invalid publication key.');
			}
			publication = record;
			publicationWireRevision = installed.revision;
			continue;
		}
		if (installed.key === 'publication' || installed.key !== record.itemId) {
			throw new Error('Review batch item key differs from its identity.');
		}
		if (itemIds.has(record.itemId)) throw new Error('Review batch repeats an item key.');
		itemIds.add(record.itemId);
		items.push(record);
	}
	if (publication === null || publication.publicationId !== begin.publicationId) {
		throw new Error('Review publication does not match its batch.');
	}
	if (
		publicationWireRevision !== publication.revision ||
		publication.revision > begin.targetRevision
	) {
		throw new Error('Review publication revision does not match its installed record.');
	}
	if (publication.displayed === null && items.length > 0) {
		throw new Error('A Review publication without displayed content cannot own items.');
	}
	for (const item of items) validateContentIdentity(item, publication);
	return { items, publication };
}

function validateContentIdentity(item: ReviewBatchItem, publication: ReviewBatchPublication): void {
	for (const role of ['base', 'diff', 'file', 'head'] as const) {
		const content = item.contentByRole[role];
		const lineCount = item.extentByRole[role];
		if (content.state !== 'available') {
			if (lineCount !== null) throw new Error('Unavailable Review content retained an extent.');
			continue;
		}
		const displayed = publication.displayed;
		if (
			displayed === null ||
			content.source.packageId !== displayed.packageId ||
			content.source.reviewGeneration !== displayed.generation ||
			content.source.sourceIdentity !== displayed.query.queryId
		) {
			throw new Error('Review content source belongs to another publication.');
		}
	}
}
