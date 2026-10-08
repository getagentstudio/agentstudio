import { uuidv7 } from 'uuidv7';

import type { BridgeProductSnapshotCause } from '../core/comm-worker/bridge-product-batch-wire-contracts.js';
import { bridgeProductBatchFrameSchema } from '../core/comm-worker/bridge-product-batch-wire-contracts.js';
import {
	bridgeProductFileBatchRowSchema,
	type BridgeProductFileBatchRow,
} from '../core/comm-worker/bridge-product-file-batch-row-contracts.js';
import type { BridgeProductFileSourceIdentity } from '../core/comm-worker/bridge-product-file-contracts.js';
import {
	bridgeProductFileMemberStatusRecordSchema,
	type BridgeProductFileMemberStatusRecord,
} from '../core/comm-worker/bridge-product-file-member-status-contracts.js';
import { bridgeProductFileDescriptorReadyPayloadSchema } from '../core/comm-worker/bridge-product-subscription-contracts.js';
import type { BridgeProductViewInstallation } from '../core/comm-worker/bridge-product-view-batch-receiver.js';
import type { BridgeProductViewScopeRequest } from '../core/comm-worker/bridge-product-view-control-wire-contracts.js';

export type BrowserFileDescriptorOutcome = NonNullable<
	BridgeProductFileBatchRow['descriptorOutcome']
>;
export type BrowserFileViewScope = Extract<
	BridgeProductViewScopeRequest['scope'],
	{ readonly kind: 'file' }
>;
export type PublishBrowserFileBatch = (batch: BridgeProductViewInstallation) => void;

export interface BrowserFileDescriptorProps {
	readonly path: string;
	readonly fileId?: string;
	readonly descriptorId?: string;
	readonly source?: BridgeProductFileSourceIdentity;
	readonly declaredByteLength?: number;
	readonly expectedSha256?: string;
	readonly lineCount?: number;
	readonly endsWithNewline?: boolean;
	readonly availability?: 'available' | 'binary' | 'unavailable';
}

export function makeBrowserFileSourceIdentity(
	props: { readonly sourceCursor?: string; readonly subscriptionGeneration?: number } = {},
): BridgeProductFileSourceIdentity {
	return {
		repoId: '00000000-0000-4000-8000-000000000001',
		rootRevisionToken: 'root-revision-1',
		sourceCursor: props.sourceCursor ?? 'cursor-1',
		sourceId: 'dev-worktree-source',
		subscriptionGeneration: props.subscriptionGeneration ?? 1,
		worktreeId: '00000000-0000-4000-8000-000000000002',
	};
}

export function makeBrowserFileDescriptorOutcome(
	props: BrowserFileDescriptorProps,
): BrowserFileDescriptorOutcome {
	const source = props.source ?? makeBrowserFileSourceIdentity();
	const fileId = props.fileId ?? browserFileId(props.path);
	const rowId = browserFileRowId(props.path);
	const descriptorId =
		props.descriptorId ?? `descriptor:${browserSafeFileIdentityPath(props.path)}`;
	const declaredByteLength = props.declaredByteLength ?? 64;
	const lineCount = props.lineCount ?? 1;
	const availability = props.availability ?? 'available';
	const contentDescriptor = {
		contentKind: 'file.content',
		declaredByteLength,
		descriptorId,
		encoding: 'utf-8',
		expectedSha256: props.expectedSha256 ?? 'a'.repeat(64),
		fileId,
		maximumBytes: declaredByteLength,
		source,
		window: {
			kind: 'prefix',
			maximumBytes: declaredByteLength,
			maximumLines: lineCount,
			startByte: 0,
		},
	};
	return bridgeProductFileDescriptorReadyPayloadSchema.parse({
		availability:
			availability === 'available'
				? { availabilityKind: 'available', contentDescriptor }
				: availability === 'binary'
					? { availabilityKind: 'binary' }
					: { availabilityKind: 'unavailable', reason: 'outside_scope' },
		encoding: availability === 'available' ? 'utf-8' : null,
		endsMidLine: false,
		endsWithNewline: availability === 'available' && (props.endsWithNewline ?? true),
		estimatedContentHeightPixels: null,
		fileExtension: 'ts',
		fileId,
		language: 'typescript',
		modifiedAtUnixMilliseconds: null,
		path: props.path,
		payloadByteCount: availability === 'available' ? declaredByteLength : 0,
		payloadLineCount: availability === 'available' ? lineCount : 0,
		rowId,
		sizeBytes: declaredByteLength,
		source,
		totalLineCount: availability === 'available' ? lineCount : null,
		truncationKind: 'none',
		virtualizedExtentKind: availability === 'available' ? 'exactLineCount' : 'unavailable',
	});
}

