import { readBridgeCommWorkerAbsoluteNowMilliseconds } from './bridge-comm-worker-clock.js';
import type {
	BridgeWorkerFilePierreRenderJobEvent,
	BridgeWorkerReviewPierreRenderJobEvent,
} from './bridge-worker-contracts.js';
import {
	bridgeWorkerRenderDispositionReceiptSchema,
	bridgeWorkerPaintReleasedSchema,
	type BridgeWorkerPaintReleasedReceipt,
	type BridgeWorkerRenderDispositionReceipt,
	type BridgeWorkerRenderReceiptIdentity,
	type BridgeWorkerRenderRejectionReason,
} from './bridge-worker-render-fulfillment.js';

export type BridgeMainRenderPublication =
	| BridgeWorkerFilePierreRenderJobEvent
	| BridgeWorkerReviewPierreRenderJobEvent;

export type BridgeMainRenderPublicationItem = BridgeMainRenderPublication['job']['payload']['item'];
type BridgeMainRenderSourceCorrelation =
	BridgeMainRenderPublication['job']['sourceCorrelations'][number];

export type BridgeMainPierreItemResidency = 'replaced' | 'reusedPainted';
type BridgeMainPostRenderPhase = 'mount' | 'update' | 'unmount';

// Keep retained evidence within the existing CodeView materialization retry horizon.
const BRIDGE_RETAINED_PAINT_VALIDATION_FRAME_LIMIT = 30;

interface BridgeMainPaintedSourceCorrelation extends BridgeMainRenderSourceCorrelation {
	readonly disposition: 'painted';
	readonly pierreItemId: string;
	readonly publicationId: string;
	readonly semanticItemId: string;
	readonly surface: BridgeMainRenderPublication['surface'];
}

interface BridgeMainRetainedPaintedEvidence {
	readonly encodedSourceCorrelations: string;
	readonly publicationId: string;
}

export interface BridgeMainRenderedItemReadback {
	readonly element: {
		readonly isConnected: boolean;
		readonly getAttribute: (qualifiedName: string) => string | null;
		readonly removeAttribute: (qualifiedName: string) => void;
		readonly setAttribute: (qualifiedName: string, value: string) => void;
	};
	readonly item: BridgeMainRenderPublicationItem;
	readonly readableContentMatchesItem: boolean;
}

export interface BridgeMainRenderReadback {
	readonly readCurrentItem: () => BridgeMainRenderPublicationItem | undefined;
	readonly readRenderedItem: () => BridgeMainRenderedItemReadback | null;
}

export interface BridgeMainRenderFulfillmentCoordinator {
	readonly acceptPublication: (
		publication: BridgeMainRenderPublication,
	) => BridgeMainRenderPublicationAdmission;
	readonly bindPublicationItem: (props: {
		readonly finalItem: BridgeMainRenderPublicationItem;
		readonly publicationItem: BridgeMainRenderPublicationItem;
		readonly residency: BridgeMainPierreItemResidency;
	}) => void;
	readonly dispose: () => void;
	readonly isBoundFinalItem: (item: BridgeMainRenderPublicationItem) => boolean;
	readonly readBoundFinalItem: (itemId: string) => BridgeMainRenderPublicationItem | undefined;
	readonly holdPublication: (publication: BridgeMainRenderPublication) => void;
	readonly markPublicationQueued: (publication: BridgeMainRenderPublication) => void;
	readonly retireWorkerInstance: () => void;
	readonly releasePaintedCopy: (itemId: string) => boolean;
	readonly observePostRender: (
		props: BridgeMainRenderReadback & {
			readonly contextItem: BridgeMainRenderPublicationItem;
			readonly itemId: string;
			readonly phase: BridgeMainPostRenderPhase;
		},
	) => void;
	readonly reconcilePublication: (
		props: BridgeMainRenderReadback & { readonly itemId: string },
	) => void;
	readonly rejectPublication: (
		publication: BridgeMainRenderPublication,
		reason: BridgeWorkerRenderRejectionReason,
	) => void;
	readonly supersedeItem: (itemId: string, reason: BridgeWorkerRenderRejectionReason) => void;
}

export type BridgeMainRenderPublicationAdmission = 'accepted' | 'duplicate';

