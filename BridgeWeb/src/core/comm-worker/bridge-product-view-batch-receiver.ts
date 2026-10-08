import type { BridgeProductBatchRejectionReason } from './bridge-product-batch-diagnostics.js';
import type {
	BridgeProductBatchFrame,
	BridgeProductSnapshotCause,
} from './bridge-product-batch-wire-contracts.js';

type BatchBegin = Extract<BridgeProductBatchFrame, { readonly kind: 'subscription.batchBegin' }>;
type BatchPart = Extract<BridgeProductBatchFrame, { readonly kind: 'subscription.batchPart' }>;
type BatchComplete = Extract<
	BridgeProductBatchFrame,
	{ readonly kind: 'subscription.batchComplete' }
>;

interface InstalledRecord {
	readonly key: string;
	readonly revision: number;
	readonly value: unknown;
}

export interface BridgeProductViewInstallation {
	readonly begin: BatchBegin;
	readonly certified: boolean;
	readonly domain: string;
	readonly records: readonly InstalledRecord[];
	readonly staleRecords: readonly InstalledRecord[];
}

interface StagedBatch {
	readonly begin: BatchBegin;
	readonly partsByIndex: Map<number, BatchPart>;
	complete: BatchComplete | null;
}

interface DomainState {
	readonly incarnation: string;
	expiredBatchId: string | null;
	cursor: number;
	readonly receivedPartSequences: Set<number>;
	receivedThroughDeliverySequence: number;
	receiptBaselinePending: boolean;
	hasCertifiedSnapshot: boolean;
	lastInstalledBatchId: string | null;
	lastInstalledCompleteStreamSequence: number;
	readonly recordsByKey: Map<string, InstalledRecord>;
	readonly tombstoneRevisionByKey: Map<string, number>;
	readonly certifiedAbsenceFloorsByScope: Map<
		string,
		{
			readonly coveredScope: BatchComplete['coveredScope'];
			readonly revision: number;
		}
	>;
	stage: StagedBatch | null;
	containedBegin: BatchBegin | null;
}

export type BridgeProductBatchAcceptance =
	| {
			readonly kind: 'ignored';
			readonly receivedThroughDeliverySequence?: number;
			readonly snapshotContained?: true;
	  }
	| {
			readonly kind: 'staged';
			readonly receivedThroughDeliverySequence?: number;
			readonly snapshotCause?: BridgeProductSnapshotCause;
	  }
	| { readonly kind: 'installed'; readonly domain: string; readonly targetRevision: number }
	| {
			readonly kind: 'resnapshot';
			readonly domain: string;
			readonly rejection: BridgeProductBatchRejectionReason;
	  };

/** W4's side bank. The live transport calls this owner only after the N3 cutover. */
export class BridgeProductViewBatchReceiver {
	#handle: string;
	#scope: BatchBegin['scope'];
	#scopeRevision: number;
	readonly #subscriptionId: string;
	readonly #subscriptionKind: BatchBegin['subscriptionKind'];
	readonly #coversKey: (coveredScope: BatchComplete['coveredScope'], key: string) => boolean;
	readonly #domains = new Map<string, DomainState>();
	readonly #staleRecordsByDomain = new Map<string, Map<string, InstalledRecord>>();
	readonly #completedInstallations: BridgeProductViewInstallation[] = [];

	constructor(props: {
		readonly handle: string;
		readonly scope: BatchBegin['scope'];
		readonly scopeRevision: number;
		readonly subscriptionId: string;
		readonly subscriptionKind: BatchBegin['subscriptionKind'];
		readonly coversKey?: (coveredScope: BatchComplete['coveredScope'], key: string) => boolean;
	}) {
		this.#handle = props.handle;
		this.#scope = props.scope;
		this.#scopeRevision = props.scopeRevision;
		this.#subscriptionId = props.subscriptionId;
		this.#subscriptionKind = props.subscriptionKind;
		this.#coversKey = props.coversKey ?? (() => true);
	}

