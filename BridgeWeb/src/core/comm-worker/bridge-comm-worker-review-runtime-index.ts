import type { BridgeCommWorkerReviewRuntimeSource } from './bridge-comm-worker-review-source-diff.js';

export function upsertIndexedValue<TKey, TValue>(
	values: TValue[],
	indexByKey: Map<TKey, number>,
	key: TKey,
	value: TValue,
): void {
	const existingIndex = indexByKey.get(key);
	if (existingIndex === undefined) {
		indexByKey.set(key, values.length);
		values.push(value);
		return;
	}
	values[existingIndex] = value;
}

export function removeIndexedValue<TKey, TValue>(
	values: TValue[],
	indexByKey: Map<TKey, number>,
	key: TKey,
	keyForValue: (value: TValue) => TKey,
): void {
	const removedIndex = indexByKey.get(key);
	if (removedIndex === undefined) return;
	const lastValue = values.pop();
	indexByKey.delete(key);
	if (lastValue === undefined || removedIndex === values.length) return;
	values[removedIndex] = lastValue;
	indexByKey.set(keyForValue(lastValue), removedIndex);
}

export function reviewRuntimeItemSignatures(
	source: BridgeCommWorkerReviewRuntimeSource,
): ReadonlyMap<string, string> {
	type ReviewRuntimeItemSignatureInput = {
		contentItem: BridgeCommWorkerReviewRuntimeSource['contentItems'][number] | null;
		contentRequests: BridgeCommWorkerReviewRuntimeSource['contentRequestDescriptors'][number][];
		renderSemantics: BridgeCommWorkerReviewRuntimeSource['renderSemantics'][number] | null;
		sourceLineage: {
			packageId: string;
			reviewGeneration: number;
			sourceIdentity: string;
		} | null;
	};
	const publication = source.reviewPublicationIdentity;
	const sourceLineage =
		publication === null
			? null
			: {
					packageId: publication.packageId,
					reviewGeneration: publication.reviewGeneration,
					sourceIdentity: publication.sourceIdentity,
				};
	const signaturesByItemId = new Map<string, ReviewRuntimeItemSignatureInput>();
	const signatureForItem = (itemId: string): ReviewRuntimeItemSignatureInput => {
		const existing = signaturesByItemId.get(itemId);
		if (existing !== undefined) return existing;
		const created = {
			contentItem: null,
			contentRequests: [],
			renderSemantics: null,
			sourceLineage,
		};
		signaturesByItemId.set(itemId, created);
		return created;
	};
	for (const item of source.contentItems) signatureForItem(item.itemId).contentItem = item;
	for (const descriptor of source.contentRequestDescriptors) {
		signatureForItem(descriptor.itemId).contentRequests.push(descriptor);
	}
	for (const semantics of source.renderSemantics) {
		signatureForItem(semantics.itemId).renderSemantics = semantics;
	}
	return new Map(
		[...signaturesByItemId].map(([itemId, signature]) => [itemId, JSON.stringify(signature)]),
	);
}

/** One semantic change classification for presentation impact and content admission. */
export function reviewRuntimeChangedItemIds(
	previous: BridgeCommWorkerReviewRuntimeSource,
	successor: BridgeCommWorkerReviewRuntimeSource,
): readonly string[] {
	const previousSignatures = reviewRuntimeItemSignatures(previous);
	const successorSignatures = reviewRuntimeItemSignatures(successor);
	return [...new Set([...previousSignatures.keys(), ...successorSignatures.keys()])].filter(
		(itemId): boolean => previousSignatures.get(itemId) !== successorSignatures.get(itemId),
	);
}

export function reviewContentRequestKey(
	descriptor: BridgeCommWorkerReviewRuntimeSource['contentRequestDescriptors'][number],
): string {
	return `${descriptor.itemId}\u0000${descriptor.role}`;
}

export function reviewTreeParentPath(path: string): string | null {
	const separatorIndex = path.lastIndexOf('/');
	return separatorIndex < 0 ? null : path.slice(0, separatorIndex);
}