export interface CreateBridgeMainRenderFulfillmentCoordinatorProps {
	readonly cancelAnimationFrame?: (frameHandle: number) => void;
	readonly nowMilliseconds?: () => number;
	readonly requestAnimationFrame?: (callback: FrameRequestCallback) => number;
	readonly sendDisposition: (receipt: BridgeWorkerRenderDispositionReceipt) => void;
	readonly sendPaintRelease?: (receipt: BridgeWorkerPaintReleasedReceipt) => void;
}

interface BridgeMainPendingRenderPublication {
	readonly identityKey: string;
	item: BridgeMainRenderPublicationItem;
	readonly logicalItemId: string;
	readonly pierreItemId: string;
	readonly publication: BridgeMainRenderPublication;
	readonly publicationItem: BridgeMainRenderPublicationItem;
	animationFrameHandle: number | null;
	finalItemBound: boolean;
	latestPostRenderReadback: BridgeMainRenderReadback | null;
	postRenderObserved: boolean;
	queuedSubmissionObserved: boolean;
	residency: BridgeMainPierreItemResidency;
	stage: 'accepted' | 'held' | 'queued' | 'applied';
}

export function createBridgeMainRenderFulfillmentCoordinator(
	props: CreateBridgeMainRenderFulfillmentCoordinatorProps,
): BridgeMainRenderFulfillmentCoordinator {
	const cancelFrame =
		props.cancelAnimationFrame ?? globalThis.cancelAnimationFrame.bind(globalThis);
	const nowMilliseconds = props.nowMilliseconds ?? readBridgeCommWorkerAbsoluteNowMilliseconds;
	const requestFrame =
		props.requestAnimationFrame ?? globalThis.requestAnimationFrame.bind(globalThis);
	const pendingByPierreItemId = new Map<string, BridgeMainPendingRenderPublication>();
	const pendingByPublicationItem = new WeakMap<
		BridgeMainRenderPublicationItem,
		BridgeMainPendingRenderPublication
	>();
	let retainedPaintedEvidenceByFinalItem = new WeakMap<
		BridgeMainRenderPublicationItem,
		BridgeMainRetainedPaintedEvidence
	>();
	const retainedPaintValidationFramesByFinalItem = new Map<
		BridgeMainRenderPublicationItem,
		number
	>();
	const terminalPublicationIdentityKeys = new Set<string>();
	const paintedReceiptByLogicalItemId = new Map<string, BridgeWorkerRenderReceiptIdentity>();
	let isDisposed = false;

	const scheduleRetainedPaintValidation = (
		item: BridgeMainRenderPublicationItem,
		readback: BridgeMainRenderReadback,
	): void => {
		if (retainedPaintValidationFramesByFinalItem.has(item)) return;
		const scheduleFrame = (remainingFrameCount: number): void => {
			const frameHandle = requestFrame((): void => {
				if (retainedPaintValidationFramesByFinalItem.get(item) !== frameHandle) return;
				retainedPaintValidationFramesByFinalItem.delete(item);
				if (isDisposed) return;
				const needsPaintValidation = synchronizeRetainedPaintedEvidence(
					item,
					readback,
					retainedPaintedEvidenceByFinalItem,
				);
				if (needsPaintValidation && remainingFrameCount > 1) {
					scheduleFrame(remainingFrameCount - 1);
				}
			});
			retainedPaintValidationFramesByFinalItem.set(item, frameHandle);
		};
		scheduleFrame(BRIDGE_RETAINED_PAINT_VALIDATION_FRAME_LIMIT);
	};
	const cancelRetainedPaintValidation = (item: BridgeMainRenderPublicationItem): void => {
		const frameHandle = retainedPaintValidationFramesByFinalItem.get(item);
		if (frameHandle === undefined) return;
		retainedPaintValidationFramesByFinalItem.delete(item);
		cancelFrame(frameHandle);
	};

	const sendPositiveDisposition = (
		entry: BridgeMainPendingRenderPublication,
		disposition: 'held' | 'queued' | 'applied' | 'painted',
	): void => {
		props.sendDisposition(
			bridgeWorkerRenderDispositionReceiptSchema.parse({
				...entry.publication.renderReceiptIdentity,
				disposition,
				kind: 'render.disposition',
				receivedAtMilliseconds: nowMilliseconds(),
			}),
		);
	};

	const cancelPendingFrame = (entry: BridgeMainPendingRenderPublication): void => {
		if (entry.animationFrameHandle === null) return;
		cancelFrame(entry.animationFrameHandle);
		entry.animationFrameHandle = null;
	};

	const publishQueuedDispositionWhenReady = (entry: BridgeMainPendingRenderPublication): void => {
		if (entry.stage !== 'accepted' || !entry.queuedSubmissionObserved || !entry.finalItemBound) {
			return;
		}
		sendPositiveDisposition(entry, 'queued');
		entry.stage = 'queued';
	};

	const sendTerminalDisposition = (
		publication: BridgeMainRenderPublication,
		disposition: 'rejected' | 'superseded',
		reason: BridgeWorkerRenderRejectionReason,
	): void => {
		const identityKey = bridgeMainRenderReceiptIdentityKey(publication.renderReceiptIdentity);
		if (terminalPublicationIdentityKeys.has(identityKey)) return;
		const receivedAtMilliseconds = nowMilliseconds();
		props.sendDisposition(
			bridgeWorkerRenderDispositionReceiptSchema.parse({
				...publication.renderReceiptIdentity,
				disposition,
				kind: 'render.disposition',
				reason,
				receivedAtMilliseconds,
				retryAtMilliseconds: receivedAtMilliseconds,
			}),
		);
		terminalPublicationIdentityKeys.add(identityKey);
	};

	const closePendingPublication = (
		entry: BridgeMainPendingRenderPublication,
		disposition: 'rejected' | 'superseded',
		reason: BridgeWorkerRenderRejectionReason,
	): void => {
		if (pendingByPierreItemId.get(entry.pierreItemId) !== entry) return;
		cancelPendingFrame(entry);
		pendingByPierreItemId.delete(entry.pierreItemId);
		pendingByPublicationItem.delete(entry.publicationItem);
		sendTerminalDisposition(entry.publication, disposition, reason);
	};

	const schedulePaintValidation = (
		entry: BridgeMainPendingRenderPublication,
		readback: BridgeMainRenderReadback,
	): void => {
		if (
			entry.stage !== 'applied' ||
			!entry.postRenderObserved ||
			entry.animationFrameHandle !== null
		) {
			return;
		}
		const animationFrameHandle = requestFrame((): void => {
			if (
				entry.animationFrameHandle !== animationFrameHandle ||
				pendingByPierreItemId.get(entry.pierreItemId) !== entry
			) {
				return;
			}
			entry.animationFrameHandle = null;
			const renderedItem = matchingRenderedItemForEntry(entry, readback);
			if (renderedItem === null) {
				closePendingPublication(entry, 'rejected', 'stale_attempt');
				return;
			}
			sendPositiveDisposition(entry, 'painted');
			paintedReceiptByLogicalItemId.set(
				entry.logicalItemId,
				entry.publication.renderReceiptIdentity,
			);
			pendingByPierreItemId.delete(entry.pierreItemId);
			pendingByPublicationItem.delete(entry.publicationItem);
			terminalPublicationIdentityKeys.add(entry.identityKey);
			retainAndStampPaintedSourceCorrelation(
				entry,
				renderedItem,
				retainedPaintedEvidenceByFinalItem,
			);
		});
		entry.animationFrameHandle = animationFrameHandle;
	};

	const reconcileEntry = (
		entry: BridgeMainPendingRenderPublication,
		readback: BridgeMainRenderReadback,
	): void => {
		const renderedItem = matchingRenderedItemForEntry(entry, readback);
		if (renderedItem === null) return;
		if (renderedItem.readableContentMatchesItem) entry.postRenderObserved = true;
		clearPaintedSourceCorrelation(renderedItem);
		if (entry.stage === 'accepted' || entry.stage === 'held') return;
		if (entry.residency !== 'reusedPainted' && !entry.postRenderObserved) return;
		if (entry.stage === 'queued') {
			sendPositiveDisposition(entry, 'applied');
			entry.stage = 'applied';
		}
		schedulePaintValidation(entry, readback);
	};

	const reconcileRetainedPostRenderAfterQueued = (
		entry: BridgeMainPendingRenderPublication,
	): void => {
		if (entry.stage !== 'queued' || entry.latestPostRenderReadback === null) return;
		reconcileEntry(entry, entry.latestPostRenderReadback);
	};

	const acceptPublication = (
		publication: BridgeMainRenderPublication,
		resumeHeld: boolean = true,
	): BridgeMainRenderPublicationAdmission => {
		if (isDisposed) {
			throw new Error('Bridge main render fulfillment coordinator is disposed.');
		}
		assertBridgeMainRenderPublicationIdentity(publication);
		const identityKey = bridgeMainRenderReceiptIdentityKey(publication.renderReceiptIdentity);
		if (terminalPublicationIdentityKeys.has(identityKey)) return 'duplicate';
		const logicalItemId = publication.job.itemId;
		const pierreItemId = publication.job.payload.item.id;
		const existingEntry =
			pendingByPierreItemId.get(pierreItemId) ??
			findPendingPublicationByLogicalItemId(pendingByPierreItemId, logicalItemId);
		if (existingEntry?.identityKey === identityKey) {
			if (resumeHeld && existingEntry.stage === 'held') {
				existingEntry.stage = 'accepted';
				return 'accepted';
			}
			return 'duplicate';
		}
		if (existingEntry !== undefined) {
			closePendingPublication(existingEntry, 'superseded', 'stale_submission');
		}
		const entry: BridgeMainPendingRenderPublication = {
			animationFrameHandle: null,
			finalItemBound: false,
			identityKey,
			item: publication.job.payload.item,
			latestPostRenderReadback: null,
			logicalItemId,
			pierreItemId,
			postRenderObserved: false,
			publication,
			publicationItem: publication.job.payload.item,
			queuedSubmissionObserved: false,
			residency: 'replaced',
			stage: 'accepted',
		};
		retainedPaintedEvidenceByFinalItem.delete(entry.publicationItem);
		pendingByPierreItemId.set(pierreItemId, entry);
		pendingByPublicationItem.set(entry.publicationItem, entry);
		return 'accepted';
	};
	return {
		acceptPublication,
		holdPublication: (publication): void => {
			acceptPublication(publication, false);
			const entry = pendingByPierreItemId.get(publication.job.payload.item.id);
			if (
				entry?.identityKey !==
					bridgeMainRenderReceiptIdentityKey(publication.renderReceiptIdentity) ||
				entry.stage !== 'accepted'
			)
				return;
			sendPositiveDisposition(entry, 'held');
			entry.stage = 'held';
		},
		bindPublicationItem: (bindProps): void => {
			if (isDisposed) return;
			const entry = pendingByPublicationItem.get(bindProps.publicationItem);
			if (
				entry === undefined ||
				pendingByPierreItemId.get(entry.pierreItemId) !== entry ||
				bindProps.finalItem.id !== entry.pierreItemId ||
				bindProps.finalItem.bridgeMetadata.itemId !== entry.logicalItemId ||
				bindProps.finalItem.type !== entry.publicationItem.type
			) {
				return;
			}
			if (entry.item === bindProps.finalItem && entry.finalItemBound) return;
			cancelPendingFrame(entry);
			retainedPaintedEvidenceByFinalItem.delete(entry.item);
			retainedPaintedEvidenceByFinalItem.delete(bindProps.finalItem);
			entry.item = bindProps.finalItem;
			entry.finalItemBound = true;
			entry.latestPostRenderReadback = null;
			entry.postRenderObserved = bindProps.residency === 'reusedPainted';
			entry.residency = bindProps.residency;
			publishQueuedDispositionWhenReady(entry);
			reconcileRetainedPostRenderAfterQueued(entry);
		},
		dispose: (): void => {
			if (isDisposed) return;
			isDisposed = true;
			for (const entry of pendingByPierreItemId.values()) {
				closePendingPublication(entry, 'superseded', 'stale_submission');
			}
			for (const frameHandle of retainedPaintValidationFramesByFinalItem.values()) {
				cancelFrame(frameHandle);
			}
			retainedPaintValidationFramesByFinalItem.clear();
			retainedPaintedEvidenceByFinalItem = new WeakMap();
			paintedReceiptByLogicalItemId.clear();
			terminalPublicationIdentityKeys.clear();
		},
		isBoundFinalItem: (item): boolean => {
			if (isDisposed) return false;
			const entry = pendingByPierreItemId.get(item.id);
			return (
				(entry?.finalItemBound === true && entry.item === item) ||
				retainedPaintedEvidenceByFinalItem.has(item)
			);
		},
		readBoundFinalItem: (itemId): BridgeMainRenderPublicationItem | undefined => {
			if (isDisposed) return undefined;
			const entry = findPendingPublicationByLogicalItemId(pendingByPierreItemId, itemId);
			return entry?.finalItemBound === true ? entry.item : undefined;
		},
		markPublicationQueued: (publication): void => {
			if (isDisposed) return;
			assertBridgeMainRenderPublicationIdentity(publication);
			const entry = pendingByPierreItemId.get(publication.job.payload.item.id);
			if (
				entry === undefined ||
				entry.identityKey !==
					bridgeMainRenderReceiptIdentityKey(publication.renderReceiptIdentity) ||
				entry.stage !== 'accepted'
			) {
				return;
			}
			entry.queuedSubmissionObserved = true;
			publishQueuedDispositionWhenReady(entry);
			reconcileRetainedPostRenderAfterQueued(entry);
		},
		retireWorkerInstance: (): void => {
			if (isDisposed) return;
			for (const entry of pendingByPierreItemId.values()) cancelPendingFrame(entry);
			pendingByPierreItemId.clear();
			for (const frameHandle of retainedPaintValidationFramesByFinalItem.values()) {
				cancelFrame(frameHandle);
			}
			retainedPaintValidationFramesByFinalItem.clear();
			retainedPaintedEvidenceByFinalItem = new WeakMap();
			paintedReceiptByLogicalItemId.clear();
			terminalPublicationIdentityKeys.clear();
		},
		releasePaintedCopy: (itemId): boolean => {
			if (isDisposed) return false;
			const identity = paintedReceiptByLogicalItemId.get(itemId);
			if (identity === undefined) return false;
			paintedReceiptByLogicalItemId.delete(itemId);
			if (props.sendPaintRelease === undefined) {
				throw new Error('Bridge painted-copy release requires a receipt admission owner.');
			}
			props.sendPaintRelease(
				bridgeWorkerPaintReleasedSchema.parse({
					...identity,
					kind: 'paint.released',
					receivedAtMilliseconds: nowMilliseconds(),
				}),
			);
			return true;
		},
		observePostRender: (observeProps): void => {
			if (isDisposed || observeProps.phase === 'unmount') return;
			const entry = pendingByPierreItemId.get(observeProps.itemId);
			if (entry === undefined || observeProps.contextItem !== entry.item) {
				const needsPaintValidation = synchronizeRetainedPaintedEvidence(
					observeProps.contextItem,
					observeProps,
					retainedPaintedEvidenceByFinalItem,
				);
				if (needsPaintValidation) {
					scheduleRetainedPaintValidation(observeProps.contextItem, observeProps);
				} else {
					cancelRetainedPaintValidation(observeProps.contextItem);
				}
				return;
			}
			entry.latestPostRenderReadback = observeProps;
			entry.postRenderObserved = true;
			reconcileEntry(entry, observeProps);
		},
		reconcilePublication: (reconcileProps): void => {
			if (isDisposed) return;
			const entry = pendingByPierreItemId.get(reconcileProps.itemId);
			if (entry === undefined) {
				const currentItem = reconcileProps.readCurrentItem();
				if (currentItem === undefined) return;
				const needsPaintValidation = synchronizeRetainedPaintedEvidence(
					currentItem,
					reconcileProps,
					retainedPaintedEvidenceByFinalItem,
				);
				if (needsPaintValidation) {
					scheduleRetainedPaintValidation(currentItem, reconcileProps);
				} else {
					cancelRetainedPaintValidation(currentItem);
				}
				return;
			}
			entry.latestPostRenderReadback = reconcileProps;
			reconcileEntry(entry, reconcileProps);
		},
		rejectPublication: (publication, reason): void => {
			if (isDisposed) return;
			assertBridgeMainRenderPublicationIdentity(publication);
			const existingEntry = pendingByPierreItemId.get(publication.job.payload.item.id);
			const identityKey = bridgeMainRenderReceiptIdentityKey(publication.renderReceiptIdentity);
			if (existingEntry?.identityKey === identityKey) {
				closePendingPublication(existingEntry, 'rejected', reason);
				return;
			}
			sendTerminalDisposition(publication, 'rejected', reason);
		},
		supersedeItem: (itemId, reason): void => {
			if (isDisposed) return;
			const entry = findPendingPublicationByLogicalItemId(pendingByPierreItemId, itemId);
			if (entry === undefined) return;
			closePendingPublication(entry, 'superseded', reason);
		},
	};
}

