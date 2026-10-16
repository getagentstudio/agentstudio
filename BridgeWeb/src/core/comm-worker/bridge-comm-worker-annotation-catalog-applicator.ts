import {
	MetadataCatalogAssembler,
	type MetadataCatalogAssemblerRejectionReason,
} from './bridge-metadata-catalog-assembler.js';
import {
	bridgeProductWorktreeAnnotationCatalogEntrySchema,
	type BridgeProductWorktreeAnnotationCatalogEntry,
	type BridgeProductWorktreeAnnotationEvent,
} from './bridge-product-worktree-annotation-contracts.js';

export interface BridgeCommWorkerAnnotationCatalogAuthority {
	readonly subscriptionId: string;
	readonly workerDerivationEpoch: number;
	readonly worktreeId: string;
}

export interface BridgeCommWorkerAnnotationCatalog {
	readonly authority: BridgeCommWorkerAnnotationCatalogAuthority;
	readonly catalogRevision: number;
	readonly entries: readonly BridgeProductWorktreeAnnotationCatalogEntry[];
	readonly messageIdsByThreadId: ReadonlyMap<string, readonly string[]>;
	readonly messagesById: ReadonlyMap<
		string,
		Extract<BridgeProductWorktreeAnnotationCatalogEntry, { kind: 'message' }>
	>;
	readonly orderedSessionIds: readonly string[];
	readonly sessionsById: ReadonlyMap<
		string,
		Extract<BridgeProductWorktreeAnnotationCatalogEntry, { kind: 'session' }>
	>;
	readonly threadIdsBySessionId: ReadonlyMap<string, readonly string[]>;
	readonly threadsById: ReadonlyMap<
		string,
		Extract<BridgeProductWorktreeAnnotationCatalogEntry, { kind: 'thread' }>
	>;
	readonly transferId: string;
}

export interface BridgeCommWorkerAnnotationCatalogPublication {
	readonly catalog: BridgeCommWorkerAnnotationCatalog;
	readonly surface: 'file' | 'review';
}

export type BridgeCommWorkerAnnotationCatalogRejectionReason =
	| MetadataCatalogAssemblerRejectionReason
	| 'duplicate_message_id'
	| 'duplicate_message_ordinal'
	| 'duplicate_session_id'
	| 'duplicate_thread_id'
	| 'duplicate_thread_ordinal'
	| 'generation_mismatch'
	| 'unknown_session'
	| 'unknown_thread';

export type BridgeCommWorkerAnnotationCatalogApplicatorResult =
	| { readonly status: 'accepted' }
	| {
			readonly catalog: BridgeCommWorkerAnnotationCatalog;
			readonly status: 'completed';
	  }
	| {
			readonly reason: BridgeCommWorkerAnnotationCatalogRejectionReason;
			readonly status: 'rejected';
	  };

type AnnotationCatalogEvent = Extract<
	BridgeProductWorktreeAnnotationEvent,
	{ kind: 'annotation.catalog' }
>;
type AnnotationSessionEntry = Extract<
	BridgeProductWorktreeAnnotationCatalogEntry,
	{ kind: 'session' }
>;
type AnnotationThreadEntry = Extract<
	BridgeProductWorktreeAnnotationCatalogEntry,
	{ kind: 'thread' }
>;
type AnnotationMessageEntry = Extract<
	BridgeProductWorktreeAnnotationCatalogEntry,
	{ kind: 'message' }
>;

export class BridgeCommWorkerAnnotationCatalogApplicator {
	readonly #assembler: MetadataCatalogAssembler<
		BridgeProductWorktreeAnnotationCatalogEntry,
		BridgeCommWorkerAnnotationCatalogAuthority
	>;
	#activeCatalog: BridgeCommWorkerAnnotationCatalog | null = null;
	#expectedAuthority: BridgeCommWorkerAnnotationCatalogAuthority;

