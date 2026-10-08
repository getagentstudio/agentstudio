import { uuidv7 } from 'uuidv7';
import { describe, expect, test } from 'vitest';

import { createBridgeProductDeferred } from './bridge-product-async-queue.js';
import { bridgeProductBatchFrameSchema } from './bridge-product-batch-wire-contracts.js';
import {
	bridgeProductFileAnnotationMetadataApplicationProtocol,
	bridgeProductFileMetadataApplicationProtocol,
	bridgeProductMetadataApplicationRegistry,
	bridgeProductReviewAnnotationMetadataApplicationProtocol,
	bridgeProductReviewMetadataApplicationProtocol,
} from './bridge-product-metadata-application-registry.js';
import { BridgeProductControlMux } from './bridge-product-session-authority.js';
import { productSessionBootstrap } from './bridge-product-session-authority.test-support.js';
import {
	bridgeProductControlRequestSchema,
	type BridgeProductControlRequest,
	type BridgeProductMetadataStreamRequest,
} from './bridge-product-session-contracts.js';
import { createBridgeProductTransport } from './bridge-product-transport.js';
import type { BridgeWorkerViewRecoveryStatusEvent } from './bridge-worker-view-recovery-contracts.js';
import {
	fileSourceConfiguration,
	metadataAccepted,
	subscriptionAccepted,
	TestProductServer,
	requestErrorResponse,
} from './test-fixtures/bridge-product-transport-metadata.test-support.js';