function matchingRenderedItemForEntry(
	entry: BridgeMainPendingRenderPublication,
	readback: BridgeMainRenderReadback,
): BridgeMainRenderedItemReadback | null {
	return matchingRenderedItemForExactItem(entry.item, readback);
}

function matchingRenderedItemForExactItem(
	item: BridgeMainRenderPublicationItem,
	readback: BridgeMainRenderReadback,
): BridgeMainRenderedItemReadback | null {
	if (readback.readCurrentItem() !== item) return null;
	const renderedItem = readback.readRenderedItem();
	return renderedItem !== null && renderedItem.item === item && renderedItem.element.isConnected
		? renderedItem
		: null;
}

const BRIDGE_PAINTED_SOURCE_CORRELATIONS_ATTRIBUTE = 'data-bridge-painted-source-correlations';
export const BRIDGE_PAINTED_PUBLICATION_ID_ATTRIBUTE = 'data-bridge-painted-publication-id';
const BRIDGE_RENDER_DISPOSITION_SETTLED_PUBLICATION_ID_ATTRIBUTE =
	'data-bridge-render-disposition-settled-publication-id';
const BRIDGE_RENDER_DISPOSITION_SETTLED_OUTCOME_ATTRIBUTE =
	'data-bridge-render-disposition-settled-outcome';

