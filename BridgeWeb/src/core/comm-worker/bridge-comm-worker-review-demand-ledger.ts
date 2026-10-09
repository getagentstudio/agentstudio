import type { BridgeCommWorkerDemandMember } from './bridge-comm-worker-reconciler.js';
import type { BridgeWorkerReviewContentReadyPreparationSettlement } from './bridge-comm-worker-review-preparation.js';
import type {
	BridgeWorkerOutstandingPublicationObservation,
	BridgeWorkerOutstandingPublicationOutcome,
	BridgeWorkerOutstandingPublicationPhase,
} from './bridge-render-disposition-telemetry.js';
import type {
	BridgeWorkerRenderDispositionReceipt,
	BridgeWorkerRenderReceiptIdentity,
} from './bridge-worker-render-fulfillment.js';

export type BridgeCommWorkerReviewDemandPositionKind = 'dynamic' | 'reserved';

export interface BridgeCommWorkerReviewDemandAdmission {
	readonly attemptToken: number;
	readonly itemId: string;
	readonly positionKind: BridgeCommWorkerReviewDemandPositionKind;
	readonly role: BridgeCommWorkerDemandMember['role'];
	readonly signal: AbortSignal;
}

export interface BridgeCommWorkerReviewCurrentActiveDemand {
	readonly itemId: string;
	readonly role: BridgeCommWorkerDemandMember['role'];
}

export interface BridgeCommWorkerReviewDemandStartHandle {
	readonly cancel: () => void;
	readonly pause?: () => void;
	readonly resume?: () => void;
	readonly updateRole: (role: BridgeCommWorkerDemandMember['role']) => void;
}

export interface BridgeCommWorkerReviewDemandLedger {
	readonly invalidate: (
		itemId: string,
		activeAttempt?:
			| 'cancel'
			| {
					readonly preserveIfPreparationIdentity: string;
			  },
	) => void;
	readonly markRetryReady: (itemId: string, attemptToken?: number) => boolean;
	readonly markPublished: (
		itemId: string,
		attemptToken: number,
		receiptIdentity: BridgeWorkerRenderReceiptIdentity,
	) => boolean;
	readonly setSuspended: (suspended: boolean) => void;
	readonly updateGeneration: (generation: number | null) => void;
	readonly reconcile: (membership: readonly BridgeCommWorkerDemandMember[]) => {
		readonly active: readonly BridgeCommWorkerReviewDemandAdmission[];
		readonly started: readonly BridgeCommWorkerReviewDemandAdmission[];
		readonly wanted: readonly BridgeCommWorkerDemandMember[];
	};
	readonly release: (
		itemId: string,
		attemptToken: number,
		disposition: BridgeWorkerReviewContentReadyPreparationSettlement,
	) => boolean;
	readonly releaseRejected: (itemId: string, attemptToken: number) => boolean;
	readonly releasePublished: (receipt: BridgeWorkerRenderDispositionReceipt) => boolean;
	readonly releaseExpiredPublication: (itemId: string) => boolean;
	readonly restartPublished: (itemId: string) => boolean;
}

interface ActiveBridgeCommWorkerReviewDemandRecord {
	readonly abortController: AbortController;
	readonly attemptToken: number;
	readonly handle: BridgeCommWorkerReviewDemandStartHandle;
	readonly itemId: string;
	readonly positionKind: BridgeCommWorkerReviewDemandPositionKind;
	readonly preparationIdentity: string | null;
	intentCurrent: boolean;
	publishedAtMilliseconds: number | null;
	publishedReceiptIdentity: BridgeWorkerRenderReceiptIdentity | null;
	role: BridgeCommWorkerDemandMember['role'];
}