describe('Bridge metadata transport poisoning and user Retry', () => {
	test.each(['stream', 'open'] as const)(
		'a user reopen failing before W2 registration at %s remains retryable until a later install',
		async (failurePoint) => {
			const server = new TestProductServer();
			const authority = {
				bootstrap: productSessionBootstrap(),
				capabilityHeader: 'private-capability',
				open: Promise.resolve(),
			};
			const deadlineClock = { schedule: (): (() => void) => (): void => {} };
			let failNextStream = false;
			let failNextOpen = false;
			const executeProductRequest = async (
				route: 'command' | 'content' | 'stream',
				init: RequestInit,
			): Promise<Response> => {
				if (route === 'stream' && failNextStream) {
					failNextStream = false;
					throw new Error('fresh stream refused before registration');
				}
				if (
					route === 'command' &&
					failNextOpen &&
					(init.body instanceof Uint8Array || init.body instanceof ArrayBuffer)
				) {
					const parsed = bridgeProductControlRequestSchema.safeParse(
						JSON.parse(new TextDecoder().decode(init.body)),
					);
					if (parsed.success && parsed.data.kind === 'subscription.open') {
						failNextOpen = false;
						return requestErrorResponse(parsed.data, 'internal');
					}
				}
				return await server.fetch(`agentstudio://rpc/${route}`, init);
			};
			const statuses: Array<Pick<BridgeWorkerViewRecoveryStatusEvent, 'status' | 'view'>> = [];
			const firstInstall = createBridgeProductDeferred<void>();
			const finalInstall = createBridgeProductDeferred<void>();
			let finalSubscriptionId: string | null = null;
			let installedRows: readonly unknown[] = [];
			const transport = createBridgeProductTransport({
				authority,
				deadlineClock,
				executeProductRequest,
				controlMux: new BridgeProductControlMux({
					authority,
					deadlineClock,
					executeProductRequest,
				}),
				metadataApplicationRegistry: bridgeProductMetadataApplicationRegistry,
				onViewRecoveryStatus: (status): void => {
					statuses.push(status);
					if (status.status === 'ready') {
						firstInstall.resolve();
						if (status.view.subscriptionId === finalSubscriptionId) finalInstall.resolve();
					}
				},
			});
			transport.setBatchFrameSinks?.({
				install: (installation): void => {
					installedRows = installation.records.map((record) => record.value);
				},
				receipt: (): void => {},
				resnapshot: (): void => {},
				resnapshotLatest: (): void => {},
			});
			const original = transport.subscribe(bridgeProductReviewMetadataApplicationProtocol, {});
			const originalTerminal = original.events[Symbol.asyncIterator]()
				.next()
				.catch((error: unknown): unknown => error);
			try {
				const stream = await server.waitForMetadataStreamOpened();
				server.emitMetadata(metadataAccepted(stream, 0));
				await server.waitForControlRequestWhere(
					(request) =>
						request.kind === 'subscription.open' &&
						request.subscriptionId === original.subscriptionId,
				);
				server.emitMetadata(
					subscriptionAccepted({
						epoch: 0,
						kind: original.subscriptionKind,
						request: stream,
						streamSequence: 1,
						subscriptionId: original.subscriptionId,
					}),
				);
				const initialScope = await server.waitForControlRequestWhere(
					(request) =>
						request.kind === 'subscription.setScope' &&
						request.subscriptionId === original.subscriptionId,
				);
				if (initialScope.kind !== 'subscription.setScope')
					throw new Error('Expected initial scope.');
				emitRetainedSnapshot(server, stream, initialScope, 2);
				await firstInstall.promise;
				server.failMetadataReader(new Error('physical disconnect'));
				const resumed = await server.waitForMetadataStreamOpened(2);
				if (resumed.resumeFromStreamSequence === null) throw new Error('Expected resumed stream.');
				server.emitMetadata(
					metadataAccepted(resumed, resumed.resumeFromStreamSequence + 1, 'resumed'),
				);
				await server.waitForControlRequest('subscription.resnapshot');
				server.endMetadataStream();
				await originalTerminal;
				expect(statuses.at(-1)).toMatchObject({ status: 'failedRetryable' });
				expect(installedRows).toEqual([{ text: 'last good bank' }]);

				if (transport.retryView === undefined) throw new Error('Expected view Retry owner.');
				await transport.retryView(original.subscriptionId);
				failNextStream = failurePoint === 'stream';
				failNextOpen = failurePoint === 'open';
				const failed = transport.subscribe(bridgeProductReviewMetadataApplicationProtocol, {});
				const failedTerminal = failed.events[Symbol.asyncIterator]()
					.next()
					.catch((error: unknown): unknown => error);
				if (failurePoint === 'open') {
					const reopened = await server.waitForMetadataStreamOpened(3);
					server.emitMetadata(metadataAccepted(reopened, 0));
				}
				await failedTerminal;
				expect(statuses.at(-1)).toMatchObject({
					status: 'failedRetryable',
					view: { kind: 'review.metadata' },
				});
				expect(installedRows).toEqual([{ text: 'last good bank' }]);
				expect(
					server.controlRequests.some(
						(request) =>
							request.kind === 'subscription.setScope' &&
							request.subscriptionId === failed.subscriptionId,
					),
				).toBe(false);

				const retryStatus = statuses.at(-1);
				if (retryStatus === undefined) throw new Error('Expected a retryable surface identity.');
				await transport.retryView(retryStatus.view.subscriptionId);
				const fresh = transport.subscribe(bridgeProductReviewMetadataApplicationProtocol, {});
				finalSubscriptionId = fresh.subscriptionId;
				const freshStream =
					failurePoint === 'stream'
						? await server.waitForMetadataStreamOpened(3)
						: server.requiredMetadataRequest(2);
				if (failurePoint === 'stream') server.emitMetadata(metadataAccepted(freshStream, 0));
				await server.waitForControlRequestWhere(
					(request) =>
						request.kind === 'subscription.open' && request.subscriptionId === fresh.subscriptionId,
				);
				server.emitMetadata(
					subscriptionAccepted({
						epoch: 0,
						kind: fresh.subscriptionKind,
						request: freshStream,
						streamSequence: 1,
						subscriptionId: fresh.subscriptionId,
					}),
				);
				const freshScope = await server.waitForControlRequestWhere(
					(request) =>
						request.kind === 'subscription.setScope' &&
						request.subscriptionId === fresh.subscriptionId,
				);
				if (freshScope.kind !== 'subscription.setScope') throw new Error('Expected fresh scope.');
				expect(statuses.at(-1)).toMatchObject({
					status: 'recovering',
					view: { subscriptionId: fresh.subscriptionId },
				});
				emitRetainedSnapshot(server, freshStream, freshScope, 2);
				await finalInstall.promise;
				expect(statuses.at(-1)).toMatchObject({
					status: 'ready',
					view: { subscriptionId: fresh.subscriptionId },
				});
				expect(installedRows).toEqual([{ text: 'last good bank' }]);
				await fresh.cancel();
			} finally {
				server.shutdown();
				await original.cancel();
			}
		},
	);
	test('exhaustion publishes failedRetryable for all registered kinds before terminating their E3s', async () => {
		const server = new TestProductServer();
		const heldResnapshotReply = createBridgeProductDeferred<Response>();
		let resnapshotCount = 0;
		server.resnapshotHandler = (request): Response | Promise<Response> => {
			resnapshotCount += 1;
			return resnapshotCount === 4 ? heldResnapshotReply.promise : acceptedResnapshotReply(request);
		};
		const authority = {
			bootstrap: productSessionBootstrap(),
			capabilityHeader: 'private-capability',
			open: Promise.resolve(),
		};
		const deadlineClock = { schedule: (): (() => void) => (): void => {} };
		const executeProductRequest = (
			route: 'command' | 'content' | 'stream',
			init: RequestInit,
		): Promise<Response> => server.fetch(`agentstudio://rpc/${route}`, init);
		const statuses: Array<Pick<BridgeWorkerViewRecoveryStatusEvent, 'status' | 'view'>> = [];
		const transport = createBridgeProductTransport({
			authority,
			deadlineClock,
			executeProductRequest,
			controlMux: new BridgeProductControlMux({ authority, deadlineClock, executeProductRequest }),
			metadataApplicationRegistry: bridgeProductMetadataApplicationRegistry,
			onViewRecoveryStatus: (status): void => {
				statuses.push(status);
			},
		});
		transport.setBatchFrameSinks?.({
			install: (): void => {},
			receipt: (): void => {},
			resnapshot: (): void => {},
			resnapshotLatest: (): void => {},
		});
		const subscriptions = [
			transport.subscribe(bridgeProductFileMetadataApplicationProtocol, {
				source: fileSourceConfiguration(),
			}),
			transport.subscribe(bridgeProductReviewMetadataApplicationProtocol, {}),
			transport.subscribe(bridgeProductFileAnnotationMetadataApplicationProtocol, {}),
			transport.subscribe(bridgeProductReviewAnnotationMetadataApplicationProtocol, {}),
		];
		const terminations = subscriptions.map((subscription) =>
			subscription.events[Symbol.asyncIterator]()
				.next()
				.catch((error: unknown): unknown => error),
		);
		try {
			const initialStream = await server.waitForMetadataStreamOpened();
			server.emitMetadata(metadataAccepted(initialStream, 0));
			let sequence = 1;
			for (const subscription of subscriptions) {
				// eslint-disable-next-line no-await-in-loop -- Admissions establish the exact E3 before its lifecycle frame is delivered.
				await server.waitForControlRequestWhere(
					(request) =>
						request.kind === 'subscription.open' &&
						request.subscriptionId === subscription.subscriptionId,
				);
				server.emitMetadata(
					subscriptionAccepted({
						epoch: 0,
						kind: subscription.subscriptionKind,
						request: initialStream,
						streamSequence: sequence++,
						subscriptionId: subscription.subscriptionId,
					}),
				);
				// eslint-disable-next-line no-await-in-loop -- W2 registration and its initial scope are observed before poisoning.
				await server.waitForControlRequestWhere(
					(request) =>
						request.kind === 'subscription.setScope' &&
						request.subscriptionId === subscription.subscriptionId,
				);
			}
			const scope = server.requiredControlRequest('subscription.setScope', 0);
			server.failMetadataReader(new Error('first physical disconnect'));
			const resumedStream = await server.waitForMetadataStreamOpened(2);
			if (resumedStream.resumeFromStreamSequence === null)
				throw new Error('Expected a resumed stream.');
			server.emitMetadata(
				metadataAccepted(resumedStream, resumedStream.resumeFromStreamSequence + 1, 'resumed'),
			);
			await server.waitForControlRequest('subscription.resnapshot', 4);
			server.emitMetadata(
				bridgeProductBatchFrameSchema.parse({
					domain: scope.domain,
					handle: scope.handle,
					incarnation: scope.incarnation,
					paneSessionId: scope.paneSessionId,
					scope: scope.scope,
					scopeRevision: scope.scopeRevision,
					subscriptionId: scope.subscriptionId,
					subscriptionKind: scope.subscriptionKind,
					wireVersion: scope.wireVersion,
					workerInstanceId: scope.workerInstanceId,
					kind: 'subscription.batchBegin',
					batchId: 'uninstalled-recovered-batch',
					baseRevision: 0,
					targetRevision: 1,
					mode: 'snapshot',
					snapshotCause: 'open',
					partCount: 1,
					metadataStreamId: resumedStream.metadataStreamId,
					streamSequence: resumedStream.resumeFromStreamSequence + 2,
				}),
			);
			server.endMetadataStream();
			await Promise.all(terminations);
			expect(
				statuses
					.filter((status) => status.status === 'failedRetryable')
					.map((status) => status.view.kind)
					.toSorted(),
			).toEqual(['file.annotations', 'file.metadata', 'review.annotations', 'review.metadata']);
			expect(
				server.controlRequests.filter((request) => request.kind === 'workerSession.resync'),
			).toHaveLength(1);
			expect(transport.metadataStreamDiagnostics?.().activeSubscriptionCount).toBe(0);

			// A fresh E3 is the existing Retry owner; its physical open does not renew RR6.
			const lastResnapshot = server.requiredControlRequest('subscription.resnapshot', 3);
			heldResnapshotReply.resolve(acceptedResnapshotReply(lastResnapshot));
			const fresh = transport.subscribe(bridgeProductReviewMetadataApplicationProtocol, {});
			const freshTerminal = fresh.events[Symbol.asyncIterator]()
				.next()
				.catch((error: unknown): unknown => error);
			// The wrong path admits a new E3 onto stale readiness. Its open control is
			// a causal counterexample, so the regression fails without a time budget.
			const reopenBoundary = await Promise.race([
				server
					.waitForMetadataStreamOpened(3)
					.then((stream) => ({ kind: 'freshStream', stream }) as const),
				server
					.waitForControlRequestWhere(
						(request) =>
							request.kind === 'subscription.open' &&
							request.subscriptionId === fresh.subscriptionId,
					)
					.then(() => ({ kind: 'staleStream' }) as const),
			]);
			expect(reopenBoundary.kind).toBe('freshStream');
			if (reopenBoundary.kind !== 'freshStream')
				throw new Error('Fresh E3 admitted onto poisoned stream readiness.');
			const freshStream = reopenBoundary.stream;
			server.emitMetadata(metadataAccepted(freshStream, 0));
			await server.waitForControlRequestWhere(
				(request) =>
					request.kind === 'subscription.open' && request.subscriptionId === fresh.subscriptionId,
			);
			server.emitMetadata(
				subscriptionAccepted({
					epoch: 0,
					kind: fresh.subscriptionKind,
					request: freshStream,
					streamSequence: 1,
					subscriptionId: fresh.subscriptionId,
				}),
			);
			await server.waitForControlRequestWhere(
				(request) =>
					request.kind === 'subscription.setScope' &&
					request.subscriptionId === fresh.subscriptionId,
			);
			expect(statuses.at(-1)).toMatchObject({
				status: 'recovering',
				view: { subscriptionId: fresh.subscriptionId },
			});
			server.endMetadataStream();
			await freshTerminal;
			expect(
				server.controlRequests.filter((request) => request.kind === 'workerSession.resync'),
			).toHaveLength(1);
		} finally {
			heldResnapshotReply.reject(new Error('test cleanup'));
			server.shutdown();
			await Promise.allSettled(subscriptions.map((subscription) => subscription.cancel()));
		}
	});
});