export function stampBridgeRenderDispositionSettlementEvidence(props: {
	readonly elements: Iterable<Pick<Element, 'getAttribute' | 'setAttribute'>>;
	readonly outcome: 'settled-ok' | 'settled-failed';
	readonly publicationId: string;
}): void {
	for (const element of props.elements) {
		if (element.getAttribute(BRIDGE_PAINTED_PUBLICATION_ID_ATTRIBUTE) !== props.publicationId)
			continue;
		element.setAttribute(
			BRIDGE_RENDER_DISPOSITION_SETTLED_PUBLICATION_ID_ATTRIBUTE,
			props.publicationId,
		);
		element.setAttribute(BRIDGE_RENDER_DISPOSITION_SETTLED_OUTCOME_ATTRIBUTE, props.outcome);
	}
}

function retainAndStampPaintedSourceCorrelation(
	entry: BridgeMainPendingRenderPublication,
	renderedItem: BridgeMainRenderedItemReadback,
	retainedPaintedEvidenceByFinalItem: WeakMap<
		BridgeMainRenderPublicationItem,
		BridgeMainRetainedPaintedEvidence
	>,
): void {
	try {
		const paintedSourceCorrelations = paintedSourceCorrelationsForEntry(entry);
		if (paintedSourceCorrelations.length === 0) {
			retainedPaintedEvidenceByFinalItem.delete(entry.item);
			clearPaintedSourceCorrelation(renderedItem);
			return;
		}
		const evidence = {
			encodedSourceCorrelations: JSON.stringify(paintedSourceCorrelations),
			publicationId: entry.publication.renderReceiptIdentity.publicationId,
		} satisfies BridgeMainRetainedPaintedEvidence;
		retainedPaintedEvidenceByFinalItem.set(entry.item, evidence);
		if (renderedItem.readableContentMatchesItem) {
			stampRetainedPaintedEvidence(renderedItem, evidence);
		} else {
			clearPaintedSourceCorrelation(renderedItem);
		}
	} catch {
		// Packaged proof metadata is diagnostic-only and cannot gate product fulfillment.
	}
}

