import { describe, expect, test } from 'vitest';

import fileCorpus from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-file-batch-row-corpus.json' with { type: 'json' };
import { BridgeProductBatchFrameRouter } from './bridge-product-batch-frame-router.js';
import {
	bridgeProductBatchFrameSchema,
	type BridgeProductBatchFrame,
} from './bridge-product-batch-wire-contracts.js';
import {
	installBridgeProductFileBatch,
	type BridgeProductInstalledFileView,
} from './bridge-product-file-batch-installer.js';
import { bridgeProductFileBatchRowSchema } from './bridge-product-file-batch-row-contracts.js';
import { BridgeProductViewBatchReceiver } from './bridge-product-view-batch-receiver.js';

const scope = {
	kind: 'file',
	changeFilter: { kind: 'none' },
	interests: [],
	pathScope: [],
} as const;
const identity = {
	domain: 'default',
	handle: 'file-handle',
	incarnation: 'file-incarnation',
	metadataStreamId: 'metadata-stream',
	paneSessionId: 'pane-session',
	scopeRevision: 1,
	subscriptionId: 'file-subscription',
	subscriptionKind: 'file.metadata',
	wireVersion: 2,
	workerInstanceId: 'worker-instance',
} as const;
interface FixtureRecord {
	readonly key: string;
	readonly revision: number;
	readonly value: unknown;
	readonly operation?: 'put' | 'delete';
}

function frameFactory(): (props: {
	readonly base?: number;
	readonly handle?: string;
	readonly incarnation?: string;
	readonly snapshotCause:
		| import('./bridge-product-batch-wire-contracts.js').BridgeProductSnapshotCause
		| undefined;
	readonly mode: 'snapshot' | 'coverage' | 'change';
	readonly records: readonly FixtureRecord[];
	readonly scope?: Extract<
		BridgeProductBatchFrame,
		{ readonly kind: 'subscription.batchBegin' }
	>['scope'];
	readonly scopeRevision?: number;
	readonly target: number;
}) => readonly BridgeProductBatchFrame[] {
	let streamSequence = 0;
	let deliverySequence = 0;
	let batchSequence = 0;
	return (props): readonly BridgeProductBatchFrame[] => {
		const shared = {
			...identity,
			batchId: `batch-${++batchSequence}`,
			handle: props.handle ?? identity.handle,
			incarnation: props.incarnation ?? identity.incarnation,
			scopeRevision: props.scopeRevision ?? identity.scopeRevision,
		};
		return [
			bridgeProductBatchFrameSchema.parse({
				...shared,
				kind: 'subscription.batchBegin',
				streamSequence: ++streamSequence,
				baseRevision: props.base ?? 0,
				mode: props.mode,
				...(props.snapshotCause === undefined ? {} : { snapshotCause: props.snapshotCause }),
				partCount: props.records.length,
				scope: props.scope ?? scope,
				targetRevision: props.target,
			}),
			...props.records.map(
				(record, index): BridgeProductBatchFrame =>
					bridgeProductBatchFrameSchema.parse({
						...shared,
						kind: 'subscription.batchPart',
						streamSequence: ++streamSequence,
						deliverySequence: ++deliverySequence,
						partIndex: index,
						part:
							record.operation === 'delete'
								? { operation: 'delete', key: record.key, revision: record.revision }
								: {
										operation: 'put',
										key: record.key,
										revision: record.revision,
										value: record.value,
									},
					}),
			),
			bridgeProductBatchFrameSchema.parse({
				...shared,
				kind: 'subscription.batchComplete',
				streamSequence: ++streamSequence,
				coveredScope: props.scope ?? scope,
			}),
		];
	};
}

function fileReceiver(): BridgeProductViewBatchReceiver {
	const receiver = new BridgeProductViewBatchReceiver({ ...identity, scope });
	receiver.admitDomain(identity.domain, identity.incarnation);
	return receiver;
}

function installFrames(
	receiver: BridgeProductViewBatchReceiver,
	frames: readonly BridgeProductBatchFrame[],
): void {
	for (const frame of frames) receiver.accept(frame);
}

