import type {
	BridgeMainCodeViewItem,
	BridgeMainCodeViewItemPatch,
	BridgeMainReviewTreeDisplayRow,
} from './bridge-main-render-snapshot-store.js';
import {
	applyReviewDisplayPatchEventInPlace,
	bridgeMainReviewRenderCopyInvalidationItemIds,
	bridgeMainReviewRetainedRenderCopyItemIds,
	invalidateBridgeMainReviewRenderCopies,
	reconcileBridgeMainReviewRenderCopyMetadata,
	type BridgeMainReviewDisplayPatchEffect,
	type MutableBridgeMainRenderSnapshot,
} from './bridge-main-review-display-state.js';
import type {
	BridgeWorkerReviewCandidateStartDisposition,
	BridgeWorkerReviewDisplayPatchEvent,
	BridgeWorkerSlicePatch,
} from './bridge-worker-contracts.js';
import {
	BRIDGE_WORKER_REVIEW_AFFECTED_STABLE_FILE_IDENTITY_LIMIT,
	type BridgeWorkerReviewPreDeliveryPresentationClass,
} from './bridge-worker-review-publication-contracts.js';
import {
	compareReviewMetadataLineages,
	type ReviewMetadataLineage,
} from './bridge-worker-review-publication-lineage.js';

export type BridgeMainReviewPublicationIdentity = ReviewMetadataLineage;
export type BridgeMainReviewCandidateRole = 'installing' | 'provisional' | 'updateReady';
export type BridgeMainReviewEffectivePresentationClass =
	| { readonly kind: 'ordinary' }
	| {
			readonly kind: 'promoted';
			readonly reason:
				| Extract<
						BridgeWorkerReviewPreDeliveryPresentationClass,
						{ readonly kind: 'promoted' }
				  >['reason']
				| 'activeAnchor';
	  };
export interface BridgeMainReviewCandidatePresentation {
	readonly affectedStableFileIdentities: readonly string[];
	readonly effectivePresentationClass: BridgeMainReviewEffectivePresentationClass;
	readonly identity: BridgeMainReviewPublicationIdentity;
	readonly role: BridgeMainReviewCandidateRole;
	readonly startDisposition: BridgeWorkerReviewCandidateStartDisposition;
}
interface BridgeMainReviewFailureFacts {
	readonly affectedStableFileIdentities: readonly string[];
	readonly identity: BridgeMainReviewPublicationIdentity;
	readonly retryable: boolean;
}
export type BridgeMainReviewFailurePresentation = BridgeMainReviewFailureFacts &
	(
		| {
				readonly kind: 'installation';
				readonly presentationClass: BridgeMainReviewEffectivePresentationClass;
		  }
		| {
				readonly kind: 'promotedRefresh';
				readonly presentationClass: Extract<
					BridgeMainReviewEffectivePresentationClass,
					{ readonly kind: 'promoted' }
				>;
		  }
	);
export interface BridgeMainReviewRefreshPresentation {
	readonly activeIdentity: BridgeMainReviewPublicationIdentity | null;
	readonly candidate: BridgeMainReviewCandidatePresentation | null;
	readonly failure: BridgeMainReviewFailurePresentation | null;
}
export type BridgeMainReviewCandidateWorkerPatch = Exclude<
	BridgeWorkerSlicePatch,
	{ readonly slice: 'selection' | 'viewport' }
