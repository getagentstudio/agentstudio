import { describe, expect, it } from 'vitest';

import { BridgeProductBatchFrameRouter } from '../src/core/comm-worker/bridge-product-batch-frame-router.js';
import {
	bridgeProductBatchFrameSchema,
	type BridgeProductBatchFrame,
} from '../src/core/comm-worker/bridge-product-batch-wire-contracts.js';
import {
	installBridgeProductFileBatch,
	type BridgeProductInstalledFileView,
} from '../src/core/comm-worker/bridge-product-file-batch-installer.js';
import { bridgeProductFileMemberStatusRecordSchema } from '../src/core/comm-worker/bridge-product-file-member-status-contracts.js';
import {
	BridgeProductViewBatchReceiver,
	type BridgeProductBatchAcceptance,
} from '../src/core/comm-worker/bridge-product-view-batch-receiver.js';
import { ControlledBatchDeadlineClock } from '../src/core/comm-worker/bridge-product-view-batch-receiver.test-support.js';

const fileScope = {
	kind: 'file',
	changeFilter: { kind: 'none' },
	interests: [],
	pathScope: [],
} as const;
const fileIdentity = {
	domain: 'default',
	handle: 'file-handle',
	incarnation: 'file-incarnation',
	metadataStreamId: 'metadata-stream',
	paneSessionId: 'pane-session',
	scopeRevision: 1,
	subscriptionId: 'tq53-file',
	subscriptionKind: 'file.metadata',
	wireVersion: 2,
	workerInstanceId: 'worker-instance',
} as const;

interface FrameObservation {
	readonly batchId: string;
	readonly frameKind: BridgeProductBatchFrame['kind'];
	readonly sequence: number;
	readonly disposition: BridgeProductBatchAcceptance;
}

function fileBatch(props: {
	readonly batchId: string;
	readonly target: number;
	readonly mode: 'snapshot' | 'coverage';
	readonly firstStreamSequence: number;
	readonly deliverySequence: number;
	readonly snapshotCause?: 'open' | 'requested';
}): readonly BridgeProductBatchFrame[] {
	const memberStatus = bridgeProductFileMemberStatusRecordSchema.parse({
		kind: 'memberStatus',
		status: props.mode === 'snapshot' ? 'ready' : 'loading',
		ahead: 0,
		behind: 0,
		branchName: 'main',
		staged: 0,
		unstaged: 0,
		untracked: 0,
		source: {
			repoId: '00000000-0000-7000-8000-000000000061',
			worktreeId: '00000000-0000-7000-8000-000000000062',
			rootRevisionToken: null,
			sourceCursor: 'cursor-1',
			sourceId: 'source-1',
			subscriptionGeneration: 1,
		},
	});
	const identity = { ...fileIdentity, batchId: props.batchId };
	return [
		bridgeProductBatchFrameSchema.parse({
			...identity,
			kind: 'subscription.batchBegin',
			streamSequence: props.firstStreamSequence,
			mode: props.mode,
			...(props.snapshotCause === undefined ? {} : { snapshotCause: props.snapshotCause }),
			baseRevision: 0,
			targetRevision: props.target,
			partCount: 1,
			scope: fileScope,
		}),
		bridgeProductBatchFrameSchema.parse({
			...identity,
			kind: 'subscription.batchPart',
			streamSequence: props.firstStreamSequence + 1,
			deliverySequence: props.deliverySequence,
			partIndex: 0,
			part: { operation: 'put', key: 'member-status', revision: props.target, value: memberStatus },
		}),
		bridgeProductBatchFrameSchema.parse({
			...identity,
			kind: 'subscription.batchComplete',
			streamSequence: props.firstStreamSequence + 2,
			coveredScope: fileScope,
		}),
	];
}

