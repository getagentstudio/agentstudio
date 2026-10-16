import { afterEach, describe, expect, test, vi } from 'vitest';

import { bridgeProductBatchFrameSchema } from './bridge-product-batch-wire-contracts.js';
import { bridgeProductFileMetadataApplicationProtocol } from './bridge-product-metadata-application-registry.js';
import {
	createTransportHarness,
	disposeTransportHarnesses,
	fileSourceConfiguration,
	metadataAccepted,
	subscriptionAccepted,
	subscriptionCancelled,
} from './test-fixtures/bridge-product-transport-metadata.test-support.js';

afterEach(async () => {
	try {
		await disposeTransportHarnesses();
	} finally {
		vi.unstubAllGlobals();
	}
});

describe('Bridge product transport metadata reconnection', () => {
	test('an uninstalled batch begin cannot renew physical-stream recovery', async () => {
		const harness = createTransportHarness();
		harness.transport.setBatchFrameSinks?.({
			install: (): void => {},
			receipt: (): void => {},
			resnapshot: (): void => {},
			resnapshotLatest: (): void => {},
		});
		const subscription = harness.transport.subscribe(bridgeProductFileMetadataApplicationProtocol, {
			source: fileSourceConfiguration(),
		});
		const settled = subscription.events[Symbol.asyncIterator]()
			.next()
			.then(
				(): string => 'delivered',
				(): string => 'failed',
			);
		try {
			await harness.server.waitForMetadataStream();
			const initialStream = harness.server.requiredMetadataRequest(0);
			harness.server.emitMetadata(metadataAccepted(initialStream, 0));
			harness.server.emitMetadata(
				subscriptionAccepted({
					epoch: 0,
					kind: 'file.metadata',
					request: initialStream,
					streamSequence: 1,
					subscriptionId: subscription.subscriptionId,
				}),
			);
			await harness.server.waitForControlKind('subscription.setScope');
			const scope = harness.server.requiredControlRequest('subscription.setScope', 0);
			if (scope.kind !== 'subscription.setScope') throw new Error('Expected File scope.');

			harness.server.failMetadataReader(new Error('first physical disconnect'));
			await harness.server.waitForControlKind('workerSession.resync');
			await harness.server.waitForMetadataStream(2);
			const replacementStream = harness.server.requiredMetadataRequest(1);
			if (replacementStream.resumeFromStreamSequence === null)
				throw new Error('Expected resumed metadata stream.');
			harness.server.emitMetadata(
				metadataAccepted(
					replacementStream,
					replacementStream.resumeFromStreamSequence + 1,
					'resumed',
				),
			);
			await harness.server.waitForControlKind('subscription.resnapshot');
			harness.server.emitMetadata(
				bridgeProductBatchFrameSchema.parse({
					baseRevision: 0,
					batchId: 'incomplete-recovered-file',
					domain: scope.domain,
					handle: scope.handle,
					incarnation: scope.incarnation,
					kind: 'subscription.batchBegin',
					metadataStreamId: replacementStream.metadataStreamId,
					mode: 'snapshot',
					snapshotCause: 'open',
					paneSessionId: replacementStream.paneSessionId,
					partCount: 1,
					scope: scope.scope,
					scopeRevision: scope.scopeRevision,
					streamSequence: replacementStream.resumeFromStreamSequence + 2,
					subscriptionId: subscription.subscriptionId,
					subscriptionKind: 'file.metadata',
					targetRevision: 1,
					wireVersion: replacementStream.wireVersion,
					workerInstanceId: replacementStream.workerInstanceId,
				}),
			);
			// EOF preserves the queued begin's wire order while ending the physical stream.
			harness.server.endMetadataStream();
			const outcome = await Promise.race([
				settled,
				harness.server.waitForControlKind('workerSession.resync', 2).then(
					(): string => 'recovered-again',
					(): string => 'no-second-resync',
				),
			]);
			expect(outcome).toBe('failed');
			expect(
				harness.server.controlRequests.filter((request) => request.kind === 'workerSession.resync'),
			).toHaveLength(1);
		} finally {
			harness.server.shutdown();
		}
	});

	test('resnapshots an installed File view after its physical stream reconnects', async () => {
		const harness = createTransportHarness();
		let resolveInstallation: () => void = (): void => {};
		const installed = new Promise<void>((resolve): void => {
			resolveInstallation = resolve;
		});
		let resolveReplacementInstallation: () => void = (): void => {};
		const replacementInstalled = new Promise<void>((resolve): void => {
			resolveReplacementInstallation = resolve;
		});
		let installationCount = 0;
		harness.transport.setBatchFrameSinks?.({
			install: (): void => {
				installationCount += 1;
			},
			certifiedInstallCompleted: (): void => {
				if (installationCount === 1) resolveInstallation();
				if (installationCount === 2) resolveReplacementInstallation();
			},
			receipt: (): void => {},
			resnapshot: (): void => {},
			resnapshotLatest: (): void => {},
		});
		const subscription = harness.transport.subscribe(bridgeProductFileMetadataApplicationProtocol, {
			source: fileSourceConfiguration(),
		});
		try {
			await harness.server.waitForMetadataStream();
			const firstStream = harness.server.requiredMetadataRequest(0);
			harness.server.emitMetadata(metadataAccepted(firstStream, 0));
			harness.server.emitMetadata(
				subscriptionAccepted({
					epoch: 0,
					kind: 'file.metadata',
					request: firstStream,
					streamSequence: 1,
					subscriptionId: subscription.subscriptionId,
				}),
			);
			await harness.server.waitForControlKind('subscription.open');
			await harness.server.waitForControlKind('subscription.setScope');
			const acceptedScope = harness.server.requiredControlRequest('subscription.setScope', 0);
			const scope = {
				kind: 'file',
				changeFilter: { kind: 'none' },
				interests: [],
				pathScope: [],
			} as const;
			const identity = {
				batchId: 'file-reconnect-batch-1',
				domain: 'default',
				handle: acceptedScope.handle,
				incarnation: acceptedScope.incarnation,
				metadataStreamId: firstStream.metadataStreamId,
				paneSessionId: firstStream.paneSessionId,
				scopeRevision: acceptedScope.scopeRevision,
				subscriptionId: subscription.subscriptionId,
				subscriptionKind: 'file.metadata',
				wireVersion: firstStream.wireVersion,
				workerInstanceId: firstStream.workerInstanceId,
			} as const;
			harness.server.emitMetadata(
				bridgeProductBatchFrameSchema.parse({
					...identity,
					baseRevision: 0,
					kind: 'subscription.batchBegin',
					mode: 'snapshot',
					snapshotCause: 'open',
					partCount: 0,
					scope,
					streamSequence: 2,
					targetRevision: 1,
				}),
			);
			harness.server.emitMetadata(
				bridgeProductBatchFrameSchema.parse({
					...identity,
					coveredScope: scope,
					kind: 'subscription.batchComplete',
					streamSequence: 3,
				}),
			);
			await installed;
			harness.server.failMetadataReader(new Error('physical stream lost after File view install'));
			await harness.server.waitForControlKind('workerSession.resync');
			await harness.server.waitForMetadataStream(2);
			const replacementStream = harness.server.requiredMetadataRequest(1);
			if (replacementStream.resumeFromStreamSequence === null)
				throw new Error('Expected a resumed metadata stream.');
			harness.server.emitMetadata(
				metadataAccepted(
					replacementStream,
					replacementStream.resumeFromStreamSequence + 1,
					'resumed',
				),
			);
			await harness.server.waitForControlKind('subscription.resnapshot');
			await harness.transport.resnapshotView?.(
				harness.server.requiredControlRequest('subscription.resnapshot', 0),
			);
			expect(harness.server.requiredControlRequest('subscription.resnapshot', 0)).toMatchObject({
				domain: 'default',
				handle: identity.handle,
				incarnation: identity.incarnation,
				scopeRevision: acceptedScope.scopeRevision,
				subscriptionId: subscription.subscriptionId,
			});
			const replacementIdentity = {
				...identity,
				batchId: 'file-reconnect-batch-2',
				metadataStreamId: replacementStream.metadataStreamId,
			};
			harness.server.emitMetadata(
				bridgeProductBatchFrameSchema.parse({
					...replacementIdentity,
					baseRevision: 1,
					kind: 'subscription.batchBegin',
					mode: 'snapshot',
					snapshotCause: 'open',
					partCount: 0,
					scope,
					streamSequence: replacementStream.resumeFromStreamSequence + 2,
					targetRevision: 2,
				}),
			);
			harness.server.emitMetadata(
				bridgeProductBatchFrameSchema.parse({
					...replacementIdentity,
					coveredScope: scope,
					kind: 'subscription.batchComplete',
					streamSequence: replacementStream.resumeFromStreamSequence + 3,
				}),
			);
			await replacementInstalled;
			harness.server.failMetadataReader(new Error('physical stream lost after certified install'));
			await harness.server.waitForControlKind('workerSession.resync', 2);
			expect(
				harness.server.controlRequests.filter((request) => request.kind === 'workerSession.resync'),
			).toHaveLength(2);
		} finally {
			harness.server.shutdown();
		}
	});

	test.each(['read-error', 'eof'] as const)(
		'reopens the metadata stream after physical %s and resnapshots the retained scope',
		async (failureKind) => {
			const harness = createTransportHarness();
			const subscription = harness.transport.subscribe(
				bridgeProductFileMetadataApplicationProtocol,
				{
					source: fileSourceConfiguration(),
				},
			);
			const events = subscription.events[Symbol.asyncIterator]();

			try {
				await harness.server.waitForMetadataStream();
				const initialStreamRequest = harness.server.requiredMetadataRequest(0);
				harness.server.emitMetadata(metadataAccepted(initialStreamRequest, 0));
				harness.server.emitMetadata(
					subscriptionAccepted({
						epoch: 0,
						kind: 'file.metadata',
						request: initialStreamRequest,
						streamSequence: 1,
						subscriptionId: subscription.subscriptionId,
					}),
				);
				await harness.server.waitForControlKind('subscription.open');
				await harness.server.waitForControlKind('subscription.setScope');

				if (failureKind === 'read-error') {
					harness.server.failMetadataReader(new Error('deliberate physical metadata read failure'));
				} else {
					harness.server.endMetadataStream();
				}

				await harness.server.waitForControlKind('workerSession.resync');
				const resyncRequest = harness.server.requiredControlRequest('workerSession.resync', 0);
				expect(resyncRequest.activeSubscriptions).toEqual([
					{
						subscriptionId: subscription.subscriptionId,
						subscriptionKind: 'file.metadata',
						workerDerivationEpoch: 0,
					},
				]);
				expect(resyncRequest.lastAcceptedStreamSequence).toBe(1);
				await harness.server.waitForMetadataStream(2);
				const replacementStreamRequest = harness.server.requiredMetadataRequest(1);
				expect(replacementStreamRequest).toMatchObject({
					paneSessionId: initialStreamRequest.paneSessionId,
					resumeFromStreamSequence: 1,
					workerInstanceId: initialStreamRequest.workerInstanceId,
				});
				expect(replacementStreamRequest.metadataStreamId).not.toBe(
					initialStreamRequest.metadataStreamId,
				);
				harness.server.emitMetadata(metadataAccepted(replacementStreamRequest, 2, 'resumed'));
				await harness.server.waitForControlKind('subscription.resnapshot');
				expect(harness.server.requiredControlRequest('subscription.resnapshot', 0)).toMatchObject({
					subscriptionId: subscription.subscriptionId,
					subscriptionKind: 'file.metadata',
				});
				expect(harness.transport.metadataStreamDiagnostics?.()).toMatchObject({
					activeSubscriptionCount: 1,
					failureStage: null,
					lifecycleState: 'reading',
					streamOpenCount: 2,
				});

				const cancel = subscription.cancel();
				await harness.server.waitForControlKind('subscription.cancel');
				harness.server.emitMetadata(
					subscriptionCancelled({
						epoch: 0,
						kind: 'file.metadata',
						request: replacementStreamRequest,
						streamSequence: 3,
						subscriptionId: subscription.subscriptionId,
					}),
				);
				await cancel;
				expect(await events.next()).toEqual({ done: true, value: undefined });
				expect(harness.transport.metadataStreamDiagnostics?.().activeSubscriptionCount).toBe(0);
			} finally {
				harness.server.shutdown();
			}
		},
	);
});