function synchronizeRetainedPaintedEvidence(
	item: BridgeMainRenderPublicationItem,
	readback: BridgeMainRenderReadback,
	retainedPaintedEvidenceByFinalItem: WeakMap<
		BridgeMainRenderPublicationItem,
		BridgeMainRetainedPaintedEvidence
	>,
): boolean {
	const renderedItem = matchingRenderedItemForExactItem(item, readback);
	if (renderedItem === null) return false;
	const evidence = retainedPaintedEvidenceByFinalItem.get(item);
	if (evidence === undefined) {
		clearPaintedSourceCorrelation(renderedItem);
		return false;
	}
	if (!renderedItem.readableContentMatchesItem) {
		clearPaintedSourceCorrelation(renderedItem);
		return true;
	}
	stampRetainedPaintedEvidence(renderedItem, evidence);
	return false;
}

function clearPaintedSourceCorrelation(renderedItem: BridgeMainRenderedItemReadback): void {
	try {
		renderedItem.element.removeAttribute(BRIDGE_PAINTED_PUBLICATION_ID_ATTRIBUTE);
		renderedItem.element.removeAttribute(BRIDGE_PAINTED_SOURCE_CORRELATIONS_ATTRIBUTE);
		renderedItem.element.removeAttribute(
			BRIDGE_RENDER_DISPOSITION_SETTLED_PUBLICATION_ID_ATTRIBUTE,
		);
		renderedItem.element.removeAttribute(BRIDGE_RENDER_DISPOSITION_SETTLED_OUTCOME_ATTRIBUTE);
	} catch {
		// Packaged proof metadata is diagnostic-only and cannot gate product fulfillment.
	}
}