>;
export interface BridgeMainReviewCandidateSnapshotUpdate {
	readonly codeViewItemPatches?: readonly BridgeMainCodeViewItemPatch[];
	readonly identity: BridgeMainReviewPublicationIdentity;
	readonly workerPatches?: readonly BridgeMainReviewCandidateWorkerPatch[];
}
export interface BridgeMainReviewCandidateStore {
	readonly getReviewRefreshPresentation: () => BridgeMainReviewRefreshPresentation;
	readonly subscribeReviewCandidateSource: (listener: () => void) => () => void;
	readonly getReviewCandidateSourceDiagnostic: () => {
		readonly publicationId: string;
		readonly status: string | null;
	} | null;
	readonly subscribeReviewRefreshPresentation: (listener: () => void) => () => void;
	readonly setReviewCandidateCodeViewItem: (props: {
		readonly identity: BridgeMainReviewPublicationIdentity;
		readonly itemId: string;
		readonly item: BridgeMainCodeViewItem;
	}) => boolean;
	readonly startReviewCandidate: (props: {
		readonly disposition: BridgeWorkerReviewCandidateStartDisposition;
		readonly identity: BridgeMainReviewPublicationIdentity;
	}) => boolean;
	readonly stageReviewCandidateDisplayEvent: (props: {
		readonly event: BridgeWorkerReviewDisplayPatchEvent;
		readonly identity: BridgeMainReviewPublicationIdentity;
	}) => boolean;
	readonly applyReviewCandidateSnapshotUpdate: (
		update: BridgeMainReviewCandidateSnapshotUpdate,
	) => boolean;
	readonly escalateReviewCandidatePresentation: (props: {
		readonly identity: BridgeMainReviewPublicationIdentity;
		readonly presentationClass: Extract<
			BridgeMainReviewEffectivePresentationClass,
			{ readonly kind: 'promoted' }
		>;
	}) => boolean;
	readonly markReviewCandidateReady: (props: {
		readonly identity: BridgeMainReviewPublicationIdentity;
		readonly role: BridgeMainReviewCandidateRole;
	}) => boolean;
	readonly promoteReviewCandidate: (identity: BridgeMainReviewPublicationIdentity) => boolean;
	readonly discardReviewCandidate: (identity?: BridgeMainReviewPublicationIdentity) => boolean;
	readonly failReviewCandidate: (props: {
		readonly identity: BridgeMainReviewPublicationIdentity;
		readonly retryable: boolean;
	}) => boolean;
	readonly clearReviewCandidateFailure: () => boolean;
	readonly failReviewInstallation: (identity: BridgeMainReviewPublicationIdentity) => boolean;
}
export interface MutableBridgeMainReviewCandidateBank {
	effectivePresentationClass: BridgeMainReviewEffectivePresentationClass;
	readonly identity: BridgeMainReviewPublicationIdentity;
	readonly promotionImpact: MutableBridgeMainReviewCandidatePromotionImpact;
	readonly reviewItemIndexById: Map<string, number>;
	readonly reviewTreeRowById: Map<string, BridgeMainReviewTreeDisplayRow>;
	role: BridgeMainReviewCandidateRole;
	snapshot: MutableBridgeMainRenderSnapshot;
	readonly startDisposition: BridgeWorkerReviewCandidateStartDisposition;
}

export interface MutableBridgeMainReviewCandidatePromotionImpact {
	comparisonChanged: boolean;
	readonly itemIds: Set<string>;
	readonly itemOrderMutations: BridgeMainReviewDisplayPatchEffect['itemOrderMutations'][number][];
	reset: boolean;
	sourceChanged: boolean;
	readonly treeRowIds: Set<string>;
	readonly treeRowOrderMutations: BridgeMainReviewDisplayPatchEffect['treeRowOrderMutations'][number][];
}

export class BridgeMainReviewCandidateBankOwner {
	#activeIdentity: BridgeMainReviewPublicationIdentity | null = null;
	#candidate: MutableBridgeMainReviewCandidateBank | null = null;
	#failure: BridgeMainReviewFailurePresentation | null = null;
	#presentation: BridgeMainReviewRefreshPresentation = presentation(null, null, null);

	get currentPresentation(): BridgeMainReviewRefreshPresentation {
		return this.#presentation;
	}

	get currentCandidateSourceDiagnostic(): {
		readonly publicationId: string;
		readonly status: string | null;
	} | null {
		const candidate = this.#candidate;
		if (candidate === null) return null;
		return {
			publicationId: candidate.identity.publicationId,
			status: candidate.snapshot.reviewSourceSlice?.status ?? null,
		};
	}