	admitDomain(domain: string, incarnation: string): void {
		const existing = this.#domains.get(domain);
		if (existing?.incarnation === incarnation) return;
		this.#completedInstallations.splice(
			0,
			this.#completedInstallations.length,
			...this.#completedInstallations.filter((installation) => installation.domain !== domain),
		);
		if (existing !== undefined) this.#retainStaleRecords(domain, existing.recordsByKey.values());
		this.#domains.set(domain, {
			cursor: 0,
			expiredBatchId: null,
			receivedPartSequences: new Set(),
			receivedThroughDeliverySequence: 0,
			receiptBaselinePending: true,
			hasCertifiedSnapshot: false,
			lastInstalledBatchId: null,
			lastInstalledCompleteStreamSequence: 0,
			certifiedAbsenceFloorsByScope: new Map(),
			incarnation,
			recordsByKey: new Map(),
			stage: null,
			containedBegin: null,
			tombstoneRevisionByKey: new Map(),
		});
	}

	setScope(scope: BatchBegin['scope'], scopeRevision: number): boolean {
		if (scopeRevision <= this.#scopeRevision) return false;
		const filterChanged = !sameViewFilter(this.#scope, scope);
		this.#scope = scope;
		this.#scopeRevision = scopeRevision;
		if (!filterChanged) return false;
		this.#completedInstallations.length = 0;
		for (const [domain, state] of this.#domains) {
			if (!state.hasCertifiedSnapshot) {
				this.#retainStaleRecords(domain, state.recordsByKey.values());
				state.recordsByKey.clear();
			}
			state.stage = null;
			state.containedBegin = null;
			state.expiredBatchId = null;
			state.receivedPartSequences.clear();
			state.receivedThroughDeliverySequence = 0;
			state.receiptBaselinePending = true;
		}
		return true;
	}

	replaceHandle(handle: string, scope: BatchBegin['scope'], scopeRevision: number): void {
		if (handle === this.#handle) {
			this.setScope(scope, scopeRevision);
			return;
		}
		this.#completedInstallations.length = 0;
		for (const [domain, state] of this.#domains) {
			this.#retainStaleRecords(domain, state.recordsByKey.values());
		}
		this.#domains.clear();
		this.#handle = handle;
		this.#scope = scope;
		this.#scopeRevision = scopeRevision;
	}

	#retainStaleRecords(domain: string, records: Iterable<InstalledRecord>): void {
		const staleRecords =
			this.#staleRecordsByDomain.get(domain) ?? new Map<string, InstalledRecord>();
		for (const record of records) staleRecords.set(record.key, record);
		if (staleRecords.size > 0) this.#staleRecordsByDomain.set(domain, staleRecords);
	}

	accept(
		frame: BridgeProductBatchFrame,
		verifyInstallation?: (installation: BridgeProductViewInstallation) => void,
		admitSnapshot?: (begin: BatchBegin) => boolean,
	): BridgeProductBatchAcceptance {
		const domainState = this.#domains.get(frame.domain);
		if (
			domainState === undefined ||
			frame.incarnation !== domainState.incarnation ||
			frame.handle !== this.#handle ||
			frame.subscriptionId !== this.#subscriptionId ||
			frame.subscriptionKind !== this.#subscriptionKind
		)
			return { kind: 'ignored' };
		if (frame.kind !== 'subscription.batchBegin' && frame.batchId === domainState.expiredBatchId)
			return { kind: 'ignored' };
		switch (frame.kind) {
			case 'subscription.batchBegin':
				return this.#begin(domainState, frame, admitSnapshot);
			case 'subscription.batchPart':
				return this.#part(domainState, frame);
			case 'subscription.batchComplete':
				return this.#complete(domainState, frame, verifyInstallation);
		}
	}

	/** Expiry cannot discard an installed bank or a later replacement stage. */
	abandonIncompleteStage(begin: BatchBegin): boolean {
		const domain = this.#domains.get(begin.domain);
		const stage = domain?.stage;
		if (
			domain?.incarnation !== begin.incarnation ||
			begin.handle !== this.#handle ||
			stage?.begin.batchId !== begin.batchId ||
			stage.complete !== null
		)
			return false;
		domain.stage = null;
		domain.expiredBatchId = begin.batchId;
		return true;
	}

	hasStagedPart(frame: BatchPart): boolean {
		const stage = this.#domains.get(frame.domain)?.stage;
		return stage?.begin.batchId === frame.batchId && stage.partsByIndex.has(frame.partIndex);
	}

	hasIncompleteStage(begin: BatchBegin): boolean {
		const stage = this.#domains.get(begin.domain)?.stage;
		return stage?.begin.batchId === begin.batchId && stage.complete === null;
	}

	cursor(domain: string): number {
		return this.#domains.get(domain)?.cursor ?? 0;
	}

	records(domain: string): readonly InstalledRecord[] {
		return [...(this.#domains.get(domain)?.recordsByKey.values() ?? [])].sort((left, right) =>
			left.key.localeCompare(right.key),
		);
	}

	staleRecords(domain: string): readonly InstalledRecord[] {
		return [...(this.#staleRecordsByDomain.get(domain)?.values() ?? [])].sort((left, right) =>
			left.key.localeCompare(right.key),
		);
	}

	/** Includes members whose collection dependency became ready in this turn. */
	takeInstallations(): readonly BridgeProductViewInstallation[] {
		return this.#completedInstallations.splice(0);
	}

	#begin(
		domainState: DomainState,
		frame: BatchBegin,
		admitSnapshot?: (begin: BatchBegin) => boolean,
	): BridgeProductBatchAcceptance {
		if (domainState.containedBegin?.batchId === frame.batchId) return { kind: 'ignored' };
		const currentBegin = domainState.stage?.begin ?? domainState.containedBegin;
		if (currentBegin !== null && frame.streamSequence < currentBegin.streamSequence)
			return { kind: 'ignored' };
		if (domainState.expiredBatchId === frame.batchId) return { kind: 'ignored' };
		if (domainState.lastInstalledBatchId === frame.batchId) return { kind: 'ignored' };
		if (frame.streamSequence <= domainState.lastInstalledCompleteStreamSequence)
			return { kind: 'ignored' };
		if (!domainState.hasCertifiedSnapshot && frame.mode === 'change')
			return { kind: 'resnapshot', domain: frame.domain, rejection: 'changeBeforeSnapshot' };
		if (frame.targetRevision < domainState.cursor) return { kind: 'ignored' };
		const initialCumulativeCoverage =
			!domainState.hasCertifiedSnapshot && frame.mode === 'coverage' && frame.baseRevision === 0;
		if (
			frame.mode !== 'snapshot' &&
			!initialCumulativeCoverage &&
			frame.baseRevision < domainState.cursor
		)
			return { kind: 'ignored' };
		if (frame.mode !== 'snapshot' && frame.baseRevision > domainState.cursor) {
			domainState.stage = null;
			return { kind: 'resnapshot', domain: frame.domain, rejection: 'revisionGap' };
		}
		if (!sameViewFilter(frame.scope, this.#scope)) {
			domainState.stage = null;
			return { kind: 'ignored' };
		}
		const priorStage = domainState.stage;
		if (priorStage?.begin.batchId === frame.batchId) {
			if (sameJSON(priorStage.begin, frame)) return { kind: 'staged' };
			domainState.stage = null;
			return { kind: 'resnapshot', domain: frame.domain, rejection: 'conflictingBegin' };
		}
		if (priorStage !== null && frame.mode !== 'snapshot') {
			domainState.stage = null;
			return { kind: 'resnapshot', domain: frame.domain, rejection: 'overlappingChange' };
		}
		if (frame.mode === 'snapshot' && frame.snapshotCause === undefined)
			throw new Error('Snapshot cause is required.');
		if (frame.mode === 'snapshot' && admitSnapshot?.(frame) === false) {
			// Keep receipt identity only: contained parts return credits without entering the side bank.
			domainState.stage = null;
			domainState.containedBegin = frame;
			domainState.receiptBaselinePending = true;
			return { kind: 'ignored', snapshotContained: true };
		}
		domainState.stage = { begin: frame, complete: null, partsByIndex: new Map() };
		domainState.containedBegin = null;
		domainState.expiredBatchId = null;
		if (frame.mode === 'snapshot') domainState.receiptBaselinePending = true;
		return {
			kind: 'staged',
			...(frame.mode === 'snapshot' && frame.snapshotCause !== undefined
				? { snapshotCause: frame.snapshotCause }
				: {}),
		};
	}

	#part(domainState: DomainState, frame: BatchPart): BridgeProductBatchAcceptance {
		const contained = domainState.containedBegin;
		if (contained !== null && contained.batchId === frame.batchId) {
			if (
				frame.partIndex >= contained.partCount ||
				(frame.part.operation !== 'evict' && frame.part.revision > contained.targetRevision)
			) {
				return { kind: 'ignored' };
			}
			return { kind: 'ignored', ...this.#receivePart(domainState, frame) };
		}
		const stage = domainState.stage;
		if (
			stage !== null &&
			stage.begin.batchId !== frame.batchId &&
			frame.streamSequence < stage.begin.streamSequence
		)
			return { kind: 'ignored' };
		if (
			stage === null &&
			(frame.batchId === domainState.lastInstalledBatchId ||
				frame.streamSequence <= domainState.lastInstalledCompleteStreamSequence)
		)
			return { kind: 'ignored' };
		if (stage === null || stage.begin.batchId !== frame.batchId)
			return { kind: 'resnapshot', domain: frame.domain, rejection: 'missingStage' };
		if (frame.part.operation !== 'evict' && frame.part.revision > stage.begin.targetRevision) {
			domainState.stage = null;
			return { kind: 'resnapshot', domain: frame.domain, rejection: 'partRevisionAhead' };
		}
		if (frame.partIndex >= stage.begin.partCount) {
			domainState.stage = null;
			return { kind: 'resnapshot', domain: frame.domain, rejection: 'partIndexOutsideBatch' };
		}
		const existing = stage.partsByIndex.get(frame.partIndex);
		if (existing !== undefined && !sameJSON(existing.part, frame.part)) {
			domainState.stage = null;
			return { kind: 'resnapshot', domain: frame.domain, rejection: 'conflictingPart' };
		}
		stage.partsByIndex.set(frame.partIndex, frame);
		if (
			domainState.receiptBaselinePending &&
			frame.deliverySequence - frame.partIndex - 1 < domainState.receivedThroughDeliverySequence
		) {
			domainState.stage = null;
			return { kind: 'resnapshot', domain: frame.domain, rejection: 'receiptBaselineRegressed' };
		}
		return { kind: 'staged', ...this.#receivePart(domainState, frame) };
	}

	#receivePart(
		domainState: DomainState,
		frame: BatchPart,
	): { readonly receivedThroughDeliverySequence?: number } {
		if (domainState.receiptBaselinePending) {
			// A resnapshot abandons native's older in-transit credits. The first
			// received part establishes its sealed batch's sequence base even if
			// an earlier part in this same batch was delayed or lost.
			const baseline = frame.deliverySequence - frame.partIndex - 1;
			if (baseline < domainState.receivedThroughDeliverySequence) {
				domainState.stage = null;
				return {};
			}
			domainState.receivedPartSequences.clear();
			domainState.receivedThroughDeliverySequence = baseline;
			domainState.receiptBaselinePending = false;
		}
		const priorReceivedThrough = domainState.receivedThroughDeliverySequence;
		domainState.receivedPartSequences.add(frame.deliverySequence);
		while (
			domainState.receivedPartSequences.delete(domainState.receivedThroughDeliverySequence + 1)
		) {
			domainState.receivedThroughDeliverySequence += 1;
		}
		return domainState.receivedThroughDeliverySequence === priorReceivedThrough
			? {}
			: { receivedThroughDeliverySequence: domainState.receivedThroughDeliverySequence };
	}

	#complete(
		domainState: DomainState,
		frame: BatchComplete,
		verifyInstallation?: (installation: BridgeProductViewInstallation) => void,
	): BridgeProductBatchAcceptance {
		if (domainState.containedBegin?.batchId === frame.batchId) return { kind: 'ignored' };
		const stage = domainState.stage;
		if (
			stage !== null &&
			stage.begin.batchId !== frame.batchId &&
			frame.streamSequence < stage.begin.streamSequence
		)
			return { kind: 'ignored' };
		if (
			stage === null &&
			(frame.batchId === domainState.lastInstalledBatchId ||
				frame.streamSequence <= domainState.lastInstalledCompleteStreamSequence)
		)
			return { kind: 'ignored' };
		if (stage === null || stage.begin.batchId !== frame.batchId)
			return { kind: 'resnapshot', domain: frame.domain, rejection: 'missingStage' };
		if (stage.begin.scope.kind !== frame.coveredScope.kind) {
			domainState.stage = null;
			return { kind: 'resnapshot', domain: frame.domain, rejection: 'coveredScopeMismatch' };
		}
		if (stage.partsByIndex.size !== stage.begin.partCount) {
			domainState.stage = null;
			return { kind: 'resnapshot', domain: frame.domain, rejection: 'incompleteBatch' };
		}
		stage.complete = frame;
		if (
			stage.begin.requiresCollection !== undefined &&
			this.cursor('collection') < stage.begin.requiresCollection
		)
			return { kind: 'staged' };
		const installed = this.#install(frame.domain, domainState, stage, verifyInstallation);
		if (frame.domain === 'collection') this.#installReadyMembers(verifyInstallation);
		return installed;
	}

	#installReadyMembers(
		verifyInstallation?: (installation: BridgeProductViewInstallation) => void,
	): void {
		for (const [domain, state] of this.#domains) {
			const stage = state.stage;
			if (
				domain === 'collection' ||
				stage?.complete === null ||
				stage === null ||
				(stage.begin.requiresCollection ?? 0) > this.cursor('collection')
			)
				continue;
			this.#install(domain, state, stage, verifyInstallation);
		}
	}

	#install(
		domain: string,
		state: DomainState,
		stage: StagedBatch,
		verifyInstallation?: (installation: BridgeProductViewInstallation) => void,
	): BridgeProductBatchAcceptance {
		const nextRecords = new Map(state.recordsByKey);
		const nextTombstones = new Map(state.tombstoneRevisionByKey);
		const nextStaleRecords = new Map(this.#staleRecordsByDomain.get(domain));
		const includedKeys = new Set<string>();
		for (let index = 0; index < stage.begin.partCount; index += 1) {
			const part = stage.partsByIndex.get(index)?.part;
			if (part === undefined) return { kind: 'resnapshot', domain, rejection: 'missingPart' };
			includedKeys.add(part.key);
			if (part.operation === 'evict') {
				nextRecords.delete(part.key);
				nextStaleRecords.delete(part.key);
				continue;
			}
			let priorRevision = Math.max(
				nextRecords.get(part.key)?.revision ?? 0,
				nextTombstones.get(part.key) ?? 0,
			);
			if (stage.begin.mode !== 'snapshot') {
				const floor = state.certifiedAbsenceFloorsByScope.get(viewFilterKey(stage.begin.scope));
				if (floor !== undefined && this.#coversKey(floor.coveredScope, part.key)) {
					priorRevision = Math.max(priorRevision, floor.revision);
				}
			}
			if (part.revision <= priorRevision) continue;
			nextStaleRecords.delete(part.key);
			if (part.operation === 'delete') {
				nextRecords.delete(part.key);
				nextTombstones.set(part.key, part.revision);
			} else {
				nextRecords.set(part.key, {
					key: part.key,
					revision: part.revision,
					value: part.value,
				});
				nextTombstones.delete(part.key);
			}
		}
		if (stage.begin.mode === 'snapshot') {
			for (const [key, record] of nextRecords) {
				if (
					!includedKeys.has(key) &&
					record.revision <= stage.begin.targetRevision &&
					this.#coversKey(stage.complete?.coveredScope ?? stage.begin.scope, key)
				)
					nextRecords.delete(key);
			}
		}
		const installation = {
			begin: stage.begin,
			certified:
				stage.begin.mode !== 'coverage' &&
				(stage.begin.mode === 'snapshot' || state.hasCertifiedSnapshot),
			domain,
			records: [...nextRecords.values()],
			staleRecords:
				stage.begin.mode === 'coverage'
					? [...nextStaleRecords.values()].filter((record) => !nextRecords.has(record.key))
					: [],
		};
		try {
			verifyInstallation?.(installation);
		} catch {
			state.stage = null;
			return { kind: 'resnapshot', domain, rejection: 'payloadVerificationFailed' };
		}
		if (stage.begin.mode === 'snapshot') {
			const coveredScope = stage.complete?.coveredScope ?? stage.begin.scope;
			state.certifiedAbsenceFloorsByScope.set(viewFilterKey(coveredScope), {
				coveredScope,
				revision: stage.begin.targetRevision,
			});
		}
		if (stage.begin.mode === 'snapshot') {
			const coveredScope = stage.complete?.coveredScope ?? stage.begin.scope;
			for (const key of nextStaleRecords.keys()) {
				if (this.#coversKey(coveredScope, key)) nextStaleRecords.delete(key);
			}
		}
		if (nextStaleRecords.size === 0) this.#staleRecordsByDomain.delete(domain);
		else this.#staleRecordsByDomain.set(domain, nextStaleRecords);
		state.recordsByKey.clear();
		for (const [key, record] of nextRecords) state.recordsByKey.set(key, record);
		state.tombstoneRevisionByKey.clear();
		for (const [key, revision] of nextTombstones) state.tombstoneRevisionByKey.set(key, revision);
		state.cursor = stage.begin.targetRevision;
		if (stage.begin.mode === 'snapshot') state.hasCertifiedSnapshot = true;
		state.lastInstalledBatchId = stage.begin.batchId;
		state.lastInstalledCompleteStreamSequence = stage.complete?.streamSequence ?? 0;
		state.stage = null;
		this.#completedInstallations.push(installation);
		return { kind: 'installed', domain, targetRevision: state.cursor };
	}
}

function sameJSON(left: unknown, right: unknown): boolean {
	return canonicalJSON(left) === canonicalJSON(right);
}

function sameViewFilter(left: BatchBegin['scope'], right: BatchBegin['scope']): boolean {
	if (left.kind !== right.kind) return false;
	if (left.kind !== 'file' || right.kind !== 'file') return true;
	return (
		sameJSON(left.changeFilter, right.changeFilter) && sameJSON(left.pathScope, right.pathScope)
	);
}

function viewFilterKey(scope: BatchBegin['scope']): string {
	return scope.kind === 'file'
		? canonicalJSON({
				kind: scope.kind,
				changeFilter: scope.changeFilter,
				pathScope: scope.pathScope,
			})
		: canonicalJSON({ kind: scope.kind });
}

function canonicalJSON(value: unknown): string {
	if (Array.isArray(value)) return `[${value.map(canonicalJSON).join(',')}]`;
	if (isJSONRecord(value)) {
		return `{${Object.keys(value)
			.sort()
			.map((key) => `${JSON.stringify(key)}:${canonicalJSON(value[key])}`)
			.join(',')}}`;
	}
	return JSON.stringify(value) ?? 'undefined';
}

function isJSONRecord(value: unknown): value is Readonly<Record<string, unknown>> {
	return value !== null && typeof value === 'object' && !Array.isArray(value);
}