export function createBridgeCommWorkerReviewDemandLedger(props: {
	readonly now?: () => number;
	readonly onCurrentActiveDemandChanged?: (
		activeDemand: readonly BridgeCommWorkerReviewCurrentActiveDemand[],
	) => void;
	readonly observeOutstandingPublications?: (
		observation: BridgeWorkerOutstandingPublicationObservation,
	) => void;
	readonly resolvePreparationIdentity?: (itemId: string) => string;
	readonly start: (
		admission: BridgeCommWorkerReviewDemandAdmission,
	) => BridgeCommWorkerReviewDemandStartHandle;
}): BridgeCommWorkerReviewDemandLedger {
	const activeRecordsByItemId = new Map<string, ActiveBridgeCommWorkerReviewDemandRecord>();
	const completedItemIds = new Set<string>();
	const retryWaitingAttemptTokenByItemId = new Map<string, number>();
	let latestMembership: readonly BridgeCommWorkerDemandMember[] = [];
	let suspended = false;
	let currentGeneration: number | null = null;
	let nextAttemptToken = 1;
	let outstandingPublicationHighWaterMark = 0;
	const now = props.now ?? performance.now.bind(performance);
	const observeOutstandingPublications = (
		phase: BridgeWorkerOutstandingPublicationPhase,
		outcome: BridgeWorkerOutstandingPublicationOutcome,
	): void => {
		const observedAtMilliseconds = now();
		const publishedRecords = [...activeRecordsByItemId.values()].filter(
			(record) => record.publishedReceiptIdentity !== null,
		);
		outstandingPublicationHighWaterMark = Math.max(
			outstandingPublicationHighWaterMark,
			publishedRecords.length,
		);
		const oldestPublishedAtMilliseconds = publishedRecords.reduce<number | null>(
			(oldest, record) =>
				record.publishedAtMilliseconds === null
					? oldest
					: oldest === null
						? record.publishedAtMilliseconds
						: Math.min(oldest, record.publishedAtMilliseconds),
			null,
		);
		try {
			props.observeOutstandingPublications?.({
				currentCount: publishedRecords.length,
				highWaterMark: outstandingPublicationHighWaterMark,
				oldestAgeMilliseconds:
					oldestPublishedAtMilliseconds === null
						? 0
						: Math.max(0, observedAtMilliseconds - oldestPublishedAtMilliseconds),
				outcome,
				phase,
			});
		} catch {
			// Optional operational evidence must not alter Review position ownership.
		}
	};

	const startMember = (
		member: BridgeCommWorkerDemandMember,
		positionKind: BridgeCommWorkerReviewDemandPositionKind,
	): BridgeCommWorkerReviewDemandAdmission => {
		const abortController = new AbortController();
		const attemptToken = nextAttemptToken;
		nextAttemptToken += 1;
		const admission: BridgeCommWorkerReviewDemandAdmission = {
			attemptToken,
			itemId: member.itemId,
			positionKind,
			role: member.role,
			signal: abortController.signal,
		};
		activeRecordsByItemId.set(member.itemId, {
			abortController,
			attemptToken,
			handle: props.start(admission),
			itemId: member.itemId,
			intentCurrent: true,
			positionKind,
			preparationIdentity: props.resolvePreparationIdentity?.(member.itemId) ?? null,
			publishedAtMilliseconds: null,
			publishedReceiptIdentity: null,
			role: member.role,
		});
		return admission;
	};
	const currentActiveAdmissions = (): readonly BridgeCommWorkerReviewDemandAdmission[] =>
		[...activeRecordsByItemId.values()].map((record) => ({
			attemptToken: record.attemptToken,
			itemId: record.itemId,
			positionKind: record.positionKind,
			role: record.role,
			signal: record.abortController.signal,
		}));
	const publishCurrentActiveDemand = (): void => {
		props.onCurrentActiveDemandChanged?.(
			[...activeRecordsByItemId.values()]
				.filter(({ intentCurrent }) => intentCurrent)
				.map(({ itemId, role }) => ({ itemId, role })),
		);
	};

	const reconcile = (
		membership: readonly BridgeCommWorkerDemandMember[],
	): ReturnType<BridgeCommWorkerReviewDemandLedger['reconcile']> => {
		latestMembership = membership;
		const memberByItemId = new Map(membership.map((member) => [member.itemId, member]));
		for (const [itemId, activeRecord] of activeRecordsByItemId) {
			const currentMember = memberByItemId.get(itemId);
			if (currentMember === undefined) continue;
			if (currentMember.role !== activeRecord.role) {
				activeRecord.role = currentMember.role;
				activeRecord.handle.updateRole(currentMember.role);
			}
		}
		const pendingMembers = membership.filter(
			(member) =>
				!activeRecordsByItemId.has(member.itemId) &&
				!completedItemIds.has(member.itemId) &&
				!retryWaitingAttemptTokenByItemId.has(member.itemId),
		);
		if (suspended) {
			const active = currentActiveAdmissions();
			publishCurrentActiveDemand();
			return {
				active,
				started: [],
				wanted: pendingMembers,
			};
		}
		let availableReservedPositions =
			3 -
			[...activeRecordsByItemId.values()].filter(({ positionKind }) => positionKind === 'reserved')
				.length;
		let availableDynamicPositions =
			9 -
			[...activeRecordsByItemId.values()].filter(({ positionKind }) => positionKind === 'dynamic')
				.length;
		const startedItemIds = new Set<string>();
		const startedAdmissions: BridgeCommWorkerReviewDemandAdmission[] = [];
		for (const member of pendingMembers) {
			if (availableReservedPositions === 0 || !roleCanUseReservedPosition(member.role)) continue;
			startedAdmissions.push(startMember(member, 'reserved'));
			startedItemIds.add(member.itemId);
			availableReservedPositions -= 1;
		}
		for (const member of pendingMembers) {
			if (availableDynamicPositions === 0) break;
			if (startedItemIds.has(member.itemId)) continue;
			startedAdmissions.push(startMember(member, 'dynamic'));
			startedItemIds.add(member.itemId);
			availableDynamicPositions -= 1;
		}
		const active = currentActiveAdmissions();
		publishCurrentActiveDemand();
		return {
			active,
			started: startedAdmissions,
			wanted: pendingMembers.filter((member) => !startedItemIds.has(member.itemId)),
		};
	};

	return {
		invalidate: (itemId, activeAttempt = 'cancel'): void => {
			const activeRecord = activeRecordsByItemId.get(itemId);
			if (activeRecord !== undefined && activeRecord.publishedReceiptIdentity !== null) {
				activeRecord.intentCurrent = false;
				completedItemIds.delete(itemId);
				retryWaitingAttemptTokenByItemId.delete(itemId);
				latestMembership = latestMembership.filter((member) => member.itemId !== itemId);
				publishCurrentActiveDemand();
				return;
			}
			const shouldCancelActiveAttempt =
				activeRecord !== undefined &&
				(activeAttempt === 'cancel' ||
					activeRecord.preparationIdentity !== activeAttempt.preserveIfPreparationIdentity);
			if (activeRecord !== undefined && shouldCancelActiveAttempt) {
				activeRecord.abortController.abort('review_demand_identity_invalidated');
				activeRecord.handle.cancel();
				activeRecordsByItemId.delete(itemId);
			}
			completedItemIds.delete(itemId);
			retryWaitingAttemptTokenByItemId.delete(itemId);
			latestMembership = latestMembership.filter((member) => member.itemId !== itemId);
			publishCurrentActiveDemand();
		},
		markRetryReady: (itemId, attemptToken): boolean => {
			const waitingAttemptToken = retryWaitingAttemptTokenByItemId.get(itemId);
			if (waitingAttemptToken === undefined) return false;
			if (attemptToken !== undefined && waitingAttemptToken !== attemptToken) return false;
			retryWaitingAttemptTokenByItemId.delete(itemId);
			return true;
		},
		markPublished: (itemId, attemptToken, receiptIdentity): boolean => {
			const activeRecord = activeRecordsByItemId.get(itemId);
			if (activeRecord?.attemptToken !== attemptToken) return false;
			activeRecord.publishedReceiptIdentity = Object.freeze({ ...receiptIdentity });
			activeRecord.publishedAtMilliseconds = now();
			observeOutstandingPublications('render_publication_outstanding_changed', 'published');
			return true;
		},
		reconcile,
		setSuspended: (nextSuspended): void => {
			if (suspended === nextSuspended) return;
			suspended = nextSuspended;
			for (const activeRecord of activeRecordsByItemId.values()) {
				if (suspended) activeRecord.handle.pause?.();
				else activeRecord.handle.resume?.();
			}
		},
		updateGeneration: (generation): void => {
			if (currentGeneration === generation) return;
			currentGeneration = generation;
			for (const [itemId, activeRecord] of activeRecordsByItemId) {
				if (activeRecord.publishedReceiptIdentity !== null) {
					activeRecord.intentCurrent = false;
					continue;
				}
				activeRecord.abortController.abort('review_demand_generation_changed');
				activeRecord.handle.cancel();
				activeRecordsByItemId.delete(itemId);
			}
			completedItemIds.clear();
			retryWaitingAttemptTokenByItemId.clear();
			latestMembership = [];
			publishCurrentActiveDemand();
		},
		release: (itemId, attemptToken, disposition): boolean => {
			const activeRecord = activeRecordsByItemId.get(itemId);
			if (activeRecord?.attemptToken !== attemptToken) return false;
			if (activeRecord.publishedReceiptIdentity !== null && disposition !== 'teardown') {
				if (disposition === 'invalidated') {
					activeRecord.intentCurrent = false;
					publishCurrentActiveDemand();
				}
				return true;
			}
			const wasPublished = activeRecord.publishedReceiptIdentity !== null;
			activeRecordsByItemId.delete(itemId);
			if (wasPublished) {
				observeOutstandingPublications('render_publication_outstanding_changed', 'cleared');
			}
			if (disposition === 'invalidated') {
				latestMembership = latestMembership.filter((member) => member.itemId !== itemId);
				publishCurrentActiveDemand();
				return true;
			}
			if (disposition === 'teardown') {
				publishCurrentActiveDemand();
				return true;
			}
			if (disposition === 'retryWait') retryWaitingAttemptTokenByItemId.set(itemId, attemptToken);
			else completedItemIds.add(itemId);
			reconcile(latestMembership);
			return true;
		},
		releaseRejected: (itemId, attemptToken): boolean => {
			const activeRecord = activeRecordsByItemId.get(itemId);
			if (activeRecord?.attemptToken !== attemptToken) return false;
			activeRecordsByItemId.delete(itemId);
			latestMembership = latestMembership.filter((member) => member.itemId !== itemId);
			reconcile(latestMembership);
			if (activeRecord.publishedReceiptIdentity !== null) {
				observeOutstandingPublications('render_publication_outstanding_changed', 'cleared');
			}
			return true;
		},
		releasePublished: (receipt): boolean => {
			if (
				receipt.disposition !== 'held' &&
				receipt.disposition !== 'queued' &&
				receipt.disposition !== 'rejected' &&
				receipt.disposition !== 'superseded'
			) {
				return false;
			}
			const activeRecord = activeRecordsByItemId.get(receipt.itemId);
			const receiptIdentity = activeRecord?.publishedReceiptIdentity ?? null;
			if (activeRecord === undefined || receiptIdentity === null) return false;
			if (!renderReceiptMatchesIdentity(receipt, receiptIdentity)) return false;
			observeOutstandingPublications(
				'render_disposition_response_posted_before_owner_effect',
				receipt.disposition,
			);
			activeRecordsByItemId.delete(receipt.itemId);
			if (activeRecord.intentCurrent) {
				completedItemIds.add(receipt.itemId);
			}
			reconcile(latestMembership);
			observeOutstandingPublications('render_publication_outstanding_changed', 'released');
			return true;
		},
		releaseExpiredPublication: (itemId): boolean => {
			const activeRecord = activeRecordsByItemId.get(itemId);
			if (activeRecord?.publishedReceiptIdentity === null || activeRecord === undefined) {
				return false;
			}
			activeRecordsByItemId.delete(itemId);
			observeOutstandingPublications('render_publication_outstanding_changed', 'cleared');
			publishCurrentActiveDemand();
			return true;
		},
		restartPublished: (itemId): boolean => {
			const activeRecord = activeRecordsByItemId.get(itemId);
			if (
				activeRecord === undefined ||
				activeRecord.publishedReceiptIdentity === null ||
				!activeRecord.intentCurrent
			) {
				return false;
			}
			activeRecordsByItemId.delete(itemId);
			observeOutstandingPublications('render_publication_outstanding_changed', 'released');
			publishCurrentActiveDemand();
			return true;
		},
	};
}

function renderReceiptMatchesIdentity(
	receipt: BridgeWorkerRenderDispositionReceipt,
	identity: BridgeWorkerRenderReceiptIdentity,
): boolean {
	return (
		receipt.attemptId === identity.attemptId &&
		receipt.itemId === identity.itemId &&
		receipt.operationCorrelationId === identity.operationCorrelationId &&
		receipt.paneSessionId === identity.paneSessionId &&
		receipt.publicationId === identity.publicationId &&
		receipt.publicationSequence === identity.publicationSequence &&
		receipt.submissionId === identity.submissionId &&
		receipt.surface === identity.surface &&
		receipt.windowKey === identity.windowKey &&
		receipt.workerDerivationEpoch === identity.workerDerivationEpoch &&
		receipt.workerInstanceId === identity.workerInstanceId
	);
}

function roleCanUseReservedPosition(role: BridgeCommWorkerDemandMember['role']): boolean {
	return role === 'selected' || role === 'visible';
}
