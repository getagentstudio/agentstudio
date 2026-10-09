import { afterEach, describe, expect, test, vi } from 'vitest';

import fileCorpus from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-file-batch-row-corpus.json' with { type: 'json' };
import { createBridgeProductDeferred } from './bridge-product-async-queue.js';
import { bridgeProductBatchFrameSchema } from './bridge-product-batch-wire-contracts.js';
import type { BridgeProductDeadlineClock } from './bridge-product-deadline-clock.js';
import {
	installBridgeProductFileBatch,
	type BridgeProductInstalledFileView,
} from './bridge-product-file-batch-installer.js';
import { bridgeProductFileBatchRowSchema } from './bridge-product-file-batch-row-contracts.js';
import { bridgeProductFileMetadataApplicationProtocol } from './bridge-product-metadata-application-registry.js';
import { BridgeProductViewScopeOwner } from './bridge-product-view-scope-owner.js';
import {
	createTransportHarness,
	disposeTransportHarnesses,
	fileSourceConfiguration,
	metadataAccepted,
	subscriptionAccepted,
} from './test-fixtures/bridge-product-transport-metadata.test-support.js';

afterEach(async (): Promise<void> => {
	vi.restoreAllMocks();
	await disposeTransportHarnesses();
});

class ControlledMetadataDeadlineClock implements BridgeProductDeadlineClock {
	readonly deadlines: Array<{ active: boolean; delayMilliseconds: number; fire: () => void }> = [];
	readonly #scheduleWaiters: Array<{ count: number; resolve: () => void }> = [];

	schedule(delayMilliseconds: number, onDeadline: () => void): () => void {
		const deadline = {
			active: true,
			delayMilliseconds,
			fire: (): void => {
				if (!deadline.active) throw new Error('Expected an active metadata progress deadline.');
				deadline.active = false;
				onDeadline();
			},
		};
		this.deadlines.push(deadline);
		for (const waiter of this.#scheduleWaiters.filter(
			(candidate) => candidate.count <= this.deadlines.length,
		)) {
			waiter.resolve();
		}
		this.#scheduleWaiters.splice(
			0,
			this.#scheduleWaiters.length,
			...this.#scheduleWaiters.filter((candidate) => candidate.count > this.deadlines.length),
		);
		return (): void => {
			deadline.active = false;
		};
	}

	waitForScheduleCount(count: number): Promise<void> {
		if (this.deadlines.length >= count) return Promise.resolve();
		return new Promise((resolve): void => {
			this.#scheduleWaiters.push({ count, resolve });
		});
	}

	activeDeadline(): (typeof this.deadlines)[number] {
		const deadline = this.deadlines.find((candidate) => candidate.active);
		if (deadline === undefined) throw new Error('Expected an armed metadata progress deadline.');
		return deadline;
	}
}

