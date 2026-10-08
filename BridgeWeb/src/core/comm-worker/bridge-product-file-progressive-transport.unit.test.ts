import { afterEach, describe, expect, test } from 'vitest';

import { createBridgeProductDeferred } from './bridge-product-async-queue.js';
import { bridgeProductBatchFrameSchema } from './bridge-product-batch-wire-contracts.js';
import type { BridgeProductDeadlineClock } from './bridge-product-deadline-clock.js';
import { bridgeProductFileMetadataApplicationProtocol } from './bridge-product-metadata-application-registry.js';
import {
	createTransportHarness,
	disposeTransportHarnesses,
	fileSourceConfiguration,
	metadataAccepted,
	subscriptionAccepted,
} from './test-fixtures/bridge-product-transport-metadata.test-support.js';

afterEach(async (): Promise<void> => {
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
			harness.transport.failFileRender?.();
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
