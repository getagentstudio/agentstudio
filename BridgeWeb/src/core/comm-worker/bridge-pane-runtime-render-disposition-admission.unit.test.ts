import { afterEach, beforeEach, describe, expect, test, vi } from 'vitest';

import type { BridgeTelemetrySample } from '../../foundation/telemetry/bridge-telemetry-event.js';
import { encodeBridgeWorkerViewRecoveryRetryCommand } from './bridge-comm-worker-protocol.js';
import { makeReviewPublication } from './bridge-main-render-fulfillment-coordinator.test-support.js';
import type { BridgePaneCommWorkerDispatcher } from './bridge-pane-comm-worker-session.js';
import { createBridgePaneRuntime, type BridgePaneSessionPort } from './bridge-pane-runtime.js';
import type {
	BridgeWorkerMainToServerMessage,
	BridgeWorkerServerToMainMessage,
} from './bridge-worker-contracts.js';

describe('Bridge pane runtime render disposition admission', () => {
	beforeEach((): void => {
		vi.stubGlobal('cancelAnimationFrame', vi.fn());
		vi.stubGlobal(
			'requestAnimationFrame',
			vi.fn((): number => 1),
		);
	});

	afterEach((): void => {
		vi.unstubAllGlobals();
	});

	test('posts an urgent annotation action before the next acknowledged receipt batch', () => {
		const dispatchedMessages: BridgeWorkerMainToServerMessage[] = [];
		let publishWorkerMessages:
			| ((messages: readonly BridgeWorkerServerToMainMessage[]) => void)
			| undefined;
		const session: BridgePaneSessionPort = {
			createDispatcher: (props): BridgePaneCommWorkerDispatcher => {
				publishWorkerMessages = props.publishWorkerMessages;
				return {
					dispatch: (message): void => {
						dispatchedMessages.push(message);
					},
					dispose: vi.fn(),
				};
			},
			dispose: vi.fn(),
			installNativeBootstrap: vi.fn(),
		};
		const runtime = createBridgePaneRuntime({
			sessionFactory: (): BridgePaneSessionPort => session,
		});
		const reviewClient = runtime.surfaceClient('review');
		for (let index = 1; index <= 2; index += 1) {
			const publication = makeReviewPublication({
				itemId: `review-admission-item-${index}`,
				publicationSequence: index,
			});
			reviewClient.renderFulfillmentCoordinator.acceptPublication(publication);
			reviewClient.renderFulfillmentCoordinator.markPublicationQueued(publication);
			reviewClient.renderFulfillmentCoordinator.bindPublicationItem({
				finalItem: publication.job.payload.item,
				publicationItem: publication.job.payload.item,
				residency: 'replaced',
			});
		}
		const firstBatch = dispatchedMessages.find(
			(message): boolean => message.command === 'renderDisposition',
		);
		if (firstBatch === undefined) throw new Error('Expected an in-flight receipt batch.');

		reviewClient.send({
			command: 'annotationCommand',
			epoch: 1,
			operation: {
				body: 'urgent body',
				editToken: '00000000-0000-7000-8000-000000000041',
				expectedDraftRevision: 1,
				expectedMessageRevision: 1,
				kind: 'draft.flush',
				messageId: '00000000-0000-7000-8000-000000000042',
				sessionId: '00000000-0000-7000-8000-000000000043',
			},
			reviewPublicationIdentity: {
				packageId: 'package-current',
				publicationId: '00000000-0000-7000-8000-000000000044',
				reviewGeneration: 1,
				revision: 1,
				sourceIdentity: 'source-current',
			},
			surface: 'review',
		});
		expect(dispatchedMessages.map((message) => message.command)).toEqual([
			'renderDisposition',
			'annotationCommand',
		]);

		publishWorkerMessages?.([
			{
				direction: 'serverWorkerToMain',
				kind: 'health',
				requestId: firstBatch.requestId,
				status: 'ready',
				transferDescriptors: [],
				wireVersion: 1,
			},
		]);
		expect(dispatchedMessages.map((message) => message.command)).toEqual([
			'renderDisposition',
			'annotationCommand',
			'renderDisposition',
		]);
		runtime.dispose();
	});

	test('routes main admission telemetry through the installed main recorder', () => {
		const telemetrySamples: BridgeTelemetrySample[] = [];
		const session: BridgePaneSessionPort = {
			createDispatcher: (): BridgePaneCommWorkerDispatcher => ({
				dispatch: (): void => {},
				dispose: vi.fn(),
			}),
			dispose: vi.fn(),
			installNativeBootstrap: vi.fn(),
		};
		const runtime = createBridgePaneRuntime({
			sessionFactory: (): BridgePaneSessionPort => session,
		});
		runtime.installMainTelemetryRecorder({
			record: (sample): void => {
				telemetrySamples.push(sample);
			},
		});
		const coordinator = runtime.surfaceClient('review').renderFulfillmentCoordinator;
		const publication = makeReviewPublication({
			itemId: 'review-telemetry-item',
			publicationSequence: 1,
		});
		coordinator.acceptPublication(publication);
		coordinator.markPublicationQueued(publication);
		coordinator.bindPublicationItem({
			finalItem: publication.job.payload.item,
			publicationItem: publication.job.payload.item,
			residency: 'replaced',
		});

		expect(telemetrySamples).toEqual([
			expect.objectContaining({
				name: 'performance.bridge.web.render_disposition_admission',
			}),
		]);
		runtime.dispose();
	});

	test('closes receipt admission before replacement terminalizes old requests', () => {
		const dispatchedMessages: BridgeWorkerMainToServerMessage[] = [];
		let requestReplacement: ((reason: 'workerReplacement') => void) | undefined;
		const session: BridgePaneSessionPort = {
			createDispatcher: (): BridgePaneCommWorkerDispatcher => ({
				dispatch: (message): void => {
					dispatchedMessages.push(message);
				},
				dispose: vi.fn(),
			}),
			dispose: vi.fn(),
			installNativeBootstrap: vi.fn(),
			setNativeBootstrapRequester: (requester): void => {
				requestReplacement = requester;
			},
		};
		const runtime = createBridgePaneRuntime({
			sessionFactory: (): BridgePaneSessionPort => session,
		});
		runtime.setNativeBootstrapRequester(vi.fn());
		const coordinator = runtime.surfaceClient('review').renderFulfillmentCoordinator;
		for (let index = 1; index <= 2; index += 1) {
			const publication = makeReviewPublication({
				itemId: `review-replacement-item-${index}`,
				publicationSequence: index,
			});
			coordinator.acceptPublication(publication);
			coordinator.markPublicationQueued(publication);
			coordinator.bindPublicationItem({
				finalItem: publication.job.payload.item,
				publicationItem: publication.job.payload.item,
				residency: 'replaced',
			});
		}
		expect(
			dispatchedMessages.filter((message) => message.command === 'renderDisposition'),
		).toHaveLength(1);

		requestReplacement?.('workerReplacement');

		expect(
			dispatchedMessages.filter((message) => message.command === 'renderDisposition'),
		).toHaveLength(1);
		runtime.dispose();
	});

	test('keeps the worker and fails only the Review view after its disposition probe times out', () => {
		// Arrange
		vi.useFakeTimers();
		const dispatchedMessages: BridgeWorkerMainToServerMessage[] = [];
		const requestWorkerReplacement = vi.fn();
		let publishWorkerMessages:
			| ((messages: readonly BridgeWorkerServerToMainMessage[]) => void)
			| undefined;
		const session: BridgePaneSessionPort = {
			createDispatcher: (props): BridgePaneCommWorkerDispatcher => {
				publishWorkerMessages = props.publishWorkerMessages;
				return {
					dispatch: (message): void => {
						dispatchedMessages.push(message);
					},
					dispose: vi.fn(),
				};
			},
			dispose: vi.fn(),
			installNativeBootstrap: vi.fn(),
			requestWorkerReplacement,
		};
		const runtime = createBridgePaneRuntime({
			sessionFactory: (): BridgePaneSessionPort => session,
		});
		publishWorkerMessages?.([
			{
				direction: 'serverWorkerToMain',
				kind: 'viewRecoveryStatus',
				status: 'ready',
				transferDescriptors: [],
				view: { kind: 'review.metadata', subscriptionId: 'review-1' },
				wireVersion: 1,
			},
		]);
		const coordinator = runtime.surfaceClient('review').renderFulfillmentCoordinator;
		for (let index = 1; index <= 2; index += 1) {
			const publication = makeReviewPublication({
				itemId: `review-probe-timeout-item-${index}`,
				publicationSequence: index,
			});
			coordinator.acceptPublication(publication);
			coordinator.markPublicationQueued(publication);
			coordinator.bindPublicationItem({
				finalItem: publication.job.payload.item,
				publicationItem: publication.job.payload.item,
				residency: 'replaced',
			});
		}

		try {
			// Act
			vi.advanceTimersByTime(5_000);
			vi.advanceTimersByTime(5_000);
			vi.advanceTimersByTime(5_000);

			// Assert
			expect(
				dispatchedMessages.filter((message) => message.command === 'renderDisposition'),
			).toHaveLength(2);
			expect(requestWorkerReplacement).not.toHaveBeenCalled();
			expect(
				runtime.surfaceClient('review').renderStore.getViewRecoveryStatus('review.metadata')
					?.status,
			).toBe('failedRetryable');
			runtime.surfaceClient('review').send(
				encodeBridgeWorkerViewRecoveryRetryCommand({
					epoch: 2,
					requestId: 'retry-review-render-probe',
					view: { kind: 'review.metadata', subscriptionId: 'review-1' },
				}),
			);
			const retryPublication = makeReviewPublication({
				itemId: 'review-probe-retry-item',
				publicationSequence: 3,
			});
			coordinator.acceptPublication(retryPublication);
			coordinator.markPublicationQueued(retryPublication);
			coordinator.bindPublicationItem({
				finalItem: retryPublication.job.payload.item,
				publicationItem: retryPublication.job.payload.item,
				residency: 'replaced',
			});
			expect(
				dispatchedMessages.filter((message) => message.command === 'renderDisposition'),
			).toHaveLength(3);
		} finally {
			runtime.dispose();
			vi.useRealTimers();
		}
	});
});