function rowRecord(path: string, revision: number): FixtureRecord {
	return {
		key: `/workspace/${path}`,
		revision,
		value: bridgeProductFileBatchRowSchema.parse({
			...fileCorpus.rows[0]?.row,
			displayKey: path,
			parentDisplayKey: null,
			depth: 0,
			name: path,
			sortKey: path,
			fileId: `file-${path}`,
			rowId: `row-${path}`,
			descriptorOutcome: null,
			readDescriptor: null,
		}),
	};
}

function statusRecord(
	status: 'loading' | 'ready',
	revision: number,
	sourceId = 'source-1',
): FixtureRecord {
	const fixture = fileCorpus.memberStatuses[0]?.record;
	if (fixture === undefined) throw new Error('File member status corpus missing.');
	return {
		key: 'member-status',
		revision,
		value: { ...fixture, status, source: { ...fixture.source, sourceId } },
	};
}

describe('File progressive coverage through the real batch codec and receiver', () => {
	test('successive replacement coverage retains unseen stale geometry until final certification', () => {
		const receiver = fileReceiver();
		const batch = frameFactory();
		installFrames(
			receiver,
			batch({
				mode: 'snapshot',
				snapshotCause: 'open',
				target: 1,
				records: [
					{ key: 'a', revision: 1, value: 'old a' },
					{ key: 'b', revision: 1, value: 'old b' },
				],
			}),
		);
		receiver.replaceHandle('handle-2', scope, 1);
		receiver.admitDomain('default', 'incarnation-2');
		installFrames(
			receiver,
			batch({
				snapshotCause: undefined,
				mode: 'coverage',
				handle: 'handle-2',
				incarnation: 'incarnation-2',
				target: 2,
				records: [{ key: 'a', revision: 2, value: 'new a' }],
			}),
		);
		receiver.replaceHandle('handle-3', scope, 1);
		receiver.admitDomain('default', 'incarnation-3');
		installFrames(
			receiver,
			batch({
				snapshotCause: undefined,
				mode: 'coverage',
				handle: 'handle-3',
				incarnation: 'incarnation-3',
				target: 3,
				records: [{ key: 'c', revision: 3, value: 'new c' }],
			}),
		);
		expect(
			receiver
				.takeInstallations()
				.at(-1)
				?.staleRecords.toSorted((left, right) => left.key.localeCompare(right.key)),
		).toEqual([
			{ key: 'a', revision: 2, value: 'new a' },
			{ key: 'b', revision: 1, value: 'old b' },
		]);
		installFrames(
			receiver,
			batch({
				mode: 'snapshot',
				snapshotCause: 'open',
				handle: 'handle-3',
				incarnation: 'incarnation-3',
				target: 4,
				records: [{ key: 'c', revision: 4, value: 'final c' }],
			}),
		);
		expect(receiver.staleRecords('default')).toEqual([]);
	});

	test('named deletion in coverage retires stale geometry and its tombstone refuses late resurrection', () => {
		const receiver = fileReceiver();
		const batch = frameFactory();
		installFrames(
			receiver,
			batch({
				mode: 'snapshot',
				snapshotCause: 'open',
				target: 1,
				records: [
					{ key: 'a', revision: 1, value: 'old a' },
					{ key: 'b', revision: 1, value: 'old b' },
				],
			}),
		);
		receiver.replaceHandle('handle-2', scope, 1);
		receiver.admitDomain('default', 'incarnation-2');
		installFrames(
			receiver,
			batch({
				snapshotCause: undefined,
				mode: 'coverage',
				handle: 'handle-2',
				incarnation: 'incarnation-2',
				target: 3,
				records: [{ key: 'a', revision: 3, operation: 'delete', value: null }],
			}),
		);
		expect(receiver.takeInstallations().at(-1)?.staleRecords).toEqual([
			{ key: 'b', revision: 1, value: 'old b' },
		]);
		installFrames(
			receiver,
			batch({
				snapshotCause: undefined,
				mode: 'coverage',
				handle: 'handle-2',
				incarnation: 'incarnation-2',
				target: 4,
				records: [{ key: 'a', revision: 2, value: 'late a' }],
			}),
		);
		expect(receiver.records('default')).toEqual([]);
		expect(receiver.takeInstallations().at(-1)?.staleRecords).toEqual([
			{ key: 'b', revision: 1, value: 'old b' },
		]);
		installFrames(
			receiver,
			batch({
				snapshotCause: undefined,
				mode: 'coverage',
				handle: 'handle-2',
				incarnation: 'incarnation-2',
				target: 5,
				records: [{ key: 'a', revision: 5, value: 'recreated a' }],
			}),
		);
		expect(receiver.records('default')).toEqual([{ key: 'a', revision: 5, value: 'recreated a' }]);
	});

	test('initial membership A to B to A keeps incompatible prefixes stale rather than current', () => {
		const receiver = fileReceiver();
		const batch = frameFactory();
		installFrames(
			receiver,
			batch({
				snapshotCause: undefined,
				mode: 'coverage',
				target: 1,
				records: [{ key: 'a', revision: 1, value: 'prefix a' }],
			}),
		);
		const scopeB = { ...scope, pathScope: ['b'] };
		expect(receiver.setScope(scopeB, 2)).toBe(true);
		installFrames(
			receiver,
			batch({
				snapshotCause: undefined,
				mode: 'coverage',
				scope: scopeB,
				scopeRevision: 2,
				target: 2,
				records: [{ key: 'b', revision: 2, value: 'prefix b' }],
			}),
		);
		expect(receiver.records('default')).toEqual([{ key: 'b', revision: 2, value: 'prefix b' }]);
		expect(receiver.takeInstallations().at(-1)?.staleRecords).toEqual([
			{ key: 'a', revision: 1, value: 'prefix a' },
		]);
		expect(receiver.setScope(scope, 3)).toBe(true);
		installFrames(
			receiver,
			batch({
				snapshotCause: undefined,
				mode: 'coverage',
				scopeRevision: 3,
				target: 3,
				records: [{ key: 'a', revision: 3, value: 'current a' }],
			}),
		);
		expect(receiver.records('default')).toEqual([{ key: 'a', revision: 3, value: 'current a' }]);
		expect(receiver.takeInstallations().at(-1)?.staleRecords).toEqual([
			{ key: 'b', revision: 2, value: 'prefix b' },
		]);
		installFrames(
			receiver,
			batch({
				mode: 'snapshot',
				snapshotCause: 'open',
				scopeRevision: 3,
				target: 4,
				records: [{ key: 'a', revision: 4, value: 'final a' }],
			}),
		);
		expect(receiver.staleRecords('default')).toEqual([]);
	});

	test('missing coverage parts retain the previous stale bank and cannot install a prefix', () => {
		const receiver = fileReceiver();
		const batch = frameFactory();
		installFrames(
			receiver,
			batch({
				mode: 'snapshot',
				snapshotCause: 'open',
				target: 1,
				records: [{ key: 'old', revision: 1, value: 'old row' }],
			}),
		);
		receiver.replaceHandle('replacement-handle', scope, 1);
		receiver.admitDomain('default', 'replacement-incarnation');
		const incomplete = batch({
			snapshotCause: undefined,
			mode: 'coverage',
			handle: 'replacement-handle',
			incarnation: 'replacement-incarnation',
			target: 2,
			records: [
				{ key: 'a', revision: 2, value: 'first' },
				{ key: 'b', revision: 2, value: 'missing' },
			],
		});
		const begin = incomplete[0];
		const part = incomplete[1];
		const complete = incomplete.at(-1);
		if (begin === undefined || part === undefined || complete === undefined)
			throw new Error('Missing coverage frames.');
		expect(receiver.accept(begin).kind).toBe('staged');
		expect(receiver.accept(part).kind).toBe('staged');
		expect(receiver.accept(complete).kind).toBe('resnapshot');
		expect(receiver.records('default')).toEqual([]);
		expect(receiver.staleRecords('default')).toEqual([
			{ key: 'old', revision: 1, value: 'old row' },
		]);
	});

	test('the typed File installer preserves stale presentation rows without promoting their descriptors', () => {
		const batch = frameFactory();
		const oldRecords = [rowRecord('a.ts', 1), rowRecord('b.ts', 1), statusRecord('ready', 1)];
		const oldBegin = batch({
			mode: 'snapshot',
			snapshotCause: 'open',
			target: 1,
			records: oldRecords,
		})[0];
		if (oldBegin?.kind !== 'subscription.batchBegin') throw new Error('Initial begin missing.');
		const previous = installBridgeProductFileBatch({
			begin: oldBegin,
			domain: 'default',
			records: oldRecords,
			certified: true,
			staleRecords: [],
		});
		const records = [rowRecord('a.ts', 2), statusRecord('loading', 2, 'source-2')];
		const begin = batch({
			snapshotCause: undefined,
			mode: 'coverage',
			handle: 'replacement-handle',
			incarnation: 'replacement-incarnation',
			target: 2,
			records,
		})[0];
		if (begin?.kind !== 'subscription.batchBegin') throw new Error('Coverage begin missing.');
		const partial = installBridgeProductFileBatch(
			{ begin, certified: false, domain: 'default', records, staleRecords: oldRecords },
			previous,
		);
		expect(partial.memberStatus.status).toBe('loading');
		expect(partial.currentRecords.map((record) => record.key)).toEqual(['/workspace/a.ts']);
		expect(partial.displayTreeRows.map((row) => row.path)).toEqual(['a.ts', 'b.ts']);
		expect(partial.contentRequests).toEqual([]);
	});

	test('replacement coverage prefers current geometry when source keys change at the same display path', () => {
		const batch = frameFactory();
		const oldFile = fileCorpus.rows[0];
		const parentDirectory = fileCorpus.rows[1];
		if (oldFile === undefined || parentDirectory === undefined)
			throw new Error('File corpus incomplete.');
		const currentFile = {
			key: '/new-root/src/a.ts',
			revision: 2,
			value: { ...oldFile.row, descriptorOutcome: null, readDescriptor: null },
		};
		const records = [
			currentFile,
			{ key: '/new-root/src', revision: 2, value: parentDirectory.row },
			statusRecord('loading', 2, 'new-source'),
		];
		const begin = batch({ snapshotCause: undefined, mode: 'coverage', target: 2, records })[0];
		if (begin?.kind !== 'subscription.batchBegin') throw new Error('Coverage begin missing.');
		const partial = installBridgeProductFileBatch({
			begin,
			certified: false,
			domain: 'default',
			records,
			staleRecords: [
				{ key: oldFile.recordKey, revision: 1, value: oldFile.row },
				{ key: parentDirectory.recordKey, revision: 1, value: parentDirectory.row },
				rowRecord('b.ts', 1),
			],
		});
		expect(partial.displayTreeRows.map((row) => row.path).toSorted()).toEqual([
			'b.ts',
			'src',
			'src/a.ts',
		]);
		expect(partial.currentRecords.map((record) => record.key).toSorted()).toEqual([
			'/new-root/src',
			'/new-root/src/a.ts',
		]);
		expect(partial.contentRequests).toEqual([]);
		expect(partial.contentItems).toEqual([]);
	});

	test('initial cumulative coverage installs without certifying absence, then final snapshot prunes', () => {
		const receiver = fileReceiver();
		const batch = frameFactory();
		installFrames(
			receiver,
			batch({
				snapshotCause: undefined,
				mode: 'coverage',
				target: 2,
				records: [
					{ key: 'a', revision: 1, value: 'first' },
					{ key: 'obsolete', revision: 2, value: 'old' },
				],
			}),
		);
		expect(receiver.records('default').map((record) => record.key)).toEqual(['a', 'obsolete']);
		expect(receiver.cursor('default')).toBe(2);
		installFrames(
			receiver,
			batch({
				snapshotCause: undefined,
				mode: 'coverage',
				target: 3,
				records: [{ key: 'a', revision: 3, value: 'updated' }],
			}),
		);
		expect(receiver.records('default').map((record) => record.key)).toEqual(['a', 'obsolete']);
		// Coverage advances progress, but never establishes the snapshot prerequisite for changes.
		const change = batch({
			snapshotCause: undefined,
			mode: 'change',
			base: 3,
			target: 4,
			records: [],
		})[0];
		if (change === undefined) throw new Error('Change begin missing.');
		expect(receiver.accept(change).kind).toBe('resnapshot');
		installFrames(
			receiver,
			batch({
				mode: 'snapshot',
				snapshotCause: 'open',
				target: 5,
				records: [{ key: 'a', revision: 5, value: 'final' }],
			}),
		);
		expect(receiver.records('default')).toEqual([{ key: 'a', revision: 5, value: 'final' }]);
		const late = batch({
			snapshotCause: undefined,
			mode: 'coverage',
			target: 3,
			records: [{ key: 'obsolete', revision: 2, value: 'late' }],
		});
		installFrames(receiver, late);
		expect(receiver.records('default')).toEqual([{ key: 'a', revision: 5, value: 'final' }]);
	});

	test('certified domains keep existing base continuity and absence floors for coverage', () => {
		const receiver = fileReceiver();
		const batch = frameFactory();
		installFrames(
			receiver,
			batch({ mode: 'snapshot', snapshotCause: 'open', target: 5, records: [] }),
		);
		const behind = batch({
			snapshotCause: undefined,
			mode: 'coverage',
			target: 6,
			records: [{ key: 'gone', revision: 2, value: 'stale' }],
		})[0];
		if (behind === undefined) throw new Error('Coverage begin missing.');
		expect(receiver.accept(behind).kind).toBe('ignored');
		installFrames(
			receiver,
			batch({
				snapshotCause: undefined,
				mode: 'coverage',
				base: 5,
				target: 6,
				records: [{ key: 'gone', revision: 2, value: 'stale' }],
			}),
		);
		expect(receiver.records('default')).toEqual([]);
		expect(receiver.cursor('default')).toBe(6);
	});

	test('replacement coverage keeps stale display rows outside its current bank until full certification', () => {
		let installed: BridgeProductInstalledFileView | null = null;
		let installedCount = 0;
		const router = new BridgeProductBatchFrameRouter({
			deadlineClock: { schedule: () => (): void => {} },
			progressDeadlineMilliseconds: 5_000,
		});
		router.setSinks({
			install: (installation): void => {
				installed = installBridgeProductFileBatch(installation, installed);
				installedCount += 1;
			},
			receipt: (): void => {},
			resnapshot: (): void => {},
			resnapshotLatest: (): void => {},
		});
		const batch = frameFactory();
		for (const frame of batch({
			mode: 'snapshot',
			snapshotCause: 'open',
			target: 1,
			records: [rowRecord('a.ts', 1), rowRecord('b.ts', 1), statusRecord('ready', 1)],
		}))
			router.accept(frame);
		expect(installedCount).toBe(1);
		for (const frame of batch({
			snapshotCause: undefined,
			mode: 'coverage',
			handle: 'replacement-handle',
			incarnation: 'replacement-incarnation',
			target: 2,
			records: [rowRecord('a.ts', 2), statusRecord('loading', 2, 'source-2')],
		}))
			router.accept(frame);
		expect(installedCount).toBe(2);
		const partial = requiredInstalledView(installed);
		expect(partial.memberStatus.status).toBe('loading');
		expect(partial.currentRecords.map((record) => record.key)).toEqual(['/workspace/a.ts']);
		expect(partial.displayTreeRows.map((row) => row.path)).toEqual(['a.ts', 'b.ts']);
		for (const frame of batch({
			mode: 'snapshot',
			snapshotCause: 'open',
			handle: 'replacement-handle',
			incarnation: 'replacement-incarnation',
			target: 3,
			records: [rowRecord('a.ts', 3), statusRecord('ready', 3, 'source-2')],
		}))
			router.accept(frame);
		const final = requiredInstalledView(installed);
		expect(final.displayTreeRows.map((row) => row.path)).toEqual(['a.ts']);
		expect(final.memberStatus.status).toBe('ready');
		expect(installedCount).toBe(3);
	});
});

function requiredInstalledView(
	view: BridgeProductInstalledFileView | null,
): BridgeProductInstalledFileView {
	if (view === null) throw new Error('Expected the real router to install a File bank.');
	return view;
}