	constructor(expectedAuthority: BridgeCommWorkerAnnotationCatalogAuthority) {
		this.#expectedAuthority = expectedAuthority;
		this.#assembler = new MetadataCatalogAssembler({
			authoritiesEqual: annotationCatalogAuthoritiesEqual,
			entrySchema: bridgeProductWorktreeAnnotationCatalogEntrySchema,
			expectedAuthority,
		});
	}

	get activeCatalog(): BridgeCommWorkerAnnotationCatalog | null {
		return this.#activeCatalog;
	}

	accept(event: AnnotationCatalogEvent): BridgeCommWorkerAnnotationCatalogApplicatorResult {
		if (event.authority.worktreeId !== this.#expectedAuthority.worktreeId) {
			return { reason: 'unexpected_authority', status: 'rejected' };
		}
		if (event.authority.applicationSourceGeneration !== event.transfer.catalogRevision) {
			return { reason: 'generation_mismatch', status: 'rejected' };
		}
		const result = this.#assembler.accept(this.#expectedAuthority, event.transfer);
		if (result.status !== 'completed') return result;
		const normalized = normalizeAnnotationCatalog({
			authority: result.catalog.authority,
			catalogRevision: result.catalog.catalogRevision,
			entries: result.catalog.entries,
			transferId: result.catalog.transferId,
		});
		if (normalized.status === 'rejected') return normalized;
		this.#activeCatalog = normalized.catalog;
		return normalized;
	}

	replaceExpectedAuthority(authority: BridgeCommWorkerAnnotationCatalogAuthority): void {
		if (annotationCatalogAuthoritiesEqual(this.#expectedAuthority, authority)) return;
		this.#expectedAuthority = authority;
		this.#assembler.replaceExpectedAuthority(authority);
	}

	retireExpectedAuthority(): void {
		this.#assembler.retireExpectedAuthority();
	}
}

export interface NormalizeAnnotationCatalogProps {
	readonly authority: BridgeCommWorkerAnnotationCatalogAuthority;
	readonly catalogRevision: number;
	readonly entries: readonly BridgeProductWorktreeAnnotationCatalogEntry[];
	readonly transferId: string;
}

export function normalizeAnnotationCatalog(props: NormalizeAnnotationCatalogProps):
	| { readonly catalog: BridgeCommWorkerAnnotationCatalog; readonly status: 'completed' }
	| {
			readonly reason: BridgeCommWorkerAnnotationCatalogRejectionReason;
			readonly status: 'rejected';
	  } {
	const sessionsById = new Map<string, AnnotationSessionEntry>();
	const threadsById = new Map<string, AnnotationThreadEntry>();
	const messagesById = new Map<string, AnnotationMessageEntry>();
	for (const entry of props.entries) {
		switch (entry.kind) {
			case 'session':
				if (sessionsById.has(entry.sessionId)) return rejected('duplicate_session_id');
				sessionsById.set(entry.sessionId, entry);
				break;
			case 'thread':
				if (threadsById.has(entry.threadId)) return rejected('duplicate_thread_id');
				threadsById.set(entry.threadId, entry);
				break;
			case 'message':
				if (messagesById.has(entry.messageId)) return rejected('duplicate_message_id');
				messagesById.set(entry.messageId, entry);
				break;
		}
	}

	const threadsBySessionId = new Map<string, AnnotationThreadEntry[]>();
	for (const thread of threadsById.values()) {
		if (!sessionsById.has(thread.sessionId)) return rejected('unknown_session');
		const siblings = threadsBySessionId.get(thread.sessionId) ?? [];
		if (siblings.some((candidate) => candidate.createdOrdinal === thread.createdOrdinal)) {
			return rejected('duplicate_thread_ordinal');
		}
		siblings.push(thread);
		threadsBySessionId.set(thread.sessionId, siblings);
	}

	const messagesByThreadId = new Map<string, AnnotationMessageEntry[]>();
	for (const message of messagesById.values()) {
		if (!threadsById.has(message.threadId)) return rejected('unknown_thread');
		const siblings = messagesByThreadId.get(message.threadId) ?? [];
		if (siblings.some((candidate) => candidate.ordinal === message.ordinal)) {
			return rejected('duplicate_message_ordinal');
		}
		siblings.push(message);
		messagesByThreadId.set(message.threadId, siblings);
	}

	return {
		catalog: {
			authority: props.authority,
			catalogRevision: props.catalogRevision,
			entries: canonicalAnnotationCatalogEntries({
				messagesByThreadId,
				sessionsById,
				threadsBySessionId,
			}),
			messageIdsByThreadId: sortedChildIds(messagesByThreadId, 'messageId', 'ordinal'),
			messagesById,
			orderedSessionIds: Object.freeze([...sessionsById.keys()].toSorted()),
			sessionsById,
			threadIdsBySessionId: sortedChildIds(threadsBySessionId, 'threadId', 'createdOrdinal'),
			threadsById,
			transferId: props.transferId,
		},
		status: 'completed',
	};
}

function canonicalAnnotationCatalogEntries(props: {
	readonly messagesByThreadId: ReadonlyMap<string, readonly AnnotationMessageEntry[]>;
	readonly sessionsById: ReadonlyMap<string, AnnotationSessionEntry>;
	readonly threadsBySessionId: ReadonlyMap<string, readonly AnnotationThreadEntry[]>;
}): readonly BridgeProductWorktreeAnnotationCatalogEntry[] {
	const entries: BridgeProductWorktreeAnnotationCatalogEntry[] = [];
	for (const sessionId of [...props.sessionsById.keys()].toSorted()) {
		const session = props.sessionsById.get(sessionId);
		if (session === undefined) continue;
		entries.push(session);
		for (const thread of (props.threadsBySessionId.get(sessionId) ?? []).toSorted(
			(left, right) => left.createdOrdinal - right.createdOrdinal,
		)) {
			entries.push(thread);
			entries.push(
				...(props.messagesByThreadId.get(thread.threadId) ?? []).toSorted(
					(left, right) => left.ordinal - right.ordinal,
				),
			);
		}
	}
	return Object.freeze(entries);
}

function sortedChildIds<
	TEntry extends Readonly<Record<TIdentityKey | TOrdinalKey, number | string>>,
	TIdentityKey extends keyof TEntry,
	TOrdinalKey extends keyof TEntry,
>(
	entriesByParentId: ReadonlyMap<string, readonly TEntry[]>,
	identityKey: TIdentityKey,
	ordinalKey: TOrdinalKey,
): ReadonlyMap<string, readonly string[]> {
	return new Map(
		[...entriesByParentId].map(([parentId, entries]) => [
			parentId,
			Object.freeze(
				entries
					.toSorted((left, right) => Number(left[ordinalKey]) - Number(right[ordinalKey]))
					.map((entry) => String(entry[identityKey])),
			),
		]),
	);
}

function annotationCatalogAuthoritiesEqual(
	left: BridgeCommWorkerAnnotationCatalogAuthority,
	right: BridgeCommWorkerAnnotationCatalogAuthority,
): boolean {
	return (
		left.subscriptionId === right.subscriptionId &&
		left.workerDerivationEpoch === right.workerDerivationEpoch &&
		left.worktreeId === right.worktreeId
	);
}

function rejected(reason: BridgeCommWorkerAnnotationCatalogRejectionReason): {
	readonly reason: BridgeCommWorkerAnnotationCatalogRejectionReason;
	readonly status: 'rejected';
} {
	return { reason, status: 'rejected' };
}