function stampRetainedPaintedEvidence(
	renderedItem: BridgeMainRenderedItemReadback,
	evidence: BridgeMainRetainedPaintedEvidence,
): void {
	try {
		if (
			renderedItem.element.getAttribute(BRIDGE_PAINTED_PUBLICATION_ID_ATTRIBUTE) !==
			evidence.publicationId
		) {
			clearPaintedSourceCorrelation(renderedItem);
		}
		renderedItem.element.setAttribute(
			BRIDGE_PAINTED_SOURCE_CORRELATIONS_ATTRIBUTE,
			evidence.encodedSourceCorrelations,
		);
		renderedItem.element.setAttribute(
			BRIDGE_PAINTED_PUBLICATION_ID_ATTRIBUTE,
			evidence.publicationId,
		);
	} catch {
		// Packaged proof metadata is diagnostic-only and cannot gate product fulfillment.
	}
}

function paintedSourceCorrelationsForEntry(
	entry: BridgeMainPendingRenderPublication,
): readonly BridgeMainPaintedSourceCorrelation[] {
	return entry.publication.job.sourceCorrelations.map((sourceCorrelation) => ({
		...sourceCorrelation,
		disposition: 'painted',
		pierreItemId: entry.pierreItemId,
		publicationId: entry.publication.renderReceiptIdentity.publicationId,
		semanticItemId: entry.logicalItemId,
		surface: entry.publication.surface,
	}));
}

