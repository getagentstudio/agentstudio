import { afterEach, describe, expect, test, vi } from 'vitest';

import { createBridgeProductDeferred } from './bridge-product-async-queue.js';
import {
	bridgeProductFileMetadataApplicationProtocol,
	bridgeProductReviewMetadataApplicationProtocol,
} from './bridge-product-metadata-application-registry.js';
import {
	bridgeProductMetadataFrameSchema,
	type BridgeProductMetadataStreamRequest,
} from './bridge-product-session-contracts.js';
import {
	createTransportHarness,
	disposeTransportHarnesses,
	fileSourceConfiguration,
	metadataAccepted,
	subscriptionAccepted,
} from './test-fixtures/bridge-product-transport-metadata.test-support.js';
import {
	establishFileSubscription,
	observeSettlement,
	resyncResponse,
	retainedResponse,
} from './test-fixtures/bridge-product-transport-recovery.test-support.js';

afterEach(async () => {
	try {
		await disposeTransportHarnesses();
	} finally {
		vi.unstubAllGlobals();
		vi.useRealTimers();
	}
});

describe('Bridge product transport recovery edges', () => {
	test('does not invent a received stream sequence when the first stream fails before acceptance', async () => {
		// Arrange
		const harness = createTransportHarness();
		const subscription = harness.transport.subscribe(
			bridgeProductReviewMetadataApplicationProtocol,
			{},
		);
		const terminal = subscription.events[Symbol.asyncIterator]().next();
		observeSettlement(terminal, (): void => {});
		await harness.server.waitForMetadataStream();

		// Act: no complete metadata frame has ever been delivered.
		harness.server.failMetadataReader(new Error('initial stream acceptance unavailable'));
		await expect(terminal).rejects.toThrow(/initial stream acceptance unavailable/iu);
		await harness.whenSubscriptionsEnded();

		// Assert: fail explicitly instead of claiming unobserved stream sequence zero.
		expect(
			harness.server.controlRequests.filter((request) => request.kind === 'workerSession.resync'),
		).toHaveLength(0);
		expect(harness.server.metadataFetchCount).toBe(1);
	});

	test('bounds repeated connection openings even when no subscription frame was ever received', async () => {
		// Arrange: native accepted each open but its subscription acceptance was
		// lost. Reconciliation therefore requires a fresh subscription identity.
		const harness = createTransportHarness();
		harness.server.resyncHandler = (request): Response =>
			resyncResponse(
				request,
				request.activeSubscriptions.map((subscription) => ({
					disposition: 'reopenRequired',
					reason: 'snapshot_required',
					requiredWorkerDerivationEpoch: subscription.workerDerivationEpoch,
					subscriptionId: subscription.subscriptionId,
					subscriptionKind: subscription.subscriptionKind,
				})),
				request.lastAcceptedStreamSequence + 1,
			);
		const first = harness.transport.subscribe(bridgeProductReviewMetadataApplicationProtocol, {});
		const firstTerminal = first.events[Symbol.asyncIterator]().next();
		observeSettlement(firstTerminal, (): void => {});
		await harness.server.waitForMetadataStream();
		harness.server.emitMetadata(metadataAccepted(harness.server.requiredMetadataRequest(), 0));
		await harness.server.waitForControlKind('subscription.open');
		await harness.server.waitForControlKind('subscription.setScope');
		harness.server.failMetadataReader(new Error('first subscription acceptance lost'));
		await expect(firstTerminal).rejects.toThrow(/snapshot_required/iu);
		const fresh = harness.transport.subscribe(bridgeProductReviewMetadataApplicationProtocol, {});
		const freshTerminal = fresh.events[Symbol.asyncIterator]().next();
		observeSettlement(freshTerminal, (): void => {});
		await harness.server.waitForMetadataStream(2);
		harness.server.emitMetadata(
			metadataAccepted(harness.server.requiredMetadataRequest(1), 2, 'resumed'),
		);
		await harness.server.waitForControlKind('subscription.open', 2);
		await harness.server.waitForControlKind('subscription.setScope', 2);

		// Act: another EOF with opening acknowledgements only is no useful progress.
		harness.server.endMetadataStream();

		// Assert
		await expect(freshTerminal).rejects.toThrow(/ended unexpectedly/iu);
		expect(
			harness.server.controlRequests.filter((request) => request.kind === 'workerSession.resync'),
		).toHaveLength(1);
		expect(harness.server.metadataFetchCount).toBe(2);
	});

	test('claims a half-open control-admitted subscription and waits for replacement before typed recovery', async () => {
		const harness = createTransportHarness();
		const subscription = harness.transport.subscribe(bridgeProductFileMetadataApplicationProtocol, {
			source: fileSourceConfiguration(),
		});
		const terminal = subscription.events[Symbol.asyncIterator]().next();
		observeSettlement(terminal, (): void => {});
		await harness.server.waitForMetadataStream();
		const initial = harness.server.requiredMetadataRequest();
		harness.server.emitMetadata(metadataAccepted(initial, 0));
		await harness.server.waitForControlKind('subscription.open');
		await harness.server.waitForControlKind('subscription.setScope');
		harness.server.resyncHandler = (request): Response =>
			resyncResponse(request, [
				{
					disposition: 'reopenRequired',
					reason: 'snapshot_required',
					requiredWorkerDerivationEpoch: 0,
					subscriptionId: subscription.subscriptionId,
					subscriptionKind: 'file.metadata',
				},
			]);
		harness.server.failMetadataReader(new Error('lost acceptance'));
		await harness.server.waitForControlKind('workerSession.resync');
		const resync = harness.server.requiredControlRequest('workerSession.resync', 0);
		expect(resync.activeSubscriptions).toHaveLength(1);
		await harness.server.waitForMetadataStream(2);
		await expect(terminal).rejects.toThrow(/snapshot_required/iu);
		const fresh = harness.transport.subscribe(bridgeProductFileMetadataApplicationProtocol, {
			source: fileSourceConfiguration(),
		});
		expect(fresh.subscriptionId).not.toBe(subscription.subscriptionId);
		await Promise.resolve();
		expect(
			harness.server.controlRequests.filter((request) => request.kind === 'subscription.open'),
		).toHaveLength(1);
		const replacement = harness.server.requiredMetadataRequest(1);
		harness.server.emitMetadata(metadataAccepted(replacement, 1, 'snapshot_required'));
		await harness.server.waitForControlKind('subscription.open', 2);
		await harness.server.waitForControlKind('subscription.setScope', 2);
		harness.server.shutdown();
	});

	test('reopens a retained view whose resnapshot is refused as unknown without poisoning the metadata stream', async () => {
		// Arrange: native reconciles the ID, then definitively loses it before resnapshot.
		const harness = createTransportHarness();
		const first = await establishFileSubscription(harness);
		const firstTerminal = first.events.next();
		observeSettlement(firstTerminal, (): void => {});
		const sibling = harness.transport.subscribe(bridgeProductReviewMetadataApplicationProtocol, {});
		const siblingTerminal = sibling.events[Symbol.asyncIterator]().next();
		observeSettlement(siblingTerminal, (): void => {});
		await harness.server.waitForControlKind('subscription.open', 2);
		await harness.server.waitForControlKind('subscription.setScope', 2);
		const initialStream = harness.server.requiredMetadataRequest();
		harness.server.emitMetadata(
			subscriptionAccepted({
				epoch: 0,
				kind: 'review.metadata',
				request: initialStream,
				streamSequence: 2,
				subscriptionId: sibling.subscriptionId,
			}),
		);
		await harness.server.waitForControlKind('subscription.setScope', 2);
		harness.server.resnapshotHandler = (request): Response => {
			if (request.subscriptionId === sibling.subscriptionId)
				return new Response(
					JSON.stringify({
						domain: request.domain,
						handle: request.handle,
						incarnation: request.incarnation,
						kind: 'subscription.resnapshotAccepted',
						paneSessionId: request.paneSessionId,
						requestId: request.requestId,
						requestSequence: request.requestSequence,
						scopeRevision: request.scopeRevision,
						subscriptionId: request.subscriptionId,
						subscriptionKind: request.subscriptionKind,
						wireVersion: request.wireVersion,
						workerInstanceId: request.workerInstanceId,
					}),
					{ status: 200 },
				);
			return new Response(
				JSON.stringify({
					code: 'unknown_subscription',
					kind: 'request.error',
					nextExpectedRequestSequence: request.requestSequence,
					paneSessionId: request.paneSessionId,
					requestId: request.requestId,
					requestSequence: request.requestSequence,
					retryAfterMilliseconds: null,
					retryable: false,
					safeMessage: null,
					wireVersion: request.wireVersion,
					workerInstanceId: request.workerInstanceId,
				}),
				{ status: 200 },
			);
		};

		// Act: the physical reader drops; the replacement stream resumes with this ID retained.
		harness.server.failMetadataReader(new Error('physical stream disconnected'));
		await harness.server.waitForControlKind('workerSession.resync');
		const resync = harness.server.requiredControlRequest('workerSession.resync', 0);
		expect(resync.activeSubscriptions.map((active) => active.subscriptionId)).toContain(
			first.subscription.subscriptionId,
		);
		expect(resync.activeSubscriptions.map((active) => active.subscriptionId)).toContain(
			sibling.subscriptionId,
		);
		await harness.server.waitForMetadataStream(2);
		const resumed = harness.server.requiredMetadataRequest(1);
		if (resumed.resumeFromStreamSequence === null)
			throw new Error('Expected a resumed metadata stream.');
		harness.server.emitMetadata(
			metadataAccepted(resumed, resumed.resumeFromStreamSequence + 1, 'resumed'),
		);
		await harness.server.waitForControlKind('subscription.resnapshot');

		// Assert: local identity loss becomes a reset, so the existing view owner can reopen.
		await expect(firstTerminal).rejects.toThrow(/snapshot_required/iu);
		const replacement = harness.transport.subscribe(bridgeProductFileMetadataApplicationProtocol, {
			source: fileSourceConfiguration(),
		});
		await harness.server.waitForControlKind('subscription.open', 3);
		await harness.server.waitForControlKind('subscription.resnapshot', 2);
		expect(replacement.subscriptionId).not.toBe(first.subscription.subscriptionId);
		expect(harness.server.metadataFetchCount).toBe(2);
		expect(
			harness.server.controlRequests.filter(
				(request) =>
					request.kind === 'subscription.open' &&
					request.subscription.subscriptionKind === 'review.metadata',
			),
		).toHaveLength(1);
		expect(harness.transport.metadataStreamDiagnostics?.().activeSubscriptionCount).toBe(2);
		harness.server.shutdown();
	});

	test('treats authoritative unknown_subscription on cancel as benign without reopening', async () => {
		const suspectReasons: string[] = [];
		const harness = createTransportHarness({
			onSessionSuspect: (reason): void => {
				suspectReasons.push(reason);
			},
		});
		harness.server.cancelHandler = (request): Response =>
			new Response(
				JSON.stringify({
					code: 'unknown_subscription',
					kind: 'request.error',
					nextExpectedRequestSequence: request.requestSequence + 1,
					paneSessionId: request.paneSessionId,
					requestId: request.requestId,
					requestSequence: request.requestSequence,
					retryAfterMilliseconds: null,
					retryable: false,
					safeMessage: null,
					wireVersion: request.wireVersion,
					workerInstanceId: request.workerInstanceId,
				}),
				{ headers: { 'Content-Type': 'application/json' }, status: 404 },
			);
		const first = await establishFileSubscription(harness);
		await harness.server.waitForControlKind('subscription.open');
		await harness.server.waitForControlKind('subscription.setScope');
		await first.subscription.cancel();
		await harness.server.waitForControlKind('subscription.cancel');
		const second = harness.transport.subscribe(bridgeProductFileMetadataApplicationProtocol, {
			source: fileSourceConfiguration(),
		});
		await harness.server.waitForControlKind('subscription.open', 2);
		await harness.server.waitForControlKind('subscription.setScope', 2);
		expect(
			harness.server.controlRequests.filter(
				(request) =>
					request.kind === 'subscription.open' &&
					request.subscriptionId === first.subscription.subscriptionId,
			),
		).toHaveLength(1);
		expect(
			harness.server.controlRequests.filter((request) => request.kind === 'subscription.cancel'),
		).toHaveLength(1);
		expect(
			harness.server.controlRequests.filter((request) => request.kind === 'workerSession.resync'),
		).toHaveLength(0);
		expect(suspectReasons).toEqual([]);
		expect(second.subscriptionId).not.toBe(first.subscription.subscriptionId);
		harness.server.shutdown();
	});
	test('holds a fresh subscription behind an in-flight resync and does not open a second stream', async () => {
		const harness = createTransportHarness();
		const heldResponse = createBridgeProductDeferred<Response>();
		harness.server.resyncHandler = (): Promise<Response> => heldResponse.promise;
		const first = await establishFileSubscription(harness);
		harness.server.failMetadataReader(new Error('reader failed'));
		await harness.server.waitForControlKind('workerSession.resync');

		const fresh = harness.transport.subscribe(bridgeProductReviewMetadataApplicationProtocol, {});
		await Promise.resolve();
		expect(harness.server.metadataFetchCount).toBe(1);
		expect(
			harness.server.controlRequests.filter((request) => request.kind === 'subscription.open'),
		).toHaveLength(1);

		const request = harness.server.requiredControlRequest('workerSession.resync', 0);
		heldResponse.resolve(retainedResponse(request));
		await harness.server.waitForMetadataStream(2);
		const replacement = harness.server.requiredMetadataRequest(1);
		if (replacement.resumeFromStreamSequence === null)
			throw new Error('Expected a resumed metadata stream.');
		harness.server.emitMetadata(
			metadataAccepted(replacement, replacement.resumeFromStreamSequence + 1, 'resumed'),
		);
		await harness.server.waitForControlKind('subscription.open', 2);
		await harness.server.waitForControlKind('subscription.setScope', 2);
		void fresh;
		void first;
		harness.server.shutdown();
	});

	test('settles subscriptions and recovery waiters when resync fails', async () => {
		const harness = createTransportHarness();
		const heldResponse = createBridgeProductDeferred<Response>();
		harness.server.resyncHandler = (): Promise<Response> => heldResponse.promise;
		const first = await establishFileSubscription(harness);
		const terminal = first.events.next();
		observeSettlement(terminal, (): void => {});
		harness.server.failMetadataReader(new Error('reader failed'));
		await harness.server.waitForControlKind('workerSession.resync');
		const fresh = harness.transport.subscribe(bridgeProductReviewMetadataApplicationProtocol, {});
		const freshTerminal = fresh.events[Symbol.asyncIterator]().next();
		observeSettlement(freshTerminal, (): void => {});
		// Release failure only after the fresh subscriber has joined recovery.
		heldResponse.reject(new Error('resync transport failed twice'));
		await expect(terminal).rejects.toMatchObject({ name: 'BridgeProductSessionSuspectError' });
		await expect(freshTerminal).rejects.toMatchObject({ name: 'BridgeProductSessionSuspectError' });
		expect(harness.transport.metadataStreamDiagnostics?.().activeSubscriptionCount).toBe(0);
		harness.server.shutdown();
	});

	test.each(['none', 'presentation', 'selection'] as const)(
		'does not replenish recovery from connection replay (%s)',
		async (replayKind): Promise<void> => {
			const harness = createTransportHarness();
			const first = await establishFileSubscription(harness);
			const terminal = first.events.next();
			observeSettlement(terminal, (): void => {});
			const emitReplay = (
				request: BridgeProductMetadataStreamRequest,
				streamSequence: number,
			): Promise<void> => {
				const routed = createBridgeProductDeferred<void>();
				if (replayKind === 'presentation')
					harness.transport.setPanePresentationFrameSink?.((): void => {
						routed.resolve();
					});
				else
					harness.transport.setPaneSurfaceSelectionFrameSink?.((): void => {
						routed.resolve();
					});
				const replay =
					replayKind === 'presentation'
						? {
								fileRefreshFailure: null,
								kind: 'pane.presentation',
								nativeActivity: 'foreground',
								operationCorrelationId: null,
								presentationRevision: 1,
								refreshingLanes: [],
								reviewComparison: null,
							}
						: {
								kind: 'pane.surfaceSelectionRequested',
								navigationCommand: {
									bindingRevision: 1,
									commandId: 'retained-navigation',
									commandKind: 'activateContext',
									surface: 'file',
								},
							};
				harness.server.emitMetadata(
					bridgeProductMetadataFrameSchema.parse({
						...replay,
						metadataStreamId: request.metadataStreamId,
						paneSessionId: request.paneSessionId,
						streamSequence,
						wireVersion: request.wireVersion,
						workerInstanceId: request.workerInstanceId,
					}),
				);
				return routed.promise;
			};
			let nextStreamSequence = 2;
			if (replayKind !== 'none') {
				await emitReplay(harness.server.requiredMetadataRequest(), nextStreamSequence++);
				expect(harness.transport.metadataStreamDiagnostics?.().routedFrameCount).toBe(
					nextStreamSequence,
				);
			}
			harness.server.endMetadataStream();
			await harness.server.waitForMetadataStream(2);
			const replacement = harness.server.requiredMetadataRequest(1);
			harness.server.emitMetadata(metadataAccepted(replacement, nextStreamSequence++, 'resumed'));
			if (replayKind !== 'none') {
				await emitReplay(replacement, nextStreamSequence++);
				expect(harness.transport.metadataStreamDiagnostics?.().routedFrameCount).toBe(
					nextStreamSequence,
				);
			}
			harness.server.endMetadataStream();

			await Promise.race([
				terminal.then(
					(): void => {},
					(): void => {},
				),
				harness.server.waitForMetadataStream(3).then((): void => {}),
			]);
			expect(harness.server.metadataFetchCount).toBe(2);
			await expect(terminal).rejects.toThrow(/ended unexpectedly/iu);
			harness.server.shutdown();
		},
	);

	test('does not resync or reopen after a strict metadata identity failure', async () => {
		const harness = createTransportHarness();
		const subscription = harness.transport.subscribe(
			bridgeProductReviewMetadataApplicationProtocol,
			{},
		);
		const terminal = subscription.events[Symbol.asyncIterator]().next();
		await harness.server.waitForMetadataStream();
		const request = harness.server.requiredMetadataRequest();
		harness.server.emitMetadata(metadataAccepted(request, 0));
		harness.server.emitMetadata(
			bridgeProductMetadataFrameSchema.parse({
				...metadataAccepted(request, 1),
				metadataStreamId: 'wrong-stream',
			}),
		);

		await expect(terminal).rejects.toThrow();
		expect(harness.server.metadataFetchCount).toBe(1);
		expect(
			harness.server.controlRequests.filter(
				(candidate) => candidate.kind === 'workerSession.resync',
			),
		).toHaveLength(0);
		harness.server.shutdown();
	});
});
