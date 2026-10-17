import {
	normalizeAnnotationCatalog,
	type BridgeCommWorkerAnnotationCatalog,
	type BridgeCommWorkerAnnotationCatalogAuthority,
} from './bridge-comm-worker-annotation-catalog-applicator.js';
import {
	bridgeProductCommentCatalogRecordKey,
	bridgeProductCommentCatalogRecordSchema,
} from './bridge-product-comment-catalog-record-contracts.js';
import type { BridgeProductViewInstallation } from './bridge-product-view-batch-receiver.js';

/** Converts one certified W4 bank into the annotation model's current catalog. */
export function installBridgeProductCommentBatch(
	installation: BridgeProductViewInstallation,
	authority: BridgeCommWorkerAnnotationCatalogAuthority,
): BridgeCommWorkerAnnotationCatalog {
	if (
		installation.begin.subscriptionKind !== 'file.annotations' &&
		installation.begin.subscriptionKind !== 'review.annotations'
	)
		throw new Error('A comment installer requires an annotation batch.');
	if (authority.subscriptionId !== installation.begin.subscriptionId) {
		throw new Error('Comment catalog authority differs from its subscription.');
	}
	if (
		installation.begin.scope.kind !== 'comment' ||
		installation.begin.scope.worktreeId !== authority.worktreeId
	) {
		throw new Error('Comment catalog authority differs from its certified worktree scope.');
	}
	const entries = installation.records.map((installed) => {
		const record = bridgeProductCommentCatalogRecordSchema.parse(installed.value);
		if (
			installed.key !== bridgeProductCommentCatalogRecordKey(record) ||
			installed.revision !== record.revision ||
			record.revision > installation.begin.targetRevision
		) {
			throw new Error('Comment catalog record differs from its certified key or revision.');
		}
		return record.entry;
	});
	const normalized = normalizeAnnotationCatalog({
		authority,
		catalogRevision: installation.begin.targetRevision,
		entries,
		transferId: installation.begin.batchId,
	});
	if (normalized.status === 'rejected') {
		throw new Error(`Comment catalog rejected a certified bank: ${normalized.reason}.`);
	}
	return normalized.catalog;
}