describe('File progressive coverage transport obligations', () => {
	test('an installed initial coverage leaves a missing final snapshot under the existing view deadline', async () => {
		const clock = new ControlledMetadataDeadlineClock();
		const installed = createBridgeProductDeferred<void>();
		let certifiedCount = 0;
		const harness = createTransportHarness({ deadlineClock: clock });
		harness.transport.setBatchFrameSinks?.({
			install: (): void => installed.resolve(),
			receipt: (): void => {},
			resnapshot: (): void => {},
			resnapshotLatest: (): void => {},
			certifiedInstallCompleted: (): void => {
				certifiedCount += 1;
			},
		});
		const subscription = harness.transport.subscribe(bridgeProductFileMetadataApplicationProtocol, {
			source: fileSourceConfiguration(),
		});
		try {
			const stream = await harness.server.waitForMetadataStreamOpened();
			harness.server.emitMetadata(metadataAccepted(stream, 0));
			harness.server.emitMetadata(
				subscriptionAccepted({
					epoch: 0,
					kind: 'file.metadata',
					request: stream,
					streamSequence: 1,
					subscriptionId: subscription.subscriptionId,
				}),
			);
			const firstScope = await harness.server.waitForControlRequest('subscription.setScope');
			if (firstScope.kind !== 'subscription.setScope') throw new Error('Expected File scope.');
			const settlement = await harness.transport.setViewScopeForSubscription?.({
				scope: firstScope.scope,
				subscriptionId: subscription.subscriptionId,
			});
			expect(settlement?.kind).toBe('accepted');
			const current = harness.server.requiredControlRequest('subscription.setScope', 1);
			const shared = {
				domain: current.domain,
				handle: current.handle,
				incarnation: current.incarnation,
				metadataStreamId: stream.metadataStreamId,
				paneSessionId: stream.paneSessionId,
				scopeRevision: current.scopeRevision,
				subscriptionId: subscription.subscriptionId,
				subscriptionKind: 'file.metadata',
				wireVersion: stream.wireVersion,
				workerInstanceId: stream.workerInstanceId,
				batchId: 'coverage-with-no-final',
			} as const;
			harness.server.emitMetadata(
				bridgeProductBatchFrameSchema.parse({
					...shared,
					kind: 'subscription.batchBegin',
					streamSequence: 2,
					baseRevision: 0,
					targetRevision: 1,
					mode: 'coverage',
					partCount: 0,
					scope: current.scope,
				}),
			);
			harness.server.emitMetadata(
				bridgeProductBatchFrameSchema.parse({
					...shared,
					kind: 'subscription.batchComplete',
					streamSequence: 3,
					coveredScope: current.scope,
				}),
			);
			await installed.promise;
			expect(certifiedCount).toBe(0);
			clock.activeDeadline().fire();
			const resnapshot = await harness.server.waitForControlRequest('subscription.resnapshot');
			expect(resnapshot).toMatchObject({
				subscriptionId: subscription.subscriptionId,
				handle: current.handle,
			});
			expect(certifiedCount).toBe(0);
		} finally {
			await subscription.cancel();
		}
	});

	test('partial coverage installs never certify readiness or renew the File recovery budget', async () => {
		const timeline: string[] = [];
		const certifiedModes: string[] = [];
		const firstCertified = createBridgeProductDeferred<void>();
		const finalCertified = createBridgeProductDeferred<void>();
		const harness = createTransportHarness({
			deadlineClock: { schedule: () => (): void => {} },
			onViewRecoveryStatus: (status): void => {
				timeline.push(`status:${status.status}`);
			},
		});
		harness.transport.setBatchFrameSinks?.({
			install: (installation): void => {
				timeline.push(`installed:${installation.begin.mode}`);
			},
			receipt: (): void => {},
			resnapshot: (): void => {},
			resnapshotLatest: (): void => {},
			certifiedInstallCompleted: (frame): void => {
				certifiedModes.push(frame.mode);
				if (frame.mode === 'snapshot') {
					if (certifiedModes.filter((mode) => mode === 'snapshot').length === 1)
						firstCertified.resolve();
					else finalCertified.resolve();
				}
			},
		});
		const subscription = harness.transport.subscribe(bridgeProductFileMetadataApplicationProtocol, {
			source: fileSourceConfiguration(),
		});
		try {
			const stream = await harness.server.waitForMetadataStreamOpened();
			harness.server.emitMetadata(metadataAccepted(stream, 0));
			harness.server.emitMetadata(
				subscriptionAccepted({
					epoch: 0,
					kind: 'file.metadata',
					request: stream,
					streamSequence: 1,
					subscriptionId: subscription.subscriptionId,
				}),
			);
			const acceptedScope = await harness.server.waitForControlRequest('subscription.setScope');
			if (acceptedScope.kind !== 'subscription.setScope')
				throw new Error('Expected File scope admission.');
			let sequence = 1;
			const emitEmptyBatch = (
				mode: 'snapshot' | 'coverage',
				snapshotCause:
					| import('./bridge-product-batch-wire-contracts.js').BridgeProductSnapshotCause
					| undefined,
				base: number,
				target: number,
			): void => {
				const shared = {
					domain: acceptedScope.domain,
					handle: acceptedScope.handle,
					incarnation: acceptedScope.incarnation,
					metadataStreamId: stream.metadataStreamId,
					paneSessionId: stream.paneSessionId,
					scopeRevision: acceptedScope.scopeRevision,
					subscriptionId: subscription.subscriptionId,
					subscriptionKind: 'file.metadata',
					wireVersion: stream.wireVersion,
					workerInstanceId: stream.workerInstanceId,
					batchId: `progressive-${target}`,
				} as const;
				harness.server.emitMetadata(
					bridgeProductBatchFrameSchema.parse({
						...shared,
						kind: 'subscription.batchBegin',
						streamSequence: ++sequence,
						baseRevision: base,
						targetRevision: target,
						mode,
						...(snapshotCause === undefined ? {} : { snapshotCause }),
						partCount: 0,
						scope: acceptedScope.scope,
					}),
				);
				harness.server.emitMetadata(
					bridgeProductBatchFrameSchema.parse({
						...shared,
						kind: 'subscription.batchComplete',
						streamSequence: ++sequence,
						coveredScope: acceptedScope.scope,
					}),
				);
			};
			emitEmptyBatch('snapshot', 'open', 0, 1);
			await firstCertified.promise;
			harness.transport.failFileRender?.(subscription.subscriptionId);
			expect(timeline.at(-1)).toBe('status:failedRetryable');
			emitEmptyBatch('coverage', undefined, 1, 2);
			emitEmptyBatch('snapshot', 'newerInput', 0, 3);
			await finalCertified.promise;

			expect(certifiedModes).toEqual(['snapshot', 'snapshot']);
			const partialIndex = timeline.indexOf('installed:coverage');
			const finalIndex = timeline.lastIndexOf('installed:snapshot');
			expect(partialIndex).toBeGreaterThan(-1);
			expect(timeline.slice(partialIndex, finalIndex)).not.toContain('status:ready');
			expect(timeline.at(-1)).toBe('status:ready');
		} finally {
			await subscription.cancel();
		}
	});
});