	stage(props: {
		readonly activeSnapshot: MutableBridgeMainRenderSnapshot;
		readonly event: BridgeWorkerReviewDisplayPatchEvent;
		readonly identity: BridgeMainReviewPublicationIdentity;
	}): boolean {
		const candidate = this.#candidate;
		if (candidate === null || !isExact(props.identity, candidate.identity)) return false;
		const replacesWorkerDerivationEpoch =
			candidate.snapshot.reviewDisplayFreshness !== null &&
			props.event.epoch > candidate.snapshot.reviewDisplayFreshness.epoch;
		const effect = applyReviewDisplayPatchEventInPlace({
			event: props.event,
			reviewItemIndexById: candidate.reviewItemIndexById,
			reviewTreeRowById: candidate.reviewTreeRowById,
			snapshot: candidate.snapshot,
		});
		if (effect === null) return false;
		this.#candidate = candidate;
		const invalidation = invalidateBridgeMainReviewRenderCopies({
			itemIds: bridgeMainReviewRenderCopyInvalidationItemIds({
				currentItemsById: candidate.snapshot.reviewItemById,
				previousItemsById: effect.previousItemsById,
				preserveProjectionHiddenCopies: false,
				retainedRenderCopyItemIds: bridgeMainReviewRetainedRenderCopyItemIds(candidate.snapshot),
				replacesWorkerDerivationEpoch,
			}),
			selectionItemIds: [...effect.itemIds],
			snapshot: candidate.snapshot,
		});
		candidate.snapshot = reconcileBridgeMainReviewRenderCopyMetadata({
			currentItemsById: candidate.snapshot.reviewItemById,
			previousItemsById: effect.previousItemsById,
			snapshot: invalidation.snapshot,
		}).snapshot;
		accumulateCandidatePromotionImpact(candidate.promotionImpact, effect);
		return true;
	}