describe('Bridge product transport fresh metadata stream after poison', () => {
	test('a fresh metadata stream after an exhausted recovery does not need native replay of the old subscription ids', async () => {
		const harness = createTransportHarness();
		const poisoned = harness.transport.subscribe(bridgeProductFileMetadataApplicationProtocol, {
			source: fileSourceConfiguration(),
		});
		const poisonedEvents = poisoned.events[Symbol.asyncIterator]();
		// Keep the poisoned iterator's rejection handled, and use it as the barrier that
		// says the transport has finished forgetting its subscription ids.
		const poisonedSettled = poisonedEvents.next().then(
			() => 'delivered',
			() => 'failed',
		);

		try {
			await harness.server.waitForMetadataStream();
			const firstRequest = harness.server.requiredMetadataRequest(0);
			harness.server.emitMetadata(metadataAccepted(firstRequest, 0));
			harness.server.emitMetadata(
				subscriptionAccepted({
					epoch: 0,
					kind: 'file.metadata',
					request: firstRequest,
					streamSequence: 1,
					subscriptionId: poisoned.subscriptionId,
				}),
			);
			await harness.server.waitForControlKind('subscription.open');
			await harness.server.waitForControlKind('subscription.setScope');

			// Spend the single recovery attempt: kill stream #1, let the resync reopen...
			harness.server.failMetadataReader(new Error('deliberate metadata read failure'));
			await harness.server.waitForControlKind('workerSession.resync');
			await harness.server.waitForMetadataStream(2);
			expect(harness.server.requiredMetadataRequest(1).resumeFromStreamSequence).toBe(1);

			// ...then kill the replacement before it makes progress. Recovery is exhausted,
			// so the transport poisons and holds no subscription ids at all.
			harness.server.failMetadataReader(new Error('deliberate replacement read failure'));
			await expect(poisonedSettled).resolves.toBe('failed');

			// The surface still wants its data, so it subscribes again. That opens a FRESH
			// stream under a NEW id, and native must not replay the id the client forgot.
			const replacement = harness.transport.subscribe(
				bridgeProductFileMetadataApplicationProtocol,
				{ source: fileSourceConfiguration() },
			);
			const replacementEvents = replacement.events[Symbol.asyncIterator]();
			await harness.server.waitForMetadataStream(3);
			const freshRequest = harness.server.requiredMetadataRequest(2);
			expect(freshRequest.resumeFromStreamSequence).toBeNull();
			expect(replacement.subscriptionId).not.toBe(poisoned.subscriptionId);

			harness.server.emitMetadata(metadataAccepted(freshRequest, 0));
			harness.server.emitMetadata(
				subscriptionAccepted({
					epoch: 0,
					kind: 'file.metadata',
					request: freshRequest,
					streamSequence: 1,
					subscriptionId: replacement.subscriptionId,
				}),
			);
			await harness.server.waitForControlKind('subscription.open', 2);
			await harness.server.waitForControlKind('subscription.setScope', 2);
			expect(harness.transport.metadataStreamDiagnostics?.()).toMatchObject({
				activeSubscriptionCount: 1,
				failureStage: null,
				lifecycleState: 'reading',
			});
			await replacement.cancel();
			expect(await replacementEvents.next()).toEqual({ done: true, value: undefined });
		} finally {
			harness.server.shutdown();
		}
	});

	test('a frame naming a subscription the client no longer holds fails the fresh stream closed', async () => {
		const harness = createTransportHarness();
		const subscription = harness.transport.subscribe(bridgeProductFileMetadataApplicationProtocol, {
			source: fileSourceConfiguration(),
		});
		const events = subscription.events[Symbol.asyncIterator]();
		const settled = events.next().then(
			() => 'delivered',
			() => 'failed',
		);

		try {
			await harness.server.waitForMetadataStream();
			const request = harness.server.requiredMetadataRequest(0);
			harness.server.emitMetadata(metadataAccepted(request, 0));
			harness.server.emitMetadata(
				subscriptionAccepted({
					epoch: 0,
					kind: 'file.metadata',
					request,
					streamSequence: 1,
					subscriptionId: subscription.subscriptionId,
				}),
			);
			await harness.server.waitForControlKind('subscription.open');
			await harness.server.waitForControlKind('subscription.setScope');

			// This is what the pre-fix native side did on a fresh stream: announce a
			// subscription under an id from before the client poisoned its session.
			harness.server.emitMetadata(
				subscriptionAccepted({
					epoch: 0,
					kind: 'file.metadata',
					request,
					streamSequence: 2,
					subscriptionId: 'subscription-the-client-never-opened',
				}),
			);

			// The client fails CLOSED: the whole stream dies, taking the live
			// subscription with it. That is the contract the native fix relies on.
			await expect(settled).resolves.toBe('failed');
			expect(harness.transport.metadataStreamDiagnostics?.()).toMatchObject({
				routeFailureCode: 'unknown_subscription',
				routeFailureSubscriptionId: 'subscription-the-client-never-opened',
			});
		} finally {
			harness.server.shutdown();
		}
	});
});