function emitRetainedSnapshot(
	server: TestProductServer,
	stream: BridgeProductMetadataStreamRequest,
	scope: Extract<BridgeProductControlRequest, { kind: 'subscription.setScope' }>,
	sequence: number,
): void {
	const identity = {
		batchId: uuidv7(),
		domain: scope.domain,
		handle: scope.handle,
		incarnation: scope.incarnation,
		metadataStreamId: stream.metadataStreamId,
		paneSessionId: stream.paneSessionId,
		scopeRevision: scope.scopeRevision,
		subscriptionId: scope.subscriptionId,
		subscriptionKind: scope.subscriptionKind,
		wireVersion: stream.wireVersion,
		workerInstanceId: stream.workerInstanceId,
	};
	server.emitMetadata(
		bridgeProductBatchFrameSchema.parse({
			...identity,
			baseRevision: 0,
			kind: 'subscription.batchBegin',
			mode: 'snapshot',
			snapshotCause: 'open',
			partCount: 1,
			publicationId: uuidv7(),
			scope: scope.scope,
			streamSequence: sequence,
			targetRevision: 1,
		}),
	);
	server.emitMetadata(
		bridgeProductBatchFrameSchema.parse({
			...identity,
			deliverySequence: 1,
			kind: 'subscription.batchPart',
			partIndex: 0,
			part: {
				key: 'retained-row',
				operation: 'put',
				revision: 1,
				value: { text: 'last good bank' },
			},
			streamSequence: sequence + 1,
		}),
	);
	server.emitMetadata(
		bridgeProductBatchFrameSchema.parse({
			...identity,
			coveredScope: scope.scope,
			kind: 'subscription.batchComplete',
			streamSequence: sequence + 2,
		}),
	);
}

function acceptedResnapshotReply(
	request: Extract<BridgeProductControlRequest, { kind: 'subscription.resnapshot' }>,
): Response {
	return new Response(JSON.stringify({ ...request, kind: 'subscription.resnapshotAccepted' }), {
		headers: { 'Content-Type': 'application/json' },
	});
}