function createDiagnosticHarness(): {
	readonly send: (frames: readonly BridgeProductBatchFrame[]) => void;
	readonly observations: FrameObservation[];
	readonly sinkCalls: string[];
	readonly installed: () => BridgeProductInstalledFileView | null;
	readonly finish: () => void;
} {
	const clock = new ControlledBatchDeadlineClock();
	const receiver = new BridgeProductViewBatchReceiver({
		handle: fileIdentity.handle,
		scope: fileScope,
		scopeRevision: 1,
		subscriptionId: fileIdentity.subscriptionId,
		subscriptionKind: fileIdentity.subscriptionKind,
	});
	receiver.admitDomain(fileIdentity.domain, fileIdentity.incarnation);
	const router = new BridgeProductBatchFrameRouter({
		deadlineClock: clock,
		progressDeadlineMilliseconds: 5_000,
	});
	const observations: FrameObservation[] = [];
	const sinkCalls: string[] = [];
	let installed: BridgeProductInstalledFileView | null = null;
	router.setSinks({
		verify: (installation): void => {
			sinkCalls.push(`verify:${installation.begin.batchId}`);
			installBridgeProductFileBatch(installation, installed);
		},
		install: (installation): void => {
			sinkCalls.push(`install:${installation.begin.batchId}:${installation.begin.targetRevision}`);
			installed = installBridgeProductFileBatch(installation, installed);
		},
		receipt: (frame, through): void => {
			sinkCalls.push(`receipt:${frame.batchId}:${through}`);
		},
		diagnostic: (sample): void => {
			sinkCalls.push(`diagnostic:${sample.frameKind}:${sample.rejection}`);
		},
		resnapshot: (frame): void => {
			sinkCalls.push(`resnapshot:${frame.batchId}:${frame.streamSequence}`);
		},
		resnapshotLatest: (subscriptionId, domain): void => {
			sinkCalls.push(`resnapshotLatest:${subscriptionId}:${domain}`);
		},
	});
	return {
		observations,
		sinkCalls,
		installed: (): BridgeProductInstalledFileView | null => installed,
		send: (frames): void => {
			for (const frame of frames) {
				const disposition = receiver.accept(frame);
				observations.push({
					batchId: frame.batchId,
					frameKind: frame.kind,
					sequence: frame.streamSequence,
					disposition,
				});
				router.accept(frame);
			}
		},
		finish: (): void => {
			router.clear();
			expect(clock.deadlines.every((deadline) => !deadline.active)).toBe(true);
		},
	};
}

describe('TQ53 current late File coverage behavior', () => {
	it('ignores stale BEGIN but resnapshots fresh-sequence PART and COMPLETE without receipts', () => {
		const harness = createDiagnosticHarness();
		try {
			harness.send(
				fileBatch({
					batchId: 'certificate',
					target: 2,
					mode: 'snapshot',
					snapshotCause: 'open',
					firstStreamSequence: 1,
					deliverySequence: 1,
				}),
			);
			harness.send(
				fileBatch({
					batchId: 'late-coverage',
					target: 1,
					mode: 'coverage',
					firstStreamSequence: 100,
					deliverySequence: 2,
				}),
			);
			expect(harness.observations.map((sample) => sample.disposition)).toEqual([
				{ kind: 'staged', snapshotCause: 'open' },
				{ kind: 'staged', receivedThroughDeliverySequence: 1 },
				{ kind: 'installed', domain: 'default', targetRevision: 2 },
				{ kind: 'ignored' },
				{ kind: 'resnapshot', domain: 'default', rejection: 'missingStage' },
				{ kind: 'resnapshot', domain: 'default', rejection: 'missingStage' },
			]);
			expect(harness.sinkCalls).toEqual([
				'receipt:certificate:1',
				'verify:certificate',
				'install:certificate:2',
				'diagnostic:subscription.batchPart:missingStage',
				'resnapshot:late-coverage:101',
				'diagnostic:subscription.batchComplete:missingStage',
				'resnapshot:late-coverage:102',
			]);
			expect(harness.installed()?.memberStatus.status).toBe('ready');
			console.log(
				'TQ53-R2 receiver/router trace',
				JSON.stringify({ frames: harness.observations, sinks: harness.sinkCalls }),
			);
		} finally {
			harness.finish();
		}
	});

	it.each([2, 3])(
		'installs requested target %i and resumes cumulative receipts after the rejected coverage',
		(recoveryTarget: number) => {
			const harness = createDiagnosticHarness();
			try {
				harness.send(
					fileBatch({
						batchId: 'certificate',
						target: 2,
						mode: 'snapshot',
						snapshotCause: 'open',
						firstStreamSequence: 1,
						deliverySequence: 1,
					}),
				);
				harness.send(
					fileBatch({
						batchId: 'late-coverage',
						target: 1,
						mode: 'coverage',
						firstStreamSequence: 100,
						deliverySequence: 2,
					}),
				);
				// This supplies a valid recovery response at the receiver boundary;
				// native request handling is proved separately by the real HTTP test.
				harness.send(
					fileBatch({
						batchId: 'recovery',
						target: recoveryTarget,
						mode: 'snapshot',
						snapshotCause: 'requested',
						firstStreamSequence: 103,
						deliverySequence: 3,
					}),
				);
				expect(harness.observations.slice(-3).map((sample) => sample.disposition)).toEqual([
					{ kind: 'staged', snapshotCause: 'requested' },
					{ kind: 'staged', receivedThroughDeliverySequence: 3 },
					{ kind: 'installed', domain: 'default', targetRevision: recoveryTarget },
				]);
				expect(harness.sinkCalls.slice(-3)).toEqual([
					'receipt:recovery:3',
					'verify:recovery',
					`install:recovery:${recoveryTarget}`,
				]);
				expect(harness.installed()?.memberStatusRevision).toBe(recoveryTarget);
				console.log(
					'TQ53-R2 supplied recovery trace',
					JSON.stringify({ frames: harness.observations, sinks: harness.sinkCalls }),
				);
			} finally {
				harness.finish();
			}
		},
	);
});