export async function makeBrowserFileDescriptorOutcomeForContent(
	props: Omit<BrowserFileDescriptorProps, 'declaredByteLength' | 'expectedSha256' | 'lineCount'> & {
		readonly content: string;
		readonly contentHandle?: string;
	},
): Promise<BrowserFileDescriptorOutcome> {
	const bytes = new TextEncoder().encode(props.content);
	const digest = new Uint8Array(await globalThis.crypto.subtle.digest('SHA-256', bytes));
	const expectedSha256 = Array.from(digest, (byte) => byte.toString(16).padStart(2, '0')).join('');
	const newlineCount = bytes.reduce((count, byte) => count + (byte === 0x0a ? 1 : 0), 0);
	return makeBrowserFileDescriptorOutcome({
		...props,
		declaredByteLength: bytes.byteLength,
		...(props.contentHandle === undefined ? {} : { descriptorId: props.contentHandle }),
		endsWithNewline: bytes.at(-1) === 0x0a,
		expectedSha256,
		lineCount: newlineCount + (bytes.byteLength > 0 && bytes.at(-1) !== 0x0a ? 1 : 0),
	});
}

export function makeBrowserFileRow(props: {
	readonly path: string;
	readonly kind?: BridgeProductFileBatchRow['kind'];
	readonly fileId?: string | null;
	readonly fileClass?: BridgeProductFileBatchRow['fileClass'];
	readonly changeStatus?: BridgeProductFileBatchRow['changeStatus'];
	readonly lineCount?: number | null;
	readonly sizeBytes?: number | null;
	readonly descriptorOutcome?: BrowserFileDescriptorOutcome | null;
}): BridgeProductFileBatchRow {
	const kind = props.kind ?? 'file';
	const name = props.path.split('/').at(-1) ?? props.path;
	const descriptorOutcome = props.descriptorOutcome ?? null;
	const readDescriptor =
		descriptorOutcome?.availability.availabilityKind === 'available'
			? descriptorOutcome.availability.contentDescriptor
			: null;
	return bridgeProductFileBatchRowSchema.parse({
		changeStatus: props.changeStatus ?? (kind === 'deleted' ? 'deleted' : null),
		depth: Math.max(props.path.split('/').length - 1, 0),
		descriptorOutcome,
		displayKey: props.path,
		fileClass: kind === 'file' ? (props.fileClass ?? 'source') : null,
		fileId:
			kind === 'file'
				? (props.fileId ?? descriptorOutcome?.fileId ?? browserFileId(props.path))
				: null,
		kind,
		lineCount:
			kind === 'file' ? (props.lineCount ?? descriptorOutcome?.totalLineCount ?? null) : null,
		name,
		oldPath: null,
		parentDisplayKey: props.path.includes('/')
			? props.path.slice(0, props.path.lastIndexOf('/'))
			: null,
		readDescriptor,
		rowId: browserFileRowId(props.path),
		sizeBytes: kind === 'file' ? (props.sizeBytes ?? descriptorOutcome?.sizeBytes ?? null) : null,
		sortKey: name,
	});
}

export function makeBrowserFileBatch(props: {
	readonly snapshotCause: BridgeProductSnapshotCause;
	readonly rows: readonly BridgeProductFileBatchRow[];
	readonly source?: BridgeProductFileSourceIdentity;
	readonly revision?: number;
	readonly status?: Partial<BridgeProductFileMemberStatusRecord>;
}): BridgeProductViewInstallation {
	const source = props.source ?? makeBrowserFileSourceIdentity();
	const revision = props.revision ?? 1;
	const rows = withBrowserFileParentDirectories(props.rows);
	const memberStatus = bridgeProductFileMemberStatusRecordSchema.parse({
		ahead: 0,
		behind: 0,
		branchName: 'main',
		kind: 'memberStatus',
		source,
		staged: 0,
		status: 'ready',
		unstaged: 0,
		untracked: 0,
		...props.status,
	});
	const begin = bridgeProductBatchFrameSchema.parse({
		baseRevision: 0,
		batchId: `browser-file-batch-${uuidv7()}`,
		domain: 'default',
		handle: 'browser-file-view-handle',
		incarnation: 'browser-file-view-incarnation',
		kind: 'subscription.batchBegin',
		metadataStreamId: 'browser-file-test-metadata-stream',
		mode: 'snapshot',
		snapshotCause: props.snapshotCause,
		paneSessionId: 'browser-file-test-pane-session',
		partCount: rows.length + 1,
		scope: { kind: 'file', changeFilter: { kind: 'none' }, interests: [], pathScope: [] },
		scopeRevision: 0,
		streamSequence: revision,
		subscriptionId: 'browser-file-metadata-subscription',
		subscriptionKind: 'file.metadata',
		targetRevision: revision,
		wireVersion: 2,
		workerInstanceId: 'browser-file-test-worker-instance',
	});
	if (begin.kind !== 'subscription.batchBegin')
		throw new Error('Expected browser File batch begin.');
	return {
		certified: true,
		staleRecords: [],
		begin,
		domain: 'default',
		records: [
			...rows.map((row) => ({
				key: `/workspace/${row.displayKey}`,
				revision,
				value: row,
			})),
			{ key: 'member-status', revision, value: memberStatus },
		],
	};
}