class ControlledDemandDeadlineClock implements BridgeProductDeadlineClock {
	nowMilliseconds = 0;
	readonly deadlines: Array<{ active: boolean; dueMilliseconds: number; fire: () => void }> = [];

	schedule(delayMilliseconds: number, onDeadline: () => void): () => void {
		const deadline = {
			active: true,
			dueMilliseconds: this.nowMilliseconds + delayMilliseconds,
			fire: (): void => {
				deadline.active = false;
				onDeadline();
			},
		};
		this.deadlines.push(deadline);
		return (): void => {
			deadline.active = false;
		};
	}

	advanceDeadlineTo(
		deadline: (typeof this.deadlines)[number] | undefined,
		nowMilliseconds: number,
	): void {
		if (nowMilliseconds < this.nowMilliseconds) throw new Error('Clock cannot move backwards.');
		this.nowMilliseconds = nowMilliseconds;
		// Drive the selected W2 begin deadline; unrelated ACK/control deadlines are not subjects.
		if (deadline?.active && deadline.dueMilliseconds <= nowMilliseconds) deadline.fire();
	}
}

test.each(['descriptor-change', 'no-batch'] as const)(
	'GO22: healthy same-filter File demand with %s stays ready and spends no recovery attempt',
	async (nativeResponse): Promise<void> => {
		const clock = new ControlledDemandDeadlineClock();
		const observations: Array<{
			readonly phase: string;
			readonly milliseconds: number;
			readonly status: string | undefined;
			readonly consecutiveResnapshots: number | undefined;
			readonly resnapshotRequests: number;
		}> = [];
		const statuses: Array<{ milliseconds: number; status: string }> = [];
		const ownerObserved = createBridgeProductDeferred<BridgeProductViewScopeOwner>();
		// oxlint-disable-next-line unbound-method -- Saved method is explicitly rebound to the original W2 instance below.
		const originalCertifiedInstall = BridgeProductViewScopeOwner.prototype.recordCertifiedInstall;
		// Passive observation only: execute the original production method on the real W2 owner.
		vi.spyOn(BridgeProductViewScopeOwner.prototype, 'recordCertifiedInstall').mockImplementation(
			function (
				this: BridgeProductViewScopeOwner,
				identity: Parameters<typeof originalCertifiedInstall>[0],
			): void {
				originalCertifiedInstall.call(this, identity);
				ownerObserved.resolve(this);
			},
		);
		const harness = createTransportHarness({
			deadlineClock: clock,
			onViewRecoveryStatus: ({ status }): void => {
				statuses.push({ milliseconds: clock.nowMilliseconds, status });
			},
		});
		const initialCertified = createBridgeProductDeferred<void>();
		const enrichedInstalled = createBridgeProductDeferred<void>();
		const forcedCertified = createBridgeProductDeferred<void>();
		let installedView: BridgeProductInstalledFileView | null = null;
		harness.transport.setBatchFrameSinks?.({
			install: (installation): void => {
				installedView = installBridgeProductFileBatch(installation, installedView);
				expect(installedView.memberStatus.status).toBe('ready');
				if (installation.begin.mode === 'change') {
					expect(installedView.contentItems[0]?.descriptorId).toBe('go22-enriched-descriptor');
					expect(installedView.displayPatches.map((patch) => patch.slice)).toEqual(['fileItem']);
					enrichedInstalled.resolve();
				}
			},
			receipt: (): void => {},
			resnapshot: (): void => {
				throw new Error('Healthy W4 must not request recovery.');
			},
			resnapshotLatest: (): void => {
				throw new Error('Healthy W4 must not expire progress.');
			},
			certifiedInstallCompleted: (begin): void => {
				if (begin.batchId === 'go22-initial') initialCertified.resolve();
				if (begin.batchId === 'go22-forced') forcedCertified.resolve();
			},
		});
		const subscription = harness.transport.subscribe(bridgeProductFileMetadataApplicationProtocol, {
			source: fileSourceConfiguration(),
		});
		try {
			const stream = await harness.server.waitForMetadataStreamOpened();
			harness.server.emitMetadata(metadataAccepted(stream, 0));
			harness.server.emitMetadata(
				subscriptionAccepted({
					epoch: 0,
					kind: 'file.metadata',
					request: stream,
					streamSequence: 1,
					subscriptionId: subscription.subscriptionId,
				}),
			);
			const initialScope = await harness.server.waitForControlRequest('subscription.setScope');
			if (initialScope.kind !== 'subscription.setScope' || initialScope.scope.kind !== 'file')
				throw new Error('Expected initial File scope.');
			let sequence = 1;
			let deliverySequence = 0;
			const enrichedRow = bridgeProductFileBatchRowSchema.parse(fileCorpus.rows[0]?.row);
			const outcome = enrichedRow.descriptorOutcome;
			if (outcome?.availability.availabilityKind !== 'available')
				throw new Error('Expected available descriptor fixture.');
			const enrichedDescriptor = {
				...outcome.availability.contentDescriptor,
				descriptorId: 'go22-enriched-descriptor',
			};
			const enrichedValue = bridgeProductFileBatchRowSchema.parse({
				...enrichedRow,
				readDescriptor: enrichedDescriptor,
				descriptorOutcome: {
					...outcome,
					availability: { availabilityKind: 'available', contentDescriptor: enrichedDescriptor },
				},
			});
			const initialRecords: readonly { readonly key: string; readonly value: unknown }[] = [
				...fileCorpus.rows.map(({ recordKey, row }, index) => ({
					key: recordKey,
					value:
						index === 0
							? bridgeProductFileBatchRowSchema.parse({
									...row,
									descriptorOutcome: null,
									readDescriptor: null,
								})
							: row,
				})),
				{ key: 'member-status', value: fileCorpus.memberStatuses[0]?.record },
			];
			const emitBatch = (props: {
				readonly batchId: string;
				readonly mode: 'snapshot' | 'change';
				readonly scopeRequest: typeof initialScope;
				readonly targetRevision: number;
				readonly records: readonly { readonly key: string; readonly value: unknown }[];
			}): void => {
				const shared = {
					domain: props.scopeRequest.domain,
					handle: props.scopeRequest.handle,
					incarnation: props.scopeRequest.incarnation,
					metadataStreamId: stream.metadataStreamId,
					paneSessionId: stream.paneSessionId,
					scopeRevision: props.scopeRequest.scopeRevision,
					subscriptionId: subscription.subscriptionId,
					subscriptionKind: 'file.metadata',
					wireVersion: stream.wireVersion,
					workerInstanceId: stream.workerInstanceId,
					batchId: props.batchId,
				} as const;
				harness.server.emitMetadata(
					bridgeProductBatchFrameSchema.parse({
						...shared,
						kind: 'subscription.batchBegin',
						streamSequence: ++sequence,
						baseRevision: props.mode === 'snapshot' ? 0 : 1,
						targetRevision: props.targetRevision,
						mode: props.mode,
						...(props.mode === 'snapshot'
							? { snapshotCause: props.batchId === 'go22-initial' ? 'open' : 'requested' }
							: {}),
						partCount: props.records.length,
						scope: props.scopeRequest.scope,
					}),
				);
				props.records.forEach((record, partIndex): void => {
					harness.server.emitMetadata(
						bridgeProductBatchFrameSchema.parse({
							...shared,
							kind: 'subscription.batchPart',
							streamSequence: ++sequence,
							deliverySequence: ++deliverySequence,
							partIndex,
							part: { ...record, revision: props.targetRevision, operation: 'put' },
						}),
					);
				});
				harness.server.emitMetadata(
					bridgeProductBatchFrameSchema.parse({
						...shared,
						kind: 'subscription.batchComplete',
						streamSequence: ++sequence,
						coveredScope: props.scopeRequest.scope,
					}),
				);
			};
			emitBatch({
				batchId: 'go22-initial',
				mode: 'snapshot',
				scopeRequest: initialScope,
				targetRevision: 1,
				records: initialRecords,
			});
			await initialCertified.promise;
			const owner = await ownerObserved.promise;
			const resnapshotRequests = (): number =>
				harness.server.controlRequests.filter(
					(request) => request.kind === 'subscription.resnapshot',
				).length;
			const observe = (phase: string): void => {
				const state = owner.recoveryState(subscription.subscriptionId);
				observations.push({
					phase,
					milliseconds: clock.nowMilliseconds,
					status: state?.status,
					consecutiveResnapshots: state?.consecutiveResnapshots,
					resnapshotRequests: resnapshotRequests(),
				});
			};
			expect(owner.recoveryState(subscription.subscriptionId)).toEqual({
				status: 'ready',
				consecutiveResnapshots: 0,
			});
			observe('installed-ready');
			const demandScope = {
				...initialScope.scope,
				interests: [{ lane: 'foreground' as const, paths: [enrichedRow.displayKey] }],
			};
			const deadlinesBeforeDemand = clock.deadlines.length;
			const demandSettlement = await harness.transport.setViewScopeForSubscription?.({
				scope: demandScope,
				subscriptionId: subscription.subscriptionId,
			});
			expect(demandSettlement?.kind).toBe('accepted');
			const demandRequest = harness.server.requiredControlRequest('subscription.setScope', 1);
			expect(demandRequest.scope).toMatchObject({
				changeFilter: initialScope.scope.changeFilter,
				pathScope: initialScope.scope.pathScope,
			});
			// Admission is closed; only newly armed begin obligations are this clock subject.
			const beginDeadlines = clock.deadlines
				.slice(deadlinesBeforeDemand)
				.filter((deadline) => deadline.active && deadline.dueMilliseconds === 5000);
			// This transport clock also owns independent result-ACK deadlines. The isolated
			// W2 oracle checks absence of begin timers; here expiry must issue no view recovery.
			expect.soft(statuses.at(-1)?.status).toBe('ready');
			const beginDeadline = beginDeadlines.at(-1);
			const resnapshotOperations: Promise<void>[] = [];
			const requestResnapshot = owner.requestResnapshot.bind(owner);
			vi.spyOn(owner, 'requestResnapshot').mockImplementation((request): Promise<void> => {
				const operation = requestResnapshot(request);
				resnapshotOperations.push(operation);
				return operation;
			});
			observe('demand-admitted');
			if (nativeResponse === 'descriptor-change') {
				emitBatch({
					batchId: 'go22-enrichment',
					mode: 'change',
					scopeRequest: demandRequest,
					targetRevision: 2,
					records: [{ key: fileCorpus.rows[0]?.recordKey ?? '', value: enrichedValue }],
				});
				await enrichedInstalled.promise;
			}
			observe('native-answer-complete');
			expect.soft(owner.recoveryState(subscription.subscriptionId)?.status).toBe('ready');
			clock.advanceDeadlineTo(beginDeadline, 4999);
			observe('before-5s-deadline');
			expect(resnapshotRequests()).toBe(0);
			expect
				.soft(owner.recoveryState(subscription.subscriptionId))
				.toEqual({ status: 'ready', consecutiveResnapshots: 0 });
			clock.advanceDeadlineTo(beginDeadline, 5000);
			// Join only operations synchronously issued by this deadline, through their real E4 ender.
			await Promise.all(resnapshotOperations);
			observe('5s-deadline-closed');
			expect.soft(resnapshotRequests()).toBe(0);
			expect.soft(owner.recoveryState(subscription.subscriptionId)?.consecutiveResnapshots).toBe(0);
			const forcedRequest = harness.server.controlRequests.find(
				(request) => request.kind === 'subscription.resnapshot',
			);
			if (forcedRequest?.kind === 'subscription.resnapshot') {
				emitBatch({
					batchId: 'go22-forced',
					mode: 'snapshot',
					scopeRequest: { ...demandRequest, ...forcedRequest, kind: 'subscription.setScope' },
					targetRevision: 3,
					records: initialRecords.map((record) =>
						record.key === fileCorpus.rows[0]?.recordKey && nativeResponse === 'descriptor-change'
							? { key: record.key, value: enrichedValue }
							: record,
					),
				});
				await forcedCertified.promise;
			}
			observe(
				forcedRequest === undefined ? 'healthy-demand-complete' : 'forced-snapshot-installed',
			);
			expect(owner.recoveryState(subscription.subscriptionId)).toEqual({
				status: 'ready',
				consecutiveResnapshots: 0,
			});
			console.info(
				'[GO22 observations]',
				JSON.stringify({ nativeResponse, observations, statuses }),
			);
		} finally {
			await subscription.cancel();
		}
	},
);