function assertBridgeMainRenderPublicationIdentity(publication: BridgeMainRenderPublication): void {
	const item = publication.job.payload.item;
	if (
		item.id.length === 0 ||
		item.bridgeMetadata.itemId !== publication.job.itemId ||
		publication.renderReceiptIdentity.itemId !== publication.job.itemId ||
		publication.renderReceiptIdentity.surface !== publication.surface ||
		publication.renderReceiptIdentity.publicationSequence !== publication.publicationSequence ||
		publication.renderReceiptIdentity.workerDerivationEpoch !== publication.workerDerivationEpoch
	) {
		throw new Error('Bridge main render publication carries mismatched item or receipt identity.');
	}
}

function findPendingPublicationByLogicalItemId(
	pendingByPierreItemId: ReadonlyMap<string, BridgeMainPendingRenderPublication>,
	logicalItemId: string,
): BridgeMainPendingRenderPublication | undefined {
	for (const entry of pendingByPierreItemId.values()) {
		if (entry.logicalItemId === logicalItemId) return entry;
	}
	return undefined;
}

function bridgeMainRenderReceiptIdentityKey(identity: BridgeWorkerRenderReceiptIdentity): string {
	return JSON.stringify([
		identity.attemptId,
		identity.itemId,
		identity.operationCorrelationId,
		identity.paneSessionId,
		identity.publicationId,
		identity.publicationSequence,
		identity.submissionId,
		identity.surface,
		identity.windowKey,
		identity.workerDerivationEpoch,
		identity.workerInstanceId,
	]);
}