	start(props: {
		readonly activeSnapshot: MutableBridgeMainRenderSnapshot;
		readonly disposition: BridgeWorkerReviewCandidateStartDisposition;
		readonly identity: BridgeMainReviewPublicationIdentity;
	}): boolean {
		if (this.#activeIdentity !== null && !isNewer(props.identity, this.#activeIdentity)) {
			return false;
		}
		const reoffersFailedInstallation =
			this.#failure?.kind === 'installation' && isExact(props.identity, this.#failure.identity);
		if (
			this.#failure !== null &&
			!isNewer(props.identity, this.#failure.identity) &&
			!reoffersFailedInstallation
		) {
			return false;
		}
		const candidate = this.#candidate;
		if (candidate !== null) {
			if (!isNewer(props.identity, candidate.identity) || candidate.role === 'installing') {
				return false;
			}
		}
		if (
			candidate !== null &&
			props.disposition.kind === 'sameSource' &&
			candidateCanContinueIntoSuccessor(candidate, props)
		) {
			this.#candidate = cloneSuccessorCandidate(candidate, props.identity, props.disposition);
		} else {
			this.#candidate = cloneCandidate(props.activeSnapshot, props.identity, props.disposition);
		}
		if (!reoffersFailedInstallation) this.#failure = null;
		this.#refresh();
		return true;
	}

	update(
		identity: BridgeMainReviewPublicationIdentity,
		apply: (
			snapshot: MutableBridgeMainRenderSnapshot,
			containsItem: (itemId: string) => boolean,
		) => MutableBridgeMainRenderSnapshot | null,
	): boolean {
		if (this.#candidate === null || !isExact(identity, this.#candidate.identity)) return false;
		const nextSnapshot = apply(
			this.#candidate.snapshot,
			(itemId): boolean => this.#candidate?.reviewItemIndexById.has(itemId) === true,
		);
		if (nextSnapshot === null) return false;
		this.#candidate.snapshot = nextSnapshot;
		return true;
	}

	markReady(props: {
		readonly identity: BridgeMainReviewPublicationIdentity;
		readonly role: BridgeMainReviewCandidateRole;
	}): boolean {
		if (
			this.#candidate === null ||
			!isExact(props.identity, this.#candidate.identity) ||
			(this.#candidate.role === 'installing' && props.role !== 'installing') ||
			this.#candidate.snapshot.reviewSourceSlice?.status !== 'ready'
		)
			return false;
		this.#candidate.role = props.role;
		this.#refresh();
		return true;
	}

	escalatePresentation(props: {
		readonly identity: BridgeMainReviewPublicationIdentity;
		readonly presentationClass: Extract<
			BridgeMainReviewEffectivePresentationClass,
			{ readonly kind: 'promoted' }
		>;
	}): boolean {
		const candidate = this.#candidate;
		if (
			candidate === null ||
			!isExact(props.identity, candidate.identity) ||
			candidate.role === 'installing' ||
			candidate.startDisposition.kind !== 'sameSource'
		)
			return false;
		if (candidate.effectivePresentationClass.kind === 'promoted') return true;
		candidate.effectivePresentationClass = props.presentationClass;
		this.#refresh();
		return true;
	}

	promote(
		identity: BridgeMainReviewPublicationIdentity,
	): MutableBridgeMainReviewCandidateBank | null {
		if (
			this.#candidate === null ||
			!isExact(identity, this.#candidate.identity) ||
			this.#candidate.snapshot.reviewSourceSlice?.status !== 'ready'
		)
			return null;
		const candidate = this.#candidate;
		this.#activeIdentity = candidate.identity;
		this.#candidate = null;
		this.#failure = null;
		this.#refresh();
		return candidate;
	}

	discard(identity?: BridgeMainReviewPublicationIdentity): boolean {
		if (
			this.#candidate === null ||
			(identity !== undefined && !isExact(identity, this.#candidate.identity))
		)
			return false;
		this.#candidate = null;
		this.#refresh();
		return true;
	}

	fail(props: {
		readonly identity: BridgeMainReviewPublicationIdentity;
		readonly retryable: boolean;
	}): boolean {
		const candidate = this.#candidate;
		if (
			candidate === null ||
			!isExact(props.identity, candidate.identity) ||
			candidate.role === 'installing'
		)
			return false;
		this.#candidate = null;
		this.#failure = promotedFailure(candidate, props.retryable);
		this.#refresh();
		return true;
	}

	clearFailure(): boolean {
		if (this.#failure === null) return false;
		this.#failure = null;
		this.#refresh();
		return true;
	}

	failInstallation(identity: BridgeMainReviewPublicationIdentity): boolean {
		const candidate = this.#candidate;
		if (
			candidate === null ||
			candidate.role !== 'installing' ||
			!isExact(identity, candidate.identity)
		)
			return false;
		this.#candidate = null;
		this.#failure = {
			affectedStableFileIdentities:
				candidate.startDisposition.kind === 'sameSource'
					? candidate.startDisposition.affectedStableFileIdentities
					: [],
			identity: candidate.identity,
			kind: 'installation',
			presentationClass: candidate.effectivePresentationClass,
			retryable: true,
		};
		this.#refresh();
		return true;
	}

	dispose(): void {
		this.#activeIdentity = null;
		this.#candidate = null;
		this.#failure = null;
		this.#refresh();
	}

	#refresh(): void {
		this.#presentation = presentation(this.#activeIdentity, this.#candidate, this.#failure);
	}
}

export function mergeBridgeMainReviewCandidateSnapshot(props: {
	readonly activeSnapshot: MutableBridgeMainRenderSnapshot;
	readonly candidateSnapshot: MutableBridgeMainRenderSnapshot;
}): MutableBridgeMainRenderSnapshot {
	const oldIds = Object.keys(props.activeSnapshot.reviewItemById);
	const newIds = Object.keys(props.candidateSnapshot.reviewItemById);
	const selectedId = props.activeSnapshot.selectionSlice.selectedItemId;
	const selectionSlice =
		selectedId === null || props.candidateSnapshot.reviewItemById[selectedId] !== undefined
			? props.activeSnapshot.selectionSlice
			: { selectedItemId: null, source: null };
	const viewportValid = props.activeSnapshot.viewportSlice.visibleItemIds.every(
		(itemId): boolean => props.candidateSnapshot.reviewItemById[itemId] !== undefined,
	);
	const { reviewComparison: _oldComparison, ...nonReviewChrome } =
		props.activeSnapshot.panelChromeSlice;
	const nextComparison = props.candidateSnapshot.panelChromeSlice.reviewComparison;
	return {
		...props.activeSnapshot,
		codeViewItemsById: mergeRecords(
			props.activeSnapshot.codeViewItemsById,
			props.candidateSnapshot.codeViewItemsById,
			oldIds,
			newIds,
		),
		contentAvailabilityById: mergeRecords(
			props.activeSnapshot.contentAvailabilityById,
			props.candidateSnapshot.contentAvailabilityById,
			oldIds,
			newIds,
		),
		panelChromeSlice:
			nextComparison === undefined
				? nonReviewChrome
				: { ...nonReviewChrome, reviewComparison: nextComparison },
		reviewDisplayFreshness: props.candidateSnapshot.reviewDisplayFreshness,
		reviewItemById: props.candidateSnapshot.reviewItemById,
		reviewItemIdsByIndex: props.candidateSnapshot.reviewItemIdsByIndex,
		reviewSourceSlice: props.candidateSnapshot.reviewSourceSlice,
		reviewTreeRowsByIndex: props.candidateSnapshot.reviewTreeRowsByIndex,
		rowPaintById: mergeRecords(
			props.activeSnapshot.rowPaintById,
			props.candidateSnapshot.rowPaintById,
			oldIds,
			newIds,
		),
		selectionSlice,
		viewportSlice: viewportValid
			? props.activeSnapshot.viewportSlice
			: { firstVisibleIndex: 0, lastVisibleIndex: 0, visibleItemIds: [] },
	};
}

function cloneCandidate(
	snapshot: MutableBridgeMainRenderSnapshot,
	identity: BridgeMainReviewPublicationIdentity,
	startDisposition: BridgeWorkerReviewCandidateStartDisposition,
): MutableBridgeMainReviewCandidateBank {
	return {
		effectivePresentationClass:
			startDisposition.kind === 'sameSource'
				? startDisposition.presentationClass
				: { kind: 'ordinary' },
		identity,
		promotionImpact: emptyCandidatePromotionImpact(),
		reviewItemIndexById: itemIndex(snapshot.reviewItemIdsByIndex),
		reviewTreeRowById: rowIndex(snapshot.reviewTreeRowsByIndex),
		role: 'provisional',
		startDisposition,
		snapshot: {
			...snapshot,
			codeViewItemsById: { ...snapshot.codeViewItemsById },
			contentAvailabilityById: { ...snapshot.contentAvailabilityById },
			panelChromeSlice: { ...snapshot.panelChromeSlice },
			reviewItemById: { ...snapshot.reviewItemById },
			reviewItemIdsByIndex: [...snapshot.reviewItemIdsByIndex],
			reviewTreeRowsByIndex: [...snapshot.reviewTreeRowsByIndex],
			rowPaintById: { ...snapshot.rowPaintById },
		},
	};
}

function candidateCanContinueIntoSuccessor(
	candidate: MutableBridgeMainReviewCandidateBank,
	props: {
		readonly disposition: BridgeWorkerReviewCandidateStartDisposition;
		readonly identity: BridgeMainReviewPublicationIdentity;
	},
): boolean {
	return (
		candidate.role === 'updateReady' &&
		candidate.startDisposition.kind === 'sameSource' &&
		props.disposition.kind === 'sameSource' &&
		candidate.identity.packageId === props.identity.packageId &&
		candidate.identity.sourceIdentity === props.identity.sourceIdentity &&
		candidate.identity.generation === props.identity.generation &&
		props.identity.revision === candidate.identity.revision + 1
	);
}

function cloneSuccessorCandidate(
	predecessor: MutableBridgeMainReviewCandidateBank,
	identity: BridgeMainReviewPublicationIdentity,
	disposition: Extract<
		BridgeWorkerReviewCandidateStartDisposition,
		{ readonly kind: 'sameSource' }
	>,
): MutableBridgeMainReviewCandidateBank {
	if (predecessor.startDisposition.kind !== 'sameSource') {
		return cloneCandidate(predecessor.snapshot, identity, disposition);
	}
	const startDisposition = combineSameSourceCandidateDispositions(
		predecessor.startDisposition,
		disposition,
	);
	const successor = cloneCandidate(predecessor.snapshot, identity, startDisposition);
	copyCandidatePromotionImpact(successor.promotionImpact, predecessor.promotionImpact);
	successor.effectivePresentationClass = combineCandidatePresentationClasses(
		predecessor.effectivePresentationClass,
		successor.effectivePresentationClass,
	);
	return successor;
}

function combineSameSourceCandidateDispositions(
	predecessor: Extract<
		BridgeWorkerReviewCandidateStartDisposition,
		{ readonly kind: 'sameSource' }
	>,
	successor: Extract<BridgeWorkerReviewCandidateStartDisposition, { readonly kind: 'sameSource' }>,
): Extract<BridgeWorkerReviewCandidateStartDisposition, { readonly kind: 'sameSource' }> {
	const presentationClass = combineWorkerPresentationClasses(
		predecessor.presentationClass,
		successor.presentationClass,
	);
	const affectedStableFileIdentities = [
		...new Set([
			...predecessor.affectedStableFileIdentities,
			...successor.affectedStableFileIdentities,
		]),
	];
	if (
		(presentationClass.kind === 'promoted' && presentationClass.reason === 'unknown') ||
		affectedStableFileIdentities.length > BRIDGE_WORKER_REVIEW_AFFECTED_STABLE_FILE_IDENTITY_LIMIT
	) {
		return {
			affectedStableFileIdentities: [],
			kind: 'sameSource',
			presentationClass: { kind: 'promoted', reason: 'unknown' },
		};
	}
	return { affectedStableFileIdentities, kind: 'sameSource', presentationClass };
}

function combineWorkerPresentationClasses(
	predecessor: BridgeWorkerReviewPreDeliveryPresentationClass,
	successor: BridgeWorkerReviewPreDeliveryPresentationClass,
): BridgeWorkerReviewPreDeliveryPresentationClass {
	if (predecessor.kind === 'ordinary') return successor;
	if (successor.kind === 'ordinary' || predecessor.reason === successor.reason) return predecessor;
	return { kind: 'promoted', reason: 'unknown' };
}

function combineCandidatePresentationClasses(
	predecessor: BridgeMainReviewEffectivePresentationClass,
	successor: BridgeMainReviewEffectivePresentationClass,
): BridgeMainReviewEffectivePresentationClass {
	if (predecessor.kind === 'ordinary') return successor;
	if (successor.kind === 'ordinary' || predecessor.reason === successor.reason) return predecessor;
	return { kind: 'promoted', reason: 'unknown' };
}

function copyCandidatePromotionImpact(
	target: MutableBridgeMainReviewCandidatePromotionImpact,
	source: MutableBridgeMainReviewCandidatePromotionImpact,
): void {
	target.comparisonChanged = source.comparisonChanged;
	for (const itemId of source.itemIds) target.itemIds.add(itemId);
	target.itemOrderMutations.push(...source.itemOrderMutations);
	target.reset = source.reset;
	target.sourceChanged = source.sourceChanged;
	for (const rowId of source.treeRowIds) target.treeRowIds.add(rowId);
	target.treeRowOrderMutations.push(...source.treeRowOrderMutations);
}

function emptyCandidatePromotionImpact(): MutableBridgeMainReviewCandidatePromotionImpact {
	return {
		comparisonChanged: false,
		itemIds: new Set(),
		itemOrderMutations: [],
		reset: false,
		sourceChanged: false,
		treeRowIds: new Set(),
		treeRowOrderMutations: [],
	};
}

function accumulateCandidatePromotionImpact(
	impact: MutableBridgeMainReviewCandidatePromotionImpact,
	effect: BridgeMainReviewDisplayPatchEffect,
): void {
	impact.comparisonChanged ||= effect.comparisonChanged;
	for (const itemId of effect.itemIds) impact.itemIds.add(itemId);
	impact.itemOrderMutations.push(...effect.itemOrderMutations);
	impact.reset ||= effect.reset;
	impact.sourceChanged ||= effect.sourceChanged;
	for (const rowId of effect.treeRowIds) impact.treeRowIds.add(rowId);
	impact.treeRowOrderMutations.push(...effect.treeRowOrderMutations);
}
function isExact(
	left: BridgeMainReviewPublicationIdentity,
	right: BridgeMainReviewPublicationIdentity,
): boolean {
	return compareReviewMetadataLineages(left, right) === 'same';
}
function isNewer(
	candidate: BridgeMainReviewPublicationIdentity,
	current: BridgeMainReviewPublicationIdentity,
): boolean {
	return compareReviewMetadataLineages(candidate, current) === 'newer';
}
function presentation(
	activeIdentity: BridgeMainReviewPublicationIdentity | null,
	candidate: MutableBridgeMainReviewCandidateBank | null,
	failure: BridgeMainReviewFailurePresentation | null,
): BridgeMainReviewRefreshPresentation {
	return {
		activeIdentity,
		candidate:
			candidate === null
				? null
				: {
						affectedStableFileIdentities:
							candidate.startDisposition.kind === 'sameSource'
								? [...candidate.startDisposition.affectedStableFileIdentities]
								: [],
						effectivePresentationClass: candidate.effectivePresentationClass,
						identity: candidate.identity,
						role: candidate.role,
						startDisposition: candidate.startDisposition,
					},
		failure,
	};
}

function promotedFailure(
	candidate: MutableBridgeMainReviewCandidateBank,
	retryable: boolean,
): BridgeMainReviewFailurePresentation | null {
	const disposition = candidate.startDisposition;
	if (
		disposition.kind !== 'sameSource' ||
		candidate.effectivePresentationClass.kind !== 'promoted'
	) {
		return null;
	}
	return {
		kind: 'promotedRefresh',
		affectedStableFileIdentities: disposition.affectedStableFileIdentities,
		identity: candidate.identity,
		presentationClass: candidate.effectivePresentationClass,
		retryable,
	};
}
function mergeRecords<T>(
	active: Readonly<Record<string, T>>,
	candidate: Readonly<Record<string, T>>,
	oldIds: readonly string[],
	newIds: readonly string[],
): Record<string, T> {
	const result = { ...active };
	for (const id of oldIds) delete result[id];
	for (const id of newIds) {
		const value = candidate[id];
		if (value !== undefined) result[id] = value;
	}
	return result;
}
function itemIndex(ids: readonly (string | null)[]): Map<string, number> {
	const result = new Map<string, number>();
	for (const [index, id] of ids.entries()) if (id !== null) result.set(id, index);
	return result;
}
function rowIndex(
	rows: readonly (BridgeMainReviewTreeDisplayRow | null)[],
): Map<string, BridgeMainReviewTreeDisplayRow> {
	const result = new Map<string, BridgeMainReviewTreeDisplayRow>();
	for (const row of rows) if (row !== null) result.set(row.rowId, row);
	return result;
}