function withBrowserFileParentDirectories(
	rows: readonly BridgeProductFileBatchRow[],
): readonly BridgeProductFileBatchRow[] {
	const rowsByPath = new Map(rows.map((row) => [row.displayKey, row]));
	for (const row of rows) {
		let parentPath = row.parentDisplayKey;
		while (parentPath !== null) {
			if (!rowsByPath.has(parentPath)) {
				rowsByPath.set(parentPath, makeBrowserFileRow({ path: parentPath, kind: 'directory' }));
			}
			parentPath = parentPath.includes('/')
				? parentPath.slice(0, parentPath.lastIndexOf('/'))
				: null;
		}
	}
	return [...rowsByPath.values()];
}

export function makeBrowserFileBatchWithDescriptors(
	snapshotCause: BridgeProductSnapshotCause,
	...descriptors: readonly BrowserFileDescriptorOutcome[]
): BridgeProductViewInstallation {
	const source = descriptors[0]?.source ?? makeBrowserFileSourceIdentity();
	return makeBrowserFileBatch({
		snapshotCause,
		rows: descriptors.map((descriptorOutcome) =>
			makeBrowserFileRow({
				path: descriptorOutcome.path,
				fileId: descriptorOutcome.fileId,
				descriptorOutcome,
			}),
		),
		source,
	});
}

export function makeBrowserMetadataOnlyFileBatch(
	snapshotCause: BridgeProductSnapshotCause,
): BridgeProductViewInstallation {
	return makeBrowserFileBatch({
		snapshotCause,
		rows: [
			makeBrowserFileRow({ path: 'Sources', kind: 'directory' }),
			makeBrowserFileRow({ path: 'Sources/AgentStudio', kind: 'directory' }),
			makeBrowserFileRow({ path: 'Sources/AgentStudio/App', kind: 'directory' }),
			makeBrowserFileRow({
				path: 'Sources/AgentStudio/App/AppDelegate.swift',
				fileId: 'file-app-delegate',
				lineCount: 42,
			}),
			makeBrowserFileRow({ path: 'Sources/AgentStudio/Features', kind: 'directory' }),
			makeBrowserFileRow({ path: 'Sources/AgentStudio/Features/Bridge', kind: 'directory' }),
		],
	});
}

export function makeBrowserSequentialFileRows(props: {
	readonly count: number;
	readonly startIndex?: number;
}): readonly BridgeProductFileBatchRow[] {
	return Array.from({ length: props.count }, (_unused, index) => {
		const fileIndex = (props.startIndex ?? 0) + index;
		const fileName = `File-${fileIndex.toString().padStart(3, '0')}.swift`;
		return makeBrowserFileRow({
			path: fileName,
			fileId: `file-${fileIndex.toString().padStart(3, '0')}`,
			sizeBytes: 24,
		});
	});
}

export function replaceBrowserFileBatchRows(props: {
	readonly snapshotCause: BridgeProductSnapshotCause;
	readonly previous: BridgeProductViewInstallation;
	readonly upserts?: readonly BridgeProductFileBatchRow[];
	readonly deletedPaths?: readonly string[];
	readonly source?: BridgeProductFileSourceIdentity;
	readonly revision: number;
}): BridgeProductViewInstallation {
	const records = new Map(
		props.previous.records.flatMap((record) =>
			record.key === 'member-status'
				? []
				: [[record.key, bridgeProductFileBatchRowSchema.parse(record.value)] as const],
		),
	);
	for (const path of props.deletedPaths ?? []) records.delete(`/workspace/${path}`);
	for (const row of props.upserts ?? []) records.set(`/workspace/${row.displayKey}`, row);
	return makeBrowserFileBatch({
		snapshotCause: props.snapshotCause,
		rows: [...records.values()],
		...(props.source === undefined ? {} : { source: props.source }),
		revision: props.revision,
	});
}

export function browserFileRowId(path: string): string {
	return `row:${path.replaceAll('/', ':').replaceAll(' ', '_')}`;
}

function browserFileId(path: string): string {
	return `file:${browserSafeFileIdentityPath(path)}`;
}

function browserSafeFileIdentityPath(path: string): string {
	return path.replaceAll('/', ':').replace(/[^A-Za-z0-9._:-]/g, '_');
}
